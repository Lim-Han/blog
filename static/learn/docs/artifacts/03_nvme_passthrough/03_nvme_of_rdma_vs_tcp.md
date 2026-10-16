# NVMe-oF 전송 계층: nvme-rdma vs nvme-tcp, 그리고 TLS·인증·수신 오프로드

> 기준 소스: Linux 7.3-rc7 (`torvalds/linux` master, 2026-10 확인) `drivers/nvme/host/{tcp.c,rdma.c,fabrics.c,auth.c}`, `drivers/nvme/target/{tcp.c,rdma.c,io-cmd-bdev.c}`. 메일링 리스트 인용은 LWN 패치 미러, lists.infradead.org, lkml.iu.edu 아카이브에서 원문과 Message-ID를 확인했다.

## 1. Verdict

NVMe-oF의 리눅스 구현은 2016년 RDMA(`nvme-rdma`/`nvmet-rdma`)로 시작했다. 2018년 말 Sagi Grimberg(당시 Lightbits Labs)가 TCP 전송(`nvme-tcp`/`nvmet-tcp`)을 올렸고, 이것이 5.0에 들어갔다. 두 전송은 경쟁 관계라기보다 **역할 분담**에 가깝다.

- **RDMA**는 데이터 이동을 NIC이 RDMA READ/WRITE로 직접 처리한다. 그래서 호스트의 데이터 경로에 복사가 없고 CPU 소비가 가장 적다. 대가로 RDMA 지원 NIC이 필요하고, RoCEv2는 실무상 PFC/ECN 같은 혼잡·손실 제어를 정밀하게 설정해야 한다. "RoCEv2는 L2에 한정되어 L3 라우팅이 불가능하다"는 흔한 설명은 **틀렸다.** RoCEv2는 IB 전송 헤더를 UDP/IP(목적지 포트 4791)에 싣는 방식이라 IP 라우팅이 된다. L2에 묶이는 것은 RoCE v1이다. 운영 난이도의 실체는 라우팅이 아니라 손실 민감도다.
- **TCP**는 어떤 이더넷에서나 돈다. 대신 수신 측에서 소켓 버퍼 → 블록 버퍼 복사(`skb_copy_datagram_iter()`)와 선택적 CRC32C 다이제스트 계산을 CPU가 맡는다. 송신은 `MSG_SPLICE_PAGES`로 페이지를 참조로 넘긴다(6.5에서 `kernel_sendpage()`가 이것으로 대체됨).

이후의 발전은 대부분 TCP 쪽에서 일어났다. DH-HMAC-CHAP 인밴드 인증(6.0), TLS 1.3 PSK 기반 암호화(6.7, `tlshd` 사용자 공간 핸드셰이크)가 들어왔다. **NVMe-TCP 수신 DDP 오프로드**는 2025년 7월 v30까지 제출됐지만, **7.3-rc7 master에는 병합되지 않았다**(`drivers/nvme/host/tcp.c`에 `ulp_ddp` 참조 없음). TCP 전송이 RDMA 대비 몇 % 효율인지, 전송별 추가 지연이 몇 µs인지에 대한 1차 출처 수치는 찾지 못했다 `[추측/미확인]`. 또 "CRC32-NI"라는 명령어 집합은 없다. x86의 CRC32C 가속은 SSE4.2 `crc32` 명령이며, 커널은 `crc32c()` 라이브러리로 이를 쓴다.

---

## 2. Problem Statement

### 2.1 로컬 NVMe를 네트워크 너머로
NVMe-oF는 NVMe 큐 모델(SQ/CQ 쌍, 명령 캡슐, 완료 캡슐)을 네트워크로 확장한다. 각 NVMe I/O 큐가 전송 연결 하나(RDMA QP 또는 TCP 소켓)에 대응한다. 목표는 로컬 PCIe 대비 추가 지연과 CPU 소비를 최소화하는 것이다. 이를 위해 (a) 데이터 복사, (b) 컨텍스트 전환·락 경합, (c) 무결성 검사(다이제스트) 비용을 줄여야 한다.

### 2.2 RDMA의 장점과 비용
- **데이터 경로**: 호스트는 명령 캡슐에 자기 메모리의 SGL(주소 + rkey)을 실어 SEND로 보낸다. 타깃 NIC은 쓰기면 RDMA READ로 호스트 메모리에서 데이터를 당겨 오고, 읽기면 RDMA WRITE로 호스트 메모리에 직접 넣는다. 호스트 CPU는 데이터를 만지지 않는다.
- **비용 1: 메모리 등록.** 원격 접근을 허용하려면 MR(memory region)을 등록해야 한다. `nvme-rdma`는 기본(`register_always=true`)으로 I/O마다 fast registration(`IB_WR_REG_MR`)을 하고, 완료 후 invalidate한다(`IB_WR_LOCAL_INV` 또는 타깃의 SEND_WITH_INV). 이 작업 요청들이 I/O당 오버헤드가 된다.
- **비용 2: 패브릭.** RoCEv2는 패킷 손실 시 go-back-N 재전송으로 성능이 급락하기 쉽다. 그래서 PFC로 무손실을 만들거나 ECN 기반 혼잡 제어(DCQCN 등)를 정밀하게 조정해야 한다. PFC는 pause 프레임 전파로 head-of-line blocking이나 교착을 일으킬 위험이 있다는 것이 업계에 알려진 우려다. 다만 그 빈도나 영향 규모에 대한 정량 자료는 이 문서에서 검증하지 못했다 [추측/미확인]. InfiniBand는 자체 크레딧 기반 흐름 제어를 쓴다.

### 2.3 TCP의 구조적 비용
- **바이트 스트림 파싱**: TCP에는 메시지 경계가 없다. 수신 측은 PDU 공통 헤더(`struct nvme_tcp_hdr`: `type`, `flags`, `hlen`, `pdo`, `plen`)를 읽어 다음 PDU의 경계를 찾아야 한다. 패킷 손실·재정렬이 있어도 TCP가 순서를 보장하므로 정확성 문제는 없고, 비용은 CPU 쪽에 쌓인다.
- **수신 복사**: NIC은 도착한 바이트가 어느 I/O의 데이터인지 모른다. 그래서 데이터가 일단 skb로 들어오고, 드라이버가 C2H Data PDU의 `command_id`로 `struct request`를 찾은 뒤 `skb_copy_datagram_iter()`로 bio 페이지에 복사한다. 데이터 다이제스트를 켜면 `skb_copy_and_crc32c_datagram_iter()`로 복사와 CRC 계산을 한 번에 한다.
- **혼잡 제어**: 일반 TCP 혼잡 제어(Cubic, BBR 등)와 손실 복구를 그대로 쓴다. 손실이 있는 일반 이더넷에서도 동작하는 이유가 이것이다. 대신 꼬리 지연이 TCP 재전송 타이머의 영향을 받는다.

### 2.4 보안 요구
iSCSI의 CHAP처럼, 패브릭 스토리지에는 호스트/컨트롤러 상호 인증과 전송 암호화가 필요하다. NVMe 사양은 DH-HMAC-CHAP 인밴드 인증과 NVMe/TCP용 TLS를 정의했다(각각 TP 8006, TP 8011로 알려져 있으나 사양 원문으로 확인하지 못함 [추측/미확인]). 리눅스는 이를 각각 6.0과 6.7에서 구현했다. RDMA 전송에는 사양 수준의 전송 암호화가 없고, 인밴드 인증만 공통으로 쓸 수 있다.

---

## 3. The Debate

아래는 원문을 확인한 발언이다.

### 3.1 2018년 11월: "every Ethernet port in the world"
Grimberg의 첫 시리즈 "[PATCH 00/11] TCP transport binding for NVMe over Fabrics"는 2018-11-15에 올라왔다(Message-ID `20181115171626.9306-1-sagi@lightbitslabs.com`, LWN 미러로 확인).

> "This patch set implements the NVMe over Fabrics TCP host and the target drivers. Now NVMe over Fabrics can run on every Ethernet port in the world."
>
> — Sagi Grimberg, 2018-11-15 ([LWN 미러](https://lwn.net/Articles/772556/))

같은 커버 레터가 설계 원칙도 밝힌다.

> "All NVMe queues are sharded over a private bound workqueue such that we always have a single context handling the byte stream and we don't need to worry about any locking/serialization. In addition, close attention was paid to a completely non-blocking data plane to minimize context switching and/or unforced scheduling."
>
> — Sagi Grimberg, 2018-11-15 (같은 메일)

이 문장이 지금까지 `nvme-tcp`/`nvmet-tcp` 구조의 뼈대다. 큐마다 `io_work`라는 work item이 하나 있고, 이것이 특정 CPU(`io_cpu`)에 묶인 workqueue에서 돌며 송수신을 모두 처리한다. 타깃이 "CPU별 작업자 풀에서 epoll/kthread로 다중 큐를 감시"한다는 설명은 틀렸다. 실제로는 소켓 콜백 `sk_data_ready`가 `queue_work_on()`으로 `io_work`를 깨우는 구조다. 시리즈 1~3번 패치는 netdev에 "online digest calculation" 헬퍼(`skb_copy_and_hash_datagram_iter`)를 추가하는 것이었다. 지금은 `skb_copy_and_crc32c_datagram_iter()`로 바뀌어 수신 복사와 CRC32C 계산을 한 번의 순회로 처리한다. v5(`20181204015217.16613-1-sagi@grimberg.me`, 2018-12-03)를 거쳐 5.0에 병합되었다.

### 3.2 RDMA vs TCP: 실제 쟁점은 무엇이었나
메일링 리스트에서 "RDMA를 대체해야 한다"는 식의 진영 대립은 확인되지 않았다. 커버 레터의 근거는 보편성(어디서나 돈다)과 단순성이었다. RDMA 쪽 개발자(Grimberg 자신도 nvme-rdma 메인테이너다)가 TCP 전송을 만든 것이므로, 대립보다는 "RDMA 하드웨어가 없는 환경을 위한 두 번째 전송"으로 보는 편이 정확하다. 실제 기술 논쟁은 다음 두 지점에서 벌어졌다.
- **데이터 다이제스트 비용**: 다이제스트를 켜면 CPU가 모든 데이터 바이트에 CRC32C를 돌린다. 그래서 `hdr_digest`/`data_digest`는 기본값이 꺼짐인 fabrics 옵션으로 남았다. 데이터 무결성은 TCP 체크섬과 링크 계층 CRC에 맡기는 것이 기본이다.
- **송신 제로카피의 안전성**: 페이지를 참조로 넘기려면 그 페이지가 전송 완료 전까지 바뀌지 않고, slab 페이지가 아니어야 한다. 드라이버는 `sendpages_ok()`가 거짓이면 `MSG_SPLICE_PAGES`를 빼고 복사 송신으로 떨어진다. 6.5 이전에는 같은 판단을 `sendpage_ok()` + `kernel_sendpage()`로 했다. David Howells의 "splice, net: Replace sendpage with sendmsg(MSG_SPLICE_PAGES)" 작업이 `->sendpage` 연산 자체를 없애면서 nvme-tcp도 `sock_sendmsg()` + `MSG_SPLICE_PAGES`로 옮겨 갔다. `sock_alloc_send_pskb()`는 skb 할당 함수일 뿐 nvme-tcp의 제로카피 송신과는 무관하다.

### 3.3 TLS: 커널 TLS 레코드 계층 + 사용자 공간 핸드셰이크
Hannes Reinecke(SUSE)의 "nvme: In-kernel TLS support for TCP"는 RFC(2023-03 `[추측/미확인]`)부터 v11(`20230824143925.9098-1-hare@suse.de`, 2023-08-24)까지 진행되어 6.7에 들어갔다. 핵심 설계 결정은 TLS 핸드셰이크를 커널에 넣지 않는 것이었다.

> "with the merge of Chuck Levers handshake upcall mechanism and my tls_read_sock() implementation finally merged with net-next it's now time to restart on the actual issue, namely implementing in-kernel TLS support for nvme-tcp. ... It also requires the 'tlshd' userspace daemon (https://github.com/oracle/ktls-utils) for the actual TLS handshake."
>
> — Hannes Reinecke, 2023-08-24 ([LWN 미러](https://lwn.net/Articles/942817/))

즉 레코드 암복호화는 kTLS(`net/tls`)가 커널에서 하고, 핸드셰이크만 net/handshake 업콜(`tls_client_hello_psk()`)로 사용자 공간 `tlshd`에 위임한다. PSK는 전용 `.nvme` keyring에 둔다. 그 결과 TLS 큐에서는 `nvme_tcp_queue_request()`가 제출 CPU에서 바로 보내는 인라인 송신을 하지 않는다. 소스 주석은 kTLS의 `tx_lock`과 blk-mq `set->srcu` 사이의 lockdep 순환 경고를 이유로 들며, 송신을 `io_work`로 미룬다.

### 3.4 인밴드 인증(DH-HMAC-CHAP)
같은 Reinecke의 "nvme: In-band authentication support" v12(`20220518112234.24264-1-hare@suse.de`, 2022-05-18)가 6.0에 들어갔다. 커버 레터는 "it provides some real benefit especially for NVMe-TCP"라고 동기를 밝힌다. 동시에 당시에는 secure concatenation(협상된 파라미터로 TLS 시작)이 커널 TLS 핸드셰이크 부재로 불가능하다고 적었다. 현재 master의 `host/auth.c`에는 `opts->concat` 경로와 `nvme_tls_psk_refresh()`가 있어, DH-HMAC-CHAP 결과로 TLS PSK를 만들어 갱신하는 secure concatenation이 구현되어 있다(Linux 6.15에서 도입: v6.14 `host/auth.c`에 `nvme_tls_psk_refresh`/`opts->concat` 없음, v6.15에 있음).

### 3.5 수신 DDP 오프로드: v30까지 왔지만 미병합
NVIDIA(Aurelien Aptel, Shai Malin, Boris Pismenny 등)의 "nvme-tcp receive offloads"는 NIC이 TCP 스트림 안에서 NVMe-TCP PDU를 추적하게 한다. 그래서 (1) skb → 블록 버퍼 복사와 (2) 수신 CRC 검증을 하드웨어가 맡는다. 네트워크 스택 전체를 오프로드하는 TOE가 아니라 kTLS 장치 오프로드(`net/tls/tls_device.c`)와 같은 "TCP와 협업하는" 방식이라는 점을 커버 레터가 강조한다. v30 커버 레터(2025-07-15, ConnectX-7, Xeon Platinum 8380, fio qd=128·jobs=8)가 밝힌 수치는 다음과 같다.

| 조건 | 오프로드 없음 | 오프로드 | 개선 |
|---|---|---|---|
| 다이제스트 없음, 64K 읽기 | 84 Gbps | 111 Gbps | 최대 32% |
| 다이제스트 없음, 512K 읽기 | 98 Gbps | 148 Gbps | 최대 55% |
| 데이터 다이제스트, 64K 읽기 | 53 Gbps | 111 Gbps | 최대 107% |
| 데이터 다이제스트, 512K 읽기 | 61 Gbps | 146 Gbps | 최대 138% |

같은 문서에 "With small IOs we are not expecting that the offload will show a performance gain."이라는 단서가 있고, 오프로드는 `io_threshold`보다 큰 I/O에만 쓰인다. 2025-07-31 Aptel이 리뷰를 재촉하자 netdev 메인테이너 Jakub Kicinski는 "What thoughts do you expect me to have?"라고만 답했다(`20250731072033.030866c4@kernel.org`). 이 메일은 기술적 합의가 아니라 진척이 없음을 보여 준다. 또 이 시리즈는 page pool 기반 수신 제로카피와는 무관하다.

---

## 4. Implementation Impact

### 4.1 nvme-tcp 호스트 (`drivers/nvme/host/tcp.c`)
```
blk-mq: nvme_tcp_queue_rq(hctx, bd)
 ├ nvme_tcp_setup_cmd_pdu()         # 명령 캡슐 PDU 구성, (in-capsule data 가능 시) 데이터 동봉
 └ nvme_tcp_queue_request(req, last)
    ├ llist_add(&req->lentry, &queue->req_list)
    ├ [io_cpu == 현재 CPU && !TLS && 큐가 비어 있음 && mutex_trylock(send_mutex)]
    │     → nvme_tcp_send_all()     # 제출 컨텍스트에서 바로 송신
    └ [last && pending] → queue_work_on(queue->io_cpu, nvme_tcp_wq, &queue->io_work)

nvme_tcp_io_work()                  # 1ms 예산 루프
 ├ mutex_trylock(send_mutex) → nvme_tcp_try_send()
 │     └ nvme_tcp_try_send_cmd_pdu / _data / _data_pdu / _ddgst
 │          sock_sendmsg(MSG_DONTWAIT | MSG_SPLICE_PAGES [| MSG_MORE / MSG_EOR])
 ├ nvme_tcp_try_recv() → sock->ops->read_sock(sk, &rd_desc, nvme_tcp_recv_skb)
 │     └ PDU 헤더 → nvme_tcp_handle_c2h_data / handle_r2t / process_nvme_cqe
 │        데이터 → skb_copy_datagram_iter() 또는 skb_copy_and_crc32c_datagram_iter()
 └ 예산 소진 시 자기 자신을 다시 queue_work_on()

소켓 콜백: sk_data_ready = nvme_tcp_data_ready, sk_write_space = nvme_tcp_write_space
          → 둘 다 queue_work_on(io_cpu, nvme_tcp_wq, &queue->io_work)
```
- **CPU 배치**: `nvme_tcp_set_queue_io_cpu()`는 blk-mq 매핑(`HCTX_TYPE_DEFAULT`/`READ`/`POLL`)을 보고 큐마다 CPU를 고른다. 이때 이미 큐가 가장 적게 배정된 CPU를 우선한다. 모듈 파라미터 `wq_unbound=Y`이면 unbound workqueue로 바꿔 sysfs에서 affinity를 조정할 수 있다.
- **소켓 우선순위**: `so_priority` 모듈 파라미터가 `SO_PRIORITY`를 설정해 NIC의 ADQ 같은 최적화를 유도한다.
- **쓰기 흐름 제어**: 큰 쓰기는 타깃이 R2T PDU로 "이 오프셋부터 이만큼 보내라"고 허락한 범위만 H2C Data PDU로 보낸다(`nvme_tcp_handle_r2t()`). 작은 쓰기는 in-capsule data로 명령과 함께 보낸다.
- **폴링**: `nr_poll_queues` fabrics 옵션으로 poll 큐를 만들면 `nvme_tcp_poll()`이 소켓에서 직접 수신을 돈다(busy poll 가능 시 `sk_busy_loop()`).
- **오류 복구**: 연결 오류 시 `err_work` → 재연결(`reconnect_delay`), `ctrl_loss_tmo` 만료 시 컨트롤러 삭제, `fast_io_fail_tmo` 만료 시 대기 중 I/O 실패 처리. 멀티패스 헤드가 있으면 이것이 failover로 이어진다(→ 03/01, 4.4절).

### 4.2 nvmet-tcp 타깃 (`drivers/nvme/target/tcp.c`)
```
sk_data_ready = nvmet_tcp_data_ready → queue_work_on(queue_cpu(queue), nvmet_tcp_wq, &queue->io_work)
nvmet_tcp_wq = alloc_workqueue("nvmet_tcp_wq", WQ_MEM_RECLAIM | WQ_HIGHPRI | WQ_PERCPU, 0)

nvmet_tcp_io_work()
 do {
   nvmet_tcp_try_recv(queue, NVMET_TCP_RECV_BUDGET=8, &ops)
     └ nvmet_tcp_try_recv_pdu() → nvmet_tcp_done_recv_pdu() → nvmet_req_init()
        → req->execute() = nvmet_bdev_execute_rw()   # bdev 백엔드: bio 구성, blk_start_plug, submit_bio
       (H2C 데이터: nvmet_tcp_handle_h2c_data_pdu())
   nvmet_tcp_try_send(queue, NVMET_TCP_SEND_BUDGET=8, &ops)
     └ nvmet_setup_c2h_data_pdu()   # 읽기 응답 데이터 PDU
       nvmet_setup_r2t_pdu()        # 쓰기 데이터 요청
       nvmet_setup_response_pdu()   # 완료 캡슐
       sock_sendmsg(MSG_DONTWAIT | MSG_SPLICE_PAGES ...)
 } while (pending && ops < NVMET_TCP_IO_WORK_BUDGET=64)
 재큐잉: idle 폴링 기간 중이거나 pending이면 다시 queue_work_on()
```
`nvmet_tcp_read_pdu()`, `nvmet_bdev_execute_bio()`, `nvmet_tcp_send_ddgst()` 같은 이름은 존재하지 않는다. 또 `nvmet_setup_c2h_data_pdu()`는 커맨드 디스패치가 아니라 **읽기 응답 데이터 PDU를 만드는** 함수다. 모듈 파라미터 `idle_poll_period_usecs`(기본 0)를 주면 큐가 비어도 그 시간만큼 `io_work`가 계속 폴링한다. 인터럽트 조정(coalescing)이 강한 NIC에서 지연을 줄이는 선택지다.

### 4.3 nvme-rdma 호스트 (`drivers/nvme/host/rdma.c`)
- 연결: `rdma_create_id(..., RDMA_PS_TCP, IB_QPT_RC)` → `rdma_resolve_addr()`. 큐마다 RC QP 하나를 쓴다. CQ는 일반 큐면 `ib_cq_pool_get(..., IB_POLL_SOFTIRQ)`, poll 큐면 `ib_alloc_cq(..., IB_POLL_DIRECT)`로 만들고, `nvme_rdma_poll()`이 `ib_process_cq_direct()`를 호출한다.
- 데이터 매핑 `nvme_rdma_map_data()`의 분기는 다음과 같다. ① PI가 있으면 `nvme_rdma_map_sg_pi()`(`IB_WR_REG_MR_INTEGRITY`). ② 세그먼트 수가 `num_inline_segments` 이하인 I/O 큐 쓰기이고 크기가 inline 한도 이하면 `nvme_rdma_map_sg_inline()`으로 데이터를 SEND에 동봉한다(메모리 등록 없음). ③ 단일 세그먼트이고 PD에 `IB_PD_UNSAFE_GLOBAL_RKEY`가 있으면(`register_always=N`일 때만) `nvme_rdma_map_sg_single()`. ④ 그 밖에는 `nvme_rdma_map_sg_fr()`로 `ib_map_mr_sg()` + `IB_WR_REG_MR` fast registration을 한다.
- 완료: 응답에 `IB_WC_WITH_INVALIDATE`가 있으면 타깃이 원격 invalidate를 해 준 것이다. 없으면 `nvme_rdma_inv_rkey()`로 `IB_WR_LOCAL_INV`를 보낸다.
- 타깃(`nvmet-rdma`)은 `rdma_rw_ctx_init()`/`rdma_rw_ctx_post()`로 RDMA READ/WRITE를 구성한다. 선택적으로 SRQ(`use_srq`)를 써서 수신 버퍼를 큐 간에 공유한다.

### 4.4 비교표: 전송별 데이터 경로

| 항목 | nvme-rdma (RoCEv2/IB/iWARP) | nvme-tcp | nvme-tcp + TLS (6.7+) |
|---|---|---|---|
| 네트워크 요건 | RDMA NIC. RoCEv2는 UDP/IP로 L3 라우팅 가능하나 손실에 민감(PFC/ECN 조정) | 일반 이더넷·IP | 동일 |
| 호스트 쓰기 데이터 | inline SEND 또는 타깃의 RDMA READ | in-capsule 또는 R2T 후 H2C Data PDU, `MSG_SPLICE_PAGES` | kTLS 암호화로 페이지 참조 송신 이점 감소 |
| 호스트 읽기 데이터 | 타깃의 RDMA WRITE로 bio 페이지에 직접 | C2H Data PDU를 skb에서 bio로 복사 | 복호화 후 복사 |
| I/O당 추가 작업 | MR 등록·invalidate WR (inline·global rkey 예외) | PDU 헤더 파싱, 선택적 CRC32C | 위 + 레코드 암복호화 |
| 실행 컨텍스트 | CQ softirq 또는 poll 큐 | 큐별 `io_work`(CPU 고정 workqueue) | 동일, 단 인라인 송신 없음 |
| 무결성 | IB/RoCE ICRC | TCP 체크섬 + 선택적 `hdr_digest`/`data_digest` | TLS AEAD |
| 암호화 | 없음(사양상) | 없음 | TLS 1.3 PSK, `tlshd` 핸드셰이크 |
| 인증 | DH-HMAC-CHAP (6.0+) | DH-HMAC-CHAP (6.0+) | DH-HMAC-CHAP + secure concatenation |
| 수신 오프로드 | NIC의 RDMA 자체 | 없음 (DDP 시리즈 미병합) | kTLS 장치 오프로드는 별개 |

### 4.5 연표

| 버전/날짜 | 내용 |
|---|---|
| 4.8 (2016) | NVMe-oF 호스트/타깃, RDMA 전송 |
| 2018-11-15 | Grimberg, nvme-tcp 첫 패치 시리즈 (`20181115171626.9306-1-sagi@lightbitslabs.com`) |
| 5.0 | nvme-tcp / nvmet-tcp 병합 |
| 6.0 | DH-HMAC-CHAP 인밴드 인증 |
| 6.5 | `->sendpage` 제거, `MSG_SPLICE_PAGES`로 전환 |
| 6.7 | nvme-tcp TLS (handshake upcall + `tlshd`) |
| 6.15 | DH-HMAC-CHAP secure concatenation (`nvme_tls_psk_refresh()`) |
| 2025-07 | 수신 DDP 오프로드 v30 제출, 7.3-rc7 기준 미병합 |

4.8 도입은 릴리스 태그로 확인했다(v4.7에 `drivers/nvme/host/rdma.c` 없음, v4.8에 있음). secure concatenation은 Linux 6.15에 들어왔다(3.4절).

### 4.6 운영 판단
- RDMA NIC과 잘 관리된 패브릭이 이미 있으면 nvme-rdma가 CPU 효율에서 유리하다. 특히 큰 읽기는 호스트 복사가 없다.
- 범용 데이터센터 네트워크, 클라우드 VM, 멀티테넌트 환경은 nvme-tcp가 현실적이다. CPU 비용은 `io_cpu` 배치, poll 큐, `so_priority`/ADQ, 큰 I/O 위주 튜닝으로 관리한다.
- 데이터 다이제스트는 CPU 비용이 크다. DDP 커버 레터의 수치에서도 다이제스트 유무에 따라 소프트웨어 처리량이 84→53 Gbps(64K)로 떨어졌다. 필요할 때만 켜는 것이 기본이다.
- 보안 요구가 있으면 TCP+TLS(+DH-HMAC-CHAP)가 현재 메인라인에서 전송 암호화를 제공하는 유일한 NVMe-oF 전송이다.

---

## 5. Primary References

lore.kernel.org는 봇 차단으로 자동 검증이 안 된다. 아래 lore 링크의 Message-ID·작성자·날짜는 LWN 미러, lists.infradead.org, lkml.iu.edu 아카이브의 헤더와 대조했다.

- [TCP transport binding for NVMe over Fabrics](https://lwn.net/Articles/772556/) — Sagi Grimberg, 2018-11-15 커버 레터 LWN 미러, `20181115171626.9306-1-sagi@lightbitslabs.com`
- [[PATCH v5 00/13] TCP transport binding for NVMe over Fabrics](https://lore.kernel.org/all/20181204015217.16613-1-sagi@grimberg.me/) — Sagi Grimberg, 2018-12-03
- [nvme: In-kernel TLS support for TCP](https://lwn.net/Articles/942817/) — Hannes Reinecke, v11 커버 레터 LWN 미러, 2023-08-24
- [[PATCHv12 00/11] nvme: In-band authentication support](https://lore.kernel.org/all/20220518112234.24264-1-hare@suse.de/) — Hannes Reinecke, 2022-05-18
- [splice, net: Replace sendpage with sendmsg(MSG_SPLICE_PAGES)](https://lwn.net/Articles/928019/) — David Howells의 `->sendpage` 제거 시리즈 LWN 미러
- [nvme-tcp receive offloads](https://lwn.net/Articles/951323/) — Aurelien Aptel, v19 LWN 미러, 2023-11-14
- [[PATCH v30 00/20] nvme-tcp receive offloads](https://lore.kernel.org/all/20250715132750.9619-1-aaptel@nvidia.com/) — Aurelien Aptel, 2025-07-15
- [Re: [PATCH v30 00/20] nvme-tcp receive offloads](https://lore.kernel.org/all/20250731072033.030866c4@kernel.org/) — Jakub Kicinski, 2025-07-31 짧은 답장
- [drivers/nvme/host/tcp.c](https://github.com/torvalds/linux/blob/master/drivers/nvme/host/tcp.c) — nvme-tcp 호스트 (GitHub 미러)
- [drivers/nvme/target/tcp.c](https://github.com/torvalds/linux/blob/master/drivers/nvme/target/tcp.c) — nvmet-tcp 타깃 (GitHub 미러)
- [drivers/nvme/host/rdma.c](https://github.com/torvalds/linux/blob/master/drivers/nvme/host/rdma.c) — nvme-rdma 호스트 (GitHub 미러)
- [NVMe Subsystem](https://docs.kernel.org/nvme/index.html) — 커널 공식 NVMe 문서 색인
