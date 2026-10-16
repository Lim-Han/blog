# Ceph OSD → io_uring/libaio → blk-mq → NVMe 구간의 eBPF 상관관계 추적 설계

> 범위: 단일 호스트 안에서 사용자 공간 스토리지 데몬(예: Ceph OSD/BlueStore)의 I/O 하나를 커널 블록 계층과 NVMe 드라이버까지 연결하는 방법, 그리고 호스트 간 연결의 한계. 커널 이름은 Linux master(2026-10) 및 명시한 태그, Ceph 이름은 `ceph/ceph` main 브랜치 기준으로 소스에서 확인했다.

## 1. Verdict

"USDT → io_uring → blk-mq → NVMe → TCP를 하나의 Correlation ID로 꿰는 파이프라인이 확립되어 1% 미만 오버헤드로 운영된다"는 식의 설명은 실제 메커니즘과 맞지 않는 부분이 많다. 실제 메커니즘에서 출발한 결론은 다음과 같다.

1. **단일 ID는 존재하지 않는다.** 계층 경계마다 요청의 정체(identity)가 바뀐다. 사용자 공간 객체 포인터 → io_uring `user_data`/`struct io_kiocb *` → `struct bio *` → `struct request *` → NVMe `(qid, command_id)`. 상관관계는 경계마다 "조인 키"를 맵에 기록해 이어 붙이는 작업이다.
2. **블록 계층과 NVMe 계층의 공통 키는 `struct request *` 포인터다.** `block:block_rq_issue`, `block:block_rq_complete`, `nvme:nvme_setup_cmd`, `nvme:nvme_complete_rq`는 모두 `struct request *`를 인자로 받는다(BTF 기반 `tp_btf`로 접근). 포인터는 완료 후 재사용되므로 수명은 issue~complete 구간에 한정된다. `rq->tag` 단독은 hctx별 네임스페이스이며 I/O 스케줄러 사용 시 디스패치 전에는 `internal_tag`만 유효하므로 키로 쓰려면 `(dev, hctx 번호, tag)`를 묶어야 한다.
3. **상관관계 맵은 공유 맵이어야 한다.** 제출 CPU와 완료 CPU는 일반적으로 다르다(IRQ affinity, 폴링 큐, 원격 완료). `BPF_MAP_TYPE_PERCPU_HASH`에 시작 시각을 넣으면 완료 측 CPU에서 찾지 못한다. 시작 시각 저장은 `BPF_MAP_TYPE_HASH`(또는 누수 방지용 `LRU_HASH`), 결과 집계(히스토그램 카운터)만 per-CPU 맵을 쓴다.
4. **사용자 공간은 uprobe/USDT 영역이다.** `fentry`는 커널 함수 전용이다. Ceph에는 `ceph_rgw:op_start` 같은 USDT가 없으며, 소스 트리의 정적 계측은 `src/tracing/*.tp`의 **LTTng-UST** 트레이스포인트와 `src/common/tracer.h`의 **OpenTelemetry**(빌드 옵션 `WITH_JAEGER`) 스팬이다. LTTng-UST는 `--with-sdt`로 빌드된 경우에만 SDT 노트를 함께 내보내 USDT로 부착할 수 있고, 그렇지 않으면 C++ 심볼에 uprobe를 건다.
5. **호스트 간 시각 뺄셈은 기본적으로 불가능하다.** `bpf_ktime_get_ns()`는 각 호스트의 `CLOCK_MONOTONIC`이며 기준점이 다르다. 호스트 간 구간은 PTP로 동기화된 `CLOCK_TAI`(`bpf_ktime_get_tai_ns()`, 6.1) 위에서 동기화 오차를 명시하고 쓰거나, 송신 측 단일 호스트에서 관측 가능한 `srtt_us` 같은 지표로 대체한다.
6. **오버헤드는 주장하지 말고 측정한다.** `kernel.bpf_stats_enabled=1`로 프로그램별 `run_time_ns`/`run_cnt`를 얻고, ring buffer 예약 실패 횟수와 워크로드 A/B(fio IOPS·p99)를 함께 본다. "1% 미만"은 프로브 빈도·맵 연산·출력량에 따라 달라지는 결과이지 설계 상수가 아니다.

---

## 2. Problem Statement

### 2.1 하나의 BlueStore 쓰기가 지나가는 경로

Ceph OSD(BlueStore, 커널 블록 디바이스 백엔드) 쓰기를 예로 든다. 함수 이름은 Ceph main 브랜치에서 확인한 것이다.

1. 메신저가 메시지를 받아 `OSD::ms_fast_dispatch(Message *m)`로 넘긴다. 여기서 LTTng 트레이스포인트 `tracepoint(osd, ms_fast_dispatch, reqid.name._type, reqid.name._num, reqid.tid, reqid.inc)`가 발생하고, 메시지에 OpenTelemetry 컨텍스트(`m->otel_trace`)가 있으면 `"op-request-created"` 스팬이 추가된다.
2. PG 처리 후 BlueStore가 `BlueStore::_do_write()`로 데이터 배치를 결정하고 트랜잭션 상태 기계(`BlueStore::_txc_state_proc()`)를 진행한다. `src/tracing/bluestore.tp`에는 `transaction_state_duration`, `transaction_commit_latency`, `transaction_kv_submit_latency` 등이 정의되어 있다.
3. 블록 I/O는 `KernelDevice::aio_write()` → `KernelDevice::aio_submit(IOContext *ioc)`로 제출된다. 기본값(`bdev_ioring: false`)은 libaio `io_submit()`이고, `bdev_ioring=true`이면 `src/blk/kernel/io_uring.cc`가 `io_uring_prep_writev()` 후 `io_uring_sqe_set_data(sqe, io)`로 `struct aio_t *`를 `user_data`에 넣는다. 완료는 `KernelDevice::_aio_thread()`가 수확한다.
4. 커널: io_uring 제출(`io_uring:io_uring_submit_req`) → 블록 디바이스 direct I/O → `submit_bio()` → `blk_mq_submit_bio()`(`block:block_bio_queue`) → `struct request` 할당·병합·스케줄러(`block:block_rq_insert`) → `blk_mq_start_request()`(`block:block_rq_issue`) → `nvme_queue_rq()` → `nvme_setup_cmd()`(`nvme:nvme_setup_cmd`) → SQ doorbell.
5. 완료: CQE 처리(IRQ 또는 폴링) → `nvme_complete_rq()`/`nvme_complete_batch_req()`(둘 다 `nvme:nvme_complete_rq`) → `blk_update_request()`/`blk_complete_request()`(`block:block_rq_complete`) → bio 완료 → io_uring CQE 게시(`io_uring:io_uring_complete`) → 사용자 공간 수확.

### 2.2 정체성(identity)이 바뀌는 경계

| 경계 | 앞쪽 식별자 | 뒤쪽 식별자 | 문제 |
|---|---|---|---|
| 사용자 → io_uring | `struct aio_t *` (Ceph) | `req->cqe.user_data`, `struct io_kiocb *` | `user_data`는 사용자 값 그대로라 조인 가능. libaio 경로는 `iocb` 포인터 |
| io_uring → bio | `struct io_kiocb *` | `struct bio *` | 인라인 제출이면 같은 task, io-wq로 punt되면 다른 스레드 |
| bio → request | `struct bio *` | `struct request *` | 병합 시 여러 bio가 한 request로, split 시 한 bio가 여러 request로 |
| request → NVMe | `struct request *`, `rq->tag` | `(qid, cid)`, `cid = genctr<<12 | tag` | 같은 tag가 다른 hctx에 동시에 존재, 완료 직후 재사용 |
| 호스트 → 호스트 | 소켓/메시지 | 원격 호스트의 소켓/메시지 | 시계 기준점 상이, 커널 객체 포인터 무의미 |

### 2.3 흔한 설계 오류

- `BPF_MAP_TYPE_PERCPU_HASH`에 `<op_id, start_time>`을 넣고 다른 CPU에서 완료를 조회 → 대부분 조회 실패.
- `rq->tag`를 전역 키로 사용 → 서로 다른 hctx·디바이스의 동일 tag가 충돌하고, 스케줄러 사용 시 `rq->tag`는 디스패치 전 -1이다.
- `fexit/nvme_irq`로 하드웨어 완료 시각 측정 → `nvme_irq()`는 CQ를 배치로 처리하며 폴링 큐(`REQ_POLLED`, io_uring `IORING_SETUP_IOPOLL`)에는 IRQ가 없다. 요청 단위 완료는 `nvme:nvme_complete_rq`로 잡아야 한다.
- 존재하지 않는 Ceph USDT(`ceph_rgw:op_start`, `librados:aio_submit`)나 소스 트리에 없는 경로(`src/probes`)를 전제로 한 설계.
- "ringbuf는 다중 CPU가 락리스로 공유" → 실제로는 생산자 예약이 spinlock으로 직렬화된다(3.2절).

---

## 3. The Debate

이 주제에 대해 커널 BPF 개발자와 Ceph 성능 엔지니어가 공동으로 합의한 공개 기록은 확인되지 않는다. 아래는 실제 기록(커밋, 커널 문서, 소스)이 있는 설계 쟁점들이다.

### 3.1 perf buffer vs BPF ring buffer (5.8, Andrii Nakryiko)

BPF ring buffer(`BPF_MAP_TYPE_RINGBUF`)는 Alexei가 아니라 Andrii Nakryiko가 2020년 5월 제출해 5.8에 들어갔다(커밋 `457f44363a88`, `kernel/bpf/ringbuf.c`는 v5.7에 없고 v5.8에 존재).

> "There are two distinctive motivators for this work, which are not satisfied by existing perf buffer, which prompted creation of a new ring buffer implementation.
>   - more efficient memory utilization by sharing ring buffer across CPUs;
>   - preserving ordering of events that happen sequentially in time, even across multiple CPUs (e.g., fork/exec/exit events for a task)."
>
> — Andrii Nakryiko, "bpf: Implement BPF ring buffer and verifier support for it", 2020-05-29 ([lore](https://lore.kernel.org/bpf/20200529075424.3139988-2-andriin@fb.com/))

맥락: I/O 상관관계 관점에서 두 번째 동기가 중요하다. 제출은 CPU 3, 완료는 CPU 17에서 일어나는 요청의 이벤트를 per-CPU perf buffer로 내보내면 사용자 공간에서 타임스탬프로 재정렬해야 한다. 공유 MPSC ring buffer는 예약 순서대로 레코드가 놓이므로 이 부담이 줄어든다.

다만 "락리스"는 아니다. `Documentation/bpf/ringbuf.rst`는 생산자 카운터 증가가 spinlock 아래에서 직렬화되고, 예약 이후의 레코드 작성과 commit만 독립적이라고 설명한다. 문서는 NMI 컨텍스트에서 lock을 얻지 못하면 버퍼가 차지 않았어도 예약이 실패할 수 있다고 적는다. 구현은 v6.14까지 NMI에서 `raw_spin_trylock_irqsave()`를 썼고, v6.15부터 `struct bpf_ringbuf`가 `rqspinlock_t spinlock`(resilient queued spinlock)으로 바뀌어 모든 컨텍스트에서 `raw_res_spin_lock_irqsave()`로 예약한다. 이 lock은 교착·타임아웃을 감지하면 실패를 반환하므로, 그 경우에도 `bpf_ringbuf_reserve()`는 NULL을 돌려준다(태그별 `kernel/bpf/ringbuf.c` 대조). 즉 모든 CPU가 고빈도로 하나의 ringbuf에 쓰면 그 lock이 경합 지점이 된다. 대안은 다음과 같다.

| 선택지 | 장점 | 단점 |
|---|---|---|
| 단일 `RINGBUF` | 메모리 효율, 전역 순서, `bpf_ringbuf_reserve()`/`submit()`으로 복사 1회 | 생산자 lock 경합, 가득 차면 `reserve`가 NULL 반환(드롭) |
| CPU별 `RINGBUF`를 `ARRAY_OF_MAPS`로 | 경합 제거 | 순서 보장 상실, 메모리 증가 |
| `PERF_EVENT_ARRAY` | 구형 커널(5.8 이전) 지원 | per-CPU 메모리, 레코드 복사(`bpf_perf_event_output`), 순서 없음 |
| 이벤트 미출력 + 커널 내 집계 | 출력 비용 없음 | 개별 요청 정보 손실 |

wakeup 비용도 고려 대상이다. `bpf_ringbuf_submit()`에 `BPF_RB_NO_WAKEUP`을 주면 소비자 깨우기를 생략하고, 소비자는 주기적 폴링으로 읽는다. 고빈도 이벤트에서는 이것이 epoll wakeup 폭주를 막는다.

### 3.2 per-CPU 맵 vs 공유 맵

per-CPU 맵은 lock과 캐시 라인 바운싱이 없다는 장점이 있지만, **같은 키를 다른 CPU에서 조회하는 패턴에는 쓸 수 없다**. I/O 상관관계는 정확히 그 패턴이다.

- 제출/완료 CPU 불일치: blk-mq는 hctx를 여러 CPU가 공유할 수 있고, NVMe 완료 IRQ는 해당 큐의 affinity CPU에서, 폴링 완료는 폴링하는 task의 CPU에서 처리된다. 같은 CPU라는 보장이 없다.
- 따라서 `start[rq] = ts`는 `BPF_MAP_TYPE_HASH`(버킷 단위 lock)에 두고 완료 시 `bpf_map_lookup_elem()` 후 `bpf_map_delete_elem()`한다. 완료 이벤트를 놓쳐 엔트리가 쌓일 위험(트레이서 부착 직전 제출된 요청, 오류 경로)이 있으므로 `BPF_MAP_TYPE_LRU_HASH`로 상한을 두는 것이 안전하다.
- 히스토그램 버킷처럼 "합산만 하면 되는" 값은 `BPF_MAP_TYPE_PERCPU_ARRAY`/`PERCPU_HASH`에 두고 사용자 공간에서 CPU별 값을 합친다.

### 3.3 이벤트 스트리밍 vs 커널 내 집계

bcc/libbpf-tools의 `biolatency`류 도구는 시작·완료 시각 차이를 커널에서 계산해 log2 히스토그램만 갱신하고, `biosnoop`류는 요청마다 레코드를 내보낸다. 둘은 "합의된 원칙"이 아니라 용도에 따른 선택이다. 꼬리 지연 원인 분석에는 임계값 초과 요청만 ring buffer로 내보내는 하이브리드가 흔히 쓰인다. 이때 임계값 필터는 히스토그램과 같은 프로그램 안에서 처리해 추가 프로브를 만들지 않는다.

### 3.4 사용자 공간 계측: Ceph의 실제 선택

Ceph 소스 트리의 정적 계측은 두 계열이다.

1. **LTTng-UST**: `CMakeLists.txt`의 `option(WITH_LTTNG "LTTng tracing is enabled" ON)`과 `src/tracing/`의 `.tp` 파일들(`osd.tp`, `bluestore.tp`, `librados.tp`, `librbd.tp`, `rgw_op.tp`, `rgw_rados.tp`, `objectstore.tp`, `oprequest.tp`, `pg.tp` 등). 예: `TRACEPOINT_EVENT(osd, ms_fast_dispatch, ...)`, `TRACEPOINT_EVENT(librados, rados_aio_write_enter, ...)`, `TRACEPOINT_EVENT(rgw_op, before_data_transfer, ...)`. `src/tracing/README.md`는 `lttng-gen-tp`와 `liblttng-ust-dev` 사용법을 안내한다.
2. **OpenTelemetry 분산 트레이싱**: `option(WITH_JAEGER ... ON)`일 때 `src/common/tracer.h`의 `tracing::Tracer`가 `opentelemetry::trace` API로 `start_trace()`/`add_span()`을 제공하고, OSD 메시지가 `otel_trace` 컨텍스트를 실어 나른다. 이것이 호스트 간 요청 연결의 정답에 가깝다. 컨텍스트가 애플리케이션 프로토콜 안에서 전파되기 때문이다.

eBPF와의 접점: LTTng-UST 트레이스포인트는 그 자체로는 USDT가 아니다. lttng-ust가 `--with-sdt`(기본 비활성)로 빌드되어 `LTTNG_UST_HAVE_SDT_INTEGRATION`이 켜진 경우에만 `tracepoint()` 호출이 `sys/sdt.h` 프로브도 함께 생성한다. 그렇지 않으면 `usdt:` 대신 `uprobe:`로 C++ 심볼(예: `KernelDevice::aio_submit(IOContext*)`의 맹글링된 이름)에 붙여야 하며, 이는 Ceph 버전·컴파일러 인라이닝에 따라 깨질 수 있는 비안정 인터페이스다. 사용자 공간 uprobe는 매 히트마다 커널 진입(트랩)이 필요해 커널 `fentry`보다 비싸므로 고빈도 함수에는 신중해야 한다.

### 3.5 호스트 간 상관관계와 시계

`bpf_ktime_get_ns()`는 `CLOCK_MONOTONIC`이고 부팅 시점 기준이므로 서로 다른 호스트의 값을 빼는 것은 의미가 없다. 선택지는 다음과 같다.

| 방법 | 필요 조건 | 오차/한계 |
|---|---|---|
| 각 호스트 내부 구간만 측정, 호스트 간은 애플리케이션 스팬(OpenTelemetry)으로 연결 | 앱 수준 컨텍스트 전파 | 네트워크 구간은 "클라이언트 스팬 − 서버 스팬"의 차로만 추정 |
| `bpf_ktime_get_tai_ns()`(6.1) + PTP(`phc2sys`로 시스템 시계 동기) | NIC 하드웨어 타임스탬프, PTP 인프라 | 동기화 오차(환경에 따라 수십 ns~수 µs) 이하 구간은 해석 불가 [추측/미확인: 오차 범위는 환경 의존] |
| 송신 측 단일 호스트 지표(`tcp_sock->srtt_us`, `tcp:tcp_probe`, `tcp:tcp_retransmit_skb`) | 없음 | 단방향 지연은 알 수 없음, RTT 평활값 |

`bpf_ktime_get_boot_ns()`(5.8)는 suspend 시간을 포함할 뿐 호스트 간 기준점 문제는 해결하지 않는다.

---

## 4. Implementation Impact

### 4.1 수정된 상관관계 파이프라인 (단일 호스트, Linux 5.11+ 가정)

```
[user] Ceph KernelDevice (bdev_ioring=true)
   uprobe: KernelDevice::aio_submit(IOContext*)        -> 선택. 사용자 컨텍스트(OSD reqid는 LTTng 이벤트로 별도 수집)
   io_uring_sqe_set_data(sqe, aio_t*)                  -> user_data = aio_t 포인터
        |
[kernel] tp_btf/io_uring_submit_req (struct io_kiocb *req)
   key: tid  ->  inflight_task[tid] = { user_data, ts }            (HASH, 제출 task에서 갱신)
   (io-wq punt 시: io_uring:io_uring_queue_async_work 로 감지 → tid 조인 불가 표시)
        |
   tp_btf/block_bio_queue (struct bio *bio)            -> 같은 tid면 bio_ctx[bio] = user_data
        |  (merge/split: block_bio_backmerge / block_split 로 다대일·일대다 기록)
   tp_btf/block_rq_insert / block_rq_issue (struct request *rq)
   key: rq 포인터 -> req_ctx[rq] = { user_data(rq->bio로 조회), issue_ts, dev, hctx->queue_num, rq->tag }
        |
   tp_btf/nvme_setup_cmd (struct request *req, struct nvme_command *cmd)
   key: rq 포인터 -> req_ctx[rq].setup_ts, qid = hctx->queue_num + 1, cid = cmd->common.command_id
        |
   ... 디바이스 ...
        |
   tp_btf/nvme_complete_rq (struct request *req)        -> IRQ/폴링/배치 완료 모두 발생
   tp_btf/block_rq_complete (struct request *rq, blk_status_t error, unsigned int nr_bytes)
        -> 지연 계산, 히스토그램(PERCPU_ARRAY) 갱신, 임계값 초과 시 RINGBUF 출력, req_ctx 삭제
        |
   tp_btf/io_uring_complete (ctx, req, struct io_uring_cqe *cqe) -> cqe->user_data로 사용자 요청과 재결합
```

설계 근거:

- **`struct request *`가 블록과 NVMe를 잇는다.** `nvme_setup_cmd()`와 `nvme_complete_rq()`/`nvme_complete_batch_req()`(drivers/nvme/host/core.c)는 모두 `trace_nvme_*`에 `struct request *`를 넘긴다. 따라서 `tp_btf` 사용 시 별도 키 변환이 필요 없다. 단 nvme 드라이버가 모듈이면 모듈 BTF(`CONFIG_DEBUG_INFO_BTF_MODULES`, 5.11)가 있어야 `tp_btf/nvme_*`를 쓸 수 있다.
- **tracefs 형식 트레이스포인트만 쓸 때**: `tracepoint/nvme/nvme_setup_cmd`의 레코드는 포인터 대신 `ctrl_id`, `qid`, `cid`, `disk`를 준다. `qid`는 `nvme_req_qid()` = `req->mq_hctx->queue_num + 1`, `cid`는 `nvme_cid()` = `(genctr & 0xf) << 12 | rq->tag`이다. 그러므로 블록 쪽에서 `(dev, hctx->queue_num, rq->tag)`를 기록해 두면 `(disk, qid-1, cid & 0xfff)`로 조인할 수 있다. 이 키는 issue부터 complete까지만 유일하다.
- **tag 사용 주의**: `struct request`에는 `int tag;`와 `int internal_tag;`가 따로 있다. I/O 스케줄러(mq-deadline 등)가 있으면 할당 시에는 `internal_tag`만 잡히고 드라이버 tag는 디스패치 때 붙는다. `block_rq_insert` 시점의 `rq->tag`를 키로 쓰면 안 된다.
- **io_uring ↔ bio 조인은 휴리스틱이다.** 인라인 제출에서는 `io_uring_submit_req` 직후 같은 task에서 `submit_bio()`가 이어지므로 tid로 묶을 수 있지만, `-EAGAIN` 후 io-wq로 넘어가거나 `IORING_SETUP_SQPOLL`이면 다른 스레드에서 bio가 생긴다. 이런 경우는 `(dev, sector)` 범위 매칭이나 `kiocb` 포인터 기반 `fentry`(내부 함수, 비안정)로 보완하고, 조인 실패 비율을 지표로 남긴다.
- **libaio 경로(`bdev_ioring=false`, Ceph 기본값)**: Ceph `aio_t`는 `struct iocb`를 담고 `io_submit()`에 그 포인터를 넘긴다. 커널 측 aio 제출에는 전용 tracepoint가 없으므로 `syscalls:sys_enter_io_submit`(tid, iocb 배열 포인터)와 tid 기반 조인을 쓴다. [추측/미확인: `fs/aio.c` 내부 함수에 대한 fentry 부착 가능 여부는 인라이닝에 따라 다름]

### 4.2 계층별 프로브 매핑

| 계층 | 프로브 (실재 확인) | 조인 키 | 수명/주의 |
|---|---|---|---|
| Ceph OSD | LTTng-UST `osd:ms_fast_dispatch`, `bluestore:transaction_*`; OpenTelemetry 스팬 | `reqid.name`, `reqid.tid` / trace id | LTTng 세션 필요. USDT는 lttng-ust `--with-sdt` 빌드 시에만 |
| Ceph BlockDevice | `uprobe:KernelDevice::aio_submit`, `uprobe:KernelDevice::_aio_thread` 내부 (맹글링 심볼) | `IOContext*`, `aio_t*` | 비안정, 인라이닝 위험 |
| io_uring | `io_uring:io_uring_submit_req`(6.4 이전 이름 `io_uring_submit_sqe`), `io_uring:io_uring_complete`, `io_uring:io_uring_queue_async_work` | `user_data`, `struct io_kiocb *` | 6.4 개명 대응 필요 |
| block (bio) | `block:block_bio_queue`, `block:block_bio_backmerge`, `block:block_split`, `block:block_bio_complete` | `struct bio *`, `(dev, sector)` | merge/split로 다대다 |
| block (request) | `block:block_rq_insert`, `block:block_rq_issue`, `block:block_rq_complete`, `block:block_rq_requeue`, `block:block_io_start`/`block_io_done`(6.5) | `struct request *` 또는 `(dev, hctx, tag)` | 5.11에서 `block_rq_issue` 등 TP_PROTO의 `request_queue` 인자 제거 |
| NVMe | `nvme:nvme_setup_cmd`, `nvme:nvme_complete_rq`, `nvme:nvme_sq` | `struct request *` 또는 `(ctrl_id, qid, cid)` | `cid` 상위 4비트는 generation counter |
| TCP | `tcp:tcp_probe`, `tcp:tcp_retransmit_skb`, `tcp:tcp_sendmsg_locked` | `struct sock *` (소켓 수명 동안만 유일), 4-tuple | 호스트 간 시계 문제(3.5절) |

### 4.3 맵 구성

| 용도 | 맵 타입 | 이유 |
|---|---|---|
| in-flight 요청 시작 시각/컨텍스트 | `BPF_MAP_TYPE_LRU_HASH` (키: `struct request *`) | 제출·완료 CPU가 달라도 조회 가능, 완료 누락 시 자동 축출 |
| tid → 현재 io_uring 요청 | `BPF_MAP_TYPE_HASH` 또는 task local storage | 같은 task 내 조인 |
| 지연 히스토그램 | `BPF_MAP_TYPE_PERCPU_ARRAY` (log2 버킷) | 합산만 필요, lock 없음 |
| 이상치 레코드 | `BPF_MAP_TYPE_RINGBUF` + `BPF_RB_NO_WAKEUP` | 순서 보존, 복사 1회; 예약 실패 카운터를 PERCPU_ARRAY에 기록 |

### 4.4 오버헤드 측정 절차

1. `sysctl -w kernel.bpf_stats_enabled=1` (5.1) 또는 `BPF_ENABLE_STATS` 명령(5.8, fd를 닫으면 해제).
2. `bpftool prog show`에서 프로그램별 `run_time_ns`, `run_cnt`, `recursion_misses`를 읽어 평균 실행 시간 = `run_time_ns / run_cnt`를 계산한다. 이 값은 trampoline/tracepoint 진입 비용을 제외한 BPF 본문 시간에 가깝다(`__update_prog_stats()`가 `__bpf_prog_enter*`와 `__bpf_prog_exit*` 사이를 `sched_clock()`으로 잰다).
3. 진입 비용까지 포함한 영향은 같은 fio 작업(예: 4KiB randread, 고정 iodepth)을 프로브 없음/있음으로 반복해 IOPS, CPU 사용률, p99를 비교한다.
4. ring buffer 예약 실패 수, LRU 축출 수, 조인 실패 수를 함께 보고한다. 이 셋이 0이 아니면 결과 해석 범위를 줄여야 한다.
5. 측정이 끝나면 통계를 끈다. 통계 수집은 프로그램 실행마다 `sched_clock()` 두 번과 per-CPU 카운터 갱신을 더한다.

"CPU 오버헤드 1% 미만", "처리량 20% 급감" 같은 일반화된 수치에는 1차 출처가 없다. 이 문서가 제시하는 것은 숫자가 아니라 숫자를 얻는 절차다.

---

## 5. Primary References

- [bpf: Implement BPF ring buffer and verifier support for it (lore)](https://lore.kernel.org/bpf/20200529075424.3139988-2-andriin@fb.com/) — Andrii Nakryiko, 2020-05-29. 병합 커밋의 Link 대상 패치 메일, 3.1절 인용 원문.
- [BPF ring buffer [LWN.net]](https://lwn.net/Articles/820559/) — 첫 패치셋 `[PATCH bpf-next 0/6] BPF ring buffer` 커버레터 사본, 2020-05-13.
- [bpf: Implement BPF ring buffer and verifier support for it · torvalds/linux@457f443](https://github.com/torvalds/linux/commit/457f44363a8894135c85b7a9afd2bd8196db24ab) — 병합 커밋 (Linux 5.8).
- [BPF ring buffer — The Linux Kernel documentation](https://www.kernel.org/doc/html/latest/bpf/ringbuf.html) — 생산자 spinlock 직렬화, NMI 컨텍스트 예약 실패.
- [Documentation for /proc/sys/kernel/ — The Linux Kernel documentation](https://www.kernel.org/doc/html/latest/admin-guide/sysctl/kernel.html) — `bpf_stats_enabled` 항목.
- [linux/drivers/nvme/host/trace.h at master · torvalds/linux](https://github.com/torvalds/linux/blob/master/drivers/nvme/host/trace.h) — `nvme_setup_cmd`, `nvme_complete_rq` 정의.
- [linux/include/trace/events/block.h at master · torvalds/linux](https://github.com/torvalds/linux/blob/master/include/trace/events/block.h) — 블록 계층 tracepoint 정의.
- [linux/include/trace/events/io_uring.h at master · torvalds/linux](https://github.com/torvalds/linux/blob/master/include/trace/events/io_uring.h) — io_uring tracepoint 정의.
- [ceph/src/tracing at main · ceph/ceph](https://github.com/ceph/ceph/tree/main/src/tracing) — LTTng-UST tracepoint 정의.
- [ceph/src/common/tracer.h at main · ceph/ceph](https://github.com/ceph/ceph/blob/main/src/common/tracer.h) — OpenTelemetry tracer 래퍼.
- [JAEGER- DISTRIBUTED TRACING — Ceph Documentation](https://docs.ceph.com/en/latest/dev/developer_guide/jaegertracing/) — Ceph 분산 트레이싱 빌드·사용법.
