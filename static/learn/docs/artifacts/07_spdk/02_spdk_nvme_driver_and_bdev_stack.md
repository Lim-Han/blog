# SPDK 사용자 공간 NVMe 드라이버와 bdev 스택: qpair·PRP/SGL·CMB/PMR·multi-process에서 blobstore/lvol·xNVMe까지

> 기준: SPDK `master` (v27.01 개발 중, 2026-10-14 확인), 최신 릴리스 v26.09. 함수·구조체 이름은 `include/spdk/nvme.h`, `include/spdk/bdev.h`, `include/spdk/bdev_module.h`, `include/spdk/blob.h`, `include/spdk/lvol.h`, `lib/nvme/nvme_pcie_common.c`, `lib/nvme/nvme.c`, `lib/bdev/bdev.c`, `lib/blob/blobstore.h`, `module/bdev/*` 원문과 대조했다. 모듈 목록은 GitHub `module/bdev` 디렉터리의 현재 상태다.

## 1. Verdict

SPDK의 데이터 경로는 두 층으로 나뉜다.

1. **`lib/nvme`: 수동적(passive) 사용자 공간 NVMe 드라이버.** [NVMe Driver](https://spdk.io/doc/nvme.html) 문서는 이 라이브러리가 "entirely passive, meaning that it spawns no threads and only performs actions in response to function calls from the application itself"라고 설명한다. PCI BAR를 프로세스에 매핑해 MMIO로 컨트롤러를 초기화한다. I/O는 `spdk_nvme_ns_cmd_read()`/`_write()`로 SQ에 넣고, `spdk_nvme_qpair_process_completions()`를 호출해 CQ를 폴링한다. qpair 안에는 락도 원자적 연산도 없다. 대신 "한 qpair는 한 시점에 한 스레드만 쓴다"는 계약을 드라이버가 검사하지 않고 사용자에게 맡긴다. 계약을 어기면 정의되지 않은 동작이다.
2. **`lib/bdev`: 사용자 공간 블록 계층.** `spdk_bdev_io`를 단위로 모듈(nvme, aio, uring, malloc, raid, crypto, lvol, ftl, xnvme 등)을 꽂아 쓰는 플러그인 구조다. 큐잉(`nomem_io`), 분할(split), QoS, 타임아웃, reset, 메모리 도메인, accel 시퀀스 같은 공용 기능을 제공한다. 그 위에 blobstore(`lib/blob`)와 그 위의 lvol(`lib/lvol`)이 씬 프로비저닝, 스냅샷, 클론을 제공한다.

판단 요지는 다음과 같다.

- 성능의 근원은 **qpair를 스레드에 직접 주는 것**과 **doorbell MMIO를 줄이는 것**이다(`delay_cmd_submit`, shadow doorbell, CQ head 배치 갱신). PRP/SGL 빌드는 I/O마다 `nvme_pcie_prp_list_append()` 같은 함수가 tracker 안의 미리 할당된 PRP 리스트에 채운다. I/O 경로에서 malloc은 하지 않는다.
- multi-process는 존재한다. SPDK를 두고 "다중 프로세스 간 디바이스 공유 불가"라고 흔히 설명하지만 정확하지 않다(커널 passthrough와의 비교는 → 03/02). DPDK primary/secondary 모델과 `spdk_memzone`(`"spdk_nvme_driver"`)을 써서 같은 `shm_id`의 프로세스들이 컨트롤러를 공유하고 각자 qpair를 만든다. 다만 공유 범위는 "같은 shm 그룹의 SPDK 프로세스"뿐이다. 커널, 파일시스템, 다른 테넌트와는 공유하지 못한다.
- bdev 모듈 구성은 계속 바뀌었다. **compress bdev와 reduce 라이브러리, blobfs, RocksDB 플러그인은 v25.09에서 제거됐다**(CHANGELOG v25.09). 따라서 "SPDK bdev 종류"를 말할 때 compress와 blobfs는 과거형으로 써야 한다.
- xNVMe bdev(v22.09)는 SPDK 안에서 커널 경로(libaio, io_uring, `io_uring_cmd` 패스스루)를 고를 수 있게 한다. SPDK 사용자 공간 드라이버와 커널 io_uring passthrough의 경계를 흐리는 지점이다.

---

## 2. Problem Statement

### 2.1 커널 NVMe 경로가 하는 일과 그 비용

Linux에서 `O_DIRECT` 4KiB read 하나는 다음 단계를 거친다.

- syscall 진입, `iov_iter` 구성, `bio` 할당과 페이지 pin(`get_user_pages` 계열)
- blk-mq 태그 할당(`sbitmap`), `struct request` 초기화
- `nvme_queue_rq()`에서 DMA 매핑(IOMMU가 있으면 IOVA 할당), PRP/SGL 구성, SQ doorbell MMIO
- MSI-X 인터럽트, softirq/irq 문맥 완료 처리, 사용자 공간으로 복귀

io_uring, `REQ_POLLED`, 배치 제출(`queue_rqs`)이 이 비용을 크게 줄였다. 그래도 공용 기능(태그, 타임아웃, cgroup, 페이지 pin, DMA API)은 계속 남는다. FAST '24 I/O Passthru 논문도 passthrough가 block 계층의 태그 관리와 타임아웃 기능을 쓰기 때문에 SPDK와 격차가 남는다고 분석했다([논문 페이지](https://www.usenix.org/conference/fast24/presentation/joshi)).

### 2.2 사용자 공간 드라이버가 대신 풀어야 할 문제

커널을 떠나면 커널이 해 주던 일을 SPDK가 직접 해야 한다.

| 커널이 하던 일 | SPDK가 대신 해야 하는 일 | SPDK의 해법 |
|---|---|---|
| DMA 가능한 메모리, 주소 변환 | pin된 버퍼와 IOVA | hugepage + `spdk_mem_map`/`spdk_vtophys()` (→ 07/01, 4.1절) |
| 큐 소유권 동기화 | qpair 동시 접근 방지 | "1 qpair = 1 thread" 계약, 검사하지 않음 |
| 요청 객체·태그 할당 | CID/tracker 관리 | qpair마다 미리 할당한 `struct nvme_tracker`(트래커당 4KiB) |
| 최대 전송 크기·PRP 경계 처리 | 큰 I/O 분할 | `nvme_ns_cmd.c`가 MDTS나 stripe 경계에서 자식 요청으로 분할 |
| 핫플러그·서프라이즈 제거 | BAR 접근 시 SIGBUS | SIGBUS 핸들러가 BAR를 placeholder 메모리로 다시 매핑 |
| 다중 프로세스 접근 | 컨트롤러 상태 공유 | DPDK multi-process + `spdk_memzone` |
| 블록 계층 공용 기능 | 큐잉, 분할, QoS, 파티션, LVM | `lib/bdev`, vbdev 모듈, blobstore/lvol |

### 2.3 파일시스템 없이 상위 서비스를 올리는 문제

장치를 커널에서 떼면 ext4나 XFS를 쓸 수 없다. 그래서 SPDK는 [Blobstore Programmer's Guide](https://spdk.io/doc/blob.html)가 말하는 "persistent, power-fail safe block allocator"를 직접 제공한다. 문서에 따르면 blobstore는 "local storage system backing a higher level storage service, typically in lieu of a traditional filesystem"이고, "intentionally not POSIX compliant"하다. 즉 SPDK는 범용 파일시스템을 만들지 않고, 데이터베이스나 분산 스토리지가 바로 쓸 수 있는 할당기를 제공하는 쪽을 택했다. POSIX 파일 인터페이스를 흉내 내던 blobfs는 v25.09에서 제거됐다.

---

## 3. The Debate

### 3.1 "드라이버가 스레드 안전을 보장해야 하는가"

SPDK NVMe 드라이버의 가장 논쟁적인 결정은 qpair에 락을 넣지 않은 것이다. [NVMe Driver](https://spdk.io/doc/nvme.html) 문서의 "Scaling Performance" 절은 다음과 같이 적는다.

> "Queue pairs contain no locks or atomics, however, so a given queue pair may only be used by a single thread at a time. This requirement is not enforced by the NVMe driver (doing so would require a lock), and violating this requirement results in undefined behavior."
>
> — SPDK 공식 문서 [NVMe Driver](https://spdk.io/doc/nvme.html) (2026-10-14 확인)

해설: 커널 드라이버라면 받아들일 수 없는 계약이다. 커널은 임의의 문맥에서 들어오는 I/O를 받아야 하기 때문이다. SPDK는 "애플리케이션이 스레드 구조를 안다"는 전제(→ 07/01, 2.2절)에서 이 계약을 정당화한다. 같은 문서는 장치가 보통 32~128개 qpair를 지원하고, 실제로는 qpair 하나로도 장치 성능을 거의 다 낼 수 있다고 덧붙인다. 그래서 "스레드 풀 + 스레드당 qpair 하나"를 가장 쉬운 모델로 권한다. 헤더 주석도 `spdk_nvme_ns_cmd_read()` 같은 제출 함수에 "The user must ensure that only one thread submits I/O on a given qpair at any given point in time"라고 반복한다(`include/spdk/nvme.h`).

반대 방향의 압력은 bdev 계층에서 나온다. 여러 스레드가 같은 NVMe 컨트롤러를 쓰려면 스레드마다 qpair가 필요하다. 이를 `bdev_nvme` 모듈이 `spdk_io_channel` 생성 콜백에서 qpair를 할당하는 방식으로 자동화했다. 즉 "스레드 안전"은 드라이버가 아니라 **io_channel 모델**이 보장한다.

### 3.2 PRP vs SGL: 사양의 선택지를 어떻게 쓸 것인가

[DMA From User Space](https://spdk.io/doc/memory.html) 문서는 NVMe 1.0의 PRP 제약을 자세히 설명한다. 첫 페이지만 4바이트 정렬된 부분 페이지일 수 있고, 중간 페이지는 4KiB 경계에서 시작하고 끝나야 한다. 이 제약 때문에 임의의 scatter 버퍼는 PRP로 표현하지 못할 수 있다. NVMe 1.1부터 SGL을 쓸 수 있지만 문서는 "the feature is optional and most devices available today do not support it"이라고 쓴다(작성 시점 기준 서술). 그래서 SPDK는 두 경로를 모두 구현한다. `nvme_pcie_qpair_build_prps_sgl_request()`/`nvme_pcie_qpair_build_prps_iov_request()`는 iovec을 PRP로 바꾸다가 경계 조건을 어기면 요청을 실패시키거나 분할한다. 컨트롤러가 SGL을 지원하면 `nvme_pcie_qpair_build_hw_sgl_request()`나 `nvme_pcie_qpair_build_contig_hw_sgl_request()`를 쓴다.

여기서 생기는 쟁점은 "PRP로 표현할 수 없는 iovec을 누가 책임지는가"이다. 커널 NVMe 드라이버는 block 계층의 `virt_boundary_mask` 설정으로 상위가 PRP 호환 bio만 내려보내게 한다. SPDK 드라이버는 `spdk_nvme_req_reset_sgl_cb`/`spdk_nvme_req_next_sge_cb` 콜백으로 사용자 버퍼를 한 조각씩 받는다. 조각이 PRP 규칙을 어기면 `nvme_pcie_fail_request_bad_vtophys()` 같은 실패 경로로 보낸다. bdev 계층은 정렬 요구가 맞지 않는 버퍼를 bounce buffer로 감싼다(`spdk_bdev_io_complete()`의 `has_bounce_buf` 경로).

### 3.3 blobstore: 파일시스템이 아닌 할당기를 고른 이유

[Blobstore Programmer's Guide](https://spdk.io/doc/blob.html)는 설계 동기를 이렇게 밝힌다.

> "Blobstore is a persistent, power-fail safe block allocator designed to be used as the local storage system backing a higher level storage service, typically in lieu of a traditional filesystem. ... It is not designed to be a general purpose filesystem, however, and it is intentionally not POSIX compliant."
>
> — SPDK 공식 문서 [Blobstore Programmer's Guide](https://spdk.io/doc/blob.html) (2026-10-14 확인)

해설: 이 결정의 대가는 **메타데이터 일관성 모델**이다. 문서에 따르면 blob별 메타데이터(xattr, 크기)는 RAM에 캐시되고 `spdk_blob_sync_md()`를 호출해야 디스크에 원자적으로 반영된다. blobstore 전역 메타데이터(할당 비트맵 등)는 정상 unload(`spdk_bs_unload()`) 때만 동기화된다. 비정상 종료 뒤에는 다음 load에서 추가 복구 작업이 필요하다. 문서는 일관성은 깨지지 않고 성능 페널티만 있다고 설명한다. 저널링 파일시스템과 비교하면, SPDK는 런타임 쓰기 증폭을 피하는 대신 비정상 종료 복구 비용을 감수하는 쪽을 택했다.

또 하나의 쟁점은 **메타데이터 스레드**다. blob.h 헤더는 "only allowing most functions to be called on the metadata thread"라고 명시한다. 여기서 메타데이터 스레드는 `spdk_bs_init()`나 `spdk_bs_load()`를 호출한 스레드다. 메타데이터 연산끼리, 그리고 메타데이터 연산과 그와 겹치는 I/O 사이에는 내부 락이 없다. 따라서 직렬화는 애플리케이션 책임이다. 락 없는 설계를 메타데이터까지 밀어붙인 결과다.

### 3.4 "커널 경로도 bdev로" — xNVMe와 uring bdev

SPDK 안에도 커널을 다시 쓰는 경로가 있다. `bdev_aio`(Linux AIO), `bdev_uring`(io_uring, v19.04 도입), `bdev_xnvme`(v22.09)가 그것이다. FAST '24 I/O Passthru 논문 5.2.2절은 Samsung 저자들이 xNVMe bdev를 추가한 이유를 다음과 같이 설명한다.

> "We add a new bdev xNVMe in SPDK (shown in Figure 6). This single bdev allows to switch among AIO, io_uring, and io_uring_cmd. This bdev became part of SPDK since release version 22.09."
>
> — Joshi et al., [I/O Passthru: Upstreaming a flexible and efficient I/O Path in Linux](https://www.usenix.org/conference/fast24/presentation/joshi), FAST '24 (2024-02), §5.2.2

해설: SPDK의 가치를 "사용자 공간 NVMe 드라이버"로 보는 시각과 "bdev/NVMe-oF/vhost라는 스토리지 서비스 프레임워크"로 보는 시각이 여기서 갈린다. xNVMe bdev를 쓰면 장치는 커널(`/dev/ngXnY`)에 남겨 둔 채, SPDK의 NVMe-oF target이나 vhost 같은 상위 서비스만 쓸 수 있다. `bdev_xnvme_create` RPC의 `io_mechanism` 파라미터는 `libaio`, `io_uring`, `io_uring_cmd` 등을 받는다. `conserve_cpu` 옵션은 폴링 강도를 조절한다([JSON-RPC](https://spdk.io/doc/jsonrpc.html) 문서). `bdev_uring` 소스에는 "Do not use IORING_SETUP_IOPOLL until the Linux kernel can support not only local devices but also devices attached from remote target"라는 주석이 있다. 즉 uring bdev는 IOPOLL 없이 일반 io_uring 링을 쓴다(`module/bdev/uring/bdev_uring.c`).

---

## 4. Implementation Impact

### 4.1 probe/attach: 컨트롤러 획득

```
struct spdk_nvme_transport_id trid = {};
spdk_nvme_transport_id_parse(&trid, "trtype:PCIe traddr:0000:04:00.0");
spdk_nvme_probe(&trid, cb_ctx, probe_cb, attach_cb, remove_cb);
   probe_cb(cb_ctx, trid, opts)   // 붙을지 결정, spdk_nvme_ctrlr_opts(큐 수, io_queue_size, enable_interrupts 등) 수정
   attach_cb(cb_ctx, trid, ctrlr, opts)  // 초기화 완료된 struct spdk_nvme_ctrlr *
   remove_cb(cb_ctx, ctrlr)       // 핫 제거 감지 시
```

- `spdk_nvme_probe()`는 동기 래퍼다. 비동기판은 `spdk_nvme_probe_async()` + `spdk_nvme_probe_poll_async()`, 단일 컨트롤러용은 `spdk_nvme_connect()`이다. 해제는 `spdk_nvme_detach()`/`spdk_nvme_detach_async()`로 한다.
- transport 종류(`SPDK_NVME_TRANSPORT_PCIE`, `_TCP`, `_RDMA`, `_VFIOUSER`, `_CUSTOM`)와 상관없이 API가 같다. 같은 코드가 로컬 SSD와 NVMe-oF 원격 서브시스템(discovery 포함)에 모두 붙는다.
- PCIe에서는 `nvme_pcie_ctrlr_scan()`이 장치를 열거하고, `nvme_pcie_ctrlr_allocate_bars()`로 BAR를 매핑한다. 그 뒤 `nvme_pcie_ctrlr_set_asq()`/`_set_acq()`/`_set_aqa()`로 admin 큐를 설정하고 `CC.EN`을 켜는 사양 절차를 사용자 공간에서 그대로 수행한다.
- admin 완료는 `spdk_nvme_ctrlr_process_admin_completions()`를 주기적으로 호출해 처리한다. AER과 keep-alive도 이 호출에 묶여 있다. bdev_nvme 모듈은 이를 `bdev_nvme_poll_adminq` poller로 돌린다.

### 4.2 qpair와 I/O 제출·완료

```
struct spdk_nvme_io_qpair_opts o;
spdk_nvme_ctrlr_get_default_io_qpair_opts(ctrlr, &o, sizeof(o));
o.delay_cmd_submit = true;                 // doorbell을 process_completions까지 미룸
qp = spdk_nvme_ctrlr_alloc_io_qpair(ctrlr, &o, sizeof(o));
ns = spdk_nvme_ctrlr_get_ns(ctrlr, nsid);
spdk_nvme_ns_cmd_read(ns, qp, buf, lba, lba_count, cb_fn, cb_arg, io_flags);
...
spdk_nvme_qpair_process_completions(qp, 0 /* 0 = max_completions_cap까지 */);
```

**제출 경로 (PCIe, master 기준)**

```
spdk_nvme_ns_cmd_read()                   // lib/nvme/nvme_ns_cmd.c
  └─ 요청 생성(nvme_request), 필요하면 MDTS/stripe 경계로 자식 요청 분할
  └─ nvme_qpair_submit_request()
       └─ nvme_pcie_qpair_submit_request()      // lib/nvme/nvme_pcie_common.c
            ├─ 빈 nvme_tracker 확보 (없으면 queued_req로 대기)
            ├─ 페이로드 유형별 빌드:
            │    contig → nvme_pcie_qpair_build_contig_request() → nvme_pcie_prp_list_append()
            │    SGL 콜백 + PRP → nvme_pcie_qpair_build_prps_sgl_request()
            │    SGL 콜백 + HW SGL → nvme_pcie_qpair_build_hw_sgl_request()
            │    메타데이터 → nvme_pcie_qpair_build_metadata()
            └─ nvme_pcie_qpair_submit_tracker()
                 ├─ 64B SQE를 pqpair->cmd[sq_tail]에 복사
                 │   (CMB SQ + NVME_QUIRK_MAXIMUM_PCI_ACCESS_WIDTH면 8바이트 단위 MMIO 복사)
                 ├─ sq_tail 증가(래핑)
                 ├─ fused 첫 명령이면 두 번째 명령까지 doorbell 보류
                 └─ !delay_cmd_submit 이면 nvme_pcie_qpair_ring_sq_doorbell()
```

**완료 경로** (`nvme_pcie_qpair_process_completions()`):

1. CQ의 `cq_head` 항목의 phase 비트(`cpl->status.p`)를 `pqpair->flags.phase`와 비교한다. 다르면 새 완료가 없으므로 종료한다. 완료 감지에 MMIO가 없다는 점이 폴링 비용이 낮은 이유다. [User Space Drivers](https://spdk.io/doc/userspace.html) 문서는 Intel DDIO가 장치가 갱신한 CQ 라인을 CPU 캐시에 넣어 준다는 점도 언급한다.
2. 다음 CQE의 유효성을 미리 보고, 유효하면 `__builtin_prefetch(&pqpair->tr[next_cpl->cid])`로 다음 tracker를 미리 캐시에 올린다.
3. 약한 메모리 순서 아키텍처에서는 phase 읽기와 나머지 필드 읽기 사이에 배리어를 둔다. PPC64/RISC-V/LoongArch는 `spdk_mb()`, aarch64는 `dmb oshld`를 쓴다. x86은 TSO 덕분에 생략한다.
4. `cq_head`가 끝에 닿으면 0으로 돌리고 phase를 뒤집는다.
5. tracker 완료 → 사용자 콜백 호출.
6. 루프가 끝나면 CQ head doorbell을 **한 번만** 쓴다. `delay_cmd_submit`이면 이때 SQ tail doorbell도 쓴다. 처리 개수 상한 `max_completions_cap`은 CQ doorbell이 한 바퀴를 넘지 않게 막는다.
7. admin 큐에서는 `nvme_ctrlr_lock()`을 잡는다. admin 큐는 여러 스레드가 만질 수 있기 때문이다. I/O qpair에는 락이 없다.

**shadow doorbell.** 컨트롤러가 Doorbell Buffer Config(가상화 환경의 에뮬레이트 NVMe에서 흔함)를 지원하면, `has_shadow_doorbell` 플래그가 켜진다. 그러면 `nvme_pcie_qpair_update_mmio_required()`가 shadow 값과 eventidx를 비교해 **필요할 때만** 실제 MMIO를 쓴다. VM 안에서 SPDK를 돌릴 때 VM exit를 줄여 주는 장치다.

**메모리 사용.** NVMe 문서에 따르면 tracker 하나는 4096바이트로 고정이다. 그래서 I/O 큐당 tracker 메모리는 최대 (MQES+1)×4KiB이고, SQ/CQ 자체는 (MQES+1)×(64+16)바이트다.

### 4.3 poll group

스레드 하나가 여러 컨트롤러의 qpair를 가지면 각각을 폴링하는 대신 `spdk_nvme_poll_group_create()` → `spdk_nvme_poll_group_add(group, qpair)` → `spdk_nvme_poll_group_process_completions(group, 0, disconnected_cb)` 순서로 한 번에 처리한다. transport별 poll group(`nvme_pcie_poll_group_create()` 등)은 RDMA처럼 CQ를 공유할 수 있는 transport에서 특히 유리하다. v25.05부터는 poll group이 fd group을 만들고, `spdk_nvme_poll_group_wait()`로 interrupt 이벤트를 기다릴 수 있다(CHANGELOG v25.05). `bdev_nvme`는 스레드마다 `struct nvme_poll_group` 하나를 io_channel로 만들고(`bdev_nvme_create_poll_group_cb`), `bdev_nvme_poll` poller에서 위 함수를 호출한다.

### 4.4 CMB와 PMR

- **CMB(Controller Memory Buffer)**: `nvme_pcie_ctrlr_map_cmb()`가 CMBLOC/CMBSZ 레지스터를 읽고 BAR 영역을 매핑한다. `spdk_nvme_io_qpair_opts`에 따라 SQ를 CMB에 둘 수 있다(`sq_in_cmb`). 이렇게 하면 장치가 SQE를 호스트 메모리에서 읽어 오는 PCIe 왕복이 사라진다. 데이터 버퍼용으로는 `spdk_nvme_ctrlr_reserve_cmb()` → `spdk_nvme_ctrlr_map_cmb()`/`spdk_nvme_ctrlr_unmap_cmb()`로 CMB를 매핑해 P2P DMA 대상으로 쓸 수 있다. vfio에서는 BAR 영역도 `vtophys_iommu_map_dma_bar()`로 IOMMU에 등록한다.
- **PMR(Persistent Memory Region)**: `spdk_nvme_ctrlr_enable_pmr()`, `spdk_nvme_ctrlr_map_pmr()`, `spdk_nvme_ctrlr_get_pmrsz()`를 쓴다. 내부적으로는 PMRCAP/PMRCTL/PMRSTS 레지스터(`nvme_pcie_ctrlr_get_pmrcap()` 등)를 다룬다. v25.09에 추가된 NVMe-oF NSSR 문서는 NSSR이 연관 컨트롤러의 PMR을 비활성화한다고 설명한다.

### 4.5 multi-process

`lib/nvme/nvme.c`의 `nvme_driver_init()` 흐름은 다음과 같다.

- primary(`spdk_process_is_primary()`): `spdk_memzone_reserve("spdk_nvme_driver", ...)`로 전역 드라이버 구조를 공유 메모리에 만들고 `shared_attached_ctrlrs` 리스트를 초기화한다.
- secondary: `spdk_memzone_lookup("spdk_nvme_driver")`로 같은 구조를 찾는다. PCIe probe 시 `shared_attached_ctrlrs`에서 이미 붙은 컨트롤러를 찾아 `nvme_ctrlr_proc_get_ref()`로 참조만 추가한다.
- 프로세스별 상태는 `struct spdk_nvme_ctrlr_process`(할당한 I/O qpair 목록, 활성 프로세스)에 담고, 컨트롤러의 `active_proc`이 가리킨다.

[NVMe Driver](https://spdk.io/doc/nvme.html) 문서가 밝힌 제약은 다음과 같다. 같은 shm_id를 쓰는 프로세스끼리 코어를 겹쳐 쓰면 안 된다. primary가 먼저 죽으면 기존 secondary는 계속 돌지만 새 primary는 만들 수 없다. LBA 접근 조정은 애플리케이션 몫이다. 의도된 용도는 "management tools that can attach to long running applications"이다. v25.05 PCIe interrupt 모드는 primary process에서만 지원된다(릴리스 공지).

### 4.6 bdev 계층: 사용자 API와 모듈 API

**사용자 측** (`include/spdk/bdev.h`):

```
spdk_bdev_open_ext("Nvme0n1", write, event_cb /* SPDK_BDEV_EVENT_REMOVE/RESIZE... */, ctx, &desc);
ch = spdk_bdev_get_io_channel(desc);                  // 스레드마다 한 번
rc = spdk_bdev_read_blocks(desc, ch, buf, offset_blocks, num_blocks, cb, cb_arg);
if (rc == -ENOMEM) spdk_bdev_queue_io_wait(bdev, ch, &wait_entry);  // spdk_bdev_io 풀 고갈 시
...
cb(struct spdk_bdev_io *bdev_io, bool success, void *cb_arg) { ...; spdk_bdev_free_io(bdev_io); }
```

이 밖에 벡터/확장 API(`spdk_bdev_readv_blocks()`, `spdk_bdev_writev_blocks_ext()` + `struct spdk_bdev_ext_io_opts`), `spdk_bdev_unmap_blocks()`, `spdk_bdev_zcopy_start()`, NVMe passthrough(`spdk_bdev_nvme_io_passthru()`, `spdk_bdev_nvme_admin_passthru()`), QoS(`spdk_bdev_set_qos_rate_limits()`), 메모리 도메인(`spdk_bdev_get_memory_domains()`)이 있다.

**모듈 측** (`include/spdk/bdev_module.h`): 모듈은 `SPDK_BDEV_MODULE_REGISTER()`로 `struct spdk_bdev_module`을 등록한다. bdev마다 `struct spdk_bdev_fn_table`을 채운다(`submit_request`, `io_type_supported`, `get_io_channel`, `destruct` 등). `spdk_bdev_register()`로 공개하고, 완료는 `spdk_bdev_io_complete()`나 `spdk_bdev_io_complete_nvme_status()`로 알린다. 버퍼가 필요한 read는 `spdk_bdev_io_get_buf(bdev_io, cb, len)`로 bdev 계층 버퍼 풀에서 받는다. vbdev는 `spdk_bdev_module_claim_bdev()`/`spdk_bdev_module_claim_bdev_desc()`로 하위 bdev를 점유하고, 파티션형은 `spdk_bdev_part_base_construct_ext()`를 쓴다. 지원 I/O 유형은 `SPDK_BDEV_IO_TYPE_READ/WRITE/UNMAP/FLUSH/RESET/NVME_ADMIN/NVME_IO/NVME_IO_MD/WRITE_ZEROES/ZCOPY/GET_ZONE_INFO/ZONE_MANAGEMENT/ZONE_APPEND/COMPARE/COMPARE_AND_WRITE/ABORT/SEEK_HOLE/SEEK_DATA/COPY/NVME_IOV_MD/NVME_NSSR/WRITE_UNCORRECTABLE`이다.

**`spdk_bdev_io`의 수명과 내부 경로** (`lib/bdev/bdev.c`):

- 할당: 스레드별 `struct spdk_bdev_mgmt_channel`의 `per_thread_cache`(기본 `SPDK_BDEV_IO_CACHE_SIZE` = 256개)에서 먼저 꺼낸다. 비어 있으면 전역 mempool에서 가져온다. 해제(`spdk_bdev_free_io()`)할 때는 캐시가 덜 찼으면 캐시로 돌려준다. 락 없는 할당의 핵심이다.
- 제출: `bdev_io_submit()` → `_bdev_io_submit()` → (QoS 대상이면 `bdev_qos_io_submit()`) → (분할 필요 시 `bdev_io_split()`) → `bdev_io_do_submit()`. 여기서 `shared_resource->nomem_io`가 비어 있으면 `bdev_submit_request()`가 모듈의 `submit_request`를 호출한다. 비어 있지 않으면 순서 보존을 위해 큐 뒤에 붙인다.
- `struct spdk_bdev_shared_resource`: 같은 스레드에서 같은 하위 io_channel(예: 같은 NVMe poll group)을 공유하는 bdev 채널들의 공용 상태다. `nomem_io` 큐와 `nomem_threshold`를 가진다. 모듈이 `SPDK_BDEV_IO_STATUS_NOMEM`으로 완료하면 I/O는 이 큐로 가고, `io_outstanding`이 임계값 아래로 떨어지면 `bdev_ch_retry_io()`가 다시 제출한다. 커널 blk-mq의 `BLK_STS_RESOURCE` + 재실행과 같은 역할이다.
- 완료: `spdk_bdev_io_complete()`는 outstanding 카운터를 줄이고, 필요하면 accel 시퀀스를 실행하거나 bounce buffer 데이터를 되돌린 뒤 `bdev_io_complete()`를 호출한다. 이때 `in_submit_request` 플래그가 켜져 있으면, 즉 모듈이 submit 안에서 동기적으로 완료했으면, 재귀를 피하려고 `spdk_thread_send_msg()`로 콜백을 다음 반복으로 미룬다.
- reset: `SPDK_BDEV_IO_TYPE_RESET` 완료 시 `spdk_bdev_for_each_channel(bdev, bdev_unfreeze_channel, ...)`로 모든 스레드의 채널을 순회하며 freeze를 푼다.

### 4.7 bdev 모듈 지형 (master, 2026-10)

GitHub `module/bdev` 디렉터리의 현재 목록은 다음과 같다. aio, crypto, daos, delay, error, ftl, gpt, iscsi, kvmalloc, lvol, malloc, null, nvme, ocf, passthru, raid, rbd, split, uring, virtio, xnvme, zone_block.

| 모듈 | 하위 경로 | 비고 (도입/변경) |
|---|---|---|
| `nvme` | SPDK 사용자 공간 NVMe 드라이버 (PCIe/TCP/RDMA/vfio-user) | 스레드별 `nvme_poll_group`, 멀티패스(`nvme_bdev_channel`, `nvme_io_path`, `bdev_nvme_find_io_path()`), `bdev_nvme_attach_controller` RPC |
| `aio` | Linux libaio (커널 블록 장치/파일) | eventfd 기반 interrupt 지원, v26.01 hot remove |
| `uring` | io_uring (`io_uring_prep_readv/writev`) | v19.04 도입, IOPOLL 미사용, zoned 지원, v26.01 hot remove |
| `xnvme` | xNVMe (libaio / io_uring / io_uring_cmd …) | v22.09 도입, `io_mechanism`, `conserve_cpu` |
| `malloc` / `null` | DRAM / 데이터 없음 | 테스트·벤치마크 |
| `raid` | raid0, raid1, concat, raid5f | v18.07 raid 도입. 소스 파일 `raid0.c`, `raid1.c`, `concat.c`, `raid5f.c`, superblock(`bdev_raid_sb.c`) |
| `crypto` | accel 프레임워크(dpdk_cryptodev, mlx5 등) | v18.10 도입 |
| `lvol` | blobstore 위 논리 볼륨 | v17.10 도입, 스냅샷/클론 v18.04 |
| `ftl` | Flash Translation Layer | v20.01 FTL bdev |
| `ocf` | Open CAS Framework 캐시 | |
| `rbd` / `daos` / `iscsi` / `virtio` | Ceph RBD / DAOS / iSCSI initiator / virtio-blk·scsi initiator | |
| `gpt` / `split` / `passthru` / `delay` / `error` / `zone_block` | 파티션, 분할, 예제, 지연·오류 주입, zoned 에뮬레이션 | |
| `kvmalloc` | 메모리 KV 백엔드 | v26.09 NVMe-oF KV 지원과 함께 추가 |
| ~~`compress`~~ | reduce 라이브러리 + accel 압축 | v19.04 도입, **v25.09 제거** |
| ~~`pmem`~~ | libpmemblk | 초기 버전에 존재. 현재 `module/bdev`에 없음(제거 시점 미확인) [추측/미확인] |

### 4.8 blobstore 온디스크 구조와 API

`lib/blob/blobstore.h` 기준이다.

- 계층: logical block → page(`SPDK_BS_PAGE_SIZE` = 0x1000, 4KiB 메타데이터 페이지) → cluster(기본 1MiB) → blob(cluster의 순서 있는 리스트). 데이터 I/O 단위는 io_unit(`spdk_bs_get_io_unit_size()`)이다.
- super block: 시그니처 `SPDK_BS_SUPER_BLOCK_SIG` = `"SPDKBLOB"`. `used_page_mask_start/len`, `used_cluster_mask_start/len`, `md_start` 등 비트맵과 메타데이터 영역 위치(페이지 단위)를 담는다.
- blob 메타데이터 페이지의 descriptor 유형: `SPDK_MD_DESCRIPTOR_TYPE_XATTR`, `_FLAGS`, `_XATTR_INTERNAL`, `_EXTENT_RLE`, `_EXTENT_TABLE`, `_EXTENT_PAGE`.
- API: `spdk_bs_init()`/`spdk_bs_load()`/`spdk_bs_unload()`, `spdk_bs_create_blob_ext()`(`struct spdk_blob_opts`의 `thin_provision`, `esnap_id` 등), `spdk_bs_open_blob()`, `spdk_blob_resize()`, `spdk_blob_set_xattr()` + `spdk_blob_sync_md()`. I/O는 `spdk_bs_alloc_io_channel()`로 얻은 채널에 `spdk_blob_io_read()`/`_write()`/`_unmap()`으로 한다. 스냅샷·클론은 `spdk_bs_create_snapshot()`, `spdk_bs_create_clone()`, `spdk_bs_inflate_blob()`, `spdk_bs_blob_decouple_parent()`, 용량 확장은 `spdk_bs_grow()`/`spdk_bs_grow_live()`, `spdk_bs_blob_shallow_copy()`.
- bdev 연결: `spdk_bdev_create_bs_dev_ext()`(`include/spdk/blob_bdev.h`)가 bdev를 `struct spdk_bs_dev`로 감싼다.
- 씬 프로비저닝 쓰기: 할당되지 않은 cluster에 처음 쓸 때 cluster를 할당하고 메타데이터를 갱신해야 하므로 메타데이터 스레드로 메시지를 보낸다. 그래서 첫 쓰기는 비싸고, 이후 쓰기는 I/O 채널 경로만 탄다.

**lvol** (`include/spdk/lvol.h`): lvolstore는 blobstore 하나이고 lvol은 blob 하나다. `spdk_lvs_init()`, `spdk_lvs_load()`, `spdk_lvs_grow()`, `spdk_lvol_create()`, `spdk_lvol_create_snapshot()`, `spdk_lvol_create_clone()`, `spdk_lvol_inflate()`, external snapshot 기반 `spdk_lvol_create_esnap_clone()`, `spdk_lvol_set_parent()`, `spdk_lvol_set_external_parent()`, `spdk_lvol_shallow_copy()`가 있다. esnap clone은 다른 bdev(예: 읽기 전용 골든 이미지)를 부모로 삼는다. blobstore IO 채널은 esnap 장치용 채널 트리를 따로 유지한다(Blobstore 문서).

**blobfs**: blobstore 위 평면 파일 이름 공간 + 캐시였다. RocksDB `Env` 플러그인과 FUSE 마운트(`blobfs_mount` RPC, v19.10)를 제공했지만 **v25.09에서 deprecated 상태로 제거**됐다. RocksDB 플러그인도 같은 릴리스에서 제거됐다.

### 4.9 커널 대비 비교

| 관점 | Linux nvme-pci + blk-mq | SPDK lib/nvme + lib/bdev |
|---|---|---|
| 요청 객체 | `struct request`(태그셋에서 할당) + `struct nvme_iod` | `spdk_bdev_io`(스레드 캐시 256) → `nvme_request` → qpair의 `nvme_tracker` |
| 큐 선택 | CPU → hctx 매핑 | 호출 스레드의 io_channel이 가진 qpair |
| PRP/SGL | `nvme_map_data()`, DMA API(IOMMU IOVA 할당) | `nvme_pcie_prp_list_append()` 등, 사전 등록된 `spdk_vtophys()` 변환 |
| doorbell | `nvme_write_sq_db()`(bd->last 배치) | `delay_cmd_submit`, shadow doorbell, CQ 배치 갱신 |
| 자원 부족 | `BLK_STS_RESOURCE` → 재실행 | `SPDK_BDEV_IO_STATUS_NOMEM` → `nomem_io` → `bdev_ch_retry_io()` |
| 볼륨 관리 | dm/LVM, 파일시스템 | lvol(blobstore), raid, split, gpt |
| 프로세스 공유 | 모든 프로세스 | 같은 shm_id 그룹만 (primary/secondary) |
| 핫 제거 | PCI 서브시스템 + 드라이버 remove | `remove_cb`, SIGBUS 핸들러로 BAR 재매핑, `SPDK_BDEV_EVENT_REMOVE` |

---

## 5. Primary References

- [NVMe Driver](https://spdk.io/doc/nvme.html): 수동적 드라이버, qpair 스레드 규칙, tracker 메모리, multi-process, hotplug, CUSE
- [Block Device User Guide](https://spdk.io/doc/bdev.html): bdev 모듈 구성, uring 빌드 옵션
- [Writing a Custom Block Device Module](https://spdk.io/doc/bdev_module.html): 모듈 API
- [Blobstore Programmer's Guide](https://spdk.io/doc/blob.html): 계층, 원자성, 메타데이터 스레드, esnap
- [Direct Memory Access (DMA) From User Space](https://spdk.io/doc/memory.html): PRP 제약, pinning
- [User Space Drivers](https://spdk.io/doc/userspace.html): BAR 매핑, 폴링, 큐-스레드 배정
- [JSON-RPC](https://spdk.io/doc/jsonrpc.html): `bdev_xnvme_create`, `bdev_nvme_attach_controller` 등
- [Flash Translation Layer](https://spdk.io/doc/ftl.html): FTL bdev
- 소스: [include/spdk/nvme.h](https://github.com/spdk/spdk/blob/master/include/spdk/nvme.h), [lib/nvme/nvme_pcie_common.c](https://github.com/spdk/spdk/blob/master/lib/nvme/nvme_pcie_common.c), [lib/nvme/nvme.c](https://github.com/spdk/spdk/blob/master/lib/nvme/nvme.c), [include/spdk/bdev_module.h](https://github.com/spdk/spdk/blob/master/include/spdk/bdev_module.h), [lib/bdev/bdev.c](https://github.com/spdk/spdk/blob/master/lib/bdev/bdev.c), [include/spdk/blob.h](https://github.com/spdk/spdk/blob/master/include/spdk/blob.h), [module/bdev/xnvme/bdev_xnvme.c](https://github.com/spdk/spdk/blob/master/module/bdev/xnvme/bdev_xnvme.c), [CHANGELOG.md](https://github.com/spdk/spdk/blob/master/CHANGELOG.md)
- [10.39M Storage I/O Per Second From One Thread](https://spdk.io/news/2019/05/06/nvme/) (2019-05-06): MMIO 최소화, 캐시 전략
- [I/O Passthru: Upstreaming a flexible and efficient I/O Path in Linux](https://www.usenix.org/conference/fast24/presentation/joshi) (FAST '24): xNVMe bdev, SPDK 비교
- [GitHub - xnvme/xnvme: xNVMe: cross-platform libraries and tools for NVMe devices](https://github.com/xnvme/xnvme)
- [4. Multi-process Support](https://doc.dpdk.org/guides/prog_guide/multi_proc_support.html) (DPDK 문서, primary/secondary)
