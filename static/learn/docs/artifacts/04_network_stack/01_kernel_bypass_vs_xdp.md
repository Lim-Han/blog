# 커널 바이패스(DPDK) 논쟁과 XDP·AF_XDP: 스토리지 네트워크 데이터패스에서의 위치

> 기준: Linux 6.x 메인라인(`master`, 2026-10 확인) 소스, XDP 논문(ACM CoNEXT '18), LWN 기사. 함수·구조체 이름은 `include/net/xdp.h`, `net/core/dev.c`, `net/xdp/xsk.c`를 grep으로 확인했다.

## 1. Verdict

2010년대 중반 10/40/100GbE NIC가 보급되자 패킷당 CPU 예산이 수십 ns로 줄었고, Intel이 시작한 DPDK(Data Plane Development Kit)처럼 NIC를 사용자 공간 PMD(Poll Mode Driver)에 통째로 넘기는 커널 바이패스가 통신·NFV 영역에서 사실상 표준이 되었다. 리눅스 netdev 커뮤니티의 응답은 "바이패스를 금지"하는 것이 아니라, **드라이버 수신 경로의 가장 이른 지점에서 검증된 eBPF 프로그램을 실행하는 XDP(eXpress Data Path)**와, 그 결과를 사용자 공간 소켓으로 넘기는 **AF_XDP(XSK)**를 커널 안에 만드는 것이었다.

결론적으로 XDP는 DDoS 드롭, L4 로드밸런싱, 단순 포워딩처럼 "패킷 단위로 빨리 판정하는" 작업에서 DPDK와 경쟁할 수 있는 커널 내 대안이 되었다. CoNEXT '18 논문 측정에서 단일 코어 드롭 성능은 XDP 24 Mpps, DPDK 43.5 Mpps, 일반 네트워크 스택(raw 모드) 4.8 Mpps였다. 즉 XDP는 DPDK를 "이긴" 것이 아니라, 일반 스택보다 약 5배 빠르면서 커널의 보안·관리 모델을 유지하는 절충점이다.

스토리지 관점에서의 판단은 다르다. NVMe/TCP, iSCSI, Ceph msgr2 같은 스토리지 프로토콜은 신뢰성 있는 바이트 스트림(TCP)과 혼잡 제어·재전송을 전제로 한다. XDP/AF_XDP는 L2~L4 **프레임** 단위 처리 계층이므로 TCP 상태 머신을 제공하지 않는다. 따라서 리눅스 커널 기반 스토리지 데이터패스는 XDP가 아니라 커널 TCP를 유지한 채 복사·시스템 콜 비용을 줄이는 방향(`MSG_ZEROCOPY`, `MSG_SPLICE_PAGES`, io_uring `SEND_ZC`/multishot recv, devmem TCP, io_uring zcrx, busy polling)으로 진화했다. 반대로 SPDK처럼 사용자 공간에서 NVMe-oF를 구현하는 스택은 DPDK의 EAL/메모리 모델 위에 서 있고, TCP 전송은 커널 소켓(posix)이나 uring 소켓 구현을 쓴다(상세는 (→ 04/04), (→ 07/01), (→ 07/03) 참조).

### 1.1 한 줄 요약
| 질문 | 답 |
|---|---|
| XDP는 DPDK를 대체했나? | 아니다. 패킷 처리 성능은 DPDK가 여전히 높고(논문 기준 단일 코어 43.5 vs 24 Mpps), XDP의 가치는 커널 통합·보안·공유에 있다. |
| 스토리지 TCP 트래픽에 XDP를 쓰나? | 주 데이터패스로는 쓰지 않는다. 필터링/계측/스티어링 보조 역할이 현실적이다. |
| 커널 스토리지 네트워킹의 실제 진화 방향은? | 커널 TCP 유지 + 제로카피 송신/수신 + 완료 기반 비동기 I/O(io_uring) + busy polling. |

---

## 2. Problem Statement

### 2.1 100GbE의 패킷당 시간 예산
64바이트 최소 프레임(프리앰블·IFG 포함 84바이트 와이어 점유) 기준 100GbE 라인 레이트는 약 148.8 Mpps이며, 단일 코어가 이를 감당하려면 패킷당 약 6.7 ns 안에 처리해야 한다. 실제 서버는 RSS로 여러 큐·코어에 분산하지만, 그래도 코어당 수십 ns가 한계다. XDP 논문은 3.6 GHz CPU에서 XDP와 DPDK의 패킷당 차이 18.7 ns가 67 사이클에 해당하며, mlx5 드라이버의 함수 호출 10회가 그중 13 ns를 차지한다고 분석했다. 이 정도 예산에서는 함수 호출·캐시 미스 하나가 성능을 좌우한다.

### 2.2 일반 수신 경로의 비용 구조
일반 경로에서 NIC 드라이버의 NAPI poll 함수(예: `mlx5e_napi_poll()`)는 수신 디스크립터마다 `struct sk_buff`를 만들고(`napi_build_skb()`/`build_skb()` 계열), GRO(`napi_gro_receive()`)를 거쳐 `__netif_receive_skb()` → 프로토콜 핸들러(`ip_rcv()`) → netfilter 훅 → 라우팅 → `tcp_v4_rcv()` → 소켓 수신 큐로 올린다. 이 과정의 비용은 크게 셋이다.

1. **메타데이터 할당**: `sk_buff`(x86-64에서 200바이트대)와 `skb_shared_info`의 할당·초기화, 슬랩 캐시 접근.
2. **계층 순회**: netfilter/conntrack, 라우팅 룩업, 소켓 룩업 등 범용성을 위한 분기. 논문 측정에서 conntrack이 켜진 일반 스택은 단일 코어 1.8 Mpps, raw 모드(conntrack 생략) 4.8 Mpps였다.
3. **사용자 공간 전달**: 소켓 큐잉, 웨이크업, `recvmsg()`의 `copy_to_user()`.

### 2.3 DPDK의 해법과 그 비용
DPDK는 NIC를 커널 드라이버에서 언바인드해 `vfio-pci`(권장) 또는 UIO(`uio_pci_generic`, `igb_uio`)에 붙이고, BAR와 DMA 가능한 hugepage 메모리를 프로세스에 매핑한 뒤 PMD가 디스크립터 링을 바쁜 루프로 폴링한다(`rte_eth_rx_burst()`). 인터럽트·시스템 콜·`sk_buff`·컨텍스트 스위칭이 모두 사라지는 대가는 다음과 같다.

- **커널 기능 상실**: 해당 포트의 트래픽은 netfilter/nftables, tc, 네트워크 네임스페이스, 커널 TCP/IP, `tcpdump`(AF_PACKET) 경로를 거치지 않는다. 필요하면 애플리케이션이 직접 구현하거나 별도 라이브러리를 써야 한다.
- **포트 독점**: 일반적으로 한 프로세스(또는 DPDK multi-process 그룹)가 포트를 독점한다. 예외는 mlx5 같은 bifurcated driver로, 커널 드라이버가 장치를 관리하고 PMD는 하드웨어 flow 규칙으로 걸러진 트래픽만 받는다.
- **CPU 전용**: PMD 코어는 부하와 무관하게 100%로 회전한다. 논문 Figure 4 설명도 DPDK 선이 최대 성능까지 100%에 머문다고 기록한다. DPDK는 이를 완화하기 위해 Rx 인터럽트 모드와 전원 관리(monitor/pause/scale) 기능을 제공한다.

이 비용이 스토리지에서 특히 문제가 되는 이유는, 스토리지 노드가 같은 NIC로 관리·모니터링·복제·클라이언트 트래픽을 동시에 처리하는 범용 서버라는 점이다.

---

## 3. The Debate

### 3.1 XDP의 병합: Brenden Blanco의 mlx4 패치 세트 (Linux 4.8)
XDP의 첫 메인라인 구현은 Brenden Blanco가 2016년 7월 netdev에 제출한 "Add driver bpf hook for early packet drop and forwarding" 시리즈다. 새 BPF 프로그램 타입 `BPF_PROG_TYPE_XDP`, `ndo_xdp`(이후 `ndo_bpf`로 일반화), rtnetlink 속성 `IFLA_XDP`, 그리고 mlx4 드라이버의 드롭/TX 지원을 담았다. David S. Miller가 2016-07-20에 `Merge branch 'xdp'`로 net-next에 병합했고 Linux 4.8에 포함되었다. 개념과 초기 설계는 Tom Herbert, Alexei Starovoitov, Jesper Dangaard Brouer, Daniel Borkmann 등이 netdev/Netconf에서 함께 논의했지만, 메인라인에 들어간 첫 구현 패치 세트의 작성자는 Blanco다.

> "This patch set introduces new infrastructure for programmatically processing packets in the earliest stages of rx, as part of an effort others are calling eXpress Data Path (XDP)."
>
> — Brenden Blanco, 커버 레터 (merge commit `22b3548861fb`, 2016-07-20), https://github.com/torvalds/linux/commit/22b3548861fb21ad79e0d3afeee123b0eb3912cc

해설: Blanco 스스로 XDP를 "다른 사람들이 그렇게 부르는 노력"의 일부라고 표현한다. XDP는 한 사람이 설계한 기능이 아니라 Netconf/netdev에서 형성된 합의를 드라이버 훅으로 처음 구현한 것이라는 점이 원문에서도 드러난다.

### 3.2 "XDP는 무의미한가" 논쟁 (2016년 12월)
XDP의 가치에 대해 실제로 확인되는 공개 논쟁은 LWN "Debating the value of XDP"(Jonathan Corbet, 2016-12-06)에 정리된 netdev 스레드다.

- **반대(Florian Westphal)**: XDP 관련 패치가 쏟아지는 것을 멈췄으면 좋겠다고 하며, DPDK 같은 사용자 공간 네트워킹과 하드웨어 필터가 더 나은 해법이라고 주장했다. 사용자 공간은 언어 선택과 디버깅 지원이 자유로운 반면 BPF는 개발이 어렵고 기능이 제한된다는 것이 근거였다.
- **반대·우려(Hannes Frederic Sowa)**: 조기 드롭은 하드웨어로 풀 수 있지 않느냐는 질문과 함께, XDP가 커널 내부 정보를 BPF helper로 노출할수록 그것이 사용자 ABI가 되어 네트워크 스택의 변경을 제약한다고 우려했다.
- **찬성(Thomas Graf)**: 패킷이 커널을 떠나는 순간 커널은 그 패킷에 대해 보안 결정을 내릴 수 없고, 사용자 공간 코드가 침해되어도 커널은 알 수 없다고 반박했다.
- **찬성(Tom Herbert, David Miller)**: Miller는 하드웨어 필터가 충분하지 않으며 패킷 드롭 용도에는 XDP가 올바른 접근이라고 답했다.

> "DDOS mitigation alone is probably a sufficient motivation to look at XDP. We need something that drops bad packets as quickly as possible when under attack, we need this to be integrated into the stack, we need it to be programmable to deal with the increasing savvy of attackers, and we don't want to be forced to be dependent on HW solutions. This is why we created XDP!"
>
> — Tom Herbert, netdev (LWN 인용, 2016-12-06), https://lwn.net/Articles/708087/

해설: XDP 옹호 논리의 핵심어는 "integrated into the stack"이다. 즉 성능만이 목적이 아니라, 드롭되지 않은 패킷은 `XDP_PASS`로 일반 스택에 그대로 올라가 TCP·netfilter·소켓을 정상적으로 이용해야 한다는 것이다. Stephen Hemminger는 같은 스레드에서 XDP는 고속 패킷 가공에, 사용자 공간 방식은 다른 용도에 적합하며 여러 접근이 공존할 수 있다고 정리했다.

### 3.3 논문이 정리한 XDP의 설계 입장 (CoNEXT '18)
Høiland-Jørgensen, Brouer, Borkmann, Fastabend, Herbert, Ahern, Miller의 논문은 바이패스의 문제를 "커널의 보안 메커니즘과 검증된 관리 도구가 동작하지 않게 된다"는 점으로 정의하고, 다음과 같이 XDP를 소개한다.

> "In XDP, the operating system kernel itself provides a safe execution environment for custom packet processing applications, executed in device driver context. XDP is part of the mainline Linux kernel and provides a fully integrated solution working in concert with the kernel's networking stack."
>
> — Høiland-Jørgensen et al., "The eXpress Data Path: Fast Programmable Packet Processing in the Operating System Kernel", CoNEXT '18 (2018-12), https://dl.acm.org/doi/10.1145/3281411.3281443

같은 논문은 성능 격차를 숨기지 않는다. 측정 환경은 Intel Xeon E5-1650 v4(3.6 GHz, 6코어, DDIO), Mellanox ConnectX-5 Ex 100G(mlx5), TRex 트래픽 생성기, Linux 4.18 pre-release이다. 단일 코어 드롭에서 XDP 24 Mpps(41.6 ns/패킷), DPDK 43.5 Mpps(22.9 ns/패킷)이고, 두 방식 모두 코어 수에 비례해 증가하다 PCI 버스 한계(디스크립터 압축 활성 시 115 Mpps)에서 멈췄다. 저자들은 격차를 DPDK의 저수준 마이크로 최적화 차이로 설명한다.

### 3.4 AF_XDP와 스토리지 프로토콜의 간극
2018년 Intel의 Björn Töpel과 Magnus Karlsson이 주도한 AF_XDP가 Linux 4.18에 병합되었다(LWN "Accelerating networking with AF_XDP"). `XDP_REDIRECT`로 XSKMAP의 소켓에 프레임을 넘기고, 사용자 공간과 공유하는 UMEM 및 네 개의 링(Fill, Rx, Tx, Completion)으로 프레임을 주고받는다. 드라이버 지원 시 zero-copy 모드(4.20, i40e부터), 미지원 시 copy 모드로 동작한다.

스토리지 관점의 간극은 다음과 같다.
- AF_XDP가 주는 것은 **이더넷 프레임**이다. NVMe/TCP나 Ceph msgr2를 AF_XDP 위에 올리려면 사용자 공간 TCP 스택이 필요하고, 이는 DPDK 위 사용자 공간 TCP(F-Stack, mTCP, Seastar native stack 등)와 같은 유지보수 부담을 진다.
- 커널 TCP가 제공하는 혼잡 제어(CUBIC/BBR), SACK/RACK 손실 복구, kTLS, cgroup/네임스페이스 통합을 잃는다.
- 반면 XDP 자체는 스토리지 노드에서도 유용하다. 예: 관리 네트워크 보호용 드롭, 복제 트래픽 계측, `XDP_REDIRECT` + cpumap(4.15)을 이용한 CPU 스티어링.

그래서 커널 스토리지 진영의 해법은 "TCP는 커널에 두고, 복사와 시스템 콜을 줄이는 것"으로 수렴했다. (→ 04/02)와 (→ 04/03)이 이 흐름을 다룬다.

---

## 4. Implementation Impact

### 4.1 XDP 수신 콜패스 (Linux 6.x 기준)
```
NIC RX 디스크립터 완료 → IRQ → napi_schedule()
  └─ net_rx_action() → 드라이버 poll (예: mlx5e_napi_poll())
       ├─ struct xdp_buff 준비 (data, data_end, data_meta, data_hard_start, rxq, frame_sz)
       ├─ act = bpf_prog_run_xdp(prog, &xdp)        /* include/net/xdp.h, __always_inline */
       │    ├─ XDP_DROP     → 페이지를 page_pool로 즉시 재활용
       │    ├─ XDP_TX       → 같은 NIC의 XDP 전용 TX 링으로 반사
       │    ├─ XDP_REDIRECT → xdp_do_redirect(): devmap / cpumap / xskmap
       │    │                   └─ xskmap: __xsk_map_redirect() → xsk_rcv_zc()/__xsk_rcv()
       │    ├─ XDP_PASS     → sk_buff 생성 후 일반 스택 (GRO → ip_rcv → tcp_v4_rcv)
       │    └─ XDP_ABORTED  → 드롭 + tracepoint xdp:xdp_exception
       └─ NAPI poll 종료 시 xdp_do_flush()            /* redirect 배치 플러시 */

Generic XDP (드라이버 미지원 NIC, 4.12):
  __netif_receive_skb_core() → do_xdp_generic() → netif_receive_generic_xdp()
    → bpf_prog_run_generic_xdp()   /* sk_buff가 이미 할당된 뒤 실행 → 성능 이점 작음 */
```
`include/net/xdp.h`에서 `struct xdp_buff`는 `data`, `data_end`, `data_meta`, `data_hard_start`, `rxq`, `txq`, `frame_sz`, `flags` 필드를 가지며, `XDP_FLAGS_HAS_FRAGS`가 multi-buffer(5.18) 프레임을 표시한다. 액션 값은 uapi `include/uapi/linux/bpf.h`의 `enum xdp_action`(`XDP_ABORTED = 0`, `XDP_DROP`, `XDP_PASS`, `XDP_TX`, `XDP_REDIRECT`)이다. `xdp_do_redirect()`와 `xdp_do_flush()`의 짝은 같은 CPU 컨텍스트에서 호출되어야 한다("MUST be called in the same cpu context")는 주석이 `include/linux/filter.h`에 있으며, 드라이버는 실제로 한 NAPI poll 안에서 이 짝을 호출한다.

### 4.2 AF_XDP의 링·UMEM 구조
- **UMEM**: 사용자 공간이 등록한 연속 메모리(`XDP_UMEM_REG`)를 고정 크기 청크로 나눈 영역. 여러 소켓이 `XDP_SHARED_UMEM`으로 공유 가능.
- **Fill ring (user→kernel)**: 수신에 쓸 빈 청크 주소 공급. **Rx ring (kernel→user)**: 수신된 청크의 주소와 길이.
- **Tx ring (user→kernel)**: 송신할 청크 디스크립터. **Completion ring (kernel→user)**: 송신 완료되어 재사용 가능한 청크 주소.
- 각 링은 단일 생산자/단일 소비자 링이다. 멀티스레드에서 한 링을 공유하려면 애플리케이션 측 동기화가 필요하다.
- 바인드 플래그: `XDP_COPY`, `XDP_ZEROCOPY`, `XDP_USE_NEED_WAKEUP`(5.4). `need_wakeup`이 설정된 경우에만 사용자 공간이 `sendto()`/`poll()`로 커널을 깨우면 되므로 시스템 콜을 줄인다. 드라이버가 zero-copy를 지원하지 않으면 TX는 `xsk_generic_xmit()`의 skb 경로를 탄다.
- 5.11부터 `SO_PREFER_BUSY_POLL`/`SO_BUSY_POLL_BUDGET`로 AF_XDP 소켓의 busy polling을 쓸 수 있다(DPDK AF_XDP PMD 문서도 busy polling에 커널 5.11 이상을 요구).

### 4.3 기능 도입 연표
| 커널 | 기능 | 비고 |
|---|---|---|
| 4.8 (2016) | XDP 최초 병합 (mlx4, Brenden Blanco) | `BPF_PROG_TYPE_XDP`, `XDP_DROP`/`XDP_PASS`/`XDP_TX` |
| 4.12 | Generic XDP (현재 진입점은 4.14부터의 `do_xdp_generic()`) | 드라이버 미지원 NIC용 skb 경로 |
| 4.14 | `XDP_REDIRECT`, devmap | 다른 NIC로 전달 |
| 4.15 | cpumap | 다른 CPU로 skb 생성 위임 |
| 4.18 | AF_XDP (copy 모드) | Björn Töpel, Magnus Karlsson |
| 4.20 | AF_XDP zero-copy (i40e) | 드라이버별 지원 |
| 5.4 | `XDP_USE_NEED_WAKEUP` | 시스템 콜 감소 |
| 5.11 | `SO_PREFER_BUSY_POLL` | AF_XDP busy poll |
| 5.18 | XDP multi-buffer (`XDP_FLAGS_HAS_FRAGS`) | 점보 프레임/GRO-HW |

### 4.4 DPDK vs XDP/AF_XDP vs 커널 TCP 스택 비교
| 비교 지표 | DPDK (커널 바이패스) | XDP / AF_XDP | 커널 TCP 스택 |
|---|---|---|---|
| 실행 위치 | 사용자 공간 PMD (`vfio-pci`/UIO, bifurcated 예외) | 드라이버 NAPI 컨텍스트의 eBPF + (AF_XDP) 사용자 공간 UMEM | 커널 softirq + 소켓 계층 |
| 단일 코어 드롭 성능 (CoNEXT '18, 4.18, CX-5) | 43.5 Mpps (22.9 ns/pkt) | 24 Mpps (41.6 ns/pkt) | raw 4.8 Mpps / conntrack 1.8 Mpps |
| 커널 보안·관리 도구 | 해당 포트에 적용 안 됨 | XDP_PASS 트래픽은 그대로 적용, BPF verifier로 프로그램 검증 | 전부 적용 |
| TCP 상태 머신 | 없음 (사용자 공간 TCP 필요) | 없음 (프레임 단위) | 있음 (CUBIC/BBR, SACK, kTLS) |
| NIC 공유 | 포트 독점 (bifurcated driver 제외) | 큐 단위 공유, 나머지 큐는 커널 | 공유 |
| 유휴 시 CPU | 기본 100% (Rx 인터럽트/전원 관리 옵션 있음) | 인터럽트 + NAPI, 필요 시 busy poll | 인터럽트 + NAPI |
| 스토리지 프로토콜 적합성 | SPDK 등 사용자 공간 스택에서 사용, TCP는 별도 구현 필요 | 보조 기능(필터·계측·스티어링) | NVMe/TCP, iSCSI, Ceph의 기본 전송 |

### 4.5 운영상 시사점
- 스토리지 노드에서 XDP를 쓸 때는 데이터 경로가 아니라 **방어·관측** 용도로 쓰는 것이 일반적이다. `XDP_PASS` 경로의 추가 비용은 논문 기준 13.3 ns/패킷(카운터 갱신 후 PASS 시 4.8 → 4.5 Mpps)이었다.
- 드라이버 네이티브 XDP를 켜면 많은 드라이버가 RX 버퍼 레이아웃(페이지당 1프레임, headroom 확보)이나 MTU 상한을 바꾼다. 점보 프레임을 쓰는 스토리지 네트워크라면 multi-buffer 지원 여부를 드라이버별로 확인해야 한다 `[추측/미확인: 드라이버별 제약은 버전마다 다름]`.
- DPDK와 공존이 필요하면 bifurcated driver(mlx5)나 DPDK의 AF_XDP PMD(`net_af_xdp`, DPDK 19.05 추가)를 고려할 수 있다. 후자는 커널 드라이버를 유지한 채 큐 일부만 DPDK에 넘긴다.

---

## 5. Primary References

- [The eXpress Data Path: Fast Programmable Packet Processing in the Operating System Kernel (CoNEXT '18, ACM DL)](https://dl.acm.org/doi/10.1145/3281411.3281443) — 성능 수치·측정 환경·설계 입장의 출처.
- [Merge branch 'xdp' — Brenden Blanco, "Add driver bpf hook for early packet drop and forwarding" (commit 22b3548861fb)](https://github.com/torvalds/linux/commit/22b3548861fb21ad79e0d3afeee123b0eb3912cc) — XDP 최초 병합(4.8).
- [Early packet drop — and more — with BPF (LWN, 2016)](https://lwn.net/Articles/682538/) — XDP 초기 제안 배경.
- [Debating the value of XDP (LWN, 2016-12-06)](https://lwn.net/Articles/708087/) — Westphal/Sowa/Graf/Herbert/Miller 논쟁.
- [Accelerating networking with AF_XDP (LWN, 2018)](https://lwn.net/Articles/750845/) — AF_XDP 설계.
- [AF_XDP — The Linux Kernel documentation](https://www.kernel.org/doc/html/latest/networking/af_xdp.html) — UMEM, 링, 바인드 플래그.
- [AF_XDP Poll Mode Driver — DPDK documentation](https://doc.dpdk.org/guides/nics/af_xdp.html) — DPDK와 AF_XDP의 결합, 커널 버전 요구사항.
