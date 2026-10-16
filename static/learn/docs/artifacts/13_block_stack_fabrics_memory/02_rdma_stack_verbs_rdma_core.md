# 리눅스 RDMA 스택: ib_core, uverbs ioctl uAPI, rdma-core, 메모리 등록, 전송 계열과 커널 ULP

> 기준: Linux `torvalds/linux` master(7.3-rc7, 2026-10 확인)의 `drivers/infiniband/core/{verbs.c,cq.c,rw.c,umem.c,umem_odp.c,umem_dmabuf.c,uverbs_main.c,uverbs_ioctl.c,uverbs_uapi.c,uverbs_std_types_dmabuf.c,frmr_pools.c,nldev.c,cma.c,roce_gid_mgmt.c}`, `include/rdma/{ib_verbs.h,ib_umem.h,ib_umem_odp.h,rw.h}`, `include/uapi/rdma/{ib_user_ioctl_cmds.h,rdma_netlink.h,rdma_user_ioctl_cmds.h}`. 사용자 공간은 `linux-rdma/rdma-core` master(최신 릴리스 v65.0, 2026-09-06)의 `libibverbs/verbs.h`, `libibverbs/libibverbs.map.in`, `providers/mlx5/qp.c`, `librdmacm/rdma_cma.h`. 기능 도입 버전은 파일·심볼을 처음 추가한 커밋이 처음 포함된 커널 릴리스다. NVMe-oF RDMA/TCP 전송 비교는 (→ 03/03), P2PDMA는 (→ 08/02), dma-buf importer 생태계와 `nvidia-peermem`은 (→ 08/03), IOMMU 매핑 비용은 (→ 12/01), DAOS의 libfabric 기반 사용자 공간 RDMA는 (→ 10/01)을 참조한다.

## 1. Verdict

**기준 버전: Linux 7.3-rc7 master, rdma-core v65.0.**

리눅스 RDMA 스택은 "**제어 경로는 커널, 데이터 경로는 사용자 공간 또는 커널 ULP가 직접**"이라는 분업 구조다. 커널(`ib_core` + 하드웨어 드라이버)은 PD·MR·QP·CQ 같은 객체를 만들고, 메모리를 고정(pin)하고 DMA 매핑하며, 접근 키(lkey/rkey)와 보호 도메인으로 격리를 보장한다. 이후 작업 요청(WR) 게시와 완료 폴링은 커널을 지나지 않는다. 사용자 공간 provider(예: rdma-core의 `providers/mlx5`)가 mmap된 큐 메모리에 WQE를 쓰고 MMIO doorbell을 직접 울린다. 이 문서의 결론은 다섯 가지다.

1. **uAPI는 write()에서 ioctl로 옮겨 갔고, 동기는 보안이었다.** 2016년 Jann Horn의 보고로 `write()`를 양방향 ioctl처럼 쓰던 설계가 안전하지 않다는 것이 드러났다. Jason Gunthorpe의 `e6bd18f57aad` "IB/security: Restrict use of the write() interface"(v4.6-rc6)가 응급 조치였다. 장기 해법인 TLV 기반 `RDMA_VERBS_IOCTL`은 Matan Barak의 `fac9658cabb9` "IB/core: Add new ioctl interface"로 v4.14에 들어왔다. 이후 명령은 객체-메서드-속성 트리(`uverbs_uapi.c`의 radix tree, v4.19)로 기술되고, 드라이버별 확장 메서드를 공통 파서가 검증한다. 7.3-rc7에도 `ib_uverbs_write()`는 남아 있지만 `ib_safe_file_access()` 검사를 거치는 레거시 경로다.
2. **메모리 등록이 RDMA 비용의 중심이다.** `ib_umem_get()`은 `pin_user_pages_fast()`를 `FOLL_LONGTERM`으로 호출하고 `RLIMIT_MEMLOCK`에 대해 `mm->pinned_vm`을 계산한다. 이 고정 비용과 메모리 과점유를 줄이려는 세 갈래가 있다. ① **ODP**(On-Demand Paging, v3.19, `8ada2c1c0c1d`)는 고정 없이 NIC 페이지 폴트로 매핑한다. v4.11에 implicit ODP(mlx5), v5.0에 `ibv_advise_mr()` prefetch, v5.10에 `hmm_range_fault()` 기반 재작성이 이어졌다. ② **dma-buf MR**(v5.12, `368c0159d492`)은 GPU 등 장치 메모리를 struct page 없이 MR로 가져온다. 2021년 pinned 변형(v5.16)이 추가됐고, 2026년에는 revocable pinned import(v7.1)가 추가됐다. ③ **커널 ULP의 fast registration**(`IB_WR_REG_MR`)과 v7.1의 범용 `frmr_pools`는 MR 객체 재사용으로 등록 지연을 줄인다.
3. **방향은 "RDMA 장치가 dma-buf 생태계의 양방향 참여자"가 되는 것이다.** v5.12까지 RDMA는 dma-buf importer였다. v7.0에는 `UVERBS_OBJECT_DMABUF`(`0ac6f4056c4a`)가 들어와 RDMA 장치의 PCI 메모리(장치 메모리, mlx5 UAR 페이지)를 dma-buf fd로 **내보낸다**. 같은 흐름에서 v6.15 UCAP(세분화된 펌웨어 기능 권한)와 v6.17 DMAH(TPH 등 DMA 속성 핸들) 객체가 추가됐다. 새 기능의 대부분은 NVIDIA(구 Mellanox) 개발자가 주도하고, Leon Romanovsky와 Jason Gunthorpe가 메인테이너로 병합한다.
4. **전송 계열은 세 가지지만 verbs 추상은 하나다.** InfiniBand(전용 링크 계층, SM이 관리), RoCE(v1은 L2 Ethertype, v2는 UDP/IP 목적지 포트 `ROCE_V2_UDP_DPORT` 4791), iWARP(TCP 위 DDP/RDMAP, 커널 `iwcm`과 port mapper `iwpm`)가 같은 `struct ib_device` 콜백 테이블로 노출된다. 소프트웨어 구현 `rdma_rxe`(Soft-RoCE, v4.8)와 `siw`(Soft-iWARP, v5.3)는 RDMA NIC 없이 일반 NIC 위에서 같은 API를 제공한다. 둘은 성능 장치가 아니라 개발·테스트·상호 운용성 도구다.
5. **"RDMA vs TCP"는 대체 논쟁이 아니라 운영 비용 논쟁이다.** Microsoft(SIGCOMM '16, NSDI '23)와 Alibaba(NSDI '21)는 RoCEv2를 스토리지 백엔드에 대규모로 배포했다고 보고했다. Azure는 "around 70% of traffic in Azure is RDMA"라고 적었다. 대가는 PFC 교착·pause storm, NIC 간 상호 운용성, RDMA/TCP 전환(fallback) 같은 운영 장치였다. 반대편에서는 eRPC(NSDI '19)가 손실 이더넷 위 일반 RPC로 RDMA급 성능을 냈고, 커널은 NVMe/TCP(→ 03/03), devmem TCP·io_uring zcrx(→ 08/03)로 TCP 쪽 복사 비용을 줄이고 있다. 결론은 "RDMA는 CPU 효율이 가장 중요하고 패브릭을 직접 통제하는 곳, TCP는 보편성과 운영 단순성이 중요한 곳"이다.

| 커널 | 변화 | 의미 |
|---|---|---|
| 2.6.18 / 2.6.24·2.6.25 / 2.6.30 | iSER 개시자 / NFS/RDMA 클라이언트·서버 / RDS-IB | 초기 커널 ULP |
| 3.3 / 3.10 | SRP 타깃(`ib_srpt`) / iSER 타깃(`isert`) | LIO 타깃 쪽 RDMA |
| 3.19 | ODP(`umem_odp.c`) | 고정 없는 MR |
| 4.5 | `ib_alloc_cq()`, `enum ib_poll_context` | ULP 완료 처리 표준화 |
| 4.6-rc6 | write() 인터페이스 제한 | uverbs 보안 수정 |
| 4.7 | `rdma_rw_ctx` 범용 RDMA READ/WRITE API | 타깃 ULP 공통화 |
| 4.8 | `rdma_rxe`(Soft-RoCE) | 소프트웨어 RoCEv2 |
| 4.11 | SMC(`net/smc`), implicit ODP(mlx5) | 소켓 투명 RDMA |
| 4.14 | `RDMA_VERBS_IOCTL`, RDMA netlink `nldev` | 새 uAPI, `rdma` 도구 기반 |
| 4.16 | `restrack`(자원 추적) | `rdma resource show` |
| 5.0 | `advise_mr`(ODP prefetch) | ODP 폴트 비용 선지불 |
| 5.3 | `siw`(Soft-iWARP) | 소프트웨어 iWARP |
| 5.8 | 공유 CQ 풀(`ib_cq_pool_get`), RTRS/RNBD | CQ 수 절감, RDMA 블록 장치 |
| 5.10 | ODP의 `hmm_range_fault()` 전환 | mm 통합 |
| 5.12 / 5.16 | dma-buf MR / pinned dma-buf MR | GPU 메모리 직접 등록 |
| 6.15 / 6.17 | UCAP / DMAH | 권한·DMA 속성 객체 |
| 7.0 | `UVERBS_OBJECT_DMABUF`(dma-buf export) | RDMA 장치 메모리 내보내기 |
| 7.1 | `frmr_pools`, revocable pinned dma-buf import | MR 재사용, VFIO 등 revoke 필요 exporter 지원 |

---

## 2. Problem Statement

### 2.1 소켓 경로의 고정 비용

TCP 소켓 수신은 커널이 패킷을 skb로 받고, 프로토콜을 처리하고, `recvmsg()` 시점에 사용자 버퍼로 복사하는 구조다. 송신도 시스템 콜, 소켓 락, 체크섬·세그먼트 처리를 거친다(→ 04 시리즈). 100~400Gbps NIC에서 이 경로는 코어 여러 개를 소비한다. RDMA는 이 비용을 NIC으로 옮긴다. 신뢰성 있는 전송(RC QP의 순서·재전송), 원격 메모리 주소 해석(rkey → MR → DMA 주소), 데이터 배치를 NIC이 맡는다. 호스트 CPU는 WR 게시와 완료 확인만 한다. 단방향 연산(RDMA READ/WRITE, atomic)은 원격 CPU를 아예 깨우지 않는다.

### 2.2 커널 바이패스의 대가: 격리와 수명 주기

데이터 경로에서 커널을 빼면 커널이 하던 일을 다른 곳에서 보장해야 한다.

- **주소 공간 격리**: 사용자 프로세스가 임의의 물리 메모리를 NIC에 가리키게 해서는 안 된다. 그래서 모든 버퍼는 사전에 MR로 등록되고, NIC은 lkey/rkey와 PD 검사로 접근을 제한한다.
- **페이지 수명**: NIC이 언제든 DMA할 수 있으므로 등록된 페이지는 이동·회수되면 안 된다. 장기 고정(`FOLL_LONGTERM`)은 메모리 compaction, CMA, THP, fork의 COW와 충돌한다. 이것이 ODP와 dma-buf revoke 모델이 나온 이유다.
- **장치 제거와 프로세스 종료**: 사용자 공간이 큐 메모리와 doorbell 페이지를 mmap하고 있으므로 장치 hot-unplug 때 매핑을 끊어야 한다. uverbs는 `disassociate_srcu`와 드라이버의 `disassociate_ucontext` 콜백으로 이를 처리한다.

### 2.3 uAPI 확장성

RDMA 하드웨어는 벤더별 기능 차이가 크다(mlx5 DevX·steering, EFA SRD, irdma 등). 고정 구조체 기반 write() 명령 체계에서는 기능 하나마다 공통 ABI를 바꾸거나 `udata` blob에 숨겨야 했다. 커널이 내용을 검증할 수 없는 blob은 보안과 유지보수 양쪽에서 부담이었다.

### 2.4 패브릭 운영

RoCEv2는 IP 라우팅이 되지만(→ 03/03), 손실 시 go-back-N 재전송 비용이 크다. 그래서 실무에서는 PFC로 무손실 이더넷을 구성하거나 혼잡 제어(DCQCN 등)를 정밀하게 조정한다. PFC는 교착(deadlock)과 pause frame storm이라는 새로운 장애 유형을 만든다. InfiniBand는 credit 기반 흐름 제어로 이 문제가 덜하지만 별도 패브릭과 Subnet Manager가 필요하다. iWARP는 TCP 위라 손실에 강하지만 NIC에 TCP 오프로드 엔진이 필요해 생태계가 작다.

---
## 3. The Debate

### 3.1 write()를 ioctl처럼 쓰던 uAPI: 보안 사고에서 시작된 재설계

uverbs는 처음부터 `/dev/infiniband/uverbsN`에 `write()`로 명령 구조체를 보내고, 커널이 구조체 안의 사용자 포인터로 응답을 써 주는 방식이었다. 2016년 Jann Horn은 이 패턴이 `write()`의 의미(호출자 자격과 무관하게 fd에 데이터를 쓴다)를 깨뜨린다는 것을 보였다. 예를 들어 setuid 프로그램이 공격자가 넘긴 fd에 쓰게 만들면, 응답이 공격자가 고른 주소로 기록될 수 있다. 수정 커밋의 설명은 다음과 같다.

> "The drivers/infiniband stack uses write() as a replacement for bi-directional ioctl(). This is not safe. There are ways to trigger write calls that result in the return structure that is normally written to user space being shunted off to user specified kernel memory instead. For the immediate repair, detect and deny suspicious accesses to the write API. For long term, update the user space libraries and the kernel API to something that doesn't present the same security vulnerabilities (likely a structured ioctl() interface)."
>
> — Jason Gunthorpe, "IB/security: Restrict use of the write() interface", 2016-04-10 ([github.com/torvalds/linux/commit/e6bd18f57aad](https://github.com/torvalds/linux/commit/e6bd18f57aad1a2d1ef40e646d03ed0f2515c9e3))

해설: 커밋에는 `Signed-off-by: Linus Torvalds`가 함께 붙어 있다. 응급 조치는 `ib_safe_file_access()`로 "현재 호출자의 자격(`current_cred()`)이 fd를 연 시점의 자격(`filp->f_cred`)과 같을 때만" write를 허용하는 것이었다. 7.3-rc7의 `include/rdma/ib.h`에서 이 함수는 `return filp->f_cred == current_cred();` 한 줄이며, `ib_uverbs_write()`가 여전히 이를 호출한다. "structured ioctl()"이라는 장기 과제는 1년여 뒤 Mellanox의 Matan Barak이 제출한 시리즈로 구체화됐다.

> "We introduce a hierarchal object-method-attributes structure. Adding an entity to this hierarchy doesn't affect the rest of the interface. Such a hierarchy could be rooted in a specific device and describes both the common features and features which are unique to this specific device."
>
> — Matan Barak, "[PATCH rdma-next V1 00/13] IB/core: SG IOCTL based RDMA ABI", 2017-08-03 ([lwn.net/Articles/733179](https://lwn.net/Articles/733179/))

해설: 쟁점은 "공통 ABI를 얼마나 고정할 것인가"였다. 커버 레터는 uverbs의 역할을 (a) 명령의 기본 속성 검증, (b) IDR/uobject 관리와 락킹, (c) ABI→커널 API 변환으로 나누고, (a)와 (b)만 공통 코드로 남기고 나머지는 드라이버가 객체·메서드·속성을 선언하게 했다. 속성 클래스는 `PTR_IN`, `PTR_OUT`, `IDR_OBJECT`, `FD_OBJECT`다. 커널은 객체 ID를 커널 포인터로 바꾸고 형식을 검증한다. 드라이버 고유 기능도 같은 파서를 통과하므로 `udata` blob보다 검증 범위가 넓다. 이 설계는 v4.14에 들어갔다. v4.19에서 Jason Gunthorpe가 사양을 런타임 radix tree로 빌드하는 `uverbs_uapi.c`로 재구성했다. 이후 mlx5 DevX처럼 펌웨어 명령을 거의 그대로 노출하는 확장이 이 틀 위에 올라왔다. 이것이 "커널이 하드웨어 기능을 이해하지 못한 채 통로만 제공한다"는 비판의 대상이 되기도 한다. v6.15의 UCAP 커밋은 이 긴장에 대한 한 가지 답이다. 커밋은 기존 Linux capability가 "too generic for certain FW features"라며 기능별 문자 장치를 두고 root가 `chown` 등으로 권한을 위임하게 했다.

### 3.2 고정(pin) vs ODP vs dma-buf: 등록된 메모리는 누구의 것인가

장기 고정은 RDMA가 mm 서브시스템과 가장 오래 충돌해 온 지점이다. `FOLL_LONGTERM`으로 고정된 페이지는 migration·compaction 대상에서 빠지고, `ZONE_MOVABLE`/CMA 영역에서는 고정 전에 다른 곳으로 옮겨진다. fsdax 파일 페이지에는 장기 고정이 아예 거부된다. 그래서 파일 시스템 DAX 위의 RDMA는 ODP가 아니면 불가능하다.

ODP는 이 문제를 NIC 쪽 페이지 테이블로 푼다. 첫 커밋(Shachar Raindel 작성, Haggai Eran·Sagi Grimberg 등 서명, v3.19)은 umem에 ODP 정보를 붙이고, 이후 MMU notifier로 무효화를 받아 NIC 매핑을 지우게 했다. 7.3-rc7 `struct ib_umem_odp`는 `struct mmu_interval_notifier notifier`, `struct hmm_dma_map map`, 매핑 직렬화용 `umem_mutex`, implicit 여부 `is_implicit_odp`를 가진다. 폴트 처리 `ib_umem_odp_map_dma_and_lock()`은 `mmu_interval_read_begin()`으로 시퀀스를 잡고 `hmm_range_fault()`로 PFN을 채운 뒤, 드라이버가 NIC 페이지 테이블을 갱신하는 동안 `umem_mutex`를 잡은 채로 반환한다. 트레이드오프는 분명하다. 고정이 없어 등록이 빠르고 메모리를 과점유하지 않는다. 대신 첫 접근에서 NIC 페이지 폴트가 생긴다. 이 폴트는 RC 전송에서 RNR(Receiver Not Ready) NAK나 재전송 지연으로 나타난다. `ibv_advise_mr()`(v5.0)는 이 비용을 미리 치르는 prefetch다. ODP를 지원하는 하드웨어는 사실상 mlx5 계열이 중심이고, 소프트웨어 `rxe`에도 ODP 경로가 있다(`drivers/infiniband/sw/rxe/rxe_odp.c`).

dma-buf MR은 다른 문제를 푼다. GPU 메모리에는 struct page가 없거나 GUP가 거부되므로 `ib_umem_get()`으로 등록할 수 없다. Jianxin Xiong(Intel)의 v5.12 커밋은 "Dma-buf is a standard cross-driver buffer sharing mechanism that can be used to support peer-to-peer access from RDMA devices"라고 동기를 적었다. 초기 구현은 dynamic attach였다. exporter가 메모리를 옮길 때 `move_notify`로 importer에게 알리고, importer는 NIC 매핑을 무효화한 뒤 다시 매핑해야 한다. 이것은 ODP와 같은 "무효화 가능한 MR" 하드웨어를 전제로 한다. Gal Pressman(Amazon, EFA)의 v5.16 `ib_umem_dmabuf_get_pinned()`는 그런 하드웨어가 없는 드라이버를 위해 exporter에 pin을 요청하는 변형이다. 2026년의 v7.1 시리즈는 그 사이를 채운다. VFIO처럼 "pin은 허용하지만 장치 리셋 때 회수(revoke)해야 하는" exporter를 위해 `pinned_revoke` 콜백을 받는 revocable pinned import를 추가했다. GPU 메모리를 RDMA로 노출하는 out-of-tree 경로(`nvidia-peermem`)와의 관계는 (→ 08/03)을 참조한다.

| 등록 방식 | 진입 함수 | 페이지 고정 | 무효화 | 주 용도 | 한계 |
|---|---|---|---|---|---|
| 일반 MR | `ib_umem_get()` | `pin_user_pages_fast(FOLL_LONGTERM)` | 없음 | 대부분의 사용자 버퍼 | `RLIMIT_MEMLOCK`, migration 차단, fsdax 불가 |
| 명시적 ODP | `ib_umem_odp_get()` | 없음 | `mmu_interval_notifier` | 큰 주소 공간, 과점유 회피 | NIC 폴트 지연, 하드웨어 지원 필요 |
| implicit ODP | `ib_umem_odp_alloc_implicit()` | 없음 | 하위 MR별 notifier | 프로세스 전체 주소 공간 하나의 MR | mlx5 중심 |
| dma-buf(dynamic) | `ib_umem_dmabuf_get()` | exporter가 결정 | `move_notify` → 재매핑 | GPU 메모리, P2P | importer가 무효화 가능해야 함 |
| dma-buf(pinned) | `ib_umem_dmabuf_get_pinned()` | exporter pin | 없음(v7.1부터 revoke 콜백 선택) | EFA 등 무효화 불가 HW | exporter 메모리 이동 불가 |
| 커널 FRWR | `ib_alloc_mr()` + `ib_map_mr_sg()` + `IB_WR_REG_MR` | 호출자(bio 페이지 등)가 보장 | `IB_WR_LOCAL_INV`/SEND_WITH_INV | nvme-rdma, iSER, NFS/RDMA | I/O마다 WR 2개 추가 |

### 3.3 하나의 verbs, 세 개의 전송: 추상화의 비용

verbs는 원래 InfiniBand 사양의 소프트웨어 인터페이스였다. RoCE와 iWARP는 이 추상에 맞춰 들어왔고, 그 흔적이 코드 곳곳에 남아 있다.

- **주소 지정**: IB는 LID/GID와 Subnet Administrator(SA) 경로 질의(`sa_query.c`)를 쓴다. RoCE는 GID 테이블에 IP 주소를 넣는다. `roce_gid_mgmt.c`가 netdev 이벤트를 받아 GID 항목을 만들고, 항목마다 `IB_GID_TYPE_ROCE`(v1)와 `IB_GID_TYPE_ROCE_UDP_ENCAP`(v2) 유형이 붙는다. iWARP는 GID 대신 TCP 4-튜플을 쓰므로 연결 관리가 IB CM이 아니라 `iwcm.c`로 간다. 사용자 공간 TCP와의 포트 충돌을 피하려고 netlink 기반 port mapper(`iwpm_msg.c`, `RDMA_NL_IWCM`)도 둔다.
- **RDMA CM이 차이를 숨긴다.** `rdma_cm`(`cma.c`)은 IP 주소와 포트로 `rdma_resolve_addr()` → `rdma_resolve_route()` → `rdma_connect()`/`rdma_listen()`/`rdma_accept()`를 제공하고, 하부에서 IB CM, RoCE GID 해석, iWARP CM 중 하나를 고른다. nvme-rdma가 `rdma_create_id(..., RDMA_PS_TCP, IB_QPT_RC)`로 시작하는 것(→ 03/03)은 이 추상 덕에 세 전송에서 같은 코드가 돈다는 뜻이다. 사용자 공간은 `librdmacm`이 `/dev/infiniband/rdma_cm`(`ucma.c`)을 통해 같은 의미론을 제공한다.
- **기능 비대칭**: atomic, UD QP, XRC, ODP, 멀티캐스트는 전송이나 장치에 따라 지원 여부가 다르다. 애플리케이션은 `ibv_query_device_ex()`로 능력을 확인해야 하므로 "verbs로 쓰면 어디서나 돈다"는 기대는 연결형 SEND/RECV와 RDMA READ/WRITE 정도에만 성립한다.

소프트웨어 구현은 이 추상의 시험대다. `rdma_rxe`(Soft-RoCE)는 v4.8에 들어왔다. 일반 netdev 위에서 UDP 4791로 RoCEv2 패킷을 만들고 받으며, `rdma link add rxe0 type rxe netdev eth0`(netlink `RDMA_NLDEV_CMD_NEWLINK`)로 붙인다. `siw`(Soft-iWARP, Bernard Metzler, v5.3)는 커널 TCP 소켓 위에서 iWARP를 구현한다. 둘 다 데이터 복사와 CPU 처리를 소프트웨어로 하므로 RDMA의 CPU 효율 이점은 없다. 쓸모는 세 가지다. RDMA NIC 없는 CI에서 ULP·애플리케이션 테스트(blktests 문서에 따르면 nvme/srp 그룹의 RDMA 테스트는 기본으로 siw를 쓰고, `USE_RXE=1`이면 rdma_rxe를 쓴다), 하드웨어 NIC과의 상호 운용성 확인, 한쪽만 RDMA NIC이 있는 비대칭 구성이다. rxe는 메인라인에서 여러 차례 버그·유지보수 부담이 지적돼 왔지만, 7.3-rc7 기준 제거되지 않았다.

### 3.4 RDMA vs TCP: 데이터센터 운영자의 보고와 반론

이 논쟁의 1차 근거는 메일링 리스트보다 대규모 운영 보고 논문에 있다. 커널 NVMe-oF 전송 논쟁(Sagi Grimberg의 nvme-tcp 도입 배경)은 (→ 03/03)에서 다뤘으므로 여기서는 반복하지 않는다.

**RDMA 진영의 운영 보고.** Microsoft의 SIGCOMM '16 논문 "RDMA over Commodity Ethernet at Scale"은 RoCEv2를 VLAN 너머로 확장하려고 DSCP 기반 PFC를 설계했다. 그리고 PFC가 만드는 교착, RDMA 전송 livelock, NIC PFC pause frame storm을 어떻게 막았는지 보고했다. 같은 회사의 NSDI '23 논문은 범위를 지역(region) 단위로 넓혔다.

> "Today, around 70% of traffic in Azure is RDMA and intra-region RDMA is supported in all Azure public regions. RDMA helps us achieve significant disk I/O performance improvements and CPU core savings."
>
> — Wei Bai 외, "Empowering Azure Storage with RDMA", NSDI '23 초록 ([usenix.org](https://www.usenix.org/conference/nsdi23/presentation/bai))

해설: 같은 초록은 "the problem of interoperability between different types of RDMA network interface cards"를 새 과제로 꼽는다. RDMA의 이점(디스크 I/O 성능, CPU 코어 절감)이 실재한다는 보고와, 그 이점을 얻기 위해 인프라 전체를 바꿔야 했다는 보고가 한 문단에 같이 있다. Alibaba의 NSDI '21 논문 "When Cloud Storage Meets RDMA"(Pangu)도 같은 구조다. 초록은 무손실 이더넷 위 RDMA를 "the most promising answer for network bottleneck in cloud storage"라고 부르면서, 신뢰성을 위해 "RDMA/TCP switching as a final resort"를 두었다고 적었다. 즉 대규모 배포자도 TCP를 안전망으로 유지한다.

**반론: 범용 경로로도 충분하다.** Kalia 등의 NSDI '19 논문 "Datacenter RPCs can be General and Fast"(eRPC)는 RDMA·무손실 네트워크 같은 특수 기술이 필요하다는 통념에 반박한다. 초록에 따르면 eRPC는 손실 이더넷에서도 동작하며, 마이크로벤치마크에서 코어 하나가 초당 최대 1,000만 개의 작은 RPC를 처리하거나 75Gbps로 큰 메시지를 보냈다. Raft 복제 지연은 5.5µs로, RDMA를 쓰는 특수 시스템과 같거나 빨랐다. 다만 eRPC는 DPDK 등 사용자 공간 패킷 I/O 위의 라이브러리이므로 "커널 TCP가 RDMA만큼 빠르다"는 근거는 아니다. 같은 저자들의 ATC '16 논문 "Design Guidelines for High Performance RDMA Systems"는 반대 방향에서 같은 결론을 보강한다. RDMA 성능은 연산 선택, PCIe 트랜잭션, NIC 구조 같은 저수준 세부에 크게 좌우되므로 "RDMA를 쓰면 자동으로 빠르다"가 아니다.

**커널 쪽 수렴.** 리눅스는 두 방향을 모두 받아들였다. TCP 쪽에서는 NVMe/TCP, 송신 `MSG_SPLICE_PAGES`, 수신 devmem TCP(6.12)와 io_uring zcrx(6.15)로 복사를 줄인다(→ 03/03, 08/03). RDMA 쪽에서는 dma-buf import/export와 P2PDMA(→ 08/02)로 GPU·가속기 메모리를 직접 연결한다. 두 방향 모두 dma-buf라는 같은 메모리 공유 추상으로 모이고 있다. 현재 실무의 쟁점은 "어느 쪽이 이기느냐"가 아니라 "패브릭 운영(PFC/혼잡 제어)과 NIC 상호 운용성을 감당할 조직인가"다.

---

## 4. Implementation Impact

### 4.1 객체 모델과 수명 주기

커널 객체는 `include/rdma/ib_verbs.h`에 있다. `struct ib_device`는 드라이버 콜백 테이블 `struct ib_device_ops ops`를 가지며, verbs 함수 대부분은 이 테이블로 바로 내려가는 얇은 inline이다. 예를 들어 `ib_post_send()`는 `qp->device->ops.post_send(qp, send_wr, bad_send_wr ? : &dummy)` 한 줄이다. 핵심 객체 관계는 다음과 같다.

- `struct ib_pd`: 보호 도메인. 같은 PD의 MR·QP·SRQ·AH만 서로를 참조할 수 있다. 커널 ULP는 `ib_alloc_pd(device, flags)` 매크로(`__ib_alloc_pd(..., KBUILD_MODNAME)`)로 얻는다. `IB_PD_UNSAFE_GLOBAL_RKEY`는 모든 메모리에 원격 접근을 여는 위험한 플래그라 nvme-rdma에서도 `register_always=N`일 때만 쓴다(→ 03/03).
- `struct ib_mr`: lkey/rkey, iova, 길이. 사용자 MR은 `struct ib_umem`(일반), `struct ib_umem_odp`, `struct ib_umem_dmabuf`를 품는다. 접근 플래그는 `IB_ACCESS_LOCAL_WRITE`, `IB_ACCESS_REMOTE_{READ,WRITE,ATOMIC}`, `IB_ACCESS_ON_DEMAND`, `IB_ACCESS_RELAXED_ORDERING`, 영속 메모리용 `IB_ACCESS_FLUSH_GLOBAL`/`IB_ACCESS_FLUSH_PERSISTENT` 등이 있다.
- `struct ib_qp`: 송신 큐(SQ)와 수신 큐(RQ) 쌍. 유형은 `enum ib_qp_type`의 `IB_QPT_RC`/`UC`/`UD`/`RAW_PACKET`/`XRC_INI`/`XRC_TGT`와 관리용 `IB_QPT_SMI`/`GSI`, 드라이버 고유 `IB_QPT_DRIVER`(EFA SRD, mlx5 DCT 등)다. 상태는 RESET → INIT → RTR → RTS로 `ib_modify_qp()`가 전이시킨다.
- `struct ib_srq`: 여러 QP가 공유하는 수신 큐. 연결 수 N에 비례하던 수신 버퍼를 하나로 모은다. nvmet-rdma의 `use_srq`가 예다.
- `struct ib_cq`: 완료 큐. 하나의 CQ를 여러 QP의 SQ/RQ가 공유할 수 있다.

사용자 객체는 `struct ib_uobject`로 감싸지고, uverbs ioctl이 객체 ID ↔ 커널 포인터 변환과 락(공유/배타)을 처리한다. 진입점은 `ib_uverbs_ioctl()` → `ib_uverbs_cmd_verbs()` → `ib_uverbs_run_method()`다. 메서드 사양은 `uverbs_uapi.c`가 장치별 radix tree로 만들고, `uapi_get_method()` 계열 조회로 찾는다. 프로세스 종료나 장치 제거 때 `uverbs_destroy_ufile_hw()`가 객체를 의존 역순으로 파괴한다. hot-unplug 시에는 `uverbs_user_mmap_disassociate()`가 사용자 mmap(doorbell·큐 페이지)의 PTE를 지운다. 이후 그 VMA에 접근하면 `rdma_umap_fault()`가 dummy zero page를 돌려준다. 사용자 프로세스는 SIGBUS로 죽지 않고, 다음 verbs 호출에서 오류를 받는다.

### 4.2 사용자 공간 데이터 경로: WQE 쓰기와 doorbell

rdma-core의 `ibv_post_send()`는 `libibverbs/verbs.h`의 inline으로, `qp->context->ops.post_send(qp, wr, bad_wr)`를 호출해 provider로 바로 간다. 시스템 콜은 없다. mlx5 provider의 `post_send_db()`(`providers/mlx5/qp.c`)가 doorbell 순서를 잘 보여 준다.

1. WQE를 SQ 버퍼(사용자 메모리, NIC이 DMA로 읽음)에 쓴다.
2. `udma_to_device_barrier()`로 WQE 쓰기가 doorbell record 갱신보다 먼저 보이게 한다.
3. doorbell record `qp->db[MLX5_SND_DBR]`에 SQ 생산자 인덱스를 쓴다(호스트 메모리).
4. `mmio_wc_start()`(또는 공유 UAR이면 `mmio_wc_spinlock()`) 후, WQE가 하나이고 작으면 `mlx5_bf_copy()`로 WQE 전체를 write-combining된 BlueFlame 레지스터에 복사한다. 그렇지 않으면 `mmio_write64_be()`로 제어 세그먼트 8바이트만 doorbell 레지스터에 쓴다.
5. `mmio_flush_writes()`로 WC 버퍼를 비우고 BlueFlame 오프셋을 토글한다.

BlueFlame은 NIC이 WQE를 DMA로 다시 읽어 오는 왕복을 없애는 지연 최적화다. 소스 주석은 WC 플러시를 스핀락 안에서 해야 하는 이유도 적는다. CPU A의 doorbell 1이 WC 버퍼에 머무는 동안 CPU B의 doorbell 2가 먼저 나가면 HCA가 순서를 뒤집어 본다. 수신(`mlx5_post_recv()`)은 RQ WQE를 쓰고 barrier 후 `qp->db[MLX5_RCV_DBR]`만 갱신한다. 완료 폴링은 CQ 버퍼의 소유권 비트를 읽는 순수 메모리 연산이다. 이벤트 모드에서는 `ibv_req_notify_cq()`로 arm하고 completion channel fd에서 기다린다.

rdma-core의 확장 API인 `struct ibv_qp_ex`의 `ibv_wr_start()`/`ibv_wr_*()`/`ibv_wr_complete()`는 연결 리스트 `ibv_send_wr`를 만들지 않고 WQE를 바로 조립한다. 메모리 등록 API는 심볼 버전으로 추적할 수 있다. `libibverbs.map.in`에서 `ibv_reg_mr_iova2`는 `IBVERBS_1.8`, `ibv_reg_dmabuf_mr`는 `IBVERBS_1.12`, `ibv_reg_mr_ex`는 `IBVERBS_1.15`에 있다. rdma-core의 `debian/libibverbs1.symbols`에 따르면 이 세 심볼 버전은 각각 rdma-core 28, 34, 59부터 제공된다. rdma-core master의 provider 디렉토리는 `bnxt_re cxgb4 efa erdma hfi1verbs hns ionic ipathverbs irdma mana mlx4 mlx5 mthca ocrdma qedr rxe siw vmw_pvrdma`다. 커널 쪽의 `bng_re`(Broadcom 차세대)와 `usnic`에 대응하는 provider는 이 목록에 없다. 커널 uAPI 헤더는 rdma-core의 `kernel-headers/`에 복사돼 함께 버전 관리된다.

### 4.3 커널 ULP 경로: CQ 추상, rdma_rw, CQ 풀

커널 ULP는 사용자 공간과 같은 verbs를 쓰지만 완료 처리 방식이 다르다. v4.5에 Christoph Hellwig의 `14d3a3b2498e` "IB: add a proper completion queue abstraction"이 들어오기 전에는 ULP마다 CQ 이벤트 핸들러와 폴링 루프를 따로 구현했다. 지금은 `ib_alloc_cq(dev, private, nr_cqe, comp_vector, poll_ctx)`가 폴링 문맥을 받는다.

- `IB_POLL_SOFTIRQ`: `irq_poll` 기반. `ib_poll_handler()`가 예산 `IB_POLL_BUDGET_IRQ`(256) 안에서 `__ib_process_cq()`를 돌고, 한 번에 `IB_POLL_BATCH`(16)개씩 `ib_poll_cq()`로 꺼낸다.
- `IB_POLL_WORKQUEUE` / `IB_POLL_UNBOUND_WORKQUEUE`: `ib_cq_poll_work()`가 `ib_comp_wq`/`ib_comp_unbound_wq`에서 처리. 완료 처리에서 잠들 수 있어야 하는 ULP(NFS 서버 등)용이다.
- `IB_POLL_DIRECT`: 하드웨어 인터럽트 없이 호출자가 `ib_process_cq_direct()`로 폴링. nvme-rdma의 poll 큐(`REQ_POLLED`)가 쓴다.

완료는 WR의 `struct ib_cqe *wr_cqe`에 담긴 `done` 콜백으로 전달된다. 그래서 ULP는 `wr_id` 해석 테이블 없이 `container_of()`로 요청을 찾는다. 선택적으로 `rdma_dim_init()`이 net DIM을 붙여 인터럽트 조절(moderation)을 적응적으로 바꾼다. v5.8의 공유 CQ 풀(`ib_cq_pool_get()`/`ib_cq_pool_put()`)은 장치·폴링 문맥별로 CQ를 미리 만들어 두고 ULP가 나눠 쓰게 한다. 연결 수가 많은 타깃에서 CQ와 인터럽트 벡터 수를 줄인다. 큐를 닫을 때는 `ib_drain_qp()`로 마지막 WR까지 완료를 받아 수명 문제를 막는다.

타깃 쪽 ULP를 위한 `rdma_rw_ctx_init()`/`rdma_rw_ctx_post()`(v4.7, Hellwig)는 scatterlist 하나로 RDMA READ/WRITE WR 체인을 만든다. 장치 특성에 따라 직접 SGE를 쓸지 MR을 등록할지도 정한다. `rw.c`의 `rdma_rw_io_needs_mr()`은 iWARP에서 RDMA READ(`DMA_FROM_DEVICE`)면 반드시 MR을 쓴다. iWARP의 READ 싱크는 원격 쓰기 권한이 있는 MR이어야 하기 때문이다. IB/RoCE에서는 SGE 수가 `max_sgl_rd`를 넘을 때만 MR을 쓰고, 디버그용 `force_mr` 모듈 파라미터로 강제할 수 있다. T10-PI가 있으면 `rdma_rw_ctx_signature_init()`이 `IB_WR_REG_MR_INTEGRITY` 경로를 만든다. nvmet-rdma, isert, ib_srpt, svcrdma가 이 API를 공유한다. v7.1의 `frmr_pools.c`는 이 위에 "같은 속성의 MR을 RB-tree 풀에 보관했다가 재사용"하는 드라이버용 push/pop API를 더했다. 커밋 설명에 따르면 드라이버와 하드웨어가 MR의 clear/set 수정 연산을 지원해야 하며, netlink에 `RDMA_NLDEV_CMD_FRMR_POOLS_GET`/`SET`이 같이 추가됐다.

### 4.4 커널 ULP 지도

| ULP | 위치 | 도입 | 전송/QP | 상위 인터페이스 | 비고 |
|---|---|---|---|---|---|
| nvme-rdma / nvmet-rdma | `drivers/nvme/{host,target}/rdma.c` | 4.8 | RC, rdma_cm | blk-mq | (→ 03/03) |
| iSER / isert | `drivers/infiniband/ulp/{iser,isert}` | 2.6.18 / 3.10 | RC, rdma_cm | libiscsi / LIO | iSCSI 명령은 SEND, 데이터는 RDMA |
| SRP / SRPT | `drivers/infiniband/ulp/{srp,srpt}` | 2.6.15 / 3.3 | RC, IB CM 또는 rdma_cm | SCSI / LIO | IB 전통 블록 프로토콜 |
| RTRS + RNBD | `drivers/infiniband/ulp/rtrs`, `drivers/block/rnbd` | 5.8 | RC, rdma_cm | 원격 블록 장치 | 다중 경로 내장 |
| NFS/RDMA | `net/sunrpc/xprtrdma` | 클라이언트 2.6.24 / 서버 2.6.25 | RC, rdma_cm | SUNRPC | RPC-over-RDMA, FRWR 등록 |
| SMB Direct | `fs/smb/client/smbdirect.c`, `fs/smb/server/transport_rdma.c` | 클라이언트 4.16 / 서버(ksmbd) 5.15 | RC, rdma_cm | cifs / ksmbd | SMB3 다중 채널과 결합 |
| SMC-R | `net/smc` | 4.11 | RC(RoCE), CLC는 TCP | `AF_SMC`, v6.11부터 `IPPROTO_SMC` | 실패 시 TCP fallback, v6.19 BPF 핸드셰이크 훅 |
| RDS | `net/rds` (`ib*.c`) | 2.6.30 | RC | `AF_RDS` 데이터그램 | Oracle 클러스터 용도 |
| IPoIB | `drivers/infiniband/ulp/ipoib` | git 이력 시작(2.6.12) 이전 | UD/RC | netdev | IB 위 IP |

SMC-R은 이 표에서 성격이 독특하다. 애플리케이션은 TCP 소켓처럼 쓰고, 연결 수립 때 TCP 위 CLC 핸드셰이크로 양쪽이 RoCE를 지원하는지 확인한다. 실패하면 `use_fallback`으로 일반 TCP를 계속 쓴다. "RDMA vs TCP"를 소켓 계층 안에서 투명하게 고르는 시도다.

### 4.5 관리 평면: RDMA netlink, `rdma` 도구, restrack, cgroup

`nldev.c`(v4.14)는 `RDMA_NL_NLDEV` 패밀리로 장치·포트·자원 정보를 노출한다. 명령은 `RDMA_NLDEV_CMD_GET`/`SET`/`PORT_GET`, 소프트웨어 장치 생성·삭제 `NEWLINK`/`DELLINK`, 자원 덤프 `RES_QP_GET`/`RES_CM_ID_GET`/`RES_CQ_GET`/`RES_MR_GET`/`RES_PD_GET`/`RES_CTX_GET`/`RES_SRQ_GET`, 하드웨어 원시 상태 `*_GET_RAW`, 카운터 `STAT_GET`/`STAT_SET`/`STAT_DEL`, 이벤트 `MONITOR`, `FRMR_POOLS_GET`/`SET` 등이다. iproute2의 `rdma` 도구(`rdma dev`, `rdma link`, `rdma resource show qp`, `rdma statistic`)가 이 인터페이스의 사용자다. 자원 덤프의 기반은 v4.16 `restrack.c`다. QP·CQ·MR·PD·CM ID를 생성 시점에 등록해 두고, 소유 프로세스(PID)와 함께 나열한다. "누가 QP를 몇 개 잡고 있나", "어떤 MR이 해제되지 않았나"를 운영 중에 볼 수 있다. 자원 상한은 rdma cgroup(`kernel/cgroup/rdma.c`, `rdma.max`의 `hca_handle`/`hca_object`)으로 건다.

### 4.6 전송 계열 비교

| 항목 | InfiniBand | RoCEv2 | iWARP | rxe (Soft-RoCE) | siw (Soft-iWARP) |
|---|---|---|---|---|---|
| 링크/네트워크 | IB 링크, LID/GID, SM 필요 | 이더넷 + UDP/IP(4791), L3 라우팅 가능 | 이더넷 + TCP/IP | 일반 netdev 위 UDP | 커널 TCP 소켓 |
| 손실 처리 | credit 기반 무손실 | 손실에 민감, 실무상 PFC/ECN | TCP 재전송 | 소프트웨어 재전송 | TCP |
| 연결 관리 | IB CM + SA | IB CM 형식 + GID(IP) 해석 | `iwcm` + `iwpm` | rdma_cm(RoCE 경로) | rdma_cm(iWARP 경로) |
| RDMA READ 싱크 | SGE 직접 가능 | SGE 직접 가능 | MR 필수(`rdma_rw_io_needs_mr`) | SGE 직접 | MR 필수 |
| CPU 효율 | 최고 | 최고 | 높음(NIC TOE) | 낮음(복사·CRC를 CPU가) | 낮음 |
| 주 용도 | HPC, AI 클러스터 | 클라우드 스토리지, AI | 일부 스토리지 | 개발·테스트·상호 운용 | 개발·테스트 |

### 4.7 운영상 함의

- **등록 비용을 데이터 경로 밖으로 뺀다.** 사용자 공간 애플리케이션은 버퍼 풀을 시작 시 한 번 등록하고 재사용하는 것이 정석이다. 등록 지연은 페이지 수에 비례하는 GUP·DMA 매핑과 NIC 변환 테이블 기록이므로, `ib_umem_find_best_pgsz()`가 큰 HW 페이지를 고를 수 있게 hugepage 버퍼를 쓰면 줄어든다. IOMMU가 켜져 있으면 DMA 매핑 비용이 더해진다(→ 12/01).
- **`RLIMIT_MEMLOCK`은 실제 상한이다.** 일반 MR은 `mm->pinned_vm`으로 계산되며, `CAP_IPC_LOCK` 없이 한도를 넘으면 `-ENOMEM`이다. 컨테이너에서는 이 값과 rdma cgroup 한도를 함께 확인해야 한다.
- **ODP는 지연 꼬리를 바꾼다.** 평균 처리량은 비슷해도 첫 접근 폴트와 무효화가 tail latency를 키운다. 스토리지 데이터 경로처럼 접근 패턴이 예측 가능하면 prefetch(`ibv_advise_mr()`)나 일반 MR이 낫다.
- **GPU 메모리는 dma-buf로 간다.** CUDA의 dma-buf fd export와 `ibv_reg_dmabuf_mr()` 조합이 upstream 경로다. out-of-tree peer memory 경로와의 차이는 (→ 08/03)에 있다.
- **소프트웨어 RDMA는 성능 비교 기준이 아니다.** rxe/siw 위 측정은 기능 확인용으로만 쓴다.
- **관측은 netlink로 한다.** `rdma resource show`(restrack)와 `rdma statistic`(하드웨어 카운터)이 1차 진단 도구다. 커널 ULP의 완료 처리 비용은 `IB_POLL_*` 문맥별로 softirq·workqueue 사용률에 나타난다.

| 비교 축 | 레거시(초기 uverbs, ULP별 CQ) | 현재(7.3-rc7) |
|---|---|---|
| uAPI | `write()` + 고정 구조체 + `udata` blob | `RDMA_VERBS_IOCTL` TLV, 객체-메서드-속성 트리, write는 자격 검사 후 호환용 |
| 완료 처리 | ULP별 이벤트 핸들러·폴링 | `ib_alloc_cq()`의 `IB_POLL_*`, `ib_cqe->done`, 공유 CQ 풀, DIM |
| RDMA READ/WRITE 구성 | ULP별 WR 체인 코드 | `rdma_rw_ctx_*` 공통 API, iWARP MR 처리 내장 |
| 사용자 메모리 | 장기 고정만 | 고정 / ODP(`hmm_range_fault`) / dma-buf(dynamic·pinned·revocable) |
| 장치 메모리 공유 | 벤더 전용 경로 | dma-buf import(5.12) + export(7.0) |
| 관리 | sysfs, 벤더 도구 | RDMA netlink + `rdma` 도구 + restrack + rdma cgroup |
| 권한 | Linux capability | capability + UCAP 문자 장치(6.15) |

---

## 5. Primary References

- [IB/security: Restrict use of the write() interface](https://github.com/torvalds/linux/commit/e6bd18f57aad1a2d1ef40e646d03ed0f2515c9e3) — Jason Gunthorpe, 2016-04-10. uverbs write() 보안 수정과 ioctl 전환 예고
- [IB/core: Add new ioctl interface](https://github.com/torvalds/linux/commit/fac9658cabb98afb68ef1630c558864e6f559c07) — Matan Barak, v4.14. `RDMA_VERBS_IOCTL` 도입 커밋
- [[PATCH rdma-next V1 00/13] [PATCH V1 for-next 00/13] IB/core: SG IOCTL based RDMA ABI](https://lwn.net/Articles/733179/) — Matan Barak, 2017-08-03 (LWN 패치 미러). 객체-메서드-속성 설계 근거
- [IB/core: Add support for on demand paging regions](https://github.com/torvalds/linux/commit/8ada2c1c0c1d75a60723cd2ca7d49c594a146af6) — Shachar Raindel·Haggai Eran 외, v3.19. ODP 최초 커밋
- [RDMA/umem: Support importing dma-buf as user memory region](https://github.com/torvalds/linux/commit/368c0159d492d7fbdb5791b40c9263ec4e97a10f) — Jianxin Xiong, v5.12. dma-buf MR
- [RDMA: Add support for exporting dma-buf file descriptors](https://lwn.net/Articles/1056826/) — Edward Srouji, 2026-02-01 (LWN 패치 미러, v3). `UVERBS_OBJECT_DMABUF` export
- [IB/core: Introduce FRMR pools](https://github.com/torvalds/linux/commit/ce5df0b891edfa19620cd7e28bd69246c77ae78c) — Michael Guralnik, v7.1. MR 재사용 풀
- [IB: add a proper completion queue abstraction](https://github.com/torvalds/linux/commit/14d3a3b2498edadec344cb11e60e66091f5daf63) — Christoph Hellwig, v4.5. `ib_alloc_cq()`/`IB_POLL_*`
- [IB/core: generic RDMA READ/WRITE API](https://github.com/torvalds/linux/commit/a060b5629ab066dd1d321430eeb96f70939a1790) — Christoph Hellwig, v4.7. `rdma_rw_ctx`
- [Soft RoCE driver](https://github.com/torvalds/linux/commit/8700e3e7c4857d28ebaa824509934556da0b3e76) — v4.8. `rdma_rxe`
- [include/rdma/ib_verbs.h](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/include/rdma/ib_verbs.h) — 커널 verbs 객체·플래그 정의
- [drivers/infiniband/core/umem_odp.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/infiniband/core/umem_odp.c) — ODP 폴트·무효화 구현
- [linux-rdma/rdma-core](https://github.com/linux-rdma/rdma-core) — libibverbs, librdmacm, provider 공식 저장소
- [rdma-core providers/mlx5/qp.c](https://github.com/linux-rdma/rdma-core/blob/master/providers/mlx5/qp.c) — `post_send_db()`의 doorbell·BlueFlame 순서
- [InfiniBand and Remote DMA (RDMA) Interfaces](https://docs.kernel.org/driver-api/infiniband.html) — 커널 RDMA 드라이버 API 문서
- [RDMA over Commodity Ethernet at Scale](https://dl.acm.org/doi/10.1145/2934872.2934908) — Guo 외, SIGCOMM '16. DSCP 기반 PFC, 교착·pause storm
- [Empowering Azure Storage with RDMA](https://www.usenix.org/conference/nsdi23/presentation/bai) — Bai 외, NSDI '23. 지역 단위 RDMA, Azure 트래픽 약 70%
- [When Cloud Storage Meets RDMA](https://www.usenix.org/conference/nsdi21/presentation/gao) — Gao 외, NSDI '21. Alibaba Pangu, RDMA/TCP 전환
- [Datacenter RPCs can be General and Fast](https://www.usenix.org/conference/nsdi19/presentation/kalia) — Kalia 외, NSDI '19. 손실 이더넷 위 eRPC
- [Design Guidelines for High Performance RDMA Systems](https://www.usenix.org/conference/atc16/technical-sessions/presentation/kalia) — Kalia 외, ATC '16. RDMA 연산·PCIe 수준 설계 지침
