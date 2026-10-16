# blk-mq "스케줄러 불필요론"의 후퇴와 I/O 스케줄러·QoS 재도입

> 소스 기준: 2026-10 시점 메인라인 master(7.3 개발 주기)와 git.kernel.org 버전 태그(`?h=vX.Y`)를 grep해 확인했다. 기본값 상수는 master의 `block/mq-deadline.c`, `block/kyber-iosched.c`, `block/bfq-iosched.c`에서 가져왔다.

## 1. Verdict

blk-mq는 3.13(2014)에 I/O 스케줄러 없이 들어왔다. 빠른 장치에서는 소프트웨어 정렬보다 하드웨어 병렬성이 중요하다는 판단이었다. 이 전제는 두 방향에서 깨졌다.

1. **레거시 경로를 지우려면 대체재가 필요했다.** 회전 디스크와 단일 큐 SATA 장치는 정렬, 기아 방지, 공정성이 필요했다. CFQ/deadline에 상응하는 것이 blk-mq에 없으면 레거시 `request_fn`을 지울 수 없었다. BFQ는 레거시 API로 만들어져 있어서 병합이 막혀 있었다(LWN "A way forward for BFQ", 2016-12-14).
2. **빠른 장치에서도 혼합 부하의 꼬리 지연은 장치 큐 깊이로 결정된다.** 쓰기와 discard가 장치 큐를 채우면 뒤에 온 읽기는 장치 내부에서 기다린다. 이를 풀려면 장치에 들어가는 깊이 자체를 제한해야 한다.

이에 대한 커널의 답은 하나가 아니라 계층별로 나뉘었다.

- **4.11**: `blk-mq-sched` 프레임워크와 `struct elevator_mq_ops`, 첫 스케줄러 `mq-deadline`.
- **4.12**: Omar Sandoval의 `kyber`(빠른 다중 큐 장치용, 깊이 제한 기반)와 Paolo Valente의 `bfq`(느린 장치·데스크톱용, 프로세스 단위 공정성).
- **스케줄러 바깥의 QoS(`rq_qos`)**: `blk-wbt`(4.10), `blk-iolatency`(4.19), `blk-iocost`(5.4). 이것들은 스케줄러와 무관하게 `none`에서도 동작한다.

현재 기본 정책(`block/elevator.c`)은 hw 큐가 1개이거나 공유 태그(`blk_mq_is_shared_tags`)인 장치에는 `mq-deadline`을, 다중 큐 NVMe에는 `none`을 쓰는 것이다. 드라이버는 `BLK_MQ_F_NO_SCHED_BY_DEFAULT`로 기본 스케줄러를 끌 수 있다. 정리하면 "스케줄러 만능"도 "스케줄러 불필요"도 아니다. 장치 특성에 따라 선택하고, 멀티테넌트 격리는 cgroup 기반 QoS로 푸는 쪽으로 정착했다.

자주 혼동되는 점: `struct elevator_mq_ops`는 지금도 실제 이름이다. v4.11~v4.20에는 `struct elevator_type` 안에 `union { struct elevator_ops sq; struct elevator_mq_ops mq; } ops;`가 있었고, Linux 5.0에서 레거시 `elevator_ops`가 삭제되면서 `struct elevator_mq_ops ops;` 하나만 남았다(master `block/elevator.h`).

---

## 2. Problem Statement

### 2.1 장치 내부 큐의 Head-of-Line Blocking
NAND 매체에서 읽기는 수십 µs, 프로그램(쓰기)은 수백 µs, 블록 소거는 ms 단위가 일반적이다(셀 종류에 따라 다름). 장치 컨트롤러는 내부 버퍼와 FTL로 이를 숨기지만, 큐 깊이가 큰 비동기 쓰기 버스트가 들어오면 그 뒤에 제출된 동기 읽기는 장치 내부 자원(채널, 다이, 쓰기 버퍼 플러시)을 기다린다. 소프트웨어가 장치 큐에 넣는 순서를 아무리 잘 정해도, 이미 장치에 들어간 명령은 다시 정렬할 수 없다. 그래서 대책의 핵심은 순서 정렬보다 장치에 동시에 들어가는 쓰기 수를 제한하는 것이다. Kyber와 wbt의 설계가 모두 이 결론에서 출발했다.

`none`에서 plug가 없으면 `blk_mq_submit_bio()`는 `blk_mq_try_issue_directly()`로 곧바로 `->queue_rq()`를 부른다. 장치 태그가 남아 있는 한 쓰기는 제한 없이 장치로 들어간다. 이를 막을 수 있는 수단은 `rq_qos_throttle()` 훅(wbt 등)뿐이다.

### 2.2 페이지 캐시 writeback 버스트
버퍼드 쓰기는 `wb_workfn()`에서 대량의 비동기 쓰기 bio로 쏟아진다. 4.10 이전에는 이 background writeback이 포그라운드 읽기와 `fsync`의 지연을 크게 늘리는 문제가 반복 보고되었다. Jens Axboe의 writeback throttling 패치(LWN "Throttled background buffered writeback")는 읽기·쓰기의 최소 지연을 관찰하다가 임계치를 넘으면 background writeback의 in-flight 수를 줄이는 방식으로 이 문제에 대응했다. 이것이 4.10의 `blk-wbt`이고, 지금도 `wb_background`/`wb_normal` 한도와 sysfs `wbt_lat_usec`로 남아 있다.

### 2.3 레거시 스케줄러를 그대로 옮길 수 없는 이유
CFQ는 `queue_lock` 아래에서 프로세스별 큐(cfqq), 서비스 트리, idle 타이머를 다뤘다. 이 상태를 blk-mq로 옮기면 per-CPU 제출 경로가 다시 스케줄러 전역 락 하나로 모인다. 실제로 지금의 BFQ도 `bfqd->lock` 하나로 보호되고(`spin_lock_irq(&bfqd->lock)`), mq-deadline도 `dd->lock` 하나를 쓴다. 차이는 두 가지다. 이 직렬화가 스케줄러를 고른 큐에만 적용된다는 점, 그리고 Kyber처럼 per-ctx 큐(`kyber_ctx_queue`)와 `sbitmap_queue` 토큰으로 전역 락을 피하는 설계도 고를 수 있다는 점이다.

---

## 3. The Debate

메인테이너 발언은 원문(lore 메시지)을 확보하지 못했기 때문에 인용 블록을 쓰지 않는다. 아래는 LWN 보도와 코드 이력으로 확인한 쟁점이다.

### 3.1 "BFQ는 blk-mq로 와야 병합된다" (2016)
BFQ(Paolo Valente, Arianna Avanzini)는 2008년 무렵부터 레거시 API용 패치로 여러 차례 제출되었다(LWN "The BFQ I/O scheduler", "The return of the BFQ I/O scheduler"). 리뷰어들은 잘 검증된 CFQ를 BFQ로 대체하는 데 반대했다. 블록 계층 개발자들은 앞으로 사라질 레거시 API에 새 스케줄러를 넣지 말고 multiqueue API를 쓰라고 요구했다. 당시 blk-mq에는 스케줄링 지원 자체가 없었다(LWN "A way forward for BFQ", 2016-12-14). 결국 Jens Axboe가 4.11에서 `blk-mq-sched` 프레임워크를 먼저 넣었고, Valente가 BFQ를 이 위로 이식해 4.12에 병합되었다. 이 사례에서 확립된 원칙은 "새 기능은 blk-mq에만"이고, 이 원칙이 5.0의 레거시 삭제로 이어졌다.

### 3.2 공정성 대 오버헤드: BFQ와 Kyber의 역할 분담
LWN "Two new block I/O schedulers for 4.12"(2017-04-24)는 두 스케줄러를 다음과 같이 대비한다.

- **BFQ**: 연산당 오버헤드가 비교적 크다. I/O 자체가 느리고 비싼 장치에서는 이 비용이 정당화되지만, I/O가 싸고 처리량이 우선인 빠른 SSD에서는 의미가 적다.
- **Kyber**: Omar Sandoval 작성, 1,000줄 미만. 디스패치로 보내는 연산 수를 엄격히 제한해 장치 쪽 큐를 짧게 유지한다. 읽기 2ms, 쓰기 10ms 지연 목표를 두고 깊이를 조절한다.

BFQ의 복잡성에 대해 특정 메인테이너(예: Christoph Hellwig)가 강하게 반대했다는 서술이 돌아다니지만, 확인한 LWN 기사에는 그런 발언이 귀속되어 있지 않다 `[추측/미확인]`.

### 3.3 Kyber 설계의 진화 (코드로 확인)
- **4.12~4.19**: 도메인은 `KYBER_READ`/`KYBER_SYNC_WRITE`/`KYBER_OTHER` 셋이었고, 깊이는 256/128/64였다. 지연 목표는 `read_lat_nsec` 2ms, `write_lat_nsec` 10ms 두 개뿐이었다(v4.12 `kyber_queue_data_alloc()`).
- **4.20~**: 도메인이 `KYBER_READ`/`KYBER_WRITE`/`KYBER_DISCARD`/`KYBER_OTHER` 넷으로 재편되었다(v4.19에 `KYBER_DISCARD` 없음, v4.20에 있음). 지연 측정도 per-CPU 히스토그램(`KYBER_LATENCY_BUCKETS = 2 << KYBER_LATENCY_SHIFT`)으로 바뀌었다. 현재 기본값은 다음과 같다.
  - 깊이 `kyber_depth[]`: READ 256, WRITE 128, DISCARD 64, OTHER 16
  - 지연 목표 `kyber_latency_targets[]`: READ 2ms, WRITE 10ms, DISCARD 5s
  - 비동기 요청 태그 비율 `KYBER_DEFAULT_ASYNC_PERCENT = 75`

현재의 제어 루프(`kyber_timer_fn()`)는 흔히 요약되는 "읽기가 목표를 넘으면 쓰기를 줄인다"와 다르다.

1. 각 도메인의 **I/O latency**(장치 체류 시간) p90이 목표의 "good" 버킷을 넘으면 혼잡(`bad = true`)으로 판정한다.
2. 각 도메인의 **total latency** p99를 목표 대비 비율로 구해 `depth = orig_depth * (p99 + 1) >> KYBER_LATENCY_SHIFT`로 조정한다.
3. 혼잡하면 지연이 좋은 도메인을 줄이고, 지연이 나쁜 도메인은 오히려 늘린다.

다시 말해 "읽기를 위해 쓰기만 깎는" 단방향 규칙이 아니라, 장치가 혼잡할 때 목표를 여유 있게 지키고 있는 도메인의 몫을 덜어 내는 대칭 규칙이다.

### 3.4 단일 큐 장치의 기본 스케줄러 (2018)
레거시 삭제를 앞둔 2018년, SATA/eMMC 같은 단일 큐 장치를 blk-mq로 옮기면 CFQ에 상응하는 기본 스케줄러를 무엇으로 할지가 논의되었다(LWN "I/O scheduling for single-queue devices", 2018). 결론은 지금의 `elevator.c` 정책, 즉 단일 hw 큐면 `mq-deadline`이다. 데스크톱 배포판들이 udev 규칙으로 회전 디스크에 `bfq`를 쓰는 것은 커널 기본값이 아니라 배포판 정책이다 `[추측/미확인: 배포판별 기본값 미조사]`.

### 3.5 스케줄러 대신 cgroup QoS
Facebook(현 Meta)이 실제로 택한 경로는 스케줄러를 고도화하는 것보다 `rq_qos` 계층을 쓰는 쪽이었다. Josef Bacik의 `io.latency`(4.19, LWN "Introduce io.latency io controller for cgroups")와 Tejun Heo의 `io.cost`(5.4, LWN "IO cost model based work-conserving porportional controller")가 그 예다. 이들은 `none` 스케줄러와도 조합할 수 있다. 공정성을 스케줄러 정렬이 아니라 제출 시점의 스로틀과 지연(`use_delay`)으로 구현하므로 다중 큐 장치에서도 스케줄러 락이 생기지 않는다.

---

## 4. Implementation Impact

### 4.1 `struct elevator_mq_ops` (master `block/elevator.h`)
스케줄러는 `struct elevator_type`의 `ops`(`struct elevator_mq_ops`)에 콜백을 채운다. 역할별로 묶으면 다음과 같다.

- **생명주기**: `init_sched`/`exit_sched`, `init_hctx`/`exit_hctx`, `depth_updated`(`nr_requests` 변경 시), 최근 추가된 `alloc_sched_data`/`free_sched_data`
- **병합**: `allow_merge`, `bio_merge`, `request_merge`, `request_merged`, `requests_merged`, `former_request`/`next_request`
- **할당 단계 깊이 제한**: `limit_depth(blk_opf_t, struct blk_mq_alloc_data *)`. `data->shallow_depth`를 설정해 `sbitmap_queue`의 shallow 할당을 강제한다. Kyber와 mq-deadline은 동기 읽기가 아닌 요청에 `q->async_depth`를 적용한다.
- **큐잉/디스패치**: `prepare_request`, `insert_requests(hctx, list, flags)`, `dispatch_request(hctx)`, `has_work(hctx)`, `requeue_request`, `finish_request`
- **완료 피드백**: `completed_request(rq, now)`. Kyber는 여기서 지연 히스토그램을 갱신한다.
- **io_context**: `init_icq`/`exit_icq`. BFQ가 프로세스별 `bfq_io_cq`를 붙일 때 쓴다.

### 4.2 스케줄러가 있을 때의 콜패스
```
blk_mq_submit_bio()
  ├─ blk_mq_attempt_bio_merge() → blk_mq_sched_bio_merge() → e->type->ops.bio_merge()
  ├─ __blk_mq_alloc_requests()
  │     ├─ blk_mq_limit_depth()  → ops.limit_depth()        /* shallow_depth */
  │     ├─ RQF_SCHED_TAGS: hctx->sched_tags에서 internal_tag 할당
  │     └─ RQF_USE_SCHED 설정 (passthrough/flush/reserved 제외)
  ├─ plug 사용 시: blk_add_rq_to_plug() → plug->has_elevator = true
  │     └─ flush 때 blk_mq_dispatch_list() → ops.insert_requests()  /* queue_rqs 경로 불가 */
  └─ plug 없음: blk_mq_insert_request() → ops.insert_requests(); blk_mq_run_hw_queue(hctx, async)

blk_mq_run_hw_queue() → blk_mq_sched_dispatch_requests()
  └─ __blk_mq_sched_dispatch_requests()
        ├─ hctx->dispatch 잔여 요청 먼저 (hctx->lock)
        ├─ elevator: blk_mq_do_dispatch_sched() → ops.dispatch_request() 반복
        │     └─ blk_mq_dispatch_rq_list() → 드라이버 태그 획득 → ->queue_rq() / ->commit_rqs()
        └─ none: blk_mq_do_dispatch_ctx() 또는 ctx 리스트 일괄 flush
```
스케줄러 큐에 있는 동안 요청은 장치 태그를 잡지 않는다. 디스패치 시점에야 드라이버 태그(`rq->tag`)를 얻으므로 스케줄러는 "장치에 몇 개를 넣을지"를 스스로 통제할 수 있다. Kyber는 여기에 더해 도메인 토큰(`kyber_get_domain_token()`)을 얻어야만 디스패치하게 한다.

### 4.3 스케줄러별 내부 구조와 기본값

| 항목 | `mq-deadline` (4.11) | `kyber` (4.12, 4.20 개편) | `bfq` (4.12) |
|---|---|---|---|
| 핵심 자료구조 | `struct deadline_data` 안에 우선순위별 `struct dd_per_prio per_prio[DD_PRIO_COUNT]`(`DD_PRIO_COUNT = 3`, RT/BE/IDLE, 5.14~), 방향별 sort rbtree + FIFO | per-ctx `kyber_ctx_queue`(kcq), 도메인별 `sbitmap_queue domain_tokens[]`, per-CPU 지연 버킷 | 프로세스(`bfq_queue`)·cgroup(`bfq_group`) 계층, B-WF2Q+ 가상 시간 증강 rbtree |
| 락 | `dd->lock` 하나 | 큐 전역 스케줄러 락 없음. kcq별 `kcq->lock`, hctx별 `khd->lock`, 토큰은 sbitmap | `bfqd->lock` 하나 (`spin_lock_irq`) |
| 주요 기본값 | `read_expire = HZ/2`, `write_expire = 5*HZ`, `writes_starved = 2`, `fifo_batch = 16`, `prio_aging_expire = 10*HZ` | READ 2ms / WRITE 10ms / DISCARD 5s, 깊이 256/128/64/16, async 75% | `bfq_timeout = HZ/8`, `bfq_slice_idle = NSEC_PER_SEC/125`(8ms), `bfq_default_max_budget = 16*1024` **섹터**, `low_latency` 기본 on |
| 제어 원리 | 섹터 정렬 배치 + 만료 FIFO로 기아 방지, 쓰기 기아 카운터 | 지연 피드백으로 도메인 깊이 동적 조절 | 예산(섹터) 단위 공정 배분, idling, weight-raising |
| 적합 장치 | 단일 큐 SATA/SAS, 가상 디스크, 공유 태그 HBA | 빠른 다중 큐 SSD에서 읽기 지연 보호 | HDD, 저속 SSD/eMMC, 대화형 데스크톱, `io.bfq.weight` 비례 배분 |

표를 읽을 때 주의할 점:
- BFQ 예산 단위는 바이트가 아니라 섹터다(`bfq_default_max_budget` 주석 "in sectors").
- Kyber는 "토큰 버킷"이 아니라 `sbitmap_queue` 기반 토큰(동시 in-flight 상한)이다.
- mq-deadline의 500ms/5s는 SOFT 한도다(소스 주석 "these limits are SOFT!").

### 4.4 스케줄러 바깥의 QoS 계층

| 메커니즘 | 도입 | 훅 위치 | 제어 대상 | 인터페이스 |
|---|---|---|---|---|
| `blk-throttle` | 2.6.x (cgroup v1 blkio) | bio 단위, `submit_bio_noacct()` → `blk_throtl_bio()` | bps/iops 절대 상한 (비작업보존) | v2 `io.max`, v1 `blkio.throttle.*` |
| `blk-wbt` | 4.10 | `rq_qos` (`RQ_QOS_WBT`) | background/normal writeback in-flight 수 | `queue/wbt_lat_usec` |
| `blk-iolatency` | 4.19 | `rq_qos` (`RQ_QOS_LATENCY`) | 보호 cgroup의 지연 목표 위반 시 형제 cgroup 깊이 축소 + `use_delay` | `io.latency target=` |
| `blk-iocost` | 5.4 | `rq_qos` (`RQ_QOS_COST`) | 장치 비용 모델 기반 vtime·hweight 비례 배분 (작업보존) | `io.cost.qos`(rpct/rlat/wpct/wlat/min/max), `io.cost.model`, `io.weight` |

`rq_qos` 훅은 `blk_mq_get_new_requests()`의 `rq_qos_throttle()`(할당 전, 슬립 가능)과 `rq_qos_track()`, 완료 시 `rq_qos_done()`에서 불린다. 그래서 `none` 스케줄러에서도 같은 방식으로 동작한다. 반면 blk-throttle은 request 이전 bio 단계에서 작동한다. `blk-iocost`는 장치 virtual time(vtime)을 주 지표로 쓰고, cgroup의 vtime은 계층적 가중치(hweight)에 반비례하는 속도로 흐르게 해서 비례 배분을 구현한다(`block/blk-iocost.c` 헤더 주석).

### 4.5 운영상 트레이드오프
- **`none` + NVMe**: CPU 비용은 가장 낮다. plug가 있을 때는 `->queue_rqs()` 배치 경로를 쓸 수 있다(`plug->has_elevator`가 false일 때만). 반면 쓰기 버스트에 대한 보호는 wbt와 cgroup QoS에 전적으로 의존한다.
- **스케줄러를 붙이면 잃는 것**: plug flush가 `->queue_rqs()`를 쓰지 못하고 `insert_requests` → `run_hw_queue` 경로로 간다. sched 태그와 드라이버 태그를 이중으로 관리해야 하고, mq-deadline·BFQ에서는 단일 락 직렬화가 생긴다. 고IOPS NVMe에서 BFQ는 CPU 병목이 될 수 있다. LWN 기사의 정성적 평가이며, 이 문서는 수치를 제시하지 않는다.
- **mq-deadline의 I/O 우선순위**: Linux 5.14부터 `ioprio` 클래스(RT/BE/IDLE)별 큐를 갖는다. 낮은 우선순위의 기아를 막는 `prio_aging_expire`(10s)는 Linux 5.16에서 추가되었다(v5.15 `mq-deadline.c`에 없음, v5.16에 있음).
- **공유 태그 HBA**: hw 큐가 여러 개라도 `blk_mq_is_shared_tags()`이면 기본이 `mq-deadline`이다. 이때 스케줄러 태그도 `q->sched_shared_tags`로 공유된다.
- **런타임 전환**: `/sys/block/<dev>/queue/scheduler`에 쓰면 `elevator_change()`가 큐를 freeze/quiesce한 뒤 교체한다. 전환하는 동안 I/O가 멈추므로 운영 중 전환에는 주의가 필요하다.

---

## 5. Primary References

- [Two new block I/O schedulers for 4.12 (LWN, 2017-04-24)](https://lwn.net/Articles/720675/) — Kyber·BFQ 병합 시점의 비교 기사
- [A way forward for BFQ (LWN, 2016-12-14)](https://lwn.net/Articles/709202/) — BFQ가 blk-mq 이식을 조건으로 병합된 경위
- [The return of the BFQ I/O scheduler (LWN)](https://lwn.net/Articles/674308/) — 2016년 레거시 API용 BFQ 재제출
- [I/O scheduling for single-queue devices (LWN)](https://lwn.net/Articles/767987/) — 단일 큐 장치의 blk-mq 기본 스케줄러 논의
- [Throttled background buffered writeback (LWN)](https://lwn.net/Articles/698815/) — `blk-wbt` 패치 소개
- [Introduce io.latency io controller for cgroups (LWN)](https://lwn.net/Articles/758697/) — `blk-iolatency` 패치 소개
- [IO cost model based work-conserving porportional controller (LWN)](https://lwn.net/Articles/793460/) — `blk-iocost` 패치 소개
- [BFQ (Budget Fair Queueing) — The Linux Kernel documentation](https://www.kernel.org/doc/html/latest/block/bfq-iosched.html) — BFQ 공식 문서
- [Kyber I/O scheduler tunables — The Linux Kernel documentation](https://www.kernel.org/doc/html/latest/block/kyber-iosched.html) — Kyber 튜너블 문서
- [Control Group v2 — The Linux Kernel documentation](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html) — `io.max`, `io.latency`, `io.cost.*`, `io.weight` 인터페이스
- [block/elevator.h (torvalds/linux, git.kernel.org)](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/block/elevator.h) — `struct elevator_mq_ops` 정의
- [block/kyber-iosched.c (torvalds/linux, GitHub mirror)](https://github.com/torvalds/linux/blob/master/block/kyber-iosched.c) — Kyber 기본값과 `kyber_timer_fn()`
