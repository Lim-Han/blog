# 통합 버전 연표 해설: 커널·스토리지 프로젝트 31개의 938개 이벤트로 본 I/O 스택의 시간축

> 범위: `artifacts/01`~`13`의 도메인 문서 44개에서 추출한 버전 이벤트를 하나의 표로 합친 `data/timeline/timeline.tsv`(938행, 31개 프로젝트)를 해설한다. 기준 버전은 Linux master 7.3-rc7(2026-10-14 기준점), SPDK v26.09, OpenZFS 2.4.4, Lustre 2.17.0, DAOS v2.8.0, RocksDB 11.12.0, liburing-2.15이다. 표 전체는 사이트의 "통합 버전 연표" 화면에서 프로젝트·종류·검색어로 거르고 정렬할 수 있다. 원본 데이터는 `data/timeline/timeline.tsv`에 있고, `tools/merge_timeline.py`가 두 추출본(`part1.tsv`, `part2.tsv`)에서 이 파일을 재현 가능하게 만든다. 각 사실 뒤의 `(→ NN/MM)`는 그 행의 `source_doc`, 즉 근거 도메인 문서다.

## 1. Verdict

연표를 한 축에 놓으면 세 가지 흐름이 드러난다.

1. **2013–2018: 블록 계층의 다중 큐화와 사용자 공간 경로의 등장.** blk-mq가 3.13(2014-01)에 병합되고(→ 02/01, 02/02), NVMe 드라이버가 3.19에서 blk-mq로 옮겨 갔다(→ 02/01). 같은 시기에 SPDK는 v1.0.0(2015-12-07)으로 공개되고(→ 07/01), DPDK는 17.02에서 `rte_flow`를 들였다(→ 04/04). 커널 쪽은 XDP(4.8, 2016-07-20), 네이티브 NVMe 멀티패스(4.15), AF_XDP(4.18), P2PDMA 코어(4.20)로 "우회하지 않고 빠르게"를 준비했다(→ 04/01, 03/01, 08/02).
2. **2019–2021: io_uring의 폭발적 확장.** 5.0에서 레거시 단일 큐 경로와 CFQ가 삭제된 직후(2019-03, → 02/01, 02/03), io_uring이 5.1(2019-05)에 병합됐다(→ 01/01). 5.1~5.13 사이에 opcode·setup 플래그·등록 자원이 매 릴리스 추가됐고, 5.12에서는 실행 모델이 kthread에서 io thread로 바뀌었다(→ 01/01, 01/02). 사용자 공간 프로젝트는 곧바로 따라왔다. SPDK v19.04 uring bdev(→ 07/02), Ceph Octopus의 `bluestore_ioring`(2019-12, → 06/03), RocksDB 6.7.0의 MultiGet io_uring(2020-01-21, → 10/03), QEMU 5.0의 `aio=io_uring`(→ 09/04)이 그 예다.
3. **2022–2026: 패스스루·제로카피·데이터 배치의 물결.** io_uring은 범용 링을 넘어 다른 서브시스템의 전송 계층이 됐다. `IORING_OP_URING_CMD`와 NVMe 패스스루(5.19, → 01/01, 03/02), ublk(6.0, 2022-07-13, → 09/05), FUSE-over-io_uring(6.14, 2025-01-29, → 11/03), zcrx(6.15, 2025-03-28, → 04/02, 08/03)가 같은 링을 재사용한다. 제로카피는 네트워크(`IORING_OP_SEND_ZC` 6.0, devmem TCP RX 6.12·TX 6.16), 블록(ublk 제로카피 6.15), 파일(FUSE 제로카피 7.3-rc)로 번졌다(→ 04/02, 08/03, 09/05, 11/03). 데이터 배치는 FDP TP4146 비준(2022-12-12)을 거쳐 6.16 block write streams(2025-05-06)로 커널 uAPI가 됐다(→ 09/02).

또 하나의 결론은 **"추가 → 제거·재설계"가 예외가 아니라 반복 패턴**이라는 점이다. NVMe streams는 4.13에 들어와 5.18에 제거됐고, 6.16 write streams로 다른 모양이 되어 돌아왔다(→ 09/02). 블록 hybrid polling은 4.10에 추가되어 6.4에 삭제됐다가, 6.13에 io_uring 쪽 `IORING_SETUP_HYBRID_IOPOLL`로 재등장했다(→ 02/01, 02/03, 01/01). `RWF_DONTCACHE`는 6.14 인터페이스 → 6.15 릴리스 직전 전역 비활성화 → 6.16 재활성화를 거쳤다(→ 11/02). epoll `ep->lock`은 5.1에 rwlock으로 바뀌었다가 6.18에 spinlock으로 복귀했다(→ 04/03). 연표에서 `removed`·`renamed`가 61행인 것은 이 생태계가 인터페이스를 고정하기보다 계속 고쳐 쓴다는 뜻이다.

사용자 공간 프로젝트의 릴리스는 커널 기능을 **수개월~수년의 지연을 두고, 대개 기본값 off로** 따라간다. Ceph `bdev_ioring` 기본 `false`(→ 06/03), RocksDB io_uring 기본 비활성(→ 10/03), FUSE `enable_uring` 기본 false와 libfuse `-o io_uring` 기본 off(→ 11/03)가 모두 그렇다. 반대로 커널이 외부 프로젝트를 깨는 사례도 연표에 남아 있다. 5.0의 FPU export 제거가 ZFS SIMD 체크섬 빌드를 막았고(→ 10/02), 4.18에서 staging Lustre가 삭제됐다(→ 10/04).

## 2. Problem Statement

### 2.1 왜 하나의 연표가 필요한가

도메인 문서 44개는 각자 자기 범위의 연표를 갖고 있다. 하지만 "SPDK가 io_uring을 언제 받아들였나", "OpenZFS Direct I/O는 커널 `RWF_DONTCACHE`와 같은 시기인가" 같은 질문은 문서 경계를 넘어야 답할 수 있다. 같은 사실이 여러 문서에 다른 표현으로 반복되기도 한다. 예를 들어 `IORING_SETUP_SINGLE_ISSUER`(6.0)는 01/02와 09/06에 따로 나온다. 통합 연표는 이 중복을 한 행으로 합치고, 출처 문서 목록(`source_doc`)을 남겨 원 문서로 돌아갈 수 있게 한다.

### 2.2 원 추출본의 불일치와 정규화 결정

두 추출본(문서 01~06의 316행, 07~13의 650행)은 같은 열 구조를 썼지만 규약이 달랐다. `tools/merge_timeline.py`는 다음 규칙을 적용한다.

| 문제 | 원 상태 | 통합 규칙 |
|---|---|---|
| io_uring 커널 기능의 프로젝트 | part1은 커널 uAPI(`IORING_*`, opcode, setup 플래그, zcrx)를 `io_uring(liburing)`에 넣음 | 모두 `Linux`로 옮기고 이벤트 문구에 "io_uring"을 보장. `io_uring(liburing)`은 liburing 릴리스·동작(2행)에만 사용 |
| `other(…)`, `other: X` | 30여 개의 임시 프로젝트명 | `논문·학회`, `Docker`, `RHEL`, `Boost`, `libbpf`, `Zoned 도구`(ZenFS·libzbd), `ublk 도구`(ublksrv·libublk-rs·rublk) 등으로 정리 |
| Linux 버전 표기 | `v7.3-rc7`와 `7.3-rc7` 혼재 | 앞의 `v` 제거, rc 접미사는 원문대로. 다른 프로젝트 버전은 원문 유지 |
| 게시 후 병합된 시리즈 | part1이 `proposal(unmerged)` + "게시"로 기록 | 나중에 병합된 행이 있으면 새 종류 `posted`(18행). 끝내 병합되지 않은 작업만 `proposal(unmerged)`(46행) |
| 문서 간 중복 | 같은 기능이 두 추출본에 각각 존재 | 명백한 중복 28건만 병합. 출처 목록을 합치고 더 정밀한 날짜를 유지 |
| 누락 날짜 | 기능 행에 날짜 없음 | 같은 프로젝트·버전의 날짜 있는 릴리스 행이 TSV 안에 있을 때만 채움(SPDK 7행). 외부 지식으로는 채우지 않음 |

병합은 보수적으로 했다. 09/06의 묶음 행 "`IORING_SETUP_IOPOLL`, `IORING_SETUP_SQPOLL`/`IORING_SETUP_SQ_AFF`/`IORING_SQ_NEED_WAKEUP`"(5.1)은 01/01의 플래그별 행 셋으로 나눠 흡수했다. 5.19의 `IORING_OP_URING_CMD`/`SQE128`/`CQE32` 묶음도 같은 방식이다. 반면 "Enable bio recycling for polled IO" PATCHSET v5(2021-08-12, → 09/06)는 연표 안에 대응하는 병합 행이 없어 `proposal(unmerged)`로 남겼다. Kanchan Joshi의 `IORING_OP_IOCTL_PT` RFC(2021-01-27, → 03/02)와 2019년 `RWF_UNCACHED` 첫 제안(→ 11/02)도 그대로 두었다. 둘 다 그 설계 자체는 버려졌고, 후속 설계(`uring_cmd`, 2024년 재제안)만 병합됐기 때문이다.

### 2.3 데이터 규약

연표의 각 행은 `project`, `version`, `date`, `event_ko`, `kind`, `source_doc`, `confidence`의 7열이다. 날짜가 있는 행은 312개, 버전이 있는 행은 821개다. 둘 다 없는 행 15개는 "master 미지원" 같은 상태 기술이다.

| `kind` | 의미 | 행 수 | 예 |
|---|---|---|---|
| `added` | 기능·API·드라이버가 해당 버전에 처음 들어옴 | 522 | `IORING_OP_URING_CMD` 5.19 (→ 01/01) |
| `changed` | 의미·구현·권한 모델 변경 | 176 | SQPOLL 권한 검사 제거 5.13 (→ 01/01) |
| `default` | 기본값 변경(동작은 있었으나 기본이 바뀜) | 47 | Ceph Nautilus `rgw_frontends` civetweb → beast (→ 06/01) |
| `removed` | 삭제·비활성화 | 42 | hybrid polling 삭제 6.4 (→ 02/03) |
| `renamed` | 이름만 바뀜 | 19 | `QUEUE_FLAG_PCI_P2PDMA` → `BLK_FEAT_PCI_P2PDMA` 6.11 (→ 08/02) |
| `release` | 릴리스·태그·논문·학회 세션 자체 | 68 | SPDK v25.05 LTS 2025-05-29 (→ 07/01) |
| `posted` | 메일링 리스트에 게시되고 나중에 병합된 시리즈 | 18 | `[PATCHSET v1] io_uring IO interface` 2019-01-08 (→ 01/01) |
| `proposal(unmerged)` | 7.3-rc7 기준까지 병합되지 않은 제안 | 46 | `libmultipath` 시리즈 2026-02-25 (→ 03/01) |

`confidence`는 `confirmed`(918행)와 `unverified`(20행) 두 값이다. `unverified`는 원 문서가 `[추측/미확인]`을 붙인 주장이다. 사이트에서는 "추측/미확인" 태그로 표시된다. 대표적인 예가 RHEL 8의 네이티브 NVMe 멀티패스 기본 비활성(`nvme_core.multipath=N`)이다. 03/01 본문이 이 기본값에 `[추측/미확인]`을 붙였으므로 통합 시 `unverified`로 고쳤다(→ 03/01). NVMe TP 8006/8011(→ 03/03), GDS 1.13과 CUDA 12.8의 대응(→ 08/01), 2020년 io_uring zone append 제안(→ 09/01)도 같은 등급이다.

**미출시 버전 표기.** Linux `7.3-rc`, `7.3-rc1`, `7.3-rc7`(18행)은 아직 릴리스되지 않은 master 상태다. `7.3-rc`는 7.3 머지 윈도에 들어온 것, `7.3-rc7`은 "rc7 시점에도 메인라인에 없음"을 기록한 `proposal(unmerged)` 행이 대부분이다. 7.3 정식 릴리스 전에 revert될 수 있으므로 확정 사실로 읽으면 안 된다. 다른 프로젝트도 같다. nvme-cli 3.2 "(미출시)", libfuse `master`의 `-o io_uring_bufpool`, OpenZFS `master (2.4.99)`의 `scheduler` 속성, SPDK v27.01(master 개발 중)이 그런 행이다(→ 09/03, 11/03, 10/02, 07/01).

**버전과 날짜의 관계.** Linux 행의 `date`는 대개 병합(merge) 날짜나 시리즈 작성일이다. 커널 릴리스 날짜가 아니다. 예를 들어 `RWF_DONTCACHE`의 6.15 비활성화 행의 날짜(2025-05-25)는 Linus의 비활성화 커밋 시점이다(→ 11/02). 반대로 SPDK의 v25.05·v26.01·v26.09 기능 행 7개는 같은 TSV의 릴리스 행에서 날짜를 받았으므로 릴리스 날짜다(→ 07/01, 07/02).

## 3. The Debate

연표 자체는 논쟁을 담지 않는다. 하지만 같은 기능이 여러 번 등장하는 궤적을 따라가면 어디서 설계가 부딪혔는지 보인다. 개별 논쟁의 발언과 맥락은 각 도메인 문서에 있으므로, 여기서는 시간축에서 읽히는 패턴만 정리한다.

### 3.1 데이터 배치: streams 4.13 → 5.18 제거 → write streams 6.16

| 시점 | 이벤트 | 종류 |
|---|---|---|
| 2016-03-04 | Axboe "Update version of write stream ID patchset"(숫자 stream ID 방식) (→ 09/02) | `posted` |
| 2017 | NVMe 1.3 Directives/Streams 비준 (→ 09/02) | `added` |
| 4.13 (2017-06-26) | write life time hints(`F_{GET,SET}_RW_HINT`, `RWH_WRITE_LIFE_*`)와 NVMe Streams Directive 지원. NVMe streams 모듈 파라미터 기본값 off (→ 09/02) | `added`, `default` |
| 5.18 (2022-03-26) | NVMe streams 지원, per-bio/request write hint, `kiocb.ki_hint` 제거 (→ 09/02) | `removed` |
| 6.2 (2022-10) | `request.write_hint` 제거 (→ 09/02) | `removed` |
| 2022-12-12 | FDP TP4146 비준 (→ 09/02, 09/01) | `added` |
| 6.9 (2024-03-04) | `bio->bi_write_hint` 복원, bdev `F_SET_RW_HINT`(UFS 수요) (→ 09/02) | `added` |
| 6.16 (2025-05-06) | block write streams(`max_write_streams`, `bi_write_stream`, io_uring SQE `write_stream`, NVMe FDP) (→ 09/02) | `added` |
| 7.2 | f2fs가 write stream 사용 — 첫 파일시스템 사용자 (→ 09/02) | `added` |

이 궤적의 핵심은 "힌트"가 "스트림"으로 이름과 의미를 바꿔 돌아왔다는 점이다. 6.16 병합 행은 이를 "renamed hints to streams, removed stacking"으로 요약한다(→ 09/02). 그 사이 5.19부터는 I/O Passthru(`uring_cmd`)로 FDP를 쓸 수 있었고(→ 09/02), 사용자 공간 도구는 커널 uAPI보다 먼저 움직였다. QEMU 8.0 FDP 에뮬레이션과 xNVMe v0.7 FDP 지원이 그 예다(→ 09/02). LSFMM+BPF 2025(2025-05-02) FDP 세션은 Meta가 구매한 SSD가 모두 FDP를 지원하지만 기본 비활성이라고 기록한다(→ 09/02).

### 3.2 폴링: hybrid polling의 퇴장과 io_uring 쪽 재등장

블록 폴링은 4.4의 `blk_poll()`/`REQ_HIPRI`로 시작했다. 4.10에서 hybrid polling(`blk_mq_poll_hybrid`)이 추가됐다(→ 02/01, 02/03). 5.16에는 폴링이 bio 기반(`bio_poll()`, `REQ_POLLED`)으로 재편됐다(→ 02/01, 02/03). 6.4에서 hybrid polling은 삭제(`54bdd67d0f88`)되고 `io_poll_delay`는 -1(classic)로 고정됐다(→ 02/01, 02/03). 그런데 6.13에 io_uring `IORING_SETUP_HYBRID_IOPOLL`이 추가됐다(→ 01/01, 02/01, 02/03, 09/06). 같은 아이디어가 블록 계층의 sysfs 노브에서 링 단위 setup 플래그로 자리를 옮긴 셈이다.

### 3.3 페이지 캐시 우회: `RWF_UNCACHED` → `RWF_DONTCACHE`

2019-12-12 Axboe의 `RWF_UNCACHED` 첫 제안은 중단됐다(→ 11/02). 2024-12-04 재제안(`posted`)이 6.14에서 `RWF_DONTCACHE`/`FOP_DONTCACHE`/`PG_dropbehind`로 병합됐다(→ 11/02, 11/01). 6.15에서는 XFS opt-in이 들어왔지만, 릴리스 직전(2025-05-25) Linus가 `FOP_DONTCACHE=0`으로 전역 비활성화해 6.15의 `RWF_DONTCACHE`는 `-EOPNOTSUPP`를 반환한다(→ 11/02). 6.16에 revert로 재활성화됐다. 이후 6.17 ext4, 6.18 NFS 클라이언트, 7.2 flusher kick 방식 쓰기, 7.3-rc 블록 장치 지원이 이어졌다(→ 11/02). btrfs dontcache는 master에서 아직 미지원이다(→ 11/02).

### 3.4 epoll 락: rwlock 도입과 spinlock 복귀

epoll `ep->lock`은 5.1(2019-03)에 spinlock에서 `rwlock_t`와 `xchg` 리스트 추가 방식으로 바뀌었다(→ 04/03). 6.16-rc에서는 "eventpoll: Fix priority inversion problem"(`8c44dac8add7`)이 병합된 뒤 Linus가 회귀로 revert했다(2025-07-11, → 04/03). 6.18에서 결국 `spinlock_t`로 복귀했다(`0c43094f8cc9`, 2025-09-05, PREEMPT_RT 우선순위 역전, → 04/03). 2026년에는 이 복귀가 PREEMPT_RT 격리 코어에서 지연 스파이크를 만든다는 회귀 보고가 있었다는 행이 있다. 이 행은 `unverified`다(→ 04/03).

io_uring과 epoll의 관계도 오갔다. `IORING_OP_EPOLL_CTL`은 5.6에 추가됐고 6.0에 deprecation 경고가 붙었다가 6.4에 철회됐다(libuv 사용 확인, → 01/04). 7.2-rc에서는 중첩 epoll 금지(`cfa1539b24af`)가 같은 7.2 주기에 revert(`9db03d2116ab`)되어 최종 동작 변화가 없다(→ 01/04). 반대 방향으로 6.15에 `IORING_OP_EPOLL_WAIT`(one-shot)가 추가됐다(→ 01/01, 01/04).

### 3.5 io_uring 보안: 확장 속도와 차단 정책의 경쟁

io_uring의 기능 확장과 보안 대응은 연표에서 나란히 움직인다. Docker는 2019년 PR #39415로 기본 seccomp 프로필에서 io_uring을 허용했다. 2023-11-02에는 PR #46762로 기본 차단으로 돌아섰다(→ 01/03). 그 사이 Google은 2023-06에 ChromeOS에서 io_uring을 비활성화하고, Android 앱 접근을 차단하고, 프로덕션 서버에서 껐다(→ 01/03). 커널 쪽 대응은 단계적이었다.

- 5.10: `IORING_REGISTER_RESTRICTIONS`, `IORING_SETUP_R_DISABLED` (→ 01/01, 01/03)
- 5.16: LSM 훅 `security_uring_override_creds()`/`security_uring_sqpoll()`, audit 지원 (→ 01/03)
- 5.19(2022-07): `IORING_OP_URING_CMD`가 LSM 훅 없이 병합된 사실이 드러나 논쟁 → 6.0 `security_uring_cmd()` (→ 01/03)
- 2023-06-29 Matteo Rizzo의 sysctl 패치 게시(`posted`) → 6.6 `kernel.io_uring_disabled`/`kernel.io_uring_group` (→ 01/01, 01/03)
- 6.15: `security_uring_allowed()` (→ 01/03)
- 7.0: `IORING_REGISTER_BPF_FILTER`(classic BPF opcode 필터)와 태스크 단위 "blind" 등록 (→ 01/01, 01/03)

권한 모델도 반대 방향으로 움직였다. SQPOLL은 5.10까지 `CAP_SYS_ADMIN`이 필요했고, 5.11~5.12에는 `CAP_SYS_NICE`도 허용됐으며, 5.13에 권한 검사가 제거됐다(→ 01/01). NVMe 패스스루는 6.2에 `nvme_cmd_allowed()`로 비특권 I/O를 허용했다(→ 03/02, 07/03, 09/03). 반면 7.3-rc1에서는 드라이버가 관리하는 Set Features 패스스루를 root에게도 거부하도록 좁혔다(2026-07-15, → 09/03).

### 3.6 실행 모델: io thread 전환의 회귀와 수습

2021-02-19 "Remove kthread usage from io_uring" RFC(`posted`)는 5.12 io thread 전환 병합(2021-02-27, merge `5695e5161974`)으로 이어졌다(→ 01/01, 01/02). 직후 5.12-rc에서 GDB 부착 무한 루프와 suspend/freezer 회귀가 나왔다. rc3의 "Make IO threads unfreezable by default" 임시 조치는 이후 revert됐다. freezer `PF_IO_WORKER` 처리 커밋(2021-03-12)도 2021-03-27에 revert(`d3dc04cd81e0`)됐다. rc5 무렵 io thread가 신호를 받아 `get_signal()`을 거치는 일반 스레드화로 정리됐다(→ 01/02). 2026-09의 thread identity handoff RFC(`PF_IO_HANDOFF`)는 master(7.3-rc7)에 미병합이다(→ 01/02).

### 3.7 제거·개명 주요 항목

| 프로젝트 | 버전 (날짜) | 제거·개명 내용 | 후속·대체 | 근거 |
|---|---|---|---|---|
| Linux | 4.18 (2018-06-01) | staging Lustre 삭제 (195,272줄) | LSFMM+BPF 2025 "Getting Lustre upstream" 재진입 계획 (미병합) | → 10/04 |
| Linux | 5.0 (2019-03) | 레거시 `request_fn` 경로, CFQ·legacy deadline/noop, `blk-tag.c` 삭제 | blk-mq 스케줄러(`mq-deadline` 4.11, `bfq`/`kyber` 4.12) | → 02/01, 02/02, 02/03 |
| Linux | 5.0 (2019-01-10) | `__kernel_fpu_begin()`/`__kernel_fpu_end()` export 제거 | ZFS SIMD 체크섬 빌드 불가 | → 10/02 |
| Linux | 5.18 (2022-03-26) | NVMe streams·write hint 제거 | 6.16 write streams | → 09/02 |
| Linux | 6.4 | hybrid polling 삭제 | 6.13 `IORING_SETUP_HYBRID_IOPOLL` | → 02/01, 02/03 |
| Linux | 6.4 | tracepoint `io_uring_submit_sqe` → `io_uring_submit_req` | — | → 05/01, 05/02 |
| Linux | 6.5 | `->sendpage()` 제거 | `sendmsg()`+`MSG_SPLICE_PAGES` | → 03/03, 04/02 |
| Linux | 6.11 | `QUEUE_FLAG_PCI_P2PDMA` → `BLK_FEAT_PCI_P2PDMA` | queue limits 기반 기능 플래그 | → 08/02 |
| Linux | 6.15 (2025-05-25) | `FOP_DONTCACHE` 전역 비활성화 | 6.16 재활성화 | → 11/02 |
| Linux | 6.16-rc (2025-07-11) | eventpoll 우선순위 역전 수정 revert | 6.18 spinlock 복귀 | → 04/03 |
| Linux | 6.18 | `write_cache_pages()` 삭제 | — | → 11/02 |
| Ceph | Reef v18.2.0 | FileStore 소스 제거, `rgw::sal::Store` → `Driver` | BlueStore(Luminous 기본) | → 06/03, 06/01 |
| Ceph | Pacific v16.2.0 | `bluestore_ioring` → `bdev_ioring` | — | → 06/03 |
| DPDK | 20.11 / 23.11 | `igb_uio`를 `dpdk-kmods`로 분리 / KNI 제거 | — | → 04/04 |
| SPDK | v25.09 | blobfs, RocksDB Env 플러그인, compress bdev·reduce, vfio-user live migration 코드 제거 | — | → 07/01, 07/02, 07/03, 09/04 |
| QEMU | 8.0 | C 구현 virtiofsd 제거 | Rust virtiofsd | → 11/03 |
| NVIDIA GDS | CUDA 13.0 | Tegra nv-p2p API deprecation | upstream 커널 API | → 08/03 |
| nvme-cli | 3.0 (2026-09-07) | 표준 명령을 플러그인 네임스페이스로 재편(`smart-log` → `nvme log smart` 등) | libnvme 소스 통합 | → 09/03 |
| RocksDB | 5.4.0 (2017-04-11) | `use_direct_writes` → `use_direct_io_for_flush_and_compaction` | 11.5.0 `use_direct_io_for_compaction_reads` | → 10/03 |

## 4. Implementation Impact

### 4.1 시대별 주요 행 (교차 프로젝트)

아래 표는 시대마다 다른 프로젝트의 선택에 영향을 준 행만 골랐다. 날짜가 없는 행은 버전만 적었다. 전체 행은 사이트 연표에서 프로젝트 필터로 볼 수 있다.

**2013–2018: 다중 큐와 사용자 공간 경로**

| 날짜 / 버전 | 프로젝트 | 이벤트 | 근거 |
|---|---|---|---|
| 3.13 (2014-01) | Linux | blk-mq 병합, `null_blk` 동시 추가 | → 02/01, 02/02 |
| 3.19 | Linux | NVMe 드라이버 blk-mq 전환 (`nvme_make_request` 폐기) | → 02/01 |
| 2015-12-07 | SPDK | v1.0.0 "initial open source release" | → 07/01 |
| v16.06 | SPDK | NVMf 사용자 공간 target(RDMA), YY.MM 버전 체계 시작 | → 07/01, 07/03 |
| Jewel v10.2.0 → Luminous v12 | Ceph | BlueStore experimental → 안정판·기본 백엔드 | → 06/03 |
| 4.8 (2016-07-20) | Linux | XDP 최초 병합; 같은 4.8에 NVMe-oF RDMA host/target | → 04/01, 03/03, 13/02 |
| 4.11 / 4.12 | Linux | `blk-mq-sched`와 `mq-deadline` / `bfq`·`kyber` | → 02/01, 02/02 |
| 2017-02-08 | RocksDB | 5.2.0 `use_direct_reads`/`use_direct_writes` 사용 가능 | → 10/03 |
| 4.13 (2017-06-26) | Linux | write life time hints, NVMe Streams | → 09/02 |
| 2017-07-05 | Lustre | 2.10.0 PFL, LNet Multi-Rail | → 10/04 |
| 4.14 (2017-08-04) | Linux | TCP `MSG_ZEROCOPY` | → 04/02 |
| 4.15 | Linux | 네이티브 NVMe 멀티패스, `nvme_core.multipath` | → 03/01 |
| 18.05 / 18.11 | DPDK | 동적 hugepage 기본 / vfio 비특권 실행 | → 04/04, 07/01 |
| 4.18 (2018) | Linux | AF_XDP 병합; staging Lustre 삭제 | → 04/01, 10/04 |
| 4.20 | Linux | PCI P2PDMA 코어 | → 08/02 |

**2019–2021: io_uring 확장과 즉각적인 사용자 공간 채택**

| 날짜 / 버전 | 프로젝트 | 이벤트 | 근거 |
|---|---|---|---|
| 5.0 (2019-03) | Linux | 레거시 단일 큐 경로·CFQ 삭제; `nvme-tcp`/`nvmet-tcp`; `HCTX_TYPE_POLL` | → 02/01, 02/03, 03/03, 12/02 |
| 5.1 (2019-05) | Linux | io_uring 병합(`2b188cc1bb85`), `IORING_SETUP_SQPOLL`/`IOPOLL` | → 01/01, 09/06 |
| 19.05 | DPDK | AF_XDP PMD(`net_af_xdp`) | → 04/01, 04/04 |
| v19.04 | SPDK | uring bdev(`bdev_uring`) | → 07/02 |
| 2019-05-23 | OpenZFS | ZoL 0.8.0 O_DIRECT 수용(ARC 경유) | → 10/02 |
| 2019-12 | Ceph | Octopus `bluestore_ioring`(기본 `false`) | → 06/03 |
| 2020-01-21 | RocksDB | 6.7.0 MultiGet io_uring(기본 비활성), `rocksdb::FileSystem` | → 10/03 |
| 5.0 | QEMU | `file-posix aio=io_uring` | → 09/04 |
| 5.5 (2019-11-14) | Linux | BPF trampoline, `fentry`/`fexit` | → 05/01 |
| 5.6 / 5.8 / 5.9 | Linux | zonefs / `REQ_OP_ZONE_APPEND` / NVMe ZNS 드라이버 | → 09/01 |
| 2020-11-30 | OpenZFS | 2.0.0 FreeBSD 통합, Persistent L2ARC | → 10/02 |
| v21.01 | SPDK | vfio-user custom transport, 실험적 dynamic 스케줄러 | → 07/01, 07/03 |
| 5.12 (2021-02-27) | Linux | io_uring io thread 전환; `cxl_mem` | → 01/01, 01/02, 13/03 |
| 2021-06 | NVIDIA GDS | GDS 1.0 호환 파트너 항목 | → 08/01 |
| 5.13 | Linux | `/dev/ngXnY`; 비특권 SQPOLL | → 03/02, 07/03, 09/03, 01/01 |
| 5.16 | Linux | `struct folio`, `bio_poll()`/`REQ_POLLED` | → 11/02, 02/01, 02/03 |

**2022–2024: 패스스루와 링 재사용**

| 날짜 / 버전 | 프로젝트 | 이벤트 | 근거 |
|---|---|---|---|
| 5.18 (2022-03-26) | Linux | NVMe streams·write hint 제거 | → 09/02 |
| 5.19 | Linux | `IORING_OP_URING_CMD`, `SQE128`/`CQE32`, NVMe io_uring 패스스루 | → 01/01, 03/02, 07/03, 09/03 |
| 2022-06-16 | Lustre | 2.15.0 NVIDIA GDS 지원(LU-14798), 새 LTS stream | → 10/04 |
| 6.0 (2022-07-13) | Linux | `ublk_drv`(io_uring 기반 사용자 공간 블록 드라이버) | → 09/05, 07/03 |
| 6.0 (2022-08-02) | Linux | `IORING_OP_SEND_ZC`; `IORING_SETUP_SINGLE_ISSUER` | → 01/01, 01/02, 04/02, 09/06 |
| v22.09 | SPDK | xNVMe bdev(AIO/io_uring/`io_uring_cmd` 전환) | → 03/02, 07/02 |
| 3.31 | fio | `io_uring_cmd` ioengine(`cmd_type=nvme`) | → 03/02 |
| 2022-12-12 | NVMe spec | FDP TP4146 비준 | → 09/01, 09/02 |
| v23.01 | SPDK | ublk target(`lib/ublk`, Linux 6.0+) | → 07/03 |
| 6.2 (2023-02) | Linux | `FOLL_PCI_P2PDMA`(사용자 공간 P2PDMA); iommufd | → 08/01, 08/02, 12/01, 09/04 |
| 6.6 | Linux | `kernel.io_uring_disabled` sysctl | → 01/01, 01/03 |
| 2023-10-13 → 2023-11-22 | OpenZFS | 2.2.0 block cloning → 2.2.1 기본 비활성화(`zfs_bclone_enabled=0`) | → 10/02 |
| 2023-11-02 | Docker | 기본 seccomp 프로필에서 io_uring 차단 | → 01/03 |
| 2024-02 | 논문·학회 | FAST '24 "I/O Passthru" 발표 | → 07/01 |
| 6.9 (2024-03-15) | Linux | FUSE passthrough | → 11/03 |
| 6.10 (2024-04-05) | Linux | zone write plugging, mq-deadline zone write locking 제거 | → 09/01 |
| 2024-07-26 | DAOS | v2.6.0 MD-on-SSD Phase 1 production-ready | → 10/01 |
| 6.11 / 6.12 | Linux | `RWF_ATOMIC` / devmem TCP RX, XFS LBS | → 11/01, 04/02, 08/03 |
| 2024-12-05 | SPDK | Intel의 Linux Foundation 이전 발표 | → 07/01 |

**2025–2026: 제로카피·데이터 배치·BPF 확장**

| 날짜 / 버전 | 프로젝트 | 이벤트 | 근거 |
|---|---|---|---|
| 2025-01-14 | OpenZFS | 2.3.0 Direct I/O(PR #10018), RAIDZ expansion | → 10/02 |
| 6.14 (2025-01-29) | Linux | FUSE-over-io_uring; `RWF_DONTCACHE` 인터페이스 | → 11/03, 09/05, 11/02 |
| 6.15 (2025-02-27) | Linux | ublk 제로카피(`UBLK_U_IO_REGISTER_IO_BUF`) | → 09/05 |
| 6.15 (2025-03-28) | Linux | io_uring zcrx(`IORING_OP_RECV_ZC`) | → 01/01, 04/02, 08/03 |
| 2025-05-29 | SPDK | v25.05 LTS, LF 이전 후 첫 릴리스 | → 07/01 |
| 6.16 (2025-05-06) | Linux | block write streams, NVMe FDP; 2단계 IOVA API | → 09/02, 08/02, 12/01 |
| 2025 | NVIDIA GDS | CUDA 12.8: NVMe가 패치 없이 upstream P2PDMA 사용 | → 08/01 |
| v25.09 | SPDK | blobfs·RocksDB Env·compress bdev 제거 | → 07/02 |
| 2025-12-18 | OpenZFS | 2.4.0 비정렬 O_DIRECT의 uncached I/O 폴백 | → 10/02 |
| 2025-12-29 | Lustre | 2.17.0 Hybrid IO 기본 활성 | → 10/04 |
| 7.0 / 7.1 | Linux | io_uring BPF 필터 / BPF struct_ops 루프 | → 01/01, 01/03, 01/04 |
| 7.2 | Linux | f2fs write stream; GDS 1.19의 x86 P2PDMA 요구 커널 | → 09/02, 08/01 |
| 2026-08-12 | DAOS | v2.8.0 MD-on-SSD Phase 2, SPDK 26.01 번들 | → 10/01 |
| 7.3-rc (2026-08-25) | Linux | FUSE io_uring 버퍼 풀·제로카피 (미출시) | → 11/03 |
| 2026-09-07 | nvme-cli | 3.0 libnvme 소스 통합 | → 09/03 |
| 2026-09-24 | SPDK | v26.09 릴리스 | → 07/01 |

### 4.2 커널 기능과 프로젝트 릴리스의 추종 관계

| 커널 기능 (버전) | 추종한 프로젝트 릴리스 | 채택 형태 | 근거 |
|---|---|---|---|
| io_uring (5.1, 2019-05) | SPDK v19.04 uring bdev; Ceph Octopus `bluestore_ioring`(2019-12); RocksDB 6.7.0(2020-01-21); QEMU 5.0 | 선택형 백엔드. Ceph·RocksDB는 기본 off, RocksDB 6.21.0에서 liburing 기본 빌드 시도 | → 07/02, 06/03, 10/03, 09/04 |
| `IORING_OP_URING_CMD` + NVMe 패스스루 (5.19) | SPDK v22.09 xNVMe bdev; fio 3.31; xNVMe | 벤치마크·추상화 계층에서 먼저 채택 | → 03/02, 07/02, 09/06 |
| ublk (6.0) | SPDK v23.01 ublk target; ublksrv(2022-03), libublk-rs(2023-06), rublk(2023-08) | SPDK master는 6.15 제로카피 대신 `USER_COPY` 사용(2026-10) | → 07/03, 09/05 |
| FUSE-over-io_uring (6.14) | libfuse 3.18 `-o io_uring`(기본 off); libfuse master `-o io_uring_bufpool` | 커널 기본도 `enable_uring=false` | → 11/03 |
| P2PDMA (4.20 → 6.2 사용자 공간) | GDS 1.13 P2PDMA 모드(커널 6.2+); CUDA 12.8 upstream P2PDMA; Lustre 2.15.0 GDS | out-of-tree `nvidia-fs`에서 upstream 경로로 이동 | → 08/01, 08/02, 10/04 |
| 커널 Direct I/O·페이지 캐시 변화 | OpenZFS ZoL 0.8.0 O_DIRECT(ARC 경유) → 2.3.0 Direct I/O → 2.4.0 uncached 폴백 | 자체 ARC를 가진 out-of-tree 모듈의 독자 구현 | → 10/02 |
| FDP (TP4146, 6.16 write streams) | QEMU 8.0, xNVMe v0.7; 5.19부터 `uring_cmd` 경유; CacheLib EuroSys '25 | 사용자 공간·패스스루 경로가 커널 uAPI보다 먼저 | → 09/02 |
| SPDK 릴리스 | DAOS v2.4.1이 SPDK 22.01.2, v2.8.0이 SPDK 26.01 번들 | 하위 계층 버전 고정 | → 10/01 |

추종 관계는 대칭이 아니다. 커널 쪽 결정이 외부 프로젝트에 직접 비용을 지운 행도 있다. 5.0의 FPU export 제거(→ 10/02), 4.18 staging Lustre 삭제(→ 10/04)가 그렇다. Lustre 2.18.0은 개발 중이며 RHEL 10.x(6.12) 서버 커널을 목표로 하고, OpenZFS 2.4.4는 지원 커널을 4.18–7.2로 명시한다(→ 10/04, 10/02). out-of-tree 프로젝트는 릴리스마다 지원 커널 범위를 다시 선언해야 한다.

### 4.3 시간축에서 본 레거시 대 신규 구조

| 축 | 레거시 (연표 시작 시점) | 신규 (7.3-rc7 기준) | 전환 행 |
|---|---|---|---|
| 블록 큐 | 단일 큐 `request_fn`, CFQ | blk-mq + `mq-deadline`/`bfq`/`kyber`, `HCTX_TYPE_POLL` | 3.13, 4.11–4.12, 5.0 (→ 02/01, 02/02) |
| 비동기 I/O | AIO, fibrils/syslets 등 미병합 시도(2007~2009) | io_uring + io thread + BPF 필터 | 5.1, 5.12, 7.0 (→ 01/01, 01/02, 01/03) |
| 장치 명령 경로 | 레거시 `NVME_IOCTL_SUBMIT_IO` ioctl | `uring_cmd` + `/dev/ngXnY` + 비특권 I/O 판정 | 5.13, 5.19, 6.2 (→ 03/02, 09/03) |
| 사용자 공간 블록·파일 서버 | FUSE `/dev/fuse` read/write(2.6.14) | ublk(6.0), FUSE-over-io_uring(6.14), 각자 제로카피 | → 09/05, 11/03 |
| 데이터 배치 | NVMe streams(4.13) | write streams + FDP(6.16) | → 09/02 |
| 네트워크 제로카피 | `MSG_ZEROCOPY`(4.14) | `SEND_ZC`(6.0), devmem TCP(6.12/6.16), zcrx(6.15) | → 04/02, 08/03 |
| 페이지 캐시 단위 | `struct page` | `struct folio`(5.16), large folio, `RWF_DONTCACHE` | → 11/02 |

연표를 실무에 쓰는 방법은 두 가지다. 첫째, 배포 커널 버전에서 수직선을 그어 그 아래의 `added`와 위의 `removed`를 함께 본다. 예를 들어 6.15 커널에서는 `RWF_DONTCACHE`가 인터페이스는 있어도 `-EOPNOTSUPP`다(→ 11/02). 둘째, `posted`에서 `added`까지의 간격으로 기능 성숙도를 가늠한다. io_uring 첫 패치셋(2019-01-08)에서 5.1 병합(2019-05)까지는 몇 달이었다(→ 01/01). FUSE-over-io_uring은 첫 RFC(2023-05-19)에서 6.14 병합(2025-01-29)까지 1년 반이 걸렸다(→ 11/03). 하드웨어 래핑 키는 v5(2022-02-27)에서 v11(2025-02)을 거쳐 6.15에 병합됐다(→ 13/01).

## 5. Primary References

아래 링크는 통합 연표의 행을 낳은 도메인 문서들이 이미 인용한 1차 사료다. 행별 근거는 각 행의 `source_doc`이 가리키는 문서의 참고문헌을 따른다.

- [io_uring IO interface [LWN.net]](https://lwn.net/Articles/776230/) — Jens Axboe, [PATCHSET v1] 커버 레터 사본, 2019-01-08 (`posted` 행, → 01/01)
- [torvalds/linux commit 2b188cc1bb85: Add io_uring IO interface](https://github.com/torvalds/linux/commit/2b188cc1bb857a9d4701ae59aa7768b5124e262e) — 5.1 io_uring 병합 커밋 (→ 01/01)
- [The multiqueue block layer (LWN, 2013-06-05)](https://lwn.net/Articles/552904/) — blk-mq 병합 직전 설계 개요 (→ 02/01)
- [blk-mq: remove hybrid polling (commit 54bdd67d0f88)](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=54bdd67d0f88489ac88f7664b56cb7c93799d84d) — 6.4 hybrid polling 삭제 (→ 02/03)
- [lwn.net - Add support for write life time hints](https://lwn.net/Articles/726477/) — 4.13 write hint 패치셋 v10, 2017-06-26 (→ 09/02)
- [github.com/torvalds/linux - Merge tag 'for-5.18/write-streams-2022-03-18'](https://github.com/torvalds/linux/commit/561593a048d7) — 5.18 NVMe streams·write hint 제거 머지 (→ 09/02)
- [github.com/torvalds/linux - block: introduce max_write_streams queue limit](https://github.com/torvalds/linux/commit/d2f526ba27d2) — 6.16 write streams 시리즈 (→ 09/02)
- [fs: add RWF_DONTCACHE iocb and FOP_DONTCACHE file_operations flag (commit af6505e5745b)](https://github.com/torvalds/linux/commit/af6505e5745b9f3a670de405b08b73573343c15c) — 6.14 `RWF_DONTCACHE` (→ 11/02)
- [Disable FOP_DONTCACHE for now due to bugs (commit 478ad02d6844)](https://github.com/torvalds/linux/commit/478ad02d6844217cc7568619aeb0809d93ade43d) — 6.15 직전 전역 비활성화 (→ 11/02)
- [Revert "Disable FOP_DONTCACHE for now due to bugs" (commit 7b2b67dbd449)](https://github.com/torvalds/linux/commit/7b2b67dbd449afd00fc7279b1ab7ffa3d26fe0c9) — 6.16 재활성화 (→ 11/02)
- [epoll: use rwlock in order to reduce ep_poll_callback() contention (commit a218cc491420)](https://github.com/torvalds/linux/commit/a218cc491420) — 5.1 rwlock 전환 (→ 04/03)
- [eventpoll: Replace rwlock with spinlock (commit 0c43094f8cc9)](https://github.com/torvalds/linux/commit/0c43094f8cc9) — 6.18 spinlock 복귀 (→ 04/03)
- [Merge tag 'for-6.15/io_uring-rx-zc-20250325' (commit ca0b04ba0b35)](https://github.com/torvalds/linux/commit/ca0b04ba0b35) — 6.15 zcrx 병합 (→ 04/02)
- [I/O Passthru: Upstreaming a flexible and efficient I/O Path in Linux](https://www.usenix.org/conference/fast24/presentation/joshi) — Joshi et al., FAST '24 (→ 03/02, 07/01)
- [Intel's SPDK Transition to the Linux Foundation](https://spdk.io/news/2024/12/05/LF/) — 2024-12-05 발표 (→ 07/01)
- [Direct IO Support · Pull Request #10018 · openzfs/zfs](https://github.com/openzfs/zfs/pull/10018) — OpenZFS 2.3.0 Direct I/O (→ 10/02)
- [facebook/rocksdb — HISTORY.md](https://github.com/facebook/rocksdb/blob/main/HISTORY.md) — RocksDB 버전별 도입 시점 (→ 10/03)
