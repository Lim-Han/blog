# DAOS 아키텍처 심층 분석: Argobots xstream, SPDK Blob I/O, PMDK에서 MD-on-SSD로의 전환

> 기준 버전: DAOS `master` 브랜치(2026-10 확인) 및 릴리스 v2.4.0(2023-09-22), v2.6.0(2024-07-26), v2.8.0(2026-08-12). 함수·구조체·상수 이름은 `github.com/daos-stack/daos` 소스에서 직접 확인했다. 확인하지 못한 항목은 `[추측/미확인]`으로 표시한다.

## 1. Verdict

DAOS(Distributed Asynchronous Object Storage)는 "커널을 데이터패스에서 완전히 걷어낸다"는 목표를 끝까지 밀어붙인 오픈소스 스토리지 스택이다. 서버 쪽 I/O 엔진(`daos_engine`)은 Argobots 사용자 수준 스레드(ULT) 위에서 동작하고, NVMe는 SPDK 사용자 공간 드라이버와 blobstore로, 메타데이터는 원래 PMDK `libpmemobj`로 관리하는 Optane PMem 위에 두었다. 네트워크는 Mercury RPC를 감싼 CaRT 계층이 libfabric(OFI) 또는 UCX로 RDMA를 수행한다. 공식 아키텍처 문서는 이를 "End-to-End (E2E) in user space with full OS bypass"라고 표현한다.

이 문서의 결론은 세 가지다.

1. **Shared-nothing target 모델이 DAOS 성능의 핵심이다.** 엔진 하나의 저장장치는 여러 *target*으로 정적으로 나뉘고, target마다 전용 xstream(CPU 코어에 고정), 전용 SPDK I/O channel, 전용 네트워크 컨텍스트, 전용 VOS 풀 샤드를 가진다. 그래서 데이터패스에 락 경합이 거의 없다. VEA(Versioned Extent Allocator) README가 "scalable concurrency isn't a design cosideration for VEA"(원문 철자 그대로)라고 적은 것도 같은 이유다.
2. **PMem 의존은 DAOS의 가장 큰 기술 부채였고, MD-on-SSD로 해소되었다.** Intel이 Optane 사업을 정리한 뒤(2022년 `[추측/미확인: 정확한 발표일은 1차 사료로 확인하지 않음]`) DAOS는 메타데이터를 DRAM에 캐시하고 NVMe 위 WAL(Write-Ahead Log)로 영속화하는 Metadata-on-SSD 경로를 만들었다. 이 경로는 v2.4에서 Technology Preview, v2.6에서 Phase 1 production-ready가 되었고, v2.8에서 Phase 2(bucket-memory allocator v2)가 신규 MD-on-SSD 풀의 기본 할당기가 되었다. 릴리스 노트로 확인했다.
3. **거버넌스가 단일 벤더에서 재단으로 옮겨갔다.** DAOS는 Intel 주도 프로젝트였으나, Linux Foundation 보도자료(2023-11-09)에 따르면 Argonne National Laboratory, Enakta Labs, Google Cloud, HPE, Intel을 창립 멤버로 DAOS Foundation이 출범했고 Intel은 DAOS 소스 코드를 재단에 기증하기로 했다("Intel Corporation will donate the DAOS source code to the DAOS Foundation"). 현재 저장소 README의 마지막 문장도 "DAOS is a Linux Foundation project."이다.

Lustre나 Ceph와 비교하면, DAOS는 POSIX를 1차 인터페이스로 삼지 않는다. key-array-value 객체 모델을 네이티브 API로 두고, POSIX는 그 위의 에뮬레이션 계층(`libdfs`, `dfuse`, 인터셉션 라이브러리)으로 제공한다. 이 선택 덕분에 정렬되지 않은 작은 I/O와 대량 메타데이터 연산에서 강하다. 대신 커널 VFS와 통합되는 정도는 Lustre보다 약하다.

---

## 2. Problem Statement

### 2.1 블록 기반·회전 매체 중심 스토리지 스택의 한계

DAOS 아키텍처 문서는 기존 스토리지 스택이 "primarily designed for rotating media"라고 진단하고, DAOS가 "fine-grained data access"를 기본으로 지원한다고 설명한다. HPC 병렬 파일시스템은 대개 OSD 백엔드 블록 파일시스템(ldiskfs, ZFS, XFS) 위에 서버 데몬을 얹는다. 이 구조에서 생기는 문제는 다음과 같다.

- **Read-modify-write와 정렬 제약**: 4 KiB 블록 경계에 맞지 않는 작은 쓰기는 블록 단위 RMW를 일으킨다. DAOS 문서는 "No read-modify-write operations are performed internally. Write operations are non-destructive and not sensitive to alignment."라고 명시한다. 모든 쓰기를 epoch이 붙은 새 버전으로 로그처럼 쌓기 때문에 가능하다.
- **커널 경계 비용**: 시스템 콜, 인터럽트, 페이지 캐시 복사, 블록 계층(`blk-mq`)의 태그 할당과 스케줄러 경로가 마이크로초 단위 NVMe·RDMA 지연에 비해 크다. SPDK가 이 비용을 polled-mode 사용자 공간 드라이버로 없앤다. DAOS의 BIO README는 SPDK 사용 이유로 "eliminating all syscalls and enabling zero-copy access"를 든다.
- **메타데이터 병목**: 수십만 클라이언트가 동시에 파일을 만들거나 stat하는 HPC 체크포인트·AI 학습 데이터셋 워크로드에서는 중앙 메타데이터 서버(Lustre MDS)가 병목이 된다. DAOS는 메타데이터와 데이터를 같은 target에 분산하고, 풀 수준 메타데이터만 Raft로 복제되는 소수의 *pool service* 노드에 둔다.

### 2.2 PMem 의존성이라는 구조적 리스크

초기 DAOS 설계는 SCM(Storage Class Memory), 사실상 Intel Optane PMem을 전제로 했다. VOS(Versioning Object Store) README는 "The VOS relies on a log-based architecture using persistent memory primarily to maintain internal persistent metadata indexes."라고 적는다. 인덱스 트리(B+tree, extent tree)를 PMem에 두고 load/store로 바로 갱신하며, 원자성은 PMDK `libpmemobj`의 undo log 트랜잭션으로 보장했다.

이 설계에는 두 가지 위험이 있었다.

1. **하드웨어 단종**: Optane이 단종되면서 새 서버에는 PMem을 넣을 수 없게 되었다. PMem 없이 DAOS를 배포할 방법이 필요해졌다.
2. **용량 결합**: 메타데이터 용량이 PMem 용량으로 제한되었다. 객체 수가 수십억 개 규모(`Container: 10^9 Objects`, 스토리지 모델 문서의 목표치)로 늘면 PMem 크기가 클러스터 설계를 결정하게 된다.

### 2.3 POSIX 호환성과 성능의 긴장

HPC 애플리케이션 대부분은 POSIX I/O로 작성되어 있다. 그런데 사용자 공간 객체 저장소에 POSIX를 얹는 가장 쉬운 방법인 FUSE는 요청마다 커널과 사용자 공간을 오가는 컨텍스트 스위치와 복사 비용이 든다. DAOS 파일시스템 문서도 dfuse만 쓰면 DFS API보다 훨씬 느릴 수 있다고 설명하고, 이 비용을 줄이려고 인터셉션 라이브러리를 제공한다.

---

## 3. The Debate

DAOS 설계 논쟁은 LKML 같은 공개 메일링 리스트보다 DAOS 사용자 그룹(DUG) 발표, Jira, 설계 문서, 릴리스 노트에서 주로 드러난다. 아래에는 1차 문서로 확인한 사실과 그로부터 추론할 수 있는 트레이드오프를 나눠 적는다. 개발자 발언 원문은 확인하지 못했으므로 인용 블록은 공식 문서 문구만 사용한다.

### 3.1 "PMem이 있어야 DAOS인가": MD-on-SSD 논쟁

Optane 단종 뒤 DAOS가 택할 수 있는 길은 크게 세 가지였다 `[추측/미확인: 아래 대안 분류는 공식 문서에 명시된 비교가 아니라 분석자의 정리]`.

| 대안 | 내용 | 장점 | 단점 |
|---|---|---|---|
| A. CXL 메모리 등 차세대 영속 메모리를 기다린다 | VOS 구조 유지 | 코드 변경 최소 | 하드웨어 일정이 불확실하고 현재 배포 불가 |
| B. 메타데이터를 RocksDB 같은 외부 KV에 위임 | Ceph BlueStore 방식 | 검증된 엔진 | VOS의 epoch/MVCC 인덱스 의미론과 맞지 않고 이중 로깅 |
| C. VOS 인덱스를 DRAM에 두고 NVMe WAL + checkpoint로 영속화 | MD-on-SSD (채택) | VOS 코드 대부분 재사용 | DRAM 용량 요구, WAL 장치 내구성 부담, 재시작 시 replay 시간 |

DAOS는 C를 택했다. 핵심 아이디어는 PMDK 트랜잭션이 하던 일, 즉 "메모리 내 자료구조 갱신의 원자적 영속화"를 **blob 기반 메모리(BMEM) + WAL**로 바꾸는 것이다. 이 변화는 `src/include/daos/mem.h`의 메모리 백엔드 열거형에 그대로 남아 있다.

```c
/* src/include/daos/mem.h (master 기준, DAOS_PMEM_BUILD 블록 내) */
DAOS_MD_PMEM    = 0,   /* 기존: PMDK pmemobj on PMem */
DAOS_MD_BMEM    = 1,   /* MD-on-SSD Phase 1: blob-backed memory */
DAOS_MD_ADMEM   = 2,   /* ad-hoc allocator 기반 백엔드 (src/common/ad_mem.c) */
DAOS_MD_BMEM_V2 = 3,   /* MD-on-SSD Phase 2: bucket allocator v2 */
```

v2.6 릴리스 노트는 Phase 1을 다음과 같이 설명한다 (2024-07-26 릴리스, [Release Notes v2.6](https://docs.daos.io/v2.6/release/release_notes/)).

> "DAOS Version 2.6 includes the production-ready version of Metadata-on-SSD (Phase1) that supports DAOS servers without Persistent Memory. In this configuration mode, application metadata is stored on SSD and cached in DRAM. It is persisted to a Write Ahead Log (WAL) on write and eventually flushed back to SSD by a background service."

정리하면 메타데이터는 SSD에 저장되고 DRAM에 캐시되며, 쓰기 시점에 WAL로 영속화된 뒤 백그라운드 서비스가 SSD로 flush(checkpoint)한다. v2.4에서는 같은 경로가 "Metadata-on-SSD (Phase1) code path (Technology Preview)"로 표기되어 있었다.

v2.8(2026-08-12) 릴리스 노트는 Phase 2에 대해 bucket-memory allocator v2가 production ready이며 신규 MD-on-SSD 풀의 기본 메타데이터 할당기라고 밝힌다. 다만 기본값은 `--mem-ratio 100%`, 즉 **메타데이터 전체를 DRAM에 상주**시키는 것이다. 메타데이터 일부만 DRAM에 두는 eviction(`--mem-ratio 25%` 등)은 Technology Preview다. DRAM보다 큰 메타데이터를 다루는 문제는 아직 완전히 풀리지 않았다는 뜻이다.

**트레이드오프 해설**: PMem 모드에서는 쓰기 하나가 PMem에 대한 캐시라인 flush와 fence로 끝났다. MD-on-SSD에서는 같은 갱신이 DRAM 변경 → WAL 블록 직렬화 → NVMe 쓰기 완료 대기로 바뀐다. 커밋 지연이 PMem의 sub-µs 수준에서 NVMe 쓰기 지연(수~수십 µs) 수준으로 늘어난다 `[추측/미확인: 구체 수치는 공식 벤치마크로 확인하지 않음]`. 대신 WAL은 순차 append라서 배치 커밋이 쉽다. 그래서 `bdev_roles`로 WAL 전용 고내구성 SSD를 따로 두는 구성을 문서가 권장한다.

### 3.2 user-space 전면 우회 vs 커널 통합

DAOS는 서버 쪽에서 커널 블록 계층, 파일시스템, 소켓 스택을 모두 우회한다. 이 선택에는 대가가 있다.

- **찬성 논거**: SPDK polled-mode로 인터럽트·컨텍스트 스위치가 없어지고, target당 코어 고정으로 캐시 지역성이 좋아지며, RDMA로 클라이언트 버퍼와 서버 DMA 버퍼 사이 zero-copy가 가능하다.
- **반대 논거**: NVMe 장치를 커널에서 떼어 `vfio-pci`나 `uio`에 바인딩해야 하므로 운영 도구(`nvme-cli`, `smartctl`, 커널 I/O 통계)를 그대로 쓸 수 없다. 그래서 DAOS는 장치 상태 모니터링, 장애 SSD eviction, 핫플러그, VMD LED 제어를 BIO 모듈 안에 직접 구현했다(BIO README의 Device Health Monitoring, Faulty Device Detection, NVMe SSD Hot Plug 절). 커널이 해주던 일을 다시 만든 셈이다. BIO README에는 "Full hot plug capability when using non-Intel-VMD devices is to be supported in DAOS 2.8 release"라는 문구가 남아 있다. 핫플러그는 오랫동안 Intel VMD에 묶여 있었다.

이 논쟁은 SPDK 대 `io_uring` passthrough 논쟁(→ 03/02)과 같은 구조다. DAOS는 SPDK 쪽 극단에 있는 대표 사례다.

### 3.3 POSIX 제공 방식: dfuse, libioil, libpil4dfs

DAOS의 POSIX 계층은 세 단계로 발전했다.

1. **`libdfs` (DFS API)**: `dfs_mount()`, `dfs_open()`, `dfs_read()`, `dfs_write()`, `dfs_readdir()` 같은 사용자 공간 POSIX 유사 API(`src/include/daos_fs.h`). 디렉터리는 엔트리 이름을 dkey로 쓰는 DAOS 객체이고, 정규 파일은 DAOS array 객체다(셀 크기 1바이트, 기본 chunk 1 MB. `src/client/dfs/README.md`).
2. **`dfuse`**: libfuse로 DFS를 마운트한다. 커널 페이지 캐시, dentry 캐시를 쓸 수 있다는 장점이 있지만 FUSE 왕복 비용이 든다. `src/client/dfuse/IO_PATHS_DESIGN.md`에는 pre-read, 128 KiB 정렬 읽기 coalescing(chunk read) 같은 fast path가 정리되어 있다.
3. **인터셉션 라이브러리**: `LD_PRELOAD`로 libc 호출을 가로챈다.
   - `libioil`: 데이터 I/O(read/write 계열)만 가로채고 메타데이터 연산은 dfuse로 보낸다.
   - `libpil4dfs`: 데이터와 메타데이터를 모두 가로챈다. v2.4에서 Technology Preview, v2.6에서 production이 되었다. v2.6 릴리스 노트는 "The libpil4dfs library intercepts I/O and metadata related functions (unlike it's counterpart libioil that intercepts only IO functions)"라고 설명한다. 소스는 `src/client/dfuse/pil4dfs/`(`hook.c`, `int_dfs.c`, `aio.c`, `dfs_dcache.c`)에 있다.

**논점**: 인터셉션 라이브러리는 커널을 거치지 않으므로 빠르다. 하지만 정적 링크 바이너리, 직접 `syscall()`을 부르는 코드, 가로채지 못한 libc 함수를 쓰는 경로는 놓친다. 파일시스템 문서는 인터셉션 라이브러리로 쓴 데이터와 dfuse 커널 캐시가 어긋날 수 있다고 경고한다. 예를 들어 I/O가 인터셉션 라이브러리를 통하면 dfuse가 이미 열린 핸들의 캐시를 갱신하지 않는다. v2.8 릴리스 노트에 `libpil4dfs`가 `creat`, `renameat`, `fdatasync`, `dup3`, `utimensat` 등의 인터셉션을 추가하거나 고쳤다는 항목이 계속 나오는 것도 "모든 POSIX 진입점을 다 덮는 일"이 끝나지 않는 작업이라는 증거다.

### 3.4 거버넌스: 단일 벤더 프로젝트의 지속 가능성

Intel 주도 시기 DAOS의 로드맵은 Optane과 Intel Xeon 플랫폼에 강하게 묶여 있었다(VMD 의존 핫플러그, PMem 전제 VOS). DAOS Foundation 출범(2023-11-09, Linux Foundation 보도자료)으로 Google Cloud(Parallelstore), HPE, Argonne(Aurora) 같은 사용자가 거버넌스에 참여하게 되었다. 이후 기술적으로 눈에 띄는 변화는 다음과 같다.

- v2.8 지원 매트릭스는 "ofi+cxi on HPE Slingshot fabrics", "UCX support on NVIDIA InfiniBand and RoCE fabrics: ucx+dc_x is the recommended UCX provider"를 명시한다. 벤더 중립 패브릭 지원이 강화되었다.
- 서버 지원 문구도 "DAOS Servers without Intel Optane Persistent Memory, using the production Metadata-on-SSD Phase2 code path"가 맨 앞에 온다. PMem은 이제 레거시 경로다.

---

## 4. Implementation Impact

### 4.1 엔진 스레드 모델: Argobots xstream과 ULT

`src/engine/README.md`는 엔진을 "a multi-threaded process using Argobots for non-blocking processing"로 정의한다. Argobots의 `ABT_xstream`은 OS 스레드(코어에 고정), `ABT_thread`는 그 위에서 협력적으로 스케줄되는 ULT다.

`src/include/daos_srv/daos_engine.h`의 `enum dss_xs_type`은 xstream 역할을 다음과 같이 나눈다(master 기준).

| `dss_xs_type` | 값 | 역할 (소스 주석) |
|---|---|---|
| `DSS_XS_SELF` | -1 | 현재 xstream |
| `DSS_XS_VOS` | 0 | "operations need to access VOS" (target main xstream) |
| `DSS_XS_IOFW` | 1 | "forward/dispatch IO request for TX coordinator" |
| `DSS_XS_OFFLOAD` | 2 | "EC/checksum/compress computing offload" |
| `DSS_XS_SYS` | 3 | "pool service, RDB, drpc handler" |
| `DSS_XS_SWIM` | 4 | SWIM 멤버십 프로토콜 |
| `DSS_XS_DRPC` | 5 | dRPC 리스너 |

`src/engine/srv.c`의 주요 흐름은 다음과 같다.

```
dss_xstreams_init()
  └─ dss_start_one_xstream(cpus, tag, xs_id)     # hwloc cpuset으로 코어 고정
       └─ ABT_xstream_create_with_rank(dx->dx_sched, ...)
            └─ dss_srv_handler(arg)               # xstream마다 실행되는 메인 ULT
                 ├─ crt_context_create(&dmi->dmi_ctx)  # target 전용 CaRT 네트워크 컨텍스트
                 ├─ bio_xsctxt_alloc(&dmi->dmi_nvme_ctxt, ...)   # target 전용 SPDK thread + blobstore channel
                 ├─ ABT_thread_create(dx->dx_pools[DSS_POOL_NVME_POLL], dss_nvme_poll_ult, ...)
                 │     └─ bio_nvme_poll(dmi->dmi_nvme_ctxt) → spdk_thread_poll()
                 └─ loop: crt_progress(dmi->dmi_ctx, dx->dx_timeout)  # 네트워크 완료·수신 처리
```

xstream마다 private TLS(`dss_tls_get()`, `dss_module_key_get()`)가 있고, 스케줄러(`src/engine/sched.c`)는 요청을 `SCHED_REQ_UPDATE`, `SCHED_REQ_FETCH`, `SCHED_REQ_GC`, `SCHED_REQ_SCRUB`, `SCHED_REQ_MIGRATE` 클래스로 나눠 throttling한다. 이 구조는 OpenZFS `vdev_queue`의 I/O 클래스(sync read/write, async, scrub)와 비슷한 역할을 사용자 공간 ULT 스케줄러 안에서 한다(→ 10/02, 4.2절).

**락킹 모델**: 한 target의 VOS 풀 샤드는 그 target의 main xstream만 접근한다. 같은 xstream 안의 ULT들은 협력적으로 스케줄되므로 yield 지점 사이 코드는 사실상 원자적이다. 그래서 VOS 인덱스 트리 갱신에 별도 뮤텍스가 필요 없다. 대신 ULT가 블로킹 시스템 콜을 부르면 그 코어 전체가 멈춘다. 체크섬·EC 같은 CPU 집약 작업을 `DSS_XS_OFFLOAD`로 넘기는 이유가 여기에 있다.

### 4.2 BIO: SPDK blobstore 통합

`src/bio/README.md`가 설명하는 SPDK 통합 방식은 다음과 같다.

- NVMe SSD마다 SPDK blobstore를 만들고, VOS 풀의 target 샤드마다 SPDK blob을 할당한다. BIO README는 "SPDK blobs are created and attached to each per-xstream VOS pool"이라고 적는다. 매핑 정보는 SMD(Per-Server Metadata) 테이블(NVMe Device Table, NVMe Pool Table)에 저장된다.
- xstream마다 SPDK thread(`spdk_thread_create()`)와 blobstore I/O channel(`spdk_bs_alloc_io_channel()`)을 가진다. NVMe completion poller는 서버 polling ULT 안에서 돈다.
- SPDK blobstore는 blob 단위가 크다. SPDK Blobstore 문서는 blob이 cluster("typically 1MiB in size, or 256 pages") 단위로 구성된다고 설명하고, BIO README도 "Blobs are designed to be large (at least hundreds of KB)"라고 적는다. 그래서 작은 블록 할당은 DAOS 자체 할당기 VEA가 맡는다.
- 실제 I/O는 `src/bio/bio_buffer.c`에서 `spdk_blob_io_write()` / `spdk_blob_io_read()`로, TRIM은 `src/bio/bio_context.c`의 `spdk_blob_io_unmap()`으로 내려간다.
- **DMA 버퍼**: xstream마다 SPDK 메모리 API로 할당한 DMA-safe 버퍼가 있고 필요하면 커진다. BIO README는 "client data will be RDMA transferred to this buffer first, then the SPDK blob I/O interface will be called"라고 적는다. NVMe 데이터 경로에서는 RDMA → DMA 버퍼 → NVMe DMA로 데이터가 흐르며, CPU memcpy가 없다.

장치 역할 분담도 있다. 첫 VOS xstream인 *Init Xstream*은 SPDK bdev 초기화와 핫플러그 poller를 맡고, blobstore를 처음 연 *Device Owner Xstream*은 장치 상태와 health 데이터를 관리한다. 비소유 xstream은 이벤트를 owner에게 전달한다. 장치 상태 감시 주기는 60초이고, FAULTY 전이 뒤에는 10초로 줄어든다(BIO README).

### 4.3 VOS와 VEA: epoch 기반 버전 인덱스와 "delayed atomicity"

VOS는 target 로컬 객체 저장소다. 객체는 `dkey → akey → value`의 2단 키 구조를 가진다. value는 single value(SV)이거나 array extent(EV)다. 같은 dkey 아래 엔트리는 같은 target에 함께 배치된다는 보장이 있다(스토리지 모델 문서).

- SV 인덱스: B+tree 계열(`btree`, `svt_rec_store` / `svt_rec_load`)
- EV 인덱스: extent-epoch R-tree 계열 `evtree`(`src/vos/evtree.c`, `evt_insert`, `evt_fill_entry`)
- incarnation log: `ilog`(`src/vos/ilog.c`) — punch/생성 이력
- 체크섬 경로(VOS README "Checksum VOS Flow"):
  - SV Update: `vos_update_end → akey_update_single → svt_rec_store`
  - EV Update: `vos_update_end → akey_update_recx → evt_insert`
  - EV Fetch: `vos_fetch_begin → akey_fetch_recx → evt_fill_entry`

**매체 선택 정책**: `src/vos/vos_internal.h`의 `vos_io_scm()`은 VEA가 없거나(`vp_vea_info == NULL`, 즉 NVMe가 없는 풀), 데이터 임계값이 0이거나, I/O 크기가 `pool->vp_data_thresh`보다 작으면 SCM(메타데이터 메모리)에 저장한다. 그 밖에는 NVMe에 저장한다. 기본 임계값은 `src/include/daos_prop.h`의 `DAOS_PROP_PO_DATA_THRESH_DEFAULT (1UL << 12)`, 즉 4 KiB이며 풀 속성 `DAOS_PROP_PO_DATA_THRESH`로 바꿀 수 있다. 아키텍처 문서의 "latency-sensitive I/Os, like application metadata and byte-granular data"는 SCM으로, 대용량 데이터는 NVMe로 간다는 설명이 코드에서는 이 한 함수로 구현된다.

**Delayed atomicity** (`src/vea/README.md`):

1. 갱신할 공간을 예약하고 그 예약을 DRAM에만 임시로 기록한다(`vea_reserve()`).
2. RDMA로 클라이언트 데이터를 예약 공간에 내려받는다.
3. 단일 메타데이터 트랜잭션 안에서 예약을 영속 할당으로 바꾸고(`vea_tx_publish()`) VOS 인덱스를 갱신한다.

README는 이 방식의 장점을 "the atomicity of allocation and index updating can be guaranteed without an undo log to revert the actions in first step"이라고 설명한다. 데이터 전송 중 크래시가 나면 DRAM 예약만 사라지므로 되돌릴 것이 없다. VEA는 컨테이너당 두 I/O stream(일반 갱신, 백그라운드 aggregation)을 구분해 hint를 주고, stream별로 연속 할당을 유지해 외부 단편화를 줄인다.

### 4.4 서버 쓰기 경로 콜패스 (master 기준)

`src/object/srv_obj.c`와 `src/vos/vos_io.c`로 확인한 update 경로는 다음과 같다.

```
[client] daos_obj_update() / dfs_write()
   → CaRT crt_req_send() → Mercury HG_Forward()
     (대용량 payload는 crt_bulk_create() → HG_Bulk_create()로 RDMA 노출)

[server, target xstream ULT]
ds_obj_rw_handler(crt_rpc_t *rpc)
  ├─ obj_ioc_begin()                       # 풀/컨테이너 핸들, pool map 버전 검증
  ├─ dtx_leader_begin(...)                 # 복제/EC 객체: DTX 리더로서 분산 트랜잭션 시작
  └─ obj_local_rw() → obj_local_rw_internal()
        ├─ vos_update_begin(coh, oid, epoch, ...)   # vos_io.c
        │     └─ vos_reserve_single()/recx → vos_io_scm() 로 SCM/NVMe 선택
        │           └─ (NVMe) vea_reserve()          # DRAM 임시 예약
        ├─ bio_iod_prep(biod, BIO_CHK_TYPE_IO, rpc->cr_ctx, CRT_BULK_RW)
        │                                            # DMA 버퍼 매핑 및 bulk 등록
        ├─ obj_bulk_transfer() → crt_bulk_transfer() # RDMA GET: client → server
        │     (inline RPC 경우: bio_iod_copy())
        ├─ bio_iod_post_async(biod, rc)              # NVMe: spdk_blob_io_write()
        └─ vos_update_end(ioh, map_ver, dkey, rc, ...)
              ├─ vos_tx_end() → vos_publish_blocks() → vea_tx_publish()
              └─ (MD-on-SSD) umem WAL tx → bio_wal_commit()   # bio_wal.c
  → obj_rw_reply()
```

MD-on-SSD에서 메타데이터 영속성을 맡는 `src/bio/bio_wal.c`의 주요 함수는 다음과 같다.

- `bio_wal_reserve()`: WAL 트랜잭션 ID(seq/off로 구성된 `tx_id`) 예약. WAL 공간이 부족하면 대기자를 재운다(`wakeup_reserve_waiters()`).
- `bio_wal_commit()`: `umem_wal_tx`의 redo action들을 WAL 블록(`wal_trans_blk`)에 직렬화하고(`fill_trans_blks()`), 데이터 체크섬을 만든 뒤(`generate_data_csum()`) NVMe에 쓴다. 완료는 `wal_completion()` → `wal_tx_completion()`에서 순서대로 처리한다.
- `bio_wal_checkpoint()`: 메타데이터 blob(`meta` role)로 flush가 끝난 지점까지 WAL을 purge한다.
- `bio_wal_replay()`: 재시작 시 `load_wal()` → `verify_tx()` → `replay_tx()`로 WAL을 재적용한다.

### 4.5 MD-on-SSD 장치 역할 구성

`daos_server.yml`의 NVMe tier에 `bdev_roles`(`wal`, `meta`, `data`)를 지정해야 MD-on-SSD 경로가 켜진다. 각 역할은 정확히 하나의 tier에 배정되어야 한다. 또 PMem 모드에서 PMem에 두던 control-plane 메타데이터를 둘 `control_metadata:path` 또는 `control_metadata:device`가 필요하다([System Deployment - DAOS v2.6](https://docs.daos.io/v2.6/admin/deployment/)).

| 구성 | tier 1 | tier 2 | tier 3 | 문서상 근거·특성 |
|---|---|---|---|---|
| 1-tier | wal+meta+data (4 SSD) | - | - | 가장 단순 |
| 2-tier (A) | wal (1 SSD) | meta+data (3 SSD) | - | "higher endurance and higher performance SSD for the wal tier" |
| 2-tier (B) | wal+meta (1 SSD) | meta+data … | - | data SSD 내구성이 낮을 때 대안 |
| 2-tier (C) | wal+data | meta | - | **invalid** — "Sharing wal and data roles on the same tier is not" 허용 |
| 3-tier | wal (1) | meta (1) | data (2) | 역할 완전 분리 |

### 4.6 네트워크: CaRT/Mercury와 RDMA

`src/cart/`는 Mercury 위의 집합 통신·그룹 관리 계층이다. `crt_hg.c`는 `HG_Create`, `HG_Forward`, `HG_Respond`, `HG_Bulk_create` 같은 Mercury API를 감싸고, `crt_swim.c`는 SWIM 기반 장애 감지를, `crt_iv.c`는 IV(incast variable) 트리 전파를, `crt_corpc.c`는 집합 RPC를 구현한다. Mercury의 NA 플러그인은 libfabric(OFI) provider(`ofi+tcp`, `ofi+verbs`, `ofi+cxi`)나 UCX(`ucx+dc_x`)를 쓴다. v2.6.5 릴리스 노트(2026-06-05)에는 OFI multi-receive 활성화와 Mercury libfabric 플러그인의 별도 `mercury-libfabric` RPM 분리가 기록되어 있다.

아키텍처 문서에 따르면 읽기 요청이 오면 서버는 영속 인덱스를 따라가며 "a complex scatter-gather Remote Direct Memory Access (RDMA) descriptor"를 만들고, 요청한 버전의 데이터를 애플리케이션 버퍼에 바로 재구성한다. 버전마다 흩어진 extent를 서버가 한 번의 RDMA 디스크립터로 모아 보내는 구조다.

### 4.7 데이터 모델과 배치

- **Pool**: UUID, 버전이 붙은 *pool map*(장애 도메인 트리 포함), Raft로 복제되는 pool service(`src/rdb/rdb_raft.c`). target이 장애로 빠지면 *rebuild*가 온라인으로 중복도를 복구한다. v2.6부터는 *delayed rebuild*(관리자가 다음 풀 작업을 할 때까지 rebuild 보류)가 지원된다.
- **Container**: 트랜잭션·스냅샷 단위, 객체 주소 공간.
- **Object**: object class로 중복도와 stripe을 정한다. 소스에 정의된 예시 클래스는 `OC_S1`, `OC_SX`, `OC_RP_2G1`, `OC_RP_3GX`, `OC_EC_4P2GX`, `OC_EC_8P2GX`이다. 배치는 `src/placement/jump_map.c`의 jump consistent hash 기반 알고리즘이 맡는다.
- **Epoch/트랜잭션**: 모든 I/O에 HLC(Hybrid Logical Clock) 기반 epoch이 붙는다. 복제 객체 갱신은 DTX(`src/dtx/`) 2단계 커밋으로 일관성을 보장한다(VOS README "Single redundancy group based DAOS Two-Phase Commit (DTX)").

### 4.8 Lustre / Ceph와의 비교

| 비교 항목 | DAOS (v2.8) | Lustre | Ceph (RADOS + BlueStore) |
|---|---|---|---|
| 서버 데이터패스 | 사용자 공간, SPDK polled NVMe, 커널 블록 계층 우회 | 커널 모듈(OSS/OST), ldiskfs 또는 ZFS 백엔드 | 사용자 공간 OSD, BlueStore가 raw block device에 `libaio`/`io_uring` 등으로 I/O |
| 메타데이터 | target별 분산 VOS 인덱스(메모리 + WAL/PMem), pool service만 Raft | 전용 MDS/MDT(DNE로 다중 MDT 분산) | 객체 메타데이터는 OSD별 RocksDB(BlueFS 위), 파일시스템 메타데이터는 CephFS MDS |
| 쓰기 원자성 | VEA delayed atomicity + umem tx (PMDK undo log 또는 WAL redo) | 백엔드 FS 저널(ldiskfs jbd2 / ZFS TXG) | BlueStore 메타데이터는 RocksDB WAL, 큰 쓰기는 COW 후 KV 커밋 |
| 정렬/RMW | 정렬 무관, RMW 없음(버전 로그) | 페이지/블록 정렬 영향 | 작은 쓰기는 deferred write(RocksDB 경유 후 반영) 경로 사용 가능 |
| 클라이언트 | libdaos 사용자 공간 + dfuse/인터셉션 | 커널 클라이언트(llite), POSIX 완전 | librados, RBD(커널/사용자), CephFS 커널/FUSE |
| 네트워크 | Mercury/CaRT, libfabric·UCX RDMA | LNet (o2ib, tcp, kfi 등) | Messenger v2 (TCP 중심, RDMA 실험적) |
| 장치 관리 | BIO가 health/eviction/hotplug 자체 구현 | 커널·외부 도구 | 커널 장치, ceph-volume |
| 하드웨어 의존 역사 | Optane PMem → MD-on-SSD | 범용 | 범용 |

Lustre와 Ceph 쪽 항목은 이 문서에서 해당 프로젝트 소스를 다시 검증하지 않은 일반 설명이다. BlueStore 세부는 (→ 06/03)과 (→ 10/03)을 참조한다.

### 4.9 기능 도입 연표 (공식 릴리스 노트 기준)

| 릴리스 | 날짜 | I/O 관련 변화 |
|---|---|---|
| v2.4.0 | 2023-09-22 | MD-on-SSD Phase 1 Technology Preview, `libpil4dfs` Technology Preview, EC parity rotation. 번들 SPDK 22.01.2(2.4.1 기준) |
| v2.6.0 | 2024-07-26 | MD-on-SSD Phase 1 production-ready, `libpil4dfs` production, delayed rebuild, PMDK 2.0.0 |
| v2.6.5 | 2026-06-05 | Libfabric 1.22.0-5, Mercury 2.4.1, PMDK 2.1.3, OFI multi-receive 활성화 |
| v2.8.0 | 2026-08-12 | MD-on-SSD Phase 2(allocator v2) 기본값, metadata eviction은 tech preview, SPDK 26.01, Argobots 1.2 |

### 4.10 운영 관점 요약

- **target 수 설계**: 아키텍처 문서는 "the number of targets of an engine should be an integer multiple of the number of NVMe drives"를 권장한다. target이 장애 단위이자 성능 단위이므로 코어 수, SSD 수, NUMA를 함께 맞춰야 한다.
- **DRAM 사이징**: MD-on-SSD Phase 2 기본값(`--mem-ratio 100%`)에서는 메타데이터 전체가 DRAM에 상주한다. PMem 용량 계획이 DRAM 용량 계획으로 바뀐 셈이다.
- **WAL 장치 내구성**: WAL은 모든 메타데이터 갱신을 받으므로 DWPD가 높은 SSD를 `wal` tier로 분리하는 구성이 문서 예제로 제시되어 있다.
- **FUSE vs 인터셉션**: 캐시 일관성 요구가 큰 병렬 애플리케이션에서는 dfuse 캐싱을 끄라는 경고(`--disable-caching`)가 문서에 있다. 인터셉션 라이브러리를 쓸 때의 캐시 상호작용도 함께 확인해야 한다.

---

## 5. Primary References

- [DAOS 저장소 README (github.com/daos-stack/daos)](https://github.com/daos-stack/daos) — "DAOS is a Linux Foundation project." 문구, 라이선스
- [daos-stack/daos — src/engine/README.md (DAOS Data Plane, aka daos_engine)](https://github.com/daos-stack/daos/blob/master/src/engine/README.md) — Argobots xstream, TLS, dRPC
- [daos-stack/daos — src/bio/README.md (Blob I/O)](https://github.com/daos-stack/daos/blob/master/src/bio/README.md) — SPDK blobstore 통합, DMA 버퍼, 장치 상태 관리
- [daos-stack/daos — src/vos/README.md (Versioning Object Store)](https://github.com/daos-stack/daos/blob/master/src/vos/README.md) — VOS 인덱스, MVCC, 체크섬 경로, DTX
- [daos-stack/daos — src/vea/README.md (Versioned Block Allocator)](https://github.com/daos-stack/daos/blob/master/src/vea/README.md) — delayed atomicity, I/O stream hint
- [daos-stack/daos — src/bio/bio_wal.c](https://github.com/daos-stack/daos/blob/master/src/bio/bio_wal.c) — MD-on-SSD WAL commit/replay/checkpoint
- [daos-stack/daos — src/object/srv_obj.c](https://github.com/daos-stack/daos/blob/master/src/object/srv_obj.c) — `ds_obj_rw_handler`, `obj_local_rw`, bulk transfer
- [daos-stack/daos — src/client/dfuse/IO_PATHS_DESIGN.md](https://github.com/daos-stack/daos/blob/master/src/client/dfuse/IO_PATHS_DESIGN.md) — dfuse read/write 경로
- [Architecture - DAOS v2.6](https://docs.daos.io/v2.6/overview/architecture/)
- [Storage Model - DAOS v2.6](https://docs.daos.io/v2.6/overview/storage/)
- [System Deployment - DAOS v2.6](https://docs.daos.io/v2.6/admin/deployment/) — MD-on-SSD `bdev_roles`
- [File System - DAOS v2.6](https://docs.daos.io/v2.6/user/filesystem/) — dfuse, `libioil`, `libpil4dfs`, 캐싱
- [Release Notes v2.4 - DAOS v2.4](https://docs.daos.io/v2.4/release/release_notes/)
- [Release Notes v2.6 - DAOS v2.6](https://docs.daos.io/v2.6/release/release_notes/)
- [Release Notes v2.8 - DAOS v2.8](https://docs.daos.io/latest/release/release_notes/)
- [SPDK: Blobstore Programmer's Guide](https://spdk.io/doc/blob.html) — blob/cluster 개념
