# TCP 제로카피의 진화: MSG_ZEROCOPY, MSG_SPLICE_PAGES, io_uring SEND_ZC, devmem TCP, io_uring zcrx

> 기준: Linux 메인라인 `master`(2026-10 확인). `net/ipv4/tcp.c`, `net/core/skbuff.c`, `net/core/datagram.c`, `io_uring/net.c`, `io_uring/zcrx.c`, `include/uapi/linux/io_uring.h`, `Documentation/networking/{msg_zerocopy,devmem,iou-zcrx}.rst`를 grep으로 확인했다. 병합 시점은 GitHub의 torvalds/linux 커밋 메타데이터로 확인했다.

## 1. Verdict

스토리지 노드 간 복제, NVMe/TCP, 오브젝트 게이트웨이처럼 수 GB/s를 소켓으로 밀어내는 워크로드에서 `copy_from_user()`/`copy_to_user()`는 CPU 사이클과 메모리 대역폭을 동시에 소모한다. 리눅스는 이 비용을 송신·수신 양쪽에서 단계적으로 제거해 왔다.

- **송신, 소켓 API**: Willem de Bruijn(Google)의 `MSG_ZEROCOPY`가 2017년 8월 net-next에 병합되어 Linux 4.14에 들어갔다(TCP 우선, 이후 UDP·VSOCK). 사용자 페이지 참조를 skb frag에 직접 연결하고, 완료는 소켓 에러 큐로 통지한다. 커널 문서는 이 방식이 "free lunch"가 아니며 대략 10 KB 이상 쓰기에서만 효과적이라고 명시한다.
- **송신, 커널 내부 API**: 6.5에서 David Howells가 `->sendpage()`를 제거하고 `sendmsg()` + `MSG_SPLICE_PAGES`로 일원화했다. 커널 내 스토리지 클라이언트(nvme-tcp, iSCSI, Ceph 커널 클라이언트 등)의 페이지 전송 경로가 이 플래그로 바뀌었다.
- **송신, io_uring**: Pavel Begunkov의 `IORING_OP_SEND_ZC`가 Linux 6.0(병합 태그명 `for-5.20`)에, `IORING_OP_SENDMSG_ZC`가 Linux 6.1에 들어갔다. 에러 큐 대신 **CQE 두 개**를 쓴다: 첫 CQE는 송신 결과(`IORING_CQE_F_MORE` 설정), 이후 버퍼를 재사용해도 되는 시점에 `IORING_CQE_F_NOTIF`가 설정된 알림 CQE가 온다. 등록 버퍼(`IORING_RECVSEND_FIXED_BUF`)를 쓰면 송신마다의 페이지 참조 획득도 생략된다.
- **수신**: (1) `TCP_ZEROCOPY_RECEIVE`(4.18, mmap 기반, 페이지 정렬 제약), (2) **devmem TCP**(6.12, Mina Almasry 등): dma-buf로 표현된 **디바이스 메모리**(GPU 등)로 페이로드를 직접 DMA, (3) **io_uring zcrx**(`IORING_OP_RECV_ZC`, 6.15, Pavel Begunkov·David Wei): **호스트 사용자 메모리**로 직접 DMA. 둘 다 NIC의 header/data split, flow steering, RSS를 요구하고 헤더는 커널 TCP 스택이 정상 처리한다.

`SEND_ZC`가 작은 메시지(수 KB 이하)에서도 복사보다 빠른지는 1차 출처로 확인된 수치가 없다. 작은 메시지에서의 손익은 NIC, IOMMU, 등록 버퍼 여부, 알림 처리 방식에 따라 달라지므로 실측해야 한다. devmem TCP의 소켓 uAPI 이름은 `SO_DEVMEM_LINEAR`, `SO_DEVMEM_DMABUF`, `SO_DEVMEM_DONTNEED`(cmsg 타입은 `SCM_DEVMEM_LINEAR`, `SCM_DEVMEM_DMABUF`)이다.

---

## 2. Problem Statement

### 2.1 복사가 소모하는 자원
100 Gbit/s 송신은 약 12.5 GB/s의 페이로드다. 일반 `send()`에서 `tcp_sendmsg_locked()`는 사용자 버퍼를 skb 페이지로 복사(`skb_copy_to_page_nocache()` 계열)한다. 이 복사는 사용자 버퍼 읽기와 커널 페이지 쓰기를 일으키고, NIC가 DMA로 다시 읽으므로 메모리 트래픽이 페이로드의 수 배가 된다. 복사 데이터가 LLC를 채우면 다른 작업의 캐시도 밀려난다. io_uring zcrx의 초기 RFC(2023)는 iperf3 부하에서 시스템 메모리 대역폭이 약 50% 줄었다고 보고했다(LWN "Zero copy Rx using io_uring", Broadcom BCM57504, DDIO 비활성 조건).

### 2.2 기존 제로카피 경로의 한계
- `sendfile(2)`: 파일 → 소켓 전송에 한정된다. 사용자 공간에서 헤더와 페이로드를 조립하는 RPC 엔진(Ceph msgr2, gRPC)에는 맞지 않는다.
- `splice(2)`/`vmsplice(2)`: 파이프를 매개로 하므로 호출 수가 늘고, `vmsplice`는 사용자 페이지의 수명 보장이 애매하다.
- `->sendpage()`: 커널 내부 API로 페이지 하나씩 전송했다. 6.5에서 제거되고 `MSG_SPLICE_PAGES`로 대체되었다(multipage folio 전달 가능).

### 2.3 송신 제로카피의 근본 문제: 버퍼 수명
복사를 하지 않으면 `send()`가 반환된 뒤에도 NIC가 아직 사용자 버퍼를 읽는 중일 수 있다. TCP는 재전송을 위해 데이터를 ACK 수신 전까지 보관해야 하므로, 사용자 버퍼는 **ACK까지** 수정하면 안 된다. 커널 문서는 이를 "시스템 콜 의미의 변화"로 설명한다: 복사와 달리 프로세스는 반환 직후 버퍼를 덮어쓰면 전송 중인 데이터를 바꿀 수 있다. 따라서 제로카피 API의 핵심은 "언제 버퍼를 돌려받는가"를 알리는 완료 통지 설계다.

### 2.4 수신 제로카피의 근본 문제: 목적지를 모른다
송신은 사용자가 버퍼를 지정하지만, 수신은 NIC가 DMA할 시점에 어느 소켓의 데이터인지 모른다. 그래서 수신 제로카피는 (a) 특정 RX 큐를 특정 메모리 풀에 묶고(page pool/memory provider), (b) flow steering으로 원하는 흐름만 그 큐로 보내며, (c) header split으로 헤더만 커널 메모리에 받아 TCP가 처리하게 하는 하드웨어 협조를 전제로 한다.

---

## 3. The Debate

### 3.1 MSG_ZEROCOPY: 완료 통지를 어디로 보낼 것인가 (2017)
Willem de Bruijn의 시리즈는 기존 tuntap/vhost/xen용 zerocopy 인프라(`ubuf_info`)를 TCP용으로 확장했다. 커버 레터는 설계를 이렇게 요약한다.

> "On a send call with MSG_ZEROCOPY, the kernel pins user pages and links these directly into the skbuff frags[] array. Each send call with MSG_ZEROCOPY that transmits data will eventually queue a completion notification on the error queue: a per-socket u32 incremented on each such call."
>
> — Willem de Bruijn, "socket sendmsg MSG_ZEROCOPY" 커버 레터 (merge commit `35615994c1f7`, 2017-08-04), https://github.com/torvalds/linux/commit/35615994c1f7

해설: 통지를 에러 큐로 보낸 이유는 송신 타임스탬프(`SO_TIMESTAMPING`)가 이미 같은 채널을 쓰고 있었기 때문이다(문서도 "akin to the transmit timestamping interface"라고 쓴다). 새 시스템 콜이나 새 fd 타입 없이 기존 소켓 API에 얹을 수 있었지만, 대가로 애플리케이션은 `recvmsg(MSG_ERRQUEUE)`를 별도로 호출해 `SO_EE_ORIGIN_ZEROCOPY` 레코드의 `[ee_info, ee_data]` 범위를 읽어야 한다. 커버 레터의 "pins"는 일반적인 의미이고, 현재 구현(`zerocopy_fill_skb_from_iter()`)은 `iov_iter_get_pages2()`로 페이지 **참조**를 얻는다(`FOLL_PIN` 기반 `pin_user_pages()`가 아님).

같은 시리즈의 문서(`Documentation/networking/msg_zerocopy.rst`)는 비용을 직접 밝힌다.

> "Copy avoidance is not a free lunch. As implemented, with page pinning, it replaces per byte copy cost with page accounting and completion notification overhead. As a result, MSG_ZEROCOPY is generally only effective at writes over around 10 KB."
>
> — Linux kernel documentation, msg_zerocopy.rst, https://www.kernel.org/doc/html/latest/networking/msg_zerocopy.html

해설: 손익분기 수치로 흔히 인용되는 것은 이 문서 문장의 "around 10 KB"이며, 문서에 "16KB" 같은 다른 수치는 없다. 추가 제약도 문서에 있다: 소켓 `optmem` 한도나 사용자 locked memory 한도를 넘으면 `ENOBUFS`로 실패하고, 장치가 scatter-gather를 지원하지 않으면 복사로 되돌아가고, 로컬 소켓(루프백)·packet socket(tcpdump)·tun으로 루프되는 패킷은 무한정 큐잉될 수 있어 지연 복사(deferred copy)된다. 복사가 일어났으면 완료 레코드의 `ee_code`에 `SO_EE_CODE_ZEROCOPY_COPIED`가 설정된다. 따라서 같은 호스트 안 veth 쌍에서 벤치마크하면 개선이 보이지 않는다는 점도 문서에 명시되어 있다.

### 3.2 io_uring SEND_ZC: 에러 큐를 CQE로 (6.0)
io_uring은 이미 완료 큐가 있으므로 별도 통지 채널이 필요 없다. 6.0 병합 요청에서 Jens Axboe는 작업의 주체를 분명히 했다.

> "This adds support for efficient support for zerocopy sends through io_uring. Both ipv4 and ipv6 is supported, as well as both TCP and UDP. [...] All of the work has been done by Pavel"
>
> — Jens Axboe, pull request "for-5.20/io_uring-zerocopy-send-2022-07-29" (merge commit `42df1cbf6a47`, 2022-08-02), https://github.com/torvalds/linux/commit/42df1cbf6a47

즉 구현 주체는 Pavel Begunkov이고 Jens Axboe는 io_uring 메인테이너로서 병합 요청을 보냈다. 설계상의 쟁점은 다음과 같다.

1. **CQE 개수**: 완료와 버퍼 해제는 단일 CQE로 통지되지 않는다. 송신 결과 CQE(바이트 수 또는 에러, `IORING_CQE_F_MORE` 설정)와 알림 CQE(`IORING_CQE_F_NOTIF`, 같은 `user_data`)가 분리된다. 단, 알림 요청이 할당되기 전 단계(prep 등)에서 실패하면 결과 CQE에 `IORING_CQE_F_MORE`가 없고 알림 CQE도 오지 않으므로(`io_sendrecv_fail()`), 애플리케이션은 `F_MORE` 여부로 알림 대기 여부를 판단해야 한다. 송신 결과는 즉시 알 수 있지만 버퍼 반환은 TCP ACK와 skb 해제 이후이기 때문이다. 알림 CQE를 받기 전에는 버퍼를 수정하면 안 된다.
2. **복사 폴백 감지**: `IORING_SEND_ZC_REPORT_USAGE`(Linux 6.2)를 주면 알림 CQE의 `res`에 `IORING_NOTIF_USAGE_ZC_COPIED`가 설정되어 실제로 복사되었는지 알 수 있다. MSG_ZEROCOPY의 `SO_EE_CODE_ZEROCOPY_COPIED`에 대응한다.
3. **페이지 참조 비용**: `IORING_RECVSEND_FIXED_BUF`로 등록 버퍼를 지정하면 `io_sg_from_iter()`가 bvec를 frag에 직접 채우고 `SKBFL_MANAGED_FRAG_REFS`를 설정해 frag별 페이지 참조를 잡지 않는다. 버퍼 수명은 io_uring의 등록 버퍼 참조와 알림 요청(알림 전용 `io_kiocb`, 내부 데이터는 `struct io_notif_data`)이 관리한다.

### 3.3 수신 제로카피: devmem TCP와 io_uring zcrx의 분업
devmem TCP(Mina Almasry 외, 6.12)는 "가속기 메모리로 바로 받기"가 목적이었다. NIC RX 큐를 dma-buf에 바인딩(netlink `bind-rx`)하고, 페이로드는 디바이스 메모리에, 헤더는 호스트 메모리에 받는다. 사용자는 `recvmsg()`의 `SCM_DEVMEM_DMABUF`/`SCM_DEVMEM_LINEAR` cmsg로 프래그 위치를 받고, 다 쓰면 `SO_DEVMEM_DONTNEED`로 토큰을 반환한다. 송신 측 devmem TX(`bind-tx`)는 2025-05 net-next 병합으로 6.16에 들어갔다.

io_uring zcrx는 같은 netdev 인프라(page pool memory provider, `net_iov`)를 공유하면서 목적지를 **호스트 사용자 메모리**로 바꾼다. 6.15 병합 요청은 둘의 관계를 다음처럼 설명한다.

> "'Reading' data out of a socket instead becomes a _notification_ mechanism, where the kernel tells userspace where the data is. The overall approach is similar to the devmem TCP proposal [...] This relies on hw header/data split, flow steering and RSS to ensure packet headers remain in kernel memory and only desired flows hit a hw rx queue configured for zero copy."
>
> — Pavel Begunkov, David Wei (v14 커버 레터, Jens Axboe의 6.15 pull request "for-6.15/io_uring-rx-zc-20250325" 인용, merge commit `ca0b04ba0b35`, 2025-03-28), https://github.com/torvalds/linux/commit/ca0b04ba0b35

해설: 수신 제로카피에서 "읽기"는 데이터 이동이 아니라 위치 통지가 된다. 커널 문서도 "Compared to kernel bypass solutions such as e.g. DPDK, the packet headers are processed by the kernel TCP stack as normal."이라고 적어, 바이패스와의 차이를 TCP 스택 보존에 둔다. 이 점이 (→ 04/01)의 결론(스토리지는 커널 TCP를 유지한 채 복사를 줄인다)과 연결된다.

---

## 4. Implementation Impact

### 4.1 송신 콜패스: `tcp_sendmsg_locked()`의 세 갈래
```
tcp_sendmsg_locked(sk, msg, size)                    /* net/ipv4/tcp.c */
 ├─ (flags & MSG_ZEROCOPY)
 │    ├─ msg->msg_ubuf != NULL        ← io_uring SEND_ZC가 자기 ubuf_info(알림)를 넘김
 │    └─ sock_flag(sk, SOCK_ZEROCOPY) ← setsockopt(SO_ZEROCOPY) 필수
 │         └─ msg_zerocopy_realloc()  /* net/core/skbuff.c, 실패 시 -ENOBUFS */
 │       NETIF_F_SG 없으면 zerocopy = 0 (복사로 폴백)
 ├─ (msg_flags & MSG_SPLICE_PAGES)    ← 커널 내부 호출자 (6.5~, sendpage 대체)
 └─ 기본: 복사
루프 내부:
 ├─ zc == MSG_ZEROCOPY    → skb_zerocopy_iter_stream()
 │                            └─ msg->sg_from_iter ? (io_uring: io_sg_from_iter)
 │                               : __zerocopy_sg_from_iter() → zerocopy_fill_skb_from_iter()
 │                                   └─ iov_iter_get_pages2()   /* 페이지 참조 획득 */
 ├─ zc == MSG_SPLICE_PAGES → skb_splice_from_iter()
 └─ 복사                   → skb_copy_to_page_nocache() 계열
완료:
 skb 해제(ACK 후) → skb_zcopy_clear() → ubuf_info->ops->complete
   ├─ MSG_ZEROCOPY: msg_zerocopy_complete() → __msg_zerocopy_callback()
   │                 → sk_error_queue에 SO_EE_ORIGIN_ZEROCOPY [ee_info, ee_data]
   └─ io_uring:     알림 io_kiocb 완료 → CQE(flags = IORING_CQE_F_NOTIF)
```
`tcp_sendmsg_locked()`에는 devmem TX 바인딩(`sockc.dmabuf_id`, `net_devmem_get_binding()`)도 같은 MSG_ZEROCOPY 갈래에 들어 있다. devmem TX는 `MSG_ZEROCOPY` + `SCM_DEVMEM_DMABUF` cmsg 조합으로 동작한다.

### 4.2 io_uring SEND_ZC 세부 (`io_uring/net.c`)
- `io_send_zc_prep()`: 알림용 `io_kiocb`를 할당하고 `notif->cqe.flags = IORING_CQE_F_NOTIF`로 표시, `zc->msg_flags`에 `MSG_NOSIGNAL | MSG_ZEROCOPY`를 OR한다.
- 버퍼 가져오기: `IORING_RECVSEND_FIXED_BUF`면 등록 버퍼의 bvec를 쓰고 `iomsg->msg.sg_from_iter = io_sg_from_iter`, 아니면 일반 iovec용 `io_sg_from_iter_iovec`(내부적으로 `zerocopy_fill_skb_from_iter()`)를 쓴다.
- 결과 CQE: 송신 요청은 `IORING_CQE_F_MORE`를 붙여 완료되며, 이는 같은 `user_data`로 알림 CQE가 하나 더 온다는 뜻이다. 알림 CQE는 `IORING_CQE_F_NOTIF`가 설정되고 `IORING_CQE_F_MORE`는 없다.
- 관련 플래그(uapi): `IORING_RECVSEND_POLL_FIRST`, `IORING_RECVSEND_FIXED_BUF`, `IORING_SEND_ZC_REPORT_USAGE`, `IORING_NOTIF_USAGE_ZC_COPIED`(bit 31).

### 4.3 수신 제로카피 구성 요소
| 항목 | `TCP_ZEROCOPY_RECEIVE` (4.18) | devmem TCP RX (6.12) | io_uring zcrx (6.15) |
|---|---|---|---|
| 목적지 메모리 | 커널 페이지를 사용자 VMA에 mmap | dma-buf(GPU 등 디바이스 메모리) | 사용자 호스트 메모리 (dmabuf 영역도 지원 코드 존재: `io_import_dmabuf()`) |
| 하드웨어 요구 | 페이지 정렬된 페이로드(MTU·header split 조건) | header split + flow steering + RSS | header/data split(`ethtool -G ... tcp-data-split on`) + flow steering + RSS |
| 설정 경로 | `getsockopt(TCP_ZEROCOPY_RECEIVE)` + `mmap()` | netlink `bind-rx`(dmabuf ↔ RX 큐) | `IORING_REGISTER_ZCRX_IFQ` + refill ring(`struct io_uring_zcrx_rqe`) |
| 데이터 통지 | 매핑된 범위 반환 | `SCM_DEVMEM_DMABUF`/`SCM_DEVMEM_LINEAR` cmsg | `IORING_OP_RECV_ZC` CQE (큰 CQE: `CQE32` 또는 `CQE_MIXED`) |
| 버퍼 반환 | `munmap`/재매핑 | `SO_DEVMEM_DONTNEED` | refill ring에 rqe 기록 |
| 링 요구 | 해당 없음 | 해당 없음 | `IORING_SETUP_SINGLE_ISSUER` + `IORING_SETUP_DEFER_TASKRUN` |
| 폴백 | 정렬 안 된 부분은 복사 | devmem 아닌 데이터는 일반 수신 | 메모리 부족 등에서 복사 폴백 |

`io_uring/zcrx.c`에서 확인되는 핵심 객체는 `struct io_zcrx_ifq`(RX 큐 바인딩), `struct io_zcrx_area`(등록 메모리 영역), `net_iov`(page pool이 나눠주는 비 페이지 메모리 단위)이며, 사용자 반환 참조는 `io_zcrx_get_niov_uref()`/`io_zcrx_put_niov_uref()`로 센다.

### 4.4 송신 메커니즘 비교
| 비교 항목 | 일반 `send()` | `MSG_ZEROCOPY` | io_uring `SEND_ZC` (일반 버퍼) | io_uring `SEND_ZC` (등록 버퍼) |
|---|---|---|---|---|
| 페이로드 복사 | 있음 | 없음(폴백 시 있음) | 없음(폴백 시 있음) | 없음(폴백 시 있음) |
| 페이지 처리 | 없음 | 송신마다 `iov_iter_get_pages2()` + optmem/memlock 계정 | 송신마다 참조 획득 + 계정 | 등록 시 1회, frag 참조 생략(`SKBFL_MANAGED_FRAG_REFS`) |
| 버퍼 재사용 시점 | 반환 즉시 | 에러 큐 완료 레코드 수신 후 | `IORING_CQE_F_NOTIF` 수신 후 | 동일 |
| 완료 확인 비용 | 없음 | `recvmsg(MSG_ERRQUEUE)` 추가 호출(여러 send를 범위로 묶어 통지) | CQ 링 읽기 | CQ 링 읽기 |
| 이득 구간 | 작은 메시지 | 문서 기준 약 10 KB 이상 | 실측 필요 `[추측/미확인]` | 실측 필요 `[추측/미확인]` |
| 도입 | — | 4.14 (TCP), 이후 UDP·VSOCK | 6.0 (`SEND_ZC`), 6.1 (`SENDMSG_ZC`) | 6.0 (`SEND_ZC`), 6.1 (`SENDMSG_ZC`) |

### 4.5 기능 연표
| 커널 | 기능 | 주도 |
|---|---|---|
| 4.14 | `MSG_ZEROCOPY` (TCP) | Willem de Bruijn |
| 4.18 | `TCP_ZEROCOPY_RECEIVE` | Eric Dumazet |
| 6.0 | `IORING_OP_SEND_ZC` | Pavel Begunkov |
| 6.1 | `IORING_OP_SENDMSG_ZC` | Pavel Begunkov |
| 6.5 | `MSG_SPLICE_PAGES`, `->sendpage()` 제거 | David Howells |
| 6.12 | devmem TCP RX | Mina Almasry 외 |
| 6.15 | io_uring zcrx (`IORING_OP_RECV_ZC`) | Pavel Begunkov, David Wei |
| 6.16 | devmem TCP TX | Mina Almasry 외 |

### 4.6 스토리지 적용 관점
- Ceph msgr2 같은 사용자 공간 RPC는 큰 오브젝트 청크 송신에 `SEND_ZC`(등록 버퍼)를 고려할 수 있지만, 버퍼를 알림 CQE까지 보유해야 하므로 메모리 풀 크기를 대역폭×RTT 이상으로 잡아야 한다. 현재 Ceph AsyncMessenger의 MSG_ZEROCOPY 적용은 RFC 단계(ceph PR #70638)로 기본 경로가 아니다.
- 커널 내 NVMe/TCP 호스트·타겟은 페이지 캐시/bio 페이지를 `MSG_SPLICE_PAGES`로 넘기므로 사용자 공간 API 변화와 무관하게 이미 복사 없이 송신한다.
- 수신 제로카피는 NIC 기능(header split, ntuple 스티어링)과 드라이버의 memory provider 지원(bnxt, mlx5, gve, fbnic 등 드라이버별)에 의존하므로, 배포 전 드라이버 지원 여부를 확인해야 한다 `[추측/미확인: 드라이버 목록은 버전에 따라 변함]`.

---

## 5. Primary References

- [MSG_ZEROCOPY — The Linux Kernel documentation](https://www.kernel.org/doc/html/latest/networking/msg_zerocopy.html) — "not a free lunch", 10 KB 기준, 루프백 지연 복사.
- [Merge branch 'socket-sendmsg-zerocopy' (commit 35615994c1f7, Willem de Bruijn 커버 레터)](https://github.com/torvalds/linux/commit/35615994c1f7) — MSG_ZEROCOPY 병합(4.14).
- [Zero-copy networking (LWN, 2017)](https://lwn.net/Articles/726917/) — MSG_ZEROCOPY 설계 해설.
- [Zero-copy TCP receive (LWN, 2018)](https://lwn.net/Articles/752188/) — `TCP_ZEROCOPY_RECEIVE`.
- [Zero-copy network transmission with io_uring (LWN, 2021)](https://lwn.net/Articles/879724/) — SEND_ZC 초기 설계 논의.
- [Merge tag 'for-5.20/io_uring-zerocopy-send-2022-07-29' (commit 42df1cbf6a47)](https://github.com/torvalds/linux/commit/42df1cbf6a47) — SEND_ZC 병합(6.0).
- [Device Memory TCP (LWN)](https://lwn.net/Articles/937882/) — devmem TCP 제안.
- [Device Memory TCP — The Linux Kernel documentation](https://www.kernel.org/doc/html/latest/networking/devmem.html) — `SO_DEVMEM_*` uAPI, RX/TX 바인딩.
- [Zero copy Rx using io_uring (LWN)](https://lwn.net/Articles/950582/) — zcrx RFC.
- [io_uring zero copy Rx — The Linux Kernel documentation](https://www.kernel.org/doc/html/latest/networking/iou-zcrx.html) — HW 요구사항과 설정 절차.
- [Merge tag 'for-6.15/io_uring-rx-zc-20250325' (commit ca0b04ba0b35)](https://github.com/torvalds/linux/commit/ca0b04ba0b35) — zcrx 병합(6.15).
