# Linux PCI P2PDMA 해부: ZONE_DEVICE 페이지, NVMe CMB, nvmet p2pmem, 사용자 공간 O_DIRECT, 그리고 scatterlist 이후의 DMA 매핑

> 기준: Linux `master`(v7.3-rc7 이후 32커밋, 커밋 `0fcb05b72344`, 2026-10-14). 함수·구조체·플래그 이름은 `include/linux/pci-p2pdma.h`, `drivers/pci/p2pdma.c`, `block/blk-mq-dma.c`, `include/linux/blk-mq-dma.h`, `include/linux/dma-mapping.h`, `drivers/nvme/host/pci.c`, `drivers/nvme/target/{core,configfs}.c`를 해당 태그에서 `git show <tag>:<path> | grep`으로 대조했다. 도입 버전은 커밋을 포함하는 최초 릴리스 태그(`git tag --contains`)와 태그별 grep으로 고정했다. lore.kernel.org는 이 환경에서 403을 반환한다. 그래서 메일링 리스트 원문은 LWN에 미러된 패치 cover letter(Message-ID 포함)로 확인했다.

## 1. Verdict

PCI P2PDMA는 "PCIe 장치 A의 BAR 메모리를 장치 B의 DMA 목적지로 쓰는 것"을 커널이 **안전하게 허용할지 판단하고, 그 메모리를 기존 I/O 스택이 다룰 수 있는 형태로 포장하는** 서브시스템이다. Logan Gunthorpe(Eideticom)가 2017년 RFC부터 이끌었고, Christoph Hellwig, Stephen Bates, Jason Gunthorpe, Dan Williams 등이 설계에 참여했다. 첫 코어 커밋 `52916982af48 "PCI/P2PDMA: Support peer-to-peer memory"`는 **Linux 4.20**에 들어갔다(`pci-v4.20-changes` 병합).

결론은 다섯 가지다.

1. **struct page 진영이 이겼다. 다만 조건부다.** P2PDMA는 BAR를 `devm_memremap_pages()`로 `ZONE_DEVICE`의 `MEMORY_DEVICE_PCI_P2PDMA` 페이지로 만든다. 그래서 `bio_vec`·scatterlist·GUP 같은 기존 경로가 그대로 흐른다. 대신 "이 페이지를 받아도 되는 경로"를 플래그(`BLK_FEAT_PCI_P2PDMA`, `FOLL_PCI_P2PDMA`, `ITER_ALLOW_P2PDMA`)로 일일이 허용하는 opt-in 모델을 택했다. 2019년 "Removing struct page from P2PDMA" RFC는 병합되지 않았다. 2025년(6.19)에 struct page 없는 `struct p2pdma_provider` 계층이 dma-buf용으로 따로 생겼다.
2. **토폴로지 판정은 보수적이다.** `calc_map_type_and_dist()`는 두 장치의 공통 상위 브리지를 찾고, 경로상 ACS redirect 비트를 검사한다. 결과는 `PCI_P2PDMA_MAP_BUS_ADDR`(스위치 내부 직통), `PCI_P2PDMA_MAP_THRU_HOST_BRIDGE`(루트 컴플렉스 경유, IOMMU 매핑 필요), `PCI_P2PDMA_MAP_NOT_SUPPORTED` 중 하나다. host bridge를 지나는 경로는 `pci_p2pdma_whitelist[]`에 있거나 AMD Zen 이상 CPU(`cpu_supports_p2pdma()`)일 때만 허용된다.
3. **사용자 공간 경로는 6.2에서 열렸다.** `FOLL_PCI_P2PDMA`(커밋 `4003f107fa2e`), `__bio_iov_iter_get_pages()`의 플래그 설정(`5e3e3f2e15df`), sysfs `p2pmem/allocate` mmap(`7e9c7ef83d78`)이 모두 v6.2다. 이로써 P2P 메모리를 mmap한 VA를 `O_DIRECT` read/write에 바로 넘길 수 있다. NVIDIA GDS의 "NVMe P2PDMA 모드"(CUDA 12.8)가 이 경로를 쓴다(→ 08/01, 4.6절).
4. **DMA 매핑 계층이 scatterlist 이후로 넘어갔다.** 6.16에 Leon Romanovsky의 2단계 IOVA API(`dma_iova_try_alloc`/`dma_iova_link`/`dma_iova_sync`/`dma_iova_destroy`)와 Hellwig의 P2PDMA 헬퍼 재작성(`pci_p2pdma_state`, `struct pci_p2pdma_map_state`)이 들어갔다. 6.17에는 블록 계층의 `blk_rq_dma_map_iter_start`/`_next`와 이를 쓰는 `nvme-pci` 변환이 들어갔다. P2P 판정은 이제 요청을 DMA 매핑하는 반복자 안에서 세그먼트마다 일어난다.
5. **2026년에도 범위는 넓어지는 중이다.** v7.1에 Google SoC host bridge, v7.2에 Intel QAT/DSA/IAA 화이트리스트, NVMe multipath(`fb0eeeed91f3`)와 MD RAID 멤버 전파(`02666132403a`)가 들어갔다. v7.3-rc에는 NVIDIA Vera Rubin 화이트리스트(`894a78088fc3`)가 있다. GDS 릴리스 노트의 "RAID1/RAID10 … x86 P2PDMA mode: Supported starting with kernel 7.2"는 이 커밋들과 정확히 맞는다.

---

## 2. Problem Statement

### 2.1 출발점: NVMe-oF target의 메모리 대역폭

Gunthorpe의 2017-03-30 RFC [Copy Offload with Peer-to-Peer PCI Memory](https://lwn.net/Articles/718593/)(Message-ID `<1490911959-5146-1-git-send-email-logang@deltatee.com>`)는 동기를 이렇게 적는다.

> "The concept here is to use memory that's exposed on a PCI BAR as data buffers in the NVME target code such that data can be transferred from an RDMA NIC to the special memory and then directly to an NVMe device avoiding system memory entirely."
>
> — Logan Gunthorpe, [RFC 0/8] Copy Offload with Peer-to-Peer PCI Memory, 2017-03-30 ([LWN 미러](https://lwn.net/Articles/718593/))

해설: 최초 사용자는 GPU가 아니라 **NVMe-oF target**(`nvmet-rdma`)이었다. RDMA NIC → 호스트 DRAM → NVMe 경로에서 DRAM을 빼면 CPU 쪽 메모리 대역폭과 PCIe 레인 요구가 줄어든다. 같은 글은 "the trade-off is currently a reduction in overall throughput"이라고 솔직히 인정한다. 당시 하드웨어(CMB 지원 SSD가 거의 없었음)의 한계 때문이다.

### 2.2 커널이 P2P를 막아야 하는 이유

[커널 문서 PCI Peer-to-Peer DMA Support](https://docs.kernel.org/driver-api/pci/p2pdma.html)는 문제를 세 가지로 정리한다.

- **라우팅 불확실성**: "The PCIe specification doesn't define the forwarding of transactions between hierarchy domains and kernel defaults to blocking such routing." 스위치 내부 P2P는 정의되어 있지만, TLP가 host bridge에 닿으면 그 뒤 동작은 SoC마다 다르다.
- **ACS**: 스위치 다운스트림 포트에 ACS Request/Completion Redirect가 켜져 있으면 P2P TLP가 루트로 올라가 IOMMU를 거친다. 버스 주소를 그대로 쓰면 IOMMU가 막는다.
- **수명 주기**: "The providing driver has to convey its MMIO to the consuming driver. To meet the driver model lifecycle rules the MMIO must have all DMA mapping removed, all CPU accesses prevented, all page table mappings undone before the providing driver completes remove()." BAR를 제공한 장치가 hot-unplug되면 그 주소로 진행 중인 DMA를 모두 끊어야 한다.

### 2.3 I/O 스택이 BAR 메모리를 모른다

블록 계층은 `struct bio_vec { bv_page, bv_len, bv_offset }`으로, DMA API는 `struct scatterlist`로 메모리를 기술한다. 둘 다 `struct page`를 기준으로 한다. BAR 주소에는 page가 없다. page를 만들어 준다 해도 문제가 남는다. 그 page는 CPU가 캐시 가능하게 접근하면 안 되는 MMIO이고, `kmap`/`memcpy`로 bounce해도 안 되며, 같은 SG 세그먼트로 일반 페이지와 merge되어도 안 된다. 또 DMA 주소는 `dma_map_page()`의 IOMMU 경로가 아니라 "PCI 버스 주소 = CPU 물리 주소 + `bus_offset`"으로 계산해야 할 수도 있다. 이 모든 예외를 기존 코드에 안전하게 넣는 것이 P2PDMA 8년 역사의 대부분이다.

### 2.4 사용자 공간에서 쓰려면

GPU나 연산 스토리지 사용자에게 필요한 것은 "장치 메모리를 mmap해 `read(fd, p2p_va, ...)`로 NVMe에서 바로 채우기"다. 그러려면 GUP(`pin_user_pages`)가 `VM_IO|VM_PFNMAP`가 아닌 정상 페이지를 돌려줘야 하고, 그 페이지가 P2P 미지원 장치(예: 일반 SATA 디스크)로 가지 않게 막아야 한다. 6.2 시리즈가 이 문제를 풀었다(4.5절).

---
## 3. The Debate

### 3.1 struct page를 쓸 것인가

이 논쟁은 P2PDMA 역사 전체에 걸쳐 있다. Gunthorpe 자신이 2019-06-20 RFC [Removing struct page from P2PDMA](https://lwn.net/Articles/791676/)(Message-ID `<20190620161240.22738-1-logang@deltatee.com>`)에서 양측을 이렇게 요약했다.

> "For eons there has been a debate over whether or not to use struct pages for peer-to-peer DMA transactions. Pro-pagers have argued that struct pages are necessary for interacting with existing code like scatterlists or the bio_vecs. Anti-pagers assert that the tracking of the memory is unecessary and allocating the pages is a waste of memory."
>
> — Logan Gunthorpe, [RFC PATCH 00/28] Removing struct page from P2PDMA, 2019-06-20 ([LWN 미러](https://lwn.net/Articles/791676/))

해설: 같은 cover letter는 "developers working on GPUs and RDMA tend to be able to do away with struct pages relatively easily compared to those wanting to work with NVMe devices through the block layer"라고 덧붙인다. GPU/RDMA는 자체 매핑 구조(dma-buf, MR)를 갖지만, 블록 계층은 `bio_vec`에 page가 필요하다는 뜻이다. 이 RFC는 `dma_vec`이라는 DMA 주소 기반 bio 변형을 제안했지만 병합되지 않았다. 그 결과가 오늘의 이원 구조다. 커널 문서는 "At the lowest level the P2P subsystem offers a naked struct p2p_provider that delegates lifecycle management to the providing driver. It is expected that drivers using this option will wrap their MMIO memory in DMABUF"라고 적는다. 그 위에 "a layer to wrap the MMIO in a ZONE_DEVICE pgmap of MEMORY_DEVICE_PCI_P2PDMA to create struct pages"가 있다. struct page 없는 계층은 `read()`/`write()`/`O_DIRECT`에 쓸 수 없다. page 계층은 "The use of FOLL_LONGTERM is prevented"라는 제약을 받는다. 즉 **블록 I/O는 page 계층, RDMA/VFIO/GPU 간 공유는 dma-buf 계층**으로 역할이 나뉘었다.

### 3.2 토폴로지 판정: "같은 스위치 아래만" 에서 화이트리스트로

2017 RFC는 "we've designed the system to only enable using the PCI memory in cases where the NIC, NVMe devices and memory are all behind the same PCI switch"라고 했다. LSF/MM 피드백에 따라 사용자가 토폴로지를 이해하지 않아도 되도록 보수적으로 설계한 것이다. LWN [Device-to-device memory-transfer offload with P2PDMA](https://lwn.net/Articles/767281/)(Marta Rybczyńska, 2018-10-02)는 4.20 병합 직전 상태를 다룬다. 초기에는 같은 host bridge 아래만 허용했고, ACS redirect를 끄려면 4.19에 추가된 `disable_acs_redir` 인자가 필요했다. 또 같은 기사에 Stephen Bates가 단 댓글(2018-10-05)에 따르면 `ZONE_DEVICE`가 아키텍처 의존이라 당시 x86_64는 되지만 aarch64는 지원하지 못했다. 이후 완화 과정은 커밋으로 추적된다.

- v5.2 `6dbbd053e6ae` "Ignore root complex whitelist when an IOMMU is present": IOMMU가 켜져 있으면 host bridge 경유 P2P를 막았다(버스 주소가 IOMMU를 통과하지 못하므로).
- v5.4 `5d52e1abcd47` "dma_map() requests that traverse the host bridge"와 `5daf40b03924` "Allow IOMMU for host bridge whitelist": host bridge 경유 경로는 일반 `dma_map`으로 IOMMU 매핑하도록 바꿨다. 이것이 `PCI_P2PDMA_MAP_THRU_HOST_BRIDGE`의 기원이다.
- v5.9 `dea286bb71ba` "Allow P2PDMA on AMD Zen and newer CPUs": `cpu_supports_p2pdma()`가 `X86_VENDOR_AMD && c->x86 >= 0x17`이면 true를 돌려준다.
- 이후 Intel Skylake-E/Ice Lake 루트 포트, v7.1 Google SoC(와일드카드 Device ID 도입 `1a1f96e3e2a8`), v7.2 Intel QAT/DSA/IAA, v7.3-rc NVIDIA Vera Rubin(`0x2f95`~`0x2f98`)이 추가됐다.

비판은 화이트리스트 자체에 있다. PCIe 스펙이 root complex 간 포워딩을 정의하지 않으므로 커널은 실측된 SoC만 허용한다. 그 결과 새 CPU가 나올 때마다 화이트리스트 패치가 필요하다. 거부될 때 `pci_warn`으로 "to disable ACS redirect for this path, add the kernel parameter: pci=disable_acs_redir=..."를 출력하는 것도 운영자에게 보안 설정을 끄라고 권하는 셈이라는 비판이 있다 `[추측/미확인: 공개 비판 원문 미확인]`.

### 3.3 사용자 공간 O_DIRECT: 혼합 SGL 문제

[Userspace P2PDMA with O_DIRECT NVMe devices](https://lwn.net/Articles/883051/) v5(2022-01-27, Message-ID `<20220128002614.6136-1-logang@deltatee.com>`)는 핵심 기술 장애를 이렇게 적는다.

> "This is relatively straightforward, however the one significant problem is that, presently, pci_p2pdma_map_sg() requires a homogeneous SGL with all P2PDMA pages or all regular pages. Enhancing GUP to support enforcing this rule would require a huge hack that I don't expect would be all that pallatable."
>
> — Logan Gunthorpe, [PATCH v5 00/24] Userspace P2PDMA with O_DIRECT NVMe devices, 2022-01-27 ([LWN 미러](https://lwn.net/Articles/883051/))

해설: 사용자는 iovec 하나에 일반 메모리와 P2P 메모리를 섞어 넘길 수 있다. 해결책은 GUP를 고치는 것이 아니라 **DMA API(`dma_map_sg`)가 P2P 페이지를 직접 이해하도록** 하는 것이었다. 이 부분은 v8 [DMA Mapping P2PDMA Pages](https://lwn.net/Articles/900481/)(2022-07-08)로 분리돼 **v6.0**에 들어갔다. dma-direct와 dma-iommu가 P2P 세그먼트를 처리하고, 구 `pci_p2pdma_[un]map_sg()`는 제거됐다(`0d06132fc84b`). cover letter는 `dma_map_sgtable()`이 매핑 불가능한 P2P 페이지에 `-EREMOTEIO`를 돌려준다고 적는다. 나머지(GUP 플래그, bio, sysfs mmap)는 v6.2에 들어갔다. 원래 시리즈의 "nvme char device mmap" 패치는 병합 목록에 없다. 사용자 공간 할당 경로는 sysfs `/sys/bus/pci/devices/.../p2pmem/allocate`로 정해졌다.

### 3.4 scatterlist 이후의 DMA API: "two-step" 논쟁

Leon Romanovsky(NVIDIA)의 [Provide a new two step DMA mapping API](https://lwn.net/Articles/1008073/) v7(2025-02-05, Message-ID `<cover.1738765879.git.leonro@nvidia.com>`)는 scatterlist를 이렇게 비판한다. "This uniqueness has been a long standing pain point as the scatterlist API is mandatory, but expensive to use. It prevents any kind of optimization or feature improvement (such as avoiding struct page for P2P) due to the impossibility of improving the scatterlist." 해법은 IOVA 공간 할당과 개별 매핑을 분리하는 것이다.

LWN [Dancing the DMA two-step](https://lwn.net/Articles/997563/)(Jonathan Corbet, 2024-11-14)은 반론을 전한다. Robin Murphy는 연속 IOVA 결합의 가치 자체를 의심했다.

> "TBH I doubt there are many actual scatter-gather-capable devices with significant enough limitations to meaningfully benefit from DMA segment combining these days - I've often thought that by now it might be a good idea to turn that behaviour off by default and add an attribute for callers to explicitly request it."
>
> — Robin Murphy, LWN [Dancing the DMA two-step](https://lwn.net/Articles/997563/) 인용 (2024-11-14 기사)

해설: 같은 기사에 따르면 Hellwig는 "devices often perform better with a contiguous IOVA range"라고 반박했고, Jason Gunthorpe는 RDMA에서 "big wins"가 있다고 동의했다. Jens Axboe는 블록 계층에서 원인 불명의 성능 회귀를 관측했다. 그래서 Romanovsky는 블록 쪽 변경 일부를 빼고 진행했다. 기사는 6.13 병합 가능성을 언급했지만 실제로는 늦어졌다. git 태그 기준으로 IOVA API(`393cf700e624`, `433a76207dcf`)와 P2PDMA 헬퍼 재작성(`a25e7962db0d`)은 **v6.16**, 블록 `blk_rq_dma_map_*`(`858299dc6160`)와 `nvme-pci` 변환(`7ce3c1dd78fc`)은 **v6.17**에 들어갔다.

### 3.5 page_free 콜백과 장치 메모리 관리권

NVIDIA 오픈 커널 모듈(615.78.08) `uvm_devmem.c`의 주석은 upstream 설계에 대한 벤더 측 불만을 보여 준다. "The current upstream PCIe P2PDMA architecture does not allow drivers to specify a page_free callback. We plan to work with upstream maintainers to resolve this…" P2PDMA 코어는 BAR 전체를 `gen_pool`로 관리하고 `p2pdma_pgmap_ops`를 고정한다. 반면 GPU 드라이버는 자기 메모리 관리자(UVM PMM)로 BAR 페이지를 직접 할당·회수하고 싶어 한다. 그래서 NVIDIA는 등록 뒤 `pgmap->ops`를 덮어쓰는 우회를 쓴다. 이 긴장은 v6.19 Romanovsky 시리즈("Refactor to separate core P2P functionality from memory allocation", `372d6d1b8ae3`)로 일부 해소되기 시작했다. 코어 판정 로직(`p2pdma_provider`, `pci_p2pdma_map_type()` 공개)과 genalloc 기반 할당기가 분리됐다.

### 3.6 다음 단계: 장치가 I/O를 시작한다면

LSFMM+BPF 2025에서 Stephen Bates는 P2PDMA의 다음 단계로 device-initiated I/O를 제안했다(LWN [Device-initiated I/O](https://lwn.net/Articles/1022718/), Jake Edge, 2025-06-04). 같은 기사에 따르면 IOMMU가 켜진 상태에서 DMA 매핑을 할 때 NVMe 드라이버는 코어당 약 200만 IOPS만 유지하고, pass-through 모드에서는 약 800만 IOPS다(발표자 수치, 측정 조건 미상). DMA 매핑 비용이 P2P를 포함한 고성능 I/O의 병목이라는 지적이고, 3.4절 API 재작업의 동기와 같다. 상세 논쟁은 (→ 08/03) 3절에서 다룬다.

---
## 4. Implementation Impact

### 4.1 공급자 API: BAR를 P2P 메모리로 등록하기

`include/linux/pci-p2pdma.h`(v7.3-rc7)의 공급자 측 API는 다음과 같다.

- `int pci_p2pdma_add_resource(struct pci_dev *pdev, int bar, size_t size, u64 offset)` — `EXPORT_SYMBOL_GPL`. 내부 흐름은 다음 순서다. BAR 유효성 검사(`IORESOURCE_MEM`, 범위) → `pcim_p2pdma_init()` → `pci_p2pdma_setup_pool()`(`gen_pool_create(PAGE_SHIFT, …)`) → `pcim_p2pdma_provider(pdev, bar)`로 `struct p2pdma_provider { owner, bus_offset }` 획득 → `struct pci_p2pdma_pagemap` 할당 → `pgmap->type = MEMORY_DEVICE_PCI_P2PDMA`, `pgmap->ops = &p2pdma_pgmap_ops` → `devm_memremap_pages()`로 `ZONE_DEVICE` struct page 생성 → `gen_pool_add_owner(pool, vaddr, pci_bus_address(pdev, bar) + offset, …, &pgmap->ref)`로 CPU 가상주소와 버스 주소를 함께 풀에 등록한다. 성공하면 "added peer-to-peer DMA memory %#llx-%#llx" 로그가 찍힌다.
- `void pci_p2pmem_publish(struct pci_dev *pdev, bool publish)` — 다른 드라이버가 `pci_p2pmem_find*()`로 찾아 쓸 수 있게 공개한다.
- `pcim_p2pdma_init()` / `pcim_p2pdma_provider()` — v6.19에서 page 없는 공급자 계층으로 분리됐다(`372d6d1b8ae3`). VFIO의 dma-buf export(`drivers/vfio/pci/vfio_pci_dmabuf.c`, v6.19+)가 `pcim_p2pdma_provider()`를 써서 BAR를 struct page 없이 dma-buf로 내보낸다.

`memremap_pages` 제약 때문에 크기·시작 주소가 정렬돼야 한다. `nvme_map_cmb()`는 `IS_ALIGNED(size, memremap_compat_align())`를 검사한다. LWN 767281의 2024년 독자 댓글은 비정렬 크기(29MB 등)에서 `pci_p2pdma_add_resource()`가 실패한 사례를 보고한다(댓글이므로 참고 수준).

### 4.2 소비자 API: 거리, 탐색, 할당

| API | 역할 |
|---|---|
| `pci_p2pdma_distance_many(provider, clients[], n, verbose)` / `pci_p2pdma_distance()` | 공급자와 모든 클라이언트 간 거리. 불가하면 음수 |
| `pci_p2pmem_find_many(clients[], n)` / `pci_p2pmem_find(client)` | 공개된 공급자 중 가장 가까운 것(동률이면 무작위) |
| `pci_alloc_p2pmem()` / `pci_free_p2pmem()` / `pci_p2pmem_virt_to_bus()` | genalloc 풀에서 할당 |
| `pci_p2pmem_alloc_sgl()` / `pci_p2pmem_free_sgl()` | scatterlist 형태로 할당 (nvmet용) |
| `pci_p2pdma_enable_store()` / `pci_p2pdma_enable_show()` | configfs/sysfs의 "auto/none/장치명" 파싱 헬퍼 |
| `pci_p2pdma_map_type(provider, dev)` | 매핑 유형 판정 (v6.19부터 비-static 공개 함수, `EXPORT_SYMBOL`은 없음, `395698bd2cd7`) |
| `pci_p2pdma_state(&state, dev, page)` / `pci_p2pdma_bus_addr_map(provider, paddr)` | 매핑 시점 헬퍼 (v6.16 재작성) |

`calc_map_type_and_dist()`의 알고리즘은 다음과 같다. 공급자 `a`에서 `pci_upstream_bridge()`를 따라 올라가며 각 브리지에서 클라이언트 `b`의 상위 체인을 훑어 공통 조상을 찾는다. 올라가는 동안 `pci_bridge_has_acs_redir()`가 `PCI_ACS_RR | PCI_ACS_CR | PCI_ACS_EC` 비트를 확인한다. 공통 조상이 있고 ACS redirect가 없으면 `PCI_P2PDMA_MAP_BUS_ADDR`, 거리는 `dist_a + dist_b`이다. 소스 주석 예시에서 같은 스위치의 두 다운스트림 포트 아래 장치 간 거리는 4다. 그 외에는 host bridge를 경유하는 것으로 본다. 이때 `cpu_supports_p2pdma()` 또는 `host_bridge_whitelist()`(`pci_p2pdma_whitelist[]`, 일부 항목은 `REQ_SAME_HOST_BRIDGE` 플래그로 같은 host bridge일 때만 허용)를 통과하면 `PCI_P2PDMA_MAP_THRU_HOST_BRIDGE`, 아니면 `PCI_P2PDMA_MAP_NOT_SUPPORTED`이다. 결과는 공급자의 `p2pdma->map_types` xarray에 캐시된다(`110203bee05f`, v5.4).

### 4.3 NVMe CMB를 p2pmem으로

`nvme-pci`의 `nvme_map_cmb()`(4.20 `0f238ff5cc92` "Use PCI p2pmem subsystem to manage the CMB")는 다음 순서로 동작한다. NVMe 1.4+ `NVME_CAP_CMBS`면 `NVME_REG_CMBMSC`에 `NVME_CMBMSC_CRE`를 써서 레지스터를 활성화한다. `NVME_REG_CMBSZ`/`NVME_REG_CMBLOC`에서 크기·오프셋·BAR 번호(`NVME_CMB_BIR`)를 계산하고, BAR 크기로 자른다. 정렬을 검사한 뒤 `pci_p2pdma_add_resource(pdev, bar, size, offset)`를 호출하고, 성공하면 `pci_p2pmem_publish(pdev, true)`로 공개한다. `pci_p2pmem_publish()`는 `dev->cmbsz`에 `NVME_CMBSZ_WDS | NVME_CMBSZ_RDS`(쓰기·읽기 데이터 지원)가 모두 있을 때만 호출된다. `NVME_CMBSZ_SQS`가 있으면 CMB에 SQ를 두는 기존 용도(`cmb_use_sqes`)도 함께 쓸 수 있다. sysfs에는 `/sys/bus/pci/devices/<bdf>/p2pmem/{size,available,published,allocate}`가 생긴다.

요청 쪽은 `nvme_pci_supports_pci_p2pdma()` → `dma_pci_p2pdma_supported(dev->dev)`가 참이면 `nvme_alloc_ns()`(`drivers/nvme/host/core.c`)의 queue limits 설정에서 `lim.features |= BLK_FEAT_PCI_P2PDMA`를 켠다. 이 기능 비트는 v6.11에서 `QUEUE_FLAG_PCI_P2PDMA`(4.20 `49d92c0dd64a`) 대신 들어간 queue limits 기반 표기다. v7.2부터는 NVMe multipath 헤드 디스크(`fb0eeeed91f3`)와 MD RAID 장치(`02666132403a`, 멤버의 기능을 전파)도 이 비트를 가진다.

### 4.4 nvmet: p2pmem configfs

NVMe-oF target에서는 namespace별 configfs 속성 `p2pmem`(`drivers/nvme/target/configfs.c`의 `nvmet_ns_p2pmem_show/store`)이 `pci_p2pdma_enable_store()`로 "auto", "none" 또는 특정 PCI 장치 이름을 받는다. 연결 시 `nvmet_p2pmem_ns_add_p2p()`(`core.c`)가 다음을 수행한다. 지정 장치면 `pci_p2pdma_distance(ns->p2p_dev, ctrl->p2p_client, true)`로 RDMA NIC(`p2p_client`)와 namespace 블록 장치 양쪽에서 도달 가능한지 확인한다. auto면 `pci_p2pmem_find_many({p2p_client, nvmet_ns_dev(ns)}, 2)`로 가장 가까운 공급자를 찾는다. I/O 시 `nvmet_req_alloc_p2pmem_sgls()` 경로에서 `pci_p2pmem_alloc_sgl()`로 데이터·메타데이터 SGL을 할당한다. RDMA NIC가 P2P 메모리에 RDMA READ/WRITE하고, NVMe가 같은 버퍼로 블록 I/O를 수행한다. **호스트 DRAM을 전혀 거치지 않는 NVMe-oF target**이고, 2017 RFC의 원래 목표 그대로다. RDMA 쪽은 4.20 `50b7d22079f7` "IB/core: Ensure we map P2P memory correctly in rdma_rw_ctx_[init|destroy]()"로 지원됐다.

### 4.5 사용자 공간 O_DIRECT 경로 (Linux 6.2+)

v6.2의 Gunthorpe 시리즈 9개 커밋이 사용자 공간 경로를 완성했다.

| 커밋 | 내용 |
|---|---|
| `0f0892356fa1` | `try_grab_page()`가 여러 오류 코드를 돌려줄 수 있게 함 |
| `4003f107fa2e` | `FOLL_PCI_P2PDMA` 도입: 이 플래그 없이 P2PDMA 페이지를 GUP하면 실패 |
| `d82076403cef` | `iov_iter_get_pages_[alloc_]flags()` 도입 |
| `49580e690755`, `1567b49d1a40` | bio·scatterlist에서 zone device 페이지 merge 시 같은 pgmap인지 확인 |
| `5e3e3f2e15df` | `__bio_iov_iter_get_pages()`: 큐가 P2PDMA를 지원하면 `FOLL_PCI_P2PDMA` 설정 |
| `7ee4ccf57484` | `bio_map_user_iov()`(passthrough)에도 같은 처리 |
| `7e9c7ef83d78`, `6d4338cb4070` | sysfs `p2pmem/allocate` mmap과 ABI 문서 |

콜패스(v7.3-rc7)는 다음과 같다.

1. 사용자: `fd = open("/sys/bus/pci/devices/<nvme_bdf>/p2pmem/allocate", O_RDWR)`, `buf = mmap(NULL, len, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0)`. `p2pmem_alloc_mmap()`은 `VM_MAYSHARE`가 아니거나 offset이 0이 아니면 `-EINVAL`을 돌려준다. `gen_pool_alloc_owner()`로 청크를 할당하고, pgmap `percpu_ref`를 잡은 뒤 페이지마다 `vm_insert_page()`로 VMA에 넣는다. ABI 문서 표현으로는 "For each mmap() call on this file, the kernel will allocate a chunk of Peer-to-Peer memory".
2. 사용자: 다른 NVMe 위 파일 `fd2`(`O_DIRECT`)로 `pread(fd2, buf, len, off)`.
3. 커널: `iomap_dio_rw` 등 → `bio_iov_iter_get_pages()`. 현재 코드는 `bio->bi_bdev && blk_queue_pci_p2pdma(bio->bi_bdev->bd_disk->queue)`면 `ITER_ALLOW_P2PDMA`(`include/linux/uio.h`, `iov_iter_extraction_t` 0x01)를 추출 플래그로 넘긴다. `iov_iter_extract_pages()` → `pin_user_pages_fast()`가 `FOLL_PCI_P2PDMA`로 GUP한다.
4. GUP: `mm/gup.c`의 `try_grab_folio()` 계열은 `!(flags & FOLL_PCI_P2PDMA) && folio_is_pci_p2pdma(folio)`이면 `-EREMOTEIO`를 돌려준다. fast-GUP 경로도 `is_pci_p2pdma_page(page)`이면 NULL이다. 또 `FOLL_LONGTERM | FOLL_PCI_P2PDMA` 조합은 `WARN_ON_ONCE`로 거부된다(주석: "We want to allow the pgmap to be hot-unplugged at all times"). 즉 RDMA MR처럼 장기 pin하는 용도는 이 경로로 불가능하다. (→ 08/03)의 dma-buf 경로가 필요한 이유다.
5. 블록: bio 병합 시 `bio`/`blk-merge`가 P2P 페이지와 일반 페이지, 또는 서로 다른 pgmap 페이지를 같은 세그먼트로 합치지 않는다(`block/bio.c`의 `is_pci_p2pdma_page()` 검사).
6. NVMe 매핑: 4.6절.

이 경로의 의미는 **CPU가 데이터 이동을 시작하지만 payload는 한 장치의 BAR에서 다른 장치로 직행한다**는 것이다. NVIDIA GDS P2PDMA 모드는 공급자가 NVMe CMB가 아니라 GPU BAR1(`nvidia-uvm`의 `pci_p2pdma_add_resource`)이라는 점만 다르다.

### 4.6 DMA 매핑 재작업: `dma_iova_*`와 `blk_rq_dma_map_*`

**v6.16 IOVA API**(`include/linux/dma-mapping.h`):

```c
struct dma_iova_state { dma_addr_t addr; u64 __size; };
bool dma_iova_try_alloc(struct device *dev, struct dma_iova_state *state,
                        phys_addr_t phys, size_t size);
int  dma_iova_link(struct device *dev, struct dma_iova_state *state,
                   phys_addr_t phys, size_t offset, size_t size,
                   enum dma_data_direction dir, unsigned long attrs);
int  dma_iova_sync(struct device *dev, struct dma_iova_state *state,
                   size_t offset, size_t size);
void dma_iova_unlink(...); void dma_iova_destroy(...); void dma_iova_free(...);
static inline bool dma_use_iova(struct dma_iova_state *state);
```

`dma_iova_try_alloc()`은 IOMMU가 있으면 요청 전체 크기의 연속 IOVA를 한 번에 잡는다. IOMMU가 없거나 swiotlb가 필요하면 false를 돌려준다. 그러면 호출자는 세그먼트별 직접 매핑으로 간다. scatterlist를 만들지 않고 `phys_addr_t`만으로 동작하므로 struct page가 필요 없다(위 선언은 v7.3-rc7 헤더 원문과 대조했다).

**v6.16 P2PDMA 헬퍼**(`a25e7962db0d`, `ca2c2e4a78c6`): `struct pci_p2pdma_map_state { struct p2pdma_provider *mem; enum pci_p2pdma_map_type map; }`와 `pci_p2pdma_state(state, dev, page)`. 페이지가 P2PDMA가 아니면 `PCI_P2PDMA_MAP_NONE`, 맞으면 `__pci_p2pdma_update_state()`로 유형과 공급자를 채운다. 버스 직통이면 `pci_p2pdma_bus_addr_map(provider, paddr)` = `paddr + provider->bus_offset`이다.

**v6.17 블록 반복자**(`include/linux/blk-mq-dma.h`, `block/blk-mq-dma.c`):

```c
struct blk_dma_iter {
        dma_addr_t addr; u32 len;               /* 이번 세그먼트 출력 */
        struct pci_p2pdma_map_state p2pdma;
        blk_status_t status;
        struct blk_map_iter iter;               /* v6.18부터 별도 구조체 */
};
bool blk_rq_dma_map_iter_start(struct request *req, struct device *dma_dev,
                               struct dma_iova_state *state, struct blk_dma_iter *iter);
bool blk_rq_dma_map_iter_next(...);
```

`blk_dma_map_iter_start()`는 첫 세그먼트를 꺼내 `pci_p2pdma_state()`로 판정한다. `PCI_P2PDMA_MAP_BUS_ADDR`면 `blk_dma_map_bus()`가 버스 주소를 바로 돌려준다(IOMMU 우회). `THRU_HOST_BRIDGE`와 `NONE`은 같은 경로로 처리된다. `blk_can_dma_map_iova()`이고 `dma_iova_try_alloc()`이 성공하면 `blk_rq_dma_map_iova()`가 `dma_iova_link()`로 모든 세그먼트를 한 IOVA 창에 연결한다. 아니면 `blk_dma_map_direct()`가 `dma_map_phys()`로 세그먼트마다 매핑한다. 그 외 유형(NOT_SUPPORTED)은 `BLK_STS_INVAL`이다. `nvme-pci`는 v6.17 `7ce3c1dd78fc`에서 PRP/SGL 생성을 이 반복자로 바꿨다. 중간 `struct scatterlist` 할당이 사라졌다. 같은 시기 out-of-tree `nvidia-fs`는 NVMe 패치를 `nvme_v2_register_nvfs_dma_ops`(`HAVE_BLK_RQ_DMA_MAP_ITER_START`)로 분기해야 했다(→ 08/01, 3.1절). `struct blk_map_iter`는 태그 grep 기준 v6.18에 처음 나타난다. `nvidia-fs` 소스 주석은 이를 "Kernel 7.0+"라고 적는데, 이는 NVIDIA 쪽 서술과 메인라인 태그가 어긋나는 부분이다.

### 4.7 레거시 vs 신규 데이터패스 비교

| 단계 | P2P 없음 (DRAM bounce) | P2PDMA ≤6.15 (scatterlist) | P2PDMA ≥6.17 (`blk_rq_dma_map`) |
|---|---|---|---|
| 버퍼 기술 | 일반 page | `MEMORY_DEVICE_PCI_P2PDMA` page | 동일 |
| GUP | `FOLL_PIN` | `FOLL_PIN \| FOLL_PCI_P2PDMA` (6.2+) | 동일 (`ITER_ALLOW_P2PDMA`) |
| 드라이버 매핑 | `blk_rq_map_sg` → `dma_map_sgtable` | `dma_map_sgtable`이 P2P 세그먼트 인식 (6.0+), 불가 시 `-EREMOTEIO` | `blk_rq_dma_map_iter_start/next` + `pci_p2pdma_state` |
| IOMMU 사용 | 세그먼트별 또는 SG 결합 | BUS_ADDR는 우회, THRU_HOST_BRIDGE는 매핑 | BUS_ADDR는 `pci_p2pdma_bus_addr_map`, 나머지는 `dma_iova_link`로 연속 IOVA |
| 중간 할당 | `struct scatterlist` 테이블 | 동일 | 없음 (IOVA 사용 시 `dma_vec`도 생략, `1bb94ff5ab4b`) |
| payload 경로 | 장치→DRAM→(복사)→장치 | 장치 BAR↔장치 직행 | 동일 |

### 4.8 dma-buf 계층과의 관계

| 측면 | ZONE_DEVICE pgmap 계층 | `p2pdma_provider` + dma-buf 계층 |
|---|---|---|
| struct page | 있음 | 없음 |
| 사용 가능한 uAPI | `O_DIRECT` read/write, passthrough (`bio_map_user_iov`) | dma-buf fd를 받는 API (RDMA dma-buf MR, VFIO, DRM) |
| 장기 pin | 불가 (`FOLL_LONGTERM` 거부) | importer가 move_notify/invalidate로 관리 |
| 수명 관리 | pgmap refcount가 0이 될 때까지 remove 대기 | dma-buf invalidation으로 동기 shutdown |
| 대표 공급자 | NVMe CMB, NVIDIA GPU BAR1(`nvidia-uvm`) | VFIO PCI BAR (v6.19+), GPU 드라이버 dma-buf exporter |
| 아키텍처 요구 | `ZONE_DEVICE`, `memremap_pages` 정렬 | 없음 |

### 4.9 버전 연표

| 커널 | 변화 | 근거 커밋 |
|---|---|---|
| (2017-03-30) | RFC "Copy Offload with Peer-to-Peer PCI Memory" | LWN 718593 |
| 4.20 | P2PDMA 코어, `QUEUE_FLAG_PCI_P2PDMA`, nvme CMB p2pmem, nvmet `p2pmem`, rdma_rw P2P | `52916982af48`, `49d92c0dd64a`, `0f238ff5cc92`, `c6925093d0b2`, `50b7d22079f7` |
| 5.2 | AMD Zen root complex 허용(`0f97da831026`), IOMMU 존재 시 화이트리스트 무시 | `6dbbd053e6ae` |
| 5.4 | ACS용 host bridge 화이트리스트, host bridge 경유 시 `dma_map`, map type xarray 캐시 | `e2cbfbf78968`, `5d52e1abcd47`, `110203bee05f` |
| 5.9 | `cpu_supports_p2pdma()`: AMD Zen 이상 전체 | `dea286bb71ba` |
| 6.0 | `dma_map_sg`가 P2P 페이지 지원, `pci_p2pdma_[un]map_sg` 제거 | `0d06132fc84b` |
| 6.2 | `FOLL_PCI_P2PDMA`, bio GUP 플래그, sysfs `p2pmem/allocate` | `4003f107fa2e`, `5e3e3f2e15df`, `7e9c7ef83d78` |
| 6.11 | `QUEUE_FLAG_PCI_P2PDMA` → `BLK_FEAT_PCI_P2PDMA` (queue limits) | 태그 grep |
| 6.15 | compound zone device page, p2pdma refcount 초기화 이동 | `82ba975e4c43`, `b7e282378773` |
| 6.16 | 2단계 IOVA API, P2PDMA 매핑 헬퍼 재작성 | `393cf700e624`, `433a76207dcf`, `a25e7962db0d` |
| 6.17 | `blk_rq_dma_map_iter_*`, nvme-pci 변환 | `858299dc6160`, `7ce3c1dd78fc` |
| 6.19 | 코어/할당기 분리, `p2pdma_provider`, `pci_p2pdma_map_type()` 공개, VFIO dma-buf | `372d6d1b8ae3`, `395698bd2cd7` |
| 7.1 | Google SoC, 와일드카드 Device ID | `70cf146a674c`, `1a1f96e3e2a8` |
| 7.2 | Intel QAT/DSA/IAA, NVMe multipath, MD RAID 전파 | `0ba76b19fd4c`, `fb0eeeed91f3`, `02666132403a` |
| 7.3-rc | NVIDIA Vera Rubin 화이트리스트 | `894a78088fc3` |

---

## 5. Primary References

- [PCI Peer-to-Peer DMA Support](https://docs.kernel.org/driver-api/pci/p2pdma.html) — 커널 공식 문서 (라우팅, 수명 주기, provider/pgmap 2계층, 드라이버 작성 가이드)
- 소스: [drivers/pci/p2pdma.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/pci/p2pdma.c), [include/linux/pci-p2pdma.h](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/include/linux/pci-p2pdma.h), [block/blk-mq-dma.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/block/blk-mq-dma.c), [include/linux/dma-mapping.h](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/include/linux/dma-mapping.h), [drivers/nvme/target/core.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/nvme/target/core.c)
- 커밋: [52916982af48 PCI/P2PDMA: Support peer-to-peer memory](https://github.com/torvalds/linux/commit/52916982af48), [4003f107fa2e mm: introduce FOLL_PCI_P2PDMA to gate getting PCI P2PDMA pages](https://github.com/torvalds/linux/commit/4003f107fa2e), [7e9c7ef83d78 PCI/P2PDMA: Allow userspace VMA allocations through sysfs](https://github.com/torvalds/linux/commit/7e9c7ef83d78), [858299dc6160 block: add scatterlist-less DMA mapping helpers](https://github.com/torvalds/linux/commit/858299dc6160), [fb0eeeed91f3 nvme-multipath: enable PCI P2PDMA for multipath devices](https://github.com/torvalds/linux/commit/fb0eeeed91f3)
- [Copy Offload with Peer-to-Peer PCI Memory](https://lwn.net/Articles/718593/) (Logan Gunthorpe RFC, 2017-03-30)
- [Device-to-device memory-transfer offload with P2PDMA](https://lwn.net/Articles/767281/) (Marta Rybczyńska, LWN, 2018-10-02)
- [Removing struct page from P2PDMA](https://lwn.net/Articles/791676/) (Logan Gunthorpe RFC, 2019-06-20)
- [Userspace P2PDMA with O_DIRECT NVMe devices](https://lwn.net/Articles/883051/) (Logan Gunthorpe v5, 2022-01-27)
- [DMA Mapping P2PDMA Pages](https://lwn.net/Articles/900481/) (Logan Gunthorpe v8, 2022-07-08)
- [Peer-to-peer DMA](https://lwn.net/Articles/931668/) (Jake Edge, LSFMM+BPF 2023, 2023-05-16)
- [Dancing the DMA two-step](https://lwn.net/Articles/997563/) (Jonathan Corbet, 2024-11-14)
- [Provide a new two step DMA mapping API](https://lwn.net/Articles/1008073/) (Leon Romanovsky v7, 2025-02-05)
- [Device-initiated I/O](https://lwn.net/Articles/1022718/) (Jake Edge, LSFMM+BPF 2025, 2025-06-04)
- [GPUDirect Storage Overview Guide](https://docs.nvidia.com/gpudirect-storage/overview-guide/index.html) — CUDA 12.8 NVMe P2PDMA 모드 (교차 검증)
- [NVIDIA/open-gpu-kernel-modules uvm_devmem.c](https://github.com/NVIDIA/open-gpu-kernel-modules/blob/main/kernel-open/nvidia-uvm/uvm_devmem.c) — GPU BAR1의 `pci_p2pdma_add_resource` 사용과 `page_free` 우회
