# Linux 5.0 레거시 블록 계층 삭제와 bio→request 경로의 배치화·폴링

> 소스 기준: 2026-10 시점 메인라인 master(7.3 개발 주기)와 git.kernel.org 버전 태그(`?h=vX.Y`) grep. "6.16+" 표기는 함수 이름이 바뀐 시점을 뜻한다.

## 1. Verdict

Linux 5.0(2019-03)은 3.13부터 이어진 레거시 `request_fn` 경로와 레거시 I/O 스케줄러(`cfq-iosched.c`, `deadline-iosched.c`, `noop-iosched.c`), 레거시 태그(`block/blk-tag.c`)를 모두 지웠다. 세 파일은 v4.20에는 있고 v5.0에는 없다. 그 뒤로 request 기반 드라이버는 `struct blk_mq_ops`만 구현한다. 이 정리는 Jens Axboe가 2018년 10월 드라이버 변환 시리즈(LWN "Convert drivers to blk-mq")를 올리며 주도했고, SCSI 쪽 `scsi-mq` 기반 작업은 Christoph Hellwig가 앞서 진행했다. 대표 커밋은 "block: remove legacy rq tagging"(7ca01926463a)과 "block: kill legacy parts of timeout handling"(4316b79e4321)이다.

레거시 삭제가 남긴 것은 단일 경로만이 아니다. 이후 5.x~6.x 블록 계층 최적화는 모두 "bio 하나 → request 하나"의 고정 비용을 배치로 나누는 방향으로 진행되었다.

- **`struct blk_plug`**(task 로컬 배치, 2.6.39부터 존재). 5.16부터는 `cached_rqs`로 request와 tag를 미리 묶음 할당한다.
- **`->commit_rqs()`**(5.0): 배치 끝에 doorbell을 한 번만 울린다.
- **`->queue_rqs()`**(5.17): plug에 쌓인 request 리스트를 드라이버에 통째로 넘긴다(NVMe `nvme_queue_rqs()`).
- **폴링**: 4.4 `blk_poll()`/`REQ_HIPRI`, 4.10 hybrid polling, 5.16 bio 기반 `bio_poll()`/`REQ_POLLED`, 6.4 블록 계층 hybrid polling 삭제, 6.13 io_uring `IORING_SETUP_HYBRID_IOPOLL`.

`REQ_POLLED`가 5.0에서 정착했다는 설명이 흔하지만 시대가 맞지 않는다. `REQ_POLLED`는 Linux 5.16에 처음 생겼고, 5.0 당시 폴링 플래그는 `REQ_HIPRI`였다. 폴링이 없애는 것은 완료 인터럽트와 그에 따른 wakeup이지, 제출 syscall이나 스케줄링 비용 전부가 아니다.

---

## 2. Problem Statement

### 2.1 두 경로의 공존 비용 (3.13~4.20)
공존 기간에는 블록 코어 곳곳에 `q->mq_ops` 분기가 있었다. 타임아웃 처리, 태그, flush 시퀀싱, 스케줄러, cgroup, 전원 관리가 레거시와 blk-mq 두 벌로 유지되었다. 레거시 경로는 `*queue_lock` 포인터를 드라이버 락과 공유할 수 있었기 때문에 락 순서 문제도 경로마다 달랐다. 새 기능(blk-mq 스케줄러, `rq_qos`, 폴링)은 blk-mq에만 들어갔고, 레거시 사용자는 그 혜택을 받지 못했다. 레거시 삭제의 직접 동기는 "두 벌 유지 비용"과 "새 기능을 쓰려면 blk-mq여야 한다"는 사실이었다. 삭제 규모(줄 수, 참여 인원)는 이 문서에서 집계하지 않았다 `[추측/미확인]`.

### 2.2 bio와 request의 역할 차이
- `struct bio`: 상위 계층(파일시스템, direct I/O, dm/md)이 만드는 I/O 단위. `bi_bdev`, `bi_opf`, `bi_iter`, `bio_vec` 배열, 완료 콜백 `bi_end_io`, 폴링 쿠키 `bi_cookie`를 가진다.
- `struct request`: 드라이버에 넘기는 단위. 태그(`tag`, `internal_tag`), `mq_ctx`/`mq_hctx`, 병합된 bio 체인(`bio`…`biotail`), `rq_flags`(`RQF_USE_SCHED`, `RQF_SCHED_TAGS` 등), 드라이버 PDU(`cmd_size`만큼 뒤에 붙음)를 가진다.

request는 hctx마다 미리 할당된 `static_rqs[]`에서 꺼내 쓰기 때문에 할당은 곧 "태그 획득"이다. 따라서 bio당 비용의 대부분은 다음 항목이다.
(1) `bio_queue_enter()`의 percpu ref
(2) 태그 sbitmap 연산
(3) request 초기화(`blk_mq_rq_ctx_init`)
(4) 드라이버 제출과 doorbell MMIO
(5) 완료 인터럽트와 wakeup

plug 캐시, `queue_rqs`, 폴링은 각각 (1)~(3), (4), (5)를 겨냥한다.

### 2.3 인터럽트 완료의 비용
µs 단위 지연을 내는 장치에서는 완료 IRQ → softirq/IPI → wakeup → 컨텍스트 스위치 비용이 장치 지연과 같은 크기가 된다. LWN "Block-layer I/O polling"(2015)은 4.4에 들어간 폴링을 이 문제에 대한 대응으로 소개한다. 인터럽트 경로가 차지하는 CPU 비율이나 폴링의 지연 단축 폭 같은 수치는 장치와 측정 조건에 따라 크게 달라서, 1차 출처를 확인하지 못한 값은 쓰지 않는다 `[추측/미확인]`.

---

## 3. The Debate

레거시 삭제 당시 메인테이너 발언은 원문 링크를 확보하지 못해 인용 블록으로 쓰지 않는다. 아래는 확인 가능한 범위의 쟁점이다.

### 3.1 레거시 삭제 시점 논쟁
레거시 삭제 전 마지막 쟁점은 두 가지였다. 하나는 blk-mq로 가면 기본 스케줄러를 무엇으로 할지(LWN "I/O scheduling for single-queue devices", 2018), 다른 하나는 아직 변환되지 않은 드라이버를 어떻게 처리할지였다. request 기반 dm(dm-multipath)은 4.1에서 blk-mq 경로를 얻었다(LWN "dm: add full blk-mq support to request-based DM"). SCSI는 4.19에서 `CONFIG_SCSI_MQ_DEFAULT`를 `default y`로 바꾼 뒤 5.0에서 레거시 경로를 아예 없앴다. dm 메인테이너 Mike Snitzer나 SCSI 메인테이너 Martin K. Petersen이 레거시 삭제에 깊은 우려를 표명했다는 서술은 해당 발언을 찾지 못했다 `[추측/미확인]`. 단일 큐 HBA에서 blk-mq가 이득이 없다거나 회전 디스크 성능이 회귀한다는 우려는 당시 반복적으로 제기된 일반적 쟁점이었다. 이에 대한 기술적 답은 단일 hw 큐 장치의 `mq-deadline` 기본값(→ 02/02)과 공유 태그 지원이었다.

### 3.2 plug: 누가 병합하고 언제 내려보내나
`struct blk_plug`는 2.6.39에서 on-stack plugging으로 도입되었다(v2.6.38에 `blk_start_plug` 없음, v2.6.39에 있음). blk-mq 이전부터 있던 장치다. blk-mq에서 plug의 의미는 두 가지다.

1. **병합 지점**: `blk_attempt_plug_merge()`가 현재 task의 plug 리스트에서 병합을 시도한다. 리스트는 task 로컬이므로 다른 CPU와 공유하지 않는다. 그렇다고 병합 전체가 락리스인 것은 아니다. plug에서 병합하지 못하면 `blk_mq_sched_bio_merge()`가 스케줄러 락이나 `ctx->lock` 아래에서 다시 시도한다.
2. **배치 지점**: request는 `blk_add_rq_to_plug()`로 `plug->mq_list`(`struct rq_list`, 단방향 `rq_next` 체인)에 붙는다. 다음 조건에서 `blk_mq_flush_plug_list()`로 내려간다.
   - `rq_count`가 `BLK_MAX_REQUEST_COUNT`(32, 여러 큐에 걸친 plug는 2배)에 도달했을 때
   - 마지막 요청이 `BLK_PLUG_FLUSH_SIZE`(128KiB) 이상일 때
   - `blk_finish_plug()`가 불릴 때
   - task가 슬립해 `schedule()` 경로에서 `blk_flush_plug(…, true)`가 불릴 때

두 가지를 혼동하기 쉽다. plug에 request를 추가하는 것은 `blk_add_rq_to_plug()`이고, `blk_mq_plug_issue_direct()`는 flush 시점의 직접 발행 헬퍼였다(5.16~6.15). 6.16부터는 `blk_mq_issue_direct()`로 이름이 바뀌었다. 또 `commit_rqs`는 "원샷 일괄 전송"이 아니라 배치 중간에 `BLK_STS_RESOURCE` 등으로 멈췄을 때 이미 큐에 넣은 명령의 doorbell을 울리게 하는 훅이다(5.0). 리스트를 통째로 넘기는 것은 `->queue_rqs()`(5.17)다.

### 3.3 폴링: 허용할 것인가, 어떻게 제한할 것인가
4.4의 첫 구현(LWN "Block-layer I/O polling")은 `REQ_HIPRI`가 붙은 동기 direct I/O에서 `submit_bio()`가 돌려준 `blk_qc_t` 쿠키(hw 큐 번호 + 태그)로 `blk_poll()`을 반복 호출하는 방식이었다. CPU를 100% 태운다는 비판에 대한 답이 4.10의 hybrid polling이다. 이전 완료 시간 통계(`blk_stat`, 4.10 "block: add scalable completion tracking of requests" cf43e6be865a)를 바탕으로 예상 완료 시간의 절반만큼 잠든 뒤 폴링한다(`io_poll_delay` sysfs).

이후 구조는 두 번 크게 바뀌었다.
- **5.0**: `HCTX_TYPE_POLL` 전용 hw 큐가 생겼다. 폴링 큐는 인터럽트 벡터가 없으며(NVMe `poll_queues` 모듈 파라미터), 폴링 I/O와 인터럽트 I/O가 같은 CQ를 다투지 않게 되었다.
- **5.16**: Christoph Hellwig의 "block: switch polling to be bio based"(3e08773c3841)로 쿠키가 `submit_bio()` 반환값에서 `bio->bi_cookie`로 옮겨 갔다(`submit_bio`의 반환형이 v5.15 `blk_qc_t`에서 v5.16 `void`로 바뀜). 플래그는 `REQ_HIPRI`에서 `REQ_POLLED`로 바뀌었고, 진입점은 `bio_poll()`이 되었다. 이 변경으로 bio 기반 스택 드라이버(NVMe multipath, dm)도 `->poll_bio`로 폴링을 지원할 수 있게 되었다.

"폴링 쿠키는 `submit_bio()`가 반환한다"는 설명은 4.4~5.15에만 해당한다. 6.x에서는 `blk_mq_start_request()`가 `rq->bio->bi_cookie`에 `hctx->queue_num`을 기록한다. hybrid polling은 6.4에서 블록 계층에서 삭제되었고(54bdd67d0f88 "blk-mq: remove hybrid polling", 작성자 Keith Busch, v6.3에 `blk_mq_poll_hybrid` 있음, v6.4에 없음), `io_poll_delay`는 -1(classic) 고정으로 deprecated되었다. 그 아이디어는 6.13에서 io_uring 쪽 `IORING_SETUP_HYBRID_IOPOLL`(`io_uring_hybrid_poll()`, 지금까지의 최소 실행 시간의 절반을 잠듦)로 옮겨 갔다.

---

## 4. Implementation Impact

### 4.1 plug 배치 경로 (6.16+ master `block/blk-mq.c`)
```
blk_start_plug(&plug)  /  blk_start_plug_nr_ios(&plug, nr)   /* io_uring 등이 nr_ios 힌트 제공 */
  current->plug = &plug;  plug->nr_ios = min(nr, BLK_MAX_REQUEST_COUNT)

submit_bio() … blk_mq_submit_bio(bio)
  ├─ rq = blk_mq_get_cached_request(plug, q, opf)   /* plug->cached_rqs 맨 앞, 같은 q·호환 hctx type */
  ├─ (miss) blk_mq_get_new_requests()
  │     └─ data.nr_tags = plug->nr_ios; data.cached_rqs = &plug->cached_rqs
  │        __blk_mq_alloc_requests() → __blk_mq_alloc_requests_batch()
  │            /* 태그 여러 개를 한 번에 얻어 나머지 rq는 cached_rqs에 저장 */
  └─ blk_add_rq_to_plug(plug, rq)
        ├─ rq_count ≥ blk_plug_max_rq_count() 또는 last ≥ BLK_PLUG_FLUSH_SIZE → 먼저 flush
        ├─ 다른 q가 섞이면 plug->multiple_queues = true
        ├─ RQF_SCHED_TAGS면 plug->has_elevator = true
        └─ rq_list_add_tail(&plug->mq_list, rq)

blk_finish_plug() → __blk_flush_plug() → blk_mq_flush_plug_list(plug, from_schedule)
  ├─ !has_elevator && !from_schedule
  │     ├─ multiple_queues → blk_mq_dispatch_multiple_queue_requests()  /* q별로 분리 */
  │     └─ blk_mq_dispatch_queue_requests()
  │           ├─ q->mq_ops->queue_rqs 있으면 → __blk_mq_flush_list() → ->queue_rqs(rqs)
  │           └─ 남은 rq → blk_mq_issue_direct()  /* rq별 ->queue_rq, hctx 바뀔 때 commit_rqs */
  └─ 그 외 (elevator, schedule()에서 호출, 잔여) → blk_mq_dispatch_list()
        ├─ passthrough → hctx->dispatch
        ├─ elevator → ops.insert_requests() + blk_mq_run_hw_queue()
        └─ none → blk_mq_insert_requests(hctx, ctx, list)
```
`blk_mq_flush_plug_list()`는 진입하자마자 `plug->rq_count = 0`으로 만든다. 드라이버 `queue_rq()` 안에서 `schedule()`이 일어나 재귀 flush가 생겨도 리스트가 흔들리지 않게 하려는 것이다(소스 주석). 사용하지 않고 남은 `cached_rqs`는 `blk_finish_plug()` 때 반환된다.

### 4.2 `->queue_rqs()`와 NVMe
NVMe PCI 드라이버는 `.queue_rq`, `.queue_rqs = nvme_queue_rqs`, `.commit_rqs = nvme_commit_rqs`, `.poll = nvme_poll`을 등록한다. `nvme_queue_rqs()`는 같은 hctx에 속한 request 묶음의 SQE를 모두 쓴 뒤 SQ tail doorbell을 한 번만 쓴다. 요청 수가 많은 배치에서 MMIO와 `sq_lock` 획득 횟수가 줄어드는 것이 이점이다. `queue_rqs`는 `has_elevator`가 false일 때만 쓰인다. 스케줄러가 붙은 큐에서는 이 최적화가 꺼진다.

### 4.3 폴링 경로 (5.16+)
```
io_uring IORING_SETUP_IOPOLL (또는 preadv2 RWF_HIPRI)
  → kiocb에 IOCB_HIPRI → bio->bi_opf |= REQ_POLLED
  → blk_mq_submit_bio: REQ_POLLED인데 !blk_mq_can_poll(q)면 BLK_STS_NOTSUPP
  → blk_mq_map_queue(): REQ_POLLED → HCTX_TYPE_POLL hctx (IRQ 없음)
  → blk_mq_start_request(): bio->bi_cookie = hctx->queue_num
완료 수확:
  io_uring io_do_iopoll() → iocb_bio_iopoll() → bio_poll(bio, iob, flags)
      ├─ blk_flush_plug(current->plug, false)
      ├─ blk-mq: blk_mq_poll(q, cookie) → blk_hctx_poll() → q->mq_ops->poll(hctx, iob)
      └─ bio 기반: disk->fops->poll_bio()        /* BLK_FEAT_POLL */
  struct io_comp_batch(5.16)로 완료 배치 → 한 번에 end_request
  (6.13+) IORING_SETUP_HYBRID_IOPOLL: io_uring_hybrid_poll()이 먼저 잠들고 폴링
```
IOPOLL만 쓰면 완료를 수확하기 위해 `io_uring_enter(IORING_ENTER_GETEVENTS)`가 필요하다. syscall까지 없애려면 SQPOLL 스레드가 대신 폴링해야 한다.

### 4.4 버전별 변화 요약

| 버전 | 변화 | 근거(태그 grep / 커밋) |
|---|---|---|
| 2.6.39 | `struct blk_plug`, `blk_start_plug()` | v2.6.39 `blk-core.c` |
| 4.4 | `blk_qc_t submit_bio()`, `blk_poll()`, `REQ_HIPRI` | v4.4 |
| 4.10 | `blk_stat` 완료 추적(cf43e6be865a, Jens Axboe), hybrid polling | v4.10 |
| 5.0 | 레거시 경로·`blk-tag.c`·cfq/deadline/noop 삭제, `->commit_rqs`, `HCTX_TYPE_POLL` | v4.20↔v5.0 |
| 5.16 | `bio_poll`/`REQ_POLLED`/`bi_cookie`(3e08773c3841, Christoph Hellwig), `submit_bio()` void, `io_comp_batch`, plug `cached_rq` | v5.15↔v5.16 |
| 5.17 | `->queue_rqs()`(3c67d44de787, Jens Axboe) | v5.17 |
| 6.4 | 블록 계층 hybrid polling 삭제(54bdd67d0f88, Keith Busch) | v6.3↔v6.4 |
| 6.13 | `IORING_SETUP_HYBRID_IOPOLL` | v6.13 uapi |
| 6.16 | `blk_mq_plug_issue_direct()` → `blk_mq_issue_direct()` 재편 | v6.15↔v6.16 |

### 4.5 레거시(4.20) vs blk-mq(6.x) 데이터패스 비교

| 항목 | 레거시 `request_fn` (~4.20) | blk-mq 6.x |
|---|---|---|
| 드라이버 인터페이스 | `request_fn(q)`, `queue_lock` 보유 상태에서 `blk_fetch_request()` | `->queue_rq(hctx, bd)`(`bd->last`로 doorbell 지연), `->commit_rqs()`, `->queue_rqs(rq_list)`, `->poll()` |
| 요청 할당 | mempool 기반 `get_request()`, 큐 락 아래 | 태그 = 미리 할당된 `static_rqs[tag]`, plug 시 `__blk_mq_alloc_requests_batch()`로 묶음 할당 후 `cached_rqs` 재사용 |
| 병합 | 큐 락 아래 엘리베이터 해시/rbtree | plug 리스트(task 로컬) → 스케줄러 `bio_merge` 또는 `ctx->lock` 아래 ctx 리스트 |
| 배치 제출 | 없음. 드라이버가 루프에서 하나씩 꺼냄 | plug flush → `->queue_rqs()` 한 번 + doorbell 1회(NVMe `nvme_submit_cmds()`) |
| 완료 | IRQ → `BLOCK_SOFTIRQ` | IRQ(affinity 매핑, 필요 시 제출 CPU로 IPI) 또는 `HCTX_TYPE_POLL` 폴링 + `io_comp_batch` 배치 완료 |
| 폴링 쿠키 | (4.4~5.15 blk-mq) `submit_bio()` 반환 `blk_qc_t` | `bio->bi_cookie` = `hctx->queue_num`, `bio_poll()` |
| 남은 직렬화 지점 | `queue_lock` 전부 | 스케줄러 락(`dd->lock`/`bfqd->lock`), `hctx->lock`(dispatch 리스트), NVMe `sq_lock`(SQ 단위) |

### 4.6 한계와 트레이드오프
- plug 배치는 같은 task가 연속으로 제출할 때만 효과가 있다. 스레드마다 I/O 하나씩만 내는 부하에서는 이득이 작다.
- `queue_rqs`는 스케줄러가 없는 큐에서만 쓰인다. `BLK_STS_RESOURCE`가 나면 남은 request는 `hctx->dispatch`로 되돌아가 일반 경로를 탄다.
- 폴링 큐는 IRQ가 없으므로 폴링하는 주체(io_uring IOPOLL 루프나 SQPOLL)가 없으면 완료가 수확되지 않는다. 폴링 큐 수(`poll_queues`)만큼 인터럽트 큐가 줄어든다. 6.4 이후 블록 계층의 폴링은 항상 classic(바쁜 대기)이다.
- `bio_poll()`은 `percpu_ref_tryget(&q->q_usage_counter)`로 큐 생존을 확인한다. 큐가 freeze되는 동안(스케줄러 전환, nr_hw_queues 변경)에는 폴링이 0을 반환하고 재시도된다.

---

## 5. Primary References

- [Convert drivers to blk-mq (LWN, 2018)](https://lwn.net/Articles/768263/) — 레거시 삭제 직전 드라이버 변환 시리즈
- [I/O scheduling for single-queue devices (LWN)](https://lwn.net/Articles/767987/) — 단일 큐 장치의 기본 스케줄러 논의
- [dm: add full blk-mq support to request-based DM (LWN)](https://lwn.net/Articles/636461/) — request 기반 dm의 blk-mq 지원(Linux 4.1)
- [Block-layer I/O polling (LWN)](https://lwn.net/Articles/663879/) — Linux 4.4 블록 계층 폴링 소개
- [block: switch polling to be bio based (commit 3e08773c3841)](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=3e08773c3841e9db7a520908cc2b136a77d275ff) — Linux 5.16, 쿠키를 `bi_cookie`로 옮긴 커밋
- [blk-mq: remove hybrid polling (commit 54bdd67d0f88)](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=54bdd67d0f88489ac88f7664b56cb7c93799d84d) — Linux 6.4, hybrid polling 삭제
- [block: add mq_ops->queue_rqs hook (commit 3c67d44de787)](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=3c67d44de787dff288d7f2a51c372b22f7356db6) — Linux 5.17 배치 제출 훅
- [block: remove legacy rq tagging (commit 7ca01926463a)](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=7ca01926463a15f5d2681458643b2453930b873a) — Linux 5.0 레거시 태그(`blk-tag.c`) 삭제
- [Multi-Queue Block IO Queueing Mechanism (blk-mq) — The Linux Kernel documentation](https://www.kernel.org/doc/html/latest/block/blk-mq.html) — 커널 공식 blk-mq 문서
