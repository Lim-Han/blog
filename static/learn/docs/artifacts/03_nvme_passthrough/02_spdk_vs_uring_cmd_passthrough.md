# SPDK 커널 바이패스와 io_uring `uring_cmd` NVMe 패스스루: 무엇을 우회하고 무엇을 남겼나

> 기준 소스: Linux 7.3-rc7 (`torvalds/linux` master, 2026-10 확인) `drivers/nvme/host/{ioctl.c,pci.c,core.c,multipath.c}`, `include/uapi/linux/{nvme_ioctl.h,io_uring.h}`. 논문 수치는 Joshi et al., FAST '24 본문(Table 3 실험 환경)에서 그대로 옮겼다. SPDK 사실관계는 spdk.io 공식 문서 기준이다.

## 1. Verdict

NVMe I/O Passthru는 "커널을 통째로 우회하는 SPDK"와 "모든 계층을 거치는 블록 I/O" 사이에 놓인 **세 번째 경로**다. `/dev/ngXnY` 문자 디바이스로 열고, `IORING_OP_URING_CMD`로 NVMe 명령을 그대로 넘긴다. 이 경로가 "블록 계층, `request_queue`까지 완전 우회"한다는 설명이 흔하지만 **틀렸다.** `nvme_uring_cmd_io()`는 `nvme_alloc_user_request()` → `blk_mq_alloc_request()`로 blk-mq 태그와 `struct request`를 할당하고, `blk_execute_rq_nowait()`로 blk-mq 디스패치를 통해 `nvme_queue_rq()`에 도달한다. 우회하는 것은 다음 세 가지뿐이다.

1. VFS/파일시스템·페이지 캐시·파티션 계층 (문자 디바이스이므로)
2. bio 분할·병합(`bio_split_to_limits()`, plug merge)과 I/O 스케줄러. 패스스루 명령은 `REQ_OP_DRV_IN/OUT`이라 병합 대상이 아니다.
3. 블록 계층의 "장치 한계 추상화". 패스스루는 장치의 MDTS를 넘는 명령을 쪼개 주지 않는다.

FAST '24 논문(Joshi et al., Samsung·Meta) 스스로도 4.4절 "Block layer: To bypass or not"에서 "Does NVMe passthrough mean bypassing the block layer? It is a common misconception."이라고 쓴다. 남는 블록 계층 기능은 태그 관리, 코어-큐 매핑, 타임아웃/abort다.

성능 결론도 흔히 인용되는 "SPDK 대비 99%"와 다르다. 논문에는 그런 수치가 없다. 논문 7.3절의 측정 조건과 결과는 다음과 같다. 환경은 AMD Ryzen 9 5900X, Intel Optane P5800X 400GB, Linux 6.2, fio 3.35, 512B 랜덤 읽기다.

- **장치당 코어 1개, 장치 2개**: 블록 경로 7.55M IOPS, 패스스루와 SPDK는 모두 10M IOPS(장치 포화).
- **코어 1개로 장치 2개**: SPDK는 두 장치를 계속 포화시킨다. 블록 4.4M, 패스스루 6M IOPS. 추가 커널 설정 변경(강제 선점 끄기, `HZ=100`, wbt·blk-cgroup 제거) 후에도 블록 7.9M, 패스스루 8.3M에 그친다.
- 논문 결론: "I/O Passthru reduces the per-core efficiency gap but is still far from kernel-bypass solutions like SPDK."

즉 장치가 병목인 구성에서는 패스스루가 SPDK와 같은 처리량을 낸다. 하지만 **코어당 효율**에서는 여전히 SPDK가 앞선다. 패스스루의 가치는 이 효율 격차를 상당 부분 줄이면서도 표준 파일 권한·멀티 프로세스 공유·커널 드라이버의 오류 처리를 유지한다는 데 있다.

---

## 2. Problem Statement

### 2.1 블록 인터페이스로 표현할 수 없는 NVMe
NVMe는 더 이상 블록 읽기/쓰기만 하는 프로토콜이 아니다. ZNS(Zone Append), FDP(Flexible Data Placement, placement handle 지정), KV 명령 세트, 계산 스토리지, 엔드투엔드 PI 메타데이터처럼 블록 계층이 추상화하지 못하거나 추상화가 늦게 따라오는 기능이 계속 늘어난다. 새 기능마다 블록 계층·파일시스템 인터페이스를 거쳐 커널에 올리면 수년이 걸린다. 논문 서론이 지적한 문제도 이것이다.

### 2.2 기존 탈출구 1: 동기 ioctl 패스스루
커널은 오래전부터 `NVME_IOCTL_IO_CMD`(`struct nvme_passthru_cmd`), `NVME_IOCTL_IO64_CMD`, 그리고 벡터형 `NVME_IOCTL_IO64_CMD_VEC`을 제공했다. 논문 3.1절이 정리한 한계는 다음과 같다.
- **블록 디바이스에 묶여 있다.** `/dev/nvmeXnY` 블록 디바이스가 만들어지지 않으면(지원하지 않는 LBA 포맷, 블록 계층이 모르는 명령 세트 등) 쓸 수 없다.
- **동기·블로킹이다.** ioctl 기반 읽기는 큐 깊이를 늘려도 IOPS가 평평하게 머문다(논문 Figure 3). 비동기를 흉내 내려면 스레드를 큐 깊이만큼 띄워야 한다.
- 명령과 결과를 매번 `copy_from_user`/`put_user`로 복사해야 한다.
- **root 전용이다.** `CAP_SYS_ADMIN`이 필요했다.

ioctl 경로가 SPDK 대비 몇 % 수준인지를 보여 주는 1차 출처 수치는 찾지 못했다 `[추측/미확인]`. 논문 Figure 3은 io_uring 대비 ioctl이 큐 깊이에 따라 확장되지 않는다는 정성적 비교다.

### 2.3 기존 탈출구 2: SPDK 사용자 공간 드라이버
SPDK NVMe 드라이버는 `vfio-pci`(또는 `uio_pci_generic`)로 장치를 커널 드라이버에서 떼어 낸다. 그다음 BAR를 프로세스에 매핑해 MMIO로 doorbell을 직접 쓰고 CQ를 폴링한다. SPDK 문서는 이를 "entirely passive, meaning that it spawns no threads"한 C 라이브러리라고 설명한다. 대가는 다음과 같다.
- **장치 독점.** 장치가 커널에서 분리되므로 같은 SSD를 커널 파일시스템과 나눠 쓸 수 없다.
- **멀티 프로세스는 제한적으로만 가능하다.** "절대 불가"는 아니다. SPDK NVMe 문서의 "NVMe Multi Process" 절에 따르면 같은 shared memory group ID(`-i`/`shm_id`)를 쓰는 프로세스끼리는 primary/secondary로 컨트롤러를 공유할 수 있다. 단 "Two processes sharing memory may not share any cores in their core mask."라는 제약이 있다.
- **유휴 CPU 100%는 기본 동작일 뿐이다.** "항상 100%"는 아니며, SPDK에는 interrupt 모드(`--interrupt-mode`)와 dynamic scheduler가 있다. 단 모든 구성요소가 interrupt를 지원해야 한다(SPDK Interrupt Mode 문서).
- **관측성 단절.** `iostat`, blktrace, 블록 트레이스포인트에 보이지 않는다. SPDK 자체 도구(`spdk_top`, `spdk_trace`)로 대신해야 한다.
- **권한 모델.** VFIO/IOMMU group 설정과 hugepage 예약이 필요하고, 일반 사용자 권한으로는 사실상 운용할 수 없다.

### 2.4 요구사항
정리하면 필요한 것은 (a) 블록 디바이스와 무관하게 NVMe 명령을 직접 내리고, (b) io_uring 수준의 비동기·배치·폴링 효율을 갖고, (c) 파일 권한으로 비특권 사용자에게도 열 수 있으며, (d) 커널 드라이버의 큐·타임아웃·리셋 처리를 그대로 쓰는 경로였다. 이것이 `/dev/ngXnY` + `IORING_OP_URING_CMD` 설계의 출발점이다.

---

## 3. The Debate

아래 인용은 LKML/linux-nvme 아카이브에서 본문과 Message-ID를 확인한 것이다.

### 3.1 2021년 1월: "async ioctl"로 시작해 범용 `uring_cmd`로
Kanchan Joshi(Samsung)는 2021-01-27에 "[RFC PATCH 0/4] Asynchronous passthrough ioctl"을 올렸다(`20210127150029.13766-1-joshi.k@samsung.com`). 첫 설계는 새 opcode `IORING_OP_IOCTL_PT`와 블록 디바이스 연산 `async_ioctl`을 추가하는 것이었다. 커버 레터는 이 경로가 "made to skip the block-layer and reach directly to the underlying driver"라고 적었다. Pavel Begunkov는 바로 Jens Axboe의 `io_uring-fops` 브랜치를 가리키며 그 논의를 되살리자고 답했다. Axboe는 블록 디바이스 전용이 아닌 범용 경로를 주장했다.

> "Right, it's meant to span wider than just block devices. ... I do think that's the way forward in providing controlled access to what is basically async ioctls."
>
> — Jens Axboe, 2021-01-28 (`2d37d0ca-5853-4bb6-1582-551b9044040c@kernel.dk`)

완료 처리에서도 Axboe는 드라이버가 task_work를 직접 만지지 말고 io_uring 헬퍼에 맡기라고 했다.

> "For this use case, we should ensure that just io_uring handles this part. ... Could be done by having an io_uring helper ala: io_uring_cmd_complete_in_task(cmd, handler);"
>
> — Jens Axboe, 2021-01-28 (`6d847f4a-65a5-bc62-1d36-52e222e3d142@kernel.dk`)

이 제안은 실제 API가 되었다. 현재 NVMe 드라이버는 그 후신인 `io_uring_cmd_do_in_task_lazy(ioucmd, nvme_uring_task_cb)`를 쓴다.

### 3.2 명령 크기 문제와 Big SQE
가장 실질적인 쟁점은 "NVMe 명령을 SQE 안에 넣을 수 있는가"였다. 당시 `io_uring-fops` 설계에서 명령 전용 공간은 48바이트였고 Axboe가 56바이트로 늘렸다. Joshi는 2021-02-22에 이렇게 답했다(`CA+1E3rJqtpfDbKVGBjSYhX=WfzZ2bE8b0U3drUNz_=bp0u9Vuw@mail.gmail.com`). "nvme_user_io is 48 bytes, while nvme passthrough requires 72 or 80 bytes (passthru with 64 bit result)." 그러면서 "large-cmd" 지원 작업에 들어갔다.

해법은 2022-03-08의 "[PATCH 00/17] io_uring passthru over nvme"에서 나왔다(`20220308152105.309618-1-joshi.k@samsung.com`). Axboe의 "io_uring: add support for 128-byte SQEs" 패치가 포함됐다.

> "To store the command inline within the sqe, Jens added an option to setup the ring with 128-byte SQEs.This gives 80 bytes of space (16 bytes at the end of the first sqe + 64 bytes in the second sqe)."
>
> — Kanchan Joshi, 2022-03-08 ([linux-nvme 아카이브](https://lists.infradead.org/pipermail/linux-nvme/2022-March/030314.html))

"0~63바이트는 io_uring 헤더, 64~127바이트에 64B `nvme_uring_cmd`"라는 식의 설명은 틀렸다. `sqe->cmd`는 오프셋 48에서 시작하고(첫 SQE 뒤쪽 16바이트 + 둘째 SQE 64바이트 = 80바이트), `struct nvme_uring_cmd`는 72바이트다. 같은 커버 레터에는 Samsung 측 512B randread 측정(QD 256에서 uring 1043K vs 패스스루 1230K IOPS, 폴링 시 1376K vs 1429K)이 있다. 단 장치·CPU 조건이 명시되지 않은 예비 수치다. 이 시리즈에는 Keith Busch의 "nvme: allow user passthrough commands to poll", Anuj Gupta의 fixed-buffer 패치도 함께 있었다. 2022-03-10에 Christoph Hellwig는 "What branch is this against?"라며 기반 트리를 물었고, 이후 리뷰를 거쳐 5.19에서 `IORING_OP_URING_CMD`와 NVMe 패스스루가, 6.1에서 폴링·fixed buffer가 들어왔다(논문 Table 2).

### 3.3 왜 블록 디바이스가 아니라 문자 디바이스인가
`/dev/ngXnY`는 io_uring 패스스루보다 먼저 5.13에서 들어왔다. Minwoo Im의 "nvme: introduce generic per-namespace chardev"(V2 커버 `20210406064841.103393-1-minwoo.im.dev@gmail.com`)는 Javier González(Samsung)의 앞선 시리즈를 바탕으로 다시 짠 것이다. 동기는 "블록 디바이스가 제대로 초기화되지 않은 네임스페이스에도 I/O를 하자"였다. 블록 계층이 지원하지 않는 포맷이나 명령 세트를 가진 네임스페이스는 `nvmeXnY`가 생기지 않거나 0 용량이 되는데, 문자 디바이스는 그와 무관하게 만들어진다. 멀티패스 환경에서는 숨은 경로(`nvmeXcYnZ`)마다 노출하지 않고 헤드에만 `ngXnY`를 만든다. 이때 I/O는 서브시스템 iopolicy가 고른 컨트롤러로 간다. Christoph Hellwig가 이 설계를 주도했다는 근거는 찾지 못했다. 그의 역할로 확인되는 것은 V3가 hch의 ioctl 정리 위에 리베이스되었다는 점 정도다 `[추측/미확인: V3 커버 레터 미대조]`.

### 3.4 비특권 접근(6.2)과 보안 논쟁
패스스루를 일반 사용자에게 여는 것은 6.2에서야 이뤄졌다(논문 Table 2). 현재 `nvme_cmd_allowed()`/`nvme_ns_cmd_allowed()`의 규칙은 다음과 같다.
- 파티션 경유, vendor-specific(`>= nvme_cmd_vendor_start`) 또는 fabrics 명령은 `CAP_SYS_ADMIN`이 필요하다.
- 컨트롤러의 Commands Supported and Effects 로그가 해당 opcode를 `NVME_CMD_EFFECTS_CSUPP`로 표시하지 않으면 거부한다.
- CSUPP/LBCC/UUID_SEL/SCOPE 외의 효과(예: 네임스페이스·컨트롤러 상태 변경)가 있는 명령도 거부한다.
- 쓰기 방향이거나 LBCC(논리 블록 내용 변경) 명령은 파일을 쓰기 모드로 연 경우에만 허용한다.

즉 "파일 권한 = 명령 권한"을 그대로 대응시키지 않고, 장치가 자기 신고한 명령 효과를 근거로 허용 범위를 좁혔다. SPDK에는 이에 해당하는 커널 측 중재가 없다. VFIO로 장치를 넘긴 순간 그 프로세스가 모든 명령을 낼 수 있다.

### 3.5 SPDK 진영과의 관계: 경쟁에서 수렴으로
SPDK 쪽도 커널 경로를 받아들였다. 논문 5.2절에 따르면 xNVMe bdev가 SPDK 22.09부터 들어왔고, 이 bdev 하나로 AIO·io_uring·`io_uring_cmd` 백엔드를 전환한다. fio에는 3.31부터 `io_uring_cmd` ioengine(`cmd_type=nvme`)이 있다. 반대로 논문은 SPDK가 앞서는 이유를 셋으로 든다. (1) 장치 독점이라 공유·동기화 코드가 없다. (2) 패스스루는 하드웨어 큐 추상화·태그·타임아웃 같은 블록 계층 기능을 쓰므로 그만큼 처리가 늘어난다. (3) wbt·blk-cgroup처럼 패스스루에 맞지 않는 기능이 경로에 끼어 있었다(논문은 6.8부터 패스스루에서 이를 건너뛴다고 적음).

---

## 4. Implementation Impact

### 4.1 uAPI 레이아웃 (Linux 7.3-rc7 `include/uapi/linux/nvme_ioctl.h`)
`struct nvme_uring_cmd`는 72바이트이며 128바이트 SQE의 `sqe->cmd`(오프셋 48, 가용 80바이트)에 그대로 들어간다.

| 오프셋 | 필드 | 의미 |
|---|---|---|
| 0 | `__u8 opcode`, `__u8 flags`, `__u16 rsvd1` | NVMe CDW0 일부 (CID는 커널이 채움) |
| 4 | `__u32 nsid` | 네임스페이스 ID |
| 8 | `__u32 cdw2`, `cdw3` | |
| 16 | `__u64 metadata` | 메타데이터 버퍼 사용자 주소 |
| 24 | `__u64 addr` | 데이터 버퍼 주소 (`_VEC`이면 iovec 배열) |
| 32 | `__u32 metadata_len`, `data_len` | |
| 40 | `__u32 cdw10` ~ `cdw15` | 명령별 인자 |
| 64 | `__u32 timeout_ms`, `__u32 rsvd2` | 명령별 타임아웃 (0이면 기본값) |

- `cmd_op`(SQE의 별도 필드)는 `NVME_URING_CMD_IO`, `NVME_URING_CMD_IO_VEC`, `NVME_URING_CMD_ADMIN`, `NVME_URING_CMD_ADMIN_VEC` 중 하나다. 이 값은 리터럴 0x80~0x83이 아니라 `_IOWR('N', 0x80~0x83, struct nvme_uring_cmd)`로 인코딩된 ioctl 번호다.
- 완료는 32바이트 CQE(`IORING_SETUP_CQE32`)의 `res`에 NVMe 상태가, `big_cqe[0]`에 64비트 `result`(CQE DW0/DW1)가 들어간다. `result0`/`result1` 같은 별도 필드는 존재하지 않는다.
- `nvme_uring_cmd_checks()`는 `IO_URING_F_SQE128`과 `IO_URING_F_CQE32`가 둘 다 세워져 있지 않으면(하나라도 빠지면) `-EOPNOTSUPP`를 돌려준다. 6.18에서 `IORING_SETUP_CQE_MIXED`, 6.19에서 `IORING_SETUP_SQE_MIXED`와 `IORING_OP_URING_CMD128`이 uapi에 추가되었다(각 태그의 `io_uring.h` 비교로 확인). 그 결과 링 전체를 128B로 만들지 않고 해당 SQE만 128B로 낼 수 있다. `io_uring/uring_cmd.c`는 `IORING_OP_URING_CMD128`에도 `IO_URING_F_SQE128`을 세운다.

### 4.2 제출 콜패스
```
io_uring_enter() / SQPOLL
 └ io_uring_cmd()                        # io_uring/uring_cmd.c
    ├ security_uring_cmd(ioucmd)          # LSM 훅
    ├ issue_flags |= SQE128 / CQE32 / (IOPOLL이면 REQ_F_IOPOLL)
    └ file->f_op->uring_cmd()
       = nvme_ns_chr_uring_cmd()          # /dev/ngXnY (헤드면 nvme_ns_head_chr_uring_cmd)
         └ nvme_ns_uring_cmd() → nvme_uring_cmd_io()
            ├ SQE 필드를 READ_ONCE()로 한 번씩만 읽어 struct nvme_command 구성
            ├ nvme_cmd_allowed()           # 3.4절 권한 규칙
            ├ IORING_URING_CMD_FIXED → io_uring_cmd_import_fixed{,_vec}()  # 등록 버퍼
            ├ IO_URING_F_NONBLOCK → BLK_MQ_REQ_NOWAIT, IO_URING_F_IOPOLL → REQ_POLLED
            ├ nvme_alloc_user_request()
            │   └ blk_mq_alloc_request(q, REQ_OP_DRV_IN/OUT | flags)   # blk-mq 태그 할당
            ├ nvme_map_user_request()
            │   └ blk_rq_map_user_io() / blk_rq_map_user_iov(), blk_rq_integrity_map_user()
            ├ req->timeout = timeout_ms, req->end_io = nvme_uring_cmd_end_io
            └ blk_execute_rq_nowait(req, false) → return -EIOCBQUEUED
               └ blk-mq dispatch → nvme_queue_rq()  (PCIe: drivers/nvme/host/pci.c)
```
SQE를 `READ_ONCE()`로 읽는 이유는 SQE가 사용자와 공유된 메모리이기 때문이다. 검사 후 값이 바뀌는 TOCTOU를 막으려고 각 필드를 한 번만 읽어 커널 사본에 담는다. 참고로 `nvme_uring_cmd()`라는 함수는 없고(`nvme_uring_cmd`는 uAPI 구조체 이름이다), 사용자 버퍼 매핑에 `bio_map_user_iov()`도 쓰지 않는다.

### 4.3 완료 콜패스와 폴링
`nvme_uring_cmd_end_io()`는 NVMe 상태와 64비트 result를 `struct nvme_uring_cmd_pdu`에 저장한다. 이후 두 갈래로 나뉜다.
- 폴링 요청(`blk_rq_is_poll()`)이고 완료가 같은 링 컨텍스트의 `io_comp_batch` 안에서 일어나면(`iob->poll_ctx == io_uring_cmd_ctx_handle()`) 그 자리에서 `blk_rq_unmap_user()` 후 `io_uring_cmd_done32()`를 호출한다.
- 그 밖(IRQ 완료 등)은 `io_uring_cmd_do_in_task_lazy(ioucmd, nvme_uring_task_cb)`로 제출자 태스크에서 마무리한다. 사용자 버퍼 언맵(`blk_rq_unmap_user`)은 제출자 mm 컨텍스트가 필요하기 때문이다.

IOPOLL 링에서는 io_uring이 `f_op->uring_cmd_iopoll` = `nvme_ns_chr_uring_cmd_iopoll()`을 호출한다. 이 함수는 pdu에 저장된 `struct request`에 대해 `blk_rq_poll()`을 부른다. 논문 4.2.4절은 큐 ID와 명령 ID를 합친 4바이트 cookie 방식을 설명하지만, 현재 master는 request 포인터를 직접 들고 `blk_rq_poll()`로 폴링한다. 논문이 적은 모듈 파라미터 이름 `polled_queues`도 실제로는 `nvme.poll_queues`다.

### 4.4 PCIe 드라이버 내부 (`drivers/nvme/host/pci.c`)
패스스루든 블록 I/O든 `nvme_queue_rq()` 이후는 같다.
- **`nvme_queue_rq()`**: `NVMEQ_ENABLED`와 `nvme_check_ready()`를 확인한 뒤 `nvme_prep_rq()`를 부른다. 이 함수는 `nvme_setup_cmd()`로 CID를 부여하고, `nvme_map_data()`/`nvme_map_metadata()`로 DMA를 매핑하고, `nvme_start_request()`로 타임아웃 타이머를 건다. 그다음 `nvmeq->sq_lock` 아래에서 `nvme_sq_copy_cmd()`가 64B 명령을 `sq_cmds + (sq_tail << sqes)`에 memcpy한다. `nvme_write_sq_db(nvmeq, bd->last)`는 배치의 마지막(`bd->last`)일 때만 doorbell을 `writel()`한다. 중간 요청의 doorbell은 `nvme_commit_rqs()`가 몰아서 친다. 5.17 이후 `queue_rqs` 경로(`nvme_queue_rqs()` → `nvme_submit_cmds()`)는 plug 리스트 전체를 한 번의 락·한 번의 doorbell로 보낸다.
- **Shadow doorbell**: `nvme_dbbuf_update_and_check_event()`는 Doorbell Buffer Config(주로 에뮬레이션 컨트롤러)를 지원하면 shadow 값만 갱신한다. 그리고 eventidx를 넘었을 때만 MMIO를 쓴다.
- **PRP vs SGL**: `nvme_pci_use_sgls()`는 I/O 큐에서 컨트롤러가 SGL을 지원할 때 세 경우에 SGL을 강제(`SGL_FORCED`)한다. (1) 페이지 간격(gap)이 있어 PRP로 표현할 수 없을 때, (2) **`NVME_REQ_USERCMD`, 즉 패스스루 명령일 때**(장치가 전송 길이를 검증할 수 있도록), (3) 무결성 세그먼트가 2개 이상일 때다. 그 밖에는 평균 세그먼트 크기가 `sgl_threshold`(기본 `SZ_32K`) 이상이면 SGL, 아니면 PRP를 쓴다. 단일 세그먼트는 `nvme_pci_setup_data_simple()`로 DMA iterator를 건너뛴다. 따라서 SGL을 지원하는 SSD에서는 같은 4KB 읽기라도 패스스루와 블록 경로의 데이터 디스크립터 형식이 다를 수 있다.
- **CQ phase**: `nvme_cqe_pending()`은 `hcqe->status`의 bit 0(phase tag)이 `nvmeq->cq_phase`와 같은지로 새 CQE를 판별한다. `nvme_poll_cq()`는 phase 확인과 CQE 본문 읽기 사이에 `dma_rmb()`를 두고, `nvme_update_cq_head()`는 head가 `q_depth`에 닿으면 0으로 돌리며 `cq_phase ^= 1`로 뒤집는다. 처리한 CQE가 있으면 마지막에 `nvme_ring_cq_doorbell()`을 한 번 친다.
- **Poll queue**: `nvme.poll_queues=N`으로 만든 큐는 `nvme_create_queue(..., polled=true)`에서 `NVME_CQ_IRQ_ENABLED` 없이 생성되고 `NVMEQ_POLLED`가 세워진다. 즉 **IRQ가 없다.** blk-mq의 `HCTX_TYPE_POLL` 맵에 붙고, `REQ_POLLED` 요청만 이 큐로 간다. `nvme_poll()`은 `cq_poll_lock`을 잡고 `nvme_poll_cq()`를 돈다. 일반 큐는 `nvme_irq()`에서 CQE를 배치로 처리한다. `nvme.write_queues`로 읽기/쓰기 큐를 분리할 수도 있다.

### 4.5 블록 계층 기능: 블록 I/O vs 패스스루 (논문 Table 1 + 소스 확인)

| 기능 | io_uring 블록 경로 (`/dev/nvmeXnY`) | io_uring 패스스루 (`/dev/ngXnY`) | SPDK NVMe PCIe 드라이버 |
|---|---|---|---|
| VFS/파일시스템/파티션 | 거침 (`blkdev_read_iter` 등) | 없음 (문자 디바이스) | 없음 |
| bio 분할·병합 | `bio_split_to_limits()`, plug merge | 없음, MDTS 초과는 장치 오류 | 없음 (`spdk_nvme_ns_cmd_*`이 자체 분할) |
| I/O 스케줄러 | 설정 시 거침 | 건너뜀 | 없음 |
| blk-mq 태그·코어-큐 매핑 | 있음 | **있음** (`blk_mq_alloc_request`) | 자체 qpair, CID 관리 |
| 타임아웃·abort·컨트롤러 리셋 | 전역 타임아웃 | 명령별 `timeout_ms` | 애플리케이션 책임 (`spdk_nvme_ctrlr_register_timeout_callback`) |
| 데이터 디스크립터 | PRP/SGL (`sgl_threshold`) | SGL 지원 시 SGL 강제 | 자체 PRP/SGL 구성 |
| 완료 | IRQ 또는 IOPOLL | IRQ 또는 IOPOLL (`uring_cmd_iopoll`) | CQ phase 폴링 (interrupt 모드 선택) |
| 권한 | 파일 권한 | 파일 권한 + 명령 효과 기반 제한 (6.2+) | VFIO 장치 소유자 = 전권 |
| 장치 공유 | 다수 프로세스·커널 FS | 다수 프로세스 (블록 디바이스와 공존) | 같은 `shm_id` 그룹 내에서만 |
| 관측성 | blktrace, `block:*` 트레이스포인트 | `nvme:nvme_setup_cmd`/`nvme_complete_rq` 트레이스포인트 | `spdk_trace`, `spdk_top` |

### 4.6 FAST '24 측정 결과 (조건 포함)
공통 조건: AMD Ryzen 9 5900X(12코어), DDR4 16GB, Intel Optane P5800X 400GB(사양 512B 랜덤 읽기 5M IOPS), Ubuntu 22.04, Linux 6.2, fio 3.35. "최적화 설정"은 `CONFIG_RETPOLINE`과 `CONFIG_PAGE_TABLE_ISOLATION`을 끈 커널이다.

| 실험 | 조건 | 블록 (io_uring) | 패스스루 (uring_cmd) | SPDK |
|---|---|---|---|---|
| 단일 코어 피크, 기본 설정 | t/io_uring 1코어, 512B randread, QD128, batch 32, FB+Poll | 2.9M | 3.9M (+35%) | – |
| 단일 코어 피크, 최적화 설정 | 동일 | 3.83M | 5M (+31%, 장치 포화) | – |
| 제출 핸들러 시간 | 최적화 설정 | `io_read` 209ns | `io_uring_cmd` 144ns | – |
| 큐 깊이 확장 | QD16 / QD128 | 기준 | +19% / +31% | – |
| SQPOLL | batch 2, SQPOLL 스레드 별도 코어 고정(`IORING_SETUP_SQ_AFF`) | – | SQPOLL 켜면 +136% | – |
| 장치 2개, 장치당 1코어 | SPDK perf | 7.55M | 10M | 10M |
| 장치 2개, 1코어 | SPDK perf | 4.4M | 6M | 두 장치 포화 |
| 위 + 추가 설정 | 강제 선점 끄기, `HZ=100`, wbt/blk-cgroup 제거 | 7.9M | 8.3M | 두 장치 포화 |

해석할 때 주의할 점이 있다.
- 512B 랜덤 읽기와 Optane은 소프트웨어 오버헤드를 최대한 드러내는 조건이다. NAND SSD의 4KB 이상 I/O에서는 장치가 먼저 병목이 되므로 경로 간 차이가 줄어든다.
- 저자들(Samsung·Meta)이 직접 제안한 경로를 평가한 논문이다.
- 1QD에서는 두 경로의 성능이 같다고 논문이 명시한다. 이득은 높은 큐 깊이에서 제출 경로가 가벼워서 나온다.

### 4.7 운영상 선택 기준
- **패스스루가 맞는 경우**: FDP placement ID, ZNS Zone Append, 벤더 독립 신규 명령 세트처럼 블록 계층이 아직 표현하지 못하는 기능을 쓰면서, 장치를 커널 FS나 다른 프로세스와 공유해야 할 때. 논문 7.2절은 CacheLib에 FDP를 패스스루로 적용한 사례를 다룬다.
- **SPDK가 맞는 경우**: 코어당 IOPS가 결정적이고 장치를 독점할 수 있을 때. 또는 NVMe-oF 타깃처럼 SPDK 생태계(bdev, nvmf, vhost) 전체를 쓰는 경우.
- **블록 경로가 맞는 경우**: 파일시스템, dm 계층, cgroup I/O 제어가 필요하거나, I/O가 MDTS를 넘어 자동 분할이 필요할 때.
- 패스스루는 장치 오류가 그대로 사용자에게 올라온다. 멀티패스 헤드(`ngXnY` on `ns_head`)를 통하더라도 `REQ_FAILFAST_DRIVER`가 붙어 failover 대상이 아니다(`nvme_alloc_user_request()` 주석). 재시도는 애플리케이션 책임이다.

### 4.8 연표

| 버전 | 내용 |
|---|---|
| 5.13 | `/dev/ngXnY` 문자 디바이스 (Minwoo Im, Javier González 시리즈 기반) |
| 5.19 | `IORING_OP_URING_CMD`, `IORING_SETUP_SQE128`/`CQE32`, NVMe uring 패스스루 |
| 6.0 | 문자 디바이스가 지원하지 않는 명령 세트(any command set)에도 생성 |
| 6.1 | 패스스루 폴링·fixed buffer |
| 6.2 | 비특권 패스스루 (명령 효과 기반) |
| 6.8 | 패스스루에서 wbt·blk-cgroup 처리 생략 (논문 서술) |
| 6.18 / 6.19 | `IORING_SETUP_CQE_MIXED` / `IORING_SETUP_SQE_MIXED`, `IORING_OP_URING_CMD128` |

---

## 5. Primary References

lore.kernel.org는 봇 차단으로 자동 검증이 안 된다. Message-ID와 작성자·날짜는 lkml.iu.edu 및 lists.infradead.org 아카이브 사본의 헤더와 대조했다.

- [I/O Passthru: Upstreaming a flexible and efficient I/O Path in Linux](https://www.usenix.org/conference/fast24/presentation/joshi) — Joshi et al., FAST '24 논문 개별 페이지
- [[RFC PATCH 0/4] Asynchronous passthrough ioctl](https://lore.kernel.org/all/20210127150029.13766-1-joshi.k@samsung.com/) — Kanchan Joshi, 2021-01-27 커버 레터
- [Re: [RFC PATCH 0/4] Asynchronous passthrough ioctl](https://lore.kernel.org/all/2d37d0ca-5853-4bb6-1582-551b9044040c@kernel.dk/) — Jens Axboe, 2021-01-28 ("span wider than just block devices")
- [Re: [RFC PATCH 0/4] Asynchronous passthrough ioctl](https://lore.kernel.org/all/6d847f4a-65a5-bc62-1d36-52e222e3d142@kernel.dk/) — Jens Axboe, 2021-01-28 (`io_uring_cmd_complete_in_task` 제안)
- [[PATCH V2 0/1] nvme: introduce generic per-namespace chardev](https://lore.kernel.org/all/20210406064841.103393-1-minwoo.im.dev@gmail.com/) — Minwoo Im, 2021-04-06
- [[PATCH 00/17] io_uring passthru over nvme](https://lore.kernel.org/all/20220308152105.309618-1-joshi.k@samsung.com/) — Kanchan Joshi, 2022-03-08 커버 레터
- [NVMe Subsystem](https://docs.kernel.org/nvme/index.html) — 커널 공식 NVMe 문서 색인
- [drivers/nvme/host/ioctl.c](https://github.com/torvalds/linux/blob/master/drivers/nvme/host/ioctl.c) — `nvme_uring_cmd_io()` 등 패스스루 구현 (GitHub 미러)
- [include/uapi/linux/nvme_ioctl.h](https://github.com/torvalds/linux/blob/master/include/uapi/linux/nvme_ioctl.h) — `struct nvme_uring_cmd` uAPI (GitHub 미러)
- [drivers/nvme/host/pci.c](https://github.com/torvalds/linux/blob/master/drivers/nvme/host/pci.c) — NVMe PCIe 드라이버 (GitHub 미러)
- [NVMe Driver](https://spdk.io/doc/nvme.html) — SPDK 문서, Multi Process·Character Devices 절
- [Interrupt Mode](https://spdk.io/doc/interrupt_mode.html) — SPDK interrupt 모드와 dynamic scheduler
- [module/bdev/xnvme/bdev_xnvme.c](https://github.com/spdk/spdk/blob/master/module/bdev/xnvme/bdev_xnvme.c) — SPDK xNVMe bdev 구현
