# RocksDB I/O 경로 심층 분석: WAL, Flush, Compaction, Direct I/O, RateLimiter, FileSystem 추상화, io_uring

> 기준 버전: RocksDB `main` 브랜치(2026-10 확인)와 `HISTORY.md` 최신 항목 11.12.0(2026-10-07). 옵션·클래스·함수 이름은 `github.com/facebook/rocksdb` 소스(`include/rocksdb/options.h`, `advanced_options.h`, `file_system.h`, `rate_limiter.h`, `env/io_posix.cc`, `db/db_impl/db_impl_write.cc` 등)에서 직접 확인했다. 기능 도입 버전은 `HISTORY.md`의 릴리스 헤더로 확인했다. 확인하지 못한 항목은 `[추측/미확인]`으로 표시한다.

## 1. Verdict

RocksDB는 "커널 I/O 스택 위에서 가장 많이 돌아가는 사용자 공간 스토리지 엔진" 중 하나다. MySQL(MyRocks), Ceph BlueStore 메타데이터 등이 그 위에 올라갔고, FAST '20 논문(Cao et al.)은 Facebook의 UDB(MySQL 저장 계층), ZippyDB, UP2X 워크로드를 RocksDB 위에서 분석했다. 그래서 RocksDB의 I/O 패턴은 곧 많은 스토리지 시스템의 I/O 패턴이다. 그 패턴은 세 갈래다.

1. **포그라운드 쓰기는 WAL에 대한 작은 append + 선택적 `fsync`다.** `DBImpl::WriteImpl()`이 `WriteThread`로 여러 writer를 그룹 커밋하고, 리더가 `log::Writer::AddRecord()`로 32 KiB(`kBlockSize = 32768`) 블록 단위 레코드를 WAL에 쓴다. memtable(기본 SkipList)에는 동시 삽입한다(`allow_concurrent_memtable_write = true`).
2. **백그라운드 쓰기는 큰 순차 쓰기(flush, compaction)이고, 이것이 쓰기 증폭(write amplification)의 본체다.** leveled compaction은 보통 10 이상의 쓰기 증폭을 낸다. 공식 wiki는 이를 "the usual write amplification of leveled compaction, which is often larger than 10"이라고 적는다. universal과 FIFO는 읽기·공간 증폭을 내주고 쓰기 증폭을 줄인다. `RateLimiter`(`NewGenericRateLimiter`)는 이 백그라운드 I/O가 포그라운드 지연을 해치지 않도록 토큰 버킷으로 조절한다.
3. **읽기는 block cache → (페이지 캐시) → 장치 순으로 내려간다.** `use_direct_reads`/`use_direct_io_for_flush_and_compaction`으로 페이지 캐시를 우회할 수 있다. 2026년 11.5.0에는 compaction 입력만 `O_DIRECT`로 읽는 `use_direct_io_for_compaction_reads`가 추가되었다. MultiGet과 scan은 `FSRandomAccessFile::MultiRead()`/`ReadAsync()`를 통해 io_uring을 쓴다. io_uring은 6.7.0(2020-01-21)에 MultiGet용으로 처음 들어갔고, `ReadOptions::async_io`는 7.1.0(2022-03-23)에 실험 기능으로 들어갔다.

설계상 가장 중요한 결정은 **`FileSystem`/`Env` 추상화**다. 6.7.0에서 파일 연산이 `rocksdb::Env`에서 분리되어 `rocksdb::FileSystem`(`include/rocksdb/file_system.h`)이 되었다. 이 경계 덕분에 Ceph는 `BlueRocksEnv`(여전히 레거시 `rocksdb::EnvWrapper` 상속)로 BlueFS 위에서 RocksDB를 돌린다. Western Digital의 ZenFS는 `class ZenFS : public FileSystemWrapper`로 ZNS SSD의 zone에 SST/WAL을 직접 배치한다. 같은 엔진이 커널 파일시스템, 사용자 공간 파일시스템, zoned 장치 위에서 모두 동작하는 이유가 이 추상화다.

FAST '21 논문(Dong et al.)은 RocksDB의 최적화 목표가 바뀌어 온 과정을 이렇게 요약한다. "We describe how and why RocksDB's resource optimization target migrated from write amplification, to space amplification, to CPU utilization." I/O 경로의 많은 옵션은 이 세 목표 사이의 트레이드오프를 조절하는 손잡이다.

---

## 2. Problem Statement

### 2.1 LSM-tree가 풀려는 문제와 새로 만드는 문제

B-tree는 제자리 갱신(in-place update)을 하므로 작은 랜덤 쓰기가 장치의 랜덤 쓰기가 되고, 플래시에서는 FTL GC와 쓰기 증폭으로 이어진다. LSM-tree는 쓰기를 메모리(memtable)에 모았다가 정렬된 불변 파일(SST)로 순차 기록하고, 백그라운드 compaction으로 파일을 병합한다. 랜덤 쓰기가 순차 쓰기로 바뀌지만 대가가 있다.

- **쓰기 증폭(WA)**: 같은 키가 레벨을 내려갈 때마다 다시 쓰인다. leveled에서 레벨 크기 배율 `max_bytes_for_level_multiplier = 10`이면 레벨당 최대 약 10배 재기록이 생긴다.
- **읽기 증폭(RA)**: 키 하나를 찾으려 여러 레벨과 L0 파일을 뒤진다. bloom filter와 block cache가 이를 완화한다.
- **공간 증폭(SA)**: 오래된 버전과 tombstone이 compaction 전까지 남는다. universal compaction은 full compaction 중 일시적으로 공간을 두 배 쓴다. wiki는 이를 "both of input files and the output file need to be kept, so the DB will be temporarily double the disk space usage"라고 적는다.

### 2.2 커널 I/O 스택과의 마찰

- **이중 캐싱**: RocksDB는 자체 block cache(압축 해제된 블록)를 가진다. buffered I/O를 쓰면 같은 데이터가 페이지 캐시(압축된 블록)에도 있다. Direct-IO wiki는 이를 이렇게 설명한다. "for self-caching applications such as RocksDB, the application itself should have a better knowledge of the logical semantics of the data than OS".
- **compaction의 캐시 오염**: 큰 순차 compaction 읽기가 페이지 캐시의 hot 사용자 데이터를 밀어낸다. 11.5.0 `use_direct_io_for_compaction_reads`의 동기도 정확히 이것이다. "avoiding page-cache eviction of hot user-read data by sequential compaction scans".
- **writeback 버스트**: 큰 SST를 buffered로 쓰면 dirty page가 쌓였다가 한 번에 writeback되어 WAL `fsync` 지연을 키운다. `bytes_per_sync`/`wal_bytes_per_sync`(기본 0)는 `sync_file_range` 계열의 `RangeSync()`로 이 버스트를 쪼갠다. `strict_bytes_per_sync`(6.2.0)는 한도를 넘으면 쓰기 스레드를 막는다.
- **동기 I/O의 직렬성**: 전통적인 `pread()` 기반 `Get()`은 레벨마다 블록 하나를 차례로 읽는다. 지연이 높은 원격·클라우드 스토리지에서 MultiGet과 scan이 I/O를 병렬로 내지 못하는 문제가 있었다. 이것이 io_uring `MultiRead`와 `async_io`의 동기다.

### 2.3 쓰기 정지(write stall)

compaction이 쓰기 속도를 따라가지 못하면 RocksDB는 스스로 쓰기를 늦추거나 멈춘다. 기준은 L0 파일 수(`level0_slowdown_writes_trigger = 20`, `level0_stop_writes_trigger = 36`), compaction 대기 바이트(`soft_pending_compaction_bytes_limit = 64 GiB`, `hard_pending_compaction_bytes_limit = 256 GiB`), 대기 중 memtable 수(`max_write_buffer_number = 2`)다. 따라서 장치의 순차 쓰기 대역폭이 곧 RocksDB의 지속 가능 쓰기 처리량 상한이고, RateLimiter를 너무 낮게 잡으면 stall이 생긴다.

---

## 3. The Debate

### 3.1 Compaction 스타일: 어떤 증폭을 낼 것인가

RocksDB의 compaction 스타일은 `enum CompactionStyle`(`advanced_options.h`)의 `kCompactionStyleLevel`(기본), `kCompactionStyleUniversal`, `kCompactionStyleFIFO`, `kCompactionStyleNone`이다. leveled 안에서도 파일 선택 정책 `compaction_pri`가 있다. 기본값은 `kMinOverlappingRatio`이고, 그 밖에 `kByCompensatedSize`와 `kRoundRobin`(7.6.0 HISTORY에 기재되었으나 같은 항목이 "available since 7.5"라고 밝힘) 등이 있다.

| 스타일 | 쓰기 증폭 | 읽기 증폭 | 공간 증폭 | 대표 용도 / 한계 |
|---|---|---|---|---|
| Leveled (`kCompactionStyleLevel`) | 높음(wiki: "often larger than 10") | 낮음(레벨당 파일 1개 탐색) | 낮음(`level_compaction_dynamic_level_bytes=true`일 때 상한 보장) | 범용 OLTP, 읽기 많은 워크로드 |
| Universal (`kCompactionStyleUniversal`) | 낮음(wiki: "targeting the use cases requiring lower write amplification") | 높음(sorted run 여러 개) | 높음(full compaction 중 2배) | 쓰기 많은 워크로드, 디스크 여유 필요 |
| FIFO (`kCompactionStyleFIFO`) | 1(wiki: "write amplification of data is always 1 (in addition to WAL write amplification)") | 매우 높음 | TTL/크기로 오래된 파일 삭제 | 시계열·캐시성 데이터 |

`level_compaction_dynamic_level_bytes`의 기본값은 8.4.0(2023-06-26)에 `true`로 바뀌었다. 마지막 레벨의 실제 크기에서 거꾸로 레벨 목표 크기를 계산하므로 공간 증폭 상한이 생긴다. 이 결정은 FAST '21 논문이 말하는 "write amplification → space amplification" 우선순위 이동과 같은 방향이다. 플래시 가격이 비싸고 내구성이 충분해지면서 WA보다 SA가 더 비싼 자원이 된 것이다.

학계의 대안도 같은 축 위에 있다.

- **WiscKey(FAST '16)**: 키와 값을 분리해 LSM에는 키와 포인터만 두고 값은 value log에 둔다. 논문 요약은 "WiscKey is 2.5x–111x faster than LevelDB for loading a database and 1.6x–14x faster for random lookups"이다(LevelDB 대비, 논문의 SSD 마이크로벤치마크 조건). RocksDB의 integrated BlobDB(`enable_blob_files`. 6.18.0, 2021-02-19에 "A new, experimental version of BlobDB (key-value separation)"로 코어에 통합)가 같은 아이디어를 흡수했다.
- **PebblesDB(SOSP '17)**: Fragmented LSM으로 같은 레벨 안의 재기록을 줄인다.
- **Dostoevsky(SIGMOD '18)**와 **Monkey(SIGMOD '17)**: 레벨별 병합 정책(lazy leveling)과 bloom filter 비트 배분을 수학적으로 최적화한다.

RocksDB는 이 중 무엇도 "기본"으로 채택하지 않았다. 대신 옵션(스타일, `compaction_pri`, BlobDB, 레벨별 bloom 설정)으로 노출해 워크로드별로 고르게 했다. 이는 FAST '21 논문이 강조하는 "resource allocation needs to be managed across different RocksDB instances" 같은 운영상 교훈과도 맞닿아 있다.

### 3.2 Direct I/O vs buffered I/O

| 관점 | buffered (기본) | `use_direct_reads` / `use_direct_io_for_flush_and_compaction` |
|---|---|---|
| 캐시 | block cache(비압축) + 페이지 캐시(압축) 이중 | block cache 단독, 메모리 예산 예측 가능 |
| 읽기 선행 | 커널 readahead | RocksDB 자체 prefetch(`compaction_readahead_size = 2 MiB`, `FilePrefetchBuffer`) |
| 쓰기 | dirty page + `bytes_per_sync` RangeSync | `writable_file_max_buffer_size = 1 MiB` 정렬 버퍼에서 직접 쓰기 |
| 정렬 | 불필요 | 논리 블록 크기 정렬(`PosixHelper::GetLogicalBlockSizeOfFd()`, sysfs `logical_block_size`) |
| 위험 | compaction이 hot 데이터를 페이지 캐시에서 밀어냄 | block cache를 충분히 크게 잡지 않으면 읽기 성능 급락. tmpfs 등 미지원 FS에서 `DB::Open` 실패 |

Direct-IO wiki는 "they may or may not improve performance depending on the use case"라는 `options.h` 주석을 그대로 옮긴다. 이 옵션은 만능이 아니다. 11.5.0의 `use_direct_io_for_compaction_reads`는 두 극단 사이의 절충이다. 사용자 읽기는 buffered로 두어 페이지 캐시의 2차 캐시 효과를 살리고, compaction 입력만 `O_DIRECT`로 읽어 캐시 오염을 막는다. `options.h` 주석은 그 비용도 명시한다. compaction마다 입력 파일을 다시 열어 TableCache를 우회하므로 `NO_FILE_OPENS`와 `TABLE_OPEN_IO_MICROS`가 늘어난다. 또 "The flag is neutral or slightly negative for in-memory DBs or uniform random reads, so measure before enabling."이라고 경고한다.

역사적으로 `use_direct_writes`/`use_direct_reads`는 5.2.0(2017-02-08)에 "ready to use"가 되었다. 5.4.0(2017-04-11)에 `use_direct_writes`는 `use_direct_io_for_flush_and_compaction`으로 대체되었다. 5.14.0에서는 `use_direct_io_for_flush_and_compaction`이 백그라운드 쓰기에만, `use_direct_reads`가 사용자 읽기와 백그라운드 읽기 모두에 적용되도록 의미가 정리되었다. WAL은 이 옵션의 대상이 아니다. WAL은 항상 buffered append + `fsync`/`fdatasync` 경로를 쓴다 `[추측/미확인: WAL direct write 지원 여부를 소스로 전수 확인하지 않음]`.

### 3.3 동기 I/O에서 io_uring·코루틴으로: 어디까지 비동기화할 것인가

RocksDB의 비동기화는 세 단계로 진행되었다.

1. **6.7.0 (2020-01-21)**: "MultiGet() can use IO Uring to parallelize read from the same SST file." 처음에는 환경 변수 `ROCKSDB_USE_IO_URING`으로 켜는 기본 비활성 기능이었다. 6.21.0에서는 빌드 기본값이 "try to build with liburing"으로 바뀌었다. 6.25.0에서는 사용자가 정의하는 `RocksDbIOUringEnable()` 훅이 추가되었다.
2. **7.0.0-7.3.0 (2022)**: `FSRandomAccessFile::ReadAsync()`와 `FileSystem::Poll()` API가 7.0.0에서 실험 기능으로 들어왔다. `ReadOptions::async_io`는 7.1.0에 `FilePrefetchBuffer`의 비동기 prefetch로 시작했다. 7.3.0에서는 batched MultiGet이 한 레벨의 여러 파일을 동시에 읽게 되었다. 7.4.0에서는 `AbortIO`(io_uring cancel)가 추가되었다. 7.6.0의 `optimize_multiget_for_io`는 코루틴으로 여러 레벨을 동시에 읽고, 7.7.0에서 기본값이 on이 되었다.
3. **11.8.0-11.12.0 (2026)**: 콜백 기반 `DB::GetAsync()`/`DB::MultiGetAsync()`(11.8.0), `DB::GetCoroDB()`의 lazy 코루틴 `Get`/`MultiGet`(11.9.0), `kFSBuffer`를 지원하는 `FileSystem`에서 단일 Get 코루틴 읽기가 `FSRandomAccessFile::SubmitReadAsync()`를 쓰는 변경(11.12.0)이 이어졌다.

쟁점은 복잡도와 이식성이다. Asynchronous-IO wiki는 MultiGet 비동기화가 "requires RocksDB to be compiled with folly using a compiler with C++ 20 support"라고 적는다. 같은 문서의 "No parallelism across levels" 한계 서술은 7.6.0 `optimize_multiget_for_io` 이전 상태를 반영하므로 현재 코드와 맞지 않는다. 플랫폼 문제도 있었다. 8.0.0 이전에는 io_uring이 없는 환경에서 `async_io` MultiGet이 `Status::Corruption()`을 잘못 반환했다. 8.0.0에서 `Status::NotSupported()`로 고쳐졌고, 8.1.0부터는 io_uring이 없으면 옵션을 무시하고 동기 I/O로 처리한다. 즉 io_uring은 "있으면 쓰는" 가속 경로이고, 정확성은 동기 경로가 보장한다.

### 3.4 `Env`에서 `FileSystem`으로: 플러그인 경계 논쟁

6.7.0 `HISTORY.md`는 이렇게 적었다. "Added a rocksdb::FileSystem class in include/rocksdb/file_system.h to encapsulate file creation/read/write operations". 처음에는 `DBOptions::file_system` 옵션도 함께 도입되었다. 현재 `main`의 `options.h`에는 이 옵션이 없고, `Env* env`만 남아 있다. 대신 `NewCompositeEnv(const std::shared_ptr<FileSystem>& fs)`로 FileSystem을 감싼 Env를 만들고, `Env::GetFileSystem()`으로 꺼낸다. 즉 스레드 풀·시계 같은 OS 서비스는 `Env`에 두고, 파일 I/O는 `FileSystem`으로 분리하는 방향이다.

이 경계는 외부 스토리지 백엔드에 결정적이다.

- **Ceph BlueFS**: `src/os/bluestore/BlueRocksEnv.h`의 `class BlueRocksEnv : public rocksdb::EnvWrapper`는 지금도 레거시 Env 인터페이스(`NewSequentialFile` 등이 `rocksdb::Status` 반환)를 구현한다. BlueFS는 WAL/DB/SLOW 장치(`BDEV_WAL`, `BDEV_DB`, `BDEV_SLOW`)에 RocksDB 파일을 배치한다. 자세한 내용은 (→ 06/03) 3.2절을 참고한다. 같은 문서에 따르면 RocksDB의 WAL 파일 재사용(`recycle_log_file_num`)은 BlueStore 요구에서 업스트림된 기능이다. 이 옵션은 `WALRecoveryMode`와의 상호작용 버그 때문에 6.8.0과 6.13에서 일부 모드와 함께 쓰지 못하게 되었다가, 9.1.0에서 `kPointInTimeRecovery`에 대해 다시 허용되었다.
- **ZenFS**: `fs/fs_zenfs.h`의 `class ZenFS : public FileSystemWrapper`는 새 `FileSystem` API를 쓴다. `ROCKSDB_PLUGINS=zenfs`로 빌드하고 `--fs_uri=zenfs://dev:<dev>`로 지정한다. 상세는 (→ 09/01) 4.7절을 참고한다. ZNS 논문(ATC '21)은 ZenFS 실행에 최소 3개의 active zone이 필요하며 각각 journal, WAL, compaction에 할당된다고 보고한다.

`IOStatus`, `IOOptions`(타임아웃, `rate_limiter_priority`), `IODebugContext`가 FileSystem API의 차별점이다. 오류 원인(retryable, data loss 등)을 엔진에 전달할 수 있고, 원격 스토리지에서 요청별 타임아웃을 줄 수 있다. 반면 BlueRocksEnv처럼 Env 경로에 머문 구현은 `env/env.cc`의 `class LegacyFileSystemWrapper : public FileSystem`과 `LegacyRandomAccessFileWrapper`/`LegacyWritableFileWrapper` 어댑터를 거친다. 그래서 `MultiRead`/`ReadAsync` 같은 새 API의 이점을 직접 누리지 못하고, 기본 구현(순차 `Read` 반복)으로 떨어진다 `[추측/미확인: BlueRocksEnv 경로의 MultiRead 실제 동작은 Ceph 소스로 확인하지 않음]`.

---

## 4. Implementation Impact

### 4.1 쓰기 경로 콜패스 (`main` 기준)

```
DB::Put() / DBImpl::Write()                  // db/db_impl/db_impl_write.cc
 └ DBImpl::WriteImpl()
    ├ write_thread_.JoinBatchGroup(&w)       // 리더 선출, 팔로워는 대기
    ├ (리더) PreprocessWrite()                // stall 판단: DelayWrite(), 필요 시
    │                                         //   ScheduleFlushes() → SwitchMemtable()
    ├ write_thread_.EnterAsBatchGroupLeader(&w, &write_group)
    ├ WriteGroupToWAL()  (two_write_queues면 ConcurrentWriteGroupToWAL())
    │   └ WriteToWAL() → log::Writer::AddRecord()
    │       └ EmitPhysicalRecord()           // 32 KiB 블록, 7바이트 헤더(kHeaderSize)
    │           └ WritableFileWriter::Append() → FSWritableFile::Append()
    │       └ WriteOptions::sync면 WritableFileWriter::Sync() → fsync/fdatasync
    └ memtable 삽입(allow_concurrent_memtable_write면 팔로워도 병렬 삽입)
```

- **그룹 커밋**: `WriteThread`의 리더 하나가 그룹 전체 배치를 하나의 WAL 레코드로 합쳐 쓴다. 따라서 `sync=true` 쓰기가 많아도 `fsync` 횟수는 그룹 수에 비례한다. `enable_pipelined_write`(WAL 쓰기와 memtable 삽입 파이프라인, `DBImpl::PipelinedWriteImpl()`), `two_write_queues`(WAL 전용 큐), `unordered_write`(스냅샷 불변성을 일부 포기하고 처리량 확보)는 그룹 커밋의 직렬 구간을 줄이는 변형이다.
- **WAL 레코드 포맷**: `db/log_format.h`의 `kBlockSize = 32768`, `kHeaderSize = 4 + 2 + 1`(CRC, 길이, 타입), 재사용 WAL용 `kRecyclableHeaderSize = 4 + 2 + 1 + 4`(로그 번호 추가)다. 레코드는 `kFullType`/`kFirstType`/`kMiddleType`/`kLastType`으로 블록 경계를 넘는다. `recycle_log_file_num > 0`이면 기존 WAL 파일을 덮어써 파일 생성·`fallocate`·메타데이터 `fsync`를 피한다.
- **WAL과 RateLimiter**: Rate-Limiter wiki는 "RocksDB does not enforce rate limit for anything other than flush and compaction, e.g. write to WAL"이라고 적는다. 그러나 7.1.0에 `WriteOptions::rate_limiter_priority`가 추가되어 자동 WAL flush도 지정한 우선순위로 RateLimiter에 과금할 수 있게 되었다(`manual_wal_flush == false`, `disableWAL == false`일 때). 10.8.0의 `FlushWALOptions::rate_limiter_priority`가 수동 `FlushWAL`까지 범위를 넓혔다. wiki 서술은 이 변경 이전 기준이다.
- **복구 모드**: `wal_recovery_mode` 기본값은 `WALRecoveryMode::kPointInTimeRecovery`다. 손상 지점 직전까지 복구하므로, 꼬리가 찢어진(torn) 쓰기를 허용한다.

### 4.2 Flush와 Compaction

```
MaybeScheduleFlushOrCompaction()             // db_impl_compaction_flush.cc
 ├ Env::Schedule(BGWorkFlush, HIGH pool)
 │   └ BackgroundCallFlush() → BackgroundFlush()
 │       └ FlushMemTableToOutputFile() → FlushJob::Run() → WriteLevel0Table()
 │           └ BuildTable() → BlockBasedTableBuilder → WritableFileWriter
 └ Env::Schedule(BGWorkCompaction, LOW pool)
     └ BackgroundCallCompaction() → BackgroundCompaction()
         └ CompactionJob::Run() → ProcessKeyValueCompaction() (subcompaction별)
             → CompactionJob::Install()     // VersionEdit → MANIFEST 기록
```

- 스레드 수는 `max_background_jobs = 2`(5.6.0에서 `max_background_flushes`/`max_background_compactions` 대체)가 정하고, 큰 compaction은 `max_subcompactions`로 키 범위를 나눠 병렬화한다.
- flush는 `Env::IO_HIGH`, compaction은 `Env::IO_LOW`로 RateLimiter에 과금된다(Rate-Limiter wiki). 사용자 요청은 `Env::IO_USER`로 항상 최우선이다.
- memtable은 `write_buffer_size = 64 MiB`에 도달하면 immutable이 되고, `max_write_buffer_number = 2`를 넘으면 stall이다. 여러 CF·DB의 memtable 총량은 `db_write_buffer_size` 또는 `WriteBufferManager`로 묶을 수 있다.
- L0 → L1 compaction이 밀리면 L0 파일 수가 늘어 읽기 증폭과 stall이 동시에 커진다. `level0_file_num_compaction_trigger = 4`가 시작점이다.

### 4.3 RateLimiter 내부 (`util/rate_limiter_impl.h`)

`NewGenericRateLimiter(rate_bytes_per_sec, refill_period_us = 100 * 1000, fairness = 10, mode = RateLimiter::Mode::kWritesOnly, auto_tuned = false, single_burst_bytes = 0)`가 `GenericRateLimiter`를 만든다. 내부에는 우선순위별 대기열 `std::deque<Req*> queue_[Env::IO_TOTAL]`이 있다. `RefillBytesAndGrantRequestsLocked()`가 주기마다 토큰을 채우고 대기 요청에 배분한다. 순서는 `GeneratePriorityIterationOrderLocked()`가 정한다. `IO_USER`가 항상 먼저이고, 나머지는 `fairness` 확률로 하위 우선순위가 먼저 기회를 얻는다(기아 방지). `Mode`는 `kReadsOnly`/`kWritesOnly`/`kAllIo`이며, 5.7.0부터 백그라운드 읽기도 조절할 수 있다. `auto_tuned`(5.9.0)는 수요에 따라 실제 한도를 지정값 이하로 동적으로 조정한다. 한 요청이 한 번에 받을 수 있는 최대 바이트(`single_burst_bytes`)가 있어서, 큰 요청 하나가 작은 요청을 오래 막지 못한다. Direct I/O 쓰기는 정렬 단위로 토큰을 받아야 하므로 `RequestToken(bytes, alignment, ...)`이 정렬을 고려한다.

### 4.4 읽기 경로와 block cache

`DBImpl::GetImpl()`은 memtable과 immutable memtable을 먼저 조회한다. 그다음 현재 `Version`의 레벨별 파일을 `TableCache`로 연 테이블 리더(`BlockBasedTable`)로 조회한다. index/filter 블록으로 data block 위치를 찾고, block cache 미스이면 `BlockFetcher`(`table/block_fetcher.h`) → `RandomAccessFileReader` → `FSRandomAccessFile::Read()`(Posix에서는 `PosixRandomAccessFile::Read()`, `pread`)로 읽는다. `main`에서는 코루틴 경로 리팩터링으로 `Version`/`BlockBasedTable`의 Get 진입 함수 이름이 바뀌었으므로, 이 문서는 중간 함수명을 특정하지 않는다.

- **block cache**: 10.7.0(2025-09-19)부터 `block_cache`가 nullptr(기본)일 때 기본 구현이 LRUCache에서 HyperClockCache로 바뀌었다. HyperClockCache는 7.9.0(2022-11-21)에 production-ready가 되었다. 당시 노트는 "As much as 4.5x higher ops/sec vs. LRUCache has been seen in db_bench under high parallel load"라고 적었다(db_bench, 고병렬 부하 조건). 8.7.0의 "automatic" 변형(`HyperClockCacheOptions::estimated_entry_charge = 0`)은 10.7.0에서 production-ready가 되었다. 블록 크기 기본값은 `block_size = 4 * 1024`이고, `cache_index_and_filter_blocks = false`가 기본이라 index/filter는 별도 메모리(테이블 리더)에 있다.
- **Direct I/O와 block cache 크기**: `use_direct_reads=true`에서는 페이지 캐시라는 2차 캐시가 사라진다. 따라서 block cache를 키우거나 compressed secondary cache(`NewTieredCache`, `TieredCacheOptions`)를 써야 같은 적중률을 유지한다.

### 4.5 io_uring 구현 (`env/io_posix.cc`, `env/io_posix.h`, `main` 기준)

- **스레드별 링 두 개**: `PosixRandomAccessFile`은 `ThreadLocalPtr* thread_local_multi_read_io_urings_`와 `thread_local_async_read_io_urings_`를 받는다. 동기 `MultiRead()`용 링과 비동기 `ReadAsync()`용 링이 분리되어 있다. 링은 처음 쓸 때 `CreateIOUring()`으로 만든다. 깊이는 `kIoUringDepth = 256`이고, 플래그는 `IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN`이다. 오래된 커널 헤더용으로 `io_posix.h`에 `#ifndef IORING_SETUP_SINGLE_ISSUER` → `(1U << 12)`, `IORING_SETUP_DEFER_TASKRUN` → `(1U << 13)` 폴백 정의가 있다. 링이 스레드 전용이므로 소스 주석대로 "No cross-thread coordination required"이다. DEFER_TASKRUN 덕분에 완료 task work가 제출 스레드에서만 돈다.
- **`MultiRead()`**: 요청마다 `io_uring_prep_readv(sqe, fd_, &req->iov, 1, offset)`를 만들고 `io_uring_submit_and_wait()`로 제출과 대기를 한 번에 한다. 이후 `io_uring_wait_cqes()`로 완료를 거둔다. short read는 재제출 리스트(`resubmit_rq_list`)로 다시 보낸다. Direct I/O면 offset·len·버퍼가 `GetRequiredBufferAlignment()`에 맞는지 assert한다. 컴파일 시 `ROCKSDB_IOURING_PRESENT`가 없으면 `FSRandomAccessFile::MultiRead()`의 기본 구현(요청별 순차 `Read()`)으로 떨어진다.
- **`ReadAsync()` / `Poll()` / `AbortIO()`**: `ReadAsync()`는 SQE에 `posix_handle`을 실어 제출만 하고 반환한다. 링 초기화에 실패하면 `IOStatus::NotSupported("ReadAsync: failed to init io_uring")`를 돌려준다. `FilePrefetchBuffer`는 버퍼 중간 지점에서 다음 구간을 `ReadAsync()`로 미리 요청하고, 필요할 때 `FileSystem::Poll()`로 완료를 기다린다. iterator가 버려지면 `AbortIO()`가 io_uring cancel로 진행 중 요청을 취소한다(7.4.0).
- **`FSSupportedOps`**: 8.4.0에서 `FileSystem::use_async_io()`가 `SupportedOps` API로 바뀌었다. `FSSupportedOps::kAsyncIO`, `kFSBuffer`(FileSystem이 자체 버퍼를 `FSReadRequest::fs_scratch`로 넘기는 zero-copy 경로)가 플래그다. 플러그인 FileSystem(원격 스토리지 등)은 이 플래그로 비동기 경로 참여 여부를 선언한다.

### 4.6 Direct I/O 옵션 적용 범위

| 파일/연산 | 기본 | `use_direct_reads` | `use_direct_io_for_compaction_reads` (11.5+) | `use_direct_io_for_flush_and_compaction` |
|---|---|---|---|---|
| 사용자 Get/MultiGet/Iterator SST 읽기 | buffered | `O_DIRECT` | buffered | buffered |
| compaction 입력 SST 읽기 | buffered | `O_DIRECT` | `O_DIRECT`(임시 리더, TableCache 우회) | buffered |
| flush/compaction 출력 SST 쓰기 | buffered | buffered | buffered | `O_DIRECT` |
| WAL 쓰기 | buffered | buffered | buffered | buffered |
| MANIFEST 열기 검사 | — | — | `DB::Open` 시 `O_DIRECT` 프로브 | — |
| macOS 구현 | — | `fcntl(fd, F_NOCACHE, 1)` | 동일 | 동일 |

`env/fs_posix.cc`는 Linux에서 `flags |= O_DIRECT`를, macOS에서 `F_NOCACHE`를 쓴다. 정렬 처리는 파일 클래스가 아니라 상위 `RandomAccessFileReader`/`WritableFileWriter`가 맡는다. Direct-IO wiki의 표현으로는 "RocksDB implements all the alignment logic inside FileReader/FileWriter".

### 4.7 스토리지 백엔드별 RocksDB 배치 비교

| 백엔드 | 통합 계층 | 장치 접근 | 캐시 | 주요 제약 |
|---|---|---|---|---|
| ext4/XFS (`PosixFileSystem`) | 기본 `FileSystem::Default()` | VFS, buffered 또는 `O_DIRECT`, io_uring | block cache + 페이지 캐시 | 커널 writeback·저널 간섭 |
| Ceph BlueFS | `BlueRocksEnv : rocksdb::EnvWrapper` | `KernelDevice`(libaio/io_uring) 또는 SPDK로 원시 블록 | block cache(BlueFS 자체 버퍼) | 레거시 Env 경로, BlueStore와 공간 공유 |
| ZenFS (ZNS/SMR) | `ZenFS : FileSystemWrapper` 플러그인 | zoned 블록 장치 직접, zone 단위 배치 | block cache | active zone 수, WAL/SST 수명 분리 필요 |
| 원격/클라우드 FS | 사용자 `FileSystem` 구현 | 네트워크 | block cache + secondary cache | 높은 지연 → `async_io`, `MultiRead` 중요 |

BlueFS의 장치 I/O 경로 이름(`KernelDevice` 등)은 (→ 06/03)을 따른다. ZNS 위 RocksDB의 지연·처리량 결과(ATC '21 초록의 "zone-specialized RocksDB", 즉 ZenFS 기반 RocksDB의 p99.9 랜덤 읽기 지연 "at least 2–4× lower")는 (→ 09/01)에서 측정 조건과 함께 다룬다.

### 4.8 기능 도입 연표 (`HISTORY.md` 기준)

| 버전 (날짜) | 변경 |
|---|---|
| 3.11.0 (2015-05-19) | `bytes_per_sync`가 테이블 파일 전용이 되고 WAL용 `wal_bytes_per_sync` 분리 |
| 5.2.0 (2017-02-08) | `use_direct_reads`, `use_direct_writes` 사용 가능 |
| 5.4.0 (2017-04-11) | `use_direct_writes` → `use_direct_io_for_flush_and_compaction` |
| 5.6.0 (2017-06-06) | `max_background_jobs` 도입 |
| 5.7.0 / 5.9.0 (2017) | RateLimiter 읽기 조절 / `auto_tuned` |
| 6.7.0 (2020-01-21) | `rocksdb::FileSystem` 클래스, MultiGet io_uring(환경 변수로 활성) |
| 6.18.0 (2021-02-19) | integrated BlobDB(실험) |
| 6.21.0 (2021-05-21) | liburing 기본 빌드 시도 |
| 7.0.0 (2022-02-20) | `ReadAsync`/`Poll` API(실험), `ReadOptions::rate_limiter_priority` |
| 7.1.0 (2022-03-23) | `ReadOptions::async_io`(실험), `WriteOptions::rate_limiter_priority` |
| 7.6.0 / 7.7.0 (2022) | `optimize_multiget_for_io` 추가 / 기본 on. `kRoundRobin`은 7.6.0 HISTORY 기재(7.5부터 사용 가능) |
| 7.9.0 (2022-11-21) | HyperClockCache production-ready |
| 8.4.0 (2023-06-26) | `level_compaction_dynamic_level_bytes` 기본 true, `FSSupportedOps` |
| 10.7.0 (2025-09-19) | 기본 block cache를 HyperClockCache로 |
| 11.5.0 (2026-06-16) | `use_direct_io_for_compaction_reads` |
| 11.8.0-11.12.0 (2026) | `GetAsync`/`MultiGetAsync`, `CoroDB`, `SubmitReadAsync()` |

### 4.9 운영 관점 요약

1. **쓰기 많은 NVMe 워크로드**: `use_direct_io_for_flush_and_compaction=true` + `use_direct_io_for_compaction_reads=true`로 compaction이 페이지 캐시를 오염시키지 않게 한다. `RateLimiter`(`auto_tuned=true`)로 compaction 버스트를 평탄화한다. 단 한도를 너무 낮게 잡으면 `pending_compaction_bytes` stall이 생긴다.
2. **읽기 지연 민감**: `use_direct_reads`는 block cache를 충분히 키울 수 있을 때만 쓴다. 지연이 높은 스토리지에서는 `ReadOptions::async_io`와 batched MultiGet으로 I/O 병렬성을 확보한다(io_uring 빌드 필요).
3. **공간 vs 쓰기 증폭**: SSD 수명보다 용량이 비싸면 leveled + dynamic level bytes(기본)를, 쓰기 대역폭이 병목이면 universal을, TTL 데이터면 FIFO를 쓴다. 큰 값은 BlobDB로 분리해 compaction 재기록량을 줄인다.
4. **커널 측 상호작용**: WAL `fsync` 지연은 같은 장치의 compaction 쓰기에 직접 영향을 받는다. `wal_bytes_per_sync`와 별도 WAL 장치(`DBOptions::wal_dir`)가 고전적 완화책이다.

---

## 5. Primary References

- [facebook/rocksdb — include/rocksdb/options.h](https://github.com/facebook/rocksdb/blob/main/include/rocksdb/options.h) — `use_direct_reads`, `use_direct_io_for_compaction_reads`, `use_direct_io_for_flush_and_compaction`, `async_io`, `optimize_multiget_for_io`
- [facebook/rocksdb — include/rocksdb/advanced_options.h](https://github.com/facebook/rocksdb/blob/main/include/rocksdb/advanced_options.h) — `CompactionStyle`, `CompactionPri`, stall 트리거
- [facebook/rocksdb — include/rocksdb/file_system.h](https://github.com/facebook/rocksdb/blob/main/include/rocksdb/file_system.h) — `FileSystem`, `FSRandomAccessFile::MultiRead/ReadAsync`, `FSSupportedOps`
- [facebook/rocksdb — include/rocksdb/rate_limiter.h](https://github.com/facebook/rocksdb/blob/main/include/rocksdb/rate_limiter.h) — `NewGenericRateLimiter`, `RateLimiter::Mode`
- [facebook/rocksdb — env/io_posix.cc](https://github.com/facebook/rocksdb/blob/main/env/io_posix.cc) — `PosixRandomAccessFile::MultiRead/ReadAsync`, io_uring
- [facebook/rocksdb — db/db_impl/db_impl_write.cc](https://github.com/facebook/rocksdb/blob/main/db/db_impl/db_impl_write.cc) — `WriteImpl`, `WriteGroupToWAL`, `PreprocessWrite`
- [facebook/rocksdb — HISTORY.md](https://github.com/facebook/rocksdb/blob/main/HISTORY.md) — 버전별 도입 시점
- [Direct IO · facebook/rocksdb Wiki](https://github.com/facebook/rocksdb/wiki/Direct-IO)
- [Asynchronous IO · facebook/rocksdb Wiki](https://github.com/facebook/rocksdb/wiki/Asynchronous-IO)
- [Rate Limiter · facebook/rocksdb Wiki](https://github.com/facebook/rocksdb/wiki/Rate-Limiter)
- [Leveled Compaction · facebook/rocksdb Wiki](https://github.com/facebook/rocksdb/wiki/Leveled-Compaction)
- [Universal Compaction · facebook/rocksdb Wiki](https://github.com/facebook/rocksdb/wiki/Universal-Compaction)
- [FIFO compaction style · facebook/rocksdb Wiki](https://github.com/facebook/rocksdb/wiki/FIFO-compaction-style)
- [Write Ahead Log (WAL) · facebook/rocksdb Wiki](https://github.com/facebook/rocksdb/wiki/Write-Ahead-Log-%28WAL%29)
- [Block Cache · facebook/rocksdb Wiki](https://github.com/facebook/rocksdb/wiki/Block-Cache)
- [Write Stalls · facebook/rocksdb Wiki](https://github.com/facebook/rocksdb/wiki/Write-Stalls)
- [Evolution of Development Priorities in Key-value Stores Serving Large-scale Applications: The RocksDB Experience (FAST '21)](https://www.usenix.org/conference/fast21/presentation/dong)
- RocksDB: Evolution of Development Priorities in a Key-value Store Serving Large-scale Applications, ACM Transactions on Storage, 2021 — DOI `10.1145/3483840` (FAST '21 논문 확장판. Crossref API로 제목·게재지 확인, dl.acm.org는 봇 차단(403)으로 링크 검증 불가해 URL 생략)
- [Characterizing, Modeling, and Benchmarking RocksDB Key-Value Workloads at Facebook (FAST '20)](https://www.usenix.org/conference/fast20/presentation/cao-zhichao)
- [WiscKey: Separating Keys from Values in SSD-conscious Storage (FAST '16)](https://www.usenix.org/conference/fast16/technical-sessions/presentation/lu)
- PebblesDB, Proceedings of the 26th Symposium on Operating Systems Principles (SOSP '17) — DOI `10.1145/3132747.3132765` (Crossref 확인, URL 생략 사유 동일)
- Dostoevsky, Proceedings of the 2018 International Conference on Management of Data (SIGMOD '18) — DOI `10.1145/3183713.3196927` (Crossref 확인, URL 생략 사유 동일)
- Monkey, Proceedings of the 2017 ACM International Conference on Management of Data (SIGMOD '17) — DOI `10.1145/3035918.3064054` (Crossref 확인, URL 생략 사유 동일)
- [ZNS: Avoiding the Block Interface Tax for Flash-based SSDs (ATC '21)](https://www.usenix.org/conference/atc21/presentation/bjorling)
- [ceph/ceph — src/os/bluestore/BlueRocksEnv.h](https://github.com/ceph/ceph/blob/main/src/os/bluestore/BlueRocksEnv.h) — `class BlueRocksEnv : public rocksdb::EnvWrapper`
- [westerndigitalcorporation/zenfs — fs/fs_zenfs.h](https://github.com/westerndigitalcorporation/zenfs/blob/master/fs/fs_zenfs.h) — `class ZenFS : public FileSystemWrapper`
