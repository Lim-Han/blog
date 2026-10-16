# OpenZFS I/O 경로 심층 분석: ZIO 파이프라인, vdev 큐 스케줄러, ARC/ZIL/TXG, 그리고 2.3의 Direct I/O

> 기준 버전: OpenZFS `master`(2026-10 확인, `META` 상 `Version: 2.4.99`, `Linux-Maximum: 7.2`) 및 릴리스 zfs-2.1.0(2021-07-02), zfs-2.2.0(2023-10-13), zfs-2.3.0(2025-01-14), zfs-2.4.0(2025-12-18), zfs-2.4.4(2026-08-21). 구조체·함수·튜너블 이름은 `github.com/openzfs/zfs` 소스(`include/sys/zio_impl.h`, `module/zfs/zio.c`, `module/zfs/vdev_queue.c` 등)와 `man/man4/zfs.4`, `man/man7/zfsprops.7`에서 직접 확인했다. 확인하지 못한 항목은 `[추측/미확인]`으로 표시한다.

## 1. Verdict

OpenZFS의 I/O 경로는 "블록 하나를 처리하는 일은 전부 `zio_t` 하나가 단계(stage) 비트마스크를 따라 진행하는 상태 기계"라는 설계 위에 서 있다. 압축, 암호화, 체크섬 생성, dedup, gang block, DVA 할당, vdev I/O, 체크섬 검증은 모두 `zio_pipeline[]` 함수 테이블의 한 칸이다. I/O 유형마다 `ZIO_WRITE_PIPELINE`, `ZIO_READ_PIPELINE` 같은 비트마스크가 어떤 칸을 지나갈지 정한다. 이 덕분에 기능을 추가할 때 파이프라인에 단계 하나를 끼우면 된다. 실제로 block cloning은 `ZIO_STAGE_BRT_FREE`를, Direct I/O는 `ZIO_STAGE_DIO_CHECKSUM_VERIFY`를 추가했다.

이 문서의 결론은 다섯 가지다.

1. **ZFS 성능은 vdev 큐 스케줄러와 TXG 더티 데이터 제어가 함께 결정한다.** `vdev_queue.c`는 I/O를 sync read, sync write, async read, async write, scrub, removal, initializing, trim, rebuild의 9개 클래스(`zio_priority_t`)로 나눈다. 클래스마다 `zfs_vdev_*_min_active`/`*_max_active`로 동시 발행 수를 제한한다. async write 클래스의 동시성은 풀 전체 더티 데이터 비율에 따라 구간 선형(piece-wise linear)으로 바뀐다. 블록 장치 층의 mq-deadline/BFQ와 별개로 동작하는 2단 스케줄링이다.
2. **ARC는 ZFS의 장점이자 NVMe 시대의 병목이다.** 자체 캐시인 ARC가 페이지 캐시를 대신하기 때문에, 0.8.0(2018 머지된 PR #7823) 이후 Linux에서 `O_DIRECT`는 "받아들이되 무시"되어 왔다. 2024-09-14에 머지되어 2.3.0(2025-01-14)에 포함된 Direct I/O(PR #10018, 작성자 Brian Atkinson)가 이 상황을 끝냈다. 새 데이터셋 속성 `direct=disabled|standard|always`가 생겼고 기본값은 `standard`다. 단, ZIO 파이프라인은 우회하지 않는다. 체크섬, 압축, 암호화, 패리티 계산은 Direct I/O에서도 그대로 수행된다.
3. **ZIL/SLOG는 쓰기 지연을 줄이는 장치이지 쓰기 캐시가 아니다.** 동기 쓰기(`fsync`, `O_SYNC`, `sync=always`)만 ZIL을 거친다. 실제 데이터는 TXG sync(`spa_sync()`, 기본 `zfs_txg_timeout = 5`초)에서 메인 풀에 기록된다. `zil_write_state()`는 `logbias`, 쓰기 크기(`zfs_immediate_write_sz = 32768`), SLOG 존재 여부, `O_DIRECT` 여부에 따라 `WR_COPIED`/`WR_NEED_COPY`/`WR_INDIRECT`를 고른다.
4. **레이아웃 기능은 릴리스별로 차곡차곡 쌓였다.** dRAID는 2.1.0, block cloning은 2.2.0(단 2.2.1에서 데이터 손상 버그 #15526 때문에 기본 비활성화되었고 2.3.0에서 다시 기본 활성), RAIDZ expansion·Fast Dedup·Direct I/O는 2.3.0에 들어갔다. 2.4.0은 정렬되지 않은 Direct I/O 요청을 "uncached I/O"로 폴백시키는 기능(PR #17218 외)을 더했다.
5. **Linux 통합 비용은 라이선스에서 시작해 API 변화(churn)로 이어진다.** CDDL 모듈인 OpenZFS는 GPL-only 심볼을 쓸 수 없다. Linux 5.0에서 `__kernel_fpu_begin()`/`__kernel_fpu_end()` export가 제거되었을 때 SIMD 체크섬 가속이 한동안 막혔다. 현재 소스의 `simd_x86.h`는 커널이 FPU 심볼을 export하지 않으면 자체 `kfpu_begin()`/`kfpu_end()` 구현(`HAVE_KERNEL_FPU_INTERNAL`)으로 우회한다. 릴리스마다 "compatible with 4.18 - 7.2 kernels" 같은 지원 범위를 명시하고 configure 단계의 `HAVE_*` 매크로로 커널 API 차이를 흡수하는 것은 out-of-tree 파일시스템의 숙명이다.

---

## 2. Problem Statement

### 2.1 "블록 장치 위의 파일시스템"이 아닌 구조

ext4/XFS는 블록 장치 하나(또는 dm/md가 만든 논리 장치) 위에서 동작하고, 중복성과 체크섬은 하위 계층이나 사용자에게 맡긴다. ZFS는 볼륨 관리자, RAID, 파일시스템, 캐시를 한 스택에 통합했다. 그 결과 블록 하나의 쓰기는 다음 일을 모두 해야 한다.

- 압축(`compression=lz4|zstd|...`), 암호화(`encryption`), 체크섬 생성(`checksum=fletcher4|sha256|blake3|...`)
- dedup 테이블(DDT) 조회, block cloning 참조 테이블(BRT) 갱신
- 메타슬랩에서 DVA 할당(`zio_dva_allocate`)과 할당 스로틀(`zio_dva_throttle`)
- 미러/RAIDZ/dRAID 자식 vdev로의 팬아웃과 패리티 계산
- 읽기 시 체크섬 검증과 실패 시 다른 사본/패리티에서 자가 치유(self-healing)

이 단계들을 함수 호출 체인으로 엮으면 어느 지점에서 블로킹하고 어느 taskq에서 재개할지 관리하기 어렵다. ZIO 파이프라인은 각 단계를 "다음 `zio_t`를 돌려주거나, 대기를 위해 `NULL`을 돌려주는" 독립 함수로 만들어 이 문제를 푼다.

### 2.2 COW + TXG 모델의 지연 특성

ZFS는 copy-on-write다. 모든 변경은 열린 TXG(open → quiescing → syncing)에 더티 데이터로 쌓였다가 `spa_sync()`에서 한꺼번에 새 위치에 쓰이고, 마지막에 uberblock이 갱신된다. 처리량에는 유리하지만 두 가지 문제가 생긴다.

- **버스트성 쓰기**: TXG sync가 시작되면 async write가 한꺼번에 쏟아진다. 이것이 sync read나 ZIL 쓰기의 지연을 망가뜨린다. `vdev_queue.c` 주석은 async write 동시성을 더티 데이터 양에 연동하는 이유를 "reducing the burstiness in the number of concurrent operations also stabilizes the response time of operations from other -- and in particular synchronous -- queues"라고 설명한다.
- **동기 쓰기 지연**: `fsync()`가 TXG sync(최대 `zfs_txg_timeout`초)를 기다리면 데이터베이스는 쓸 수 없다. 그래서 ZIL이라는 별도의 intent log가 필요하다.

### 2.3 ARC와 NVMe: memcpy가 병목이 되는 지점

ARC는 MRU/MFU 기반 적응형 캐시이고, 2.2.0의 "Fully adaptive ARC"(PR #14359)로 데이터/메타데이터 구분 제한도 완화되었다. 그러나 Direct I/O PR #10018 본문은 문제를 이렇게 적는다. "the performance of ZPool's composed of NVMe devices displayed poor read/write performance due to the extra overhead of memcpy's issued to the ARC." 장치가 수 GB/s를 내면, 사용자 버퍼에서 ARC 버퍼(ABD)로 복사하는 비용과 ARC 해시·eviction 관리 비용이 장치 지연보다 커진다. 데이터베이스처럼 자체 버퍼 풀을 가진 애플리케이션에서는 이중 캐싱도 문제다.

### 2.4 왜 `O_DIRECT`는 오랫동안 무시되었나

ZFS on Linux 0.8.0 이전에는 `O_DIRECT` open이 `EINVAL`로 실패해 일부 애플리케이션이 동작하지 않았다(이슈 #224). Brian Behlendorf의 PR #7823 "Direct IO support"(2018-08-27 머지)는 `O_DIRECT`를 받아들이되 ARC를 계속 쓰는 방식을 택했다. 근거는 PR 본문에 있다. "By design the ARC is already scan-resistant which helps mitigate the need for special O_DIRECT handling." 또 정렬 제약도 추가로 두지 않았다. 즉 호환성을 위한 수용이었지 캐시 우회는 아니었다. 현재 `zfsprops(7)`의 `direct` 설명도 `disabled`를 "causes the O_DIRECT flag to be silently ignored and all direct requests will be handled by the ARC. This is the default behavior for OpenZFS 2.2 and prior releases."라고 적는다.

진짜 우회가 어려웠던 이유는 구조적이다.

- **체크섬과 페이지 안정성**: ARC 경유 쓰기는 ZFS가 소유한 버퍼에 데이터를 복사한 뒤 체크섬을 계산한다. 사용자 페이지를 그대로 쓰면 체크섬 계산 이후 애플리케이션이 버퍼를 바꿀 수 있고, 그러면 디스크의 데이터와 체크섬이 어긋난다.
- **recordsize 단위 COW**: 블록 일부만 덮어쓰는 쓰기는 read-modify-write가 필요하다. 이 경우 ARC를 거치지 않을 수 없다.
- **coherency**: 같은 파일에 buffered I/O, mmap, Direct I/O가 섞이면 ARC 사본과 디스크가 일관되어야 한다.

---

## 3. The Debate

### 3.1 Direct I/O: "ARC는 이미 scan-resistant하다" vs "NVMe에서는 memcpy가 병목이다"

2018년 PR #7823과 2024년 PR #10018은 같은 제목("Direct IO support" / "Direct IO Support")이지만 결론이 반대다.

| 관점 | PR #7823 (0.8.0, 2018-08-27 머지) | PR #10018 (2.3.0, 2024-09-14 머지) |
|---|---|---|
| `O_DIRECT` 의미 | 플래그 수용, ARC 경유 유지 | ARC 우회(`direct=standard` 기본) |
| 정렬 제약 | 추가 제약 없음 | 페이지 정렬 필수, 쓰기는 `recordsize` 정렬 시에만 우회 |
| 근거 | ARC가 scan-resistant, 호환성 확보가 목적 | NVMe 풀에서 ARC memcpy 오버헤드 |
| ZIO 파이프라인 | 일반 경로 | 그대로 통과(체크섬/압축/암호화/패리티 유지) |
| 사용자 버퍼 안정성 | 문제 없음(ZFS 버퍼로 복사) | 페이지 stable 처리, Linux에서는 `zfs_vdev_direct_write_verify=1` |

PR #10018 본문은 "Direct IO does not bypass the ZIO pipeline, so all checksums, compression, etc. are still all supported with Direct IO."라고 강조한다. 이것이 ext4/XFS의 Direct I/O와 가장 크게 다른 점이다. ZFS의 Direct I/O는 "ARC를 건너뛸 뿐 ZFS가 하는 일은 모두 한다". 그래서 정렬되지 않은 쓰기는 RMW가 필요하고 ARC로 돌아간다. 또 `O_DIRECT`는 `O_SYNC`를 뜻하지 않는다. 데이터 블록은 vdev에 바로 쓰이지만 블록 포인터를 담은 메타데이터는 TXG sync 때 커밋된다.

**페이지 안정성 논쟁.** Linux에서는 Direct I/O 진행 중 익명(anonymous) 사용자 페이지를 write-protect할 수 없다. `module/zfs/vdev.c`의 주석은 이렇게 적는다. "VDEV checksum verification for Direct I/O writes. This is neccessary for Linux, because anonymous pages can not be placed under write protection during Direct I/O writes." 그래서 기본값이 Linux는 1, FreeBSD는 0으로 플랫폼마다 다르다. 체크섬이 맞지 않으면 쓰기는 `EIO`로 실패하고 `dio_verify_wr` zevent가 생기며, `zpool status -d`로 확인할 수 있다(`zfs(4)`). 이는 Direct I/O가 데이터 무결성 계약을 깨지 않게 하려는 비용이다. 애플리케이션이 I/O 도중 버퍼를 바꾸는 버그를 드러내는 효과도 있다.

**2.4의 수정: EINVAL 대신 uncached I/O로 폴백.** Alexander Motin의 PR #17218 "Wire O_DIRECT also to Uncached I/O"(2025-05-13 머지)는 Direct I/O의 한계를 정면으로 다룬다. "While Direct I/O has the lowest possible memory bandwidth usage, it also has a significant number of limitations. It require I/Os to be page aligned, does not allow speculative prefetch, etc." 그래서 정렬되지 않은 `O_DIRECT` 요청을 일반 DMU/ARC 경로로 처리하되 캐시에서 가능한 한 빨리 내보내는 "Uncached I/O"로 보내고, `EINVAL`을 기본으로 끄는 방향을 택했다. 현재 `zfs(4)`의 `zfs_dio_strict`(기본 0)는 "Strictly enforce alignment for Direct I/O requests, returning EINVAL if not page-aligned instead of silently falling back to uncached I/O"로 문서화되어 있다. 2.4.0 릴리스 노트의 "Uncached IO: Direct IO fallback to a light-weight uncached IO when unaligned (#17218, #17407, #17872, #17875)" 항목이 이 변화다.

### 3.2 vdev 큐를 NVMe에서 아예 건너뛸 것인가

vdev 큐는 회전 디스크 시대의 설계다. LBA 정렬 AVL 트리와 집계(aggregation, `zfs_vdev_aggregation_limit = 1 << 20`, 비회전 장치는 `zfs_vdev_aggregation_limit_non_rotating = SPA_OLD_MAXBLOCKSIZE`), read/write gap 병합(`zfs_vdev_read_gap_limit = 32 << 10`, `zfs_vdev_write_gap_limit = 4 << 10`)이 그 흔적이다. PR #16591 "Add vdev property to bypass vdev queue"(작성자 MigeljanImeri)는 동기를 "The intention behind this property is to improve performance when using o_direct"라고 적었다. 이 PR 자체는 머지되지 않고 닫혔다(GitHub API `merged_at: null`). 그러나 현재 `master`의 `vdevprops(7)`에는 leaf vdev 속성 `scheduler=auto|on|off`가 있고, `auto`는 "queue I/O if the vdev is backed by a rotational block device or file, and not queue otherwise"로 설명된다. 이 속성은 zfs-2.4.4 태그의 `vdevprops.7`에는 없으므로 아직 릴리스되지 않은 기능이다. 어느 릴리스에 들어갈지는 `[추측/미확인]`이다.

쟁점은 공정성이다. 큐를 건너뛰면 클래스별 `min_active`/`max_active`가 보장하던 우선순위(예: scrub이 sync read를 굶기지 않게 하는 것)가 사라진다. NVMe의 내부 병렬성과 장치 큐에 맡기는 쪽이 지연에는 유리하지만, scrub/resilver 간섭 제어는 약해진다.

### 3.3 Block cloning: 기능의 가치와 2.2.0 데이터 손상 사건

Pawel Jakub Dawidek의 PR #13392 "Block Cloning"(2023-03-10 머지)은 BRT(Block Reference Table)로 블록 참조 횟수를 관리해 `FICLONE`/`FICLONERANGE`/`copy_file_range()`를 메타데이터 연산으로 만들었다. 2.2.0 릴리스 노트는 "Many common file copying programs, including newer versions of `/bin/cp` on Linux, will try to create clones automatically."라고 적었다. 바로 이 점이 문제를 키웠다. 이슈 #15526 "some copied files are corrupted (chunks replaced by zeros)"가 보고되자 2.2.1(2023-11-22)은 block cloning을 기본으로 껐다. 2.2.1 노트에는 "zfs-2.2.1 disables block cloning by default"라고 되어 있고, 소스에서는 `module/os/linux/zfs/zpl_file_range.c`의 `int zfs_bclone_enabled = 0;`이다. 그런데 2.2.2(2023-12-01) 노트에 따르면 근본 원인은 block cloning 자체가 아니었다. 원인은 "an incorrect dirty dnode check"(`dnode_is_dirty`, PR #15571)였고, coreutils 9.x `cp`의 `SEEK_DATA`/`SEEK_HOLE` 사용 변화로 드러난 것이다. 이 버그는 2.1.x에도 영향을 주어 2.1.14가 함께 나왔다. 기본값은 2.3.0에서 `zfs_bclone_enabled = 1`로 돌아왔다(위치는 `module/zfs/zfs_vnops.c`, 2.3.0 태그로 확인).

교훈은 두 가지다. 첫째, 커널 VFS 쪽 기본 동작 변화(여기서는 coreutils와 `copy_file_range`)가 out-of-tree 파일시스템의 잠복 버그를 갑자기 드러낼 수 있다. 둘째, ZFS는 이런 상황에 module parameter 기본값을 바꾸는 방식으로 빠르게 대응한다. 현재 `master`에는 `zfs_bclone_wait_dirty = 1`도 있다. `FICLONE` 시 더티 데이터가 디스크에 쓰일 때까지 기다리게 하는 이 설정은 더티 블록 cloning 경로의 위험을 줄이는 방향이다.

### 3.4 Linux 통합: GPL-only 심볼과 "tolerance" 논쟁

Linux 5.0 개발 주기에 `x86/fpu: Don't export __kernel_fpu_{begin,end}()` 패치가 들어가면서 ZFS on Linux의 SIMD 체크섬/패리티 구현이 빌드되지 않았다. 대안인 `kernel_fpu_begin()`은 GPL-only export다. 이 스레드에서 Greg Kroah-Hartman은 이렇게 답했다.

> "My tolerance for ZFS is pretty non-existant. Sun explicitly did not want their code to work on Linux, so why would we do extra work to get their code to work properly?"
> — Greg Kroah-Hartman, "Re: x86/fpu: Don't export __kernel_fpu_{begin,end}()", 2019-01-10 (LKML 아카이브 미러 [lkml.iu.edu 1901.1/03500](https://lkml.iu.edu/hypermail/linux/kernel/1901.1/03500.html)에서 원문 확인. lore.kernel.org 원본은 봇 차단으로 직접 확인하지 못함)

해설: 메인라인은 "in-kernel 사용자가 없는 심볼은 export하지 않는다"는 원칙을 지킨다. 같은 메일의 앞 문장은 GPL 심볼을 감싸는 래퍼 방식("GPL condom")도 받아들일 수 없다고 했다. 따라서 ZFS는 라이선스 경계를 존중하면서 스스로 우회해야 한다. 현재 `include/os/linux/kernel/linux/simd_x86.h`는 두 경로를 둔다. 커널이 FPU 심볼을 export하면(`KERNEL_EXPORTS_X86_FPU`) `kernel_fpu_begin()` 또는 `__kernel_fpu_begin()`을 쓴다. 그렇지 않으면 "When the kernel_fpu_* symbols are unavailable then provide our own versions which allow the FPU to be safely used" 주석과 함께 XSAVE 영역을 직접 저장·복원하는 자체 구현(`HAVE_KERNEL_FPU_INTERNAL`)을 쓴다. OpenZFS 공식 License 페이지는 이 긴장을 이렇게 요약한다. "The combination of them causes problems because it prevents using pieces of code exclusively available under one license with pieces of code exclusively available under the other in the same binary."

API 변화 비용은 릴리스 노트의 지원 커널 범위에서 그대로 보인다. 2.1.0은 3.10-5.13, 2.2.0은 3.10-6.5, 2.3.0은 4.18-6.12, 2.4.0은 4.18-6.18, 2.4.4는 4.18-7.2다. 2.2.x 패치 릴리스에도 "Linux 6.6 compat" 같은 항목이 계속 나온다. 새 메인라인 커널이 나오면 bio/`blk_*` API, `iov_iter`, folio, VFS inode 연산 시그니처 변화를 `config/kernel-*.m4` 검사와 `HAVE_*` 매크로로 흡수해야 한다. 그래서 배포판 커널을 최신 메인라인으로 빨리 올리면 ZFS 지원이 늦어지는 상황이 반복된다.

---

## 4. Implementation Impact

### 4.1 `zio_t`와 단계 비트마스크 (master 기준)

`include/sys/zio.h`의 `struct zio`(typedef `zio_t`)에서 파이프라인과 직접 관련된 필드는 다음과 같다.

- `enum zio_stage io_stage`, `io_pipeline`: 현재 단계와 남은 단계 비트마스크. `io_orig_stage`/`io_orig_pipeline`은 재시도용 원본이고, `io_pipeline_trace`는 지나간 단계 기록이다.
- `zio_priority_t io_priority`: vdev 큐 클래스
- `blkptr_t *io_bp`, `vdev_t *io_vd`, `enum zio_child io_child_type`: 블록 포인터, 대상 vdev, 자식 유형(vdev/gang/ddt/logical)
- `io_queue_node`(`____cacheline_aligned`): allocator 큐와 vdev 큐가 공유하는 노드
- `void *io_executor`: 현재 이 zio를 실행 중인 스레드

`include/sys/zio_impl.h`는 단계를 `1 << n` 비트로 정의한다. 주석의 `RWFCXT` 열은 Read/Write/Free/Claim/ioctl(X)/Trim 중 어느 I/O 유형이 그 단계를 쓰는지 표시한다.

| 비트 | 단계 | 적용 유형 | 역할 |
|---|---|---|---|
| 0 | `ZIO_STAGE_OPEN` | RWFCXT | 시작 |
| 1-3 | `READ_BP_INIT` / `WRITE_BP_INIT` / `FREE_BP_INIT` | R / W / F | bp 초기화, 임베디드 bp·nopwrite 판단 준비 |
| 4 | `ISSUE_ASYNC` | -WF--T | taskq로 넘겨 호출자 스레드 해방 |
| 5-7 | `WRITE_COMPRESS` / `ENCRYPT` / `CHECKSUM_GENERATE` | W | 압축, 암호화, 체크섬 |
| 8 | `NOP_WRITE` | W | 체크섬이 같으면 쓰기 생략(nopwrite) |
| 9-12 | `DDT_READ_START` / `DDT_READ_DONE` / `DDT_WRITE` / `DDT_FREE` | R/W/F | dedup |
| 13 | `BRT_FREE` | F | block cloning 참조 감소 |
| 14-15 | `GANG_ASSEMBLE` / `GANG_ISSUE` | RWFC | gang block |
| 16-19 | `DVA_THROTTLE` / `DVA_ALLOCATE` / `DVA_FREE` / `DVA_CLAIM` | W/F/C | 할당 스로틀과 DVA 관리 |
| 20 | `READY` | RWFCXT | 자식 대기 interlock, `io_ready` 콜백 |
| 21-23 | `VDEV_IO_START` / `VDEV_IO_DONE` / `VDEV_IO_ASSESS` | RW--XT | vdev 발행, 완료, 재시도·에러 판정 |
| 24 | `CHECKSUM_VERIFY` | R | 읽기 체크섬 검증 |
| 25 | `DIO_CHECKSUM_VERIFY` | W | Direct I/O 쓰기 체크섬 재검증(2.3+) |
| 26 | `ZIO_STAGE_DONE` | RWFCXT | 완료, 부모 통지 |

`module/zfs/zio.c`의 `static zio_pipe_stage_t *zio_pipeline[]`는 이 순서대로 `zio_read_bp_init`, `zio_write_bp_init`, … `zio_dio_checksum_verify`, `zio_done` 함수를 담는다(첫 칸은 `NULL`인 OPEN). `__zio_execute()`는 `io_pipeline`에서 현재보다 높은 다음 비트를 찾아 그 함수를 호출한다. 단계 함수가 `NULL`을 반환하면 zio는 대기 상태가 되고(자식 대기, taskq 재디스패치, vdev 큐 대기 등), 나중에 `zio_taskq_dispatch()`로 재개된다.

조합 매크로의 예는 다음과 같다.

- `ZIO_WRITE_PIPELINE` = `ZIO_WRITE_COMMON_STAGES`(interlock + vdev I/O + `ISSUE_ASYNC` + `CHECKSUM_GENERATE`) + `WRITE_BP_INIT` + `WRITE_COMPRESS` + `ENCRYPT` + `DVA_THROTTLE` + `DVA_ALLOCATE`
- `ZIO_DIRECT_WRITE_PIPELINE` = `ZIO_WRITE_PIPELINE & (~ZIO_STAGE_ISSUE_ASYNC)`. Direct I/O 쓰기는 호출자 스레드에서 곧바로 압축·체크섬을 수행한다. 사용자 페이지를 고정한 채 비동기 taskq로 넘기지 않기 위해서다.
- `ZIO_DDT_WRITE_PIPELINE`은 `DVA_ALLOCATE` 대신 `DDT_WRITE`를 넣는다.

taskq는 `ZIO_TYPES × ZIO_TASKQ_TYPES` 행렬(`ZIO_TASKQ_ISSUE`, `ZIO_TASKQ_ISSUE_HIGH`, `ZIO_TASKQ_INTERRUPT`, `ZIO_TASKQ_INTERRUPT_HIGH`)이다. 설정은 `module/zfs/spa.c`의 `zio_taskqs[ZIO_TYPES][ZIO_TASKQ_TYPES]`에 있다. write issue taskq 크기는 `zio_taskq_batch_pct = 80`(%)이 좌우한다(`zfs(4)`).

### 4.2 콜패스: buffered write, TXG sync, Direct I/O

**Buffered write (Linux, master 기준)**

```
zpl_iter_write()                         // module/os/linux/zfs/zpl_file.c
 └ zfs_write()                           // module/zfs/zfs_vnops.c
    ├ zfs_setup_direct()                 // direct 속성·정렬 판단
    ├ dmu_write_uio_dbuf() → dbuf_dirty() // 열린 TXG에 더티 레코드
    └ zfs_log_write() → zil_write_state() // sync 요구 시 ZIL itx 생성
...
txg_sync_thread → spa_sync(spa, txg)     // module/zfs/spa.c
 └ dsl_pool_sync() → ... → dbuf_sync_leaf() → dbuf_write()
    └ arc_write() → zio_write() → zio_nowait()
       └ __zio_execute(): WRITE_BP_INIT → ISSUE_ASYNC → WRITE_COMPRESS
          → ENCRYPT → CHECKSUM_GENERATE → DVA_THROTTLE → DVA_ALLOCATE
          → READY → VDEV_IO_START
             └ zio_vdev_io_start(): vdev_mirror/raidz/draid 팬아웃
                └ leaf: vdev_queue_io(zio) → vd->vdev_ops->vdev_op_io_start
                   └ vdev_disk_io_start() → vdev_disk_io_rw()
                      → vbio_alloc()/vbio_submit() → submit_bio()
```

**Direct I/O write (2.3+)**: `zfs_write()` → `dmu_write_uio_direct()` → `dmu_write_abd()` → `dmu_write_direct()`(`module/zfs/dmu_direct.c`). 이 경로는 사용자 페이지로 만든 ABD를 그대로 `zio_write()`에 넘기고, `ZIO_DIRECT_WRITE_PIPELINE`을 따른다. Linux에서는 `VDEV_IO_DONE` 이후 `DIO_CHECKSUM_VERIFY`가 붙는다(`zfs_vdev_direct_write_verify`). 블록 포인터 갱신은 `dmu_write_direct_ready`/`dmu_write_direct_done` 콜백에서 dbuf 더티 레코드에 반영되고, TXG sync 때 메타데이터로 커밋된다. 읽기는 `dmu_read_uio_direct()` → `dmu_read_abd()` 경로이며 ARC에 사본이 있으면 ARC에서 복사한다(PR #10018 본문).

**Read**: `zfs_read()` → `dmu_read_uio_dbuf()` → `dbuf_read()` → `arc_read()`. 캐시 미스이면 `zio_read()`를 만들고 `READ_BP_INIT` → `VDEV_IO_START` → ... → `CHECKSUM_VERIFY`를 거친다. 체크섬이 실패하면 `VDEV_IO_ASSESS`/`zio_done`에서 미러의 다른 사본이나 RAIDZ 재구성을 시도하고, 성공하면 손상된 사본을 다시 쓴다(self-healing).

### 4.3 vdev 큐 스케줄러 (`module/zfs/vdev_queue.c`)

`vdev_queue_t`는 클래스별 `vq_class[p]`와 "대기 I/O가 있는 클래스" 비트맵 `vq_cqueued`를 가진다. `vdev_queue_class_fifo()`는 `ZIO_PRIORITY_SYNC_READ`, `ZIO_PRIORITY_SYNC_WRITE`, `ZIO_PRIORITY_TRIM`을 FIFO 리스트(`vqc_list`)로, 나머지를 오프셋 정렬 AVL 트리(`vqc_tree`)로 관리한다. 발행 경로는 다음과 같다.

1. `vdev_queue_io(zio)`: 자식 zio의 우선순위를 I/O 유형에 맞게 보정하고 `ZIO_FLAG_DONT_QUEUE`를 세운다. `master`에서는 `vdev_should_queue_io()`가 거짓이면(leaf vdev 속성 `scheduler`, 3.2절) `ZIO_FLAG_BYPASSED_QUEUE`를 세우고 큐 없이 바로 반환한다. 그렇지 않으면 `vq_lock`을 잡고 `vdev_queue_io_add()`로 클래스에 넣는다.
2. `vdev_queue_io_to_issue()` → `vdev_queue_class_to_issue()`: `min_active`를 채우지 못한 클래스를 우선 찾고, 그다음 `max_active` 미만 클래스를 찾는다. 전체 상한은 `zfs_vdev_max_active = 1000`이다.
3. `vdev_queue_aggregate()`: 인접 I/O를 집계 한도와 gap 한도 안에서 하나의 큰 zio로 묶는다.
4. 완료 시 `vdev_queue_io_done()`이 루프를 돌며 다음 I/O를 발행한다.

| 클래스 (`zio_priority_t`) | 출처 | 기본 min/max active | 큐 형태 |
|---|---|---|---|
| `SYNC_READ` | 대부분의 읽기 | 10 / 10 | FIFO |
| `SYNC_WRITE` | ZIL | 10 / 10 | FIFO |
| `ASYNC_READ` | prefetch | 1 / 3 | AVL |
| `ASYNC_WRITE` | `spa_sync()` | 2 / 10 (더티 비율 연동) | AVL |
| `SCRUB` | scrub/resilver 읽기 | 1 / 3 | AVL |
| `REMOVAL` | vdev removal | 1 / 2 | AVL |
| `INITIALIZING` | `zpool initialize` | 1 / 1 | AVL |
| `TRIM` | TRIM/UNMAP | 1 / 2 | FIFO |
| `REBUILD` | sequential resilver(2.0+) | 1 / 3 | AVL |

async write의 실제 `max_active`는 더티 데이터가 `zfs_dirty_data_max`의 `zfs_vdev_async_write_active_min_dirty_percent = 30`% 미만이면 min(2)에 머문다. 60%(`..._max_dirty_percent`)에서 max(10)까지 선형으로 늘어난다. 더티 데이터가 `zfs_delay_min_dirty_percent = 60`%를 넘으면 `dmu_tx_delay()`가 쓰기 트랜잭션 자체를 지연시킨다(`zfs_delay_scale`). 주석에 따르면 이 상태는 "the rate of incoming data is greater than the rate that the backend storage can handle"을 뜻한다. 비대화형 클래스(scrub 등)는 `zfs_vdev_nia_delay = 5`, `zfs_vdev_nia_credit = 5`로 대화형 I/O가 있을 때 더 억제된다.

### 4.4 ARC / L2ARC

- **ARC**: `zfs_arc_max`/`zfs_arc_min`(0이면 자동)이 상한과 하한이다. 2.2.0의 "Fully adaptive ARC"(PR #14359) 이후 MRU/MFU와 data/metadata 사이의 고정 비율 제한이 완화되었고, 메타데이터 비중은 `zfs_arc_meta_balance = 500`이 조절한다. `arc_read()`는 해시 테이블에서 `arc_buf_hdr_t`를 찾고, 미스이면 `zio_read()`를 만든다. 압축된 블록은 기본적으로 압축된 상태로 ARC에 둔다(compressed ARC, `arc.c`의 `int zfs_compressed_arc_enabled = B_TRUE;`).
- **L2ARC**: 별도 피더 스레드가 ARC 꼬리에서 eviction 직전 버퍼를 캐시 장치로 내린다. 주요 튜너블은 `l2arc_write_max`, `l2arc_headroom`, `l2arc_feed_secs`, `l2arc_noprefetch = B_TRUE`(prefetch 버퍼는 캐시하지 않음), `l2arc_meta_percent = 33`, `l2arc_trim_ahead`다. 현재 `master`에는 SSD 수명을 고려한 `l2arc_dwpd_limit = 100`("100 = 1.0 DWPD")도 있다. 2.0.0 릴리스(PR #9582)에서 Persistent L2ARC가 들어와 재부팅 후 워밍업이 사라졌다. L2ARC 헤더는 ARC 메모리를 차지하므로, 큰 L2ARC를 작은 RAM에 붙이면 오히려 ARC 적중률이 떨어진다.
- **Direct I/O와의 상호작용**: 정렬된 Direct I/O 쓰기는 ARC에 해당 블록의 캐시 사본이 있으면 버린다. 이후 읽기는 디스크에서 다시 가져온다(PR #10018 본문).

### 4.5 ZIL / SLOG

`zil_write_state()`(`module/zfs/zil.c`)는 각 쓰기 로그 레코드를 어떻게 남길지 정한다.

| 상태 | 의미 | 선택 조건(요약) |
|---|---|---|
| `WR_COPIED` | 데이터를 `lr_write_t`에 즉시 복사 | 작은 동기 쓰기. 로그 블록 하나에 들어가야 함 |
| `WR_NEED_COPY` | 커밋 시점에 데이터 복사 | 큰 쓰기 또는 `WR_COPIED`가 로그 블록을 넘칠 때 |
| `WR_INDIRECT` | 데이터를 메인 풀에 바로 쓰고 ZIL에는 bp만 기록 | `logbias=throughput`, `O_DIRECT`, 또는 SLOG가 없고 크기 ≥ `zfs_immediate_write_sz`(32 KiB) |

코드 기준으로 `if (zilog->zl_logbias == ZFS_LOGBIAS_THROUGHPUT || o_direct)`이면 indirect가 된다. 즉 Direct I/O 동기 쓰기는 데이터를 두 번 쓰지 않는다. SLOG 관련 튜너블로는 `zil_slog_bulk = 64 MiB`(이보다 큰 커밋은 낮은 우선순위로 SLOG에 발행), `zil_nocacheflush`, `zil_replay_disable`이 있다. 2.4.0부터는 SLOG가 없을 때 special vdev에 ZIL을 둘 수 있다(PR #17505, 소스의 `zil_special_is_slog = 1`).

SLOG는 동기 쓰기 지연만 줄인다. async write 처리량을 늘리지는 않는다. SLOG 장치가 TXG 2-3개 분량의 동기 쓰기만 담으면 충분한 이유도, 전원 손실 보호(PLP)가 있는 장치가 필요한 이유도 여기에 있다.

### 4.6 TXG sync와 더티 데이터 제어

| 튜너블 | 기본값 | 위치 | 역할 |
|---|---|---|---|
| `zfs_txg_timeout` | 5 (초) | `txg.c` | 열린 TXG 최대 수명 |
| `zfs_dirty_data_max` | 0 → 메모리의 `zfs_dirty_data_max_percent`(10%) | `dsl_pool.c` | 풀 더티 상한 |
| `zfs_dirty_data_sync_percent` | 20 | `dsl_pool.c` | 이 비율을 넘으면 timeout 전에 sync 시작 |
| `zfs_delay_min_dirty_percent` | 60 | `dsl_pool.c` | 이 비율부터 `dmu_tx_delay()` 쓰기 지연 |
| `zfs_vdev_async_write_active_{min,max}_dirty_percent` | 30 / 60 | `vdev_queue.c` | async write 동시성 곡선 |

이 다섯 값이 하나의 피드백 루프를 이룬다. 애플리케이션 쓰기 속도가 장치 속도를 넘으면 더티 데이터가 쌓인다. 그러면 vdev 큐가 async write 동시성을 올리고, 그래도 넘치면 트랜잭션 생성 단계에서 지연을 주입한다. 결과적으로 쓰기 지연이 매끄럽게 늘어난다.

### 4.7 체크섬·압축·RAID 레이아웃

- **체크섬**: `enum zio_checksum`에는 `ZIO_CHECKSUM_FLETCHER_2`, `FLETCHER_4`, `SHA256`, `SHA512`, `SKEIN`, `EDONR`, `BLAKE3` 등이 있다. BLAKE3는 2.2.0에서 추가되었다(PR #12918). 2.2.0 노트는 BLAKE3를 "the recommended secure checksum"이라 부른다. 같은 릴리스에서 SHA2는 하드웨어 가속을 쓰도록 최적화되었다(PR #13741). fletcher4·RAIDZ 패리티·AES-GCM이 SIMD(`kfpu_begin()`)에 의존하므로 3.4절의 FPU 문제가 곧 성능 문제다.
- **압축**: ZStandard 압축은 2.0.0(PR #10278)에 들어왔다. `ZIO_COMPRESS_RAW(ZIO_COMPRESS_ZSTD, level)` 매크로로 레벨을 bp에 인코딩한다.
- **dRAID (2.1.0, PR #10102, feature `org.openzfs:draid`)**: 생성 문법은 `draid[<parity>][:<data>d][:<children>c][:<spares>s]`이다. 분산 스페어로 sequential resilver를 한다. 공식 dRAID 문서는 트레이드오프를 이렇게 적는다. "it uses a fixed stripe width (padding as necessary with zeros). This allows a dRAID vdev to be sequentially resilvered, however the fixed stripe width significantly effects both usable capacity and IOPS. For example, with the default D=8 and 4k disk sectors the minimum allocation size is 32k."
- **RAIDZ expansion (2.3.0, PR #15022 by Don Brady, feature `org.openzfs:raidz_expansion`)**: `zpool attach <pool> raidz2-0 <new-dev>`로 한 디스크씩 넓힌다. 기존 데이터를 읽어 새 너비로 재배치(reflow)하며, 진행 상태는 uberblock의 `ub_raidz_reflow_info`에 기록된다(`vdev_raidz.c`). `zpool-attach(8)`에 따르면 "old blocks retain their old data-to-parity ratio"이고 새 블록만 새 비율로 쓰인다. 그래서 확장 직후의 공간 효율은 처음부터 넓게 만든 vdev보다 낮다.

### 4.8 Direct I/O 동작 매트릭스 (2.4.x / master)

| 요청 | `direct=disabled` | `direct=standard`(기본) | `direct=always` |
|---|---|---|---|
| `O_DIRECT`, 페이지 정렬, `recordsize` 정렬 쓰기 | ARC 경유 | ARC 우회, `ZIO_DIRECT_WRITE_PIPELINE` | ARC 우회 |
| `O_DIRECT`, 페이지 정렬, `recordsize` 비정렬 쓰기 | ARC 경유 | 비정렬 부분만 ARC로 | 비정렬 부분만 ARC로 |
| `O_DIRECT`, 페이지 비정렬 | ARC 경유 | 2.3: `EINVAL` / 2.4+: uncached I/O 폴백(`zfs_dio_strict=1`이면 `EINVAL`) | ARC 경유 |
| 일반(buffered) 요청 | ARC | ARC | 정렬 조건을 만족하면 Direct |
| 전역 끄기 | — | `zfs_dio_enabled=0`이면 모두 `disabled`처럼 | 동일 |

mmap을 쓰는 파일에서 coherency가 어떻게 유지되는지는 `zfsprops(7)`에 별도 규칙이 있다. 이 문서에서는 전문을 확인하지 않았다 `[추측/미확인]`.

### 4.9 기능 도입 연표 (GitHub 릴리스 노트 기준)

| 릴리스 (날짜) | 기능 | PR |
|---|---|---|
| ZoL 0.8.0 (2019-05-23) | `O_DIRECT` 수용(ARC 경유) | #7823 (2018-08-27 머지) |
| 2.0.0 (2020-11-30) | FreeBSD 통합, Persistent L2ARC, ZStandard, sequential resilver | #8987, #9582, #10278, #10349 |
| 2.1.0 (2021-07-02) | dRAID, `compatibility` 속성 | #10102, #11468 |
| 2.2.0 (2023-10-13) | Block cloning, BLAKE3, Fully adaptive ARC, Linux container 지원 | #13392, #12918, #14359 |
| 2.2.1 (2023-11-22) | block cloning 기본 비활성화(`zfs_bclone_enabled=0`) | #15529 |
| 2.2.2 (2023-12-01) | dirty dnode 검사 데이터 손상 수정 | #15571 |
| 2.3.0 (2025-01-14) | RAIDZ expansion, Fast Dedup, Direct I/O, JSON 출력, 1023자 이름 | #15022, #15896, #10018, #16217, #15921 |
| 2.4.0 (2025-12-18) | uncached I/O 폴백, 통합 allocation throttling, special vdev ZIL, 기본 quota | #17218, #17020, #17505, #17130 |
| master (2026-10) | leaf vdev `scheduler=auto\|on\|off` (미릴리스) | — |

### 4.10 ext4/XFS(+md) 스택과의 비교

| 항목 | ext4/XFS + md/dm (in-tree) | OpenZFS (out-of-tree) |
|---|---|---|
| 캐시 | 페이지 캐시(folio), `O_DIRECT`는 iomap DIO로 우회 | ARC(+L2ARC). 2.3부터 `direct` 속성으로 우회 |
| I/O 스케줄링 | blk-mq 스케줄러(none/mq-deadline/BFQ/kyber) | vdev 큐 9클래스 + 그 아래 blk-mq 스케줄러(2단) |
| 데이터 체크섬 | 없음(XFS는 메타데이터 CRC만) | 모든 블록 체크섬, 읽기 시 검증, 자가 치유 |
| Direct I/O 비용 | 사용자 페이지 → bio, 복사 없음 | 사용자 페이지 → ABD → ZIO 파이프라인(체크섬/압축/패리티), Linux에서는 쓰기 재검증 |
| 동기 쓰기 | 저널(jbd2/XFS log) + `REQ_PREFLUSH`/`REQ_FUA` | ZIL(+SLOG), `WR_INDIRECT`로 이중 쓰기 회피 |
| reflink | XFS `FICLONE` | 2.2+ BRT block cloning |
| RAID 확장 | md `--grow` | 2.3+ RAIDZ expansion(기존 블록은 옛 비율 유지) |
| 커널 API 결합 | 메인라인과 동시 변경 | `config/kernel-*.m4` + `HAVE_*` 호환층, GPL-only 심볼 사용 불가 |

### 4.11 운영 관점 요약

1. **NVMe 풀**: `direct=standard`(기본)에서 애플리케이션이 `O_DIRECT`를 쓰면 ARC memcpy를 피할 수 있다. 다만 `recordsize`보다 작은 쓰기나 정렬되지 않은 쓰기는 여전히 ARC/RMW 경로를 탄다. 데이터베이스 페이지 크기와 `recordsize`를 맞추는 것이 Direct I/O 효과의 전제다.
2. **Linux에서 Direct I/O 쓰기**: `zfs_vdev_direct_write_verify=1`이 기본이라 쓰기마다 체크섬을 한 번 더 계산한다. I/O 도중 버퍼를 바꾸는 애플리케이션은 `EIO`와 `dio_verify_wr` 이벤트를 만난다.
3. **혼합 워크로드**: scrub/resilver가 서비스 지연을 해치면 `zfs_vdev_scrub_max_active`를 낮추거나 `zfs_vdev_nia_*`를 조정한다. 반대로 NVMe에서 vdev 큐가 병목이면 `zfs_vdev_*_max_active`를 올리거나, 향후 릴리스의 `scheduler=off`를 검토할 수 있다.
4. **커널 업그레이드**: 릴리스 노트의 "compatible with X - Y kernels" 범위를 먼저 확인한다. 범위 밖 커널에서는 DKMS 빌드가 실패하거나, 빌드되더라도 보장되지 않는다.

---

## 5. Primary References

- [openzfs/zfs — include/sys/zio_impl.h](https://github.com/openzfs/zfs/blob/master/include/sys/zio_impl.h) — `ZIO_STAGE_*` 비트, `ZIO_WRITE_PIPELINE`, `ZIO_DIRECT_WRITE_PIPELINE`
- [openzfs/zfs — module/zfs/zio.c](https://github.com/openzfs/zfs/blob/master/module/zfs/zio.c) — `zio_pipeline[]`, `__zio_execute()`, `zio_vdev_io_start()`
- [openzfs/zfs — module/zfs/vdev_queue.c](https://github.com/openzfs/zfs/blob/master/module/zfs/vdev_queue.c) — ZFS I/O Scheduler 주석, `zfs_vdev_*_active`, 집계
- [openzfs/zfs — module/zfs/zil.c](https://github.com/openzfs/zfs/blob/master/module/zfs/zil.c) — `zil_write_state()`, `zfs_immediate_write_sz`, `zil_slog_bulk`
- [openzfs/zfs — module/zfs/dmu_direct.c](https://github.com/openzfs/zfs/blob/master/module/zfs/dmu_direct.c) — `dmu_write_direct()`, `dmu_read_uio_direct()`
- [openzfs/zfs — include/os/linux/kernel/linux/simd_x86.h](https://github.com/openzfs/zfs/blob/master/include/os/linux/kernel/linux/simd_x86.h) — `kfpu_begin()`, `KERNEL_EXPORTS_X86_FPU`, `HAVE_KERNEL_FPU_INTERNAL`
- [Direct IO Support · Pull Request #10018 · openzfs/zfs](https://github.com/openzfs/zfs/pull/10018)
- [Direct IO support · Pull Request #7823 · openzfs/zfs](https://github.com/openzfs/zfs/pull/7823)
- [Wire O_DIRECT also to Uncached I/O · Pull Request #17218 · openzfs/zfs](https://github.com/openzfs/zfs/pull/17218)
- [Block Cloning · Pull Request #13392 · openzfs/zfs](https://github.com/openzfs/zfs/pull/13392)
- [raidz expansion feature · Pull Request #15022 · openzfs/zfs](https://github.com/openzfs/zfs/pull/15022)
- [Distributed Spare (dRAID) Feature · Pull Request #10102 · openzfs/zfs](https://github.com/openzfs/zfs/pull/10102)
- [some copied files are corrupted (chunks replaced by zeros) · Issue #15526 · openzfs/zfs](https://github.com/openzfs/zfs/issues/15526)
- [Add vdev property to bypass vdev queue · Pull Request #16591 · openzfs/zfs](https://github.com/openzfs/zfs/pull/16591) — 머지되지 않음
- [Release zfs-2.1.0 · openzfs/zfs](https://github.com/openzfs/zfs/releases/tag/zfs-2.1.0)
- [Release zfs-2.2.0 · openzfs/zfs](https://github.com/openzfs/zfs/releases/tag/zfs-2.2.0)
- [Release zfs-2.2.1 · openzfs/zfs](https://github.com/openzfs/zfs/releases/tag/zfs-2.2.1)
- [Release zfs-2.2.2 · openzfs/zfs](https://github.com/openzfs/zfs/releases/tag/zfs-2.2.2)
- [Release zfs-2.3.0 · openzfs/zfs](https://github.com/openzfs/zfs/releases/tag/zfs-2.3.0)
- [Release zfs-2.4.0 · openzfs/zfs](https://github.com/openzfs/zfs/releases/tag/zfs-2.4.0)
- [zfsprops.7 — OpenZFS documentation](https://openzfs.github.io/openzfs-docs/man/master/7/zfsprops.7.html) — `direct` 속성
- [zfs.4 — OpenZFS documentation](https://openzfs.github.io/openzfs-docs/man/master/4/zfs.4.html) — `zfs_dio_strict`, `zfs_vdev_direct_write_verify`, `zil_slog_bulk`
- [ZFS I/O (ZIO) Scheduler — OpenZFS documentation](https://openzfs.github.io/openzfs-docs/Performance%20and%20Tuning/ZIO%20Scheduler.html)
- [dRAID — OpenZFS documentation](https://openzfs.github.io/openzfs-docs/Basic%20Concepts/Pool%20Structure/dRAID%20Howto.html)
- [License — OpenZFS documentation](https://openzfs.github.io/openzfs-docs/License.html)
- [Re: x86/fpu: Don't export __kernel_fpu_{begin,end}() (LKML 아카이브 미러, 2019-01-10)](https://lkml.iu.edu/hypermail/linux/kernel/1901.1/03500.html) — Greg Kroah-Hartman 발언 원문. 1차 메일링 리스트(lore.kernel.org) 원본은 봇 차단으로 직접 대조하지 못함
