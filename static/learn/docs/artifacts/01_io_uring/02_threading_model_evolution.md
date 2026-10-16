# io_uring 스레딩 모델의 진화: workqueue → io-wq kthread → io thread → task_work 최적화

> 기준: 별도 표기가 없으면 소스는 Linux 메인라인 master(7.3-rc7, 2026-10)이며, 과거 동작은 해당 태그(`v5.1`, `v5.5`, `v5.11`, `v5.12`, `v5.13`, `v6.3`, `v6.4` 등)의 `fs/io_uring.c`, `fs/io-wq.c`, `io_uring/io-wq.c`, `kernel/fork.c`를 grep으로 직접 확인했다.

## 1. Verdict

io_uring이 "블록할 수도 있는 작업"을 어디서 실행하느냐는 5.1 이후 네 번 바뀌었다.

1. **5.1~5.4: 링별 커널 workqueue.** `io_uring_setup()`마다 `alloc_workqueue("io_ring-wq", WQ_UNBOUND | WQ_FREEZABLE, ...)`로 링 전용 unbound workqueue를 만들고(`ctx->sqo_wq`), 작업자는 `use_mm()`으로 제출자의 주소 공간을 빌렸다. SQPOLL은 별도 kthread(`io_uring-sq`)였다. 커널 공용 `system_unbound_wq`를 공유한 것이 아니다.
2. **5.5~5.11: io-wq (kthread 기반 전용 풀).** `fs/io-wq.c`가 생기고, NUMA 노드마다 `struct io_wqe`를 두며, 그 안에서 **bound**(일반 파일·블록 I/O, 동시성 상한 있음)와 **unbound**(소켓 등 무기한 블록 가능 작업, 상한은 `RLIMIT_NPROC`) 두 회계(`IO_WQ_ACCT_BOUND`/`IO_WQ_ACCT_UNBOUND`)로 워커를 관리했다. 워커는 kthread라 제출자의 mm, creds, `fs`, `files`를 하나씩 "빌려 입어야" 했고, 5.10에서는 이를 묶은 `struct io_identity`까지 등장했다.
3. **5.12~: io thread.** 워커와 SQPOLL 스레드를 제출자 프로세스의 **스레드**로 fork한다. `create_io_worker()`가 `create_io_thread(io_wqe_worker, worker, wqe->node)`를 부르고, `create_io_thread()`는 `CLONE_VM|CLONE_FS|CLONE_FILES|CLONE_SIGHAND|CLONE_THREAD|CLONE_IO|CLONE_UNTRACED`로 `copy_process()`를 수행하며 `PF_IO_WORKER`를 세운다. 신원을 빌리는 대신 처음부터 공유하므로 identity 관련 버그 계열이 사라졌다. 다만 이 변화가 5.12-rc 기간에 **GDB 부착 무한 루프와 suspend/freezer 문제**를 일으켰고, "io thread를 일반 스레드처럼 신호를 받게 한다"는 방향으로 rc5 무렵 정리됐다. 이 회귀는 kthread 시대가 아니라 io thread 도입 직후에 생긴 것이다.
4. **5.19~6.1: task_work 경로 최적화.** 비동기 완료를 제출자에게 되돌리는 task_work의 IPI·인터럽트 비용을 줄이기 위해 `IORING_SETUP_COOP_TASKRUN`/`TASKRUN_FLAG`(5.19), `IORING_SETUP_SINGLE_ISSUER`(6.0), `IORING_SETUP_DEFER_TASKRUN`(6.1)이 추가되었다. 이것들은 특정 조건에서 IPI와 일부 락 획득을 **생략**할 뿐, "락 전면 제거"나 "IPI 100% 제거"가 아니다.

이후 6.4에서 io-wq의 NUMA 노드별 `io_wqe` 계층이 제거되어 `struct io_wq` 하나가 `acct[IO_WQ_ACCT_NR]`과 `cpu_mask`를 직접 갖게 되었다. 2026년 9월에는 Jens Axboe가 "블록이 실제로 일어날 때만" 워커로 넘기는 thread identity handoff RFC(`PF_IO_HANDOFF`)를 올렸으나, master(7.3-rc7)에는 아직 없다.

---

## 2. Problem Statement

### 2.1 비동기 실행 컨텍스트가 필요한 이유

io_uring은 먼저 `IO_URING_F_NONBLOCK`으로 인라인 실행을 시도한다. `-EAGAIN`이 오면 (a) 파일이 poll을 지원하면 `io_arm_poll_handler()`로 준비 통지를 기다렸다가 task_work로 재시도하고, (b) 그럴 수 없으면 io-wq 워커에 넘겨 **블로킹 모드로** 실행한다. 버퍼드 쓰기에서 `i_rwsem`을 기다리거나, `openat`이 디스크에서 디렉터리 블록을 읽거나, `fsync`가 저널 커밋을 기다리는 경우가 (b)에 해당한다. 그래서 워커는 제출자와 *같은 권한, 같은 주소 공간, 같은 파일 테이블*로 syscall 경로를 실행해야 한다.

### 2.2 5.1: 링별 workqueue와 `use_mm()`

v5.1 `fs/io_uring.c`는 링마다 `ctx->sqo_wq = alloc_workqueue("io_ring-wq", WQ_UNBOUND | WQ_FREEZABLE, ...)`를 만들고, 비동기 요청을 `queue_work(ctx->sqo_wq, &req->work)`로 넣었다. 작업자는 `use_mm(ctx->sqo_mm)`/`unuse_mm()`으로 제출자의 mm을 잠시 빌렸다. 문제는 세 가지였다.

- **동시성 제어 부재**: 소켓 `recv`처럼 무기한 블록할 수 있는 작업과 금방 끝나는 블록 I/O가 같은 풀을 공유하므로, 전자가 워커를 다 붙잡으면 후자가 굶는다.
- **신원 불완전**: mm 외에 creds, `current->fs`(cwd, root), `current->files`(fd 테이블), 신호, cgroup, `audit` 컨텍스트 등이 제출자와 다르다. 새 opcode(`openat`, `statx`, `accept`)가 추가될 때마다 "무엇을 더 빌려야 하는가"가 늘었다.
- **링 수만큼 workqueue**: 링을 많이 만드는 프로세스는 workqueue와 rescuer 스레드를 그만큼 만든다.

### 2.3 5.5 io-wq: bound/unbound 분리

5.5의 `fs/io-wq.c`는 io_uring 전용 풀이다(v5.5 소스 기준).

- NUMA 노드마다 `struct io_wqe`를 만들고(`for_each_node(node)`), 워커를 `kthread_create_on_node(io_wqe_worker, worker, wqe->node, ...)`로 그 노드에 생성했다.
- 각 `io_wqe`에 `acct[IO_WQ_ACCT_BOUND]`와 `acct[IO_WQ_ACCT_UNBOUND]`가 있다. `io_wq_create(bounded, data)`에서 bound 쪽 `max_workers = bounded`, unbound 쪽은 `task_rlimit(current, RLIMIT_NPROC)`이다. `bounded` 값은 `io_uring.c`에서 `min(ctx->sq_entries, 4 * num_online_cpus())`로 정했다.
- 어느 쪽으로 갈지는 요청 준비 시 정한다. `IORING_OP_SENDMSG`, `RECVMSG`, `ACCEPT`, `POLL_ADD`, `CONNECT` 등에서 대상이 일반 파일이 아니면(`!(req->flags & REQ_F_ISREG)`) `IO_WQ_WORK_UNBOUND`를 세운다. 즉 **bound = 일반 파일/블록 디바이스처럼 언젠가 끝나는 작업(동시성 상한 적용), unbound = 소켓·파이프처럼 외부 이벤트에 무기한 묶일 수 있는 작업**이다.

### 2.4 kthread 신원 차용의 한계

5.5~5.11 워커는 여전히 kthread였다. v5.9~v5.11 `fs/io-wq.c`는 `kthread_use_mm()`, `override_creds()`, `current->fs`/`current->files` 교체를 수행했고, 5.10~5.11의 `fs/io_uring.c`에는 이를 묶은 `struct io_identity`가 있었다. Jens Axboe는 5.12 병합 요청(merge commit `5695e5161974`)에서 이 영역을 "the worst part of the code"라고 부르며, `/dev/tty`와 userfaultfd read의 fd 설치처럼 특수 처리가 필요한 파일 유형이 계속 나온다고 썼다. 새 opcode나 특이한 파일 유형이 생길 때마다 빠진 신원 조각이 버그(때로는 보안 버그)가 될 수 있다는 것이 io thread 전환의 동기였다.

### 2.5 task_work 비용

io thread 전환 뒤에도 남은 비용은 **완료 경로**였다. poll 기반 재시도나 드라이버 완료는 IRQ/softirq나 다른 CPU에서 일어나고, 결과는 `task_work_add()`로 제출자 태스크에 넘겨 그 태스크 문맥에서 CQE를 만든다. 기본 통지 방식 `TWA_SIGNAL`은 대상 태스크가 다른 CPU에서 사용자 모드로 돌고 있으면 IPI로 커널 진입을 강제한다. 이벤트 루프가 어차피 곧 `io_uring_enter()`를 부를 예정이라면 이 IPI는 낭비다. 이 비용을 줄인 것이 5.19~6.1의 플래그들이다.

---

## 3. The Debate

### 3.1 "kthread가 신원을 빌리지 말고, 원래 태스크의 스레드가 되자" (2021-02)

> "tldr - instead of using kthreads that assume the identity of the original
> tasks for work that needs offloading to a thread, setup these workers as
> threads of the original task."
>
> — Jens Axboe, [PATCHSET RFC 0/18] Remove kthread usage from io_uring, 2021-02-19 ([LWN 사본](https://lwn.net/Articles/846807/), Message-ID `20210219171010.281878-1-axboe@kernel.dk`)

같은 커버 레터는 성능도 언급한다. 비동기 오프로드를 쓰는 워크로드뿐 아니라 일반 경로에서도 구조체가 작아지고 hot path 코드가 줄어 더 빠르다고 했다. 시리즈 구성은 io-wq 준비 패치, arch/kernel 지원, kthread에서 thread로 전환, 그리고 "now dead/unneeded PF_IO_WORKER restrictions" 제거였다. Linus는 다음 날 바로 방향에 동의했다.

> "Ok, from a quick look-through of the patch series this most definitely
> seems to be the right way to go, getting rid of a lot of subtle (and
> not-so-subtle) issues."
>
> — Linus Torvalds, Re: [PATCHSET RFC 0/18] Remove kthread usage from io_uring, 2021-02-20 ([LWN 메일 아카이브](https://lwn.net/ml/io-uring/CAHk-=wgShFTn_BiVqtFrtL6xnJVUFJ5xFgVeWFHYs7P2ak_5zg@mail.gmail.com/))

이 시리즈는 `io_uring-worker.v3-2021-02-25` 태그로 5.12 병합 창에 들어갔다(merge commit `5695e5161974`, 2021-02-27). 병합 메시지에서 Jens는 "kills > 400 lines of code from io_uring/io-wq"라고 적고, 남은 위험은 "thread startup/exit" 방식 변화에 있다고 예고했다. 그 예고대로 rc 기간에 회귀가 나왔다.

### 3.2 5.12-rc: freezer와 GDB 회귀

**freezer(suspend/resume).** 5.12-rc3 io_uring fixes에 Jens는 "Make IO threads unfreezable by default"를 넣으면서, resume 뒤 스레드가 계속 pending signal을 보며 도는 원인은 "not quite sure"라고 썼다. Linus의 답이다.

> "That "not quite sure" doesn't exactly give my the warm and fuzzies,
> but not being new is ok, I guess. But I'd really like you to try to
> figure out what is actually going on.
>
> I'm _guessing_ it's just that now those threads are user threads, and
> then the freezing logic expects them to freeze/thaw using a signal
> machinery or something like that. And that doesn't work when there is
> no signal handling for those threads."
>
> — Linus Torvalds, Re: [GIT PULL] io_uring fixes for 5.12-rc3, 2021-03-12 ([LWN 메일 아카이브](https://lwn.net/ml/io-uring/CAHk-=wjpS-kwozJQFNBestco=q5j3bcfXpVXc6uz=9_mmQ7oYg@mail.gmail.com/), 원문 오타 "my" 그대로)

**GDB.** LWN "GDB and io_uring"(2021-03-31)에 따르면 Stefan Metzmacher가 3월 20일 io_uring 프로그램에 GDB를 붙이면 io thread에 attach하지 못해 무한 루프에 빠진다고 보고했다. 5.12 이전에는 워커가 프로세스와 무관한 kthread라 GDB에 보이지 않았지만, 5.12에서 같은 스레드 그룹(`CLONE_THREAD`)이 되면서 `/proc/<pid>/task/`에 나타났기 때문이다. 따라서 "kthread 시대에는 GDB와 완벽히 호환되었다"는 식의 비교는 기준을 뒤집은 것이다. kthread 시대에는 GDB가 워커를 *보지 못했을* 뿐이다.

해법 후보는 두 방향이었다.

| 방향 | 내용 | 결과 |
|---|---|---|
| 숨기기·특수 취급 | `PF_IO_WORKER`를 `/proc/<pid>/task/`와 `same_thread_group()`에서 제외, 모든 신호·STOP 차단, freezer에서 kthread처럼 취급 | Eric W. Biederman이 "왜 신호, 특히 SIGSTOP을 받을 수 없는가"를 문제 삼음(LWN). 관련 커밋은 곧 revert |
| 일반 스레드화 | io thread도 신호를 받아 `get_signal()`을 거치게 하여 STOP/freeze를 정상 처리 | 채택(5.12-rc5) |

Linus는 이 두 번째 방향을 이렇게 평가했다.

> "I think this ends up being the right approach - just the final part
> (famous last words) of "io_uring threads act like normal threads".
>
> Doing it for VM and FS got rid of all the special cases there, and now
> doing it for signal handling gets rid of all these ptrace etc issues."
>
> — Linus Torvalds, Re: [PATCH 0/2] Don't show PF_IO_WORKER in /proc/<pid>/task/, 2021-03-25 ([LWN 메일 아카이브](https://lwn.net/ml/linux-kernel/CAHk-=wgmHRvoYdsA2ZL4aEOYvNx-5c7typsUbFcqq+GmOMcoDQ@mail.gmail.com/))

같은 메일에서 Linus는 `get_signal()`이 `try_to_freeze()`를 하므로 freezer 특수 처리도 지울 수 있다고 덧붙였다. 실제로 "kernel: freezer should treat PF_IO_WORKER like PF_KTHREAD for freezing"(`15b2219facad`, 2021-03-12)은 2021-03-27 `d3dc04cd81e0`로 revert되었다.

### 3.3 task_work 최적화를 둘러싼 트레이드오프 (2022)

io thread 문제가 정리된 뒤 성능 논의는 완료 경로로 옮겨 갔다.

- **`IORING_SETUP_COOP_TASKRUN`(5.19)**: 앱이 "나는 어차피 곧 커널에 들어간다"고 약속하면 커널은 `TWA_SIGNAL` 대신 `TWA_SIGNAL_NO_IPI`로 task_work를 건다. master의 `io_uring_create()`는 `SQPOLL` 또는 `COOP_TASKRUN`이면 `ctx->notify_method = TWA_SIGNAL_NO_IPI`로 둔다. `IORING_SETUP_TASKRUN_FLAG`를 함께 주면 대기 중인 task_work가 있을 때 `sq_flags`에 `IORING_SQ_TASKRUN`이 서서, 앱이 폴링으로 확인할 수 있다.
- **`IORING_SETUP_SINGLE_ISSUER`(6.0, Pavel Begunkov)**: 한 태스크만 제출한다고 선언한다. 커널은 제출 태스크(`ctx->submitter_task`)를 기억하고 다른 태스크의 제출을 거부하며, 이를 전제로 일부 동기화를 생략할 수 있다. `uring_lock`이 사라지는 것은 아니다.
- **`IORING_SETUP_DEFER_TASKRUN`(6.1, Dylan Yudaken)**: `SINGLE_ISSUER`를 전제로, task_work를 태스크의 일반 task_work 리스트가 아니라 링 단위 lock-free 리스트(`io_req_local_work_add()`)에 쌓아 두고 앱이 `io_uring_enter(IORING_ENTER_GETEVENTS)`를 부를 때(`io_run_local_work()`) 한꺼번에 처리한다. 앱이 커널에 들어오지 않으면 완료가 진행되지 않으므로, 완료 지연과 이벤트 루프 구조에 대한 요구가 생긴다.

비용은 명확하다. `DEFER_TASKRUN`은 다른 스레드가 같은 링에서 완료를 대기하는 패턴을 금지하고, `COOP_TASKRUN`은 앱이 오래 사용자 모드에 머무는 경우 완료가 늦게 반영된다. 반면 스레드당 링 하나를 쓰는 이벤트 루프형 서버에서는 IPI와 불필요한 커널 진입이 줄어든다. 개선 폭은 워크로드에 따라 다르며, 이 문서는 정량 수치를 제시하지 않는다.

### 3.4 2026: "블록할 때만 넘기자" — thread identity handoff RFC

LWN "Thread-identity switcheroo for io_uring"(2026-09-17)은 Jens Axboe의 RFC를 소개한다. 현재는 블록 *가능성*이 있는 연산을 미리 워커로 넘기므로, 실제로는 블록하지 않는 경우에도 워커 깨우기와 문맥 전환 비용을 낸다. RFC는 `task_struct`에 `PF_IO_HANDOFF` 플래그를 추가하고, 이 플래그를 단 스레드가 잠들려 하면 스케줄러가 `io_uring_task_sleeping()`을 호출한다. 그러면 제출 스레드가 워커와 *신원을 맞바꿔*, 블록하는 쪽은 워커가 되고 원래 사용자 스레드는 계속 진행하게 한다. LWN은 shadow stack 등 신원 교환의 위험 요소도 함께 다룬다. master(7.3-rc7)의 `include/linux/sched.h`에는 `PF_IO_HANDOFF`가 없으므로 아직 병합되지 않은 제안이다.

---

## 4. Implementation Impact

### 4.1 `create_io_thread()`: 5.12와 master

v5.12 `kernel/fork.c`의 구현은 다음과 같다(발췌).

```c
struct task_struct *create_io_thread(int (*fn)(void *), void *arg, int node)
{
	unsigned long flags = CLONE_FS|CLONE_FILES|CLONE_SIGHAND|CLONE_THREAD|
				CLONE_IO;
	struct kernel_clone_args args = {
		.flags		= ((lower_32_bits(flags) | CLONE_VM |
				    CLONE_UNTRACED) & ~CSIGNAL),
		...
		.io_thread	= 1,
	};
```

`copy_process()`는 `args->io_thread`이면 `p->flags |= PF_IO_WORKER`를 세우고, v5.12에서는 `SIGKILL`/`SIGSTOP` 외 모든 신호를 막았다. master에서는 `flags = CLONE_FS|CLONE_FILES|CLONE_SIGHAND|CLONE_THREAD|CLONE_IO|CLONE_VM|CLONE_UNTRACED`를 직접 넘기고 `.user_worker = 1`도 함께 설정한다. 플래그의 의미는 다음과 같다.

- `CLONE_VM`/`CLONE_FS`/`CLONE_FILES`: mm, cwd/root, fd 테이블을 *공유*한다. kthread 시대의 `kthread_use_mm()`·`current->fs` 교체가 필요 없어진 이유다.
- `CLONE_SIGHAND`/`CLONE_THREAD`: 같은 스레드 그룹이 되어 `/proc/<pid>/task/`에 보이고, 프로세스 종료·신호 의미론을 공유한다. GDB 회귀의 원인이자 일반 스레드화의 근거다.
- `CLONE_IO`: I/O 컨텍스트(`io_context`, I/O 우선순위·cgroup 회계)를 공유한다.
- `CLONE_UNTRACED`: 트레이서가 이 생성 이벤트를 자동 추적(`PTRACE_O_TRACECLONE`)하지 않게 한다.

사용처는 두 가지다. io-wq 워커(`iou-wrk-<pid>`, `io_wq_worker()`)와 SQPOLL 스레드(`iou-sqp-<pid>`, `io_sq_thread()`)다. 5.12부터는 SQPOLL 스레드도 io-wq 워커와 같은 io thread다.

### 4.2 io-wq 구조 변화

| 시기 | 실행 주체 | 풀 구조 | 동시성 제어 | 신원 |
|---|---|---|---|---|
| 5.1~5.4 | 링별 `alloc_workqueue("io_ring-wq", WQ_UNBOUND \| WQ_FREEZABLE)` 워커 + SQPOLL kthread `io_uring-sq` | 링당 workqueue | workqueue 기본(`max_active`) | `use_mm()`만 차용 |
| 5.5~5.11 | io-wq kthread (`kthread_create_on_node`) | NUMA 노드별 `struct io_wqe` × bound/unbound `acct`, 관리 kthread `io_wq_manager` | bound=`min(sq_entries, 4*CPU)`, unbound=`RLIMIT_NPROC` | mm·creds·fs·files 차용, 5.10~5.11 `struct io_identity` |
| 5.12 | io thread, 관리자 `iou-mgr` 포함 | 노드별 `io_wqe` 유지 | 동일 | 공유(`CLONE_*`) |
| 5.13~6.3 | io thread, 관리자 제거. 워커 생성은 원 태스크에 `task_work_add(..., TWA_SIGNAL)`로 요청(`create_worker_cb()`) | 노드별 `io_wqe` | `IORING_REGISTER_IOWQ_MAX_WORKERS`(5.15)로 조정 가능 | 공유 |
| 6.4~master | io thread | `struct io_wq` 하나에 `acct[IO_WQ_ACCT_NR]`, `cpu_mask`, `hash_tail[]` | 동일, `IORING_REGISTER_IOWQ_AFF`(5.14)로 CPU 마스크 | 공유 |

**해시 직렬화.** `io_prep_async_work()`는 일반 파일에 대해 `def->hash_reg_file`이 참이면(주로 쓰기) `io_wq_hash_work(&req->work, file_inode(req->file))`로 inode 기준 해시를 붙인다. 같은 해시의 작업은 한 번에 한 워커만 처리하므로, 같은 파일에 대한 버퍼드 쓰기가 워커 여러 개에서 `i_rwsem`을 두고 다투는 상황을 피한다. `O_DIRECT`이고 파일시스템이 `FOP_DIO_PARALLEL_WRITE`를 선언하면 해시를 생략한다. 블록 디바이스가 아닌 비일반 파일에 대해 `def->unbound_nonreg_file`이 참이면 `IO_WQ_WORK_UNBOUND`가 붙는다. 5.5의 opcode별 `switch`가 opdef 테이블 속성으로 바뀐 것이다.

### 4.3 task_work 통지 모드

| 설정 | 도입 | 통지 경로 (master) | 얻는 것 | 대가 |
|---|---|---|---|---|
| 기본 | 5.x | `io_req_normal_work_add()` → `task_work_add(tctx->task, ..., TWA_SIGNAL)` | 완료가 즉시 반영됨 | 사용자 모드 실행 중이면 IPI·강제 커널 진입 |
| `COOP_TASKRUN` (+`TASKRUN_FLAG`) | 5.19 | `notify_method = TWA_SIGNAL_NO_IPI`, `IORING_SQ_TASKRUN` 표시 | IPI 제거 | 앱이 커널에 들어올 때까지 완료 지연 |
| `SQPOLL` | 5.1 (통지 방식은 master 기준) | 항상 `TWA_SIGNAL_NO_IPI` | SQ 스레드가 처리 | CPU 하나 상시 점유 |
| `SINGLE_ISSUER` | 6.0 | 제출자 `ctx->submitter_task` 고정 | 다른 태스크 제출 거부를 전제로 한 최적화 | 다중 스레드 제출 불가 |
| `DEFER_TASKRUN` | 6.1 | `io_req_local_work_add()`로 링 단위 llist, `io_run_local_work()`에서 실행 | 배치 처리, 캐시 지역성, IPI 없음 | `SINGLE_ISSUER` 필수, GETEVENTS 없이 진행 안 됨 |

`io_req_local_work_add()`는 대기 중인 앱이 요구한 개수(`ctx->cq_wait_nr`)를 채울 때까지 깨우기를 미루는 lazy wake(`IOU_F_TWQ_LAZY_WAKE`, 예: `rw.c`의 완료 경로)도 지원한다.

### 4.4 운영 체크리스트

- **스레드 수**: unbound 워커 상한은 기본 `RLIMIT_NPROC`이다. 소켓 연산을 강제로 비동기(`IOSQE_ASYNC`)로 보내면 워커가 폭증할 수 있으므로 `IORING_REGISTER_IOWQ_MAX_WORKERS`로 제한한다.
- **CPU 격리**: 워커는 제출 프로세스에서 fork되므로 cgroup을 상속하고, CPU affinity는 io-wq의 `cpu_mask`를 따른다. 격리된 코어에 퍼지지 않게 하려면 `IORING_REGISTER_IOWQ_AFF`를 쓴다.
- **디버깅**: 5.12-rc5 이후 GDB는 `iou-wrk-*`/`iou-sqp-*`를 일반 LWP처럼 보여 준다. 워커는 사용자 공간으로 돌아가지 않으므로 그 스택은 커널 스택뿐이다.
- **suspend**: io thread는 `get_signal()` 경로에서 freeze된다. 5.12-rc3의 "unfreezable" 임시 조치는 revert되었다.

---

## 5. Primary References

- [Redesigned workqueues for io_uring [LWN.net]](https://lwn.net/Articles/803070/) — 5.5 io-wq 도입 해설
- [Remove kthread usage from io_uring [LWN.net]](https://lwn.net/Articles/846807/) — Jens Axboe RFC 커버 레터 사본, 2021-02-19
- [Re: [PATCHSET RFC 0/18] Remove kthread usage from io_uring (LWN mail archive)](https://lwn.net/ml/io-uring/CAHk-=wgShFTn_BiVqtFrtL6xnJVUFJ5xFgVeWFHYs7P2ak_5zg@mail.gmail.com/) — Linus Torvalds, 2021-02-20
- [Re: [GIT PULL] io_uring fixes for 5.12-rc3 (LWN mail archive)](https://lwn.net/ml/io-uring/CAHk-=wjpS-kwozJQFNBestco=q5j3bcfXpVXc6uz=9_mmQ7oYg@mail.gmail.com/) — Linus Torvalds, 2021-03-12
- [Re: [PATCH 0/2] Don't show PF_IO_WORKER in /proc/<pid>/task/ (LWN mail archive)](https://lwn.net/ml/linux-kernel/CAHk-=wgmHRvoYdsA2ZL4aEOYvNx-5c7typsUbFcqq+GmOMcoDQ@mail.gmail.com/) — Linus Torvalds, 2021-03-25
- [GDB and io_uring [LWN.net]](https://lwn.net/Articles/851076/) — Jake Edge, 2021-03-31
- [Thread-identity switcheroo for io_uring [LWN.net]](https://lwn.net/Articles/1094303/) — Jonathan Corbet, 2026-09-17
- [torvalds/linux merge 5695e5161974: io_uring-worker.v3-2021-02-25](https://github.com/torvalds/linux/commit/5695e51619745d4fe3ec2506a2f0cd982c5e27a4)
- [torvalds/linux commit 97bbdc06a444: io_uring: add IORING_SETUP_SINGLE_ISSUER](https://github.com/torvalds/linux/commit/97bbdc06a444)
- [torvalds/linux commit c0e0d6ba25f1: io_uring: add IORING_SETUP_DEFER_TASKRUN](https://github.com/torvalds/linux/commit/c0e0d6ba25f1)
- [io_uring/io-wq.c (torvalds/linux master)](https://github.com/torvalds/linux/blob/master/io_uring/io-wq.c)
- [kernel/fork.c (torvalds/linux master)](https://github.com/torvalds/linux/blob/master/kernel/fork.c) — `create_io_thread()`
