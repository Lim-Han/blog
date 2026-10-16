# 블록 스태킹 계층: md RAID, device-mapper(dm-crypt/thin/integrity/verity), blk-crypto 인라인 암호화

> 기준: Linux `torvalds/linux` master(7.3-rc7, 2026-10 확인)의 `drivers/md/{md.c,md.h,md-bitmap.[ch],md-llbitmap.c,raid0.c,raid1.c,raid10.c,raid5.[ch],raid5-cache.c,raid5-ppl.c,dm.c,dm-core.h,dm-table.c,dm-crypt.c,dm-thin.c,dm-integrity.c,dm-verity-target.c,Kconfig}`, `include/linux/device-mapper.h`, `block/{blk-settings.c,blk-crypto.c,blk-crypto-profile.c,blk-crypto-fallback.c}`, `include/linux/{blkdev.h,blk-crypto.h,blk-crypto-profile.h}`, `include/uapi/linux/blk-crypto.h`, `Documentation/admin-guide/{md.rst,device-mapper/dm-crypt.rst,device-mapper/dm-integrity.rst}`. 기능 도입 버전은 릴리스 태그별 소스에서 파일·심볼이 처음 등장하는 버전이다. blk-mq 자체는 (→ 02/01), bio와 request의 구분은 (→ 02/03), 존드 장치는 (→ 09/01), 쓰기 스트림/FDP는 (→ 09/02)를 참조한다.

## 1. Verdict

**기준 버전: Linux 7.3-rc7 master.**

md와 device-mapper(dm)는 모두 **bio 기반 가상 블록 장치**다. 자체 `->submit_bio`에서 bio를 받아 하위 장치용 bio로 복제·분할·재매핑한 뒤 다시 `submit_bio_noacct()`로 내려보낸다. 하위 장치의 blk-mq 큐(태그, hctx, 스케줄러)는 맨 아래 물리 장치에만 있다. 예외는 request 기반 dm(`DM_TYPE_REQUEST_BASED`, 사실상 dm-multipath)뿐이다. 그래서 스태킹 계층의 성능 문제는 대부분 blk-mq 바깥에서 생긴다. 원인은 (1) 계층 자신의 직렬화 지점(전역 락, 단일 스레드), (2) 작업 큐로의 문맥 전환, (3) 상위로 잘못 전파되거나 전파되지 않은 `queue_limits` 세 가지다.

| 커널 | 변화 | 의미 |
|---|---|---|
| 2.6.4 | dm-crypt | 소프트웨어 블록 암호화의 표준 |
| 3.2 / 3.4 | dm-thin / dm-verity | 씬 프로비저닝·스냅숏, 읽기 전용 무결성(Android, ChromeOS) |
| 4.4 | raid5 journal(`raid5-cache.c`, write-through) | RAID5 write hole 차단 |
| 4.10 | raid5 journal write-back(`R5C_JOURNAL_MODE_WRITE_BACK`) | 저널 장치를 쓰기 캐시로 사용 |
| 4.12 | raid5 PPL(`raid5-ppl.c`), dm-integrity | 저널 장치 없이 write hole 차단, 섹터 단위 무결성 태그 |
| 5.8 | blk-crypto(`keyslot-manager.c`) | 인라인 암호화 하드웨어(UFS/eMMC ICE)용 블록 계층 프레임워크 |
| 5.9 | dm-crypt `no_read_workqueue`/`no_write_workqueue` | 작업 큐 우회로 NVMe 지연 감소 |
| 5.12 | dm의 인라인 암호화 능력 교집합 전달(당시 `dm_table_construct_keyslot_manager`, 5.16에서 `dm_table_construct_crypto_profile`로 개명) | dm-linear 등 위에서도 인라인 암호화 사용 |
| 5.16 | `struct blk_keyslot_manager` → `struct blk_crypto_profile` | 이름·구조 정리 |
| 6.6 | `CONFIG_MD_BITMAP_FILE`(외부 파일 비트맵을 선택 사항으로) | 파일 비트맵 단계적 폐지 |
| 6.10 | dm-crypt `high_priority` | 작업 큐·writer 스레드를 고우선순위로 |
| 6.11 | dm-integrity inline 모드(`'I'`) | 하위 장치 PI/메타데이터 영역에 태그 저장 |
| 6.12 | `struct bitmap_operations`(md 비트맵 추상화) | 비트맵 구현 교체 가능 구조 |
| 6.13 | 원자적 쓰기 스태킹(`blk_stack_atomic_writes_limits`), md raid0/1/10 `BLK_FEAT_ATOMIC_WRITES_STACKED`(6.14에서 `BLK_FEAT_ATOMIC_WRITES`로 개명) | md 위에서 `RWF_ATOMIC` |
| 6.14 | `DM_TARGET_ATOMIC_WRITES`(dm-linear/stripe/mirror). dm-mpath·dm-crypt는 6.19 | dm 위에서 `RWF_ATOMIC` |
| 6.15 | blk-crypto 하드웨어 래핑 키(`BLK_CRYPTO_KEY_TYPE_HW_WRAPPED`, `BLKCRYPTO*KEY` ioctl) | 커널 메모리에 평문 키가 남지 않는 인라인 암호화 |
| 6.18 | `md-llbitmap`(lockless bitmap, `CONFIG_MD_LLBITMAP`, 실험적), `CONFIG_MD_BITMAP` | 전역 락 없는 쓰기 의도 비트맵 |
| 7.0 | `blk_crypto_submit_bio()` | crypto fallback 판단을 호출자 쪽 헬퍼로 이동 |
| 7.2 | dm-inlinecrypt(`CONFIG_DM_INLINECRYPT`) + 하드웨어 래핑 키 | dm-crypt 문법으로 blk-crypto 사용 |

결론:

1. **스태킹 계층의 성능은 "몇 번 문맥을 바꾸고 어디서 직렬화하는가"로 결정된다.** dm-crypt는 기본적으로 bio 하나를 `kcryptd_io`(I/O 제출)와 `kcryptd`(암복호화) 작업 큐, 그리고 쓰기 정렬용 `dmcrypt_write` 커널 스레드로 넘긴다. HDD 시절에 합리적이던 이 설계가 NVMe에서는 지연의 주원인이 되었다. Ignat Korchagin(Cloudflare)의 5.9 패치가 이를 우회하는 플래그를 넣었다(3.1절).
2. **md의 오래된 병목은 쓰기 의도 비트맵이다.** 모든 쓰기가 비트맵 비트를 먼저 dirty로 만들고 비트맵 페이지를 디스크에 쓴 다음에야 데이터를 낼 수 있다. 기존 `md-bitmap.c`는 전역 spinlock과 자체 페이지 쓰기 경로를 가진다. Yu Kuai(Huawei)는 이 구현을 고치는 대신 6.18에서 lockless 비트맵(`md-llbitmap.c`)을 새로 넣었다. 비트맵 구현은 6.12에서 `struct bitmap_operations`로 추상화되었고, 6.18부터 sysfs `bitmap_type`으로 `bitmap`/`llbitmap`/`none`을 고른다.
3. **blk-crypto는 "암호화를 장치에 맡기되 키 관리는 블록 계층이"라는 모델이다.** 파일 시스템(fscrypt)이나 dm 타깃이 bio에 `struct bio_crypt_ctx`(키 + DUN)를 붙인다. 블록 계층은 장치의 `struct blk_crypto_profile`에서 키슬롯을 잡아 프로그래밍하고, 지원되지 않는 조합은 crypto API 기반 fallback(`CONFIG_BLK_INLINE_ENCRYPTION_FALLBACK`)으로 처리한다. 6.15의 하드웨어 래핑 키는 키가 커널 메모리에 평문으로 존재하지 않게 한다.
4. **dm은 crypto profile을, 블록 계층은 원자적 쓰기 한도를 "교집합"으로 전파한다.** 하나라도 지원하지 않는 하위 장치가 있으면 상위 장치에서 기능이 사라진다. 원자적 쓰기는 `chunk_sectors`(RAID 스트라이프)에 맞춰 2의 거듭제곱으로 다시 깎인다. 반면 쓰기 스트림(`max_write_streams`)은 `blk_stack_limits()`가 전파하지 않으므로 md/dm 위에서는 0이다(4.7절).
5. **Android의 dm-default-key는 메인라인에 들어오지 못했다.** 7.2의 dm-inlinecrypt는 그 코드에서 논쟁적이던 passthrough(상위 fscrypt가 이미 암호화한 bio는 건너뛰는 기능)를 뺀 형태로 들어왔다. 그래서 fscrypt와 함께 쓰면 이중 암호화가 된다(3.3절).

---

## 2. Problem Statement

### 2.1 bio 기반 스태킹의 구조적 비용

md와 대부분의 dm 타깃은 `struct block_device_operations`의 `->submit_bio`만 구현한다. 상위에서 들어온 bio는 다음을 거친다.

- **복제와 분할.** dm은 bio마다 `struct dm_io`와 타깃별 `struct dm_target_io`를 만들고, 타깃 경계나 `max_io_len`에 걸리면 `dm_accept_partial_bio()`로 앞부분만 처리한 뒤 나머지를 다시 돈다. md는 personality의 `make_request`가 스트라이프·청크 경계에서 `bio_split()`한다.
- **재귀 제출 평탄화.** 하위로 내려가는 `submit_bio_noacct()`는 `current->bio_list`에 쌓였다가 상위 `->submit_bio`가 끝난 뒤 순서대로 처리된다. 스택 오버플로를 막는 장치지만, 스택이 깊을수록 bio 할당·완료 콜백 체인이 길어진다.
- **완료 경로.** 하위 bio 완료 → 상위 `clone_endio()`(dm) 또는 personality의 `end_io` → 원본 bio 완료. dm-crypt 읽기처럼 완료 후 추가 작업(복호화)이 필요하면 인터럽트 문맥에서 할 수 없으므로 작업 큐로 넘어간다.

blk-mq의 plug 배치, 폴링(`REQ_POLLED`), `nowait`(`REQ_NOWAIT`)는 스택 계층이 명시적으로 지원해야 위로 전파된다. `blk_stack_limits()`는 하위 장치 중 하나라도 `BLK_FEAT_NOWAIT`/`BLK_FEAT_POLL`/`BLK_FEAT_PCI_P2PDMA`가 없으면 상위에서 그 비트를 지운다.

### 2.2 RAID5/6의 write hole과 RMW

패리티 RAID에서 부분 스트라이프 쓰기는 기존 데이터·패리티를 읽어 새 패리티를 계산해야 한다(read-modify-write, `rmw_level`) 아니면 나머지 데이터 청크를 읽어 다시 계산한다(reconstruct-write). 데이터와 패리티가 서로 다른 디스크에 비원자적으로 써지므로 정전 시 둘이 어긋나는 **write hole**이 생긴다. 해법은 세 가지다. 재동기화(비트맵이 범위를 줄임), 저널 장치(raid5-cache), 그리고 패리티 로그(PPL)다. 모두 쓰기 경로에 추가 I/O나 락을 넣는다.

raid5 쓰기는 `struct stripe_head` 캐시(기본 `NR_STRIPES` = 256개, sysfs `stripe_cache_size`, 범위 17~32768)를 거친다. bio의 데이터는 스트라이프 페이지로 복사되고(`skip_copy`로 끌 수 있음), 상태 머신 `handle_stripe()`가 패리티 계산과 디스크 I/O를 진행한다. 기본값에서는 이 처리가 배열당 커널 스레드 `raid5d` 하나에 몰린다. `group_thread_cnt`(기본 0)를 올려야 NUMA 노드별 워커 그룹(`struct r5worker_group`)이 생긴다.

### 2.3 dm-crypt의 비동기 파이프라인

dm-crypt 코드 주석은 작업 큐를 둘로 나눈 이유를 이렇게 설명한다. 인터럽트 문맥에서 복호화하면 안 되고, 제출 단계와 암복호화 단계를 분리하지 않으면 메모리 할당에서 막힌 새 요청이 마지막 단계를 굶길 수 있다는 것이다. 쓰기는 암호화 후 `dmcrypt_write` 스레드가 red-black tree(`write_tree`)로 섹터 순 정렬해서 제출한다. 관리 문서(`dm-crypt.rst`의 `submit_from_crypt_cpus` 설명)에 따르면 이 단일 스레드 제출은 CFQ 시절 같은 문맥에서 쓰기를 내는 것이 유리했던 데서 왔다. NVMe에서는 이 단계 하나하나가 수 µs의 스케줄링 지연과 캐시 이동을 더한다.

### 2.4 쓰기 의도 비트맵의 직렬화

`md-bitmap.c`의 쓰기 경로(`start_write`)는 비트맵 카운터를 올리고, 해당 비트맵 페이지가 디스크에 반영되기 전에는 데이터 쓰기를 내보내지 않는다(`unplug`). 카운터는 `bitmap->counts.lock` 하나로 보호된다. 같은 청크에 연속으로 쓰더라도 카운터 증감과 락 획득은 쓰기마다 일어난다. 빠른 NVMe RAID1/10에서는 이 락과 비트맵 플러시가 처리량 상한이 된다(3.2절).

### 2.5 인라인 암호화 하드웨어

모바일 SoC의 UFS/eMMC 호스트 컨트롤러에는 DMA 경로에서 AES-XTS를 처리하는 엔진(Qualcomm ICE, Exynos FMP 등)이 있다. CPU 암호화보다 전력과 메모리 대역폭 면에서 유리하다. 대신 키슬롯 수가 수십 개 수준으로 제한되고, 요청마다 키슬롯 번호와 DUN(data unit number, IV)을 실어 보내야 한다. 블록 계층에는 (1) 어떤 키가 어느 슬롯에 있는지 LRU로 관리하고, (2) 요청 병합 시 DUN 연속성을 검사하고, (3) 하드웨어가 없으면 투명하게 소프트웨어로 처리하는 공통 프레임워크가 필요했다. 이것이 5.8의 blk-crypto다.

### 2.6 한도 전파 문제

상위 장치는 하위 장치들의 `struct queue_limits`를 `blk_stack_limits()`로 합성한다. 논리/물리 블록 크기, `max_sectors`, `max_segments`, `dma_alignment`, `chunk_sectors`, discard 세분도, 원자적 쓰기 한도, 존드 속성이 여기서 결정된다. 합성을 잘못하면 상위에서 허용한 I/O가 하위에서 쪼개지거나(원자성 위반), 정렬이 맞지 않아 `BLK_FLAG_MISALIGNED`가 서거나, 하위 장치의 기능(FUA, 폴링)이 상위에서 사라진다.

---

## 3. The Debate

### 3.1 dm-crypt의 작업 큐: 역사적 유산인가, 필요한 격리인가

Cloudflare의 Ignat Korchagin은 2020년 dm-crypt 경로의 지연을 분석한 뒤 작업 큐를 건너뛰는 플래그를 제안했다. 커밋 `39d42fa96ba1`("dm crypt: add flags to optionally bypass kcryptd workqueues", 5.9)의 설명은 다음과 같다.

> "Current dm-crypt implementation creates a significant IO performance overhead (at least on small IO block sizes) for both latency and throughput. We suspect offloading IO request processing into workqueues and async threads is more harmful these days with the modern fast storage. I also did some digging into the dm-crypt git history and much of this async processing is not needed anymore, because the reasons it was added are mostly gone from the kernel."
>
> — Ignat Korchagin, 2020-07-06 ([github.com/torvalds/linux/commit/39d42fa96ba1](https://github.com/torvalds/linux/commit/39d42fa96ba1b7d2544db3f8ed5da8fb0d5cb877))

해설: 당시 dm 메인테이너 Mike Snitzer는 기본값을 바꾸지 않고 **옵트인 플래그**로 받았고, 문서화는 Milan Broz가 뒤이어 했다(`4a5caa4af0df` "dm crypt: document new no_workqueue flags"). 기본 동작을 지킨 이유는 같은 커밋이 밝힌 한계에 있다. 첫째, 일부 NVMe 드라이버처럼 읽기 완료가 hard IRQ 문맥에서 오면 그 자리에서 복호화할 수 없다. 둘째, Crypto API 구현체 자신이 내부 작업 큐로 넘길 수 있다. 커밋은 "these flags only ensure no async BIO processing in the dm-crypt module"이라고 범위를 한정했다. 처음에는 hard IRQ일 때 tasklet으로 넘겼다. 이 경로는 곧 문제를 드러냈다. 2021-01의 수정 두 건(`d68b29584c25` "use GFP_ATOMIC when allocating crypto requests from softirq", `8e14f610159d` "do not call bio_endio() from the dm-crypt tasklet")은 softirq 문맥에서 잠드는 할당과 tasklet 객체의 use-after-free를 고쳤다. master의 `kcryptd_queue_crypt()`는 tasklet 대신 `in_hardirq() || irqs_disabled()`이면 작업 큐로 돌아가는 형태다. 정리하면 "동기 처리가 빠르다"는 주장은 맞지만, 완료 문맥이 장치마다 다르다는 사실 때문에 기본값이 될 수는 없었다.

호스트 관리형 존드 장치에서는 `no_write_workqueue`가 자동으로 켜진다(`dm-crypt.rst`). 작업 큐와 `write_tree`를 거치면 제출 순서가 바뀔 수 있어 존 순차 쓰기 규칙과 충돌하기 때문으로 보인다(문서는 이유를 적지 않는다).

### 3.2 md 비트맵: 고칠 것인가, 새로 만들 것인가

md의 외부 파일 비트맵(파일 시스템 위의 파일에 비트맵을 두는 옵션)은 Christoph Hellwig가 6.6에서 `CONFIG_MD_BITMAP_FILE`로 분리했다.

> "The support for write intent bitmaps in files on an external files in md is a hot mess that abuses ->bmap to map file offsets into physical device objects, and also abuses buffer_heads in a creative way."
>
> — Christoph Hellwig, "md: make bitmap file support optional", 2023-06-15 ([github.com/torvalds/linux/commit/a34d4ef82c3c](https://github.com/torvalds/linux/commit/a34d4ef82c3c4bd8bda817e9fb53ef37c5595ddd))

해설: 목표는 buffer_head 없는 커널에서도 md를 빌드하는 것이었다. 같은 커밋은 내부 비트맵(슈퍼블록 근처)에는 이런 문제가 없다고 구분했다. Kconfig 도움말은 이 옵션을 "(deprecated)"로 표시한다.

내부 비트맵의 성능 문제는 Yu Kuai가 맡았다. 그는 2024년 비트맵 구현을 `struct bitmap_operations` 뒤로 숨기는 리팩터링을 진행했고(6.12, "md/md-bitmap: introduce struct bitmap_operations"), 2025년에 새 구현을 넣었다.

> "Due to known performance issues with md-bitmap and the unreasonable implementations: - self-managed IO submitting like filemap_write_page(); - global spin_lock I have decided not to continue optimizing based on the current bitmap implementation, this new bitmap is invented without locking from IO fast path and can be used with fast disks."
>
> — Yu Kuai, "md/md-llbitmap: introduce new lockless bitmap", 2025-08-29 ([github.com/torvalds/linux/commit/5ab829f1971d](https://github.com/torvalds/linux/commit/5ab829f1971dc99f2aac10846c378e67fc875abc))

해설: 기존 구현을 점진적으로 고치지 않고 병행 구현을 들인 결정이다. 근거는 두 가지다. 기존 코드는 md-cluster, 외부 파일 비트맵, behind write 같은 기능과 얽혀 있어 락을 걷어내기 어렵다. 그리고 비트맵 형식 자체가 "카운터 + 디스크 비트"라 쓰기마다 카운터를 건드린다. llbitmap은 비트 하나를 1바이트 상태(`BitUnwritten`/`BitClean`/`BitDirty`/`BitNeedSync`/`BitSyncing` 등)로 바꾸고, 같은 비트에 대한 두 번째 이후 쓰기는 추가 비용이 없게 만들었다. 대가는 호환성이다. 별도 형식이고, Kconfig는 "experimental feature"라고 명시하며 기본값이 N이다. 생성 후에는 `bitmap_type`을 바꿀 수 없다(`md.rst`). llbitmap을 생성할 수 있는 mdadm 버전은 다루지 않는다 [추측/미확인].

### 3.3 dm-default-key와 dm-inlinecrypt: passthrough 논쟁

Android는 수년간 다운스트림 타깃 dm-default-key로 "메타데이터 암호화"를 해 왔다. 파일 내용은 fscrypt가 파일별 키로 인라인 암호화하고, 파일 시스템 메타데이터와 미사용 블록은 dm-default-key가 장치 키로 암호화한다. 핵심은 **passthrough**다. 이미 fscrypt 암호화 문맥이 붙은 bio는 dm-default-key가 건드리지 않아 이중 암호화를 피한다. 이 기능은 상위 계층이 블록 계층에 "이 bio는 암호화하지 말라"고 지시하는 셈이라 메인라인에서 받아들여지지 않았다. 7.2의 dm-inlinecrypt 커밋은 이를 명시한다.

> "dm-inlinecrypt is based on Android's dm-default-key with the controversial passthrough support removed. Note that due to the removal of passthrough support, use of dm-inlinecrypt in combination with fscrypt causes double encryption of file contents (similar to dm-crypt + fscrypt), with the fscrypt layer not being able to use the inline encryption hardware. This makes dm-inlinecrypt unusable on systems such as Android that use fscrypt and where a more optimized approach is needed. It is however suitable as a replacement for dm-crypt."
>
> — Eric Biggers, "dm-inlinecrypt: add target for inline block device encryption", 2026-04-30 ([github.com/torvalds/linux/commit/e7f57d2c47e2](https://github.com/torvalds/linux/commit/e7f57d2c47e265ef64e1dab84fc8f70dae2dd150))

해설: 메인라인은 "범용 dm-crypt 대체재"를 먼저 받고, Android식 계층 간 협업은 미해결로 남겼다. 초기 버전은 AES-256-XTS만 지원하고, 하드웨어가 해당 암호를 지원하지 않으면 blk-crypto fallback(소프트웨어)으로 내려간다. 같은 7.2 사이클에 Qualcomm(Linlin Zhang)의 하드웨어 래핑 키 지원(`f9f57971da38` "dm-inlinecrypt: add support for hardware-wrapped keys")이 이어졌다. LWN 게시본(2026-05-16)은 테이블 문법에 필수 인자를 하나 추가하는 형태였다. 머지된 커밋은 이를 선택 인자 `keytype:raw` / `keytype:hw-wrapped`(생략 시 raw)로 바꿔 기존 테이블과 호환된다(`dm-inlinecrypt.rst`).

### 3.4 하드웨어 래핑 키: 블록 계층이 키 수명 주기를 알아야 하는가

하드웨어 래핑 키 패치는 LWN에 게시된 2022-02-27의 v5부터 2025-02의 v11까지 3년 가까이 돌았다. Eric Biggers의 v10 커버 레터는 개념을 이렇게 정의한다.

> "hardware-wrapped keys are inline encryption keys that are wrapped (encrypted) by a key internal to the hardware so that they can only be unwrapped (decrypted) by the hardware. Initially keys are wrapped with a permanent hardware key, but during actual use they are re-wrapped with a per-boot ephemeral key for improved security. The hardware supports importing keys as well as generating keys itself."
>
> — Eric Biggers, "[PATCH v10 00/15] Support for hardware-wrapped inline encryption keys", 2024-12-12 ([lwn.net/Articles/1002065](https://lwn.net/Articles/1002065/))

해설: 쟁점은 범위였다. 커널 crypto API에도 "hardware-bound keys"가 있는데 왜 블록 계층에 따로 두는가에 대해, 커버 레터는 crypto API는 범용 암호 연산용이고 blk-crypto는 인라인 스토리지 암호화용이라는 같은 구분이 키에도 적용된다고 답했다. 다른 쟁점은 벤더 의존성이었다. Bartosz Golaszewski(Linaro)의 v7(2024-12-02)은 UFS/MMC 코어에 호스트별 훅을 추가하는 방식이었다. Biggers의 v9 이후는 ufs-qcom과 sdhci-msm이 `blk_crypto_profile`을 직접 초기화하게 바꿔 코어 변경을 줄였다. 결과적으로 블록 계층은 키 유형(`BLK_CRYPTO_KEY_TYPE_RAW` / `HW_WRAPPED`)과 네 가지 드라이버 연산(`derive_sw_secret`, `import_key`, `generate_key`, `prepare_key`)만 안다. 래핑 형식은 하드웨어·펌웨어 고유로 남는다. 6.15에 블록·fscrypt 프레임워크가 들어왔다.

---

## 4. Implementation Impact

### 4.1 진입 콜패스: md와 dm

```
[md]  submit_bio_noacct() → md_submit_bio(bio)
        bio_split_to_limits(bio)                    // 상위 queue_limits 기준 분할
        md_handle_request(mddev, bio)
          is_suspended()? → REQ_NOWAIT면 bio_wouldblock_error(), 아니면 sb_wait 대기
          percpu_ref_tryget_live(&mddev->active_io) // 정지(suspend)와의 동기화
          mddev->pers->make_request(mddev, bio)     // raid0/1/10/5 personality
            false 반환 시 ref 반납 후 check_suspended로 재시도

[dm]  submit_bio_noacct() → dm_submit_bio(bio)
        map = dm_get_live_table(md, &srcu_idx)      // SRCU로 테이블 교체와 동기화
        DMF_BLOCK_IO_FOR_SUSPEND? → REQ_NOWAIT면 거절, REQ_RAHEAD면 에러, 아니면 queue_io()
        dm_split_and_process_bio(md, map, bio)
          __split_and_process_bio(ci)               // 타깃 경계·max_io_len 단위로 clone
            __map_bio(clone) → ti->type->map(ti, clone)
               DM_MAPIO_REMAPPED → 하위로 submit, DM_MAPIO_SUBMITTED → 타깃이 직접 처리
        dm_put_live_table(md, srcu_idx)
      완료: clone_endio() → (ti->type->end_io) → dm_io_complete()
```

두 계층 모두 **"정지 중인 장치에 들어온 I/O를 어떻게 다루는가"**를 진입점에서 처리한다. md는 `percpu_ref`(`active_io`), dm은 SRCU와 `DMF_BLOCK_IO_FOR_SUSPEND` 플래그다. 공통적으로 `REQ_NOWAIT` bio는 기다리지 않고 `BLK_STS_AGAIN`으로 돌려준다. io_uring의 nowait 제출(→ 01/02)이 스택 장치에서 막히지 않으려면 이 경로와 `BLK_FEAT_NOWAIT` 전파가 모두 필요하다.

| 항목 | md | dm(bio 기반) | dm(request 기반, dm-mpath) |
|---|---|---|---|
| 큐 모델 | `->submit_bio` | `->submit_bio` | blk-mq(`dm-rq.c`), 자체 태그셋 |
| 구성 단위 | personality(raid0/1/10/456, linear) | 테이블 = 타깃 배열(`struct dm_table`) | 단일 타깃(`DM_TARGET_SINGLETON`) |
| 재구성 | sysfs/ioctl, reshape | 테이블 load → suspend → resume(원자 교체) | 같음 |
| I/O 동기화 | `percpu_ref active_io` | SRCU(`dm_get_live_table`) | 같음 + 요청 큐 quiesce |
| 메타데이터 | md 슈퍼블록, 비트맵, 저널 | 타깃별(thin pool 메타 장치, integrity 슈퍼블록 등) | 없음 |
| 대표 사용 | 소프트웨어 RAID | LVM, LUKS, Android/ChromeOS verity, 씬 풀 | SAN/NVMe-oF 다중 경로 |

### 4.2 md personality별 내부 구조

| personality | 쓰기 경로 핵심 | 동시성 장치 | 일관성 장치 | 원자적 쓰기(6.13~) |
|---|---|---|---|---|
| raid0 | 청크 단위 `bio_split` 후 매핑(`strip_zone`) | 없음(무상태) | 해당 없음 | 지원(`BLK_FEAT_ATOMIC_WRITES`) |
| raid1 | 모든 미러로 bio 복제, write-behind 선택 | 배리어 버킷(`BARRIER_BUCKETS_NR`, `nr_pending[]`/`barrier[]`) | 비트맵 + resync | 지원(배드 블록 때문에 `REQ_ATOMIC` bio를 쪼개야 하면 분할 대신 `BLK_STS_NOTSUPP`로 실패) |
| raid10 | near/far/offset 레이아웃 매핑 후 복제 | raid1과 같은 배리어 | 비트맵 + resync | 지원 |
| raid4/5/6 | `stripe_head` 캐시 경유, RMW/RCW, `handle_stripe()` | `hash_locks[NR_STRIPE_HASH_LOCKS]`(8개), `device_lock`, `raid5d` + `group_thread_cnt` 워커 | 비트맵, journal(`raid5-cache.c`), PPL(`raid5-ppl.c`) | 미지원 |

raid5 운영 파라미터(`/sys/block/mdX/md/`):

- `stripe_cache_size`: 기본 256, 최대 32768. 메모리 사용량은 대략 엔트리 수 × 스트라이프 페이지 크기 × 디스크 수다. 순차 쓰기에서 전체 스트라이프 쓰기를 모으려면 크게 잡는다.
- `group_thread_cnt`: 기본 0(= `raid5d` 단일 스레드). NVMe 배열에서는 사실상 필수 조정 항목이다.
- `stripe_size`: 5.9부터 sysfs로 노출된다. `PAGE_SIZE`가 4KiB가 아닌 시스템(arm64 64KiB 페이지 등)에서만 쓰기 가능하고 기본은 `DEFAULT_STRIPE_SIZE`(4096)다.
- `skip_copy`: bio 페이지를 스트라이프 캐시로 복사하지 않고 직접 사용한다. 하위 장치가 stable pages를 요구하면 의미가 달라지므로 주의한다.
- `journal_mode`: `write-through`(기본) / `write-back`. `consistency_policy`: `resync` / `bitmap` / `journal` / `ppl`.

PPL은 저널 장치 없이 각 멤버 디스크의 메타데이터 영역에 부분 패리티를 남기는 방식이다(raid5 전용). 저널(write-back)은 별도 고속 장치에 데이터와 패리티를 먼저 쓰므로 RMW 지연을 감추지만, 저널 장치가 단일 장애 지점이 된다.

### 4.3 md 비트맵: `bitmap` vs `llbitmap`

| 항목 | `md-bitmap.c`(classic) | `md-llbitmap.c`(6.18, 실험적) |
|---|---|---|
| Kconfig | `CONFIG_MD_BITMAP`(기본 y), 파일 비트맵 `CONFIG_MD_BITMAP_FILE`(deprecated) | `CONFIG_MD_LLBITMAP`(기본 n) |
| 비트 표현 | 청크당 16비트 카운터(메모리) + 디스크 비트 | 비트당 1바이트 상태(`enum llbitmap_state`) |
| 쓰기 경로 락 | `bitmap->counts.lock`(전역 spinlock) | IO 경로 lockless, 페이지별 `struct llbitmap_page_ctl`의 `percpu_ref` |
| 반복 쓰기 비용 | 쓰기마다 카운터 증감 | 같은 비트 두 번째 쓰기부터 추가 비용 없음 |
| dirty 해제 | 데몬이 카운터 0인 청크 정리 | 데몬(기본 30초, `DEFAULT_DAEMON_SLEEP`)이 5초 이상 유휴(`DEFAULT_BARRIER_IDLE`) 페이지를 suspend → clean → resume |
| 새 배열·새 디스크 | 전체 resync/recover | `BitUnwritten` 상태로 **쓴 영역만** sync. raid456은 `MD_RECOVERY_LAZY_RECOVER`로 지연 초기 복구 |
| 기본 크기 | 설정에 따름 | 128KiB(1KiB 슈퍼블록 포함), 청크 기본 64KiB, 비트 수가 127K 이상이면 청크를 2배씩 확대 |
| 선택 | `bitmap_type` = `bitmap` | `bitmap_type` = `llbitmap`(생성 시에만) |

`struct bitmap_operations`는 `start_write`/`end_write`/`start_discard`/`end_discard`, `start_sync`/`end_sync`, `unplug`, `daemon_work`, `skip_sync_blocks`, `blocks_synced` 같은 훅을 정의한다. personality 코드(raid1/10/5)는 이 함수 포인터만 부르므로 구현이 바뀌어도 쓰기 경로 코드는 그대로다. md 서브모듈 등록(`register_md_submodule()`, `ID_BITMAP`/`ID_LLBITMAP`/`ID_BITMAP_NONE`)은 personality 등록과 같은 틀을 쓴다.

### 4.4 dm-crypt 파이프라인과 옵션

`crypt_ctr()`가 장치마다 만드는 실행 문맥은 세 가지다.

- `kcryptd_io-<dev>`: `WQ_PERCPU` 작업 큐. 읽기 bio 제출(`kcryptd_io_read_work`)에 쓴다.
- `kcryptd-<dev>`: 암복호화 작업 큐. 기본은 `WQ_UNBOUND`(max_active = `num_online_cpus()`). `same_cpu_crypt`면 `WQ_CPU_INTENSIVE | WQ_PERCPU`로 제출 CPU에서 처리한다.
- `dmcrypt_write/<dev>`: 커널 스레드. 암호화된 쓰기 bio를 `write_tree`(rb-tree)에 모아 섹터 순으로 제출한다.

```
쓰기: crypt_map() → kcryptd_queue_crypt() ─(기본)→ kcryptd 작업 큐
        └ kcryptd_crypt_write_convert() → crypt_convert()(skcipher/aead)
          → kcryptd_crypt_write_io_submit()
              NO_WRITE_WORKQUEUE 또는 (동기 완료 && NO_OFFLOAD) → 즉시 submit
              그 외 → write_tree에 삽입, dmcrypt_write 깨움
읽기: crypt_map() → kcryptd_io_read() → 하위 장치 → crypt_endio()
        → kcryptd_queue_crypt() ─(기본)→ kcryptd 작업 큐 → 복호화 → bio_endio
           NO_READ_WORKQUEUE면 완료 문맥에서 바로 복호화
           (in_hardirq() || irqs_disabled()이면 어쩔 수 없이 작업 큐로)
```

| 옵션(테이블 인자) | 도입 | 효과 | 주의 |
|---|---|---|---|
| `same_cpu_crypt` | 4.0 | 제출 CPU에서 암복호화 | 제출이 소수 CPU에 몰리면 그 CPU만 포화 |
| `submit_from_crypt_cpus` | 4.0 | `dmcrypt_write` 오프로드 생략(`DM_CRYPT_NO_OFFLOAD`) | 정렬 없음 |
| `no_read_workqueue` | 5.9 | 읽기 복호화를 완료 문맥에서 동기 처리 | 완료가 hard IRQ면 효과 없음. softirq 시간 증가 |
| `no_write_workqueue` | 5.9 | 쓰기 암호화를 제출 문맥에서 동기 처리, rb-tree 생략 | 제출 스레드 CPU 사용 증가. 호스트 관리형 존드 장치에서 자동 활성 |
| `high_priority` | 6.10 | 작업 큐와 writer 스레드를 고우선순위로 | 문서상 "degrading general responsiveness" |
| 모듈 파라미터 `max_read_size`/`max_write_size` | 6.11 | 암호화 단위 요청 크기 상한(0 = 기본값) | 대형 I/O의 지연 분포 조정용 |

존드 장치에서는 dm-crypt가 `emulate_zone_append`를 켜고, zone append나 `REQ_ATOMIC` bio는 분할하지 않는다(필요하면 `DM_MAPIO_KILL`).

### 4.5 dm-thin, dm-integrity, dm-verity

**dm-thin**(3.2): 풀(`struct pool`)이 데이터 장치와 메타데이터 장치(persistent-data B-tree)를 묶는다. 새 블록 할당, 스냅숏 공유 블록의 쓰기 시 복사(CoW), discard는 `dm_bio_prison_cell`로 같은 블록 범위의 bio를 가둔 뒤 풀 워커가 처리한다. 워커는 풀당 하나의 **ordered 작업 큐**(`alloc_ordered_workqueue("dm-thin", WQ_MEM_RECLAIM)`)다. 이미 매핑된 블록에 대한 읽기·쓰기는 `thin_bio_map()`에서 바로 재매핑되어 빠르다. 할당과 CoW가 많은 워크로드(스냅숏 직후, 첫 쓰기)는 이 단일 워커와 메타데이터 커밋에 묶인다. 공간 고갈 시 동작은 `PM_OUT_OF_DATA_SPACE` 모드와 `error_if_no_space` 기능 인자로 정한다(기본은 모듈 파라미터 `no_space_timeout`, 기본 60초(`NO_SPACE_TIMEOUT_SECS`) 동안 bio를 보류한 뒤 에러). `DM_TARGET_PASSES_CRYPTO`가 있어 하위 장치의 인라인 암호화 능력을 위로 전달한다.

**dm-integrity**(4.12): 섹터마다 태그(CRC32C, HMAC 등)를 저장해 조용한 손상을 검출한다. 단독으로 쓰거나, dm-crypt의 AEAD 모드(`integrity:<bytes>:aead`) 하부 계층으로 쓴다.

| 모드 | 동작 | 크래시 일관성 | 쓰기 비용 |
|---|---|---|---|
| `J` journaled | 데이터와 태그를 저널에 먼저 기록 | 데이터·태그 원자적 | 문서: 쓰기 처리량 "degrades ... twice" |
| `B` bitmap | 비동기 기록 + dirty 영역 비트맵 | 크래시 후 dirty 영역 재계산 | 낮음(내부 해시 전용) |
| `D` direct | 저널 없이 따로 기록 | 데이터·태그 불일치 가능 | 낮음 |
| `R` recovery | 저널 재생·검사 없이 읽기 전용 | 복구용 | 해당 없음 |
| `I` inline(6.11) | 하위 장치의 메타데이터(PI) 영역에 태그 저장 | 하위 장치에 의존 | 추가 I/O 없음. 메타데이터 지원 NVMe 필요 |

기본값은 `DEFAULT_INTERLEAVE_SECTORS` 32768, `DEFAULT_BUFFER_SECTORS` 128, `DEFAULT_JOURNAL_WATERMARK` 50(%), `DEFAULT_SYNC_MSEC` 10000이다. 작업 큐가 `dm-integrity-metadata`/`-wait`/`-offload`/`-commit`/`-writer`/`-recalc`로 나뉘어 있어 dm-crypt보다 문맥 전환이 많다. `I` 모드는 NVMe의 확장 LBA 메타데이터를 쓰므로 저널·인터리브 영역이 필요 없다. 고속 장치에서 무결성 검사 비용을 줄이는 현실적 경로다.

**dm-verity**(3.4): 읽기 전용 장치를 Merkle 트리로 검증한다. 검증은 `kverityd` 작업 큐(`verify_wq`)에서 한다. 6.0의 `try_verify_in_tasklet` 옵션과 6.15의 모듈 파라미터 `use_bh_bytes`(ioprio 클래스별 바이트 상한, IDLE 클래스는 0)는 작은 읽기를 softirq/BH 문맥에서 바로 검증해 부팅 지연을 줄인다. 해시 블록이 bufio 캐시에 없어 잠들어야 하면 다시 kworker로 넘긴다. 손상 시 정책은 `ignore_corruption`/`restart_on_corruption`/`panic_on_corruption` 중에서 고른다.

### 4.6 blk-crypto: 프로파일, 키슬롯, fallback

```
[상위: fscrypt / dm-inlinecrypt]
blk_crypto_init_key(&key, key_bytes, key_size, key_type, crypto_mode, dun_bytes, data_unit_size)
blk_crypto_start_using_key(bdev, &key)         // 지원 여부 확인, 필요 시 fallback tfm 준비
bio_crypt_set_ctx(bio, &key, dun, GFP_NOIO)    // bio->bi_crypt_context = { bc_key, bc_dun[] }
blk_crypto_submit_bio(bio)                     // 7.0~: 네이티브 미지원이면 blk_crypto_fallback_bio_prep()
  → submit_bio() → blk-mq
[blk-mq] 병합 시 bio_crypt_rq_ctx_compatible()/bio_crypt_ctx_mergeable()로 키·DUN 연속성 검사
         blk_crypto_rq_get_keyslot(rq) → blk_crypto_get_keyslot(profile, key, &slot)
            해시(slot_hashtable)로 기존 슬롯 탐색 → 없으면 idle_slots LRU에서 하나 꺼내
            ll_ops.keyslot_program() 호출(슬롯이 없으면 idle_slots_wait_queue에서 대기)
[드라이버] UFS/eMMC 디스크립터에 슬롯 번호 + DUN 기록 → DMA 경로에서 암복호화
완료 후 blk_crypto_put_keyslot(); 키 폐기 시 blk_crypto_evict_key() → ll_ops.keyslot_evict()
```

`struct blk_crypto_profile`의 주요 필드는 `ll_ops`(`keyslot_program`, `keyslot_evict`, 래핑 키용 `derive_sw_secret`/`import_key`/`generate_key`/`prepare_key`), `max_dun_bytes_supported`, `key_types_supported`(`BLK_CRYPTO_KEY_TYPE_RAW` | `BLK_CRYPTO_KEY_TYPE_HW_WRAPPED`), `modes_supported[BLK_ENCRYPTION_MODE_MAX]`(데이터 단위 크기 비트마스크), `num_slots`, `lock`(rw_semaphore), `idle_slots` LRU, `slot_hashtable`이다. 지원 모드는 `BLK_ENCRYPTION_MODE_AES_256_XTS`, `AES_128_CBC_ESSIV`, `ADIANTUM`, `SM4_XTS`다.

fallback(`blk-crypto-fallback.c`)은 같은 프로파일 인터페이스를 소프트웨어로 구현한다. 쓰기는 바운스 페이지(`num_prealloc_bounce_pg`)에 암호화한 새 bio를 만들어 내보내고 원본은 완료까지 보관한다. 읽기는 완료 후 작업 큐에서 제자리 복호화한다. dm-crypt와 비슷한 비용 구조이므로 "인라인 암호화를 켰는데 CPU 사용률이 dm-crypt와 같다"면 fallback으로 떨어진 것이다.

하드웨어 래핑 키(6.15)의 사용자 공간 경로는 블록 장치 ioctl 세 개다. `BLKCRYPTOIMPORTKEY`(평문 키 → 장기 래핑 키), `BLKCRYPTOGENERATEKEY`(하드웨어가 키 생성), `BLKCRYPTOPREPAREKEY`(장기 래핑 키 → 부팅별 임시 래핑 키)다. 커널에는 임시 래핑 키만 전달된다. fscrypt는 파일 이름 암호화 등 소프트웨어 암호에 필요한 비밀을 `derive_sw_secret`으로 하드웨어에서 유도받는다.

**dm을 통한 전달.** 테이블 로드 시 `dm_table_construct_crypto_profile()`이 빈 프로파일(모든 모드·키 유형 허용)에서 시작해, 각 타깃이 `DM_TARGET_PASSES_CRYPTO`이면 하위 장치 프로파일과 `blk_crypto_intersect_capabilities()`로 교집합을 낸다. 플래그가 없는 타깃이 하나라도 있으면 능력은 비게 된다. 테이블 교체로 능력이 줄어드는 것은 허용하지 않는다(오류 반환). master 기준 `DM_TARGET_PASSES_CRYPTO`를 가진 타깃은 dm-linear, dm-stripe, dm-thin 등이다. dm-crypt, dm-integrity, dm-verity는 이 플래그가 없다. md는 crypto profile을 전달하지 않으므로 md RAID 위의 fscrypt는 인라인 하드웨어를 쓰지 못하고 fallback으로 간다. md 소스에 crypto profile 처리 코드가 없다는 점에 근거한 추론이다 [추측/미확인].

### 4.7 한도 전파: `blk_stack_limits()`와 기능 비트

| 한도/기능 | 합성 규칙(`blk_stack_limits()`, master) | 스택 위에서의 결과 |
|---|---|---|
| `BLK_FEAT_INHERIT_MASK`(WRITE_CACHE, FUA, ROTATIONAL, STABLE_WRITES, ZONED, RAID_PARTIAL_STRIPES_EXPENSIVE) | 하위 중 하나라도 있으면 OR | 하나라도 회전형이면 상위도 회전형 |
| `BLK_FEAT_NOWAIT`, `BLK_FEAT_POLL`, `BLK_FEAT_PCI_P2PDMA` | 하위 중 하나라도 없으면 제거 | dm은 `dm_set_stacking_limits()`가 IO_STAT/NOWAIT/POLL로 시작해 깎아 나감 |
| `max_sectors`, `max_segments`, `max_hw_zone_append_sectors` | `min`/`min_not_zero` | 가장 작은 장치 기준 |
| `dma_alignment` | `max` | 가장 엄격한 장치 기준 |
| `chunk_sectors` | `gcd`, 물리 블록 크기의 배수가 아니면 0 + `BLK_FLAG_MISALIGNED` | RAID 스트라이프 경계 |
| 원자적 쓰기(`atomic_write_hw_*`) | 첫 장치로 시작(`_head`), 이후 장치와 교집합(`_tail`, boundary 다르면 불가), 마지막으로 `chunk_sectors`의 최대 2의 거듭제곱 약수로 `unit_max` 제한 | 예: unit_max 16K, chunk 24K → 8K로 축소 |
| `BLK_FEAT_ATOMIC_WRITES` | 상속되지 않음. md personality / dm 타깃이 명시 설정 | md raid0/1/10(6.13), dm-linear/stripe/mirror(6.14), dm-mpath/crypt(6.19) |
| `max_write_streams`, `write_stream_granularity` | 합성 대상 아님(`blk_set_stacking_limits()`가 0으로 초기화) | md/dm 위에서 쓰기 스트림 사용 불가(→ 09/02) |

원자적 쓰기 경로에서 스택 계층이 지켜야 할 규칙은 "`REQ_ATOMIC` bio는 절대 쪼개지 않는다"이다. dm 코어는 타깃이 부분 처리를 요청하는 `dm_accept_partial_bio()`에서 `BUG_ON(bio->bi_opf & REQ_ATOMIC)`으로 원자적 bio의 분할을 금지한다. dm-crypt는 분할이 필요하면 `DM_MAPIO_KILL`로 실패시킨다. raid1은 배드 블록 등으로 쪼개야 하면 에러를 돌려준다. raid5는 패리티 갱신이 여러 디스크에 걸치므로 원자성을 보장할 수 없어 지원 목록에 없다.

존드 장치는 dm 쪽이 표준 경로다. dm-linear, dm-crypt, dm-inlinecrypt가 `DM_TARGET_ZONED_HM`을 갖고, `dm_table`은 혼합 존드 모델(`DM_TARGET_MIXED_ZONED_MODEL`)과 zone append 에뮬레이션을 처리한다(→ 09/01). md personality에는 존드 장치 전용 처리가 없다.

### 4.8 1차 사료에 나온 성능 함정

1. **dm-crypt 기본값은 HDD 시대 설정이다.** 5.9 커밋 설명대로 소형 I/O에서 지연·처리량 손실이 크다. NVMe에서는 `no_read_workqueue,no_write_workqueue`를 먼저 시험하고, 완료가 hard IRQ로 오는 드라이버에서는 효과가 제한적임을 감안한다. 인라인 암호화 하드웨어가 있는 플랫폼이라면 dm-inlinecrypt(7.2)가 대안이다.
2. **raid5 기본값 두 개(`stripe_cache_size` 256, `group_thread_cnt` 0)는 NVMe 배열에서 병목이다.** 둘 다 런타임 sysfs로 조정된다.
3. **비트맵은 쓰기 지연에 직접 더해진다.** 비트맵 청크를 크게 잡아 dirty 전환 빈도를 줄이거나, 실험적 llbitmap을 시험한다. 외부 파일 비트맵은 폐지 예정(`CONFIG_MD_BITMAP_FILE`)이다.
4. **dm-integrity `J` 모드는 쓰기를 두 번 한다.** 무결성이 목적이면 `B` 모드나, 메타데이터 지원 NVMe의 `I` 모드를 검토한다.
5. **스택 한 층이 기능을 지운다.** 폴링·nowait·P2PDMA·인라인 암호화·원자적 쓰기는 모두 "하나라도 없으면 없음"이다. `/sys/block/dm-N/queue/` 아래 `io_poll`, `atomic_write_unit_max_bytes` 등을 확인해 실제로 전파되었는지 본다.
6. **dm-thin의 할당 경로는 풀당 ordered 작업 큐 하나다.** 스냅숏 직후 쓰기 폭주나 대량 discard는 이 워커에서 직렬화된다.

---

## 5. Primary References

- [github.com/torvalds/linux - dm crypt: add flags to optionally bypass kcryptd workqueues](https://github.com/torvalds/linux/commit/39d42fa96ba1b7d2544db3f8ed5da8fb0d5cb877) — Ignat Korchagin, 2020-07-06 (5.9)
- [github.com/torvalds/linux - dm crypt: document new no_workqueue flags](https://github.com/torvalds/linux/commit/4a5caa4af0df5cd8f1c7f0c2f871d382662b022e) — Milan Broz, 2020-08-20
- [github.com/torvalds/linux - md: make bitmap file support optional](https://github.com/torvalds/linux/commit/a34d4ef82c3c4bd8bda817e9fb53ef37c5595ddd) — Christoph Hellwig, 2023-06-15 (6.6)
- [github.com/torvalds/linux - md/md-bitmap: introduce struct bitmap_operations](https://github.com/torvalds/linux/commit/7add9db6ba3e9bd12d2be97abbc13f3881a515db) — Yu Kuai, 2024-08-26 (6.12)
- [github.com/torvalds/linux - md/md-llbitmap: introduce new lockless bitmap](https://github.com/torvalds/linux/commit/5ab829f1971dc99f2aac10846c378e67fc875abc) — Yu Kuai, 2025-08-29 (6.18)
- [github.com/torvalds/linux - dm-inlinecrypt: add target for inline block device encryption](https://github.com/torvalds/linux/commit/e7f57d2c47e265ef64e1dab84fc8f70dae2dd150) — Eric Biggers, 2026-04-30 (7.2)
- [lwn.net - Support for hardware-wrapped inline encryption keys](https://lwn.net/Articles/1002065/) — Eric Biggers v10 커버 레터 게시본, 2024-12-12
- [lwn.net - Support for hardware-wrapped inline encryption keys](https://lwn.net/Articles/886377/) — v5 게시본, 2022-02-27
- [lwn.net - dm-inlinecrypt: add support for hardware-wrapped keys](https://lwn.net/Articles/1073146/) — Linlin Zhang 패치 게시본, 2026-05-16
- [kernel.org - Inline Encryption](https://docs.kernel.org/block/inline-encryption.html) — blk-crypto 설계 문서
- [kernel.org - dm-crypt](https://docs.kernel.org/admin-guide/device-mapper/dm-crypt.html) — dm-crypt 테이블 옵션
- [kernel.org - dm-integrity](https://docs.kernel.org/admin-guide/device-mapper/dm-integrity.html) — dm-integrity 모드와 인자
- [kernel.org - RAID arrays](https://docs.kernel.org/admin-guide/md.html) — md sysfs(`stripe_cache_size`, `bitmap_type`, `consistency_policy` 등)
- [git.kernel.org - block/blk-settings.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/block/blk-settings.c) — `blk_stack_limits()`, 원자적 쓰기 스태킹
- [git.kernel.org - drivers/md/md-llbitmap.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/md/md-llbitmap.c) — lockless 비트맵 설계 주석
