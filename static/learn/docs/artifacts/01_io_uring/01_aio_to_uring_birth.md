# Linux 비동기 I/O의 진화: native AIO(libaio)의 한계와 io_uring의 탄생

> 기준: 별도 표기가 없으면 소스 인용은 Linux 메인라인 master(7.3-rc7, 2026-10 시점) 기준이며, 버전별 도입 시점은 각 태그(`v5.1` … `v7.2`)의 `include/uapi/linux/io_uring.h`를 직접 대조해 확인했다.

## 1. Verdict

리눅스의 커널 네이티브 비동기 I/O(이하 native AIO, 사용자 공간 래퍼 이름을 따서 흔히 `libaio`라 부름: `io_setup(2)`, `io_submit(2)`, `io_getevents(2)`)는 2.5 개발 시리즈에서 도입되어 2.6에 포함되었지만, 15년 넘게 "`O_DIRECT` 파일 I/O 전용"이라는 한계를 벗어나지 못했다. 버퍼드 I/O는 `io_submit()` 안에서 사실상 동기로 수행되었고, 소켓·`openat`·`statx` 같은 연산은 아예 표현할 수 없었다. 2016년 Benjamin LaHaise가 AIO에 스레드 기반 `openat` 등을 덧붙이려 하자 Linus Torvalds는 AIO 인터페이스를 "horrible ad-hoc design"이라 부르며 "임의의 시스템 콜을 비동기로" 수행하는 일반 모델을 요구했다.

Jens Axboe는 2018년 AIO 내부에서 polling과 공유 링을 붙이는 작업(`aio-poll`, 내부 명칭 "scqring")을 진행하다가, Christoph Hellwig의 설득으로 이를 AIO와 분리했고 2019년 1월 `[PATCHSET v1] io_uring IO interface`를 게시했다. 이 시리즈는 커밋 `2b188cc1bb85` ("Add io_uring IO interface")로 **Linux 5.1**(2019-05)에 병합되었다.

`io_uring`의 핵심 설계 결정은 다음 세 가지로 요약된다.

1. **공유 메모리 SPSC 링 두 개**: 사용자 공간이 생산자인 Submission Queue(SQ)와 커널이 생산자인 Completion Queue(CQ)를 `mmap`으로 공유하고, 인덱스 갱신은 `smp_store_release()`/`smp_load_acquire()` 쌍으로 순서를 보장한다. 링 자체에는 락이 없다(커널 내부의 `ctx->uring_lock`, `completion_lock` 등은 여전히 존재한다).
2. **opcode 기반의 확장 가능한 명령 집합**: SQE의 `opcode` 필드로 연산을 지정하므로 새 연산을 syscall 추가 없이 넣을 수 있다. 5.1의 8개 opcode(`NOP`, `READV`, `WRITEV`, `FSYNC`, `READ_FIXED`, `WRITE_FIXED`, `POLL_ADD`, `POLL_REMOVE`)는 master 기준 65개(`IORING_OP_LAST` = 65)로 늘었고, `IORING_OP_URING_CMD`(5.19)로 드라이버별 명령까지 같은 링으로 전달한다.
3. **"먼저 non-blocking으로 시도, 안 되면 비동기 경로로"**: 제출 시 `IO_URING_F_NONBLOCK`으로 인라인 실행을 시도하고, `-EAGAIN`이면 poll 기반 재시도(`io_arm_poll_handler()`, 5.7의 `IORING_FEAT_FAST_POLL`) 또는 워커 스레드 풀(`io-wq`)로 넘긴다. 그래서 버퍼드 I/O도 호출자를 막지 않는다. 단, 워커 스레드에서는 여전히 블로킹 실행이 일어나므로 "커널 어디서도 블록하지 않는다"는 뜻은 아니다.

결론적으로 `io_uring`은 AIO의 "땜질"이 아니라, Linus가 2016년에 요구한 "비동기 syscall 큐" 모델을 공유 링 기반으로 구현한 새 서브시스템이다. 대신 그 범용성 때문에 공격 표면이 커졌고, 이후 보안 위기를 겪게 된다 (→ 01/03).

---

## 2. Problem Statement

### 2.1 native AIO의 구조

native AIO는 프로세스마다 하나 이상의 `struct kioctx`를 만든다. `io_setup()`이 생성한 kioctx들은 `mm->ioctx_table`(`struct kioctx_table`)에 매달리므로 **AIO 컨텍스트는 프로세스(`mm_struct`) 단위**로 관리된다(fs/aio.c, v5.1에서도 동일). 흔히 오해하는 것과 달리 AIO에도 사용자 공간에 매핑되는 완료 링(`struct aio_ring`)이 있어서, libaio는 `io_getevents()` 없이 링에서 직접 완료를 읽는 최적화를 할 수 있었다. 그러나 **제출 쪽에는 공유 링이 없어** 매 배치마다 `io_submit()`이 필요하고, 커널은 `struct iocb *` 배열의 포인터와 각 64바이트 `struct iocb`를 `copy_from_user()`로 가져와야 했다.

### 2.2 "O_DIRECT가 아니면 동기"

- **버퍼드 I/O 동기 수행**: `O_DIRECT`가 없는 파일에 대한 `IOCB_CMD_PREAD`/`PWRITE`는 `->read_iter`/`->write_iter`를 그대로 호출하므로 페이지 캐시 미스, 페이지 할당, `inode->i_rwsem` 경합이 모두 `io_submit()` 호출자 스레드에서 일어났다. 4.13 무렵 도입된 `RWF_NOWAIT`/`IOCB_NOWAIT`로 "블록할 것 같으면 `-EAGAIN`"을 받을 수는 있었지만, 그 뒤의 재시도는 애플리케이션 몫이었다 (`RWF_NOWAIT`는 v4.13의 `include/uapi/linux/fs.h`에 처음 등장).
- **O_DIRECT라도 메타데이터 경로는 블록**: 블록 할당, 파일 확장 쓰기, 저널 트랜잭션, `bio` 할당 대기, 디바이스 태그 고갈(`blk_mq_get_tag()` 대기) 등은 `O_DIRECT` 요청이라도 제출 경로에서 잠들 수 있다.
- **지원 연산의 빈약함**: uAPI(`include/uapi/linux/aio_abi.h`)가 정의한 명령은 `PREAD`, `PWRITE`, `FSYNC`, `FDSYNC`, `NOOP`, `PREADV`, `PWRITEV` 정도였다. `IOCB_CMD_POLL`은 Christoph Hellwig가 2018년에 추가했으나 4.18-rc 중 Linus의 revert(`a11e1d432b51`, "Revert changes to convert to ->poll_mask() and aio IOCB_CMD_POLL")로 빠졌다가, 재작성된 구현(`bfe4037e722e`, "aio: implement IOCB_CMD_POLL")이 **4.19**에 들어갔다. 즉 AIO도 소켓 readiness는 poll 명령으로 기다릴 수 있었지만, `recv`/`send`/`accept` 같은 실제 소켓 연산이나 `openat`/`statx`는 표현할 수 없었다.

### 2.3 시스템 콜 비용과 NVMe 시대의 불균형

NVMe SSD의 4KiB 랜덤 읽기 지연은 수십 µs 수준까지 내려왔고, 단일 디바이스가 수십만~백만 IOPS를 낸다. 이 영역에서는 I/O당 고정비(시스템 콜 진입/복귀, 2018년 이후 Meltdown 완화를 위한 KPTI의 CR3 전환, `iocb` 복사, `fget()`/`fput()`의 atomic 참조 카운트)가 디바이스 지연과 같은 자릿수가 된다. AIO 모델에서는 "제출 1회 + 완료 수확 1회"가 사실상 배치마다 필요했고, 파일 참조나 사용자 버퍼 pin(`get_user_pages`)을 요청마다 반복했다. io_uring이 링 공유뿐 아니라 **등록 파일**(`IORING_REGISTER_FILES`)과 **등록 버퍼**(`IORING_REGISTER_BUFFERS`)를 5.1부터 함께 넣은 이유가 바로 이 요청당 고정비 제거다.

### 2.4 해결해야 했던 요구사항 정리

| 요구사항 | native AIO의 상태 | io_uring에 필요한 것 |
|---|---|---|
| 버퍼드 I/O를 호출자 블록 없이 처리 | 불가 (동기 수행) | non-blocking 시도 + 비동기 워커 폴백 |
| 소켓/파일 메타데이터 연산 | 불가 (`IOCB_CMD_POLL`은 4.19부터, readiness만) | opcode로 확장 가능한 명령 집합 |
| 제출 측 syscall 감소 | 배치마다 `io_submit()` | 공유 SQ 링, SQPOLL 커널 스레드 |
| 요청당 `fget`/pin 비용 | 매번 수행 | 등록 파일/버퍼 테이블 |
| 요청 간 의존성 | 없음 | 링크(`IOSQE_IO_LINK`, 5.3) |

---

## 3. The Debate

### 3.1 2016년: "AIO를 더 확장하지 말고 일반 비동기 syscall을 만들라"

2016년 1월 Benjamin LaHaise는 AIO 내부에 커널 스레드 기반 헬퍼를 두고 `IOCB_CMD_OPENAT`, `fsync`, `renameat`, `unlinkat`, readahead 등을 추가하는 패치 시리즈를 올렸다. LWN은 이 시리즈가 "스레드에서 원래 syscall 경로를 그대로 호출"하는 방식이라 버퍼드 I/O 지원도 쉬워진다고 정리했지만, Linus는 방향 자체에 반대했다.

> "AIO is a horrible ad-hoc design, with the main excuse being "other,
> less gifted people, made that design, and we are implementing it for
> compatibility because database people - who seldom have any shred of
> taste - actually use it".
>
> But AIO was always really really ugly.
>
> Now you introduce the notion of doing almost arbitrary system calls
> asynchronously in threads, but then you use that ass-backwards nasty
> interface to do so."
>
> — Linus Torvalds, Re: [PATCH 09/13] aio: add support for async openat(), 2016-01-11 ([LWN 아카이브 사본](https://lwn.net/Articles/671657/))

같은 메일의 끝에서 Linus는 "generic "do system call asynchronously" model"을 목표로 할 수 없겠느냐고 되묻는다. 핵심은 두 가지다. 첫째, AIO의 `struct iocb` 인터페이스에 syscall을 하나씩 덧대면 ABI 부채만 늘어난다. 둘째, 비동기 실행의 본체(스레드에서 원래 syscall 경로 실행)와 인터페이스(제출/완료 전달 방식)는 분리해서 설계해야 한다. io_uring은 정확히 이 두 번째 지점을 받아들였다. 제출/완료는 공유 링으로, 실행은 "인라인 non-blocking 시도 → poll 재시도 → 워커 스레드" 계층으로 나눴다.

이 논쟁은 처음이 아니었다. LWN 기사 "Fixing asynchronous I/O, again"(2016)은 fibrils, syslets, threadlets, acall 등 2007~2009년의 "임의 syscall 비동기화" 시도들이 모두 병합되지 못했다는 점을 상기시킨다. 결국 LaHaise의 시리즈도 병합되지 않았다.

### 3.2 2018~2019년: aio-poll에서 독립 서브시스템으로

Jens Axboe는 2018년 말 AIO에 polled I/O와 사용자 공간 매핑 링을 붙이는 작업을 하고 있었다. 이 작업이 AIO와 갈라진 경위는 io_uring 첫 패치셋 커버 레터에 직접 적혀 있다(원문 철자 "retail" 그대로 인용).

> "After some arm twisting from Christoph, I finally caved and divorced the
> aio-poll patches from aio/libaio itself. The io_uring interface itself
> is useful and efficient, and after rebasing all the new goodies on top
> of that, there was little reason to retail the aio connection.
>
> Hence io_uring was born. This is what I previously called scqring for
> aio, but now as a standalone entity."
>
> — Jens Axboe, [PATCHSET v1] io_uring IO interface, 2019-01-08 ([LWN 아카이브 사본](https://lwn.net/Articles/776230/), Message-ID `20190108165645.19311-1-axboe@kernel.dk`)

여기서 "Christoph"는 이 메일의 Cc에 있는 Christoph Hellwig다. master의 `io_uring/io_uring.c` 저작권 헤더에도 "Copyright (c) 2018-2019 Christoph Hellwig"가 Jens와 함께 남아 있어, 초기 설계에 직접 참여했음을 확인할 수 있다. AIO에서 떼어낸 이유는 기술적으로 명확했다. `struct iocb`/`struct io_event` 레이아웃, `io_context_t` 수명, `io_getevents()`의 의미론을 모두 유지하면서 SQ 링을 추가하면 두 제출 경로가 공존해야 한다. 새 syscall 세 개(`io_uring_setup`, `io_uring_enter`, `io_uring_register`)로 시작하면 그 제약이 사라진다.

LWN의 "Ringing in a new asynchronous I/O API"(2019-01)는 이 v1 패치셋을 해설하면서 SQ/CQ 링 레이아웃, 고정 버퍼, polled I/O를 소개했다. 커밋 `2b188cc1bb85`("Add io_uring IO interface")를 비롯한 시리즈는 v5.1에 들어갔다.

### 3.3 메모리 순서 규약 논쟁 (2019년 4월, 5.1-rc)

공유 링은 락이 없으므로 정확성은 전적으로 메모리 순서에 달려 있다. 5.1-rc 기간에 Stefan Bühler가 일련의 수정 패치를 보냈고, 모두 v5.1 태그 이전에 병합되었다(GitHub compare로 v5.1 포함 여부 확인).

| 커밋 | 제목 | 의미 |
|---|---|---|
| `e523a29c4f27` | io_uring: fix race condition reading SQ entries | SQ 엔트리 읽기 경쟁 수정 |
| `0d7bae69c574` | io_uring: fix race condition when sq threads goes sleeping | SQPOLL 스레드 수면 진입 시 경쟁 수정 |
| `fb775faa9e46` | io_uring: fix poll full SQ detection | SQ 가득 참 판정 수정 |
| `1e84b97b7377` | io_uring: fix notes on barriers | 커널-앱 배리어 짝 규약 주석 정정 |
| `82ab082c0e2f` | io_uring: remove unnecessary barrier before reading SQ tail | acquire 로드로 대체 가능한 배리어 제거 |

결과로 남은 규약은 master의 `io_uring/io_uring.c` 맨 위 주석에 그대로 있다. 앱은 CQ tail을 읽은 뒤 커널의 쓰기 쪽 배리어와 짝을 이루는 read 배리어가 필요하다("using smp_load_acquire to read the tail will do"). CQ head를 갱신하기 전에는 엔트리 로드와 head 저장 사이에 순서를 보장해야 한다("smp_store_release to store head will do"). SQ 쪽도 대칭이다. SQPOLL을 쓰면 SQ tail 갱신 *후* `IORING_SQ_NEED_WAKEUP`을 확인해야 하고, 그 사이에 완전한 `smp_mb()`가 필요하다. 이 마지막 규칙이 SQPOLL에서 가장 자주 틀리는 부분이며, liburing의 `io_uring_submit()`이 대신 처리한다.

### 3.4 남은 쟁점: "AIO를 대체하는가, 공존하는가"

io_uring은 `fs/aio.c`를 제거하지 않았다. AIO는 기존 ABI로 남아 있고 데이터베이스 등 기존 사용자는 그대로 동작한다. 대신 새 기능(버퍼드 비동기, 네트워크, 메타데이터 연산, 드라이버 passthrough)은 io_uring에만 들어갔다. 이 선택의 비용은 공격 표면 확대다 (→ 01/03). 범용 syscall 큐를 만들자는 2016년 Linus의 요구는 성능 면에서는 옳았지만, "모든 syscall 경로를 다른 컨텍스트(워커, task_work, SQPOLL 스레드)에서 실행한다"는 구조는 자격 증명·수명·취소에서 새로운 버그 계열을 만들었다.

---

## 4. Implementation Impact

> 이 절의 함수·필드 이름은 master(7.3-rc7)의 `io_uring/*.c`, `io_uring/tw.h`, `include/linux/io_uring_types.h`, `include/uapi/linux/io_uring.h`에서 grep으로 확인했다. 5.1 당시에는 모든 코드가 `fs/io_uring.c` 한 파일에 있었고(v5.19까지), v6.0에서 `io_uring/` 디렉터리로 분리되었다.

### 4.1 공유 메모리 레이아웃

- **`struct io_uring_sqe`**(64B): `opcode`, `flags`(`IOSQE_*`), `fd`, `off`, `addr`, `len`, op별 플래그 union, `user_data`, `buf_index` 등. 5.19의 `IORING_SETUP_SQE128`은 SQE를 128B로 늘려 `IORING_OP_URING_CMD`의 드라이버 명령을 담는다.
- **`struct io_uring_cqe`**(16B): `user_data`, `res`, `flags`. 5.19의 `IORING_SETUP_CQE32`는 32B CQE를 쓰고, master에는 둘을 섞는 `IORING_SETUP_CQE_MIXED`(6.18)도 있다.
- **`struct io_rings`**: SQ/CQ의 head·tail, `sq_flags`(`IORING_SQ_NEED_WAKEUP`, `IORING_SQ_TASKRUN` 등), `cq_overflow`, CQE 배열을 담고 `mmap`으로 공유된다. 커널 내부 상태인 **`struct io_ring_ctx`**(`uring_lock`, 캐시된 head/tail, 등록 자원 테이블)는 공유되지 않는다.
- SQ는 원래 "SQE 배열 + 인덱스 배열(`sq_array`)" 2단 구조였다. 6.6의 `IORING_SETUP_NO_SQARRAY`로 인덱스 배열을 생략할 수 있고, 6.5의 `IORING_SETUP_NO_MMAP`은 사용자가 할당한 메모리를 링으로 쓰게 해 준다.

### 4.2 요청(`struct io_kiocb`)의 수명 주기

`struct io_kiocb`는 SQE 하나를 커널에서 표현한다. 주요 필드는 `file`(또는 `cmd`), `opcode`, `flags`(`REQ_F_*`), `cqe`, `ctx`, `tctx`, `refs`, `io_task_work`, `apoll`, `async_data`, `link`, `creds`, `work`(`struct io_wq_work`)다. master 기준 콜패스는 다음과 같다.

```
io_uring_enter()
 └─ io_submit_sqes(ctx, nr)                     // ctx->uring_lock 보유
     ├─ io_alloc_req()                          // 요청 캐시에서 io_kiocb 확보
     └─ io_submit_sqe()
         ├─ io_init_req()                       // opcode 검증, io_check_restriction()
         ├─ io_uring_run_bpf_filters()          // 7.0+, 등록된 필터가 있을 때만
         └─ io_queue_sqe()                      // IO_URING_F_NONBLOCK | IO_URING_F_COMPLETE_DEFER
             └─ io_issue_sqe() → def->issue()   // io_issue_defs[opcode], 예: io_read()
                  ├─ 완료: CQE를 배치에 모아 __io_submit_flush_completions()
                  └─ -EAGAIN: io_queue_async()
                        └─ io_arm_poll_handler()
                             ├─ IO_APOLL_OK      : poll 대기, 준비되면 task_work로 재발행
                             ├─ IO_APOLL_READY   : io_req_task_queue()
                             └─ IO_APOLL_ABORTED : io_queue_iowq() → io_wq_enqueue()
```

비동기 완료는 대부분 **task_work**로 제출자 태스크에 돌아온다. `io_req_task_work_add()`는 `__io_req_task_work_add()`로 이어지며, `IORING_SETUP_DEFER_TASKRUN` 링이면 `io_req_local_work_add()`(링 단위 llist에 넣고 대기자만 깨움), 아니면 `io_req_normal_work_add()`(태스크의 `tctx->task_work`에 `task_work_add()`)로 갈린다. 완료된 요청은 `io_free_batch_list()`에서 일괄 회수되어 캐시로 돌아간다. 링크(`IOSQE_IO_LINK`, 5.3)된 요청은 `req->link`를 따라 이전 요청이 끝난 뒤에 발행된다.

### 4.3 등록 자원: 파일·버퍼·provided buffer

| 기능 | uAPI (도입) | 커널 경로 | 제거되는 요청당 비용 |
|---|---|---|---|
| 등록 파일 | `IORING_REGISTER_FILES`(5.1), `_FILES_UPDATE`(5.5), `_FILES2`(5.13), `_FILE_ALLOC_RANGE`(6.0) | `io_sqe_files_register()`, `io_file_get_fixed()` → `io_rsrc_node_lookup(&ctx->file_table.data, fd)` | `fget()`/`fput()`의 atomic 참조 카운트 |
| 등록 버퍼 | `IORING_REGISTER_BUFFERS`(5.1), `_BUFFERS2`(5.13) | `io_sqe_buffers_register()`, `io_import_reg_buf()` | 요청마다 `get_user_pages` pin/unpin |
| provided buffers | `IORING_OP_PROVIDE_BUFFERS`(5.7) | `io_buffer_select()` | 수신 전에 버퍼를 미리 고정할 필요 |
| buffer ring | `IORING_REGISTER_PBUF_RING`(5.19), `IOU_PBUF_RING_INC`(6.12) | `io_register_pbuf_ring()`, `io_ring_buffer_select()`, `io_kbuf_recycle()` | provided buffer의 SQE 기반 재보충 비용 |

등록 자원은 성능 이득과 함께 수명 관리 부담을 낳았다. 등록 파일 테이블과 Unix 소켓 GC의 상호작용(CVE-2022-2602), 고정 버퍼 등록 시 페이지 병합 경계 계산(CVE-2023-2598), buffer ring `mmap` 해제(CVE-2024-0582)가 모두 이 영역에서 나왔다 (→ 01/03).

### 4.4 IOPOLL과 SQPOLL: syscall이 실제로 몇 번 필요한가

"IOPOLL/SQPOLL을 쓰면 syscall이 0회"라는 설명이 흔하지만, 이는 SQPOLL에만 해당한다.

- **`IORING_SETUP_IOPOLL` 단독**: 완료 인터럽트 대신 드라이버 큐를 폴링한다. 그러나 폴링을 *실행*하는 것은 `io_uring_enter(..., IORING_ENTER_GETEVENTS)` 안의 `io_iopoll_check()` → `io_do_iopoll()`이다. 사용자가 이 syscall을 부르지 않으면 CQE가 생기지 않는다. 즉 IOPOLL이 줄이는 것은 인터럽트와 문맥 전환이지 syscall이 아니다.
- **`IORING_SETUP_SQPOLL`**: 커널 스레드 `io_sq_thread()`(5.12부터 `iou-sqp-<pid>` 이름의 io thread)가 SQ tail을 감시해 대신 제출한다. 스레드가 유휴 시간(`sq_thread_idle`) 후 잠들면 `IORING_SQ_NEED_WAKEUP`을 세우고, 앱은 그때만 `io_uring_enter(IORING_ENTER_SQ_WAKEUP)`을 부른다. SQPOLL+IOPOLL 조합이면 SQ 스레드가 `io_do_iopoll()`까지 수행하므로 정상 상태에서 syscall 없이 제출과 완료가 모두 가능하다.
- **권한**: SQPOLL은 v5.10까지 `CAP_SYS_ADMIN`, v5.11~v5.12는 `CAP_SYS_ADMIN` 또는 `CAP_SYS_NICE`가 필요했고, v5.13부터는 권한 검사가 없다(각 태그의 소스에서 확인).

### 4.5 native AIO vs io_uring 비교

| 항목 | native AIO (`io_submit`) | io_uring |
|---|---|---|
| 컨텍스트 단위 | 프로세스(`mm->ioctx_table`)에 매달린 `struct kioctx` | fd로 표현되는 링(`struct io_ring_ctx`), 링마다 독립 |
| 버퍼드 I/O | 호출자 스레드에서 동기 수행 | non-blocking 시도 → poll 재시도 → io-wq 워커 |
| 지원 연산 | read/write/fsync/fdsync/noop/vectored, `IOCB_CMD_POLL`(4.19) | 65개 opcode(master): 소켓, open/close/statx, futex, waitid, `URING_CMD` 등. `IORING_OP_BPF`는 없음 |
| 제출 | 배치마다 `io_submit()`, `iocb` 복사 | 공유 SQ. SQPOLL이면 정상 상태에서 syscall 없음 |
| 완료 | 매핑된 `aio_ring` 또는 `io_getevents()` | 공유 CQ. IOPOLL 단독이면 `io_uring_enter(GETEVENTS)` 필요 |
| 동기화 | 링 갱신에 `ctx->completion_lock` 등 | 링은 acquire/release 규약, 커널 내부는 `uring_lock`, `completion_lock` 유지 |
| 요청 간 의존성 | 없음 | `IOSQE_IO_LINK`(5.3), `IOSQE_IO_HARDLINK`, `IOSQE_IO_DRAIN` |
| 자원 등록 | 없음 | 파일·버퍼·buffer ring 등록 |

### 4.6 버전 연표 (uapi 헤더 대조 결과)

| 버전 | 주요 추가 |
|---|---|
| 5.1 | 최초 병합: `IORING_SETUP_IOPOLL`/`SQPOLL`/`SQ_AFF`, `REGISTER_FILES`/`BUFFERS`, `READ_FIXED`, `POLL_ADD` |
| 5.3 / 5.4 / 5.5 | `IOSQE_IO_LINK` / `IORING_OP_TIMEOUT` / `IORING_OP_ACCEPT`, `IORING_FEAT_NODROP`, io-wq 도입 |
| 5.6 | `IORING_OP_OPENAT`, `SEND`, `EPOLL_CTL`, `IORING_SETUP_ATTACH_WQ` |
| 5.7 | `IORING_FEAT_FAST_POLL`, `IORING_OP_PROVIDE_BUFFERS` |
| 5.10 | `IORING_REGISTER_RESTRICTIONS`, `IORING_SETUP_R_DISABLED` |
| 5.12 | io-wq/SQPOLL 워커를 kthread에서 io thread(`create_io_thread()`)로 전환 |
| 5.13 | `IORING_POLL_ADD_MULTI`, `REGISTER_FILES2`/`BUFFERS2`, 비특권 SQPOLL |
| 5.19 | `IORING_OP_URING_CMD`, `SQE128`/`CQE32`, `REGISTER_PBUF_RING`, `COOP_TASKRUN` |
| 6.0 / 6.1 | `SINGLE_ISSUER`, `SEND_ZC`, `RECV_MULTISHOT` / `DEFER_TASKRUN` |
| 6.5 / 6.6 | `NO_MMAP` / `NO_SQARRAY`, sysctl `io_uring_disabled` |
| 6.7 | `IORING_OP_FUTEX_WAIT`, `IORING_OP_WAITID` |
| 6.12 / 6.13 | `IOU_PBUF_RING_INC` / `HYBRID_IOPOLL`, `REGISTER_MEM_REGION` |
| 6.15 | `IORING_OP_RECV_ZC`(zcrx), `IORING_OP_EPOLL_WAIT` |
| 7.0 / 7.1 | `IORING_REGISTER_BPF_FILTER` / BPF struct_ops 루프(`io_uring/bpf-ops.c`) |

### 4.7 운영상 함의

1. **syscall 감소는 기본값이 아니다.** 일반 모드는 배치 단위 syscall이며, 진짜 "무 syscall"은 CPU 하나를 SQ 스레드에 내주는 SQPOLL의 대가다.
2. **등록 자원은 수명 관리 책임을 앱으로 옮긴다.** 버퍼를 등록한 채 `munmap`하거나 파일 테이블을 바꾸는 순서를 잘못 잡으면 오류가 나고, 커널 쪽에서는 이 수명 관리가 CVE의 주된 출처였다.
3. **AIO 사용자에게 이전 압력은 약하다.** `O_DIRECT` 블록 I/O만 쓰는 기존 코드에서는 io_uring 이득이 주로 제출/완료 배치와 등록 버퍼에서 나온다. 버퍼드 I/O나 네트워크를 함께 쓰는 이벤트 루프에서 차이가 크다.

---

## 5. Primary References

- [Re: [PATCH 09/13] aio: add support for async openat() [LWN.net]](https://lwn.net/Articles/671657/) — Linus Torvalds, 2016-01-11 (LKML 메일 사본)
- [Fixing asynchronous I/O, again [LWN.net]](https://lwn.net/Articles/671649/) — 2016년 LaHaise 시리즈와 과거 비동기 syscall 시도 정리
- [io_uring IO interface [LWN.net]](https://lwn.net/Articles/776230/) — Jens Axboe, [PATCHSET v1] 커버 레터 사본, 2019-01-08
- [Ringing in a new asynchronous I/O API [LWN.net]](https://lwn.net/Articles/776703/) — 2019-01-15
- [The rapid growth of io_uring [LWN.net]](https://lwn.net/Articles/810414/) — 5.1 이후 1년간의 opcode·기능 확장 개관 (2020-01)
- [torvalds/linux commit 2b188cc1bb85: Add io_uring IO interface](https://github.com/torvalds/linux/commit/2b188cc1bb857a9d4701ae59aa7768b5124e262e)
- [torvalds/linux commit 1e84b97b7377: io_uring: fix notes on barriers](https://github.com/torvalds/linux/commit/1e84b97b7377)
- [io_uring/io_uring.c (torvalds/linux master)](https://github.com/torvalds/linux/blob/master/io_uring/io_uring.c) — 메모리 순서 규약 주석, 제출 경로
- [include/uapi/linux/io_uring.h (torvalds/linux master)](https://github.com/torvalds/linux/blob/master/include/uapi/linux/io_uring.h)
- [liburing man page: io_uring_setup.2](https://github.com/axboe/liburing/blob/master/man/io_uring_setup.2) — `io_uring_setup(2)`의 플래그·파라미터 공식 설명
