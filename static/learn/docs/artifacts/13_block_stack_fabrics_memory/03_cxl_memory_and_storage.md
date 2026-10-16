# CXL 메모리와 스토리지: 프로토콜·장치 유형, 리눅스 CXL 서브시스템, 메모리 티어링, DAX, 그리고 CXL SSD 주장

> 기준: Linux `torvalds/linux` master(7.3-rc7, 2026-10 확인)의 `drivers/cxl/{acpi.c,pci.c,mem.c,port.c,pmem.c,cxl.h,cxlmem.h}`, `drivers/cxl/core/{region.c,hdm.c,cdat.c,mbox.c,memdev.c,features.c,edac.c,atl.c,region_dax.c,region_pmem.c}`, `include/cxl/cxl.h`, `drivers/dax/{cxl.c,kmem.c,fsdev.c,hmem/hmem.c}`, `mm/{memory-tiers.c,mempolicy.c}`, `include/linux/memory-tiers.h`, `Documentation/driver-api/cxl/{maturity-map.rst,linux/memory-hotplug.rst}`, `drivers/net/ethernet/sfc/efx_cxl.c`. 사용자 공간 도구는 `pmem/ndctl` v85(2026-06-29)의 `cxl-cli`/`daxctl`. 기능 도입 버전은 파일·심볼을 처음 추가한 커밋이 처음 포함된 커널 릴리스다. 사양은 CXL 컨소시엄 공개 페이지(현행 CXL 4.0) 기준이며, 사양 본문 절 번호는 패치 커버 레터의 인용을 따른다. PCI P2PDMA는 (→ 08/02), dma-buf와 GPU 메모리는 (→ 08/03), IOMMU는 (→ 12/01), RDMA 스택은 (→ 13/02), Optane PMem 이후 DAOS의 메타데이터 경로는 (→ 10/01)을 참조한다.

## 1. Verdict

**기준 버전: Linux 7.3-rc7 master, ndctl v85.**

CXL(Compute Express Link)은 PCIe 물리 계층 위에서 세 프로토콜을 다중화한다. CXL.io(PCIe와 같은 열거·구성·DMA), CXL.cache(장치가 호스트 메모리를 일관성 있게 캐시), CXL.mem(호스트가 장치 메모리를 load/store로 접근)이다. 장치 유형은 조합으로 나뉜다. Type 1은 .io+.cache(메모리 없는 가속기·SmartNIC), Type 2는 .io+.cache+.mem(자체 메모리를 가진 가속기), Type 3은 .io+.mem(메모리 확장기)이다. 리눅스 커널의 `enum cxl_devtype`은 이를 `CXL_DEVTYPE_DEVMEM`(Type 2, HDM-D/HDM-DB)과 `CXL_DEVTYPE_CLASSMEM`(Type 3, HDM-H, 표준 메일박스 필수)으로 구분한다. 결론은 다섯 가지다.

1. **리눅스 CXL 지원의 실체는 "Type 3 메모리 확장기를 NUMA 노드로 만드는 것"이다.** `cxl_acpi`가 ACPI CEDT의 CFMWS로 루트 디코더(호스트 물리 주소 창)를 만든다. `cxl_pci`가 클래스 코드로 메모리 장치를 찾고, `cxl_port`/`cxl_mem`이 스위치·엔드포인트 HDM 디코더를 열거한다. `cxl_region`이 여러 장치를 인터리브해 하나의 HPA 범위를 만든다. 그 범위는 `dax_cxl` → device-dax → `kmem`을 거쳐 CPU 없는 NUMA 노드의 System RAM이 된다. 5.12(`cxl_mem`, Dan Williams)에서 시작해 6.0 영속 영역(region), 6.3 휘발성 영역 생성·BIOS 영역 자동 조립·DAX 연결로 실용 단계에 왔다.
2. **"CXL 메모리를 어떻게 쓸지"는 CXL 서브시스템이 아니라 mm이 결정한다.** 성능 정보(CDAT, HMAT)는 `memory-tiers`의 abstract distance로 바뀐다. 이 값이 강등(demotion, 5.15)과 승격(promotion: NUMA balancing 티어링 모드 5.18, DAMON `DAMOS_MIGRATE_HOT` 6.11) 경로를 정한다. 대역폭 정보는 가중 인터리브(`MPOL_WEIGHTED_INTERLEAVE` 6.9, HMAT/CDAT 기반 자동 가중치 6.16)를 정한다. 승격 신호가 약하다는 문제는 2026년에도 미해결이다. 하드웨어 접근 추적을 통합하려는 `pghot` 시리즈는 Matthew Wilcox의 반대와 리뷰 부재로 병합 전망이 불투명하다(LWN, 2026-09-03).
3. **CXL 2.0/3.x의 "패브릭" 기능은 대부분 메인라인에 없다.** 커널 문서 `maturity-map.rst`는 DCD(Dynamic Capacity Device), 다중 호스트 공유 메모리(하드웨어/소프트웨어 일관성 모두), Fabrics/G-FAM, Switch CCI를 `[0] Known gap`으로 표시한다. 7.3-rc7 소스에도 DCD 파티션 모드는 없다(`enum cxl_partition_mode`는 `CXL_PARTMODE_RAM`, `CXL_PARTMODE_PMEM` 두 개뿐). DCD 시리즈는 Anisa Su(Samsung)가 2026-06-25에 v11까지 올렸다. 사용 사례(in-kernel 사용자) 문제가 오래 병합을 막았다. 단일 계층 CXL 2.0 스위치는 `struct cxl_switch_decoder`로 열거된다(성숙도 `[2]`).
4. **Type 2(가속기) 지원은 7.1~7.3에 처음 생겼다.** Alejandro Lucero(AMD)의 시리즈가 내부 구조체를 `include/cxl/cxl.h`로 내보냈다(7.1, `005869886d1d`). Dan Williams의 `devm_cxl_probe_mem()`이 7.2에 들어왔다. 첫 사용자인 sfc 드라이버(`drivers/net/ethernet/sfc/efx_cxl.c`, CXL 메모리를 TX PIO 버퍼로 사용)는 7.2-rc5 트리에는 없고 7.3-rc7 master에 있다. `maturity-map.rst`의 마지막 갱신은 2025-08이라 이 진전(그리고 6.16 EDAC scrub, 7.1 Soft Reserved 소유권 처리)을 아직 반영하지 않았다.
5. **"CXL SSD"와 "메모리 시맨틱 SSD"는 아직 커널 개념이 아니다.** 메인라인에는 플래시 기반 CXL 메모리 장치를 위한 별도 드라이버나 블록·메모리 하이브리드 계층이 없다. 그런 장치는 Type 3 메모리(HDM-H)로 보이거나 벤더 Type 2 드라이버가 필요하다. 수명·지연 주장은 벤더 발표가 대부분이다 [추측/미확인]. 동료 평가 연구(USENIX ATC '23 "Overcoming the Memory Wall with CXL-Enabled SSDs")는 캐싱·프리페치로 메모리 요청의 68–91%를 1µs 미만에 처리할 수 있다고 실제 애플리케이션 트레이스를 이용해 추정했다. 실제 장치 측정은 아니다. P2PDMA와의 관계도 정리해 둘 필요가 있다. CXL Type 3 메모리는 System RAM이 되므로, NVMe가 그곳으로 DMA하는 것은 P2PDMA가 아니라 일반 호스트 메모리 DMA다(→ 08/02). CXL.io BAR를 P2P 대상으로 쓰는 경로와 CXL 3.0 HDM-DB 기반 장치 간 직접 접근은 별개 문제이고 후자는 미지원이다.

| 커널 | 변화 | 의미 |
|---|---|---|
| 5.1 | device-dax `kmem` | DAX 장치를 System RAM으로 hotplug |
| 5.12 | `cxl_mem`(CXL 2.0 Type 3 엔드포인트) | 서브시스템 시작 |
| 5.14 | `cxl_acpi`, `cxl_pci` 분리, `cxl_pmem` | 포트 토폴로지와 nvdimm 연동 |
| 5.15 | 강등 경로(`demotion_enabled`) | 회수 대신 하위 티어로 이동 |
| 5.18 | HDM 디코더 열거(`core/hdm.c`), NUMA balancing 티어링 모드 | 디코더 모델, 승격 |
| 6.0 | `cxl_region`(영속 영역 생성) | 인터리브 집합 |
| 6.1 | `mm/memory-tiers.c` | 명시적 메모리 티어 |
| 6.3 | 휘발성 영역, 영역 자동 탐색(`CXL_REGION_F_AUTO`), `dax_cxl` | RAM 확장 실용화 |
| 6.4 / 6.5 | poison 주입, CXL PMU | RAS·관측 |
| 6.8 | CDAT 파싱(`core/cdat.c`) | 성능 좌표 → 티어 |
| 6.9 | 가중 인터리브 | 대역폭 비례 배치 |
| 6.11 | DAMON `DAMOS_MIGRATE_HOT`/`COLD` | 사용자 정책 승격/강등 |
| 6.15 | extended linear cache, Features 명령 | 메모리 측 캐시, fwctl |
| 6.16 | EDAC patrol scrub, 가중 인터리브 자동 조정 | RAS, 자동 가중치 |
| 7.0 | AMD Zen5 주소 변환(`core/atl.c`, ACPI PRMT) | 플랫폼 HPA 변환 |
| 7.1 | Type 2 내보내기 헤더, Soft Reserved 소유권 지연 결정, dax `fsdev` | 가속기, famfs 기반 |
| 7.2 / 7.3 | `devm_cxl_probe_mem()` / sfc의 CXL PIO | 첫 Type 2 사용자 |

---
## 2. Problem Statement

### 2.1 메모리 용량·대역폭의 벽과 좌초 메모리

서버 CPU의 코어 수는 빠르게 늘었지만 DDR 채널 수와 DIMM 슬롯은 그만큼 늘지 않았다. 코어당 메모리 대역폭과 용량이 상대적으로 줄어든다. 클라우드에서는 반대 방향의 낭비도 있다. VM 배치 단위로 메모리를 고정 할당하면 일부 서버에는 쓰이지 않는 메모리가 남는다. Microsoft의 ASPLOS '23 논문 "Pond: CXL-Based Memory Pooling Systems for Cloud Platforms"는 풀링으로 DRAM 활용률을 높이는 것을 목표로 삼았다. 초록에 따르면 운영 트레이스 분석에서 8–16 소켓 규모의 풀이면 이점 대부분을 얻었고, 158개 워크로드 평가에서 DRAM 비용을 7% 줄이면서 성능은 같은 NUMA 노드 할당 대비 1–5% 이내였다. CXL Type 3 장치는 PCIe 슬롯·케이블로 메모리를 더하고, 스위치나 다중 헤드 장치로 여러 호스트가 용량을 나누는 길을 연다.

### 2.2 load/store 메모리지만 "느린 메모리"

CXL.mem은 CPU의 캐시 라인 단위 load/store다. 그래서 응용 프로그램 변경 없이 쓸 수 있다. 하지만 지연은 로컬 DRAM보다 길고(장치 컨트롤러, 링크, 스위치를 지난다), 대역폭은 링크 폭에 묶인다. 정확한 지연 배수는 플랫폼과 장치에 따라 다르며, 특정 배수를 일반화할 1차 측정치는 제시하지 않는다 [추측/미확인]. 운영체제 입장에서 이 메모리는 "같은 페이지 할당기에 들어가지만 성능이 다른 노드"다. 이것이 티어링 문제의 출발점이다.

- **배치**: 새 할당을 어느 노드에 둘 것인가(기본 정책, 인터리브, 가중 인터리브).
- **이동**: 차가운 페이지를 언제 내리고(demotion), 뜨거운 페이지를 언제 올릴 것인가(promotion). 내리는 판단은 회수(reclaim)와 같은 LRU 신호로 할 수 있다. 올리는 판단에는 "느린 메모리에 있는 페이지가 지금 자주 접근된다"는 신호가 필요한데, 이 신호를 싸게 얻기 어렵다.
- **격리**: 먼저 뜬 워크로드가 빠른 메모리를 다 차지하는 문제.

### 2.3 펌웨어와 OS의 경계

CXL 메모리는 부팅 시 BIOS가 이미 디코더를 커밋하고 EFI 메모리 맵에 넣어 둘 수도 있고(`EFI_MEMORY_SP`, "Soft Reserved"), OS가 나중에 직접 구성할 수도 있다. 같은 주소 범위를 `dax_hmem`(펌웨어가 알려 준 Soft Reserved 범위를 DAX로 노출)과 `cxl_region`(CXL 토폴로지로부터 재구성)이 서로 소유하려 할 수 있다. 장치 hot-plug, 인터리브를 이루는 장치 하나의 고장, 포트별 HDM 디코더를 인스턴스 번호 순서대로 커밋·해제해야 하는 제약(`port->commit_end`, `hdm.c`의 "out of order commit" 검사) 같은 제약도 OS가 모두 지켜야 한다.

### 2.4 RAS: 장치 안의 메모리 컨트롤러

DIMM 오류는 전통적으로 CPU 메모리 컨트롤러와 플랫폼별 EDAC 드라이버가 다뤘다. CXL Type 3 장치는 메모리 컨트롤러를 장치 안에 가진다. 그래서 poison 목록, 이벤트 로그, patrol scrub, 주소 변환(DPA ↔ HPA, 인터리브와 XOR 해시 포함)이 CXL 메일박스와 커널 CXL 코어의 일이 된다. 2024년 LSFMM+BPF에서 Dan Williams는 EDAC가 메모리 컨트롤러 정보를 추상화하려고 생겼고 CXL은 그 추상의 표준화라고 설명했다(LWN 2024-05-22 요약).

### 2.5 스토리지와의 접점

스토리지 관점에서 CXL은 세 갈래로 등장한다. (a) 영속 메모리(CXL PMEM) 영역을 nvdimm 버스로 연결해 fsdax 파일 시스템으로 쓰는 경로. Optane DIMM이 사라진 뒤 PMem 소프트웨어 스택의 후계 후보다(→ 10/01). (b) 플래시를 백엔드로 두고 DRAM 캐시를 앞에 둔 "CXL SSD"·"메모리 시맨틱 SSD". (c) 스토리지 컨트롤러·DPU가 Type 2 장치로서 호스트와 일관성 있게 메모리를 공유하는 경로다. 셋 모두에서 "블록 I/O로 볼 것인가, 메모리로 볼 것인가"가 쟁점이다.

---
## 3. The Debate

### 3.1 CXL 메모리는 "그냥 NUMA 노드"인가

2022년 LSFMM에서는 CXL 세션이 다섯 개 열렸다. LWN의 첫 요약 기사(Jonathan Corbet, 2022-05-13)는 이를 "CXL may bring some welcome capabilities, especially for cloud-service providers, but that will come at the cost of some headaches on the kernel-development side"라고 정리했다. 기사에 따르면 쟁점은 두 가지였다. 하나는 CXL 메모리를 CPU 없는 NUMA 노드로 노출하고 기존 메커니즘(cgroup, mempolicy)으로 관리할지였다. 다른 하나는 hot-unplug와 ballooning이었다. Michal Hocko는 memory hotplug가 "mostly works"이지만 줄이는 쪽이 어렵고, 제거할 메모리는 movable 할당에만 쓸 수 있어 예전 highmem 시스템으로 돌아가는 셈이라고 지적했다. Dave Hansen은 비우려는 영역에 끝내 옮기지 못하는 페이지가 늘 몇 개 남는다고 답했다. 커널은 결국 "NUMA 노드 + 티어" 모델을 택했다. 그 근거는 기존 할당기·회수·migration 코드를 재사용할 수 있다는 점이었다. 별도 메모리 관리자는 만들지 않았다.

`ZONE_MOVABLE`과 `ZONE_NORMAL`의 선택은 지금도 운영자 몫으로 남아 있다. 7.3-rc7의 `Documentation/driver-api/cxl/linux/memory-hotplug.rst`는 트레이드오프를 이렇게 적는다.

> "`ZONE_MOVABLE` attempts to retain the hotplug-ability of a memory block so that it the entire region may be hot-unplugged at a later time. Any capacity onlined into `ZONE_NORMAL` should be considered permanently attached to the page allocator."
>
> — Linux 커널 문서, "Memory Hotplug" (CXL driver-api), 7.3-rc7 master ([docs.kernel.org](https://docs.kernel.org/driver-api/cxl/linux/memory-hotplug.html))

해설: `ZONE_MOVABLE`에는 커널 객체(slab, 페이지 테이블 등 이동 불가 할당)가 들어가지 않는다. 그래서 장치를 뺄 수 있고, 같은 이유로 DCD처럼 용량이 바뀌는 장치와도 맞는다. 대가는 두 가지다. 커널 할당이 로컬 DRAM에 몰리고, 거대한 CXL 풀의 `struct page` 메모리 맵 자체를 로컬 `ZONE_NORMAL`이 감당해야 한다. 같은 문서는 "Systems with extremely large amounts of `ZONE_MOVABLE` memory (e.g. CXL memory pools) must ensure that there is sufficient local `ZONE_NORMAL` capacity to host the memory map"이라고 경고한다. `ZONE_NORMAL`로 올리면 할당 유연성은 늘지만 해당 용량은 사실상 영구 부착이다.

### 3.2 승격 신호: 누가 "뜨거운 페이지"를 알려 주는가

강등은 비교적 쉽게 해결됐다. Dave Hansen의 "Migrate Pages in lieu of discard" 시리즈(v11, 5.15)는 회수 시 페이지를 버리는 대신 다음 티어로 옮긴다. 이 동작은 `/sys/kernel/mm/numa/demotion_enabled`로 켜며, 기본값은 `numa_demotion_enabled = false`다. 승격은 Huang Ying의 5.18 "NUMA balancing: optimize page placement for memory tiering system"이 기본 경로다. `kernel.numa_balancing=2`(`NUMA_BALANCING_MEMORY_TIERING`)에서 NUMA hint fault로 하위 티어 페이지의 접근을 감지해 상위 티어로 옮긴다. 속도는 `numa_balancing_promote_rate_limit_MBps`(기본 65536)로 제한한다. Meta의 TPP(ASPLOS '23, "Transparent Page Placement for CXL-Enabled Tiered-Memory")가 같은 문제 공간의 산업 측 근거다. 한계는 hint fault 자체의 비용과 신호의 거칠기다. DAMON `DAMOS_MIGRATE_HOT`/`DAMOS_MIGRATE_COLD`(6.11)는 영역 단위 샘플링으로 사용자가 정책을 정하게 하는 대안이다.

2024년 LSFMM+BPF에서 Dan Williams는 CXL 벤더에게 "a good promotion signal"이 없다는 점을 문제로 꼽았다(LWN 2024-05-22 요약). 하드웨어 접근 추적(CXL 장치의 hotness 보고, AMD IBS 등)을 모아 승격하려는 Bharata B Rao의 `pghot`(커널 스레드 `kmigrated`) 시리즈는 2026년 여덟 번째 판까지 왔다. LWN은 Matthew Wilcox의 반대를 원문으로 인용했다.

> "I don't think we should do this. I don't think it's a use-case that customers actually want; I think it's something CPU vendors think their customers want. I've said this repeatedly over the months this patchset has been in development. I say no."
>
> — Matthew Wilcox, LWN "Recent work in memory tiering"(Jonathan Corbet, 2026-09-03)에 인용된 메일 ([lwn.net/Articles/1092001](https://lwn.net/Articles/1092001/))

해설: 같은 기사에 따르면 Gregory Price(Meta)는 Meta가 "actively interested in this work"라고 반박했다. Andrew Morton은 이미 메인라인에 있는 DAMON으로 충분하지 않은지 물었다. David Hildenbrand는 여덟 번의 판 동안 리뷰 태그가 하나도 없다며 "far away from being mergeable"이라고 평가했다. 쟁점은 기술이 아니라 우선순위다. 티어드 메모리가 범용 서버의 문제인가, 일부 하이퍼스케일러와 CPU 벤더의 문제인가. 같은 기사는 티어별 memcg 한도(Joshua Hahn의 비례 한도, Qiqi Liu의 조정 가능 한도) 시리즈도 소개했다. Michal Hocko는 티어 단위 제어라는 목표 자체에 의문을 제기했다. 두 시리즈 모두 7.3-rc7에는 없다.

### 3.3 펌웨어 영역과 OS 영역: Soft Reserved 소유권

BIOS가 CXL 메모리를 이미 구성해 Soft Reserved로 넘기는 플랫폼에서는 `dax_hmem`과 `cxl_region`이 경쟁한다. 6.3의 영역 자동 탐색(`CXL_REGION_F_AUTO`, Dan Williams)은 BIOS가 커밋한 디코더를 읽어 같은 영역을 재구성한다. 그 결과 "누가 먼저 probe되느냐"에 따라 소유자가 바뀌는 문제가 남았다. 7.1의 `e4de6b910bf3`(Smita Koralahalli, AMD)는 이를 지연 결정으로 바꿨다. 커밋 메시지는 "dax_hmem probing is not always guaranteed to run after CXL enumeration and region assembly, which can lead to incorrect ownership decisions"라고 적는다. 이제 Soft Reserved 범위가 CXL 창과 겹치면 `wait_for_device_probe()` 후 범위별로 판단한다. CXL 영역이 범위를 완전히 포함하면 `dax_cxl`이, 아니면 `dax_hmem`이 갖는다(`hmem_register_cxl_device()`). 설계 선택은 "CXL 영역을 해체하지 않는다"였다. 범위 단위 소유와 `alloc_dax_region()`의 자원 배제로 이중 소유를 막는다. 펌웨어가 만든 구성을 OS가 존중하되, CXL 토폴로지 정보가 있으면 그쪽을 우선한다는 원칙이다.

### 3.4 DCD: in-kernel 사용자가 없는 기능을 받을 것인가

DCD(CXL 3.1 9.13.3절)는 장치 리셋이나 디코더·DAX 영역 재구성 없이 영역 안의 용량을 extent 단위로 더하거나 빼는 기능이다. 오케스트레이터와 Fabric Manager가 호스트에 메모리를 붙였다 떼는 풀링의 핵심이다. 시리즈는 Intel의 Ira Weiny가 v9(2025-04-13)까지 이끌었고, 2026년에는 Anisa Su(Samsung)가 이어받았다. v10 커버 레터는 병합을 막아 온 것이 코드가 아니라 사용 사례였다고 밝힌다.

> "The use case for DCD has been a long-time blocker for this series. In the previous months, we discussed moving forward with FAMFS as the first end-user for DCD."
>
> — Anisa Su, "[PATCH v10 00/31] DCD: Add support for Dynamic Capacity Devices (DCD)", 2026-05-23 ([lwn.net/Articles/1074139](https://lwn.net/Articles/1074139/))

해설: 커뮤니티 원칙은 "사용자 없는 커널 인터페이스는 받지 않는다"이다. 커버 레터는 CXL 회의에서 "DCD DAX 장치도 결국 DAX 장치이므로 사용자 공간 소비자로 충분하다"는 취지의 의견이 나왔다고 전한다. 예로 든 것은 LLM 추론용 KV 캐시 계층(LM Cache)의 DAX 백엔드다. LSFMM+BPF 2026 논의의 요구 사항도 정리돼 있다. 태그는 유일해야 하고, 같은 태그의 extent 묶음 하나가 DAX 장치 하나가 된다. 공유 extent는 시퀀스 번호로 조립한다. v11(2026-06-25)은 `dynamic_ram_a`를 `dynamic_ram_1`(`CXL_PARTMODE_DYNAMIC_RAM_1`)로 바꾸는 등 ABI 이름을 정리했다. 장치가 보낸 데이터를 신뢰하지 않는 검증도 강화했다. 대응하는 `cxl-cli` 변경도 ndctl에 별도로 올라와 있다. famfs의 기반인 dax `fsdev` 드라이버는 7.1에 먼저 들어왔다(`d5406bd458b0`, John Groves). 이 드라이버는 device-dax 인스턴스를 fsdax 호환 folio 상태로 바꿔 fs-dax 파일 시스템이 문자 DAX 장치 위에서 돌게 한다. famfs 파일 시스템 자체는 7.3-rc7에 없다.

### 3.5 CXL SSD와 "메모리 시맨틱 SSD": 메모리인가, 스토리지인가

"CXL SSD"라는 말은 서로 다른 세 설계를 묶어 부른다.

1. **플래시 백엔드 Type 3 메모리**: 장치가 DRAM 캐시와 NAND를 갖고, 호스트에는 HDM-H 메모리로 보인다. 캐시 미스는 수십 µs 단위의 NAND 읽기가 된다. load 명령이 그동안 CPU를 멈춰 세운다는 것이 근본 문제다.
2. **이중 인터페이스 장치**: NVMe 블록 인터페이스(CXL.io)와 바이트 접근 창(CXL.mem)을 함께 노출한다. 벤더들이 "memory-semantic SSD", "CMM-H" 같은 이름으로 발표했다. 근거는 벤더 발표 자료뿐이고 1차 사양이나 커널 드라이버로 확인되는 제품 정의는 없다 [추측/미확인].
3. **연산·압축 메모리 장치**: 2024년 LSFMM+BPF에서 Yiannis Nikolakopoulos가 발표한 "densemem"처럼, 실제 설치량보다 큰 주소 공간을 내걸고 압축으로 채우는 장치다.

학술 쪽 근거는 신중하다. USENIX ATC '23의 "Overcoming the Memory Wall with CXL-Enabled SSDs"(Shao-Peng Yang 외)는 설계 공간 탐색 논문이다. 초록에 따르면 실제 애플리케이션 트레이스로 캐싱·프리페치를 적용하면 수명이 "at least 3.1 years"로 추정되고, 메모리 요청의 "68–91%"를 1µs 미만에 처리한다. 동시에 같은 초록은 기존 기법의 한계를 분석하고 DRAM 수준 성능을 위해 "system-level changes"가 필요하다고 적는다. 즉 나머지 9–32% 요청의 꼬리 지연이 해결 과제로 남는다.

커널 커뮤니티의 반응도 같은 방향이다. LWN의 2024년 요약에 따르면 Davidlohr Bueso는 압축이 이미 느린 기술에 지연을 더한다고 지적했다. David Hildenbrand는 densemem의 합리적 용도는 zswap뿐이라고 보았다. Matthew Wilcox는 PCI 버스는 메모리 접근이 아니라 스토리지용이라며, CXL 메모리를 swap 장치로 쓰는 것은 가능할 수 있다고 했다. Dan Williams는 densemem이 차가운 메모리용이며 디스크로 swap하는 것보다 낫다고 답했다. 이 논쟁은 플래시 기반 CXL 장치에도 그대로 적용된다. 커널이 가진 도구는 (a) 장치를 매우 낮은 티어(큰 abstract distance)의 NUMA 노드로 두고 강등 대상으로만 쓰거나, (b) devdax로 두고 사용자 공간이 명시적으로 쓰거나, (c) 블록 장치로 쓰는 것이다. 7.3-rc7에는 "CXL SSD" 전용 커널 계층이 없다. 미스 지연을 커널에 알려 스레드를 재스케줄하는 메커니즘도 없다.

### 3.6 Type 2: "가속기 드라이버가 CXL 코어를 라이브러리로 쓴다"

Type 2 지원은 오래 `maturity-map.rst`의 `[0]`이었다. 문제는 구조였다. 기존 CXL 코어는 `cxl_pci`가 표준 메일박스를 가진 Type 3 장치를 소유한다고 가정했다. 그러나 가속기는 자기 PCI 드라이버(예: 네트워크 드라이버)가 장치를 소유하고, 메일박스가 없을 수도 있다. Alejandro Lucero의 시리즈는 이 가정을 뒤집었다. 7.1에서 `include/cxl/cxl.h`로 `struct cxl_dev_state`, `enum cxl_devtype`, 레지스터 맵 구조체를 내보냈다. 커밋 설명은 "In preparation for type2 support, move structs and functions a type2 driver will need to access to into a new shared header file"이다. 7.2에는 Dan Williams의 `devm_cxl_probe_mem()`이 들어왔다. 이 함수는 BIOS가 커밋한 HDM에 연결된 CXL 범위를 안전하게 얻는다. 7.3 master의 `efx_cxl_init()` 흐름은 `devm_cxl_dev_state_create(..., CXL_DEVTYPE_DEVMEM, ...)` → `cxl_pci_setup_regs()` → 메일박스 없이 `cxl_set_capacity()`로 DPA 초기화 → `devm_cxl_probe_mem()`이다. 얻은 범위는 CTPIO 버퍼로 매핑된다. 커밋 설명은 "With CXL mem protocol this latency can be lowered further"라고 동기를 적었다. 이 첫 사용자가 CXL.cache를 쓰지 않는다는 점이 중요하다. 커널은 아직 CXL.cache(68B/256B) 관리를 하지 않는다(`maturity-map.rst` `[0]`). Type 2 지원은 "장치 메모리를 HDM으로 매핑"하는 데까지다.

---

## 4. Implementation Impact

### 4.1 드라이버와 객체 모델

CXL 서브시스템은 PCI 장치 하나를 드라이버 하나가 맡는 모델이 아니다. 별도의 `cxl` 버스 위에 포트·디코더·영역 객체를 두는 구조다.

- **`cxl_acpi`** (`drivers/cxl/acpi.c`): ACPI0017 장치를 루트로 삼는다. CEDT의 CHBS(호스트 브리지 컴포넌트 레지스터)와 CFMWS(CXL Fixed Memory Window)를 읽는다. CFMWS 하나가 `struct cxl_root_decoder` 하나가 된다. 창의 제약(`ACPI_CEDT_CFMWS_RESTRICT_DEVMEM`/`HOSTONLYMEM`/`VOLATILE`/`PMEM` 등)은 디코더 플래그가 되어 어떤 장치 유형과 영역 유형을 받을지 정한다. XOR 인터리브 창은 CXIMS 테이블(`struct cxl_cxims_data`)로 해시를 계산한다. 7.0에서는 AMD Zen5 플랫폼의 주소 변환을 ACPI PRMT로 위임하는 `core/atl.c`(Robert Richter)가 들어왔다.
- **`cxl_pci`** (`drivers/cxl/pci.c`): PCI 클래스 `PCI_CLASS_MEMORY_CXL`/`CXL_MEMORY_PROGIF`에 바인딩한다. DVSEC과 레지스터 로케이터로 컴포넌트·장치 레지스터를 매핑하고, 메일박스를 초기화하고, `struct cxl_memdev_state`를 채운 뒤 `cxl_memdev`(`/dev/cxl/memN`)를 등록한다.
- **`cxl_port`/`cxl_mem`**: `cxl_mem`이 memdev를 받아 루트까지의 포트 경로(`struct cxl_port`, `struct cxl_dport`)를 만든다. 각 포트의 HDM 디코더 능력을 `core/hdm.c`가 열거한다. 디코더는 세 종류다. `struct cxl_root_decoder`(플랫폼 창), `struct cxl_switch_decoder`(호스트 브리지·스위치 포트, 다운스트림 대상 목록), `struct cxl_endpoint_decoder`(장치 DPA → HPA)다. 모두 `struct cxl_decoder`를 품는다.
- **`cxl_region`** (`core/region.c`): 루트 디코더 아래의 HPA 범위와 엔드포인트 디코더 집합(`struct cxl_region_params`의 `targets[CXL_DECODER_MAX_INTERLEAVE]`, 최대 16)을 묶는다. 영역은 `cxl_pmem_region`(nvdimm 연결) 또는 `cxl_dax_region`(DAX 연결)으로 이어진다. 7.1에서 Gregory Price가 이 연결 코드를 `region_pmem.c`/`region_dax.c`로 분리했다.
- **성능 좌표**: `core/cdat.c`(6.8)는 장치와 스위치의 CDAT(DSMAS/DSLBIS/SSLBIS)를 읽는다. 이를 HMAT의 호스트 측 값과 합쳐 영역별 `struct access_coordinate`(`cxlr->coord[]`)를 만든다. `qos_class`가 루트 디코더와 맞지 않으면 `cxl create-region -Q`가 생성을 거부할 수 있다.

### 4.2 영역 생성 콜패스와 사용자 공간

OS가 직접 만드는 경우 sysfs 흐름은 다음과 같다. `cxl-cli`는 이 sysfs 조작을 감싼다.

1. 루트 디코더의 `create_ram_region`(또는 `create_pmem_region`)에 다음 영역 이름을 써서 `struct cxl_region`을 할당한다.
2. `interleave_ways`, `interleave_granularity`, `size`를 쓴다. 인터리브 방식 수는 `ways_to_eiw()`가 허용하는 1·2·4·8·16과 3·6·12다. 인터리브 단위는 `granularity_to_eig()`가 허용하는 256B(`CXL_DECODER_MIN_GRANULARITY`)~16KiB의 2의 거듭제곱이다. `size`가 루트 디코더 창에서 HPA를 할당한다.
3. 엔드포인트 디코더마다 DPA를 예약하고(`cxl reserve-dpa`에 해당) `target0..N`에 쓴다. `attach_target()` → `cxl_region_attach()`가 위치·유형·DPA 크기를 검증한다. 각 상위 포트에는 `cxl_port_attach_region()`이 `struct cxl_region_ref`를 만든다.
4. `cxl_region_setup_targets()` → 포트마다 `cxl_port_setup_targets()`가 스위치 디코더의 대상 목록과 인터리브 파라미터를 계산한다. 상위 레벨의 granularity·ways와 맞아야 하므로 실패의 대부분이 여기서 난다.
5. `commit`에 1을 쓰면 `cxl_region_decode_commit()`이 엔드포인트부터 루트 방향으로 `commit_decoder()`를 호출한다. 실패하면 `cxl_region_decode_reset()`으로 되돌린다.
6. `cxl_region_probe()`가 영역 유형에 따라 `cxl_dax_region` 또는 `cxl_pmem_region`을 만든다. RAM 영역이면 `register_mt_adistance_algorithm()`으로 `cxl_region_calculate_adistance()` 알림 핸들러(우선순위 100)를 등록한다. 이 핸들러는 영역의 `ACCESS_COORDINATE_CPU` 성능을 `mt_perf_to_adistance()`로 abstract distance로 바꾼다.

ndctl 문서의 예시 `cxl create-region -m -d decoder0.1 -w 2 -g 1024 mem0 mem1`은 2-way, 1KiB 단위 영역을 만든다. 출력의 `mappings`에서 `position`이 인터리브 순서다. BIOS가 이미 커밋한 경우 6.3의 자동 탐색이 `cxl_region_attach_auto()`와 `cxl_calc_interleave_pos()`로 위치를 역산한다. 결과 영역에는 `CXL_REGION_F_AUTO`가 붙고, 자동 탐색 밖의 엔드포인트 디코더는 추가할 수 없다. 펌웨어가 잠근(locked) 디코더가 하나라도 있으면 영역 전체에 `CXL_REGION_F_LOCK`이 붙는다("all or nothing"). 디코더 일부가 해체된 커밋 영역은 `CXL_REGION_F_NEEDS_RESET`으로 표시돼 완전히 해체될 때까지 `cxl_region_probe()`가 막힌다. AMD Zen5처럼 HPA와 SPA가 다른 플랫폼에는 `CXL_REGION_F_NORMALIZED_ADDRESSING`이 있다.

### 4.3 DAX 경로: devdax, system-ram, fsdax, fsdev

CXL 영역은 결국 DAX 계층으로 사용자에게 간다. RAM 영역과 PMEM 영역의 경로가 다르다.

- **RAM 영역 → `dax_cxl` → device-dax**: `cxl_dax_region`에 `drivers/dax/cxl.c`(6.3)가 바인딩해 `dax_region`과 `/dev/daxX.Y`를 만든다. 기본 모드는 **devdax**다. 응용 프로그램이 문자 장치를 `mmap()`해 페이지 캐시·할당기 없이 직접 쓴다. 정렬(2MiB/1GiB) 단위로 compound folio를 미리 만든다.
- **system-ram (kmem)**: `daxctl reconfigure-device --mode=system-ram`이 장치를 `kmem`(5.1, Dave Hansen)에 다시 바인딩한다. `kmem`은 `add_memory_driver_managed()`로 범위를 "System RAM (kmem)" 자원으로 hotplug한다. 온라인 정책(자동 온라인 여부, `ZONE_MOVABLE`/`ZONE_NORMAL`)은 memory hotplug 설정을 따른다(3.1절). `kmem`은 성능 정보가 없을 때 `MEMTIER_DEFAULT_DAX_ADISTANCE`(= `MEMTIER_ADISTANCE_DRAM * 5`)를 기본값으로 쓴다. 그러면 DRAM보다 아래 티어로 분류된다. CXL 영역이면 4.2절의 adistance 알림이 이 값을 성능 기반으로 바꾼다.
- **PMEM 영역 → `cxl_pmem` → nvdimm → fsdax**: `cxl_nvdimm_bridge`/`cxl_nvdimm`이 libnvdimm 버스를 만든다. 그 위에서 `pmem` 블록 장치와 fsdax(ext4/XFS `-o dax`)가 Optane 시절과 같은 경로로 동작한다. 레이블(LSA) 지원은 `maturity-map.rst`에서 `[1] PMEM labels`, GPF/dirty shutdown은 `[3]`이다.
- **fsdev (7.1)**: device-dax 인스턴스를 fsdax 호환 상태(order-0 folio, 일반 refcount)로 바꿔 fs-dax 파일 시스템이 문자 DAX 위에서 돌게 하는 드라이버다(`CONFIG_DEV_DAX_FSDEV`). 커밋 설명에 따르면 이 모드에서는 raw `mmap()`을 제공하지 않으며, raw mmap이 필요하면 devdax 모드로 돌아가야 한다. ndctl 문서는 `daxctl`에서 devdax 장치를 'famfs' 모드로 바꾸면 `fsdev_dax`에 바인딩된다고 설명한다. famfs 파일 시스템 본체는 메인라인 밖이다.

`dax_hmem`(`drivers/dax/hmem/hmem.c`)은 CXL과 무관하게 펌웨어가 Soft Reserved(EFI `EFI_MEMORY_SP`)로 표시한 범위를 DAX로 노출하는 경로다. CXL 창과 겹칠 때의 소유권 규칙은 3.3절과 같다.

| 사용 방식 | 커널 경로 | 페이지 캐시/할당기 | 장점 | 한계 |
|---|---|---|---|---|
| devdax | `dax_cxl` → `device_dax` | 우회(mmap 직접) | 예측 가능한 지연, hugepage 정렬 | 응용 프로그램 수정 필요, swap·migration 없음 |
| system-ram | `kmem` → memory hotplug | 일반 NUMA 노드 | 투명, 티어링·가중 인터리브 사용 | 승격 신호 약함, `ZONE_NORMAL`이면 제거 불가 |
| fsdax (PMEM) | `cxl_pmem` → libnvdimm → `pmem` | 파일 시스템 DAX | 파일 의미론, 영속성 | PMEM 장치 드묾, 장기 GUP 고정 불가(→ 13/02의 ODP) |
| fsdev (7.1) | `fsdev_dax` | fs-dax 호환 folio | 공유 메모리 FS의 기반 | raw mmap 없음, 사용자 FS(famfs) 미병합 |
| 블록 장치 | (전용 경로 없음) | — | — | CXL.mem 메모리를 블록으로 노출하는 메인라인 드라이버 없음 |

### 4.4 메모리 티어와 배치 정책 내부

`mm/memory-tiers.c`(6.1, Aneesh Kumar K.V)는 노드마다 `struct memory_dev_type`(abstract distance, adistance)를 붙인다. adistance를 `MEMTIER_CHUNK_SIZE`(2^`MEMTIER_CHUNK_BITS` = 128) 구간으로 나눠 `memory_tierN`을 만든다. DRAM 기준값은 `MEMTIER_ADISTANCE_DRAM` = 4×128 + 64 = 576이다. 기준 DRAM 성능은 `mt_set_default_dram_perf()`가 HMAT에서 처음 본 DRAM 노드 값으로 고정한다. 다른 DRAM 노드의 지연·대역폭 중 하나라도 그 값과 10%를 넘게 다르면 `pr_info`로 알리고 `default_dram_perf_error`를 세워 성능 기반 계산 전체를 끈다. 이후 `mt_perf_to_adistance()`는 `-EIO`를 돌려준다. `mt_perf_to_adistance()`의 식은 `adist = 576 × (대상 읽기+쓰기 지연 / DRAM 읽기+쓰기 지연) × (DRAM 읽기+쓰기 대역폭 / 대상 읽기+쓰기 대역폭)`이다. 지연이 DRAM의 2배이고 대역폭이 절반이면 adist는 4배(2304)가 되어 티어 18(2304 >> 7)에 들어간다. DRAM은 티어 4(576 >> 7)다. 티어가 바뀌면 `establish_demotion_targets()`가 노드별 강등 대상을 다시 만든다. 회수는 `next_demotion_node()`로 대상을 고르고, `node_is_toptier()`가 승격 대상 판단에 쓰인다. sysfs `/sys/devices/virtual/memory_tiering/`에서 티어 구성을 볼 수 있다.

가중 인터리브는 별도 축이다. `MPOL_WEIGHTED_INTERLEAVE`(6.9, Gregory Price 정책 + Rakie Kim sysfs)는 `/sys/kernel/mm/mempolicy/weighted_interleave/nodeN`의 정수 가중치로 페이지를 배분한다. 커널 내부는 `weighted_interleave_nodes()`/`weighted_interleave_nid()`다. 6.16의 Joshua Hahn "Weighted Interleave Auto-tuning"은 `auto` 파일을 추가했다. auto 모드에서는 부팅·hotplug 때 들어오는 대역폭 정보(HMAT, CXL CDAT)로 가중치를 다시 계산한다. 커밋 설명은 이전 기본 가중치가 모두 1이어서 대역폭을 무시하는 일반 인터리브와 같았다고 지적한다. 티어링(지연 기반, 뜨거운 페이지를 빠른 곳에)과 가중 인터리브(대역폭 기반, 대역폭 포화 시 분산)는 목표가 반대일 수 있다. 같은 워크로드에 둘을 함께 켤 때는 주의가 필요하다.

### 4.5 RAS와 관리 기능

- **이벤트·poison**: 메일박스 이벤트 로그는 `cxl_event_state`로 처리돼 tracepoint로 나간다. poison 목록 조회와 주입·해제(6.4, `cxl inject-media-poison`/`clear-media-poison`)가 있다. 6.18(Alison Schofield, `c3dd67681c70`)에는 영역 오프셋 기준 주입이 debugfs `/sys/kernel/debug/cxl/regionX/{inject_poison,clear_poison}`로 추가됐다. XOR 인터리브 영역에서도 DPA를 역산할 수 있게 한 것이 핵심이다.
- **주소 변환**: DPA ↔ HPA 변환은 영역의 인터리브 위치·granularity·XOR 맵으로 계산된다. 메모리 장애를 `memory_failure()`로 연결할 때 필요하다. extended linear cache(6.15, Dave Jiang)는 HMAT가 알려 주는 메모리 측 캐시가 있는 경우 같은 HPA가 두 위치에 대응하는 문제를 다룬다. MCE 알림에서 별칭 주소를 함께 내보낸다(`core/mce.c`).
- **Features와 EDAC**: 6.15에 Get Supported Features 명령(`core/features.c`)과 fwctl 연동이 들어왔다. 6.16에 Shiju Jose의 EDAC 연동(`core/edac.c`)이 patrol scrub 제어 등을 EDAC 사용자 인터페이스로 노출했다. `maturity-map.rst`의 "Scrub control [0]"은 이 변경 이전 상태다.
- **보안·펌웨어**: sanitize, 보안 명령, 펌웨어 업데이트(`devm_cxl_setup_fw_upload()`)는 성숙도 `[3]`이다.

### 4.6 CXL 2.0/3.x 기능별 리눅스 지원 상태 (7.3-rc7)

| 기능 | 사양 | 메인라인 상태 | 근거 |
|---|---|---|---|
| Type 3 휘발성 메모리 확장 | 2.0 | 지원 | `create_ram_region`, `dax_cxl`, `kmem` (6.3) |
| 인터리브(호스트 브리지·스위치 레벨) | 2.0 | 지원 | `cxl_port_setup_targets()`, 최대 16-way |
| 단일 계층 스위치 열거 | 2.0 | 지원(`[2]`) | `struct cxl_switch_decoder`, Switch CDAT `[3]` |
| PMEM 영역 + fsdax | 2.0 | 지원 | `cxl_pmem` → libnvdimm |
| LD hot-plug(풀링의 정적 형태) | 2.0 | 초기(`[1]`) | PCI hotplug 경유 |
| Switch CCI(스위치 관리 메일박스) | 2.0+ | 미지원(`[0]`) | `maturity-map.rst` |
| DCD(동적 용량) | 3.0/3.1 | 미지원, v11 리뷰 중 | `enum cxl_partition_mode`에 DC 모드 없음 |
| 다중 호스트 공유 메모리(HW/SW 일관성) | 3.0 | 미지원(`[0]`) | `maturity-map.rst` |
| 다단 스위칭·Fabrics/G-FAM·PBR | 3.0 | 미지원(`[0]`) | 관련 코드 없음 |
| Type 2 HDM 매핑 | 1.1/2.0 | 7.1–7.3에 초기 지원 | `include/cxl/cxl.h`, `devm_cxl_probe_mem()`, sfc |
| HDM-DB(Back-Invalidate)·CXL.cache | 3.0 | 미지원(`[0]`) | `maturity-map.rst` |
| TSP/IDE 보안 | 3.x | 커널 범위 밖(`[X]`) | `maturity-map.rst` |
| 128GT/s, bundled port 등 | 4.0 | 커널 영향 없음(링크 계층) [추측/미확인] | 컨소시엄 페이지 |

### 4.7 P2PDMA·dma-buf와의 관계

P2PDMA(→ 08/02)는 PCIe BAR를 `ZONE_DEVICE` 페이지로 만들어 장치 간 DMA를 허용하는 서브시스템이다. CXL과의 관계는 세 경우로 나뉜다.

1. **CXL Type 3 메모리를 System RAM으로 쓴 경우**: 이 메모리는 일반 NUMA 노드 페이지다. NVMe나 RDMA NIC이 그곳으로 DMA하는 것은 루트 컴플렉스를 지나는 일반 DMA다. P2PDMA 판정(`calc_map_type_and_dist()`)이나 `FOLL_PCI_P2PDMA`가 필요 없다. 같은 이유로 GPU 없이 "CXL 메모리 ↔ NVMe" 경로를 만드는 데 새 커널 API가 필요 없다. 다만 성능은 CXL 링크 대역폭을 DMA와 CPU가 나눠 쓰는 구조에 좌우된다.
2. **devdax로 둔 경우**: 사용자 공간이 mmap한 devdax 페이지도 struct page가 있는 `ZONE_DEVICE`(`drivers/dax/device.c`의 `MEMORY_DEVICE_GENERIC`) 메모리다. fsdev는 `MEMORY_DEVICE_FS_DAX`를 쓴다. 이를 `O_DIRECT` 버퍼로 쓰는 것은 일반 GUP 경로다. RDMA MR로 장기 고정할 때의 제약은 (→ 13/02, 3.2절)과 같다.
3. **Type 2 장치 메모리·CXL.io BAR를 다른 장치가 직접 접근하는 경우**: 이것이 진짜 P2P 문제다. CXL.io BAR는 기존 P2PDMA 규칙을 따른다. HDM-D/HDM-DB 장치 메모리에 다른 장치가 일관성 있게 직접 접근하는 CXL 3.0 경로는 메인라인에 없다. RDMA·GPU 쪽의 dma-buf export(→ 08/03, 13/02)처럼 "장치 메모리를 fd로 내보내는" 모델이 Type 2 메모리에 적용될지는 아직 정해지지 않았다 [추측/미확인].

### 4.8 운영 지침

- **먼저 토폴로지를 본다.** `cxl list -M -D -R -v`로 memdev, 디코더, 영역의 위치·인터리브를 확인한다. `numactl -H`와 `/sys/devices/virtual/memory_tiering/`로 노드·티어 배치를 확인한다. HMAT/CDAT가 빠진 플랫폼에서는 CXL 노드가 `kmem` 기본 adistance(DRAM×5)로 분류된다. 정상 동작이지만 성능 기반 분류는 아니다.
- **온라인 존을 의도적으로 고른다.** 제거·DCD 가능성이 있으면 `ZONE_MOVABLE`, 커널 할당까지 받아야 하면 `ZONE_NORMAL`이다. 대용량 movable 풀은 로컬 DRAM의 memmap 비용을 계산해야 한다.
- **티어링은 기본으로 꺼져 있다.** `demotion_enabled`는 기본 false, `numa_balancing`은 `CONFIG_NUMA_BALANCING_DEFAULT_ENABLED`에 따라 기본 0 또는 1(일반 모드)이다. 티어링은 `numa_balancing=2`와 `demotion_enabled=true`를 명시적으로 켜야 하고, 승격 속도 한도를 워크로드에 맞춰야 한다.
- **대역폭 워크로드는 가중 인터리브.** `weighted_interleave/auto`가 true면 커널이 HMAT/CDAT 대역폭으로 가중치를 정한다. 응용 프로그램은 `set_mempolicy(MPOL_WEIGHTED_INTERLEAVE, ...)` 또는 `numactl --weighted-interleave=<nodes>`(numactl man page에 있는 옵션)로 opt-in한다.
- **벤더 "CXL SSD" 수치는 조건을 확인한다.** 캐시 적중률·워킹셋 크기·쓰기 비율이 빠진 지연 수치는 비교 근거가 아니다(3.5절).

| 비교 축 | 레거시(Optane DIMM / NUMA 원격 소켓) | CXL Type 3 (7.3-rc7) |
|---|---|---|
| 열거 | ACPI NFIT(PMEM), SRAT/SLIT | CEDT(CFMWS/CHBS) + PCI DVSEC + HDM 디코더 |
| 인터리브 구성 | BIOS 고정 | BIOS 커밋 + OS 재구성(`cxl_region`, sysfs/`cxl-cli`) |
| 성능 정보 | SLIT 거리, HMAT | HMAT + CDAT → `access_coordinate` → adistance |
| 사용자 노출 | libnvdimm(pmem, fsdax, devdax) | `dax_cxl`(devdax/system-ram), `cxl_pmem`(fsdax), `fsdev` |
| 티어 결정 | 노드 거리 | `memory-tiers` adistance, CXL 알림 우선순위 100 |
| RAS | 플랫폼 EDAC/MCE | CXL 메일박스 이벤트·poison, EDAC 연동(6.16), DPA↔HPA 변환 |
| 동적 용량·공유 | 없음 | 사양에는 있으나(DCD, 공유) 메인라인 미지원 |

---

## 5. Primary References

- [Compute Express Link Subsystem Maturity Map](https://docs.kernel.org/driver-api/cxl/maturity-map.html) — 커널 CXL 기능별 성숙도(DCD·공유·Type 2·Switch CCI `[0]` 등). 마지막 갱신 2025-08
- [Compute Express Link Driver Theory of Operation](https://docs.kernel.org/driver-api/cxl/theory-of-operation.html) — 포트·디코더·영역 객체 모델
- [Memory Hotplug](https://docs.kernel.org/driver-api/cxl/linux/memory-hotplug.html) — CXL 메모리의 `ZONE_NORMAL`/`ZONE_MOVABLE` 온라인 트레이드오프
- [NUMA Memory Policy](https://docs.kernel.org/admin-guide/mm/numa_memory_policy.html) — `MPOL_WEIGHTED_INTERLEAVE` 등 메모리 정책
- [cxl/mem: Introduce a driver for CXL-2.0-Type-3 endpoints](https://github.com/torvalds/linux/commit/4cdadfd5e0a70017fec735b7b6d7f2f731842dc6) — Dan Williams, v5.12. 서브시스템 시작
- [cxl/region: Add volatile region creation support](https://github.com/torvalds/linux/commit/6e099264185d05f50400ea494f5029264a4fe995) — Dan Williams, v6.3. RAM 영역
- [dax/hmem, cxl: Defer and resolve Soft Reserved ownership](https://github.com/torvalds/linux/commit/e4de6b910bf3645c224cd873d4e03ce3dd81fbe0) — Smita Koralahalli, v7.1. 펌웨어/OS 영역 소유권
- [cxl: export internal structs for external Type2 drivers](https://github.com/torvalds/linux/commit/005869886d1d370afb6c10cd40709d956960e9c2) — Alejandro Lucero, v7.1. Type 2 지원 기반
- [dax: add fsdev.c driver for fs-dax on character dax](https://github.com/torvalds/linux/commit/d5406bd458b0ac10b1301a4d5801d85c8f648637) — John Groves, v7.1. famfs 기반 dax 드라이버
- [mm/demotion: add support for explicit memory tiers](https://github.com/torvalds/linux/commit/992bf77591cb7e696fcc59aa7e64d1200b673513) — Aneesh Kumar K.V, v6.1. `memory-tiers`
- [NUMA balancing: optimize page placement for memory tiering system](https://github.com/torvalds/linux/commit/c574bbe917036c8968b984c82c7b13194fe5ce98) — Huang Ying, v5.18. 티어링 모드 승격
- [mm/mempolicy: Weighted Interleave Auto-tuning](https://github.com/torvalds/linux/commit/e341f9c3c8412e57fe0042a33a2640245ecdf619) — Joshua Hahn, v6.16. 대역폭 기반 자동 가중치
- [DCD: Add support for Dynamic Capacity Devices (DCD)](https://lwn.net/Articles/1074139/) — Anisa Su, v10 커버 레터, 2026-05-23 (LWN 패치 미러)
- [DCD: Add support for Dynamic Capacity Devices (DCD)](https://lwn.net/Articles/1079575/) — Anisa Su, v11 커버 레터, 2026-06-25 (LWN 패치 미러)
- [CXL 1: Management and tiering](https://lwn.net/Articles/894598/) — Jonathan Corbet, LWN, 2022-05-13. LSFMM 2022 CXL 세션
- [Two sessions on CXL memory](https://lwn.net/Articles/974518/) — Jonathan Corbet, LWN, 2024-05-22. RAS·densemem 논쟁
- [Recent work in memory tiering](https://lwn.net/Articles/1092001/) — Jonathan Corbet, LWN, 2026-09-03. pghot, 티어별 memcg
- [pmem/ndctl](https://github.com/pmem/ndctl) — `cxl-cli`, `daxctl` 공식 저장소
- [ndctl/Documentation/cxl/cxl-create-region.txt](https://github.com/pmem/ndctl/blob/main/Documentation/cxl/cxl-create-region.txt) — 영역 생성 옵션과 예시
- [About CXL®](https://computeexpresslink.org/about-cxl/) — CXL 컨소시엄. CXL 4.0 주요 기능
- [Overcoming the Memory Wall with CXL-Enabled SSDs](https://www.usenix.org/conference/atc23/presentation/yang-shao-peng) — Yang 외, USENIX ATC '23. 플래시 기반 CXL 장치 설계 공간
- [Pond: CXL-Based Memory Pooling Systems for Cloud Platforms](https://dl.acm.org/doi/10.1145/3575693.3578835) — Li 외, ASPLOS '23. 클라우드 메모리 풀링
- [TPP: Transparent Page Placement for CXL-Enabled Tiered-Memory](https://dl.acm.org/doi/10.1145/3582016.3582063) — Maruf 외, ASPLOS '23. 티어드 메모리 페이지 배치
