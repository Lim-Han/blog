# Tracepoint ABI 논쟁과 BTF·CO-RE·BPF Trampoline으로의 우회

> 범위: 2011년 PowerTOP 회귀 사건부터 2016~2017년 Kernel/Maintainers Summit 논의, 그리고 BTF(4.18)·raw tracepoint(4.17)·BPF trampoline(5.5)·kprobe_multi(5.18)로 이어진 기술적 우회 경로. 소스 확인은 Linux master(2026-10) 및 명시한 태그 기준.

## 1. Verdict

정적 트레이스포인트(`TRACE_EVENT`)가 ABI인가라는 질문에 커널 커뮤니티가 내린 답은 "원칙적으로는 내부 구현의 창(view)이지만, 실제로 쓰이는 도구가 깨지면 회귀(regression)로 취급한다"는 실용주의다. 흔히 Linus Torvalds의 발언으로 회자되는 "Tracepoints are NOT an ABI ... that's user space's problem" 같은 인용은 확인 가능한 출처가 없고 역사적 사실과도 맞지 않는다. 2011년 5월 PowerTOP이 2.6.39-rc에서 깨졌을 때 Linus는 정반대로 "We have programs that use that ABI and thus it's a regression if they break."라고 답했고, 제거된 `lock_depth` 필드 자리에 `padding`을 넣는 되돌림이 머지되었다. 이 `padding` 필드는 PowerTOP 2.0이 배포된 뒤인 v3.9에서야 `struct trace_entry`에서 사라졌다(커밋 `b000c8065a92` "tracing: Remove the extra 4 bytes of padding in events", 2013-01. v3.8 `include/linux/ftrace_event.h`에는 `int padding;`이 존재, v3.9에는 없음).

ABI 부담을 이유로 트레이스포인트 자체를 경계한 쪽은 Linus가 아니라 서브시스템 메인테이너들이었다. LWN의 2016년 Kernel Summit 보도에 따르면 Peter Zijlstra는 스케줄러에 제거하고 싶은 트레이스포인트가 있지만 무언가를 깨뜨릴까 봐 제거하지 못한다고 말했고, Al Viro는 VFS에 트레이스포인트를 허용하지 않겠다는 방침을 유지했다. 같은 자리에서 Linus는 "문제가 되는 트레이스포인트는 그냥 빼고, 누군가 비명을 지르면 그때 되돌린다"는 입장을 밝혔다(LWN 서술 기준).

eBPF 진영의 기여는 이 정치적 교착을 "안정적 인터페이스를 늘리지 않고도 내부를 볼 수 있게 하는" 기술로 우회한 것이다.

- **raw tracepoint(4.17)와 bare tracepoint**: `DECLARE_TRACE()`로 정의된 트레이스포인트는 tracefs에 이벤트/포맷 파일을 만들지 않으므로 "export된 ABI"가 아니다. 스케줄러는 v5.3에서 `pelt_cfs_tp` 등 `_tp` 접미사 트레이스포인트를 이 방식으로 추가했다.
- **BTF(4.18)와 CO-RE(libbpf, 2019)**: 커널 타입 정보를 `/sys/kernel/btf/vmlinux`(5.4)로 노출하고, 로드 시점에 필드 오프셋을 재배치해 구조체 레이아웃 변화에 적응한다. 단 필드 이름 변경(예: 5.12의 `bio->bi_disk` → `bio->bi_bdev`)은 자동으로 해결되지 않으며 `bpf_core_field_exists()` 분기가 필요하다.
- **BPF trampoline / `fentry`·`fexit`(5.5)**: ftrace의 함수 진입 nop 슬롯을 `register_ftrace_direct()` 기반 direct call로 바꿔, BTF로 타입이 기술된 거의 모든 전역 함수에 kprobe보다 저렴하게 부착한다.

결론적으로 "트레이스포인트는 ABI가 아니다"라는 선언은 존재하지 않았고, 대신 "BPF가 내부 함수에 붙는 것은 사용자가 커널 내부에 의존하는 것이며 ABI 보장 대상이 아니다"라는 묵시적 계약이 형성되었다. 이 계약도 완전하지 않다. 5.11의 `block_rq_issue` 프로토타입 변경(`struct request_queue *q` 인자 제거)이나 6.4의 `io_uring_submit_sqe` → `io_uring_submit_req` 개명처럼, raw tracepoint·fentry 사용자는 여전히 커널 버전별 분기를 유지해야 한다.

---

## 2. Problem Statement

### 2.1 Tracepoint의 두 얼굴: in-kernel hook과 user-visible event

Linux의 정적 트레이스포인트에는 계층이 둘 있다.

| 계층 | 정의 매크로 | 사용자 공간 노출 | 소비자 |
|---|---|---|---|
| tracepoint hook | `DECLARE_TRACE()` (6.16부터 `trace_<name>_tp()` 생성) | 없음 (tracefs 이벤트 디렉터리 없음) | 모듈, BPF `raw_tp`/`tp_btf` |
| trace event | `TRACE_EVENT()` / `DECLARE_EVENT_CLASS` + `DEFINE_EVENT` | `/sys/kernel/tracing/events/<sys>/<event>/format` 및 ring buffer 바이너리 레코드 | ftrace, perf, LTTng, BPF `tracepoint` |

`TRACE_EVENT()`는 `TP_STRUCT__entry`로 정의한 필드를 ring buffer에 기록하고 그 레이아웃을 `format` 파일로 자기기술(self-describing)한다. 설계 의도는 도구가 `format`을 파싱해 오프셋을 동적으로 얻는 것이었다. 2011년의 문제는 PowerTOP이 이 파일을 파싱하지 않고 고정 오프셋을 가정했다는 데 있었다. 공통 헤더(`struct trace_entry`)에서 BKL 제거용 임시 필드 `lock_depth`가 빠지자 이후 모든 필드가 4바이트씩 당겨졌고 PowerTOP은 쓰레기 값을 읽었다.

### 2.2 메인테이너가 치르는 비용

트레이스포인트가 사실상 ABI가 되면 다음 비용이 생긴다.

- **리팩토링 제약**: 이벤트가 함수 내부의 특정 지점과 인자에 묶인다. 함수를 쪼개거나 상태 기계를 바꾸면 이벤트의 의미가 달라진다. 스케줄러처럼 내부 구조가 자주 바뀌는 서브시스템에서 특히 부담이 크다.
- **필드 의미의 고착**: `sched_switch`의 `prev_state`처럼 커널 내부 상태 비트를 그대로 노출한 필드는 내부 표현을 바꾸기 어렵게 만든다. 반대로 tracefs `format`은 유지한 채 hook 프로토타입만 바꾸면 raw tracepoint 사용자가 깨진다. 실제로 `sched_switch`의 `TP_PROTO`는 v5.17의 `(bool preempt, struct task_struct *prev, struct task_struct *next)`에서 v5.18에 `unsigned int prev_state` 인자가 추가된 형태로 바뀌었다(양 태그의 `include/trace/events/sched.h` 대조). `tp_btf/sched_switch`의 인자 순서를 가정한 BPF 프로그램은 버전 분기가 필요해졌다.
- **성능 비용의 고착**: LWN "Removing four bytes from the kernel ABI"(2012)는 `lock_depth` 되돌림 때문에 ftrace/perf가 기록하는 모든 이벤트에 4바이트가 추가로 붙게 된 상황을 다룬다. ABI 지위는 기능뿐 아니라 오버헤드도 동결한다.

### 2.3 동적 계측의 비용: kprobe의 실제 구조

트레이스포인트를 늘리지 못하면 동적 계측이 대안이다. 그러나 "kprobe = 항상 `int3` + single-step, 수백 ns~µs, 처리량 수십 % 폭락" 같은 통념은 과장이다. 실제 kprobe는 세 경로를 가진다.

1. **기본 경로(`int3`)**: 프로브 주소의 첫 바이트를 `int3`로 바꾸고, 예외 핸들러가 pre-handler를 호출한 뒤 원 명령어를 out-of-line으로 실행한다. 많은 명령어는 single-step 예외 없이 "boost"되어 실행된다.
2. **`CONFIG_KPROBES_ON_FTRACE`**: 프로브 주소가 함수 진입부의 ftrace 위치(`mcount`/`fentry` nop)이면 `int3` 대신 ftrace 콜백(`kprobe_ftrace_handler`, `arch/x86/kernel/kprobes/ftrace.c`)으로 처리한다. BPF kprobe는 대부분 함수 진입에 붙으므로 실제로는 이 경로가 흔하다.
3. **`CONFIG_OPTPROBES`(jump optimization)**: 함수 중간 주소라도 안전 조건(교체 영역이 한 함수 안에 있고, 간접 점프가 없는 등)을 만족하면 `int3`를 5바이트 `jmp`로 교체해 detour buffer로 보낸다. `debug.kprobes_optimization` sysctl로 제어된다.

`Documentation/trace/kprobes.rst`는 "2005년 무렵의 전형적 CPU"에서 비최적화 kprobe 1회가 0.5~1.0µs라고 적고, 별도 항목에서 최적화된 kprobe는 통상 0.07~0.1µs라고 적고 있다. 이는 오래된 하드웨어 기준 수치이며 현대 CPU와 BPF 핸들러 비용은 별도로 측정해야 한다. 처리량 감소율은 프로브 빈도·핸들러 내용·맵 연산에 좌우되므로 일반화된 퍼센트를 제시할 근거는 없다.

`kretprobe`는 반환 주소를 가로채는 방식이라 인스턴스 풀 관리 비용이 있고, 5.18에서 `KRETPROBE_ON_RETHOOK`(rethook 기반)으로 재구현되었다. 같은 5.18에 `fprobe`와 `BPF_TRACE_KPROBE_MULTI`가 도입되어, 수천 개 함수에 한 번에 부착할 때의 비용(심볼마다 kprobe 등록)도 줄었다.

### 2.4 이식성 문제: BCC 시대

BCC는 대상 호스트에서 커널 헤더와 Clang/LLVM으로 BPF C 코드를 런타임 컴파일했다. 커널 버전별 구조체 레이아웃 차이를 흡수하는 대가로, 프로덕션 노드마다 컴파일러와 헤더를 두어야 했고 시작 지연과 메모리 비용이 컸다. 이 문제는 ABI 논쟁과 독립적이지만, "커널 내부 레이아웃에 의존하는 도구를 어떻게 배포하는가"라는 같은 뿌리를 가진다.

---

## 3. The Debate

### 3.1 2011: PowerTOP 회귀와 Linus의 "reality" 판정

사건의 순서는 다음과 같다(LWN "Ftrace, perf, and the tracing ABI", 2011-05-11, Jonathan Corbet).

1. Steven Rostedt가 BKL 제거 작업을 돕기 위해 모든 이벤트 공통 헤더에 `lock_depth` 필드를 임시로 넣었다(커밋 `637e7e864103` "tracing: add lock depth to entries", 2009-09).
2. BKL이 사라진 뒤 Rostedt가 2.6.39 개발 주기에 이 필드를 제거했다(`e6e1e2593592` "tracing: Remove lock_depth from event entry").
3. Arjan van de Ven이 PowerTOP이 깨졌다고 보고하고, 같은 자리에 0으로 채운 padding 필드를 넣는 패치를 보냈다.
4. Rostedt는 PowerTOP이 `format` 파일을 제대로 읽었다면 깨지지 않았을 것이라며 반대했다. 이에 Linus가 답했다.

> "That whole reality thing again?
> Clearly it didn't end up as the ABI. We have programs that use that ABI and thus it's a regression if they break."
>
> — Linus Torvalds, "Re: Fix powerTOP regression with 2.6.39-rc5", LKML, 2011-05-06 ([LWN 아카이브](https://lwn.net/Articles/442122/))

맥락: Rostedt는 직전 메일에서 "지난 Kernel Summit에서 당신은 trace event의 ASCII format 슬라이드를 가리키며 'That's the ABI'라고 했다"고 상기시켰다. Linus의 답은 "설계상 ABI로 의도한 것(포맷 기술 파일)"과 "현실에서 ABI가 된 것(바이너리 레이아웃)"을 구분한다. 규칙은 문서화된 인터페이스가 아니라 실제 사용자의 동작으로 정해진다는 것이다. 이 판정은 Linus에게 흔히 귀속되는 "Tracepoints are NOT an ABI"와 정반대다.

Rostedt의 반론도 기록으로 남아 있다.

> "The reason tracepoints have currently been stable is that kernel design changes do not happen often. But they do happen, and I foresee that in the future, the kernel will have a large number of "legacy tracepoints", and we will be stuck maintaining them forever."
>
> — Steven Rostedt, "Re: Fix powerTOP regression with 2.6.39-rc5", LKML, 2011-05-09 ([LWN 아카이브 442339](https://lwn.net/Articles/442339/); [LWN 442113](https://lwn.net/Articles/442113/)에 인용)

맥락: 그는 XFS의 200개가 넘는 트레이스포인트를 분석하는 도구가 생기면 그 전부가 ABI가 되느냐고 물었다. 이 우려가 이후 10년간 메인테이너들이 트레이스포인트를 경계한 논리의 원형이다. padding은 PowerTOP 2.0 배포 뒤 v3.9에서 제거되었다(LWN "Removing four bytes from the kernel ABI", 2012; 커밋 `b000c8065a92`).

### 3.2 2016 Kernel Summit: 메인테이너의 두려움과 Linus의 "change it and see who screams"

LWN "Tracepoint challenges"(2016-11-02)의 요지는 다음과 같다(모두 LWN 서술이며 발언 원문이 아님).

- Shuah Khan: 배포된 시스템에서 트레이스포인트는 디버깅에 매우 효과적이지만, 추가하면 영원히 유지해야 하는가?
- Ted Ts'o: eBPF 덕분에 트레이스포인트가 훨씬 쓰기 쉬워졌고, 관리자들이 실제로 의존하기 시작했으므로 ABI 문제는 더 이상 이론이 아니다.
- **Peter Zijlstra**: 스케줄러에 제거하고 싶은 트레이스포인트가 있지만 무언가를 깨뜨릴까 두려워 제거하지 못한다.
- **Linus**: 개발을 방해하는 트레이스포인트는 그냥 빼야 한다. PowerTOP 때는 커뮤니티가 아직 트레이스포인트 다루는 법을 배우던 중이었고 그때는 굳이 깨뜨릴 필요가 없었다. 트레이스포인트는 커널 내부를 보는 창이며 시간이 지나며 바뀔 수 있어야 한다. 제거가 사용자 공간에 고통을 주면 그때 재고한다. 알아내는 방법은 바꿔 보고 누가 비명을 지르는지 보는 것이다.
- **Al Viro**: VFS에는 트레이스포인트를 허용하지 않는다. 미래에 트레이스포인트 변경 때문에 새 커널로 부팅하지 못하는 시스템이 생기는 것을 원하지 않는다.

즉 대립 구도는 "Linus 대 도구 진영"이 아니라 "회귀 규칙을 사례별로 적용하려는 Linus" 대 "그 사례별 판단의 불확실성 자체를 비용으로 느끼는 메인테이너들"이었다.

### 3.3 2017 Kernel Summit / Maintainers Summit: BPF로 우회한다는 합의

LWN "Another attempt to address the tracepoint ABI problem"(2017-10-27)에 따르면 Rostedt는 staging 트리와 비슷하게 트레이스포인트 hook만 넣고 trace event로의 노출은 별도 모듈 로드로만 가능하게 하자고 제안했다. Ben Hutchings는 배포판마다 그 모듈을 실으면 결국 그것이 ABI가 된다고 반박했고, 서명된 모듈만 허용하는 환경 문제도 지적되었다. Ted Ts'o는 BPF 기반 도구가 PowerTOP만큼 대중화되면 같은 문제가 반복될 것이며, 커널과 밀접하게 결합된 도구에 대해 Linus의 사용자 공간 보장을 지키기 어렵기 때문에 BPF가 이 문제를 "trainwreck"으로 만들 것이라고 말했다(LWN 서술). Andrew Morton은 Linus가 트레이스포인트를 ABI에 포함시킨 판단이 옳았는지 되물었다.

결론은 그 주 Maintainers Summit에서 나왔다. LWN 서술에 따르면 명시적 트레이스포인트 추가를 보류하고, 대신 애플리케이션이 커널의 임의 함수에 인자 접근이 가능한 BPF 스크립트를 쉽게 붙일 수 있도록 지원을 추가하며, Arnd Bergmann의 질문에 Linus는 함수 제거로 인기 스크립트가 깨져도 고쳐야 할 회귀로 보지 않겠다고 답했다. 다만 그런 일이 생기면 커널이 그 정보를 더 직접적인 방식(트레이스포인트 등)으로 제공해야 한다는 신호로 보겠다고 덧붙였다.

이것이 이후 BTF 기반 `fentry`/`fexit`가 받아들여진 정책적 배경이다. "BPF가 내부 함수에 붙는 것"은 ABI 밖이라는 합의가 먼저 있었고, 기술이 그 합의를 실현했다.

### 3.4 기술적 실현: BPF trampoline 패치셋(2019-11)

Alexei Starovoitov는 2019-11-02 "Introduce BPF trampoline" 패치셋(LWN 803803, Message-ID `20191102220025.2475981-1-ast@kernel.org`)을 보냈다. 커버레터는 이 기능이 Steven Rostedt의 ftrace 트리에 있던 `register_ftrace_direct()` API에 의존한다고 밝히고 머지 경로를 Rostedt와 조율한다. 즉 trampoline은 ftrace 진영과의 대립이 아니라 ftrace 인프라 위에 세워졌다. 머지된 커밋 `fec56f5890d9`("bpf: Introduce BPF trampoline", 2019-11-14)의 메시지는 다음과 같다.

> "Introduce BPF trampoline concept to allow kernel code to call into BPF programs with practically zero overhead."
>
> "The tracing use case in the datacenter demonstrated that certain key kernel functions have (like tcp_retransmit_skb) have 2 or more kprobes that are always active. Other functions have both kprobe and kretprobe. So it is essential to keep both kernel code and BPF programs executing at maximum speed."
>
> — Alexei Starovoitov, commit fec56f5890d9, 2019-11-14 ([lore](https://lore.kernel.org/bpf/20191114185720.1641606-5-ast@kernel.org/))

맥락: 같은 메시지는 당시 nop 진입부를 통해 부착 가능한 전역 함수가 약 22k개이며, 함수 인자 타입은 BTF로 기술되고 `btf_distill_func_proto()`가 이를 "function model"로 추출한다고 설명한다. "practically zero overhead"는 kprobe 대비 상대적 표현이며 구체 ns 수치는 이 메시지에 없다. "2~5ns", "kprobe 대비 100분의 1" 같은 정량 비교는 1차 출처가 없다.

### 3.5 남은 쟁점

- **raw tracepoint도 ABI인가**: bare tracepoint(`DECLARE_TRACE`)는 tracefs에 노출되지 않지만 BPF `raw_tp`/`tp_btf`로 접근 가능하다. v5.3 `include/trace/events/sched.h`는 이에 대해 "Following tracepoints are not exported in tracefs and provide hooking mechanisms only for testing and debugging purposes."라고 주석을 단다. 그러나 앞서 본 `sched_switch`(5.18), `block_rq_issue`(5.11), `io_uring_submit_req`(6.4) 변경은 tracefs ABI 밖의 변화도 BPF 도구를 깨뜨린다는 것을 보여준다.
- **누가 비명을 지르는가**: 2017년 합의는 "BPF 스크립트 파손은 회귀가 아니다"였지만, 배포판에 포함된 libbpf-tools/bpftrace 도구가 깨질 때 실제로 어떻게 처리될지는 사례별이다. [추측/미확인: 이후 BPF 도구 파손이 회귀로 처리되어 되돌려진 사례가 있는지는 확인하지 않음]

---

## 4. Implementation Impact

### 4.1 도입 연표 (메인라인 태그별 소스 대조로 확인)

| 버전 | 기능 | 확인 근거 |
|---|---|---|
| 2.6.39 → 3.9 | `lock_depth` 제거 → PowerTOP 회귀로 `padding` 복원(`a3a4a5acd3bd`) → v3.9에서 최종 제거(`b000c8065a92`) | v3.8/v3.9 `include/linux/ftrace_event.h` |
| 4.17 | `BPF_PROG_TYPE_RAW_TRACEPOINT` | v4.16/v4.17 uapi `bpf.h` |
| 4.18 | BTF (`kernel/bpf/btf.c`, Martin KaFai Lau, 커밋 `69b693f0aefa`) | v4.17에 파일 없음, v4.18에 존재 |
| 5.3 | 스케줄러 bare tracepoint `pelt_cfs_tp` 등 | v5.2/v5.3 `sched.h` |
| 5.4 | `/sys/kernel/btf/vmlinux` (`kernel/bpf/sysfs_btf.c`, Andrii Nakryiko, `341dfcf8d78e`) | v5.3에 파일 없음 |
| 5.4 (libbpf) | CO-RE 재배치 (`ddc7c3042614` "libbpf: implement BPF CO-RE offset relocation algorithm") | 2019-08 커밋 |
| 5.5 | BPF trampoline, `BPF_TRACE_FENTRY`/`FEXIT`, `BPF_TRACE_RAW_TP`(`tp_btf`) | v5.4에 `kernel/bpf/trampoline.c` 없음 |
| 5.12 | `struct bio`의 `bi_disk`(gendisk) → `bi_bdev`(block_device) | v5.11/v5.12 `blk_types.h` |
| 5.18 | `fprobe`, `BPF_TRACE_KPROBE_MULTI`, `KRETPROBE_ON_RETHOOK` | v5.17/v5.18 대조 |
| 6.16 | `DECLARE_TRACE(name)`이 `trace_<name>_tp()`를 생성 (`_tp` 접미사 자동화) | v6.15/v6.16 `tracepoint.h` |

### 4.2 BPF trampoline의 실제 실행 경로 (x86-64, master 기준)

trampoline 내부에 `__bpf_prog_run_fentry` 같은 별도 함수가 있는 것이 아니다. 실제 구조는 `arch/x86/net/bpf_jit_comp.c`의 `__arch_prepare_bpf_trampoline()`이 생성하며, 소스 주석에 있는 `eth_type_trans` 예시를 요약하면 다음과 같다.

```
; fentry만 붙은 경우 (BPF_TRAMP_F_CALL_ORIG 없음)
push rbp ; mov rbp, rsp ; sub rsp, 16
mov [rbp-16], rdi ; mov [rbp-8], rsi        ; 인자를 u64 배열로 스택에 저장
call __bpf_prog_enter                       ; rcu_read_lock + migrate/preempt 처리, stats용 시작 시각 반환
lea  rdi, [rbp-16]                          ; R1 = ctx (u64 인자 배열)
call <JIT된 fentry 프로그램>
call __bpf_prog_exit                        ; rcu_read_unlock + stats 누적
mov rdi, [rbp-16] ; mov rsi, [rbp-8]        ; 인자 복원
leave ; ret                                 ; 원 함수의 5바이트 nop 다음으로 복귀

; fexit가 있으면 BPF_TRAMP_F_CALL_ORIG 설정:
; fentry 실행 → call eth_type_trans+5 (원 함수 본문) → 반환값을 [rbp-8]에 저장
; → fexit 프로그램 실행(인자 + 반환값 접근) → BPF_TRAMP_F_SKIP_FRAME으로 원 함수 프레임을 건너뛰고 호출자에게 반환
```

핵심 세부:

- **진입/퇴출 래퍼**: `kernel/bpf/trampoline.c`에는 `__bpf_prog_enter_recur()`/`__bpf_prog_exit_recur()`, `__bpf_prog_enter_sleepable*()`, `__bpf_prog_enter_lsm_cgroup()` 등 변형이 있다. `_recur` 변형은 `bpf_prog_get_recursion_context()`로 재귀를 막고, 실패 시 `bpf_prog_inc_misses_counter()`로 `recursion_misses`를 올린 뒤 프로그램을 건너뛴다.
- **통계**: `static_branch_unlikely(&bpf_stats_enabled_key)`가 켜져 있을 때만 `__update_prog_stats()`가 `sched_clock()` 차이를 per-CPU `prog->stats`(`cnt`, `nsecs`)에 누적한다. 이것이 `kernel.bpf_stats_enabled`(5.1) 또는 `BPF_ENABLE_STATS`(5.8)로 켜는 `run_time_ns`/`run_cnt`의 출처다.
- **부착**: `bpf_trampoline_link_prog()` → `bpf_trampoline_update()`가 이미지를 재생성하고 `register_fentry()`/`modify_fentry()`가 ftrace direct call로 nop 슬롯을 `call <trampoline>`으로 바꾼다. 커밋 메시지대로 프로그램이 붙거나 떨어질 때마다 trampoline을 다시 만들어 간접 호출(retpoline) 비용을 피한다.
- **제약**: ftrace 위치(nop)가 있는 함수만 가능하므로 `notrace` 함수, 인라인된 함수, 일부 아키텍처 제약 대상은 부착할 수 없다. 인자는 BTF 함수 모델로 기술 가능해야 하며 x86-64에서 6개를 넘는 인자는 스택 인자 처리가 필요하다(`nr_regs > 6` 분기).

### 4.3 CO-RE가 해결하는 것과 해결하지 못하는 것

CO-RE는 같은 이름의 필드가 다른 오프셋에 있는 경우를 해결한다. 5.12의 `bi_disk` → `bi_bdev` 같은 **필드 제거/개명**은 프로그램이 명시적으로 분기해야 한다. libbpf 관용구는 `___suffix`가 붙은 "flavor" 타입과 `bpf_core_field_exists()`(`tools/lib/bpf/bpf_core_read.h`)를 조합하는 것이다.

```c
/* 5.11 이하 레이아웃을 기술하는 flavor 타입. libbpf는 '___' 이후를 무시하고 매칭 */
struct bio___old { struct gendisk *bi_disk; } __attribute__((preserve_access_index));

static __always_inline dev_t bio_dev(struct bio *bio)
{
    if (bpf_core_field_exists(bio->bi_bdev))          /* 5.12+ */
        return BPF_CORE_READ(bio, bi_bdev, bd_dev);
    struct bio___old *old = (void *)bio;              /* <= 5.11 */
    struct gendisk *disk = BPF_CORE_READ(old, bi_disk);
    return MKDEV(BPF_CORE_READ(disk, major), BPF_CORE_READ(disk, first_minor));
}
```

로드 시 libbpf는 대상 커널 BTF에서 `bi_bdev` 존재 여부를 상수로 치환하고, verifier는 죽은 분기를 제거한다. `MKDEV`는 `vmlinux.h`에 포함되지 않는 커널 매크로이므로 BPF 쪽에서 직접 정의해야 하며, `gendisk` 필드 이름(`major`, `first_minor`)도 대상 버전마다 확인이 필요하다.

### 4.4 계측 수단 비교

| 항목 | trace event (`TRACE_EVENT`) | raw tracepoint / `tp_btf` | kprobe (`int3` / ON_FTRACE / optprobe) | `fentry`/`fexit` (trampoline) |
|---|---|---|---|---|
| 안정성 지위 | tracefs `format`; 사용자가 의존하면 회귀 규칙 적용 사례 있음 | tracefs 밖; TP_PROTO 변경 가능(5.11, 5.18 사례) | ABI 아님. 2017 합의상 함수 제거는 회귀 아님 | kprobe와 동일 |
| 부착 지점 | 정의된 지점만 | 정의된 지점만 (bare tracepoint 포함) | 거의 모든 명령어 주소 | ftrace nop이 있는 함수 진입/반환 |
| 인자 접근 | 기록된 필드(복사본) | 원 인자 포인터, `tp_btf`는 타입 검증 | `pt_regs`, 타입 정보 없음 | BTF 타입이 붙은 인자, fexit는 반환값까지 |
| 진입 메커니즘 | static key + 직접 호출 | static key + `__bpf_trace_*` shim | 예외 또는 ftrace 콜백 또는 jmp detour | ftrace direct call → 생성된 trampoline |
| 반환 추적 | 별도 이벤트 필요 | 별도 이벤트 필요 | `kretprobe`(5.18부터 rethook) | `fexit` (BPF_TRAMP_F_CALL_ORIG) |
| 다수 함수 일괄 부착 | 해당 없음 | 해당 없음 | `kprobe_multi`(5.18, fprobe) | `kernel/bpf/trampoline.c`의 `register_fentry_multi()` (v7.1에는 없고 v7.2에 처음 등장, 태그별 대조) |

### 4.5 운영상 함의

- 도구는 tracefs trace event를 1순위로 쓰되, `format`을 런타임 파싱하거나 BTF 기반 `tp_btf`를 써서 레이아웃 의존을 줄인다.
- 내부 함수(`fentry`)에 의존하는 도구는 "커널이 바뀌면 깨질 수 있는 것"으로 간주하고, `bpf_core_field_exists()`, `bpf_core_type_exists()`, 그리고 함수 존재 여부 검사(`libbpf`의 `bpf_program__set_autoload(false)` 등)로 다중 버전을 지원한다.
- 오버헤드는 수치를 가정하지 말고 `kernel.bpf_stats_enabled=1` 상태에서 `bpftool prog show`의 `run_time_ns`/`run_cnt`로 측정한다. 통계 자체가 `sched_clock()` 호출 비용을 더하므로 측정 후 끈다.

---

## 5. Primary References

- [Ftrace, perf, and the tracing ABI [LWN.net]](https://lwn.net/Articles/442113/) — Jonathan Corbet, 2011-05-11. PowerTOP 회귀와 `lock_depth`/padding 경위.
- [Re: Fix powerTOP regression with 2.6.39-rc5 [LWN.net]](https://lwn.net/Articles/442122/) — Linus Torvalds, 2011-05-06. 3.1절 인용 원문.
- [Removing four bytes from the kernel ABI [LWN.net]](https://lwn.net/Articles/498128/) — Jake Edge, 2012-05-23. padding 필드 제거 논의.
- [Tracepoint challenges [LWN.net]](https://lwn.net/Articles/705270/) — Jonathan Corbet, 2016-11-02. Peter Zijlstra, Al Viro, Linus 발언 서술.
- [Another attempt to address the tracepoint ABI problem [LWN.net]](https://lwn.net/Articles/737530/) — Jonathan Corbet, 2017-10-27. Maintainers Summit의 "BPF를 임의 함수에 부착" 합의.
- [Introduce BPF trampoline [LWN.net]](https://lwn.net/Articles/803803/) — Alexei Starovoitov 패치셋 커버레터 사본, 2019-11-02.
- [[PATCH bpf-next 0/7] Introduce BPF trampoline](https://lore.kernel.org/bpf/20191102220025.2475981-1-ast@kernel.org/) — lore 원문, 2019-11-02.
- [bpf: Introduce BPF trampoline (lore)](https://lore.kernel.org/bpf/20191114185720.1641606-5-ast@kernel.org/) — 병합 커밋의 Link 태그가 가리키는 패치 메일, 2019-11-14 (제목의 `[PATCH ...]` 접두어는 lore 봇 차단으로 미확인).
- [bpf: Introduce BPF trampoline · torvalds/linux@fec56f5](https://github.com/torvalds/linux/commit/fec56f5890d93fc2ed74166c397dc186b1c25951) — 병합 커밋, 3.4절 인용 원문.
- [BPF Type Format (BTF) — The Linux Kernel documentation](https://www.kernel.org/doc/html/latest/bpf/btf.html) — BTF 인코딩과 커널 BTF 공식 문서.
- [Kernel Probes (Kprobes) — The Linux Kernel documentation](https://www.kernel.org/doc/html/latest/trace/kprobes.html) — jump optimization과 오버헤드 수치(2005년 CPU 기준).
- [Using the Linux Kernel Tracepoints — The Linux Kernel documentation](https://www.kernel.org/doc/html/latest/trace/tracepoints.html) — `DECLARE_TRACE`와 `_tp` 접미사.
