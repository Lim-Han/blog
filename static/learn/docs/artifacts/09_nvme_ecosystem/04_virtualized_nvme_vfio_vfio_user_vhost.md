# 가상화 환경의 NVMe: virtio-blk, QEMU 에뮬레이트 NVMe, VFIO passthrough, SR-IOV, vhost-user-blk, vDPA, vfio-user

> 기준: Linux `torvalds/linux` master(7.3-rc7, 2026-10 확인). 도입 버전은 git.kernel.org `plain/<path>?h=vX.Y` 태그별 grep으로 확인했다. QEMU는 `gitlab.com/qemu-project/qemu` master의 `hw/block/virtio-blk.c`, `hw/nvme/ctrl.c`, `qapi/block-core.json`, `qapi/block-export.json`과 wiki.qemu.org ChangeLog를 근거로 했다. libvfio-user는 `nutanix/libvfio-user` master의 `include/libvfio-user.h`, `include/vfio-user.h`를 대조했다. SPDK 쪽 vhost/vfio-user 서버 구현은 별도 문서(→ 07/03)에서 다뤘으므로, 이 문서는 하이퍼바이저·커널·프로토콜 쪽을 중심으로 본다.

## 1. Verdict

VM에 NVMe 성능을 전달하는 방법은 "게스트가 어떤 장치 모델을 보는가"와 "데이터 경로에서 누가 virtqueue/NVMe 큐를 처리하는가" 두 축으로 정리된다.

| 방식 | 게스트가 보는 장치 | 데이터 경로 처리 주체 | 라이브 마이그레이션 | 호스트 스토리지 기능(스냅샷, 씬 프로비저닝 등) |
|---|---|---|---|---|
| virtio-blk (QEMU 내장) | virtio-blk PCI | QEMU iothread → `aio=native`/`io_uring`/`threads` | 가능(표준) | 전부 사용 가능(qcow2, 블록 잡) |
| QEMU 에뮬레이트 NVMe (`-device nvme`) | NVMe 컨트롤러 | QEMU 메인 루프/iothread의 `nvme_process_sq()` | 가능 | 전부 사용 가능, 대신 느림 |
| VFIO passthrough (PF 전체) | 실제 NVMe | 게스트 nvme 드라이버가 HW 큐를 직접 구동 | 사실상 불가 | 없음(장치 독점) |
| SR-IOV VF + VFIO | 실제 NVMe VF | 게스트가 VF 큐 직접 구동 | 표준 경로 없음(NVMe용 variant driver 미병합) | 장치 펌웨어가 제공하는 것만 |
| vhost-user-blk | virtio-blk PCI | 별도 프로세스(SPDK, qemu-storage-daemon)가 게스트 메모리를 매핑해 폴링 | 가능(백엔드 협조 필요) | 백엔드에 따라 |
| vDPA (vdpa-blk, VDUSE) | virtio-blk(VF 또는 소프트웨어 장치) | HW 또는 VDUSE 사용자 공간 데몬 | 장치·드라이버별 | 백엔드에 따라 |
| vfio-user | NVMe(또는 virtio) PCI | 별도 프로세스(SPDK `nvmf` vfio-user transport 등) | 프로토콜은 정의, 구현별 상이 | 백엔드에 따라 |

결론은 다음과 같다.

1. **"빠름"과 "관리 가능함"의 교환 관계가 기본 구도다.** VFIO passthrough와 SR-IOV는 게스트가 HW 큐를 직접 다루므로 호스트 CPU 개입이 가장 적다. 대신 IOMMU 그룹 단위 독점, 마이그레이션 불가, 호스트 측 스냅샷 불가라는 운영 비용이 따른다. 반대쪽 끝인 QEMU 에뮬레이션은 기능은 전부 갖췄지만 MMIO trap과 BQL에 묶인 경로 때문에 느리다.
2. **중간 지대는 "데이터 경로를 QEMU 밖으로 빼되 장치 모델은 소프트웨어로 유지"하는 설계다.** vhost-user-blk(virtio), vfio-user(NVMe/virtio), VDUSE(커널 vDPA 버스 위의 사용자 공간 virtio 장치)가 여기에 속한다. 셋 다 게스트 메모리를 공유 메모리로 매핑하고, 알림은 eventfd(ioeventfd/irqfd)로 처리한다.
3. **QEMU 내장 virtio-blk도 많이 빨라졌다.** 게스트 쪽은 Linux 3.13에서 blk-mq 전환, 3.17에서 `VIRTIO_BLK_F_MQ` 멀티 virtqueue, 5.19에서 `poll_queues`와 `virtio_queue_rqs` 배치 제출이 들어왔다. 호스트 쪽은 QEMU 5.0에서 `aio=io_uring`, 9.0에서 `iothread-vq-mapping`(virtqueue별 iothread 분산)이 들어왔다. 이로써 "QEMU의 단일 iothread가 병목"이라는 오래된 제약이 풀렸다.
4. **VFIO 마이그레이션 v2(Linux 5.18)는 상태 머신만 표준화했다. 장치 상태를 저장하는 일은 벤더 variant driver의 몫이다.** 메인라인 `drivers/vfio/pci/`에는 mlx5, hisilicon, pds(6.6), qat, virtio, nvgrace-gpu, xe 등이 있지만 NVMe 전용 variant driver는 없다. 2022-12 Intel의 `nvme-vfio` RFC는 Christoph Hellwig의 구조적 반대에 부딪혔다(3.1절). NVMe SR-IOV VF의 라이브 마이그레이션은 표준 커널 경로가 없는 상태로 남아 있다.
5. **vfio-user는 "VFIO ioctl을 소켓 메시지로 옮긴 것"이다.** QEMU는 7.1에서 실험적 서버(`x-vfio-user-server`)를, 10.1에서 클라이언트(`vfio-user-pci`)를 받았다. 덕분에 SPDK 같은 외부 프로세스가 에뮬레이트한 NVMe 컨트롤러를 게스트가 표준 nvme 드라이버로 쓸 수 있다. 게스트에 virtio 드라이버가 필요 없다는 점이 vhost-user와의 핵심 차이다.

---

## 2. Problem Statement

### 2.1 에뮬레이션 비용: MMIO trap과 VM exit

게스트 nvme 드라이버는 SQ tail doorbell에 MMIO 쓰기를 한다. 장치가 에뮬레이트되어 있다면 이 쓰기는 EPT violation/misconfig에 의한 VM exit가 되고, KVM은 이를 사용자 공간(QEMU)으로 넘기거나(`KVM_EXIT_MMIO`) ioeventfd로 바꿔 신호만 보낸다. NVMe 명령 하나마다 doorbell 쓰기와 완료 인터럽트 주입이 일어나므로, 4KiB 랜덤 I/O에서는 exit 비용이 장치 지연(수 µs~수십 µs)과 같은 규모가 된다.

이를 줄이려는 장치 모델 측 기법이 둘 있다.

- **virtio의 notification suppression**: `VRING_AVAIL_F_NO_INTERRUPT`/`VRING_USED_F_NO_NOTIFY`, `VIRTIO_RING_F_EVENT_IDX`. 상대가 이미 폴링 중이면 kick이나 인터럽트를 생략한다.
- **NVMe Doorbell Buffer Config**(shadow doorbell): 게스트가 doorbell 값을 메모리 버퍼에 쓰고, EventIdx를 넘을 때만 실제 MMIO를 한다. Linux nvme 드라이버는 4.12부터 `nvme_dbbuf_set()`/`dbbuf_dbs`로 이를 지원한다(`NVME_CTRL_OACS_DBBUF_SUPP` 확인 후 사용). QEMU 에뮬레이트 NVMe는 `nvme_dbbuf_config()`로 응답한다.

### 2.2 DMA 격리: IOMMU가 없으면 passthrough도 없다

장치를 게스트에 직접 주면 그 장치의 DMA는 게스트 물리 주소(GPA)를 대상으로 한다. 호스트 물리 주소(HPA)로 바꾸고 다른 VM의 메모리를 보호하려면 IOMMU(Intel VT-d, AMD-Vi, Arm SMMU)가 필요하다. VFIO는 IOMMU group을 격리 단위로 삼는다. PCIe ACS가 없는 스위치 아래의 장치들은 한 그룹으로 묶여 함께만 할당할 수 있다. 게스트 메모리는 DMA 대상이므로 VFIO type1 백엔드나 iommufd를 통해 **핀(pin)되어야** 한다. 이 때문에 메모리 오버커밋, balloon, KSM과의 상호작용이 제약된다.

### 2.3 인터럽트 전달: remapping과 posted interrupt

passthrough 장치의 MSI-X는 호스트에서 먼저 받아 게스트에 주입해야 한다. 기본 경로는 `vfio_msihandler()` → `eventfd_signal()` → KVM irqfd → vCPU에 가상 인터럽트 주입이다. 인터럽트 remapping(VT-d IR)은 장치가 임의의 MSI 메시지로 다른 CPU를 공격하지 못하게 막는 보안 요건이다. VT-d posted interrupt는 IRTE에 게스트 vCPU의 PI descriptor(`struct pi_desc`)를 기록해 두는 방식이다. vCPU가 실행 중이면 호스트 개입(VM exit) 없이 인터럽트가 게스트에 바로 전달된다. Linux에서는 `irq_bypass_register_producer()`(VFIO 쪽, `vfio_msi_set_vector_signal()` 안)와 KVM의 consumer가 짝을 이뤄 `vmx_pi_update_irte()`로 IRTE를 갱신한다(`virt/lib/irqbypass.c`, `arch/x86/kvm/vmx/posted_intr.c`).

### 2.4 QEMU 내부 병목: BQL과 단일 iothread

QEMU의 장치 에뮬레이션은 전통적으로 BQL(Big QEMU Lock) 아래의 메인 루프에서 돌았다. `-object iothread`와 dataplane이 virtio-blk 처리를 별도 스레드로 옮겼지만, 디스크 하나는 iothread 하나에 묶여 있었다. 게스트가 vCPU 수만큼 virtqueue를 만들어도 호스트에서는 한 스레드가 모든 virtqueue를 처리하는 비대칭이 남았다. QEMU 9.0의 `iothread-vq-mapping`이 이 문제를 해결했다(4.2절).

### 2.5 마이그레이션과 passthrough의 근본 충돌

라이브 마이그레이션은 (a) 장치 상태를 직렬화할 수 있어야 하고 (b) 장치가 게스트 메모리에 쓴 페이지(dirty page)를 추적할 수 있어야 한다. 소프트웨어 장치는 둘 다 QEMU가 알고 있다. passthrough 장치는 둘 다 HW 안에 있다. 장치 상태는 펌웨어 내부에 있고, DMA 쓰기는 CPU의 dirty logging을 거치지 않는다. VFIO 마이그레이션 v2와 DMA logging uAPI(4.9절)는 이 두 요건을 커널 인터페이스로 표준화하려는 시도다. 실제 상태 저장은 장치별 드라이버가 구현해야 한다.

---
## 3. The Debate

### 3.1 NVMe VF 라이브 마이그레이션: "controlled function에 VFIO 드라이버를 붙일 것인가"

2022-12 Intel의 Lei Rao가 `[RFC PATCH 0/5] Add new VFIO PCI driver for NVMe devices`를 올렸다. 설계는 다음과 같았다. NVMe VF용 `nvme-vfio` variant driver를 만들고, 마이그레이션 명령은 PF의 admin queue로 보낸다. 이를 위해 `nvme-pci`에 `nvme_submit_vf_cmd()`를 추가한다. 명령은 벤더 고유 opcode를 쓰고, 표준화는 나중에 한다(LWN의 시리즈 요약 참조). Christoph Hellwig은 NVMe 쪽에서 이 구조 자체에 반대했다. linux-nvme 아카이브에서 확인한 원문은 다음과 같다.

> "The same I've used through this whole thread:  controlling and controlled function. [...] The objection is that: - in hardware fundamentally only the controlling funtion can control live migration features on the controlled function, because the controlled function is assigned to a VM which has control over it. - for the same reason there is no portable way to even find the controlling function from a controlled function, unless you want to equate PF = controlling and VF = controlled, and even that breaks down in some corner cases"
> — Christoph Hellwig, 2022-12-07 (Jason Gunthorpe의 2022-12-07 회신 [linux-nvme 036962](https://lists.infradead.org/pipermail/linux-nvme/2022-December/036962.html) 안의 인용으로 확인)

> "So now we need to write a vfio shim for every function even if there is absolutely nothing special about that function?  Migrating really is the controlling functions behavior, and writing a new vfio bit for every controlled thing just does not scale."
> — Christoph Hellwig, 2022-12-12, Message-ID `20221212075046.GB11162@lst.de` ([lore](https://lore.kernel.org/all/20221212075046.GB11162@lst.de/), [linux-nvme 036993](https://lists.infradead.org/pipermail/linux-nvme/2022-December/036993.html))

해설: Hellwig이 문제 삼은 것은 계층 구조다. 마이그레이션 상태를 읽고 쓰는 주체는 PF(controlling function)다. 그런데 VFIO variant driver는 VF(controlled function)에 바인딩된다. 그러면 VF 쪽 드라이버가 PF 쪽 드라이버를 찾아가 대신 명령을 내리는, 발견 방법조차 이식성 없는 결합이 생긴다는 지적이다.

Jason Gunthorpe(VFIO/iommufd 메인테이너)는 반대 입장이었다.

> "Huh? "does not scale?" We are looking at boilerplates of around 20-30 lines to make a VFIO driver for a real PCI device. Why is that even something we should worry about optimizing?"
> — Jason Gunthorpe, 2022-12-13, Message-ID `Y5iFnw5i3vI9iMFY@ziepe.ca` ([lore](https://lore.kernel.org/all/Y5iFnw5i3vI9iMFY@ziepe.ca/), [linux-nvme 037020](https://lists.infradead.org/pipermail/linux-nvme/2022-December/037020.html))

해설: Gunthorpe의 논리는 실증에 기대고 있다. mlx5와 hisilicon 등 이미 병합된 드라이버는 모두 "VFIO 드라이버가 곧 마이그레이션 드라이버"였고, FLR 가로채기나 BAR 공유 같은 장치별 quirk는 VFIO 계층에서만 처리할 수 있다는 것이다. 이 논쟁은 메인라인에 NVMe variant driver가 없는 상태로 끝났다(master `drivers/vfio/pci/` 목록 확인). 같은 시기 AMD/Pensando도 `pds_vfio` RFC를 처음에는 NVMe VF 마이그레이션 용도로 냈다(LWN 917915). 그러나 실제로 병합된 `PDS_VFIO_PCI`(Linux 6.6)의 Kconfig 도움말은 "generic PCI support for PDS devices"이고 문서는 `networking/device_drivers/ethernet/amd/` 아래에 있다. NVMe 표준 쪽 live migration 기능(NVMe TP 형태)으로 해결하자는 방향이 언급되었지만, 그 진행 상황은 이 문서에서 확인하지 못했다 `[추측/미확인]`.

### 3.2 virtio를 계속 쓸 것인가, NVMe를 에뮬레이트할 것인가

vhost-user-blk는 게스트에 virtio-blk 드라이버를 요구한다. Linux 게스트에는 문제가 되지 않지만, Windows 게스트는 virtio 드라이버(virtio-win)를 따로 설치해야 한다. 펌웨어(OVMF) 부팅 경로나 클라우드 이미지 호환성에서도 "어디서나 동작하는 NVMe"가 유리하다. vfio-user는 이 요구에서 나왔다. 장치 모델을 QEMU 밖 프로세스에 두고, 그 프로세스가 PCI 구성 공간·BAR·MSI-X·DMA 매핑을 소켓 메시지로 주고받는다(4.8절). 비용도 있다. NVMe 에뮬레이션은 virtio보다 상태가 많고(admin 명령 집합, 네임스페이스 관리, AER), doorbell 기반이라 shadow doorbell 없이는 MMIO exit가 잦다. SPDK는 이 때문에 vfio-user NVMe 에뮬레이션에서 shadow doorbell을 지원한다(→ 07/03, 4.6절).

### 3.3 vhost-user vs vDPA/VDUSE

vhost-user는 QEMU와 백엔드 사이의 UNIX 소켓 프로토콜이다. 백엔드는 반드시 사용자 공간 프로세스이고, 컨테이너나 베어메탈 프로세스는 이 장치를 소비할 수 없다. vDPA는 virtio 데이터 경로를 HW(또는 커널 내 시뮬레이터)가 처리하고 제어 평면만 벤더 드라이버가 맡는 커널 버스다. `vhost-vdpa`로 VM에, `virtio-vdpa`로 호스트 커널에 같은 장치를 붙일 수 있다. VDUSE(Linux 5.15, `drivers/vdpa/vdpa_user/vduse_dev.c`)는 vDPA 장치를 사용자 공간에서 구현하게 해 준다. 그래서 같은 소프트웨어 백엔드를 VM(vhost-vdpa)과 호스트 컨테이너(virtio-vdpa → `/dev/vdX`) 양쪽에 내보낼 수 있다. QEMU는 7.1에서 `vduse-blk` 블록 export를 추가했다(`qapi/block-export.json`의 "since 7.1"). 호스트 로컬 노출 측면에서는 ublk(→ 09/05)가 경쟁 관계다. VDUSE는 virtio 의미론과 bounce buffer(`vduse` IOVA domain)를 쓰고, ublk는 blk-mq 요청을 io_uring으로 직접 전달한다.

### 3.4 SR-IOV 하드웨어 분할 vs 소프트웨어 분할

NVMe SR-IOV는 VF마다 독립 컨트롤러와 큐를 준다. Linux nvme 드라이버는 `.sriov_configure = pci_sriov_configure_simple`로 VF 생성만 지원하고, VF에 자원(VQ/VI)을 배분하는 Virtualization Management 명령은 사용자 공간 도구(nvme-cli)에 맡긴다. QEMU 에뮬레이트 NVMe도 `sriov_max_vfs`, `sriov_vq_flexible`, `sriov_vi_flexible`, `sriov_max_vq_per_vf`, `sriov_max_vi_per_vf` 속성으로 이 모델을 재현할 수 있다(QEMU 문서의 "Composable SR-IOV device"). 클라우드 사업자는 SR-IOV 대신 SPDK vhost/vfio-user 같은 소프트웨어 분할을 택하는 경우가 많다. 예를 들어 Alibaba Cloud의 Spool(USENIX ATC '20)은 사용자 공간 NVMe 가상화 시스템의 신뢰성을 다뤘다. 장애 유형을 진단해 실제 매체 오류일 때만 장치를 교체하고, 컨트롤러 리셋·시스템 업그레이드 중의 데이터 일관성을 보장한다. 초록에 따르면 성능 손실은 3% 미만이고 재시작 시간은 SPDK 대비 91% 줄었다. 소프트웨어 분할은 호스트 코어를 소모하는 대신, 볼륨 단위 QoS, 스냅샷, 백엔드 교체, 마이그레이션을 얻는다.

---
## 4. Implementation Impact

### 4.1 게스트 virtio-blk 드라이버 (`drivers/block/virtio_blk.c`)

| 기능 | 이름 | 도입(태그 grep으로 확인) |
|---|---|---|
| blk-mq 전환 | `struct blk_mq_ops virtio_mq_ops` | Linux 3.13 |
| 멀티 virtqueue | `VIRTIO_BLK_F_MQ`, `init_vq()`가 `num_queues`개 vq 생성 | 3.17 |
| 큐 수 제한 | `module_param(num_request_queues, ...)` | 5.17 이전부터 존재 |
| 폴링 큐 | `module_param(poll_queues, ...)`, `virtblk_poll()` | 5.19 |
| 배치 제출 | `.queue_rqs = virtio_queue_rqs` | 5.19 |
| 존드 장치 | `VIRTIO_BLK_F_ZONED` | 6.3 |

콜패스는 다음과 같다. `virtio_queue_rq()`/`virtio_queue_rqs()`가 요청을 `struct virtblk_req`로 바꿔 split/packed virtqueue에 넣고 `virtqueue_kick_prepare()` 후 notify한다. 완료는 vq 인터럽트 콜백 `virtblk_done()`이 받는다. `virtblk_map_queues()`가 blk-mq의 `HCTX_TYPE_DEFAULT`/`HCTX_TYPE_POLL` 맵을 virtqueue에 대응시킨다. 그래서 `poll_queues`로 할당된 vq는 인터럽트 없이 `io_uring`의 `IORING_SETUP_IOPOLL` 경로(`blk_mq_poll` → `virtblk_poll`)로 수거된다. 게스트 쪽 폴링은 호스트 백엔드도 폴링(SPDK vhost)할 때 효과가 크다. 호스트 iothread가 이벤트 기반이면 게스트 폴링은 vCPU 시간만 소모할 수 있다.

### 4.2 QEMU virtio-blk 데이터 경로와 백엔드

`hw/block/virtio-blk.c`의 흐름은 다음과 같다. ioeventfd 알림 → `virtio_blk_handle_vq()` → 요청 파싱 → 연속 요청을 `MultiReqBuffer`에 모아 `virtio_blk_submit_multireq()`로 병합 → `blk_aio_preadv()`/`blk_aio_pwritev()` → BlockDriverState 그래프(포맷 드라이버 qcow2/raw → 프로토콜 드라이버 file-posix) → 호스트 커널.

장치 속성(master `DEFINE_PROP` 확인): `num-queues`, `queue-size`(기본 256), `iothread`, `iothread-vq-mapping`, `request-merging`, `discard`, `write-zeroes`, `seg-max-adjust`.

file-posix의 `aio=` 선택지(`qapi/block-core.json`의 `BlockdevAioOptions`):

| `aio=` | 메커니즘 | 비고 |
|---|---|---|
| `threads` | 스레드 풀에서 `preadv`/`pwritev` | 기본값, 버퍼드 I/O와 호환 |
| `native` | Linux AIO(`io_submit`) | `cache.direct=on` 필요 |
| `io_uring` | `io_uring` SQ/CQ | "since 5.0". QEMU 10.0에서 FUA 쓰기를 `RWF_DSYNC`로 처리 |

QEMU 7.2부터는 libblkio 기반 블록 드라이버 `io_uring`, `nvme-io_uring`, `virtio-blk-vfio-pci`, `virtio-blk-vhost-user`, `virtio-blk-vhost-vdpa`가 `CONFIG_BLKIO`로 추가되었다(`qapi/block-core.json` "Since: 7.2"). `nvme-io_uring`은 NVMe generic char device(`/dev/ngXnY`)에 io_uring passthrough를 쓴다. 이와 별개로 QEMU에는 2.12부터 VFIO로 호스트 NVMe를 사용자 공간에서 직접 구동하는 `nvme` 블록 드라이버(`block/nvme.c`)도 있다. 이 드라이버는 게스트 장치 모델과 무관하며, 호스트 쪽 백엔드를 SPDK처럼 커널 바이패스하는 용도다.

멀티큐 확장의 핵심은 9.0의 `iothread-vq-mapping`이다. wiki.qemu.org ChangeLog/9.0은 "The 'virtio-blk' device has gained true multiqueue support where different queues of a single disk can be processed by different I/O threads"라고 적고 있다. virtio-scsi는 10.0에서 같은 기능을 얻었다. 이전에는 `num-queues`를 vCPU 수만큼 늘려도 한 iothread가 모든 vq를 처리했다. 매핑 후에는 vq 그룹마다 iothread가 따로 돌고, 각 iothread의 AioContext가 io_uring/Linux AIO 컨텍스트를 따로 가진다.

### 4.3 QEMU 에뮬레이트 NVMe (`hw/nvme/`)

`hw/nvme/ctrl.c`(master 약 10.7k줄)의 구조는 다음과 같다. SQ doorbell 쓰기 → (`ioeventfd=on`이면 eventfd, 아니면 MMIO 핸들러) → `nvme_process_sq()`가 SQE를 DMA로 읽음 → `nvme_admin_cmd()` 또는 `nvme_io_cmd()` → `nvme_io_cmd_nvm()`/`nvme_io_cmd_zoned()` → block 계층 AIO → 완료 시 CQE 기록과 MSI-X 주입.

주요 속성(master `DEFINE_PROP`): `max_ioqpairs`(기본 64), `mdts`(기본 7), `aerl`, `ioeventfd`(기본 **false**), `sriov_max_vfs`와 `sriov_*` 계열, `cmb_size_mb`, `legacy-cmb`. ChangeLog로 확인한 연표는 다음과 같다. 6.0에서 사양을 v1.4로 올렸고 ZNS(TP 4053), NVM Subsystem/멀티패스/네임스페이스 공유, 메타데이터/E2E 보호를 실험적으로 넣었다. 7.0에서 SR-IOV 초기 지원("initial bits of SR/IOV support")을 넣었다. 문서에 FDP(`fdp=on`, `fdp.nruh`, `fdp.runs`)가 있다. Doorbell Buffer Config(`NVME_ADM_CMD_DBBUF_CONFIG` → `nvme_dbbuf_config()`)가 구현되어 있다. 이 장치의 존재 이유는 성능이 아니라 **사양 기능 개발·테스트 플랫폼**이다. ZNS, FDP, SR-IOV, 멀티패스를 실제 HW 없이 커널 드라이버와 nvme-cli로 시험할 수 있다는 점에서 가치가 크다.

### 4.4 VFIO passthrough: 컨테이너에서 iommufd로

| 계층 | 레거시 | 신규 | 도입 |
|---|---|---|---|
| IOMMU 백엔드 | VFIO container + `VFIO_TYPE1v2_IOMMU`, `VFIO_IOMMU_MAP_DMA` | iommufd(`/dev/iommu`, IOAS, HWPT) | iommufd 6.2 (`drivers/iommu/iommufd/`) |
| 장치 열기 | group fd → `VFIO_GROUP_GET_DEVICE_FD` | per-device cdev `/dev/vfio/devices/vfioX` + `VFIO_DEVICE_BIND_IOMMUFD` | 6.6 (`drivers/vfio/device_cdev.c`) |
| 장치별 확장 | `vfio-pci` 단일 드라이버 | `vfio_pci_core` + variant driver(mlx5, hisilicon, pds, ...) | vfio-pci-core 5.15 (`vfio_pci_core.c`) |
| 인터럽트 | eventfd → irqfd 주입 | + irqbypass로 posted interrupt | irqbypass 4.4 (`virt/lib/irqbypass.c`) |

passthrough 장치의 데이터 경로에는 호스트 소프트웨어가 없다. 게스트 nvme 드라이버가 BAR0 doorbell에 직접 쓰고(EPT로 매핑된 MMIO라 exit 없음), 장치는 IOMMU를 거쳐 게스트 메모리에 DMA하며, 완료 MSI-X는 posted interrupt로 vCPU에 바로 전달된다. 호스트 개입은 (1) 첫 DMA 맵핑 시 페이지 핀, (2) posted interrupt가 불가능한 경우(vCPU가 스케줄 아웃된 상태 등)의 wakeup(`pi_wakeup_handler()`), (3) 구성 공간 접근 에뮬레이션(`vfio_pci_config.c`) 정도다. 그래서 4KiB 랜덤 IOPS와 지연이 베어메탈에 가장 가깝다. 대가로 장치 전체(또는 VF)를 독점하고, 2.5절의 이유로 마이그레이션을 막는다(QEMU는 마이그레이션 미지원 VFIO 장치가 있으면 migration blocker를 등록한다).

### 4.5 vhost-user-blk: 데이터 경로를 별도 프로세스로

QEMU 쪽 장치는 `hw/block/vhost-user-blk.c`이고, 백엔드는 SPDK `vhost` 앱이나 `qemu-storage-daemon --export type=vhost-user-blk`(export 타입은 QEMU 5.2부터) 등이다. 제어 평면은 UNIX 소켓으로 오가는 vhost-user 메시지다(QEMU "Vhost-user Protocol" 문서).

1. `VHOST_USER_SET_MEM_TABLE`(또는 `VHOST_USER_ADD_MEM_REG`)로 게스트 RAM 영역의 fd를 전달하면 백엔드가 `mmap`한다. 이를 위해 게스트 메모리는 `memory-backend-memfd`/hugepage 파일처럼 공유 가능해야 한다(`share=on`).
2. `VHOST_USER_SET_VRING_KICK`/`VHOST_USER_SET_VRING_CALL`로 ioeventfd(게스트 → 백엔드)와 irqfd(백엔드 → 게스트) eventfd를 넘긴다. KVM이 이 둘을 직접 연결하므로 데이터 경로에서 QEMU 프로세스는 깨어나지 않는다.
3. 백엔드 재시작 내성: `VHOST_USER_PROTOCOL_F_INFLIGHT_SHMFD`와 `VHOST_USER_GET_INFLIGHT_FD`/`VHOST_USER_SET_INFLIGHT_FD`로 in-flight 디스크립터를 공유 메모리에 기록한다. 백엔드가 죽었다가 다시 붙어도 처리 중이던 요청을 재제출할 수 있다.
4. 마이그레이션: `VHOST_USER_SET_LOG_BASE`로 dirty log 비트맵을 공유하고, 최신 프로토콜은 `VHOST_USER_PROTOCOL_F_DEVICE_STATE`/`VHOST_USER_SET_DEVICE_STATE_FD`로 백엔드 내부 상태를 전송한다.

SPDK 백엔드는 virtqueue를 reactor에서 폴링한다. 게스트 kick도 SPDK가 virtqueue를 직접 확인하므로 사실상 불필요해진다. 그래서 백엔드 쪽 코어를 쓰는 대신 exit와 인터럽트를 모두 없앤다.

### 4.6 vDPA와 VDUSE

| 구성 요소 | 경로 | 도입 |
|---|---|---|
| vDPA 블록 시뮬레이터 | `drivers/vdpa/vdpa_sim/vdpa_sim_blk.c` | Linux 5.13 |
| VDUSE | `drivers/vdpa/vdpa_user/vduse_dev.c` | 5.15 |
| QEMU `vduse-blk` export | `qapi/block-export.json` | QEMU 7.1 |
| QEMU `virtio-blk-vhost-vdpa` 블록 드라이버(libblkio) | `qapi/block-core.json` | QEMU 7.2 |

vdpa-blk에는 두 방향이 있다. (a) HW vDPA: SmartNIC/DPU의 virtio-blk VF를 `vhost-vdpa`로 VM에 붙인다. 데이터 경로는 passthrough에 가깝고, 제어는 vDPA 버스가 맡는다. (b) 소프트웨어 vDPA: VDUSE로 사용자 공간 데몬(qemu-storage-daemon 등)이 virtio-blk 장치를 구현하고, 같은 장치를 virtio-vdpa로 호스트 커널에 `/dev/vdX`로 노출할 수 있다. QEMU 9.0 ChangeLog에는 "Fixed 'vhost-vdpa-device' to be compatible with VDUSE block exports again (this was broken in QEMU 8.2.0)"이라는 항목이 있다. 이 경로가 실제로 쓰이고 있지만 회귀가 있었다는 뜻이다.

### 4.7 vfio-user: VFIO를 소켓으로

vfio-user 프로토콜(QEMU "vfio-user Protocol Specification")은 커널 VFIO ioctl의 의미를 UNIX 소켓 메시지로 옮긴 것이다. libvfio-user의 `include/vfio-user.h`에 정의된 명령은 다음과 같다.

`VFIO_USER_VERSION`(1), `VFIO_USER_DMA_MAP`(2), `VFIO_USER_DMA_UNMAP`(3), `VFIO_USER_DEVICE_GET_INFO`(4), `VFIO_USER_DEVICE_GET_REGION_INFO`(5), `VFIO_USER_DEVICE_GET_REGION_IO_FDS`(6), `VFIO_USER_DEVICE_GET_IRQ_INFO`(7), `VFIO_USER_DEVICE_SET_IRQS`(8), `VFIO_USER_REGION_READ`/`WRITE`(9/10), `VFIO_USER_DMA_READ`/`WRITE`(11/12), `VFIO_USER_DEVICE_RESET`(13), `VFIO_USER_REGION_WRITE_MULTI`(15), `VFIO_USER_DEVICE_FEATURE`(16), `VFIO_USER_MIG_DATA_READ`/`WRITE`(17/18).

동작은 다음과 같다. 클라이언트(QEMU)가 `VFIO_USER_DMA_MAP`과 함께 게스트 RAM fd를 넘기면 서버가 이를 매핑하고, 이후 NVMe SQE/PRP가 가리키는 게스트 메모리를 직접 읽고 쓴다. fd로 매핑할 수 없는 영역만 `VFIO_USER_DMA_READ/WRITE` 메시지로 복사한다. BAR 접근은 `VFIO_USER_REGION_READ/WRITE`로 전달된다. 그러나 doorbell처럼 잦은 쓰기는 `VFIO_USER_DEVICE_GET_REGION_IO_FDS`로 받은 ioeventfd나 서버가 mmap 가능하게 공개한 sparse 영역으로 처리해 소켓 왕복을 피한다. 인터럽트는 `VFIO_USER_DEVICE_SET_IRQS`로 받은 eventfd(irqfd)로 보낸다. `VFIO_USER_DEVICE_FEATURE`와 `MIG_DATA_*`, 그리고 `VFIO_USER_DEVICE_STATE_{STOP,RUNNING,STOP_COPY,RESUMING,PRE_COPY}`는 커널 VFIO 마이그레이션 v2 상태 머신과 같은 모양이다.

서버 라이브러리 libvfio-user의 API는 `vfu_create_ctx()`(`VFU_TRANS_SOCK`, `LIBVFIO_USER_FLAG_ATTACH_NB`), `vfu_pci_init()`, `vfu_setup_region()`, `vfu_setup_device_nr_irqs()`, `vfu_setup_device_dma()`, `vfu_setup_device_migration_callbacks()`, `vfu_setup_device_quiesce_cb()`, `vfu_realize_ctx()`, `vfu_attach_ctx()`, `vfu_run_ctx()`, `vfu_get_poll_fd()`, 그리고 DMA 접근용 `vfu_addr_to_sgl()`/`vfu_sgl_get()`/`vfu_sgl_put()`/`vfu_sgl_read()`/`vfu_sgl_write()`/`vfu_sgl_mark_dirty()`, 인터럽트용 `vfu_irq_trigger()`다. `vfu_get_poll_fd()`가 있어서 SPDK처럼 자체 이벤트 루프를 가진 서버가 소켓을 자기 poller에 넣을 수 있다. 마이그레이션 쪽은 `VFU_MIGR_STATE_{STOP,RUNNING,STOP_AND_COPY,PRE_COPY,RESUME}` 콜백 모델을 쓴다. SPDK는 libvfio-user 인터페이스 전환 과정에서 v25.09에 vfio-user 라이브 마이그레이션 코드를 제거했다(→ 07/03).

QEMU 쪽 연표(ChangeLog 확인): 6.0에서 multi-process QEMU(`-machine x-remote`, `x-pci-proxy-dev`)가 실험적으로 추가되었다. 7.1에서 `--object x-vfio-user-server`가 들어왔는데, 당시 ChangeLog는 "A vfio-user client is not yet available in QEMU"라고 적었다. 10.1에서 "Added support for vfio-user client device"로 `vfio-user-pci` 장치(`"socket": {"path": ..., "type": "unix"}`)가 추가되었다. 그 전까지 SPDK vfio-user를 쓰려면 Nutanix/Oracle이 유지한 out-of-tree QEMU 브랜치가 필요했다 `[추측/미확인: 브랜치 유지 주체]`.

### 4.8 VFIO 마이그레이션 v2의 uAPI와 제약

`include/uapi/linux/vfio.h`(master)에서 확인한 이름과 태그별 도입 버전은 다음과 같다.

| uAPI | 의미 | 도입 |
|---|---|---|
| `VFIO_DEVICE_FEATURE_MIGRATION`(1) + `VFIO_MIGRATION_STOP_COPY`, `VFIO_MIGRATION_P2P` | 장치가 지원하는 마이그레이션 기능 질의 | 5.18 |
| `VFIO_DEVICE_FEATURE_MIG_DEVICE_STATE`(2) | 상태 전이. 전이 시 데이터 fd 반환 | 5.18 |
| `enum vfio_device_mig_state`: `ERROR`, `STOP`, `RUNNING`, `STOP_COPY`, `RESUMING`, `RUNNING_P2P` | v2 상태 머신 | 5.18 |
| `VFIO_DEVICE_FEATURE_DMA_LOGGING_START/STOP/REPORT`(6/7/8) | 장치 측 dirty page 추적 | 6.1 |
| `VFIO_MIGRATION_PRE_COPY`, `PRE_COPY`, `PRE_COPY_P2P`, `VFIO_DEVICE_FEATURE_MIG_DATA_SIZE`(9) | 실행 중 사전 복사, 예상 데이터 크기 | 6.2 |
| 레거시 v1 `VFIO_DEVICE_STATE_V1_{STOP,RUNNING,SAVING,RESUMING}` | 이름만 남은 v1 정의 | 5.18에서 v1 → v2 전환 |

v2는 LWN에 "Add mlx5 live migration driver and v2 migration protocol"(Yishai Hadas가 게시한 시리즈)로 소개된 설계다. 핵심은 v1의 "migration region을 통한 데이터 교환"을 버린 것이다. 대신 상태 전이 ioctl이 **데이터 스트림 fd**를 돌려주고, 사용자 공간은 그 fd를 `read()`/`write()`로 읽고 쓴다. 각 상태의 의미는 다음과 같다. `RUNNING_P2P`는 장치가 더 이상 P2P DMA를 시작하지 않도록 하는 단계다. 여러 passthrough 장치가 서로의 BAR에 쓰는 경우, 모두 멈춘 뒤에 상태를 저장하기 위해 필요하다. `STOP_COPY`에서 최종 상태를 저장하고, 대상 쪽은 `RESUMING`에서 쓴다.

NVMe에 적용할 때의 제약은 다음과 같다.

1. **장치 상태 저장은 펌웨어가 해야 한다.** SQ/CQ head/tail, 진행 중인 명령, 네임스페이스 연결, AER 상태를 HW가 직렬화해야 한다. 메인라인 variant driver는 이 기능이 있는 장치(mlx5 VF, HiSilicon ACC, AMD PDS, Intel QAT, virtio-net VF 등)에 한해 존재한다.
2. **dirty tracking**: 장치가 DMA logging(6.1)을 지원하지 않으면 IOMMU의 dirty bit 추적(iommufd의 dirty tracking, `IOMMU_HWPT_ALLOC_DIRTY_TRACKING` 계열)에 의존해야 한다. 둘 다 없으면 STOP_COPY 단계에서 전체 메모리를 다시 보내야 하므로 downtime이 커진다.
3. **controlling function 문제**(3.1절): NVMe에서 상태를 저장하는 주체는 PF다. VF에 바인딩된 VFIO 드라이버가 PF 드라이버와 통신하는 구조를 메인테이너들이 합의하지 못했다.
4. **스토리지 의미론**: 원본과 대상이 같은 네임스페이스(공유 스토리지, 예: NVMe-oF 뒤의 볼륨)를 봐야 한다. 로컬 SSD VF를 옮기면 데이터 자체를 옮겨야 하므로 장치 상태 저장만으로는 부족하다.

이 때문에 클라우드의 "마이그레이션 가능한 고성능 NVMe"는 대부분 소프트웨어 장치(vhost-user/vfio-user, 또는 DPU가 에뮬레이트하는 NVMe/virtio-blk)로 구현된다. 로컬 NVMe passthrough 인스턴스는 마이그레이션 대상에서 빠지는 경우가 많다. 다만 사업자별 구현은 공개 1차 사료로 확인하지 못했다 `[추측/미확인]`.

### 4.9 종합 비교

| 항목 | virtio-blk + iothread | QEMU NVMe 에뮬레이션 | VFIO passthrough / SR-IOV VF | vhost-user-blk(SPDK) | vfio-user(SPDK NVMe) | vDPA HW |
|---|---|---|---|---|---|---|
| 게스트 드라이버 | virtio_blk | nvme | nvme | virtio_blk | nvme | virtio_blk |
| doorbell/kick | ioeventfd(exit 1회) | MMIO 또는 ioeventfd, shadow doorbell | exit 없음 | 백엔드 폴링 시 생략 가능 | sparse mmap + shadow doorbell | HW |
| 완료 알림 | irqfd 주입 | MSI-X 에뮬레이션 | posted interrupt | irqfd | irqfd | posted interrupt 가능 |
| 호스트 CPU 비용 | iothread당 코어 일부 | 높음 | 거의 0 | 폴링 코어 전용 | 폴링 코어 전용 | 거의 0 |
| 멀티큐 확장 | 9.0 `iothread-vq-mapping` | `max_ioqpairs`, 단일 처리 루프 | HW 큐 수 | reactor 코어 수 | poll group 수 | HW |
| 마이그레이션 | 표준 | 표준 | 표준 경로 없음(NVMe) | inflight/dirty log 지원 | 프로토콜 정의, 구현 부분적 | 장치별 |
| 게스트 메모리 | 일반 | 일반 | 핀 필요 | 공유(memfd/hugepage) 필요 | 공유 필요 | 핀 필요 |
| 주 용도 | 범용 클라우드 디스크 | 사양 개발·테스트 | 로컬 SSD 인스턴스, HPC | 고성능 클라우드 블록 | NVMe 호환 고성능 블록 | DPU 오프로드 |

### 4.10 운영 체크리스트

- **IOMMU**: `intel_iommu=on`(또는 AMD 기본 활성)과 IR(interrupt remapping)이 꺼져 있으면 VFIO는 기본적으로 unsafe interrupts를 거부한다. 호스트 자체 I/O 성능을 위해 `iommu=pt`를 쓰더라도, VFIO에 할당한 장치는 변환 도메인을 쓴다.
- **NUMA**: passthrough NVMe, iothread, vCPU, 게스트 메모리를 같은 노드에 두지 않으면 DMA와 인터럽트가 노드를 건너간다. vhost-user에서는 백엔드 reactor 코어도 같은 노드에 둔다.
- **큐 매핑**: 게스트 virtio-blk `num-queues`를 vCPU 수로 맞추고(QEMU의 virtio-blk-pci는 자동 값 사용), 호스트에서는 `iothread-vq-mapping`으로 iothread 수를 별도로 정한다. 게스트 큐 수 = 호스트 스레드 수일 필요는 없다.
- **폴링 정책**: 게스트 `poll_queues`, QEMU iothread `poll-max-ns`(adaptive polling), SPDK reactor 폴링은 서로 중첩되면 같은 이벤트를 위해 코어 여러 개가 회전한다. 한쪽을 이벤트 기반으로 두는 편이 일반적이다.

---

## 5. Primary References

- [lwn.net - Add new VFIO PCI driver for NVMe devices](https://lwn.net/Articles/917063/) — Lei Rao(Intel) RFC 시리즈 게시본, 2022-12-06
- [lwn.net - Add mlx5 live migration driver and v2 migration protocol](https://lwn.net/Articles/884049/) — Yishai Hadas, VFIO 마이그레이션 v2 시리즈, 2022-02-07
- [lwn.net - Add device DMA logging support for mlx5 driver](https://lwn.net/Articles/901222/) — Yishai Hadas, 장치 측 dirty page 추적 uAPI, 2022-07-14
- [lwn.net - pds vfio driver](https://lwn.net/Articles/917915/) — Brett Creeley, `pds_vfio` RFC(초기 목적은 NVMe VF 마이그레이션), 2022-12-14
- [lists.infradead.org - [RFC PATCH 1/5] nvme-pci: add function nvme_submit_vf_cmd to issue admin commands for VF driver.](https://lists.infradead.org/pipermail/linux-nvme/2022-December/036962.html) — Jason Gunthorpe 회신(Hellwig 2022-12-07 원문 인용 포함), 2022-12-07
- [lists.infradead.org - [RFC PATCH 1/5] nvme-pci: add function nvme_submit_vf_cmd to issue admin commands for VF driver.](https://lists.infradead.org/pipermail/linux-nvme/2022-December/036993.html) — Christoph Hellwig 회신, Message-ID `20221212075046.GB11162@lst.de` ([lore](https://lore.kernel.org/all/20221212075046.GB11162@lst.de/))
- [lists.infradead.org - [RFC PATCH 1/5] nvme-pci: add function nvme_submit_vf_cmd to issue admin commands for VF driver.](https://lists.infradead.org/pipermail/linux-nvme/2022-December/037020.html) — Jason Gunthorpe 회신, Message-ID `Y5iFnw5i3vI9iMFY@ziepe.ca` ([lore](https://lore.kernel.org/all/Y5iFnw5i3vI9iMFY@ziepe.ca/))
- [kernel.org - VFIO - "Virtual Function I/O"](https://docs.kernel.org/driver-api/vfio.html) — VFIO 커널 문서
- [kernel.org - IOMMUFD](https://docs.kernel.org/userspace-api/iommufd.html) — iommufd uAPI 문서
- [git.kernel.org - include/uapi/linux/vfio.h](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/include/uapi/linux/vfio.h) — 마이그레이션 v2·DMA logging uAPI 정의
- [git.kernel.org - drivers/vfio/pci/vfio_pci_intrs.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/vfio/pci/vfio_pci_intrs.c) — `vfio_msihandler()`, irqbypass producer 등록
- [git.kernel.org - drivers/block/virtio_blk.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/block/virtio_blk.c) — 게스트 virtio-blk 드라이버
- [git.kernel.org - arch/x86/kvm/vmx/posted_intr.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/arch/x86/kvm/vmx/posted_intr.c) — VT-d posted interrupt, `vmx_pi_update_irte()`
- [qemu.org - NVMe Emulation](https://www.qemu.org/docs/master/system/devices/nvme.html) — QEMU 에뮬레이트 NVMe 문서(FDP, SR-IOV 속성)
- [qemu.org - vfio-user](https://www.qemu.org/docs/master/system/devices/vfio-user.html) — QEMU `vfio-user-pci` 클라이언트 문서
- [qemu.org - vfio-user Protocol Specification](https://www.qemu.org/docs/master/interop/vfio-user.html) — vfio-user 프로토콜 규격
- [qemu.org - Vhost-user Protocol](https://www.qemu.org/docs/master/interop/vhost-user.html) — vhost-user 프로토콜 규격
- [wiki.qemu.org - ChangeLog/9.0](https://wiki.qemu.org/ChangeLog/9.0) — virtio-blk `iothread-vq-mapping`, VDUSE export 회귀 수정
- [wiki.qemu.org - ChangeLog/10.1](https://wiki.qemu.org/ChangeLog/10.1) — vfio-user 클라이언트 장치 추가
- [wiki.qemu.org - ChangeLog/7.1](https://wiki.qemu.org/ChangeLog/7.1) — `x-vfio-user-server` 추가
- [wiki.qemu.org - ChangeLog/6.0](https://wiki.qemu.org/ChangeLog/6.0) — multi-process QEMU, NVMe v1.4·ZNS 실험 지원
- [gitlab.com/qemu-project - hw/nvme/ctrl.c](https://gitlab.com/qemu-project/qemu/-/blob/master/hw/nvme/ctrl.c) — QEMU NVMe 컨트롤러 구현
- [gitlab.com/qemu-project - hw/block/virtio-blk.c](https://gitlab.com/qemu-project/qemu/-/blob/master/hw/block/virtio-blk.c) — QEMU virtio-blk 장치 구현
- [gitlab.com/qemu-project - qapi/block-core.json](https://gitlab.com/qemu-project/qemu/-/blob/master/qapi/block-core.json) — `aio=` 옵션, libblkio 드라이버 정의
- [GitHub - nutanix/libvfio-user: framework for emulating devices in userspace](https://github.com/nutanix/libvfio-user) — vfio-user 서버 라이브러리
- [spdk.io - VFIO-USER: A new virtualization protocol](https://spdk.io/news/2021/05/04/vfio-user/) — SPDK 블로그, 2021-05-04
- [spdk.io - SPDK: vhost Target](https://spdk.io/doc/vhost.html) — SPDK vhost 타깃 문서
- [usenix.org - Spool: Reliable Virtualized NVMe Storage Pool in Public Cloud Infrastructure](https://www.usenix.org/conference/atc20/presentation/xue) — Xue et al., USENIX ATC '20
