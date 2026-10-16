# NVIDIA GPUDirect Storage 해부: bounce buffer 문제, cuFile API, nvidia-fs.ko의 I/O 경로 후킹, 그리고 upstream P2PDMA로의 이동

> 기준: GPUDirect Storage(GDS) 문서 세트 v1.19.1(docs.nvidia.com/gpudirect-storage, 2026-10-15 확인), `NVIDIA/gds-nvidia-fs` `master`(2026-09-23 push), `NVIDIA/open-gpu-kernel-modules` 615.78.08(2026-10-07 커밋). API 이름·구조체·enum은 cuFile API Reference Guide 원문을, 커널 모듈 내부 이름은 위 저장소 소스를 grep해 대조했다. 성능 수치는 출처를 함께 적고, 출처가 없으면 `[추측/미확인]`으로 표시한다.

## 1. Verdict

GPUDirect Storage(GDS)는 "스토리지와 GPU 메모리 사이 DMA에서 CPU 시스템 메모리의 bounce buffer를 빼는 것"을 목표로 하는 NVIDIA의 소프트웨어 스택이다. 공식 Overview Guide 첫 문단의 정의는 다음과 같다.

> "GPUDirect® Storage (GDS) enables a direct data path for direct memory access (DMA) transfers between GPU memory and storage, which avoids a bounce buffer through the CPU."
>
> — [GPUDirect Storage Overview Guide](https://docs.nvidia.com/gpudirect-storage/overview-guide/index.html) 1.1 Introduction (2026-10-15 확인)

해설: 핵심은 "DMA 엔진이 누구냐"이다. GDS 경로에서 데이터를 옮기는 것은 NVMe 컨트롤러나 RDMA NIC의 DMA 엔진이다. CPU는 명령만 만들고 payload에는 손대지 않는다. GPU 복사 엔진(`cudaMemcpy`)도 쓰지 않는다.

이 문서의 결론은 다섯 가지다.

1. **GDS는 API 계층과 커널 경로 계층으로 나뉜다.** 응용은 `libcufile.so`의 cuFile API(`cuFileDriverOpen`, `cuFileHandleRegister`, `cuFileBufRegister`, `cuFileRead`/`cuFileWrite`, `cuFileBatchIO*`, `cuFileReadAsync`/`cuFileWriteAsync`)만 본다. 아래 커널 경로는 네 가지 중 하나로 정해진다. (a) out-of-tree 모듈 `nvidia-fs.ko`(NVFS 모드), (b) upstream PCI P2PDMA(CUDA 12.8 이후 NVMe), (c) dma-buf(일부 분산 파일시스템), (d) POSIX bounce 경로(compat 모드). NVIDIA는 API를 고정하고 구현을 바꾼다는 입장을 문서에 명시한다(3.5절).
2. **`nvidia-fs.ko`는 "가짜 CPU 페이지 + 드라이버 콜백"으로 동작하는 우회로다.** 커널 블록 계층은 GPU 가상주소를 다루지 못한다. 그래서 `nvidia-fs.ko`는 CPU 쪽 shadow buffer 페이지를 VFS에 대신 흘려 보낸다. 패치된 NVMe/NVMe-oF/분산 FS 드라이버가 `struct nvfs_dma_rw_ops` 콜백(`nvfs_is_gpu_page`, `nvfs_blk_rq_map_sg`, `nvfs_dma_map_sg_attrs`)으로 그 페이지를 GPU BAR 주소로 바꿔 DMA를 프로그래밍한다. 이 방식은 리눅스 코어 수정 없이 동작한다. 대신 스토리지 드라이버마다 NVIDIA 패치(MLNX_OFED/DOCA 배포)가 필요하다.
3. **2025년(CUDA 12.8) 이후 로컬 NVMe 경로는 upstream P2PDMA로 옮겨 가는 중이다.** Overview Guide는 CUDA 12.8부터 x86_64에서 NVMe(로컬 또는 DOCA SNAP)가 `nvidia-fs.ko`나 `nvme.ko` 패치 없이 upstream PCI P2PDMA를 쓸 수 있다고 적는다. 오픈 커널 모듈의 `nvidia-uvm`은 GPU의 static BAR1을 `pci_p2pdma_add_resource()`로 등록한다(`kernel-open/nvidia-uvm/uvm_devmem.c`). 단 RAID0와 NVMe multipath는 이 모드에서 아직 제약이 있다. RAID1/RAID10의 P2PDMA 모드는 GDS v1.19 기준 "kernel 7.2 and later"에서 지원된다.
4. **compat 모드는 기능이면서 함정이다.** `nvidia-fs.ko`가 없거나, 파일시스템이 GDS를 지원하지 않거나, `O_DIRECT`를 쓸 수 없으면 cuFile은 POSIX `pread`/`pwrite`와 내부 bounce buffer로 조용히 내려간다(`allow_compat_mode`). 이식성은 좋아지지만 "GDS를 쓰고 있다고 믿었는데 실제로는 bounce 경로"인 상황이 생긴다. 운영 환경에서는 `gdscheck.py -p`와 cuFile 통계로 경로를 확인해야 한다.
5. **성능 이득은 PCIe 토폴로지가 결정한다.** NVIDIA 문서도 이득이 "GPU와 NVMe/NIC가 같은 PCIe 스위치 아래 있을 때" 가장 크다고 한다. Troubleshooting Guide는 IOMMU off(또는 `iommu=pt`)와 ACS 비활성화를 권한다. 둘 다 격리·보안과 맞바꾸는 설정이다. 그래서 GDS는 "켜면 빨라지는 기능"이 아니고 플랫폼 설계의 문제다.

---

## 2. Problem Statement

### 2.1 bounce buffer 경로: 두 번의 DMA와 한 번의 시스템 메모리 경유

GDS가 없을 때 파일 데이터를 GPU로 올리는 표준 경로는 다음과 같다.

1. `pread(fd, sysmem_buf, ...)`: NVMe DMA가 데이터를 CPU 시스템 메모리(page cache 또는 사용자 버퍼)에 쓴다.
2. `cudaMemcpy(dev_buf, sysmem_buf, ..., cudaMemcpyHostToDevice)`: GPU 복사 엔진이 같은 데이터를 시스템 메모리에서 다시 읽어 PCIe로 GPU HBM에 쓴다.

Overview Guide 1.2절 첫 예제가 이 패턴이다("`pread` is used to move data from storage into a CPU bounce buffer, `sysmem_buf`"). 이 경로의 비용은 세 가지다.

- **메모리 대역폭 두 배 소모**: 같은 바이트가 DRAM에 한 번 쓰이고 한 번 읽힌다. 다중 GPU 서버에서는 CPU 소켓의 메모리 대역폭과 루트 포트 대역폭이 공유 병목이 된다.
- **지연 증가**: 두 DMA가 직렬이다. 두 번째 DMA는 첫 번째가 끝나야 시작된다. 파이프라이닝하려면 응용이 청크를 나눠야 한다.
- **CPU 사용**: page cache 경로라면 `copy_to_user`가 추가되고, bounce buffer 관리와 동기화에 CPU 코어를 쓴다.

NVIDIA 기술 블로그 [GPUDirect Storage: A Direct Path Between Storage and GPU Memory](https://developer.nvidia.com/blog/gpudirect-storage/)(Adam Thompson 외, 2019-08-06)는 DGX-2에서 시스템 메모리→GPU 대역폭이 50 GB/s로 제한되는 반면, 시스템 메모리·다수 로컬 드라이브·다수 NIC를 합하면 "nearly 200 GB/s" 상한에 이를 수 있다고 썼다. 같은 글은 GPU 복사 엔진 대신 로컬 NVMe의 DMA 엔진을 쓰자 I/O 대역폭이 12.0 GB/s에서 13.3 GB/s로 약 10% 늘었다고 보고한다(PCIe Gen3, Volta 세대, GTC19 발표 기반 초기 수치). 2019년 하드웨어 기준 수치이므로 현재 PCIe Gen5 시스템에 그대로 적용하면 안 된다.

### 2.2 PCIe 토폴로지: "직접 경로"가 실제로 짧은가

Overview Guide는 "a direct path between local or remote storage that goes through a PCIe switch or a NIC acting as a PCIe switch offers at least twice the peak bandwidth as compared to taking a data path through the CPU"라고 적는다. 조건은 **같은 PCIe 스위치 아래에 GPU와 NVMe/NIC가 있는 것**이다. GPU와 NVMe가 서로 다른 루트 포트에 있으면 P2P 트래픽이 CPU 루트 컴플렉스를 지나야 한다. 이 경우 다음 문제가 생긴다.

- 루트 컴플렉스 간 P2P 포워딩을 지원하지 않는 CPU가 있다. 그래서 커널 P2PDMA도 host bridge 화이트리스트를 둔다(→ 08/02).
- 지원하더라도 대역폭·지연이 스위치 내부 P2P보다 나쁠 수 있다. GDS의 Dynamic Routing(1.2.6절)이 이 문제를 다룬다. 같은 루트 포트에 있는 다른 GPU의 메모리를 중간 bounce buffer로 쓰고 NVLink로 목적 GPU에 복사한다.

### 2.3 커널 I/O 스택은 GPU 메모리를 모른다

리눅스 블록 계층의 데이터 기술자는 `struct bio_vec`(page, offset, len)이다. NVMe 드라이버는 이를 `struct scatterlist`로 바꾸고 `dma_map_sg()`로 버스 주소를 얻는다. 여기에는 두 가지 전제가 있다.

1. 버퍼 메모리에 `struct page`가 있다. `O_DIRECT`에서는 `iov_iter_get_pages`/`pin_user_pages`가 사용자 VA를 page 배열로 바꾼다.
2. 그 page의 물리 주소는 CPU 메모리이고, DMA API가 IOMMU를 통해 장치 버스 주소로 바꾼다.

`cudaMalloc`으로 받은 GPU 메모리는 두 전제를 모두 깬다. GPU VA는 CPU 페이지 테이블에 없다(UVM이 아닌 한). GPU HBM은 GPU BAR1 창을 통해서만 PCIe에 노출되며, 그 물리 주소에는 기본적으로 `struct page`가 없다. Overview Guide 1.3절은 이를 "Existing operating systems attempting to program DMA engines cannot process GPU virtual addresses without help"라고 표현한다. 해결책은 두 갈래다.

- **우회(NVFS)**: CPU 쪽 대리(proxy) 페이지를 만들어 VFS를 통과시키고, 마지막 DMA 매핑 단계에서만 드라이버가 GPU 주소로 바꾼다. `nvidia-fs.ko` 방식이다.
- **정공(P2PDMA)**: GPU BAR를 `ZONE_DEVICE`의 `MEMORY_DEVICE_PCI_P2PDMA` 페이지로 등록해 `struct page`를 만든다. 그 페이지를 사용자 공간에 매핑하고 `FOLL_PCI_P2PDMA`로 pin하면 일반 `O_DIRECT` 경로로 흘려 보낼 수 있다. upstream 커널 방식이다.

### 2.4 O_DIRECT 요구와 정렬

[O_DIRECT Requirements Guide](https://docs.nvidia.com/gpudirect-storage/o-direct-guide/index.html)는 "O_DIRECT is the only supported mode before CUDA toolkit 12.2 (GDS version 1.7)"라고 적는다. page cache를 거치면 DMA 목적지가 page cache 페이지가 되므로 GPU 직접 경로가 성립하지 않는다. CUDA 12.2(GDS 1.7) 이후 cuFile은 non-`O_DIRECT` fd도 받는다. 다만 이 경우는 page cache를 쓰는 compat 경로다. 정렬도 문제다. cuFile은 4KiB 비정렬 `file_offset`·크기·GPU 오프셋을 내부 정렬 버퍼로 흡수한다. Best Practices Guide는 이것을 "unaligned IO" 패턴으로 분류하고, 중간 정렬 버퍼가 필요할 수 있다고 경고한다.

---
## 3. The Debate

GDS의 논쟁은 LKML보다 NVIDIA 문서·릴리스 노트, 그리고 upstream P2PDMA/dma-buf 논의(→ 08/02, 08/03)에 흩어져 있다. 이 절은 확인 가능한 1차 문서에 근거해 쟁점을 정리한다. 메인테이너 발언 원문은 lore.kernel.org가 이 환경에서 403을 반환해 직접 확인하지 못했다. 그래서 인용 블록을 쓰지 않고 (→ 08/02)에서 LWN·커밋으로 교차 검증한 내용만 다룬다.

### 3.1 out-of-tree 콜백 vs upstream 인프라: 유지보수 비용 논쟁

`nvidia-fs.ko` 방식은 리눅스 코어를 고치지 않는다. Overview Guide도 "The Linux kernel core is completely unmodified"라고 강조한다. 하지만 이 말은 "블록 계층과 VFS는 그대로"라는 뜻이다. **스토리지 드라이버는 수정해야 한다.** 같은 문서는 "In some cases, NVIDIA provides patches to these, or alternate, implementations, for example, to kernel modules for NVMe and NVMe-oF"라고 적는다. `nvidia-fs` 소스의 `modules_list[]`(`src/nvfs-dma.c`)에는 `nvidia-fs`가 찾아 호출하는 등록 함수 이름이 들어 있다. `nvme_v1_register_nvfs_dma_ops`/`nvme_v2_register_nvfs_dma_ops`, `nvme_rdma_v1_register_nvfs_dma_ops`, `lustre_v1_register_nvfs_dma_ops`, `beegfs_v1_register_nvfs_dma_ops`, `ibm_scale_v1_register_nvfs_dma_ops`, `rpcrdma_register_nvfs_dma_ops`, `panfs_register_nvfs_dma_ops` 등이다. 즉 NVMe, NVMe-oF RDMA, NFS over RDMA, 각 분산 FS 클라이언트가 이 심볼을 export하도록 패치되어 있어야 한다.

이 구조의 유지보수 비용은 릴리스 노트에 그대로 나온다.

- **v1.19.1 known issue**: "On Linux 6.17 and later with nvidia-fs mode enabled, the NVMe patch has a known issue with drives that support scatter-gather lists (SGLs)... As a workaround, use the p2pdma path on these kernels." upstream NVMe 드라이버의 DMA 매핑 경로가 바뀌자 out-of-tree 패치가 깨진 사례다(→ 08/02, 4.6절의 `blk_rq_dma_map_iter_start` 재작업과 시기가 겹친다).
- **소스의 버전 분기**: `src/nvfs-dma.c`에는 "Kernel 7.0+ replaced req_iterator with blk_map_iter inside blk_dma_iter"라는 주석과 `HAVE_BLK_MAP_ITER`, `HAVE_BLK_RQ_DMA_MAP_ITER_START` 조건 컴파일이 있다. `HAVE_BLK_RQ_DMA_MAP_ITER_START`가 정의되면 `nvme_v2_register_nvfs_dma_ops`를 찾는다. 커널 내부 API가 바뀔 때마다 NVMe 패치와 `nvidia-fs`가 함께 버전을 올려야 한다.
- **v1.16 known issue**: `nvidia-fs`가 로드되어 있는데 NVMe/NVMe-oF 드라이버가 패치되지 않았으면, 블록 장치 I/O가 GDS 경로를 잘못 시도하다 실패할 수 있다. 우회책은 `nvidia-fs` 언로드였다.
- **P2P 인터페이스 버전**: "The nvidia.ko kernel P2P interface version has changed to 0x00020000 starting from NVIDIA driver version R580.82.05. The nvidia-fs.ko module must be rebuilt..." `nv-p2p.h`의 `NVIDIA_P2P_PAGE_TABLE_VERSION`이 `0x00020000`인 것과 맞는다.

upstream 진영(Logan Gunthorpe, Christoph Hellwig, Jason Gunthorpe 등)은 PCI P2PDMA와 dma-buf를 "struct page 또는 dma-buf 기반의 일반 인프라"로 만들어 왔다. 특정 벤더 콜백을 블록 드라이버에 넣는 방식은 upstream에 받아들여지지 않았다. NVIDIA가 CUDA 12.8에서 NVMe 경로를 P2PDMA로 옮긴 것은 이 논쟁이 사실상 upstream 쪽으로 정리됐다는 신호다. 다만 분산 FS(Lustre, WekaFS, GPFS, NFS over RDMA, BeeGFS)는 여전히 `nvidia-fs` 콜백이나 벤더 dma-buf 경로를 쓴다. gdscheck 샘플 출력에서 IBM Spectrum Scale과 WekaFS는 `dmabuf, compat`로 표시된다.

### 3.2 IOMMU와 ACS: 성능 vs 격리

[Installation and Troubleshooting Guide](https://docs.nvidia.com/gpudirect-storage/troubleshooting-guide/index.html)의 권고는 상당히 공격적이다.

- IOMMU: "In our experience, iommu=off provides the best functionality and performance. On certain platforms, such as DGX A100 and DGX-2, iommu=pt is supported. iommu=on is not guaranteed to work functionally or performantly." 그리고 `amd_iommu=off`/`intel_iommu=off` 커널 인자 예를 든다.
- ACS: "For best GPUDirect Storage (GDS) performance, disable PCIe ACS at boot"라며 `pci=disable_acs_redir=pci:0:0` 예시를 준다.

ACS(Access Control Services) Request Redirect가 켜져 있으면 스위치 아래 장치 간 P2P 요청도 루트 컴플렉스로 올라가 IOMMU 검사를 받는다. 격리는 강해지지만 P2P 경로가 길어진다. ACS를 끄면 같은 스위치 아래 장치들이 IOMMU를 거치지 않고 서로의 BAR에 접근할 수 있다. 그 결과 IOMMU group이 커지고 VFIO 장치 할당이나 멀티테넌트 격리에 영향을 준다. 커널 P2PDMA의 `pci_p2pdma_distance` 계산도 ACS redirect가 켜진 경로를 "host bridge 경유"로 취급한다(→ 08/02). **GDS를 위한 플랫폼 튜닝은 가상화·보안 요구와 직접 충돌한다.** 클라우드 VM 안에서 GDS를 쓸 때 compat 모드로 떨어지는 경우가 많은 이유가 여기 있다 `[추측/미확인]`(공식 문서에서 VM 일반에 대한 서술은 확인하지 못했다).

### 3.3 compat 모드: 이식성 vs 투명성

cuFile API Reference Guide 2절은 compat 모드 설정을 다음처럼 나열한다.

- `"allow_compat_mode": true` — 열린 fd가 GDS를 쓸 수 없다고 판단되면 compat 모드로 떨어진다.
- `"force_compat_mode": false` — true면 모든 I/O를 compat 모드로 강제한다. "Alternatively the admin can unload the nvidia_fs.ko or not expose the character devices in the docker container environment."
- 파일시스템별 스위치: `fs.generic.posix_unaligned_writes`, `fs.lustre.posix_gds_min_kb`, `fs.weka.rdma_write_support`, `fs.gpfs.gds_write_support` 등.

같은 절의 fallback 표는 compat 모드가 자동으로 쓰이는 경우를 열거한다. "No BAR1 memory in GPU", "Bounce buffers cannot be allocated in GPU memory", WekaFS/IBM Spectrum Scale에서 커널이 `-ENOTSUP`을 돌려준 경우(내부 재시도), 그리고 "The nvidia_fs.ko driver is not loaded" 등이다. 찬성 논리는 Overview Guide 1.2.3절에 있다. compat 모드는 "allows the cuFile APIs to be used ubiquitously even under suboptimal circumstances"이고, 성능은 "generally at least the same or better than current CPU-based APIs"라는 것이다. 반대쪽 우려는 운영 측면이다. 오류 없이 느려지기 때문에 컨테이너에 `/dev/nvidia-fs*`를 노출하지 않은 것 같은 배포 실수가 성능 회귀로만 드러난다. KvikIO도 같은 문제를 겪어 `KVIKIO_COMPAT_MODE=AUTO`의 fallback 조건을 명시한다. 예를 들어 "`/run/udev` isn't readable, which typically happens when running inside a docker image not launched with `--volume /run/udev:/run/udev:ro`"인 경우다(4.9절).

### 3.4 GPL 경계

Overview Guide는 `nvidia-fs.ko`를 "Licensed under GPLv2"라고 명시하고, "any kernel third-party kernel components that call the nvidia-fs APIs should expect to be subject to GPLv2"라고 덧붙인다. 소스의 `MODULE_LICENSE("GPL v2")`(`src/nvfs-core.c`)와 일치한다. `nvidia-fs`는 `nvidia.ko`의 `nvidia_p2p_get_pages()`/`nvidia_p2p_dma_map_pages()`(`kernel-open/nvidia/nv-p2p.h`)를 호출해 GPU 메모리를 pin하고 매핑한다. 오픈 커널 모듈(Dual MIT/GPL) 이전에는 이 경계가 GPL 심볼 사용 문제와 얽혀 있었다. P2PDMA 모드에서는 `nvidia-uvm`이 GPL-only 심볼인 `pci_p2pdma_add_resource()`를 직접 호출한다. 이는 오픈 커널 모듈이어야 가능한 설계다. Overview Guide가 P2PDMA 모드의 조건으로 "OpenRM driver version 570.x or above"를 요구하는 것과도 맞는다. (`pci_p2pdma_add_resource`의 `EXPORT_SYMBOL_GPL` 여부는 (→ 08/02)에서 커널 소스로 확인한다.)

### 3.5 "API는 남고 구현이 바뀐다"

NVIDIA는 upstream이 P2P를 흡수해도 cuFile API는 유지된다고 문서에 못 박았다.

> "The cuFile APIs will remain relevant after the functionalities mentioned earlier are added to Linux. Only the underlying implementations will change, but not the existing cuFile APIs."
>
> — [GPUDirect Storage Overview Guide](https://docs.nvidia.com/gpudirect-storage/overview-guide/index.html) 1.3.3 Aligning with Other Linux Initiatives (2026-10-15 확인)

해설: 이 문장은 CUDA 12.8에서 실제로 실행됐다. 응용 코드는 그대로 두고 `cufile.json`의 `use_pci_p2pdma` 스위치와 드라이버 레지스트리 설정만으로 NVMe 경로를 NVFS에서 P2PDMA로 바꿀 수 있다. 반대 시각도 있다. upstream만으로도 `cudaMalloc` 메모리를 P2PDMA 페이지로 노출하고 `O_DIRECT`/io_uring으로 직접 읽을 수 있다면, cuFile의 부가가치는 batch/stream 연동, 정렬 흡수, compat fallback, 분산 FS 통합 정도로 줄어든다. NVIDIA는 v1.17~v1.19에서 dma-buf interoperability, user-defined topology, scatter-gather API, `prefer_iouring`(`CUFILE_PARAM_PREFER_IO_URING`) 같은 기능을 계속 추가하고 있다. 라이브러리 계층의 존재 이유를 넓히는 방향이다.

### 3.6 배포 모델의 변화

Troubleshooting Guide에는 "Starting in CUDA Toolkit 13.4, nvidia-fs must be installed separately"라는 문장이 있다. 비-DGX 플랫폼에서 `nvidia-fs`는 CUDA Toolkit 번들에서 빠져 별도 다운로드 페이지로 옮겨졌다. cuFile 사용자 공간 라이브러리와 도구는 계속 Toolkit에 들어 있다. NVMe 사용자에게 `nvidia-fs`가 선택 사항이 된 흐름과 맞는 변화다.

---
## 4. Implementation Impact

### 4.1 소프트웨어 계층과 경로 선택

Overview Guide 1.3.1절의 계층은 다음과 같다. (1) `cufile.h`를 include하는 응용, (2) 사용자 공간 라이브러리 `libcufile.so`(RDMA 정보는 `libcufile_rdma.so`), (3) VFS, (4) 리눅스 또는 벤더 커널 스토리지 드라이버, (5) `nvidia-fs.ko`(조건부). `libcufile`은 "based on the filesystem, the configuration, and the hardware support"를 보고 경로를 고른다. 선택 단위는 mount point이다(`<file path> –> <mount point> –> <filesystem selection>`). 런타임 의존성은 `libcuda.so`뿐이고 CUDA Runtime 링크는 필요 없다.

| 경로 | 커널 쪽 구성요소 | 대상 | GPU 주소 변환 주체 | 도입 |
|---|---|---|---|---|
| NVFS (`CUFILE_NVFS`) | `nvidia-fs.ko` + 패치된 `nvme`/`nvme-rdma`/FS 클라이언트 | ext4/XFS on NVMe·NVMe-oF, Lustre, BeeGFS, NFSoRDMA 등 | 드라이버가 `nvfs_dma_rw_ops` 콜백 호출 | GDS 1.0 (지원 매트릭스상 2021-06 WekaFS 항목이 최초) |
| PCI P2PDMA (`CUFILE_P2PDMA`) | upstream `CONFIG_PCI_P2PDMA` + OpenRM ≥570 `nvidia-uvm` | NVMe(로컬, DOCA SNAP) on x86_64 | 커널 DMA API(`pci_p2pdma_map_type`) | CUDA 12.8, GDS 1.13 |
| dma-buf (`CUFILE_DMABUF`) | `nvidia.ko` dma-buf exporter + FS/RDMA importer | IBM Spectrum Scale, WekaFS (gdscheck 샘플 기준) | importer의 `dma_buf_map_attachment` | v1.17 "DMA-Buf interoperability" 등 `[추측/미확인: 최초 도입 버전]` |
| C2C (`CUFILE_C2C`) | Grace 계열 칩 간 coherent 링크 | Grace Hopper/Blackwell 시스템 | 하드웨어 coherent 주소 | v1.19 RAID1/10 C2C 언급 |
| compat | 없음 (POSIX `pread`/`pwrite`, 선택적으로 io_uring) | 모든 fd | 해당 없음 (CPU bounce) | 1.0부터 |

`CUfileP2PFlags_t` enum 원문은 `CUFILE_P2PDMA = 0`, `CUFILE_NVFS = 1`, `CUFILE_DMABUF = 2`, `CUFILE_C2C = 3`, `CUFILE_NVIDIA_PEERMEM = 4`(주석: "Only for IBM Spectrum Scale and WekaFS")이다. GDS 1.16에 추가된 `cuFileDriverSetP2PFlags(CUfileDriverStatusFlags_t status_flag, CUfileP2PFlags_t p2p_flags)`로 파일시스템/장치 종류별 P2P 모드를 설정한다. 문서는 "On x86_64 platforms: only CU_FILE_P2P_FLAG_PCI_P2PDMA is allowed. On AARCH64 platforms: only CU_FILE_P2P_FLAG_C2C is allowed"라고 제한한다. NVFS와 DMABUF 플래그는 드라이버가 내부에서 관리한다.

### 4.2 cuFile 기본 API와 수명 주기

API Reference Guide 3.1절의 규칙을 정리하면 이렇다. `cuFileDriverOpen`은 선택 사항이다(호출하지 않으면 첫 `cuFileHandleRegister`/`cuFileRead`/`cuFileWrite`/`cuFileBufRegister`에서 암묵 초기화). `cuFileHandleRegister`는 필수다. "All APIs are thread-safe"이고, "The fork system call should not be used after the library is initialized"이며, "All APIs are issued from the CPU, not the GPU"이다. 마지막 문장은 GDS와 GPU-initiated I/O(→ 08/03의 BaM)를 가르는 기준이다.

```c
/* cuFile API Reference Guide 원문 시그니처 기반 (오류 처리 생략) */
CUfileError_t st = cuFileDriverOpen();              /* 선택: 명시 초기화 */

int fd = open("/mnt/nvme/data.bin", O_RDONLY | O_DIRECT);
CUfileDescr_t descr = {0};
descr.handle.fd = fd;
descr.type = CU_FILE_HANDLE_TYPE_OPAQUE_FD;         /* 1: linux fd */
CUfileHandle_t fh;
st = cuFileHandleRegister(&fh, &descr);             /* mount/열기 방식으로 GDS 가능성 판정 */

void *dev; cudaMalloc(&dev, SZ);
st = cuFileBufRegister(dev, SZ, 0);                 /* 선택: GPU 메모리 pin + BAR1 매핑 */

ssize_t n = cuFileRead(fh, dev, SZ, /*file_offset*/0, /*bufPtr_offset*/0);

cuFileBufDeregister(dev);
cuFileHandleDeregister(fh);
close(fd);
cuFileDriverClose();
```

- `ssize_t cuFileRead(CUfileHandle_t fh, void *bufPtr_base, size_t size, off_t file_offset, off_t bufPtr_offset)`: 반환값은 POSIX처럼 바이트 수 또는 음수 오류다. CUDA 12.2(GDS 1.7)부터 `bufPtr_base`로 호스트 메모리도 받는다.
- `CUfileError_t cuFileBufRegister(const void *bufPtr_base, size_t size, int flags)`: 등록하지 않은 버퍼는 "an internal registered memory is used if required"이다. 즉 내부 GPU bounce buffer(크기 `per_buffer_cache_size_kb`)를 거쳐 한 번 더 복사된다. 등록에는 BAR1 공간을 쓴다. BAR1이 작은 GPU에서는 `max_device_pinned_mem_size_kb`와 BAR1 크기(`cuFileGetBARSizeInKB`)가 상한이 된다.
- `CUfileDescr_t`의 `type`에는 `CU_FILE_HANDLE_TYPE_OPAQUE_FD = 1`, `CU_FILE_HANDLE_TYPE_OPAQUE_WIN32 = 2`, `CU_FILE_HANDLE_TYPE_USERSPACE_FS = 3`이 있다. 세 번째는 사용자 공간 FS가 `CUfileFSOps_t` 콜백을 제공하는 경로다.
- 드라이버 속성은 `cuFileDriverGetProperties`가 `CUfileDrvProps_t`로 돌려준다. `nvfs` 하위 구조에 `major_version`, `minor_version`, `poll_thresh_size`, `max_direct_io_size`, `dstatusflags`(지원 FS 비트), `dcontrolflags`(`CU_FILE_USE_POLL_MODE`, `CU_FILE_ALLOW_COMPAT_MODE`)가 있고, 바깥에 `fflags`(`CU_FILE_BATCH_IO_SUPPORTED`, `CU_FILE_STREAMS_SUPPORTED`, `CU_FILE_P2P_SUPPORTED` 등), `max_device_cache_size`, `per_buffer_cache_size`, `max_pinned_memory_size`, `max_batch_io_timeout_msecs`가 있다. 설정 함수는 `cuFileDriverSetPollMode`, `cuFileDriverSetMaxDirectIOSize`, `cuFileDriverSetMaxCacheSize`, `cuFileDriverSetMaxPinnedMemSize`이고, GDS 1.14부터 일반화된 `cuFileGetParameter*`/`cuFileSetParameter*`(Bool/SizeT/String) 계열이 추가됐다.

### 4.3 Batch API: io_submit을 닮은 비동기 인터페이스

Batch API는 "submitted synchronously, but executed asynchronously with respect to host thread"이다. 구조는 Linux AIO의 `io_setup`/`io_submit`/`io_getevents`와 거의 같다.

```c
CUfileError_t cuFileBatchIOSetUp(CUfileBatchHandle_t *batch_idp, int max_nr);
CUfileError_t cuFileBatchIOSubmit(CUfileBatchHandle_t batch_idp, unsigned nr,
                                  CUfileIOParams_t *iocbp, unsigned int flags);
CUfileError_t cuFileBatchIOGetStatus(CUfileBatchHandle_t batch_idp, unsigned min_nr,
                                     unsigned *nr, CUfileIOEvents_t *iocbp,
                                     struct timespec *timeout);
CUfileError_t cuFileBatchIOCancel(CUfileBatchHandle_t batch_idp);
void          cuFileBatchIODestroy(CUfileBatchHandle_t batch_idp);
```

(시그니처는 API Reference Guide 5.5.1~5.5.5절 원문 기준이다. `cuFileBatchIODestroy`만 `void`를 반환한다. `max_nr`은 "between 1 - properties.io_batch_size"이다.)

`CUfileIOParams_t`는 `mode`(반드시 첫 필드, `CUFILE_BATCH`), `u.batch.{devPtr_base, file_offset, devPtr_offset, size}`, `fh`, `opcode`(`CU_FILE_READ`/`CU_FILE_WRITE`), `cookie`로 구성된다. 완료 이벤트 `CUfileIOEvents_t`는 `cookie`, `status`, `ret`을 담는다. 상태 enum `CUfileStatus_t`는 `CUFILE_WAITING`(제출 전 필수값), `CUFILE_PENDING`, `CUFILE_INVALID`, `CUFILE_CANCELED`, `CUFILE_COMPLETE`, `CUFILE_TIMEOUT`, `CUFILE_FAILED`이다. 커널 쪽에서는 `NVFS_IOCTL_BATCH_IO`(`src/nvfs-core.h`)와 `src/nvfs-batch.c`가 받는다. GDS 1.16 이전에는 batch I/O 크기가 bounce buffer 크기로 제한됐다. 1.16에서 그보다 큰 batch I/O는 POSIX I/O로 처리하게 바뀌었고, 1.18에서 "Removed the batch I/O size limitation for GDS mode that was caused by the bounce buffer size"가 들어갔다.

### 4.4 Stream API: CUDA stream 순서에 I/O 끼워 넣기

`cuFileReadAsync`/`cuFileWriteAsync`는 크기·오프셋을 **포인터**로 받는다(`size_t *size_p`, `off_t *file_offset_p`, `off_t *bufPtr_offset_p`, `ssize_t *bytes_read_p`, `CUstream stream`). 앞선 커널이 계산한 값을 실행 시점에 읽을 수 있게 하려는 설계다. 문서는 "Operations that are enqueued with cuFile Stream APIs are FIFO ordered with respect to other work on the stream"이라고 정의한다. `cuFileStreamRegister(CUStream_t stream, unsigned flags)`의 `flags`는 어떤 값이 제출 시점에 확정되는지 알려 준다. `0x1` 버퍼 오프셋, `0x2` 파일 오프셋, `0x4` 크기가 제출 시점에 유효하고, `0x8`은 모든 입력이 4K 정렬이라는 뜻이다. `0xf`가 "perform best"이다.

중요한 점은 **I/O를 시작하는 주체가 여전히 CPU 스레드**라는 것이다. stream API는 GPU 작업과 I/O의 순서를 맞춰 줄 뿐, GPU가 NVMe doorbell을 직접 울리지는 않는다. 그래서 stream 연동은 CPU 쪽 헬퍼 스레드나 stream memop(`CUFILE_PARAM_STREAM_MEMOPS_BYPASS` 파라미터가 존재함)로 구현된다고 볼 수 있다 `[추측/미확인: 내부 구현은 비공개]`. IBM Spectrum Scale과 WekaFS에서는 "All Async and batch operations will internally use compatibility mode IO"라는 제약도 있다.

### 4.5 `nvidia-fs.ko` 내부: shadow buffer, ioctl, 드라이버 콜백

`NVIDIA/gds-nvidia-fs` 소스로 Overview Guide의 "Workflow 1"을 따라가면 다음과 같다.

1. **GPU 버퍼 등록(`NVFS_IOCTL_MAP`)**: `libcufile`은 `/dev/nvidia-fs*` 문자 장치를 mmap해 CPU 가상주소 영역(shadow buffer)을 만든다. 이어 `NVFS_IOCTL_MAP`으로 `nvfs_map()`을 호출한다. `nvfs_map()`은 `nvfs_mgroup_pin_shadow_pages(cpuvaddr, length)`로 shadow 페이지를 pin한다. 그다음 `nvfs_pin_gpu_pages()`가 `nvidia_p2p_get_pages()`(또는 `nvidia_p2p_get_pages_persistent()`)로 GPU 메모리를 pin하고 BAR 물리 페이지 테이블을 얻는다. 비영속 pin에는 `nvfs_get_pages_free_callback`이 등록된다. GPU 메모리가 해제되면 nvidia.ko가 이 콜백을 불러 매핑을 회수한다. shadow 페이지와 GPU 페이지의 대응은 `nvfs_mgroup` 객체(해시 테이블 `nvfs_io_mgroup_hash`)가 관리한다. 단위는 소스상 `NVFS_BLOCK_SIZE`가 4096(`src/nvfs-mmap.h`), `GPU_PAGE_SIZE`가 `1 << 16`=64KiB(`src/nvfs-core.h`)이다. 64KiB GPU 페이지 하나가 4KiB shadow 블록 16개에 대응하는 구조다. 64K 커널 페이지(Grace) 환경에서는 `PAGE_SIZE / NVFS_BLOCK_SIZE` 계산으로 페이지당 블록 수가 달라진다.
2. **읽기/쓰기(`NVFS_IOCTL_READ`/`NVFS_IOCTL_WRITE`)**: `nvfs_ioctl()` → `nvfs_io_start_op()` → `nvfs_direct_io()`. 이 함수는 **shadow buffer의 사용자 VA**로 `struct iovec`/`iov_iter`를 만들고, `init_sync_kiocb()`로 kiocb를 초기화한다. 비동기면 `ki_complete = nvfs_io_complete`를 설정한다. 이어 `call_read_iter()`(구커널) 또는 `filp->f_op->read_iter()`를 직접 호출한다. VFS·파일시스템·블록 계층 입장에서는 평범한 `O_DIRECT` 읽기다. 파일시스템은 extent 매핑을 하고, `iov_iter`의 페이지를 pin해 `bio`에 담는다. 이때 담기는 것은 shadow 페이지(CPU 페이지)다.
3. **드라이버의 DMA 매핑 단계**: 패치된 NVMe 드라이버는 요청을 매핑할 때 `struct nvfs_dma_rw_ops`를 확인한다. `nvfs_is_gpu_page(page)`가 참이면 일반 `blk_rq_map_sg()`/`dma_map_sg_attrs()` 대신 `nvfs_blk_rq_map_sg(q, req, sglist)`와 `nvfs_dma_map_sg_attrs(device, sglist, nents, dir, attrs)`를 부른다. `nvidia-fs`는 shadow 페이지에서 `nvfs_mgroup`을 찾는다. 그리고 `nvidia_p2p_dma_map_pages(peer, ...)`로 **해당 NVMe 장치(peer `pci_dev`) 기준의 GPU BAR DMA 주소**를 계산해 SG 리스트에 채운다. NVMe 컨트롤러는 그 주소로 PRP/SGL을 만들어 GPU BAR1에 직접 쓴다. `nvfs_is_gpu_page()`는 `__nvfs_mgroup_from_page()` 조회로 판정한다. 셧다운 경로에서 참조를 얻지 못해도 true를 돌려준다. 그래야 드라이버가 CPU 페이지로 착각해 shadow 메모리에 DMA하지 않는다.
4. **완료**: 블록 완료가 kiocb 완료로 올라오면 `nvfs_io_complete()`가 통계(`nvfs_read_bytes_per_sec` 등)를 갱신하고 사용자 공간에 알린다.

`struct nvfs_dma_rw_ops`의 필드는 `ft_bmap`(feature bitmap), `nvfs_blk_rq_map_sg`, `nvfs_dma_map_sg_attrs`, `nvfs_dma_unmap_sg`, `nvfs_is_gpu_page`, `nvfs_gpu_index`, `nvfs_device_priority`, `nvfs_get_gpu_sglist_rdma_info` 등이다(`src/nvfs-dma.h`). `nvfs_device_priority(dev, gpu_index)`는 RAID나 다중 경로에서 GPU와 가까운 장치를 고르는 데 쓰인다. `nvfs_get_gpu_sglist_rdma_info`는 NFSoRDMA나 분산 FS가 원격 RDMA 키를 얻는 데 쓰인다. RDMA 쪽 사용자 공간 정보는 `NVFS_IOCTL_SET_RDMA_REG_INFO`/`GET`/`CLEAR`로 주고받는다(Workflow 2).

이 설계의 의미는 "GPU 주소가 블록 계층을 통과하지 않는다"는 것이다. `bio`에는 언제나 CPU `struct page`(shadow)가 들어간다. 진짜 주소는 드라이버의 마지막 매핑 단계에서만 바뀐다. 블록 계층의 bounce, merge, split, integrity, 그리고 shadow 페이지에 실수로 CPU 접근이 일어나는 경우(예: 파일시스템이 데이터를 들여다보는 경로)에 대한 안전성은 모두 "드라이버가 콜백을 빠짐없이 호출한다"는 가정에 기댄다. 2026년 릴리스 노트의 SGL 경로 hang 이슈가 이 가정이 깨진 예다.

### 4.6 P2PDMA 모드: static BAR1과 `pci_p2pdma_add_resource`

CUDA 12.8(GDS 1.13) P2PDMA 모드에서는 `nvidia-fs`가 빠진다. 오픈 커널 모듈 615.78.08의 `kernel-open/nvidia-uvm/uvm_devmem.c`에는 다음 흐름이 있다.

- RM이 "a contiguous BAR mapping large enough to cover all of GPU memory that will be allocated to userspace buffers"를 만들면 `static_bar1_size`가 설정된다. 이것이 Troubleshooting Guide 16.3절의 `NVreg_RegistryDwords="RMForceStaticBar1=1;RmForceDisableIomapWC=1;"`이다. pre-Hopper GPU(L4, L40, A100, A40)에는 `ForceP2P=0`도 추가한다.
- BAR1이 write-combined로 매핑돼 있으면 P2PDMA 페이지를 만들 수 없다(소스 주석: "P2PDMA pages require the PCIe BAR to be mapped UC"). 그래서 `RmForceDisableIomapWC`가 필요하다.
- 조건이 맞으면 `pci_p2pdma_add_resource(parent_gpu->pci_dev, uvm_device_p2p_static_bar(parent_gpu), 0, 0)`로 BAR 전체를 P2PDMA 메모리로 등록한다. 커널은 `ZONE_DEVICE` 페이지와 `dev_pagemap`을 만든다.
- 소스는 upstream 한계도 적어 둔다. "The current upstream PCIe P2PDMA architecture does not allow drivers to specify a page_free callback." 그래서 등록 뒤 `page_pgmap(p2p_page)->ops = &uvm_device_p2p_pgmap_ops`로 커널이 만든 `dev_pagemap_ops`를 **덮어쓰는** 우회를 한다(TODO: "Allow drivers to manage and allocate PCI P2PDMA pages directly").
- 사용자 공간에는 `UVM_ALLOC_DEVICE_P2P` ioctl(`uvm_ioctl.h`, `UVM_IOCTL_BASE(78)`)과 `uvm_va_range_device_p2p_map_cpu()`가 P2PDMA 페이지를 CPU VA에 매핑하는 경로를 제공한다. 이렇게 매핑된 VA를 `O_DIRECT`로 넘기면 커널의 `iov_iter_extract_pages()`가 `FOLL_PCI_P2PDMA`로 pin한다(Linux 6.2+). NVMe 드라이버는 DMA 매핑 단계에서 `pci_p2pdma_state`로 P2P 버스 주소를 쓴다. libcufile이 정확히 이 ioctl을 쓰는지는 공개 문서로 확인하지 못했다 `[추측/미확인]`.

전제 조건은 Overview Guide와 Troubleshooting Guide 16절에 따르면 다음과 같다. 커널에 `p2pdma_pgmap_ops` 심볼이 있어야 하고(`/proc/kallsyms`로 확인), Ubuntu 기준 6.2 이상 또는 RHEL 9.4의 5.14 백포트 커널이어야 한다. NVMe multipath는 끈다(`options nvme_core multipath=N`). GPU는 A100, A40, L4, L40S, H100, H200, B100, B200, B300이다. `cufile.json`에는 `"properties": {"use_pci_p2pdma": true}`와 `"block": {"nvme": {"use_pci_p2pdma": true}}`를 설정한다.

### 4.7 `cufile.json`: 경로·버퍼·스레드 풀 제어

기본 설정 파일은 `/etc/cufile.json`이다. 응용별 파일은 `CUFILE_ENV_PATH_JSON` 환경변수로 지정한다([Benchmarking and Configuration Guide](https://docs.nvidia.com/gpudirect-storage/configuration-guide/index.html) 표 4.2). 운영에서 중요한 키는 다음과 같다(기본값은 해당 문서 및 Troubleshooting Guide의 gdscheck 샘플 기준).

| 키 | 기본값 | 의미 |
|---|---|---|
| `properties.allow_compat_mode` | true | GDS 불가 시 POSIX 경로로 fallback |
| `properties.force_compat_mode` | false | 모든 I/O를 compat로 강제 |
| `properties.use_pci_p2pdma` | false | 전역 P2PDMA 선호 (`block.nvme.use_pci_p2pdma` 등과 함께 켜야 함) |
| `properties.max_direct_io_size_kb` | 16384 (legacy) | `nvidia-fs`에 넘기는 I/O 청크 상한 |
| `properties.max_device_cache_size_kb` | 131072 (legacy) | GPU당 내부 bounce buffer 총량 |
| `properties.per_buffer_cache_size_kb` | 1024 | 내부 bounce buffer 하나의 크기 (v1.13부터 최대 16MiB) |
| `properties.gpu_bounce_buffer_slab_config` | `slab_size_kb` [1024, 8192, 16384, 65536] / `slab_count` [128, 8, 4, 2] | v1.17 slab 방식 bounce buffer (위 두 legacy 키 대체) |
| `properties.max_device_pinned_mem_size_kb` | 33554432 | GPU당 pin 가능한 총량(내부 bounce 포함) |
| `properties.use_poll_mode` / `poll_mode_max_size_kb` | false / 4 | 작은 I/O 완료를 sleep 대신 polling |
| `properties.rdma_dynamic_routing` | false (gdscheck 출력은 `0`) | 분산 FS의 cross-root-port 회피 라우팅 |
| `properties.prefer_iouring` | false | compat 경로에서 io_uring 선호 |
| `execution.max_io_threads` / `parallel_io` / `min_io_threshold_size_kb` / `max_request_parallelism` | 4 / true / 8192 / 4 | 큰 I/O를 내부 스레드 풀로 쪼개 병렬 처리 |
| `fs.<fs>.use_pci_p2pdma`, `block.{nvme,nvmeof,raid}.use_pci_p2pdma` | false | 대상별 P2PDMA 스위치 |

`execution.*` 항목은 중요한 사실을 보여 준다. GDS의 "direct" 경로도 큰 I/O를 내부 스레드 풀이 `min_io_threshold_size_kb` 단위로 쪼개 여러 커널 호출로 낸다. CPU 사용이 0이 되는 것이 아니고, payload 복사가 없어질 뿐이다.

### 4.8 지원 파일시스템과 전송 계층

Troubleshooting Guide의 gdscheck 샘플(GDS 1.16.0.49, nvidia_fs 2.27)은 드라이버 구성을 다음처럼 표시한다. `NVMe : nvfs, compat`, `NVMeOF : compat`, `SCSI : compat`, `FSx Lustre : Supported`, `IBM Spectrum Scale : dmabuf, compat`, `WekaFS : dmabuf, compat`, `NFS/BeeGFS/ScaTeFS/VIRTIOFS/DDN EXAScaler/NVMesh/ScaleFlux CSD : compat`, `Userspace RDMA : Supported`. 이 출력은 해당 호스트의 패치·모듈 상태를 반영한다. 지원 범위 그 자체가 아니다. 예를 들어 NVMeOF가 compat인 것은 그 호스트의 `nvme-rdma`가 패치되지 않았기 때문이다.

공식 지원 범위는 문서별로 다음과 같다.

- **로컬 블록 + 커널 FS**: ext4(ordered mode), XFS on NVMe/NVMe-oF/ScaleFlux CSD(`gds-nvidia-fs` README). Troubleshooting Guide 3.2.1절의 "EXT4/XFS: Mounting a Local File System for GDS". RAID는 NVMe RAID0(NVFS), RAID1/RAID10(v1.19, x86 P2PDMA는 kernel 7.2+).
- **분산·파트너 FS**(Release Notes 5절 Support Matrix): AWS FSx for Lustre(1.13.1+, 2024-11), DDN EXAScaler(1.1+, 2021-11), Dell PowerScale(1.0, 2021-10), Hammerspace(1.8, 2024-01), Hitachi HCSF, HPE Cray ClusterStor/GreenLake/Data Fabric, IBM Spectrum Scale(1.1+), NetApp ONTAP(1.0+, 2022-01), Pure FlashBlade(1.7+), VAST(1.1+), WekaFS(1.0, 2021-06), VDURA PanFS(1.19.1+, 2026-09).
- **전송**: 로컬 PCIe NVMe, NVMe-oF(RDMA, NVIDIA 패치 `nvme-rdma`), NFS over RDMA(MOFED 5.1+ 필요, README), 사용자 공간 RDMA(`libcufile_rdma.so`, WekaFS·GPFS 같은 벤더 클라이언트), DOCA SNAP(NVMe 에뮬레이션 DPU). compat 경로는 v1.17부터 ZFS와 BTRFS도 포함한다.
- **GPU**: GDS 모드는 "Data Center and Quadro (desktop) cards with compute capability > 6"이고, 그 외는 compat만 지원한다. v1.15에서 Pascal과 Volta 지원이 제거됐다. P2PDMA 모드 GPU 목록은 4.6절 참조.

### 4.9 KvikIO: cuFile 위의 사용자 친화 계층

RAPIDS [KvikIO](https://github.com/rapidsai/kvikio)는 cuFile의 C++/Python 바인딩이다. README는 "Object oriented API of cuFile with C++/Python exception handling"과 "Concurrent reads and writes using an internal thread pool"을 핵심 기능으로 든다. Python에서는 `kvikio.CuFile(path, "r")`로 열고 `f.pread(buf)`가 future를 돌려준다. C++에서는 `kvikio::default_thread_pool::reset(16)` 같은 스레드 풀 제어를 제공한다.

런타임 설정(`docs/source/runtime_settings.rst`)은 다음과 같다.

- `KVIKIO_COMPAT_MODE` = `ON`/`OFF`/`AUTO`. `AUTO`는 "Try cuFile I/O first, and fall back to POSIX I/O"이다. fallback 조건은 `libcufile.so`가 없을 때, WSL일 때, `/run/udev`를 읽을 수 없을 때이다.
- `KVIKIO_NTHREADS`(기본 1), `KVIKIO_TASK_SIZE`(기본 4 MiB): 큰 I/O를 태스크로 나눠 병렬 처리한다.
- `KVIKIO_GDS_THRESHOLD`(기본 16 KiB): 이보다 작은 I/O는 스레드 풀을 우회하고 POSIX 백엔드로 바로 처리한다. GDS 경로의 고정 비용이 작은 I/O에서는 손해라는 판단이 기본값에 반영되어 있다.
- `KVIKIO_BOUNCE_BUFFER_SIZE`(기본 16 MiB): POSIX 경로에서 스레드당 호스트 bounce buffer 크기.

KvikIO는 HTTP/S3 원격 읽기(`KVIKIO_REMOTE_IO_BACKEND`, `KVIKIO_HTTP_*`)도 지원한다. "GPU로 데이터를 올리는 범용 I/O 라이브러리"로 범위를 넓히고 있다. cuDF, Zarr 등 RAPIDS 생태계가 GDS를 쓰는 주 진입점이다.

### 4.10 버전 연표

| 시점 | 사건 | 근거 |
|---|---|---|
| 2019-08-06 | NVIDIA 기술 블로그에서 GDS 개념 공개 (DGX-2, GTC19 수치) | developer.nvidia.com 블로그 |
| 2020-12-02 | `NVIDIA/gds-nvidia-fs` GitHub 저장소 생성 | GitHub API `created_at` |
| 2021-06 ~ 2021-11 | GDS 1.0/1.1 호환 파트너 항목 (WekaFS 1.0 2021-06, VAST/DDN/IBM 1.1 2021-11) | Release Notes Support Matrix |
| Linux 6.2 (2023-02) | upstream `FOLL_PCI_P2PDMA` 사용자 공간 P2PDMA (→ 08/02) | 커널 소스 |
| CUDA 12.2 / GDS 1.7 | 호스트 메모리 버퍼, non-`O_DIRECT` fd 지원 | API Ref, O_DIRECT Guide |
| GDS 1.13 / CUDA 12.8 | NVMe P2PDMA 모드 (커널 6.2+ Ubuntu, RHEL 9.4) | Release Notes, Overview Guide |
| GDS 1.14 | P2PDMA 통계, `nvidia-fs` 6.12 지원, Get/Set Parameter API | Release Notes |
| GDS 1.15 | stats API, Pascal/Volta 제거 | Release Notes |
| GDS 1.16 | `cuFileDriverSetP2PFlags`/`GetP2PFlags`, FSx Lustre | Release Notes |
| GDS 1.17 | dma-buf interoperability, slab bounce buffer, ZFS/BTRFS compat | Release Notes |
| GDS 1.18 | `nvidia-fs` Linux 7.0 지원, batch 크기 제한 제거 | Release Notes |
| CUDA 13.4 | 비-DGX에서 `nvidia-fs` 별도 설치 | Troubleshooting Guide |
| GDS 1.19 / 1.19.1 | scatter-gather API, RAID1/10 (P2PDMA는 kernel 7.2+), PanFS | Release Notes |

CUDA 12.8과 GDS 1.13의 대응은 Overview Guide("As of CUDA 12.8")와 Release Notes(v1.13의 "NVME P2PDMA")를 교차해 추정한 것이다. 정확한 CUDA↔GDS 버전 매핑표는 확인하지 못했다 `[추측/미확인]`.

### 4.11 경로별 비교

| 항목 | CPU bounce (`pread`+`cudaMemcpy`) | cuFile compat | cuFile NVFS (`nvidia-fs.ko`) | cuFile P2PDMA |
|---|---|---|---|---|
| payload가 DRAM 경유 | 예 (2회 DMA) | 예 (내부 POSIX 풀) | 아니오 | 아니오 |
| `bio`에 담기는 page | 사용자/page cache 페이지 | 사용자 bounce 페이지 | shadow CPU 페이지(대리) | GPU BAR의 `ZONE_DEVICE` P2PDMA 페이지 |
| GPU 주소 변환 위치 | 해당 없음 | 해당 없음 | 패치된 드라이버 → `nvfs_dma_map_sg_attrs` → `nvidia_p2p_dma_map_pages` | 커널 DMA API (`pci_p2pdma_map_type`) |
| 필요한 커널 수정 | 없음 | 없음 | NVMe/FS 드라이버 패치 + out-of-tree 모듈 | 없음 (upstream 6.2+, OpenRM ≥570) |
| `O_DIRECT` | 선택 | 불필요 | 필수 | 필수 |
| 제약 | 메모리 대역폭, CPU 사용 | 성능 = POSIX 수준 | 커널 업그레이드마다 패치 재빌드 | multipath/RAID0 미지원, static BAR1·UC 매핑 필요 |
| IOMMU/ACS | 무관 | 무관 | off/pt 권장, ACS off 권장 | upstream 거리 계산에 종속 (→ 08/02) |

---
## 5. Primary References

- [GPUDirect Storage Overview Guide](https://docs.nvidia.com/gpudirect-storage/overview-guide/index.html): 정의, compat 모드, Dynamic Routing, 소프트웨어 구성요소, Workflow 1/2, CUDA 12.8 P2PDMA, GPL 고지
- [cuFile API Reference Guide](https://docs.nvidia.com/gpudirect-storage/api-reference-guide/index.html): `cuFileDriverOpen`, `cuFileHandleRegister`, `cuFileBufRegister`, `cuFileRead`/`Write`, `cuFileBatchIO*`, `cuFileReadAsync`/`WriteAsync`, `cuFileStreamRegister`, `CUfileP2PFlags_t`, `cuFileDriverSetP2PFlags`
- [GPUDirect Storage Installation and Troubleshooting Guide](https://docs.nvidia.com/gpudirect-storage/troubleshooting-guide/index.html): IOMMU/ACS 권고, gdscheck 출력, 16절 NVMe P2PDMA(드라이버 레지스트리, multipath, 지원 GPU)
- [GPUDirect Storage Release Notes](https://docs.nvidia.com/gpudirect-storage/release-notes/index.html): v1.7~v1.19.1 기능 변화, known issue, Support Matrix
- [GPUDirect Storage Benchmarking and Configuration Guide](https://docs.nvidia.com/gpudirect-storage/configuration-guide/index.html): `cufile.json` 변수 표, poll mode, `CUFILE_ENV_PATH_JSON`
- [GPUDirect Storage Best Practices Guide](https://docs.nvidia.com/gpudirect-storage/best-practices-guide/index.html): 정렬/비정렬 I/O 패턴
- [GPUDirect Storage O_DIRECT Requirements Guide](https://docs.nvidia.com/gpudirect-storage/o-direct-guide/index.html): `O_DIRECT` 요구와 GDS 1.7 이후 변화
- [GPUDirect Storage: A Direct Path Between Storage and GPU Memory](https://developer.nvidia.com/blog/gpudirect-storage/) (Adam Thompson 외, 2019-08-06): DGX-2 대역폭 수치
- 소스: [NVIDIA/gds-nvidia-fs](https://github.com/NVIDIA/gds-nvidia-fs) — [src/nvfs-dma.h](https://github.com/NVIDIA/gds-nvidia-fs/blob/master/src/nvfs-dma.h), [src/nvfs-dma.c](https://github.com/NVIDIA/gds-nvidia-fs/blob/master/src/nvfs-dma.c), [src/nvfs-core.c](https://github.com/NVIDIA/gds-nvidia-fs/blob/master/src/nvfs-core.c), [src/nvfs-core.h](https://github.com/NVIDIA/gds-nvidia-fs/blob/master/src/nvfs-core.h), [src/nvfs-mmap.c](https://github.com/NVIDIA/gds-nvidia-fs/blob/master/src/nvfs-mmap.c)
- 소스: [NVIDIA/open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules) — [kernel-open/nvidia-uvm/uvm_devmem.c](https://github.com/NVIDIA/open-gpu-kernel-modules/blob/main/kernel-open/nvidia-uvm/uvm_devmem.c), [kernel-open/nvidia/nv-p2p.h](https://github.com/NVIDIA/open-gpu-kernel-modules/blob/main/kernel-open/nvidia/nv-p2p.h)
- [rapidsai/kvikio](https://github.com/rapidsai/kvikio) 및 [runtime_settings.rst](https://github.com/rapidsai/kvikio/blob/main/docs/source/runtime_settings.rst): KvikIO API와 `KVIKIO_*` 설정
- 커널 측: [drivers/pci/p2pdma.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/pci/p2pdma.c), [PCI Peer-to-Peer DMA Support](https://docs.kernel.org/driver-api/pci/p2pdma.html) (상세는 → 08/02)
