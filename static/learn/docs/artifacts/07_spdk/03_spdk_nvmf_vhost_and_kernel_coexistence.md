# SPDK 스토리지 서비스 계층: NVMe-oF target, vhost, vfio-user, ublk와 커널(nvmet·io_uring passthrough)과의 공존

> 기준: SPDK `master` (v27.01 개발 중, 2026-10-14 확인), 최신 릴리스 v26.09. Linux 쪽은 `torvalds/linux` master(2026-10 확인)의 `drivers/nvme/target/`, `drivers/block/ublk_drv.c`. SPDK 함수 이름은 `lib/nvmf/{nvmf.c,transport.c,tcp.c,vfio_user.c}`, `lib/vhost/`, `lib/ublk/ublk.c`, `include/spdk/{nvmf.h,nvmf_transport.h,vhost.h}` 원문과 대조했다. 커널 기능의 도입 버전은 GitHub에서 확인한 최초 커밋 날짜와 FAST '24 논문의 Table 2를 근거로 한다.

## 1. Verdict

SPDK의 실제 쓰임새는 "애플리케이션에 링크하는 NVMe 드라이버"보다 **스토리지 서비스를 제공하는 데몬**(`spdk_tgt`, `nvmf_tgt`, `vhost`)에 가깝다. 스레딩 모델(→ 07/01)과 bdev 스택(→ 07/02) 위에, 소비자에게 장치를 노출하는 네 가지 "프런트엔드"가 있다.

| 프런트엔드 | 소비자 | 전송 경로 | SPDK 도입 |
|---|---|---|---|
| NVMe-oF target (`lib/nvmf`) | 원격 호스트(커널 `nvme-tcp`/`nvme-rdma`, SPDK initiator) | TCP, RDMA, FC | v16.06 (RDMA), v19.01 (TCP), v19.07 (FC) |
| vhost-user-scsi / -blk (`lib/vhost`) | QEMU VM(게스트 virtio 드라이버) | UNIX 소켓 제어 + 공유 메모리 virtqueue | v17.03 (scsi), v17.07 (blk) |
| vfio-user (`lib/nvmf/vfio_user.c`, `lib/vfu_tgt`) | QEMU VM(게스트 **NVMe** 또는 virtio 드라이버) | vfio-user 프로토콜 + 공유 메모리 | v21.01 (NVMe), v22.09 (virtio-blk/scsi) |
| ublk target (`lib/ublk`) | 같은 호스트의 프로세스·컨테이너(`/dev/ublkbN`) | 커널 ublk_drv + io_uring `IORING_OP_URING_CMD` | v23.01 (Linux 6.0+) |

결론은 다음과 같다.

1. **NVMe-oF target의 "SPDK다움"은 poll group에 있다.** `spdk_nvmf_tgt`는 `spdk_io_device`이고 `spdk_nvmf_poll_group`은 그 io_channel 컨텍스트다(`spdk_io_device_register(tgt, nvmf_tgt_create_poll_group, ...)`). 새 qpair(= 네트워크 연결)는 하나의 poll group에 배정되고, 그 뒤 READ/WRITE는 해당 스레드 안에서 네트워크 수신부터 bdev 제출과 완료까지 락 없이 처리된다.
2. **vhost와 vfio-user는 "게스트 메모리를 직접 매핑해 virtqueue/NVMe 큐를 폴링하는" 같은 계열의 설계다.** QEMU는 제어 평면만 중계한다. vfio-user는 virtio가 아니라 NVMe 장치를 그대로 에뮬레이트하므로 게스트에 별도 virtio 드라이버가 필요 없다. 다만 SPDK의 vfio-user live migration 코드는 v25.09에서 제거됐다(libvfio-user v2 인터페이스 전환 때문).
3. **커널과의 관계는 경쟁에서 공존으로 바뀌었다.** 커널에는 `nvmet`(2016), `nvmet-tcp`(2018-12 커밋), `nvmet` passthru(2020-07 커밋), ublk(2022-07 커밋, 6.0), io_uring NVMe passthrough(5.19)가 들어왔다. SPDK도 xNVMe/uring bdev로 커널 경로를 쓰고, ublk로 커널에 블록 장치를 내보낸다.
4. **FAST '24의 정량 비교에 따르면 성능 우위는 남아 있지만 격차는 좁아졌다.** 장치당 코어 하나일 때 Optane P5800X 2개에서 passthrough와 SPDK가 모두 약 10M IOPS로 장치를 포화시켰고, block 경로는 7.55M IOPS였다. **코어 하나로 장치 2개를 구동하면** SPDK는 계속 포화시켰지만 block 4.4M, passthrough 6M에 그쳤다. 커널 설정을 바꾸면 block 7.9M, passthrough 8.3M이 됐다. 흔히 인용되는 "SPDK의 99%" 같은 수치는 이 논문에 없다.
5. **운영상 비용은 CPU 점유, 격리, 관측성 세 가지다.** interrupt 모드(→ 07/01, 4.7절)가 첫째를 완화하고 있다. 둘째(장치 독점, 루트 권한/IOMMU group)와 셋째(커널 `iostat`/blktrace에서 보이지 않음)는 SPDK 자체 도구(`spdk_top`, `spdk_trace`, USDT 기반 BPF 트레이싱, `bdev_get_iostat` RPC)로 대체해야 한다.

---

## 2. Problem Statement

### 2.1 원격 블록 서비스: 커널 target의 처리 구조

Linux 커널 NVMe-oF target(`nvmet`)은 `drivers/nvme/target/`에 있다. Christoph Hellwig의 "nvmet: add a generic NVMe target" 커밋(a07b4970f464, 2016-07)으로 시작했고, TCP transport는 Sagi Grimberg의 "nvmet-tcp: add NVMe over TCP target driver" 커밋(872d26a391da, 2018-12)으로 들어왔다. 태그별 소스로 확인하면 `drivers/nvme/target/core.c`는 Linux 4.8에, `tcp.c`는 Linux 5.0에 처음 나타난다(passthru `passthru.c`는 Linux 5.9). 현재 master의 nvmet-tcp 데이터 경로는 다음과 같다.

- 소켓 콜백 `nvmet_tcp_data_ready()`(`sk->sk_data_ready`)가 `queue_work_on(queue_cpu(queue), nvmet_tcp_wq, &queue->io_work)`로 작업을 큐잉한다.
- 워크 함수 `nvmet_tcp_io_work()`가 `nvmet_tcp_try_recv()` → `nvmet_tcp_try_recv_pdu()` 같은 수신 함수와 송신을 예산(`NVMET_TCP_RECV_BUDGET`) 단위로 처리한다.
- bdev 백엔드는 `nvmet_bdev_parse_io_cmd()`가 `req->execute = nvmet_bdev_execute_rw`를 설정하고 bio를 만들어 블록 계층으로 내려보낸다.
- 모듈 파라미터 `idle_poll_period_usecs`(기본 0)를 쓰면 io_work가 큐를 바로 idle로 판정하지 않고 지정한 시간 동안 폴링한다. 주석에 따르면 "advanced interrupt moderation" NIC과 함께 쓰는 선택적 동작이다.

즉 커널 target은 **인터럽트 → softirq → workqueue → block 계층**이라는 일반 커널 경로를 쓴다. 장치를 공유할 수 있고 cgroup이나 파일시스템과도 함께 쓸 수 있다. 대신 요청마다 workqueue 스케줄링, bio 할당, 블록 계층 처리를 거친다.

### 2.2 가상화 스토리지: QEMU를 데이터 경로에서 빼기

[Virtualized I/O with Vhost-user](https://spdk.io/doc/vhost_processing.html) 문서는 순수 virtio에서는 "it's always the QEMU process that handles all I/O traffic"이라고 지적한다. 커널 vhost(vhost-scsi 등)는 ioctl 인터페이스로 커널 안에서 virtqueue를 처리한다. SPDK는 vhost-user 프로토콜로 같은 일을 사용자 공간 데몬에서 한다. 이렇게 하면 QEMU의 I/O 스레드와 커널 블록 계층을 모두 데이터 경로에서 뺄 수 있다. 남은 문제는 게스트에 virtio 드라이버가 있어야 한다는 점(Windows, UEFI 부팅)과 virtio-scsi/blk 의미론의 한계였다. vfio-user는 이 문제를 겨냥했다.

### 2.3 로컬 컨테이너: SPDK 장치를 커널 블록 장치로

SPDK가 장치를 가져가면 같은 호스트의 다른 프로세스(컨테이너)는 그 장치를 커널 블록 장치로 볼 수 없다. Jim Harris의 2023-03-28 블로그 [ublk: the new and improved way to serve SPDK storage locally!](https://spdk.io/news/2023/03/28/ublk/)는 이 문제의 역사를 정리한다. 처음에는 nbd(v17.07)를 썼지만 "massive scalability and performance problems"가 있었다. 그다음 권장 방식은 NVMe/TCP loopback(SPDK target + 커널 initiator)이었다. 블로그는 OpenEBS Mayastor가 이 방식을 쓴다고 소개하면서도, TCP loopback이 "always felt a bit kludgy"했다고 적었다. ublk는 이 공백을 메우려는 시도다.

### 2.4 커널 쪽의 반격: 같은 하드웨어 효율을 커널 안에서

FAST '24 [I/O Passthru: Upstreaming a flexible and efficient I/O Path in Linux](https://www.usenix.org/conference/fast24/presentation/joshi)는 Table 2에서 커널 기능의 도입 순서를 정리한다. 문자 장치 `/dev/ngXnY` 초기 지원은 5.13, io_uring command와 NVMe uring passthrough는 5.19, 임의 command set 지원은 6.0, 폴링·fixed buffer 같은 효율 옵션은 6.1, 비특권 passthrough는 6.2다. 논문은 SPDK의 약점으로 장치 독점(멀티테넌트 어려움), 폴링 전용, 클라우드에서 raw PCIe 접근이 어렵다는 점을 들고, 커널 안에서 유연성과 효율을 함께 얻는 경로를 제시했다.

---

## 3. The Debate

### 3.1 "커널 바이패스는 여전히 필요한가": FAST '24의 측정과 그 해석

FAST '24 논문 7.3절은 AMD Ryzen 9 5900X, Intel Optane P5800X(사양 5M IOPS, 512B random read), Linux 6.2 환경(논문 Table 3)에서 io_uring block 경로, io_uring passthrough(`io_uring_char`), SPDK `perf`를 비교했다. 원문은 다음과 같다.

> "The block path shows 7.55M IOPS with two devices, whereas the passthrough and SPDK paths show 10M IOPS. The second experiment examines the per-core scalability by forcing a single CPU core for both devices. Figure 12(b) shows the comparison. SPDK continues to saturate both the devices. Block path shows 4.4M, while passthrough reaches 6M IOPS."
>
> — Joshi et al., FAST '24 (2024-02), §7.3, [논문 PDF](https://www.usenix.org/system/files/fast24-joshi.pdf)

해설: 장치당 코어 하나가 주어지면 passthrough도 장치 한계(약 5M×2)에 닿는다. 코어 예산이 빠듯할 때 SPDK가 앞선다. 논문은 그 이유를 세 가지로 든다. (1) SPDK `perf`는 장치를 독점하므로 공유·동기화 코드가 없다("single-user luxury"). (2) passthrough도 block 계층의 hctx·태그·타임아웃을 쓴다. (3) writeback throttling과 blk-cgroup 같은 기능이 passthrough 경로에 맞지 않는다. 저자들은 6.8 커널부터 passthrough I/O에서 이 기능들을 건너뛴다고 밝혔다. 또 커널 설정(강제 선점 끄기, HZ=100)을 바꾸면 block 7.9M, passthrough 8.3M까지 오른다고 보고했다.

이 결과는 "커널이 SPDK를 따라잡았다"는 근거도, "SPDK가 압도적이다"라는 근거도 아니다. **코어당 효율**에서는 SPDK가 앞서고, **장치당 코어를 하나씩 줄 수 있다면** 커널 passthrough로도 장치를 포화시킬 수 있다는 결과로 읽어야 한다. 실제 서비스(NVMe-oF target, vhost)에서는 네트워크 처리와 bdev 기능이 더해진다. 그래서 이 마이크로벤치마크 격차가 그대로 서비스 성능 격차가 된다고 볼 근거는 없다.

### 3.2 vhost-user vs vfio-user: virtio를 계속 쓸 것인가

Ben Walker는 2021-05-04 블로그 [VFIO-USER: A new virtualization protocol](https://spdk.io/news/2021/05/04/vfio-user/)에서 vfio-user를 "just like vhost-user but able to emulate NVMe devices instead of virtio-blk or virtio-scsi devices"라고 소개했다. 그가 든 근거는 다음과 같다.

> "By emulating a physical NVMe device, any operating system with an NVMe driver (i.e. all of them) can talk to the device. This is especially important for Windows - no more loading virtio drivers! It also allows for virtual machines to boot from the emulated NVMe devices because the UEFI BIOS contains an NVMe driver."
>
> — Ben Walker, SPDK 블로그 (2021-05-04), [VFIO-USER: A new virtualization protocol](https://spdk.io/news/2021/05/04/vfio-user/)

해설: 구현 측면에서 핵심은 NVMe 장치 에뮬레이션을 **기존 NVMe-oF target에 transport로 붙였다**는 점이다. 블로그는 NVMe-oF 사양이 이미 NVMe 장치 에뮬레이션 대부분을 요구했기 때문에 "It really was as simple as adding a new transport plugin for vfio-user"라고 설명한다. 서버 쪽 프로토콜 처리는 Nutanix의 [libvfio-user](https://github.com/nutanix/libvfio-user)에 맡겼다. 반대로 vhost-user는 QEMU/DPDK 생태계에서 오래 검증됐고 live migration 같은 기능이 성숙했다. SPDK의 vfio-user migration 코드는 v25.09에서 제거됐다. CHANGELOG는 그 이유로 동작하지 않는 상태였다는 점, upstream libvfio-user가 v2 인터페이스로 바뀐 점, QEMU 10.1에 아직 vfio-user live migration이 없다는 점을 든다. 운영 측면에서 vfio-user가 vhost-user를 대체했다고 보기는 이르다.

### 3.3 nbd → NVMe/TCP loopback → ublk: 로컬 노출 방식의 변천

ublk 블로그(2023-03-28)는 ublk가 "all based around io_uring and blk-mq (multi-queue)"라는 점을 장점으로 든다. 커널 쪽에서는 Ming Lei의 "ublk_drv: add io_uring based userspace block driver" 커밋(71f28f3136af, 2022-07)으로 들어왔고, LWN [An io_uring-based user-space block driver](https://lwn.net/Articles/903855/)는 이 드라이버가 6.0 merge window에 io_uring pull request의 일부로 병합됐다고 전한다. 쟁점은 데이터 복사다. SPDK [ublk Target](https://spdk.io/doc/ublk.html) 문서에 따르면 I/O 데이터는 사용자 버퍼와 request/bio 페이지 사이에서 "copied only once"된다. 즉 zero-copy가 아니다. 커널 커뮤니티는 이후 ublk zero-copy를 여러 방식으로 논의했다(LWN "Zero-copy I/O for ublk, three different ways" 등). 하지만 SPDK ublk가 어느 zero-copy 경로를 쓰는지는 이 문서 작성 중 확인하지 못했다 [추측/미확인]. `lib/ublk/ublk.c`에는 `UBLK_F_USER_COPY` 플래그 처리가 있다.

### 3.4 폴링 비용 논쟁: "유휴 코어 100%"

SPDK를 두고 흔히 "유휴 상태에서도 코어를 100% 회전"시키고 "다중 프로세스 공유 불가"라고 설명한다. 2026년 기준으로 보면 두 주장 모두 정정이 필요하다.

- 기본(poll) 모드에서 reactor 코어가 100%로 도는 것은 사실이다. SPDK [Interrupt Mode](https://spdk.io/doc/interrupt_mode.html) 문서도 "burns 100% CPU"라고 인정한다.
- 하지만 `--interrupt-mode`(v24.01), dynamic scheduler(v21.01), NVMe-oF TCP(v24.09)·RDMA(v26.01) target과 NVMe PCIe(v25.05) interrupt 지원이 이미 들어와 있다. [NVMe over Fabrics Target](https://spdk.io/doc/nvmf.html) 문서는 vfio-user, TCP, RDMA transport가 interrupt 모드를 지원한다고 명시한다.
- 그렇다고 interrupt 모드가 공짜는 아니다. 4.7절(→ 07/01)에서 봤듯이 진짜 fd가 없는 active poller는 interrupt 모드에서도 계속 돈다. sock uring, NVMe-oF FC처럼 지원하지 않는 구성요소가 하나라도 있으면 전역 interrupt 모드를 쓸 수 없다.
- multi-process는 v16.12부터 있었다(→ 07/02, 4.5절). 다만 같은 shm 그룹 안에서만 공유된다.

---

## 4. Implementation Impact

### 4.1 NVMe-oF target: 객체 모델과 poll group

[NVMe over Fabrics Target Programming Guide](https://spdk.io/doc/nvmf_tgt_pg.html)가 정의하는 기본 객체는 `struct spdk_nvmf_tgt`, `spdk_nvmf_subsystem`, `spdk_nvmf_ns`(= bdev), `spdk_nvmf_qpair`(네트워크 연결과 1:1), `spdk_nvmf_transport`, `spdk_nvmf_poll_group`, `spdk_nvmf_listener`, `spdk_nvmf_host`다. 구성 순서는 다음과 같다.

```
tgt = spdk_nvmf_tgt_create(&opts)
   └─ spdk_io_device_register(tgt, nvmf_tgt_create_poll_group, nvmf_tgt_destroy_poll_group,
                              sizeof(struct spdk_nvmf_poll_group), tgt->name)
transport = spdk_nvmf_transport_create("TCP", &topts)   // RPC: nvmf_create_transport -t TCP
spdk_nvmf_tgt_add_transport(tgt, transport, cb, ctx)
spdk_nvmf_tgt_listen_ext(tgt, &trid, &listen_opts)
ss = spdk_nvmf_subsystem_create_ext(tgt, nqn, SPDK_NVMF_SUBTYPE_NVME, nsid_max, ...)
spdk_nvmf_subsystem_add_ns_ext(ss, "Nvme0n1", &ns_opts, ...)
spdk_nvmf_subsystem_add_listener(ss, &trid, cb, ctx)
spdk_nvmf_subsystem_start(ss, cb, ctx)                  // Inactive → Active
각 데이터 스레드에서: spdk_nvmf_poll_group_create(tgt)  // = spdk_get_io_channel(tgt)
```

- `nvmf_tgt_create_poll_group()`는 대상 스레드를 기록하고(`group->thread = spdk_get_thread()`), 등록된 모든 transport에 transport별 poll group을 만든다(`nvmf_poll_group_add_transport()`).
- transport poll group마다 `spdk_poller_register_named(nvmf_tgroup_poll, tgroup, 0, name)`으로 **주기 0 poller**를 등록하고, `spdk_poller_register_interrupt()`로 interrupt 전환이 가능하다고 표시한다(`lib/nvmf/transport.c`). `nvmf_tgroup_poll()`은 `transport->ops->poll_group_poll()`을 호출한다.
- 새 연결(`spdk_nvmf_tgt_new_qpair()`)은 먼저 `spdk_nvmf_get_optimal_poll_group(qpair)`(transport의 `get_optimal_poll_group` 콜백)으로 배정할 그룹을 찾는다. 없으면 `tgt->next_poll_group`을 라운드 로빈으로 돈다. 그다음 `spdk_thread_send_msg(group->thread, _nvmf_poll_group_add, ctx)`로 **그 스레드에서** qpair를 붙인다.
- 프로그래밍 가이드에 따르면 READ/WRITE 같은 일반 명령은 "processed on the initial thread from start to the point where it is submitted to the backing storage device, without interruption"이고 락을 잡지 않는다. 반면 namespace 변경처럼 전역 상태를 바꾸는 ADMIN 명령은 subsystem을 **pause**한다. 모든 스레드에 메시지를 보내 새 I/O를 큐에 쌓게 한 뒤 상태를 바꾸고 resume한다.

`struct spdk_nvmf_transport_ops`(`include/spdk/nvmf_transport.h`)의 콜백은 transport 플러그인 경계를 보여 준다. 주요 콜백은 `opts_init`, `create`/`create_async`, `destroy`, `listen`/`stop_listen`, `listen_associate`, `cdata_init`, `listener_discover`, `poll_group_create`, `get_optimal_poll_group`, `poll_group_add`/`remove`, `poll_group_poll`, `req_free`, `req_complete`, `qpair_fini`, `qpair_get_peer_trid`, `qpair_abort_request`, `poll_group_dump_stat`, `subsystem_add_host` 등이다. vfio-user 블로그가 말한 "transport plugins can even exist in shared libraries outside of the SPDK repository"가 이 테이블로 구현된다.

### 4.2 TCP transport

- 수락: `accept_poller = SPDK_POLLER_REGISTER(nvmf_tcp_accept, ...)`(주기 poller, interrupt 등록 가능).
- 데이터: transport poll group은 `spdk_sock_group`을 가지고, `nvmf_tcp_poll_group_poll()`이 `spdk_sock_group_poll()`을 호출해 준비된 소켓을 처리한다. 소켓 구현은 posix(커널 TCP 스택, epoll)와 uring이 있고, VPP 구현은 제거됐다(CHANGELOG v20.10 "Removed socket abstraction for VPP"). **TCP/IP 스택 자체는 여전히 커널이다.** SPDK가 우회하는 것은 블록 계층과 스케줄링이다.
- 요청 상태 머신 `nvmf_tcp_req_process()`: `TCP_REQUEST_STATE_NEW` → `NEED_BUFFER` → `HAVE_BUFFER` → (쓰기면 `TRANSFERRING_HOST_TO_CONTROLLER`) → `READY_TO_EXECUTE` → `EXECUTING` → `EXECUTED` → `READY_TO_COMPLETE` → (읽기면 `TRANSFERRING_CONTROLLER_TO_HOST`) → `COMPLETED`. zcopy bdev를 쓸 때는 `AWAITING_ZCOPY_START/COMMIT/RELEASE` 상태를 추가로 거친다.
- 보안: NVMe/TCP TLS 1.3 PSK(`TLS_AES_256_GCM_SHA384` 권장 / `TLS_AES_128_GCM_SHA256`). 문서는 "experimental"이라고 표기한다([NVMe over Fabrics Target](https://spdk.io/doc/nvmf.html)).
- 보안 이력: v25.09 CHANGELOG에는 PTPL(Persist Through Power Loss)을 켰을 때 reservation 등록자가 16개(`SPDK_NVMF_MAX_NUM_REGISTRANTS`)를 넘으면 배열 경계를 넘어 쓰는 취약점(CVE-2025-57275)을 고쳤다는 기록이 있다. TCP와 RDMA target 모두 해당되고 PTPL 기본값은 꺼짐이다.

### 4.3 RDMA transport

프로그래밍 가이드에 따르면 RDMA transport는 libibverbs/rdmacm 위에 구현되고 DPDK 사용자 공간 RDMA 스택은 쓰지 않는다. 구조는 다음과 같다.

- **poll group마다 RDMA CQ 하나**를 두고, 그룹에 배정된 모든 qpair가 이 CQ를 공유한다. 그래서 연결이 수천 개여도 CQ 하나만 폴링하면 된다.
- RECV와 SEND 완료 순서가 보장되지 않는 문제(새 캡슐 RECV가 이전 SEND ACK보다 먼저 보일 수 있음)를 다루려고 요청을 `rdma_recv`와 `rdma_request` 두 부분으로 나눴다.
- READ/WRITE 작업 큐 깊이가 SEND/RECV보다 작은 NIC이 많아서, 부족분은 소프트웨어 큐로 흡수한다.
- SRQ(shared receive queue) 사용 여부와 깊이는 `nvmf_create_transport`의 `no_srq`, `max_srq_depth` 파라미터로 정한다([JSON-RPC](https://spdk.io/doc/jsonrpc.html)).
- 데이터는 NIC → 호스트 메모리 → SSD로 이동하고 중간 복사는 없다. 이를 위해 메모리를 `spdk_mem_map`으로 RDMA MR에 등록한다.

### 4.4 커널 nvmet vs SPDK nvmf

| 관점 | Linux nvmet (TCP/RDMA) | SPDK nvmf target |
|---|---|---|
| 실행 문맥 | `sk_data_ready` → workqueue `io_work`(TCP), RDMA CQ 콜백 | reactor 위 poll group 스레드, `nvmf_tgroup_poll` 주기 0 poller |
| 연결 → CPU 배정 | `queue_cpu(queue)` 기반 workqueue CPU | `get_optimal_poll_group` 또는 라운드 로빈, 배정 후 고정 |
| 백엔드 | `nvmet_bdev_execute_rw`(bio), file(`IOCB_NOWAIT` 시도), passthru(`blk_execute_rq_nowait`) | bdev(`nvme`, `lvol`, `raid`, `aio`, `uring`, `xnvme` …) |
| 전역 변경 | configfs, 내부 락/RCU | subsystem pause/resume 메시지 |
| TCP 스택 | 커널 | 커널(posix/uring sock), VPP 제거 |
| 유휴 CPU | 이벤트 구동, 0에 가까움 | poll 모드 100%, interrupt 모드(TCP v24.09, RDMA v26.01)로 완화 |
| 장치 공유 | 같은 블록 장치를 로컬에서도 사용 | 백엔드 NVMe를 SPDK가 독점 |
| 설정 | configfs (`/sys/kernel/config/nvmet`), nvmetcli | JSON-RPC (`nvmf_create_transport`, `nvmf_subsystem_add_ns` 등) |

### 4.5 vhost-user-blk / -scsi

- 프로토콜 처리는 DPDK `rte_vhost` 라이브러리가 맡는다(`lib/vhost/rte_vhost_user.c`: `rte_vhost_driver_register()`, `rte_vhost_driver_callback_register()`, `rte_vhost_driver_start()`, `rte_vhost_get_mem_table()`). SPDK는 vhost-user **back-end 서버**로 UNIX 소켓을 열고, QEMU(front-end)가 접속한다([Vhost-user Protocol](https://www.qemu.org/docs/master/interop/vhost-user.html)).
- 초기화: 기능 협상 → 게스트 메모리 영역 공유(fd, user address, guest physical address, offset, size. 문서상 영역 수 제한은 8개) → vring 주소, call fd, kick fd 전달.
- 데이터 경로: SPDK는 게스트 메모리를 mmap한 상태에서 virtqueue avail ring을 **폴링**한다. vhost_processing 문서는 kick 디스크립터를 "to listen for I/O requests - unused by SPDK"라고 적는다. 다만 interrupt 모드에서는 vhost-blk가 게스트 kickfd를 `spdk_interrupt_register()`로 등록한다(Interrupt Mode 문서). 완료 통지는 `rte_vhost_vring_call()`(callfd = eventfd → KVM irqfd)로 하고, `spdk_vhost_set_coalescing()`으로 인터럽트 합치기를 조정한다.
- API: `spdk_vhost_blk_construct()`, `spdk_vhost_scsi_dev_construct()` + `spdk_vhost_scsi_dev_add_tgt()`, `spdk_vhost_dev_remove()`. RPC는 `vhost_create_blk_controller`, `vhost_create_scsi_controller`. vhost-blk 큐 처리는 `vdev_worker`/`vdev_vq_worker` → `process_vq` 경로로 진행된다(`lib/vhost/vhost_blk.c`).

### 4.6 vfio-user: 에뮬레이트된 NVMe

- 위치: NVMe-oF target의 transport `VFIOUSER`(`lib/nvmf/vfio_user.c`). 게스트 쪽 QEMU는 vfio-user 클라이언트로 접속한다.
- libvfio-user 통합: `vfu_create_ctx()` → `vfu_setup_device_dma()` → `vfu_realize_ctx()`, 이벤트 처리는 `vfu_run_ctx()`, 게스트 주소 변환은 `vfu_addr_to_sgl()`/`vfu_sgl_get()`.
- 큐: 게스트 NVMe 드라이버가 만든 SQ/CQ는 게스트 메모리에 있고, SPDK가 이를 매핑해 직접 읽는다. 게스트 doorbell 쓰기는 BAR0 영역에서 처리된다. 기본은 doorbell 영역을 공유 메모리로 매핑(mappable BAR0)해 VM exit 없이 SPDK가 tail 값을 폴링한다. interrupt 모드에는 `disable_mappable_bar0`가 필요하다(Interrupt Mode 문서 표). 게스트가 NVMe Doorbell Buffer Config를 쓰면 shadow doorbell과 eventidx로 깨움 조건을 조정한다(`handle_sq_tdbl_write`, `shadow_doorbells`, `eventidx` 관련 코드).
- 이력: v21.01 vfio-user custom transport(NVMe-oF), v22.05 adaptive IRQ(`disable_adaptive_irq`), v22.09 `vfu_tgt` 라이브러리와 virtio-blk/scsi over vfio-user(`vfu_virtio_create_blk_endpoint` RPC), v25.09 live migration 코드 제거.

### 4.7 ublk target

[ublk Target](https://spdk.io/doc/ublk.html) 문서와 `lib/ublk/ublk.c` 기준이다.

- 제어 평면: `/dev/ublk-control`에 io_uring `IORING_OP_URING_CMD`로 `UBLK_CMD_ADD_DEV`, `UBLK_CMD_SET_PARAMS`, `UBLK_CMD_START_DEV` 등을 보낸다. ADD는 `/dev/ublkcN` 문자 장치를, START는 `/dev/ublkbN` 블록 장치를 만든다. SPDK는 `IORING_SETUP_SQE128` 링을 쓴다(`io_uring_queue_init_params`).
- 데이터 평면: 큐마다 io_uring을 두고, 시작할 때 모든 태그에 `UBLK_IO_FETCH_REQ` SQE를 채운다. CQE가 오면 mmap된 I/O descriptor를 읽어 bdev I/O를 만든다. 완료되면 `UBLK_IO_COMMIT_AND_FETCH_REQ`로 결과 반환과 다음 요청 대기를 한 번에 한다. `ublk_poll` poller가 이 링을 폴링한다.
- 기능 플래그: `UBLK_F_NEED_GET_DATA`(v23.05 활성화: 쓰기 버퍼를 미리 할당하지 않음), `UBLK_F_USER_RECOVERY`/`UBLK_F_USER_RECOVERY_REISSUE`(v24.01 `ublk_recover_disk` RPC: target 재시작 후 장치 복구), `UBLK_F_USER_COPY`, `UBLK_F_CMD_IOCTL_ENCODE`.
- 사용: `ublk_create_target` → `ublk_start_disk <bdev> <id> -q <queues> -d <depth>`(ublk 블로그 예시).
- 의미: 커널 블록 장치이므로 컨테이너 런타임이 mount, 파일시스템, cgroup을 그대로 쓸 수 있다. 대신 커널 blk-mq를 한 번 거치고 데이터를 한 번 복사한다.

### 4.8 커널 io_uring passthrough와의 관계

| 관점 | SPDK NVMe 드라이버 (PCIe) | io_uring NVMe passthrough (`/dev/ngXnY`) | SPDK xNVMe bdev (`io_uring_cmd`) |
|---|---|---|---|
| 장치 소유 | SPDK 프로세스(vfio/uio) | 커널 nvme 드라이버 | 커널 nvme 드라이버 |
| 명령 표현 | `spdk_nvme_cmd` 직접 구성 | `struct nvme_uring_cmd`(SQE128 안에) | xNVMe가 `xnvme_cmd_passv()`로 변환 |
| 큐 | 스레드 전용 qpair | blk-mq hctx(공유), 태그 | 커널 hctx |
| 완료 | CQ phase 폴링 / v25.05+ eventfd | CQE, IOPOLL 선택 | `xnvme_queue_poke()` 폴링, `conserve_cpu` |
| 권한 | root 또는 IOMMU group 위임 | 6.2+ 비특권 passthrough(파일 권한) | 커널 장치 파일 권한 |
| 멀티테넌시 | 같은 shm 그룹만 | 일반 파일 공유 | 일반 파일 공유 |
| 커널 버전 | 무관(vfio/uio만 필요) | 5.13 `/dev/ng`, 5.19 uring passthrough | 위와 동일 + SPDK v22.09+ |

### 4.9 운영 트레이드오프

**CPU 점유와 전력.** poll 모드는 지정된 reactor 코어를 항상 100% 쓴다. 대응책은 (1) `-m` 코어 마스크를 줄이고 poll group 수를 조정하는 것, (2) dynamic scheduler로 유휴 스레드를 main core에 모으고 빈 코어를 interrupt 모드로 바꿔 주파수를 낮추는 것, (3) `--interrupt-mode`로 전체를 이벤트 구동으로 돌리는 것이다(구성요소가 모두 지원할 때). (3)은 지연 시간이 늘어난다. [Scheduler](https://spdk.io/doc/scheduler.html) 문서는 interrupt 모드 reactor가 "may be less responsive when events occur"라고만 적고 정량치는 없다.

**격리와 권한.** NVMe를 vfio-pci에 넘기면 호스트의 `/dev/nvme*`, 파일시스템, SMART 같은 커널 도구가 사라진다. 일부는 NVMe CUSE(`bdev_nvme_cuse_register`, `/dev/spdk/nvmeX`)로 nvme-cli와 smartctl을 쓸 수 있지만, sysfs는 갱신되지 않는다(NVMe Driver 문서). IOMMU group 단위 위임, hugepage 예약(`--huge-dir`), 그리고 vfio에서 SPDK 메모리 전체가 IOMMU에 매핑된다는 점(System Configuration 문서의 "Memory constraints")은 컨테이너 환경 배포를 어렵게 한다. 커널 nvmet과 io_uring passthrough는 이 비용이 없다.

**관측성.** SPDK I/O는 커널 블록 계층을 거치지 않는다. 그래서 `iostat`, blktrace, `block:` tracepoint, blk-cgroup 통계에 보이지 않는다. 대체 도구는 다음과 같다.

- `spdk_top`(v20.04 도입, reactor/thread/poller 실시간 점유율)
- `spdk_trace` 라이브러리(공유 메모리 링 기반 저오버헤드 트레이스, [Tracing Framework](https://spdk.io/spdk_trace/2022/01/17/tracing_library_post/))
- v21.07부터 USDT 정적 프로브(`SPDK_DTRACE_PROBE*`, 예: `nvmf_create_poll_group`)와 bpftrace 스크립트([BPF tracing with SPDK](https://spdk.io/news/2021/09/28/bpf_tracing_with_spdk/). 블로그는 libtrace가 오버헤드가 훨씬 낮고, BPF는 커널 trap이 필요해 비싸지만 동적으로 붙일 수 있다고 비교한다)
- RPC: `bdev_get_iostat`, `thread_get_stats`, `thread_get_pollers`, `framework_get_reactors`, `nvmf_get_stats`

**고장 영역.** SPDK 데몬 하나가 여러 VM과 원격 호스트의 스토리지를 함께 처리한다. 그래서 데몬 재시작이 곧 서비스 중단이다. 다음 절의 Spool 논문이 SPDK 대비 재시작 시간을 91% 줄였다고 보고한 것도 이 문제 때문이다. ublk의 `UBLK_F_USER_RECOVERY`도 같은 문제를 겨냥한다.

### 4.10 1차 사료로 확인한 배포·활용 사례

| 사례 | 내용 | 출처 |
|---|---|---|
| Alibaba Cloud — Spool | SPDK NVMe 드라이버 기반 NVMe 가상화 스토리지 풀. 장치 고장 유형 진단, 재설정 시 데이터 일관성, 재시작 시간 단축. "reduces restart time by 91% when compared with SPDK", 성능 손실 3% 미만 | [Spool: Reliable Virtualized NVMe Storage Pool in Public Cloud Infrastructure](https://www.usenix.org/conference/atc20/presentation/xue) (USENIX ATC '20) |
| SpanDB | RocksDB 변형. WAL과 상위 LSM 레벨을 고속 NVMe에 두고 SPDK로 병렬 WAL 쓰기. 처리량 최대 8.8배(논문 초록 기준) | [SpanDB: A Fast, Cost-Effective LSM-tree Based KV Store on Hybrid Storage](https://www.usenix.org/conference/fast21/presentation/chen-hao) (USENIX FAST '21) |
| DAOS | "the Storage Performance Development Kit (SPDK) enables user-space I/O to NVMe devices" | [Architecture - DAOS v2.8](https://docs.daos.io/latest/overview/architecture/) |
| OpenEBS Mayastor | SPDK NVMe-oF target으로 Kubernetes 스토리지 제공, NVMe/TCP loopback 방식 | [SPDK In The News](https://spdk.io/news/), ublk 블로그 |
| Nutanix | Intel과 공동 랩에서 Blockstore + SPDK 성능 개선 발표. 2025 개발자 밋업 주최. LF 이전 창구(Rob Mills) | [SPDK In The News](https://spdk.io/news/), [Updates on SPDK Linux Foundation Transition](https://spdk.io/news/2024/12/16/transition/) |
| NVIDIA BlueField-3 | SPDK 26.01 NVMe-oF RDMA 성능 보고서가 BlueField3 Storage Controller를 사용(spdk.io 블로그 2026-05-18 게시) | [Performance Report](https://spdk.io/news/2026/05/18/Performance_Report_Update/) (Alexey Marchuk, 2026-05-18) |

이 표에 없는 "OO사가 프로덕션에서 SPDK를 쓴다"는 주장은 1차 사료로 확인하지 못했으므로 쓰지 않았다.

---

## 5. Primary References

- [NVMe over Fabrics Target](https://spdk.io/doc/nvmf.html): transport, TLS, interrupt 모드, NSSR
- [NVMe over Fabrics Target Programming Guide](https://spdk.io/doc/nvmf_tgt_pg.html): 객체 모델, poll group, 스레딩, RDMA 설계
- [vhost Target](https://spdk.io/doc/vhost.html), [Virtualized I/O with Vhost-user](https://spdk.io/doc/vhost_processing.html)
- [ublk Target](https://spdk.io/doc/ublk.html)
- [Interrupt Mode](https://spdk.io/doc/interrupt_mode.html), [JSON-RPC](https://spdk.io/doc/jsonrpc.html)
- [VFIO-USER: A new virtualization protocol](https://spdk.io/news/2021/05/04/vfio-user/) (Ben Walker, 2021-05-04)
- [ublk: the new and improved way to serve SPDK storage locally!](https://spdk.io/news/2023/03/28/ublk/) (Jim Harris, 2023-03-28)
- [BPF tracing with SPDK](https://spdk.io/news/2021/09/28/bpf_tracing_with_spdk/) (Konrad Sztyber, 2021-09-28), [Tracing Framework](https://spdk.io/spdk_trace/2022/01/17/tracing_library_post/)
- [SPDK NVMe-oF TCP Transport](https://spdk.io/news/2018/11/15/nvme_tcp/) (2018-11-15)
- 소스: [lib/nvmf/transport.c](https://github.com/spdk/spdk/blob/master/lib/nvmf/transport.c), [lib/nvmf/tcp.c](https://github.com/spdk/spdk/blob/master/lib/nvmf/tcp.c), [lib/nvmf/vfio_user.c](https://github.com/spdk/spdk/blob/master/lib/nvmf/vfio_user.c), [lib/ublk/ublk.c](https://github.com/spdk/spdk/blob/master/lib/ublk/ublk.c), [include/spdk/nvmf_transport.h](https://github.com/spdk/spdk/blob/master/include/spdk/nvmf_transport.h)
- [I/O Passthru: Upstreaming a flexible and efficient I/O Path in Linux](https://www.usenix.org/conference/fast24/presentation/joshi) (Joshi et al., USENIX FAST '24)
- [An io_uring-based user-space block driver](https://lwn.net/Articles/903855/) (LWN, ublk 6.0)
- 커널 커밋: [nvmet: add a generic NVMe target](https://github.com/torvalds/linux/commit/a07b4970f464f13640e28e16dad6cfa33647cc99), [nvmet-tcp: add NVMe over TCP target driver](https://github.com/torvalds/linux/commit/872d26a391da92ed8f0c0f5cb5fef428067b7f30), [nvmet: add passthru code to process commands](https://github.com/torvalds/linux/commit/c1fef73f793b7fd9d2ffcb5ef85807ea55bf7adb), [ublk_drv: add io_uring based userspace block driver](https://github.com/torvalds/linux/commit/71f28f3136aff5890cd56de78abc673f8393cad9)
- [Userspace block device driver (ublk driver)](https://docs.kernel.org/block/ublk.html) (커널 문서)
- [Vhost-user Protocol](https://www.qemu.org/docs/master/interop/vhost-user.html) (QEMU 문서)
- [GitHub - nutanix/libvfio-user: framework for emulating devices in userspace](https://github.com/nutanix/libvfio-user)
- [Spool: Reliable Virtualized NVMe Storage Pool in Public Cloud Infrastructure](https://www.usenix.org/conference/atc20/presentation/xue) (USENIX ATC '20)
- [SpanDB: A Fast, Cost-Effective LSM-tree Based KV Store on Hybrid Storage](https://www.usenix.org/conference/fast21/presentation/chen-hao) (USENIX FAST '21)
- [Architecture - DAOS v2.8](https://docs.daos.io/latest/overview/architecture/)
