# Ceph OSD 스토리지 백엔드의 전환: FileStore·NewStore에서 BlueStore 원시 블록까지

> 기준: `github.com/ceph/ceph` `main`(2026-10 확인)과 릴리스 태그 v9.2.0(Infernalis), v10.2.0(Jewel), v12.2.0(Luminous), v14.2.x(Nautilus), v15.2.x(Octopus), v16.2.0(Pacific), v17.2.0(Quincy), v18.2.0(Reef). 옵션 기본값은 태그별 `src/common/options.cc` 또는 `src/common/options/global.yaml.in`에서 직접 확인했다. 학술 근거는 Aghayev et al., "File Systems Unfit as Distributed Storage Backends: Lessons from 10 Years of Ceph Evolution", SOSP '19 (ACM, DOI 10.1145/3341301.3359656)와 같은 저자들의 USENIX ;login: Spring 2020 요약 기사다.

## 1. Verdict

Ceph는 약 10년 동안 OSD 데이터를 로컬 파일시스템(XFS, Btrfs, ext4, ZFS) 위에 저장하는 FileStore를 썼다. 이 선택은 성숙한 코드를 재사용한다는 장점이 있었지만, SOSP '19 논문이 정리한 세 가지 비용을 치렀다. (1) 오버헤드 없는 트랜잭션 메커니즘을 만들기 어렵다. (2) 로컬 메타데이터 성능이 분산 계층 성능을 좌우한다. (3) 새 저장 하드웨어(호스트 관리형 SMR, ZNS 등)를 지원하는 속도가 매우 느리다.

BlueStore는 이를 풀기 위해 원시 블록 장치에 직접 데이터를 쓰고, 메타데이터는 RocksDB에, RocksDB 파일은 최소 기능만 가진 사용자 공간 파일시스템 BlueFS에 둔다. 소스 태그로 확인한 연표는 다음과 같다. NewStore(`src/os/newstore/NewStore.cc`)는 Infernalis v9.2.0과 v10.0.0~v10.0.2 개발 릴리스에 존재했고, v10.0.3 개발 릴리스에서 사라지면서 `src/os/bluestore/BlueStore.cc`가 들어왔다. Jewel v10.2.0에서 BlueStore는 experimental 상태였다. Luminous(v12)에서 안정판·기본 백엔드가 되었고, FileStore 소스(`src/os/filestore/FileStore.cc`)는 Quincy v17.2.0까지 있다가 Reef v18.2.0 태그에서 사라졌다.

흔히 퍼진 몇 가지 오해를 소스 기준으로 바로잡으면 다음과 같다.

- 작은 쓰기 임계값 옵션은 `bdev_write_threshold`가 아니라 `bluestore_prefer_deferred_size_hdd`/`_ssd`(그리고 둘을 덮어쓰는 `bluestore_prefer_deferred_size`)다. `main` 기본값은 HDD 64 KiB, SSD 0(SSD에서는 이 경로로 지연하지 않음)이다.
- `bluestore_min_alloc_size_ssd`는 Octopus v15.2.0에서 16 KiB → 4 KiB로 바뀌었고 Nautilus에도 v14.2.8로 백포트되었다(v14.2.7까지 16 KiB). `bluestore_min_alloc_size_hdd`는 Pacific v16.2.0에서 64 KiB → 4 KiB로 바뀌었다. 따라서 "Pacific부터 4K"는 HDD에만 정확하고, SSD는 한 릴리스(백포트 포함 시 Nautilus 후반) 앞선다.
- 기본 할당자는 `BitmapAllocator`가 아니라 `hybrid`(AVL + bitmap)다. `hybrid` 기본값은 v14.2.11과 v15.2.4 태그에서 처음 보이고(v14.2.10, v15.2.3은 `bitmap`), Pacific v16.2.0도 `hybrid`다.
- 압축은 기본으로 꺼져 있다(`bluestore_compression_mode=none`, 알고리즘 기본 `snappy`). "Zlib/Snappy/LZ4 인라인 투명 압축이 기본"이라는 서술은 틀렸다.
- FileStore/XFS는 데이터 체크섬을 제공하지 않는다. XFS v5 포맷의 CRC는 메타데이터 보호용이다. FileStore가 "crc32c 데이터 보호"를 했다는 서술은 틀렸다. BlueStore는 기본 `bluestore_csum_type=crc32c`로 모든 쓰기에 체크섬을 계산하고 모든 읽기에서 검증한다.
- io_uring 경로는 기본이 아니다. Octopus에서는 `bluestore_ioring`(기본 `false`, PR #27392 "os/bluestore: introduce new io_uring IO engine", 2019-12 머지), Pacific부터는 `bdev_ioring`(기본 `false`)이다. 기본 I/O 엔진은 libaio다.

## 2. Problem Statement

### 2.1 FileStore의 트랜잭션 문제

Ceph의 `ObjectStore::Transaction`은 객체 데이터 쓰기, xattr 갱신, omap(키-값) 갱신, PG 로그 기록을 원자적으로 묶는다. POSIX 파일시스템은 여러 파일과 xattr에 걸친 원자적 커밋 API가 없다. FileStore는 이를 위해 별도 저널(원시 파티션 또는 파일)에 트랜잭션 전체를 먼저 기록하고(write-ahead), 그 다음 파일시스템에 적용했다. 그 결과:

- **이중 쓰기**: 데이터가 저널과 파일에 두 번 기록된다. 큰 순차 쓰기에서는 장치 대역폭의 상당 부분이 저널에 쓰인다. Btrfs에서는 스냅샷 기반으로 저널을 줄이려는 시도가 있었으나, 결국 XFS 위 FileStore가 사실상 표준이 되었다(;login: 기사).
- **두 번의 캐시 플러시**: SOSP '19 요약은 저널링 파일시스템 위에 파일로 데이터를 쓰면 데이터 쓰기 하나에 캐시 플러시가 두 번 필요하지만, 원시 디스크에 직접 쓰면 한 번이라고 설명한다.
- **omap 저장**: omap은 FileStore 안에서도 LevelDB/RocksDB에 저장했으므로, 파일시스템 저널과 KV 저널이 따로 놀았다.

### 2.2 디렉터리 분할과 메타데이터 성능

FileStore는 PG(collection)를 디렉터리로, 객체를 파일로 매핑했다. 디렉터리 하나에 객체가 많아지면 해시 접두사로 하위 디렉터리를 만드는 split을 했고(`filestore_split_multiple`, `filestore_merge_threshold`), 이는 많은 `rename(2)`과 `mkdir(2)`을 동반했다. ;login: 기사는 "With FileStore, collection splitting was an expensive operation performed by renaming many directories in a deeply nested hierarchy."라고 적는다. BlueStore는 객체 이름을 RocksDB 키로 정렬해 두기 때문에, collection 분할이 키 범위의 유효 비트 수를 바꾸는 메타데이터 연산이 된다.

### 2.3 NewStore의 시도

NewStore는 메타데이터를 RocksDB로 옮기고 데이터는 여전히 파일시스템의 파일에 두는 중간 단계였다. 이렇게 하면 디렉터리 분할 문제는 사라지지만, 데이터 파일 쓰기와 RocksDB 커밋을 원자적으로 묶으려면 여전히 KV WAL에 데이터를 넣거나, 파일 `fsync`와 KV `fsync`를 순서대로 해야 한다. 어느 쪽이든 저널링 파일시스템 + KV 저널의 이중 일관성 비용이 남는다. NewStore가 v10.2.0 이전에 BlueStore로 대체된 이유를 1차 사료로 상세히 확인하지는 못했다 `[추측/미확인: NewStore 폐기 결정의 구체적 논의 출처]`.

### 2.4 체크섬과 새 하드웨어

;login: 기사는 대부분의 로컬 파일시스템이 데이터 체크섬을 지원하지 않고, 지원하는 Btrfs도 4 KiB 블록 단위여서 10 TiB 데이터에 10 GiB 체크섬 메타데이터가 필요하다고 지적한다. 분산 스토리지에서는 복제본 간 불일치 시 어느 쪽이 손상되었는지 판단할 수단이 필요하므로 체크섬이 필수다. 또한 커널 파일시스템이 SMR/ZNS 같은 순차 쓰기 강제 장치를 지원하기까지 오래 걸렸으므로, 저장 엔진이 I/O 스택을 직접 통제하는 편이 새 하드웨어 수용에 유리하다는 것이 논문의 주장이다.

## 3. The Debate

아래 인용은 SOSP '19 논문의 초록을 저자 그룹(CMU PDL)의 초록 페이지와 대조해 확인한 원문이다.

> "For a decade, the Ceph distributed file system followed the conventional wisdom of building its storage backend on top of local file systems. This is a preferred choice for most distributed file systems today because it allows them to benefit from the convenience and maturity of battle-tested code. Ceph's experience, however, shows that this comes at a high price."
>
> — Aghayev, Weil, Kuchnik, Nelson, Ganger, Amvrosiadis, "File Systems Unfit as Distributed Storage Backends: Lessons from 10 Years of Ceph Evolution", SOSP '19 (2019-10), 초록

해설: 논문의 주장은 "파일시스템이 느리다"가 아니다. 범용 파일시스템의 추상화(POSIX 트랜잭션 부재, 디렉터리 기반 메타데이터, 고정 블록 체크섬)가 분산 스토리지 백엔드의 요구와 맞지 않는다는 것이다. 같은 초록은 BlueStore가 도입 2년 만에 기존 백엔드보다 좋은 성능을 냈고 프로덕션 사용자의 70%가 채택했다고 적는다(논문 작성 시점 기준 설문 수치).

### 3.1 "파일시스템을 고치자" vs "파일시스템을 버리자"

대안은 파일시스템 쪽에 트랜잭션 기능을 넣는 것이었다. Btrfs의 트랜잭션 ioctl이나 저널 생략 같은 기법이 시도되었지만, 커널 파일시스템의 변경은 배포 커널의 버전 주기를 따라야 하고 Ceph가 통제할 수 없다. ;login: 기사는 BlueStore가 빨리 성숙한 이유를 두 가지로 든다. 작고 특수 목적인 인터페이스만 구현하고 POSIX 전체를 구현하지 않는다는 점, 그리고 사용자 공간에서 구현되어 검증된 서드파티 라이브러리(RocksDB 등)를 쓸 수 있다는 점이다.

반대 측의 우려는 지금도 유효하다. 자체 저장 엔진은 fsck, 복구 도구, 할당자 단편화, 메모리 관리(onode 캐시)를 전부 직접 책임져야 한다. BlueStore의 `bluestore_fsck_*`, `ceph-bluestore-tool`, 할당자 단편화 지표, `osd_memory_target` 기반 캐시 자동 조정은 모두 이 책임의 결과물이다.

### 3.2 RocksDB를 원시 블록 위에서 돌리는 방법: BlueFS

RocksDB는 `rocksdb::Env` 인터페이스로 파일을 연다. BlueStore는 BlueFS라는 최소 파일시스템을 만들고 `BlueRocksEnv`로 RocksDB에 연결했다. BlueFS는 디렉터리 계층이 거의 없고, 파일 메타데이터를 자체 로그(BlueFS log)에 기록하며, 장치를 WAL/DB/SLOW(`BlueFS::BDEV_WAL`, `BDEV_DB`, `BDEV_SLOW`) 역할로 나눠 쓴다. SOSP '19 요약은 또 하나의 변경을 언급한다. RocksDB가 WAL 파일을 원형 버퍼처럼 재사용하도록 바꿔(이 기능은 RocksDB 메인라인에 업스트림됨) 메타데이터 쓰기 하나에 캐시 플러시가 한 번만 필요하게 했다는 것이다.

BlueFS와 BlueStore 할당자가 같은 장치를 공유할 때의 공간 경계는 오래된 논쟁거리였다. 초기에는 BlueStore가 주기적으로 BlueFS에 공간을 넘겨주는 방식이었고(;login: 기사의 "periodically communicate to balance free space"), 이후 BlueFS가 공유 할당자를 직접 쓰는 방식으로 바뀌었다 `[추측/미확인: 변경 릴리스]`. `main`에서 `bluefs_shared_alloc_size` 기본값은 64 KiB, `bluefs_alloc_size`는 1 MiB, `bluefs_allocator`는 `hybrid`다.

### 3.3 Deferred write의 임계값

BlueStore는 copy-on-write 백엔드다. 새 데이터는 새로 할당한 익스텐트에 쓰고, 쓰기 완료 후 RocksDB에 메타데이터를 넣는다. 그러나 이미 할당된 블록의 일부만 덮어쓰는 작은 쓰기에 매번 새 할당을 하면 비효율적이다. 그래서 작은 쓰기는 데이터 자체를 RocksDB 트랜잭션에 "미래 I/O의 약속"으로 넣어 커밋한 뒤, 나중에 제자리에 쓴다. 이것이 deferred write다. ;login: 기사는 그 목적을 다음과 같이 적는다.

> "This deferred write mechanism has two purposes. First, it batches small writes to increase efficiency, because new data writes require two I/O operations whereas an insert to RocksDB requires one. Second, it optimizes I/O based on the device type"
>
> — Aghayev et al., "File Systems Unfit as Distributed Storage Back Ends", USENIX ;login: Vol. 45 No. 1, Spring 2020

해설: 같은 기사는 당시 기준으로 HDD에서 64 KiB 이하 덮어쓰기를 제자리에 비동기로 쓰고, SSD에서는 16 KiB 미만만 제자리 덮어쓰기를 한다고 적는다. 이 수치는 2019년의 `min_alloc_size`(HDD 64 KiB, SSD 16 KiB)에 묶여 있었다. `min_alloc_size`가 4 KiB로 내려간 뒤에는 임계값이 별도 옵션(`bluestore_prefer_deferred_size_hdd` 기본 64 KiB, `_ssd` 기본 0)으로 결정되며, SSD에서는 거의 모든 쓰기가 직접 쓰기다.

`min_alloc_size`를 4 KiB로 내린 논쟁의 핵심은 공간 증폭이다. RGW처럼 작은 객체가 많은 워크로드에서 64 KiB 할당 단위는 객체당 수십 KiB를 낭비한다. 반대로 할당 단위를 줄이면 할당자 메타데이터와 단편화가 늘고, HDD에서는 작은 쓰기가 랜덤 I/O가 된다. HDD 기본값을 4 KiB로 낮추면서 HDD의 작은 쓰기를 deferred 경로로 흡수하도록 `bluestore_prefer_deferred_size_hdd`를 32 KiB(v15.2.x까지)에서 64 KiB(v16.2.0)로 올린 것이 이 절충이다. 또한 `min_alloc_size`는 OSD 생성(mkfs) 시점에 고정되므로(`global.yaml.in`에서 `flags: create`), 기존 OSD는 재배포해야 새 값이 적용된다.

## 4. Implementation Impact

### 4.1 장치 배치

```
block      (주 데이터 장치)   : 객체 데이터. 할당자 = bluestore_allocator (기본 hybrid)
                               BlueFS가 공유할 때는 BDEV_SLOW 역할 (RocksDB SST 넘침 영역)
block.db   (선택, 빠른 장치)  : BlueFS BDEV_DB. RocksDB SST
block.wal  (선택, 가장 빠름)  : BlueFS BDEV_WAL. RocksDB WAL
RocksDB 키 접두사 예          : PREFIX_DEFERRED (지연 쓰기 레코드), onode, omap, 할당 정보 등
```

BlueFS는 "인메모리 메타데이터 파일시스템"이 아니라 영속 파일시스템이다. 캐시는 BlueStore onode/buffer 캐시와 RocksDB block cache가 맡는다(`bluestore_cache_size`가 0이면 `osd_memory_target` 기반 자동 조정).

### 4.2 쓰기 콜패스와 TransContext 상태 기계 (main 기준)

```
BlueStore::queue_transactions(ch, tls, op, handle)
  ├─ _txc_create(...)                        // TransContext, OpSequencer(osr)에 순서대로 연결
  ├─ for each Transaction: _txc_add_transaction(txc, t)
  │     └─ OP_WRITE → _write() → _do_write(txc, c, o, offset, length, bl, fadvise)
  │           └─ _do_write_data()
  │                ├─ _do_write_small()   // min_alloc 경계 안의 작은 쓰기
  │                │    ├─ 기존 mutable blob의 미사용·할당 블록에 쓰기:
  │                │    │    b_len < prefer_deferred_size → _get_deferred_op() (OP_WRITE)  // deferred
  │                │    │    아니면 txc->ioc에 aio 쓰기 추가                                 // direct
  │                │    └─ 부분 블록 덮어쓰기 → read-modify-write 후 deferred
  │                └─ _do_write_big()     // 큰 쓰기: 새 blob, prefer_deferred_size 비교로 deferred 여부 결정
  │           └─ _do_alloc_write()        // alloc->allocate(), 체크섬 계산, 압축(설정 시), aio 준비
  ├─ _txc_calc_cost(txc); _txc_write_nodes(txc, txc->t)
  └─ _txc_state_proc(txc)
        STATE_PREPARE    → _txc_aio_submit(): bdev->aio_submit() (libaio 기본, bdev_ioring=true면 io_uring)
        STATE_AIO_WAIT   → aio 완료 콜백 → _txc_finish_io() (osr 순서 보장)
        STATE_IO_DONE    → kv_queue.push_back(txc), kv_cond 통지
        STATE_KV_QUEUED  → [kv_sync_thread] _kv_sync_thread():
                              bdev->flush()  (aio 또는 deferred_done가 있을 때)
                              _txc_apply_kv(txc, false) → db->submit_transaction(txc->t)
                              db->submit_transaction_sync(synct)   // RocksDB WAL fsync 1회로 배치 커밋
                              kv_committing → kv_committing_to_finalize, kv_finalize_cond 통지
        STATE_KV_SUBMITTED / STATE_KV_DONE
                         → [kv_finalize_thread] _kv_finalize_thread():
                              _txc_committed_kv(txc) → 완료 콜백(onreadable/oncommit)을 finisher로
                              deferred가 있으면 _deferred_queue(txc) → STATE_DEFERRED_QUEUED
                              deferred_try_submit(), _reap_collections()
        STATE_DEFERRED_QUEUED → _deferred_submit_unlock(osr): 지연 데이터를 제자리 aio 쓰기
        STATE_DEFERRED_CLEANUP → 다음 kv 배치에서 PREFIX_DEFERRED 키 삭제(rm_single_key)
        STATE_FINISHING → STATE_DONE
```

핵심 동시성 구조는 다음과 같다.

- **OpSequencer(osr)**: PG(collection)마다 하나. 같은 PG의 트랜잭션 완료 순서를 보장한다. `_txc_finish_io()`는 앞선 txc가 끝나지 않으면 뒤 txc를 대기시킨다.
- **kv_sync_thread**: 단일 스레드가 여러 txc의 KV 트랜잭션을 모아 `submit_transaction_sync()` 한 번으로 커밋한다. 그룹 커밋으로 RocksDB WAL fsync 수를 줄이지만, 이 스레드가 직렬화 지점이 된다. 클래식 OSD에서 고성능 NVMe를 쓸 때 CPU 병목으로 자주 지목되는 지점이다 `[추측/미확인: 정량 근거는 이 문서에서 확인하지 않음]`.
- **kv_finalize_thread**: 커밋 후 처리(콜백, deferred 큐잉)를 kv_sync_thread에서 분리해 동기화 지점의 일을 줄인다.
- **deferred 배치**: `bluestore_deferred_batch_ops_hdd`(기본 64), `_ssd`(기본 16)만큼 모아 제출한다.

### 4.3 백엔드 비교

| 항목 | FileStore | NewStore (개발 단계) | BlueStore |
|---|---|---|---|
| 존재 기간 (태그 기준) | 초기 ~ Quincy v17.2.0, Reef v18.2.0에서 소스 제거 | v9.2.0 ~ v10.0.2 | v10.0.3 신규, Jewel v10.2.0 experimental, Luminous v12 기본 |
| 데이터 위치 | 로컬 FS(XFS 사실상 표준)의 파일 | 로컬 FS의 파일 | 원시 블록 장치 |
| 메타데이터 | 디렉터리 구조 + xattr + omap용 LevelDB/RocksDB | RocksDB | RocksDB on BlueFS |
| 트랜잭션 원자성 | 별도 저널(write-ahead) 후 FS 적용 | KV WAL + 파일 fsync | 데이터 direct 쓰기 후 KV 커밋, 작은 덮어쓰기는 deferred |
| 큰 쓰기의 쓰기 횟수 | 저널 + 파일 = 2회 | 파일 + KV | 1회 데이터 + KV 메타데이터 |
| collection split | 디렉터리 rename 다수 | KV 키 기반 | KV 키 기반 |
| 데이터 체크섬 | 없음 (XFS CRC는 메타데이터만) | `[추측/미확인]` | 기본 `crc32c`, 모든 읽기에서 검증 (`bluestore_csum_type`) |
| 인라인 압축 | 없음 (Btrfs 자체 압축 제외) | 없음 | 지원, 기본 `none` |
| I/O 엔진 | 커널 FS + 페이지 캐시 | 커널 FS | `KernelDevice`: libaio 기본, io_uring 선택 |

### 4.4 기본값 연표

| 옵션 | v12.2.0 | v14.2.0 | v15.2.0 | v16.2.0 | main |
|---|---|---|---|---|---|
| `bluestore_min_alloc_size_hdd` | 64 KiB | 64 KiB | 64 KiB | 4 KiB | 4 KiB |
| `bluestore_min_alloc_size_ssd` | 16 KiB | 16 KiB (v14.2.8+ 4 KiB) | 4 KiB | 4 KiB | 4 KiB |
| `bluestore_prefer_deferred_size_hdd` | 32 KiB | 32 KiB | 32 KiB | 64 KiB | 64 KiB |
| `bluestore_prefer_deferred_size_ssd` | 0 | 0 | 0 | 0 | 0 |
| `bluestore_allocator` | bitmap | bitmap (v14.2.11+ hybrid) | bitmap (v15.2.4+ hybrid) | hybrid | hybrid |
| io_uring 옵션 | 없음 | 없음 | `bluestore_ioring=false` | `bdev_ioring=false` | `bdev_ioring=false` |

### 4.5 운영상 의미

- Pacific 이전에 만든 HDD OSD는 64 KiB `min_alloc_size`를 유지한다. 작은 객체가 많은 RGW 풀에서는 재배포 전후 공간 사용량이 크게 다를 수 있다.
- `bdev_ioring`을 켜려면 커널과 liburing 지원이 필요하며, 기본값이 `false`인 이유는 성능 이득이 워크로드에 따라 일정하지 않기 때문으로 보인다 `[추측/미확인: 기본 비활성 결정의 공식 근거]`.
- 쓰기 지연 분석은 `ceph daemon osd.N perf dump`의 `l_bluestore_state_*_lat` 계열(상태별 지연: prepare, aio_wait, io_done, kv_queued, kv_commit 등)로 TransContext 단계별로 쪼개 볼 수 있다.

## 5. Primary References

- [File systems unfit as distributed storage backends: lessons from 10 years of Ceph evolution (SOSP '19, ACM DL)](https://dl.acm.org/doi/10.1145/3341301.3359656) — Aghayev, Weil, Kuchnik, Nelson, Ganger, Amvrosiadis
- [File Systems Unfit as Distributed Storage Back Ends: Lessons from 10 Years of Ceph Evolution — USENIX ;login: Spring 2020 (PDF)](https://www.usenix.org/system/files/login/articles/spring20_02_aghayev.pdf)
- [BlueStore Configuration Reference — Ceph Documentation](https://docs.ceph.com/en/latest/rados/configuration/bluestore-config-ref/)
- [Ceph.io — New in Luminous: BlueStore](https://ceph.io/en/news/blog/2017/new-luminous-bluestore/)
- [os/bluestore: introduce new io_uring IO engine · Pull Request #27392 · ceph/ceph](https://github.com/ceph/ceph/pull/27392)
- [kv: add column family support to KeyValueDB and RocksDBStore · Pull Request #9306 · ceph/ceph](https://github.com/ceph/ceph/pull/9306) — closed, 미머지 (머지되지 않은 제안)
- [ceph/src/os/bluestore/BlueStore.h (main)](https://github.com/ceph/ceph/blob/main/src/os/bluestore/BlueStore.h) — `TransContext` 상태, `KVSyncThread`, `KVFinalizeThread`
- [ceph/src/os/bluestore/BlueStore.cc (main)](https://github.com/ceph/ceph/blob/main/src/os/bluestore/BlueStore.cc) — `_txc_state_proc`, `_kv_sync_thread`, `_do_write_small`
- [ceph/src/common/options/global.yaml.in (main)](https://github.com/ceph/ceph/blob/main/src/common/options/global.yaml.in) — `bluestore_*`, `bdev_ioring` 기본값
