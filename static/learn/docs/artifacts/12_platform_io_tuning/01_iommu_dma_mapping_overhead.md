# IOMMU와 DMA 매핑 오버헤드: dma-iommu, IOVA 할당기, strict/lazy 무효화, swiotlb, ATS, iommufd

> 기준: Linux `master`(v7.3-rc7). 함수·구조체·상수 이름은 로컬 트리(v7.2-rc5+76, 커밋 `11028ab62899e`)의 `drivers/iommu/dma-iommu.c`, `drivers/iommu/iova.c`, `drivers/iommu/iommu.c`, `drivers/iommu/Kconfig`, `kernel/dma/{mapping,swiotlb}.c`, `drivers/pci/{ats,probe}.c`, `block/blk-mq-dma.c`, `drivers/nvme/host/pci.c`에서 grep으로 확인했다. `dma-iommu.c`의 핵심 상수와 함수는 git.kernel.org의 master(v7.3-rc7)에서 다시 대조했다. 도입 버전은 `git log -S`/`--grep`으로 찾은 커밋에 `git describe --contains`를 적용해 고정했다.

## 1. Verdict

IOMMU를 켠 시스템에서 I/O 한 건은 "DMA 주소를 얻는 비용"을 두 번 낸다. 제출할 때 IOVA를 할당하고 페이지 테이블을 쓰는 비용, 완료할 때 페이지 테이블을 지우고 **IOTLB를 무효화**하고 IOVA를 반납하는 비용이다. 하드웨어 주소 변환(IOTLB hit) 자체는 거의 공짜에 가깝다. 비싼 것은 **소프트웨어 관리 경로**다. 이 문서의 결론은 다음과 같다.

1. **성능 차이의 대부분은 "translate냐 identity냐"보다 "무효화를 언제 하느냐"와 "IOVA를 어디서 꺼내느냐"에서 나온다.** Peleg 등(USENIX ATC '15)은 Linux 3.17.2에서 identity 매핑은 무시할 만한 오버헤드만 내지만, 동적 매핑은 당시 최적화(EiovaR)를 적용한 Linux조차 16코어에서 No-IOMMU 처리량의 23%에 그친다고 측정했다(netperf TCP_RR 270개 동시 요청, 10GbE). per-CPU IOVA 캐시(magazine)를 넣으면 93%까지 회복했다. 이 설계가 Linux 4.7의 `iova_rcache`(커밋 `9257b4a206fc`, Omer Peleg)로 들어왔다.
2. **x86 기본값은 이미 "lazy"다.** `CONFIG_IOMMU_DEFAULT_DMA_LAZY`가 X86/S390 기본이고, 그 결과 기본 도메인 타입은 `IOMMU_DOMAIN_DMA_FQ`가 된다. unmap은 per-CPU flush queue(`IOVA_DEFAULT_FQ_SIZE`=256 항목, `IOVA_DEFAULT_FQ_TIMEOUT`=10ms)에 쌓였다가 한 번의 `flush_iotlb_all`로 정리된다. 대가로 unmap 뒤 최대 수 ms 동안 장치가 그 IOVA로 계속 접근할 수 있다. `iommu.strict=1`은 이 창을 닫지만 unmap마다 동기 무효화를 한다.
3. **신뢰할 수 없는 장치는 설정과 무관하게 strict + bounce다.** `pci_dev->untrusted`(외부 노출 포트 아래 장치, Thunderbolt 등)인 장치는 `IOMMU_DOMAIN_DMA`로 강제된다. 페이지보다 작은 버퍼는 swiotlb로 bounce된다(`dev_use_swiotlb()`). ATS도 꺼진다(`pci_ats_supported()`). 이 경로는 사용자가 튜닝할 수 없는 보안 경계다.
4. **NVMe에서 IOVA 캐시의 크기 한계가 직접 큐 한계로 내려온다.** rcache는 2^5 = 32페이지(4KiB 페이지에서 128KiB) 이하 크기만 캐시한다. 이보다 큰 매핑은 전역 `iova_rbtree_lock` 아래 RB 트리로 간다. 448코어 AMD 서버에서 이 락 경합이 soft/hard lockup을 냈고, 6.4-rc3의 `3710e2b056cb` "nvme-pci: clamp max_hw_sectors based on DMA optimized limitation"이 `dma_opt_mapping_size()`로 `max_hw_sectors`를 잘랐다. IOMMU를 켜면 NVMe의 `max_hw_sectors_kb`가 128로 보이는 이유가 이것이다.
5. **API 쪽 방향은 "매핑을 덜 자주, 더 크게"다.** 6.12에서 dma-iommu가 `dma_map_ops` 간접 호출 대신 직접 호출로 바뀌었다(`b5c58b2fdc42`, `use_dma_iommu()`). 6.16의 2단계 API(`dma_iova_try_alloc`/`dma_iova_link`/`dma_iova_sync`)는 요청 하나에 IOVA 한 덩어리와 IOTLB 동기화 한 번만 쓴다. 6.17에서는 `blk_rq_dma_map_iter_start()`와 nvme-pci가 이 API를 쓴다(→ 08/02). 6.18에서는 `dma_map_phys()`로 struct page 없는 물리 주소 매핑이 표준이 됐다.
6. **"IOMMU를 끄면 빠르다"는 운영 결정은 보안 결정이다.** `iommu.passthrough=1`(identity)은 IOTLB miss와 관리 비용을 모두 없앤다. 대신 장치(그리고 장치 펌웨어)를 커널 메모리 전체에 노출한다. 실무의 타협점은 "기본 lazy 유지, 성능이 필요한 내부 장치 그룹만 sysfs `type`으로 identity, 외부 포트는 손대지 않음"이다. IOTLB miss가 병목인 200Gbps급 NIC에서는 hugepage 기반 버퍼가 더 근본적인 해법으로 보고됐다(3.4절).

---

## 2. Problem Statement

### 2.1 DMA API가 숨기는 세 개의 경로

드라이버는 `dma_map_page_attrs()`, `dma_map_sg_attrs()`, `dma_map_phys()`(6.18+)만 부르고, 그 아래에서 무엇이 일어나는지는 플랫폼이 정한다. `kernel/dma/mapping.c`의 `dma_map_phys()`는 세 갈래로 나뉜다.

| 경로 | 조건 | 매핑 비용 | 완료 시 비용 | 보호 |
|---|---|---|---|---|
| dma-direct | IOMMU 없음 또는 identity 도메인 (`dma_go_direct()`) | 주소 변환 산술만 | 비일관(non-coherent) 아키텍처의 캐시 sync | 없음 |
| dma-direct + swiotlb | 장치 DMA 마스크 밖 메모리, 기밀 VM(`force_dma_unencrypted()`), `swiotlb=force` | 슬롯 할당 + memcpy | memcpy(FROM_DEVICE) + 슬롯 반납 | 없음 (주소 제약 우회용) |
| dma-iommu | `use_dma_iommu(dev)` (6.12+ 직접 호출) | IOVA 할당 + IOPTE 쓰기 | IOPTE 지우기 + IOTLB 무효화 + IOVA 반납 | 페이지 단위 격리 |
| dma-iommu + bounce | `untrusted` 장치의 sub-page 버퍼 | 위 + swiotlb memcpy | 위 + memcpy | 바이트 단위에 가까운 격리 |

NVMe 4KiB 랜덤 읽기 하나도 dma-iommu 경로에서는 "IOVA 할당 → `iommu_map()` → 장치 DMA → 완료 IRQ → `iommu_unmap_fast()` → IOTLB 무효화 → IOVA 반납"을 거친다. 초당 수백만 IOPS에서는 이 고정 비용이 코어당 처리량을 좌우한다.

### 2.2 병목 1: IOVA 할당기

IOVA 공간은 도메인마다 하나의 `struct iova_domain`이다. 원래 구현은 `iova_rbtree_lock` 하나로 보호되는 RB 트리였다. 모든 CPU가 같은 도메인(같은 NVMe 컨트롤러, 같은 NIC)에 대해 할당·해제를 반복하므로 이 락은 캐시 라인 바운싱의 중심이 된다. Peleg 등은 이 락과 flush queue 락을 "current OSes melt down under load"의 원인으로 지목했다.

### 2.3 병목 2: IOTLB 무효화

IOMMU는 변환 결과를 IOTLB에 캐시한다. 매핑을 지운 뒤 IOTLB를 비우지 않으면 장치는 해제된 페이지에 계속 DMA할 수 있다. 무효화는 IOMMU의 invalidation queue(Intel VT-d의 QI, AMD의 command buffer, Arm SMMUv3의 CMDQ)에 명령을 넣고 완료를 기다리는 일이다. 이 큐는 IOMMU당 하나라 직렬화된다. ATS로 장치 쪽 ATC(Address Translation Cache)까지 쓰는 경우에는 장치까지 왕복하는 무효화가 추가된다.

### 2.4 병목 3: IOTLB miss와 페이지 크기

관리 비용을 줄여도 하드웨어 IOTLB miss는 남는다. 4KiB 단위로 흩어진 수신 버퍼를 쓰는 100–200Gbps NIC에서는 IOTLB 용량이 작업 집합을 감당하지 못한다. miss마다 IOMMU가 메모리에서 페이지 테이블을 걷는다. 이 비용은 strict/lazy 선택과 무관하다. 매핑 크기(huge IOPTE)와 버퍼 배치로만 줄일 수 있다.

### 2.5 보안 요구는 반대 방향을 당긴다

IOMMU의 원래 목적은 DMA 공격과 버그 있는 장치로부터 메모리를 지키는 것이다. LWN의 2019-03-06 기사(Jake Edge)가 정리한 Thunderclap 연구는 IOMMU를 켠 상태에서도 공격이 가능함을 보였다. (a) 운영체제가 장치 통신용 메모리와 같은 영역에 민감한 데이터를 둔다. (b) Linux에서는 악성 NIC가 보낸 메시지의 몇몇 옵션 필드만 바꿔 IOMMU를 우회할 수 있었다. 여기에 IOMMU 매핑 단위(Intel IOMMU의 최소 4KiB)가 버퍼보다 크면 같은 페이지의 나머지까지 장치에 노출된다는 문제가 있다(LWN "Bounce buffers for untrusted devices", 2019-04-26). 여기에 lazy 무효화가 남기는 시간 창(4.3절)이 더해진다. 성능 최적화(lazy, identity, ATS)는 대부분 이 보호를 약하게 만든다. 따라서 튜닝 문제는 "어느 장치에 어느 수준의 보호를 줄 것인가"라는 정책 문제가 된다.

---

## 3. The Debate

### 3.1 "IOMMU 자체가 느리다"는 통념에 대한 반론: Peleg 등 (USENIX ATC '15)

이 분야의 기준점이 된 측정은 Omer Peleg, Adam Morrison, Benjamin Serebrin(Google), Dan Tsafrir의 "Utilizing the IOMMU Scalably"다. 측정 조건은 다음과 같다. 서버는 Dell PowerEdge R430, Xeon E5-2630 v3 2소켓 16코어(HT 끔), Broadcom BCM57810 10Gb/s NIC, Linux 3.17.2. 부하는 netperf TCP_RR 270개 동시 요청과 memcached였다. 논문의 문제 제기는 다음 문장에 요약된다.

> "Mediating DMAs by the IOMMU imposes only negligible overhead by itself, as evidenced by the throughput obtained when the IOMMU is configured with static identity mappings that pass DMA requests through the IOMMU unchanged. In contrast, when IOMMU management is enabled, throughput drops significantly and ceases to increase with the number of cores."
>
> — Peleg et al., [Utilizing the IOMMU Scalably](https://www.usenix.org/conference/atc15/technical-session/presentation/peleg), USENIX ATC '15 (2015-07), 1절

해설: 비용은 변환이 아니라 **관리**(IOVA 할당과 무효화)에서 나온다는 주장이다. 측정 결과(6.1절)는 다음과 같다. No-IOMMU Linux는 16코어에서 1코어 대비 14.4배로 확장된다. 당시 최적화였던 EiovaR는 1코어에서 No-IOMMU의 86%였지만 16코어에서는 23%에 그쳤다. 제안한 설계(magazine 기반 per-core IOVA 캐시, kmalloc 기반 IOVA, dynamic identity)는 16코어에서 No-IOMMU의 93–94%를 냈다. 논문은 당시 Linux의 deferred invalidation도 설명한다. 10ms마다 또는 250개 요청이 모이면 전역 IOTLB flush를 한다는 것이다. 이 방식은 "trades off some security—creating a window of time in which a device can access unmapped IOVAs"라고 평가했다. 현재 커널의 `IOVA_DEFAULT_FQ_SIZE`=256과 `IOVA_DEFAULT_FQ_TIMEOUT`=10ms는 이 설계의 직계 후손이다.

이 논문의 magazine 설계는 2016년 Omer Peleg의 패치 `9257b4a206fc` "iommu/iova: introduce per-cpu caching to iova allocation"으로 Linux 4.7에 들어갔다. 처음에는 Intel VT-d 드라이버 전용이었다(`22e2f9fa63b0`). 2023년 Robin Murphy의 `911aa1245da8` "iommu/iova: Make the rcache depot scale better"(6.7)는 고정 크기 배열이던 depot을 무한 연결 리스트로 바꿨다. 커밋 메시지는 이것이 "원 논문의 알고리즘대로"라고 밝힌다.

### 3.2 strict vs lazy: 아키텍처별 기본값 전쟁의 정리 (4.14 → 5.15)

무효화 정책은 처음에 IOMMU 드라이버마다 달랐다. Intel VT-d와 AMD-Vi는 자체 flush queue로 lazy가 기본이었고, Arm SMMU는 strict였다. 정리는 다음 순서로 진행됐다.

| 버전 | 커밋 | 내용 |
|---|---|---|
| 4.14 | `42f87e71c3df` (Joerg Roedel) | flush queue를 IOVA 계층의 공통 자료구조로 이동 |
| 4.20 | `68a6efe86f6a` (Zhen Lei) | `iommu.strict=` 커맨드라인 옵션 (당초 arm64의 lazy 지원용) |
| 5.15 | `bf3aed4660c6` (Robin Murphy) | `IOMMU_DOMAIN_DMA_FQ`를 별도 도메인 타입으로 승격 |
| 5.15 | `26225bea1d84` (Robin Murphy) | sysfs `iommu_groups/<id>/type`에 `DMA-FQ` 노출 |
| 5.15 | `712d8f205835` (Zhen Lei), `e96763ec42ce` (Robin Murphy) | `CONFIG_IOMMU_DEFAULT_DMA_{STRICT,LAZY}`, `PASSTHROUGH`를 하나의 Kconfig choice로 통합 |
| 6.5 | `4a20ce0ff68e` (Robin Murphy) | `IOMMU_CAP_DEFERRED_FLUSH`로 드라이버의 FQ 지원을 명시 |
| 6.7 | `32d5bc8b09c7`, `9f5b681e2a3f` (Niklas Schnelle) | 단일 대형 FQ 옵션 (`IOMMU_DMA_OPTS_SINGLE_QUEUE`) |
| 7.1 | `1c18a1212c77` (Jason Gunthorpe) | generic page table(iommupt) 도메인은 항상 DMA-FQ 허용 (RISC-V 포함) |

논쟁의 핵심은 "기본값을 무엇으로 할 것인가"였다. 결과는 Kconfig 기본값에 남아 있다. `default IOMMU_DEFAULT_DMA_LAZY if X86 || S390`, 그 밖에는 `default IOMMU_DEFAULT_DMA_STRICT`다. Kconfig 도움말은 lazy를 이렇게 설명한다.

> "This mode allows higher performance with some IOMMUs due to reduced TLB flushing, but at the cost of reduced isolation since devices may be able to access memory for some time after it has been unmapped."
>
> — `drivers/iommu/Kconfig`, `config IOMMU_DEFAULT_DMA_LAZY` ([소스](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/iommu/Kconfig), v7.3-rc7 확인)

해설: x86은 레거시(VT-d/AMD의 기존 lazy 동작)와 서버 I/O 성능을 우선했다. arm64는 모바일·임베디드에서 보안 기본값을 우선했다. 배포판 커널은 이 Kconfig 기본값을 그대로 쓰는 경우가 많다. 그래서 같은 NVMe 장치가 x86 서버에서는 `DMA-FQ`, arm64 서버에서는 `DMA`로 부팅될 수 있다. 성능 비교 결과를 해석할 때 이 차이를 먼저 확인해야 한다.

### 3.3 가상화 환경: 무효화가 VM exit일 때

IOTLB flush가 하이퍼바이저 트랩이 되는 환경에서는 flush 한 번의 비용이 훨씬 크다. 현재 트리에서 `dev->iommu->shadow_on_flush`를 켜는 드라이버는 s390(`drivers/iommu/s390-iommu.c`)뿐이다. virtio-iommu는 `6f01a732608f`(Niklas Schnelle)로 `flush_iotlb_all`과 deferred flush를 얻었지만 기본 per-CPU FQ를 쓴다. Schnelle의 `9f5b681e2a3f`는 이 경우 FQ를 CPU당 256개 대신 하나의 32768항목 큐(`IOVA_SINGLE_FQ_SIZE`)와 1초 타임아웃(`IOVA_SINGLE_FQ_TIMEOUT`)으로 바꿨다. 커밋 메시지는 이 설정으로 "performance on par with the previous s390 specific DMA API implementation"을 얻었다고 쓴다. 대가는 분명하다. lazy 창이 10ms에서 최대 1초로 늘어난다. 가상화에서 이 선택이 받아들여진 이유는 게스트의 "장치"가 대개 하이퍼바이저가 중재하는 가상 장치이기 때문이다.

### 3.4 관리 비용 다음의 병목: IOTLB miss

2020년대 연구는 소프트웨어 관리 비용이 아니라 **하드웨어 IOTLB miss**를 문제 삼는다. Rubin, Agarwal, Cai, Agarwal의 "Fast & Safe IO Memory Protection"(SOSP '24, DOI 10.1145/3694715.3695943) 초록은 프로덕션 데이터센터 연구를 인용한다. 기존 메모리 보호 메커니즘이 "significant throughput degradation, orders-of-magnitude tail latency inflation, and violation of isolation guarantees"를 낸다는 것이다. 이 논문은 "IOTLB miss율을 줄이는 것보다 miss 한 번의 비용을 줄이는 데 집중해야 한다"고 주장하고, 하드웨어 변경 없이 OS 수정만으로 가장 강한 안전성(strict)과 거의 0에 가까운 오버헤드를 동시에 얻는 F&S를 제안한다. 구체적 수치는 본문 조건과 함께 봐야 한다. 이 문서는 초록에서 확인한 주장만 옮긴다.

같은 맥락의 KTH 연구(Farshin, Rizzo, Elmeleegy, Kostić, "Overcoming the IOTLB wall for multi-100-Gbps Linux-based networking", PeerJ Computer Science, 2023)는 200Gbps에서 IOTLB miss로 No-IOMMU 대비 최대 20%의 처리량 손실을 보고했다. 그리고 NIC 드라이버의 수신 버퍼를 hugepage 기반으로 할당하면 이 손실을 회복할 수 있다고 했다. 이 경로는 strict/lazy 스위치로는 바뀌지 않는다. `page_pool`의 `PP_FLAG_DMA_MAP`(한 번 매핑해 재사용)과 큰 IOPTE를 만들 수 있는 연속 메모리가 해법이다.

### 3.5 identity(passthrough)는 "튜닝"인가 "보안 정책 포기"인가

`iommu.passthrough=1`(과거 `iommu=pt`)은 신뢰하는 장치를 identity 도메인에 두어 관리 비용과 IOTLB miss를 모두 없앤다. 이 선택을 둘러싼 입장은 둘로 갈린다.

- **성능 진영**: 베어메탈 스토리지 서버에서 NVMe·NIC는 모두 내부 장치이고, IOMMU는 VFIO/SR-IOV 할당을 위해서만 필요하다. 이 경우 호스트 드라이버용 기본 도메인은 identity로 두는 것이 합리적이다.
- **격리 진영**: 장치 펌웨어 버그, 악성 PCIe 카드, 메모리 손상 DMA(드라이버의 use-after-free)를 잡는 유일한 장치가 IOMMU다. Kconfig의 passthrough 도움말도 "giving them unrestricted access to memory"라고 쓴다.

커널의 답은 **정책을 장치 단위로 내리는 것**이다. 기본값은 전역(커맨드라인·Kconfig)으로 정하되, sysfs `type` 파일로 그룹마다 바꿀 수 있다. 그리고 `untrusted` 장치는 어떤 설정에서도 `IOMMU_DOMAIN_DMA`로 강제한다(`iommu_get_default_domain_type()`의 `untrusted` 분기). 드라이버가 다른 타입을 요구하면 프로브를 거부한다("Device is not trusted, but driver is overriding group ... refusing to probe.").

### 3.6 scatterlist 이후의 매핑 API

`dma_map_sg()`는 scatterlist 전체를 받아 IOVA를 한 번에 할당하지만, 결과를 scatterlist에 다시 써야 한다. 블록·RDMA·VFIO는 각자의 자료구조를 scatterlist로 바꾸는 비용을 냈다. Leon Romanovsky와 Christoph Hellwig의 2단계 API(6.16) 논쟁과 블록 계층 적용(6.17)은 08/02의 3.4절과 4.6절에 자세히 있다(→ 08/02). 이 문서의 관점에서 중요한 점은 IOTLB 비용이다. 2단계 API는 요청 하나에 대해 `dma_iova_try_alloc()`으로 IOVA를 한 번 할당한다. 세그먼트마다 `dma_iova_link()`로 IOPTE만 쓰고, 마지막에 `dma_iova_sync()` → `iommu_sync_map()`으로 한 번만 동기화한다. 해제도 `dma_iova_destroy()` 한 번이다. 세그먼트 수만큼 IOVA를 할당·반납하던 page 단위 매핑보다 rcache·FQ 트래픽이 줄어든다.

---

## 4. Implementation Impact

### 4.1 매핑·해제 콜패스 (Linux 7.3-rc7 기준)

```
[제출] dma_map_phys(dev, phys, size, dir, attrs)            kernel/dma/mapping.c (6.18+)
  ├─ dma_map_direct() → dma_direct_map_phys()               identity/IOMMU 없음
  └─ use_dma_iommu(dev) → iommu_dma_map_phys()              drivers/iommu/dma-iommu.c
       ├─ dev_use_swiotlb() && iova_unaligned()  → iommu_dma_map_swiotlb()   (untrusted sub-page)
       ├─ !coherent → arch_sync_dma_for_device()
       └─ __iommu_dma_map()
            ├─ iommu_dma_alloc_iova()
            │    ├─ pci_32bit_workaround → alloc_iova_fast(..., DMA_BIT_MASK(32), false)
            │    └─ alloc_iova_fast(iovad, len, limit, true)
            │         ├─ iova_rcache_get()        per-CPU magazine (≤ 32 pages)
            │         └─ alloc_iova()             RB tree, iova_rbtree_lock
            └─ iommu_map(domain, iova, phys, size, prot, GFP_ATOMIC)   → IOPTE 쓰기, iotlb_sync_map

[완료] dma_unmap_phys() → iommu_dma_unmap_phys() → __iommu_dma_unmap()
  ├─ iotlb_gather.queued = READ_ONCE(cookie->fq_domain)       DMA-FQ면 true
  ├─ iommu_unmap_fast(domain, iova, size, &gather)            IOPTE 지우기
  ├─ !queued → iommu_iotlb_sync()                             strict: 동기 무효화
  └─ iommu_dma_free_iova()
       ├─ queued → queue_iova()   → per-CPU iova_fq 링에 넣고 타이머 무장
       └─ else   → free_iova_fast() → iova_rcache_insert() 또는 RB tree
```

눈여겨볼 지점이 둘 있다. 첫째, `iommu_dma_alloc_iova()`는 장치가 64비트 DMA를 지원해도 **먼저 32비트 IOVA 공간을 시도한다**. 소스 주석은 하드웨어·펌웨어 버그 때문에 "it's safest not to venture into the 64-bit space until necessary"라고 설명한다. 32비트 공간이 고갈되면 `pci_32bit_workaround`를 끄고 "Using %d-bit DMA addresses" 알림을 한 번 남긴다. `iommu.forcedac=1`(5.13, `3542dcb15cef`에서 부활)은 이 단계를 처음부터 건너뛴다. 큰 머신에서 32비트 공간 고갈과 rcache flush가 반복되는 것을 피하는 옵션이다.

둘째, 6.12의 `b5c58b2fdc42` "dma-mapping: direct calls for dma-iommu" 이후 `dma_map_*`는 `dev->dma_ops`를 거치지 않는다. `use_dma_iommu()`를 확인한 뒤 `iommu_dma_*`를 직접 호출한다. 커밋 메시지는 이것이 "avoids the indirect call overhead for IOMMU ops"라고 쓴다. Spectre 완화로 간접 호출이 retpoline이 된 환경에서는 I/O당 고정 비용이 줄었다.

### 4.2 Flush queue 내부: 카운터 기반 지연 해제

`struct iommu_dma_cookie`는 FQ 상태로 `fq_flush_start_cnt`/`fq_flush_finish_cnt`(atomic64), `fq_timer`, `fq_timer_on`, `fq_domain`을 가진다. 동작은 다음과 같다.

1. `queue_iova()`는 먼저 `smp_mb()`로 IOPTE 제거와의 순서를 보장한다. 그런 다음 현재 CPU의 `iova_fq`(`raw_cpu_ptr`) 락을 잡는다.
2. `fq_ring_free_locked()`로 **이미 완료된 flush 이후에 들어온 항목만** 해제한다. 항목의 `counter`가 `fq_flush_finish_cnt`보다 작으면 해제 가능하다.
3. 링이 가득 차면(`fq_full()`) 그 자리에서 `fq_flush_iotlb()` → `domain->ops->flush_iotlb_all()`을 동기 호출한다.
4. 항목에 `iova_pfn`, `pages`, 현재 `fq_flush_start_cnt`, 해제할 페이지 테이블 페이지(`freelist`)를 기록한다.
5. 타이머가 꺼져 있으면 `fq_timeout`(기본 10ms) 뒤로 무장한다. `fq_flush_timeout()`은 전체 IOTLB를 flush하고 모든 CPU의 링을 비운다.

여기서 lazy의 보안 의미가 정확히 드러난다. **IOVA는 flush 전까지 재사용되지 않는다. 하지만 그 IOVA가 가리키던 물리 페이지는 드라이버가 unmap 직후 바로 해제할 수 있다.** 따라서 최대 `fq_timeout` 동안 장치는 IOTLB에 남은 항목으로 이미 다른 용도로 재할당된 페이지에 DMA할 수 있다. strict 모드는 이 창을 0으로 만든다.

또 하나의 함정은 `fq_flush_timeout()`이 타이머 softirq에서 **모든 CPU의 FQ를 순회**한다는 점이다. 3710e2b056cb의 커밋 메시지에 남은 ftrace는 448코어 AMD 서버에서 `fq_flush_timeout()`이 31초를 쓰고, `free_iova()`가 `iova_rbtree_lock`에서 85ms씩 대기한 기록을 보여 준다. 4MiB 요청(MDTS=10)이 rcache 범위를 벗어나 모두 RB 트리로 갔기 때문이다.

### 4.3 IOVA rcache 구조

| 항목 | 값 / 이름 | 의미 |
|---|---|---|
| 캐시 대상 크기 | `IOVA_RANGE_CACHE_MAX_SIZE` = 6 → order 0–5 | 1–32 페이지(4KiB 페이지에서 4KiB–128KiB). 2의 거듭제곱으로 올림 |
| magazine | `struct iova_magazine`, `IOVA_MAG_SIZE` = 127 pfn | 구조체 크기를 2의 거듭제곱으로 맞추도록 `static_assert` |
| per-CPU | `struct iova_cpu_rcache { lock, loaded, prev }` | 두 magazine을 번갈아 써서 경계에서의 thrashing 완화 |
| 전역 | `struct iova_rcache { lock, depot_size, depot, cpu_rcaches, work }` | 가득 찬 magazine의 연결 리스트 (6.7+) |
| depot 회수 | `IOVA_DEPOT_DELAY` = 100ms, `iova_depot_work_func()` | 남는 magazine을 지연 해제 |
| 고갈 시 | `alloc_iova_fast(..., flush_rcache=true)` | 모든 CPU 캐시를 비우고(`free_cpu_cached_iovas`) RB 트리 재시도 |
| 외부 노출 | `iova_rcache_range()` → `iommu_dma_opt_mapping_size()` → `dma_opt_mapping_size()` (6.0) | 드라이버가 최적 매핑 크기를 알 수 있게 함 |

NVMe가 이 값을 쓴다. `nvme_pci_alloc_dev()`에서 `dev->ctrl.max_hw_sectors = min_t(u32, NVME_MAX_BYTES >> SECTOR_SHIFT, dma_opt_mapping_size(&pdev->dev) >> 9)`로 상한을 둔다. IOMMU가 identity면 `dma_opt_mapping_size()`가 사실상 무제한이라 이 제약이 없다. 운영 관점에서 이 차이는 크다. IOMMU 모드를 바꾸면 NVMe의 `max_hw_sectors_kb`가 바뀌고, 큰 순차 I/O의 분할 횟수와 명령 수가 달라진다.

### 4.4 swiotlb: bounce buffer의 세 가지 쓰임

`kernel/dma/swiotlb.c`의 bounce 풀은 slot 단위로 관리된다. 기본값은 `IO_TLB_SHIFT` = 11(2KiB slot), `IO_TLB_SEGSIZE` = 128(한 번에 최대 128 slot = 256KiB 연속), `IO_TLB_DEFAULT_SIZE` = 64MiB다(7.3 개발 주기에 `CONFIG_SWIOTLB_DEFAULT_SIZE_MB`, 범위 1~64, 기본 64가 추가되어 빌드 시 줄일 수 있다). 풀은 각자 락을 가진 `struct io_tlb_area`로 나뉜다. 커맨드라인 `swiotlb=<slabs>,<areas>|force|noforce`로 크기·area 수·강제 여부를 정한다. 6.6부터는 `CONFIG_SWIOTLB_DYNAMIC`(`62708b2ba405`, Petr Tesarik)으로 풀이 런타임에 커질 수 있다.

1. **주소 제약 우회**: DMA 마스크가 좁은 장치가 높은 주소의 메모리를 쓸 때. 현대 NVMe·NIC에서는 드물다.
2. **기밀 VM(SEV/TDX)**: `force_dma_unencrypted()`가 참이면 **모든** 스트리밍 DMA가 공유(비암호화) bounce 풀을 거친다. I/O마다 memcpy가 붙고, 풀 크기와 area 락이 처리량 상한이 된다. 기밀 VM에서 NVMe/virtio 성능을 볼 때는 이 경로가 먼저 의심 대상이다.
3. **untrusted 장치 보호**: `iommu_dma_map_phys()`는 `dev_use_swiotlb()`가 참이고 버퍼의 시작이나 길이가 IOVA granule에 맞지 않을 때만 bounce한다(`iova_unaligned()`). untrusted 장치에는 bounce 영역의 앞뒤 패딩을 0으로 채운다. 이 설계는 2019년 Lu Baolu의 VT-d 전용 구현(`cfb94a372f2d`, 5.4)에서 시작해 dma-iommu 공통 코드로 옮겨졌다. LWN "Bounce buffers for untrusted devices"(2019-04-26)가 당시 설계를 다룬다.

### 4.5 ATS, PRI, PASID

ATS(Address Translation Services)는 장치가 변환 결과를 자체 ATC에 캐시하도록 한다. IOMMU의 IOTLB miss를 줄일 수 있지만 대가가 있다.

- **무효화 비용 증가**: unmap 시 IOMMU IOTLB뿐 아니라 장치 ATC까지 무효화해야 한다. Intel VT-d에서는 `qi_flush_dev_iotlb()`/`qi_flush_dev_iotlb_pasid()`가 이를 맡는다. 장치가 응답할 때까지 기다려야 하므로 strict 모드의 unmap 지연이 커진다. lazy 모드에서는 이 비용도 `flush_iotlb_all` 하나로 모인다.
- **신뢰 문제**: ATS를 쓰는 장치는 "이미 변환된" 주소로 요청할 수 있다. 그래서 `pci_ats_supported()`는 `dev->untrusted`이면 false를 반환한다. 커맨드라인 `pci=noats`로 전역으로 끌 수 있다.
- **PRI/PASID**: PRI(Page Request Interface)는 장치가 매핑되지 않은 주소에서 페이지 폴트를 IOMMU에 보고하게 한다(`iommu_report_device_fault()`, `iopf_queue_alloc()`). PASID와 함께 쓰면 `iommu_sva_bind_device()`로 프로세스 주소 공간을 장치와 공유하는 SVA가 된다. 스토리지 데이터 경로에서는 Intel DSA/IAA 같은 가속기가 대표적 사용자다. NVMe 데이터 경로에서는 쓰이지 않는다. 폴트 처리 지연이 I/O 지연 예산을 크게 넘기 때문이다.

### 4.6 iommufd: 사용자 공간 드라이버의 IOMMU 비용 모델

iommufd(6.2, `2ff4bed7fee7`, Jason Gunthorpe)는 VFIO type1을 대체하는 IOMMU 사용자 API다. 객체 모델은 IOAS(I/O 주소 공간, `IOMMU_IOAS_ALLOC`), HWPT(하드웨어 페이지 테이블, `IOMMU_HWPT_ALLOC`), 장치 바인딩이다. 6.13에는 memfd 기반 매핑(`IOMMU_IOAS_MAP_FILE`)과 vIOMMU 객체(`IOMMU_VIOMMU_ALLOC`)가 추가됐다. LWN의 "Connect VFIO to IOMMUFD"(912519)가 VFIO 연결 시리즈를 다룬다.

I/O 성능에서 중요한 점은 비용이 **언제** 생기는가다. SPDK·DPDK 같은 VFIO 사용자 공간 드라이버는 hugepage를 시작할 때 한 번 `IOMMU_IOAS_MAP`(또는 type1 `VFIO_IOMMU_MAP_DMA`)으로 고정 매핑한다. 그래서 I/O마다 IOVA 할당·무효화가 없다(→ 07/01). 커널 드라이버의 스트리밍 DMA가 I/O마다 내는 비용을 사용자 공간 드라이버는 초기화 단계로 옮긴 셈이다. 같은 원리가 커널 안에서는 `page_pool`(`PP_FLAG_DMA_MAP`)의 "한 번 매핑해 재사용"으로 나타난다. 블록 계층에는 아직 일반적인 "미리 매핑된 버퍼" 경로가 없다. io_uring의 registered buffer는 페이지 pinning만 줄이고 DMA 매핑은 I/O마다 한다.

### 4.7 모드별 비교

| 모드 | 도메인 타입 | 매핑 비용 | unmap 비용 | 격리 수준 | 대표 설정 |
|---|---|---|---|---|---|
| passthrough | `IOMMU_DOMAIN_IDENTITY` | 없음 (dma-direct) | 없음 | 없음 | `iommu.passthrough=1`, sysfs `identity` |
| lazy | `IOMMU_DOMAIN_DMA_FQ` | IOVA(rcache) + IOPTE | IOPTE 제거 + FQ 큐잉, 주기적 전체 flush | 페이지 단위, 최대 10ms 창 | x86 기본, `iommu.strict=0`, sysfs `DMA-FQ` |
| strict | `IOMMU_DOMAIN_DMA` | 동일 | IOPTE 제거 + 동기 범위 무효화 | 페이지 단위, 창 없음 | arm64 기본, `iommu.strict=1`, sysfs `DMA` |
| strict + bounce | `IOMMU_DOMAIN_DMA` (강제) | + swiotlb memcpy (sub-page) | + memcpy | sub-page | `untrusted` 장치 (변경 불가) |
| 사용자 공간 VFIO | iommufd/type1 UNMANAGED 도메인 | 시작 시 1회 | 종료 시 1회 | 프로세스 단위 | SPDK/DPDK |

### 4.8 운영 튜닝 체크리스트

1. **현재 상태 확인**: `iommu_subsys_init()`은 부팅 시 "Default domain type: ..."와 "DMA domain TLB invalidation policy: strict/lazy mode" 두 줄을 남기고, 커맨드라인으로 정한 경우 "(set via kernel command line)"을 붙인다. 메모리 암호화 플랫폼(`CC_ATTR_MEM_ENCRYPT`)에서는 Kconfig가 passthrough여도 기본값을 translated로 되돌리고 "Memory encryption detected - Disabling default IOMMU Passthrough"를 출력한다. 장치별로는 `/sys/kernel/iommu_groups/<id>/type`을 읽는다.
2. **그룹 단위 전환**: sysfs `type` 쓰기에는 `CAP_SYS_ADMIN`과 `CAP_SYS_RAWIO`가 필요하다. `DMA` → `DMA-FQ` 전환은 드라이버가 바인딩된 상태에서도 된다(`iommu_dma_init_fq()`로 FQ만 추가). 그 밖의 전환(identity 등)은 그룹 안 장치에 드라이버가 없어야 한다(`-EPERM`). ABI 문서는 루트 파일시스템 장치에서 이 작업을 하면 "catastrophic effects"가 날 수 있다고 경고한다.
3. **NVMe 대용량 순차 I/O**: IOMMU 모드에 따라 `max_hw_sectors_kb`가 달라진다(4.3절). 큰 블록 처리량을 비교할 때 이 값을 함께 기록한다.
4. **대규모 코어 수 + 큰 매핑**: `fq_flush_timeout()` 순회 비용과 RB 트리 경합을 의심한다. 매핑 크기를 rcache 범위 안으로 유지하는 것이 우선이다.
5. **200Gbps급 NIC**: strict/lazy보다 IOTLB miss가 문제일 수 있다. 드라이버의 `page_pool` 사용 여부, 큰 페이지 할당 지원을 먼저 본다.
6. **외부 포트**: Thunderbolt 컨트롤러의 `/sys/bus/thunderbolt/devices/.../domainX/iommu_dma_protection`(4.21/5.0 ABI)이 1인지 확인한다. 이 값은 펌웨어가 ExternalFacingPort를 알리고 IOMMU가 그것을 신뢰할 수 있을 때만 1이 된다(`drivers/thunderbolt/pci.c`).

### 4.9 버전 연표

| 버전 | 변화 |
|---|---|
| 4.7 | per-CPU IOVA rcache (`9257b4a206fc`, Omer Peleg) |
| 4.14 | flush queue를 IOVA 공통 코드로 (`42f87e71c3df`) |
| 4.20 | `iommu.strict=` (`68a6efe86f6a`) |
| 5.4 | 기본 도메인 타입 런타임 설정 (`22bb182c839d`), VT-d untrusted bounce (`cfb94a372f2d`) |
| 5.11 | sysfs `iommu_groups/<id>/type` 쓰기 (ABI 문서 기준) |
| 5.13 | `iommu.forcedac` 부활 (`3542dcb15cef`) |
| 5.15 | `IOMMU_DOMAIN_DMA_FQ`, sysfs `DMA-FQ`, Kconfig 기본 모드 통합 |
| 6.0 | `dma_opt_mapping_size()` (`a229cc14f339`) |
| 6.2 | iommufd (`2ff4bed7fee7`) |
| 6.4 | nvme-pci `max_hw_sectors`를 `dma_opt_mapping_size()`로 제한 (`3710e2b056cb`, 6.4-rc3) |
| 6.6 | `CONFIG_SWIOTLB_DYNAMIC` (`62708b2ba405`) |
| 6.7 | rcache depot 연결 리스트화 (`911aa1245da8`), 단일 대형 FQ (`32d5bc8b09c7`) |
| 6.8 | virtio-iommu deferred flush (`6f01a732608f`) |
| 6.12 | dma-iommu 직접 호출 (`b5c58b2fdc42`) |
| 6.13 | `IOMMU_IOAS_MAP_FILE`, `IOMMU_VIOMMU_ALLOC` |
| 6.16 | `dma_iova_try_alloc`/`dma_iova_link`/`dma_iova_sync` (`393cf700e624`) |
| 6.17 | `blk_rq_dma_map_iter_start` (`858299dc6160`) |
| 6.18 | `dma_map_phys()` 공개 인터페이스 (`f7326196a781`) |
| 6.19 | generic page table(iommupt) 기반 API (`7c5b184db714`) |
| 7.1 | iommupt 도메인은 항상 DMA-FQ 허용 (`1c18a1212c77`) |

---

## 5. Primary References

- [Utilizing the IOMMU Scalably](https://www.usenix.org/conference/atc15/technical-session/presentation/peleg) — Peleg, Morrison, Serebrin, Tsafrir, USENIX ATC '15. IOVA 할당·IOTLB 관리의 확장성 병목과 magazine 캐시 (Linux 3.17.2, 16코어, 10GbE 측정)
- [Fast & Safe IO Memory Protection](https://dl.acm.org/doi/10.1145/3694715.3695943) — Rubin, Agarwal, Cai, Agarwal, SOSP '24. IOTLB miss 비용 관점의 strict 보호
- [The Thunderclap vulnerabilities](https://lwn.net/Articles/782381/) — Jake Edge, LWN, 2019-03-06. IOMMU를 켠 상태의 DMA 공격
- [Bounce buffers for untrusted devices](https://lwn.net/Articles/786558/) — Marta Rybczyńska, LWN, 2019-04-26. untrusted 장치용 sub-page bounce 설계
- [Connect VFIO to IOMMUFD](https://lwn.net/Articles/912519/) — Jason Gunthorpe 패치 시리즈 (LWN 미러)
- [Dancing the DMA two-step](https://lwn.net/Articles/997563/) — Jonathan Corbet, LWN, 2024-11-14. `dma_iova_*` 2단계 API 논쟁
- [Dynamic DMA mapping using the generic device](https://docs.kernel.org/core-api/dma-api.html) — 커널 DMA API 공식 문서
- [IOMMUFD](https://docs.kernel.org/userspace-api/iommufd.html) — iommufd 사용자 API 공식 문서
- [x86 IOMMU Support](https://docs.kernel.org/arch/x86/iommu.html) — VT-d/AMD-Vi 동작과 커널 옵션
- [The kernel's command-line parameters](https://docs.kernel.org/admin-guide/kernel-parameters.html) — `iommu.strict`, `iommu.passthrough`, `iommu.forcedac`, `swiotlb=`, `pci=noats`
- [drivers/iommu/dma-iommu.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/iommu/dma-iommu.c) — 커널 소스(master)
- [drivers/iommu/iova.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/iommu/iova.c) — 커널 소스(master)
- [drivers/iommu/iommu.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/iommu/iommu.c) — 커널 소스(master)
- [drivers/iommu/Kconfig](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/iommu/Kconfig) — 커널 소스(master)
- [kernel/dma/swiotlb.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/kernel/dma/swiotlb.c) — 커널 소스(master)
- [Documentation/ABI/testing/sysfs-kernel-iommu_groups](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/Documentation/ABI/testing/sysfs-kernel-iommu_groups) — 커널 소스(master)
- [9257b4a206fc iommu/iova: introduce per-cpu caching to iova allocation](https://github.com/torvalds/linux/commit/9257b4a206fc) — 커밋
- [bf3aed4660c6 iommu: Introduce explicit type for non-strict DMA domains](https://github.com/torvalds/linux/commit/bf3aed4660c6) — 커밋
- [3710e2b056cb nvme-pci: clamp max_hw_sectors based on DMA optimized limitation](https://github.com/torvalds/linux/commit/3710e2b056cb) — 커밋
- [911aa1245da8 iommu/iova: Make the rcache depot scale better](https://github.com/torvalds/linux/commit/911aa1245da8) — 커밋
- [9f5b681e2a3f iommu/dma: Use a large flush queue and timeout for shadow_on_flush](https://github.com/torvalds/linux/commit/9f5b681e2a3f) — 커밋
- [b5c58b2fdc42 dma-mapping: direct calls for dma-iommu](https://github.com/torvalds/linux/commit/b5c58b2fdc42) — 커밋
- [1c18a1212c77 iommu/dma: Always allow DMA-FQ when iommupt provides the iommu_domain](https://github.com/torvalds/linux/commit/1c18a1212c77) — 커밋
- [PATCH v13 6/6 iommu/dma: Use a large flush queue and timeout for shadow_on_flush](https://lore.kernel.org/r/20230928-dma_iommu-v13-6-9e5fc4dacc36@linux.ibm.com) — Niklas Schnelle, 2023-09-28, 커밋 `9f5b681e2a3f`의 Link 태그
