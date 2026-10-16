# I/O 오픈소스 생태계 지도: 커널 경로 · 사용자 공간 경로 · 스토리지 시스템의 관계와 선택 기준

> 범위: `artifacts/01`~`13`의 도메인 문서 44개(01~10의 35개에 파일시스템·페이지 캐시 3개, 플랫폼 I/O 튜닝 2개, 블록 스택·패브릭·메모리 3개, Lustre 1개를 더한 9개)가 다룬 프로젝트를 한 장의 지도로 묶는다. 기준 시점은 2026-10이다(Linux master 7.3-rc7, SPDK v26.09, DPDK 23.11+, GDS 1.19, DAOS v2.8, OpenZFS 2.4, RocksDB 11.x, Ceph Tentacle v20, libfuse 3.18.3). 각 주장 뒤의 `(→ 07/01)` 같은 표기는 근거가 된 도메인 문서(디렉터리 번호/파일 번호)를 가리킨다. 도메인 문서에 없는 판단은 `[추측/미확인]`으로 표시했다.

## 1. Verdict

이 생태계는 "누가 장치 큐를 소유하는가"라는 하나의 축으로 정리된다.

1. **커널 경로**: 커널 드라이버가 장치를 소유한다. 사용자 공간은 점점 더 효율적인 큐 인터페이스를 받는다. io_uring(5.1)이 그 중심이다. 그 위에 NVMe 패스스루(`IORING_OP_URING_CMD`, 5.19), ublk(6.0), zcrx(6.15)가 같은 링을 재사용한다(→ 01/01, 03/02, 09/05, 04/02). 블록 계층(blk-mq)은 우회 대상이 아니다. 패스스루와 ublk도 blk-mq의 태그와 `struct request`를 그대로 쓴다(→ 03/02, 09/05). 장치 기능은 커널 공통 모델로 흡수된다. zoned 장치는 4.10부터, zone write plugging은 6.10부터, FDP write stream은 6.16부터, P2PDMA는 4.20부터(사용자 공간 `O_DIRECT`는 6.2부터) 들어왔다(→ 09/01, 09/02, 08/02).
2. **사용자 공간 경로**: 사용자 프로세스가 `vfio-pci`로 장치를 넘겨받아 직접 폴링한다. DPDK가 네트워크 쪽 원형이다. SPDK는 DPDK의 EAL을 환경 계층(`lib/env_dpdk`)으로 재사용해 NVMe에 같은 모델을 적용한다(→ 04/04, 07/01). xNVMe는 그 사이에서 "같은 NVMe 명령 API, 여러 백엔드"를 제공한다. 백엔드로 io_uring, io_uring_cmd, libaio, SPDK, libvfn 등을 고를 수 있다(→ 09/06). GDS/cuFile은 API는 사용자 공간에 두고, 실제 데이터 이동은 커널 경로(`nvidia-fs.ko` 또는 upstream P2PDMA)에 맡긴다. 그래서 GDS는 순수 바이패스가 아니라 혼합형이다(→ 08/01).
3. **스토리지 시스템**: 위 두 경로 중 어디에 서느냐로 성격이 갈린다. DAOS는 SPDK 위에서 "E2E in user space"를 택했다(→ 10/01). Ceph BlueStore는 커널 블록 장치(libaio 기본, io_uring 선택) 위에 있다. SPDK 백엔드는 빌드 옵션으로만 고를 수 있다(→ 06/03, synthesis/00 4.3절). OpenZFS는 커널 안에서 동작하지만 out-of-tree 모듈이다. 자체 ZIO 파이프라인과 vdev 스케줄러를 가지며, 블록 계층은 그 아래에 둔다(→ 10/02). RocksDB는 `FileSystem`/`Env` 추상화 하나로 커널 FS, BlueFS, ZenFS(zoned) 위에서 모두 돈다(→ 10/03). Lustre는 정반대 극단이다. 클라이언트(`llite`·`lov`·`osc`·`ldlm`·`lnet`)와 서버(`ofd` + ldiskfs 또는 ZFS OSD)가 모두 커널 모듈이고, out-of-tree로 유지된다. 확장성은 MDT에 저장되는 레이아웃(`trusted.lov`)과 분산 락 LDLM에서 나온다(→ 10/04).
4. **세 경로 모두가 지나는 공통 기반**: 어느 경로를 고르든 아래 계층의 비용은 따로 남는다.
   - **파일 계층**: 커널 FS의 파일 I/O는 모두 `kiocb` + `iov_iter` → `->read_iter`/`->write_iter`로 들어온다. Direct I/O는 XFS(4.10)부터 ext4(5.5), btrfs(5.10), f2fs(5.17)까지 공용 엔진 iomap으로 옮겨 갔다(→ 11/01). 버퍼드 I/O의 페이지 캐시는 `struct folio`(5.16)와 large folio로 단위가 커졌다. `RWF_DONTCACHE`(인터페이스 6.14, 실효 6.16)는 "캐시를 거치되 바로 버린다"는 제3의 선택지를 만들었다(→ 11/02).
   - **사용자 공간 파일시스템**: FUSE-over-io_uring(6.14)은 ublk의 `uring_cmd` 프로토콜을 파일 연산에 이식했다. 기본값은 꺼져 있다(모듈 파라미터 `enable_uring`, libfuse `-o io_uring`). 제로카피는 7.3-rc에 들어왔다(→ 11/03).
   - **플랫폼**: IOMMU를 켜면 커널 드라이버의 스트리밍 DMA는 I/O마다 IOVA 할당과 IOTLB 무효화 비용을 낸다. VFIO 기반 SPDK·DPDK는 이 비용을 시작 시 1회 고정 매핑으로 옮긴다(→ 12/01). 스토리지 IRQ는 커널이 정하는 managed interrupt라 제출 CPU와 완료 CPU가 구조적으로 맞는다. 반면 NIC IRQ는 사용자가 정한다. CPU 격리(`isolcpus=managed_irq`)는 best-effort에 그친다(→ 12/02).
   - **스태킹 블록 계층**: md와 dm은 bio 기반 가상 장치라 blk-mq 큐는 맨 아래 물리 장치에만 있다. 비용은 계층 자신의 직렬화(md 쓰기 의도 비트맵, 6.18 `md-llbitmap`)와 작업 큐 전환(dm-crypt, 5.9 `no_read_workqueue`/`no_write_workqueue`)에서 나온다. 기능은 `queue_limits`의 교집합으로만 위로 전파된다(→ 13/01).
   - **패브릭과 메모리**: RDMA는 제어 경로만 커널(`ib_core`)이 맡고, 데이터 경로는 사용자 공간 provider(rdma-core)나 커널 ULP(nvme-rdma, NFS/RDMA)가 직접 다룬다. 비용의 중심은 메모리 등록이다(→ 13/02). CXL은 리눅스에서 사실상 "Type 3 메모리 확장기를 CPU 없는 NUMA 노드로 만드는 것"이다. 그 메모리를 어떻게 쓸지는 mm의 티어링이 결정한다(→ 13/03).

현재 흐름은 다음과 같다. **코어당 효율 격차는 줄었지만 사라지지 않았다.** FAST '24 측정에서도 SPDK는 코어 하나로 장치 둘을 포화시켰고, 커널 패스스루는 그러지 못했다(→ 03/02). 그래서 선택 기준은 "어느 쪽이 빠른가"보다 "장치 공유, 격리, 관측성, 운영 도구를 얼마나 포기할 수 있는가"로 옮겨 갔다. 4.3절의 결정 매트릭스가 이 기준을 정리한다.

## 2. Problem Statement

### 2.1 왜 경로가 여러 개인가

NVMe와 100GbE급 NIC가 보급되자 요청 하나의 소프트웨어 비용이 장치 지연과 같은 규모가 됐다. 이를 줄이는 방법은 세 갈래로 나뉘었고, 각각 다른 대가를 치른다.

| 접근 | 줄이는 비용 | 치르는 대가 | 대표 프로젝트 |
|---|---|---|---|
| 커널 인터페이스 개선 | syscall 수(SQ/CQ 링, SQPOLL), 완료 IRQ(IOPOLL), fd·버퍼 참조(등록 자원) | 공격 표면(io_uring CVE 계열, → 01/03), 설정 복잡도 | io_uring, liburing, uring_cmd |
| 커널 계층 생략 | VFS·bio 분할·병합·스케줄러 | MDTS 초과 등 장치 한계를 앱이 처리, 명령 권한 모델 필요 | NVMe 패스스루 (`/dev/ngXnY`) |
| 커널 우회 | 커널 진입 전체, 인터럽트, 공유 락 | 장치 독점, CPU 상시 점유(폴링), 커널 도구로 안 보임 | SPDK, DPDK, BaM |
| 장치에 의미 전달 | 장치 내부 GC·WAF | 호스트 수정(ZNS) 또는 얕은 통합(FDP) | zoned/ZNS, FDP write stream |
| 메모리 경로 단축 | CPU DRAM bounce | PCIe 토폴로지 제약, IOMMU/ACS 설정 | P2PDMA, GDS, dma-buf |

### 2.2 측정이 서로 비교되지 않는다

"코어당 IOPS" 주장은 조건이 제각각이다. Jens Axboe의 "3.5M+ IOPS per core"(2021-08)는 512B 블록, 폴링, 등록 파일·버퍼, 1코어 조건의 `t/io_uring` 결과다. FAST '24의 10M IOPS는 Optane P5800X 2개, 512B randread 조건이다. Haas & Leis(VLDB 2023)의 12.5M IOPS는 4KiB, SSD 8개 조건이며, 이 논문은 fio의 인터럽트 기반 I/O 구현이 4KB 랜덤 읽기에서 전체 대역폭에 닿지 못해 벤치마크 도구 자체가 병목이 될 수 있다고 보고했다("fio can be the bottleneck", → 09/06 4.9절). 그러니 이 지도에서 프로젝트끼리 수치를 직접 비교하지 않는다. 대신 구조(누가 큐를 소유하는가, 완료 모델, 공유 범위)를 비교한다.

## 3. The Debate

### 3.1 커널 우회는 여전히 필요한가

SPDK의 설계 원칙은 공식 문서에 세 문장으로 나와 있다.

> "Moving all of the necessary drivers into userspace, which avoids syscalls and enables zero-copy access from the application. Polling hardware for completions instead of relying on interrupts, which lowers both total latency and latency variance. Avoiding all locks in the I/O path, instead relying on message passing."
>
> — SPDK, [What is SPDK](https://spdk.io/doc/about.html) (2026-10-14 확인, 07/01 문서)

해설: 커널 쪽의 답은 이 세 가지를 하나씩 흡수하는 것이었다. syscall은 SQ/CQ 공유 링과 SQPOLL로 줄였다. 인터럽트는 IOPOLL과 NVMe poll queue로 대체할 수 있게 했다. 락은 per-CPU `blk_mq_ctx`, hctx, 태그 `sbitmap`으로 잘게 나눴다(→ 01/01, 02/01). 그래도 FAST '24 논문의 결론은 "I/O Passthru reduces the per-core efficiency gap but is still far from kernel-bypass solutions like SPDK."다(→ 03/02). 반대 방향의 압력도 있다. SPDK는 "100% CPU" 비판에 대응해 interrupt 모드를 넓혀 왔다. v20.10 실험 기능에서 출발해 v24.09 NVMe-oF TCP target, v25.05 NVMe PCIe, v26.01 NVMe-oF RDMA target, v26.09 RDMA initiator까지 왔다(→ 07/01). 두 진영이 서로의 장점을 가져가며 가까워지는 중이다.

### 3.2 ZNS인가 FDP인가

ZNS는 장치가 순차 쓰기 제약을 호스트에 그대로 드러낸다. 호스트가 GC와 배치를 직접 맡는다. ATC '21 논문에서 zone-specialized RocksDB(ZenFS 위에서 동작)는 블록 인터페이스 SSD 대비 99.9 백분위 랜덤 읽기 지연이 최소 2–4배 낮고("at least 2–4× lower") 쓰기 처리량이 2배였다. 단 이는 물리 하드웨어가 같은("identical physical hardware") ZNS SSD와 블록 인터페이스 SSD를 비교한 결과다(→ 09/01). FDP는 하위 호환이다. 힌트를 무시해도 정상 동작하고 랜덤 쓰기도 허용한다. Meta CacheLib 논문(EuroSys '25)은 장치 WAF ~1을 보고했다(→ 09/02). 리눅스 통합은 두 방식의 성숙도가 다르다. zoned는 블록 계층·파일시스템·DM 전반에 들어가 있다. FDP write stream(6.16)을 쓰는 경로는 블록 장치 direct I/O, NVMe 패스스루, f2fs(7.2) 셋뿐이다(→ 09/02). ZNS SSD의 시장 보급 규모를 보여 주는 1차 자료는 찾지 못했다 `[추측/미확인]`.

### 3.3 GPU 메모리: struct page인가 dma-buf인가

P2PDMA는 BAR를 `ZONE_DEVICE` 페이지로 만들어 기존 bio·scatterlist 경로에 태운다. 이 페이지를 받아도 되는 경로는 `FOLL_PCI_P2PDMA`, `BLK_FEAT_PCI_P2PDMA` 같은 플래그로 opt-in 해야 한다(→ 08/02). dma-buf는 struct page 없이 메모리를 빌려주고 무효화(`move_notify`)를 지원한다. 그래서 장기 등록이 필요한 RDMA MR, devmem TCP, zcrx 쪽을 맡는다(→ 08/03). 두 계층은 경쟁이라기보다 분업이다. GDS도 둘 다 쓴다(`CUFILE_P2PDMA`, `CUFILE_DMABUF`). 블록 read/write의 dma-buf 경로는 7.3-rc7 기준 메인라인에 없다. LSFMM+BPF 2026(2026-05)에서 논의됐고 아직 병합되지 않았다(→ 08/03).

GDS의 목표는 공식 문서 첫 문단에 있다.

> "GPUDirect® Storage (GDS) enables a direct data path for direct memory access (DMA) transfers between GPU memory and storage, which avoids a bounce buffer through the CPU."
>
> — NVIDIA, [GPUDirect Storage Overview Guide](https://docs.nvidia.com/gpudirect-storage/overview-guide/index.html) 1.1 Introduction (2026-10-15 확인, 08/01 문서)

해설: 이 정의에는 "CPU가 I/O를 발행하지 않는다"는 말이 없다. cuFile API는 모두 CPU에서 호출된다. 제어 경로까지 GPU로 옮긴 것은 연구 프로토타입 BaM(ASPLOS '23)이다. BaM은 그 대가로 커널 NVMe 드라이버를 unbind해야 한다(→ 08/03).

### 3.4 in-tree와 out-of-tree

out-of-tree 구성요소는 커널 API가 바뀔 때마다 비용을 치른다. OpenZFS는 CDDL 라이선스라 GPL-only 심볼을 쓸 수 없다. Linux 5.0에서 `__kernel_fpu_begin()` export가 사라졌을 때 SIMD 가속이 한동안 막혔다. 지금은 `HAVE_KERNEL_FPU_INTERNAL` 같은 configure 매크로로 차이를 흡수한다(→ 10/02). `nvidia-fs.ko`도 NVMe·FS 드라이버마다 NVIDIA 패치가 필요했다. CUDA 12.8부터는 로컬 NVMe 경로를 upstream P2PDMA로 옮기는 중이다(→ 08/01). Lustre는 이 비용을 가장 오래 치른 사례다. 클라이언트는 Linux 3.11에서 staging에 들어갔다가 4.18 머지 윈도우에서 통째로 삭제됐다(커밋 `be65f9ed267f`). 2025년 LSFMM+BPF에서 클라이언트 upstream 재진입 계획이 다시 제시됐고, 2.17 태그부터 커널 호환 코드를 `lustre_compat/`로 분리하기 시작했다. 서버는 ldiskfs(ext4 패치)나 OpenZFS에 묶여 있어 upstream 대상이 아니다(→ 10/04). 거버넌스도 바뀌었다. SPDK는 2024-12 Intel 발표에 따라 Linux Foundation으로 옮겨 갔고 v25.05가 이전 후 첫 릴리스다. DAOS는 2023-11 DAOS Foundation(LF) 출범 때 Intel이 소스 코드를 재단에 기증하기로 했고(LF 보도자료 원문 "Intel Corporation will donate the DAOS source code"), 지금 저장소 README는 "DAOS is a Linux Foundation project."라고 적는다. DPDK는 2017-04 LF로 이관됐다(→ 07/01, 10/01, 04/04). 커널 바깥의 사용자 공간 스택들이 단일 벤더에서 재단 체제로 옮겨 가는 흐름이다.

## 4. Implementation Impact

### 4.1 계층 지도: 프로젝트별 위치와 성질

| 프로젝트 | 층 | 장치 큐 소유 | 완료 모델 | 장치 공유 | 최소 요구 / 도입 | 근거 |
|---|---|---|---|---|---|---|
| io_uring (+liburing) | 커널 인터페이스 | 커널 | CQ 링, IRQ 또는 IOPOLL, SQPOLL 선택 | 일반 파일 권한 | Linux 5.1 | 01/01, 09/06 |
| libaio (native AIO) | 커널 인터페이스 | 커널 | `io_getevents` 또는 aio ring | 일반 | 2.6, `O_DIRECT` 전제 | 01/01 |
| blk-mq | 커널 블록 계층 | 커널 | IRQ affinity, poll queue | 일반 | 3.13, 5.0부터 유일 경로 | 02/01, 02/03 |
| NVMe 드라이버 (pci, tcp, rdma, multipath) | 커널 드라이버 | 커널 | IRQ 배치 / `nvme_poll` | 일반 | native multipath 4.15, nvme-tcp 5.0 | 03/01, 03/03 |
| NVMe 패스스루 (`/dev/ngXnY`) | 커널, 계층 일부 생략 | 커널(blk-mq 태그 유지) | CQE, IOPOLL | 파일 권한, 6.2+ 비특권 | 5.13 / 5.19 | 03/02 |
| ublk | 커널 드라이버 + 사용자 서버 | 커널 blk-mq, 로직은 서버 | `uring_cmd` CQE | `/dev/ublkbN`로 공유 | 6.0, 제로카피 6.15 | 09/05 |
| zoned / ZNS / zonefs | 커널 장치 모델·FS | 커널 | 일반 | 일반 | 4.10, NVMe ZNS 5.9, zone write plugging 6.10 | 09/01 |
| FDP write stream | 커널 블록·io_uring | 커널 | 일반 | 일반 | 6.16, f2fs 7.2 | 09/02 |
| PCI P2PDMA | 커널 PCI/DMA | 커널 | 해당 없음(메모리 계층) | 일반 | 4.20, 사용자 공간 6.2 | 08/02 |
| nvme-cli / libnvme | 관리 평면 | 커널(admin 패스스루) | ioctl / `uring_cmd` | root, 6.2+ 일부 비특권 | nvme-cli 3.0 (2026-09) | 09/03 |
| VFIO / iommufd / vfio-user | 장치 위임 | 게스트 또는 사용자 프로세스 | 장치별 | IOMMU 그룹 독점 | iommufd 6.2, cdev 6.6, QEMU vfio-user 7.1/10.1 | 09/04 |
| DPDK | 사용자 공간 네트워크 | 사용자(PMD) | 폴링, Rx 인터럽트 옵션 | 포트 독점(bifurcated 예외) | LF 이관 2017-04 | 04/04 |
| AF_XDP / XDP | 커널 내 fast path | 커널 드라이버, 일부 큐만 XSK | NAPI + busy poll | 큐 단위 공유 | XDP 4.8, AF_XDP 4.18 | 04/01 |
| SPDK | 사용자 공간 스토리지 | 사용자(qpair 직접) | CQ 폴링, v25.05+ PCIe interrupt | 같은 `shm_id` 그룹만 | v1.0.0 2015-12 태그, LF 이관 2025 | 07/01~03 |
| xNVMe | 사용자 공간 추상화 | 백엔드에 따라 커널 또는 사용자 | 백엔드별 | 백엔드별 | SPDK xnvme bdev v22.09 | 09/06, 07/02 |
| GDS / cuFile | 사용자 API + 커널 경로 | 커널(NVFS 또는 P2PDMA) | CPU가 발행, 내부 스레드 풀 | 커널 보장 | GDS 1.0 (2021), P2PDMA 모드 GDS 1.13 / CUDA 12.8 | 08/01 |
| BaM | GPU-initiated | GPU 스레드(`libnvm`) | GPU 폴링 | 장치 독점 | 연구(ASPLOS '23) | 08/03 |
| Ceph (RGW/RADOS/BlueStore) | 분산 스토리지 | 커널(`KernelDevice`), 선택적으로 SPDK | libaio 기본, io_uring 선택 | 일반 | BlueStore 기본 Luminous v12 | 06/01~04 |
| DAOS | 분산 스토리지 | 사용자(SPDK) | SPDK 폴링, Argobots ULT | 엔진이 독점 | MD-on-SSD v2.6 production | 10/01 |
| OpenZFS | 커널 FS(out-of-tree) | 커널 블록 장치 위 vdev | ZIO 파이프라인 + vdev 큐 9클래스 | 일반 | Direct I/O 2.3.0 (2025-01, PR #10018은 2024-09-14 머지) | 10/02 |
| RocksDB | 임베디드 KV 엔진 | `FileSystem`/`Env` 구현에 위임 | 동기 + `MultiRead`/`ReadAsync`(io_uring) | 구현별 | `FileSystem` 6.7.0 (2020-01) | 10/03 |
| VFS + iomap (Direct I/O) | 커널 FS 공용 엔진 | 커널(bio → blk-mq) | `->end_io`, 동기 또는 `-EIOCBQUEUED` | 일반 | `fs/iomap.c` 4.8, `iomap_dio_rw()` 4.10, `iomap_iter()` 5.15, 레거시 DIO는 6.3부터 `CONFIG_LEGACY_DIRECT_IO` | 11/01 |
| 페이지 캐시 (folio, writeback) | 커널 mm·FS | 커널(flusher `wb_workfn()`) | 버퍼드: writeback 비동기 | 일반 | folio 5.16, LBS 6.12, `writeback_iter()` 6.9, `RWF_DONTCACHE` 6.14(실효 6.16) | 11/02 |
| FUSE / FUSE-over-io_uring | 커널 FS + 사용자 서버 | 커널 VFS, 로직은 서버 | `/dev/fuse` read/write 또는 `uring_cmd` CQE | 이름 공간 공유(서버 구현) | FUSE 2.6.14, passthrough 6.9, io_uring 6.14(기본 꺼짐), 제로카피 7.3-rc | 11/03 |
| virtiofs | 게스트 FS(FUSE 프로토콜) | 게스트 커널 → virtqueue → 호스트 `virtiofsd` | virtqueue 완료 | VM 경계 | 5.4, DAX 5.10, 다중 virtqueue 6.10 | 11/03 |
| IOMMU / dma-iommu | 커널 DMA 계층 | 해당 없음(주소 변환 계층) | 해당 없음 | 장치 격리 단위 | rcache 4.7, `DMA_FQ` 5.15, x86 기본 lazy, 2단계 IOVA API 6.16 | 12/01, 08/02 |
| md / dm (dm-crypt, dm-integrity) | 커널 bio 기반 가상 블록 장치 | 커널(맨 아래 물리 장치의 blk-mq만) | 하위 bio 완료 → 상위 `bi_end_io` | 일반 | dm-crypt 2.6.4, raid5 PPL 4.12, `md-llbitmap` 6.18(실험적), dm-inlinecrypt 7.2 | 13/01 |
| blk-crypto (인라인 암호화) | 커널 블록 계층 | 커널(장치 키슬롯) | 일반 | 일반 | 5.8, 하드웨어 래핑 키 6.15 | 13/01 |
| RDMA (`ib_core` + rdma-core) | 커널 제어 경로 + 사용자/커널 데이터 경로 | 사용자 provider(QP 직접 게시) 또는 커널 ULP | CQ 폴링 또는 완료 이벤트(`ib_poll_context`) | PD·lkey/rkey 격리 | ioctl uAPI 4.14, ODP 3.19, dma-buf MR 5.12, dma-buf export 7.0 | 13/02 |
| CXL (Type 3 메모리) | 커널 메모리 장치·mm | 해당 없음(load/store 메모리) | 해당 없음 | NUMA 노드 | `cxl_mem` 5.12, region 6.0, 휘발성 region 6.3, DCD 미병합 | 13/03 |
| Lustre | 병렬 FS(커널 모듈, out-of-tree) | 커널(클라이언트 `osc` RPC, 서버 OSD는 ldiskfs/ZFS) | ptlrpc RPC, LNet LND(o2ib는 RDMA) | POSIX 공유 이름 공간, LDLM | PFL 2.10, DoM 2.11, GDS 2.15, Hybrid IO 2.17 | 10/04 |
| managed IRQ + blk-mq 큐 맵 | 커널 IRQ·블록 계층 | 커널 | IRQ(CPU 고정) 또는 poll queue | 일반 | `PCI_IRQ_AFFINITY` 4.8, `HCTX_TYPE_*`·`poll_queues` 5.0, `isolcpus=managed_irq` 5.6 | 12/02 |

### 4.2 상호 연결: 누가 누구 위에 서 있는가

```
                         ┌──────────── 애플리케이션 / 스토리지 시스템 ────────────┐
   RocksDB ── FileSystem/Env ──┬─ PosixFileSystem → VFS (ext4/XFS) → blk-mq
                               ├─ BlueRocksEnv → BlueFS ─┐  (Ceph BlueStore 메타데이터)
                               └─ ZenFS (FileSystemWrapper) → libzbd → zoned 블록 장치 (ZNS/SMR)
   Ceph BlueStore ── KernelDevice ── libaio | io_uring(bdev_ioring) → blk-mq → nvme
                 └── NVMEDevice (HAVE_SPDK) ──────────────┐
   Ceph Crimson ── Seastar reactor (io_uring|linux-aio|epoll) → blk-mq   (tech preview)
   DAOS engine ── BIO → SPDK blobstore ────────────────────┤
   OpenZFS ── ZIO → vdev_disk → submit_bio → blk-mq        │
   GDS/cuFile ── nvidia-fs.ko 콜백 | upstream P2PDMA(FOLL_PCI_P2PDMA) → blk-mq → nvme
                                                           ▼
   SPDK ── lib/env_dpdk ── DPDK EAL(hugepage, vfio-pci, rte_ring, rte_mempool, lcore)
     ├─ bdev: nvme(사용자 공간 드라이버) | aio | uring | xnvme(io_uring_cmd …) | rbd | daos
     └─ 프런트엔드: nvmf target(TCP/RDMA) | vhost-user | vfio-user | ublk target(커널 ublk_drv)
   xNVMe ── be: linux(io_uring, io_uring_cmd, libaio) | spdk | libvfn | 기타 OS
   ublk ── 커널 ublk_drv(blk-mq) ⇄ io_uring IORING_OP_URING_CMD ⇄ 서버(ublksrv, rublk, SPDK)
   FUSE ── VFS → fuse_req ⇄ /dev/fuse | io_uring URING_CMD(6.14) ⇄ 서버(libfuse) ; passthrough → 백킹 파일
   virtiofs ── 게스트 FUSE → virtqueue(hiprio + requests.N) ⇄ 호스트 virtiofsd (+DAX 창)
   ext4/XFS/btrfs ── 버퍼드: 페이지 캐시(folio) → writeback ─┐
                  └─ O_DIRECT: iomap_dio_rw() ─────────────────┴→ submit_bio → blk-mq
   Lustre client ── llite → lov → osc → ptlrpc → LNet ─ o2iblnd(verbs) | socklnd(TCP) | kfilnd | efalnd
   Lustre server ── ofd → osd-ldiskfs(ext4 패치) | osd-zfs(OpenZFS DMU) → blk-mq
   md / dm ── submit_bio → (raid·crypt·integrity 처리) → submit_bio_noacct → 하위 blk-mq
   RDMA ULP ── nvme-rdma / nvmet-rdma / NFS·RDMA / iSER → ib_core ⇄ HCA ; 사용자: rdma-core provider → MMIO doorbell
   CXL Type 3 ── cxl_region → dax_cxl → device-dax → kmem → CPU 없는 NUMA 노드 (memory-tiers)
   ── 공통 하부: dma-iommu(IOVA rcache, flush queue) │ managed IRQ ↔ blk-mq 큐 맵 │ NIC RSS/RPS/XPS
```

| 연결 | 의존 방향 | 무엇을 가져다 쓰는가 | 근거 |
|---|---|---|---|
| SPDK → DPDK | SPDK `env_dpdk`가 `rte_eal_init()` 호출 | hugepage 메모리, IOVA, `vfio-pci` PCI 접근, `rte_ring`·`rte_mempool`, lcore. NVMe-oF/TCP 데이터는 DPDK PMD가 아니라 커널 소켓(posix/uring sock) | 04/04 4.7, 07/01 |
| DAOS → SPDK | DAOS BIO가 SPDK blobstore와 I/O channel 사용 | target별 전용 I/O channel, NVMe 사용자 공간 드라이버. 문서상 "SPDK enables user-space I/O to NVMe devices" | 10/01, 07/03 |
| Ceph BlueFS → RocksDB Env | `BlueRocksEnv : rocksdb::EnvWrapper` | RocksDB SST/WAL을 BlueFS 파일로 저장. 레거시 Env 경로 | 10/03, 06/03 |
| ZenFS → zoned | `ZenFS : FileSystemWrapper` + libzbd | zone 단위 SST/WAL 배치. ZNS는 커널 5.9+ | 09/01, 10/03 |
| GDS → P2PDMA | cuFile `CUFILE_P2PDMA` 모드 | `FOLL_PCI_P2PDMA`(6.2), `nvidia-uvm`이 BAR1을 `pci_p2pdma_add_resource()`로 등록 | 08/01, 08/02 |
| GDS → dma-buf | `CUFILE_DMABUF` 모드 | 일부 분산 FS importer | 08/01, 08/03 |
| SPDK ↔ 커널 | ublk target, xnvme/uring bdev | 커널에 블록 장치 노출, 또는 커널 I/O 경로를 bdev로 사용 | 07/03 4.7~4.8 |
| ublk → io_uring | `UBLK_IO_FETCH_REQ` / `COMMIT_AND_FETCH_REQ` | 요청 전달이 곧 `uring_cmd` 완료. 6.15 고정 버퍼 제로카피 | 09/05 |
| zcrx, devmem → NIC | header/data split, flow steering, RSS | 페이로드를 호스트 메모리 / dma-buf로 직접 DMA | 04/02 |
| fio → 각 엔진 | `io_uring`(liburing 미사용), `io_uring_cmd`, `libaio`, `spdk`, `xnvme` | 같은 job으로 백엔드 비교 | 09/06 4.6 |
| FUSE-over-io_uring ↔ ublk | 같은 `uring_cmd` 프로토콜, 다른 요청 단위 | FUSE는 CPU별 큐에서 `REGISTER` → `COMMIT_AND_FETCH`, ublk는 hctx별 `FETCH_REQ` → `COMMIT_AND_FETCH_REQ`. 제로카피는 둘 다 `io_buffer_register_bvec()`(ublk 6.15, FUSE 7.3-rc, FUSE는 `CAP_SYS_ADMIN`·버퍼 풀 필요). FUSE는 파일 연산 단위라 메타데이터도 서버를 왕복하고, ublk는 블록 요청만 받아 그 위의 커널 FS가 메타데이터를 처리한다 | 11/03 4.8, 09/05 |
| RocksDB·OpenZFS·BlueStore ↔ iomap/페이지 캐시 | 누가 커널 FS의 캐시와 DIO 엔진을 쓰는가 | RocksDB `PosixFileSystem`은 ext4/XFS 위에서 페이지 캐시 또는 `O_DIRECT`(iomap DIO)를 탄다. BlueStore는 FS 없이 raw 블록 장치에 `O_DIRECT`로 쓰므로 iomap을 거치지 않는다(단 `bluefs_buffered_io`가 기본 `true`라 BlueFS 읽기와 SST 쓰기는 블록 장치 페이지 캐시를 거친다, synthesis/00 2.3절). OpenZFS는 iomap이 아닌 자체 DIO 구현(2.3)과 ARC를 쓴다 | 11/01, 11/02, 10/02, 10/03, 06/03 |
| 모든 커널 DMA 경로 → IOMMU | 스트리밍 DMA마다 dma-iommu | NVMe `nvme_map_data()` 같은 커널 드라이버의 스트리밍 DMA는 I/O마다 IOVA 할당·해제(lazy면 flush queue에서 묶어 무효화). NIC 수신 `page_pool`은 `PP_FLAG_DMA_MAP`으로 한 번 매핑해 재사용. io_uring 등록 버퍼는 pinning만 줄이고 DMA 매핑은 I/O마다 한다. IOMMU가 DMA 도메인이면 nvme-pci `max_hw_sectors`가 `dma_opt_mapping_size()`(4KiB 페이지에서 128KiB)로 잘린다(6.4) | 12/01 4.3·4.6 |
| SPDK·DPDK(VFIO) → IOMMU | iommufd/type1 UNMANAGED 도메인 | hugepage를 시작 시 1회 `IOMMU_IOAS_MAP`/`VFIO_IOMMU_MAP_DMA`로 고정 매핑. I/O마다 IOVA 비용 없음. 커널 경로와의 효율 차이 일부가 여기서 나온다는 판단은 정성적이다 `[추측/미확인: 정량 기여도]` | 12/01 4.6, 07/01, 09/04 |
| GDS·P2PDMA → IOMMU/ACS | 토폴로지 판정 | 스위치 내부 P2P는 `PCI_P2PDMA_MAP_BUS_ADDR`(IOMMU 미경유), 루트 컴플렉스 경유는 `THRU_HOST_BRIDGE`(IOMMU 매핑). NVIDIA는 IOMMU off 또는 `iommu=pt`, ACS off를 권한다. 둘 다 격리와 맞바꾸는 설정이다 | 08/01 3.2, 08/02, 12/01 |
| NVMe-oF·DAOS·Lustre·SPDK·Ceph → RDMA | 같은 verbs 추상, 다른 소비자 | 커널 nvme-rdma/nvmet-rdma(4.8)는 FRWR(`IB_WR_REG_MR`)로 I/O마다 MR을 등록하고, poll 큐는 `IB_POLL_DIRECT`를 쓴다. Lustre는 LNet `o2iblnd`(IB·RoCE·OPA verbs)로 bulk를 RDMA 전송한다. DAOS는 CaRT/Mercury가 libfabric·UCX 위에서 RDMA를 쓴다. SPDK nvmf target은 RDMA 전송을 가진다. Ceph AsyncMessenger에도 `async+rdma`가 있지만 옵션 설명상 experimental일 수 있고 기본은 TCP다 | 13/02, 03/03, 10/04 4.2·4.11, 10/01, 07/01, synthesis/00 1절 |
| RDMA ↔ dma-buf ↔ GDS | 장치 메모리 공유 | RDMA는 dma-buf importer(MR, 5.12)였고, 7.0에서 exporter(`UVERBS_OBJECT_DMABUF`)도 됐다. Lustre는 2.15(LU-14798)에서 `nvidia-fs`에 `lustre_v1_register_nvfs_dma_ops`를 등록해 GPU 페이지를 o2iblnd로 직접 RDMA한다 | 13/02, 08/03, 10/04 4.8, 08/01 |
| CXL 티어링 vs P2PDMA | 서로 다른 문제 | CXL Type 3 메모리는 System RAM이 되므로, NVMe가 그곳으로 DMA하는 것은 P2PDMA가 아니라 일반 호스트 메모리 DMA다. P2PDMA는 struct page를 가진 장치 BAR(`ZONE_DEVICE`) 사이의 직접 전송이다. CXL 3.0 HDM-DB 기반 장치 간 직접 접근은 미지원이다 | 13/03, 08/02 |
| md/dm → 상위 기능 전파 | `blk_stack_limits()`의 교집합 | 원자적 쓰기 한도와 crypto profile은 하위 장치 전부가 지원할 때만 위로 올라간다(원자적 쓰기는 `chunk_sectors`에 맞춰 다시 깎임). `max_write_streams`는 전파되지 않으므로 md/dm 위에서는 FDP write stream이 0이다 | 13/01 4.7, 09/02, 11/01 |
| Lustre vs DAOS vs Ceph | 같은 "분산 스토리지", 다른 배치·일관성 모델 | 데이터 배치: Lustre는 MDT의 레이아웃 EA에 OST 객체 목록 저장, DAOS는 객체 클래스 + 해시, Ceph는 CRUSH 계산(중앙 조회 없음). 일관성: LDLM extent/ibits lock / epoch·DTX / PG primary 직렬화(CephFS는 caps). 서버 데이터패스: 커널 모듈 + ldiskfs/ZFS / 사용자 공간 SPDK / 사용자 공간 OSD(BlueStore). 커널 의존: 클라이언트·서버 모두 out-of-tree / 거의 비의존 / 커널 클라이언트(`ceph.ko`, `rbd`)는 메인라인 | 10/04 4.11, 10/01, 06/03 |
| Lustre 서버 → ldiskfs / OpenZFS | OSD 계층(`dt_*_operations`) | OST·MDT 백엔드로 ext4 패치 세트 ldiskfs 또는 ZFS DMU(`osd-zfs`, 2.3부터)를 쓴다. 2.17.0 태그부터 `osd-wbcfs`도 있다 | 10/04 4.1, 10/02 |
| blk-mq ↔ managed IRQ ↔ io_uring IOPOLL | 같은 affinity 마스크 공유 | `blk_mq_map_hw_queues()`(6.14+)가 IRQ 마스크로 CPU→hctx 맵을 만든다. `poll_queues`는 IRQ 벡터 없이 `HCTX_TYPE_POLL`로 매핑되어 `REQ_POLLED`(io_uring IOPOLL)를 받는다 | 12/02 4.2, 02/01, 01/01 |

### 4.3 결정 매트릭스: 언제 무엇을 쓰는가

아래 표의 "권장"은 도메인 문서들이 정리한 트레이드오프를 요약한 것이다. 특정 워크로드에서의 우열을 보장하지 않는다.

| 요구 조건 | 1순위 | 대안 | 피할 것 / 이유 | 근거 |
|---|---|---|---|---|
| 범용 서버 앱, 파일시스템 필요, 장치 공유 | io_uring (+등록 버퍼·파일, 필요 시 IOPOLL) | libaio(`O_DIRECT` 전용 부하) | SPDK: 장치 독점, FS 없음 | 01/01, 09/06 |
| 원시 NVMe 명령(ZNS·FDP·벤더 명령)을 커널 권한 모델 안에서 비동기로 | NVMe 패스스루 (`/dev/ngXnY` + uring_cmd) | xNVMe(`io_uring_cmd` 백엔드) | ioctl 동기 패스스루: 비동기 불가 | 03/02, 09/06 |
| 코어당 IOPS 최대화, 전용 스토리지 어플라이언스, 장치 독점 허용 | SPDK (bdev + nvme) | 커널 패스스루 + SQPOLL/IOPOLL | 커널 경로: FAST '24 기준 코어당 효율 격차 남음 | 03/02, 07/01 |
| 이식 가능한 NVMe 코드, 여러 백엔드 비교 | xNVMe | fio `xnvme` 엔진으로 백엔드 교차 측정 | — | 09/06 |
| 사용자 공간에 블록 장치 로직(qcow2, 네트워크 스토리지, SPDK bdev)을 두고 커널에 `/dev/…` 노출 | ublk (6.15+ 제로카피, recovery 플래그) | NBD(원격 노출 필요 시), VDUSE | TCMU/FUSE: 전송 경로 비효율 | 09/05 |
| 원격 블록 장치 제공 | 커널 nvmet-tcp / nvmet-rdma | SPDK nvmf target (poll group, interrupt 모드로 CPU 완화) | — | 03/03, 07/03 |
| VM에 NVMe 성능 전달, 마이그레이션 필요 | virtio-blk + iothread(`iothread-vq-mapping`), vhost-user-blk | vfio-user(SPDK) | VFIO PF/VF 패스스루: NVMe 마이그레이션 표준 경로 없음 | 09/04 |
| 패킷 단위 고속 처리(드롭, LB) | XDP | DPDK(최대 성능), AF_XDP | 스토리지 TCP를 XDP로: TCP 상태 머신 없음 | 04/01 |
| 스토리지 TCP 복사 비용 절감 | 송신 `MSG_ZEROCOPY`(≥~10 KB) / io_uring `SEND_ZC`, 수신 io_uring zcrx | 디바이스 메모리 수신은 devmem TCP | 작은 메시지 제로카피: 손익 실측 필요 | 04/02 |
| 쓰기 증폭 감소(플래시 수명·지연) | FDP write stream(하위 호환) | ZNS + zonefs/ZenFS/btrfs zoned(호스트 GC 감수) | ZNS를 범용 FS에 그대로: active zone·GC 관리 부담 | 09/01, 09/02 |
| GPU 학습·분석 데이터 적재 | GDS P2PDMA 모드(CUDA 12.8+, 커널 6.2+) | GDS NVFS 모드(분산 FS 파트너) | compat 모드로 조용히 폴백: `gdscheck.py -p`로 확인 | 08/01 |
| 데이터 의존적 세밀 GPU 접근(그래프, GNN) | BaM(연구) | GDS batch API | 프로덕션 사용: 장치 독점, FS 없음 | 08/03 |
| 객체/블록/파일 통합 분산 스토리지, 범용 하드웨어 | Ceph (BlueStore, Classic OSD) | Crimson/SeaStore는 시험용 | Crimson을 프로덕션에: tech preview | 06/04 |
| HPC, 작은 비정렬 I/O, 사용자 공간 E2E | DAOS (MD-on-SSD) | Lustre(DoM으로 작은 파일 완화) | 커널 VFS 깊은 통합이 필요하면 부적합 | 10/01, 10/04 |
| HPC, 기존 POSIX 앱 무수정, 대규모 순차 I/O, 다중 fabric | Lustre (2.15 LTS 또는 2.17, PFL·DNE) | DAOS(`dfuse`/`libdfs` POSIX 에뮬레이션), CephFS | 공유 파일 동시 쓰기: LDLM extent lock 경합. 작은 파일 위주: MDT 부하. 커널 추종 비용(out-of-tree) | 10/04 4.11 |
| 저장 매체 암호화 | 인라인 암호화 하드웨어가 있으면 blk-crypto(fscrypt 또는 7.2 dm-inlinecrypt) | dm-crypt(NVMe에서는 `no_read_workqueue`/`no_write_workqueue` 검토) | dm-inlinecrypt + fscrypt: passthrough가 없어 이중 암호화 | 13/01 |
| 소프트웨어 RAID 위에서 쓰기 지연 | md + `bitmap_type=llbitmap`(6.18, 실험적) 검토 | 기존 비트맵, `none`(재동기화 비용 감수) | md/dm 위에서 FDP write stream·원자적 쓰기 기대: 전파 조건 확인 | 13/01 |
| 원격 스토리지 전송(패브릭 통제 가능) | RDMA(RoCEv2/IB) — nvme-rdma, NFS/RDMA, LNet o2ib | NVMe/TCP, devmem TCP·zcrx로 복사 절감 | 패브릭 통제 없이 RoCE: PFC 교착·pause storm 운영 비용 | 13/02, 03/03, 04/02 |
| RDMA 없는 환경에서 RDMA API 개발·시험 | `rdma_rxe`(Soft-RoCE, 4.8), `siw`(5.3) | — | 성능 장치로 사용: 개발·상호 운용성 도구일 뿐 | 13/02 |
| DRAM 용량 확장 | CXL Type 3 → `kmem` NUMA 노드 + memory-tiers 강등/승격, 가중 인터리브(6.9) | — | DCD·다중 호스트 공유 메모리 전제: 메인라인 미지원. "CXL SSD"를 커널 개념으로 기대: 없음 | 13/03 |
| 데이터 무결성(체크섬·자가 치유) 우선 로컬 FS | OpenZFS (2.3+ Direct I/O 선택) | XFS/ext4 + md | ARC와 페이지 캐시 이중 캐싱 주의 | 10/02 |
| 임베디드 KV, LSM | RocksDB (`FileSystem` 플러그인으로 백엔드 교체) | — | leveled compaction WA(>10) 무시: RateLimiter로 제어 | 10/03 |
| 한 번 읽고 버리는 대용량 버퍼드 I/O(백업, 스캔) | `RWF_DONTCACHE`(6.16+ XFS, 6.17+ ext4, 7.3-rc 블록 장치) | `O_DIRECT`(정렬은 `STATX_DIOALIGN`으로 확인) | btrfs: master에서 `FOP_DONTCACHE` 미지원. 사후 `POSIX_FADV_DONTNEED`: 캐시 오염 후 정리 | 11/02, 11/01 |
| 찢어지지 않는 쓰기(DB 페이지) | `RWF_ATOMIC` + `STATX_WRITE_ATOMIC`(ext4/XFS 6.13 단일 블록, XFS 6.16 다중 블록) | 앱 수준 double-write | btrfs: master 미지원 | 11/01 |
| 사용자 공간 파일시스템(이름 공간이 필요) | FUSE passthrough(데이터가 백킹 파일에 있을 때, `CAP_SYS_ADMIN`) | FUSE-over-io_uring(6.14+, 명시적으로 켜야 함), 블록 의미면 ublk + 커널 FS | passthrough + `FUSE_WRITEBACK_CACHE`: 함께 쓸 수 없음 | 11/03, 09/05 |
| VM 게스트에 호스트 디렉터리 공유 | virtiofs(+DAX로 게스트 캐시 복제 제거) | virtio-blk/vhost-user-blk(블록 의미일 때) | C 구현 virtiofsd: QEMU 8.0에서 제거, Rust `virtiofsd` 사용 | 11/03, 09/04 |
| 베어메탈 스토리지 서버의 IOMMU 모드 | 기본 lazy(`DMA-FQ`) 유지, 내부 성능 장치 그룹만 sysfs `type`을 identity로 | `iommu.passthrough=1`(보안 결정임을 문서화) | untrusted(외부 포트) 장치 튜닝: strict+bounce가 강제되어 바뀌지 않음. IOMMU 모드를 바꾸면 NVMe `max_hw_sectors_kb`도 바뀌므로 함께 기록 | 12/01 |
| 저지연 전용 코어(폴링, 격리) | nvme `poll_queues` + io_uring IOPOLL, `isolcpus=managed_irq` + `nohz_full` | `irqaffinity=`로 non-managed IRQ 이동 | managed IRQ의 `smp_affinity` 수동 변경: `-EPERM`. `isolcpus=io_queue`: 미병합 | 12/02 |
| 관측 | 커널: tracepoint/`tp_btf`, `fentry`. 사용자: uprobe/USDT. SPDK: `spdk_trace` | — | 바이패스 스택에 커널 도구 기대: 보이지 않음 | 05/02, 07/03 |

### 4.4 교차 프로젝트 버전 연표

| 시점 | 커널 경로 | 사용자 공간 경로 | 스토리지 시스템 |
|---|---|---|---|
| 2014-01 | Linux 3.13 blk-mq | — | — |
| 2015 | 3.19 RDMA ODP | SPDK 오픈소스 공개(`v1.0.0` 태그 2015-12-07) | — |
| 2016 | 4.7 IOVA rcache, 4.8 XDP·NVMe-oF(RDMA)·`fs/iomap.c`·`PCI_IRQ_AFFINITY`·`rdma_rxe` | SPDK v16.06 NVMf target | — |
| 2017 | 4.10 zoned 블록 장치·`iomap_dio_rw()`(XFS), 4.12 raid5 PPL·dm-integrity, 4.13 write hint·`RWF_NOWAIT`·managed IRQ hotplug shutdown, 4.14 `MSG_ZEROCOPY`·`RDMA_VERBS_IOCTL` | DPDK LF 이관(2017-04-03), SPDK blobstore(v17.03) | Ceph Luminous v12: BlueStore 기본, Lustre 2.10(2017-07) PFL·Multi-Rail |
| 2018 | 4.15 native NVMe multipath, 4.18 AF_XDP·Lustre 클라이언트 staging 삭제, 4.20 P2PDMA·`i_pages` xarray·`iommu.strict=` | — | Lustre 2.11(2018-04) DoM·FLR, 2.12(2018-12) LNet Health |
| 2019 | 5.0 레거시 블록 경로 삭제·nvme-tcp·`HCTX_TYPE_*`·nvme `poll_queues`, 5.1 io_uring, 5.4 virtiofs | SPDK v19.01 NVMe-oF TCP | Ceph Nautilus v14: Beast·msgr2 기본, Lustre 2.13(2019-11) PCC·overstriping |
| 2020 | 5.5 ext4 iomap DIO, 5.6 zonefs·`isolcpus=managed_irq`, 5.8 Zone Append·blk-crypto·RTRS/RNBD, 5.9 NVMe ZNS·dm-crypt 작업 큐 우회, 5.10 btrfs iomap DIO·virtiofs DAX | SPDK v20.10 interrupt 모드(실험) | RocksDB 6.7.0 `FileSystem`·MultiGet io_uring, OpenZFS 2.0 |
| 2021 | 5.12 `cxl_mem`·RDMA dma-buf MR, 5.13 `/dev/ngXnY`, 5.15 `iomap_iter()`·`IOMMU_DOMAIN_DMA_FQ` | GDS 1.0 파트너 지원 등장 | ZNS 논문(ATC '21), OpenZFS 2.1 dRAID, Lustre 2.14(2021-02) |
| 2022 | 5.16 `struct folio`(2022-01 릴리스), 5.17 XFS large folio·f2fs iomap DIO, 5.18 streams 제거, 5.19 `IORING_OP_URING_CMD`, 6.0 ublk·`SEND_ZC`, 6.1 `DEFER_TASKRUN`·`memory-tiers` | SPDK v22.09 xnvme bdev | Lustre 2.15.0(2022-06) LTS 계열·GDS 지원 |
| 2023 | 6.2 사용자 공간 P2PDMA·비특권 패스스루·iommufd, 6.3 `CONFIG_LEGACY_DIRECT_IO`·CXL 휘발성 region·`dax_cxl`, 6.4 nvme-pci `max_hw_sectors` IOMMU 제한, 6.6 iomap 블록 단위 dirty 추적 | SPDK v23.01 ublk target | DAOS v2.4 MD-on-SSD preview, DAOS Foundation(2023-11), OpenZFS 2.2 block cloning |
| 2024 | 6.9 write hint 복원·FUSE passthrough·`writeback_iter()`, 6.10 zone write plugging, 6.11 `RWF_ATOMIC`, 6.12 devmem TCP RX·LBS(최소 folio 차수)·dma-iommu 직접 호출 | SPDK v24.09 nvmf TCP interrupt, Intel SPDK LF 이전 발표(2024-12-05) | DAOS v2.6 MD-on-SSD production, Ceph Squid v19 Crimson tech preview, Lustre 2.16.0(2024-11-08) IPv6·`kfilnd` |
| 2025 | 6.14 FUSE-over-io_uring·`RWF_DONTCACHE`·`blk_mq_map_hw_queues()`, 6.15 io_uring zcrx·ublk 제로카피, 6.16 FDP write stream·2단계 IOVA API·dontcache 재활성화·ext4 large folio, 6.17 `blk_rq_dma_map_iter_*`, 6.15 blk-crypto 하드웨어 래핑 키, 6.18 `write_cache_pages()` 삭제·`dma_map_phys()`·`md-llbitmap` | SPDK v25.05(LF 첫 릴리스), GDS 1.13 / CUDA 12.8 P2PDMA 모드 | OpenZFS 2.3.0 Direct I/O(2025-01-14 릴리스), Ceph Tentacle v20 SeaStore tech preview(v20.2.0, 2025-11-18), OpenZFS 2.4.0(2025-12-18), Lustre 2.15.8 LTS(2025-12-02)·2.17.0(2025-12-29) Hybrid IO |
| 2026 | 7.0 `IORING_REGISTER_BPF_FILTER`·`IOMAP_DIO_BOUNCE`·RDMA dma-buf export, 7.1 io_uring BPF struct_ops 루프, 7.2 f2fs write stream·P2PDMA multipath/MD RAID·btrfs large folio 기본·dm-inlinecrypt·CXL `devm_cxl_probe_mem()`, 7.3-rc 패스스루 Set Features 차단·FUSE io_uring 제로카피·블록 장치 dontcache | SPDK v26.01 LTS / v26.09, nvme-cli 3.0(2026-09-07), GDS 1.19 | DAOS v2.8(2026-08-12), RocksDB 11.5.0 compaction direct read |

근거: 01/01, 01/04, 02/01, 03/02, 03/03, 04/01, 04/02, 04/04, 07/01, 07/03, 08/01, 08/02, 09/01, 09/02, 09/03, 09/05, 10/01, 10/02, 10/03, 06/04, 11/01, 11/02, 11/03, 12/01, 12/02, 13/01, 13/02, 13/03, 10/04. 커널 버전을 연도에 배치할 때는 릴리스 연도를 기준으로 했다(예: 5.16은 2022-01 릴리스). Tentacle v20.2.0의 날짜(2025-11-18)는 docs.ceph.com 릴리스 타임라인에서 확인했다. GDS 1.13의 정확한 릴리스 날짜는 확인하지 못해 연도만 적었다 `[추측/미확인: 월 단위 날짜]`.

### 4.5 공유 메커니즘 비교: "같은 문제, 다른 답"

| 문제 | 커널 답 | 사용자 공간 답 | 스토리지 시스템의 선택 |
|---|---|---|---|
| 요청당 syscall | SQ/CQ 링, SQPOLL, 등록 링 fd(5.18) | syscall 없음(MMIO doorbell 직접) | Ceph: libaio 배치 `io_submit`. DAOS: SPDK |
| 완료 통지 | managed IRQ(제출 CPU = 완료 CPU), IOPOLL, poll queue, `HYBRID_IOPOLL`(6.13) | CQ phase 폴링, interrupt 모드(eventfd) | OpenZFS: 블록 완료 콜백 → ZIO 파이프라인 |
| 동시성 | per-CPU ctx, hctx, `sbitmap` 태그, `SINGLE_ISSUER` | 스레드 ↔ qpair 1:1, 메시지 전달(`spdk_thread_send_msg`) | DAOS: target별 xstream. Crimson: 코어당 reactor. Classic Ceph: 샤드 워커 + mutex |
| DMA 메모리 | DMA API, IOMMU(I/O마다 IOVA: per-CPU rcache 4.7, lazy flush queue), `dma_iova_*`(6.16) | hugepage pin + `spdk_mem_map` / DPDK memseg, VFIO로 시작 시 1회 IOMMU 매핑 | GDS: P2PDMA 페이지 또는 shadow buffer, IOMMU off/pt 권장 |
| 데이터 캐시 | 페이지 캐시(folio, large folio), `RWF_DONTCACHE`, `O_DIRECT`로 우회 | 캐시 없음(앱이 직접 관리) | BlueStore: 자체 캐시 + raw 블록 `O_DIRECT`. OpenZFS: ARC. FUSE: FUSE inode 페이지 캐시(`FUSE_WRITEBACK_CACHE` 선택) |
| 쓰기 배치·수명 | write stream(6.16), zone write plugging(6.10) | 앱이 직접 명령 구성(패스스루·SPDK) | ZenFS: zone 배치. DAOS VEA: I/O stream hint |
| 관측 | tracepoint, BPF, blktrace, iostat | `spdk_trace`, `spdk_top`, USDT | Ceph: LTTng-UST, OpenTelemetry |

### 4.6 열린 문제

- **커널과 바이패스의 코어당 효율 격차**: FAST '24 이후 커널 쪽 개선(6.8의 패스스루 wbt/blk-cgroup 생략 등)이 격차를 얼마나 줄였는지 보여 주는 새 공개 측정은 확인하지 못했다 `[추측/미확인]`.
- **블록 read/write의 dma-buf 경로**: io_uring dma-buf read/write 시리즈가 LSFMM+BPF 2026(2026-05)에서 논의됐고 7.3-rc7 기준 미병합이다(→ 08/03). 병합 시점과 GDS가 이를 채택할지 여부는 `[추측/미확인]`.
- **GPU-initiated I/O의 커널 모델**: NVMe 쪽 큐별 격리 같은 하드웨어 지원이 먼저라는 것이 LSFMM 2025 논의의 요지였다. 표준화 경로는 `[추측/미확인]`.
- **FDP의 범용 FS 통합**: XFS·ext4·btrfs iomap 경로는 아직 연결되지 않았다. 희소 stream 자원을 누가 배분하는가라는 2017년의 질문도 남아 있다(→ 09/02).
- **Crimson/SeaStore의 성숙**: 프로덕션 전환 시점, 그리고 패스스루·FDP 활용 여부 `[추측/미확인]`(→ 06/04, synthesis/00 4.7절).
- **NVMe-TCP 수신 DDP 오프로드**: 2025-07 v30까지 제출됐지만 7.3-rc7 기준 미병합이다(→ 03/03).
- **NVMe VF 라이브 마이그레이션**: 메인라인에 NVMe variant driver가 없다(→ 09/04).
- **SPDK interrupt 모드 문서 공백**: v26.09 CHANGELOG는 nvme 라이브러리에 RDMA initiator 쪽 interrupt 모드를 추가했다고 적지만, Interrupt Mode 문서 표는 2026-10-15 확인 시점에도 "NVMe bdev (fabrics)"를 No(TCP, RDMA는 `-ENOTSUP`)로 적는다. 문서가 뒤처진 것인지 bdev 계층이 아직 지원하지 않는 것인지는 `[추측/미확인]`(→ 07/01).
- **CPU 격리와 NVMe 큐**: `isolcpus=managed_irq`는 best-effort이고, 격리 CPU에 큐를 아예 만들지 않는 `isolcpus=io_queue` 시리즈는 일부 헬퍼(6.17)만 병합됐다. v7.3-rc7에 `HK_TYPE_IO_QUEUE`가 없다(→ 12/02).
- **블록 계층의 "미리 매핑된 버퍼"**: NIC 수신은 `page_pool`로 DMA 매핑을 재사용하지만, 블록 I/O는 io_uring 등록 버퍼를 써도 I/O마다 DMA 매핑을 한다(→ 12/01 4.6절). dma-buf read/write 시리즈(위 항목)가 이 공백을 메울지는 `[추측/미확인]`.
- **DIO 제로카피 전제의 후퇴**: 체크섬·stable write가 필요한 경로에서 사용자 버퍼 직접 DMA가 깨지는 문제로 btrfs는 6.15에 버퍼드 폴백, 7.3 개발 주기에 `IOMAP_DIO_BOUNCE`로 옮겼다. 다른 FS로 확대될지는 `[추측/미확인]`(→ 11/01).
- **FUSE-over-io_uring 기본값**: 커널 `enable_uring`과 libfuse 모두 기본 꺼짐이고, 제로카피 큐와 passthrough는 `CAP_SYS_ADMIN`을 요구한다. 비특권 컨테이너 환경에서 언제 기본 경로가 될지는 `[추측/미확인]`(→ 11/03).
- **CXL 패브릭 기능**: DCD(Dynamic Capacity Device), 다중 호스트 공유 메모리, Fabrics/G-FAM은 커널 `maturity-map.rst`에서 "Known gap"이다. DCD 시리즈는 2026-06 v11까지 올라왔지만 미병합이다. 승격 신호를 통합하려는 `pghot` 시리즈도 병합 전망이 불투명하다(→ 13/03).
- **md/dm 위의 FDP**: `max_write_streams`가 `blk_stack_limits()`로 전파되지 않아 스태킹 장치 위에서는 write stream이 사라진다. 전파 설계가 나올지는 `[추측/미확인]`(→ 13/01, 09/02).
- **Lustre 클라이언트 upstream 재진입과 EC**: 재진입 계획(2025 LSFMM+BPF)의 병합 시점, 그리고 master에 들어온 erasure coding 레이아웃(`LOV_PATTERN_PARITY`)이 포함될 릴리스는 `[추측/미확인]`(→ 10/04).
- **RDMA와 TCP의 수렴**: 두 진영이 모두 dma-buf로 장치 메모리를 다루게 됐다(RDMA dma-buf export 7.0, devmem TCP). 스토리지 백엔드 전송의 선택이 성능보다 운영 비용(PFC, 상호 운용성)으로 정해진다는 판단은 대규모 운영 보고에 근거한다. 일반 환경으로 일반화할 수 있는지는 `[추측/미확인]`(→ 13/02).
- **btrfs의 `RWF_DONTCACHE`와 원자 쓰기**: master 기준 둘 다 미지원이다(→ 11/01, 11/02).
- **ZenFS·libzbd 유지보수**: 마지막 push가 각각 2025-03, 2024-05다. 장기 유지 여부는 `[추측/미확인]`(→ 09/01).

## 5. Primary References

아래는 도메인 문서가 확인한 1차 사료 중 이 지도의 핵심 주장을 받치는 것들이다. 괄호 안은 해당 도메인 문서다.

- [usenix.org - I/O Passthru: Upstreaming a flexible and efficient I/O Path in Linux (FAST '24)](https://www.usenix.org/conference/fast24/presentation/joshi) — 패스스루·블록·SPDK 측정 (03/02, 09/06)
- [usenix.org - ZNS: Avoiding the Block Interface Tax for Flash-based SSDs (ATC '21)](https://www.usenix.org/conference/atc21/presentation/bjorling) (09/01)
- [lwn.net - Ringing in a new asynchronous I/O API](https://lwn.net/Articles/776703/) — io_uring 소개 (01/01)
- [lwn.net - Enable bio recycling for polled IO](https://lwn.net/Articles/866114/) — "3.5M+ IOPS per core" 측정 조건 (09/06)
- [lwn.net - Zone write plugging](https://lwn.net/Articles/968580/) (09/01)
- [lwn.net - An io_uring-based user-space block driver](https://lwn.net/Articles/903855/) — ublk (09/05)
- [lwn.net - Copy Offload with Peer-to-Peer PCI Memory](https://lwn.net/Articles/718593/) — P2PDMA RFC (08/02)
- [kernel.org - PCI Peer-to-Peer DMA Support](https://docs.kernel.org/driver-api/pci/p2pdma.html) (08/02)
- [kernel.org - Userspace block device driver (ublk driver)](https://docs.kernel.org/block/ublk.html) (09/05)
- [kernel.org - io_uring zero copy Rx](https://www.kernel.org/doc/html/latest/networking/iou-zcrx.html) (04/02)
- [kernel.org - Device Memory TCP](https://www.kernel.org/doc/html/latest/networking/devmem.html) (04/02)
- [spdk.io - What is SPDK](https://spdk.io/doc/about.html) — 세 가지 설계 원칙 (07/01)
- [spdk.io - Interrupt Mode](https://spdk.io/doc/interrupt_mode.html) (07/01)
- [spdk.io - Intel's SPDK Transition to the Linux Foundation](https://spdk.io/news/2024/12/05/LF/) (07/01)
- [doc.dpdk.org - Environment Abstraction Layer (EAL) Library](https://doc.dpdk.org/guides/prog_guide/env_abstraction_layer.html) (04/04)
- [github.com/spdk/spdk - module/bdev/xnvme/bdev_xnvme.c](https://github.com/spdk/spdk/blob/master/module/bdev/xnvme/bdev_xnvme.c) (03/02, 07/02)
- [xnvme.io - Material — xNVMe documentation](https://xnvme.io/material/index.html) (09/06)
- [docs.nvidia.com - GPUDirect Storage Overview Guide](https://docs.nvidia.com/gpudirect-storage/overview-guide/index.html) (08/01)
- [docs.nvidia.com - GPUDirect Storage Release Notes](https://docs.nvidia.com/gpudirect-storage/release-notes/index.html) (08/01)
- [docs.daos.io - Architecture - DAOS v2.8](https://docs.daos.io/latest/overview/architecture/) (10/01, 07/03)
- [github.com/daos-stack/daos - src/bio/README.md (Blob I/O)](https://github.com/daos-stack/daos/blob/master/src/bio/README.md) — SPDK blobstore 통합 (10/01)
- [github.com/openzfs/zfs - Direct IO Support (PR #10018)](https://github.com/openzfs/zfs/pull/10018) (10/02)
- [github.com/openzfs/zfs - module/zfs/vdev_queue.c](https://github.com/openzfs/zfs/blob/master/module/zfs/vdev_queue.c) (10/02)
- [github.com/facebook/rocksdb - include/rocksdb/file_system.h](https://github.com/facebook/rocksdb/blob/main/include/rocksdb/file_system.h) — `FileSystem`, `MultiRead`/`ReadAsync` (10/03)
- [github.com/facebook/rocksdb - HISTORY.md](https://github.com/facebook/rocksdb/blob/main/HISTORY.md) (10/03)
- [github.com/ublk-org/ublksrv - ublk: userspace block device driver](https://github.com/ublk-org/ublksrv) (09/05)
- [docs.ceph.com - Tentacle](https://docs.ceph.com/en/latest/releases/tentacle/) — SeaStore Tech Preview (06/04)
- [docs.ceph.com - BlueStore Configuration Reference](https://docs.ceph.com/en/latest/rados/configuration/bluestore-config-ref/) (06/03)
- [kernel.org - 1. Library Design — The Linux Kernel documentation](https://docs.kernel.org/filesystems/iomap/design.html) — iomap 설계 (11/01)
- [lwn.net - Filesystems and iomap](https://lwn.net/Articles/974958/) — 2024 LSFMM+BPF iomap 전환 현황 (11/01, 11/02)
- [github.com/torvalds/linux - mm: Introduce struct folio (commit 7b230db3b8d3)](https://github.com/torvalds/linux/commit/7b230db3b8d373219f88a3d25c8fbbf12cc7f233) — Linux 5.16 (11/02)
- [lwn.net - The return of RWF_UNCACHED](https://lwn.net/Articles/998783/) — `RWF_DONTCACHE` 재제안 (11/02)
- [kernel.org - FUSE-over-io-uring design documentation — The Linux Kernel documentation](https://docs.kernel.org/filesystems/fuse/fuse-io-uring.html) (11/03)
- [kernel.org - virtiofs: virtio-fs host<->guest shared file system — The Linux Kernel documentation](https://docs.kernel.org/filesystems/virtiofs.html) (11/03)
- [usenix.org - Utilizing the IOMMU Scalably (ATC '15)](https://www.usenix.org/conference/atc15/technical-session/presentation/peleg) — IOVA 할당·IOTLB 관리 병목과 magazine 캐시 (12/01)
- [github.com/torvalds/linux - nvme-pci: clamp max_hw_sectors based on DMA optimized limitation (commit 3710e2b056cb)](https://github.com/torvalds/linux/commit/3710e2b056cb) (12/01)
- [kernel.org - Affinity managed interrupts](https://docs.kernel.org/core-api/irq/managed_irq.html) (12/02)
- [kernel.org - Inline Encryption](https://docs.kernel.org/block/inline-encryption.html) — blk-crypto 설계 (13/01)
- [github.com/torvalds/linux - md/md-llbitmap: introduce new lockless bitmap](https://github.com/torvalds/linux/commit/5ab829f1971dc99f2aac10846c378e67fc875abc) — Linux 6.18 (13/01)
- [github.com/linux-rdma/rdma-core - RDMA core userspace libraries and daemons](https://github.com/linux-rdma/rdma-core) — libibverbs, librdmacm, provider (13/02)
- [github.com/torvalds/linux - IB/core: Add new ioctl interface](https://github.com/torvalds/linux/commit/fac9658cabb98afb68ef1630c558864e6f559c07) — Linux 4.14 `RDMA_VERBS_IOCTL` (13/02)
- [kernel.org - Compute Express Link Subsystem Maturity Map](https://docs.kernel.org/driver-api/cxl/maturity-map.html) — DCD·공유 메모리 "Known gap" (13/03)
- [github.com/torvalds/linux - mm/demotion: add support for explicit memory tiers](https://github.com/torvalds/linux/commit/992bf77591cb7e696fcc59aa7e64d1200b673513) — Linux 6.1 `memory-tiers` (13/03)
- [wiki.lustre.org - Lustre Release Information](https://wiki.lustre.org/Lustre_Release_Information) — Current LTS 2.15.8, Current Major 2.17.0 (10/04)
- [lwn.net - Getting Lustre upstream](https://lwn.net/Articles/1025268/) — LSFMM+BPF 2025 클라이언트 upstream 계획 (10/04)
- [jira.whamcloud.com - [LU-14798] NVIDIA GPUDirect Storage Support](https://jira.whamcloud.com/browse/LU-14798) — Lustre 2.15.0 GDS (10/04)
- [kernel.org - Scaling in the Linux Networking Stack](https://docs.kernel.org/networking/scaling.html) — RSS/RPS/RFS/XPS (12/02)
