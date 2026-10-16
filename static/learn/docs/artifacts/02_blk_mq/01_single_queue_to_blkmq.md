# Legacy Single-Queue의 한계와 blk-mq 2계층 아키텍처

> 소스 기준: 함수·구조체 이름은 2026-10 시점 메인라인 master(Makefile `VERSION = 7`, `PATCHLEVEL = 3`)와 버전별 태그(`?h=vX.Y`)를 git.kernel.org에서 grep해 확인했다. 본문에서 "6.x 기준"이라 쓴 경로는 6.16 이후 master까지 동일하게 유지되는 구조다.

## 1. Verdict

`blk-mq`(Multi-Queue Block I/O Queueing Mechanism)는 Linux 3.13(2014년 1월 릴리스)에 병합된 블록 계층 재설계다. 프로토타입과 설계 논문은 Matias Bjørling(당시 IT University of Copenhagen)과 Jens Axboe가 주도했고, 결과는 SYSTOR '13 논문 "Linux block IO: introducing multi-queue SSD access on multi-core systems"(Bjørling, Axboe, Nellans, Bonnet)로 발표되었다. Christoph Hellwig의 주된 기여는 그 뒤의 `scsi-mq`(3.17)와 이후 레거시 경로 제거 작업이며, blk-mq 원설계자로 묶는 것은 정확하지 않다.

핵심 결정은 단일 `struct request_queue` + 디바이스 전역 `queue_lock` 모델을 버리고, I/O 경로를 다음 두 단계로 나눈 것이다.

- **소프트웨어 스테이징 큐** `struct blk_mq_ctx`: CPU마다 하나. 제출 CPU 로컬에서 요청을 모으고 병합한다.
- **하드웨어 디스패치 큐** `struct blk_mq_hw_ctx`(hctx): 드라이버가 노출하는 실제 제출 채널(NVMe SQ 등)에 대응한다.

여기에 요청 슬롯(tag)을 `struct blk_mq_tags` + `sbitmap_queue`로 관리하는 태그 할당기가 붙는다. 이 조합 덕분에 서로 다른 CPU의 제출이 같은 캐시라인을 두고 다투는 일이 크게 줄었다. "완전 락리스"는 아니다. `blk_mq_ctx`에도 `spinlock_t lock`이 있고 hctx에도 `lock`과 `dispatch` 리스트가 있다. 다만 이 락들은 CPU별·하드웨어 큐별로 쪼개져 있어서 보통은 경합이 없다. Linux 5.0에서 레거시 `request_fn` 경로가 삭제된 뒤로는 모든 request 기반 블록 드라이버가 `struct blk_mq_ops`를 구현한다. bio 기반 드라이버(`->submit_bio`를 쓰는 dm 일부, md, brd 등)는 지금도 따로 존재한다.

현대 커널에서의 의미:
1. NVMe, `null_blk`, virtio-blk, `scsi-mq`, `ublk` 등 모든 request 기반 드라이버가 같은 tag/hctx 모델을 공유한다. io_uring passthrough(`IORING_OP_URING_CMD`)도 `struct request`와 tag는 그대로 쓴다.
2. I/O 스케줄러(mq-deadline/kyber/bfq), QoS(`rq_qos`: wbt/iolatency/iocost), 폴링(`HCTX_TYPE_POLL`, `bio_poll`)이 모두 이 2계층 구조 위에 얹힌 확장이다.
3. 남은 병목은 큐 락이 아니라 요청 하나당 고정 비용(할당, 태그, 드라이버 doorbell)이다. 5.16~5.17의 plug 캐시 요청과 `->queue_rqs` 배치 제출은 이 비용을 줄이려고 들어왔다.

---

## 2. Problem Statement

### 2.1 단일 `request_queue`와 `queue_lock`
레거시 블록 계층(4.20까지 존재)에서는 디바이스마다 `struct request_queue`가 하나뿐이었다. v4.20 `include/linux/blkdev.h`에는 `spinlock_t __queue_lock;`과 `spinlock_t *queue_lock;`가 함께 있다. 드라이버가 자기 락을 큐 락으로 넘길 수 있게 하려고 포인터로 둔 것이다. 제출 경로는 대략 다음 단계를 모두 이 락 아래에서 거쳤다.

1. bio를 기존 request에 병합할 수 있는지 엘리베이터 해시/rbtree에서 찾는다.
2. 새 `struct request`를 할당하고 엘리베이터(CFQ, deadline, noop)에 넣는다.
3. 드라이버의 `request_fn`을 불러 디스패치한다. 이 콜백도 큐 락을 잡은 채로 실행된다.

요청 할당, 병합, 스케줄링, 디스패치, 완료(`blk_finish_request` 계열)가 모두 같은 락과 같은 리스트 헤드를 건드렸다. 그래서 여러 소켓의 CPU가 같은 디바이스에 제출하면 락 캐시라인과 큐 메타데이터가 소켓 사이를 계속 오갔다(cacheline bouncing). 완료 인터럽트가 제출 CPU와 다른 CPU에서 처리되면 원격 캐시 미스가 더 늘었다.

### 2.2 하드웨어 병렬성과의 불일치
NVMe 규격은 최대 64K개의 I/O Submission/Completion Queue 쌍을 정의하고, 컨트롤러는 실제로 수십~수백 개 큐를 노출한다. 하나의 `request_queue`와 `request_fn` 모델은 이 병렬성을 소프트웨어 쪽에서 한 줄로 직렬화한다. 초기 NVMe 드라이버(`drivers/block/nvme-core.c`)가 레거시 엘리베이터를 피하려고 `make_request_fn`(bio 기반)으로 직접 구현했던 것도 이 때문이다. NVMe 드라이버가 blk-mq로 전환된 것은 v3.19부터다(v3.18 `nvme-core.c`에는 `blk_mq_ops`가 없고 v3.19에는 있음).

### 2.3 문제의 정량적 근거
SYSTOR '13 논문의 초록은 기존 블록 계층이 "thousands of IOPS" 시대를 전제로 설계되어 NUMA 시스템에서 병목이 된다고 지적하고, 새 설계가 단일 장치를 둔 멀티코어 시스템에서 수천만 IOPS 수준까지 확장된다고 보고한다. `null_blk` 드라이버도 v3.13에 blk-mq와 함께 들어왔지만, 논문 측정이 정확히 어떤 장치와 소켓 구성에서 이루어졌는지, 구체적 IOPS 수치가 얼마인지는 논문 본문으로 확인해야 한다. 흔히 인용되는 "단일 큐 블록 계층은 80만~100만 IOPS에서 한계" 같은 수치는 1차 출처를 확인하지 못했으므로 이 문서에서는 쓰지 않는다 `[추측/미확인]`.

---

## 3. The Debate

이 절은 확인한 코드 이력과 LWN·논문을 근거로 쟁점을 서술한다. blk-mq 도입 당시 메인테이너 발언은 원문 링크를 확보하지 못해 인용 블록으로 쓰지 않는다.

### 3.1 락을 쪼갤 것인가, 큐 모델을 바꿀 것인가
기존 구조를 유지한 채 `queue_lock` 임계 구역을 줄이는 방법(락 분할, RCU 도입)도 이론적으로는 가능했다. 하지만 엘리베이터 하나가 디바이스 전체 요청의 전역 정렬 상태를 쥐고 있는 한, 그 상태를 갱신하는 지점은 결국 직렬화된다. SYSTOR '13 논문과 LWN "The multiqueue block layer"(2013-06-05)가 정리한 결론은 "CPU 로컬 스테이징 + 하드웨어 큐 단위 디스패치"로 공유 상태 자체를 나누는 것이었다. 이 선택에는 대가가 있었다. 전역 정렬과 공정성 보장을 포기해야 했고, 그래서 초기 blk-mq에는 I/O 스케줄러가 아예 없었다. 스케줄러는 4.11(`mq-deadline`)과 4.12(`kyber`, `bfq`)에서야 다시 들어왔다(→ 02/02).

### 3.2 공존 기간과 드라이버 전환
3.13부터 4.20까지 약 5년 동안 레거시 경로와 blk-mq가 함께 있었다. 주요 전환 시점은 코드로 확인할 수 있다.

- `null_blk`: 3.13, blk-mq와 동시 도입. 블록 계층 자체의 오버헤드를 재는 기준 장치다.
- `scsi-mq`: 3.17(`scsi_mq_ops` 첫 등장). Christoph Hellwig가 주도했다. `CONFIG_SCSI_MQ_DEFAULT`는 Linux 3.18에서 추가되었고 v4.18까지 기본값이 없었다(n). 중간에 Linux 4.13 merge window에서 Hellwig의 커밋 5c279bd9e406 "scsi: default to scsi-mq"(2017-06-16)가 scsi-mq를 기본으로 만들었지만, 4.13-rc에서 회귀가 잇따르자 cbe7dfa26eee (Revert "scsi: default to scsi-mq")(2017-08-13)로 4.13 릴리스 전에 되돌렸다. 최종 전환은 Linux 4.19의 d5038a13eca7 "scsi: core: switch to scsi-mq by default"(Johannes Thumshirn, 2018-07-04)로 `default y`가 되었다.
- NVMe: 3.19에서 bio 기반 `nvme_make_request`를 버리고 blk-mq로 전환했다.
- 5.0: 레거시 `request_fn`, CFQ, legacy deadline/noop 삭제(→ 02/03).

초기 SCSI 쪽의 반대 근거는 대략 세 가지였다. 단일 큐 HBA에서는 이득이 없다는 점, 회전 디스크에 쓸 스케줄러가 없다는 점, 에러 핸들링 경로가 안정적이지 않다는 점이다. 앞의 두 가지는 4.11~4.12의 blk-mq 스케줄러 프레임워크로 해소되었다.

### 3.3 태그 할당기: `percpu_ida`에서 `sbitmap`으로
흔히 "Jens Axboe가 `sbitmap`을 `blk_mq_tag_set`에 도입했다"고 요약되지만, 코드 이력은 다음과 같다.

| 시기 | 태그 할당기 | 근거 |
|---|---|---|
| 3.13~3.15 | `percpu_ida` (Kent Overstreet가 만든 per-CPU 캐시형 ID 할당기) | v3.13~v3.15 `block/blk-mq-tag.c`에 `percpu_ida` 18회 등장 |
| 3.16~4.8 | blk-mq 자체 비트맵 `struct blk_mq_bitmap_tags`, `bt_get()` | v3.16에서 `percpu_ida` 0회, `blk_mq_bitmap_tags` 14회 |
| 4.9~ | `lib/sbitmap.c`의 `struct sbitmap` / `struct sbitmap_queue` | v4.9 `lib/sbitmap.c`에 `sbitmap_queue_get` 존재. 파일 헤더 "Copyright (C) 2016 Facebook / 2013-2014 Jens Axboe" |

4.9의 일반화 작업은 당시 Facebook 소속이던 Omar Sandoval이 했다. blk-mq 전용 비트맵 코드를 `lib/`로 빼서 Kyber 같은 다른 사용자도 쓸 수 있게 했다. 커밋 88459642cba4 "blk-mq: abstract tag allocation out into sbitmap library"(작성자 Omar Sandoval <osandov@fb.com>, 2016-09-17)로 확인했다. 또 sbitmap은 `blk_mq_tag_set`이 아니라 `struct blk_mq_tags`의 `bitmap_tags`/`breserved_tags`(`struct sbitmap_queue`)에 들어 있다. `blk_mq_tag_set`은 드라이버가 등록하는 설정 묶음이고, 실제 비트맵은 hctx마다(또는 공유 태그일 때 하나) 할당되는 `blk_mq_tags`가 가진다.

`percpu_ida`를 버린 이유로는 보통 두 가지가 꼽힌다. 하나는 태그가 CPU별 캐시에 묶여 있어서, 큐 깊이가 작은 장치에서 다른 CPU에 남은 태그를 가져오는 비용과 공정성 문제가 생긴다는 점이다. 다른 하나는 깊이를 바꾸거나 태그를 공유하기 어렵다는 점이다 `[추측/미확인: 원 커밋 메시지 미확인]`.

### 3.4 CPU → hctx 매핑 정책
매핑 쟁점은 "하드웨어 큐 수 < CPU 수"일 때 어떤 CPU들을 같은 hctx에 묶을지였다. 지금 코드에서 기본 정책은 `block/blk-mq-cpumap.c`의 `blk_mq_map_queues(struct blk_mq_queue_map *qmap)`가 맡는다. PCI/virtio처럼 IRQ affinity를 아는 드라이버는 6.14부터 `blk_mq_map_hw_queues()`(그 전에는 `blk_mq_pci_map_queues()`, `blk_mq_virtio_map_queues()` 등 버스별 헬퍼)로 인터럽트 벡터의 affinity mask를 그대로 매핑에 반영한다. 그러면 완료 인터럽트가 제출 CPU 근처에서 처리된다. 맵은 `HCTX_TYPE_DEFAULT`, `HCTX_TYPE_READ`, `HCTX_TYPE_POLL` 세 종류이고(5.0에서 도입된 다중 큐 맵), 요청 플래그에 따라 `blk_mq_map_queue(opf, ctx)`가 `ctx->hctxs[blk_mq_get_hctx_type(opf)]`를 고른다.

---

## 4. Implementation Impact

### 4.1 핵심 자료구조 (master 기준)
- `struct request_queue`(`include/linux/blkdev.h`): `queue_lock`은 지금도 남아 있다. 다만 v5.0부터 포인터가 아닌 내장 `spinlock_t queue_lock;`이고, 핫패스 직렬화가 아니라 elevator 전환이나 blkcg 같은 제어 경로 보호에 쓰인다. `nr_requests`, 공유 스케줄러 태그 `sched_shared_tags`도 이 구조체에 있다.
- `struct blk_mq_ctx`(`block/blk-mq.h`): CPU마다 하나. `____cacheline_aligned_in_smp`로 정렬된 내부 블록에 `spinlock_t lock`과 `struct list_head rq_lists[HCTX_MAX_TYPES]`가 있고, `index_hw[]`, `hctxs[]`로 타입별 hctx를 가리킨다.
- `struct blk_mq_hw_ctx`(`include/linux/blk-mq.h`): `lock` + `dispatch` 리스트(드라이버가 거절해 되돌아온 요청용), `state`(`BLK_MQ_S_STOPPED`, `BLK_MQ_S_TAG_ACTIVE` 등), 어떤 ctx에 요청이 쌓였는지 표시하는 `struct sbitmap ctx_map`, `dispatch_busy`, `tags`, `sched_tags`를 가진다.
- `struct blk_mq_tag_set`: 드라이버가 채우는 `ops`, `nr_hw_queues`, `queue_depth`, `numa_node`, `flags`(`BLK_MQ_F_TAG_QUEUE_SHARED`, `BLK_MQ_F_TAG_HCTX_SHARED`, `BLK_MQ_F_BLOCKING`, `BLK_MQ_F_NO_SCHED_BY_DEFAULT` 등)와 `map[HCTX_MAX_TYPES]`.
- `struct blk_mq_tags`: `nr_tags`, `nr_reserved_tags`, `active_queues`, `struct sbitmap_queue bitmap_tags`/`breserved_tags`, 태그 번호로 request를 찾는 `rqs[]`, 미리 할당된 `static_rqs[]`.

### 4.2 제출 콜패스 (6.x~master `block/blk-mq.c`)
```
submit_bio() → submit_bio_noacct() → (blk_throtl_bio 등) → __submit_bio()
  └─ blk_mq_submit_bio(bio)
       ├─ rq = blk_mq_get_cached_request(plug, q, opf)    /* plug->cached_rqs 재사용 */
       ├─ bio_queue_enter()                              /* 캐시 rq 없을 때만 q_usage_counter */
       ├─ __bio_split_to_limits()                        /* queue_limits 기준 분할 */
       ├─ blk_mq_attempt_bio_merge()
       │     ├─ blk_attempt_plug_merge()                 /* 현재 task plug 리스트 */
       │     └─ blk_mq_sched_bio_merge()                 /* elevator ->bio_merge 또는 ctx 리스트 */
       ├─ blk_mq_get_new_requests()  (캐시 미스)
       │     ├─ rq_qos_throttle()                        /* wbt / iolatency / iocost */
       │     └─ __blk_mq_alloc_requests()
       │           ├─ data->ctx  = blk_mq_get_ctx(q)
       │           ├─ data->hctx = blk_mq_map_queue(opf, ctx)
       │           ├─ blk_mq_limit_depth()               /* elevator ->limit_depth */
       │           ├─ __blk_mq_alloc_requests_batch()    /* nr_tags > 1 (plug) */
       │           └─ blk_mq_get_tag()                   /* sbitmap_queue, 실패 시 대기 */
       ├─ blk_mq_bio_to_request()
       ├─ plug 있으면 blk_add_rq_to_plug() 후 return
       └─ plug 없으면
             ├─ RQF_USE_SCHED 또는 dispatch_busy → blk_mq_insert_request() + blk_mq_run_hw_queue(async)
             └─ 그 외 → blk_mq_try_issue_directly() → ->queue_rq()
```
`blk_mq_get_ctx()`는 `block/blk-mq.h`의 static inline이다. `blk_mq_submit_bio()`가 직접 부르지 않고 `__blk_mq_alloc_requests()` 안에서 호출된다. 6.x에서 캐시 미스 시 할당 경로는 `blk_mq_get_new_requests()` → `__blk_mq_alloc_requests()`이다.

### 4.3 태그와 공유 태그
`blk_mq_get_tag()`는 `sbitmap_queue`에서 비트 하나를 얻는다. `struct sbitmap_word`는 `word`와 `cleared`를 서로 다른 캐시라인에 두고 `swap_lock`(raw spinlock)으로 지연 해제(deferred clear)를 합친다. per-CPU `alloc_hint`는 CPU마다 다른 워드에서 검색을 시작하게 해서 같은 워드를 두고 경합할 확률을 낮춘다. 해제 쪽은 `wake_batch` 단위로 대기자를 깨워 thundering herd를 줄인다.

여러 `request_queue`가 하나의 `tag_set`을 공유하면(SCSI 호스트의 여러 LUN, NVMe 네임스페이스 등) `BLK_MQ_F_TAG_QUEUE_SHARED`가 켜진다. 이때 `hctx_may_queue()`는 활성 큐 수 `users = tags->active_queues`로 깊이를 균등 분할한다. 각 큐는 `max((depth + users - 1) / users, 4)`개까지만 쓸 수 있다. 5.10에서 들어온 `BLK_MQ_F_TAG_HCTX_SHARED`는 hisi_sas, megaraid_sas처럼 "여러 hw 큐가 호스트 전체 태그 하나를 공유"하는 HBA를 위한 것이다. 이 경우 hctx별이 아니라 큐 전체 카운터 `nr_active_requests_shared_tags`로 세고 `QUEUE_FLAG_HCTX_ACTIVE`로 활성 여부를 판단한다 (v5.9 `blk-mq.h`에는 없고 v5.10에 있음). 이 경우 `tag_set->shared_tags` 하나를 모든 hctx가 쓴다.

I/O 스케줄러가 붙으면 요청은 먼저 `hctx->sched_tags`(또는 공유 시 `q->sched_shared_tags`)에서 `internal_tag`를 받는다. 드라이버 태그 `rq->tag`는 디스패치 직전에 할당된다. 그래서 `rq->tag`는 hctx마다 재사용되는 번호이고, 스케줄러가 있는 큐에서는 큐잉 동안 -1일 수 있다.

### 4.4 기능 도입 연표 (git.kernel.org 태그별 grep으로 확인)

| 버전 | 변화 | 확인 근거 |
|---|---|---|
| 3.13 | blk-mq, `null_blk` 병합. 태그는 `percpu_ida` | v3.12 `block/blk-mq.c` 없음, v3.13 1510줄 |
| 3.16 | 자체 비트맵 태그(`blk_mq_bitmap_tags`) | v3.16 `blk-mq-tag.c` |
| 3.17 | `scsi-mq` (`scsi_mq_ops`) | v3.17 `drivers/scsi/scsi_lib.c` |
| 3.19 | NVMe 드라이버 blk-mq 전환 | v3.19 `nvme-core.c` |
| 4.4 | 폴링 `blk_poll()` / `REQ_HIPRI` | v4.4 `block/blk-core.c` |
| 4.9 | `lib/sbitmap.c` (`sbitmap_queue`) | v4.9 |
| 4.10 | hybrid polling(`blk_mq_poll_hybrid`), `blk-wbt` | v4.10 |
| 4.11 / 4.12 | `mq-deadline` / `kyber`, `bfq` | 파일 존재 여부 |
| 4.19 | `CONFIG_SCSI_MQ_DEFAULT` `default y`, `blk-iolatency` | v4.19 |
| 5.0 | 레거시 `request_fn`·CFQ 삭제, `HCTX_TYPE_*` 다중 맵 | v5.0 `blkdev.h`, `blk-mq.h` |
| 5.4 | `blk-iocost` | v5.4 |
| 5.10 | `BLK_MQ_F_TAG_HCTX_SHARED` | v5.10 `blk-mq.h` |
| 5.16 | `bio_poll()`/`REQ_POLLED`, plug 캐시 요청(`cached_rq`) | v5.16 `blk-core.c` |
| 5.17 | `->queue_rqs()` 배치 제출 | v5.17 `blk-mq.c` |
| 6.4 | hybrid polling 삭제 (커밋 54bdd67d0f88) | v6.3 있음, v6.4 없음 |
| 6.13 | io_uring `IORING_SETUP_HYBRID_IOPOLL` | v6.13 uapi |
| 6.14 | `blk_mq_map_hw_queues()` | v6.14 `blk-mq-cpumap.c` |

### 4.5 Legacy Single-Queue vs blk-mq 비교

| 항목 | Legacy (`request_fn`, ~4.20) | blk-mq (3.13~, 5.0부터 유일) |
|---|---|---|
| 큐 구조 | 디바이스당 `request_queue` 1개, 엘리베이터 1개 | per-CPU `blk_mq_ctx` + `blk_mq_hw_ctx` N개, `HCTX_TYPE_DEFAULT/READ/POLL` 맵 |
| 핫패스 락 | `*queue_lock` 하나가 할당·병합·디스패치·완료 모두 보호 | 대부분 per-CPU `ctx->lock`, per-hctx `hctx->lock`(dispatch 리스트), 스케줄러 사용 시 스케줄러 자체 락(`dd->lock`, `bfqd->lock`) |
| 태그 | 드라이버마다 따로(SCSI `blk_queue_tags` 등) | `blk_mq_tags` + `sbitmap_queue`, 공유 태그 시 `hctx_may_queue()` 공정 분할 |
| 드라이버 인터페이스 | `request_fn(q)`가 락을 잡은 채 큐에서 꺼냄 | `->queue_rq(hctx, bd)`, `->queue_rqs(rq_list)`, `->commit_rqs()`, `->poll()` |
| 병합 | 큐 전역 해시/rbtree | plug 리스트 → 스케줄러 `->bio_merge` 또는 ctx 리스트 |
| 완료 | softirq(`BLOCK_SOFTIRQ`), 제출 CPU 고려 제한적 | IRQ affinity 매핑 + 제출 CPU로 IPI 완료(`QUEUE_FLAG_SAME_COMP` 계열), 폴링 큐 |
| 스케줄러 | CFQ/deadline/noop (`elevator_ops`) | none/mq-deadline/kyber/bfq (`elevator_mq_ops`) |

트레이드오프도 있다. blk-mq는 hctx마다 `static_rqs`를 미리 할당하기 때문에 큐 수 × 깊이 × `cmd_size`만큼 메모리를 쓴다. 공유 태그 장치에서는 활성 큐 수가 늘수록 큐당 깊이가 줄어든다. 단일 큐 HDD에서는 스케줄러 락 하나로 다시 직렬화되므로 레거시 대비 확장성 이득이 거의 없다.

---

## 5. Primary References

- [Linux block IO: introducing multi-queue SSD access on multi-core systems (Bjørling, Axboe, Nellans, Bonnet, SYSTOR '13)](https://dl.acm.org/doi/10.1145/2485732.2485740) — blk-mq 설계 논문 (SYSTOR '13, FAST가 아님).
- [The multiqueue block layer (LWN, 2013-06-05)](https://lwn.net/Articles/552904/) — blk-mq 병합 직전의 설계 개요 기사
- [Block layer introduction part 2: the request layer (LWN)](https://lwn.net/Articles/738449/) — request 계층과 blk-mq 구조 해설
- [Multi-Queue Block IO Queueing Mechanism (blk-mq) — The Linux Kernel documentation](https://www.kernel.org/doc/html/latest/block/blk-mq.html) — 커널 공식 blk-mq 문서
- [block/blk-mq.c (torvalds/linux, git.kernel.org)](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/block/blk-mq.c) — 4.2절 콜패스 원본
- [include/linux/sbitmap.h (torvalds/linux, git.kernel.org)](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/include/linux/sbitmap.h) — `sbitmap_word`/`sbitmap_queue` 정의
- [blk-mq: abstract tag allocation out into sbitmap library (commit 88459642cba4)](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=88459642cba452630326b9cab1c651e09577d4e4) — Linux 4.9, Omar Sandoval의 sbitmap 분리 커밋
- [block: add mq_ops->queue_rqs hook (commit 3c67d44de787)](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=3c67d44de787dff288d7f2a51c372b22f7356db6) — Linux 5.17 배치 제출 훅
- [Improving Block-level Efficiency with scsi-mq (Caldwell, arXiv 1504.07481)](https://arxiv.org/abs/1504.07481) — Linux 3.18 scsi-mq 성능 평가
