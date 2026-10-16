# io_uring 보안 위기와 대응: CVE 계열, LSM 훅, sysctl 차단, 제한·필터 메커니즘

> 기준: 별도 표기가 없으면 소스는 Linux 메인라인 master(7.3-rc7, 2026-10)이며, 각 기능의 도입 버전은 태그별 `include/linux/security.h`, `include/uapi/linux/io_uring.h`, `io_uring/io_uring.c`, `io_uring/register.c`를 grep으로 대조해 확인했다. CVE 설명은 NVD 레코드 원문을 확인한 범위로 한정했다.

## 1. Verdict

io_uring은 "임의의 syscall 경로를 다른 실행 문맥(io-wq 워커, task_work, SQPOLL 스레드)에서, syscall 경계 없이" 실행하는 구조다. 이 구조가 두 가지 보안 문제를 낳았다.

1. **취약점 밀도.** 요청 수명, 등록 자원(파일·버퍼·buffer ring), 취소·타임아웃, 링크 처리에 걸친 use-after-free·경쟁 조건이 2021~2024년에 반복되었다(CVE-2021-3491, CVE-2021-41073, CVE-2022-29582, CVE-2022-2602, CVE-2023-2598, CVE-2024-0582 등). Google은 2023-06-14 보안 블로그에서 지난 1년간 kCTF VRP 제출 익스플로잇의 60%가 io_uring을 악용했고 io_uring 관련으로만 약 100만 달러를 지급했다고 밝혔다.
2. **기존 통제의 우회.** seccomp는 syscall 번호와 인자를 거르므로, `io_uring_enter()` 하나만 허용되면 그 안의 `openat`, `connect`, `sendmsg` 등은 개별적으로 걸러지지 않는다. LSM 훅이 붙은 VFS·소켓 경로는 io_uring에서도 그대로 호출되지만, 자격 증명 대리 실행(`IORING_REGISTER_PERSONALITY`), SQPOLL 스레드 생성, 드라이버 passthrough(`IORING_OP_URING_CMD`)처럼 io_uring 고유의 동작은 처음에 LSM이 볼 수 없었다.

대응은 한 가지 해법이 아니라 여러 겹으로 쌓였다.

| 계층 | 메커니즘 | 도입 |
|---|---|---|
| 링 단위 자기 제한 | `IORING_REGISTER_RESTRICTIONS` + `IORING_SETUP_R_DISABLED` | 5.10 |
| LSM | `security_uring_override_creds()`, `security_uring_sqpoll()` | 5.16 |
| LSM | `security_uring_cmd()` | 6.0 |
| 시스템 전역 | sysctl `kernel.io_uring_disabled`, `kernel.io_uring_group` | 6.6 |
| LSM | `security_uring_allowed()` (`io_uring_setup()` 시점) | 6.15 |
| 링·태스크 단위 필터 | `IORING_REGISTER_BPF_FILTER`(classic BPF), 태스크 단위 restrictions | 7.0 |

어느 것도 "완전 방어"는 아니다. sysctl과 seccomp는 기능을 끄는 수단이고, LSM 훅은 정책이 있어야 효과가 있으며, restrictions/BPF 필터는 링을 만드는 쪽이 스스로 거는 제한이다. 커널 버그 자체(UAF 등)는 이 통제들이 허용한 연산 안에서도 여전히 터질 수 있다. 따라서 현실적인 운영 방식은 "신뢰된 구성요소에만 io_uring을 허용하고, 허용된 쪽은 최신 stable 커널을 유지"하는 것이다. Google 블로그의 표현으로는 "safe only for use by trusted components"다.

---

## 2. Problem Statement

### 2.1 seccomp가 볼 수 없는 것

seccomp-bpf는 syscall 진입 시점의 `struct seccomp_data`(syscall 번호, 아키텍처, 인자 6개)만 본다. io_uring에서 실제 연산은 공유 메모리의 SQE에 적히고, 커널은 `io_uring_enter()` 안에서, 또는 SQPOLL이면 syscall 없이 SQ 스레드에서 이를 실행한다. 그래서 컨테이너 런타임과 Android는 "io_uring syscall 세 개를 통째로 막는" 방식을 택했다.

- **Docker(moby)**: 2019년 PR #39415로 기본 seccomp 프로필에 io_uring syscall을 허용했다가, 2023-11-02 병합된 PR #46762("seccomp: block io_uring_* syscalls in default profile")로 다시 차단했다(GitHub API로 PR 제목과 병합일 확인).
- **Google 제품(2023-06 기준, Google 보안 블로그)**: ChromeOS는 io_uring 비활성화, Android는 seccomp-bpf로 앱에서 접근 불가(향후 SELinux로 일부 시스템 프로세스만 허용 예정), GKE AutoPilot은 기본 비활성화 검토, Google 프로덕션 서버는 비활성화.

seccomp는 커널 재컴파일 없이 적용할 수 있다. 다만 seccomp 필터는 프로세스 트리마다 설치해야 하므로, 배포판이 시스템 전역 기본값을 바꾸기는 어렵다. 이것이 6.6 sysctl의 동기였다.

### 2.2 LSM이 볼 수 없던 것

io_uring 요청이 결국 `vfs_open()`, `vfs_read()`, `sock_sendmsg()` 등에 도달하면 해당 경로의 LSM 훅(`security_file_open()`, `security_socket_sendmsg()` 등)은 호출된다. 빠져 있던 것은 io_uring 고유 동작이다.

- **personality**: `IORING_REGISTER_PERSONALITY`로 등록한 creds를 SQE의 `personality` 필드로 지정하면 요청이 그 자격 증명으로 실행된다. 다른 creds로 행동한다는 사실을 LSM이 판단할 지점이 없었다.
- **SQPOLL**: 제출자 대신 커널 문맥 스레드가 계속 돌며 요청을 실행한다.
- **uring_cmd**: 5.19의 `IORING_OP_URING_CMD`는 `file->f_op->uring_cmd()`로 드라이버 고유 명령(예: NVMe passthrough)을 전달한다. `ioctl()`에는 `security_file_ioctl()`이 있지만, uring_cmd에는 처음에 대응 훅이 없었다.
- **audit**: LWN "Auditing io_uring"(2021-06-03)은 audit·LSM 지원을 추가하려는 보안 커뮤니티의 시도가 난항을 겪으며 "unpleasant fallback"까지 거론되던 상황을 다룬다.

### 2.3 취약점이 몰리는 구조적 이유

1. **수명이 syscall보다 길다.** 요청, 등록 파일, 등록 버퍼, buffer ring, 링 메모리가 여러 syscall과 여러 실행 문맥에 걸쳐 살아 있다. 참조 카운트나 락 하나가 빠지면 UAF가 된다.
2. **실행 문맥이 여럿이다.** 같은 요청이 제출자, poll 콜백, task_work, io-wq 워커, SQPOLL 스레드 중 어디서든 진행될 수 있어 경쟁 조건 조합이 많다.
3. **강력한 익스플로잇 프리미티브.** 등록 버퍼와 provided buffer는 커널이 오래 쥐고 있는 사용자 메모리이고, 공유 링은 커널-사용자 공유 페이지다. Google 블로그는 io_uring이 "strong exploitation primitives"를 제공한다고 지적했다.
4. **빠른 기능 추가.** 5.1의 8개 opcode가 master에서 65개가 되었다. 기능마다 새 수명 규칙이 붙는다.

---

## 3. The Debate

### 3.1 LSM 훅: "누가 io_uring을 충분히 이해하는가" (2021~2022)

Paul Moore(LSM·audit 메인테이너)의 "lsm,io_uring: add LSM hooks to io_uring"(`cdc1404a4046`)은 5.16에 `security_uring_override_creds()`와 `security_uring_sqpoll()`을 추가했다. 같은 시기 audit 지원도 들어갔고, opdef의 `.audit_skip` 속성으로 고빈도 read/write 같은 연산은 감사 기록을 생략할 수 있게 했다. LWN "Auditing io_uring"(2021-06)이 다룬 대로, 이 과정에서 보안 쪽은 io_uring 설계가 보안을 늦게 고려한다고 봤고 io_uring 쪽은 hot path 비용을 걱정했다.

2022년 7월, 5.19의 `IORING_OP_URING_CMD`가 LSM 훅 없이 병합된 사실이 드러나며 논쟁이 다시 붙었다. LWN "Security requirements for new kernel features"(2022-07-28)는 이를 "how easily requirements can be overlooked in a complex system with no overall supervision"의 사례로 정리했다. Luis Chamberlain의 "lsm,io_uring: add LSM hooks for the new uring_cmd file op"(`2a5840124009`)이 `security_uring_cmd()`를 추가했고 6.0에 들어갔다. 이 스레드에서 uring_cmd 작성자 중 한 명인 Kanchan Joshi(삼성)가 자신의 LSM 이해 부족을 사과하자 Paul Moore는 이렇게 답했다.

> "Thanks for your honesty.  If it is any consolation, my understanding
> of io_uring remains superficial at best, and it's one of the reasons
> I've asked the io_uring devs to ack/review the LSM io_uring hooks and
> their placement in the io_uring code.  Developing a deep understanding
> of one kernel subsystem is often very difficult, doing the same across
> multiple subsystems requires a *lot* of time and effort."
>
> — Paul Moore, Re: [PATCH] lsm,io_uring: add LSM hooks to for the new uring_cmd file op, 2022-07-18 ([LWN 메일 아카이브](https://lwn.net/ml/linux-security-module/CAHC9VhQKeufrqN=dVZ74wEFgd3K=KY-aEZafYembT738juzWUw@mail.gmail.com/), Message-ID `CAHC9VhQKeufrqN=dVZ74wEFgd3K=KY-aEZafYembT738juzWUw@mail.gmail.com`)

이 발언의 요지는 비난이 아니라 구조 문제다. io_uring은 VFS, 네트워크, 블록, 드라이버를 모두 건드리는데, 각 경로의 보안 요구사항을 아는 사람과 io_uring 내부를 아는 사람이 다르다. 그래서 새 opcode가 "기존 syscall과 같은 보안 지점을 지나는가"를 리뷰 과정에서 명시적으로 확인해야 한다는 교훈이 남았다. `security_uring_cmd()`는 명령 내용(`struct io_uring_cmd`)을 LSM에 넘기므로, SELinux는 `io_uring { cmd }` 권한으로 대상 파일의 레이블 기준 허용 여부를 판단할 수 있다.

### 3.2 전역 스위치: sysctl `io_uring_disabled` (2023)

Google의 Matteo Rizzo는 2023년 6월, 배포판과 클라우드 사업자가 쓸 수 있는 시스템 전역 차단 스위치를 제안했다.

> "Over the last few years we've seen many critical vulnerabilities in
> io_uring[1] which could be exploited by an unprivileged process to gain
> control over the kernel. This patch introduces a new sysctl which disables
> the creation of new io_uring instances system-wide.
>
> The goal of this patch is to give distros, system admins, and cloud
> providers a way to reduce the risk of privilege escalation through io_uring
> where disabling it with seccomp or at compile time is not practical."
>
> — Matteo Rizzo, [PATCH v2 0/1] Add a sysctl to disable io_uring system-wide, 2023-06-29 ([LWN 메일 아카이브](https://lwn.net/ml/io-uring/20230629132711.1712536-1-matteorizzo@google.com/), Message-ID `20230629132711.1712536-1-matteorizzo@google.com`)

v2 변경 내역에는 "Add a third level that only disables io_uring for unprivileged processes"가 있고, 리뷰에서는 Jeff Moyer, Gabriel Krisman Bertazi, Bart Van Assche 등이 의견을 냈다. 최종 병합본(6.6)은 값 0/1/2와 그룹 예외(`io_uring_group`)를 갖는다. 논쟁의 축은 "커널 기능을 런타임에 끄는 손잡이를 두는 것이 맞는가"와 "seccomp로 충분하지 않은가"였고, 커버 레터는 seccomp·컴파일 옵션이 현실적이지 않은 환경(배포판 기본값, 사용자 선택적 활성화)을 근거로 들었다.

### 3.3 자기 제한형 메커니즘: restrictions에서 BPF 필터로

Stefano Garzarella(Red Hat)는 5.10에 `IORING_REGISTER_RESTRICTIONS`(`21b55dbc0653`)와 `IORING_SETUP_R_DISABLED`(`7e84e1c7566a`)를 넣었다. 링을 비활성 상태로 만들고, 허용할 register opcode, SQE opcode, SQE 플래그를 등록한 뒤 `IORING_REGISTER_ENABLE_RINGS`로 활성화하는 방식이다. 신뢰된 쪽(예: VMM)이 링을 만들어 제한을 건 뒤 덜 신뢰된 쪽(게스트 대리 프로세스 등)에 넘기는 시나리오를 상정했다. 한계는 opcode 단위 비트맵이라 "이 경로의 openat만 허용" 같은 인자 기반 판단이 불가능하다는 점이다.

7.0에서 Jens Axboe의 "io_uring: add support for BPF filtering for opcode restrictions"(`d42eb05e60fe`)가 이 한계를 보완했다. 커밋 메시지는 "Unlike IORING_REGISTER_RESTRICTIONS which only allows bitmap-based allow/deny of opcodes, BPF filters can inspect request attributes and make dynamic decisions"라고 설명한다. **classic BPF**(seccomp와 같은 `struct sock_fprog`, `bpf_prog_create_from_user()`)를 쓰고, 필터는 `struct io_uring_bpf_ctx`(`user_data`, `opcode`, `sqe_flags`, op별 데이터)를 본다. 같은 릴리스에서 `IORING_REGISTER_RESTRICTIONS`/`IORING_REGISTER_BPF_FILTER`를 링 없이(fd = -1, "blind" 등록) 호출해 **태스크 단위**로 거는 경로도 생겼다. 이 경로는 seccomp처럼 `no_new_privs`가 설정되었거나 `CAP_SYS_ADMIN`이 있어야 한다. 태스크 단위 restrictions는 한 번만 등록할 수 있고(재등록 시 `-EPERM`), BPF 필터는 같은 opcode에 새 필터를 체인으로 덧붙일 수만 있어(`filter->next = old_filter`) 기존 필터를 해제하는 uAPI는 없다(master `io_uring/register.c`, `io_uring/bpf_filter.c`). eBPF가 아닌 cBPF를 택한 것은 비특권 사용자가 쓸 수 있어야 하는 sandboxing 용도이기 때문으로 보인다 [설계 의도 해석: 추측/미확인].

---

## 4. Implementation Impact

### 4.1 LSM 훅의 호출 지점 (master)

| 훅 | 도입 | 호출 지점 | 판단 대상 | SELinux 권한 (`io_uring` 클래스) |
|---|---|---|---|---|
| `security_uring_override_creds(new)` | 5.16 | `io_init_req()`: SQE `personality`로 `ctx->personalities`에서 creds를 찾은 직후 | 다른 자격 증명으로 요청 실행 | `override_creds` |
| `security_uring_sqpoll()` | 5.16 | `io_uring/sqpoll.c`: SQPOLL 스레드 생성 경로 | 커널 폴링 스레드 생성 | `sqpoll` |
| `security_uring_cmd(ioucmd)` | 6.0 | `io_uring/uring_cmd.c`: `file->f_op->uring_cmd()` 호출 전 | 드라이버 passthrough 명령 | `cmd` |
| `security_uring_allowed()` | 6.15 | `io_uring_allowed()`: `io_uring_setup()` 진입 시 sysctl 검사 통과 후 | 링 생성 자체 | `allowed` |

`security_uring_allowed()`는 Hamza Mahfooz의 "io_uring,lsm,selinux: add LSM hooks for io_uring_setup()"(`c6ad9fdbd44b`)으로 들어갔다. master의 SELinux `classmap.h`는 `{ "io_uring", { "override_creds", "sqpoll", "cmd", "allowed", NULL } }`로 네 권한을 정의한다. 이 훅들은 io_uring *고유* 동작만 다룬다. 요청이 도달하는 VFS·소켓 경로의 일반 LSM 훅은 원래대로 호출되므로, "io_uring이 LSM을 완전히 우회한다"는 서술도 틀리다.

### 4.2 sysctl의 정확한 의미 (6.6~master)

master `io_uring/io_uring.c`의 판정 함수는 다음과 같다.

```c
static inline int io_uring_allowed(void)
{
	int disabled = READ_ONCE(sysctl_io_uring_disabled);
	kgid_t io_uring_group;

	if (disabled == 2)
		return -EPERM;
	if (disabled == 0 || capable(CAP_SYS_ADMIN))
		goto allowed_lsm;
	io_uring_group = make_kgid(&init_user_ns, sysctl_io_uring_group);
	if (!gid_valid(io_uring_group))
		return -EPERM;
	if (!in_group_p(io_uring_group))
		return -EPERM;
allowed_lsm:
	return security_uring_allowed();
}
```

- `0`(기본): 모두 허용.
- `1`: `CAP_SYS_ADMIN` 보유자 또는 `kernel.io_uring_group`(기본 `-1`, 즉 무효) 그룹 구성원만 허용.
- `2`: 모두 거부. root도 거부된다.
- 값은 `extra2 = SYSCTL_TWO` 범위의 일반 sysctl이라 **런타임에 0↔1↔2로 자유롭게 바꿀 수 있다**. 따라서 "2는 신규 생성을 영구 차단한다"는 설명은 부정확하며, 차단은 값이 2인 동안만 유효하다.
- 검사는 `io_uring_setup()`에서만 일어난다. 이미 만들어진 링과 그 fd를 상속·전달받은 프로세스는 영향을 받지 않는다. 부팅 직후 sysctl 적용 전에 링을 만든 서비스는 계속 동작한다.

### 4.3 제한 메커니즘 비교

| 메커니즘 | 누가 거는가 | 판단 단위 | 우회 가능성 / 한계 | 비용 |
|---|---|---|---|---|
| seccomp (syscall 3개 차단) | 프로세스 트리 | syscall 번호 | io_uring 전체 on/off만 가능 | 무시 가능 |
| `io_uring_disabled` sysctl | 시스템 관리자 | 링 생성 | 기존 링에 무영향 | 없음 |
| LSM (`io_uring` 클래스) | 보안 정책 | creds 대리, SQPOLL, uring_cmd, 생성 | 정책이 있어야 효과 | 훅 호출 비용 |
| `IORING_REGISTER_RESTRICTIONS` | 링 생성자 | register op, SQE op, SQE 플래그 비트맵 | 인자 기반 판단 불가 | 비트 검사 (`io_check_restriction()`) |
| `IORING_REGISTER_BPF_FILTER` (7.0) | 링 생성자 또는 태스크(`no_new_privs` 필요) | opcode별 cBPF 프로그램, 요청 속성 | 필터가 보는 필드 범위로 제한 | opcode에 필터가 있을 때만 `bpf_prog_run_pin_on_cpu()` |

BPF 필터의 실행은 `io_submit_sqe()`에서 `io_uring_run_bpf_filters()`로 이뤄진다. `__io_uring_run_bpf_filters()`는 RCU 아래에서 `filters[req->opcode]` 체인을 돌며 모든 필터가 1을 반환해야 허용하고, 하나라도 0이면 `-EACCES`로 거부한다. 필터가 없는 opcode는 `rcu_access_pointer()` 한 번으로 빠르게 통과한다.

### 4.4 주요 CVE (NVD 레코드 확인)

| CVE | 영역 | NVD 요약 | 수정 |
|---|---|---|---|
| CVE-2021-3491 | provided buffers | `PROVIDE_BUFFERS`에서 `MAX_RW_COUNT` 제한 우회 → 힙 오버플로 | `d1f82808877b` |
| CVE-2021-41073 | provided buffers | `loop_rw_iter()`(5.10~5.14.6)에서 커널 버퍼 free 유발, 권한 상승 | `16c8d2df7ec0` |
| CVE-2022-1786 | IOPOLL | 여러 태스크가 한 IOPOLL 링에 제출할 때 UAF | [추측/미확인] |
| CVE-2022-29582 | timeout | 타임아웃 경쟁 조건 UAF (5.17.3 이전) | `e677edbcabee` |
| CVE-2022-2602 | 등록 파일 | Unix SCM 가비지 컬렉션과 등록 파일의 UAF | [추측/미확인] |
| CVE-2023-1872 | 등록 파일 | `io_file_get_fixed()`가 `uring_lock` 없이 동작, 해제와 경쟁해 UAF | 5.10.y 백포트 확인 |
| CVE-2023-2598 | 등록 버퍼 | `io_sqe_buffer_register()`가 버퍼 끝 너머 물리 메모리 접근 | [추측/미확인] |
| CVE-2023-21400 | 락킹 (Android) | 부적절한 락킹으로 인한 메모리 손상 | [추측/미확인] |
| CVE-2024-0582 | buffer ring | `IORING_REGISTER_PBUF_RING`을 `mmap` 후 해제하는 경로의 결함 | `c392cbecd8ec` |

패턴은 분명하다. 대부분 **등록 자원과 비동기 실행 문맥의 수명 교차점**에서 나왔다. 2023년 Google 블로그는 5.15의 io_uring 전체를 5.10 stable로 백포트한 대응을 "comprehensive security fixes"의 예로 들었다.

### 4.5 운영 권고

1. 일반 사용자 셸·컨테이너 호스트: `kernel.io_uring_disabled=1`과 전용 `io_uring_group`으로 필요한 서비스만 허용한다.
2. 컨테이너: 런타임 기본 seccomp 프로필이 io_uring을 막는지 확인하고, 필요한 워크로드만 별도 프로필로 연다.
3. 링을 넘겨주는 구조(VMM, 브로커): `IORING_SETUP_R_DISABLED` + restrictions, 7.0 이상이면 BPF 필터로 허용 opcode와 속성을 좁힌다.
4. SELinux 정책: `io_uring { override_creds sqpoll cmd allowed }` 권한을 도메인별로 명시한다.
5. 커널: io_uring을 허용하는 시스템일수록 stable 업데이트 주기를 짧게 가져간다.

---

## 5. Primary References

- [Auditing io_uring [LWN.net]](https://lwn.net/Articles/858023/) — 2021-06-03
- [Security requirements for new kernel features [LWN.net]](https://lwn.net/Articles/902466/) — 2022-07-28
- [Re: [PATCH] lsm,io_uring: add LSM hooks to for the new uring_cmd file op [LWN.net]](https://lwn.net/ml/linux-security-module/CAHC9VhQKeufrqN=dVZ74wEFgd3K=KY-aEZafYembT738juzWUw@mail.gmail.com/) — Paul Moore, 2022-07-18
- [[PATCH v2 0/1] Add a sysctl to disable io_uring system-wide [LWN.net]](https://lwn.net/ml/io-uring/20230629132711.1712536-1-matteorizzo@google.com/) — Matteo Rizzo, 2023-06-29
- [Documentation for /proc/sys/kernel/ — The Linux Kernel documentation](https://www.kernel.org/doc/html/latest/admin-guide/sysctl/kernel.html) — `io_uring_disabled`, `io_uring_group` 항목
- [torvalds/linux commit cdc1404a4046: lsm,io_uring: add LSM hooks to io_uring](https://github.com/torvalds/linux/commit/cdc1404a4046)
- [torvalds/linux commit 2a5840124009: lsm,io_uring: add LSM hooks for the new uring_cmd file op](https://github.com/torvalds/linux/commit/2a5840124009)
- [torvalds/linux commit c6ad9fdbd44b: io_uring,lsm,selinux: add LSM hooks for io_uring_setup()](https://github.com/torvalds/linux/commit/c6ad9fdbd44b)
- [torvalds/linux commit 21b55dbc0653: io_uring: add IOURING_REGISTER_RESTRICTIONS opcode](https://github.com/torvalds/linux/commit/21b55dbc0653)
- [torvalds/linux commit d42eb05e60fe: io_uring: add support for BPF filtering for opcode restrictions](https://github.com/torvalds/linux/commit/d42eb05e60fe)
- [io_uring/bpf_filter.c (torvalds/linux master)](https://github.com/torvalds/linux/blob/master/io_uring/bpf_filter.c)
- Google Online Security Blog, "Learnings from kCTF VRP's 42 Linux kernel exploits submissions", Tamás Koczka, 2023-06-14 (security.googleblog.com)
- moby/moby PR #46762 "seccomp: block io_uring_* syscalls in default profile", 2023-11-02 병합 (github.com/moby/moby)
