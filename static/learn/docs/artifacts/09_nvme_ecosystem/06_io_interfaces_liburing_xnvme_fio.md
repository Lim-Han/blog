# I/O 인터페이스 라이브러리와 측정: liburing 내부, xNVMe, fio ioengine, t/io_uring, 그리고 "코어당 IOPS"는 어떻게 측정되었나

> 기준: liburing master(최신 태그 `liburing-2.15`), fio master(최신 태그 `fio-3.43`), xNVMe main(최신 태그 `v0.7.5`), Linux master(7.3-rc7). 2026-10 확인. liburing 함수 이름은 `src/setup.c`, `src/queue.c`, `src/register.c`, `src/include/liburing.h`에서 grep으로 대조했다. io_uring 플래그의 도입 버전은 git.kernel.org에서 각 태그의 `include/uapi/linux/io_uring.h`를 받아 최초 등장 태그로 고정했다. io_uring 커널 내부(SQ 처리, `io_issue_sqe`, NVMe passthrough 경로)는 io_uring 도메인 문서(→ 01/01)와 NVMe passthrough 문서(→ 03/02)가 다루므로, 여기서는 **사용자 공간 라이브러리와 벤치마크 방법론**에 집중한다.

## 1. Verdict

NVMe의 성능을 소프트웨어에서 끌어내는 경로는 세 층으로 나뉜다. (1) 커널 인터페이스: `io_uring`, `libaio`(`io_submit`), `preadv2`, NVMe 문자 장치 passthrough(`IORING_OP_URING_CMD`), 커널 바이패스(SPDK, libvfn). (2) 그 위의 라이브러리: liburing, xNVMe. (3) 측정 도구: fio, t/io_uring, SPDK `perf`. 이 문서의 결론은 다음과 같다.

1. **liburing은 얇다. 성능을 좌우하는 것은 링 설정 플래그다.** `io_uring_get_sqe()`는 인라인 함수로, tail 증가와 SQE 초기화만 한다. `io_uring_submit()`은 SQ tail을 공개하고(`__io_uring_flush_sq()`), 필요할 때만 `io_uring_enter(2)`를 부른다(`sq_ring_needs_enter()`). 비용 차이는 `IORING_SETUP_SQPOLL`/`IOPOLL`/`SINGLE_ISSUER`/`DEFER_TASKRUN`, 등록 파일·버퍼, 등록 링 fd(`IORING_REGISTER_RING_FDS`, 5.18)에서 나온다.
2. **xNVMe는 "같은 NVMe 명령 API를 여러 백엔드에 실어 나르는" 추상 계층이다.** 핵심 단위는 128바이트 `struct xnvme_cmd_ctx`(NVMe 명령 `xnvme_spec_cmd` + 완료 `xnvme_spec_cpl` + 장치 + 비동기 필드)다. 같은 코드가 Linux `io_uring`/`io_uring_cmd`/`libaio`/`thrpool`/`emu`, SPDK, libvfn, FreeBSD, macOS, Windows 위에서 돈다. 백엔드는 `struct xnvme_opts`의 `be`/`async`/`sync`/`admin` 문자열로 고른다.
3. **fio의 io_uring 엔진은 liburing을 쓰지 않는다.** `engines/io_uring.c`는 `os/linux/io_uring.h`를 포함하고 시스템 콜을 직접 부른다. `t/io_uring`도 `__NR_io_uring_setup`/`__NR_io_uring_enter`를 직접 호출하는 독립 벤치마크다. "liburing 오버헤드"를 측정하려면 이 차이를 알아야 한다.
4. **논문과 메일링 리스트의 "코어당 IOPS"는 측정 조건이 제각각이다.** Jens Axboe가 2021-08 패치 커버 레터에 붙인 "3.5M+ IOPS per core"는 `t/io_uring -b512 -d128 -c32 -s32 -p1 -F1 -B1`, 즉 **512바이트 블록**, 폴링, 등록 파일·버퍼, 단일 코어(`taskset -c 0`)로 측정한 값이다(LWN 866114). 4KiB fio 결과와 직접 비교할 수 없다. Haas & Leis(VLDB 2023)는 64코어 AMD 서버와 PM1733 8개로 SPDK 4KiB 랜덤 읽기 12.5M IOPS를 측정했다(사양상 기대치 12M, SSD당 1.56M). 이 논문은 fio 자체가 병목이었다고 보고하며 자체 도구를 썼다. Ren & Trivedi(CHEOPS '23)도 "the benchmarking tool (fio) itself becomes a bottleneck"이라고 적었다.
5. **재현 가능한 측정의 최소 조건**은 다음과 같다. CPU 핀(`taskset`/`cpus_allowed`)과 NUMA 일치, 폴링 여부와 `nvme.poll_queues` 명시, 블록 크기·큐 깊이·배치 크기(`iodepth_batch_*`) 공개, 블록 계층 설정(`iostats`, `nomerges`, I/O 스케줄러) 공개, 쓰기 측정 시 사전 조건화(steady state), CPU 사용률(또는 코어 수) 동시 보고.

---

## 2. Problem Statement

### 2.1 시스템 콜 경계 비용이 장치 지연과 같은 규모가 되었다

Optane이나 최신 TLC NVMe의 4KiB 읽기 지연은 수 µs~수십 µs다. 동기 `pread()` 한 번에는 시스템 콜 진입/복귀, VFS, 블록 계층 요청 할당, 드라이버 doorbell, 인터럽트, 컨텍스트 스위치가 따른다. 투기 실행 완화(KPTI, retpoline 등)가 켜진 커널에서는 진입/복귀 비용만 해도 무시할 수 없다. 해법은 두 방향이다. **배치**(한 번의 진입으로 여러 I/O 제출·수거)와 **진입 회피**(SQPOLL 커널 스레드가 SQ를 폴링하거나, IOPOLL로 인터럽트 대신 완료 폴링)다. 커널 바이패스(SPDK)는 경계 자체를 없앤다.

### 2.2 libaio의 구조적 한계

`io_submit(2)`은 `O_DIRECT`가 아니면 사실상 동기적으로 동작한다. 메타데이터 조회나 요청 할당에서 블록될 수 있다. 완료 링(`struct aio_ring`)은 사용자 공간에 매핑되지만 제출 쪽에는 링이 없어, I/O마다 `struct iocb` 포인터 배열을 시스템 콜로 넘긴다. fio libaio 엔진의 `userspace_reap` 옵션은 `user_io_getevents()`로 `aio_ring`을 직접 읽어 `io_getevents(2)`를 피한다. 이는 libaio의 완료 경로가 사용자 공간 접근을 허용하는 유일한 지점이라는 뜻이다.

### 2.3 인터페이스 파편화

같은 NVMe 명령(예: ZNS Zone Append, FDP placement hint, 벤더 명령)을 내려면 경로마다 API가 다르다. 커널 블록 경로는 bio 플래그, ioctl passthrough는 `NVME_IOCTL_IO64_CMD`, io_uring passthrough는 `NVME_URING_CMD_IO`, SPDK는 `spdk_nvme_ns_cmd_*`, libvfn은 자체 API를 쓴다. 애플리케이션이 백엔드를 바꾸려면 I/O 계층을 다시 써야 한다. xNVMe는 이 문제를 해결하려고 Samsung의 Simon A. F. Lund 등이 만들었다(SYSTOR '22 "I/O interface independence with xNVMe").

### 2.4 측정의 신뢰성 문제

빠른 장치에서는 벤치마크 도구 자체가 CPU를 쓰고 캐시를 오염시킨다. 측정 결과가 도구의 구현 품질을 반영하게 된다. 같은 "io_uring" 결과라도 SQPOLL을 켰는지(별도 코어 소모), 폴링 큐가 있는지, 블록 크기가 512B인지 4KiB인지에 따라 수 배씩 달라진다. 논문 간 비교가 어려운 근본 원인이다(3절).

---
## 3. The Debate

### 3.1 "io_uring은 SPDK에 얼마나 가까운가": 연구마다 답이 다른 이유

| 연구 | 하드웨어 | 측정 도구 | 핵심 결론 | 결론을 좌우한 조건 |
|---|---|---|---|---|
| Didona et al., SYSTOR '22 "Understanding modern storage APIs" | 고성능 NVMe(세부는 논문 참조) | fio 등 | 폴링 설계가 성능을 크게 좌우한다. CPU 코어를 충분히 주면 io_uring이 SPDK에 근접한다. 다중 코어·다중 장치 확장에는 혼합 접근이 필요하다 [추측/미확인: 초록 원문(dl.acm.org)을 직접 확인하지 못함] | SQPOLL 스레드 수를 코어 수에 포함하는지 |
| Ren & Trivedi, CHEOPS '23 | Intel Optane SSD | fio | 저부하에서는 모든 API가 비슷하다(폴링은 1.7배 성능, 2.3배 명령어 수). 고부하·확장 시 io_uring이 SPDK보다 10배 이상 느리다. fio 자체가 병목이 된다. BFQ/mq-deadline/Kyber는 최대 50% 오버헤드를 낸다 | 스케줄러 설정, fio 한계 |
| Haas & Leis, VLDB 2023 "What Modern NVMe Storage Can Do..." | 64코어 AMD, Samsung PM1733 ×8 | 자체 도구(fio도 비교) | SPDK로 12.5M IOPS 측정(사양 기대치 12M, SSD당 1.56M). libaio와 인터럽트 기반 io_uring은 32스레드에서 최대 10M. 폴링 io_uring은 16스레드에서 근접. SPDK는 3스레드로 포화 | 파일 시스템·RAID·페이지 캐시 비활성화 |
| Joshi et al., FAST '24 "I/O Passthru" | AMD Ryzen 9 5900X, Optane P5800X ×2, Linux 6.2, 512B 랜덤 읽기 | io_uring(block/`io_uring_char`) 벤치마크, SPDK `perf` | 장치당 1코어면 passthru·SPDK 모두 약 10M. 1코어로 2장치를 돌리면 block 4.4M, passthru 6M, 튜닝 후 7.9M/8.3M, SPDK는 포화 | 커널 설정 튜닝 여부 |

(FAST '24 수치는 논문 7.3절 Figure 12 본문 기준이다. 장치별 1코어일 때 block 경로는 7.55M, passthrough와 SPDK는 10M IOPS다.)

해설: 결론이 엇갈리는 이유는 "코어"의 정의와 커널 설정 때문이다. SQPOLL은 제출 쪽 시스템 콜을 없애지만 커널 스레드가 코어 하나를 회전시킨다. 이 코어를 세지 않으면 io_uring의 코어당 IOPS가 부풀려진다. 반대로 블록 계층의 `iostats`, 스케줄러, 병합(merge) 시도를 기본값으로 두면 커널 경로가 불리해진다. Haas & Leis는 논문에서 다음과 같이 정리했다.

> "unless we use SPDK (which is not always a practical choice), around half of the available CPU cores are consumed by the OS just for submitting and reaping I/O requests."
> — Gabriel Haas, Viktor Leis, PVLDB 16(9), 2023 ([PVLDB PDF](https://www.vldb.org/pvldb/vol16/p2090-haas.pdf), DOI 10.14778/3598581.3598584)

해설: 이 문장은 64코어로 12M IOPS를 낼 때 I/O당 약 13k 사이클의 CPU 예산("2.5 GHz × 64 cores / 12 M IOPS")이 있다는 계산 위에 서 있다. 그중 절반이 커널 I/O 경로에 쓰이면 DBMS 작업에는 약 6,500 사이클만 남는다는 논지다. "IOPS 포화"보다 "I/O당 남는 CPU 사이클"이 응용에는 더 중요한 지표라는 주장이다.

### 3.2 "fio가 병목이다"

Haas & Leis 원문: "fio can be the bottleneck. [...] In particular, fio's implementation of interrupt-based I/O cannot achieve the full bandwidth with random 4 KB reads." Ren & Trivedi 초록: "(3) at high-loads and scale, the benchmarking tool (fio) itself becomes a bottleneck". fio는 범용 도구다. I/O마다 `struct io_u` 관리, 랜덤 오프셋 생성(`randrepeat`, `norandommap` 여부), 지연 통계(`clat`/`slat`/`lat` 히스토그램), 시간 측정(`gettimeofday`/`clock_gettime`, `gtod_reduce`)을 한다. 장치당 수백만 IOPS 영역에서는 이 비용이 커진다. Jens Axboe가 `t/io_uring`(fio 저장소 `t/` 아래 독립 프로그램)을 따로 유지하는 이유다. 반론도 있다. 실제 응용도 통계·스케줄링 비용을 내므로, 도구가 최소 비용만 쓰는 극단적 마이크로벤치마크는 "도달 가능한 상한"일 뿐이다. 응용 성능의 예측치로 읽으면 안 된다.

### 3.3 "코어당 수백만 IOPS"의 실체

LWN이 게재한 Axboe의 커버 레터(`[PATCHSET v5 0/6] Enable bio recycling for polled IO`, 2021-08-12, Message-ID `20210812154149.1061502-1-axboe@kernel.dk`)는 다음 출력을 담고 있다.

> "3.5M+ IOPS per core:
> axboe@amd ~/g/fio (master)> sudo taskset -c 0 t/io_uring -b512 -d128 -c32 -s32 -p1 -F1 -B1 /dev/nvme3n1
> [...]
> polled=1, fixedbufs=1, register_files=1, buffered=0 QD=128, sq_ring=128, cq_ring=256"
> — Jens Axboe, 2021-08-12 ([lwn.net/Articles/866114](https://lwn.net/Articles/866114/))

해설: 이 수치는 다음 조건을 모두 갖춘 상한이다. (1) `-b512`: 512바이트 블록이라 DMA·메모리 대역폭 부담이 4KiB의 1/8이다. (2) `-p1`: `IORING_SETUP_IOPOLL`로 인터럽트가 없다. (3) `-F1 -B1`: 등록 파일·고정 버퍼라 I/O마다 fd 참조 카운트와 페이지 핀이 생략된다. (4) `-s32 -c32`: 시스템 콜 한 번에 32개 제출·수거한다. (5) `taskset -c 0`: 단일 코어 고정이다. (6) 이 패치셋 자체가 bio 재활용으로 할당 비용을 줄이는 최적화다. 이후 커널 버전에서 수치는 계속 올라갔다. 그러나 메일링 리스트·SNS의 "코어당 XM IOPS"는 대부분 이런 조건의 `t/io_uring` 측정이다. 응용 수준 4KiB fio 수치와 같은 선상에 놓으면 안 된다.

### 3.4 추상화는 비용인가: liburing, xNVMe, 그리고 "직접 시스템 콜"

liburing의 핫패스는 대부분 `IOURINGINLINE` 함수(헤더 인라인)라서 호출 비용이 거의 없다. 그래도 fio와 t/io_uring은 직접 시스템 콜을 쓴다. 이유는 역사적인 것(두 도구가 liburing보다 먼저 생겼거나 동시에 개발되었다)과 새 커널 기능을 liburing 릴리스 전에 시험하려는 실용적인 것이다 `[추측/미확인: 의도에 대한 공식 설명은 확인하지 못함]`. xNVMe의 추상화 비용은 SYSTOR '22 논문이 백엔드별 오버헤드로 측정했다(세부 수치는 원문 참조, 이 문서에서는 미확인). Pestka, Paradies, Pohl의 arXiv 논문 "Asynchronous I/O -- With Great Power Comes Great Responsibility"(2024-11)는 반대 방향의 비용을 지적한다. io_uring 같은 현대 비동기 API의 채택률이 낮은 주된 이유가 응용에 가하는 복잡성이라는 것이다. 라이브러리 계층은 이 복잡성을 줄이는 대가로 일부 기능(예: 최신 링 플래그)을 늦게 노출한다.

---
## 4. Implementation Impact

### 4.1 링 설정과 메모리 레이아웃 (`src/setup.c`)

`io_uring_queue_init(entries, ring, flags)` → `io_uring_queue_init_params()` → `__io_uring_queue_init_params()`의 흐름은 다음과 같다.

1. `IORING_SETUP_NO_MMAP`(6.5)이면 `io_uring_alloc_huge()`로 링 메모리를 사용자 공간에서 먼저 할당한다(`INT_FLAG_APP_MEM`). 이 경로는 `io_uring_queue_init_mem()`으로도 노출된다.
2. `__sys_io_uring_setup(entries, p)`로 링 fd를 얻는다. 커널은 `struct io_uring_params`의 `sq_off`/`cq_off`에 각 필드의 오프셋을, `features`에 `IORING_FEAT_*` 비트를 채워 돌려준다.
3. `io_uring_queue_mmap()` → `io_uring_mmap()`이 세 영역을 `MAP_SHARED | MAP_POPULATE`로 매핑한다. SQ 링은 `IORING_OFF_SQ_RING`, CQ 링은 `IORING_OFF_CQ_RING`, SQE 배열은 `IORING_OFF_SQES`다. `IORING_FEAT_SINGLE_MMAP`(5.4)이면 SQ/CQ 링을 한 번의 mmap으로 공유하고 크기는 둘 중 큰 쪽으로 맞춘다.
4. `io_uring_setup_ring_pointers()`가 `khead`, `ktail`, `kflags`, `kdropped`, `array`(SQ 인덱스 배열), `cqes` 포인터를 설정한다. `IORING_SETUP_NO_SQARRAY`(6.6)면 SQ 간접 인덱스 배열이 없어지고 SQE를 tail 순서대로 소비한다. liburing은 커널이 지원하면 이 플래그를 기본으로 켜려고 시도한다(`io_uring_queue_init_try_nosqarr()`, `-EINVAL`이면 재시도).
5. `IORING_SETUP_REGISTERED_FD_ONLY`(6.5)면 링 fd를 처음부터 등록 인덱스로만 받는다. 이 경우 `ring->ring_fd = -1`이고 `INT_FLAG_REG_RING | INT_FLAG_REG_REG_RING`이 설정된다. `enter_ring_fd`는 이후 모든 `io_uring_enter` 호출에 쓰는 fd(또는 등록 인덱스)다.

`struct io_uring_sq`의 필드: `khead`, `ktail`(커널과 공유), `kflags`(`IORING_SQ_NEED_WAKEUP`, `IORING_SQ_CQ_OVERFLOW`, `IORING_SQ_TASKRUN`), `kdropped`, `array`, `sqes`, 그리고 사용자 공간 전용 `sqe_head`/`sqe_tail`, 캐시된 `ring_mask`/`ring_entries`(구 `kring_mask`/`kring_entries`는 deprecated). 사용자 공간 전용 head/tail을 따로 두기 때문에, `get_sqe`를 여러 번 불러도 커널은 `submit` 전까지 아무것도 보지 못한다.

`IORING_SETUP_SQE128`/`CQE32`(5.19)는 NVMe passthrough(`IORING_OP_URING_CMD`, 80바이트 명령 페이로드)와 ublk 제어 명령에 필요하다. 6.19의 `IORING_SETUP_SQE_MIXED`(태그별 헤더 grep 기준)는 한 링에서 64B/128B SQE를 섞어 쓰게 한다. liburing은 `io_uring_sqe_shift(ring)`으로 SQE 인덱스를 계산한다.

### 4.2 핫패스: get_sqe → submit → wait/peek → cqe_seen

```c
/* src/include/liburing.h (master) */
IOURINGINLINE struct io_uring_sqe *_io_uring_get_sqe(struct io_uring *ring)
	LIBURING_NOEXCEPT
{
	struct io_uring_sq *sq = &ring->sq;
	unsigned head = io_uring_load_sq_head(ring), tail = sq->sqe_tail;
	struct io_uring_sqe *sqe;

	if (tail - head >= sq->ring_entries)
		return NULL;

	sqe = &sq->sqes[(tail & sq->ring_mask) << io_uring_sqe_shift(ring)];
	sq->sqe_tail = tail + 1;
	io_uring_initialize_sqe(sqe);
	return sqe;
}
```

- **`io_uring_get_sqe()`**: 링이 가득 차면 `NULL`이다. 이때 응용은 `submit`으로 비우거나 `IORING_ENTER_SQ_WAIT`(`__io_uring_sqring_wait()`)를 써야 한다. `io_uring_load_sq_head()`는 SQPOLL이면 커널이 갱신하는 `khead`를 acquire로 읽는다.
- **`io_uring_submit()`** → `__io_uring_submit_and_wait(ring, 0)` → `__io_uring_flush_sq()` + `__io_uring_submit()`. `__io_uring_flush_sq()`는 `sqe_tail`을 `*sq->ktail`에 공개한다. SQPOLL이 아니면 일반 store를 쓴다. 이어지는 `io_uring_enter` 시스템 콜 자체가 배리어 역할을 하기 때문이다. SQPOLL이면 `io_uring_smp_store_release()`를 쓴다. 커널 스레드가 동시에 읽기 때문이다. 반환값은 `tail - *khead`, 즉 아직 커널이 소비하지 않은 SQE 수다.
- **`sq_ring_needs_enter()`**: SQPOLL이 아니면 항상 진입한다. SQPOLL이면 `io_uring_smp_mb()` 후 `*sq->kflags & IORING_SQ_NEED_WAKEUP`일 때만 `IORING_ENTER_SQ_WAKEUP`을 붙여 진입한다(4.3절). 7.0의 `IORING_SETUP_SQ_REWIND`이면 커널이 SQ head/tail을 무시하고 큐 처음부터 제출한다. 이 경우 liburing은 `__io_uring_flush_sq()`에서 `ktail`을 공개하지 않고 `sqe_tail`을 0으로 되돌린다.
- **`cq_ring_needs_flush()`**: `IORING_SQ_CQ_OVERFLOW | IORING_SQ_TASKRUN`이 서 있으면 CQ가 비어 보여도 커널에 들어가야 한다. 오버플로 리스트를 CQ로 옮기거나 task_work를 돌려 CQE를 만들어야 하기 때문이다. `io_uring_peek_cqe()`도 같은 조건을 확인해, 할 일이 없으면 시스템 콜 없이 `-EAGAIN`을 돌려준다.
- **`io_uring_cqe_seen()`/`io_uring_cq_advance()`**: `io_uring_smp_store_release(cq->khead, *cq->khead + nr)`. CQE 내용을 다 읽은 뒤에 head를 공개해야 커널이 그 슬롯을 덮어쓰지 않는다. 배치 수거 시 `io_uring_peek_batch_cqe()` + `io_uring_cq_advance(n)`로 release store를 한 번으로 줄인다.
- **대기 계열**: `io_uring_wait_cqe()`, `io_uring_wait_cqes()`(타임아웃, `IORING_ENTER_EXT_ARG`), `io_uring_submit_and_wait_timeout()`, 최신 `io_uring_submit_and_wait_min_timeout()`/`io_uring_wait_cqes_min_timeout()`(최소 대기 시간 동안 배치를 모으는 기능), `io_uring_submit_and_wait_reg()`(등록된 대기 영역 사용).

### 4.3 SQPOLL 깨우기 프로토콜

SQPOLL에서는 사용자 공간과 커널 스레드(`io_sq_thread()`, `io_uring/sqpoll.c`)가 "잠들기 직전 경합"을 메모리 배리어로 해결한다.

| 단계 | 커널 `io_sq_thread()` | 사용자 공간 liburing |
|---|---|---|
| 1 | `io_sqring_entries(ctx)`가 0인 상태로 `sq_thread_idle`(params의 ms 값, `jiffies + sqd->sq_thread_idle`) 경과 | SQE 작성 |
| 2 | `atomic_or(IORING_SQ_NEED_WAKEUP, &ctx->rings->sq_flags)` | `__io_uring_flush_sq()`: `io_uring_smp_store_release(sq->ktail, tail)` |
| 3 | `smp_mb__after_atomic()` 후 **다시** `io_sqring_entries(ctx)` 확인. 있으면 플래그를 지우고 계속 | `sq_ring_needs_enter()`: `io_uring_smp_mb()` 후 `kflags` 읽기 |
| 4 | 없으면 `schedule()`로 잠듦 | `IORING_SQ_NEED_WAKEUP`이 보이면 `io_uring_enter(..., IORING_ENTER_SQ_WAKEUP)` |
| 5 | `io_uring_enter`가 `IORING_ENTER_SQ_WAKEUP`을 보고 `wake_up(&ctx->sq_data->wait)` | — |

양쪽 모두 "내 쓰기 → 풀 배리어 → 상대 쓰기 읽기" 순서를 따른다. 그래서 둘 다 상대 쓰기를 못 보는 경우가 생기지 않는다(Dekker 패턴). 운영상 함의는 다음과 같다. (1) SQPOLL 스레드는 `sq_thread_idle` 동안 코어를 100% 회전시키므로, 벤치마크에서 이 코어를 사용 코어 수에 넣어야 한다. (2) `IORING_SETUP_SQ_AFF` + `sq_thread_cpu`로 스레드를 특정 CPU에 고정할 수 있다(`set_cpus_allowed_ptr(current, cpumask_of(sqd->sq_cpu))`). fio에서는 `sqthread_poll=1`, `sqthread_poll_cpu=N`이다. (3) `IORING_SETUP_ATTACH_WQ`로 여러 링이 하나의 SQPOLL 스레드를 공유할 수 있다. 이때 유휴 시간은 링들의 최댓값이다(`sq_thread_idle = max(...)`).

### 4.4 등록(registration)과 링 플래그: 도입 버전 연표

| 기능 | 이름 | 커널(태그 grep) | 효과 |
|---|---|---|---|
| 완료 폴링 | `IORING_SETUP_IOPOLL` | 5.1 | 인터럽트 대신 `blk_mq_poll`. NVMe `poll_queues` 필요 |
| 제출 폴링 | `IORING_SETUP_SQPOLL`, `IORING_SETUP_SQ_AFF`, `IORING_SQ_NEED_WAKEUP` | 5.1 | 제출 시스템 콜 제거 |
| 단일 mmap | `IORING_FEAT_SINGLE_MMAP` | 5.4 | SQ/CQ 링 mmap 1회 |
| CQ 오버플로 무손실 | `IORING_FEAT_NODROP` | 5.5 | CQ 가득 참 시 커널 내부 보관 |
| 등록 링 fd | `IORING_REGISTER_RING_FDS`, `IORING_ENTER_REGISTERED_RING` | 5.18 | `io_uring_enter`마다 `fdget`/`fdput` 생략 |
| passthrough | `IORING_OP_URING_CMD`, `IORING_SETUP_SQE128`, `IORING_SETUP_CQE32` | 5.19 | NVMe 문자 장치·ublk |
| task_work 협조 | `IORING_SETUP_COOP_TASKRUN`, `IORING_SETUP_TASKRUN_FLAG` | 5.19 | 완료 처리 IPI 감소 |
| 제공 버퍼 링 | `IORING_REGISTER_PBUF_RING` | 5.19 | 네트워크·버퍼 선택 |
| 단일 제출자 | `IORING_SETUP_SINGLE_ISSUER` | 6.0 | 내부 락 생략 |
| 지연 task_work | `IORING_SETUP_DEFER_TASKRUN` | 6.1 | 완료 작업을 `io_uring_enter(GETEVENTS)` 시점으로 미룸 |
| 고정 버퍼 passthrough | `IORING_URING_CMD_FIXED` | 6.1 | NVMe passthrough에 등록 버퍼 |
| 사용자 할당 링 | `IORING_SETUP_NO_MMAP`, `IORING_SETUP_REGISTERED_FD_ONLY` | 6.5 | hugepage 링, fd 테이블 비사용 |
| SQ 배열 제거 | `IORING_SETUP_NO_SQARRAY` | 6.6 | 간접 인덱스 제거 |
| 하이브리드 폴링 | `IORING_SETUP_HYBRID_IOPOLL` | 6.13 | 일정 시간 잠든 뒤 폴링 |
| 메모리 영역 등록 | `IORING_REGISTER_MEM_REGION` | 6.13 | 등록 대기 인자 등 |
| 혼합 SQE | `IORING_SETUP_SQE_MIXED` | 6.19 | 64B/128B SQE 혼용 |
| SQ 되감기 | `IORING_SETUP_SQ_REWIND` | 7.0 | head/tail 무시, 처음부터 제출 |

등록 링 fd의 원리는 이렇다. `io_uring_register_ring_fd()`(`src/register.c`)가 `IORING_REGISTER_RING_FDS`로 링 파일을 태스크별 테이블(`tctx->registered_rings[]`, 커널 `io_ringfd_register()`)에 넣는다. 성공하면 `ring->enter_ring_fd`를 그 인덱스로 바꾸고 `INT_FLAG_REG_RING`을 세운다. 이후 `ring_enter_flags()`가 `IORING_ENTER_REGISTERED_RING`을 자동으로 붙인다. 커널은 `io_uring_ctx_get_file(fd, flags & IORING_ENTER_REGISTERED_RING)`에서 fd 테이블 조회와 참조 카운트를 건너뛴다. 멀티스레드 프로세스에서 fd 테이블 공유로 인한 원자 연산(캐시 라인 바운싱)을 없애는 효과가 크다. t/io_uring의 `-X` 옵션이 이것이다. `io_uring_close_ring_fd()`로 일반 fd를 닫아 fd 테이블에서 아예 뺄 수도 있다.

### 4.5 xNVMe: 명령 컨텍스트와 백엔드

**핵심 객체**(`include/libxnvme_*.h`):

- `struct xnvme_opts`: `be`, `dev`, `mem`, `sync`, `async`, `admin`(백엔드·인터페이스 이름 문자열), `nsid`, OS open 플래그(`rdonly`, `wronly`, `rdwr`, `create`, `truncate`, `direct`), io_uring 옵션(`poll_io`, `poll_sq`, `register_files`, `register_buffers`), SPDK 옵션(`use_cmb_sqs`, `shm_id`, `main_core`, `core_mask`, `iova_mode`, `adrfam`, `subnqn`, `hostnqn`, `admin_timeout`, `command_timeout`).
- `struct xnvme_dev`: `xnvme_dev_open(uri, &opts)`로 연다. URI는 `/dev/nvme0n1`, `/dev/ng0n1`, PCIe BDF, fabrics 주소 등이다.
- `struct xnvme_cmd_ctx`(128바이트, `XNVME_STATIC_ASSERT`): `struct xnvme_spec_cmd cmd`(64B NVMe SQE), `struct xnvme_spec_cpl cpl`(16B CQE), `struct xnvme_dev *dev`, `struct xnvme_cmd_ctx_async async`(큐·콜백), `uint32_t opts`, `uint8_t be_rsvd[12]`(백엔드 내부용).
- `struct xnvme_queue`: `xnvme_queue_init(dev, capacity, opts, &queue)`, `xnvme_queue_get_cmd_ctx()`/`xnvme_queue_put_cmd_ctx()`, `xnvme_queue_set_cb()`, `xnvme_queue_poke(queue, max)`(완료 수거), `xnvme_queue_drain()`, `xnvme_queue_wait()`, `xnvme_queue_get_outstanding()`, `xnvme_queue_get_completion_fd()`(이벤트 루프 통합).

**동기/비동기 구분은 컨텍스트로 한다.** `xnvme_cmd_ctx_from_dev(dev)`로 만든 컨텍스트는 동기, `xnvme_queue_get_cmd_ctx(queue)`로 얻은 것은 비동기다. 같은 `xnvme_cmd_pass()`/`xnvme_cmd_passv()`/`xnvme_cmd_pass_admin()`이나 헬퍼 `xnvme_nvm_read()`/`xnvme_nvm_write()`가 두 경우 모두에 쓰인다. 명령 구조는 NVMe 사양 그대로이므로, 블록 경로 백엔드에서는 xNVMe가 NVMe 명령을 `pread`/io_uring READ로 "번역"하고, passthrough 백엔드에서는 그대로 전달한다.

| OS / 백엔드(`be`) | 비동기 인터페이스(`async`) 예 | 경로 |
|---|---|---|
| Linux(`xnvme_be_linux*.c`) | `io_uring`, `io_uring_cmd`, `libaio`, `posix`, `thrpool`, `emu`, `nil`(및 `_bdev`, `_file` 변형) | 블록 장치, NVMe 문자 장치(`/dev/ngXnY`), 파일 |
| SPDK(`xnvme_be_spdk*.c`) | SPDK NVMe 드라이버 큐 | 커널 바이패스(PCIe/fabrics) |
| libvfn(`xnvme_be_libvfn*.c`) | libvfn 큐 | VFIO 기반 사용자 공간 NVMe |
| FreeBSD, macOS(DriverKit 포함), Windows(IOCP, IoRing) | OS별 | 이식성 |
| ramdisk | 동기 | 테스트 |

`io_uring_cmd` 백엔드(`xnvme_be_linux_async_ucmd.c`)가 커널 NVMe passthrough를 쓰는 경로다. ZNS·FDP·KV 같은 새 명령 집합을 블록 계층 지원 없이 시험할 때 쓰인다. SPDK의 `bdev_xnvme` 모듈(→ 07/02)이 이 라이브러리를 통해 커널 경로를 SPDK bdev로 감싼다.

### 4.6 fio ioengine 비교

| ioengine | 소스 | 대상 | 주요 엔진 옵션(소스 `.name` 확인) | 특이점 |
|---|---|---|---|---|
| `io_uring` | `engines/io_uring.c` | 블록 장치·파일 | `hipri`(IOPOLL), `fixedbufs`, `registerfiles`, `sqthread_poll`, `sqthread_poll_cpu`, `nonvectored`, `uncached`, `nowait`, `force_async` | liburing 미사용(`os/linux/io_uring.h`). `COOP_TASKRUN`을 시도하고, `SINGLE_ISSUER|DEFER_TASKRUN`을 시도한 뒤 `-EINVAL`이면 플래그를 빼고 재시도 |
| `io_uring_cmd` | 같은 파일 | NVMe 문자 장치 `/dev/ngXnY` | `cmd_type`(nvme 등), `md_per_io_size`, `pi_act`, `pi_chk`, `apptag`, `apptag_mask`, `deac`, `readfua`/`writefua`, `write_mode`, `verify_mode` | `IORING_OP_URING_CMD` + `NVME_URING_CMD_IO`/`NVME_URING_CMD_IO_VEC`, `SQE128|CQE32` |
| `libaio` | `engines/libaio.c` | `O_DIRECT` 블록·파일 | `userspace_reap`, `nowait`, `libaio_vectored` | `userspace_reap=1`이면 `struct aio_ring`을 직접 읽어 `io_getevents` 생략 |
| `spdk` | SPDK `app/fio/nvme`(외부 플러그인) | PCIe/fabrics NVMe(`filename=trtype=PCIe traddr=0000.04.00.0 ns=1`) | `enable_wrr`, `enable_interrupts` 등 | `LD_PRELOAD=<spdk>/build/fio/spdk_nvme` 또는 `ioengine=<경로>`, **`thread=1` 필수** |
| `spdk_bdev` | SPDK `app/fio/bdev` | SPDK bdev | `spdk_conf`, `spdk_json_conf` | JSON 구성으로 bdev 스택 전체를 fio 안에서 띄움 |
| `xnvme` | `engines/xnvme.c` | xNVMe 백엔드 전체 | `xnvme_be`, `xnvme_async`, `xnvme_sync`, `xnvme_admin`, `xnvme_mem`, `xnvme_dev_nsid`, `xnvme_dev_subnqn`, `xnvme_iovec`, `hipri`, `sqthread_poll`, PI 옵션 | 같은 job 파일로 `xnvme_async=io_uring_cmd` ↔ `libaio` ↔ SPDK 비교 가능 |

`io_uring_cmd` 엔진은 블록 계층을 우회한다. 그래서 `/sys/block/*/stat` 기반 `iostat`에 이 I/O가 잡히지 않고, I/O 스케줄러·병합·`wbt`의 영향도 받지 않는다. 블록 경로(`io_uring`)와 비교할 때 이 비대칭을 감안해야 한다. FAST '24 논문이 커널 설정을 바꾼 결과를 따로 보고한 이유도 이것이다.

### 4.7 t/io_uring: 상한 측정용 마이크로벤치마크

`t/io_uring.c`(fio 저장소)는 fio 엔진 프레임워크를 쓰지 않는 독립 프로그램이다. `__NR_io_uring_setup`/`__NR_io_uring_enter`/`__NR_io_uring_register`를 직접 호출하고 링을 직접 mmap한다. usage 문자열로 확인한 옵션은 다음과 같다.

`-d` IO depth, `-s` batch submit, `-c` batch complete, `-b` block size, `-p` polled IO, `-B` fixed buffers, `-F` register files, `-n` 스레드 수, `-O` O_DIRECT, `-N` no-op 요청만(장치 없이 io_uring 오버헤드만 측정), `-t` 지연 추적, `-T` TSC rate, `-r` runtime, `-R` random IO, `-a` legacy aio, `-S` sync IO(`preadv2`), `-X` registered ring, `-P` 장치 home node에 자동 배치, `-V` vectored IO, `-e` opcode 제한 필터, `-u` NVMe passthrough I/O, `-H` hugetlbfs 버퍼.

같은 바이너리로 io_uring, legacy aio(`-a`), 동기(`-S`), passthrough(`-u`), no-op(`-N`)을 같은 조건에서 비교할 수 있다. `-N1`의 결과는 "장치가 무한히 빠를 때 io_uring 자체의 상한"이므로 장치 성능과 소프트웨어 오버헤드를 분리하는 데 쓴다. 출력의 `IOS/call=32/31`은 시스템 콜 한 번당 제출/수거 개수다. 배치 효율을 바로 보여 주므로 보고서에 함께 실어야 한다.

### 4.8 벤치마크 함정 체크리스트

| 함정 | 증상 | 대응 |
|---|---|---|
| SQPOLL 코어 미산정 | "1코어로 XM IOPS"가 실제로는 2코어 | SQPOLL 스레드 CPU를 `sqthread_poll_cpu`로 고정하고 그 코어를 사용률에 포함 |
| 폴링 큐 부재 | `hipri=1`/`-p1`인데 성능 차이가 없음 | `nvme.poll_queues=N` 모듈 파라미터, `/sys/block/nvmeXnY/queue/io_poll` 확인. 폴링 큐가 없으면 IOPOLL이 실패하거나 인터럽트로 돌아감 |
| 블록 크기 | 512B 결과를 4KiB와 비교 | 블록 크기 명시. 장치의 최대 IOPS 사양이 512B 기준인지 4KiB 기준인지도 확인 |
| 큐 깊이·배치 | QD를 키워도 IOPS 정체, 지연만 증가 | Little's law(QD = IOPS × 지연)로 포화점 확인. `iodepth_batch_submit`, `iodepth_batch_complete_min/max` 공개 |
| NUMA·IRQ 배치 | 소켓 간 성능 편차 | `cpus_allowed`/`numactl`, NVMe 장치의 `numa_node`, IRQ affinity(`/proc/irq/*/smp_affinity_list`), t/io_uring `-P1` |
| 블록 계층 부가 비용 | 블록 경로만 불리 | `iostats=0`, `nomerges=2`, 스케줄러 `none`, `wbt_lat_usec=0` 등의 설정을 결과와 함께 공개(FAST '24 튜닝 결과 참조) |
| 쓰기 사전 조건화 | 처음 몇 분만 높은 쓰기 IOPS | 전체 용량 순차 쓰기 2회 + 랜덤 쓰기로 steady state 도달 후 측정. `ramp_time` 사용 |
| 시간 측정 비용 | 지연 통계를 켜면 IOPS 하락 | `gtod_reduce=1` 또는 `clat_percentiles=0`으로 처리량 측정을 분리. 지연 측정은 별도 실행 |
| 도구 병목 | 장치 추가 시 IOPS 정체 | `numjobs` 증가로 확장되는지 확인, t/io_uring이나 SPDK `perf`와 교차 검증 |
| 투기 실행 완화·커널 설정 | 같은 HW에서 논문 수치 재현 불가 | 커널 버전, `mitigations=` 설정, `CONFIG_*` 차이 기록 |
| 장치 온도·스로틀링 | 장시간 실행 시 성능 하락 | `nvme smart-log`로 온도·스로틀 이벤트 확인 |

### 4.9 대표적 "코어당/시스템 IOPS" 주장과 측정 조건

| 주장 | 출처 | 블록 크기 | 폴링 | 등록 자원 | 코어/스레드 | 도구 |
|---|---|---|---|---|---|---|
| 3.5M+ IOPS per core | Axboe 커버 레터, 2021-08-12 (LWN 866114) | 512B | IOPOLL | 파일·버퍼 | `taskset -c 0` 1코어 | t/io_uring QD128, 배치 32 |
| 12.5M IOPS(8 SSD, SPDK 측정; 사양 기대치 12M) | Haas & Leis, PVLDB 16(9) 2023 | 4KiB | io_uring 폴링·SPDK | 논문 참조 | 폴링 io_uring 16스레드, SPDK 3스레드 | 자체 도구(fio는 병목) |
| 약 10M IOPS(2 장치, 장치당 1코어) | Joshi et al., FAST '24 | 512B | 폴링 | passthrough·SPDK | 장치당 1코어 | 논문 Table 참조 |
| io_uring이 SPDK보다 10배 이상 느림(고부하) | Ren & Trivedi, CHEOPS '23 | 논문 참조 | 비교 | — | 확장 실험 | fio(병목 보고) |

해설: 같은 "io_uring"이라도 4개 주장의 조건이 모두 다르다. 앞의 세 개는 폴링과 등록 자원을 쓴 상한이다. 마지막은 기본 설정에 가까운 확장 실험이다. 실무에서 자기 시스템에 맞는 수치를 얻으려면, 응용과 같은 블록 크기·QD·CPU 예산으로 fio(또는 응용 자체)를 돌리고 t/io_uring으로 상한을 따로 재서 차이를 "소프트웨어 오버헤드"로 해석하는 2단계 접근이 안전하다.

---

## 5. Primary References

- [lwn.net - Enable bio recycling for polled IO](https://lwn.net/Articles/866114/) — Jens Axboe [PATCHSET v5 0/6] 커버 레터 게시본, 2021-08-12 ("3.5M+ IOPS per core" 출력 포함)
- [lwn.net - Ringing in a new asynchronous I/O API](https://lwn.net/Articles/776703/) — io_uring 최초 소개 기사
- [usenix.org - I/O Passthru: Upstreaming a flexible and efficient I/O Path in Linux](https://www.usenix.org/conference/fast24/presentation/joshi) — Joshi et al., USENIX FAST '24
- Didona, Pfefferle, Ioannou, Metzler, Trivedi, "Understanding modern storage APIs: a systematic study of libaio, SPDK, and io_uring" — SYSTOR '22, DOI 10.1145/3534056.3534945 (Crossref 메타데이터로 서지 확인)
- [research.vu.nl - Performance Characterization of Modern Storage Stacks: POSIX I/O, libaio, SPDK, and io_uring](https://research.vu.nl/en/publications/performance-characterization-of-modern-storage-stacks-posix-io-li/) — Ren & Trivedi, CHEOPS '23, DOI 10.1145/3578353.3589545
- Lund, Bonnet, Jensen, Gonzalez, "I/O interface independence with xNVMe" — SYSTOR '22, DOI 10.1145/3534056.3534936 ([xnvme.io - Material — xNVMe documentation](https://xnvme.io/material/index.html)에 논문·발표 목록)
- [vldb.org - What Modern NVMe Storage Can Do, And How To Exploit It: High-Performance I/O for High-Performance Storage Engines](https://www.vldb.org/pvldb/vol16/p2090-haas.pdf) — Haas & Leis, PVLDB 16(9): 2090-2102, 2023
- [arxiv.org - Asynchronous I/O -- With Great Power Comes Great Responsibility](https://arxiv.org/abs/2411.16254) — Pestka, Paradies, Pohl, 2024-11
- [github.com/axboe - liburing src/setup.c](https://github.com/axboe/liburing/blob/master/src/setup.c) — 링 초기화·mmap
- [github.com/axboe - liburing src/queue.c](https://github.com/axboe/liburing/blob/master/src/queue.c) — submit/flush/wait 경로
- [github.com/axboe - liburing src/register.c](https://github.com/axboe/liburing/blob/master/src/register.c) — 등록 링 fd 등 register API
- [github.com/axboe - liburing src/include/liburing.h](https://github.com/axboe/liburing/blob/master/src/include/liburing.h) — 인라인 핫패스(`_io_uring_get_sqe()` 등)
- [github.com/axboe - fio engines/io_uring.c](https://github.com/axboe/fio/blob/master/engines/io_uring.c) — `io_uring`/`io_uring_cmd` ioengine
- [github.com/axboe - fio engines/libaio.c](https://github.com/axboe/fio/blob/master/engines/libaio.c) — libaio ioengine
- [github.com/axboe - fio engines/xnvme.c](https://github.com/axboe/fio/blob/master/engines/xnvme.c) — xNVMe ioengine
- [github.com/axboe - fio t/io_uring.c](https://github.com/axboe/fio/blob/master/t/io_uring.c) — 상한 측정용 독립 벤치마크
- [github.com/xnvme - include/libxnvme_cmd.h](https://github.com/xnvme/xnvme/blob/main/include/libxnvme_cmd.h) — `struct xnvme_cmd_ctx`
- [github.com/xnvme - include/libxnvme_queue.h](https://github.com/xnvme/xnvme/blob/main/include/libxnvme_queue.h) — 비동기 큐 API
- [github.com/xnvme - include/libxnvme_opts.h](https://github.com/xnvme/xnvme/blob/main/include/libxnvme_opts.h) — `struct xnvme_opts`
- [github.com/xnvme - lib/xnvme_be_linux.c](https://github.com/xnvme/xnvme/blob/main/lib/xnvme_be_linux.c) — Linux 백엔드와 비동기 인터페이스 목록
- [github.com/spdk/spdk - app/fio/nvme/README.md](https://github.com/spdk/spdk/blob/master/app/fio/nvme/README.md) — SPDK fio 플러그인 사용법
- [git.kernel.org - include/uapi/linux/io_uring.h](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/include/uapi/linux/io_uring.h) — io_uring uAPI 플래그
- [git.kernel.org - io_uring/sqpoll.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/io_uring/sqpoll.c) — `io_sq_thread()` 깨우기 프로토콜
