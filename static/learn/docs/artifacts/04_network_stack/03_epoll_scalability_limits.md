# 스토리지 RPC 서버에서 epoll의 확장성 한계와 io_uring multishot 수신

> 기준: `fs/eventpoll.c`(메인라인 `master`, 2026-10 확인), `io_uring/{net,poll,kbuf,napi}.c`, `include/uapi/linux/io_uring.h`, `include/uapi/asm-generic/socket.h`. 락 관련 병합 시점은 torvalds/linux 커밋 메타데이터로 확인했다.

## 1. Verdict

`epoll`(Davide Libenzi, 2.5.44 개발 커널에서 도입, 2.6 안정 커널)은 `select()`/`poll()`이 매 호출마다 감시 집합 전체를 훑는 비용을 "관심 집합(RB-tree)"과 "준비 리스트(rdllist)"의 분리로 해결했고, 지금도 리눅스 이벤트 루프의 기본이다. 스토리지 RPC 서버(Ceph AsyncMessenger, NVMe-oF 사용자 공간 타겟, KV 서버)에서 epoll의 한계로 지적되는 것은 크게 세 가지다.

1. **준비성(readiness) 모델의 시스템 콜 왕복**: `epoll_wait()`로 준비된 fd를 받은 뒤 fd마다 `recv()`를 다시 호출해야 한다.
2. **인스턴스 공유 시 락·웨이크업 비용**: 여러 스레드가 하나의 epoll 인스턴스를 공유하면 `ep->lock`(준비 리스트), `ep->mtx`(이벤트 수집·ctl), 웨이크업(thundering herd)에서 경합이 생긴다.
3. **연결 수명 주기 비용**: 연결이 자주 생성·종료되면 `epoll_ctl()`과 fd close 경로의 락이 병목이 된다. 과거 전역 `epmutex`가 대표적이었다.

커널은 이 문제들을 하나씩 다뤘다. `EPOLLEXCLUSIVE`(4.5), busy polling(`SO_BUSY_POLL` 3.11, epoll busy poll 4.12, per-epoll 파라미터 `EPIOCSPARAMS` 6.9), 준비 리스트 락의 rwlock 전환(5.1)과 PREEMPT_RT 우선순위 역전 때문에 다시 spinlock으로의 복귀(6.18), 그리고 전역 `epmutex`를 중첩 epoll 경우로 축소한 refcount 도입(6.4)이 그것이다. 시스템 콜 왕복이라는 구조적 한계는 io_uring의 **완료(completion) 모델**이 해결 방향을 제시했다: multishot recv(`IORING_RECV_MULTISHOT`, 6.0) + ring-mapped provided buffers(`IORING_REGISTER_PBUF_RING`, 5.19)로 한 번 제출한 요청이 데이터 도착마다 CQE를 계속 만든다.

다만 io_uring을 "락리스", "시스템 콜 0회", "thundering herd 완전 면역"으로 설명하는 것은 정확하지 않다. io_uring도 `ctx->uring_lock`과 task_work를 쓰고, CQ 링을 비우기 위해 결국 `io_uring_enter()`로 대기하거나(SQPOLL이 아니라면) 제출해야 한다. 정확히 말하면 io_uring은 "데이터 수신 시스템 콜을 이벤트 대기와 합쳐 배치화"한다.

---

## 2. Problem Statement

### 2.1 epoll 데이터 구조와 락 계층 (현재 메인라인)
`struct eventpoll`(fs/eventpoll.c)의 핵심 필드는 다음과 같다.
- `struct mutex mtx`: 이벤트 수집 루프, ctl 연산, 파일 정리 경로를 직렬화(sleepable).
- `wait_queue_head_t wq`: `epoll_wait()` 대기자. `poll_wait`: epoll fd 자체를 다른 epoll이 감시할 때.
- `struct list_head rdllist`: 준비 리스트. `ovflist`: 스캔 중 도착한 이벤트를 임시로 받는 단일 연결 리스트.
- `spinlock_t lock`: `rdllist`/`ovflist` 보호. `seqcount_spinlock_t seq`: rdllist↔ovflist 전환 보호.
- `struct rb_root_cached rbr`: 감시 중인 `struct epitem`들의 RB-tree(`ep->mtx`로 보호).
- `busy_poll_usecs`, `busy_poll_budget`, `prefer_busy_poll`: 6.9의 per-epoll busy poll 설정.

현재 파일 머리 주석은 락 순서를 `epnested_mutex`(전역, EPOLL_CTL_ADD의 루프/경로 검사에만) > `ep->mtx`(인스턴스별) > `ep->lock`(인스턴스별, IRQ-safe spinlock)으로 정의한다. `ep->lock`이 spinlock인 이유는 `ep_poll_callback()`이 `wake_up()`을 통해 하드 IRQ 컨텍스트에서도 불릴 수 있기 때문이다.

### 2.2 공유 epoll vs 스레드별 epoll
- **공유 인스턴스**: 여러 워커가 같은 epfd로 `epoll_wait()`하면 부하는 자연히 분산되지만, 생산자(`ep_poll_callback()`, softirq에서 소켓 웨이크업)와 소비자(`ep_poll()`의 준비 리스트 스캔)가 같은 `ep->lock`을 두드린다. 또 이벤트 하나에 여러 대기자가 깨어나는 thundering herd가 생긴다. `EPOLLEXCLUSIVE`(4.5, Jason Baron)는 같은 대상 fd를 여러 epoll 인스턴스가 감시할 때 웨이크업을 하나(이상)로 제한하는 플래그로, 리스닝 소켓 공유에 주로 쓴다.
- **스레드별 인스턴스**: 락 경합은 사라지지만 연결 분배가 고정되어 부하 불균형이 생긴다. 리스닝 소켓은 `SO_REUSEPORT`로 스레드마다 하나씩 두고, 커널이 해시 또는 `SO_INCOMING_CPU`/BPF로 연결을 배정한다.

스토리지 서버 대부분(Ceph의 AsyncMessenger 워커, Seastar의 shard-per-core)은 후자를 택하고, 연결 단위로 워커를 고정한다.

### 2.3 준비성 모델의 왕복 비용
준비된 소켓이 N개면 `epoll_wait()` 1회 + `recv()` N회가 필요하다. Edge-triggered(`EPOLLET`)에서는 `EAGAIN`이 나올 때까지 읽어야 하므로 마지막 `recv()`는 빈 호출이 된다. Spectre/Meltdown 완화 이후 시스템 콜 진입 비용이 커지면서, µs 단위 NVMe 지연과 비교해 이 왕복이 무시할 수 없는 비중이 되었다.

### 2.4 연결 churn과 전역 락
연결마다 epoll 항목을 만들고 close 시 정리하는 서버(HTTP 게이트웨이, S3 RGW 프런트엔드 등)는 `eventpoll_release_file()` 경로에서 전역 `epmutex`를 잡았다. 6.4 이전에는 모든 epoll 인스턴스가 이 하나의 뮤텍스를 공유했다(3.2절 참조).

---

## 3. The Debate

아래는 커밋 메시지와 LWN으로 확인한 실제 논쟁이다. 멀티스레드 epoll에서 항목 삭제와 이벤트 전달이 경합하는 문제는 LWN "EPOLL_CTL_DISABLE and multithreaded applications"(2012)가 일찍이 정리했다.

### 3.1 준비 리스트 락: spinlock → rwlock(5.1) → spinlock(6.18)
Roman Penyaev는 2019년 `ep_poll_callback()`이 여러 CPU에서 동시에 불릴 때의 경합을 줄이기 위해, 생산자는 read lock을 잡고 `xchg`로 리스트 꼬리에 원자적으로 추가하며 소비자만 write lock을 잡는 구조를 제안했다(커밋 `a218cc491420`, 2019-03, Linux 5.1). 그의 마이크로벤치마크에서 8/16/32 스레드 events/ms가 각각 6402→10038, 7045→12178, 7395→13223으로 늘었다.

이 설계는 6년 뒤 실시간 커널 쪽에서 문제가 되었다.

> "Unfortunately, this implementation may cause scheduling priority inversion problem. Suppose the consumer has higher scheduling priority than the producer. The consumer needs to acquire the write lock, but may be blocked by the producer holding the read lock. Since read-write semaphore does not support priority-boosting for the readers (even with CONFIG_PREEMPT_RT=y), we have a case of priority inversion"
>
> — Nam Cao, "eventpoll: Replace rwlock with spinlock" (commit `0c43094f8cc9`, 작성 2025-07-15, vfs 트리 커밋 2025-09-05), https://github.com/torvalds/linux/commit/0c43094f8cc9

해설: 같은 커밋 메시지는 대가도 숫자로 남겼다. Penyaev의 `stress-epoll` 벤치마크로 12코어 x86에서 8/16/32 스레드 events/ms가 각각 -31%, -38%, -30% 감소했다. 즉 커뮤니티는 "많은 생산자에 대한 처리량"보다 "PREEMPT_RT에서의 결정성과 단순성"을 택했다. 커밋 메시지는 부하가 낮은 `perf bench epoll wait`에서는 x86에서 오히려 개선이 관측되었다는 점, 그리고 rwlock 전환 커밋이 실제 워크로드가 아닌 벤치마크만 근거로 삼았다는 점도 함께 적는다. 이에 앞서 같은 저자의 다른 접근(`8c44dac8add7`, "eventpoll: Fix priority inversion problem")은 Linux 6.16-rc 주기에 병합되었다가, Linus Torvalds가 부팅·로그인 시 프로세스 지연 회귀를 bisect해 2025-07-11 되돌렸다(`5f02b80c21e1`). 이후 단순 rwlock→spinlock 교체인 `0c43094f8cc9`가 Linux 6.18에 들어갔다(vfs-6.18-rc1.misc). 정리하면 `ep->lock`은 Linux 5.1~6.17에서 `rwlock_t`, 그 전과 Linux 6.18부터는 `spinlock_t`다.

### 3.2 전역 epmutex 제거 (6.4)
Paolo Abeni(Red Hat)는 nginx 연결률 테스트에서 `eventpoll_release_file()`의 `epmutex` 대기가 프로파일 상위를 차지하는 것을 보고했다.

> "We are observing huge contention on the epmutex during an http connection/rate test [...] The application is multi-threaded, creates a new epoll entry for each incoming connection, and does not delete it before the connection shutdown - that is, before the connection's fd close(). Many different threads compete frequently for the epmutex lock, affecting the overall performance."
>
> — Paolo Abeni, "epoll: use refcount to reduce ep_mutex contention" (commit `58c9b016e128`, 2023-03-22 작성), https://github.com/torvalds/linux/commit/58c9b016e128

해결은 `struct eventpoll`에 명시적 참조 카운트를 두고(등록된 epitem마다 참조), epoll 파일 close와 감시 대상 파일 close 중 마지막으로 참조를 놓는 쪽이 해제하는 방식이다. 두 close가 경합할 때를 위해 `f_lock` 아래에서 epitem에 `dying` 표시를 한다. 그 결과 `epmutex`는 해제 경로에서 빠졌고, Davidlohr Bueso가 남은 용도(중첩 epoll의 루프 검사)에 맞게 `epnested_mutex`로 이름을 바꿨다(`d4cb626d6f3e`). 두 커밋 모두 2023-04-27 Andrew Morton의 non-MM 풀로 6.4에 들어갔다. 일반적인 `EPOLL_CTL_ADD`/`DEL`은 인스턴스별 `ep->mtx`만 잡는다.

### 3.3 busy polling: 인터럽트 지연을 CPU로 사는 선택
- **`SO_BUSY_POLL` (3.11, Eliezer Tamir, Intel)**: LWN "Low-latency Ethernet device polling"(2013)이 소개한 기능으로, 소켓 읽기·poll 시 수신 큐가 비어 있으면 해당 NAPI 컨텍스트를 직접 폴링한다. 전역 기본값은 `net.core.busy_read`/`net.core.busy_poll` sysctl.
- **epoll busy poll (4.12, Sridhar Samudrala)**: 준비 리스트에 마지막으로 추가된 소켓의 NAPI ID를 기억해 `epoll_wait()`에서 그 NAPI를 busy poll한다(커밋 `bf3b9f6372c4`). 한 epoll 인스턴스의 소켓들이 같은 NAPI(RX 큐)에 모여 있어야 효과적이므로, RX 큐 ↔ 워커 스레드 정렬이 전제다.
- **`SO_PREFER_BUSY_POLL`/`SO_BUSY_POLL_BUDGET` (5.11, Björn Töpel)**, **per-epoll `EPIOCSPARAMS`/`EPIOCGPARAMS` (6.9, Joe Damato)**: busy poll을 쓰는 동안 softirq 처리를 미뤄 애플리케이션 스레드가 NAPI를 주도하게 한다.

### 3.4 SO_INCOMING_CPU의 실제 의미
"`SO_INCOMING_CPU`를 설정하면 커널이 같은 CPU의 epoll 워커로 연결을 배정한다"는 설명은 부정확하다. `SO_INCOMING_CPU`(3.19, Eric Dumazet)는 getsockopt로 마지막 수신 CPU를 읽는 데 쓰이고, setsockopt로 리스너에 CPU를 지정하면 `SO_REUSEPORT` 그룹에서 해당 CPU가 처리한 흐름이 그 리스너로 **우선 선택**된다(`compute_score()`). 이 조합은 4.6의 reuseport 고속 선택 알고리즘 이후 무시되던 버그가 있었고, Kuniyuki Iwashima가 2022년 10월 수정했다(`b261eda84ec1`). epoll 자체가 연결을 배정하는 기능은 없다.

### 3.5 io_uring: 준비성에서 완료로
io_uring은 소켓에 대해 "준비되면 알려 달라"가 아니라 "받으면 알려 달라"를 제출한다. 네트워크 기능의 흐름은 다음 순서로 쌓였다.
- `IORING_OP_PROVIDE_BUFFERS`(5.7): 커널이 수신 시점에 버퍼를 고르는 provided buffer.
- `IORING_REGISTER_PBUF_RING`(5.19): provided buffer를 공유 메모리 링으로 공급(ring-mapped). SQE 없이 버퍼를 보충할 수 있다.
- `IORING_ACCEPT_MULTISHOT`(5.19): accept 한 번 제출로 연결마다 CQE.
- `IORING_RECV_MULTISHOT`(6.0, Dylan Yudaken, 커밋 `b3fdea6ecb55`): 5.19에 들어간 것은 multishot accept이며 multishot recv는 한 버전 뒤다.
- `IORING_REGISTER_NAPI`(6.9): io_uring 대기 중 NAPI busy poll. `IORING_RECVSEND_BUNDLE`(6.10): 한 CQE로 여러 버퍼 묶음 수신.

---

## 4. Implementation Impact

### 4.1 epoll 콜패스와 락 (메인라인 기준)
```
[생산자: softirq/IRQ]
tcp_data_queue() → sk->sk_data_ready() → wake_up(sk_sleep)
  └─ ep_poll_callback()                    /* spin_lock_irqsave(&ep->lock) */
       ├─ 스캔 중이면 ovflist에, 아니면 rdllist에 epitem 추가
       ├─ ep_set_busy_poll_napi_id()        /* busy poll용 NAPI ID 기록 */
       └─ wake_up(&ep->wq)                  /* EPOLLEXCLUSIVE면 배타적 웨이크업 */

[소비자: epoll_wait()]
do_epoll_wait() → ep_poll()
  ├─ ep_busy_loop()                        /* busy_poll_usecs 또는 net.core.busy_poll */
  ├─ ep_events_available() ? : 대기(ep->wq)
  └─ ep_try_send_events() → ep_send_events()
       ├─ mutex_lock(&ep->mtx)
       ├─ ep_start_scan(): ep->lock 아래에서 rdllist를 로컬 배치로 떼어내고 ovflist 활성화
       ├─ 각 epitem: ep_item_poll() 재확인 → copy_to_user(epoll_event)
       │    LT 모드면 rdllist에 재삽입
       └─ ep_done_scan(): ovflist에 쌓인 항목을 rdllist로 되돌림

[ctl]
do_epoll_ctl(): ep->mtx (+ 중첩 epoll ADD일 때만 epnested_mutex)
  └─ ep_insert(): epitem 할당, rbr 삽입, f_op->poll()로 웨이트 큐 등록
```
핵심은 `ep->lock`의 임계 구역이 리스트 조작으로 짧게 유지되고, `copy_to_user()`처럼 잠들 수 있는 작업은 `ep->mtx` 아래에서 한다는 점이다. 생산자가 많은 경우의 처리량은 `ep->lock` 경합으로 결정되며, 이것이 5.1의 rwlock 실험과 6.18의 복귀가 겨냥한 지점이다.

### 4.2 io_uring multishot recv 콜패스
```
제출 (1회): sqe->opcode = IORING_OP_RECV, sqe->ioprio |= IORING_RECV_MULTISHOT,
            sqe->flags |= IOSQE_BUFFER_SELECT, sqe->buf_group = <PBUF_RING bgid>
io_recv()                                       /* io_uring/net.c */
 ├─ io_recv_buf_select() → io_buffer_select() → io_ring_buffer_select()  /* kbuf.c */
 ├─ sock_recvmsg(MSG_DONTWAIT)
 │    ├─ 데이터 있음 → io_recv_finish(): io_req_post_cqe(res, cflags | IORING_CQE_F_MORE)
 │    │                  cflags 상위 16비트(IORING_CQE_BUFFER_SHIFT)에 버퍼 ID
 │    │                  → 다시 수신 시도(MULTISHOT_MAX_RETRY = 32회까지, 이후 재큐잉)
 │    └─ -EAGAIN → io_arm_apoll(): 소켓 웨이트 큐에 poll 엔트리 등록
 └─ 이후 데이터 도착:
      sk_data_ready → io_poll_wake() → __io_poll_execute() → task_work 큐잉
      (요청을 소유한 태스크 컨텍스트에서) io_poll_task_func() → io_poll_issue() → io_recv() 반복
종료: 버퍼 고갈(-ENOBUFS), 에러, EOF 시 IORING_CQE_F_MORE 없는 마지막 CQE
```
multishot recv가 드라이버 NAPI 컨텍스트에서 직접 실행되는 것은 아니다. NAPI/softirq에서는 웨이크업 콜백(`io_poll_wake()`)이 task_work를 큐잉할 뿐이고, 실제 `sock_recvmsg()`와 CQE 기록은 태스크 컨텍스트에서 일어난다. `IORING_SETUP_DEFER_TASKRUN`(6.1)을 쓰면 이 task_work가 애플리케이션이 `io_uring_enter(GETEVENTS)`로 대기할 때 일괄 실행되어 IPI·인터럽트성 실행이 줄어든다. `io_recvmsg_multishot()`는 `IORING_OP_RECVMSG` multishot용으로 별개 함수다.

### 4.3 자료구조 구분: `struct io_rings` vs `struct io_ring_ctx`
`struct io_ring_ctx`는 사용자 공간과 공유되는 링이 아니다. 사용자와 mmap으로 공유되는 것은 `struct io_rings`(SQ/CQ의 `head`/`tail`을 담은 `struct io_uring sq, cq`, CQE 배열 등)이다. `struct io_ring_ctx`는 커널 내부 컨텍스트로 `struct mutex uring_lock`, NAPI 목록(`napi_list`, `napi_lock`) 등을 가진다. 링 인덱스는 `smp_load_acquire()`/`smp_store_release()`로 주고받으므로 공유 링 자체에 락이 없다는 것은 맞지만, 제출·완료 처리 내부에는 `uring_lock`과 completion lock이 존재한다.

### 4.4 이벤트 모델 비교
| 비교 지표 | epoll (LT/ET) | epoll + busy poll | io_uring multishot recv + PBUF_RING |
|---|---|---|---|
| 모델 | 준비성 통지 | 준비성 통지 | 완료 통지 |
| N개 소켓 수신 시 시스템 콜 | `epoll_wait` 1 + `recv` N (ET는 EAGAIN 확인 추가) | 동일 | 대기/수확용 `io_uring_enter` 1회로 여러 CQE (SQPOLL 시 더 감소). 0회는 아님 |
| 공유 상태의 락 | `ep->lock`(spinlock; 5.1~6.17은 rwlock), `ep->mtx` | 동일 + NAPI 소유권 | 소켓 락 + `uring_lock` + CQ 기록; 공유 링 인덱스는 acquire/release |
| 웨이크업 | 공유 인스턴스는 thundering herd 가능, `EPOLLEXCLUSIVE`로 완화 | 동일 | 요청이 링에 귀속되므로 다중 대기자 문제 적음 |
| 버퍼 할당 시점 | `recv()` 호출 전 사용자가 지정 | 동일 | 데이터 도착 시 커널이 버퍼 링에서 선택 → 유휴 연결이 버퍼를 점유하지 않음 |
| 생산자 실행 위치 | softirq에서 `ep_poll_callback()` | 동일, busy poll 시 앱 스레드가 NAPI 구동 | softirq에서 `io_poll_wake()` → task_work로 recv |
| 도입 | 2.5.44 / `EPOLLEXCLUSIVE` 4.5 | `SO_BUSY_POLL` 3.11, epoll 4.12, `EPIOCSPARAMS` 6.9 | PBUF_RING 5.19, RECV_MULTISHOT 6.0, NAPI 6.9 |

### 4.5 락 변경 연표
| 커널 | 변경 | 커밋 / 주체 |
|---|---|---|
| 4.5 | `EPOLLEXCLUSIVE` | Jason Baron (`df0108c5da56`) |
| 4.12 | epoll busy poll | Sridhar Samudrala (`bf3b9f6372c4`) |
| 5.1 | `ep->lock` → `rwlock_t` + `xchg` 리스트 추가 | Roman Penyaev (`a218cc491420`) |
| 6.4 | `struct eventpoll` refcount, 해제 경로에서 `epmutex` 제거 → `epnested_mutex` | Paolo Abeni (`58c9b016e128`), Davidlohr Bueso (`d4cb626d6f3e`) |
| 6.9 | per-epoll busy poll `EPIOCSPARAMS` | Joe Damato |
| 6.18 | `ep->lock` → `spinlock_t` 복귀 (PREEMPT_RT 우선순위 역전) | Nam Cao (`0c43094f8cc9`) |

### 4.6 스토리지 서버 설계 시사점
- 연결 수가 많고 유휴 연결이 대부분이면 provided buffer ring의 이점(버퍼를 도착 시점에만 소비)이 크다. 반대로 버퍼 링이 고갈되면 multishot이 `-ENOBUFS`로 끝나므로 재무장 로직이 필요하다.
- busy poll은 지연을 줄이지만 코어를 소모한다. RX 큐 수, IRQ affinity, 워커 수를 1:1로 맞추지 않으면 효과가 작다.
- 6.18의 spinlock 복귀는 PREEMPT_RT 문제를 고치기 위한 것이지만 처리량 감소는 일반 커널에도 적용된다. 하나의 epoll 인스턴스에 다수 생산자가 몰리는 워크로드는 커밋 메시지 기준 -30% 안팎의 events/ms 감소를 겪을 수 있으므로 커널 업그레이드 시 측정이 필요하다. 2026년에는 이 변경이 PREEMPT_RT 격리 코어에서 오히려 지연 스파이크를 만든다는 회귀 보고도 LKML에 올라왔다 `[추측/미확인: 후속 처리 결과 미확인]`.

---

## 5. Primary References

- [EPOLL_CTL_DISABLE and multithreaded applications (LWN, 2012)](https://lwn.net/Articles/520012/) — 멀티스레드 epoll에서 항목 삭제 경합 문제.
- [Epoll evolving (LWN, 2015)](https://lwn.net/Articles/633422/) — epoll 확장 제안들(배타적 웨이크업 등)의 배경.
- [Low-latency Ethernet device polling (LWN, 2013)](https://lwn.net/Articles/551284/) — Eliezer Tamir의 busy poll(3.11).
- [epoll: use rwlock in order to reduce ep_poll_callback() contention (commit a218cc491420)](https://github.com/torvalds/linux/commit/a218cc491420) — 5.1 rwlock 전환과 벤치마크.
- [epoll: use refcount to reduce ep_mutex contention (commit 58c9b016e128)](https://github.com/torvalds/linux/commit/58c9b016e128) — 6.4 epmutex 경합 제거.
- [eventpoll: Replace rwlock with spinlock (commit 0c43094f8cc9)](https://github.com/torvalds/linux/commit/0c43094f8cc9) — 6.18 spinlock 복귀와 처리량 대가.
- [epoll: Add busy poll support to epoll with socket fds. (commit bf3b9f6372c4)](https://github.com/torvalds/linux/commit/bf3b9f6372c4) — 4.12 epoll busy poll.
- [io_uring: multishot recv (commit b3fdea6ecb55)](https://github.com/torvalds/linux/commit/b3fdea6ecb55) — 6.0 multishot recv.
- [NAPI — The Linux Kernel documentation](https://www.kernel.org/doc/html/latest/networking/napi.html) — busy polling, `SO_PREFER_BUSY_POLL`, epoll 파라미터.
