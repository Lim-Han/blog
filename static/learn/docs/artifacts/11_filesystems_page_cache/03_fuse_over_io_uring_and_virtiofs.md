# FUSE의 데이터 경로 진화: `/dev/fuse` 큐, passthrough, FUSE-over-io_uring, 그리고 virtiofs

> 기준: Linux `torvalds/linux` master(7.3-rc7, 2026-10 확인)의 `fs/fuse/{dev.c,dev_uring.c,dev_uring_i.h,fuse_dev_i.h,fuse_i.h,inode.c,backing.c,passthrough.c,iomode.c,virtio_fs.c,dax.c}`, `include/uapi/linux/fuse.h`(프로토콜 7.46), `Documentation/filesystems/fuse/fuse-io-uring.rst`. 프로토콜 마이너 버전과 기능의 도입 커널은 git.kernel.org에서 태그별(`?h=vX.Y`) `fuse.h`를 받아 `FUSE_KERNEL_MINOR_VERSION`과 심볼 최초 등장으로 고정했다. 사용자 공간은 libfuse master와 릴리스 `fuse-3.18.3`(2026-09-08)의 `lib/fuse_uring.c`, `lib/fuse_lowlevel.c`, `ChangeLog.rst`를 대조했다. 블록 장치 쪽 사용자 공간 프레임워크인 ublk는 별도 문서(→ 09/05), 가상화 스토리지 경로는 (→ 09/04), io_uring `IORING_OP_URING_CMD` 자체는 (→ 01/01)을 참조한다.

## 1. Verdict

**기준 버전: Linux 7.3-rc7 master(FUSE 프로토콜 7.46), libfuse 3.18.3.**

FUSE는 2005년(2.6.14, 프로토콜 7.2)부터 "VFS 요청을 `struct fuse_req`로 직렬화해 `/dev/fuse`의 `read()`로 서버에 넘기고, `write()`로 답을 받는" 구조를 유지해 왔다. 지난 20년간 바뀐 것은 이 인터페이스 자체가 아니라 **그 주변의 우회로**다. 세 갈래가 있다.

| 커널 | 프로토콜 | 변화 | 데이터 경로에 미친 영향 |
|---|---|---|---|
| 2.6.14 | 7.2 | FUSE 메인라인 병합 | `/dev/fuse` read/write, 요청당 최소 2회 복사 |
| 2.6.35 | 7.14 | `/dev/fuse` splice(`FUSE_SPLICE_READ/WRITE/MOVE`) | 페이지를 pipe로 옮겨 복사 1회 절감(조건부) |
| 4.2 | 7.23 | `FUSE_DEV_IOC_CLONE` | 다중 스레드 서버가 fd를 복제해 `fuse_pqueue`를 분산 |
| 5.4 | 7.31 | virtiofs(`virtio_fs.c`) | FUSE 메시지를 virtqueue로 전달, VM 게스트용 공유 파일 시스템 |
| 5.10 | 7.32 | virtiofs DAX(`fs/fuse/dax.c`; `FUSE_SETUPMAPPING`/`REMOVEMAPPING` opcode 정의는 5.4/7.31에 먼저 들어옴) | 호스트 페이지 캐시를 게스트 주소 공간에 직접 매핑 |
| 5.17 | 7.36 | `dax=always/never/inode` 마운트 옵션, `FUSE_ATTR_DAX` | inode 단위 DAX 선택 |
| 6.9 | 7.40 | `FUSE_PASSTHROUGH`, `FOPEN_PASSTHROUGH`, `FUSE_DEV_IOC_BACKING_OPEN/CLOSE` | read/write/splice/mmap을 백킹 파일로 직행. 서버 왕복 0회 |
| 6.10 | 7.40 | virtiofs 다중 request virtqueue(`mq_map`) | CPU별 virtqueue 매핑 |
| 6.14 | 7.42 | FUSE-over-io_uring(`FUSE_OVER_IO_URING`, `FUSE_IO_URING_CMD_REGISTER`/`COMMIT_AND_FETCH`) | CPU별 링 큐, 커밋+페치 결합, 컨텍스트 전환 감소 |
| 6.15 | 7.43 | `FUSE_REQUEST_TIMEOUT` | 응답 없는 서버로 인한 무한 대기 방지 |
| 6.18 | 7.45 | `FUSE_DEV_IOC_SYNC_INIT` | `FUSE_INIT`를 마운트 중 동기 처리 |
| 7.2 | 7.45 | `struct fuse_chan` 분리(전송 계층과 fs 계층 분리) | 백그라운드 큐·io_uring 상태가 `fuse_conn`에서 `fuse_chan`으로 이동 |
| 7.3-rc | 7.46 | `FUSE_IO_URING_CMD_ADD_QUEUE`/`ADD_BUFPOOL`, `FUSE_URING_ZERO_COPY`, `FOPEN_IO_URING_ZERO_COPY` | 버퍼 풀과 io_uring 고정 버퍼 기반 **제로카피** |

결론:

1. **FUSE-over-io_uring은 ublk의 프로토콜을 파일 시스템에 이식한 것이다.** 서버가 `IORING_OP_URING_CMD` SQE를 미리 넣어 두면, 커널은 `fuse_req`가 생길 때 그 명령을 완료(CQE)시켜 요청을 전달한다. 서버는 답을 쓰면서 동시에 다음 요청을 기다리는 `FUSE_IO_URING_CMD_COMMIT_AND_FETCH`를 제출한다. Bernd Schubert(DDN)가 2023년 RFC부터 v10(2025-01-20)까지 끌고 왔고, Linux 6.14 merge window(병합 커밋 `92cc9acff719`, 2025-01-29)에 들어왔다. 큐는 `num_possible_cpus()`개이고 요청은 `task_cpu(current)`로 큐가 정해진다(4.3절).
2. **기본값은 꺼져 있다.** 커널은 `fuse` 모듈 파라미터 `enable_uring`(기본 false)이 켜져 있어야 `FUSE_INIT`에서 `FUSE_OVER_IO_URING`을 받아들인다. libfuse도 `SESSION_DEF_URING_ENABLE (0)`이며 `-o io_uring`이나 환경 변수 `FUSE_URING_ENABLE=1`로 켠다. 큐 깊이 기본값은 `SESSION_DEF_URING_Q_DEPTH (8)`이다. 링 등록 전과 알림(notify)·인터럽트는 여전히 `/dev/fuse` read/write를 쓴다.
3. **passthrough는 "서버를 데이터 경로에서 빼는" 정반대 접근이다.** 6.9의 `FOPEN_PASSTHROUGH`는 서버가 `open` 응답에 `backing_id`를 실어 보내면 이후 read/write/splice/mmap을 커널이 백킹 파일에 직접 수행하게 한다. 대가는 권한이다. `fuse_backing_open()`은 지금도 `capable(CAP_SYS_ADMIN)`을 요구한다. 또 `FUSE_WRITEBACK_CACHE`와 함께 쓸 수 없다(`inode.c` 주석: "current design doesn't handle them together").
4. **7.3의 버퍼 풀과 제로카피(Joanne Koong)는 io_uring 경로의 메모리·복사 비용을 직접 겨냥한다.** 엔트리마다 최대 페이로드 크기 버퍼를 잡는 기존 방식은 LSFMM+BPF 2026에서 메모리 낭비로 지적되었다(3.3절). 제로카피는 ublk가 6.15에서 정착시킨 `io_buffer_register_bvec()`(→ 09/05, 3.1절)을 재사용해 클라이언트 페이지를 서버 io_uring의 등록 버퍼 테이블에 꽂는다. `FUSE_URING_ZERO_COPY` 큐 생성에는 `CAP_SYS_ADMIN`이 필요하다.
5. **virtiofs는 같은 FUSE 프로토콜을 다른 전송 계층에 올린 것이다.** `/dev/fuse` 대신 virtqueue(`hiprio` 1개 + `requests.N`)로 메시지를 보내고, 선택적으로 PCI 공유 메모리 영역(`VIRTIO_FS_SHMCAP_ID_CACHE`)을 DAX 창으로 써서 게스트 페이지 캐시 복제를 없앤다. 호스트 쪽 데몬은 QEMU 8.0에서 C 구현이 제거되고 Rust `virtiofsd`로 일원화되었다.

---

## 2. Problem Statement

### 2.1 고전 `/dev/fuse` 경로의 비용 구조

`read(2)` 하나가 FUSE 파일에 도달하면 커널에서는 대략 다음이 일어난다(master 기준 함수명).

1. `fuse_file_read_iter()` → 캐시 모드면 페이지 캐시 미스 시 `fuse_readahead()`가 `FUSE_READ` 요청을 **백그라운드**로 보낸다. 직접 I/O면 `fuse_direct_io()`가 동기 요청을 만든다.
2. 요청은 fs 계층의 `fuse_simple_request()`/`fuse_simple_background()`에서 만들어지고, master에서는 `fs/fuse/req.c`가 이를 전송 계층의 `fuse_chan_send()`/`fuse_chan_send_bg()`로 넘긴다. 그 뒤 `struct fuse_iqueue`의 `pending` 리스트에 걸린다(`fuse_dev_queue_req()`). 서버 스레드의 `read()`를 깨운다.
3. 서버 스레드가 `fuse_dev_do_read()`로 요청을 꺼내면, 커널은 헤더와 인자를 사용자 버퍼로 **복사**하고 요청을 `struct fuse_pqueue`의 `processing` 해시(`FUSE_PQ_HASH_SIZE` = 256 버킷)로 옮긴다.
4. 서버가 백엔드에서 데이터를 읽은 뒤 `write()`하면 `fuse_dev_do_write()`가 `unique` ID로 요청을 찾아 응답 페이로드를 페이지에 **복사**하고 `fuse_request_end()`로 대기자를 깨운다.

요청 하나당 최소 두 번의 시스템 콜(서버 `read`/`write`), 두 번의 컨텍스트 전환, 두 번의 데이터 복사(커널↔서버, 서버↔백엔드)가 든다. 여기에 **CPU 이동** 문제가 겹친다. 요청을 낸 스레드가 CPU 3에서 잠들고, 서버 스레드가 CPU 17에서 깨어 처리하고, 완료가 다시 CPU 3의 대기자를 깨운다. 캐시 라인과 스케줄러 wake-up이 소켓 경계를 넘나든다. Schubert의 LSFMM 2023 발표는 이 이동을 막았을 때(migration 비활성화) io_uring 이득이 훨씬 커졌다고 보고했다(LWN 2023-05-19).

### 2.2 백그라운드 큐와 `max_background`

읽기 선행(readahead), 비동기 직접 I/O, writeback 같은 "대기자가 없는" 요청은 `FR_BACKGROUND` 비트를 달고 별도 경로를 탄다(`fuse_request_queue_background()`).

- `fuse_chan`(7.2 이전 `fuse_conn`)의 `num_background`가 `max_background`에 도달하면 `blocked = 1`이 되고, 새 요청 할당자는 `blocked_waitq`에서 잠든다.
- 실제로 서버에 보낸 수는 `active_background`로 따로 센다. `flush_bg_queue()`는 `active_background < max_background`인 동안만 `bg_queue`에서 꺼내 `fuse_send_one()`으로 보낸다.
- 기본값은 `FUSE_DEFAULT_MAX_BACKGROUND` = 12, `congestion_threshold` 기본은 그 3/4(9)다. 서버는 `FUSE_INIT` 응답의 `max_background`로 늘릴 수 있다. 비특권 서버는 모듈 파라미터 `max_user_bgreq`/`max_user_congthresh`로 상한이 걸린다. 운영 중에는 `/sys/fs/fuse/connections/<N>/max_background`로 바꿀 수 있다.

12라는 기본값은 HDD 시절 값이다. NVMe나 네트워크 백엔드에서 순차 읽기 처리량이 기대보다 낮다면 이 값과 libfuse의 `max_background` 설정부터 봐야 한다. libfuse는 `max_background`를 `1 << 16` 미만으로 자르고, `congestion_threshold`를 기본 3/4로 맞춘다(`fuse_lowlevel.c`).

### 2.3 왜 단순히 스레드를 늘리는 것으로 부족한가

`FUSE_DEV_IOC_CLONE`(4.2)으로 서버 스레드마다 별도 `/dev/fuse` fd를 가지면 `fuse_pqueue`는 fd별로 분리된다. 그러나 입력 큐 `fuse_iqueue`는 연결당 하나이고 `fiq->lock` 아래에서 모든 스레드가 같은 `pending` 리스트를 두고 경쟁한다. 요청을 "어느 CPU의 서버 스레드가 받을지"를 커널이 정하지 못하므로 NUMA 지역성도 보장되지 않는다. io_uring 전송은 이 두 문제(공유 입력 큐, CPU 무관 배분)를 CPU별 큐로 바꾸는 것이 핵심 동기다.

### 2.4 데이터를 서버가 볼 필요가 없는 경우

Android의 `/sdcard` 에뮬레이션, 컨테이너의 권한 재매핑 파일 시스템, 오버레이형 FUSE처럼 **메타데이터만 가공하고 데이터는 하부 파일 그대로**인 경우가 많다. 이때 데이터가 서버를 통과하는 것 자체가 낭비다. Google은 이를 위해 FUSE-BPF(Daniel Rosenberg)를 제안했고, Miklos Szeredi와 Amir Goldstein은 커널이 백킹 파일로 바로 가는 passthrough를 추진했다. 메인라인은 후자를 6.9에 받았다(3.2절).

### 2.5 VM 공유 파일 시스템의 문제

virtio-9p는 프로토콜 왕복이 많고 POSIX 의미론이 약했다. NFS over virtio-net은 네트워크 스택을 두 번 탄다. virtiofs의 요구 사항은 "로컬 파일 시스템 의미론 + 게스트·호스트 간 페이지 캐시 공유"였고, 이를 위해 이미 성숙한 FUSE 프로토콜을 virtio 전송에 얹었다. 남은 문제는 게스트와 호스트가 같은 데이터를 각자 캐싱하는 이중 캐시이며, DAX 창이 그 해법이다(4.6절).

---

## 3. The Debate

### 3.1 FUSE-over-io_uring: ublk 모델을 파일 시스템에 가져올 것인가

Schubert는 DDN의 네트워크 스토리지 제품에서 FUSE가 병목이 된다는 문제의식에서 출발했다. 2023년 LSFMM+BPF 세션(LWN, Jake Edge, 2023-05-19)에서 소개된 첫 RFC는 "코어당 스레드 하나, 링 하나, 그리고 큐 ID를 오프셋으로 하는 공유 메모리 버퍼를 사용자 공간이 `mmap()`하는" 구조였다. 같은 기사는 그가 기존 FUSE 파일 시스템이 코드 변경 없이 이득을 보도록 **libfuse 안에서 투명하게** 처리하는 것을 목표로 삼았다고 전한다.

최종 병합본(v10, Message-ID `20250120-fuse-uring-for-6-10-rfc4-v10-0-ca7c5d1007c0@ddn.com`)은 두 가지가 달라졌다.

- **커널이 할당해 `mmap`시키던 버퍼가 사라지고, 서버가 SQE에 iovec 두 개(헤더, 페이로드)를 넘긴다.** `fuse_uring_get_iovec_from_sqe()`가 `FUSE_URING_IOV_SEGS` = 2를 검사한다. 헤더 영역은 `struct fuse_uring_req_header`(in/out 헤더 128바이트 + opcode별 헤더 128바이트 + `struct fuse_uring_ent_in_out`)로 고정되었다. 수명·권한 관리가 단순해지는 대신, 엔트리마다 최대 크기 페이로드 버퍼를 서버가 잡아야 하는 메모리 문제가 남았고, 이것이 3.3절의 논쟁으로 이어진다.
- **명령이 두 개로 정리되었다.** `FUSE_IO_URING_CMD_REGISTER`(엔트리 등록 + 첫 요청 대기)와 `FUSE_IO_URING_CMD_COMMIT_AND_FETCH`(결과 커밋 + 다음 요청 대기)다. ublk의 `FETCH_REQ`/`COMMIT_AND_FETCH_REQ`와 같은 형태다(→ 09/05, 4.2절). 커버 레터 스스로 접근법을 ublk에서 가져왔다고 밝힌다.

v10 커버 레터는 동기를 이렇게 적었다.

> "Motivation for these patches is all to increase fuse performance, by:
> - Reducing kernel/userspace context switches
>     - Part of that is given by the ring ring - handling multiple requests on either side of kernel/userspace without the need to switch per request
>     - Part of that is FUSE_URING_REQ_COMMIT_AND_FETCH, i.e. submitting the result of a request and fetching the next fuse request in one step. In contrary to legacy read/write to /dev/fuse
> - Core and numa affinity - one ring per core, which allows to avoid cpu core context switches"
>
> — Bernd Schubert, "fuse: fuse-over-io-uring" v10 커버 레터, 2025-01-20 ([lwn.net/Articles/1005648](https://lwn.net/Articles/1005648/))

해설: 커버 레터와 커널 문서(`fuse-io-uring.rst`)에는 `FUSE_URING_REQ_COMMIT_AND_FETCH`라는 옛 이름이 남아 있지만, uAPI의 실제 enum은 `FUSE_IO_URING_CMD_COMMIT_AND_FETCH`(값 2)다. 이득의 원천은 두 가지다. 하나는 배치(한 번의 `io_uring_enter()`로 여러 CQE/SQE 처리)와 커밋·페치 결합으로 시스템 콜 수를 줄이는 것이다. 다른 하나는 요청을 낸 CPU의 큐로 보내 CPU 간 이동을 없애는 것이다. 같은 커버 레터는 벤치마크 결과가 RFCv1 때 수치이고, 같은 코어에서 깨우기(wake-up on the same core) 같은 최적화 패치가 빠져 있어 현재 시리즈의 성능은 "더 낮을 것"이라고 단서를 달았다. 따라서 6.14 병합본의 성능을 RFC 수치로 인용해서는 안 된다.

Miklos Szeredi의 6.14 pull 요청(병합 커밋 `92cc9acff7194b1b9db078901f2a83182bb73202`, 2025-01-29)은 리뷰 경과를 이렇게 요약한다.

> "Add support for io-uring communication between kernel and userspace using IORING_OP_URING_CMD (Bernd Schubert). Following features enable gains in performance compared to the regular interface: [...] Patches were reviewed by several people, including Pavel Begunkov, io-uring co-maintainer"
>
> — Miklos Szeredi, "Merge tag 'fuse-update-6.14'", 2025-01-29 ([github.com/torvalds/linux/commit/92cc9acff719](https://github.com/torvalds/linux/commit/92cc9acff7194b1b9db078901f2a83182bb73202))

해설: io_uring 코어 쪽 변경 없이 `uring_cmd` 인터페이스(`io_uring_cmd_done()`, `io_uring_cmd_complete_in_task()`, `io_uring_cmd_mark_cancelable()`)만 소비하는 구조라 io_uring 메인테이너의 리뷰가 관건이었다. 개별 커밋에도 `Reviewed-by: Pavel Begunkov ... # io_uring`이 붙어 있다(예: `786412a73e7e` "fuse: enable fuse-over-io-uring").

남은 쟁점은 다음과 같다.

1. **"모든 큐가 준비되어야 시작"이라는 조건.** `is_ring_ready()`는 모든 qid의 큐가 존재하고 각자 `ent_avail_queue`에 엔트리가 하나 이상 있어야 `ring->ready`를 세운다. 그 전까지 요청은 `/dev/fuse`로 간다. 서버는 `nr_cpu_ids`가 아니라 `num_possible_cpus()` 개수만큼 큐를 채워야 한다. CPU가 수백 개인 서버에서는 큐 수 × 깊이 × 페이로드 크기의 메모리가 든다.
2. **CPU 고정의 비용.** 큐 선택은 `task_cpu(current)`로 고정된다. 부하가 일부 CPU에 몰리면 다른 큐의 엔트리는 놀고 있어도 그 CPU의 큐에서 기다린다. 백그라운드 요청은 `fuse_uring_flush_bg()`가 "큐당 최소 1개는 전역 `max_background`를 무시하고 허용"하는 예외를 둔다. 한 큐가 전역 한도를 다 쓰는 것을 막고 원격 큐 깨우기를 없애기 위해서다.
3. **완전 대체가 아니다.** 커널 문서는 알림(서버 시작 메시지)과 인터럽트가 io_uring으로 오지 않으므로 서버가 `/dev/fuse` 처리도 계속해야 한다고 명시한다.

### 3.2 passthrough vs FUSE-BPF: 어디까지 커널이 대신할 것인가

LSFMM+BPF 2023의 FUSE passthrough 세션(LWN, 2023-05-17)에서 Miklos Szeredi는 매핑의 단위(파일, inode, 범위)를 핵심 질문으로 제시했다. 보안 쪽 쟁점은 FUSE 응답 메시지로 파일 디스크립터를 넘기는 방식이었다. 권한 있는 프로그램이 속아서 `/dev/fuse`에 `write()`를 하도록 만드는 것은 가능하지만, 특정 `ioctl()`을 호출하도록 속이기는 훨씬 어렵다는 논리로, 백킹 파일 등록은 `ioctl()`로 하자는 방향이 정해졌다(Christian Brauner는 seccomp notifier도 같은 이유로 ioctl을 쓴다고 지적했다). 이 결론이 그대로 `FUSE_DEV_IOC_BACKING_OPEN`/`FUSE_DEV_IOC_BACKING_CLOSE`가 되었다. 네임스페이스 문제에 대해서는 이런 말이 나왔다.

> "Namespaces are horrible"
>
> — David Howells, LSFMM+BPF 2023 FUSE passthrough 세션, 2023-05-17 ([lwn.net/Articles/932060](https://lwn.net/Articles/932060/))

같은 세션에서 Daniel Rosenberg는 fuse-bpf를 소개했다. 커널 쪽 BPF 필터가 요청 전후에 끼어들어 하부 파일 시스템으로 바로 보낼지, 서버로 보낼지를 정한다. 임의 BPF 실행 위험을 묻는 질문에는 BPF 프로그램을 사전에 FUSE에 등록해야 한다는 답이 나왔고, 이런 반응이 있었다.

> "This is no more dangerous than any other BPF"
>
> — 세션 참석자, 2023-05-17 ([lwn.net/Articles/932060](https://lwn.net/Articles/932060/))

해설: 두 진영의 차이는 범위다. fuse-bpf는 lookup·getattr 같은 메타데이터 연산까지 BPF로 위임하는 범용 스택 확장이다. Goldstein의 passthrough는 **열린 파일의 데이터 I/O만** 백킹 파일로 넘기는 좁은 확장이다. 메인라인이 받은 것은 후자다. 6.9 pull 요청은 범위와 제한을 분명히 했다.

> "Add passthrough mode for regular file I/O. This allows performing read and write (also via memory maps) on a backing file without incurring the overhead of roundtrips to userspace. For now this is only allowed to privileged servers, but this limitation will go away in the future (Amir Goldstein)"
>
> — Miklos Szeredi, "Merge tag 'fuse-update-6.9'", 2024-03-15 ([github.com/torvalds/linux/commit/6ce8b2ce0d7e](https://github.com/torvalds/linux/commit/6ce8b2ce0d7e3a621cdc9eb66d74436ca7d0e66e))

해설: "for now"라고 했지만 2.5년이 지난 7.3-rc master에서도 `fuse_backing_open()`과 `fuse_backing_close()`는 `!fc->passthrough || !capable(CAP_SYS_ADMIN)`이면 거부한다. 비특권 passthrough가 어려운 이유는 서버가 임의 fd를 백킹으로 지정할 수 있기 때문이다. 비특권 서버가 자신이 쓸 수 없는 파일을 마운트 사용자에게 노출하는 경로를 막아야 하고, 스택 깊이(`max_stack_depth` ≤ `FILESYSTEM_MAX_STACK_DEPTH`)와 overlayfs 중첩도 검증해야 한다. 7.2에서 passthrough는 Amir Goldstein을, io_uring은 Bernd Schubert와 Joanne Koong을 담당 메인테이너로 둔 하위 시스템이 되었다("Add subsystems (io-uring, passthrough) and respective maintainers", fuse-update-7.2 pull).

### 3.3 io_uring 버퍼 크기 논쟁(LSFMM+BPF 2026)

LWN(Jake Edge, 2026-08-03)에 따르면 libfuse는 링마다 엔트리 8개를 만들고 엔트리마다 최대 페이로드(8MB, 4MB로 낮출 수 있음)를 잡는다. 처리량에는 엔트리 1~2개면 충분하지만 `stat()`이나 디렉터리 목록 같은 작은 메타데이터 요청이 같은 크기의 버퍼를 소비한다. Schubert는 문제를 이렇게 요약했다.

> "You don't want to disturb your streaming I/O while you are doing these metadata requests"
>
> — Bernd Schubert, LSFMM+BPF 2026, 2026-08-03 기사 ([lwn.net/Articles/1085618](https://lwn.net/Articles/1085618/))

그는 단일 링 안에 4KB·64KB·128KB·1MB 여러 크기 엔트리를 두는 안을 냈다. Joanne Koong은 크기별로 링을 여러 개 두고 헤더와 페이로드를 분리하는 안을 밀었다.

> "If you have a small request and there are larger buffers available, why are you making the small request wait until there is a small buffer available?"
>
> — Joanne Koong, 같은 세션 ([lwn.net/Articles/1085618](https://lwn.net/Articles/1085618/))

해설: Schubert의 우려는 링이 많아지면 시스템 콜과 폴링 대상이 늘어난다는 점이었다. 코어가 적은 파티션 환경에서는 한 코어가 여러 링을 폴링해야 한다. Koong의 우려는 크기 맞춤 대기가 지연을 늘리고 head-of-line blocking을 만든다는 점이었다. 7.3 merge window(병합 `9cebfe650448`, 2026-08-25)에 들어간 결과물은 Koong 쪽 설계에 가깝다. 엔트리와 페이로드 버퍼의 1:1 대응을 끊는 **버퍼 풀**(`FUSE_IO_URING_CMD_ADD_BUFPOOL`, `struct fuse_bufpool`의 `free_map` 비트맵)과, 큐를 엔트리 등록과 별도로 만드는 `FUSE_IO_URING_CMD_ADD_QUEUE`가 들어왔다. 커널이 요청마다 풀 안의 오프셋을 정해 `fuse_uring_ent_in_out`에 실어 보낸다. 다중 크기 정책은 아직 사용자 공간 몫이다. libfuse는 `-o io_uring_bufpool`(master, 미릴리스)로 이를 지원한다.

### 3.4 FUSE냐, ublk냐, 커널 파일 시스템이냐

사용자 공간에서 스토리지를 구현할 때 첫 질문은 "파일 인터페이스가 필요한가, 블록 인터페이스면 충분한가"다.

- **ublk + 커널 파일 시스템(ext4/XFS)**: 메타데이터는 커널 FS가 처리하고, 사용자 공간 서버는 블록 I/O만 본다. 페이지 캐시·저널링·`O_DIRECT` 의미론이 커널 그대로다. 대신 하나의 장치를 여러 호스트가 공유하는 분산 파일 시스템은 만들 수 없다(→ 09/05).
- **FUSE**: 이름 공간과 메타데이터를 서버가 직접 정의한다. 분산 FS 클라이언트(ceph-fuse, DDN의 네트워크 스토리지 제품 등), 객체 스토리지 게이트웨이, 컨테이너 권한 매핑에 맞다. 대가는 메타데이터 연산마다 왕복이 든다는 것이다. `entry_timeout`/`attr_timeout` 캐시, `FUSE_READDIRPLUS`, `FUSE_PARALLEL_DIROPS`가 이를 줄이는 장치다.
- **커널 파일 시스템**: 성능 상한은 가장 높지만 개발·배포 주기가 커널에 묶인다. NFS/CephFS 커널 클라이언트는 FUSE 클라이언트보다 빠른 대신 업그레이드가 커널 업그레이드와 같다.

FUSE-over-io_uring은 이 선택지 사이의 성능 격차를 줄이는 장치이지 없애는 장치가 아니다. 메타데이터 왕복 수 자체는 그대로다. 데이터 경로에서는 passthrough(로컬 백킹 파일이 있을 때)와 io_uring 제로카피(백킹이 네트워크·사용자 공간 엔진일 때)가 역할을 나눈다.

---

## 4. Implementation Impact

### 4.1 협상: `FUSE_INIT`와 모듈 파라미터

모든 확장은 `FUSE_INIT`의 `flags`/`flags2`(64비트, `FUSE_INIT_EXT` 이후) 협상으로 켜진다. 커널은 `fuse_send_init()`에서 지원 비트를 광고하고, 서버 응답을 `process_init_reply()`가 해석한다.

| 플래그 / 필드 | 값(master) | 커널 측 조건 | 결과 |
|---|---|---|---|
| `FUSE_PASSTHROUGH` + `init_out.max_stack_depth` | `1ULL << 37` | `CONFIG_FUSE_PASSTHROUGH`, `0 < max_stack_depth <= FILESYSTEM_MAX_STACK_DEPTH`, `FUSE_WRITEBACK_CACHE` 미사용 | `fc->passthrough = 1`, `sb->s_stack_depth` 설정 |
| `FUSE_OVER_IO_URING` | `1ULL << 41` | `CONFIG_FUSE_IO_URING` + 모듈 파라미터 `enable_uring=1` | `fuse_chan_param.io_uring_enabled` |
| `FUSE_REQUEST_TIMEOUT` + `init_out.request_timeout` | `1ULL << 42` | sysctl `fs.fuse.default_request_timeout`/`max_request_timeout`(초, u16 상한) | `fuse_init_server_timeout()` |
| `FUSE_HAS_IO_URING_BUFPOOL` | `1ULL << 43` | 7.3-rc 이상 | 서버가 `ADD_BUFPOOL` 사용 가능함을 앎 |
| `max_background`, `congestion_threshold` | `init_out` 필드 | 비특권이면 `max_user_bgreq`/`max_user_congthresh`로 상한 | `fuse_chan_max_background_set()` |
| `max_pages` | `init_out` 필드(u16) | sysctl `fs.fuse.max_pages_limit`(기본 상한 65535) | 요청당 페이지 수 |

`enable_uring`은 0644 런타임 파라미터라 `/sys/module/fuse/parameters/enable_uring`으로 바꿀 수 있다. 6.14 pull의 "fuse: prevent disabling io-uring on active connections"(`2d4fde59fd50`)는 이미 io_uring으로 협상된 연결이 도중에 이 값이 꺼지더라도 깨지지 않게 막는다. 7.3에는 "fuse: Fix the condition to enable over-io-uring"(`1f59015e9581`)이 다시 들어왔다. 활성화 조건이 몇 차례 고쳐졌다는 뜻이므로 배포판 커널에서는 `dmesg`와 libfuse의 초기화 상태 줄(`io_uring=on` / `io_uring=off:not_offered` 등, `EMIT_INIT_STATUS_LINE`)로 실제 협상 결과를 확인하는 것이 안전하다.

### 4.2 io_uring 전송의 자료구조(Linux 7.3-rc 기준)

`fs/fuse/dev_uring_i.h`의 3단 구조다.

| 구조체 | 단위 | 주요 필드 | 락 |
|---|---|---|---|
| `struct fuse_ring` | 연결(`fuse_chan`)당 1개 | `nr_queues`(= `num_possible_cpus()`), `max_payload_sz`, `queues[]`, `queue_refs`, `ready`, `async_teardown_work` | 큐 포인터는 `smp_store_release`/`READ_ONCE`로 게시 |
| `struct fuse_ring_queue` | CPU당 1개 | `qid`, `ent_avail_queue`, `ent_w_req_queue`, `ent_commit_queue`, `ent_in_userspace`, `ent_released`, `fuse_req_queue`, `fuse_req_bg_queue`, `fpq`, `active_background`, `payload_mode`, `bufpool`, `zero_copy` | `queue->lock`(spinlock) |
| `struct fuse_ring_ent` | 큐당 깊이만큼 | `headers`(`struct fuse_uring_req_header __user *`), `payload`(`struct iovec`), `buf_id`, `zero_copied`, `cmd`(`struct io_uring_cmd *`), `state`, `fuse_req` | `cmd` 이하 필드는 `queue->lock` 보호 |

엔트리 상태는 `enum fuse_ring_req_state`로 추적한다. `FRRS_AVAILABLE`(서버가 넣어 둔 SQE가 대기 중) → `FRRS_FUSE_REQ`(요청 배정) → `FRRS_USERSPACE`(CQE로 서버에 전달) → `FRRS_COMMIT`(서버가 `COMMIT_AND_FETCH` 제출) → 다시 `FRRS_AVAILABLE`의 순환이고, 종료 시 `FRRS_TEARDOWN` → `FRRS_RELEASED`로 간다. 각 상태는 리스트 소속과 1:1로 대응하므로 상태 변경과 리스트 이동이 항상 `queue->lock` 아래에서 함께 일어난다.

SQE는 반드시 128바이트(`IORING_SETUP_SQE128`)여야 한다. `fuse_uring_cmd()`는 `IO_URING_F_SQE128`이 없으면 `-EINVAL`을 돌려준다. 확장 영역 80바이트에 `struct fuse_uring_cmd_req`(`flags`, `commit_id`, `qid`, 그리고 bufpool 또는 `ent_zero_copy_buf_index` 공용체)가 들어간다.

### 4.3 요청 콜패스: 포그라운드와 백그라운드

```
[클라이언트 스레드, CPU n]
fuse_simple_request() → fuse_chan_send()
  → fuse_send_one() → fiq->ops->send_req()
     └ 링 준비 후 fiq->ops->send_req = fuse_uring_queue_fuse_req (virtiofs는 virtio_fs_send_req)
         queue = fuse_uring_task_to_queue(ring)     // qid = task_cpu(current)
         spin_lock(&queue->lock)
         ent = ent_avail_queue의 첫 엔트리
         ent 있고 fuse_uring_prep_buffer() 성공 시 fuse_uring_add_req_to_ring_ent() → fuse_uring_dispatch_ent()
             → io_uring_cmd_complete_in_task(cmd, fuse_uring_send_in_task)
         없으면 queue->fuse_req_queue에 대기
  → request_wait_answer()   // req->waitq에서 잠듦

[서버 링을 소유한 태스크의 task_work]
fuse_uring_send_in_task()
  → fuse_uring_prepare_send() → fuse_uring_copy_to_ring()  // 헤더·인자·페이로드 복사(또는 제로카피 등록)
  → io_uring_cmd_done(cmd, 0, ...)                          // 서버에 CQE

[서버]
CQE 처리 → 응답 작성 → SQE(FUSE_IO_URING_CMD_COMMIT_AND_FETCH, commit_id)
fuse_uring_cmd() → fuse_uring_commit_fetch()
  → fuse_uring_commit() → fuse_uring_copy_from_ring() → fuse_uring_req_end() → fuse_request_end()
  → fuse_uring_get_next_fuse_req()   // 대기 요청이 있으면 즉시 같은 엔트리로 다시 전송
```

핵심은 **CQE를 만드는 쪽이 서버 태스크의 task_work**라는 점이다. 클라이언트 스레드는 엔트리를 배정하고 `io_uring_cmd_complete_in_task()`로 작업을 넘기기만 한다. 사용자 메모리(서버 버퍼)로의 복사는 서버 태스크 문맥에서 일어나야 하기 때문이다. ublk가 `UBLK_F_URING_CMD_COMP_IN_TASK` 이후 쓰는 방식과 같다.

백그라운드 요청은 `fuse_request_queue_background()`가 `fuse_uring_ready()`를 확인한 뒤 `fuse_uring_queue_bq_req()`로 보낸다. 요청에 `FR_URING`을 세우고 큐의 `fuse_req_bg_queue`에 넣은 뒤, `fch->bg_lock`을 잡고 `num_background`를 올리고 `fuse_uring_flush_bg()`로 한도 내에서 `fuse_req_queue`로 옮긴다. 락 순서는 `queue->lock` → `fch->bg_lock`이다(`lockdep_assert_held` 두 개로 강제).

libfuse 쪽(`lib/fuse_uring.c`)은 `get_nprocs_conf()`개의 큐를 만들고, 큐마다 스레드를 하나 띄워 `sched_setaffinity()`로 해당 CPU에 고정한다. 각 스레드가 자기 `io_uring`을 갖고 `/dev/fuse` fd를 `io_uring_register_files()`로 등록한 뒤 `REGISTER` SQE를 깊이만큼 넣는다. 그래서 "요청을 낸 CPU = 커널 큐 = 서버 스레드가 도는 CPU"가 성립한다.

### 4.4 종료와 취소

서버가 죽으면 io_uring은 미완료 `uring_cmd`에 `IO_URING_F_CANCEL`을 걸어 `fuse_uring_cmd()`를 다시 부른다. 엔트리는 SQE 등록 시 `fuse_uring_prepare_cancel()`이 `io_uring_cmd_mark_cancelable()`로 취소 가능 표시를 해 둔다. `fuse_uring_cancel()`은 `FRRS_AVAILABLE` 엔트리를 `-ENOTCONN`으로 완료한다. 연결 중단(`fuse_chan_abort()`) 경로의 `fuse_uring_stop_queues()`는 엔트리가 바로 해제되지 않으면 `FUSE_URING_TEARDOWN_INTERVAL`(HZ/20) 간격의 지연 작업으로 재시도하고, `FUSE_URING_TEARDOWN_TIMEOUT`(5초)이 지나면 남은 엔트리 상태를 로그로 남긴다. 6.14 시리즈의 "fuse: {io-uring} Prevent mount point hang on fuse-server termination"(`b6236c8407cb`)이 이 경로를 만든 커밋이다.

### 4.5 7.3의 버퍼 풀과 제로카피

7.3-rc에서 큐 설정 순서는 다음처럼 바뀌었다(7.2까지는 첫 `REGISTER`가 링과 큐를 암묵적으로 만들었다. "fuse: decouple fuse_ring creation from ent registration" `6330b1f61ed1`).

1. `FUSE_IO_URING_CMD_ADD_QUEUE`(qid, flags): 큐 생성. `flags`에 `FUSE_URING_ZERO_COPY`를 넣으면 제로카피 큐가 되며 `capable(CAP_SYS_ADMIN)`이 아니면 `-EPERM`이다.
2. `FUSE_IO_URING_CMD_ADD_BUFPOOL`(qid, `bufpool.uaddr`, `bufpool.len`): 일반 큐에서는 선택이지만 제로카피 큐에서는 필수다(버퍼 풀 없이 엔트리를 등록하면 "Can only use zero copy with bufpools"로 거부). 큐의 `payload_mode`가 `FUSE_PAYLOAD_UNSET`에서 `FUSE_PAYLOAD_BUFPOOL`로 확정된다. 풀은 `max_payload_sz` 크기 버퍼 `nr_bufs`개로 쪼개지고 `free_map` 비트맵으로 관리된다. SQE에 `IORING_URING_CMD_FIXED`를 주면 풀을 io_uring 등록 버퍼로 묶는다(`registered_index`). 커널 문서는 이때 페이지 고정(pin)이 한 번만 일어나 요청별 pin/주소 변환이 사라지고, 같은 등록 버퍼를 백엔드 I/O에도 그대로 쓸 수 있다고 설명한다.
3. `FUSE_IO_URING_CMD_REGISTER`: 엔트리 등록. 버퍼 풀 큐에서는 엔트리가 헤더만 가지고, 요청이 배정될 때 `fuse_uring_select_buffer()`가 풀에서 버퍼를 고르고 오프셋을 `fuse_uring_ent_in_out`에 실어 보낸다. 제로카피 큐에서는 `ent_zero_copy_buf_index`로 엔트리마다 서버 io_uring 등록 버퍼 테이블의 빈 슬롯을 지정한다.

제로카피 조건은 `can_zero_copy_req()`에 있다. 큐가 `zero_copy`이고, 파일이 `FOPEN_IO_URING_ZERO_COPY`로 열렸고, opcode가 `FUSE_READ`/`FUSE_WRITE`이며, 요청이 페이지 페이로드(`in_pages`/`out_pages`)를 가져야 한다. 조건이 맞으면 `fuse_uring_set_up_zero_copy()`가 요청의 folio들(직접 I/O면 pin된 사용자 페이지, 버퍼드 I/O면 페이지 캐시 folio)로 `bio_vec` 배열을 만들어 `io_buffer_register_bvec()`로 서버 링의 해당 슬롯에 꽂는다. 서버는 페이로드를 직접 보지 않고 `IORING_OP_READ_FIXED`/`WRITE_FIXED`(또는 `uring_cmd` 고정 버퍼)로 백엔드 장치나 소켓에 넘긴다. 요청이 끝나면 `zero_copy_unregister()`가 슬롯을 비운다. ublk 6.15의 제로카피와 같은 커널 API다(→ 09/05, 4.3절). 헤더처럼 페이지가 아닌 인자는 여전히 복사된다.

비특권 서버에 제로카피를 막는 이유는 ublk의 `UBLK_F_UNPRIVILEGED_DEV` 제한과 같은 계열이다. 클라이언트의 페이지 캐시 folio가 서버의 고정 버퍼로 노출되므로, 서버가 읽기 요청에 데이터를 다 채우지 않거나 쓰기 요청 페이지를 다른 용도로 쓰는 경우의 정보 노출을 권한으로 차단한다.

### 4.6 passthrough의 구현

```
[서버] ioctl(/dev/fuse, FUSE_DEV_IOC_BACKING_OPEN, {fd, flags=0})
  → fuse_backing_open(fc, map)
      CAP_SYS_ADMIN 확인, backing_sb->s_stack_depth < fc->max_stack_depth 확인
      struct fuse_backing { file, cred, refcount } 생성
      idr_alloc_cyclic(&fc->backing_files_map, ...) → backing_id 반환
[서버] OPEN 응답: fuse_open_out { open_flags |= FOPEN_PASSTHROUGH, backing_id }
[커널] fuse_file_io_open() → fuse_file_passthrough_open()
      → fuse_passthrough_open(file, backing_id) → backing_file_open(...)
      → fuse_inode_uncached_io_start(fi, fb)   // inode를 passthrough(uncached) 모드로
[이후 I/O] fuse_passthrough_read_iter()  → backing_file_read_iter()
           fuse_passthrough_write_iter() → backing_file_write_iter()
           splice_read/splice_write/mmap → backing_file_splice_*() / backing_file_mmap()
```

`backing_file_*()` 헬퍼는 overlayfs와 공유하는 `fs/backing-file.c` 계층이다(`FUSE_PASSTHROUGH` Kconfig가 `select FS_STACK`). 백킹 파일 I/O는 서버의 자격 증명(`fb->cred`)으로 수행된다. 서버는 `open` 응답 직후 `FUSE_DEV_IOC_BACKING_CLOSE`로 ID를 닫아도 된다. 열린 `fuse_file`이 `fuse_backing` 참조를 쥐고 있기 때문이다.

`iomode.c`(CTERA의 Amir Goldstein, 2024)는 한 inode에 캐시 모드 open과 passthrough open이 섞이지 않게 막는다. 첫 passthrough open은 캐시 모드를 거부하고, 첫 캐시 모드 open은 passthrough를 거부한다. 주석에 따르면 `FOPEN_PASSTHROUGH | FOPEN_DIRECT_IO` 조합은 "read/write는 서버로, mmap만 백킹 파일로"라는 뜻이다. `FOPEN_KEEP_CACHE`와의 조합은 "strange and undesired"로 분류된다. libfuse는 3.17에서 `fuse_passthrough_open()`/`fuse_passthrough_close()` API와 `example/passthrough_hp.cc` 예제로 이를 노출했다.

### 4.7 virtiofs: 전송과 DAX 창

virtiofs는 `struct fuse_iqueue_ops`의 구현만 바꾼 FUSE다(`virtio_fs_fiq_ops`의 `send_req = virtio_fs_send_req`). 장치 설정 공간 `struct virtio_fs_config`는 `tag[36]`(마운트 이름)과 `num_request_queues`만 가진다.

- **virtqueue 배치**: 0번 `hiprio`(FORGET, INTERRUPT 같은 우선 메시지), 1번부터 `requests.N`. 6.10부터 `fs->mq_map[cpu]`가 CPU→request virtqueue 매핑을 담는다. `virtio_fs_map_queues()`는 장치가 인터럽트 affinity를 알려 주면(`get_vq_affinity`) 그대로 쓰고, 아니면 `group_cpus_evenly()`로 고르게 나눈다. blk-mq의 `blk_mq_map_queues()`와 같은 발상이다(→ 02/01).
- **DAX 창**: 장치가 virtio 공유 메모리 영역 `VIRTIO_FS_SHMCAP_ID_CACHE`(id 0)를 노출하면, 게스트는 `virtio_get_shm_region()`으로 찾은 PCI BAR 영역을 `devm_memremap_pages()`로 매핑하고 `alloc_dax()`로 `dax_device`를 만든다. 파일 범위를 창에 올릴 때는 FUSE 메시지 `FUSE_SETUPMAPPING`(`FUSE_SETUPMAPPING_FLAG_READ/WRITE`)을 보내 호스트가 그 창 오프셋에 파일을 `mmap`하게 한다. 해제는 `FUSE_REMOVEMAPPING`이다.
- **창 관리 단위**는 `FUSE_DAX_SZ` = 2MiB(`FUSE_DAX_SHIFT` 21)다. 사용 가능한 범위(`free_ranges`)가 전체의 `FUSE_DAX_RECLAIM_THRESHOLD`(20%) 아래로 떨어지면 지연 작업이 `FUSE_DAX_RECLAIM_CHUNK`(10개)씩 회수한다. 창이 작고 작업 집합이 크면 회수와 재매핑이 반복되어 성능이 급락한다. 창 크기는 호스트 측 장치 설정(QEMU `vhost-user-fs-pci`의 cache-size 계열 옵션 등)에 달려 있다 QEMU 메인라인의 DAX 창 지원 상태는 배포판·버전별로 다르며 여기서 확인하지 않았다 [추측/미확인].
- **모드**: 마운트 옵션 `dax`(= `always`), `dax=always|never|inode`(5.17). `inode` 모드는 서버가 `FUSE_ATTR_DAX`로 파일별로 정한다.

DAX의 효과는 게스트 페이지 캐시를 건너뛰고 호스트 페이지 캐시를 공유하는 것이다. 같은 이미지를 여러 VM이 읽는 경우 메모리 중복이 사라지고, `mmap` 공유 의미론도 호스트와 일치한다. 대신 게스트 메모리 사용량이 호스트 쪽으로 옮겨 가므로 VM 메모리 회계가 달라진다. DAX가 없으면 virtiofs는 일반 FUSE 캐시 모드(`cache=auto|always|never`는 virtiofsd 옵션)로 동작한다.

호스트 데몬은 vhost-user 프로토콜(→ 09/04)로 QEMU와 게스트 메모리를 공유하는 별도 프로세스다. QEMU 8.0에서 C 구현 `virtiofsd`가 제거되고 Rust 구현(`gitlab.com/virtio-fs/virtiofsd`)이 표준이 되었다(QEMU "Removed features" 문서).

### 4.8 데이터 경로 비교

| 경로 | 요청 전달 | 데이터 이동(4KiB 초과 READ 기준) | CPU 지역성 | 권한 | 도입 |
|---|---|---|---|---|---|
| `/dev/fuse` read/write | 공유 `fuse_iqueue.pending` + `read()` | 커널→서버 복사, 서버→페이지 복사 | 없음(아무 서버 스레드나) | 비특권 가능 | 2.6.14 |
| `/dev/fuse` splice | 같음 | pipe 경유, `SPLICE_F_MOVE` 시 `fuse_try_move_folio()`로 페이지 이동 시도 | 없음 | 비특권 가능 | 2.6.35 |
| io_uring(복사) | CPU별 `fuse_ring_queue`, CQE | 서버 버퍼로 복사(엔트리별 또는 풀) | `task_cpu()` 큐 + libfuse 스레드 고정 | 비특권 가능 | 6.14 |
| io_uring(제로카피) | 같음 | 클라이언트 folio를 서버 링 등록 버퍼로 공유. 복사 0회 | 같음 | `CAP_SYS_ADMIN` | 7.3-rc |
| passthrough | 서버 왕복 없음(open 시 1회만) | 커널이 백킹 파일에 직접 I/O | 호출 스레드 그대로 | `CAP_SYS_ADMIN` | 6.9 |
| virtiofs | virtqueue(`mq_map`) | 게스트 버퍼를 vhost-user 데몬이 공유 메모리로 접근 | CPU→virtqueue 매핑(6.10) | VM 경계 | 5.4 |
| virtiofs + DAX | 매핑 설정만 FUSE 메시지 | 게스트가 호스트 페이지 캐시를 load/store | 해당 없음 | VM 경계 | 5.10 |

| 기준 | FUSE(+io_uring) | ublk + 커널 FS (→ 09/05) | 커널 파일 시스템 |
|---|---|---|---|
| 서버가 다루는 단위 | 파일·디렉터리 연산(opcode 50여 종) | 블록 요청(READ/WRITE/FLUSH/DISCARD/ZONE) | 해당 없음 |
| 메타데이터 왕복 | 연산마다(캐시 타임아웃으로 완화) | 없음(커널 FS가 처리) | 없음 |
| 페이지 캐시 | FUSE inode의 페이지 캐시(`FUSE_WRITEBACK_CACHE` 선택) | 커널 FS의 페이지 캐시 + 블록 장치 | 자체 |
| 다중 호스트 공유 이름 공간 | 가능(서버가 구현) | 불가(단일 블록 장치) | 분산 FS 클라이언트만 |
| io_uring 전송 구조 | CPU별 큐, `REGISTER` → `COMMIT_AND_FETCH` | hctx별 큐, `FETCH_REQ` → `COMMIT_AND_FETCH_REQ` | 해당 없음 |
| 제로카피 API | `io_buffer_register_bvec()`(7.3-rc) | `io_buffer_register_bvec()`(6.15) | 해당 없음 |
| 서버 장애 시 | 연결 abort, 마운트 무효(재시작 시 `FUSE_NOTIFY_RESEND`로 재전송 지원, 6.9) | `UBLK_F_USER_RECOVERY`로 장치 유지 | 커널 패닉/FS 오류 |

### 4.9 운영상 주의점

1. **io_uring을 켜려면 세 곳을 모두 확인한다.** `CONFIG_FUSE_IO_URING=y`(기본 y), `/sys/module/fuse/parameters/enable_uring=1`(기본 0), libfuse 3.18 이상에서 `-o io_uring`. 하나라도 빠지면 조용히 `/dev/fuse`로 동작한다.
2. **큐 깊이와 메모리를 계산한다.** 기본 깊이 8, 엔트리당 최대 페이로드 버퍼를 곱하고 다시 CPU 수(`get_nprocs_conf()`)를 곱한다. CPU 128개, 깊이 8, 4MB 페이로드라면 서버 버퍼만 4GiB다. `-o io_uring_q_depth=`와 `max_pages`를 함께 조정하거나 7.3 버퍼 풀을 쓴다.
3. **`max_background`를 올린다.** 기본 12는 readahead와 비동기 직접 I/O 병렬성을 제한한다. io_uring 경로에서도 `fch->max_background` 한도는 그대로 적용된다(큐당 1개 예외만 있음).
4. **passthrough와 writeback cache는 배타적이다.** 서버가 `FUSE_WRITEBACK_CACHE`를 요청하면 커널은 passthrough를 켜지 않는다. 쓰기 집중 워크로드에서 무엇을 택할지 먼저 정해야 한다.
5. **요청 타임아웃을 설정한다.** 6.15부터 `fs.fuse.default_request_timeout`/`max_request_timeout` sysctl과 `FUSE_REQUEST_TIMEOUT`이 있다. 응답하지 않는 서버 때문에 D 상태 프로세스가 쌓이는 문제를 시간 기반 abort로 끊는다.
6. **버퍼드 읽기 128KiB 제한.** 7.3 pull 요약에는 "Don't limit buffered read to 128k (Jim Harris)"가 들어 있다. 7.3 이전 커널에서 대형 순차 버퍼드 읽기 처리량이 기대보다 낮다면 이 변경이 백포트되었는지부터 확인한다. 개별 커밋의 세부 동작은 여기서 확인하지 않았다 [추측/미확인].
7. **virtiofs DAX 창 크기.** 창이 작업 집합보다 작으면 `FUSE_SETUPMAPPING`/`REMOVEMAPPING` 회수 루프가 지배한다. DAX가 이득인지 `dax=never`와 비교 측정한다.

---

## 5. Primary References

- [FUSE and io_uring](https://lwn.net/Articles/932079/) — Jake Edge, LSFMM+BPF 2023 Schubert 세션, 2023-05-19
- [FUSE passthrough for file I/O](https://lwn.net/Articles/932060/) — Jake Edge, LSFMM+BPF 2023 Szeredi 세션(ioctl 기반 백킹 파일, fuse-bpf), 2023-05-17
- [fuse: fuse-over-io-uring](https://lwn.net/Articles/1005648/) — Bernd Schubert v10 커버 레터 게시본, 2025-01-20
- [Buffer sizes for FUSE io_uring](https://lwn.net/Articles/1085618/) — Jake Edge, LSFMM+BPF 2026, 2026-08-03
- [Merge tag 'fuse-update-6.9'](https://github.com/torvalds/linux/commit/6ce8b2ce0d7e3a621cdc9eb66d74436ca7d0e66e) — passthrough 병합, 2024-03-15
- [Merge tag 'fuse-update-6.14'](https://github.com/torvalds/linux/commit/92cc9acff7194b1b9db078901f2a83182bb73202) — FUSE-over-io_uring 병합, 2025-01-29
- [Merge tag 'fuse-update-7.3'](https://github.com/torvalds/linux/commit/9cebfe6504488198b012e746bc6b313f88b95439) — 버퍼 풀·제로카피 병합, 2026-08-25
- [fuse: enable fuse-over-io-uring](https://github.com/torvalds/linux/commit/786412a73e7ee5b00ef3437bbf2f3a250759b2ae) — Bernd Schubert, 2025-01-20
- [fuse: introduce FUSE_PASSTHROUGH capability](https://github.com/torvalds/linux/commit/7dc4e97a4f9a55bae6ed6ab3f96c92921259d59f) — Amir Goldstein, 2024-02-09
- [fuse: add zero-copy over io-uring](https://github.com/torvalds/linux/commit/43f8343858eb942d7f7c49964b31c54dcc314890) — Joanne Koong, 2026-08-14
- [FUSE-over-io-uring design documentation — The Linux Kernel documentation](https://docs.kernel.org/filesystems/fuse/fuse-io-uring.html) — 커널 설계 문서
- [virtiofs: virtio-fs host<->guest shared file system — The Linux Kernel documentation](https://docs.kernel.org/filesystems/virtiofs.html) — virtiofs 커널 문서
- [include/uapi/linux/fuse.h](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/include/uapi/linux/fuse.h) — FUSE 프로토콜 uAPI(7.46)
- [fs/fuse/dev_uring.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/fs/fuse/dev_uring.c) — io_uring 전송 구현
- [GitHub - libfuse/libfuse: The reference implementation of the Linux FUSE (Filesystem in Userspace) interface](https://github.com/libfuse/libfuse) — libfuse(`lib/fuse_uring.c`, `ChangeLog.rst`)
- [Removed features — QEMU documentation](https://www.qemu.org/docs/master/about/removed-features.html) — QEMU 8.0의 C virtiofsd 제거 기록
