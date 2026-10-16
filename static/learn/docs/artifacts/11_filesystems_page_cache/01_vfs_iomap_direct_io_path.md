# VFS에서 블록 계층까지: `read_iter`/`write_iter`, iomap, Direct I/O 경로

> 기준 버전: Linux 7.3-rc7 master(2026-10). 도입 시점은 git.kernel.org `?h=vX.Y` 태그별 grep으로 고정했다. "7.3 개발 주기"는 v7.2 태그에는 없고 master에만 있는 코드를 뜻한다.

## 1. Verdict

리눅스의 파일 I/O는 경로가 하나다. `read(2)`, `preadv2(2)`, native AIO `io_submit(2)`, io_uring `IORING_OP_READ`가 모두 `struct kiocb` + `struct iov_iter`를 만들어 `file->f_op->read_iter()`/`write_iter()`를 부른다. 버퍼드 I/O와 Direct I/O(`O_DIRECT`, 커널 내부 `IOCB_DIRECT`)의 분기는 그 다음, 파일시스템 안에서 일어난다. 현대 커널에서 그 분기 뒤를 맡는 공용 엔진이 **iomap**이다.

- **iomap**은 Christoph Hellwig가 4.8에 `fs/iomap.c`로 넣은 "파일 오프셋 → extent 매핑" 추상이다. 4.10에 `iomap_dio_rw()`(커밋 ff6a9292e6f6 "iomap: implement direct I/O")가 들어오면서 XFS가 첫 사용자가 되었다. 5.15에서 콜백 기반 `iomap_apply()`가 반복자 기반 `iomap_iter()`(f4b896c213f0 "iomap: add the new iomap_iter model")로 바뀌었다. 파일시스템은 `struct iomap_ops`의 `->iomap_begin`/`->iomap_end`로 "이 범위는 어떤 extent인가"(`IOMAP_HOLE`/`IOMAP_DELALLOC`/`IOMAP_MAPPED`/`IOMAP_UNWRITTEN`/`IOMAP_INLINE`)만 답한다. bio 생성, 페이지 캐시 무효화, 완료 처리, unwritten 변환 호출 시점은 iomap이 맡는다.
- **DIO의 iomap 전환 연표**(태그 grep 기준): XFS 4.10, ext4 5.5, btrfs 5.10, f2fs 5.17, ext2 6.5. 레거시 `fs/direct-io.c`(`__blockdev_direct_IO`)는 6.3에서 `CONFIG_LEGACY_DIRECT_IO`(커밋 9636e650e16f "fs: build the legacy direct I/O code conditionally") 뒤로 숨었다. master에서는 jfs, udf, hfs, hfsplus, affs, ntfs3, nilfs2, ocfs2, fat의 Kconfig가 이 옵션을 select한다. 즉 **삭제되지 않았고, "새 코드는 iomap을 쓰라"는 주석과 함께 격리된 상태**다.
- **락 모델은 파일시스템마다 다르지만 방향은 같다.** 정렬된 덮어쓰기 DIO는 `i_rwsem`(XFS는 `XFS_IOLOCK_SHARED`)을 공유 모드로 잡아 같은 파일에 병렬 쓰기를 허용한다. 파일 확장, 비정렬 부분 블록 zeroing, `IS_NOSEC`가 아닌 파일(suid 비트 제거가 필요한 경우)만 배타 락으로 올린다. unwritten extent는 DIO 완료 후 `->end_io`(`xfs_dio_write_end_io()` → `xfs_iomap_write_unwritten()`, `ext4_dio_write_end_io()` → `ext4_convert_unwritten_extents()`)에서 written으로 바뀐다.
- **사용자 공간 계약은 플래그로 늘어났다.** `RWF_NOWAIT`(4.13), `STATX_DIOALIGN`(6.1), `RWF_ATOMIC`/`STATX_WRITE_ATOMIC`(6.11 VFS·블록, 6.13 ext4/XFS 단일 블록), `STATX_DIO_READ_ALIGN`·`RWF_DONTCACHE`(6.14), `stx_atomic_write_unit_max_opt`·XFS 다중 블록 원자 쓰기(6.16), `RWF_NOSIGNAL`(6.18)이 이 순서로 들어왔다. 모두 `kiocb_set_rw_flags()`에서 `IOCB_*`로 번역되고, 지원 여부는 `FMODE_NOWAIT`, `FMODE_CAN_ATOMIC_WRITE`, `FOP_DONTCACHE` 같은 파일 단위 능력 비트로 거른다.
- **최근 쟁점은 "DIO가 사용자 버퍼를 직접 DMA한다"는 제로카피 전제 자체다.** 체크섬·패리티를 계산하는 파일시스템(btrfs)과 stable write가 필요한 장치(T10 PI 등)에서는 DMA 중 사용자가 버퍼를 바꾸면 체크섬이 깨진다. btrfs는 6.15에서 체크섬 inode의 DIO 쓰기를 아예 버퍼드로 돌렸다(968f19c5b1b7). 7.0의 `IOMAP_DIO_BOUNCE`(c9d114846b38, Christoph Hellwig)가 나온 뒤 7.3 개발 주기에 바운스 버퍼 방식으로 되돌렸다(e9b7b9d9e78e). 같은 주기에 작은 DIO 읽기용 `__iomap_dio_read_simple()`(36f199c8d0ee)도 들어왔다. iomap 상태 기계의 고정 비용이 Gen5 NVMe에서 병목으로 드러났기 때문이다.

io_uring/AIO가 이 경로에 들어오는 방식, 즉 `IOCB_NOWAIT` 우선 시도와 `-EAGAIN` 뒤 io-wq 재시도는 (→ 01/01)에서 다룬 제출 모델의 파일시스템 쪽 절반이다. bio 이후의 blk-mq 경로와 `REQ_POLLED`는 (→ 02/03), OpenZFS의 별도 DIO 구현은 (→ 10/02)를 참조한다.

---

## 2. Problem Statement

### 2.1 하나의 진입점, 두 개의 데이터 경로
버퍼드 I/O는 페이지 캐시(`struct address_space`의 `i_pages` xarray)를 거친다. 읽기는 `filemap_read()`, 쓰기는 `generic_perform_write()`/`iomap_file_buffered_write()`가 담당하고, 실제 장치 I/O는 readahead와 writeback이 비동기로 처리한다(→ 11/02). DIO는 페이지 캐시를 건너뛰고 사용자 버퍼 페이지를 `bio_iov_iter_get_pages()`로 핀(pin)해 bio에 직접 붙인다. 두 경로가 같은 파일을 동시에 만지면 세 가지 문제가 생긴다.

1. **일관성(coherency)**: DIO 쓰기 전에 그 범위의 더티 페이지를 써 내고(`kiocb_write_and_wait()` → `filemap_write_and_wait_range()`), 캐시된 페이지를 무효화해야 한다(`kiocb_invalidate_pages()` → `invalidate_inode_pages2_range()`). 무효화에 실패하면(예: 동시 mmap 더티) iomap은 `-ENOTBLK`를 돌려주고, 파일시스템은 남은 부분을 버퍼드로 처리한다. 무효화는 쓰기 *전에* 한다. 그래야 비동기 DIO가 `-EIOCBQUEUED`를 반환한 뒤에 페이지를 건드리지 않는다(`mm/filemap.c` 주석).
2. **할당과 크기 갱신**: hole이나 preallocated 영역에 DIO로 쓰면 블록은 먼저 unwritten 상태로 할당하고, 데이터가 장치에 닿은 *뒤에* written으로 바꿔야 한다. 그러지 않으면 크래시 후 옛 디스크 내용(다른 파일의 잔해)이 노출된다. 파일 끝을 넘는 쓰기는 `i_size`/`i_disksize` 갱신을 I/O 완료 뒤로 미뤄야 한다.
3. **부분 블록 zeroing 경합**: 파일시스템 블록 크기보다 작거나 블록 경계에 맞지 않는 DIO 쓰기가 hole/unwritten 블록에 걸치면, iomap은 블록의 나머지를 0으로 채우는 bio(`iomap_dio_zero()`)를 같이 보낸다. 같은 블록에 두 비정렬 DIO가 동시에 오면 서로의 zeroing이 데이터를 덮어쓸 수 있다.

### 2.2 레거시 `fs/direct-io.c`의 한계
`__blockdev_direct_IO()`는 2002년 Andrew Morton이 쓴 코드에서 출발했다(파일 머리 주석). 이 코드는 파일시스템의 `get_block_t` 콜백을 *블록 단위로* 불러 `buffer_head`에 매핑을 받는다. extent 기반 파일시스템은 큰 연속 범위를 한 번에 알려줄 수 있는데도 이 구조에서는 블록마다 콜백이 불린다. unwritten 변환, 완료 시점 훅, NOWAIT 의미론 같은 기능은 `DIO_*` 플래그와 콜백 포인터로 덧붙여야 했다. iomap은 이것을 "범위 단위 매핑 + 공통 bio 빌더"로 뒤집었다. `->iomap_begin`이 `[pos, pos+len)`에 대해 가능한 한 긴 extent 하나를 돌려주면, iomap이 그 extent 전체에 대해 bio를 만든다.

### 2.3 NVMe 시대의 고정 비용
장치 지연이 수 µs로 내려오자 DIO 한 건당 소프트웨어 비용이 보이기 시작했다. 7.3 개발 주기의 커밋 36f199c8d0ee("iomap: add simple dio path for small direct I/O", Fengnan Chang)의 측정을 보자. Gen5 NVMe 원시 블록 장치에서 io_uring 폴링 4K 랜덤 읽기(`t/io_uring`, 단일 코어)가 약 3.2M IOPS인데, 같은 부하를 ext4/XFS 위 파일로 돌리면 약 1.92M IOPS였다. 프로파일 상위는 `__iomap_dio_rw`(5.33%), `iomap_iter`(3.26%), `iomap_dio_bio_iter`(2.37%), `kfree`(2.35%)였다. 단순 경로를 넣은 뒤 ext4는 2.19M IOPS가 되었다. 수치는 커밋 메시지의 측정 조건(특정 Gen5 SSD, 단일 코어 폴링)에 한정된다.

### 2.4 정렬 요구의 불투명성
DIO는 버퍼 주소, 파일 오프셋, 길이가 정렬되어야 한다. 그런데 그 정렬 단위가 무엇인지(논리 블록 크기, DMA 정렬, 파일시스템 블록 크기, 암호화·verity 여부) 사용자 공간이 알 방법이 6.0까지는 없었다. ext4는 암호화된 파일 등에서 DIO를 조용히 버퍼드로 바꿨고(`ext4_should_use_dio()` 주석), 비정렬 요청에는 `-EINVAL`을 돌려주었다. 애플리케이션은 512B나 4KiB를 추측해 쓰는 수밖에 없었다.

---

## 3. The Debate

### 3.1 플래그는 파일 단위인가, I/O 단위인가
`O_DIRECT`, `O_NONBLOCK`, `O_DSYNC`는 `open(2)` 시점의 파일 속성이다. `preadv2`/`pwritev2`의 `RWF_*` 플래그(4.6의 `RWF_HIPRI`, 4.7의 `RWF_DSYNC`/`RWF_SYNC`, 4.13의 `RWF_NOWAIT`)는 같은 의미를 I/O 하나에 붙인다. `RWF_NOWAIT`는 Goldwyn Rodrigues의 "fs: Introduce RWF_NOWAIT and FMODE_AIO_NOWAIT"(b745fafaf70c, 4.13)로 들어왔다. 처음 이름이 `FMODE_AIO_NOWAIT`였던 데서 보이듯 native AIO가 `io_submit()` 안에서 블록되는 문제(→ 01/01)를 풀려고 만든 것이다. 지금 이름은 `FMODE_NOWAIT`다. 이 방향을 가장 분명하게 옹호한 사람은 Jens Axboe다. `RWF_UNCACHED`(현 `RWF_DONTCACHE`)를 `posix_fadvise(POSIX_FADV_NOREUSE)`로 대신하자는 Dave Chinner의 제안에 그는 이렇게 답했다.

> "Per-file settings is fine for sync IO, for anything async per-io is the way to go. It's why we have things like RWF_NOWAIT as well, where O_NONBLOCK exists too. I'd argue that RWF_NOWAIT should always have been a thing, and O_NONBLOCK is a mistake. That's why RWF_UNCACHED exists."
> — Jens Axboe, LWN "The return of RWF_UNCACHED"(2024-12-04)에 인용된 메일. 원문 링크는 [LWN 기사](https://lwn.net/Articles/998783/) 본문에 있음

io_uring처럼 한 링에서 여러 성격의 I/O를 섞어 내는 인터페이스에서는 파일 디스크립터 속성으로 의도를 표현할 수 없다는 주장이다. 이 결과 `kiocb_set_rw_flags()`는 사용자 `RWF_*` 비트를 하위 비트에서 그대로 `IOCB_*`로 복사한다. `IOCB_HIPRI == RWF_HIPRI` … `IOCB_NOSIGNAL == RWF_NOSIGNAL`이고, `BUILD_BUG_ON`으로 커널 전용 비트(`IOCB_EVENTFD` 이상)와 겹치지 않음을 보장한다. 대신 파일시스템이 그 의미를 실제로 지키는지는 능력 비트로 따로 확인한다. `RWF_NOWAIT`는 `FMODE_NOWAIT`, `RWF_ATOMIC`은 `FMODE_CAN_ATOMIC_WRITE`가 있어야 하고 쓰기에만 허용된다. `RWF_DONTCACHE`는 `FOP_DONTCACHE`가 필요하며 DAX에서는 금지된다. 조건이 맞지 않으면 `-EOPNOTSUPP`이다.

`IOCB_NOWAIT`의 의미는 "블록될 것 같으면 `-EAGAIN`"이지 "블록하지 않음을 보장"이 아니다. 경계가 어디인지는 파일시스템마다 다르다. XFS는 `xfs_ilock_iocb()`에서 trylock에 실패하면 `-EAGAIN`을 반환한다. 비정렬 DIO가 배타 락을 필요로 할 때도, EOF 너머 zeroing이 필요할 때도 마찬가지다. ext4는 공유 락을 배타 락으로 올려야 하는 순간(`ext4_dio_write_checks()`) `-EAGAIN`을 낸다. btrfs는 체크섬 inode의 바운스 DIO 쓰기에 아직 NOWAIT를 지원하지 않아 무조건 `-EAGAIN`이다(`btrfs_dio_write()` 주석 "For now no support for BOUNCE and NOWAIT direct write"). io_uring은 일부 파일시스템이 NOWAIT에 `-EOPNOTSUPP`을 잘못 돌려준다는 이유로 이것도 `-EAGAIN`으로 취급해 io-wq로 넘긴다(`io_uring/rw.c` 주석).

### 3.2 DIO는 정말 "페이지 캐시를 우회"하는가
iomap DIO는 페이지 캐시를 무시하지 않는다. 쓰기 전에 범위를 flush·무효화하고, 완료 시점에도 매핑에 페이지가 있으면(`mapping->nrpages`) 완료를 workqueue(`sb->s_dio_done_wq`)로 넘겨 다시 무효화한다(`iomap_dio_done()`). 그래도 mmap과는 직렬화되지 않는다. iomap 소스에는 이 한계가 경고 메시지로 남아 있다. writeback과 `iomap_iter()` 사이에 `page_mkwrite`가 delalloc 블록을 만들면 DIO는 `IOMAP_DELALLOC`을 보게 되고, `"Direct I/O collision with buffered writes!"`를 찍은 뒤 `-EIO`를 낸다. 커널 개발자들은 대체로 "같은 범위에 DIO와 버퍼드/mmap을 섞는 애플리케이션은 일관성을 스스로 책임진다"는 입장이다. 커널은 데이터 손상 대신 실패를 보장하는 수준까지만 노력한다.

### 3.3 체크섬 파일시스템과 제로카피 DIO의 충돌
DIO의 존재 이유는 사용자 버퍼에서 장치로 바로 가는 제로카피다. 그런데 bio가 장치로 가는 동안 사용자(또는 그 위의 게스트 OS)가 같은 버퍼를 고칠 수 있다. 체크섬은 제출 전에 계산되므로 디스크에 쓰인 데이터와 체크섬이 어긋난다. btrfs 개발자 Qu Wenruo는 이 문제를 커밋 메시지에 이렇게 적었다.

> "It is a long known bug that VM image on btrfs can lead to data csum mismatch, if the qemu is using direct-io for the image (this is commonly known as cache mode 'none')."
> — Qu Wenruo, [btrfs: always fallback to buffered write if the inode requires checksum (968f19c5b1b7)](https://github.com/torvalds/linux/commit/968f19c5b1b7d5595423b0ac0020cc18dfed8cb5), 2025-02-04 작성, Linux 6.15

게스트 안의 ext4/XFS는 `AS_STABLE_WRITES`가 없으면 writeback 중인 folio도 고칠 수 있다. 하지만 바깥의 btrfs는 데이터가 바뀌지 않는다고 가정한다. 6.15의 해법은 체크섬이 켜진 inode의 DIO 쓰기를 버퍼드로 돌리는 것이었다. 정합성은 얻었지만 성능을 잃었다. 7.0에서 Christoph Hellwig가 넣은 `IOMAP_DIO_BOUNCE`("iomap: add a flag to bounce buffer direct I/O", c9d114846b38)는 DIO 경로를 그대로 쓰면서 데이터를 커널 페이지로 복사해 stable하게 만든다. 7.3 개발 주기에 btrfs는 이 플래그로 갈아탔다(e9b7b9d9e78e). 같은 커밋의 fio 측정(libaio, `iodepth=64`, 60초 randwrite)에 따르면 4K에서 제로카피 35.1 MiB/s, 버퍼드 폴백 17.1 MiB/s, 바운스 33.8 MiB/s이고, 64K에서 각각 522/251/492 MiB/s다. XFS는 7.0부터 `mapping_stable_writes()`인 매핑(예: PI를 쓰는 장치)에서 DIO 읽기와 쓰기에 `IOMAP_DIO_BOUNCE`를 켠다. 바운스 읽기는 복사를 위해 사용자 컨텍스트가 필요하므로, 완료를 ioend workqueue로 넘기는 `xfs_dio_read_bounce_ops`를 쓴다.

### 3.4 레거시 direct-io.c를 지울 것인가
6.3의 `CONFIG_LEGACY_DIRECT_IO`는 "아직 레거시 코드를 쓰는 파일시스템만 select하게 해서, 그런 파일시스템이 없는 커널은 이 코드를 빌드하지 않게 한다"는 커밋 설명 그대로의 조치다. 삭제는 아니다. 2024 LSFMM+BPF의 iomap 세션(LWN "Filesystems and iomap", 2024-05-28)에서 Ritesh Harjani는 `FS_IOMAP`/`LEGACY_DIRECT_IO` grep 결과로 전환 현황을 보였다. Al Viro는 그 grep이 비슷한 파일시스템들을 인위적으로 나눈다며 올바른 잣대가 아니라고 반박했다(LWN 서술 기준). 남은 파일시스템은 대부분 `buffer_head` 기반의 작고 오래된 파일시스템이다(fat, hfs/hfsplus, udf, jfs, affs, nilfs2). ocfs2와 ntfs3만 상대적으로 활발하다. 같은 세션에서 Matthew Wilcox는 iomap 전환의 유인을 이렇게 요약했다.

> "Folios, pages, you don't care anymore if you use iomap."
> — Matthew Wilcox, [LWN "Filesystems and iomap"](https://lwn.net/Articles/974958/)(2024-05-28)

참고로 같은 LWN 기사는 btrfs의 iomap DIO 전환을 5.8로 적었다. 그러나 `fs/btrfs/inode.c`는 v5.9 태그까지 `__blockdev_direct_IO`를 부르고, iomap 호출은 v5.10에서 처음 나타난다. 이 문서는 태그 grep을 따라 5.10으로 적는다.

### 3.5 원자 쓰기: DIO 전용으로 끝날 것인가
`RWF_ATOMIC`은 "찢어지지 않는 쓰기(untorn write)"를 약속한다. 쓰기가 전부 반영되거나 전혀 반영되지 않는다는 뜻이며, 지속성은 여전히 `RWF_SYNC`/`fsync`가 맡는다. 6.11에 VFS와 블록 계층(`REQ_ATOMIC`, `queue_limits`의 `atomic_write_*`)이, 6.13에 ext4와 XFS의 단일 파일시스템 블록 원자 쓰기가 들어왔다(LWN "Support for atomic block writes in 6.13", 2025-02-20). 16KiB 원자 쓰기를 원하면 파일시스템 블록을 16KiB로 만들어야 했다. 4KiB 페이지 시스템에서 ext4는 블록이 페이지보다 클 수 없어 불가능했고, XFS는 6.12의 large block size(LBS) 지원 덕에 가능했다. 6.16에서 XFS는 out-of-place(CoW) 기반 소프트웨어 원자 쓰기(`xfs_atomic_write_cow_iomap_ops`)를 얻어 블록 크기를 넘는 원자 쓰기를 처리한다. ext4는 같은 6.16에서 bigalloc 클러스터 단위 다중 블록 원자 쓰기를 얻었다(`Documentation/filesystems/ext4/atomic_writes.rst`가 v6.16에 추가됨). 최대 크기는 클러스터 크기와 하드웨어 최대 원자 쓰기 단위 중 작은 값이다.

남은 쟁점은 버퍼드 원자 쓰기다. PostgreSQL처럼 버퍼드 I/O를 쓰는 DB가 수요를 대고 있지만, Christoph Hellwig는 반대 입장이다.

> "I think a better session would be how we can help postgres to move off buffered I/O instead of adding more special cases for them."
> — Christoph Hellwig, [LWN "The ongoing quest for atomic buffered writes"](https://lwn.net/Articles/1060063/)(2026-03-02)에 인용

Andres Freund는 DIO 지원을 개발 중이라면서도 "well over 50% of users"는 DIO의 혜택을 받지 못할 것이라고 답했다(같은 기사). 논의는 Ojaswin Mujoo가 제안한 writethrough 방식으로 모이고 있다. 버퍼드 원자 쓰기가 들어오면 페이지 캐시에 복사한 직후 DIO처럼 즉시 쓰기를 시작하고, stable page로 그동안의 수정을 막는다. 2026 LSFMM+BPF(LWN "Buffered atomic writes, writethrough, and more", 2026-05-14)에서는 새 `RWF_WRITETHROUGH` 플래그가 거론되었다. Jan Kara는 `RWF_DSYNC`가 장치 매체까지의 완료를 보장하는 반면 `RWF_WRITETHROUGH`는 "쓰기가 발행되었다"는 것만 뜻한다고 구분했다. master(7.3-rc7)의 `include/uapi/linux/fs.h`에는 `RWF_WRITETHROUGH`가 없다. 아직 제안 단계다.

---

## 4. Implementation Impact

### 4.1 진입점: `kiocb`와 `iov_iter`
```
read(2)/pread64(2)            preadv2(2) + RWF_*          io_submit(2) IOCB_CMD_PREAD     io_uring IORING_OP_READ*
  vfs_read()                    do_iter_readv_writev()      aio_read()                       io_read() → __io_read()
  new_sync_read()               kiocb_set_rw_flags()        aio_prep_rw():                   io_rw_init_file()/kiocb_set_rw_flags()
    init_sync_kiocb()                                         ki_complete = aio_complete_rw  ki_complete = io_complete_rw[_iopoll]
                                                              ki_flags |= IOCB_AIO_RW        IOCB_NOWAIT 먼저 시도
         \__________________________ file->f_op->read_iter(kiocb, iov_iter) _________________________/
```
`struct kiocb`(master `include/linux/fs.h`)의 핵심 필드는 다음과 같다.
- `ki_filp`, `ki_pos`
- `ki_complete`: `NULL`이면 동기(`is_sync_kiocb()`)
- `ki_flags`: `IOCB_*`
- `ki_ioprio`, `ki_write_stream`(FDP/write stream 힌트, → 09/02)
- `private`: iomap이 폴링용 bio를 기록하는 칸

`struct iov_iter`는 사용자 iovec(`ITER_IOVEC`), 단일 사용자 버퍼(`ITER_UBUF`), bvec, kvec, folioq 등을 하나의 커서로 감싼다. `generic_atomic_write_valid()`가 `iter_is_ubuf()`를 요구하므로, 원자 쓰기는 iovec 하나짜리(`pwrite`/단일 segment `pwritev2`)만 받는다. 길이는 2의 거듭제곱이어야 하고, `ki_pos`가 그 길이에 정렬되어야 하며, `IOCB_DIRECT`여야 한다(아니면 `-EOPNOTSUPP`).

커널 내부 전용 비트도 있다. `IOCB_DIRECT`는 `O_DIRECT`에서 온다. `IOCB_WAITQ`는 io_uring 버퍼드 읽기에서 페이지 잠금 대기를 콜백으로 바꾼다. `IOCB_NOIO`는 캐시에 있는 것만 읽는다. `IOCB_AIO_RW`는 native AIO 표식이다. io_uring 버퍼드 읽기는 `FOP_BUFFER_RASYNC`(5.9에 `FMODE_BUF_RASYNC`로 도입, 6.10부터 `fop_flags`)인 파일에서 `IOCB_WAITQ`를 켜고 `IOCB_NOWAIT`를 끈다. 그러면 `filemap_read()`가 folio unlock을 기다리는 대신 wait queue 콜백으로 task_work 재시도를 건다. 버퍼드 쓰기 쪽 `FOP_BUFFER_WASYNC`(XFS는 6.0에 `FMODE_BUF_WASYNC`로 시작)가 없으면, io_uring은 NOWAIT 인라인 시도 없이 바로 io-wq로 간다.

### 4.2 iomap DIO의 내부 흐름 (master)
```
iomap_dio_rw(iocb, iter, ops, dops, dio_flags, private, done_before)
 └ __iomap_dio_rw()
    ├ 읽기: (IOCB_NOWAIT면 범위에 캐시 페이지 있으면 -EAGAIN) / 쓰기: kiocb_write_and_wait()
    ├ 쓰기: kiocb_invalidate_pages()  ── 실패 시 -ENOTBLK (호출자가 버퍼드 폴백)
    ├ 비동기면 sb_init_dio_done_wq()
    ├ inode_dio_begin()               ── truncate/punch의 inode_dio_wait()를 막는 카운터
    ├ while (iomap_iter(&iomi, ops) > 0)   ── ->iomap_begin / ->iomap_end (또는 7.3 개발 주기의 ->iomap_next)
    │     iomap_dio_iter(): HOLE/UNWRITTEN(읽기)→0 채우기, MAPPED/UNWRITTEN(쓰기)→iomap_dio_bio_iter(),
    │                       INLINE→memcpy, DELALLOC→"Direct I/O collision" 경고 + -EIO
    │       iomap_dio_bio_iter(): 정렬 검사(bdev_logical_block_size 또는 IOMAP_DIO_FSBLOCK_ALIGNED면 i_blocksize)
    │         ├ UNWRITTEN/NEW/SHARED → IOMAP_DIO_UNWRITTEN/COW 표시, 부분 블록은 iomap_dio_zero()
    │         ├ 순수 덮어쓰기 + O_DSYNC → REQ_FUA (IOMAP_DIO_WRITE_THROUGH), 아니면 완료 후 generic_write_sync
    │         ├ IOMAP_ATOMIC → REQ_ATOMIC (bio가 쪼개지면 WARN + 실패)
    │         └ bio_iov_iter_get_pages() → dops->submit_io 또는 submit_bio(); 비동기 IOCB_HIPRI → REQ_POLLED
    └ 동기: blk_wake_io_task로 깨어나 iomap_dio_complete() / 비동기: -EIOCBQUEUED
bio 완료 → iomap_dio_done(): 에러나 캐시 페이지 존재(nrpages) 시 s_dio_done_wq로, 아니면 인라인으로
           → dops->end_io(iocb, size, error, IOMAP_DIO_UNWRITTEN|IOMAP_DIO_COW) → ki_complete
```
호출자가 주는 `dio_flags`(`include/linux/iomap.h`)는 다음과 같다.

| 플래그 | 값 | 도입 | 의미 / 주 사용자 |
|---|---|---|---|
| `IOMAP_DIO_FORCE_WAIT` | `1<<0` | 5.12 | 비동기 kiocb여도 완료까지 기다림. 파일 확장, 배타 비정렬 쓰기(ext4/XFS) |
| `IOMAP_DIO_OVERWRITE_ONLY` | `1<<1` | 5.12 | 할당·zeroing이 필요하면 `-EAGAIN`. XFS 비정렬 DIO의 낙관적 공유 락 시도 |
| `IOMAP_DIO_PARTIAL` | `1<<2` | 5.16 | page fault 시 부분 결과 반환 후 `done_before`로 재개. btrfs, gfs2 |
| `IOMAP_DIO_FSBLOCK_ALIGNED` | `1<<3` | 6.19 | bio를 fs 블록 단위로 정렬. btrfs 체크섬, XFS always-CoW |
| `IOMAP_DIO_BOUNCE` | `1<<4` | 7.0 | 사용자 버퍼를 커널 페이지로 복사(stable data). XFS stable-writes 매핑, btrfs(7.3 개발 주기) |

도입 버전은 모두 `include/linux/iomap.h` 태그 grep으로 확인했다(v5.11→v5.12, v5.15→v5.16, v6.18→v6.19, v6.19→v7.0).

`struct iomap_dio_ops`는 `->end_io`(unwritten 변환, CoW remap, `i_size` 갱신), `->submit_io`(btrfs의 `btrfs_dio_submit_io()`, XFS zoned의 `xfs_dio_zoned_submit_io()`), `bio_set`(bio 앞에 파일시스템 전용 구조를 붙임) 세 칸이다. 7.3 개발 주기에는 `struct iomap_ops`에 `->iomap_next`가 추가되었다. 이것과 `DEFINE_IOMAP_ITER_NEXT_END()`로 begin/end 쌍을 한 콜백으로 감쌀 수 있게 되었고, btrfs의 `btrfs_dio_iomap_ops`는 이미 이 형태다. 같은 주기의 `__iomap_dio_read_simple()`은 조건이 맞을 때 `struct iomap_dio` 할당 없이 bio 하나로 끝낸다. 조건은 블록 크기 이하의 읽기, `dops` 없음, `done_before == 0`, `FORCE_WAIT`/`PARTIAL`/`BOUNCE` 없음, i_size 안쪽, 비암호화다. bio 앞쪽 `front_pad`에 `struct iomap_dio_simple`을 넣어 할당을 하나로 줄인다. XFS는 `iomap_dio_read_simple()`을 먼저 시도하고 `-ENOTBLK`이면 일반 경로로 간다.

### 4.3 파일시스템별 DIO 쓰기 경로와 락
| 항목 | XFS (`fs/xfs/xfs_file.c`) | ext4 (`fs/ext4/file.c`) | btrfs (`fs/btrfs/direct-io.c`, 6.11에 분리) |
|---|---|---|---|
| 진입 | `xfs_file_dio_write()` → aligned / unaligned / atomic / zoned 분기 | `ext4_dio_write_iter()` → `ext4_dio_write_checks()` | `btrfs_direct_write()` → `btrfs_dio_write()` |
| 기본 락 | `XFS_IOLOCK_SHARED`. `xfs_file_write_checks()`가 EOF zeroing·`!IS_NOSEC`면 EXCL로 올리고, I/O 전에 `xfs_ilock_demote()`로 되돌림 | `inode_lock_shared()`. 확장, `!IS_NOSEC`, 비정렬 + hole/unwritten 부분 블록이면 `inode_lock()`으로 재시작 | `BTRFS_ILOCK_SHARED`. EOF 너머·`!IS_NOSEC`면 배타로 재시도 |
| 비정렬 DIO | 먼저 공유 락 + `IOMAP_DIO_OVERWRITE_ONLY`로 시도. `-EAGAIN`이면 EXCL + `IOMAP_DIO_FORCE_WAIT` + `inode_dio_wait()` | zeroing이 필요할 때만 배타 + `inode_dio_wait()` + `FORCE_WAIT` | `check_direct_IO()` 실패 시 버퍼드 |
| unwritten 처리 | `->end_io` = `xfs_dio_write_end_io()` → `xfs_iomap_write_unwritten()`; CoW면 `xfs_reflink_end_cow()` | `ext4_dio_write_end_io()` → `ext4_convert_unwritten_extents()`(원자 쓰기는 `_atomic` 변형) | ordered extent 완료에서 처리(`btrfs_dio_end_io()`) |
| 파일 확장 | 완료 시 `xfs_dio_endio_set_isize()` | 동기 강제(`FORCE_WAIT`), orphan list 등록 후 `ext4_handle_inode_extension()` | extent lock 아래 i_size 갱신 |
| 폴백 | 무효화 실패 `-ENOTBLK` → 버퍼드 | `ext4_should_use_dio()`가 false(verity, data=journal, inline data)면 버퍼드. 남은 바이트는 버퍼드 후 `filemap_write_and_wait_range()` + `invalidate_mapping_pages()` | inline/compressed extent, 체크섬 + NOWAIT 조합 등은 `-ENOTBLK`/`-EAGAIN` |
| stable data | `mapping_stable_writes()`면 `IOMAP_DIO_BOUNCE`(7.0) | 해당 코드 없음 | 체크섬 또는 미러/패리티 프로파일이면 `IOMAP_DIO_BOUNCE`(7.3 개발 주기). 6.15~7.2는 버퍼드 폴백 |
| 원자 쓰기 | `xfs_file_dio_write_atomic()`: HW `REQ_ATOMIC` 시도 → `-ENOPROTOOPT`/크기 초과면 `xfs_atomic_write_cow_iomap_ops`(소프트웨어, 6.16) | 6.13 단일 블록, 6.16 bigalloc 다중 블록 | master 기준 미지원(`fs/btrfs/file.c`에 `FMODE_CAN_ATOMIC_WRITE`/`IOCB_ATOMIC` 없음) |

"덮어쓰기면 공유 락, 메타데이터가 바뀌면 배타 락" 구조는 같은 파일 하나를 여러 스레드가 때리는 DB에 결정적이다. 정렬된 덮어쓰기 DIO는 `i_rwsem`을 공유로만 잡고, extent 트리 수정은 파일시스템 내부 락(ext4 `i_data_sem`, XFS `ILOCK`)이 직렬화한다. truncate/punch hole은 `i_rwsem`을 배타로 잡은 뒤 `inode_dio_wait()`로 진행 중인 DIO가 끝나기를 기다린다. 공유 락을 풀고 비동기 DIO가 아직 날아가는 동안의 안전은 `inode_dio_begin()`/`inode_dio_end()` 카운터가 보장한다.

### 4.4 정렬과 원자 쓰기 능력 노출 (`statx`)
| 마스크 | 도입 | 필드 | 의미 |
|---|---|---|---|
| `STATX_DIOALIGN` | 6.1 (825cf206ed51, Eric Biggers) | `stx_dio_mem_align`, `stx_dio_offset_align` | 버퍼 주소 정렬, 파일 오프셋/길이 정렬. 0이면 DIO 불가 |
| `STATX_WRITE_ATOMIC` | 6.11 (c34fc6f26ab8 "fs: Initial atomic write support") | `stx_atomic_write_unit_min`, `_unit_max`, `_segments_max`, `STATX_ATTR_WRITE_ATOMIC` | 찢어지지 않음이 보장되는 최소/최대 크기 |
| `STATX_DIO_READ_ALIGN` | 6.14 | `stx_dio_read_offset_align` | 읽기 오프셋 정렬이 쓰기보다 작을 때 따로 보고 |
| (같은 마스크) | 6.16 | `stx_atomic_write_unit_max_opt` | 이 크기 이하는 HW 원자 쓰기(빠름), 초과는 소프트웨어 경로 |

XFS의 `xfs_report_dioalign()`이 이 필드들의 존재 이유를 잘 보여준다. 읽기 정렬은 `bdev_logical_block_size()`다. 반면 reflink/always-CoW inode의 쓰기 정렬은 할당 단위(`xfs_inode_alloc_unitsize()`)로 보고한다. CoW inode에서 할당 단위보다 작은 쓰기는 버퍼드 read-modify-write로 떨어져 "페이지 캐시 무효화 경합"을 낳기 때문이다(소스 주석). ext4는 `ext4_dio_alignment()`가 verity, data=journal, inline data에서 0(DIO 불가, 버퍼드 폴백)을 돌려준다. 암호화 inode에서는 `i_blocksize()`를, 그 밖에는 1을 돌려주는데, 1은 iomap 기본값, 즉 장치 DMA 정렬과 논리 블록 크기를 뜻한다.

### 4.5 기능 도입 연표 (메인라인)
| 버전 | 변화 |
|---|---|
| 2.6 이전~ | `fs/direct-io.c`(2002, Andrew Morton) + `get_block_t` |
| 3.16 | `file_operations`에 `->read_iter`/`->write_iter` 추가(`iov_iter` 기반 VFS 전환) |
| 4.6 / 4.7 | `RWF_HIPRI` / `RWF_DSYNC`, `RWF_SYNC` (`preadv2`/`pwritev2`) |
| 4.8 / 4.10 | `fs/iomap.c` / `iomap_dio_rw()`, XFS DIO가 iomap으로 |
| 4.13 | `RWF_NOWAIT`, `IOCB_NOWAIT` (b745fafaf70c) |
| 5.5 | ext4 DIO가 iomap으로 |
| 5.9 | `FMODE_BUF_RASYNC`(io_uring 비동기 버퍼드 읽기) |
| 5.10 | btrfs DIO가 iomap으로 |
| 5.12 | `IOMAP_DIO_FORCE_WAIT`, `IOMAP_DIO_OVERWRITE_ONLY` |
| 5.15 / 5.16 | `iomap_iter()` 모델 / `IOMAP_DIO_PARTIAL` |
| 5.17 | f2fs DIO가 iomap으로 |
| 6.0 | XFS 버퍼드 쓰기 NOWAIT(`FMODE_BUF_WASYNC`) |
| 6.1 | `STATX_DIOALIGN` |
| 6.3 | `CONFIG_LEGACY_DIRECT_IO` |
| 6.5 | ext2 DIO가 iomap으로 |
| 6.11 | `RWF_ATOMIC`, `STATX_WRITE_ATOMIC`, `REQ_ATOMIC`; btrfs `direct-io.c` 분리 |
| 6.13 | ext4/XFS 단일 블록 원자 쓰기 |
| 6.14 | `RWF_DONTCACHE`(인터페이스), `STATX_DIO_READ_ALIGN` |
| 6.15 | btrfs 체크섬 inode DIO 쓰기 → 버퍼드 폴백 |
| 6.16 | XFS CoW 기반 원자 쓰기, ext4 bigalloc 원자 쓰기, `stx_atomic_write_unit_max_opt` |
| 6.18 | `RWF_NOSIGNAL` |
| 6.19 / 7.0 | `IOMAP_DIO_FSBLOCK_ALIGNED` / `IOMAP_DIO_BOUNCE` |
| 7.3 개발 주기 | `__iomap_dio_read_simple()`, `iomap_ops->iomap_next`, btrfs `IOMAP_DIO_BOUNCE` |

### 4.6 운영상 함의와 한계
- **정렬은 추측하지 말고 묻는다.** `statx(STATX_DIOALIGN | STATX_DIO_READ_ALIGN | STATX_WRITE_ATOMIC)`를 지원하지 않는 커널이나 파일시스템은 마스크 비트를 돌려주지 않는다. 이때만 512B/4KiB 가정으로 폴백한다.
- **DIO가 조용히 버퍼드가 되는 경우를 알아 둔다.** ext4 verity/data=journal/inline data, btrfs compressed/inline extent, 무효화 실패(`-ENOTBLK`), 6.15~7.2 btrfs 체크섬 inode 쓰기가 그렇다. 이 경우 지연과 메모리 사용은 버퍼드 특성(→ 11/02)을 따른다.
- **`O_DSYNC` DIO는 덮어쓰기면 FUA 한 번으로 끝난다.** 할당이나 unwritten 변환이 섞이면 완료 후 `generic_write_sync()`로 저널 커밋과 flush가 추가된다. 사전 할당(`fallocate`)한 뒤 한 번 써 둔 파일과 sparse 파일의 쓰기 지연이 다른 이유다.
- **`RWF_NOWAIT`의 `-EAGAIN`은 정상 신호다.** 락 경합, 할당 필요, 캐시 페이지 존재(읽기), btrfs 바운스 쓰기에서 나온다. io_uring은 이를 io-wq로 흡수하지만, 직접 `preadv2(RWF_NOWAIT)`를 쓰는 애플리케이션은 재시도 경로를 직접 가져야 한다.
- **원자 쓰기는 장치·파일시스템·크기가 모두 맞아야 한다.** `stx_atomic_write_unit_max_opt` 초과 크기는 XFS에서 CoW 소프트웨어 경로로 가서 extent remap 비용을 낸다. 버퍼드 원자 쓰기는 master 기준 없다.

---

## 5. Primary References

- [The return of RWF_UNCACHED (LWN, 2024-12-04)](https://lwn.net/Articles/998783/) — 파일 단위 대 I/O 단위 플래그 논쟁, Axboe의 `RWF_NOWAIT`/`O_NONBLOCK` 발언
- [Filesystems and iomap (LWN, 2024-05-28)](https://lwn.net/Articles/974958/) — 2024 LSFMM+BPF iomap 전환 현황, `LEGACY_DIRECT_IO` 논의, Wilcox 발언
- [Support for atomic block writes in 6.13 (LWN, 2025-02-20)](https://lwn.net/Articles/1009298/) — 6.13 원자 쓰기 인터페이스와 단일 블록 제약
- [The ongoing quest for atomic buffered writes (LWN, 2026-03-02)](https://lwn.net/Articles/1060063/) — 버퍼드 원자 쓰기, Hellwig와 Freund의 입장, writethrough 제안
- [Buffered atomic writes, writethrough, and more (LWN, 2026-05-14)](https://lwn.net/Articles/1072019/) — 2026 LSFMM+BPF `RWF_WRITETHROUGH` 논의
- [make statx() return DIO alignment information (LWN)](https://lwn.net/Articles/898176/) — Eric Biggers의 `STATX_DIOALIGN` 패치셋
- [1. Library Design — The Linux Kernel documentation](https://docs.kernel.org/filesystems/iomap/design.html) — iomap 공식 설계 문서(`iomap_iter`, 매핑 타입)
- [2. Supported File Operations — The Linux Kernel documentation](https://docs.kernel.org/filesystems/iomap/operations.html) — iomap DIO/버퍼드/writeback 연산 문서
- [iomap: implement direct I/O (commit ff6a9292e6f6)](https://github.com/torvalds/linux/commit/ff6a9292e6f633d596826be5ba70d3ef90cc3300) — Linux 4.10, `iomap_dio_rw()` 도입
- [iomap: add the new iomap_iter model (commit f4b896c213f0)](https://github.com/torvalds/linux/commit/f4b896c213f0752adc828ddc11bd55419ffab248) — Linux 5.15 반복자 모델
- [fs: Introduce RWF_NOWAIT and FMODE_AIO_NOWAIT (commit b745fafaf70c)](https://github.com/torvalds/linux/commit/b745fafaf70c0a98a2e1e7ac8cb14542889ceb0e) — Linux 4.13
- [fs: build the legacy direct I/O code conditionally (commit 9636e650e16f)](https://github.com/torvalds/linux/commit/9636e650e16f6b01f0044f7662074958c23e4707) — Linux 6.3 `CONFIG_LEGACY_DIRECT_IO`
- [statx: add direct I/O alignment information (commit 825cf206ed51)](https://github.com/torvalds/linux/commit/825cf206ed510c4a1758bef8957e2b039253e2e3) — Linux 6.1
- [fs: Initial atomic write support (commit c34fc6f26ab8)](https://github.com/torvalds/linux/commit/c34fc6f26ab86d03a2d47446f42b6cd492dfdc56) — Linux 6.11 `RWF_ATOMIC`
- [iomap: add a flag to bounce buffer direct I/O (commit c9d114846b38)](https://github.com/torvalds/linux/commit/c9d114846b380fec1093b7bca91ee5a8cd7b575d) — Linux 7.0 `IOMAP_DIO_BOUNCE`
- [btrfs: use IOMAP_DIO_BOUNCE flag instead of falling back to buffered IO (commit e9b7b9d9e78e)](https://github.com/torvalds/linux/commit/e9b7b9d9e78e5beec7f398343c979838ba29645f) — 7.3 개발 주기, 제로카피·버퍼드·바운스 비교 수치
- [iomap: add simple dio path for small direct I/O (commit 36f199c8d0ee)](https://github.com/torvalds/linux/commit/36f199c8d0ee4b8dab3559c8bc23dd5e7c366972) — 7.3 개발 주기, Gen5 NVMe 4K 읽기 오버헤드 측정
