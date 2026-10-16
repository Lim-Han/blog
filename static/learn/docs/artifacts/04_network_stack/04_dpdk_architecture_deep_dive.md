# DPDK 아키텍처 심층 분석: EAL, 메모리/IOVA, PMD, mbuf·mempool·ring, rte_flow와 SPDK와의 관계

> 기준: DPDK `main` 브랜치(문서 26.07 표기, 2026-10 확인)와 doc.dpdk.org 프로그래머 가이드·릴리스 노트. 구조체·함수·옵션 이름은 `lib/mbuf/rte_mbuf_core.h`, `lib/ring/rte_ring_core.h`, `lib/ethdev/rte_ethdev.h`, `lib/mempool/rte_mempool.h`, `lib/eal/include/*.h`, `config/rte_config.h`, `meson_options.txt`를 grep으로 확인했다. 커널 쪽 대안(XDP/AF_XDP)과의 비교는 (→ 04/01), SPDK 측 구조는 (→ 07/01)을 참조.

## 1. Verdict

DPDK(Data Plane Development Kit)는 "NIC를 커널에서 떼어 내 사용자 공간 프로세스가 직접 폴링한다"는 단순한 아이디어를, 그 아이디어가 실제로 빠르게 동작하는 데 필요한 런타임 전체로 구체화한 프레임워크다. 핵심 구성은 다섯 가지다.

1. **EAL(Environment Abstraction Layer)**: hugepage 메모리 확보, IOVA(장치가 보는 주소) 결정, PCI 장치 탐색과 `vfio-pci`/UIO 바인딩 확인, lcore(코어에 고정된 워커 스레드) 생성, multi-process 공유.
2. **PMD(Poll Mode Driver)**: 인터럽트 없이 `rte_eth_rx_burst()`/`rte_eth_tx_burst()`로 디스크립터 링을 배치 단위로 처리하는 사용자 공간 드라이버.
3. **`rte_mbuf`/`rte_mempool`/`rte_ring`**: 2개 캐시 라인 크기의 패킷 메타데이터, per-lcore 캐시를 가진 고정 크기 객체 풀, CAS 기반 lockless 링.
4. **`rte_flow`**: NIC 하드웨어 분류·스티어링 규칙을 벤더 중립적으로 기술하는 API(17.02 도입, 22.03 템플릿 API).
5. **대체 백엔드와 공존 장치**: AF_XDP PMD(19.05), bifurcated driver(mlx5 등), Rx 인터럽트 모드와 PMD 전원 관리.

DPDK가 스토리지에 중요한 이유는 네트워크 패킷 처리 자체보다 **이 런타임을 SPDK가 기본 환경 계층(`lib/env_dpdk`)으로 재사용**하기 때문이다. SPDK의 NVMe 사용자 공간 드라이버가 쓰는 DMA 가능 메모리, `vfio-pci` 바인딩, lcore 기반 reactor, 메시지 링은 모두 DPDK EAL·`rte_mempool`·`rte_ring` 위에 있다. 반면 NVMe-oF/TCP 같은 TCP 전송에서 SPDK는 DPDK의 L2 PMD가 아니라 커널 소켓(posix/uring sock 모듈)을 쓰는 것이 일반적이다. 즉 스토리지 관점에서 DPDK는 "패킷 엔진"보다 "사용자 공간 I/O 런타임"으로 더 넓게 쓰인다.

거버넌스 측면에서 DPDK는 Intel 주도로 시작해 2013년 전후 오픈소스 커뮤니티(dpdk.org)가 형성되었고 `[추측/미확인: 공개 연도 세부]`, 2017년 4월 3일 Linux Foundation 산하 프로젝트로 이관되어 Governing Board와 Technical Board 체제로 운영된다. 릴리스는 `YY.MM` 형식이며, 정책상 매년 11월 릴리스(X.11)가 LTS로 지정되어 3년간 유지된다(커뮤니티 검증 지원 조건).

### 1.1 요약 표
| 질문 | 답 |
|---|---|
| DPDK의 성능 원천은? | 인터럽트·시스템 콜·`sk_buff` 제거, 배치 처리, hugepage로 TLB 미스 감소, per-lcore 캐시와 lockless 링, 코어 고정 |
| 커널 드라이버 바인딩은? | `vfio-pci` 권장(IOMMU 보호), IOMMU 없으면 vfio no-IOMMU 모드, 차선으로 `uio_pci_generic`/`igb_uio`(20.11부터 dpdk-kmods 저장소로 분리) |
| 메모리 모델 변화는? | 18.05에서 동적 메모리(hugepage 증감) 도입, 19.08부터 대부분 IOVA-as-VA 기본 |
| 커널과의 공존은? | bifurcated driver, AF_XDP PMD, `rte_flow` isolated mode |
| SPDK와의 관계는? | SPDK `env_dpdk`가 `rte_eal_init()`·hugepage·`rte_mempool`·`rte_ring`을 사용 |

---

## 2. Problem Statement

### 2.1 범용 커널 경로가 패킷 처리에 비싼 이유
(→ 04/01)에서 본 것처럼 100GbE 최소 프레임 처리 예산은 코어당 수십 ns 수준이다. 일반 커널 경로는 패킷마다 `sk_buff` 할당, 프로토콜 계층 순회, 소켓 큐잉, 웨이크업, 시스템 콜, 복사를 거친다. CoNEXT '18 XDP 논문의 측정(Xeon E5-1650 v4, ConnectX-5)에서 단일 코어 드롭 성능은 DPDK 43.5 Mpps, XDP 24 Mpps, 일반 스택 raw 모드 4.8 Mpps였다. DPDK는 이 격차의 상한을 보여 준다.

### 2.2 사용자 공간 드라이버가 해결해야 하는 문제
NIC를 사용자 공간에서 직접 구동하려면 커널이 원래 해 주던 일을 대신해야 한다.
- **DMA 주소 문제**: NIC는 가상 주소를 모른다. 사용자 버퍼의 물리 주소(또는 IOMMU가 번역할 IOVA)를 알아야 하고, 그 메모리가 이동·스왑되지 않아야 한다. → hugepage + IOVA 모드.
- **장치 접근과 격리**: BAR 레지스터를 매핑하고, 장치가 임의 메모리에 DMA하지 못하게 해야 한다. → VFIO(IOMMU 그룹) 또는 보호 없는 UIO.
- **메모리 할당 비용**: 패킷마다 `malloc()`하면 느리다. → 미리 만든 고정 크기 객체 풀(`rte_mempool`)과 per-core 캐시.
- **코어 간 전달**: 파이프라인 단계 사이 큐가 락을 쓰면 확장되지 않는다. → `rte_ring`.
- **스케줄링 간섭**: 폴링 스레드가 다른 작업과 섞이면 지연이 튄다. → lcore를 코어에 고정하고 보통 `isolcpus`/`nohz_full`와 함께 운영.

### 2.3 대가
- 커널 네트워크 기능(netfilter, tc, TCP/IP, 네임스페이스, `tcpdump`)이 해당 포트에서 사라진다. KNI(Kernel NIC Interface)로 일부 트래픽을 커널에 넘기던 방식은 DPDK 23.11에서 제거되었다. DPDK 문서의 "Virtio_user as Exception Path"는 virtio-user + 커널 vhost를 DPDK 애플리케이션과 커널 스택 사이 패킷 전달에서 KNI의 대안으로 설명한다(TAP PMD도 쓰이지만 공식 권고 문구는 확인하지 못했다 `[추측/미확인]`).
- 폴링 코어는 부하와 무관하게 100%를 쓴다. 전원 관리와 Rx 인터럽트 모드는 이를 부분적으로 완화한다(4.8절).
- 보안 경계가 IOMMU와 프로세스 권한에 의존한다. UIO 사용 시 프로세스가 사실상 임의 물리 메모리에 DMA할 수 있다.

---

## 3. The Debate

DPDK를 둘러싼 논쟁은 크게 (1) 커널 바깥에서 할 것인가, (2) 사용자 공간 드라이버의 안전성, (3) 메모리·주소 모델, (4) 커널과의 공존 방식으로 나뉜다. (1)은 (→ 04/01)의 XDP 논쟁(LWN "Debating the value of XDP", 2016)에서 다뤘다. 그 스레드에서 Florian Westphal은 DPDK 같은 사용자 공간 네트워킹을 XDP보다 나은 해법으로 들었고, Thomas Graf는 패킷이 커널을 떠나면 커널이 보안 결정을 내릴 수 없다고 반박했다. 여기서는 DPDK 내부 설계 논쟁을 다룬다.

### 3.1 UIO vs VFIO: 성능이 아니라 보안의 문제
초기 DPDK는 자체 커널 모듈 `igb_uio`로 BAR를 매핑하고 hugepage의 물리 주소를 `/proc/self/pagemap`에서 읽어 DMA에 썼다. 이 방식은 IOMMU 보호가 없고 root 권한이 필요하다. 이후 VFIO가 표준 경로가 되었고, 현재 문서는 이렇게 권고한다.

> "It is recommended that vfio-pci be used as the kernel module for DPDK-bound ports in all cases. If an IOMMU is unavailable, the vfio-pci can be used in no-iommu mode."
>
> — DPDK Getting Started Guide for Linux, "Linux Drivers" (doc.dpdk.org, 2026-10 확인), https://doc.dpdk.org/guides/linux_gsg/linux_drivers.html

같은 문서는 UIO에 대해 "Using UIO drivers is inherently unsafe due to this method lacking IOMMU protection, and can only be done by root user."라고 경고한다. 해설: VFIO는 IOMMU 그룹 단위로 장치를 격리하므로, DPDK 프로세스의 버그나 침해가 다른 메모리로의 DMA로 번지지 않는다. 메인라인 밖 모듈인 `igb_uio`는 20.11에서 DPDK 본 저장소에서 빠져 `dpdk-kmods` 저장소(`linux/igb_uio`)로 옮겨졌다. VF 생성은 `vfio-pci`의 `sriov_numvfs`와 VF 토큰(`vf_token`)으로도 가능하다. 이 흐름은 SPDK에도 그대로 적용되어, SPDK의 `scripts/setup.sh`도 IOMMU가 켜져 있으면 `vfio-pci`, 아니면 `uio_pci_generic`, 그것도 없으면 빌드된 `igb_uio.ko`로 폴백하는 순서로 드라이버를 고른다(`DRIVER_OVERRIDE`로 강제 가능).

### 3.2 IOVA as PA vs IOVA as VA
장치에 줄 주소로 물리 주소(PA)를 쓸지, IOMMU를 통해 가상 주소를 그대로 IOVA로 쓸지(VA)는 오랜 논쟁이었다. PA 모드는 IOMMU가 없거나 UIO일 때 필요하지만 `/proc/self/pagemap` 접근(root 권한)과 물리적으로 연속된 메모리 확보를 요구한다. VA 모드는 VFIO+IOMMU가 있을 때 사용자 가상 주소를 그대로 DMA 주소로 매핑하므로 연속성 문제가 사라진다. 19.08 릴리스 노트는 기본값 변경을 이렇게 기록한다.

> "EAL will now pick IOVA as VA mode as the default in most cases. Previously, the preferred default IOVA mode was selected to be IOVA as PA."
>
> — DPDK 19.08 Release Notes (doc.dpdk.org), https://doc.dpdk.org/guides/rel_notes/release_19_08.html

현재 EAL의 선택 규칙: 각 버스가 원하는 모드(`RTE_IOVA_PA`/`RTE_IOVA_VA`/`RTE_IOVA_DC`)를 보고하고, 모두 같으면 그 모드, 의견이 갈리거나 선호가 없으면 물리 주소를 쓸 수 없을 때 VA, `/sys/kernel/iommu_groups`가 비어 있지 않으면 VA, 그 외 PA를 고른다. `--iova-mode=pa|va`로 강제할 수 있다. 17.11에서 `phys_addr_t` 계열 이름이 `rte_iova_t` 등 IOVA 용어로 바뀐 것도 이 전환의 일부다.

### 3.3 정적 메모리 vs 동적 메모리 (18.05)
18.05 이전 EAL은 시작 시 필요한 hugepage를 모두 잡고 물리 연속 청크로 정렬했다(현재의 `--legacy-mem`). 18.05에서 메모리 서브시스템이 재작성되어 `rte_malloc()`/`rte_memzone_reserve()` 요청에 따라 hugepage를 늘리고 줄이는 동적 모드가 기본이 되었다. 대가는 할당된 메모리가 IOVA 연속을 보장하지 않는다는 점이며, 문서는 큰 연속 영역이 필요하면 VFIO(=IOVA as VA)를 쓰거나 legacy 모드를 쓰라고 권한다. 동적 모드의 메모리 이벤트는 `rte_mem_event_callback_register()`로 통지되며, SPDK는 이 콜백으로 자기 주소 변환 맵과 VFIO DMA 매핑을 갱신한다(→ 07/01).

### 3.4 Lockless ring의 설계 선택
`rte_ring`은 FreeBSD 8.0의 `bufring` 구현을 참고한 고정 크기 링으로, 문서는 연결 리스트 기반 lockless 큐 대비 장점을 다음처럼 요약한다.

> "Faster; only requires a single 32 bit Compare-And-Swap instruction instead of several pointer size Compare-And-Swap instructions."
>
> — DPDK Programmer's Guide, "Ring Library" (doc.dpdk.org), https://doc.dpdk.org/guides/prog_guide/ring_lib.html

반면 고정 크기라 메모리를 미리 잡아야 하고, 기본 MP/MC 모드에서 생산자가 head를 예약한 뒤 tail 갱신 전에 선점되면 다른 생산자가 기다려야 한다(lock-waiter preemption). 이를 위해 `RTE_RING_SYNC_MT_RTS`(relaxed tail sync)와 `RTE_RING_SYNC_MT_HTS`(head/tail sync) 모드가 추가되었고, 가상화 환경처럼 vCPU 선점이 잦은 경우에 쓴다.

### 3.5 폴링 vs 전력/공유
100% 폴링은 전용 어플라이언스에서는 합리적이지만 클라우드·범용 서버에서는 비싸다. DPDK는 Rx 인터럽트 모드(`rte_eth_dev_rx_intr_enable()` + `rte_epoll_wait()`, l3fwd-power 예제)와 PMD 전원 관리 API(monitor: 디스크립터 주소를 감시하며 저전력 대기, pause: `rte_power_pause()`/`rte_pause()`, scale: 트래픽에 따른 주파수 조절)로 타협한다. 커널 쪽에서는 같은 문제를 반대 방향(인터럽트 기본 + busy poll 선택)에서 접근했다((→ 04/03) 3.3절).

---

## 4. Implementation Impact

### 4.1 `rte_eal_init()` 순서 (Linux, `lib/eal/linux/eal.c` 기준)
```
rte_eal_init(argc, argv)
 ├─ EAL 인자 파싱 (-l/--lcores, --main-lcore, -a/-b 장치 허용·차단, --iova-mode,
 │                 --legacy-mem, --in-memory, --single-file-segments, --proc-type ...)
 ├─ rte_bus_scan()                 /* PCI 등 버스 장치 탐색 */
 ├─ rte_bus_get_iommu_class()      /* 버스별 IOVA 선호 → IOVA 모드 결정 */
 ├─ eal_hugepage_info_init()       /* hugetlbfs 마운트·페이지 크기 탐색 (primary) */
 ├─ rte_eal_memory_init()          /* memseg list 예약, (legacy면 전체 매핑) */
 ├─ rte_eal_malloc_heap_init()     /* NUMA 소켓별 malloc heap */
 ├─ 워커 lcore 스레드 생성 → eal_thread_loop()에서 명령 대기
 ├─ rte_eal_mp_wait_lcore()
 ├─ rte_service_init()             /* service core 프레임워크 */
 └─ rte_bus_probe()                /* 드라이버 매칭: PMD 초기화, vfio 매핑 */
이후: rte_eal_remote_launch(fn, arg, worker_id) 또는 RTE_LCORE_FOREACH_WORKER 루프로 작업 배치
```
**lcore**는 EAL이 만든(또는 등록한) 스레드에 붙는 ID(`rte_lcore_id()`)이며, 보통 하나의 물리 코어에 고정된다. 메인 lcore(`rte_get_main_lcore()`)가 초기화를 하고, 워커 lcore가 폴링 루프를 돈다. per-lcore 데이터는 `RTE_MAX_LCORE` 크기 배열, TLS(`rte_per_lcore.h`), 또는 최근의 lcore 변수 API로 둔다. **service core**는 특정 기능(예: 이벤트 디바이스 스케줄러, 소프트웨어 타이머)을 "서비스"로 등록하고 지정한 lcore들이 돌아가며 실행하게 하는 프레임워크다(`rte_service_lcore_add()`, `rte_service_map_lcore_set()`).

### 4.2 메모리 구조
- **hugepage**: 2 MiB/1 GiB 페이지로 TLB 미스를 줄이고, 페이지가 스왑·이동되지 않게 한다. 파일 기반(hugetlbfs, multi-process에 필수) 또는 `--in-memory`(익명 매핑, multi-process 불가).
- **memseg list / fbarray**: NUMA 소켓·페이지 크기별로 미리 가상 주소 공간을 예약하고(`RTE_MAX_MEMSEG_LISTS` 등 상한), 동적 모드에서 필요할 때 hugepage를 채운다.
- **`rte_memzone`**: 이름 있는 연속 영역. IOVA 연속이 필요하면 `RTE_MEMZONE_IOVA_CONTIG`.
- **multi-process**: primary가 hugepage를 관리하고 secondary는 같은 파일을 같은 가상 주소에 매핑한다. 동적 모드에서는 새 페이지 할당이 primary를 거쳐야 하며 IPC(`rte_mp_*`)로 동기화된다.

### 4.3 PMD 데이터패스
```c
/* 전형적인 run-to-completion 워커 */
while (!quit) {
    nb_rx = rte_eth_rx_burst(port, queue, pkts, BURST);   /* 디스크립터 링에서 최대 BURST개 */
    for (i = 0; i < nb_rx; i++)
        process(pkts[i]);                                  /* 헤더 파싱, 룩업, 수정 */
    nb_tx = rte_eth_tx_burst(port, queue, pkts, nb_rx);   /* TX 링에 기록, doorbell */
    for (i = nb_tx; i < nb_rx; i++)
        rte_pktmbuf_free(pkts[i]);                         /* 미전송분 반환 → mempool 캐시 */
}
```
`rte_eth_rx_burst()`는 인라인 함수로 포트의 fast-path 함수 포인터를 호출한다. PMD는 완료된 RX 디스크립터를 읽어 미리 채워 둔 mbuf를 반환하고, 같은 수만큼 mempool에서 새 mbuf를 꺼내 디스크립터에 다시 채운다. 배치(burst) 단위 처리와 프리페치가 디스크립터·mbuf 캐시 미스를 숨긴다. 파이프라인 모델에서는 RX lcore가 `rte_ring`으로 다른 lcore에 mbuf 포인터를 넘긴다.

### 4.4 `rte_mbuf`, `rte_mempool`, `rte_ring`
- **`struct rte_mbuf`** (`rte_mbuf_core.h`): 문서 기준 64바이트 캐시 라인 두 개를 쓰며 자주 쓰는 필드가 첫 줄에 있다. `buf_addr`(버퍼 가상 주소), `buf_iova`(IOVA; `RTE_IOVA_IN_MBUF`가 0인 빌드에서는 가상 주소를 IOVA로 사용), `data_off`, `refcnt`, `nb_segs`, `port`, `ol_flags`(체크섬·TSO 등 오프로드 플래그 `RTE_MBUF_F_*`), `pkt_len`, `data_len`, `buf_len`, `pool`, `next`(체인). 데이터 시작 앞에 `RTE_PKTMBUF_HEADROOM`(meson 옵션 `pkt_mbuf_headroom` 기본 128바이트)을 둔다. 기본 데이터룸은 `RTE_MBUF_DEFAULT_DATAROOM` 2048. 간접(indirect) mbuf, 외부 버퍼, 동적 필드/플래그(dynfield) 등록을 지원한다.
- **`rte_mempool`**: 고정 크기 객체 풀. 기본 핸들러는 `RTE_MBUF_DEFAULT_MEMPOOL_OPS = "ring_mp_mc"`(즉 `rte_ring` 기반)이고, stack/bucket 등 다른 핸들러로 교체 가능하다. lcore별 캐시(`struct rte_mempool_cache`, 상한 `RTE_MEMPOOL_CACHE_MAX_SIZE` 512)가 대부분의 get/put을 공유 링 접근 없이 처리한다. 메모리 채널·랭크 수를 EAL 인자로 주면 객체 배치를 채널에 분산할 수 있다.
- **`struct rte_ring`**: 생산자·소비자 각각 `struct rte_ring_headtail`(head, tail, `sync_type`)을 가진다. 동기화 모드는 `enum rte_ring_sync_type`의 `RTE_RING_SYNC_MT`(기본), `RTE_RING_SYNC_ST`, `RTE_RING_SYNC_MT_RTS`, `RTE_RING_SYNC_MT_HTS`. bulk(전부 아니면 실패)와 burst(가능한 만큼) API, peek/zero-copy API가 있다.

| 링 모드 | 생산자 동기화 | 장점 | 비용/한계 |
|---|---|---|---|
| MP/MC (기본) | 32-bit CAS로 head 예약, tail은 순서대로 대기 | 가장 단순·빠름 | tail 대기 중 선점 시 Lock-Waiter-Preemption |
| SP/SC | 원자 연산 없음 | 최소 비용 | 단일 생산자/소비자 보장 필요 |
| MP_RTS/MC_RTS | head·tail 각각 64-bit CAS, 마지막 스레드만 tail 갱신 | 과다 할당(overcommit) 환경에서 평균 지연 개선 | CAS 2회 |
| MP_HTS/MC_HTS | head==tail일 때만 진행(완전 직렬화) | LWP 회피, peek API 사용 가능 | 동시성 낮음 |

### 4.5 `rte_flow`: 하드웨어 분류의 공통 언어
`rte_flow`(17.02)는 규칙을 **속성**(ingress/egress/transfer, group, priority) + **패턴 아이템 목록**(`struct rte_flow_item`: ETH, IPV4, TCP, VXLAN ...) + **액션 목록**(`struct rte_flow_action`: QUEUE, RSS, MARK, DROP, COUNT, JUMP ...)으로 기술한다. `rte_flow_validate()`로 지원 여부를 확인하고 `rte_flow_create()`로 설치한다. `rte_flow_isolate()`로 isolated mode를 켜면 규칙에 맞는 트래픽만 DPDK가 받고 나머지는 커널 드라이버에 남는다(bifurcated 모델의 핵심). 대량 규칙 삽입을 위해 22.03에서 템플릿 API(`rte_flow_pattern_template_create()`, `rte_flow_actions_template_create()`, `rte_flow_template_table_create()`)와 큐 기반 비동기 삽입(`rte_flow_async_create()`)이 추가되었다. 스토리지에서는 NVMe/TCP나 RDMA 이외 트래픽을 분리하거나, 특정 흐름을 특정 큐/코어에 고정하는 데 쓸 수 있다.

### 4.6 AF_XDP PMD와 인터럽트 모드
- **AF_XDP PMD** (`net_af_xdp`, 19.05): NIC를 커널 드라이버에 둔 채 AF_XDP 소켓으로 큐를 받아 DPDK 애플리케이션에 노출한다. vdev 인자로 `iface`, `start_queue`, `queue_count`, `shared_umem`, `xdp_prog`, `busy_budget`, `force_copy`, `use_cni` 등이 있다. 문서상 커널 요구사항은 need_wakeup·zero-copy 5.4 이상, shared UMEM 5.10 이상, busy polling 5.11 이상이다. 성능은 네이티브 PMD보다 낮지만 커널 관리 도구·다른 큐의 커널 트래픽을 유지할 수 있다.
- **Rx 인터럽트 모드**: `rte_eth_dev_rx_intr_enable()`/`rte_eth_dev_rx_intr_ctl_q()`로 큐 인터럽트를 epoll 인스턴스에 등록하고 `rte_epoll_wait()`로 잠든다. 트래픽이 적을 때 폴링을 멈추는 하이브리드 운용에 쓴다(VFIO의 MSI-X eventfd 사용).
- **PMD 전원 관리 API**: monitor(디스크립터 주소 감시 후 저전력 대기, 플랫폼 지원 필요), pause, scale(주파수 조절) 모드. 코드 변경 최소화가 목표다.

### 4.7 SPDK가 DPDK에서 가져다 쓰는 것
| DPDK 구성 요소 | SPDK에서의 역할 | SPDK 측 위치 (→ 07/01) |
|---|---|---|
| `rte_eal_init()`, EAL 인자 | `spdk_env_init()`이 SPDK 옵션을 EAL 인자로 변환해 호출 | `lib/env_dpdk/init.c` |
| hugepage, memseg, `rte_mem_event_callback_register()` | DMA 가능 메모리(`spdk_dma_malloc()` 등)와 vtophys 맵 갱신 | `lib/env_dpdk/memory.c` |
| `vfio-pci`/UIO 바인딩, PCI 버스 | NVMe 컨트롤러 BAR 매핑과 DMA | `scripts/setup.sh`, `lib/env_dpdk/pci*.c` |
| `rte_mempool` | `spdk_mempool_*` 구현 | `lib/env_dpdk/env.c` |
| `rte_ring` | `spdk_ring_*`, 스레드 간 메시지 전달 | `lib/env_dpdk/env.c` |
| lcore | reactor 스레드(코어당 하나)의 기반 | `lib/event` |
| ethdev PMD | NVMe-oF/TCP 기본 경로에서는 사용하지 않음(커널 소켓) | `module/sock/{posix,uring}` |

SPDK의 `env` 계층은 DPDK에 직접 의존하지 않는 인터페이스이고 `env_dpdk`가 기본 구현이므로, 이론적으로 다른 환경 구현으로 교체할 수 있다. 실무에서는 DPDK 버전 호환성(SPDK 릴리스마다 지원 DPDK 범위)이 업그레이드 제약이 된다 `[추측/미확인: 버전별 지원 범위는 SPDK 릴리스 노트 확인 필요]`.

### 4.8 데이터패스 비교
| 항목 | DPDK 네이티브 PMD | DPDK AF_XDP PMD | 커널 소켓 (+busy poll) |
|---|---|---|---|
| 장치 소유 | DPDK 프로세스 (`vfio-pci`), bifurcated 예외 | 커널 드라이버, 일부 큐만 XSK | 커널 |
| DMA 주소 | IOVA(VA/PA) 직접 관리 | UMEM, 커널이 DMA 매핑 | 커널 |
| 패킷 메타데이터 | `rte_mbuf` (2 캐시 라인) | `rte_mbuf`로 변환/연결 | `sk_buff` |
| 전송 계층 | 없음(사용자 구현/라이브러리) | 없음 | 커널 TCP |
| 유휴 CPU | 100% (인터럽트/전원 모드 옵션) | busy poll 또는 `poll()` | 인터럽트 기본 |
| 격리/보안 | IOMMU(VFIO) 의존, UIO는 보호 없음 | 커널 권한 모델 | 커널 권한 모델 |

### 4.9 연표
| 릴리스 | 변경 |
|---|---|
| 17.02 | `rte_flow` 도입 |
| 2017-04-03 | Linux Foundation 프로젝트로 이관 발표 |
| 17.08 | `rte_flow` isolated mode(`rte_flow_isolate()`) 추가 |
| 17.11 | IOVA 용어 도입(`rte_iova_t` 등 별칭) |
| 18.05 | 메모리 서브시스템 재작성(동적 hugepage) |
| 19.05 | AF_XDP PMD |
| 19.08 | 대부분의 경우 IOVA as VA 기본 |
| 20.11 | `igb_uio`를 dpdk-kmods로 분리, `rte_flow` 스레드 안전성 표시 |
| 22.03 | `rte_flow` 템플릿 API, 비동기 규칙 삽입(`rte_flow_async_create()`) |
| 23.11 | KNI 라이브러리·드라이버 제거 |

---

## 5. Primary References

- [Environment Abstraction Layer (EAL) Library — DPDK documentation](https://doc.dpdk.org/guides/prog_guide/env_abstraction_layer.html) — 동적/legacy 메모리, IOVA 모드 결정 규칙, lcore, multi-process.
- [Linux Drivers — DPDK documentation](https://doc.dpdk.org/guides/linux_gsg/linux_drivers.html) — `vfio-pci` 권고, no-IOMMU, UIO 경고, bifurcated driver.
- [Packet (Mbuf) Library — DPDK documentation](https://doc.dpdk.org/guides/prog_guide/mbuf_lib.html) — `rte_mbuf` 레이아웃, headroom, 오프로드 플래그, 동적 필드.
- [Memory Pool Library — DPDK documentation](https://doc.dpdk.org/guides/prog_guide/mempool_lib.html) — per-core 캐시, mempool 핸들러.
- [Ring Library — DPDK documentation](https://doc.dpdk.org/guides/prog_guide/ring_lib.html) — CAS 기반 링, RTS/HTS 모드.
- [Generic flow API — DPDK documentation](https://doc.dpdk.org/guides/prog_guide/ethdev/flow_offload.html) — `rte_flow` 규칙 모델, isolated mode, 템플릿 API.
- [AF_XDP Poll Mode Driver — DPDK documentation](https://doc.dpdk.org/guides/nics/af_xdp.html) — vdev 인자와 커널 버전 요구사항.
- [Power Management — DPDK documentation](https://doc.dpdk.org/guides/prog_guide/power_man.html) — PMD 전원 관리(monitor/pause/scale).
- [DPDK Release 19.08 — DPDK documentation](https://doc.dpdk.org/guides/rel_notes/release_19_08.html) — IOVA as VA 기본화.
- [DPDK Release 20.11 — DPDK documentation](https://doc.dpdk.org/guides/rel_notes/release_20_11.html) — `igb_uio`의 dpdk-kmods 이전.
- [DPDK Release 23.11 — DPDK documentation](https://doc.dpdk.org/guides/rel_notes/release_23_11.html) — KNI 제거.
- [Virtio_user as Exception Path — DPDK documentation](https://doc.dpdk.org/guides/howto/virtio_user_as_exception_path.html) — KNI 대안으로서의 virtio-user 예외 경로.
- [DPDK Stable Releases and Long Term Support — DPDK documentation](https://doc.dpdk.org/guides/contributing/stable.html) — X.11 LTS, 3년 유지 정책.
- [The eXpress Data Path (CoNEXT '18, ACM DL)](https://dl.acm.org/doi/10.1145/3281411.3281443) — DPDK/XDP/커널 스택 성능 비교 측정.
- [spdk/spdk lib/env_dpdk/init.c (GitHub)](https://github.com/spdk/spdk/blob/master/lib/env_dpdk/init.c) — SPDK의 `rte_eal_init()` 호출 지점.
- [[dpdk-announce] DPDK joins The Linux Foundation (dpdk dev mailing list, 2017-04)](https://mails.dpdk.org/archives/dev/2017-April/062967.html) — 거버넌스 이관 공지(프로젝트 공식 메일링 리스트).
