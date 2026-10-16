# GPU가 I/O를 시작할 때: BaM, GPUDirect RDMA/nvidia-peermem, 그리고 dma-buf importer(RDMA MR, devmem TCP, io_uring zcrx)

> 기준: Linux `master`(v7.3-rc7 이후 32커밋, `0fcb05b72344`, 2026-10-14), `NVIDIA/open-gpu-kernel-modules` 615.78.08, GPUDirect RDMA 문서 13.4, BaM 논문(ASPLOS '23, arXiv 2203.04910)과 `ZaidQureshi/bam` README. 커널 기능 도입 버전은 태그별 `git show <tag>:<path> | grep`과 커밋 포함 태그로 고정했다. 성능 수치는 원 출처의 측정 조건과 함께 적고, 출처가 없으면 `[추측/미확인]`으로 표시한다.

## 1. Verdict

GDS와 P2PDMA(→ 08/01, 08/02)는 **데이터 경로**에서 CPU 메모리를 뺐다. 하지만 **제어 경로**는 여전히 CPU에 있다. cuFile API Reference Guide는 "All APIs are issued from the CPU, not the GPU"라고 명시한다. 이 문서는 그 다음 두 갈래를 다룬다.

1. **GPU-initiated storage(BaM)**: GPU 스레드가 직접 NVMe SQ 엔트리를 만들고 doorbell을 울린다. 연구 프로토타입으로 제어 경로에서도 CPU를 뺐다. 대가로 커널 NVMe 드라이버를 unbind하고 장치를 사용자 공간 모듈(`libnvm`)에 넘겨야 한다. 파일시스템, 공유, 격리를 모두 포기하는 셈이다. LSFMM+BPF 2025에서 Stephen Bates는 이 방향을 "the next natural step for peer-to-peer"라고 불렀다. Christoph Hellwig는 장치별 격리와 레이아웃 lease가 먼저라고 반박했다(3.1절).
2. **dma-buf importer 생태계**: GPU 메모리를 struct page 없이 다른 서브시스템에 "빌려주는" 표준 경로는 dma-buf다. RDMA(`ib_umem_dmabuf_get`, 5.12), 네트워크 수신(devmem TCP, 6.12 RX / 6.16 TX), io_uring 수신(zcrx, 6.15 / dma-buf 영역 6.16)이 이미 메인라인에 있다. **블록 스토리지 read/write의 dma-buf 경로는 v7.3-rc7 기준 아직 메인라인에 없다.** Pavel Begunkov의 io_uring dma-buf read/write 시리즈가 LSFMM+BPF 2026에서 논의되는 중이다(3.3절).

결론:

- **NVIDIA의 RDMA 경로도 upstream 표준으로 이동 중이다.** `nvidia-peermem`은 MLNX_OFED의 out-of-tree peer memory API(`ib_register_peer_memory_client`)에 기대는 모듈이다. CUDA는 `cuMemGetHandleForAddressRange(..., CU_MEM_RANGE_HANDLE_TYPE_DMA_BUF_FD, ...)`로 GPU 메모리를 dma-buf fd로 내보내는 경로를 제공한다. CUDA 13.0 문서는 Tegra(Blackwell 기반 SoC부터)에서 nv-p2p API 지원을 끊고 "the Linux upstream kernel API"로 이전을 권한다.
- **struct page 계층(P2PDMA pgmap)과 dma-buf 계층은 경쟁이 아니라 분업이다.** 짧게 pin하는 `O_DIRECT`는 pgmap, 장기 등록과 무효화가 필요한 RDMA MR, 네트워크 큐, io_uring 등록 버퍼는 dma-buf가 맡는다. GDS도 두 경로를 모두 쓴다(`CUFILE_P2PDMA`, `CUFILE_DMABUF`).
- **GPU-initiated I/O가 실용화되려면 커널이 "장치가 큐를 직접 쓰는" 모델을 받아들여야 한다.** 그러려면 NVMe 쪽 격리 기능(큐별 namespace/LBA 제한)이나 별도 컨트롤러 같은 하드웨어 지원이 먼저 필요하다는 것이 2025년 LSFMM 논의의 요지다.

---

## 2. Problem Statement

### 2.1 CPU-initiated 모델의 한계: 세밀하고 데이터 의존적인 접근

BaM 논문 초록(arXiv 2203.04910, ASPLOS '23 확장판)은 문제를 다음처럼 정의한다.

> "Graphics Processing Units (GPUs) have traditionally relied on the host CPU to initiate access to the data storage. This approach is well-suited for GPU applications with known data access patterns that enable partitioning of their dataset to be processed in a pipelined fashion in the GPU. However, emerging applications such as graph and data analytics, recommender systems, or graph neural networks, require fine-grained, data-dependent access to storage."
>
> — Qureshi et al., [GPU-Initiated On-Demand High-Throughput Storage Access in the BaM System Architecture](https://arxiv.org/abs/2203.04910) (arXiv 2022-03-09 제출, ASPLOS '23)

해설: GDS는 "어디를 읽을지 CPU가 미리 아는" 대용량 순차 적재에 맞다. 그래프 탐색(BFS)에서는 다음에 읽을 노드가 GPU 커널 실행 중에야 결정된다. CPU 주도 모델에서는 GPU가 주소 목록을 CPU에 넘기고(동기화), CPU가 I/O를 내고, 완료 후 다시 GPU를 깨워야 한다. 초록은 이 비용을 "high CPU-GPU synchronization overheads, I/O traffic amplification, and long CPU processing latencies"로 요약한다. 페이지 단위로 통째로 읽어 생기는 amplification도 포함된다.

### 2.2 IOPS 요구의 규모

LWN [Device-initiated I/O](https://lwn.net/Articles/1022718/)(Jake Edge, 2025-06-04)에 따르면 Bates는 한 대형 가속기 회사가 "AI workloads need a lot of IOPS", 즉 GPU당 약 2억 IOPS가 필요하다고 주장한다고 소개했다. I/O 크기는 512바이트 미만이고 읽기 전용이다. 같은 발표의 커널 측 수치는 다음과 같다. NVMe 드라이버는 IOMMU pass-through에서 코어당 약 800만 IOPS(Axboe는 특정 Threadripper에서 1,000만~1,200만), IOMMU 매핑이 필요하면 약 200만 IOPS다. 출처는 모두 발표·토론 발언이며 측정 조건은 공개되지 않았다. 이 격차가 CPU 주도 모델로는 메울 수 없는 영역이라는 것이 device-initiated I/O의 동기다.

### 2.3 GPU 메모리를 "빌려주는" 문제

GPU 메모리를 다른 장치(NIC, NVMe, 다른 GPU)의 DMA 대상으로 쓰려면 세 가지가 필요하다. (1) 그 메모리의 버스 주소 목록, (2) GPU 드라이버가 메모리를 옮기거나 해제할 때 상대 장치의 매핑을 무효화하는 프로토콜, (3) 커널이 신뢰할 수 있는 수명 관리다. 역사적으로 해법은 세 가지였다.

- **벤더 API**: `nvidia_p2p_get_pages()` + free callback(`nv-p2p.h`). GDS의 `nvidia-fs`와 `nvidia-peermem`이 쓴다.
- **struct page**: P2PDMA pgmap(→ 08/02). 장기 pin(`FOLL_LONGTERM`)이 금지되고, BAR 전체를 정적으로 노출해야 한다.
- **dma-buf**: exporter가 `struct sg_table`을 제공하고 importer가 `dma_buf_attach`/`dma_buf_map_attachment`로 매핑한다. 동적 importer는 `struct dma_buf_attach_ops`(v5.7 도입)의 콜백으로 무효화를 받는다. 이 콜백 이름은 v7.0까지 `move_notify`였고, v7.1부터 `invalidate_mappings`다(태그별 `include/linux/dma-buf.h` grep). struct page가 필요 없다.

### 2.4 왜 블록 스토리지가 마지막인가

네트워크(devmem TCP, zcrx)와 RDMA는 "버퍼를 미리 등록하고 오래 재사용하는" 모델이라 dma-buf와 잘 맞는다. 블록 I/O는 요청마다 `bio`를 만들고 page 기반으로 split·merge·bounce하는 구조라 dma-buf를 끼워 넣기 어렵다. `blk_rq_dma_map_*` 재작업(6.17, → 08/02)과 struct page 없는 `p2pdma_provider`(6.19)가 그 기반 공사다.

---
## 3. The Debate

### 3.1 device-initiated I/O: 큐를 장치에 넘길 것인가 (LSFMM+BPF 2025)

LWN [Device-initiated I/O](https://lwn.net/Articles/1022718/)(Jake Edge, 2025-06-04)는 Stephen Bates의 세션을 전한다. Bates는 세션 목표를 이렇게 말했다.

> "what the next natural step for peer-to-peer is, and that is device-initiated I/O"
>
> — Stephen Bates, LSFMM+BPF 2025 (LWN [Device-initiated I/O](https://lwn.net/Articles/1022718/), 2025-06-04)

해설: Bates가 그린 모델은 "an accelerator or some other kind of I/O device that has enough intelligence to have code on it that generates NVMe-submission-queue entries and rings doorbells"(같은 기사 인용)가 직접 I/O를 내는 것이다. BaM이 이 모델의 연구 구현이다. 기사에 따르면 Bates는 NVIDIA와 University of Illinois의 GPU 기반 NVMe I/O 논문을 "only a proof of concept"로 언급했다. Hellwig는 Mellanox(현 NVIDIA)가 RDMA에서 그 논문보다 훨씬 전부터 비슷한 일을 했다고 지적했고, Jason Gunthorpe는 그것이 이미 출하 제품의 일부라고 했다.

쟁점은 다음 셋이었다(모두 같은 기사의 서술 기준).

- **커널의 통제권**: Bates는 SR-IOV/VFIO처럼 장치 제어를 커널에서 완전히 빼는 것은 원하지 않는다고 했다. 오류 처리와 파일시스템 연동 때문이다. 하드웨어 큐를 요청·예약하는 방법이 필요하다는 그의 제안에 Hellwig는 실현 가능하지 않다고 봤다.
- **격리**: 큐별로 namespace나 LBA 범위를 제한하면 컨트롤러가 "act like a guard if the device got a little crazy"(Bates) 할 수 있다. Hellwig는 오작동 장치를 차단하려면 별도 NVMe 컨트롤러가 필요하다고 봤다. 기사는 이것이 비싼 선택지라 사람들이 다른 해법을 찾는다고 덧붙인다. 잘못된 DMA 주소 문제에 대해 Gunthorpe는 IOMMU가 이미 막아 주며 이를 쓰는 코드가 커널에 있다고 했다.
- **파일시스템**: Hellwig는 pNFS의 layout lease 기법(파일의 블록 배치를 예약하되 커널이 언제든 회수 가능)을 GPU에 적용할 수 있다고 제안하며 농담처럼 말했다. "you should give us some good hardware and you'll get a mention".

BaM README는 이 논쟁의 반대편 극단을 보여 준다. 커널 NVMe 드라이버를 unbind하고(`echo -n "0000:65:00.0" > /sys/bus/pci/devices/.../driver/unbind`), 커스텀 `libnvm` 모듈이 `/dev/libnvm*`를 만들며, 응용은 `sudo`로 실행한다. "The system's IOMMU should be disabled for ease of debugging", "In the system's BIOS, `ACS` must be disabled if the option is available"라는 요구도 있다. 파일시스템 없이 raw 블록 장치를 GPU가 독점하는 구조다. 커널 메인테이너들이 요구하는 격리·공유·FS 의미론과는 정반대다.

### 3.2 peer memory API vs dma-buf: RDMA에서 이미 끝난 논쟁

RDMA에서 GPU 메모리 등록은 오랫동안 MLNX_OFED의 peer memory client API를 썼다. `nvidia-peermem.c`는 `ib_register_peer_memory_client(&nv_mem_client_ex.client, ...)`를 호출한다. GPUDirect RDMA 문서는 "The kernel must have the required support for RDMA peer memory either through additional patches to the kernel or via MLNX_OFED as a prerequisite for loading and using nvidia-peermem"이라고 적는다. 즉 upstream 커널만으로는 `nvidia-peermem`을 쓸 수 없다. upstream RDMA는 대신 dma-buf importer를 택했다. Jianxin Xiong(Intel)의 `368c0159d492` "RDMA/umem: Support importing dma-buf as user memory region"(v5.12)이 `ib_umem_dmabuf_get()`과 uverbs `UVERBS_METHOD_REG_DMABUF_MR`(사용자 공간 `ibv_reg_dmabuf_mr`)을 도입했다. 동적 importer는 exporter의 무효화 콜백을 받아 ODP처럼 매핑을 다시 잡는다. 무효화를 처리할 수 없는 NIC를 위해 Gal Pressman의 `1e4df4a21c5a` "RDMA/umem: Allow pinned dmabuf umem usage"(v5.16)가 `ib_umem_dmabuf_get_pinned()`를 추가했다. HEAD에는 `ib_umem_dmabuf_get_pinned_revocable_and_lock()`, `ib_umem_dmabuf_get_pinned_with_dma_device()` 변형도 있다.

NVIDIA 쪽도 이동했다. GPUDirect RDMA 문서는 `CU_DEVICE_ATTRIBUTE_DMA_BUF_SUPPORTED`와 `cuMemGetHandleForAddressRange()`의 `CU_MEM_RANGE_HANDLE_TYPE_DMA_BUF_FD`를 설명한다. CUDA 13.0부터는 `cuMemAlloc()`/`cuMemAddressReserve()` 메모리가 dma-buf export를 지원하는지를 이 속성이 알려 준다. 오픈 커널 모듈에는 `NV_ESC_EXPORT_TO_DMABUF_FD` ioctl과 `nv_dma_buf_export()`가 있다(`kernel-open/nvidia/nv.c`). 같은 문서의 CUDA 13.0 deprecation 공지는 다음과 같다.

> "The nv-p2p APIs will no longer be supported on NVIDIA Tegra platforms starting with Nvidia Blackwell-based SoCs. Users are encouraged to migrate to alternative APIs for peer-to-peer communication on future Tegra platforms. One such alternative is the Linux upstream kernel API."
>
> — [GPUDirect RDMA 문서](https://docs.nvidia.com/cuda/gpudirect-rdma/index.html) 2.1.1 Deprecation Notice (13.4 문서, 2026-10-15 확인)

해설: 이 공지는 Tegra 한정이다. 데이터센터 GPU의 `nvidia_p2p_get_pages()`는 계속 지원된다(`nvidia-fs`, `nvidia-peermem`이 사용). 하지만 방향은 분명하다. GDS P2PDMA 전환(→ 08/01), `CUFILE_DMABUF` 경로와 같은 흐름이다.

### 3.3 블록 I/O에 dma-buf를: P2PDMA로 충분한가 (LSFMM+BPF 2026)

LWN [Using dma-bufs for read and write operations](https://lwn.net/Articles/1072317/)(Jonathan Corbet, 2026-05-12)는 Pavel Begunkov(Kanchan Joshi 보조)의 세션을 전한다. 출발점은 Keith Busch의 2022년 패치셋이다. dma-buf를 io_uring에 등록해 재사용하면 요청마다 드는 DMA 매핑·IOMMU 설정 비용을 나눠 낼 수 있다는 아이디어였고, 메인라인에 들어가지 않았다. Begunkov의 시리즈([io_uring dmabuf read/write support](https://lwn.net/Articles/1027322/) RFC, 2025-06-27, Message-ID `<cover.1751035820.git.asml.silence@gmail.com>`)는 io_uring 등록 버퍼를 사용자 API로 쓴다. 내부 인터페이스는 `io_dmabuf_token`(dma-buf 구현 드라이버와 io_uring 사이)과 `io_dmabuf_map`(요청별, iomap이 지원)이다.

"P2PDMA로 충분하지 않은가"라는 질문에 Begunkov가 기사에서 든 이유는 다음과 같다. 사용자 공간이 이미 가진 dma-buf를 쓸 수 없다. 새 API는 중간 변환이 싸고, IOMMU 사용을 더 잘 최적화하며, 매핑 무효화를 지원한다. 청중 한 명은 P2PDMA도 무효화를 지원한다고 반박했다. 단점은 새 API가 필요하고 당분간 io_uring에 한정된다는 것이다.

IOMMU 사전 매핑 벤치마크는 최대 8.8배 개선을 보였고, lazy/strict 모드의 IOMMU 패널티를 없앴다고 한다(발표 수치, 측정 장비·워크로드 미공개 `[추측/미확인: 측정 조건]`). 토론 내용은 이렇다. Jason Gunthorpe는 pass-through 모드면 충분하지 않냐고 물었고, Begunkov는 보안 때문에 pass-through를 피하려 한다고 답했다. Hellwig는 IOMMU 사용을 요구하는 사이트가 있고 IOMMU의 메모리 결합이 성능에 도움이 된다며 Begunkov 쪽을 지지했다. David Howells는 IOMMU 슬롯 고갈을 우려해 권한 검사를 요구했다. Christian Brauner는 제거 대상인 scatterlist를 쓴다는 점을 지적했다. Hellwig는 dma-buf가 아직 scatterlist를 필요로 하므로 정리 작업을 기다리느라 이 작업을 막아서는 안 된다고 답했다. GDS 운영 권고(→ 08/01)("iommu=off provides the best functionality and performance")와 정반대 방향의 요구가 upstream에서 힘을 얻고 있다.

---
## 4. Implementation Impact

### 4.1 BaM 아키텍처

논문 초록과 README에서 확인한 BaM의 구성은 다음과 같다.

- **고처리량 큐**: NVMe SQ/CQ를 GPU 메모리(또는 GPU가 접근 가능한 메모리)에 두고, GPU 스레드들이 동시에 SQ 엔트리를 채우고 doorbell(NVMe BAR0 레지스터)을 MMIO로 쓴다. 초록 표현으로는 "high-throughput queues that enable the massive number of concurrent threads in modern GPUs to make I/O requests at a high rate". 수천 스레드가 공유 큐에 쓰므로 GPU 측 원자 연산 기반 동기화가 필요하다. 구체적 큐 프로토콜은 논문 본문에 있으며 여기서는 원문 대조를 하지 않았다 `[추측/미확인]`.
- **소프트웨어 캐시**: "BaM features a fine-grained software cache to coalesce data storage requests while minimizing I/O traffic amplification". GPU 메모리에 캐시 라인 단위 관리 구조를 두고, 여러 스레드의 같은 블록 요청을 합친다.
- **추상화**: 응용은 배열처럼 접근하는 GPU 측 추상화(README가 언급하는 `bam::array`)를 쓰고, 캐시 miss가 I/O로 바뀐다.
- **커널 구성요소**: 커스텀 `libnvm` 커널 모듈(README: "compile the custom `libnvm` kernel module for NVMe devices")이 unbind된 NVMe 컨트롤러를 `/dev/libnvm*`로 노출한다. NVIDIA 드라이버 커널 심볼(`nv-p2p`)이 필요하다. README는 `enfiskutensykkel/ssd-gpu-dma` 프로젝트를 기반으로 한다고 밝힌다.
- **요구 환경**: CUDA 12.3+, IOMMU off, BIOS ACS off, "we recommend using a PCIe switch to connect the GPU and SSDs in your server. Going over IOMMU degrades performance."

**보고 성능**(arXiv 초록 원문, 저자 측정): BFS와 CC 그래프 분석에서 호스트 메모리에서 그래프를 읽는 방식 대비 "1.0x and 1.49x end-to-end speed up … while reducing hardware costs by up to 21.7x". 데이터 분석 워크로드에서 같은 하드웨어의 CPU-initiated storage access 대비 "5.3x". 비교 기준이 다르다는 점에 주의해야 한다. 그래프 수치는 "DRAM에 다 올린 경우와 비슷한 속도를 훨씬 싼 하드웨어로" 낸다는 뜻이고, 5.3x는 CPU 주도 스토리지 대비다.

### 4.2 GPUDirect RDMA와 `nvidia-peermem`

GPUDirect RDMA는 "introduced in Kepler-class GPUs and CUDA 5.0"(문서 1절)이다. 커널 측 API는 `kernel-open/nvidia/nv-p2p.h`에 있다.

- `int nvidia_p2p_get_pages(uint64_t p2p_token, uint32_t va_space, uint64_t virtual_address, uint64_t length, struct nvidia_p2p_page_table **page_table, void (*free_callback)(void *data), void *data)`: GPU VA 범위를 pin하고 BAR 물리 페이지 테이블을 돌려준다. CUDA 6.0부터 토큰은 0을 쓴다. 문서에 따르면 "nvidia_p2p_get_pages no longer accepts a NULL callback pointer"이다.
- `nvidia_p2p_get_pages_persistent()` / `nvidia_p2p_put_pages_persistent()`: 무효화 콜백 없는 영속 매핑이다(`NVIDIA_P2P_CAP_GET_PAGES_PERSISTENT_API`로 가드).
- `nvidia_p2p_dma_map_pages(struct pci_dev *peer, ...)` / `nvidia_p2p_dma_unmap_pages()`: 특정 peer 장치 기준의 DMA 주소.
- 페이지 크기 enum `NVIDIA_P2P_PAGE_SIZE_4KB/64KB/128KB`, 테이블 버전 `NVIDIA_P2P_PAGE_TABLE_VERSION 0x00020000`(R580.82.05부터, → 08/01, 3.1절).

`nvidia-peermem`(CUDA 11.4에서 추가, 이전 out-of-tree `nv_peer_mem` 대체)은 MLNX_OFED의 `ib_register_peer_memory_client()`로 두 클라이언트(`nv_mem_client_ex`, `nv_mem_client_nc`)를 등록한다. RDMA 코어가 사용자 MR의 VA가 GPU 메모리인지 물으면 `nvidia_p2p_get_pages()`(또는 persistent 변형)로 pin해 MR을 만든다. 모듈 파라미터는 `peerdirect_support`(0 기본, 1은 "legacy, for example MLNX_OFED 4.9 LTS")와 `persistent_api_support`(1 기본)가 있다. 라이선스는 `MODULE_LICENSE("Dual BSD/GPL")`이다. 문서는 "Currently, there is no service to automatically load nvidia-peermem"이라고 적는다.

### 4.3 dma-buf importer 3종의 내부

**RDMA dma-buf MR**(v5.12+): 사용자 `ibv_reg_dmabuf_mr(pd, offset, length, iova, fd, access)` → uverbs `UVERBS_METHOD_REG_DMABUF_MR` → 드라이버 `reg_user_mr_dmabuf` → `ib_umem_dmabuf_get(device, offset, size, fd, access, ops)`. 이 함수는 `dma_buf_get(fd)` → `dma_buf_dynamic_attach(dmabuf, dma_device, ops, umem_dmabuf)`(ops의 `allow_peer2peer = true`)를 수행한다. 매핑은 `ib_umem_dmabuf_map_pages()`가 `dma_buf_map_attachment()`로 sg_table을 얻어 처리한다. 무효화 콜백이 오면 드라이버가 MR의 HW 매핑을 끊는다. 무효화를 처리할 수 없는 드라이버는 `ib_umem_dmabuf_get_pinned()`(v5.16+)로 `dma_buf_pin()`을 건다. (`ib_umem_dmabuf_map_pages`, `dma_buf_dynamic_attach`, `.allow_peer2peer = true`, `dma_buf_pin`은 `drivers/infiniband/core/umem_dmabuf.c`, `reg_user_mr_dmabuf`는 `struct ib_device_ops`(`include/rdma/ib_verbs.h`)에서 확인했다.)

**devmem TCP**(RX v6.12, TX v6.16): 커널 문서 [Device Memory TCP](https://docs.kernel.org/networking/devmem.html)의 정의는 "Device memory TCP (devmem TCP) enables receiving data directly into device memory (dmabuf)"이다. 흐름은 LWN [Direct-to-device networking](https://lwn.net/Articles/979549/)(Corbet, 2024-06-27) 기준으로 다음과 같다. (1) 가속기 드라이버에서 dma-buf fd를 얻는다. (2) netlink `NETDEV_CMD_BIND_RX`로 특정 RX 큐에 바인딩한다(`net_devmem_bind_dmabuf_to_queue()`, `net/core/devmem.c`가 `dma_buf_attach` + `dma_buf_map_attachment_unlocked` 수행). (3) flow steering으로 해당 트래픽만 그 큐로 보낸다. (4) `recvmsg(..., MSG_SOCK_DEVMEM)`을 호출한다. (5) cmsg `SCM_DEVMEM_DMABUF`(dma-buf ID·오프셋) 또는 fallback `SCM_DEVMEM_LINEAR`를 받는다. (6) 처리 후 `SO_DEVMEM_DONTNEED`로 반환한다. 내부적으로 page_pool이 struct page 대신 `netmem_ref`/`struct net_iov`를 다루고, payload frag는 커널이 읽을 수 없는("unreadable") skb frag가 된다. 헤더만 호스트 메모리로 split된다. TX는 `bd61848900bf` "net: devmem: Implement TX path"(v6.16)와 `NETDEV_CMD_BIND_TX`이다. 커밋 `170aafe35cb9` "netdev: support binding dma-buf to netdevice"(Mina Almasry)가 시리즈 시작이다.

**io_uring zcrx**(v6.15, dma-buf 영역 v6.16): `IORING_REGISTER_ZCRX_IFQ`로 인터페이스 큐와 refill 큐를 등록한다(`6f377873cb23`, David Wei). 수신 영역 `struct io_uring_zcrx_area_reg { addr, len, rq_area_token, flags, dmabuf_fd, ... }`에서 `flags = IORING_ZCRX_AREA_DMABUF`이면 `dmabuf_fd`를 쓴다(`a5c98e942457` "io_uring/zcrx: dmabuf backed zerocopy receive", Pavel Begunkov, v6.16). `io_uring/zcrx.c`는 `dma_buf_get(dmabuf_fd)` → `dma_buf_attach(dmabuf, ifq->dev)` → `dma_buf_map_attachment_unlocked(attach, DMA_FROM_DEVICE)`를 수행한다. 버퍼는 page_pool memory provider로 NIC에 공급된다. 완료는 CQE로, 반환은 refill 큐로 처리한다. v7.1에서 zcrx uapi가 `include/uapi/linux/io_uring/zcrx.h`로 분리됐다(태그별 `git ls-tree` 기준).

세 importer 모두 **dma-buf의 sg_table을 받아 장치 DMA 주소로만 쓰고 CPU 접근은 하지 않는다.** 그래서 struct page가 없어도 되고, GPU 메모리를 장기간 등록해 둘 수 있다. P2PDMA pgmap(→ 08/02)과의 결정적 차이다.

### 4.4 종합 비교: CPU-bounce vs GDS vs P2PDMA vs GPU-initiated

| 항목 | CPU bounce (`pread` + `cudaMemcpy`) | GDS (cuFile, NVFS/P2PDMA 모드) | 순수 upstream P2PDMA (`O_DIRECT` into p2pmem) | GPU-initiated (BaM) |
|---|---|---|---|---|
| I/O 발행 주체 | CPU 스레드 | CPU 스레드 (`libcufile`, 내부 스레드 풀) | CPU 스레드 | GPU 스레드 (SQ 작성 + doorbell MMIO) |
| payload 경로 | NVMe→DRAM→GPU (2회 DMA) | NVMe→GPU BAR1 (1회) | NVMe→공급자 BAR (1회) | NVMe→GPU 메모리 (1회) |
| 커널 경로 | VFS/블록 전체 | VFS/블록 전체 + `nvidia-fs` 콜백 또는 P2PDMA 페이지 | VFS/블록 전체 (`FOLL_PCI_P2PDMA`) | 없음 (NVMe 드라이버 unbind, `libnvm`) |
| 파일시스템 | 지원 | ext4/XFS + 파트너 분산 FS | NVMe 위 FS(`BLK_FEAT_PCI_P2PDMA` 큐) | 없음 (raw 블록) |
| 장치 공유·격리 | 커널 보장 | 커널 보장 | 커널 보장 | 프로세스가 장치 독점 |
| IOMMU/ACS | 무관 | off/pt 권장 (NVIDIA), upstream은 거리 판정 | 거리 판정 (THRU_HOST_BRIDGE는 IOMMU 매핑) | off 권장 (README) |
| 적합한 패턴 | 소량·불규칙 | 대용량·CPU가 미리 아는 접근 | 대용량·CPU가 아는 접근 | 세밀·데이터 의존 접근 (그래프, GNN, 추천) |
| 성숙도 | 표준 | 상용 (2021~) | 메인라인 6.2+ | 연구 프로토타입 (ASPLOS '23) |

### 4.5 GPU 메모리 공유 메커니즘 비교

| 메커니즘 | 메인라인 여부 | struct page | 무효화 | 대표 소비자 |
|---|---|---|---|---|
| `nvidia_p2p_get_pages()` + callback | 벤더 (nvidia.ko) | 없음 | free_callback | `nvidia-fs`, `nvidia-peermem`, BaM |
| MLNX_OFED peer memory client | out-of-tree (OFED 패치) | 없음 | peer invalidate | `nvidia-peermem` → IB verbs MR |
| P2PDMA pgmap (`MEMORY_DEVICE_PCI_P2PDMA`) | 4.20+ (사용자 공간 6.2+) | 있음 | pgmap 수명 (장기 pin 금지) | NVMe `O_DIRECT`, nvmet, GDS P2PDMA 모드 |
| dma-buf (dynamic importer) | 5.7+ (`dma_buf_attach_ops`) | 없음 | `move_notify` → `invalidate_mappings` (7.1) | RDMA MR (5.12), devmem TCP (6.12), zcrx (6.16) |
| dma-buf (pinned) | 5.16+ (`ib_umem_dmabuf_get_pinned`) | 없음 | 없음 (pin) | 무효화 미지원 NIC |
| `p2pdma_provider` (page 없는 P2P) | 6.19+ | 없음 | dma-buf로 위임 | VFIO PCI dma-buf export |

### 4.6 버전 연표

| 시점 | 사건 | 근거 |
|---|---|---|
| CUDA 5.0 / Kepler | GPUDirect RDMA (`nvidia_p2p_get_pages`) | GPUDirect RDMA 문서 |
| Linux 5.7 | `struct dma_buf_attach_ops` (동적 importer) | 태그 grep |
| Linux 5.12 | RDMA dma-buf MR (`368c0159d492`) | 커밋 |
| Linux 5.16 | pinned dma-buf umem (`1e4df4a21c5a`), dma-buf 심볼 `DMA_BUF` 네임스페이스 (`16b0314aa746`) | 커밋 |
| CUDA 11.4 | `nvidia-peermem` 추가 | GPUDirect RDMA 문서 2.3 |
| 2022-03-09 | BaM arXiv 공개 → ASPLOS '23 | arXiv 2203.04910 |
| Linux 6.12 | devmem TCP RX (`170aafe35cb9` 외) | 커밋, LWN |
| Linux 6.15 | io_uring zcrx (`6f377873cb23`) | 커밋 |
| Linux 6.16 | zcrx dma-buf 영역 (`a5c98e942457`), devmem TX (`bd61848900bf`) | 커밋 |
| 2025-06 | LSFMM+BPF 2025 "Device-initiated I/O"; io_uring dma-buf read/write RFC | LWN 1022718, 1027322 |
| CUDA 13.0 | Tegra(Blackwell SoC~) nv-p2p deprecation, `cuMemAlloc` dma-buf export | GPUDirect RDMA 문서 2.1 |
| Linux 6.19 | `p2pdma_provider`, VFIO dma-buf | (→ 08/02) |
| Linux 7.1 | `invalidate_mappings` 명칭 | 태그 grep |
| 2026-05 | LSFMM+BPF 2026 "Using dma-bufs for read and write operations" (미병합) | LWN 1072317 |

### 4.7 운영 관점 정리

- 지금 프로덕션에서 GPU↔스토리지 직접 경로가 필요하면 GDS(cuFile)가 사실상 유일한 상용 선택지다. 로컬 NVMe는 P2PDMA 모드(커널 6.2+, OpenRM 570+)로 out-of-tree 의존을 줄일 수 있다.
- GPU↔네트워크는 dma-buf 기반 upstream 경로(RDMA dma-buf MR, devmem TCP, zcrx)가 이미 성숙했다. `nvidia-peermem`은 MLNX_OFED 환경의 호환 경로로 남는다.
- GPU-initiated I/O는 커널 관점에서 아직 "장치를 커널에서 떼어내는" 방식뿐이다. upstream이 수용하려면 NVMe 큐 격리 하드웨어나 layout lease 같은 설계가 먼저 정리돼야 한다(3.1절).
- 블록 I/O의 dma-buf 경로(io_uring 등록 dma-buf)가 병합되면 GDS의 `CUFILE_DMABUF` 같은 경로가 NVMe에서도 upstream만으로 가능해질 수 있다 `[추측/미확인: 향후 전망]`.

---

## 5. Primary References

- [GPU-Initiated On-Demand High-Throughput Storage Access in the BaM System Architecture](https://arxiv.org/abs/2203.04910) (Qureshi et al., arXiv 확장판, ASPLOS '23 원 논문 DOI 10.1145/3575693.3575748)
- [ZaidQureshi/bam](https://github.com/ZaidQureshi/bam) — BaM 구현과 README(시스템 요구, `libnvm` 모듈)
- [Device-initiated I/O](https://lwn.net/Articles/1022718/) (Jake Edge, LWN, 2025-06-04, LSFMM+BPF 2025)
- [Using dma-bufs for read and write operations](https://lwn.net/Articles/1072317/) (Jonathan Corbet, LWN, 2026-05-12, LSFMM+BPF 2026)
- [io_uring dmabuf read/write support](https://lwn.net/Articles/1027322/) (Pavel Begunkov RFC, 2025-06-27)
- [Direct-to-device networking](https://lwn.net/Articles/979549/) (Jonathan Corbet, LWN, 2024-06-27)
- [Device Memory TCP](https://docs.kernel.org/networking/devmem.html) — 커널 문서
- [Buffer Sharing and Synchronization (dma-buf)](https://docs.kernel.org/driver-api/dma-buf.html) — 커널 문서
- [GPUDirect RDMA](https://docs.nvidia.com/cuda/gpudirect-rdma/index.html) — NVIDIA 문서(nv-p2p API, nvidia-peermem, dma-buf 속성, CUDA 13.0 deprecation)
- [cuFile API Reference Guide](https://docs.nvidia.com/gpudirect-storage/api-reference-guide/index.html) — "All APIs are issued from the CPU", `CUFILE_DMABUF`
- 소스: [kernel-open/nvidia-peermem/nvidia-peermem.c](https://github.com/NVIDIA/open-gpu-kernel-modules/blob/main/kernel-open/nvidia-peermem/nvidia-peermem.c), [kernel-open/nvidia/nv-p2p.h](https://github.com/NVIDIA/open-gpu-kernel-modules/blob/main/kernel-open/nvidia/nv-p2p.h)
- 커널 소스: [drivers/infiniband/core/umem_dmabuf.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/infiniband/core/umem_dmabuf.c), [net/core/devmem.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/net/core/devmem.c), [io_uring/zcrx.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/io_uring/zcrx.c)
- 커밋: [368c0159d492 RDMA/umem: Support importing dma-buf as user memory region](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=368c0159d492), [170aafe35cb9 netdev: support binding dma-buf to netdevice](https://github.com/torvalds/linux/commit/170aafe35cb9), [a5c98e942457 io_uring/zcrx: dmabuf backed zerocopy receive](https://github.com/torvalds/linux/commit/a5c98e942457)
