# Lustre 심층 분석: MGS/MDS/OSS 구조, LNet, PFL·DoM·DNE·FLR 레이아웃, LDLM 락킹과 클라이언트 I/O 경로, 그리고 upstream 재진입 시도

> 기준 버전: Lustre `lustre-release` master(2026-10-13 커밋 `LU-20782 osc: keep pages covered by another lock on cancel` 기준, `lustre/ChangeLog` 상 차기 버전 2.18.0) 및 릴리스 태그 `v2_15_0`, `v2_16_0`, `v2_17_0`. 구조체·함수·플래그 이름은 `lustre-release` 소스(git.whamcloud.com 원본 저장소의 GitHub 미러 `lustre/lustre-release`) 기준이다. 기능 도입 버전은 jira.whamcloud.com의 각 LU 티켓 `fixVersion` 필드와 wiki.lustre.org 릴리스 페이지를 따른다. 1차 사료로 뒷받침되지 않는 항목은 `[추측/미확인]`으로 표시한다.

## 1. Verdict

Lustre는 "메타데이터와 데이터를 서로 다른 서버 군으로 분리하고, 그 사이를 분산 락 매니저(LDLM)로 일관되게 묶는" 설계를 20년 넘게 유지해 온 POSIX 병렬 파일시스템이다. 구성 요소는 세 종류다. 설정 레지스트리인 MGS(Management Server, 저장 장치는 MGT), 네임스페이스를 담당하는 MDS(장치는 MDT), 파일 데이터를 객체로 저장하는 OSS(장치는 OST)다. 클라이언트는 커널 모듈(`llite`, `lov`, `osc`, `mdc`, `lmv`, `ptlrpc`, `ldlm`, `lnet`)로 구현되며, VFS 아래에서 직접 RPC를 만들어 LNet으로 보낸다. 데이터 경로에 FUSE나 사용자 공간 데몬이 없다.

이 문서의 결론은 다섯 가지다.

1. **Lustre의 확장성은 "레이아웃"이라는 메타데이터 객체에서 나온다.** 파일 하나의 데이터가 어느 OST 객체들에 어떤 패턴으로 흩어지는지는 MDT의 `trusted.lov` 확장 속성(LOV EA)에 저장된다. 이 레이아웃이 단순 RAID0 striping에서 구성요소(component) 목록으로 진화했다. 그 결과 PFL(2.10), DoM(2.11), FLR(2.11), self-extending layout과 overstriping(2.13), 그리고 master의 erasure coding(`LOV_PATTERN_PARITY`, `LCME_FL_PARITY`)까지 모두 "같은 레이아웃 틀 위에 component 플래그를 추가하는" 방식으로 들어왔다. 클라이언트가 레이아웃을 해석해 OST에 직접 I/O하므로 MDS는 데이터 경로에 끼지 않는다.
2. **LDLM은 Lustre 일관성의 핵심이자 가장 큰 성능 변수다.** 데이터는 OST가 발급하는 extent lock(`LDLM_EXTENT`), 메타데이터는 MDT의 inode bit lock(`LDLM_IBITS`, `MDS_INODELOCK_*`)으로 보호된다. 클라이언트는 lock이 유효한 동안 페이지 캐시를 마음껏 쓰지만, 여러 클라이언트가 같은 범위에 쓰는 순간 blocking AST → 더티 페이지 flush → cancel이라는 왕복이 생긴다. 2.17의 Hybrid IO(LU-18033, 큰 buffered I/O를 DIO로 자동 전환)와 master의 서버 측 contention 계측(`ldlm_update_contention()`)은 이 비용을 피하려는 최근의 답이다.
3. **LNet은 Lustre 전용 네트워크 추상화로, 여러 fabric을 하나의 NID 공간에 묶는다.** LND(Lustre Network Driver)로 `socklnd`(TCP), `o2iblnd`(InfiniBand/RoCE verbs), `gnilnd`(Cray Gemini/Aries), `kfilnd`(HPE kfabric, 2.16.0 태그부터 소스에 존재), `efalnd`(AWS EFA, 2.17, LU-18977)가 있다. Multi-Rail(2.10), Network Health(2.12), UDSP(2.15), IPv6/large NID(2.16)가 차례로 들어왔다. 라우터 노드를 통해 서로 다른 fabric을 잇는 것도 LNet 계층의 일이다.
4. **커널 밖(out-of-tree)에서 사는 것이 Lustre의 구조적 특성이다.** 클라이언트는 Linux 3.11에서 staging에 들어갔다가 4.18 머지 윈도우에서 Greg Kroah-Hartman이 통째로 삭제했다(커밋 `be65f9ed267f`, 195,272줄 삭제). 2025년 LSFMM+BPF에서 James Simmons와 Timothy Day가 클라이언트 upstream 재진입 계획을 다시 제시했다. 2.17 태그에 처음 생긴 최상위 `lustre_compat/` 디렉터리는 "커널 호환 코드를 코어에서 분리한다"는 그 계획과 방향이 같다. 서버는 여전히 ext4 패치 세트(`ldiskfs`)나 OpenZFS(→ 10/02)에 묶여 있어 upstream 대상이 아니다.
5. **현재 릴리스 구도는 "2.15 LTS + 최신 major"다.** wiki.lustre.org 릴리스 정보 페이지(2026-02-13 수정판)는 Current LTS를 2.15.8(2025-12-02), Current Major를 2.17.0(2025-12-29)으로 적는다. 2.16.x는 LTS가 아니다. lustre.org의 2.16.1 공지가 "This is not an LTS release"라고 명시한다.

DAOS(→ 10/01)가 커널을 데이터패스에서 걷어내고 객체 API를 1차 인터페이스로 삼은 것, Ceph가 CRUSH로 메타데이터 서버 없이 객체 위치를 계산하는 것과 비교하면, Lustre는 "커널 내 POSIX 클라이언트 + 중앙 레이아웃 + 분산 락"을 고집한다. 이 선택 덕분에 기존 HPC 애플리케이션을 수정 없이 수천 노드로 돌릴 수 있다. 대신 작은 파일, 공유 파일 동시 쓰기, 커널 버전 추종이라는 세 가지 고질적 비용을 진다. 이 문서는 그 비용을 줄이려는 기능들(DoM, DNE, PCC, Hybrid IO, GDS)을 소스 수준에서 따라간다.

## 2. Problem Statement

### 2.1 병렬 I/O가 요구하는 것

HPC 애플리케이션의 I/O는 대체로 두 패턴이다. N-N(프로세스마다 파일 하나)과 N-1(모든 프로세스가 한 파일의 서로 다른 구간에 씀, 예: MPI-IO collective checkpoint)이다. 파일시스템은 다음을 동시에 만족해야 한다.

- **대역폭 확장**: 파일 하나의 대역폭이 서버 한 대에 묶이지 않도록 데이터를 여러 서버에 흩어야 한다. 이것이 striping이다.
- **메타데이터 확장**: 수만 프로세스가 동시에 `open(O_CREAT)`하면 단일 메타데이터 서버가 병목이다. DNE(Distributed Namespace)가 이를 다룬다.
- **POSIX 일관성**: 한 클라이언트가 쓴 내용이 다른 클라이언트의 `read()`에 즉시 보여야 한다. NFS의 close-to-open보다 강한 의미론이다. 이를 위해 분산 락이 필요하고, 락은 곧 경합 비용이다.
- **네트워크 다양성**: 한 사이트 안에 InfiniBand 계산 노드, Ethernet 로그인 노드, Slingshot/Aries 시스템이 섞여 있다. 파일시스템이 이들을 라우팅으로 이어야 한다.

### 2.2 초기 설계(RAID0 striping + 단일 MDS)의 한계

2.x 초기 Lustre의 파일은 "OST 객체 N개에 stripe_size 단위로 라운드로빈"하는 고정 레이아웃 하나만 가졌다. 이 모델에는 세 가지 문제가 있었다.

1. **stripe count를 생성 시점에 정해야 한다.** 작은 파일에 stripe를 많이 주면 `stat()`·`open()` 때마다 OST마다 glimpse RPC가 나가고, 큰 파일에 stripe를 적게 주면 대역폭이 나오지 않는다. 사용자는 파일 크기를 모른 채 선택해야 했다. PFL이 이 문제를 겨냥했다.
2. **작은 파일은 MDS와 OSS를 모두 거친다.** wiki.lustre.org의 Data on MDT 페이지는 Lustre가 "currently optimized for large files"였고, 그 결과 "additional RPC round-trips to the OSTs, which hurt small file performance"가 생긴다고 문제를 정의한다. 해결책은 작은 파일의 데이터를 MDT에 두는 DoM이다.
3. **MDS 한 대의 처리량이 파일 생성 속도의 상한이다.** DNE Phase 1(LU-1187, 2.4.0)의 remote directory가 디렉터리 단위로 MDT를 나눴다. 이후 striped directory(LU-3531 DNE2), 파일시스템 전체 기본 LMV(LU-14792, 2.15), metadata overstriping(LU-12273, 2.16)이 이어졌다.

### 2.3 하드웨어 변화가 만든 새 병목

- **NVMe OST와 200/400 Gb/s 네트워크**: 서버 한 대가 수십 GB/s를 낼 수 있게 되자 클라이언트 쪽 페이지 캐시 경로(페이지 단위 `cl_page` 관리, `osc_extent` 병합, LRU)가 CPU 병목이 됐다. Lustre는 수년에 걸쳐 DIO 경로를 비동기·비정렬 지원으로 키웠고(`ll_direct_rw_pages`, `ll_dio_aio`), 2.17에서는 큰 buffered I/O를 자동으로 DIO로 바꾸는 Hybrid IO를 기본으로 켰다.
- **GPU 학습 워크로드**: 체크포인트와 데이터 로딩이 GPU 메모리로 직행해야 한다. LU-14798(NVIDIA GPUDirect Storage Support, fixVersion 2.15.0)이 LNet RDMA 경로에 `nvidia-fs` 콜백을 붙였다(→ 08/01).
- **공유 파일 쓰기 경합**: N-1 패턴에서 extent lock이 클라이언트 사이를 오가면 처리량이 급락한다. lockahead(LU-6179, 2.11)와 서버 측 contention 계측이 이 문제를 다룬다.

### 2.4 커널 밖에서 사는 비용

Lustre 클라이언트는 VFS·페이지 캐시·블록 계층의 내부 API를 깊게 사용한다. 그런데 메인라인에 없으니 커널이 바뀔 때마다 Lustre가 따라가야 한다. 2.18 개발 중인 master `lustre/ChangeLog`는 서버 기준 커널로 RHEL 10.x(6.12), RHEL 9.x(5.14), RHEL 8.10(4.18)을 동시에 나열한다. 세 계열의 커널 API 차이를 configure 시점 검사와 호환 매크로로 흡수해야 한다는 뜻이다. ldiskfs는 배포판 커널별 ext4 패치 시리즈로 관리된다. 예를 들어 `ldiskfs/kernel_patches/series/ldiskfs-5.14-rhel9.4.series`에는 패치 48개가 있고, 그중에는 병렬 디렉터리 조작용 `ext4-pdirop.patch`, OSD용 inode 연산을 export하는 `ext4-osd-iop-common.patch`, 프로젝트 ID xattr 패치가 있다. 이 유지 비용이 upstream 논쟁(3절)의 배경이다.

## 3. The Debate

### 3.1 staging 편입(3.11)과 삭제(4.18): "dual-tree development model"

Lustre 클라이언트는 Linux 3.11에서 `drivers/staging/lustre`로 들어왔다. GitHub의 `torvalds/linux` 트리를 태그별로 조회하면 `v3.10`에는 이 디렉터리가 없고 `v3.11`~`v4.17`에는 있으며 `v4.18`에서 사라진다. 삭제 커밋은 Greg Kroah-Hartman의 `be65f9ed267fd7d8b3146b7c4be9ecdd3e0aa3ed`(작성 2018-06-01, 4.18-rc1 staging 풀 `staging-4.18-rc1`로 머지)이다. 이 커밋은 추가 0줄, 삭제 195,272줄이다. 커밋 메시지의 핵심 문단은 다음과 같다.

> "There is a whole separate out-of-tree copy of this codebase where the developers work on it, and then random changes are thrown over the wall at staging at some later point in time. This dual-tree development model has never worked, and the state of this codebase is proof of that."
> — Greg Kroah-Hartman, 커밋 `be65f9ed267f` "staging: lustre: delete the filesystem from the tree." (2018-06-01), [git.kernel.org](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=be65f9ed267fd7d8b3146b7c4be9ecdd3e0aa3ed)

staging의 목적은 코드를 메인라인 품질로 끌어올려 졸업시키는 것이다. 그런데 Lustre 개발의 실제 중심은 Whamcloud/Intel의 `lustre-release` 트리였다. staging 사본은 정리 패치 위주로만 바뀌면서 out-of-tree 트리와 점점 멀어졌다. Greg은 그 상태를 "dual-tree"라고 진단하고, 개발자들이 out-of-tree에서 코드를 정비한 뒤 "real part of the kernel tree"로 다시 제출하라고 권했다. LWN의 2018-06-06 기사 "Will staging lose its Lustre?"(Jonathan Corbet)는 Andreas Dilger와 NeilBrown이 삭제에 반대했다고 전한다. Dilger는 사용자 규모와 그간의 개선을, NeilBrown은 한번 빠지면 다시 들어오기 어렵다는 점을 근거로 들었다. 결과적으로 삭제가 진행됐다.

### 3.2 2025년 LSFMM+BPF: 클라이언트만 먼저, 호환 코드는 분리

LWN의 2025-06-18 기사 "Getting Lustre upstream"(Jake Edge)은 LSFMM+BPF 2025 파일시스템 트랙에서 Timothy Day와 James Simmons가 진행한 세션을 다룬다. Simmons는 staging 시절을 이렇게 요약했다.

> "it got ejected, essentially due to insufficient progress"
> — James Simmons, LSFMM+BPF 2025 (LWN, 2025-06-18, [Getting Lustre upstream](https://lwn.net/Articles/1025268/))

기사에 따르면 staging 삭제 이후 upstream 준비 패치가 1,000개 넘게 들어갔고, 그중 약 600개는 NeilBrown, 200개는 Simmons의 것이다. 계획은 (1) 커널 버전 호환 코드를 코어 파일시스템 코드에서 분리하고, (2) 코어는 커널 트리로, 호환 코드는 Lustre 저장소에 남기는 것이다. 우선 대상은 상대적으로 변경이 적은 클라이언트다. 서버가 빠지는 이유는 Ted Ts'o의 지적에 담겨 있다.

> "pretty incestuous with ext4"
> — Ted Ts'o, LSFMM+BPF 2025 (LWN, 2025-06-18, [Getting Lustre upstream](https://lwn.net/Articles/1025268/))

서버가 ext4 심볼을 다수 요구하므로, jbd2를 buffer head 없이 다시 쓰는 것 같은 ext4 쪽 변경이 Lustre에 묶이게 된다는 뜻이다. Josef Bacik은 staging에서 정리 패치만 받던 운영 방식을 "that's like setting you up to fail"이라고 평했다. Christian Brauner는 새 파일시스템 병합이 "puts a burden on the whole community"라며 공동 결정 모델을 제안했다. Bacik은 Lustre가 folio를 전면적으로 쓰는 등 "all of the modern things"를 갖춰야 한다고 했다. Simmons가 folio 지원 후 large folio로 가는 계획을 밝히자, Matthew Wilcox는 page 기반 API 전환이 함께 진행된다면 괜찮다고 답했다. 그런 API가 점차 사라지고 있기 때문이다.

소스에서도 이 방향이 보인다. 2.17.0 태그에는 최상위 `lustre_compat/` 디렉터리(`lib/`, `kernel/sched`, `mm/shrinker_debug.c`, `mm/vmalloc.c` 등)가 처음 생겼다. 2.16.0 태그에는 이 디렉터리가 없다. master에서는 `fs/crypto`, `fs/debugfs`가 더해졌다. Jira에는 LU-12511 "Prepare lustre for adoption into the linux kernel"이 fixVersion `Upstream`, 상태 Open으로 남아 있다. 실제 메인라인 병합 시점은 정해지지 않았다. 클라이언트 병합 패치 시리즈가 메일링 리스트에 정식 제출되었는지는 1차 사료로 확인되지 않는다 `[추측/미확인]`.

### 3.3 OSD 백엔드: ldiskfs vs ZFS

Lustre 서버는 OSD(Object Storage Device) API(`dt_device_operations`, `dt_object_operations`, `dt_body_operations`)로 백엔드를 추상화한다. 백엔드는 `osd-ldiskfs`, `osd-zfs`, 그리고 2.17.0 태그부터 있는 `osd-wbcfs`("wbcFS OSD module", 소스 주석 기준) 세 가지다.

- **ldiskfs 진영의 근거**: 메타데이터 성능이 가장 높고 운영 경험이 길다. MDT는 대부분 ldiskfs로 배포된다고 알려져 있다 `[추측/미확인]`. 대가는 배포판 커널마다 ext4 패치 시리즈를 유지하는 것이다. master에는 RHEL 8.x/9.x, SLES, Ubuntu, openEuler용 `.series` 파일이 수십 개 있다.
- **ZFS 진영의 근거**: 체크섬·압축·스냅샷·RAID-Z/dRAID를 백엔드가 제공하므로 하드웨어 RAID 없이 JBOD로 OST를 만들 수 있다. 커널 패치가 필요 없다. `osd-zfs`는 DMU 트랜잭션(`dmu_tx_create`/`dmu_tx_assign`)과 SA(`sa_handle_get`)를 직접 호출한다. ZPL(POSIX 계층)을 거치지 않는다. ZFS DMU OSD(LU-1305)의 fixVersion은 2.3.0이다. 대신 메타데이터 집약 워크로드에서 ldiskfs보다 느리다는 평가가 일반적이다 `[추측/미확인]`. ZIO 파이프라인·ARC·TXG 동작은 (→ 10/02)를 참조한다.

### 3.4 강한 POSIX 일관성 vs 완화된 의미론

Lustre는 서로 다른 클라이언트의 `write()`/`read()` 사이에 POSIX 의미론을 지키기 위해 모든 캐시 데이터를 LDLM lock 아래 둔다. DAOS(→ 10/01)는 객체 API에서 epoch/트랜잭션 기반 일관성을 주고, POSIX(`dfuse`)에서는 캐시를 끄라고 권하는 방식으로 이 문제를 사용자에게 넘긴다. Lustre 개발자들은 대신 "락 비용이 클 때만 캐시를 포기한다"는 적응형 접근을 택해 왔다.

- **lockahead(LU-6179, 2.11)**: 사용자 공간이 `llapi_ladvise()`의 `LU_LADVISE_LOCKAHEAD`로 extent lock을 미리 요청한다. MPI-IO 라이브러리가 N-1 쓰기에서 rank별 구간 lock을 선점해 lock 교환을 없앤다.
- **Hybrid IO(LU-18033 "Hybrid IO on by default", 2.17)**: buffered I/O라도 크기가 임계값 이상이면 DIO 경로로 보낸다(4.3절).
- **서버 측 contention 계측(master)**: `ldlm_update_contention()`의 주석은 충돌로 인한 cancel이 곧 "other clients had to wait"인 상황이며 "a good idea to switch to DIO"라고 설명한다. 이 함수는 2.17.0 태그의 `ldlm_extent.c`에는 없다.

반대 측 논점은 DIO 전환이 읽기 재사용과 readahead 이점을 버린다는 것이다. 그래서 Hybrid IO는 임계값을 쓰기 2 MiB, 읽기 8 MiB로 다르게 두고, PCC attach 중인 파일은 전환에서 제외한다.

## 4. Implementation Impact

### 4.1 서버·클라이언트 모듈 스택

`lustre-release` master의 `lustre/` 디렉터리는 계층 구조를 그대로 보여 준다. wiki.lustre.org "Introduction to Lustre"는 MGS를 "stores configuration information for all the Lustre file systems in a cluster"라고 정의한다. 서버와 클라이언트는 기동 시 MGS에서 configuration log를 받는다.

| 역할 | 클라이언트 측 모듈 | 서버 측 모듈 | 비고 |
|---|---|---|---|
| VFS 접점 | `llite` (`ll_file_read_iter`, `ll_file_write_iter`, `ll_file_mmap`) | — | `struct ll_sb_info`, `struct ll_inode_info` |
| 메타데이터 분산 | `lmv` (`lmv_locate_tgt`) | `mdt` → `mdd` → `lod` → `osp`/OSD | LMV EA는 `trusted.lmv` |
| 메타데이터 RPC | `mdc` (`mdc_enqueue`, DoM I/O는 `mdc_io_init`) | `mdt` (`mdt_intent_policy`, `mdt_reint_open`) | intent lock으로 lookup+open을 한 RPC로 |
| 데이터 레이아웃 | `lov` (`lov_io_init_composite`, `lov_io_mirror_init`) | `lod` (레이아웃 생성·FLR·EC) | LOV EA는 `trusted.lov` |
| 데이터 RPC | `osc` (`osc_build_rpc`, `osc_brw_prep_request`) | `ofd` + `target` (`tgt_brw_read`/`tgt_brw_write`, `ofd_preprw`/`ofd_commitrw`) | bulk RDMA |
| 백엔드 | — | `osd-ldiskfs`, `osd-zfs`, `osd-wbcfs` | `dt_*_operations` |
| 락 | `ldlm` (클라이언트 namespace) | `ldlm` (서버 namespace) | `LDLM_EXTENT`/`LDLM_IBITS`/`LDLM_FLOCK`/`LDLM_PLAIN` |
| RPC | `ptlrpc` (`ptlrpcd_add_req`, `ptlrpc_queue_wait`) | `ptlrpc` 서비스 스레드, NRS/TBF | 재전송·복구(replay) |
| 네트워크 | `lnet` + LND | `lnet` + LND | NID 주소 체계 |

`osp`(Object Storage Proxy)는 MDT가 OST에 객체를 미리 만들어 두는 precreate(`osp_precreate_thread`)와 MDT 사이 원격 갱신을 담당한다. 그래서 파일 `open(O_CREAT)`은 MDT 하나와의 RPC로 끝나고 OST 객체는 미리 할당된 풀에서 꺼낸다.

### 4.2 LNet: LND, Multi-Rail, Health, 라우팅

LND 종류는 `include/uapi/linux/lnet/nidstr.h`의 네트워크 타입 열거형에서 확인된다.

| LND 타입 (`nidstr.h`) | 값 | 소스 디렉터리 | 대상 fabric | 소스 존재 확인 |
|---|---|---|---|---|
| `SOCKLND` | 2 | `lnet/klnds/socklnd` (`ksocknal_*`) | TCP/IP | 전 버전 |
| `O2IBLND` | 5 | `lnet/klnds/o2iblnd`, `in-kernel-o2iblnd` | IB, RoCE, OPA(verbs) | 전 버전. `in-kernel-o2iblnd`는 2.16.0 태그부터 |
| `GNILND` | 13 | `lnet/klnds/gnilnd` | Cray Gemini/Aries | MAINTAINERS에 HPE 리뷰어 |
| `PTL4LND` | 15 | (열거형만 정의) | Atos/Bull BXI Portals 4 | 소스 디렉터리 없음 |
| `KFILND` | 16 | `lnet/klnds/kfilnd` (`kfi_*` kfabric API) | HPE Slingshot 등 kfabric | `v2_15_0`에는 없고 `v2_16_0`부터 |
| `EFALND` | 18 | `lnet/klnds/efalnd` | AWS Elastic Fabric Adapter | `v2_17_0`부터 (LU-18977) |

`in-kernel-o2iblnd`는 외부 MOFED가 아니라 배포판 커널의 in-tree RDMA 스택에 맞춰 빌드하는 o2iblnd 변형이다. Makefile은 `o2iblnd/` 소스를 복사하면서 `HAVE_OFED_*` 매크로를 `IN_KERNEL_HAVE_OFED_*`로 바꾸고, Debian 패키지 설명은 "LNet on infiniband using the in-kernel provided driver"라고 적는다.

**Multi-Rail(LU-7734, 2.10)** 이후 LNet의 피어 표현은 `struct lnet_peer` → `struct lnet_peer_net` → `struct lnet_peer_ni`의 3단 구조다. 로컬 쪽은 `struct lnet_net` → `struct lnet_ni`다. 송신 경로 `lnet_send()` → `lnet_select_pathway()`는 로컬 NI와 피어 NI 쌍을 고른다. 기준은 NUMA 거리(`lnet_numa_range`), 크레딧, health 값, UDSP 규칙이다.

- **Network Health(LU-9120, 2.12)**: 전송 실패 시 NI의 health 값을 `lnet_health_sensitivity`(기본 100)만큼 깎는다. `lnet_recovery_interval` 주기로 복구 ping을 보낸다. 재전송 한도는 `lnet_retry_count`, 시간 제한은 `lnet_transaction_timeout` 모듈 파라미터로 조정한다.
- **UDSP(LU-9121, 2.15)**: "User Defined Selection Policy". 어떤 NID/네트워크를 우선할지 정책으로 지정한다(`lnet_udsp` 코드).
- **라우팅**: 라우터 노드는 두 LNet 네트워크(예: `o2ib0`, `tcp0`)에 동시에 NI를 가진다. 원격 네트워크는 `struct lnet_remotenet`, 경로는 `struct lnet_route`로 관리한다. 라우터 생존 확인은 LU-11300 "LNet: Router Aliveness and Health"(2.14)에서 health 체계로 통합됐다.
- **IPv6/large NID(LU-10391, 2.16)**: lustre.org 2.16.0 공지가 "Providing the option to use large NIDs"라고 소개한 기능이다.

### 4.3 레이아웃: striping → PFL → SEL/overstriping → DoM → FLR → EC

레이아웃 패턴 비트(`enum lov_pattern`, master)는 `LOV_PATTERN_RAID0`(0x001), `LOV_PATTERN_RAID1`(0x002), `LOV_PATTERN_PARITY`(0x004), `LOV_PATTERN_MDT`(0x100), `LOV_PATTERN_OVERSTRIPING`(0x200), `LOV_PATTERN_FOREIGN`(0x400), `LOV_PATTERN_COMPRESS`(0x800)다. composite layout은 `struct lov_comp_md_v1` 헤더 아래 `struct lov_comp_md_entry_v1` 배열을 둔다. 각 엔트리는 extent `[start, end)`와 `lcme_flags`를 가진다.

- **Striping 기본값 변화**: `LOV_DESC_STRIPE_SIZE_DEFAULT`는 `v2_15_0`에서 `(1 << LNET_MTU_BITS)` = 1 MiB였다. `v2_16_0`부터는 `(4 << LNET_MTU_BITS)` = 4 MiB다. 파일당 stripe 수 상한 `LOV_MAX_STRIPE_COUNT`는 2000이다.
- **PFL(LU-8998, 2.10)**: `lfs setstripe -E 64M -c 1 -E 1G -c 4 -E -1 -c -1`처럼 오프셋 구간마다 다른 stripe 정책을 준다. 아직 쓰이지 않은 component는 OST 객체가 없다. `LCME_FL_INIT`이 꺼져 있다. 클라이언트가 그 구간에 쓰면 layout intent RPC로 MDT에 instantiate를 요청하고 `ll_layout_refresh()`로 새 레이아웃을 받는다. 레이아웃 변경은 `MDS_INODELOCK_LAYOUT` bit lock의 cancel로 모든 클라이언트에 전파된다.
- **SEL(LU-10070, 2.13)과 overstriping(LU-9846, 2.13)**: `LCME_FL_EXTENSION` component는 OST가 가득 차면 다른 OST로 넘어가며 자라는 레이아웃이다. overstriping은 OST 하나에 stripe 여러 개를 둬 OST당 lock·객체 병렬성을 높인다. lustre.org 2.16.0 공지는 "avoid using Self-Extending Layouts in conjunction with 2.16 until LU-18416 is more fully understood"라고 경고했다.
- **DoM(LU-3285, 2.11)**: 첫 component의 패턴이 `LOV_PATTERN_MDT`이면 그 구간 데이터가 MDT에 저장된다. 클라이언트는 `mdc` 계층에서 DoM I/O를 수행한다. 데이터 보호용 bit는 `MDS_INODELOCK_DOM`(0x40)이다. 따라서 open+read를 MDT 한 곳에서 끝낼 수 있다. LOD의 `dom_stripesize`(최대값 기본 `lod_dom_stripesize_max_kb` = 1 MiB)와 MDT 여유 공간 기준 `dom_threshold_free_mb`가 DoM 할당을 제한한다. wiki의 Data on MDT 설계는 작은 파일은 MDT에, 커지면 "Progressive File Layouts to extend larger files onto OST objects"로 이어 붙인다고 적는다.
- **FLR(LU-9771 Phase 1, 2.11)**: 미러는 같은 extent를 덮는 component 집합이다. 파일 단위 상태는 `lcm_flags`의 `LCM_FL_RDONLY` → (쓰기 발생) `LCM_FL_WRITE_PENDING` → (`lfs mirror resync`) `LCM_FL_SYNC_PENDING` → `LCM_FL_RDONLY`다. Phase 1은 "Delayed Mirroring"이다. 쓰기는 하나의 primary 미러에만 반영되고, 나머지 미러는 `LCME_FL_STALE`이 붙어 있다가 resync로 복구된다. 읽기 선호는 `LCME_FL_PREF_RD`로 지정한다. 위키 설계 문서는 "the redundancy of a file is determined ... on a per-file basis at the Lustre client"를 핵심 결정으로 든다.
- **Erasure coding(master)**: LU-10911 "FLR2: Read only erasure coding"은 2026-10 현재 In Progress다. 소스에는 ISA-L 유래 `lustre/ec/` 모듈(`v2_16_0` 태그부터 존재), `LCME_FL_PARITY`, `lov_find_comp_with_ec()`가 있다. 주석이 "EC components are only used in FLR"이라고 밝히듯 FLR 미러 틀 위의 읽기 전용 EC다. 정식 릴리스 포함 여부는 미정이다 `[추측/미확인]`.

### 4.4 DNE: remote directory → striped directory → metadata overstriping

디렉터리 분산은 LMV 레이아웃(`struct lmv_mds_md_v1`)으로 표현한다. 이름 → MDT 매핑 해시는 `LMV_HASH_TYPE_ALL_CHARS`(1), `LMV_HASH_TYPE_FNV_1A_64`(2, 기본값), `LMV_HASH_TYPE_CRUSH`(3), `LMV_HASH_TYPE_CRUSH2`(4, LU-15692 수정판)다. CRUSH 계열은 주석상 "double-hash to optimize migration"이다. 디렉터리 migration 때 옮길 엔트리 수를 줄이려는 해시다.

| 단계 | Jira / fixVersion | 내용 |
|---|---|---|
| DNE1 remote directory | LU-1187 / 2.4.0 | 디렉터리 단위로 다른 MDT에 배치 |
| DNE2 striped directory | LU-3531 / 2.6.0, LU-3534 async update / 2.8.0 | 한 디렉터리를 여러 MDT shard로 해시 분산, MDT 간 분산 트랜잭션 |
| 파일시스템 기본 LMV | LU-14792 / 2.15.0 | 루트에 기본 striping 정책을 두고 상속 |
| non-recursive migration | LU-14975 / 2.15·2.16 변경 로그 | 디렉터리만 이동 |
| metadata overstriping | LU-12273 / 2.16.0 | MDT 하나에 shard 여러 개 |
| implicit default LMV inherit | LU-15971 / 2.16 변경 로그 | 기본 LMV 상속 규칙 |

### 4.5 클라이언트 I/O 경로 (master 기준)

buffered write의 대표 경로는 다음과 같다.

```text
write(2) → ll_file_write_iter()
  ├─ pcc_file_write_iter()            # PCC에 attach된 파일이면 로컬 캐시 FS로 처리 후 반환
  ├─ ll_hybrid_bio_dio_switch_check() # 조건 충족 시 iocb->ki_flags |= IOCB_DIRECT
  └─ ll_file_io_generic()
       └─ cl_io_loop()                # CLIO: vvp(llite) → lov → osc 계층 io 객체
            ├─ lov_io_iter_init()     # 레이아웃 component/stripe별 하위 io로 분할
            ├─ osc_lock_enqueue() → osc_enqueue_base() → ldlm_cli_enqueue()   # extent lock (PW)
            └─ osc_queue_async_io()   # 페이지를 osc_extent에 적재 (writeback 캐시)
  (writeback/flush 시)
  osc_io_submit() → osc_build_rpc() → osc_brw_prep_request()  # OST_WRITE + bulk 디스크립터
     → ptlrpcd_add_req() → ptlrpc → LNetGet/LNetPut → LND(kiblnd_send 등)
서버: tgt_brw_write() → ofd_preprw() → OSD dbo_* → ofd_commitrw()
```

- **CLIO 계층화**: `cl_io`, `cl_lock`, `cl_page`, `cl_object`가 계층마다 slice를 쌓는 구조다. `vvp`(llite), `lov`, `osc`가 각각 `*_io_init()`(`vvp_io_init`, `lov_io_init`, `osc_io_init`)로 자기 slice를 붙인다.
- **writeback 캐시 단위**: OSC는 페이지를 `struct osc_extent`로 묶는다. 하나의 extent는 하나의 lock 범위와 RPC 크기 안에 머문다. 클라이언트 전역 페이지 수는 `osc_lru_shrink()`/`osc_lru_reclaim()`로 제한된다.
- **Short I/O와 bulk**: 작은 요청은 RPC 본문에 데이터를 실어 보낸다(`cl_max_short_io_bytes`). 큰 요청은 별도 bulk 디스크립터로 RDMA한다(`ptlrpc_register_bulk`, 서버 `ptlrpc_start_bulk_transfer`).
- **DIO 경로**: `ll_direct_IO()` → `ll_direct_rw_pages()`. 비동기 DIO는 `ll_dio_aio`로 완료를 모은다. LU-13802 "New i/o path: Buffered i/o as DIO"(Open)와 LU-16964 "I/O Path: Auto switch from BIO to DIO"(Closed)가 Hybrid IO의 선행 설계 티켓이다.
- **Hybrid IO(2.17)**: `ll_hybrid_bio_dio_switch_check()`는 `LL_SBI_HYBRID_IO`가 켜져 있고, 이미 `IOCB_DIRECT`가 아니며, pipe가 아니고, PCC attach 중(`PCC_STATE_FL_ATTACHING`)이 아니면 크기를 본다. 기준은 `SBI_DEFAULT_HYBRID_IO_WRITE_THRESHOLD`(2 MiB)와 `SBI_DEFAULT_HYBRID_IO_READ_THRESHOLD`(8 MiB)이고, 넘으면 `iocb->ki_flags |= IOCB_DIRECT`로 바꾼다. 같은 값이 `v2_17_0` 태그에도 있다. 사용자 공간의 `f_flags`는 건드리지 않는다. 소스 주석도 그 이유를 "they're visible in userspace"라고 적는다.

### 4.6 LDLM: lock 수명 주기와 경합

`struct ldlm_lock`의 핵심 필드는 `l_req_mode`/`l_granted_mode`(`LCK_PR`, `LCK_PW`, `LCK_CR`, `LCK_EX` 등), `l_lru`(클라이언트 LRU), 세 콜백 `l_completion_ast`, `l_blocking_ast`, `l_glimpse_ast`다.

1. **enqueue**: 클라이언트 `ldlm_cli_enqueue()`가 요청한다. 서버 extent 정책 `ldlm_process_extent_lock()`은 충돌이 없으면 범위를 넓혀(`ldlm_extent_policy()` → `ldlm_extent_internal_policy_granted()`/`_waiting()`) 큰 lock을 준다. 순차 쓰기에서 lock 재요청을 줄이려는 것이다.
2. **conflict**: 다른 클라이언트가 겹치는 범위를 요청하면 서버가 기존 보유자에게 blocking AST를 보낸다. 클라이언트 `osc_ldlm_blocking_ast()`는 해당 범위의 더티 `osc_extent`를 flush하고 페이지를 버린 뒤 cancel한다. 이 왕복(AST → flush I/O → cancel RPC → 재grant)이 N-1 쓰기 성능 저하의 정체다.
3. **glimpse**: `stat()`이 파일 크기를 알기 위해 각 OST에 glimpse를 보내 lock을 회수하지 않고 크기만 묻는다. stripe가 많을수록 이 비용이 커진다. 작은 파일을 1 stripe나 DoM으로 두라는 권고의 근거다.
4. **LRU**: 클라이언트 namespace의 `lru_size`, `lru_max_age`와 동적 LRU resize(`lru_resize`)로 보유 lock 수를 조절한다.
5. **contention 계측(master)**: 서버 namespace는 `contention_seconds`, `ns_contended_locks`를 sysfs로 노출한다. `ldlm_update_contention()`은 리소스별 `lr_contention_hist` 히스토그램에 충돌 cancel을 누적하고, 임계 초과 시 `ns_contention_events`를 올린다.

메타데이터 쪽 `LDLM_IBITS`는 inode 하나를 비트로 쪼갠다. `MDS_INODELOCK_LOOKUP`(0x1), `UPDATE`(0x2), `OPEN`(0x4), `LAYOUT`(0x8), `PERM`(0x10), `XATTR`(0x20), `DOM`(0x40)다. 그래서 크기 갱신이 lookup 캐시를 무효화하지 않는다.

### 4.7 PCC(Persistent Client Cache)

LU-10092 "PCC: Lustre Persistent Client Cache"(fixVersion 2.13.0)는 클라이언트 로컬 NVMe 위 일반 파일시스템을 Lustre 파일의 캐시로 쓴다.

- **PCC-RW(`PCC_DATASET_PCCRW`)**: HSM 틀을 재사용한다. 파일을 PCC에 attach하면 Lustre 쪽은 HSM "released" 상태(`LOV_PATTERN_F_RELEASED`)가 되고 데이터는 로컬에만 있다. 다른 클라이언트가 접근하면 HSM restore로 Lustre에 되돌린다. 복사 도구는 `lhsmtool_posix`다. `llite/file.c`에서 `pcc_file_write_iter()`를 부르는 자리의 주석은 PCC 백엔드 공간 부족(`-ENOSPC`)으로 일반 경로로 되돌아가는 경우를 설명하며, 이때 "restore process will revoke the layout lock and detach the file from PCC cache automatically"라고 적는다.
- **PCC-RO(`PCC_DATASET_PCCRO`, 레이아웃 플래그 `LCM_FL_PCC_RDONLY`)**: 읽기 전용 캐시다. 여러 클라이언트가 동시에 같은 파일을 로컬 캐시할 수 있다. `pcc_readonly_attach()`는 `v2_15_0` 태그의 `pcc.c`에는 없고 `v2_16_0`에 있다. LU-15714 "Reserve layout intent flags for PCCRO"의 fixVersion도 2.16.0이다.
- **자동 attach**: `PCC_DATASET_OPEN_ATTACH`, `IO_ATTACH`, `STAT_ATTACH` 규칙(2.16에서 LU-13881로 `<`/`>` 비교 연산자 추가)으로 프로젝트 ID, UID, 파일 크기에 따라 자동 캐시한다.

### 4.8 GDS 통합 (→ 08/01)

LU-14798(2.15.0)의 결과물은 `lnet/lnet/lnet_rdma.c`다. `include/linux/lnet/lnet_rdma.h`가 `MODULE_PREFIX lustre_v1`과 `REGISTER_FUNC` 매크로를 정의하므로 export되는 심볼은 `lustre_v1_register_nvfs_dma_ops`다. 이 이름은 `nvidia-fs`의 `modules_list[]`와 일치한다. 등록된 `struct nvfs_dma_rw_ops`가 있으면 `lnet_rdma_map_sg_attrs()`가 `nvfs_dma_map_sg_attrs`로 GPU 페이지의 DMA 주소를 얻는다. `nvfs_device_priority`로 GPU와 HCA의 PCIe 근접도를 보고 NI를 고른다(`lnet_get_dev_prio`). OSC는 페이지에 `OBD_BRW_RDMA_ONLY`가 있으면 checksum과 short I/O를 끄고 bulk를 RDMA 전용(`bd_is_rdma`)으로 표시한다. o2iblnd에는 `is_p2p` 플래그로 GPU 등 P2P DMA 메모리를 bounce 버퍼 처리에서 구분하는 경로도 있다. GDS 쪽 동작과 upstream P2PDMA 논쟁은 (→ 08/01), (→ 08/02)를 참조한다.

### 4.9 릴리스·기능 연표

| 릴리스 | 날짜 (출처) | 이 문서 관련 주요 기능 (Jira fixVersion 또는 공지 기준) |
|---|---|---|
| 2.0.0 | 2010-07-15 (`lustre/ChangeLog`, "Oracle, Inc.") | 2.x 계열 시작 |
| 2.3.0 | — | ZFS DMU OSD (LU-1305) |
| 2.4.0 | — | DNE1 remote directory (LU-1187) |
| 2.8.0 | — | MDT 간 async update (LU-3534) |
| 2.10.0 | 2017-07-05 (ChangeLog, "Intel Corporation") | PFL (LU-8998), LNet Multi-Rail (LU-7734) |
| 2.11.0 | 2018-04-03 (ChangeLog, "Intel Corporation") | DoM (LU-3285), FLR Phase 1 (LU-9771), lockahead (LU-6179) |
| 2.12.0 | 2018-12-21 (ChangeLog, "Whamcloud") | LNet Network Health (LU-9120) |
| 2.13.0 | 2019-11-20 (ChangeLog) | PCC (LU-10092), SEL (LU-10070), overstriping (LU-9846) |
| 2.14.0 | 2021-02-20 (ChangeLog) | 클라이언트 데이터 암호화 (LU-12275), 라우터 health (LU-11300) |
| 2.15.0 | 2022-06-16 (wiki Release 2.15.0 일정) | 파일명 암호화 (LU-13717), UDSP (LU-9121), GDS (LU-14798), 파일시스템 기본 LMV (LU-14792). 공지: "Lustre 2.15.x will be the new LTS stream" |
| 2.15.8 | 2025-12-02 (wiki Release Information) | 현재 LTS 최신 |
| 2.16.0 | 2024-11-08 (ChangeLog, wiki) | IPv6/large NID (LU-10391), metadata overstriping (LU-12273), batched statahead (LU-14139), PCC-RO, 기본 stripe 4 MiB, `kfilnd` |
| 2.16.1 | lustre.org 공지 | LU-18435 단일 수정 re-spin, "This is not an LTS release" |
| 2.17.0 | 2025-12-29 (ChangeLog, wiki) | Hybrid IO 기본 활성 (LU-18033), Dynamic LNet NID 설정 (LU-18815), dynamic nodemap (LU-17431), AWS EFA LND (LU-18977), `lustre_compat/` 분리 |
| 2.18.0 | 개발 중 (master ChangeLog "TBD") | RHEL 10.x 서버 커널, master의 EC·contention 계측 등 |

2.17.0 변경 로그 페이지는 상호운용 대상을 "Latest 2.15.X, 2.16.1"로 적는다. LTS 클라이언트와 최신 서버를 섞는 운용이 공식 테스트 범위라는 뜻이다.

### 4.10 거버넌스와 개발 체계

- **조직 이력**: `lustre/ChangeLog`의 서명 주체가 이력을 보여 준다. 2002~2003년 Peter Braam, Andreas Dilger, Phil Schwan(`@clusterfs.com`), 2003~2007년 "Cluster File Systems, Inc.", 2010년 "Oracle, Inc."(2.0.0), 2017~2018년 "Intel Corporation"(2.10.0, 2.11.0), 2018-12-21(2.12.0) 이후 "Whamcloud"다. Sun의 CFS 인수(2007), Intel의 Whamcloud 인수(2012), DDN의 Intel Lustre 사업 인수(2018-06)는 이 전환과 시기가 맞는다 `[추측/미확인]`. 현재 Whamcloud는 DDN의 사업부다 `[추측/미확인]`.
- **커뮤니티**: lustre.org 사이트 하단 표기는 "© 2026 OpenSFS and EOFS"다. 미국 OpenSFS와 유럽 EOFS가 lustre.org, wiki.lustre.org, 릴리스 공지, LUG/LAD 행사를 운영한다. 코드 저장소(git.whamcloud.com `fs/lustre-release`), Gerrit 리뷰, Jira(jira.whamcloud.com), 테스트 인프라는 Whamcloud가 운영한다.
- **기여 구조**: `MAINTAINERS`에는 Whamcloud 외 기여자도 서브시스템 리뷰어로 올라 있다. HPE는 `gnilnd`, `kfilnd`, LNet 리뷰어, Amazon은 `efalnd` 리뷰어다. 클라우드 사업자(AWS FSx for Lustre)와 HPC 벤더가 각자 fabric의 LND를 upstream `lustre-release`에 넣는 구조다.
- **라이선스와 신규 구성요소**: master에는 `rustreapi/`(`lustreapi`의 Rust 바인딩, README "Rust-friendly, curated interface for `lustreapi`")가 생겼다. `v2_17_0` 태그에는 아직 없다.

### 4.11 Lustre vs DAOS vs Ceph

| 항목 | Lustre (2.17 / master) | DAOS (→ 10/01) | Ceph (RADOS + CephFS) |
|---|---|---|---|
| 1차 인터페이스 | 커널 POSIX 클라이언트 (`llite`) | 객체 API(`libdaos`), POSIX는 `libdfs`/`dfuse` 에뮬레이션 | 객체(RADOS), 블록(RBD), POSIX(CephFS, 커널/FUSE) |
| 데이터 배치 | MDT의 레이아웃 EA(`trusted.lov`)에 OST 객체 목록 저장 | 객체 클래스 + 해시로 target 계산 | CRUSH로 PG→OSD 계산, 중앙 조회 없음 |
| 메타데이터 | MDS/MDT, DNE로 수평 분산 | 메타데이터도 VOS 객체로 target에 분산 | CephFS MDS(동적 subtree 분할), RADOS 자체는 MDS 없음 |
| 일관성 | LDLM extent/ibits lock, 강한 POSIX | epoch/DTX 기반, POSIX 캐시는 사용자 선택 | CephFS capability(caps), RADOS는 PG primary 직렬화 |
| 서버 데이터패스 | 커널 모듈(`ofd`, OSD) + ldiskfs/ZFS | 사용자 공간 (SPDK, Argobots) | 사용자 공간 OSD (BlueStore, Crimson/Seastar → 06/04) |
| 네트워크 | LNet + LND (o2ib, socklnd, kfilnd, efalnd, gnilnd), 라우터 | CaRT/Mercury over libfabric/UCX | msgr v2, 기본 `async+posix`(TCP). `async+rdma`·`async+dpdk`·`async+smc`도 있으나 소스 옵션 설명상 "may be experimental" (→ 06/02) |
| 중복성 | 백엔드 RAID/ZFS + FLR 미러, EC는 개발 중 | 객체 클래스별 복제/EC | 복제·EC가 RADOS 기본 기능 |
| 커널 의존 | 클라이언트·서버 모두 out-of-tree 모듈 | 커널 거의 비의존 | 커널 클라이언트(`ceph.ko`, `rbd`)는 메인라인 |
| 강점 | 대규모 순차 I/O, 기존 HPC 앱 호환, 다중 fabric | 작은 I/O·메타데이터 IOPS, 낮은 지연 | 범용성, 자가 치유, 객체/블록/파일 통합 |
| 약점 | 작은 파일, 공유 파일 락 경합, 커널 추종 비용 | POSIX 의미론 완화, 생태계 규모 | HPC 대역폭·지연에서 열세, 운영 복잡성 |

### 4.12 운영 관점 요약

- **레이아웃 기본값을 파일시스템 수준 PFL로 두라**: 작은 구간은 DoM 또는 1 stripe, 큰 구간은 넓은 stripe로 설정한다. 2.16부터 기본 stripe 크기가 4 MiB로 바뀌었다. 업그레이드 후 명시적 기본 레이아웃이 없는 디렉터리에 새로 만드는 파일은 stripe 크기가 달라진다.
- **N-1 쓰기는 lock 경합 지표부터 본다**: 서버 namespace의 contention 통계, 클라이언트 `osc` RPC 히스토그램을 본다. 해법은 stripe 정렬, lockahead, 또는 2.17 Hybrid IO 임계값 조정이다.
- **LNet은 Multi-Rail과 health 파라미터를 같이 설계한다**: 소스 주석상 `lnet_health_sensitivity`는 송신 오류 한 번에 health 값을 깎는 양(기본 100)이다. 따라서 0으로 두면 실패가 health에 반영되지 않아 health 기반 경로 회피가 사실상 작동하지 않는다(정의에서 추론). 라우터가 있으면 라우터 health까지 고려한다.
- **GDS는 LNet 경로를 쓴다**: GPU와 HCA가 같은 PCIe 스위치 아래 있어야 `nvfs_device_priority` 기반 NI 선택이 의미가 있다.
- **커널 버전은 Support Matrix를 따른다**: 클라이언트·서버 모두 out-of-tree이므로 배포판 커널 업데이트가 Lustre 재빌드를 요구한다. DKMS 패키지(`lustre-dkms.spec.in`)가 제공된다.

## 5. Primary References

### 커널·LWN
- [staging: lustre: delete the filesystem from the tree. (commit be65f9ed267f)](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=be65f9ed267fd7d8b3146b7c4be9ecdd3e0aa3ed) — Greg Kroah-Hartman, 2018-06-01, 4.18-rc1에서 staging Lustre 삭제
- [Will staging lose its Lustre? [LWN.net]](https://lwn.net/Articles/756565/) — 2018-06-06, 삭제 제안과 Dilger·NeilBrown의 반론
- [Getting Lustre upstream [LWN.net]](https://lwn.net/Articles/1025268/) — 2025-06-18, LSFMM+BPF 2025 클라이언트 upstream 계획
- [Statistics from the 4.18 development cycle [LWN.net]](https://lwn.net/Articles/760690/) — 4.18 사이클의 Lustre 삭제 맥락

### Lustre 소스·이슈 트래커
- [Using Gerrit - Lustre Wiki](https://wiki.lustre.org/Using_Gerrit) — 원본 저장소 `fs/lustre-release`(git.whamcloud.com, 리뷰는 review.whamcloud.com Gerrit) 접근·패치 랜딩 절차. 본문에서 확인한 소스 파일: `lustre/ChangeLog`, `MAINTAINERS`, `include/uapi/linux/lustre/lustre_user.h`, `lustre/llite/file.c`, `lustre/ldlm/ldlm_extent.c`, `lnet/lnet/lnet_rdma.c`
- [[LU-14798] NVIDIA GPUDirect Storage Support](https://jira.whamcloud.com/browse/LU-14798) — fixVersion 2.15.0
- [[LU-18033] Hybrid IO on by default](https://jira.whamcloud.com/browse/LU-18033) — fixVersion 2.17.0
- [[LU-10092] PCC: Lustre Persistent Client Cache](https://jira.whamcloud.com/browse/LU-10092) — fixVersion 2.13.0
- [[LU-18977] Introduce AWS EFA LND](https://jira.whamcloud.com/browse/LU-18977) — fixVersion 2.17.0
- [[LU-12511] Prepare lustre for adoption into the linux kernel](https://jira.whamcloud.com/browse/LU-12511) — fixVersion Upstream, Open
- [[LU-10911] FLR2: Read only erasure coding](https://jira.whamcloud.com/browse/LU-10911) — In Progress

### wiki.lustre.org·lustre.org
- [Lustre Release Information - Lustre Wiki](https://wiki.lustre.org/Lustre_Release_Information) — Current LTS 2.15.8, Current Major 2.17.0
- [Release 2.15.0 - Lustre Wiki](https://wiki.lustre.org/Release_2.15.0) — 2.15.0 일정
- [Release 2.16.0 - Lustre Wiki](https://wiki.lustre.org/Release_2.16.0) — 2.16.0 일정(2024-11-08)
- [Release 2.17.0 - Lustre Wiki](https://wiki.lustre.org/Release_2.17.0) — 2.17.0 범위
- [Lustre 2.16.0 Changelog - Lustre Wiki](https://wiki.lustre.org/Lustre_2.16.0_Changelog) — New Feature 목록
- [Lustre 2.17.0 Changelog - Lustre Wiki](https://wiki.lustre.org/Lustre_2.17.0_Changelog) — New Feature 목록, 상호운용 범위
- [Introduction to Lustre - Lustre Wiki](https://wiki.lustre.org/Introduction_to_Lustre) — MGS/MDS/OSS 구성 요소
- [Understanding Lustre Internals - Lustre Wiki](https://wiki.lustre.org/Understanding_Lustre_Internals) — 클라이언트·서버 모듈 내부
- [Progressive File Layouts - Lustre Wiki](https://wiki.lustre.org/Progressive_File_Layouts) — PFL
- [Layout Enhancement High Level Design - Lustre Wiki](https://wiki.lustre.org/Layout_Enhancement) — composite layout 설계
- [Data on MDT - Lustre Wiki](https://wiki.lustre.org/Data_on_MDT) — DoM 문제 정의와 범위
- [File Level Redundancy Solution Architecture - Lustre Wiki](https://wiki.lustre.org/File_Level_Redundancy_Solution_Architecture) — FLR 단계별 설계
- [Multi-Rail LNet - Lustre Wiki](https://wiki.lustre.org/Multi-Rail_LNet) — Multi-Rail 설계
- [ZFS OSD - Lustre Wiki](https://wiki.lustre.org/ZFS_OSD) — ZFS 백엔드
- [Lustre 2.15.0 released | Lustre](https://www.lustre.org/lustre-2-15-0-released/) — "Lustre 2.15.x will be the new LTS stream"
- [Lustre 2.16.0 released | Lustre](https://www.lustre.org/lustre-2-16-0-released/) — IPv6, SEL 경고(LU-18416)
- [Lustre 2.16.1 released | Lustre](https://www.lustre.org/lustre-2-16-1-released/) — "This is not an LTS release"
- [Lustre 2.17.0 released | Lustre](https://www.lustre.org/lustre-2-17-0-released/) — Hybrid IO, Dynamic LNet NID, nodemap
- [About the Lustre® File System | Lustre](https://www.lustre.org/about/) — OpenSFS·EOFS 운영
- [Lustre* Software Release 2.x Operations Manual](https://doc.lustre.org/lustre_manual.xhtml) — 운영 매뉴얼(`lfs setstripe`, DoM, FLR, PCC, LNet 설정)
