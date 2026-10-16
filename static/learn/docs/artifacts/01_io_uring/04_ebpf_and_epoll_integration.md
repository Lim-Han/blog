# io_uring의 경계 확장: eBPF 통합 시도와 epoll 이벤트 루프 통합

> 기준: 별도 표기가 없으면 소스는 Linux 메인라인 master(7.3-rc7, 2026-10)이며, 기능 도입 버전은 태그별 `include/uapi/linux/io_uring.h`·`io_uring/` 디렉터리 목록과 GitHub compare API로 커밋 포함 여부를 확인했다.

## 1. Verdict

이 문서는 io_uring이 바깥 세계와 만나는 두 경계를 다룬다. 하나는 "사용자 공간으로 돌아오지 않고 커널 안에서 다음 요청을 결정하게 하자"는 **BPF 통합**이고, 다른 하나는 "이미 epoll 기반인 이벤트 루프를 io_uring 대기 하나로 합치자"는 **epoll 통합**이다.

**BPF 쪽 결론.** 2021년 Pavel Begunkov의 `BPF_PROG_TYPE_IOURING`/BPF 요청 RFC(v1 2021년 초, v2 2021-05-19)는 병합되지 않았다. master의 uAPI에도 `IORING_OP_BPF`는 없다. 2025년 11월에는 Ming Lei의 `IORING_OP_BPF`(BPF를 하나의 io_uring 연산으로 실행)와 Begunkov의 완료 루프 훅(BPF가 이벤트 루프 자체를 대신 실행)이 경쟁했고, Jens Axboe는 2026-03-17 Begunkov의 시리즈를 적용했다. 결과는 **7.1의 BPF struct_ops 루프**(`io_uring/bpf-ops.c`, `io_uring/loop.c`)다. `struct io_uring_bpf_ops`의 `loop_step` 콜백이 CQ 대기 루프에서 호출되고, kfunc `bpf_io_uring_submit_sqes()`와 `bpf_io_uring_get_region()`으로 SQE를 제출하거나 공유 영역에 접근한다. 별도로 7.0에는 보안 목적의 **classic BPF 필터**(`IORING_REGISTER_BPF_FILTER`) (→ 01/03)가 들어갔다. 따라서 "io_uring이 BPF 전반을 지원한다"는 표현은 2025년 이전 시점에는 틀렸고, 지금도 "eBPF struct_ops 루프 + cBPF 필터"라는 두 개의 좁은 형태로만 맞다.

**epoll 쪽 결론.** `IORING_OP_EPOLL_CTL`(5.6)은 6.0에서 "nobody ever adopted"를 이유로 deprecation 경고가 붙었다가, libuv가 실제로 쓰고 있다는 사실이 확인되어 6.4에서 되살아났다. 반대 방향인 **`IORING_OP_EPOLL_WAIT`은 6.15**에 들어갔다. 커밋 `19f7e9427327`은 `fs/eventpoll.c`에 `ep_check_params()`, `ep_try_send_events()`, `epoll_sendevents()`를 분리한 뒤, `io_epoll_wait()`가 `epoll_sendevents()`를 호출하게 한다. 이벤트가 없으면 `-EAGAIN`을 반환하고, opdef의 `.pollin = 1`에 따라 일반 poll 재시도 경로가 epoll fd의 준비를 기다린다. **병합본은 one-shot**이며 multishot 플래그나 재무장 로직이 없다. 참고로 `ep_poll_ready_events`, `io_epoll_wait_fn` 같은 이름은 커널에 존재하지 않으며, `IORING_POLL_ADD_MULTI`는 `IORING_OP_POLL_ADD`의 플래그(5.13)로 EPOLL_WAIT와 무관하다.

두 흐름의 공통점은 "기존 사용자 코드를 100% 그대로 두고 성능만 얻는다"가 아니라는 점이다. EPOLL_WAIT은 epoll 집합 관리 코드는 유지하되 대기 지점을 io_uring으로 옮기는 *부분 이전* 수단이고, BPF 루프는 이벤트 루프 로직 일부를 BPF로 다시 써야 하는 *재작성* 수단이다.

---

## 2. Problem Statement

### 2.1 요청 사이의 왕복

io_uring의 기본 모델에서 요청 A의 결과를 보고 요청 B를 결정하려면, A의 CQE가 사용자 공간에 도착하고 앱이 B의 SQE를 쓰고 다시 `io_uring_enter()`를 불러야 한다. 링크(`IOSQE_IO_LINK`)는 "A가 성공하면 B"라는 고정 순서만 표현할 수 있고, A의 *결과값*에 따라 B의 인자를 바꾸지는 못한다. 짧은 요청이 연쇄되는 워크로드(작은 레코드 읽기 → 파싱 → 다음 오프셋 읽기, 프록시의 recv → send)에서는 이 왕복이 지배적 비용이 된다. Spectre/Meltdown 완화가 켜진 커널에서는 커널 경계 왕복이 특히 비싸다.

### 2.2 2021년 시도의 한계

LWN "BPF meets io_uring"(2021-03-04)은 Begunkov의 첫 RFC가 `BPF_PROG_TYPE_IOURING` 프로그램 타입과 `IORING_ATTACH_BPF` 등록 명령을 도입했다고 정리하면서 한계를 짚었다. BPF 프로그램을 비동기로 실행해 다른 요청을 제출하는 것만으로는 이득이 작고, 이전 요청의 결과를 BPF에 넘기는 장치가 없으며, `CAP_BPF` 또는 `CAP_SYS_ADMIN`이 필요해 채택이 제한된다는 것이다. v2(2021-05-19)는 결과 전달 문제를 다중 CQ로 풀려 했다(3.1절).

### 2.3 epoll과 io_uring의 공존 비용

대형 이벤트 루프 라이브러리(libuv 등)는 수많은 fd를 epoll로 관리하고, io_uring은 파일 I/O 등 일부에만 쓴다. 두 대기 메커니즘을 합치는 기존 방법은 io_uring fd를 epoll 집합에 넣고 `epoll_wait()` 하나로 기다리는 것이었다. `19f7e9427327`의 커밋 메시지는 이 방식의 문제를 두 가지로 든다. `epoll_wait()`는 부분 회수나 배치 대기를 지원하지 않고, io_uring 링을 epoll에 넣으면 io_uring의 "I'm being polled" 로직이 활성화되어 느려진다. master에서 이 로직은 `io_activate_pollwq()`가 링의 poll 대기 큐를 켜는 형태로 남아 있다.

반대로 epoll 대신 io_uring의 `IORING_OP_POLL_ADD`(multishot은 5.13의 `IORING_POLL_ADD_MULTI`)로 epoll fd 자체의 readiness를 기다리는 방법도 있었다. 이 경우 CQE가 와도 "epoll fd가 준비됨"만 알려 주므로, 실제 이벤트를 얻으려면 `epoll_wait()` syscall을 다시 불러야 한다.

### 2.4 epoll_ctl을 io_uring에 둔 대가

`IORING_OP_EPOLL_CTL`은 `do_epoll_ctl()`에 non-blocking 경로를 만들어 io_uring에서 epoll 집합을 조작하게 했다. 하지만 epoll의 중첩(epoll fd를 다른 epoll에 추가)은 루프 검출 코드가 필요한 까다로운 영역이다. 2026년에는 io_uring에서 중첩 추가를 금지하는 커밋(`cfa1539b24af`, Linus 제안)이 들어갔다가, libuv가 바로 그 기능을 쓰고 있다는 보고로 같은 7.2 개발 주기 안에 revert(`9db03d2116ab`)되었다. 한 번 노출된 uAPI는 사용자가 있으면 거둘 수 없다는 커널 원칙이 io_uring에서도 반복 확인된 것이다.

---

## 3. The Debate

### 3.1 2021: BPF 요청과 다중 CQ (Begunkov RFC v2)

Begunkov의 두 번째 RFC는 첫 RFC의 "결과 전달 장치 부재"를 정면으로 다뤘다. 커버 레터 원문이다.

> "The main problem solved is feeding completion information of other
> requests in a form of CQEs back into BPF. I decided to wire up support
> for multiple completion queues (aka CQs) and give BPF programs access to
> them, so leaving userspace in control over synchronisation that should
> be much more flexible that the link-based approach."
>
> — Pavel Begunkov, [RFC v2 00/23] io_uring BPF requests, 2021-05-19 ([LWN 사본](https://lwn.net/Articles/856559/), Message-ID `cover.1621424513.git.asml.silence@gmail.com`)

같은 메일은 `sqe->cq_idx`로 대상 CQ를 고르고, BPF 프로그램끼리 서로의 CQ에 CQE를 써서 통신하는 ping-pong 예제를 소개하면서, "The interfaces are not even close to settle"와 "one may live-lock a task"라는 알려진 문제도 명시했다. 이 시리즈는 병합되지 않았다. 다중 CQ는 링 구조 전체에 영향을 주는 큰 변경이었고, BPF 프로그램 타입을 새로 만드는 데 따르는 verifier·권한 문제도 해결되지 않았다.

### 3.2 2025: 두 가지 방향의 경쟁

LWN "BPF and io_uring, two different ways"(2025-11-20)에 따르면, 4년 뒤 다시 두 제안이 동시에 올라왔다.

| 항목 | Ming Lei: `IORING_OP_BPF` | Pavel Begunkov: BPF 이벤트 루프 |
|---|---|---|
| BPF의 위치 | SQE 하나가 BPF 프로그램을 실행하는 "연산" | CQ 대기 루프에서 호출되는 struct_ops 콜백 |
| 사용자 공간의 역할 | SQE 생성 등 앱 로직 대부분 유지 | 루프 로직 일부를 BPF로 옮김 |
| 대체하는 것 | 특정 연산 사이의 계산(예: ublk 데이터 가공) | 링크 메커니즘과 사용자 공간 이벤트 루프 왕복 |
| 장점 | 목표가 좁은 변경에 쓰기 쉬움 | 더 넓은 유형의 애플리케이션 처리 |
| 상태 (master) | 미병합 | 7.1 병합 |

LWN "BPF comes to io_uring at last"(2026-03-18)는 Jens Axboe가 2026-03-17 Begunkov의 시리즈를 적용하기로 했고, Ming Lei의 작업은 그 위에 rebase하도록 했다고 전한다. 7.1 커밋 `d0e437b76bd3`("io_uring/bpf-ops: implement loop_step with BPF struct_ops")의 설명은 다음과 같다.

> "Introduce io_uring BPF struct ops implementing the loop_step callback,
> which will allow BPF to overwrite the default io_uring event loop logic."
>
> — Pavel Begunkov, commit d0e437b76bd3, 2026-02-26 작성 ([GitHub 커밋](https://github.com/torvalds/linux/commit/d0e437b76bd3))

EPOLL_WAIT의 multishot 지원 여부를 두고 2025년 초 Pavel Begunkov와 Jens Axboe 사이에 논의가 있었다는 설명이 있으나, 원문 메일은 확인하지 못했다 [추측/미확인]. 병합된 코드는 3.3절에서 보듯 one-shot이다.

### 3.3 EPOLL_WAIT의 설계 선택

`IORING_OP_EPOLL_WAIT` 커밋의 핵심 설명은 다음과 같다.

> "Rather than use this approach, with EPOLL_WAIT support added to io_uring,
> event loops can use the normal io_uring wait logic for everything, as
> long as an epoll wait request has been armed with io_uring.
>
> Note that IORING_OP_EPOLL_WAIT does NOT take a timeout value, as this
> is an async request."
>
> — Jens Axboe, commit 19f7e9427327 "io_uring/epoll: add support for IORING_OP_EPOLL_WAIT", 2025-01-31 작성, v6.15 포함 ([GitHub 커밋](https://github.com/torvalds/linux/commit/19f7e9427327))

설계상 쟁점은 세 가지였다.

1. **타임아웃**: `epoll_wait()`의 `timeout` 인자를 SQE에 넣지 않았다. 대기 시간은 io_uring 대기 자체(`io_uring_enter()`의 `min_complete`/타임아웃, `IORING_OP_TIMEOUT`, 링크 타임아웃)로 표현한다. 연산마다 타임아웃을 따로 두지 않는다는 io_uring 원칙과 맞춘 것이다.
2. **one-shot vs multishot**: 병합본 `io_epoll_wait()`는 `epoll_sendevents()`가 0을 반환하면 `-EAGAIN`을 돌려주고, 이벤트가 있으면 개수를 `res`에 담아 `IOU_COMPLETE`로 끝난다. 이벤트를 받을 때마다 SQE를 다시 제출해야 한다. multishot이었다면 CQE마다 사용자 버퍼(`struct epoll_event` 배열)를 덮어쓰는 수명 문제가 생기는데, 병합본은 이 문제를 피했다.
3. **epoll 내부 노출 최소화**: `fs/eventpoll.c`에 io_uring 전용 대기 코드를 넣는 대신 기존 `ep_poll()`의 일부를 `ep_check_params()`, `ep_try_send_events()`로 분리하고, 비대기 버전 `epoll_sendevents()`만 내보냈다. 커밋 `6b47d35d4d9e`, `38d203560118`, `ae3a4f1fdc2c`가 그 준비 패치이며, 6.15의 VFS eventpoll 병합 태그(`vfs-6.15-rc1.eventpoll`)로 들어갔다. epoll fd의 준비 대기는 io_uring의 일반 poll 경로가 담당한다.

### 3.4 BPF 확장에 대한 회의론

2021년 LWN 기사가 지적한 복잡성·디버깅 문제는 2026년에도 유효하다. BPF가 이벤트 루프를 대신하면 `strace`로 보이던 syscall 흐름이 사라지고, CQE를 사용자 공간이 보기 전에 BPF가 소비할 수 있다. struct_ops 등록에는 BPF 로딩 권한이 필요하므로 비특권 앱은 쓰기 어렵다. 보안 이력(→ 01/03)에 비추어 보면, io_uring 안에서 BPF 프로그램이 SQE를 제출하는 경로는 새로운 공격 표면이기도 하다. 반면 7.0의 cBPF 필터는 방향이 반대다. seccomp와 같은 classic BPF로 *허용 범위를 줄이는* 장치이며, 비특권 sandboxing을 상정한다.

---

## 4. Implementation Impact

### 4.1 `IORING_OP_EPOLL_WAIT` 콜패스 (6.15~master)

SQE 사용법: `fd` = epoll fd, `addr` = `struct epoll_event` 배열 주소, `len` = `maxevents`. `off`, `rw_flags`, `buf_index`, `splice_fd_in`이 0이 아니면 `io_epoll_wait_prep()`이 `-EINVAL`을 돌려준다. 커널 내부 명령 구조체는 `struct io_epoll_wait { file, maxevents, events }`다.

```
io_issue_sqe()
 └─ io_epoll_wait()                         // io_uring/epoll.c
     └─ epoll_sendevents(file, events, max) // fs/eventpoll.c
         ├─ ep_check_params()               // epoll fd인지, maxevents 범위 검사
         └─ ep_events_available(ep) ? ep_try_send_events() : 0
     ├─ ret == 0 → return -EAGAIN
     │      └─ io_queue_async() → io_arm_poll_handler()
     │           // opdef .pollin = 1: epoll fd에 POLLIN 대기 등록
     │           // 준비되면 task_work로 io_epoll_wait() 재실행
     ├─ ret < 0  → req_set_fail(), CQE res = -errno
     └─ ret > 0  → io_req_set_res(req, ret, 0); return IOU_COMPLETE
```

`epoll_sendevents()` 주석은 "Racy call, but that's ok - it should get retried based on poll readiness anyway"라고 적는다. `ep_events_available()` 검사와 실제 전송 사이의 경쟁은 poll 재시도로 흡수한다. opdef에는 `.audit_skip = 1`도 있어 감사 기록 대상에서 빠진다. `CONFIG_EPOLL`이 꺼진 커널에서는 `io_eopnotsupp_prep`이 연결된다.

### 4.2 epoll과 io_uring을 함께 쓰는 세 가지 방식

| 방식 | 대기 지점 | 이벤트 획득 | syscall / 비용 | 비고 |
|---|---|---|---|---|
| io_uring fd를 epoll에 추가 | `epoll_wait()` | io_uring은 CQ 확인, 나머지는 epoll 결과 | 깨어날 때마다 `epoll_wait()` + `io_uring_enter()`. `io_activate_pollwq()` 활성화 비용 | 부분 회수·배치 대기 불가 |
| `IORING_OP_POLL_ADD`(+`IORING_POLL_ADD_MULTI`, 5.13)로 epoll fd 감시 | `io_uring_enter()` | CQE는 readiness만 알림 → `epoll_wait()` 별도 호출 | 대기 1회 + 이벤트 획득 syscall 1회 | multishot이면 재무장 불필요 |
| `IORING_OP_EPOLL_WAIT` (6.15) | `io_uring_enter()` | CQE `res` = 이벤트 수, 배열은 사용자 버퍼에 기록됨 | 대기 1회. 이벤트 후 SQE 재제출 필요(one-shot) | epoll 집합 관리는 기존 코드 유지 |

세 번째 방식에서도 `epoll_ctl()`로 관심 fd를 관리하는 코드는 그대로 남는다(또는 `IORING_OP_EPOLL_CTL` 사용). 즉 "기존 epoll 코드 100% 무수정"이 아니라 대기 루프의 *대기 호출부*만 바꾸는 점진 이전 수단이다.

### 4.3 BPF struct_ops 이벤트 루프 (7.1~master)

```
io_uring_enter(fd, ...)
 └─ if (io_has_loop_ops(ctx)) io_run_loop(ctx)       // 일반 제출/대기 경로를 대체
     └─ __io_run_loop()                              // ctx->uring_lock 보유
         loop:
           step = ctx->loop_step(iou_ctx, &lp)       // BPF struct_ops 콜백
                ├─ bpf_io_uring_submit_sqes(ctx, nr) → io_submit_sqes()
                └─ bpf_io_uring_get_region(ctx, id, size)  // 공유 영역 접근
           IOU_LOOP_STOP → 사용자 공간 복귀
           IOU_LOOP_CONTINUE → lp.cq_wait_idx까지 CQE 대기
               io_loop_wait(): uring_lock 해제 → schedule() → 재획득
           task_work, 신호(-EINTR), local work, CQ overflow flush 처리 후 반복
```

등록은 BPF struct_ops 링크로 한다. `bpf_io_reg()`가 `ops->ring_fd`로 링을 찾아 `io_install_bpf()`를 부른다. 여기에는 운영상 중요한 제약이 코드로 박혀 있다.

- `IORING_SETUP_SQPOLL` 또는 `IORING_SETUP_IOPOLL` 링이면 `-EOPNOTSUPP`.
- `IORING_SETUP_DEFER_TASKRUN`이 아니면 `-EOPNOTSUPP`. 루프가 local task_work(`io_run_local_work_locked()`)를 직접 돌리는 구조이기 때문이다.
- 링당 하나만 설치 가능(`ctx->bpf_ops`가 있으면 `-EBUSY`).

kfunc는 `register_btf_kfunc_id_set(BPF_PROG_TYPE_STRUCT_OPS, ...)`로 struct_ops 프로그램에만 노출된다. `struct iou_ctx`는 실제로는 `struct io_ring_ctx`를 가리키는 불투명 핸들(`io_loop_mangle_ctx()`/`io_loop_demangle_ctx()`)이라, BPF가 링 내부 필드에 직접 접근하지 못하게 한다.

### 4.4 관측: io_uring tracepoint와 eBPF

BPF로 io_uring을 *확장*하는 것과 별개로, 관측은 오래전부터 tracepoint로 가능했다. master의 `include/trace/events/io_uring.h`에는 `io_uring_create`, `io_uring_register`, `io_uring_file_get`, `io_uring_queue_async_work`, `io_uring_defer`, `io_uring_link`, `io_uring_cqring_wait`, `io_uring_fail_link`, `io_uring_complete`, `io_uring_submit_req`, `io_uring_poll_arm`, `io_uring_task_add`, `io_uring_req_failed`, `io_uring_cqe_overflow`, `io_uring_task_work_run`, `io_uring_short_write`, `io_uring_local_work_run`이 정의되어 있다. 예를 들어 `io_uring_submit_req` → `io_uring_poll_arm` → `io_uring_task_add` → `io_uring_complete` 순서를 `user_data`로 묶으면 3.3절의 EPOLL_WAIT 재시도 경로를 그대로 관찰할 수 있고, `io_uring_queue_async_work`로 io-wq 오프로드 빈도를 셀 수 있다.

### 4.5 연표

| 버전 | 변경 |
|---|---|
| 5.6 | `IORING_OP_EPOLL_CTL` |
| 5.13 | `IORING_POLL_ADD_MULTI` (multishot poll) |
| 6.0 | `EPOLL_CTL` deprecation 경고 (`61a2732af4b0`, Linus 제안) |
| 6.4 | deprecation 철회 (`4ea0bf4b98d6`, Ben Noordhuis, libuv 사용 확인, stable 백포트) |
| 6.15 | `IORING_OP_EPOLL_WAIT` (`19f7e9427327`), `epoll_sendevents()` 헬퍼 |
| 7.0 | `IORING_REGISTER_BPF_FILTER` (cBPF, `d42eb05e60fe`) |
| 7.1 | BPF struct_ops 루프 (`d0e437b76bd3`), `io_uring/loop.c` |
| 7.2 개발 주기 | `EPOLL_CTL` 중첩 epoll 금지(`cfa1539b24af`) 후 revert(`9db03d2116ab`), 최종 동작 변화 없음 |

---

## 5. Primary References

- [BPF meets io_uring [LWN.net]](https://lwn.net/Articles/847951/) — Jonathan Corbet, 2021-03-04
- [io_uring BPF requests [LWN.net]](https://lwn.net/Articles/856559/) — Pavel Begunkov RFC v2 커버 레터 사본, 2021-05-19
- [BPF and io_uring, two different ways [LWN.net]](https://lwn.net/Articles/1046950/) — Jonathan Corbet, 2025-11-20
- [BPF comes to io_uring at last [LWN.net]](https://lwn.net/Articles/1062286/) — Daroc Alden, 2026-03-18
- [torvalds/linux commit 19f7e9427327: io_uring/epoll: add support for IORING_OP_EPOLL_WAIT](https://github.com/torvalds/linux/commit/19f7e9427327)
- [torvalds/linux commit ae3a4f1fdc2c: eventpoll: add epoll_sendevents() helper](https://github.com/torvalds/linux/commit/ae3a4f1fdc2c)
- [torvalds/linux commit 4ea0bf4b98d6: io_uring: undeprecate epoll_ctl support](https://github.com/torvalds/linux/commit/4ea0bf4b98d6)
- [torvalds/linux commit d0e437b76bd3: io_uring/bpf-ops: implement loop_step with BPF struct_ops](https://github.com/torvalds/linux/commit/d0e437b76bd3)
- [io_uring/epoll.c (torvalds/linux master)](https://github.com/torvalds/linux/blob/master/io_uring/epoll.c)
- [io_uring/bpf-ops.c (torvalds/linux master)](https://github.com/torvalds/linux/blob/master/io_uring/bpf-ops.c)
- [liburing man page: io_uring_prep_epoll_wait.3](https://github.com/axboe/liburing/blob/master/man/io_uring_prep_epoll_wait.3) — `io_uring_prep_epoll_wait(3)` 사용법
