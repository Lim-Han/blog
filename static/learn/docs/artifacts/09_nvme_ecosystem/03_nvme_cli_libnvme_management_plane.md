# NVMe 관리 평면: nvme-cli · libnvme, admin 패스스루, 디스커버리, 권한 모델

> 기준 소스: Linux 7.3-rc7 (`torvalds/linux` master, 2026-10 확인) `drivers/nvme/host/{ioctl.c,core.c,fabrics.c}`, `include/uapi/linux/nvme_ioctl.h`. 사용자 공간은 `github.com/linux-nvme/nvme-cli` master(2026-10-14 push, 최신 릴리스 v3.1 2026-09-18)와 `NEWS.md`, `linux-nvme/nvme-stas` README 기준이다. 권한 규칙의 도입 버전은 git.kernel.org 태그별 grep과 GitHub 커밋으로 확인했다.

## 1. Verdict

NVMe의 데이터 평면(I/O 큐, blk-mq, io_uring)은 커널이 소유한다. 관리 평면은 다르다. 장치 식별, 로그 페이지, 기능 설정, namespace 생성, 펌웨어 갱신, sanitize, 텔레메트리 같은 일은 대부분 **사용자 공간이 admin 명령을 직접 조립해 커널에 "통과"시키는** 구조로 되어 있다. 커널이 제공하는 것은 세 가지다.

1. **얇은 운반 수단**: `NVME_IOCTL_ADMIN_CMD`/`NVME_IOCTL_ADMIN64_CMD`, `NVME_URING_CMD_ADMIN`
2. **부작용 관리**: Commands Supported and Effects 로그 기반의 큐 freeze와 재스캔
3. **권한 검사**: `nvme_cmd_allowed()`

명령 사전, 출력 형식, 벤더 확장, 패브릭 연결 정책은 `linux-nvme` 조직의 nvme-cli와 libnvme가 맡는다.

2026년 현재 이 생태계에는 세 가지 큰 변화가 있었다.

- **nvme-cli 3.0(2026-09-07)과 저장소 통합.** libnvme 소스를 nvme-cli 저장소로 가져왔다("lib: import libnvme sources" 머지). 라이브러리 이름은 `libnvme3`(SONAME `libnvme3.so.1`)로 바뀌었고, 따로 있던 **libnvme-mi도 합쳐졌다.** 명령 체계도 플러그인 중심으로 재편됐다. 예컨대 `nvme smart-log` → `nvme log smart`, `nvme id-ctrl` → `nvme id ctrl`, `nvme create-ns` → `nvme ns create`, `nvme fw-download` → `nvme fw download`가 되었다. 옛 이름은 deprecated alias로 남았다.
- **패브릭 연결 관리를 상태 기반 데몬으로 옮기는 중.** nvme-cli 3.2(미출시) NEWS에 따르면, 기본 빌드에서 `nvme-discoverd`가 레거시 udev/systemd autoconnect(`70-nvmf-autoconnect.rules`, `nvmf-connect@.service`)를 대체한다. TP8009 mDNS와 TP8010 CDC를 맡아 온 nvme-stas는 libnvme의 ownership registry로 다른 주체와 연결 소유권을 나눈다.
- **권한 모델이 두 번 바뀌었다.**
  - **6.2**: `CAP_SYS_ADMIN` 일변도에서 "명령 효과 기반 비특권 허용"으로 바뀌었다(Kanchan Joshi, Christoph Hellwig, Joel Granados 커밋).
  - **7.3-rc1**: root라도 드라이버가 관리하는 Set Features(KATO(비패브릭), Host Behavior, HMB, Number of Queues, APST)는 패스스루로 바꿀 수 없게 됐다("nvme: reject passthrough of driver-managed Set Features", 2026-07).

이 흐름의 결론은 다음과 같다. 관리 평면은 여전히 "root가 아무 명령이나 보내는" 모델에서 출발했다. 그러나 커널은 **(a) 데이터 경로에 필요한 최소한의 비특권 접근**과 **(b) 드라이버 상태를 깨뜨리는 특권 명령 차단**이라는 양방향으로 경계를 좁혀 가고 있다.

---

## 2. Problem Statement

### 2.1 블록 계층이 표현하지 못하는 관리 기능
`ioctl(BLKGETSIZE64)`이나 sysfs만으로는 NVMe 장치 운영에 필요한 정보와 조작을 다룰 수 없다.
- **Identify**: CNS별로 수십 종이 있다(컨트롤러, namespace, 명령 세트별 구조, 활성/할당 namespace 목록, 컨트롤러 목록, NVM Set, 엔듀런스 그룹 등).
- **Get Log Page**: SMART/Health, Error, Firmware Slot, Commands Supported and Effects, Telemetry Host/Controller-Initiated, Sanitize Status, Persistent Event, ANA, FDP 등이 있다.
- **Get/Set Features**: 전원 상태, 온도 임계값, 인터럽트 병합, 비휘발 쓰기 캐시, Host Behavior, KATO 등이 있다.
- **변경 명령**: Namespace Management/Attachment, Firmware Image Download/Commit, Format NVM, Sanitize, Device Self-test, Security Send/Receive, Directive 등이 있다.

규격은 2.x 이후 빠르게 늘어나고 있다(NVMe Base 2.4의 필드명 재정의가 libnvme API 이름을 대거 바꿨다는 NEWS 항목이 그 증거다). 커널에 명령마다 전용 ioctl을 만드는 것은 불가능하다. 그래서 커널은 "64바이트 SQE와 데이터 버퍼를 그대로 넘기는" 범용 패스스루 하나만 제공한다.

### 2.2 그 대가: 부작용과 권한
범용 패스스루는 커널이 모르는 사이에 장치 상태를 바꿀 수 있다.
- Format NVM이나 Sanitize는 모든 데이터를 바꾼다. 블록 계층 캐시와 진행 중인 I/O가 무효가 된다.
- Namespace Management는 namespace를 생성하거나 삭제한다. 커널의 `nvme_ns` 목록과 장치가 어긋난다.
- Set Features(Number of Queues, HMB, KATO)는 드라이버가 직접 관리하는 상태를 뒤에서 바꾼다.
- 벤더 고유 opcode는 효과를 알 수 없다.

과제는 이 명령들을 **안전하게 직렬화**하는 것, 그리고 **누구에게 허용할지** 정하는 것이었다.

### 2.3 패브릭 시대의 관리 문제
NVMe-oF에서는 장치가 PCIe 열거로 "나타나지" 않는다. 호스트가 직접 찾아서 연결해야 한다.
- **호스트 정체성**: Host NQN과 Host ID를 정해야 한다. 타깃은 이 값으로 접근 제어를 한다.
- **디스커버리**: Discovery Controller에 접속해 Discovery Log Page를 읽고, 각 서브시스템에 connect해야 한다.
- **변화 추적**: Discovery Log 변경 AEN, FC 이벤트, mDNS 광고, CDC의 zoning 변경에 반응해야 한다.
- **부팅**: NBFT(NVMe Boot Firmware Table)로 펌웨어가 연결한 경로를 OS로 넘겨받아야 한다.

nvme-stas README는 이 지점을 짚는다. "nvme-cli is stateless". TP8009/TP8010은 "inherently long-running, event-driven behaviors"를 요구하므로 단발성 CLI로는 구현할 수 없다는 것이다.

### 2.4 대역 외 관리 (NVMe-MI)
BMC가 호스트 OS 없이 SMBus/I2C 위의 MCTP로 드라이브를 관리하는 경로(NVMe Management Interface)도 있다. 이 경로는 커널 NVMe 드라이버를 거치지 않는다. 그래서 같은 명령 사전을 공유하면서 운반 수단만 다른 라이브러리가 필요했다. 이것이 libnvme-mi(현재는 libnvme3에 통합)의 존재 이유다.

---

## 3. The Debate

### 3.1 "파일 권한은 무시되고 있었다": 6.2의 세분화된 권한
5.13에서 namespace별 범용 문자 디바이스 `/dev/ngXnY`가 생겼다. 그런데 커널은 이 파일의 접근 권한을 보지 않고 모든 패스스루에 `CAP_SYS_ADMIN`을 요구했다. Kanchan Joshi의 커밋 "nvme: fine-granular CAP_SYS_ADMIN for nvme io commands"(2022-10-31)는 문제를 이렇게 보여 준다.

> "Currently both io and admin commands are kept under a coarse-granular CAP_SYS_ADMIN check, disregarding file mode completely. … In the example above, ng0n1 appears as if it may allow unprivileged read/write operation but it does not and behaves same as ng0n2."
>
> — Kanchan Joshi, 2022-10-31 (https://github.com/torvalds/linux/commit/855b7717f44b)

그가 제안한 규칙은 이렇다.
- `CAP_SYS_ADMIN`이 있으면 그대로 통과한다.
- 없으면 admin 명령은 전부 거부한다.
- vendor-specific과 fabrics 명령도 거부한다.
- 쓰기 I/O는 `FMODE_WRITE`로 연 경우만 허용하고, 읽기 I/O는 허용한다.

리뷰 과정에서 두 가지 보완이 붙었다.
1. **CSE 로그 확인** (Christoph Hellwig, 2022-12-13): Write Zeroes처럼 데이터 전송 없이 내용을 바꾸는 명령이 있다. 그래서 비특권 명령은 Commands Supported and Effects 로그에 "지원됨"(`NVME_CMD_EFFECTS_CSUPP`)으로 표시되어야 하고, 데이터·메타데이터를 바꾸는 효과가 없어야 한다. 커밋은 실용적 근거도 덧붙였다. "While the Commands Support and Effects log page has only been mandatory since NVMe 2.0, it is widely supported because Windows requires it for any command passthrough from userspace."
2. **Identify Controller 허용** (Joel Granados, 2022-12-05): 사용자 공간이 올바른 I/O를 만들려면 MDTS, WZSL 같은 값이 필요하다. 그래서 명령 세트 독립/의존 Identify Controller를 비특권으로 허용했다. 결과적으로 비특권 admin 명령은 Identify의 CNS 5종(`NVME_ID_CNS_NS`, `NVME_ID_CNS_CS_NS`, `NVME_ID_CNS_NS_CS_INDEP`, `NVME_ID_CNS_CS_CTRL`, `NVME_ID_CNS_CTRL`)뿐이다.

이 설계의 철학은 **"데이터 평면에 필요한 만큼만"**이다. SMART 로그, 펌웨어, namespace 관리 같은 관리 평면 명령은 여전히 `CAP_SYS_ADMIN` 전용이다. 즉 `nvme smart-log`(3.0의 `nvme log smart`)는 장치 파일 권한을 풀어도 root가 아니면 실패한다.

### 3.2 관리 ioctl도 같은 잣대로 (6.1)
패스스루와 달리 `NVME_IOCTL_RESET`, `NVME_IOCTL_SUBSYS_RESET`, `NVME_IOCTL_RESCAN`은 한동안 권한 검사가 없었다. Keith Busch의 "nvme: restrict management ioctls to admin"(2022-09-22, 6.1)은 근거를 이렇게 쓴다. "these operations, which include resets and rescans, can be disruptive." 7.3-rc7의 `nvme_dev_ioctl()`에서도 세 ioctl 모두 `!capable(CAP_SYS_ADMIN)`이면 `-EACCES`를 반환한다.

### 3.3 root도 막는다: 드라이버가 관리하는 Set Features (7.3-rc1)
6.2의 `nvme_cmd_allowed()`는 맨 앞에서 `capable(CAP_SYS_ADMIN)`이면 무조건 `true`를 반환했다. 2026-07의 "nvme: reject passthrough of driver-managed Set Features"(Chao Shi)는 이 전제를 깼다. 계기는 구체적이다. KATO 변경 시 keep-alive 주기를 갱신하는 기존 커밋(`b58da2d270db`) 때문에, PCIe에서 Set Features(KATO) 패스스루 한 번으로 keep-alive가 시작될 수 있었다. 그런데 비패브릭 전송은 admin 태그를 예약하지 않으므로 `blk_mq_get_tag()`의 `WARN_ON_ONCE()`가 터졌다("keep-alive failed: -11"). 커밋 메시지는 일반 원칙을 이렇게 정리한다.

> "Several Set Features change controller state the driver manages itself and cannot react to when set behind its back."
>
> — "nvme: reject passthrough of driver-managed Set Features", 2026-07 (https://github.com/torvalds/linux/commit/1161be71d1ec)

현재 `nvme_admin_cmd_allowed()`는 KATO(비패브릭), `NVME_FEAT_HOST_BEHAVIOR`, `NVME_FEAT_HOST_MEM_BUF`, `NVME_FEAT_NUM_QUEUES`, `NVME_FEAT_AUTO_PST`에 대해 `capable()`을 확인하기 **전에** `false`를 반환한다. 태그별 grep으로 보면 `NVME_FEAT_HOST_MEM_BUF` 문자열은 v7.2 `ioctl.c`에 없고 v7.3-rc1에 있다. 운영 측면의 함의는 이렇다. `nvme set-feature -f 0x0c`(APST) 같은 튜닝 스크립트는 7.3부터 실패한다. 대신 모듈 파라미터(`nvme_core.default_ps_max_latency_us` 등)를 써야 한다 [추측/미확인: 대체 수단별 동작은 개별 확인 필요].

### 3.4 라이브러리 분리와 재통합: libnvme 1.x → libnvme3
nvme-cli 3.0 릴리스 노트(Daniel Wagner, 2026-09-07)는 프로젝트 역사를 이렇게 정리한다.
1. 2020년 1.10 직후 Keith Busch가 nvme-cli 1.x를 CLI와 라이브러리로 쪼개기 시작했다(libnvme).
2. Hannes Reinecke가 Python 바인딩을 만들었고, 이것이 nvme-stas의 기반이 됐다.
3. nvme-cli 2.0은 2022-04-08에 나왔다.

노트는 한계도 인정한다. "if a library is cut out of an existing project it usually ends up with some rather unusual APIs"였다. 그래서 3.x는 처음에 API 정리만 하는 릴리스로 계획됐다. 그러나 ALPSS 2025에서 Christoph Hellwig가 "take the time and do it properly"를 권했고, LSF/MM 2026에서도 다시 "get this done properly"를 권해 범위가 커졌다. 결과는 다음과 같다.
- **구조**: libnvme 소스를 nvme-cli 저장소로 들여왔다. libnvme-mi를 통합했다. 공개 심볼 접두사를 `libnvme_`/`libnvmf_`로 정리했다. Windows 포팅을 마쳤고 FreeBSD 포팅을 준비 중이다.
- **규모**: 노트는 v2.16 이후 메인라인 1,711커밋(58명), 테스트는 약 47개에서 140개 이상, 커버리지는 약 2%에서 24%로 늘었다고 적는다. 그중 AI 보조 커밋이 최소 168개라고 스스로 집계했다.

`github.com/linux-nvme/libnvme` 저장소도 아카이브되지 않고 1.x 유지보수(v1.16.2, 2026-06-16)를 계속한다. 그래서 배포판은 `libnvme`(1.x)와 `libnvme3`를 병렬 설치할 수 있다(NEWS: "enabling parallel installation alongside libnvme v1 packages").

### 3.5 stateless CLI vs 상태를 가진 데몬
패브릭 연결 관리는 오랫동안 nvme-cli와 udev/systemd 조합으로 처리됐다. 커널이 Discovery Log 변경 AEN을 uevent로 올리면(`NVME_AEN=="0x70f002"`) `70-nvmf-autoconnect.rules`가 `nvmf-connect@….service`를 재시작해 `nvme connect-all`을 돌리는 방식이다. 이 구조에는 재시도, 백오프, 연결 소유권, mDNS 감시가 없다. 그래서 libnvme Python 바인딩 위에 **nvme-stas**가 별도 프로젝트로 만들어졌다.
- `stafd`: Avahi `_nvme-disc._tcp` 감시, CDC/DDC 연결
- `stacd`: D-Bus로 목록을 받아 I/O 컨트롤러 연결

2026년의 변화는 이 기능을 C 라이브러리와 공식 데몬으로 흡수하는 것이다. 릴리스 노트는 "Martin Belanger started bringing major features from the nvme-stas project into libnvme"라고 적는다. 3.2 NEWS는 `nvme-discoverd`가 NBFT, `nvme-fabrics.conf`, Discovery Log, FC kickstart를 모두 처리하고 "keeps them connected and retries failed connections with backoff"한다고 설명한다. mDNS(TP8009)는 systemd-resolved 기반으로 넣되 기본은 off다. 여러 주체가 공존하는 문제는 **ownership registry**(`/run/nvme/registry/`)로 푼다. nvme-stas README가 말하듯 "Neither daemon disconnects a connection it did not make". 기본 동작 변경도 하나 있다. `nvme discover`/`connect-all`의 `--persistent` 기본값이 `no`에서 `auto`로 바뀌었다. EPCSD를 표시한 Discovery Controller와는 연결을 유지해 AEN을 받는다.

---

## 4. Implementation Impact

### 4.1 커널 uAPI (Linux 7.3-rc7 `include/uapi/linux/nvme_ioctl.h`)
| ioctl / uring_cmd | 번호 | 인자 | 대상 장치 | 용도 |
|---|---|---|---|---|
| `NVME_IOCTL_ID` | `_IO('N',0x40)` | - | ns 블록/문자 | NSID 조회 |
| `NVME_IOCTL_ADMIN_CMD` | `_IOWR('N',0x41)` | `struct nvme_admin_cmd`(= `nvme_passthru_cmd`, 32비트 result) | `/dev/nvmeX`, ns 장치 | admin 패스스루 |
| `NVME_IOCTL_SUBMIT_IO` | `_IOW('N',0x42)` | `struct nvme_user_io` | ns | 레거시 read/write |
| `NVME_IOCTL_IO_CMD` | `_IOWR('N',0x43)` | `struct nvme_passthru_cmd` | ns, `/dev/nvmeX`(단일 ns일 때만) | I/O 패스스루 |
| `NVME_IOCTL_RESET` / `SUBSYS_RESET` / `RESCAN` | 0x44 / 0x45 / 0x46 | - | `/dev/nvmeX` | 컨트롤러 리셋, NSSR, ns 재스캔 (`CAP_SYS_ADMIN`) |
| `NVME_IOCTL_ADMIN64_CMD` | 0x47 | `struct nvme_passthru_cmd64`(64비트 result) | 위와 같음 | admin 패스스루 |
| `NVME_IOCTL_IO64_CMD` / `_VEC` | 0x48 / 0x49 | `nvme_passthru_cmd64` | ns | I/O 패스스루 (벡터) |
| `NVME_URING_CMD_ADMIN` / `_VEC` | `_IOWR('N',0x82/0x83)` | `struct nvme_uring_cmd` | `/dev/nvmeX`, `/dev/ngXnY` | io_uring 비동기 admin |

`/dev/nvmeX`(컨트롤러 문자 장치)의 `nvme_dev_ioctl()`은 `file->f_mode & FMODE_WRITE`를 `open_for_write`로 넘긴다. ADMIN/ADMIN64는 `nvme_user_cmd()`/`nvme_user_cmd64()`(ns=NULL)로, IO_CMD는 `nvme_dev_user_cmd()`로 간다. 이 경로는 컨트롤러 `admin_q`(admin 태그셋)로 `struct request`를 할당해 `nvme_passthru_start()` → `nvme_execute_rq()`(내부 `blk_execute_rq()`) → `nvme_passthru_end()` 순서로 동기 실행한다. 단 `/dev/nvmeX`에 대한 `NVME_IOCTL_IO_CMD`는 namespace가 둘 이상이면 "NVME_IOCTL_IO_CMD not supported when multiple namespaces present!" 경고와 함께 `-EINVAL`을 반환한다. admin 명령 타임아웃 기본값은 모듈 파라미터 `admin_timeout`(기본 60초)이다. 사용자 구조체의 `timeout_ms`로 명령별 재정의도 가능하다.

### 4.2 부작용 처리: Commands Supported and Effects
패스스루 실행 전후로 `nvme_passthru_start()`/`nvme_passthru_end()`가 효과 비트를 본다.
```
effects = nvme_command_effects(ctrl, ns, opcode)   // CSE 로그 + 드라이버가 아는 기본 효과
nvme_passthru_start():
  if (effects & NVME_CMD_EFFECTS_CSE_MASK)          // "다른 명령과 동시 실행 금지"
      scan_lock, subsys->lock 획득
      nvme_mpath_start_freeze/wait_freeze(subsys); nvme_start_freeze/wait_freeze(ctrl)
<명령 실행>
nvme_passthru_end():
  CSE_MASK → unfreeze, 락 해제
  NVME_CMD_EFFECTS_CCC → NVME_CTRL_DIRTY_CAPABILITY 설정
                         ("controller capabilities changed, reset may be required")
  NVME_CMD_EFFECTS_NIC | NCC → nvme_queue_scan(); flush_work(&ctrl->scan_work)
  admin Set Features(KATO) 성공 → nvme_update_keep_alive()
```

`nvme_init_known_nvm_effects()`는 장치 로그와 상관없이 드라이버가 아는 효과를 강제로 덧씌운다.
- Format NVM: `LBCC|NCC|CSE_MASK`
- Sanitize: `LBCC|CSE_MASK`
- NVM Write: `LBCC`
- Security Receive: `CSE_MASK`를 **지운다.** 주석은 이유를 이렇게 설명한다. 장치들이 이 명령을 "다른 명령과 섞지 말 것"으로 표시하지만, admin 큐끼리의 배타는 드라이버가 강제할 수 없다. 그러니 I/O 큐를 얼려 봐야 의미가 없다는 것이다.

이 비트들은 운영 결과에 직접 영향을 준다. `nvme format`이나 `nvme ns create/delete`를 실행하면 해당 서브시스템의 **모든 namespace I/O가 잠시 얼었다가** 재스캔이 끝난 뒤 풀린다. 멀티패스 head 단위 freeze도 포함된다. 운영 중인 시스템에서 namespace 관리를 할 때 지연 스파이크가 생기는 이유다.

### 4.3 권한 판정 콜패스 (7.3-rc7)
```
nvme_cmd_allowed(ctrl, ns, c, flags, open_for_write)
  ├─ flags & NVME_IOCTL_PARTITION          → capable(CAP_SYS_ADMIN)   // 파티션 탈출 방지
  ├─ opcode >= nvme_cmd_vendor_start || opcode == nvme_fabrics_command
  │                                          → capable(CAP_SYS_ADMIN)
  ├─ ns == NULL → nvme_admin_cmd_allowed(ctrl, c)
  │     ├─ Identify CNS ∈ {NS, CS_NS, NS_CS_INDEP, CS_CTRL, CTRL} → true (비특권 허용)
  │     ├─ Set Features FID ∈ {KATO(비패브릭), HOST_BEHAVIOR, HOST_MEM_BUF,
  │     │                       NUM_QUEUES, AUTO_PST}          → false (root 포함 거부)
  │     └─ 그 외                                               → capable(CAP_SYS_ADMIN)
  └─ ns != NULL → nvme_ns_cmd_allowed(ns, c, open_for_write)
        ├─ !(effects & CSUPP)                                  → capable(CAP_SYS_ADMIN)
        ├─ effects & ~(CSUPP|LBCC|UUID_SEL|SCOPE_MASK) 존재     → capable(CAP_SYS_ADMIN)
        ├─ (쓰기 명령 || LBCC) && !open_for_write               → capable(CAP_SYS_ADMIN)
        └─ true
```

| 버전 | 규칙 | 근거 커밋 |
|---|---|---|
| ~6.0 | 모든 패스스루 `CAP_SYS_ADMIN`. reset/rescan ioctl은 무검사 | - |
| 6.1 | `NVME_IOCTL_RESET`/`SUBSYS_RESET`/`RESCAN`에 `CAP_SYS_ADMIN` | 23e085b2dead (Keith Busch) |
| 6.2 | `nvme_cmd_allowed()` 도입. 비특권 I/O(파일 모드 기반), Identify 5종, CSE 로그 확인 | 855b7717f44b, ea43fceea417, 6f99ac04c469 |
| 7.3-rc1 | 드라이버 관리 Set Features는 root도 거부. `capable()` 검사가 규칙 뒤로 이동 | 1161be71d1ec (Chao Shi) |

같은 시기(2026-07)의 "nvme/ioctl: check SUBMIT_IO with nvme_cmd_allowed()"(Yang Xiuwei)는 레거시 `NVME_IOCTL_SUBMIT_IO`도 같은 판정기를 거치게 했다. 경계의 빈틈을 메우는 작업이 계속되고 있다는 뜻이다.

### 4.4 libnvme3 구조 (nvme-cli master `libnvme/src/nvme/`)
- **전송 추상화**: 모든 명령은 `struct libnvme_transport_handle`을 통해 나간다. 플랫폼별 구현 파일은 `ioctl-linux.c`, `ioctl-freebsd.c`, `ioctl-win.c`, `ioctl-loopback.c`, io_uring용 `uring.c`(미지원 시 `no-uring.c`), MI용 `mi.c`/`mi-mctp.c`다.
  - 리눅스 구현(`ioctl_admin_passthru()`)은 컨텍스트의 `ioctl_probing`이 켜져 있으면 `LIBNVME_IOCTL_ADMIN64_CMD`를 시도한다. `-ENOTTY`가 돌아오면 핸들 상태를 `IOCTL_STATE_IOCTL32`로 기억하고 `LIBNVME_IOCTL_ADMIN_CMD`(32비트 result)로 폴백한다. probing이 꺼져 있으면 처음부터 32비트 ioctl을 쓴다. 리셋·재스캔은 `LIBNVME_IOCTL_RESET`/`SUBSYS_RESET`/`RESCAN`, NSID 조회는 `LIBNVME_IOCTL_ID`를 쓴다.
  - io_uring 경로는 `io_uring_opcode_supported(probe, IORING_OP_URING_CMD)`로 지원 여부를 확인한다. 이후 `IORING_SETUP_SQE128 | IORING_SETUP_CQE32` 링(엔트리 16개, `NVME_URING_ENTRIES`)을 만든다.
- **명령 빌더 + 실행기 분리**: `nvme-cmds-base.h`의 `nvme_init_*()` 인라인 함수들이 `struct libnvme_passthru_cmd`를 채운다. 예를 들면 다음과 같다.
  - Identify: `nvme_init_identify_ctrl()`, `nvme_init_identify_ns()`, `nvme_init_identify_csi_ns()`, `nvme_init_identify_ctrl_list()`
  - Log Page: `nvme_init_get_log_smart()`, `nvme_init_get_log_telemetry_host()`, `nvme_init_get_log_fw_slot()`, `nvme_init_get_log_sanitize()`, `nvme_init_get_log_fdp_stats()`
  - 변경 명령: `nvme_init_ns_mgmt_create()`, `nvme_init_ns_attach_ctrls()`, `nvme_init_fw_download()`, `nvme_init_fw_commit()`, `nvme_init_sanitize_nvm()`, `nvme_init_format_nvm()`

  채운 명령은 `libnvme_exec_admin_passthru()`(동기)로 보낸다. 비동기 쌍은 `libnvme_submit_admin_passthru()`와 `libnvme_wait_passthru()`/`libnvme_reap_passthru()`다. 큰 로그 페이지는 `libnvme_get_log()`가 전송 크기(`NVME_LOG_PAGE_PDU_SIZE`) 단위로 오프셋(LPO)을 올려 가며 나눠 읽는다. 장치의 MDTS나 패브릭 PDU 한도 때문이다.
- **토폴로지 트리**: `libnvme_scan_topology()`가 sysfs(`/sys/class/nvme*`)를 읽어 `libnvme_global_ctx` → host → subsystem → ctrl → ns(및 path) 트리를 만든다. 순회는 `libnvme_first_host()`, `libnvme_first_subsystem()`, `libnvme_subsystem_first_ctrl()`, `libnvme_ctrl_first_ns()`로 한다. 3.0에서는 경로·namespace·컨트롤러별 재시도/오류 수, failover 수, reset/reconnect 수 접근자가 추가됐다. 이 값은 항상 live로 읽으며 `nvme top`의 기반이 된다.
- **Python 바인딩**: 패키지명은 `libnvme3`(PyPI)다. nvme-stas가 이 바인딩의 대표 사용자다.

### 4.5 주요 관리 작업과 실제 명령 (nvme-cli 3.x 이름, 괄호는 2.x alias)
| 작업 | nvme-cli | NVMe 명령 | 커널 측 처리 |
|---|---|---|---|
| 장치 목록 | `nvme list`, `nvme list-subsys` | (sysfs 스캔 + Identify) | - |
| 식별 | `nvme id ctrl` (`id-ctrl`), `nvme id ns` | Identify (CNS별) | 일부 CNS는 비특권 허용 |
| 상태 | `nvme log smart` (`smart-log`), `log error`, `log effects` | Get Log Page | root 필요 |
| 텔레메트리 | `nvme log telemetry -O file [-g 1] [-d 1..4]` (`telemetry-log`) | Get Log Page (Telemetry Host-Initiated, LSP로 생성 요청) | 큰 로그 → 분할 전송 |
| ns 생성/부착 | `nvme ns create` → `nvme ns attach` (`create-ns`/`attach-ns`) | Namespace Management / Attachment | `NIC`/`NCC` 효과 → 재스캔, `CSE` → freeze |
| 펌웨어 | `nvme fw download` → `nvme fw commit -s <slot> -a <0..3,6,7>` | Firmware Image Download / Commit | Firmware Activation 알림 시 `nvme_fw_act_work()`가 `nvme_ctrl_pp_status()`(CSTS.PP)를 MTFA×100ms(없으면 `admin_timeout`)까지 폴링 |
| 포맷 | `nvme format` | Format NVM | 드라이버 기본 효과 `LBCC|NCC|CSE_MASK` |
| sanitize | `nvme sanitize -a {start-block-erase, start-overwrite, start-crypto-erase, exit-failure, exit-media-verification}`, `nvme log sanitize` | Sanitize (+ Sanitize Status 로그) | 기본 효과 `LBCC|CSE_MASK` |
| 자가 진단 | `nvme device-self-test`, `nvme log self-test` | Device Self-test | - |
| 기능 | `nvme get-feature`, `nvme set-feature` | Get/Set Features | 7.3+: 드라이버 관리 FID 거부 |
| 범용 | `nvme admin-passthru`, `nvme io-passthru` | 임의 opcode | `nvme_cmd_allowed()` |
| 대역 내 MI | `nvme nvme-mi recv`, `nvme nvme-mi send` (nvme-mi 플러그인) | NVMe-MI Receive/Send admin 명령 | 일반 admin 패스스루 |

펌웨어 commit action의 의미는 `nvme-fw-commit(1)`에 정의되어 있다. 0 `replace`, 1 `replace-and-activate`(다음 리셋), 2 `set-active`, 3 `replace-and-activate-immediate`(리셋 없이 즉시), 6/7은 boot partition 관련이다. 3번은 장치가 Firmware Activation Without Reset을 지원해야 한다. 이때 커널은 리셋 없이 컨트롤러가 처리 일시 중지(`CSTS.PP`)에서 돌아오기를 기다린다.

### 4.6 플러그인 구조
nvme-cli 플러그인은 `plugins/<name>/`에 있다. 각 플러그인은 `struct plugin`과 `struct command` 배열을 정적 생성자(`__shr_constructor register_plugin()`)로 등록한다. master 기준 디렉터리는 두 부류다.
- **표준 기능**: `id`, `log`, `ns`, `fw`, `feat`, `dir`, `security`, `resv`, `rpmb`, `sed`, `zns`, `fdp`, `io-mgmt`, `lm`(Live Migration), `nbft`, `keys`, `config`, `registry`, `exclusion`, `nvme-mi`
- **벤더 플러그인**: `amzn`, `dell`, `huawei`, `ibm`, `intel`, `micron`, `netapp`, `nvidia`, `ocp`, `samsung`, `sandisk`, `scaleflux`, `seagate`, `solidigm`, `toshiba`, `wdc`, `ymtc` 등

3.0의 큰 방향은 **표준 명령을 플러그인 네임스페이스로 옮긴 것**이다(`nvme log *`, `nvme id *`, `nvme ns *`, `nvme fw *`, `nvme keys *`). 벤더 플러그인은 대부분 벤더 고유 로그와 opcode를 다룬다. 이들은 6.2 규칙상 vendor-specific opcode이므로 **항상 `CAP_SYS_ADMIN`이 필요**하다. 3.2 NEWS는 ScaleFlux 플러그인에서 독점 커널 드라이버 지원을 뺐다고 적는다. 이유는 "nvme-cli does not support proprietary kernel modules"다.

### 4.7 대역 외 관리: NVMe-MI
libnvme3의 `mi.h`는 스스로를 "NVMe Management Interface library (libnvme-mi)"라고 소개한다. 대상은 "typically over an MCTP-over-i2c link to a NVMe device, used as part of the out-of-band management of a system"이다. 객체 구조는 다음과 같다.
- **엔드포인트**: `struct libnvme_mi_ep`. MCTP EID를 가진 주체다. `libnvme_mi_open_mctp(ctx, netid, eid)`로 열고, `libnvme_mi_scan_mctp()`로 시스템의 MCTP 엔드포인트를 찾는다.
- **컨트롤러 핸들**: `libnvme_mi_init_transport_handle()`로 얻는다. 같은 `nvme_init_*()` 빌더로 만든 admin 명령을 MI 메시지에 감싸 `libnvme_mi_admin_xfer()`로 보낸다.
- **비동기 이벤트(AEM)**: `libnvme_mi_aem_open/enable/process/ack` 계열이 담당한다.

이 경로는 리눅스 MCTP 소켓 스택(`AF_MCTP`)을 쓰므로 **커널 NVMe 드라이버와 무관하다.** 그래서 6.2/7.3의 `nvme_cmd_allowed()` 규칙이 적용되지 않는다. BMC 측 접근 통제는 MCTP 네트워크 구성과 소켓 권한의 몫이다 [추측/미확인: MCTP 소켓 권한 세부]. 반대로 nvme-cli의 `nvme-mi` 플러그인은 호스트에서 **대역 내**로 NVMe-MI Send/Receive admin 명령을 보낸다. 따라서 일반 admin 패스스루로서 root가 필요하다.

### 4.8 패브릭: 호스트 정체성, 디스커버리, 자동 연결
**커널 인터페이스.** 연결은 `/dev/nvme-fabrics` misc 장치(`nvmf_misc`)에 `transport=tcp,traddr=…,nqn=…,hostnqn=…,hostid=…` 같은 옵션 문자열을 `write()`해서 만든다(`nvmf_dev_write()`). libnvme는 이 장치에서 커널이 받는 옵션 목록을 한 번 읽어 캐시한다. 호스트 NQN/ID를 주지 않으면 커널 `nvmf_host_default()`가 `uuid_gen()`으로 `nqn.2014-08.org.nvmexpress:uuid:<무작위>`를 만든다. 같은 hostnqn에 다른 hostid(또는 그 반대)를 쓰면 `nvmf_host_add()`가 "found same hostnqn %s but different hostid" 오류로 거부한다.

**호스트 정체성 파일.** libnvme는 `SYSCONFDIR "/nvme/hostnqn"`과 `"/nvme/hostid"`(보통 `/etc/nvme/`)를 읽는다. `nvme gen-hostnqn`은 UUID를 다음 순서로 고른다.
1. DMI `product_uuid`
2. 디바이스 트리 `ibm,partition-uuid`
3. `/etc/machine-id`에서 HMAC-SHA256으로 파생한 값. machine-id 자체는 노출하지 않으며, systemd `sd_id128_get_machine_app_specific(3)`과 같은 방식이다.
4. 무작위 UUID (경고 출력)

3.1부터 DMI 파일이 root 전용이라는 이유로 `nvme gen-hostnqn`은 root로 실행해야 한다. 3.0에서는 fabrics connect/discover 내부의 암묵적 hostnqn 조회가 제거됐다. 호출자가 `libnvmf_host_get_ids()`로 먼저 결정해야 한다. 타깃 ACL이 hostnqn에 묶이는 만큼, 호스트 재설치나 클론 시 정체성 충돌·변경이 접근 장애의 흔한 원인이다.

**디스커버리와 자동 연결의 세대 비교**
| 항목 | 레거시 autoconnect (nvme-cli 2.x 기본) | nvme-stas (stafd/stacd) | nvme-discoverd (nvme-cli 3.2 기본 예정) |
|---|---|---|---|
| 트리거 | udev: `NVME_AEN=="0x70f002"`(Discovery Log 변경), FC `nvmediscovery`, `NVME_EVENT=="rediscover"` | 상시 데몬 | 상시 데몬 (systemd) |
| 연결 실행 | `nvmf-connect@….service` → `nvme connect-all` | `stacd`가 libnvme Python 바인딩으로 | libnvme C API |
| 설정 | `/etc/nvme/discovery.conf`, `config.json` (3.0부터 `nvme-fabrics.conf` INI로 대체) | `stafd.conf`, `stacd.conf` | `nvme-fabrics.conf`, `nvme-discoverd.conf` |
| mDNS (TP8009) | 없음 | Avahi `_nvme-disc._tcp` (기본 off) | systemd-resolved (기본 off, libsystemd ≥ 258) |
| CDC / Fabric Zoning (TP8010) | 없음 | 지원 | Discovery Log·EPCSD 기반 persistent 연결 [추측/미확인: CDC 등록 기능 범위] |
| 재시도/백오프 | 없음 (단발 서비스) | 있음 | 있음 |
| 소유권 | 없음 | ownership registry 존중 | ownership registry (`/run/nvme/registry/`) |
| 부팅(NBFT) | `nvmf-connect-nbft.service`, dracut | - | NBFT 직접 처리 |

**제외 목록.** 3.0의 `nvme exclusion`(`/etc/nvme/exclusions.conf`)은 자동 발견된 컨트롤러 중 연결하지 않을 대상을 관리자가 막는 장치다. 설정 항목이 없는 auto-discovered 연결을 억제할 다른 방법이 없었기 때문이다.

### 4.9 연표
| 시점 | 사건 |
|---|---|
| 2020 | nvme-cli 1.10 이후 Keith Busch가 libnvme 분리 시작 |
| 5.13 | `/dev/ngXnY` 범용 문자 장치 |
| 5.19 | `NVME_URING_CMD_IO`/`ADMIN` (io_uring 패스스루) |
| 2022-04-08 | nvme-cli 2.0 (libnvme 1.x 기반) |
| 6.1 | reset/subsys-reset/rescan ioctl에 `CAP_SYS_ADMIN` |
| 6.2 | `nvme_cmd_allowed()`: 비특권 I/O 패스스루, Identify 5종, CSE 로그 확인 |
| 2026-06-16 | libnvme v1.16.2 (1.x 유지보수 계속) |
| 2026-09-07 | nvme-cli 3.0: libnvme 소스 통합, `libnvme3`(SONAME `libnvme3.so.1`), libnvme-mi 통합, 플러그인 재편, `nvme top`, ownership registry, exclusion list, INI 설정 |
| 2026-09-18 | nvme-cli 3.1 (`gen-hostnqn` root 필수, hostid machine-id 폴백) |
| 7.3-rc1 | 드라이버 관리 Set Features 패스스루 거부 (root 포함) |
| 3.2 (미출시) | `nvme-discoverd`가 레거시 autoconnect 대체, discover 계열 `--persistent=auto` 기본 |

---

## 5. Primary References

- [github.com/linux-nvme - nvme-cli](https://github.com/linux-nvme/nvme-cli) — nvme-cli 저장소(3.x부터 libnvme3 포함)
- [github.com/linux-nvme - nvme-cli Release v3.0](https://github.com/linux-nvme/nvme-cli/releases/tag/v3.0) — Daniel Wagner, 2026-09-07
- [github.com/linux-nvme - nvme-cli NEWS.md](https://github.com/linux-nvme/nvme-cli/blob/master/NEWS.md) — 3.0~3.2 변경 사항
- [github.com/linux-nvme - libnvme](https://github.com/linux-nvme/libnvme) — libnvme 1.x 유지보수 저장소
- [github.com/linux-nvme - nvme-stas](https://github.com/linux-nvme/nvme-stas) — TP8009/TP8010 디스커버리 데몬(stafd/stacd)
- [github.com/linux-nvme - nvme-cli libnvme/src/nvme/mi.h](https://github.com/linux-nvme/nvme-cli/blob/master/libnvme/src/nvme/mi.h) — libnvme3의 NVMe-MI API
- [github.com/linux-nvme - nvme-cli 70-nvmf-autoconnect.rules.in](https://github.com/linux-nvme/nvme-cli/blob/master/nvmf-autoconnect/udev-rules/70-nvmf-autoconnect.rules.in) — 레거시 autoconnect udev 규칙
- [github.com/torvalds/linux - drivers/nvme/host/ioctl.c](https://github.com/torvalds/linux/blob/master/drivers/nvme/host/ioctl.c) — `nvme_cmd_allowed()` 등 패스스루 권한 판정
- [github.com/torvalds/linux - include/uapi/linux/nvme_ioctl.h](https://github.com/torvalds/linux/blob/master/include/uapi/linux/nvme_ioctl.h) — NVMe ioctl·uring_cmd uAPI
- [github.com/torvalds/linux - drivers/nvme/host/fabrics.c](https://github.com/torvalds/linux/blob/master/drivers/nvme/host/fabrics.c) — `/dev/nvme-fabrics`, 호스트 NQN 처리
- [github.com/torvalds/linux - nvme: fine-granular CAP_SYS_ADMIN for nvme io commands](https://github.com/torvalds/linux/commit/855b7717f44b) — Kanchan Joshi, 2022-10-31 (6.2)
- [github.com/torvalds/linux - nvme: consult the CSE log page for unprivileged passthrough](https://github.com/torvalds/linux/commit/6f99ac04c469) — Christoph Hellwig, 2022-12-13 (6.2)
- [github.com/torvalds/linux - nvme: allow unprivileged passthrough of Identify Controller](https://github.com/torvalds/linux/commit/ea43fceea417) — Joel Granados, 2022-12-05 (6.2)
- [github.com/torvalds/linux - nvme: restrict management ioctls to admin](https://github.com/torvalds/linux/commit/23e085b2dead) — Keith Busch, 2022-09-22 (6.1)
- [github.com/torvalds/linux - nvme: reject passthrough of driver-managed Set Features](https://github.com/torvalds/linux/commit/1161be71d1ec) — Chao Shi, 2026-07-15 (7.3-rc1)
- [kernel.org - NVMe Subsystem](https://docs.kernel.org/nvme/index.html) — 커널 NVMe 문서 색인
- [nvmexpress.org - Specifications](https://nvmexpress.org/specifications/) — NVMe 규격 목록
