# End-to-End 스토리지 데이터패스 통합 분석: S3 PUT 한 건이 RGW에서 NVMe DMA까지 가는 길

> 범위: Ceph RGW(Beast) → TCP → RADOS 메신저 → OSD → BlueStore / SeaStore → libaio / io_uring → blk-mq 또는 NVMe 패스스루 → NVMe PCIe DMA. 기준 시점은 2026-10(Linux master 7.3-rc7, Ceph `main`·Tentacle v20). 이 문서는 `artifacts/01`~`13`의 도메인 문서를 종합한 것이다. 각 주장 뒤의 `(→ 06/03)` 같은 표기는 근거가 된 도메인 문서(디렉터리 번호/파일 번호)를 가리킨다. 도메인 문서에 없는 내용은 이 문서를 쓰면서 1차 소스(커널·Ceph 소스, 공식 문서)로 직접 확인했고, 확인 위치를 함께 적었다.

## 1. Verdict

"모든 계층에서 락과 컨텍스트 스위칭이 사라진 단일 코어 락리스 런타임으로 수렴했다", "Crimson + SeaStore + `io_uring_cmd`의 결합이 SPDK급 성능을 입증했다" 같은 요약이 흔히 보이지만, 둘 다 도메인 문서의 검증 결과와 맞지 않는다. 확인된 결론은 아래와 같다.

1. **2026-10 현재 프로덕션 기본 경로는 Classic이다.** RGW Beast 프론트엔드(Nautilus v14.2.0부터 기본, → 06/01), librados, AsyncMessenger + msgr2(→ 06/02), Classic OSD의 `ShardedOpWQ`(→ 06/04), BlueStore(Luminous v12부터 기본, → 06/03)를 지난다. 그 아래는 `KernelDevice`가 **libaio**로 `O_DIRECT` 블록 장치에 쓰는 경로다. 블록 장치 쪽은 blk-mq(→ 02/01)와 nvme-pci 드라이버다. io_uring은 `bdev_ioring=true`를 줄 때만 쓰이고 기본값은 `false`다(→ 06/03). Ceph의 어떤 경로도 NVMe 패스스루(`/dev/ngXnY`, `IORING_OP_URING_CMD`)를 데이터 I/O에 쓰지 않는다(→ 06/04).
2. **Crimson과 SeaStore는 tech preview다.** Squid(v19) 릴리스 노트는 Crimson을 "first tech preview release"로, Tentacle(v20) 릴리스 노트는 SeaStore를 "Tech Preview"로 적는다. SeaStore의 데이터 I/O는 `seastar::file::dma_write()`를 거쳐 Seastar reactor 백엔드(`io_uring` / `linux-aio` / `epoll`)로 나간다. `main`의 `crimson/os/seastore`에는 `io_uring_cmd` 데이터 경로가 없다(→ 06/04). "Crimson + SeaStore + uring_cmd" 조합은 **현재 코드 기준으로 사실이 아니다.** 비전으로서도 공식 로드맵 문서로 확인하지 못했다 `[추측/미확인]`.
3. **NVMe 패스스루는 blk-mq를 우회하지 않는다.** `nvme_uring_cmd_io()`는 `nvme_alloc_user_request()` → `blk_mq_alloc_request()`로 태그와 `struct request`를 받고, `blk_execute_rq_nowait()`로 blk-mq 디스패치를 거쳐 `nvme_queue_rq()`에 닿는다. 건너뛰는 것은 VFS·파티션·페이지 캐시, bio 분할·병합, I/O 스케줄러다(→ 03/02). 커널을 통째로 우회하는 것은 SPDK뿐이다(→ 07/01).
4. **메신저는 둘이다.** Classic OSD와 RGW(librados)는 AsyncMessenger(`EventEpoll` 워커)를, Crimson OSD는 `crimson::net`(ProtocolV2 구현)을 쓴다. 와이어 프로토콜은 둘 다 msgr2다(→ 06/02). AsyncMessenger의 전송 계층은 `ms_type`으로 고르며 기본은 `async+posix`(TCP)다. `async+rdma`(`RDMAStack`, ibverbs·rdma_cm)도 소스에 있지만 옵션 설명이 "Other transports may be experimental and support may be limited."라고 적는다(`src/common/options/global.yaml.in`, `src/msg/async/rdma/` 직접 확인. verbs 스택 자체는 → 13/02).
5. **수신 제로카피는 메모리 종류에 따라 두 가지다.** 호스트 메모리로 받으려면 io_uring zcrx(`IORING_OP_RECV_ZC`, Linux 6.15)를 쓴다. dma-buf로 표현된 디바이스 메모리(GPU 등)로 받으려면 devmem TCP(RX 6.12, TX 6.16)를 쓴다. 송신은 `MSG_ZEROCOPY`(4.14)와 io_uring `SEND_ZC`(6.0)가 있다(→ 04/02). Ceph `main`의 AsyncMessenger는 이 중 어느 것도 쓰지 않는다. 일반 `sendmsg(..., MSG_NOSIGNAL | MSG_MORE)`를 쓰며, `MSG_ZEROCOPY` 송신은 draft RFC PR #70638 단계다(→ 06/02).
6. **지연 수치는 이 문서에서 제시하지 않는다.** 흔히 인용되는 "4KB PUT 15–35µs", "NAND 프로그램 5–8µs" 같은 수치는 1차 출처를 찾지 못했다. 특히 후자는 TLC NAND의 프로그램 시간(통상 수백 µs 규모로 알려짐 `[추측/미확인: 장치별 데이터시트 미확인]`)과 크게 어긋났다. 대신 4.5절에서 홉별 지연을 **측정하는 방법**을 정리했다.
7. **관측성 설계를 다시 짰다.** 사용자 공간(RGW/OSD)은 uprobe 또는 LTTng-UST/USDT로, 커널은 tracepoint(`tp_btf`)와 `fentry`로 본다. 블록과 NVMe 계층은 `struct request *` 포인터를 키로 잇는다. 시작 시각 맵은 공유 `HASH`/`LRU_HASH`에 둔다. 호스트 사이의 구간은 각 호스트의 단조 시계를 서로 빼서 구할 수 없다(→ 05/02).

한 줄로 줄이면 이렇다. **S3 PUT 경로의 현대화는 아직 계층마다 따로 진행 중이다.** 각 계층의 최신 기술(io_uring zcrx, uring_cmd, Crimson, SeaStore)은 독립적으로 존재하지만, Ceph 기본 배포에서 이것들이 한 경로로 이어져 있지는 않다.

## 2. Problem Statement

### 2.1 S3 PUT 한 건이 지나는 홉

클라이언트가 `PUT /bucket/key`를 보내면 다음 일이 일어난다. 이름은 모두 Ceph `main` 또는 Linux master에서 확인했다.

1. **RGW HTTP 수신**: Beast 프론트엔드의 `handle_connection()`이 `http::async_read_header()`로 헤더를 읽는다. 바디는 `StreamIO::recv_body()` 안에서 `http::async_read_some()`으로 읽는다. 둘 다 코루틴 양보 지점이다(→ 06/01). 커널 쪽에서는 일반 TCP 수신이므로 소켓 버퍼에서 사용자 버퍼로 한 번 복사된다.
2. **RGW → RADOS 분할**: `RGWPutObj::execute(optional_yield)`가 `get_data()`로 바디를 청크 단위로 읽어 `filter->process()`에 넘긴다(`src/rgw/rgw_op.cc`). 그 아래 `AtomicObjectProcessor` → `RadosWriter::process()`가 RADOS 쓰기 op(`write_full`/`write`)를 만든다(`src/rgw/driver/rados/rgw_putobj_processor.cc`). 청크 크기 `rgw_max_chunk_size`와 백킹 RADOS 객체 크기 `rgw_obj_stripe_size`는 기본 4 MiB다. 동시 진행 창 `rgw_put_obj_min_window_size`는 기본 16 MiB다(`src/common/options/rgw.yaml.in`). 즉 큰 객체는 4 MiB짜리 RADOS 객체 여러 개로 쪼개져 병렬로 나간다.
3. **librados → 메신저 송신**: yield context가 있으면 `librados::async_operate()`가 `IoCtx::aio_operate()`를 부르고, `AioCompletion` 콜백이 코루틴을 재개한다(`src/rgw/rgw_aio.cc`, `librados_asio.h`, → 06/01). 메시지는 AsyncMessenger 워커가 msgr2 프레임(crc 또는 secure 모드)으로 만들어 `sendmsg()`로 보낸다(→ 06/02).
4. **OSD 수신과 디스패치(Classic)**: `OSD::ms_fast_dispatch()` → `OSD::enqueue_op()` → `ShardedOpWQ` → `OSD::ShardedOpWQ::_process()` → `OSD::dequeue_op()` → `PrimaryLogPG::do_op()` → `execute_ctx()` → `issue_repop()` 순으로 흐른다. `ReplicatedBackend::submit_transaction()`은 복제본에 `MOSDRepOp`를 보내고(`issue_op()`), 로컬에서는 `queue_transactions()`를 부른다(`src/osd/*.cc`, → 06/04).
5. **BlueStore 트랜잭션**: `BlueStore::queue_transactions()` → `_do_write()` → `_do_write_small()`/`_do_write_big()` → `_do_alloc_write()`로 이어진다. 그다음 `_txc_state_proc()`의 `STATE_PREPARE`에서 `bdev->aio_submit()`이 불린다. 메타데이터는 `kv_sync_thread`가 RocksDB(BlueFS 위)에 그룹 커밋한다(→ 06/03, 10/03).
6. **커널 블록 제출**: `KernelDevice::aio_submit()` → `aio_queue_t::submit_batch()`(libaio `io_submit`) 또는 `ioring_queue_t::submit_batch()`(liburing)로 이어진다(`src/blk/kernel/`). 커널에서는 `io_submit_one()` → `aio_write()` 또는 io_uring `io_write()`가 `blkdev_write_iter()` → `blkdev_direct_IO()` → `submit_bio()`로 들어간다(`fs/aio.c`, `io_uring/rw.c`, `block/fops.c`).
7. **blk-mq → nvme-pci**: `blk_mq_submit_bio()`가 plug 캐시 또는 `__blk_mq_alloc_requests()`로 태그를 받고 `->queue_rq()`로 간다(→ 02/01). `nvme_queue_rq()` → `nvme_prep_rq()`(CID 부여, `nvme_map_data()`로 PRP/SGL DMA 매핑)를 거친 뒤, `nvmeq->sq_lock` 아래에서 `nvme_sq_copy_cmd()`가 64B 명령을 SQ에 복사한다. doorbell은 `nvme_write_sq_db()`가 배치 끝(`bd->last`)에서만 울린다(→ 03/02).
8. **장치 DMA와 완료**: 컨트롤러가 PRP/SGL이 가리키는 호스트 메모리를 DMA로 읽어 매체에 기록한다. 완료는 CQE로 돌아온다. 일반 큐는 `nvme_irq()`가 CQE를 **배치로** 처리하고, 폴링 큐(`nvme.poll_queues`)는 IRQ 없이 `nvme_poll()`이 처리한다(→ 03/02). 이후 블록 완료 → aio/io_uring 완료 → BlueStore `_txc_finish_io()` → KV 커밋 → 복제본 커밋 응답 수집 → 클라이언트 ack로 거슬러 올라간다.

### 2.2 무엇이 실제 병목 후보인가

연도별 병목을 단정하는 서술은 시대가 맞지 않는 경우가 많다. 예를 들어 블록 계층 `queue_lock`은 레거시 `request_fn` 경로와 함께 Linux 5.0(2019-03)에서 이미 사라졌으므로 2020년 이후의 병목 후보가 아니다(→ 02/03). 도메인 문서가 확인한 **구조적** 병목 후보는 다음과 같다. 정량 기여도는 확인하지 못했다.

| 홉 | 구조적 비용 (소스로 확인) | 근거 |
|---|---|---|
| RGW | `optional_yield`가 끊긴 호출 경로에서 `null_yield`로 동기 블로킹, `maybe_warn_about_blocking()` 경고 | 06/01 |
| 네트워크 RX | 바디 수신 시 커널→사용자 복사 1회 (zcrx 미사용) | 04/02 |
| 메신저 | 피어당 단일 연결, 워커 수 `ms_async_op_threads`(기본 3), `MSG_ZEROCOPY` 미사용 | 06/02 |
| Classic OSD | 메신저 워커 → `ShardedOpWQ` 샤드 워커 → BlueStore kv/aio/finisher 스레드 간 전환, `PG::lock()` | 06/04 |
| BlueStore | 단일 `kv_sync_thread`의 그룹 커밋 직렬화 (CPU 병목 여부는 `[추측/미확인]`) | 06/03 |
| io_uring 백엔드 | `ioring_queue_t`가 링 하나를 `sq_mutex`/`cq_mutex`(pthread mutex)로 감싸 공유 | Ceph `src/blk/kernel/io_uring.cc` 직접 확인 |
| blk-mq | 요청당 고정 비용(할당·태그·doorbell). 스케줄러 사용 시 `dd->lock` 등 | 02/01, 02/03 |
| nvme-pci | SQ 단위 `sq_lock`, PRP/SGL 매핑(IOMMU 사용 시 IOVA 할당) | 03/02, 08/02 |
| IOMMU (OSD 호스트 NVMe) | DMA 도메인이면 요청마다 IOVA 할당(per-CPU rcache)과 해제·IOTLB 무효화(x86 기본 lazy flush queue). rcache는 128KiB 이하만 캐시하므로 nvme-pci는 `max_hw_sectors`를 `dma_opt_mapping_size()`로 자른다(6.4). 4 MiB RADOS 객체 쓰기는 이 경우 여러 NVMe 명령으로 나뉜다 `[추측/미확인: BlueStore aio 크기 분포에 따른 실제 분할 횟수]` | 12/01 |
| IRQ 배치 (양 호스트) | NVMe 완료 IRQ는 managed interrupt라 제출 CPU의 hctx로 돌아온다. NIC 수신 IRQ는 RSS·irqbalance가 정하므로 메신저 워커 CPU와 어긋날 수 있다(RFS/aRFS로 맞춤). 기여도 측정은 찾지 못했다 `[추측/미확인]` | 12/02 |

### 2.3 파일시스템·페이지 캐시는 어디에 남아 있나

BlueStore 데이터 경로에는 파일시스템이 없다. `KernelDevice`는 raw 블록 장치를 `O_RDWR | O_DIRECT`로 열어 데이터를 쓰므로, iomap(→ 11/01)이나 페이지 캐시 writeback(→ 11/02)을 거치지 않고 `blkdev_direct_IO()`로 바로 내려간다. 그래도 페이지 캐시가 완전히 빠지지는 않는다.

- **BlueFS 버퍼드 I/O**: 같은 생성 루프에서 `O_DIRECT` 없는 두 번째 fd(`fd_buffereds`)도 연다. `KernelDevice::choose_fd(buffered, ...)`가 요청마다 둘 중 하나를 고른다. `bluefs_buffered_io`(기본 `true`)가 켜져 있으면 BlueFS는 읽기와 `_flush_range_F()`의 파일 쓰기를 이 fd로 수행한다. 버퍼드 쓰기는 `_sync_write()`에서 `pwritev()` 뒤 `sync_file_range()`로 내린다. 이때 블록 장치의 페이지 캐시(→ 11/02)가 RocksDB block cache의 2차 캐시 역할을 한다. 옵션 설명은 일부 워크로드에서 과도한 swap과 그에 따른 stall이 보고됐다고 적는다. 예외는 RocksDB WAL이다. `main`에서는 `bluefs_wal_envelope_mode`(기본 `true`)가 적용된 파일이 `buffered=false`, 즉 `O_DIRECT`로 쓰인다. 따라서 PUT 커밋 경로의 객체 데이터와 WAL 쓰기는 페이지 캐시를 거치지 않는다. 반면 memtable flush·compaction으로 생기는 SST 쓰기와 BlueFS 읽기는 기본 설정에서 페이지 캐시를 거친다(`src/blk/kernel/KernelDevice.cc`, `src/os/bluestore/BlueFS.cc`, `src/common/options/global.yaml.in` 직접 확인. envelope 모드가 들어간 릴리스는 확인하지 못했다 `[추측/미확인]`).
- **FileStore(역사)**: FileStore는 XFS 같은 로컬 FS 위에 객체를 파일로 두고 페이지 캐시를 썼다. Reef v18.2.0에서 소스가 제거됐다(→ 06/03). 따라서 11/01·11/02의 DIO 락 모델과 writeback 쓰로틀은 FileStore 시절 OSD 성능에 직접 걸리던 문제였다. 현재 OSD에는 해당하지 않는다.
- **RGW 호스트**: PUT 바디는 소켓 → 사용자 버퍼 → librados 메시지로 흐르고 로컬 파일에 닿지 않는다. 로컬 FS를 쓰는 RGW 기능으로는 D3N 데이터 캐시(`rgw_d3n_l1_local_datacache_enabled`, 기본 `false`)가 있다. 이것은 반복 읽기를 위한 캐시라 PUT 경로와는 무관하다([D3N RGW Data Cache](https://docs.ceph.com/en/latest/radosgw/d3n_datacache/)).

## 3. The Debate

### 3.1 BlueStore에 io_uring을 붙이면 왜 극적이지 않은가

2019년 `bdev_ioring` 성능이 기대에 못 미친 이유를 `IORING_SETUP_SINGLE_ISSUER`(6.0)와 `IORING_SETUP_DEFER_TASKRUN`(6.1)의 부재로 설명하는 것은 시대가 맞지 않는다. 이 두 플래그는 2022년에 생겼고(→ 01/02), PR #27392는 2019-12에 머지됐다. 확인된 사실은 다음과 같다.

- `KernelDevice` 생성자는 `bdev_ioring`, `bdev_ioring_hipri`(→ `IORING_SETUP_IOPOLL`), `bdev_ioring_sqthread_poll`(→ `IORING_SETUP_SQPOLL`)을 읽는다. io_uring을 쓸 수 없으면 "Fallback to libaio" 경고를 내고 libaio로 돌아간다(`src/blk/kernel/KernelDevice.cc`).
- `ioring_queue_t::submit_batch()`는 `pthread_mutex_lock(&d->sq_mutex)` 아래에서 SQE를 채우고 제출한다. 완료 수확은 `cq_mutex`로 보호한다(`src/blk/kernel/io_uring.cc`). 여러 OSD 스레드가 링 하나를 뮤텍스로 나눠 쓰는 구조다. io_uring이 가장 잘 동작하는 "링 하나 = 제출 스레드 하나" 모델과는 다르다.
- 기본값은 지금도 `bdev_ioring=false`다(→ 06/03). 기본값을 바꾸지 않은 공식 근거는 찾지 못했다 `[추측/미확인]`.

따라서 정확한 서술은 "구조적 불일치가 있다"까지다. 그 불일치가 성능 차이를 얼마나 만드는지는 공개 벤치마크로 확인하지 못했다 `[추측/미확인]`.

### 3.2 Crimson + SeaStore는 어디까지 왔나

Crimson과 SeaStore의 공식 상태는 릴리스 노트에서 확인할 수 있다.

> "Crimson’s first tech preview release! Supporting RBD workloads on Replicated pools."
>
> — [Squid — Ceph Documentation](https://docs.ceph.com/en/latest/releases/squid/), v19.2.0 Highlights (2026-10-15 확인)

> "SeaStore Tech Preview: SeaStore object store is now deployable alongside Crimson-OSD, mainly for early testing and experimentation."
>
> — [Tentacle — Ceph Documentation](https://docs.ceph.com/en/latest/releases/tentacle/), v20.2.0 (2026-10-15 확인)

해설: Squid에서는 Crimson OSD가 AlienStore(BlueStore를 별도 pthread 풀에서 실행)로 RBD 복제 풀만 지원했다. Tentacle에서 SeaStore가 함께 배포 가능해졌다. 둘 다 "early testing" 단계다. 06/04 문서가 확인한 나머지 사실은 이렇다.

- Seastar reactor 백엔드 선택 순서는 `io_uring` → `asymmetric_io_uring` → `linux-aio` → `epoll`이다. Ceph는 `WITH_LIBURING`(기본 ON)일 때 `Seastar_IO_URING`을 켠다. 그래서 `main` 빌드에서는 커널이 지원하면 io_uring이 기본일 수 있고, "Crimson은 linux-aio가 기본"이라는 설명은 현재 `main` 기준으로 정확하지 않다. 과거 릴리스의 Seastar 서브모듈도 같은 순서였는지는 확인하지 못했다 `[추측/미확인]`. 운영자는 `crimson_reactor_backend`로 백엔드를 강제할 수 있다.
- `NVMeBlockDevice`는 `linux/nvme_ioctl.h`를 포함한다. 하지만 이는 identify 같은 admin 명령과 기능 탐지에 쓰이고, 데이터 I/O는 `dma_write`다.
- ZNS용 `segment_manager/zbd.cc`는 있다. FDP 지원은 `[추측/미확인]`이다.

### 3.3 "블록 계층 우회"의 정확한 의미

> "Does NVMe passthrough mean bypassing the block layer? It is a common misconception."
>
> — Joshi et al., [I/O Passthru: Upstreaming a flexible and efficient I/O Path in Linux](https://www.usenix.org/conference/fast24/presentation/joshi), USENIX FAST '24 (2024-02), 4.4절 (03/02 문서에서 원문 확인)

해설: 이 논문은 패스스루 설계자들(Samsung·Meta)이 쓴 것이다. 저자들 스스로 패스스루가 blk-mq의 태그 관리, 코어-큐 매핑, 타임아웃/abort를 그대로 쓴다고 설명한다. 같은 논문의 결론은 "I/O Passthru reduces the per-core efficiency gap but is still far from kernel-bypass solutions like SPDK."다. 장치가 포화되는 구성(장치당 1코어, Optane P5800X 2개, 512B randread)에서는 패스스루와 SPDK가 모두 10M IOPS를 냈다. 코어 하나로 장치 둘을 돌리면 블록 경로 4.4M, 패스스루 6M IOPS였고, SPDK는 두 장치를 계속 포화시켰다(→ 03/02 4.6절 표). 따라서 "uring_cmd로 SPDK급 성능을 얻는다"는 주장은 장치 병목 조건에서만 맞고, 코어당 효율에서는 틀리다.

### 3.4 네트워크 제로카피: 송신과 수신은 다른 문제다

"io_uring SEND_ZC / devmem TCP 제로카피 수신"을 RGW–OSD 경로의 현재 상태로 묶어 말하면 서로 다른 두 문제가 섞인다.

- **송신**: `MSG_ZEROCOPY`는 커널 문서가 "not a free lunch"라고 쓰고, 대략 10 KB 이상 쓰기에서만 효과가 있다고 안내한다. io_uring `SEND_ZC`는 알림 CQE(`IORING_CQE_F_NOTIF`)로 버퍼 재사용 시점을 알린다(→ 04/02).
- **수신**: devmem TCP는 페이로드를 dma-buf 디바이스 메모리로 받는다. 호스트 메모리로 바로 받으려면 io_uring zcrx를 써야 한다. 두 방식 모두 NIC의 header/data split, flow steering, RSS가 필요하다. zcrx는 링에 `IORING_SETUP_SINGLE_ISSUER`와 `IORING_SETUP_DEFER_TASKRUN`을 요구한다(→ 04/02). devmem TCP의 소켓 옵션 uAPI는 `SO_DEVMEM_LINEAR`, `SO_DEVMEM_DMABUF`, `SO_DEVMEM_DONTNEED`이며 Linux 6.12에 들어왔다(`SO_RCV_DEV_MEM` 같은 이름은 없다).
- **Ceph 현실**: RGW는 Boost.Asio 소켓을, 메신저는 `PosixStack`의 일반 `sendmsg`를 쓴다. 위 기법 중 Ceph `main`에 들어간 것은 없다(→ 06/02).

### 3.5 관측성: "단일 Correlation ID"는 없다

05/02 문서가 정리한 논점은 세 가지다. (1) 계층 경계마다 요청의 정체가 바뀐다. 사용자 객체 → `user_data` → `struct bio *` → `struct request *` → `(qid, cid)` 순이다. 그래서 맵에 조인 키를 남기며 이어 붙일 수밖에 없다. (2) 제출 CPU와 완료 CPU는 다를 수 있다. 시작 시각을 `PERCPU_HASH`에 두면 완료 쪽에서 찾지 못한다. (3) `bpf_ktime_get_ns()`는 호스트마다 기준점이 다른 `CLOCK_MONOTONIC`이다. 호스트 간 구간을 구하려면 PTP로 맞춘 `CLOCK_TAI`(`bpf_ktime_get_tai_ns()`, 6.1)를 쓰고 동기화 오차를 함께 적어야 한다. 아니면 송신 호스트 한쪽에서 관측 가능한 `srtt_us` 같은 지표로 대체한다.

## 4. Implementation Impact

### 4.1 S3 PUT 홉별 매트릭스

아래 표는 열을 **기본 배포 / 선택 옵션 / 실험·미병합**으로 나눈다. 실재하지 않는 "현대 조합"을 한 열에 섞지 않기 위해서다.

| 홉 | 프로덕션 기본 (Ceph Tentacle, Linux 6.x) | 선택 가능 (설정·빌드 옵션) | 실험·제안 단계 |
|---|---|---|---|
| RGW HTTP | Beast + Boost.Asio 스택풀 코루틴, `boost::asio::yield_context`(v19.2.1+) | `rgw_thread_pool_size`, `rgw_max_concurrent_requests` 조정 | — |
| RGW→RADOS | `AtomicObjectProcessor` → `RadosWriter`, 4 MiB 청크/스트라이프, `librados::async_operate` | 청크·스트라이프·창 크기 조정 | — |
| TCP 송신 | 일반 `sendmsg`(+`MSG_MORE`) | 커널 수준: `MSG_ZEROCOPY`(4.14), io_uring `SEND_ZC`(6.0) — Ceph는 미사용 | Ceph PR #70638 `MSG_ZEROCOPY` RFC(draft) |
| TCP 수신 | 커널 복사 수신 | 커널 수준: io_uring zcrx(6.15, 호스트 메모리), devmem TCP(6.12, dma-buf) — Ceph는 미사용 | — |
| 메신저 | AsyncMessenger + msgr2(crc/secure AES-128-GCM), msgr2.1 프레임, `ms_type=async+posix` | `ms_osd_compress_mode`(Quincy+), secure 모드, `ms_type`/`ms_cluster_type=async+rdma`(옵션 설명상 experimental 가능) | `crimson::net`(Crimson 전용) |
| OSD | Classic: `ShardedOpWQ`, `OSDShard`, `PG::lock()`, mClock(Quincy+) | 샤드·스레드 수 | Crimson: 코어당 reactor, `PGShardMapping` (Squid tech preview) |
| 저장 엔진 | BlueStore: raw 블록 + RocksDB on BlueFS | 압축, `bluestore_prefer_deferred_size_*` | SeaStore (Tentacle tech preview) |
| 사용자→커널 I/O | `KernelDevice` libaio(`io_submit`) | `bdev_ioring=true`(+`_hipri`, `_sqthread_poll`), SPDK `NVMEDevice`(`HAVE_SPDK` 빌드) | SeaStore: `seastar::file` → reactor 백엔드 |
| 블록 계층 | `blkdev_direct_IO` → `submit_bio` → blk-mq, NVMe 기본 스케줄러 `none` | 폴링 큐(`REQ_POLLED`), 스케줄러 선택 | — |
| NVMe 명령 경로 | `nvme_queue_rq()` (블록 I/O) | `/dev/ngXnY` + `IORING_OP_URING_CMD`(5.19) — Ceph는 미사용 | — |
| 장치 DMA | PRP/SGL → 호스트 DRAM, x86 기본 IOMMU lazy(`DMA-FQ`) | `iommu.passthrough=1` 또는 그룹별 identity(보안과 맞바꿈, → 12/01), nvme `poll_queues`(→ 12/02) | P2PDMA(GPU/CMB 메모리, 08/02) — S3 경로와 무관 |

### 4.2 콜패스 (Classic + BlueStore + libaio, `main`/master 기준)

```
[RGW, Beast 코루틴]
handle_connection() → process_request() → RGWPutObj::execute(y)
  └ get_data() (StreamIO::recv_body → http::async_read_some, 양보)
  └ filter->process(data, ofs) → AtomicObjectProcessor → RadosWriter::process()
       └ op.write_full()/op.write() → aio->get(..., Aio::librados_op(...))
            └ librados::async_operate(yield) → IoCtx::aio_operate()
[librados / AsyncMessenger]  msgr2 frame → PosixConnectedSocketImpl → ::sendmsg()
                                   ── TCP ──
[OSD primary, Classic]
OSD::ms_fast_dispatch() → enqueue_op() → ShardedOpWQ::_process() → dequeue_op()
  └ PrimaryLogPG::do_op() → execute_ctx() → issue_repop()
       └ ReplicatedBackend::submit_transaction()
            ├ issue_op() → MOSDRepOp → 복제본 OSD (do_repop → queue_transactions)
            └ queue_transactions() → BlueStore::queue_transactions()
                 └ _do_write() → _do_alloc_write() → _txc_state_proc()
                      STATE_PREPARE: KernelDevice::aio_submit()
                         └ aio_queue_t::submit_batch() → io_submit(2)
[kernel]
io_submit_one() → aio_write() → blkdev_write_iter() → blkdev_direct_IO()
  └ __blkdev_direct_IO_async()/__blkdev_direct_IO() → submit_bio()
       └ blk_mq_submit_bio() → __blk_mq_alloc_requests() (tag) → ->queue_rq()
            └ nvme_queue_rq() → nvme_prep_rq() → nvme_map_data()
                 └ sq_lock: nvme_sq_copy_cmd() → nvme_write_sq_db(bd->last)
[device]  DMA read(호스트 버퍼) → 매체 기록 → CQE
[완료]
nvme_irq() (배치) / nvme_poll() (poll queue) → nvme_handle_cqe()
  → nvme_pci_complete_rq() 또는 nvme_pci_complete_batch() → nvme_complete_rq() → blk_mq_end_request()
  → bio end_io → aio_complete_rw() → aio ring
  → KernelDevice::_aio_thread() → _txc_finish_io() → kv_sync_thread (RocksDB WAL 그룹 커밋)
  → kv_finalize_thread → oncommit → 복제본 커밋 응답 수집 → MOSDOpReply → RGW 코루틴 재개
```

위 콜패스에서 io_uring을 켜면(`bdev_ioring=true`) 다음 두 부분만 바뀐다. 제출은 `ioring_queue_t::submit_batch()` → `io_uring_submit()` → `io_uring_enter()` → `io_write()` → `blkdev_write_iter()`가 된다. 완료는 `io_complete_rw()` → CQE가 된다(`io_uring/rw.c`). 블록 계층 아래는 같다. Crimson + SeaStore 경로는 06/04 문서 4.1절의 콜패스를 따른다. 그 경로는 `TransactionManager::submit_transaction()` → `Journal`/`ExtentPlacementManager` → `seastar::file::dma_write()` → reactor 백엔드로 이어지고, 커널 진입 이후는 위 경로와 같다.

### 4.3 저장 I/O 경로 3종 비교 (S3 PUT의 마지막 홉에 놓일 수 있는 것)

| 항목 | 블록 경로 (`/dev/nvmeXnY`, libaio·io_uring) | NVMe 패스스루 (`/dev/ngXnY`, `IORING_OP_URING_CMD`) | SPDK 사용자 공간 드라이버 (BlueStore `NVMEDevice`) |
|---|---|---|---|
| VFS·파티션·페이지 캐시 | 거침(`O_DIRECT`면 캐시 우회) | 없음(문자 장치) | 없음 |
| bio 분할·병합, I/O 스케줄러 | 있음 | 없음(`REQ_OP_DRV_IN`/`REQ_OP_DRV_OUT`, 병합 대상 아님) | 없음 |
| blk-mq 태그·`struct request` | 있음 | **있음**(`blk_mq_alloc_request`) | 없음(자체 qpair·CID) |
| MDTS 초과 요청 | 블록 계층이 분할 | 장치 오류 | SPDK가 분할 |
| 완료 | IRQ 또는 IOPOLL | IRQ 또는 IOPOLL(`uring_cmd_iopoll`) | CQ 폴링(기본), v25.05+ PCIe interrupt 모드 |
| 권한·공유 | 파일 권한, 다수 프로세스·FS 공존 | 파일 권한 + 명령 효과 기반 비특권 허용(6.2+) | 장치 독점(같은 `shm_id` 그룹만 공유) |
| 커널 관측 | `block:*`, `nvme:*` tracepoint | `nvme:*` tracepoint | 커널에서 안 보임(`spdk_trace`, `spdk_top`) |
| Ceph 사용 | BlueStore 기본 | 사용 안 함 | `HAVE_SPDK` 빌드에서 선택 |

근거: 03/02 4.5절, 07/01·07/02, Ceph `src/blk/BlockDevice.cc`(`block_device_t::spdk` → `new NVMEDevice(...)` 확인).

### 4.4 관측성 청사진

```
[Host A: RGW]  사용자 공간 — uprobe 또는 LTTng-UST(USDT는 lttng-ust --with-sdt 빌드 시)
   uprobe: RGWPutObj::execute (맹글링 심볼, 비안정)        key = req_state* / trace id
   OpenTelemetry 스팬(WITH_JAEGER 빌드)                  key = trace id (호스트 간 전파 수단)
[Host A: kernel TCP]  tracepoint tcp:tcp_probe, tcp:tcp_retransmit_skb   key = struct sock*
   → 호스트 A 단독 지표: srtt_us, 재전송 수.  A↔B 시각 차는 PTP + bpf_ktime_get_tai_ns()에서만
[Host B: OSD]  LTTng-UST osd:ms_fast_dispatch, bluestore:transaction_*  key = reqid(name, tid)
   uprobe: KernelDevice::aio_submit(IOContext*)            key = aio_t* (iocb / user_data)
[Host B: kernel]
   libaio: syscalls:sys_enter_io_submit (tid)  |  io_uring: tp_btf/io_uring_submit_req (io_kiocb*)
   tp_btf/block_bio_queue (bio*)  — 같은 tid로 조인, merge/split은 block_bio_backmerge / block_split
   tp_btf/block_rq_issue (request*)      → inflight[rq] = {ts, dev, hctx->queue_num, tag}  (LRU_HASH)
   tp_btf/nvme_setup_cmd (request*, nvme_command*)  → qid = hctx->queue_num + 1, cid
   tp_btf/nvme_complete_rq (request*)    — IRQ·폴링·배치 완료 모두에서 발생
   tp_btf/block_rq_complete (request*)   → 지연 계산 → PERCPU_ARRAY 히스토그램 / RINGBUF 이상치
```

흔히 제안되는 계측 설계의 문제와 대안은 다음과 같다(→ 05/01, 05/02).

| 흔한 설계 | 문제 | 대안 |
|---|---|---|
| USDT `rgw:op_start`, `rados:msgr_read_frame` | Ceph에 해당 USDT 없음 | LTTng-UST(`src/tracing/*.tp`), OpenTelemetry, 또는 C++ 심볼 uprobe |
| `fentry: crimson::osd::do_replicated_op() / bluestore_write()` | `fentry`는 커널 함수 전용. `bluestore_write()`는 존재하지 않음 | 사용자 공간은 uprobe. 실제 함수는 `BlueStore::_do_write` |
| `fentry: seastar::smp::submit_to` | 템플릿/인라인이라 부착할 심볼이 안정적으로 없음 | Seastar 자체 메트릭이나 Crimson 파이프라인 단계 계측으로 대체 `[추측/미확인: 권장 계측 지점]` |
| `fentry: nvme_uring_cmd()` | 그런 함수 없음(uAPI 구조체 이름) | `nvme_ns_chr_uring_cmd` → `nvme_ns_uring_cmd` → `nvme_uring_cmd_io` |
| `rq->tag`를 하드웨어 ID로 키 사용 | hctx별 네임스페이스이고 재사용됨. 스케줄러 사용 시 디스패치 전에는 `internal_tag`만 유효 | `struct request *` 포인터, 또는 `(dev, hctx, tag)` 튜플 |
| `fexit: nvme_irq()`로 하드웨어 완료 시각 측정 | `nvme_irq`는 여러 CQE를 배치 처리. poll queue에는 IRQ 자체가 없음 | `nvme:nvme_complete_rq` / `block:block_rq_complete` |
| `PERCPU_HASH`로 시작 시각 저장 | 제출·완료 CPU가 다르면 조회 실패 | `HASH`/`LRU_HASH`. 집계만 per-CPU |
| 호스트 간 단조 시계 뺄셈 | 기준점이 달라 의미 없음 | PTP 동기 `CLOCK_TAI` + 오차 명시, 또는 단일 호스트 `srtt_us` |
| "1% 미만 오버헤드" | 근거 없음 | `kernel.bpf_stats_enabled=1`의 `run_time_ns`/`run_cnt`와 A/B 측정 |

tracepoint 이름도 커널 버전마다 다르다. `io_uring_submit_sqe`는 6.4에서 `io_uring_submit_req`로 바뀌었다. `block_rq_issue`의 TP_PROTO에서는 5.11에 `request_queue` 인자가 빠졌다. 도구는 커널 버전별 분기를 가져야 한다(→ 05/01).

### 4.5 지연 수치 대신: 홉별 지연을 재는 절차

"~15,000–25,000 µs / ~800–1,500 µs / ~15–35 µs"처럼 홉별 지연을 단정한 표는 측정 조건과 출처가 없으면 쓸 수 없다. 그런 표를 채우려면 다음 조건을 지켜 직접 측정해야 한다(→ 09/06 4.8절 함정 목록, 05/02 4.4절).

1. **단일 호스트 구간부터 잰다.** OSD 호스트 안에서 `block_rq_issue`→`block_rq_complete`(장치+드라이버), `io_submit` 진입→aio 완료(커널 I/O), `KernelDevice::aio_submit`→`_txc_finish_io`(BlueStore 데이터 I/O), `_txc_finish_io`→`oncommit`(KV 커밋) 구간을 나눈다.
2. **호스트 간 구간은 클라이언트 쪽에서 왕복으로 잰다.** RGW에서 본 RADOS op 왕복에서 OSD 내부 구간을 빼는 방식이다. 이때 두 호스트의 시계 차이는 계산에 들어가지 않는다.
3. **조건을 함께 공개한다.** 객체 크기, 복제 수(또는 EC 프로파일), `bdev_ioring` 여부, NVMe 폴링 큐, I/O 스케줄러, CPU 핀, 쓰기 사전 조건화(steady state) 여부를 적는다.
4. **프로브 비용을 따로 잰다.** 같은 부하를 프로브 없이 한 번, 프로브를 붙여 한 번 돌려 비교한다(A/B).

### 4.6 데이터패스 관련 기능 연표 (교차 프로젝트)

| 시점 | 계층 | 변화 | 근거 |
|---|---|---|---|
| Linux 3.13 (2014-01) | blk-mq | 다중 큐 블록 계층 병합 | 02/01 |
| Linux 4.14 | TCP | `MSG_ZEROCOPY` | 04/02 |
| Ceph Luminous v12 | 저장 엔진 | BlueStore가 신규 OSD의 기본 백엔드(릴리스 노트 기준). `osd_objectstore` 옵션 기본값은 Nautilus v14.2.0에서 `filestore`→`bluestore` | 06/03, Ceph `src/common/options.cc` v12.2.0/v14.2.0 직접 확인 |
| Ceph Nautilus v14.2.0 | RGW·메신저 | Beast 기본 프론트엔드, msgr2 도입 | 06/01, 06/02 |
| Linux 5.0 (2019-03) | 블록 | 레거시 `request_fn`·`queue_lock` 경로 삭제 | 02/03 |
| Linux 5.1 (2019-05) | 비동기 I/O | io_uring | 01/01 |
| Ceph Octopus v15 | BlueStore | `bluestore_ioring`(기본 false), PR #27392 | 06/03 |
| Ceph Pacific v16 | BlueStore | 옵션명 `bdev_ioring`(기본 false) | 06/03 |
| Linux 5.13 / 5.19 | NVMe | `/dev/ngXnY` / `IORING_OP_URING_CMD` 패스스루 | 03/02 |
| Linux 6.0 / 6.1 | io_uring | `SEND_ZC`, `SINGLE_ISSUER` / `DEFER_TASKRUN` | 01/02, 04/02 |
| Linux 6.2 | NVMe | 명령 효과 기반 비특권 패스스루 | 03/02, 09/03 |
| 2023-07 | Crimson | `crimson::net` 멀티샤드 연결 (PR #51916) | 06/02 |
| Linux 6.12 / 6.15 / 6.16 | TCP RX | devmem TCP RX / io_uring zcrx / devmem TCP TX | 04/02 |
| Ceph Squid v19 | Crimson | 첫 tech preview (RBD, 복제 풀) | 06/04 |
| Ceph v19.2.1 | RGW | `boost::asio::spawn`으로 복귀 (PR #55592, #60133) | 06/01 |
| Ceph Tentacle v20 | SeaStore | tech preview, Crimson과 함께 배포 가능 | 06/04 |
| 2026-07 | 메신저 | `MSG_ZEROCOPY` + PSP RFC (PR #70638, 미머지) | 06/02 |

### 4.7 남은 미확인 항목

- `bdev_ioring` 기본값을 `false`로 유지하는 공식 근거, 그리고 libaio 대비 정량 차이 `[추측/미확인]`
- Crimson/SeaStore의 프로덕션 전환 일정, 그리고 uring_cmd·FDP 사용 계획 `[추측/미확인]`
- `kv_sync_thread`가 NVMe 환경에서 실제 CPU 병목인지에 대한 공개 측정 `[추측/미확인]`
- `async+rdma` 메신저의 프로덕션 지원 범위(어느 릴리스에서 어떤 NIC로 검증됐는지), Crimson `crimson::net`의 RDMA 지원 여부 `[추측/미확인]`. RDMA 스택 자체는 13/02 참조
- IOMMU 모드(identity / lazy / strict)가 OSD 처리량에 주는 영향의 공개 측정 `[추측/미확인]`
- RGW 바디 수신에 zcrx를 쓰는 설계(헤더/데이터 분리 NIC 필요, Boost.Asio 소켓과의 통합 방식) — 제안 자체를 찾지 못함 `[추측/미확인]`

## 5. Primary References

- [usenix.org - I/O Passthru: Upstreaming a flexible and efficient I/O Path in Linux (FAST '24)](https://www.usenix.org/conference/fast24/presentation/joshi) — 패스스루의 blk-mq 사용, SPDK 대비 측정 (03/02)
- [dl.acm.org - File systems unfit as distributed storage backends: lessons from 10 years of Ceph evolution (SOSP '19)](https://dl.acm.org/doi/10.1145/3341301.3359656) — FileStore→BlueStore 근거 (06/03). 같은 저자의 ;login: 요약본(아래)으로 내용을 교차 확인할 수 있다.
- [usenix.org - File Systems Unfit as Distributed Storage Back Ends: Lessons from 10 Years of Ceph Evolution (;login: Spring 2020, PDF)](https://www.usenix.org/system/files/login/articles/spring20_02_aghayev.pdf) (06/03)
- [docs.ceph.com - Squid](https://docs.ceph.com/en/latest/releases/squid/) — "Crimson’s first tech preview release!" (06/04)
- [docs.ceph.com - Tentacle](https://docs.ceph.com/en/latest/releases/tentacle/) — "SeaStore Tech Preview" (06/04)
- [docs.ceph.com - msgr2 protocol (msgr2.0 and msgr2.1)](https://docs.ceph.com/en/latest/dev/msgr2/) — 프레임·secure 모드 (06/02)
- [docs.ceph.com - BlueStore Configuration Reference](https://docs.ceph.com/en/latest/rados/configuration/bluestore-config-ref/) (06/03)
- [github.com/ceph/ceph - src/blk/kernel/io_uring.cc](https://github.com/ceph/ceph/blob/main/src/blk/kernel/io_uring.cc) — `ioring_queue_t`, `sq_mutex` (직접 확인)
- [github.com/ceph/ceph - src/blk/kernel/KernelDevice.cc](https://github.com/ceph/ceph/blob/main/src/blk/kernel/KernelDevice.cc) — `bdev_ioring*`, libaio 폴백 (직접 확인)
- [github.com/ceph/ceph - src/rgw/driver/rados/rgw_putobj_processor.cc](https://github.com/ceph/ceph/blob/main/src/rgw/driver/rados/rgw_putobj_processor.cc) — `RadosWriter::process` (직접 확인)
- [github.com/ceph/ceph - crimson/net: support connections in multiple shards (PR #51916)](https://github.com/ceph/ceph/pull/51916) (06/02)
- [github.com/ceph/ceph - msg/async: MSG_ZEROCOPY send path + PSP secure-mode scaffolding (RFC) (PR #70638)](https://github.com/ceph/ceph/pull/70638) (06/02)
- [github.com/ceph/ceph - os/bluestore: introduce new io_uring IO engine (PR #27392)](https://github.com/ceph/ceph/pull/27392) (06/03)
- [github.com/torvalds/linux - drivers/nvme/host/ioctl.c](https://github.com/torvalds/linux/blob/master/drivers/nvme/host/ioctl.c) — `nvme_uring_cmd_io`, `nvme_alloc_user_request` (03/02)
- [github.com/torvalds/linux - block/fops.c](https://github.com/torvalds/linux/blob/master/block/fops.c) — `blkdev_direct_IO` (직접 확인)
- [kernel.org - Multi-Queue Block IO Queueing Mechanism (blk-mq)](https://www.kernel.org/doc/html/latest/block/blk-mq.html) (02/01)
- [kernel.org - MSG_ZEROCOPY](https://www.kernel.org/doc/html/latest/networking/msg_zerocopy.html) (04/02)
- [kernel.org - Device Memory TCP](https://www.kernel.org/doc/html/latest/networking/devmem.html) (04/02)
- [kernel.org - io_uring zero copy Rx](https://www.kernel.org/doc/html/latest/networking/iou-zcrx.html) (04/02)
- [github.com/torvalds/linux - drivers/nvme/host/trace.h](https://github.com/torvalds/linux/blob/master/drivers/nvme/host/trace.h) — `nvme_setup_cmd`, `nvme_complete_rq` (05/02)
- [github.com/torvalds/linux - include/trace/events/block.h](https://github.com/torvalds/linux/blob/master/include/trace/events/block.h) (05/02)
- [github.com/ceph/ceph - src/tracing (LTTng-UST tracepoint 정의)](https://github.com/ceph/ceph/tree/main/src/tracing) (05/02)
- [github.com/ceph/ceph - src/common/options/global.yaml.in](https://github.com/ceph/ceph/blob/main/src/common/options/global.yaml.in) — `ms_type`(`async+posix` 기본, `async+rdma`), `bluefs_buffered_io` (직접 확인)
- [github.com/ceph/ceph - src/os/bluestore/BlueFS.cc](https://github.com/ceph/ceph/blob/main/src/os/bluestore/BlueFS.cc) — `_flush_range_F()`의 `bluefs_buffered_io`·envelope 모드 분기 (직접 확인)
- [github.com/ceph/ceph - src/msg/async/rdma/RDMAStack.h](https://github.com/ceph/ceph/blob/main/src/msg/async/rdma/RDMAStack.h) — `RDMAStack`, `RDMAWorker` (직접 확인)
- [docs.ceph.com - D3N RGW Data Cache](https://docs.ceph.com/en/latest/radosgw/d3n_datacache/) — RGW 로컬 읽기 캐시
- [github.com/torvalds/linux - nvme-pci: clamp max_hw_sectors based on DMA optimized limitation (commit 3710e2b056cb)](https://github.com/torvalds/linux/commit/3710e2b056cb) (12/01)
- [kernel.org - Affinity managed interrupts](https://docs.kernel.org/core-api/irq/managed_irq.html) (12/02)
- [lwn.net - Ringing in a new asynchronous I/O API](https://lwn.net/Articles/776703/) (01/01)
- [lwn.net - The multiqueue block layer](https://lwn.net/Articles/552904/) (02/01)
