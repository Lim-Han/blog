# 페이지 캐시와 writeback: folio, readahead, dirty throttling, `RWF_DONTCACHE`

> 기준 버전: Linux 7.3-rc7 master(2026-10). 도입 시점은 git.kernel.org `?h=vX.Y` 태그별 grep으로 고정했다. "7.3 개발 주기"는 v7.2 태그에는 없고 master에만 있는 코드를 뜻한다.

## 1. Verdict

리눅스 페이지 캐시는 지난 5년 동안 단위(unit)를 바꾸는 대수술을 받았다. 핵심은 Matthew Wilcox의 **`struct folio`**(커밋 7b230db3b8d3 "mm: Introduce struct folio", Linux 5.16)다. folio는 "head page인 것이 보장된 `struct page`"이고, 2^n 개 페이지 묶음을 하나의 객체로 다룬다. 이것이 있어야 페이지 캐시가 4KiB 고정 단위를 벗어나 **large folio**(수십 KiB~수 MiB)를 담을 수 있다. 정착 순서는 다음과 같다.

1. **자료구조**: `address_space->i_pages`는 4.20에서 radix tree에서 `struct xarray`로 바뀌었다(v4.19 `struct radix_tree_root i_pages` → v4.20 `struct xarray i_pages`). dirty/writeback/towrite 상태는 xarray 마크 `PAGECACHE_TAG_DIRTY`(`XA_MARK_0`), `PAGECACHE_TAG_WRITEBACK`(`XA_MARK_1`), `PAGECACHE_TAG_TOWRITE`(`XA_MARK_2`)로 인덱스에 붙는다.
2. **folio 전환과 large folio 채택**:
   - 5.16: folio 도입
   - 5.17: XFS가 `mapping_set_large_folios()`로 large folio 허용(6795801366da "xfs: Support large folios")
   - 6.6: iomap의 블록 단위 dirty 추적(`struct iomap_folio_state`, `ifs_set_range_dirty()`)
   - 6.12: 최소 folio 차수(`mapping_set_folio_min_order()`/`mapping_set_folio_order_range()`)로 블록 크기 > 페이지 크기(LBS) 지원
   - 6.16: ext4 일반 파일 large folio(Zhang Yi 패치셋)
   - 6.17~7.1: btrfs large folio(`CONFIG_BTRFS_EXPERIMENTAL` 아래)
   - 7.2: btrfs large folio 기본 활성화
3. **읽기 경로**: `filemap_read()`(5.12에 `generic_file_buffered_read()`를 대체)는 `folio_batch` 단위로 캐시를 조회한다(5.17). 없으면 `page_cache_sync_ra()`, `PG_readahead` 표식에 걸리면 `page_cache_async_ra()`를 부른다. 6.11에서 `ondemand_readahead()`가 이 두 함수에 흡수되었고, 6.17에서 `struct file_ra_state`에 `order` 필드가 생겨 readahead가 folio 차수를 기억한다.
4. **쓰기와 throttling**: 버퍼드 쓰기는 folio를 더티로 만들고 `balance_dirty_pages_ratelimited()`를 거친다. 3.2의 Wu Fengguang "IO-less dirty throttling"으로 쓰는 태스크는 직접 writeback하지 않고, 목표 속도(`dirty_ratelimit`, `pos_ratio`)에 맞춰 잠든다(최대 `MAX_PAUSE` = 200ms). 4.2의 Tejun Heo cgroup writeback은 `bdi_writeback`을 memcg×blkcg 쌍마다 하나씩 두고 `wb_domain`을 cgroup별로 만들었다. 6.0의 `BDP_ASYNC`는 NOWAIT 쓰기(io_uring)가 잠드는 대신 `-EAGAIN`을 받게 했다.
5. **writeback 실행**: flusher는 `bdi_writeback`마다 하나인 delayed work `wb_workfn()`이다. `wb_do_writeback()` → `wb_writeback()` → `writeback_sb_inodes()` → `__writeback_single_inode()` → `do_writepages()` → `->writepages`로 내려간다. 6.9에 반복자 `writeback_iter()`가 들어왔고, 6.18에 콜백 기반 `write_cache_pages()`가 사라졌다. iomap은 6.17에 `->writeback_range`/`->writeback_submit` 구조로 재편되었다.
6. **`RWF_DONTCACHE`**: Jens Axboe의 "uncached buffered I/O"는 페이지 캐시를 거치되 I/O가 끝나면 folio를 즉시 버린다(`PG_dropbehind`). 연표는 다음과 같다.
   - 6.14: 인터페이스(`RWF_DONTCACHE`, `FOP_DONTCACHE`, af6505e5745b)
   - 6.15: XFS opt-in이 들어갔지만, 릴리스 직전 use-after-free 보고로 Linus Torvalds가 `FOP_DONTCACHE`를 0으로 정의해 전역 비활성화(478ad02d6844)
   - 6.16: 재활성화
   - 6.17: ext4
   - 6.18: NFS
   - 7.2: 쓰기 경로가 인라인 flush 대신 flusher를 깨우도록 변경(e1bf79628453)
   - 7.3 개발 주기: 블록 장치(8b5ffb43ae9d)

결론은 이렇다. 페이지 캐시 작업의 무게중심은 "캐시를 쓸 것인가 말 것인가"(`O_DIRECT` 대 버퍼드)에서 "캐시를 얼마나 큰 단위로, 얼마나 짧게 쓸 것인가"(large folio, dropbehind, writethrough 논의)로 옮겨 가고 있다. DIO 쪽 경로와 캐시 일관성 규칙은 (→ 11/01), 블록 계층의 writeback 쓰로틀(`blk-wbt`, `iocost`)은 (→ 02/02)를 참조한다.

---

## 2. Problem Statement

### 2.1 `struct page`가 너무 많은 것을 뜻했다
5.16 이전에는 페이지 캐시 API가 `struct page *`를 받았다. 그 페이지가 compound page의 head인지 tail인지는 호출자가 알 수 없었다. 그래서 거의 모든 함수 머리에 `compound_head()`가 있었다. tail page에 `PageDirty()`를 물으면 head로 거슬러 올라가는 숨은 비용이 있었고, THP를 페이지 캐시에 넣는 코드는 "이 페이지는 몇 바이트인가"를 곳곳에서 다시 계산했다. folio 타입은 "이 포인터는 head이고 크기는 `folio_size()`"임을 타입 시스템으로 보장한다. 이 보장이 있어서 파일시스템이 4KiB 고정을 버리고 large folio를 받아들일 수 있었다.

### 2.2 4KiB 단위의 고정 비용
페이지 캐시의 비용 대부분은 객체 개수에 비례한다. xarray 슬롯, LRU 리스트 조작, refcount, `lock_page`, readahead 할당, writeback 시 bio 세그먼트, 더티 회계가 모두 그렇다. 1MiB 순차 읽기는 4KiB folio로 256개, 2MiB folio 하나로는 1개다. LWN에 실린 ext4 large folio 패치셋(Zhang Yi, 2025-05-12 표지 메일)의 측정에서 이 패치셋 자체(buffer_head 경로 + large folio, "base+large folio" 열)는 버퍼드 읽기 1~60%, 버퍼드 쓰기 최대 100% 향상이었다. 같은 표의 "iomap+large folio" 열(별도 iomap 전환 시리즈와 결합)은 읽기 최대 67%, 쓰기 최대 168%였다. 블록 크기와 저장 매체(hole/ramdisk/NVMe)에 따라 다르며, 표지 메일의 조건(Xeon Gold 6240, 400GB RAM, fio)에 한정된다. 대가도 있다. folio 하나에 더티 비트가 하나뿐이면 1바이트만 써도 2MiB를 다시 써야 하는 쓰기 증폭이 생긴다. 이를 풀려고 6.6에 iomap의 블록 단위 dirty 비트맵이 들어왔다(LWN "Filesystems and iomap", 2024).

### 2.3 더티 페이지는 "얼마나"와 "누구의"가 동시에 문제다
더티 페이지가 너무 많으면 회수(reclaim)가 writeback을 기다리며 멈춘다. 너무 적으면 쓰기를 모을 수 없어 I/O 패턴이 나빠진다. 3.2 이전의 `balance_dirty_pages()`는 한계를 넘은 태스크가 직접 페이지를 써 내게 했다. 여러 태스크가 동시에 같은 장치에 랜덤하게 쓰면서 시크가 폭증했다. LWN은 당시 상황을 "direct reclaim also tends to create terrible I/O patterns"라고 요약했다(LWN "No-I/O dirty throttling", 2011-08-31). cgroup이 들어오자 문제가 하나 더 생겼다. memcg는 페이지 소유자를 알지만 blkcg는 writeback I/O를 누구에게 과금할지 몰랐다. Tejun Heo는 memcg 안의 기존 장치를 "does not throttle anything effectively"라고 평가했다(LWN "Writeback and control groups", 2015-06-17).

### 2.4 "한 번 읽고 버릴 데이터"가 캐시를 오염시킨다
대용량 순차 스캔, 백업, 랜덤 읽기 워킹셋이 메모리보다 큰 부하에서는 캐시가 금방 차고, 그 뒤로는 모든 I/O가 회수를 동반한다. Axboe의 2024 측정에서는 32코어 시스템의 28코어가량이 `kswapd`로 바빴다(LWN "The return of RWF_UNCACHED", 2024-12-04). 대안이던 `O_DIRECT`는 정렬 제약과 캐시 일관성 함정이 있었다(→ 11/01). `posix_fadvise(POSIX_FADV_DONTNEED)`는 사후 처리라서 이미 일어난 오염을 되돌릴 뿐이다.

---

## 3. The Debate

### 3.1 folio 풀 리퀘스트 논쟁 (2021)
Wilcox는 2021년 8월 5.15 머지 윈도에 folio 풀 리퀘스트를 보냈다. 메모리 관리 개발자 Johannes Weiner가 즉시 "strong reservations"를 표했다(LWN "The folio pull-request pushback", 2021-09-10). Weiner의 핵심 논지는 이렇다. folio는 결국 "물리적으로 연속된 페이지 묶음"이다. 그런데 이 개념이 파일시스템 같은 상위 계층에 메모리 관리 내부를 너무 많이 노출한다. 상위 계층이 쓸 더 추상적인 메모리 표현이 필요하다. 특히 Wilcox가 folio를 slab 같은 다른 `struct page` 사용자까지 넓히려는 구상에 대해 그는 이렇게 말했다.

> "As long as this is your ambition with the folio, I'm sorry but it's a NAK from me".
> — Johannes Weiner, [LWN "The folio pull-request pushback"](https://lwn.net/Articles/868598/)(2021-09-10)에 인용

Linus Torvalds는 API 개선을 긍정적으로 평가하면서도 메모리 관리 서브시스템에 큰 churn을 일으킨다는 점을 지적했다.

> "So I don't hate the patches. I think they are clever, I think they are likely worthwhile, but I also certainly don't love them."
> — Linus Torvalds, 같은 LWN 기사(2021-09-10)에 인용

Wilcox의 마지막 논거는 "The folio patch is here now"였다(같은 기사). 대안 설계는 아직 코드가 없다는 뜻이다. 결국 folio는 5.15를 놓치고 5.16에 들어갔다(v5.15 `mm_types.h`에 `struct folio` 없음, v5.16에 있음). 범위는 페이지 캐시 쪽으로 좁혀졌다. slab을 `struct page`에서 떼어 내는 일은 별도의 `struct slab` 작업으로 갈라졌다(LWN "Pulling slabs out of struct page"). 이 논쟁의 유산은 지금의 "memdesc" 방향이다. 장기적으로 `struct page`를 줄이고 용도별 디스크립터(folio, slab, ptdesc…)로 나누는 계획이다. master `struct folio`의 `flags` 필드 타입이 이미 `memdesc_flags_t`인 것이 그 흔적이다.

### 3.2 "IO-less" dirty throttling (2010~2011)
Wu Fengguang의 패치셋은 v12까지 갔고(LWN "IO-less dirty throttling v12"), 3.2에 들어갔다. 개념은 단순했다. 태스크가 직접 써 내지 않고, 제어 루프가 정한 속도로 잠든다. 구현은 복잡했다. LWN의 Jonathan Corbet조차 "Your editor doesn't understand them either"라고 쓸 정도였다(LWN "No-I/O dirty throttling", 2011-08-31). 결과물은 지금도 `mm/page-writeback.c`의 큰 주석 그림으로 남아 있다. `freerun`(= `(thresh + bg_thresh) / 2`) 아래에서는 throttling이 없다. `setpoint`(= `(freerun + limit) / 2`)를 중심으로 3차 함수 형태의 `pos_ratio`가 속도를 조절한다. `wb_update_dirty_ratelimit()`는 장치별 실제 writeback 대역폭 추정치(`wb->avg_write_bandwidth`)를 따라 `dirty_ratelimit`를 갱신한다. 비판은 주로 "튜닝 불가능한 블랙박스"라는 점이었다. 이에 대한 응답은 sysctl과 bdi별 노브(`min_ratio`/`max_ratio`, 6.2의 `min_bytes`/`max_bytes`·`strict_limit`·`*_ratio_fine` sysfs)를 늘리는 쪽이었다.

### 3.3 cgroup writeback: "같은 메커니즘을 cgroup에도" (2015)
Tejun Heo의 설계 원칙은 cgroup 기능이 시스템 전체와 같은 메커니즘을 써야 한다는 것이었다(LWN "Writeback and control groups", 2015-06-17). `struct backing_dev_info` 하나에 있던 writeback 상태를 `struct bdi_writeback`으로 옮기고, 이를 cgroup마다 하나씩 만들었다. dirty 한계는 전역 `wb_domain`과 memcg별 `wb_domain` 중 더 엄격한 쪽을 따른다. 코드에서는 `gdtc`/`mdtc` 두 `struct dirty_throttle_control`로 나타난다. 남은 난제는 공유 inode다. inode 하나는 하나의 wb에만 속한다. 그래서 다른 cgroup이 주로 쓰는 inode는 "foreign" 판정 후 `inode_switch_wbs()`로 옮긴다. 판정은 `wbc_detach_inode()`의 투표 이력으로 한다. 지원은 파일시스템 opt-in(`SB_I_CGROUPWB`)이다. master에서 이를 설정하는 곳은 ext2, ext4, btrfs, f2fs, XFS다(GitHub 코드 검색 기준). cgroup v2에서만 동작한다.

### 3.4 `RWF_UNCACHED` → `RWF_DONTCACHE`: 새 플래그인가, fadvise인가
Axboe는 2019년에 `RWF_UNCACHED`를 처음 제안했다(LWN "Buffered I/O without page-cache thrashing", 2019-12-12). 하지만 작업이 페이지 캐시를 아예 피하는 방향으로 흐르다 멈췄다. 2024년 재제안은 "페이지 캐시를 정상적으로 쓰되 끝나면 지운다"로 돌아왔다. iomap 덕에 파일시스템 지원 비용도 낮아졌다. XFS 개발자 Darrick Wong은 반겼다.

> "there's plenty of places where this could be useful to me personally".
> — Darrick J. Wong, [LWN "The return of RWF_UNCACHED"](https://lwn.net/Articles/998783/)(2024-12-04)에 인용

Dave Chinner는 새 플래그 대신 기존 `POSIX_FADV_NOREUSE`에 이 동작을 넣으라고 주장했다. Axboe는 비동기 I/O에는 I/O 단위 플래그가 맞다고 반박했다(원문은 → 11/01의 3.1). 최종 이름은 `RWF_DONTCACHE`가 되었다. 커널 내부 상태는 `PG_dropbehind` folio 플래그로, 파일시스템 opt-in은 `FOP_DONTCACHE`로 표현된다.

### 3.5 6.15 릴리스 직전의 전역 비활성화
`RWF_DONTCACHE`는 페이지 캐시 수명 규칙을 바꾸는 기능이라 위험했다. 그 위험은 실제로 드러났다. 6.15 릴리스 직전 Al Viro가 use-after-free로 인한 메모리 손상을 보고했다. Linus Torvalds는 커밋 메시지에 이렇게 남겼다.

> "This is kind of last-minute, but Al Viro reported that the new FOP_DONTCACHE flag causes memory corruption due to use-after-free issues."
> — Linus Torvalds, [Disable FOP_DONTCACHE for now due to bugs (commit 478ad02d6844)](https://github.com/torvalds/linux/commit/478ad02d6844217cc7568619aeb0809d93ade43d), 2025-05-25

같은 메시지에 따르면 원인 후보는 writeback 완료 시 folio를 버리는 `folio_end_writeback()` 쪽 로직이다(Vlastimil Babka의 추정). XFS opt-in 커밋 974c5e6139db는 원인이 아니라 첫 사용자일 뿐이었다. 다른 파일시스템도 opt-in을 시작하고 있다는 Wilcox의 지적에 따라 커밋 하나를 되돌리지 않고 플래그 자체를 0으로 정의했다. v6.15의 `include/linux/fs.h`에는 실제로 `#define FOP_DONTCACHE 0 /* ((__force fop_flags_t)(1 << 7)) */`가 남아 있다. 따라서 **6.15 릴리스에서 `RWF_DONTCACHE`는 모든 파일시스템에서 `-EOPNOTSUPP`이다.** Jens Axboe의 revert(7b2b67dbd449)와 "dropbehind fixes and cleanups" 시리즈가 6.16-rc에 들어가 기능이 복구되었다. 이 사건은 dropbehind가 writeback 완료 컨텍스트(인터럽트에 가까운 컨텍스트)에서 folio를 무효화한다는 점을 보여 준다. 이것이 페이지 캐시 수명 규칙에서 가장 섬세한 지점이다. 이후 `folio_end_writeback_no_dropbehind()`처럼 dropbehind를 미룰 수 있는 API가 생긴 배경이다.

### 3.6 dontcache 쓰기의 지연 문제 (2026)
초기 구현은 `generic_write_sync()`에서 `IOCB_DONTCACHE`이면 쓰기 직후 해당 범위를 직접 flush했다(6.14의 `filemap_fdatawrite_range_kick()`, 이후 `filemap_flush_range()`). Jeff Layton의 커밋 e1bf79628453은 이 인라인 writeback 제출이 쓰는 태스크를 수 ms씩 막는다고 지적했다. 커밋 메시지의 측정에서는 p99.9 지연이 버퍼드 23ms에서 dontcache 93ms로 늘었다. 해법은 flusher를 깨우는 것이다. `filemap_dontcache_kick_writeback()`이 `WB_start_dontcache` 비트를 세우고, `wb_check_start_dontcache()`가 per-wb `WB_DONTCACHE_DIRTY` 카운터만큼 가장 오래된 더티 inode부터 써 낸다. v7.1 태그까지는 인라인 방식이고 v7.2부터 이 방식이다. "캐시를 오래 붙잡지 않는다"와 "쓰기 지연을 늘리지 않는다"를 동시에 만족시키려면 결국 writeback 서브시스템의 배치에 기대야 한다는 결론이다.

---

## 4. Implementation Impact

### 4.1 자료구조: `address_space`, xarray, folio
- `struct address_space`(master `include/linux/fs.h`): `host`, `i_pages`(`struct xarray`), `invalidate_lock`, `gfp_mask`, `i_mmap`, `nrpages`(xa_lock 보호), `a_ops`, `flags`. `flags`의 비트 16~25는 `AS_FOLIO_ORDER_MIN`/`AS_FOLIO_ORDER_MAX`로, 이 매핑이 허용하는 folio 차수 범위를 담는다(`AS_FOLIO_ORDER_BITS = 5`). 파일시스템은 `mapping_set_large_folios()`나 `mapping_set_folio_order_range()`로 이 값을 정한다. `AS_STABLE_WRITES`는 writeback 중 folio 수정을 금지하는 매핑 표시다(→ 11/01의 바운스 DIO).
- `struct folio`(master `include/linux/mm_types.h`): `flags`(`memdesc_flags_t`), `lru`, `mapping`, `index`, `private`(iomap은 여기에 `struct iomap_folio_state`를 둔다), `_mapcount`, `_refcount`, `memcg_data`. large folio의 크기와 mapcount 등은 둘째 페이지 이후 공간에 있다.
- xarray에서 large folio는 차수만큼의 인덱스 범위를 한 multi-index 엔트리로 차지한다. dirty/writeback 마크도 엔트리 단위다. 그래서 folio 안 블록 단위 dirty 정보는 파일시스템이 따로 들고 있어야 한다. iomap은 `ifs->state` 비트맵 하나에 uptodate 비트와 dirty 비트를 함께 둔다(6.6).

### 4.2 버퍼드 읽기 경로 (`filemap_read`)
```
->read_iter (예: xfs_file_buffered_read: XFS_IOLOCK_SHARED 아래)
 └ filemap_read(iocb, iter, already_read)
    loop:
     filemap_get_pages()
       ├ filemap_get_read_batch()          ── RCU 아래 xarray 순회, folio_batch에 refcount 잡아 담기
       ├ (없음) page_cache_sync_ra()        ── IOCB_NOIO면 중단, IOCB_DONTCACHE면 ractl.dropbehind=1
       ├ (여전히 없음) filemap_create_folio()  ── IOCB_NOWAIT|IOCB_WAITQ면 -EAGAIN, dropbehind 표시 후 ->read_folio
       ├ folio_test_readahead() → filemap_readahead() → page_cache_async_ra()
       └ !uptodate → filemap_update_page()  ── NOWAIT면 -EAGAIN, WAITQ면 wait queue 콜백 등록
     copy_folio_to_iter() …, folio_mark_accessed()
     filemap_end_dropbehind_read()           ── dropbehind folio는 복사 후 바로 무효화 시도
```
readahead 상태는 `struct file_ra_state`(`start`, `size`, `async_size`, `ra_pages`, `order`(6.17), `mmap_miss`, `prev_pos`)다.
- 첫 sync readahead 창은 `get_init_ra_size()`가 정한다. 요청 크기를 2의 거듭제곱으로 올린 뒤, 최대치의 1/32 이하면 4배, 1/4 이하면 2배, 그 밖에는 최대치를 쓴다.
- 창의 `size - async_size` 지점 folio에 `PG_readahead`를 표시한다. 이 플래그는 `PG_reclaim`과 같은 비트다(소스 주석).
- 읽기가 그 folio에 닿으면 `page_cache_async_ra()`가 `get_next_ra_size()`로 창을 키운다. 최대치의 1/16 미만이면 4배, 1/2 이하면 2배다.
- 기본 최대치는 `VM_READAHEAD_PAGES`(128KiB)이고, bdi의 `read_ahead_kb`로 바뀐다.
- `page_cache_ra_order()`는 `mapping_max_folio_order()` 범위 안에서 folio 차수를 올려 가며 할당한다(`ra_alloc_folio()`).
- mmap 폴트 경로(`do_sync_mmap_readahead()`)는 `VM_SEQ_READ`/`VM_RAND_READ`/`VM_HUGEPAGE` 힌트를 따른다. `mmap_miss`가 `MMAP_LOTSAMISS`(100)를 넘으면 readahead를 줄인다.

### 4.3 버퍼드 쓰기와 dirty throttling
```
iomap_file_buffered_write() → iomap_write_iter()          generic_perform_write() (buffer_head 계열)
  ├ balance_dirty_pages_ratelimited_flags(mapping,           ├ balance_dirty_pages_ratelimited()
  │     NOWAIT면 BDP_ASYNC)  ── -EAGAIN 가능                ├ ->write_begin / copy / ->write_end
  ├ __iomap_get_folio(): fgf_set_order(len), DONTCACHE면 FGP_DONTCACHE
  ├ copy_folio_from_iter_atomic()
  └ iomap_write_end() → filemap_dirty_folio()/ifs_set_range_dirty() → PAGECACHE_TAG_DIRTY, inode → wb->b_dirty
```
`balance_dirty_pages_ratelimited_flags()`는 태스크별 `nr_dirtied`가 `nr_dirtied_pause`를 넘을 때만 비싼 `balance_dirty_pages()`를 부른다. per-CPU `bdp_ratelimits`가 이를 보조한다. `balance_dirty_pages()` 한 바퀴는 다음과 같다.
1. 전역(`gdtc`)과 memcg(`mdtc`) 각각에 대해 dirtyable 메모리와 `thresh`/`bg_thresh`를 계산한다(`domain_dirty_limits()`).
2. 양쪽 모두 `freerun` 이하이면 통과한다. 백그라운드 한계를 넘었으면 `wb_start_background_writeback()`으로 flusher만 깨운다.
3. 그렇지 않으면 `wb_position_ratio()`로 `pos_ratio`를 구한다. 그 값에 `wb->dirty_ratelimit`를 곱한 `task_ratelimit`로 쉴 시간 `pause`를 계산한다.
4. `BDP_ASYNC`면 `-EAGAIN`을 돌려준다. 아니면 `io_schedule_timeout(pause)`로 잔다(최대 `MAX_PAUSE` = `max(HZ/5, 1)`).

`BDI_CAP_STRICTLIMIT`(FUSE 기본, sysfs `strict_limit`)인 bdi는 전역이 freerun 이하여도 자기 몫(`wb_thresh`)을 넘으면 throttle된다. 믿을 수 없는 백엔드가 전역 더티 예산을 독식하지 못하게 하는 장치다. FUSE는 슈퍼블록 초기화에서 `BDI_CAP_STRICTLIMIT`를 켜고 `bdi_set_max_ratio(sb->s_bdi, 1)`로 몫을 1%로 묶는다(`fs/fuse/inode.c`).

| sysctl / sysfs | 기본값 (master) | 의미 |
|---|---|---|
| `vm.dirty_background_ratio` / `_bytes` | 10% / 0 | 넘으면 flusher가 백그라운드 writeback 시작 |
| `vm.dirty_ratio` / `_bytes` | 20% / 0 | 하드 한계. 이 근처에서 쓰는 태스크가 throttle됨(`_bytes`가 0이 아니면 `_ratio` 대신 사용) |
| `vm.dirty_expire_centisecs` | 3000 (30초) | 이보다 오래된 더티 inode는 kupdate식 writeback 대상 |
| `vm.dirty_writeback_centisecs` | 500 (5초) | 주기적 flusher 깨움 간격 |
| `vm.dirtytime_expire_seconds` | 43200 (12시간) | lazytime의 타임스탬프 전용 더티(`b_dirty_time`) 만료 |
| `/sys/class/bdi/<bdi>/{min,max}_ratio[_fine]`, `{min,max}_bytes`, `strict_limit` | 0 / 100 / – | bdi별 전역 더티 예산 몫. `*_fine`·`*_bytes`·`strict_limit` sysfs는 6.2 |
| `/sys/class/bdi/<bdi>/read_ahead_kb` | 128 | readahead 최대 창 |

### 4.4 writeback 실행 경로
```
wb_workfn(work)                                   ── bdi_writeback마다 하나인 delayed work (bdi_wq)
 └ wb_do_writeback(wb)
    ├ 큐에 쌓인 wb_writeback_work (sync(2), fsync 범위 밖 요청, 메모리 회수 요청 등) → wb_writeback()
    ├ wb_check_start_all()                         ── WB_start_all (wakeup_flusher_threads)
    ├ wb_check_start_dontcache()                   ── WB_start_dontcache (7.2)
    ├ wb_check_old_data_flush()                    ── dirty_writeback_interval마다 kupdate식, dirty_expire 지난 inode
    └ wb_check_background_flush()                  ── 백그라운드 한계 초과 시
 wb_writeback(): queue_io()로 b_dirty → b_io 이동 (만료 기준), __writeback_inodes_wb() → writeback_sb_inodes()
   └ __writeback_single_inode(inode, wbc)
       └ do_writepages(mapping, wbc) → a_ops->writepages
            iomap: iomap_writepages(wpc) → while (folio = writeback_iter(mapping, wbc, folio, &err))
                                              iomap_writeback_folio() → wpc->ops->writeback_range() (블록 매핑, ioend 누적)
                                           → wpc->ops->writeback_submit() (bio 제출, XFS는 ioend 완료에서 unwritten 변환·i_size 갱신)
```
`struct writeback_control`의 핵심 필드는 `nr_to_write`, `pages_skipped`, `range_start`/`range_end`, `sync_mode`(`WB_SYNC_NONE` 대 `WB_SYNC_ALL`), `for_kupdate`/`for_background`/`for_sync`, `tagged_writepages`, `range_cyclic`, `fbatch`, 그리고 cgroup용 `wb`/`wb_id`/`wb_lcand_id` 등이다. `WB_SYNC_ALL`이나 `tagged_writepages`면 먼저 `PAGECACHE_TAG_DIRTY`를 `PAGECACHE_TAG_TOWRITE`로 일괄 복사한 뒤 그 마크만 따라간다. 그러지 않으면 쓰는 도중 새로 더티가 된 페이지 때문에 `sync`가 끝나지 않는 livelock이 생긴다. inode 리스트는 `b_dirty` → `b_io` → (덜 끝나면) `b_more_io` 순으로 돌고, 타임스탬프만 더티인 lazytime inode는 `b_dirty_time`에 있다.

6.9의 `writeback_iter()`는 `write_cache_pages()`의 콜백 구조를 호출자 루프로 뒤집었다. 파일시스템은 folio를 하나씩 받아 자기 컨텍스트에서 처리하고, 콜백용 상태 포인터를 넘길 필요가 없다. 그 뒤 `write_cache_pages()`는 6.18에서 삭제되었다(v6.17 있음, v6.18 없음). iomap은 6.17에 `struct iomap_writeback_ops`를 `->writeback_range`/`->writeback_submit`로 재편했다. 이 구조에서 ioend를 쓰지 않는 사용자(예: FUSE 버퍼드 쓰기)도 iomap writeback을 쓸 수 있다(→ 11/03).

### 4.5 cgroup writeback의 배선
- **소유권**: folio는 `memcg_data`로 memcg에 과금된다. inode는 `inode->i_wb`로 하나의 `bdi_writeback`(memcg×blkcg 쌍)에 묶인다.
- **I/O 과금**: writeback이 folio마다 `wbc_account_cgroup_owner()`를 불러 실제 소유 cgroup을 집계한다. bio는 `wbc->wb`의 blkcg로 태그되어 `blk-iocost`/`blk-iolatency` 정책을 받는다(→ 02/02).
- **소유권 이전**: `wbc_detach_inode()`가 다수 소유자를 판정해 `inode_switch_wbs()`를 예약한다. 이전은 `inode_switch_wbs_work_fn()`에서 RCU와 `i_pages` xa_lock 아래 진행된다.
- **throttling**: `balance_dirty_pages()`는 `gdtc`(전역 `wb_domain`)와 `mdtc`(memcg `wb_domain`)를 모두 평가해 더 엄격한 쪽을 쓴다. memcg의 dirtyable 메모리는 `mdtc_calc_avail()`에서 memcg 파일 페이지와 여유분(headroom)으로 계산한다.
- **한계**: 파일시스템이 `SB_I_CGROUPWB`를 켜야 하고 cgroup v2여야 한다. 저널 커밋처럼 여러 cgroup의 메타데이터가 섞이는 I/O는 원래 cgroup에 정확히 과금되지 않는다. 이른바 priority inversion이며, 일반적으로 알려진 한계다. 파일시스템별 완화 수준은 확인하지 않았다 [추측/미확인].

### 4.6 `RWF_DONTCACHE`의 메커니즘
- **진입**: `kiocb_set_rw_flags()`가 `FOP_DONTCACHE`가 없거나 DAX면 `-EOPNOTSUPP`을 낸다.
- **읽기**: 새로 만드는 folio에만 `__folio_set_dropbehind()`를 건다(`filemap_create_folio()`, readahead의 `ractl->dropbehind`). 이미 캐시에 있던 folio는 건드리지 않는다. 복사가 끝나면 `filemap_end_dropbehind_read()`가 잠금을 시도해 깨끗한 folio를 무효화한다.
- **쓰기**: `__iomap_get_folio()`가 `FGP_DONTCACHE`로 folio를 얻는다. `__filemap_get_folio()`는 dropbehind가 아닌 일반 접근이 오면 `folio_test_clear_dropbehind()`로 표시를 지운다. 공유 데이터가 다른 사용자의 캐시에서 쫓겨나지 않게 하려는 것이다. writeback 완료 시 `folio_end_writeback()` → `folio_end_dropbehind()`가 folio를 버린다. 지연이 필요한 파일시스템은 `folio_end_writeback_no_dropbehind()` 후 따로 처리한다.
- **writeback 개시**: 6.14~7.1은 `generic_write_sync()`에서 인라인으로 범위를 flush했다. 7.2부터는 `filemap_dontcache_kick_writeback()`이 flusher를 깨운다(3.6).

| 지원 주체 | 도입 | 비고 |
|---|---|---|
| VFS 인터페이스 (`RWF_DONTCACHE`, `FOP_DONTCACHE`, filemap 읽기/쓰기 지원) | 6.14 | XFS/ext4/btrfs/f2fs/NFS 어느 것도 6.14에서 `FOP_DONTCACHE`를 설정하지 않음(태그 grep) |
| XFS (iomap 버퍼드 쓰기) | 6.15 (실효 6.16) | 6.15 릴리스는 `FOP_DONTCACHE = 0`으로 전역 비활성 |
| ext4 | 6.17 (ae21c0c0ac56) | write_begin/write_end 리팩터링과 함께 |
| NFS 클라이언트 | 6.18 | `fs/nfs/file.c` |
| 블록 장치 (`block/fops.c`) | 7.3 개발 주기 (8b5ffb43ae9d) | `FOP_BUFFER_RASYNC | FOP_DONTCACHE` |
| btrfs | master 미지원 | 2024 패치셋에는 포함되었으나 master `fs/btrfs/file.c`에 없음 |

### 4.7 레거시 대 현재 구조 비교
| 측면 | 레거시 (≈3.1 / 5.15 이전) | 현재 (7.3-rc7 master) |
|---|---|---|
| 캐시 인덱스 | radix tree (`i_pages`가 `radix_tree_root`, ~4.19) | `struct xarray` (4.20~), multi-index 엔트리로 large folio |
| 캐시 단위 | `struct page` 4KiB, `compound_head()` 반복 | `struct folio` 2^n 페이지, 매핑별 `AS_FOLIO_ORDER_MIN/MAX` |
| 블록 단위 상태 | `buffer_head` 리스트(페이지당 블록 수만큼) | iomap `struct iomap_folio_state` 비트맵(uptodate+dirty, 6.6) 또는 `buffer_head`(ext4 등) |
| readahead | `ondemand_readahead()` 단일 함수 | `page_cache_sync_ra()`/`page_cache_async_ra()`(6.11), `page_cache_ra_order()`로 차수 증가, `ra->order`(6.17) |
| dirty throttling | 한계 초과 태스크가 직접 writeback(~3.1) | IO-less: `pos_ratio`×`dirty_ratelimit`로 pause(3.2), memcg 도메인(4.2), `BDP_ASYNC`(6.0) |
| writeback 주체 | `pdflush` 스레드 풀(2.6.32 이전) → bdi별 flusher 스레드 | `bdi_writeback`마다 workqueue 항목 `wb_workfn()`, cgroup별 wb(4.2) |
| writepages 반복 | `write_cache_pages()` + 콜백 | `writeback_iter()` 루프(6.9), `write_cache_pages()` 삭제(6.18) |
| 일회성 데이터 | `O_DIRECT` 또는 사후 `POSIX_FADV_DONTNEED` | `RWF_DONTCACHE` + `PG_dropbehind`(6.14 인터페이스, 6.16 실효) |

`pdflush`에서 bdi별 flusher로 넘어간 시점은 2.6.32다(v2.6.31에는 `mm/pdflush.c`가 있고, v2.6.32에는 없고 `bdi_forker_task`가 있음). flusher를 전용 스레드에서 unbound workqueue 항목으로 바꾼 것은 3.10이다(Tejun Heo, 839a8e8660b6 "writeback: replace custom worker pool implementation with unbound workqueue"; v3.10에 `bdi_writeback_workfn()` 등장, `bdi_forker_thread` 소멸). 지금의 `wb_workfn()`은 4.2 cgroup writeback에서 wb 단위로 바뀐 이름이다.

### 4.8 연표
| 버전 | 변화 |
|---|---|
| 3.2 | IO-less dirty throttling (`bdi_position_ratio()`, 지금의 `wb_position_ratio()`) |
| 4.2 | `CONFIG_CGROUP_WRITEBACK`, `wb_domain`, 공유 inode 전환 |
| 4.20 | `i_pages` xarray 전환 |
| 5.12 | `filemap_read()` |
| 5.16 | `struct folio` (7b230db3b8d3) |
| 5.17 | XFS large folio, `filemap_read()`의 `folio_batch` |
| 6.0 | `BDP_ASYNC`(NOWAIT 버퍼드 쓰기) |
| 6.2 | bdi `min/max_bytes`, `*_ratio_fine`, `strict_limit` sysfs |
| 6.6 | iomap 블록 단위 dirty 추적 |
| 6.9 | `writeback_iter()` |
| 6.11 | `ondemand_readahead()` 제거 |
| 6.12 | 최소 folio 차수(LBS) |
| 6.14 | `RWF_DONTCACHE` 인터페이스 |
| 6.15 | XFS dontcache opt-in, 릴리스에서는 전역 비활성 |
| 6.16 | dontcache 재활성화, ext4 large folio |
| 6.17 | `file_ra_state.order`, iomap writeback 재편, ext4 dontcache, btrfs large folio(실험적) |
| 6.18 | `write_cache_pages()` 삭제, NFS dontcache |
| 7.2 | btrfs large folio 기본 활성화, dontcache flusher kick |
| 7.3 개발 주기 | 블록 장치 dontcache |

### 4.9 운영상 함의
- **`dirty_ratio`는 비율이라 메모리가 크면 절대량이 커진다.** 512GiB 서버에서 20%면 100GiB 넘게 더티를 허용한다. 장치가 느리면 `fsync` 한 번에 수십 초가 걸릴 수 있다. 대용량 메모리 호스트에서는 `vm.dirty_bytes`/`dirty_background_bytes`로 절대량을 정하거나, 느린 bdi에 `max_bytes`를 거는 쪽이 예측 가능하다. 적정값은 장치 대역폭과 허용 지연에 달려 있어 일반값을 제시하지 않는다.
- **throttling 대기는 `balance_dirty_pages` tracepoint로 본다.** `writeback:balance_dirty_pages`는 `pause`, `dirty_ratelimit`, `task_ratelimit`을 기록한다. 버퍼드 쓰기 지연이 튀면 장치보다 이 경로를 먼저 의심한다(→ 05/02).
- **cgroup 메모리 한도가 작으면 memcg 도메인이 먼저 throttle한다.** 전역 sysctl을 바꿔도 컨테이너 안의 쓰기 지연은 그대로일 수 있다. 원인은 memcg `wb_domain`이다.
- **`O_DIRECT`와 버퍼드 혼용 시 일관성은 커널이 "최선 노력"만 한다.** DIO 쓰기 전 flush와 무효화, 무효화 실패 시 버퍼드 폴백(→ 11/01)이 그 노력이다. 같은 범위의 mmap 쓰기와는 직렬화되지 않는다. 같은 파일을 DIO와 버퍼드로 함께 쓰는 설계(예: 백업 도구가 DB 파일을 버퍼드로 읽기)는 성능 간섭과 캐시 무효화 비용을 감수해야 한다. 이런 읽기 측에는 `RWF_DONTCACHE`가 맞다.
- **`RWF_DONTCACHE`는 캐시 히트를 버리지 않는다.** 이미 캐시에 있던 folio는 남겨 두므로 공유 데이터에도 비교적 안전하다. 쓰기는 여전히 writeback을 거치므로 지속성을 원하면 `RWF_DSYNC`나 `fsync`가 필요하다. 지원 여부는 `-EOPNOTSUPP`로 판정한다. 6.15 커널은 모든 파일시스템에서 실패한다는 점에 주의한다.
- **large folio는 메모리 단편화와 맞바꾼다.** 고차 할당이 실패하면 iomap/readahead는 더 작은 차수로 물러나므로 기능상 문제는 없다. 다만 단편화된 시스템에서는 기대한 이득이 줄어든다. 쓰기 증폭은 블록 단위 dirty 추적이 있는 iomap 파일시스템에서 억제된다.

---

## 5. Primary References

- [The folio pull-request pushback (LWN, 2021-09-10)](https://lwn.net/Articles/868598/) — Weiner의 NAK, Torvalds와 Wilcox의 발언
- [Page folios (LWN)](https://lwn.net/Articles/840593/) — folio 개념 초기 소개
- [Filesystems and iomap (LWN, 2024-05-28)](https://lwn.net/Articles/974958/) — iomap large folio와 블록 단위 dirty 추적, 전환 현황
- [ext4: enable large folio for regular files (LWN)](https://lwn.net/Articles/1020982/) — Zhang Yi의 ext4 large folio 패치셋과 측정
- [No-I/O dirty throttling (LWN, 2011-08-31)](https://lwn.net/Articles/456904/) — Wu Fengguang IO-less throttling 해설
- [IO-less dirty throttling v12 (LWN)](https://lwn.net/Articles/461410/) — 병합 직전 패치셋
- [Writeback and control groups (LWN, 2015-06-17)](https://lwn.net/Articles/648292/) — Tejun Heo의 cgroup writeback 설계
- [Buffered I/O without page-cache thrashing (LWN, 2019-12-12)](https://lwn.net/Articles/806980/) — 2019년 `RWF_UNCACHED` 첫 제안
- [The return of RWF_UNCACHED (LWN, 2024-12-04)](https://lwn.net/Articles/998783/) — 2024 재제안, 측정치, Chinner/Axboe/Wong 논의
- [mm: Introduce struct folio (commit 7b230db3b8d3)](https://github.com/torvalds/linux/commit/7b230db3b8d373219f88a3d25c8fbbf12cc7f233) — Linux 5.16
- [xfs: Support large folios (commit 6795801366da)](https://github.com/torvalds/linux/commit/6795801366da0cd3d99e27c37f020a8f16714886) — Linux 5.17
- [fs: add RWF_DONTCACHE iocb and FOP_DONTCACHE file_operations flag (commit af6505e5745b)](https://github.com/torvalds/linux/commit/af6505e5745b9f3a670de405b08b73573343c15c) — Linux 6.14
- [Disable FOP_DONTCACHE for now due to bugs (commit 478ad02d6844)](https://github.com/torvalds/linux/commit/478ad02d6844217cc7568619aeb0809d93ade43d) — Linux 6.15 직전 전역 비활성화
- [Revert "Disable FOP_DONTCACHE for now due to bugs" (commit 7b2b67dbd449)](https://github.com/torvalds/linux/commit/7b2b67dbd449afd00fc7279b1ab7ffa3d26fe0c9) — 6.16-rc 재활성화
- [ext4: support uncached buffered I/O (commit ae21c0c0ac56)](https://github.com/torvalds/linux/commit/ae21c0c0ac56aa734327e9c8b7dfef4270ab54d4) — Linux 6.17
- [mm: kick writeback flusher for IOCB_DONTCACHE with targeted dirty tracking (commit e1bf79628453)](https://github.com/torvalds/linux/commit/e1bf79628453e6afac81ffa57f4f40f28e5512ff) — Linux 7.2, p99.9 지연 측정
- [block: enable RWF_DONTCACHE for block devices (commit 8b5ffb43ae9d)](https://github.com/torvalds/linux/commit/8b5ffb43ae9d27eed9165e1962963d685d879219) — 7.3 개발 주기
- [Documentation for /proc/sys/vm/ — The Linux Kernel documentation](https://docs.kernel.org/admin-guide/sysctl/vm.html) — `dirty_*` sysctl 공식 설명
