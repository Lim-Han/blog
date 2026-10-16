# Classic OSD의 스레딩 한계와 Crimson·Seastar·SeaStore 아키텍처

> 기준: `github.com/ceph/ceph` `main`(2026-10 확인), 릴리스 태그 v17.2.0(Quincy), v18.2.0(Reef), v19.2.0(Squid), v20.2.0(Tentacle), 그리고 `main`이 참조하는 `ceph/seastar` 서브모듈 커밋 `cced0236ee`. Crimson의 성숙도는 docs.ceph.com 릴리스 노트(Squid, Tentacle)와 ceph.io 블로그 "A Crimson colored Tentacle"(2025-04-21, Matan Breizman, Yingxin Cheng)로 확인했다. 확인하지 못한 항목은 `[추측/미확인]`으로 표시한다.

## 1. Verdict

Classic OSD는 pthread 기반 다단계 파이프라인이다. 메신저 워커가 메시지를 받고, `ShardedOpWQ`가 PG 해시로 고른 `OSDShard`의 큐에 넣고, 샤드 전용 워커 스레드가 `PG::lock()`(내부 `ceph::mutex _lock`)을 잡고 op를 실행하며, BlueStore는 다시 자체 `kv_sync_thread`/`kv_finalize_thread`와 aio 완료 스레드, finisher를 거친다. 이 구조는 HDD 시대에는 충분했지만 NVMe에서는 I/O당 스레드 전환·락·캐시 이동 비용이 장치 지연과 같은 규모가 되어 코어당 처리량이 CPU에 묶인다. 이것이 Crimson 프로젝트의 출발점이다.

Crimson OSD(`crimson-osd`)는 Seastar 프레임워크 위에 OSD를 다시 쓴 것이다. 코어마다 reactor 스레드 하나가 돌고, PG는 `PGShardMapping`으로 특정 코어에 배정되며, 비동기 처리는 future/continuation과 C++20 코루틴으로 표현된다. 저장 백엔드는 세 가지다. BlueStore를 별도 pthread 풀에서 돌리는 AlienStore, Seastar 네이티브 엔진 SeaStore, 테스트용 CyanStore다.

그러나 "SeaStore가 ZNS/FDP에 `io_uring`/`io_uring_cmd`로 직접 디스패치해 코어당 10만+ IOPS를 달성하는 비전을 완성했다"는 식의 결론은 근거가 없다. 확인된 상태는 다음과 같다.

- **성숙도**: Squid(v19) 릴리스 노트는 "Crimson's first tech preview release! Supporting RBD workloads on Replicated pools."라고 적는다. Tentacle(v20) 릴리스 노트는 "SeaStore Tech Preview: SeaStore object store is now deployable alongside Crimson-OSD, mainly for early testing and experimentation."라고 적는다. 즉 Tentacle 시점에 Crimson과 SeaStore는 둘 다 tech preview이며, 프로덕션 기본은 여전히 Classic OSD + BlueStore다.
- **I/O 경로**: SeaStore의 블록 I/O는 `seastar::file`의 `dma_read`/`dma_write`를 통해 Seastar reactor 백엔드로 나간다. `main`의 `crimson/os/seastore` 아래에서 `io_uring_cmd`나 NVMe passthrough I/O 경로는 찾지 못했다. `NVMeBlockDevice`가 `linux/nvme_ioctl.h`를 포함하지만, 이는 identify 등 admin 명령과 기능 탐지(멀티스트림, 체크섬 오프로드)에 쓰이고 데이터 I/O는 `dma_write`다. Crimson이 `IORING_OP_URING_CMD`를 쓴다는 주장은 `[추측/미확인]`이 아니라 현재 코드에 대해서는 사실이 아니다.
- **reactor 백엔드**: Ceph의 Seastar 서브모듈에서 `reactor_backend_selector::available()`의 순서는 `io_uring`(빌드 시 `SEASTAR_HAVE_URING`이고 런타임에 탐지되면) → `asymmetric_io_uring` → `linux-aio`(aio-nr이 충분하고 aio poll 지원 시) → `epoll`이며, 기본값은 이 목록의 첫 항목이다. Ceph는 `WITH_LIBURING`(기본 ON)일 때 `Seastar_IO_URING`을 켠다. 따라서 "SeaStore의 기본 I/O는 linux-aio"라는 서술은 현재 `main` 빌드에는 정확하지 않다. 커널과 빌드 설정에 따라 io_uring이 기본일 수 있다. 운영자는 `crimson_reactor_backend`(`io_uring`/`linux-aio`/`epoll`, 미설정 시 Seastar가 선택)로 강제할 수 있다. 과거 릴리스의 Seastar가 같은 순서였는지는 확인하지 않았다 `[추측/미확인: Squid 이전 서브모듈의 기본 백엔드]`.
- **ZNS/FDP**: SeaStore에는 `segment_manager/zbd.cc`(zoned block device, `BLKRESETZONE`/`BLKFINISHZONE` ioctl)가 있어 ZNS 계열 장치를 세그먼트 백엔드로 쓸 수 있고, RBM의 `NVMeBlockDevice`에는 write-life hint 기반 멀티스트림 코드가 있다. 그러나 "ZNS/FDP 완벽 지원"을 보여 주는 릴리스 노트나 문서는 찾지 못했다. FDP 지원은 `[추측/미확인]`이다.

## 2. Problem Statement

### 2.1 Classic OSD의 op 경로

`main` 기준 클라이언트 쓰기 op의 Classic OSD 경로는 다음과 같다.

```
AsyncMessenger Worker (EventCenter 스레드)
  └─ ProtocolV2::handle_message() → DispatchQueue::fast_dispatch()
       └─ OSD::ms_fast_dispatch(Message*)
            └─ OSD::enqueue_op(spg_t, OpRequestRef&&, epoch)
                 └─ op_shardedwq.queue(OpSchedulerItem)        // ShardedOpWQ
                      └─ OSD::ShardedOpWQ::_enqueue():
                           shard_index = pgid.hash_to_shard(num_shards)
                           OSDShard::shard_lock 아래 scheduler(mClock)에 enqueue
[osd_op_tp: ShardedThreadPool 워커, 샤드마다 osd_op_num_threads_per_shard개]
  └─ OSD::ShardedOpWQ::_process(thread_index, shard_index, hb)
       └─ scheduler dequeue → OSDShardPGSlot에서 PG 찾기 → pg->lock()
            └─ PGOpItem::run() → OSD::dequeue_op() → PrimaryLogPG::do_request()
                 └─ do_op() → execute_ctx() → issue_repop()        // 복제 전송 + 로컬 트랜잭션
                      └─ ObjectStore::queue_transactions() → BlueStore (kv_sync_thread 등)
```

`ShardedOpWQ`는 "거대한 공유 큐"가 아니라 샤딩된 구조다. `OSD::num_shards`개의 `OSDShard`가 있고, 각 샤드는 자기 `shard_lock`과 `OpSchedulerRef scheduler`를 가진다. 샤드 수와 스레드 수 기본값은 다음과 같다(`osd.yaml.in`).

| 옵션 | v17.2.0 ~ v19.2.0 (Reef v18.2.4까지) | v20.2.0 (Tentacle), main (백포트: Reef v18.2.5+, Squid v19.2.1+) |
|---|---|---|
| `osd_op_num_shards_ssd` × `osd_op_num_threads_per_shard_ssd` | 8 × 2 | 8 × 2 |
| `osd_op_num_shards_hdd` × `osd_op_num_threads_per_shard_hdd` | 5 × 1 | 1 × 5 |
| `osd_op_queue` | `mclock_scheduler` | `mclock_scheduler` |

HDD 기본값 변경은 PR #58509("common/options: Change HDD OSD shard configuration defaults for mClock", 2024-09 머지)에서 왔다. PR 본문에 따르면 HDD 대규모 클러스터 시험에서 여러 OSD 샤드(즉 샤드별로 독립된 mClock 큐)로는 다중 노드 장애 시 클라이언트 처리량이 시험마다 들쭉날쭉하고 slow request가 많았던 반면, 샤드 하나에 워커 여러 개를 두면 클라이언트·복구 처리량이 일관되었다(Tracker #66289). PR은 이 변경을 "interim measure"라고 부른다. 샤딩은 락 경합을 줄이지만, 샤드마다 스케줄러가 따로 돌면 OSD 전체 QoS 판단이 쪼개진다는 트레이드오프를 보여 주는 사례다. `osd_op_num_shards`/`osd_op_num_threads_per_shard`가 0이 아니면 이 값들을 덮어쓴다.

### 2.2 비용이 생기는 지점

- **스레드 전환**: 메신저 워커 → 샤드 워커 → BlueStore aio 완료 → `kv_sync_thread` → `kv_finalize_thread` → finisher/완료 콜백 → 메신저 워커(응답 송신). 한 op가 여러 스레드를 거치며, 각 전환에는 큐 락과 조건 변수 깨우기가 따른다.
- **락**: `OSDShard::shard_lock`, `PG::_lock`, BlueStore `OpSequencer::qlock`, kv 큐 락 등. PG 락은 같은 PG의 op를 직렬화하므로 PG 수가 적거나 핫 객체가 있으면 경합이 커진다.
- **캐시 이동**: op 객체와 버퍼가 코어 사이를 오가며 캐시 라인이 이동한다.

"컨텍스트 스위치당 2~4µs", "코어당 5,000~10,000 IOPS" 같은 수치가 흔히 인용되지만 1차 사료를 찾지 못했으므로 이 문서는 정량 수치를 제시하지 않는다. Crimson 블로그와 릴리스 노트도 Classic 대비 정량 배수를 공식 수치로 제시하지 않는다.

## 3. The Debate

아래는 릴리스 노트, ceph.io 블로그, PR 본문, 소스 주석으로 확인한 쟁점이다.

### 3.1 점진적 개선 vs 재작성

Classic OSD 쪽에서도 개선은 계속되었다. `ShardedOpWQ` 샤딩, fast dispatch, mClock 스케줄러, BlueStore의 kv 스레드 분리 등이다. 그러나 이 개선들은 "스레드 사이에서 일을 넘기는" 구조 자체를 바꾸지 않는다. Crimson은 반대로 OSD 전체를 Seastar의 shared-nothing 모델로 옮기는 재작성을 택했다. 대가는 막대하다. 피어링, 복구, 백필, 스냅샷, EC, 스크럽, 관리 명령을 모두 다시 구현해야 하며, 그래서 Squid의 첫 tech preview는 "RBD workloads on Replicated pools"로 범위가 좁았다. `main`에는 이제 `crimson/osd/ec_backend.cc`가 있지만, EC가 어느 릴리스에서 지원 범위에 들어가는지는 릴리스 노트로 확인하지 못했다 `[추측/미확인: Crimson EC 지원 릴리스]`.

공유 코드를 두 모델에서 같이 쓰는 문제도 있다. Tentacle 블로그는 다음과 같이 적는다.

> "For example, Crimson does not require mutexes due to its lockless shard-nothing design, so ceph::mutex is overridden to use a "dummy_mutex" under the hood."
>
> — Matan Breizman, Yingxin Cheng, "A Crimson colored Tentacle", ceph.io (2025-04-21)

해설: Classic과 Crimson은 `src/common`, `src/osd`의 일부 타입(PG 로그, OSDMap, 메시지)을 공유한다. Crimson 빌드에서는 `ceph::mutex`를 더미로 바꿔 락 비용을 없애지만, 이는 해당 코드가 한 샤드 안에서만 접근된다는 전제가 지켜질 때만 안전하다. 같은 글은 `WITH_SEASTAR`와 `WITH_ALIENSTORE` 매크로를 `WITH_CRIMSON` 하나로 통합했다고 적는다.

### 3.2 AlienStore: 성숙한 BlueStore를 쓰는 대가

AlienStore(`crimson/os/alienstore/alien_store.h`의 `class AlienStore final : public FuturizedStore`)는 BlueStore를 Seastar 밖의 POSIX 스레드 풀(`crimson::os::ThreadPool`, `std::vector<std::thread> threads`)에서 돌리고, reactor는 `submit()`으로 작업을 넘긴 뒤 future로 결과를 받는다. 스레드 수와 CPU는 `crimson_bluestore_num_threads`(기본 6), `crimson_bluestore_cpu_set`으로 조정한다. 장점은 검증된 BlueStore의 온디스크 포맷과 기능을 그대로 쓴다는 것이다. 단점은 Classic OSD에서 제거하려던 바로 그 비용, 즉 스레드 경계 횡단과 BlueStore 내부의 락·`kv_sync_thread` 직렬화가 다시 들어온다는 것이다. 따라서 AlienStore는 Crimson OSD 계층을 먼저 성숙시키기 위한 과도 경로로 쓰였다.

### 3.3 SeaStore: 세그먼트 기반 vs 랜덤 블록

SeaStore는 Seastar 위에서 처음부터 설계한 트랜잭션 저장소다. 데이터와 메타데이터를 익스텐트 단위로 관리하고, 모든 변경을 저널(델타)과 익스텐트 쓰기로 기록한다. 백엔드를 어떻게 둘지가 중요한 쟁점이었다.

- **세그먼트(SEGMENTED)**: 장치를 큰 세그먼트로 나눠 로그 구조로 순차 기록하고, `AsyncCleaner`의 구현인 `SegmentCleaner`가 GC를 한다(RBM은 `RBMCleaner`). 저널은 `SegmentedJournal`. ZBD(`segment_manager/zbd.cc`)처럼 순차 쓰기를 강제하는 장치에 자연스럽다. 대가는 GC 쓰기 증폭과 클리너 튜닝(`seastore_segment_cleaner_gc_formula`, `_gc_autotune`)이다.
- **랜덤 블록(RANDOM_BLOCK, RBM)**: 랜덤 쓰기가 빠른 NVMe SSD에서 제자리 갱신을 허용한다. `random_block_manager/block_rb_manager.cc`, AVL 할당자(`avlallocator.cc`), 원형 저널 `CircularBoundedJournal`(`seastore_cbjournal_size`)을 쓴다. Tentacle 블로그는 "SeaStore aims to support various storage mediums, particularly those capable of random writes without significantly sacrificing bandwidth. This allows SeaStore to avoid sequential writes"라고 설명한다.

기본값은 바뀌는 중이다. Tentacle v20.2.0의 `seastore_main_device_type` 기본값은 `SSD`(세그먼트)이고 대안이 `RANDOM_BLOCK_SSD`다. `main`에서는 옵션이 캐시/데이터 계층으로 나뉘어 `seastore_cache_backend_type` 기본 `SEGMENTED`, `seastore_data_backend_type` 기본 `RANDOM_BLOCK`, `seastore_data_device_type`은 `HDD`/`SSD`/`ZBD` 중 기본 `SSD`다. 이 변경이 다음 릴리스에서 어떤 형태로 나올지는 `[추측/미확인]`이다.

### 3.4 PG를 코어에 배정하는 방식

Crimson은 PG를 코어에 영구 배정한다. `PGShardMapping` 주석은 "Maintains a mapping from spg_t to the core containing that PG. Internally, each core has a local copy of the mapping to enable core-local lookups. Updates are proxied to core 0"라고 적는다. 매핑 변경은 core 0을 거쳐 전파되므로 조회는 코어 로컬이지만 생성·변경은 직렬화된다. 메신저 측에서는 연결의 I/O 샤드가 소켓 위치로 정해지므로(PR #51916, → 06/02), 연결 샤드와 PG 샤드가 다르면 코어 간 전달이 생긴다. SeaStore도 reactor 수에 맞춰 내부를 나누며 `seastore_require_partition_count_match_reactor_count`(기본 `true`)는 재시작 시 샤드 구성이 바뀌지 않도록 강제한다. 즉 Crimson OSD의 코어 수는 배포 후 쉽게 바꿀 수 있는 값이 아니다.

### 3.5 QoS: mClock을 다시 구현하기

Classic OSD는 Quincy(v17.2.0)부터 `osd_op_queue=mclock_scheduler`가 기본이다(Pacific v16.2.0은 `wpq`). Crimson은 이를 따라잡는 중이다. Tentacle 블로그는 복구 op 스로틀러를 "the initial step towards fully supporting the Mclock scheduler used by the Classical OSD"라고 부르고, `main`에는 PR #69017("crimson/osd: Apply mClock scheduler throttle to client operations", 2026-08-10 머지)이 들어갔다. 클라이언트 op까지 mClock 스로틀이 적용된 것은 Tentacle 이후다.

## 4. Implementation Impact

### 4.1 Crimson OSD의 쓰기 경로 (main 기준, 단순화)

```
[reactor shard X: 연결의 I/O 샤드]
crimson::net::IOHandler → Dispatcher
  └─ OSD::ms_dispatch(crimson::net::ConnectionRef, MessageRef)
       └─ OSD::handle_osd_op(...)
            └─ pg_shard_manager.start_pg_operation<ClientRequest>(...)
                 // PGShardMapping으로 PG의 코어 Y를 찾고, X != Y면 Seastar smp 메시지로 이동
[reactor shard Y: PG 소유 코어]
  └─ ClientRequest::with_pg_process() → process_op() → do_process()
       // 파이프라인 단계(stage)와 obc(object context) 잠금은 future 기반, mutex 아님
       └─ PG::submit_executer() → PG::submit_transaction()
            └─ ReplicatedBackend::submit_transaction()
                 ├─ shard_services.send_to_osd(...)       // 복제본 OSD로 MOSDRepOp
                 └─ crimson::os::with_store_do_transaction(shard_services.get_store(...), ...)
                      //   → FuturizedStore::Shard::do_transaction_no_callbacks()
                      ├─ SeaStore::Shard → _do_transaction_step() 루프
                      │    └─ TransactionManager::submit_transaction(Transaction&)
                      │         ├─ ExtentPlacementManager: 새 익스텐트를 어느 장치/계층에 쓸지 결정
                      │         ├─ LBAManager(btree_lba_manager): 논리 주소 → 물리 주소 매핑 갱신
                      │         ├─ Journal(SegmentedJournal | CircularBoundedJournal)에 레코드 제출
                      │         └─ Device(SegmentManager | RBMDevice) → seastar::file::dma_write()
                      │               → reactor 백엔드(io_uring | linux-aio | epoll)
                      └─ AlienStore 경로일 때: ThreadPool::submit() → BlueStore::queue_transactions()
```

Crimson의 동시성 원칙은 "같은 코어 안에서는 락 대신 future 순서로 직렬화"다. 그렇다고 대기가 없어지는 것은 아니다. obc 잠금, 파이프라인 stage 진입, `seastore_max_concurrent_transactions` 같은 제한이 future 대기로 표현될 뿐이다. 또한 SeaStore 트랜잭션은 낙관적 동시성으로 처리되어 충돌 시 재시도된다(`transaction_interruptor`, `Transaction`의 conflicted 처리) `[추측/미확인: 재시도 정책의 세부]`.

### 4.2 SeaStore 구성 요소 (main 소스 디렉터리 기준)

| 구성 요소 | 소스 | 역할 |
|---|---|---|
| `TransactionManager` | `transaction_manager.h` | 트랜잭션 생성·커밋, 하위 관리자 조정 |
| `Cache`, `CachedExtent` | `cache.h`, `cached_extent.h` | 익스텐트 캐시, 트랜잭션별 뷰, 충돌 감지 |
| `ExtentPlacementManager` | `extent_placement_manager.h` | 익스텐트 배치(계층·장치·세대) |
| `BtreeLBAManager` | `lba/btree_lba_manager.h` | 논리 블록 주소 B+tree |
| `BackrefManager` | `backref_manager.h` | 물리 → 논리 역참조 (클리너가 사용) |
| `SegmentedJournal` / `CircularBoundedJournal` | `journal/` | 세그먼트 백엔드 저널 / RBM용 원형 저널 |
| `SegmentCleaner` / `RBMCleaner` | `async_cleaner.h` | GC / 공간 회수 |
| `SegmentManager` 구현 | `segment_manager/block.cc`, `zbd.cc`, `ephemeral.cc` | 일반 블록, ZBD, 메모리(테스트) |
| `RBMDevice` 구현 | `random_block_manager/nvme_block_device.cc`, `hdd_device.cc` | RBM 장치 계층, `AvlAllocator` |
| onode / omap / collection | `onode_manager/`, `omap_manager/`, `collection_manager/` | 객체 메타데이터, 키-값, 컬렉션 |

### 4.3 세 가지 OSD 구성 비교

| 항목 | Classic OSD + BlueStore | Crimson + AlienStore | Crimson + SeaStore |
|---|---|---|---|
| 스레딩 | 메신저 워커, `osd_op_tp` 샤드 워커, BlueStore kv/aio/finisher 스레드 | 코어당 Seastar reactor + BlueStore용 POSIX 스레드(`crimson_bluestore_num_threads`, 기본 6) | 코어당 Seastar reactor |
| op 직렬화 | `OSDShard::shard_lock`, `PG::_lock`(mutex) | PG 소유 코어 안에서 future 순서 + 스레드 풀 경계 | PG 소유 코어 안에서 future 순서 |
| 메신저 | AsyncMessenger (epoll) | `crimson::net` (ProtocolV2, 멀티샤드 연결) | 동일 |
| 저장 I/O | `KernelDevice`: libaio 기본, `bdev_ioring` 선택 | BlueStore와 동일 | `seastar::file` DMA → reactor 백엔드 |
| QoS | mClock 기본 (Quincy~) | 진행 중 (Tentacle: 복구 스로틀, main: 클라이언트 mClock 스로틀 PR #69017) | 동일 |
| 성숙도 | 프로덕션 기본 | Squid tech preview (RBD, 복제 풀) | Tentacle tech preview (초기 시험용) |
| 정량 성능 | 공식 수치 확인 안 함 | 공식 수치 확인 안 함 | 공식 수치 확인 안 함 |

### 4.4 연표

| 시점 | 사건 | 근거 |
|---|---|---|
| Quincy v17.2.0 | Classic `osd_op_queue` 기본 `mclock_scheduler` | 태그 소스 |
| 2023-07 / Reef 백포트 | `crimson::net` 멀티샤드 연결 | PR #51916, #53949 |
| 2024-09 | Classic HDD 샤드 기본 5×1 → 1×5 (Tentacle 반영, Reef v18.2.5·Squid v19.2.1 백포트) | PR #58509 |
| Squid v19 | Crimson 첫 tech preview (RBD, 복제 풀) | Squid 릴리스 노트 |
| Tentacle v20 | SeaStore tech preview, Crimson과 함께 배포 가능 | Tentacle 릴리스 노트, ceph.io 블로그 |
| 2026-08 (main) | Crimson 클라이언트 op에 mClock 스로틀 | PR #69017 |
| main | SeaStore 데이터 계층 기본 `RANDOM_BLOCK` | `crimson.yaml.in` |

### 4.5 운영상 의미

- Tentacle까지 Crimson은 시험용이다. 블로그도 "it's also recommended to check the latest version of the main branch as the project continues to evolve rapidly"라고 권한다. 운영 클러스터의 성능 계획을 Crimson 수치에 기대서는 안 된다.
- Crimson은 코어를 상시 점유하는 모델이다. `crimson_cpu_set`/`crimson_cpu_num`으로 reactor 코어를 고정하고, `crimson_poll_mode=true`면 reactor가 잠들지 않고 폴링해 CPU 100%를 쓴다(기본 `false`). Tentacle 블로그는 한 호스트에 Crimson OSD 여러 개를 띄울 때 커널 `aio-nr` 한도가 부족할 수 있어 패키지와 cephadm 배포에서 이 값을 올렸다고 적는다. linux-aio 백엔드의 커널 자원 요구를 보여 주는 대목이다.
- io_uring을 쓰려면 Seastar가 liburing과 함께 빌드되어야 하고 런타임 커널이 탐지를 통과해야 한다. 어떤 백엔드가 선택되었는지는 OSD 시작 로그나 `crimson_reactor_backend`로 확인·고정하는 편이 안전하다.

## 5. Primary References

- [Squid — Ceph Documentation](https://docs.ceph.com/en/latest/releases/squid/) — "Crimson's first tech preview release!"
- [Tentacle — Ceph Documentation](https://docs.ceph.com/en/latest/releases/tentacle/) — SeaStore Tech Preview
- [Ceph.io — A Crimson colored Tentacle](https://ceph.io/en/news/blog/2025/crimson-T-release/)
- [Ceph.io — Crimson Project](https://ceph.io/en/news/crimson/)
- [Crimson developer documentation — Ceph Documentation](https://docs.ceph.com/en/latest/dev/crimson/index.html)
- [common/options: Change HDD OSD shard configuration defaults for mClock · Pull Request #58509 · ceph/ceph](https://github.com/ceph/ceph/pull/58509)
- [crimson/osd: Apply mClock scheduler throttle to client operations · Pull Request #69017 · ceph/ceph](https://github.com/ceph/ceph/pull/69017)
- [crimson/net: support connections in multiple shards · Pull Request #51916 · ceph/ceph](https://github.com/ceph/ceph/pull/51916)
- [ceph/src/crimson (main)](https://github.com/ceph/ceph/tree/main/src/crimson) — `osd/`, `os/seastore/`, `os/alienstore/`
- [ceph/src/common/options/crimson.yaml.in (main)](https://github.com/ceph/ceph/blob/main/src/common/options/crimson.yaml.in) — `crimson_reactor_backend`, `seastore_*_backend_type`
- [ceph/seastar src/core/reactor_backend.cc (Ceph 서브모듈 커밋)](https://github.com/ceph/seastar/blob/cced0236ee7cb4e157b5a37fd9076d62c5be4f58/src/core/reactor_backend.cc) — `reactor_backend_selector::available()`
