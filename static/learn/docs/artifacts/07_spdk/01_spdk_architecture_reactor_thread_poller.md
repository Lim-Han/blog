# SPDK 아키텍처 해부: 폴링·락리스·Shared-Nothing 철학과 env / reactor / spdk_thread / poller / io_channel

> 기준: SPDK `master` (v27.01 개발 중, 2026-10-14 확인) 및 최신 릴리스 v26.09. 함수·구조체·매크로 이름은 `include/spdk/*.h`, `lib/thread/thread.c`, `lib/event/reactor.c`, `lib/env_dpdk/*.c` 원문과 대조했다. 버전별 도입 시점은 저장소 `CHANGELOG.md`와 spdk.io 릴리스 공지를 근거로 한다.

## 1. Verdict

SPDK(Storage Performance Development Kit)는 "커널을 빠르게 만드는" 프로젝트가 아니다. 저장 장치 스택 전체를 **하나의 사용자 프로세스 안의 C 라이브러리 묶음**으로 다시 만들고, 그 안에서 세 가지 원칙을 지키는 프로젝트다. spdk.io의 "What is SPDK" 문서는 이 원칙을 이렇게 요약한다.

> "Moving all of the necessary drivers into userspace, which avoids syscalls and enables zero-copy access from the application. Polling hardware for completions instead of relying on interrupts, which lowers both total latency and latency variance. Avoiding all locks in the I/O path, instead relying on message passing."
>
> — SPDK 공식 문서 [What is SPDK](https://spdk.io/doc/about.html) (2026-10-14 확인)

해설: 세 원칙(사용자 공간 드라이버, 폴링, I/O 경로에서 락 없이 메시지 전달)은 서로 묶여 있다. 사용자 공간 드라이버여야 애플리케이션이 스레드 수를 알고 하드웨어 큐를 스레드에 1:1로 줄 수 있다. 그래야 락이 필요 없고, 락이 없어야 폴링 루프가 짧은 시간 예산 안에 끝난다.

이 문서의 결론은 다음과 같다.

1. **SPDK의 핵심은 NVMe 드라이버보다 스레딩 모델이다.** `spdk_thread`(스택 없는 경량 스레드), `spdk_poller`(반복 호출되는 함수), `spdk_thread_send_msg()`(함수 포인터 + 컨텍스트를 lockless ring으로 넘기는 메시지), `spdk_io_device`/`spdk_io_channel`(전역 객체와 스레드별 컨텍스트 쌍)의 네 가지 기본 요소가 bdev, blobstore, NVMe-oF target, vhost 등 상위 계층 전체의 동시성 모델을 정한다.
2. **"lockless"는 데이터 경로에 대한 말이다.** 제어 경로에는 락이 있다. 예를 들어 `spdk_get_io_channel()`은 전역 `g_devlist_mutex`(pthread mutex)를 잡고 `io_device` RB 트리를 조회한다(`lib/thread/thread.c`). 채널은 스레드마다 한 번 얻어서 계속 재사용하라는 설계다. I/O 경로에서 지켜지는 불변식은 "하나의 큐·채널은 한 시점에 한 스레드만 만진다"는 규칙이다.
3. **env 계층은 사실상 DPDK EAL이다.** `spdk_env_init()`은 `spdk_env_opts`를 DPDK 명령행 인자로 바꿔 `rte_eal_init()`을 부른다(`lib/env_dpdk/init.c`). hugepage 기반으로 pin된 메모리, `vfio-pci`를 통한 IOMMU 매핑, `--iova-mode` 선택은 DPDK의 기능이다. SPDK는 그 위에 2단계 페이지 테이블 형태의 `spdk_mem_map`을 두고 가상주소→IOVA 변환을 직접 관리한다.
4. **"100% CPU를 태운다"는 비판은 2020년 이후 계속 바뀌고 있다.** v20.10에 실험적 interrupt 모드(`fd_group` = epoll 래퍼)가 들어왔다. 이후 v21.01 dynamic scheduler, v24.01 `--interrupt-mode` 전역 옵션, v24.09 NVMe-oF TCP target, v25.05 NVMe PCIe 드라이버, v26.01 NVMe-oF RDMA target, v26.09 NVMe RDMA initiator로 interrupt 지원 범위가 넓어졌다. 지원 범위는 아직 서브시스템마다 다르다(4.7절 표).
5. **거버넌스가 바뀌었다.** Intel은 2013년 내부 프로젝트로 시작해 2015년 GitHub에 공개했다. 2024-12-05에는 SPDK를 Linux Foundation으로 넘기고 Intel 자신은 투자를 접는다고 발표했다. v25.05는 "LF 이전 후 첫 릴리스"이고 TSC(Technical Steering Committee) 체제에서 나왔다.

---

## 2. Problem Statement

### 2.1 I/O 하나당 수백 사이클이라는 예산

SPDK 핵심 개발자 Ben Walker와 Jim Harris는 2019-05-06 블로그 [10.39M Storage I/O Per Second From One Thread](https://spdk.io/news/2019/05/06/nvme/)에서 목표를 숫자로 적었다. 4.0GHz(터보) Xeon Platinum 8280L 코어 하나로 초당 1,000만 NVMe I/O를 처리하려면 I/O 하나에 쓸 수 있는 시간은 **400 클럭(100ns)**이다. 같은 글은 벤치마크 도구가 랜덤 LBA를 만들 때 쓰는 `divq` 명령 하나가 CPU 사이클의 6%를 먹는다고 보고했다. 같은 글에 실린 측정 결과는 다음과 같다. 출처는 모두 위 블로그다.

- 21개 Intel SSD DC P4600, 4KiB random read, 장치당 QD128, 단일 스레드에서 **10.39M IOPS**
- 20개 Optane P4800X, 512B random read, 장치당 QD32에서 평균 지연 57µs

이 예산 안에는 다음이 들어갈 자리가 없다.

- 시스템 콜 진입·복귀, VFS 계층, `bio`/`request` 할당
- 인터럽트 처리와 컨텍스트 스위치
- 공유 큐를 보호하는 락이나 원자적 연산이 일으키는 캐시 라인 바운싱
- doorbell MMIO 쓰기(PCIe posted write지만 I/O마다 하면 비싸다)

같은 블로그는 설계 원칙 네 가지를 제시한다. "No cross-thread coordination", "Poll instead of interrupt", "Minimize MMIO", "Get the important things into the CPU cache at the right time".

### 2.2 커널 드라이버가 큐를 스레드에 줄 수 없는 이유

SPDK [User Space Drivers](https://spdk.io/doc/userspace.html) 문서는 커널과 SPDK의 차이를 큐 배정 방식에서 찾는다. 커널 드라이버는 시스템의 모든 프로세스와 스레드를 상대해야 하고 스레드 구성은 계속 바뀐다. 그래서 하드웨어 큐를 **CPU 코어**에 대응시키고, 제출할 때 현재 코어의 큐를 찾는다. 이때 같은 코어의 선점을 막기 위해 락을 잡거나 인터럽트를 잠시 끈다. 반면 사용자 공간 드라이버는 하나의 애플리케이션에 내장되므로 스레드 수를 정확히 안다. SPDK는 "하드웨어 큐는 한 시점에 한 스레드만 접근한다"는 조건을 걸고 큐를 애플리케이션에 그대로 노출한다.

이 차이는 데이터 구조에서 드러난다. Linux blk-mq도 per-cpu 소프트웨어 큐(`blk_mq_ctx`)와 하드웨어 큐(`blk_mq_hw_ctx`)로 락 경합을 크게 줄였다. 그래도 태그 할당(`sbitmap`), 공유 태그셋, 타임아웃 처리, 스케줄러 같은 공용 기능을 위한 동기화는 남는다. SPDK는 이 공용 기능을 "애플리케이션이 스레드 소유권을 보장한다"는 계약으로 대신한다. 그 대가로 공유성과 격리를 내준다(→ 07/03).

### 2.3 락 기반 공유 상태의 확장성 한계

[Message Passing and Concurrency](https://spdk.io/doc/concurrency.html) 문서는 전통적인 "공유 데이터 + 락" 모델의 장점(단일 스레드 코드를 거의 그대로 쓸 수 있음, 동기식 명령형 코드, 커널 스케줄러의 시분할)을 먼저 인정한다. 그다음 스레드 수가 늘수록 락 경합이 커지고, 락을 잘게 나누면 복잡도가 커진다고 지적한다. SPDK의 목표는 "하드웨어를 더하면 선형으로 확장"이고, 이를 위해 문서는 "avoiding software locks and even atomic instructions"까지 요구한다.

### 2.4 사용자 공간 DMA의 근본 문제: 물리 주소와 pinning

NVMe 장치는 DMA로 호스트 메모리를 읽고 쓰므로 버퍼의 **버스 주소(IOVA)**를 알아야 한다. [Direct Memory Access (DMA) From User Space](https://spdk.io/doc/memory.html) 문서가 정리한 문제는 다음과 같다.

- `/proc/self/pagemap`으로 가상→물리 변환을 얻을 수 있지만 Linux 4.0부터 root 권한이 필요하다. 더 큰 문제는 OS가 매핑이 고정된다고 보장하지 않는다는 점이다(스왑, compaction, 메모리 핫플러그).
- POSIX `mlock`은 스왑만 막는다. 물리 주소가 바뀌지 않는다는 보장(pinning)은 하지 않고, POSIX에는 pin API가 없다.
- 그래서 SPDK는 DPDK를 통해 hugepage(기본 2MiB)를 할당한다. Linux는 현재 hugepage의 물리 위치를 옮기지 않는다. 문서도 이것이 "의도된 보장은 아니다"라고 적고, 장기적 해법으로 IOMMU + `vfio-pci`를 권장한다.

---

## 3. The Debate

SPDK는 단일 LKML 패치 스레드에서 결정된 설계가 아니다. 2015년 공개 후 10년 동안 프로젝트 문서, 블로그, 학회 논문을 통해 여러 쟁점을 두고 입장을 다듬어 왔다. 아래 인용은 모두 원문을 직접 확인한 것이다.

### 3.1 락 vs 메시지 전달: "데이터를 스레드에 배정한다"

SPDK의 핵심 주장은 공유 데이터를 락으로 보호하지 않고 **데이터를 소유 스레드 하나에 배정하는** 것이다.

> "Instead of placing shared data in a global location that all threads access after acquiring a lock, SPDK will often assign that data to a single thread. When other threads want to access the data, they pass a message to the owning thread to perform the operation on their behalf. ... A message in SPDK consists of a function pointer and a pointer to some context. Messages are passed between threads using a lockless ring."
>
> — SPDK 공식 문서 [Message Passing and Concurrency](https://spdk.io/doc/concurrency.html) (2026-10-14 확인)

해설: 문서는 이 방식이 새롭지 않다고 스스로 밝히고 Erlang과 Go를 예로 든다. 메시지 전달이 직관보다 빠른 이유로는 **캐시 효과**를 든다. 한 코어가 데이터를 독점하면 그 데이터는 해당 코어의 L1/L2에 남아 있을 가능성이 높다. 여러 코어가 락을 두고 경쟁하면 같은 캐시 라인이 코어 사이를 계속 오간다. 문서는 더 극단적인 경우도 설명한다. 읽기가 많고 쓰기가 드문 데이터는 **스레드마다 사본을 두고**, 갱신할 때만 모든 스레드에 메시지를 보낸다. 이 패턴은 `spdk_for_each_channel()`이 구현하며, 메모리를 더 쓰는 대신 연산 효율을 얻는다.

반론도 문서에 함께 적혀 있다. "Limitations of the C Language" 절은 메시지 전달이 비동기 콜백 코드를 낳고, C에는 future/promise가 없어 로직 분기마다 코드가 잘게 쪼개진다고 인정한다. 그래도 SPDK는 "very wide compatibility and portability"를 이유로 C를 유지했다. 대신 콜백 체인은 아래에서 위로 읽히게 함수를 배치하고, 분기나 루프가 있으면 상태 머신을 직접 쓰라고 권한다. 실제로 NVMe-oF TCP target의 `TCP_REQUEST_STATE_*`(NEW, NEED_BUFFER, HAVE_BUFFER, TRANSFERRING_HOST_TO_CONTROLLER, READY_TO_EXECUTE, EXECUTING, EXECUTED, READY_TO_COMPLETE, TRANSFERRING_CONTROLLER_TO_HOST, COMPLETED 등, `lib/nvmf/tcp.c`)가 이 권고를 따른 구조다.

### 3.2 폴링 vs 인터럽트: 원칙에서 선택 사항으로

초기 SPDK 문서는 인터럽트를 원칙적으로 거부했다. [User Space Drivers](https://spdk.io/doc/userspace.html) 문서의 "Interrupts" 절은 현재도 다음과 같이 적혀 있다.

> "SPDK polls devices for completions instead of waiting for interrupts. There are a number of reasons for doing this: 1) practically speaking, routing an interrupt to a handler in a user space process just isn't feasible for most hardware designs, 2) interrupts introduce software jitter and have significant overhead due to forced context switches."
>
> — SPDK 공식 문서 [User Space Drivers](https://spdk.io/doc/userspace.html) (2026-10-14 확인)

해설: 첫 번째 이유는 지금 기준으로 낡았다. VFIO는 MSI-X 벡터를 eventfd로 사용자 공간에 넘길 수 있다. SPDK도 v22.01에 `spdk_pci_device_enable_interrupt()` 계열 실험 API를, v25.05에 다중 벡터용 `spdk_pci_device_enable_interrupts()`와 `spdk_nvme_ctrlr_opts::enable_interrupts`를 추가해 NVMe PCIe 완료를 eventfd로 받는다(CHANGELOG). 두 번째 이유(지터, 강제 컨텍스트 스위치)는 여전히 유효하다. 그래서 SPDK는 "폴링이 기본, 인터럽트는 유휴 시 전력 절약용 선택"이라는 절충을 택했다. 새 [Interrupt Mode](https://spdk.io/doc/interrupt_mode.html) 문서 첫 문단은 이 절충을 그대로 적는다. 기본은 "without ever blocking" 계속 일을 확인하는 루프이고 "This gives the lowest latency but burns 100% CPU"라고 명시한 뒤, interrupt 모드는 일이 없을 때 코어를 재운다고 설명한다.

### 3.3 uio vs vfio: 성능 편의 vs 메모리 안전

장치를 커널 드라이버에서 떼어 낸 뒤 다시 붙일 "더미" 드라이버로 `uio_pci_generic`(또는 out-of-tree `igb_uio`)과 `vfio-pci` 중 무엇을 쓸지도 쟁점이다. SPDK 문서의 입장은 분명하다.

> "This is a future-proof, hardware-accelerated solution for performing DMA operations into and out of a user space process and forms the long-term foundation for SPDK and DPDK's memory management strategy. We highly recommend that applications are deployed using vfio and the IOMMU enabled, which is fully supported today."
>
> — SPDK 공식 문서 [Direct Memory Access (DMA) From User Space](https://spdk.io/doc/memory.html) (2026-10-14 확인)

해설: uio는 IOMMU를 프로그래밍하지 못한다. 그래서 장치가 잘못된 물리 주소에 DMA하면 커널 메모리를 포함한 임의의 메모리가 손상될 수 있다. vfio는 장치를 IOMMU group 단위로 격리하고, `VFIO_IOMMU_MAP_DMA` ioctl로 등록한 범위만 DMA를 허용한다. [System Configuration User Guide](https://spdk.io/doc/system_configuration.html)는 vfio를 쓰면 DPDK 18.11부터 **비특권 사용자**로 실행할 수 있다고 설명하면서, 격리 단위가 IOMMU group이라 group 전체의 권한을 넘겨야 하는 운영상 제약도 함께 적는다. 반대로 일부 장치는 vfio-pci에서 제대로 동작하지 않아 `uio_pci_generic`과 `intel_iommu=off` 또는 `iommu=pt`가 필요하다는 현실도 같은 문서에 있다.

### 3.4 커널 진영의 비판: "단일 사용자의 사치"

커널 쪽의 가장 정량적인 비교는 Samsung과 Meta 저자들(Kanchan Joshi 외, Jens Axboe)이 USENIX FAST '24에 발표한 [I/O Passthru: Upstreaming a flexible and efficient I/O Path in Linux](https://www.usenix.org/conference/fast24/presentation/joshi)다. 7.3절 "Comparison against SPDK"의 결론은 다음과 같다.

> "Overall, I/O Passthru reduces the per-core efficiency gap but is still far from kernel-bypass solutions like SPDK."
>
> — Joshi et al., FAST '24 (2024-02), §7.3, [논문 PDF](https://www.usenix.org/system/files/fast24-joshi.pdf)

해설: 논문은 이 격차의 원인으로 SPDK `perf`가 장치를 독점하는 "single-user luxury"를 누린다는 점, passthrough 경로도 태그 관리·타임아웃 등 block 계층 기능을 쓴다는 점을 든다. 9절에서는 SPDK가 PCI BAR를 한 애플리케이션에 통째로 매핑해 멀티테넌트 배포가 어렵고 "can operate only in polled mode"라고 비판한다. 다만 이 "폴링 전용" 지적은 논문 발표(2024-02) 뒤인 v25.05에서 NVMe PCIe interrupt 모드가 들어오면서 부분적으로 낡았다. 측정 수치(7.55M/10M/4.4M/6M IOPS)와 흔히 인용되는 "SPDK의 99%" 같은 과장이 논문에 없다는 점은 (→ 07/03)에서 다룬다.

### 3.5 프레임워크를 강제할 것인가

SPDK는 자체 이벤트 프레임워크(`lib/event`)를 갖고 있지만 그 사용을 강제하지 않는다. concurrency 문서는 thread 추상화가 시스템 스레드를 **스스로 만들지 않는다**고 강조한다. 하위 프레임워크가 이벤트 루프 안에서 `spdk_thread_poll()`을 반복 호출해 주기만 하면 된다. 그래서 Seastar나 libuv 같은 다른 비동기 프레임워크에도 붙일 수 있다는 것이 문서의 주장이다. 이 결정 때문에 SPDK에는 두 계층의 실행 단위가 생겼다. 하나는 "reactor = 코어당 pthread"이고, 다른 하나는 "spdk_thread = reactor 위에서 옮겨 다닐 수 있는 경량 실행 문맥"이다(4.5절).

---

## 4. Implementation Impact

### 4.1 env 계층: DPDK EAL 위의 얇은 추상화

`include/spdk/env.h`는 DPDK에 직접 의존하지 않는 인터페이스를 정의하고, 기본 구현은 `lib/env_dpdk/`에 있다. 초기화 흐름은 다음과 같다.

```
spdk_env_opts_init(&opts)            // 기본값 채우기
  opts.name / core_mask / shm_id / mem_size / main_core / no_pci /
  hugepage_single_segments / unlink_hugepage / no_huge / iova_mode / base_virtaddr ...
spdk_env_init(&opts)
  └─ build_eal_cmdline(opts)         // lib/env_dpdk/init.c: "--iova-mode=va|pa",
  │                                  //   "--base-virtaddr=0x...", "--huge-unlink", "--legacy-mem" 등
  └─ rte_eal_init(argc, dpdk_args)   // DPDK EAL: hugepage 매핑, PCI 스캔, lcore 정보
  └─ mem_map_init() / vtophys_init() // spdk_mem_map 구성, rte_mem_event_callback_register("spdk", memory_hotplug_cb, ...)
```

**메모리 할당 API.** 장치 DMA용 버퍼는 반드시 `spdk_dma_malloc()`/`spdk_dma_zmalloc()`(구 API), `spdk_malloc()`/`spdk_zmalloc()`에 `SPDK_MALLOC_DMA` 플래그를 주는 방식, 또는 `spdk_mem_register()`로 등록한 메모리여야 한다. NUMA 지정에는 `SPDK_ENV_NUMA_ID_ANY` 같은 값을 쓴다. v25.09에서 deprecated였던 `spdk_env_get_socket_id()`가 제거되고 `spdk_env_get_numa_id()`로 대체됐다(CHANGELOG v25.09).

**`spdk_mem_map`: 2단계 변환 테이블.** `lib/env_dpdk/memory.c`는 x86-64의 48비트(256TiB) 가상 주소 공간을 2MiB 단위로 나눈다. `MAP_256TB_IDX(vfn_2mb)`로 최상위 테이블 인덱스를, `MAP_1GB_IDX(vfn_2mb)`로 1GiB 하위 테이블 인덱스를 구한다. `spdk_mem_map_alloc()`으로 만든 맵마다 이 구조를 갖고, `spdk_mem_map_translate()`는 두 번의 배열 참조로 변환값을 돌려준다. 전역 `vtophys` 맵이 `spdk_vtophys()`의 근거이고, NVMe/RDMA 같은 모듈은 자체 맵(예: RDMA MR 등록)을 같은 메커니즘으로 둔다. 변환 단위는 오랫동안 2MiB(`VALUE_2MB`)였다. v25.09 CHANGELOG에는 "memory registration at a 4KB granularity" 지원이 추가됐다고 적혀 있다.

**IOVA 결정.** IOMMU가 켜져 있고 vfio를 쓰면 SPDK는 `VFIO_IOMMU_MAP_DMA` ioctl(`memory.c`의 `vtophys_iommu_map_dma()` 경로)로 해당 영역을 IOMMU에 등록하고, 보통 IOVA = VA(`--iova-mode=va`)로 쓴다. IOMMU가 없거나 uio를 쓰면 `rte_mem_virt2iova()`, 즉 `/proc/self/pagemap` 기반 물리 주소를 쓴다(`vtophys_get_paddr_pagemap()`). DPDK의 동적 메모리 확장/축소는 `rte_mem_event_callback_register()`로 받은 콜백(`memory_hotplug_cb`)이 `spdk_mem_register`/`unregister`로 반영한다.

**hugepage 없는 실행.** v24.01에서 `--no-huge` 옵션이 추가됐다(CHANGELOG v24.01 "env"). 개발·테스트 편의 기능이고, 물리 주소 안정성은 vfio IOMMU 매핑에 의존한다고 보는 것이 맞다.

| 항목 | uio_pci_generic / igb_uio | vfio-pci (IOMMU on) | vfio-pci (no-IOMMU 모드) |
|---|---|---|---|
| IOMMU 프로그래밍 | 불가 | `VFIO_IOMMU_MAP_DMA`로 범위 등록 | 불가 |
| DMA 주소 | 물리 주소(pagemap) | IOVA(보통 VA와 동일) | 물리 주소 |
| 잘못된 DMA의 영향 | 임의 메모리 손상 가능 | IOMMU fault로 차단 | 임의 메모리 손상 가능 |
| 비특권 실행 | 사실상 불가(pagemap root 필요) | 가능(IOMMU group 권한 위임, DPDK 18.11+) | 불가 |
| 인터럽트 eventfd | 제한적 | MSI-X → eventfd (SPDK interrupt 모드 기반) | 제한적 |
| SPDK 권장 | 호환성 예외용 | **권장** (`scripts/setup.sh` 자동 선택) | 비권장 |

### 4.2 `spdk_thread`: 스택 없는 경량 스레드의 내부

`struct spdk_thread`(`lib/thread/thread.c`, 비공개 정의)의 핵심 필드는 다음과 같다.

- `active_pollers`(TAILQ): 주기 0인 poller. 매 반복마다 실행.
- `timed_pollers`(RB 트리, `next_run_tick` 기준) + `first_timed_poller` 캐시: 주기 poller.
- `paused_pollers`(TAILQ): `spdk_poller_pause()`된 poller.
- `messages`(`struct spdk_ring *`): `spdk_ring_create(SPDK_RING_TYPE_MP_SC, 65536, SPDK_ENV_NUMA_ID_ANY)`로 만든 **multi-producer / single-consumer** 링. 내부 구현은 DPDK `rte_ring`이다.
- `msg_cache`(SLIST) + `msg_cache_count`: 스레드 로컬 메시지 객체 캐시. `SPDK_MSG_MEMPOOL_CACHE_SIZE`(1024)개를 전역 mempool(기본 크기 `SPDK_DEFAULT_MSG_MEMPOOL_SIZE` = 262143)에서 미리 받아 둔다.
- `critical_msg`: 시그널 핸들러처럼 메모리 할당을 할 수 없는 문맥에서 쓰는 단일 슬롯(`spdk_thread_send_critical_msg()`).
- `io_channels`(RB 트리): 이 스레드가 가진 `spdk_io_channel`.
- `in_interrupt`, `fgrp`(`struct spdk_fd_group *`), `msg_fd`(eventfd): interrupt 모드용.
- `cpumask`: 스케줄러가 존중해야 할 허용 코어 집합.
- `lock_count`: 이 스레드가 쥔 `spdk_spinlock` 수(디버그 검사용).

**메시지 전송 경로** (`spdk_thread_send_msg()`, master 기준):

```
spdk_thread_send_msg(thread, fn, ctx)
  ├─ 대상 스레드가 EXITED면 abort()
  ├─ local_thread = 현재 스레드; msg_cache에서 spdk_msg 하나 꺼냄 (없으면 spdk_mempool_get)
  ├─ msg->fn = fn; msg->arg = ctx
  ├─ spdk_ring_enqueue(thread->messages, &msg, 1, NULL)   // MP 안전, lockless
  └─ thread_send_msg_notification(thread)
        └─ interrupt 모드가 전역으로 꺼져 있으면 즉시 return
           대상 스레드가 in_interrupt면 write(msg_fd, 1)   // eventfd로 깨움
```

할당 실패나 enqueue 실패는 오류 코드를 돌려주지 않고 `abort()`한다. 메시지 전달이 시스템의 혈관이라서 실패를 복구 가능한 상황으로 보지 않는다는 뜻이다. 운영자는 mempool 크기(`spdk_thread_lib_init_ext()`의 `msg_mempool_size`, reactor 경로에서는 `spdk_reactors_init(msg_mempool_size)`)를 부하에 맞게 정해야 한다.

**한 번의 폴링 반복** (`thread_poll()`, `spdk_thread_poll()`이 호출):

1. `critical_msg`가 있으면 먼저 실행.
2. `msg_queue_run_batch()`: 링에서 최대 `SPDK_MSG_BATCH_SIZE`(8)개를 꺼내 실행하고, 다 쓴 `spdk_msg`는 로컬 캐시로 되돌린다. 배치 크기를 작게 둔 것은 메시지 폭주 때문에 poller가 굶지 않게 하려는 공정성 장치다.
3. `active_pollers`를 **역순**(`TAILQ_FOREACH_REVERSE_SAFE`)으로 돌며 `thread_execute_poller()`.
4. `first_timed_poller`부터 `now >= next_run_tick`인 timed poller를 RB 트리에서 꺼내 실행하고 다시 넣는다.
5. 반환값 `rc`: 메시지나 poller가 일을 했으면 양수(busy), 아니면 0(idle). poller 함수는 `SPDK_POLLER_BUSY`/`SPDK_POLLER_IDLE`을 돌려줘야 한다. 이 값이 reactor의 `busy_tsc`/`idle_tsc` 통계와 dynamic scheduler의 판단 근거가 된다.

**수명 규칙.** concurrency 문서는 `spdk_io_device_register()` → `spdk_thread_create()` → `spdk_get_io_channel()` → 작업 → `spdk_put_io_channel()` → `spdk_thread_exit()` → `spdk_thread_destroy()` → `spdk_io_device_unregister()` 순서를 요구한다. 즉 스레드는 자신을 쓰는 poller와 channel보다 오래 살아야 한다. `reactor_run()` 종료 경로는 앱 스레드가 아닌데 `spdk_thread_exit()`이 호출되지 않은 스레드를 발견하면 "This will result in a non-zero exit code in a future release"라는 오류 로그를 남긴다(`lib/event/reactor.c`).

### 4.3 poller 등록 API

| API | 의미 |
|---|---|
| `spdk_poller_register(fn, arg, period_us)` | 현재 `spdk_thread`에 poller 등록. `period_us == 0`이면 active, 아니면 timed |
| `spdk_poller_register_named()` / `SPDK_POLLER_REGISTER(fn, arg, period)` | 이름 붙은 등록(매크로는 함수명을 이름으로 사용). `thread_get_pollers` RPC, `spdk_top`에서 식별 |
| `spdk_poller_unregister(&poller)` | 해제(실제 free는 다음 반복에서 `SPDK_POLLER_STATE_UNREGISTERED` 정리) |
| `spdk_poller_pause()` / `spdk_poller_resume()` | 일시 정지 / 재개 |
| `spdk_poller_register_interrupt(poller, cb, arg)` | 이 poller가 interrupt 모드로 전환할 수 있음을 표시하고, 전환 시 호출할 콜백 등록 |

### 4.4 `spdk_io_device` / `spdk_io_channel`: 전역 객체 + 스레드별 컨텍스트

concurrency 문서에 따르면 이 쌍은 원래 "여러 하드웨어 큐를 가진 블록 장치"를 추상화하려고 만들었다. 지금은 "주소로만 식별되는 임의의 포인터(io_device)와, 그에 딸린 스레드별 컨텍스트(io_channel)"로 일반화됐다.

```
spdk_io_device_register(io_device_ptr, create_cb, destroy_cb, ctx_size, name)
   // 전역 RB 트리 g_io_devices에 삽입 (g_devlist_mutex 보호)

ch = spdk_get_io_channel(io_device_ptr)            // 반드시 spdk_thread 위에서 호출
   pthread_mutex_lock(&g_devlist_mutex)
   dev = io_device_get(io_device_ptr)              // RB 트리 조회
   ch  = thread_get_io_channel(thread, dev)        // 이 스레드의 io_channels RB 트리 조회
   if (ch) { ch->ref++; unlock; return ch; }       // 이미 있으면 참조만 증가
   ch = calloc(1, sizeof(*ch) + dev->ctx_size)     // 컨텍스트를 채널 뒤에 붙여 할당
   RB_INSERT(io_channel_tree, &thread->io_channels, ch); dev->refcnt++
   unlock
   create_cb(io_device_ptr, spdk_io_channel_get_ctx(ch))   // 모듈이 큐/qpair 등을 할당
```

중요한 점이 두 가지 있다.

1. **채널 획득은 비싸고 락을 쓴다.** 그래서 bdev 사용자는 `spdk_bdev_get_io_channel(desc)`를 스레드 시작 시 한 번 호출하고 I/O마다 재사용한다. 그 뒤의 I/O 경로(`spdk_bdev_read_blocks(desc, ch, ...)`)는 채널 컨텍스트만 만지므로 락이 없다.
2. **`spdk_for_each_channel(io_device, fn, ctx, cpl)`**은 해당 io_device의 채널을 가진 모든 스레드를 **한 스레드씩 순서대로** 메시지로 방문한다. bdev QoS 한도 변경, reset 시 채널 freeze/unfreeze(bdev 계층은 래퍼 `spdk_bdev_for_each_channel()`을 씀), NVMe-oF subsystem pause 같은 "드물지만 전역적인" 변경이 이 패턴을 쓴다. 3.1절에서 말한 "스레드별 사본 + 메시지로 갱신" 패턴의 구현이다.

### 4.5 이벤트 프레임워크: reactor와 lightweight thread

`lib/event`는 "SPDK 앱"을 만드는 선택적 프레임워크다. [Event Framework](https://spdk.io/doc/event.html) 문서의 정의는 "spawns one thread per core (reactor) and connects the threads with lockless queues"이다.

`struct spdk_reactor`(`include/spdk_internal/event.h`)의 주요 필드는 다음과 같다.

- `threads`: 이 reactor에 배정된 `spdk_lw_thread` 목록(TAILQ). `spdk_lw_thread`는 `spdk_thread`의 컨텍스트 영역에 들어 있는 reactor 쪽 메타데이터다.
- `events`(`struct spdk_ring *`) + `events_fd`: 코어 간 이벤트 큐와 interrupt 모드용 eventfd.
- `tsc_last`, `busy_tsc`, `idle_tsc`: 통계.
- `in_interrupt`, `new_in_interrupt`, `fgrp`, `resched_fd`: interrupt 모드 상태.

메인 루프(`reactor_run()` → `_reactor_run()`, master 기준)는 다음과 같다.

```
reactor_run(reactor):
  pthread 이름을 "reactor_<lcore>"로 바꿈
  while (1):
    if (reactor->in_interrupt) reactor_interrupt_run()      // spdk_fd_group_wait(fgrp, -1): epoll_wait 블로킹
    else                       _reactor_run():
        event_queue_run_batch(reactor)                       // spdk_event_call()로 들어온 이벤트
        for each lw_thread in reactor->threads:
            rc = spdk_thread_poll(thread, 0, reactor->tsc_last)
            rc > 0 ? busy_tsc += Δ : idle_tsc += Δ
            reactor_post_process_lw_thread()                 // 종료/재스케줄 요청 처리
    if (스케줄링 주기 경과 && 이 reactor가 g_scheduling_reactor):
        _reactors_scheduler_gather_metrics()                 // 스케줄러 라운드 시작
    if (g_reactor_state != SPDK_REACTOR_STATE_RUNNING) break
```

**event vs message.** `spdk_event_allocate(lcore, fn, arg1, arg2)` + `spdk_event_call()`은 **코어(reactor)**를 대상으로 하고, `spdk_thread_send_msg()`는 **spdk_thread**를 대상으로 한다. 스레드는 reactor 사이를 옮겨 다닐 수 있으므로, 상위 라이브러리는 거의 항상 thread 메시지를 쓴다. 이벤트는 reactor 관리(스레드 이동, 모드 전환, `spdk_for_each_reactor()`)에 쓰인다.

**앱 수명.** `spdk_app_opts_init()` → `spdk_app_parse_args()` → `spdk_app_start(&opts, start_fn, ctx)`(종료할 때까지 블록) → `spdk_app_stop(rc)`. 주요 `spdk_app_opts` 필드는 `json_config_file`, `rpc_addr`(UNIX 소켓 경로 또는 IP:port), `reactor_mask`, `interrupt_mode`, `shm_id` 등이다. 대표적인 명령행 옵션은 `-m/--cpumask`, `--json`, `--wait-for-rpc`, `--interrupt-mode`, `--no-huge`, `--iova-mode`, `--huge-dir`, `-i/--shm-id`이다(`lib/event/app.c`).

### 4.6 스케줄러와 governor

[Scheduler](https://spdk.io/doc/scheduler.html) 문서와 `lib/event/reactor.c`, `include/spdk/scheduler.h`(`spdk_scheduler_set()`, `spdk_scheduler_register()`, `spdk_scheduler_set_period()`)를 근거로 정리하면 다음과 같다.

- **static(기본)**: 시작 시 `cpumask`를 존중하며 라운드 로빈으로 배치하고 이후 옮기지 않는다. 다른 스케줄러로 바꾼 뒤에는 static으로 되돌릴 수 없다(원래 배치를 저장하지 않으므로).
- **dynamic**(v21.01 실험적 도입): busy = busy_tick / (busy_tick + idle_tick)으로 스레드 부하를 계산한다. active 스레드는 코어에 고르게 나누고 idle 스레드는 main core로 모은다. 스레드가 없는 reactor는 interrupt 모드로 전환하고 governor로 주파수를 낮춘다.
- **governor**: 기본 구현 `dpdk_governor`는 DPDK `rte_power`를 기반으로 한다. SMT 형제 코어는 같은 주파수여야 한다는 제약이 있다.
- 전환은 `framework_set_scheduler` RPC로 하고, 관찰은 `framework_get_reactors`, `thread_get_stats`, `thread_get_pollers` RPC나 `spdk_top`으로 한다.

### 4.7 interrupt 모드: `fd_group`(epoll) 계층

[Interrupt Mode](https://spdk.io/doc/interrupt_mode.html) 문서와 소스를 대조하면 구조는 이렇다.

- `struct spdk_fd_group`은 epoll 인스턴스 하나를 감싼다. `spdk_fd_group_add()`는 `EPOLL_CTL_ADD`, `spdk_fd_group_wait()`는 `epoll_wait()` 후 콜백 실행이다. **중첩**(`spdk_fd_group_nest()`)을 지원해서 자식 그룹의 fd를 루트 epoll로 옮긴다. 그래서 reactor 하나의 `epoll_wait()` 한 번으로 그 위 모든 스레드·서브시스템의 fd를 감시한다.
- 스레드: `msg_fd`(eventfd)에 `thread_interrupt_msg_process`를 등록한다.
- active poller: 자연스러운 fd가 없으므로 eventfd를 하나 만들고, interrupt 모드 진입 시 1을 써서 **항상 readable**로 둔다. 즉 interrupt 모드에서도 계속 돈다. 문서는 이를 "degraded"라고 부른다.
- timed poller: `timerfd`를 `next_run_tick`에 맞춰 arm한다.
- 진짜 이벤트 소스(NVMe CQ의 MSI-X eventfd, vhost kickfd, 소켓 그룹 fd)는 `spdk_interrupt_register()`, `spdk_interrupt_register_fd_group()`, `spdk_poller_register_interrupt()`로 등록한다.
- 놓친 깨움 방지: `SPDK_FD_TYPE_EVENTFD` 핸들러는 프레임워크가 카운터를 먼저 읽어 0으로 만든다. 따라서 일을 다 처리하지 못했으면 eventfd에 다시 써야 한다. 예를 들어 메시지 링에 항목이 남아 있으면 `write(msg_fd, 1)`을 다시 한다.
- 전환: `spdk_reactor_set_interrupt_mode(lcore, new_in_interrupt, cb, arg)`은 다른 reactor의 `notify_cpuset`을 갱신한 뒤(이벤트를 보낼 때 eventfd도 쓰도록), 대상 reactor에서 스레드 fd_group을 nest/unnest하고 각 스레드에 `spdk_thread_set_interrupt_mode()` 메시지를 보낸다.
- 전제: interrupt 모드는 **시작 전에** `spdk_interrupt_mode_enable()` 또는 `--interrupt-mode`로 켜야 한다. 그래야 fd_group 인프라가 만들어진다. Linux 전용이다.

**도입 연표 (CHANGELOG 및 릴리스 공지 기준)**

| 릴리스 | interrupt 관련 변화 |
|---|---|
| v20.10 | `fd_group`(epoll) 유틸리티와 실험적 thread interrupt API 추가. "a very small subset"만 지원 |
| v21.01 | 실험적 `dynamic` 스케줄러: 유휴 reactor를 interrupt 모드로, `dpdk_governor`로 주파수 조절 |
| v21.04 | `spdk_thread_set_interrupt_mode()`, `spdk_poller_register_interrupt()` 추가 |
| v22.05 | vfio-user transport adaptive interrupt(`disable_adaptive_irq`) |
| v24.01 | 전역 `--interrupt-mode` 명령행 옵션(모든 구성요소가 지원할 때만 유효) |
| v24.09 | NVMe-oF **TCP** target interrupt 모드 |
| v25.05 | NVMe 라이브러리/NVMe bdev의 **PCIe** interrupt 모드(primary process 한정), `spdk_nvme_ctrlr_opts::enable_interrupts`, `spdk_nvme_poll_group_wait()` |
| v26.01 | NVMe-oF **RDMA** target interrupt 지원 |
| v26.09 | NVMe **RDMA initiator** interrupt 모드(`spdk_nvme_qpair_get_fd()`로 완료 이벤트 대기) |

**서브시스템별 지원 (Interrupt Mode 문서 표, 2026-10-14 확인)**

| 서브시스템 | 지원 | 비고 |
|---|---|---|
| NVMe bdev (PCIe) | 예 | VFIO/UIO가 큐별 interrupt eventfd 제공 |
| NVMe bdev (fabrics) | 아니오(문서 기준) | TCP/RDMA는 `-ENOTSUP`. 단 v26.09 릴리스 노트는 RDMA initiator 지원을 발표해 문서 표가 늦게 갱신됐을 수 있음 [추측/미확인] |
| bdev_aio | 예 | 자체 eventfd |
| vhost-blk | 예 | 게스트 kickfd 등록 |
| vhost-scsi | 부분 | 범용 active-poller eventfd에 의존 |
| NVMe-oF target TCP / RDMA | 예 | |
| NVMe-oF target FC | 아니오 | poll group 생성 실패 |
| NVMe-oF target vfio-user | 예 | `disable_mappable_bar0` 필요 |
| sock posix / sock uring | 예 / 아니오 | uring은 init 시 `-ENOTSUP` |

### 4.8 JSON-RPC 제어 평면

[JSON-RPC](https://spdk.io/doc/jsonrpc.html) 문서에 따르면 SPDK는 JSON-RPC 2.0 서버를 내장하고, 기본 주소는 `SPDK_DEFAULT_RPC_ADDR` = `/var/tmp/spdk.sock`(UNIX 소켓, `include/spdk/init.h`)이다.

- 메서드 등록: `SPDK_RPC_REGISTER("bdev_malloc_create", rpc_fn, SPDK_RPC_RUNTIME)`. 매크로가 생성자 함수 안에서 `spdk_rpc_register_method()`를 호출한다. 상태 마스크 `SPDK_RPC_STARTUP`(0x1)은 `--wait-for-rpc`로 멈춘 초기화 전 단계에서, `SPDK_RPC_RUNTIME`(0x2)은 서브시스템 초기화 후에 호출할 수 있다. 상태가 맞지 않으면 오류 코드 `-1`("Invalid state")을 돌려준다.
- 응답: 핸들러가 `spdk_jsonrpc_begin_result()`/`spdk_jsonrpc_end_result()` 또는 `spdk_jsonrpc_send_error_response()`를 호출한다. 표준 오류 코드(-32600/-32601/-32602/-32603/-32700)를 쓴다.
- 운영 흐름: `spdk_tgt --wait-for-rpc` → 초기 옵션 RPC(예: `bdev_nvme_set_options`, `framework_set_scheduler`) → `framework_start_init` → 런타임 RPC(`bdev_nvme_attach_controller`, `nvmf_create_transport` 등) → `save_config`로 JSON 덤프 → 다음 기동 때 `--json`으로 재생.
- v26.01 릴리스는 "JSON-RPC schema validation"을, v26.05는 JSON-RPC 스키마 생성과 클라이언트 배칭을 주요 기능으로 발표했다(spdk.io 블로그 릴리스 공지).

RPC 처리도 특정 `spdk_thread`(앱 스레드)에서 poller로 돈다. 그래서 무거운 RPC 핸들러가 그 스레드의 다른 작업을 지연시킬 수 있다. 데이터 경로 스레드와 관리 스레드를 분리하는 것이 운영 관행이다.

### 4.9 그래도 락이 필요할 때: `spdk_spinlock`

concurrency 문서는 POSIX 락이 SPDK 경량 스레드 사이에서 올바르게 동작하지 않는다고 지적하고 `struct spdk_spinlock`(`spdk_spin_init`/`spdk_spin_lock`/`spdk_spin_unlock`)을 쓰라고 한다. `thread.h` 주석에 따르면 spdk_thread는 off-CPU일 때 다른 pthread로 옮겨질 수 있다. 그래서 poller나 이벤트에서 락을 잡은 채 반환한 뒤 나중에 푸는 것은 금지되고, 그렇게 쓰면 프로그램이 abort한다. 락을 쥔 상태로 양보할 수 없다는 규칙은 커널의 "스핀락을 쥐고 sleep 금지"와 같은 구조의 제약이다.

### 4.10 커널 블록 스택과의 구조 비교

| 관점 | Linux 커널 (blk-mq + nvme-pci) | SPDK (bdev + nvme) |
|---|---|---|
| 실행 단위 | 커널 스레드/프로세스 문맥, 선점 가능 | reactor(pthread, 코어 고정) 위 `spdk_thread`, 협력적 스케줄링 |
| HW 큐 배정 | CPU 코어 ↔ `blk_mq_hw_ctx` 매핑 | 스레드 ↔ `spdk_nvme_qpair` 1:1 (애플리케이션 책임) |
| 완료 통지 | MSI-X 인터럽트(선택적 `REQ_POLLED`/io_uring IOPOLL) | 기본 폴링, 선택적 eventfd(interrupt 모드) |
| 동기화 | per-cpu 구조 + 태그 `sbitmap` + 락/RCU | 소유 스레드 + lockless MP/SC ring 메시지, 제어 경로만 mutex |
| 교차 스레드 작업 | IPI, workqueue | `spdk_thread_send_msg()`, `spdk_for_each_channel()` |
| 메모리 | 페이지 캐시/`bio_vec`, IOMMU는 DMA API가 관리 | hugepage pin 메모리, `spdk_mem_map` 2단계 테이블, `VFIO_IOMMU_MAP_DMA` |
| 설정 인터페이스 | sysfs/configfs/ioctl | JSON-RPC 2.0 (`/var/tmp/spdk.sock`), JSON 설정 재생 |
| 장치 공유 | 다수 프로세스·파일시스템 공유 | 장치를 한 앱(또는 같은 shm_id의 primary/secondary 그룹)이 독점 |

### 4.11 역사와 거버넌스

| 시점 | 사건 | 출처 |
|---|---|---|
| 2013 | Intel 내부 프로젝트로 시작 | spdk.io 블로그 [120 Million I/O Per Second with a Standard 2U Intel® Xeon® System](https://spdk.io/news/2023/02/01/nvme-120m-iops/) (2023-02-01) |
| 2015-07-13 | GitHub `spdk/spdk` 저장소 생성 | GitHub API `created_at` |
| 2015 | 오픈소스 커뮤니티 시작(같은 2023 블로그: "When Intel kicked off the SPDK Open-Source Community in 2015"). `v1.0.0` 태그 커밋 날짜는 2015-12-07. CHANGELOG는 v1.0.0을 "initial open source release"로 기술 | CHANGELOG.md, GitHub |
| 2016-03-02 | Ben Walker, "Introduction to the Storage Performance Development Kit" 블로그: 첫 공개 구성요소는 NVMe 드라이버 | [spdk.io 블로그](https://spdk.io/news/2016/03/02/spdk_intro/) |
| v16.06 | NVMf 사용자 공간 target(이때부터 YY.MM 버전 체계) | CHANGELOG |
| v16.12 | NVMe-oF host, hotplug, multi-process | CHANGELOG |
| v17.03 / v17.07 / v17.10 | blobstore + vhost-scsi / vhost-blk + GPT / Logical Volumes | CHANGELOG |
| v19.01 | NVMe-oF TCP transport | CHANGELOG |
| 2021~2023 | 단일 시스템 80M IOPS(2021), 120M IOPS(2023, 2U Xeon 8480+ ×2, P5800X ×24, 512B random read; 1코어 13.91M) | spdk.io 블로그 |
| 2024-12-05 | Intel, SPDK를 2025년 Linux Foundation으로 이전하고 투자를 접는다고 발표 | [Intel's SPDK Transition to the Linux Foundation](https://spdk.io/news/2024/12/05/LF/) |
| 2024-12 | Intel CI 종료(12-17), Gerrit 이전을 위해 중단(12-19). 이전 기간 동안 master 병합 중단 | [Updates on SPDK Linux Foundation Transition](https://spdk.io/news/2024/12/16/transition/) |
| 2025-05-29 | v25.05 LTS: LF 이전 후 첫 릴리스, TSC 체제, 오픈 SPDK-CI | [v25.05 릴리스 공지](https://spdk.io/release/2025/05/29/v25.05_release/) |
| 2026-01-28 / 2026-09-24 | v26.01 LTS(1년 지원) / v26.09 | spdk.io 블로그 |

**릴리스 주기.** 태그와 블로그 기준으로 보면 2018~2021년은 연 4회(예: 21.01/21.04/21.07/21.10), 2022~2024년은 연 3회(1월·5월·9월)였다. LF 이전 시기에는 **25.01이 없다**(24.09 다음이 25.05). 이후 다시 1월·5월·9월 주기다(25.09, 26.01, 26.05, 26.09). LTS로 공식 확인한 것은 v25.05("supported until SPDK v26.01 LTS")와 v26.01("supported for 1 year")이다. 그 이전의 LTS 지정 관행(예: 매년 .01이 LTS였는지)은 이 문서 작성 중 원문으로 확인하지 못했다 [추측/미확인].

**리뷰 프로세스.** [SPDK Development](https://spdk.io/development/) 페이지 기준으로 코드는 BSD 3-clause(일부 커널 모듈은 BSD/GPLv2 이중)이고, GitHub는 미러이며 리뷰는 Gerrit(`review.spdk.io`)에서 한다. 병합에는 보통 core maintainer의 +2 두 개가 필요하고, 저자는 자기 패치에 +1/+2를 줄 수 없다.

---

## 5. Primary References

- [What is SPDK](https://spdk.io/doc/about.html): 세 가지 핵심 기법 정의
- [Message Passing and Concurrency](https://spdk.io/doc/concurrency.html): spdk_thread, poller, io_device/io_channel, spdk_spinlock, C 언어 한계
- [Event Framework](https://spdk.io/doc/event.html): reactor/event/poller, `spdk_app_start`
- [Interrupt Mode](https://spdk.io/doc/interrupt_mode.html): fd_group 중첩, 모드 전환, 서브시스템 지원 표
- [Scheduler](https://spdk.io/doc/scheduler.html): static/dynamic, governor
- [Direct Memory Access (DMA) From User Space](https://spdk.io/doc/memory.html): pinning, hugepage, IOMMU
- [User Space Drivers](https://spdk.io/doc/userspace.html): uio/vfio, 폴링 근거, 큐-스레드 배정
- [System Configuration User Guide](https://spdk.io/doc/system_configuration.html): IOMMU, 비특권 실행, hugetlbfs
- [JSON-RPC](https://spdk.io/doc/jsonrpc.html): 오류 코드, rpc.py
- [SPDK Development](https://spdk.io/development/): 라이선스, Gerrit, 리뷰 규칙
- 소스: [include/spdk/thread.h](https://github.com/spdk/spdk/blob/master/include/spdk/thread.h), [lib/thread/thread.c](https://github.com/spdk/spdk/blob/master/lib/thread/thread.c), [lib/event/reactor.c](https://github.com/spdk/spdk/blob/master/lib/event/reactor.c), [include/spdk/env.h](https://github.com/spdk/spdk/blob/master/include/spdk/env.h), [lib/env_dpdk/memory.c](https://github.com/spdk/spdk/blob/master/lib/env_dpdk/memory.c), [CHANGELOG.md](https://github.com/spdk/spdk/blob/master/CHANGELOG.md)
- [10.39M Storage I/O Per Second From One Thread](https://spdk.io/news/2019/05/06/nvme/) (Ben Walker, Jim Harris, 2019-05-06)
- [120 Million I/O Per Second with a Standard 2U Intel® Xeon® System](https://spdk.io/news/2023/02/01/nvme-120m-iops/) (John Kariuki, 2023-02-01)
- [Introduction to the Storage Performance Development Kit](https://spdk.io/news/2016/03/02/spdk_intro/) (Ben Walker, 2016-03-02)
- [Intel's SPDK Transition to the Linux Foundation](https://spdk.io/news/2024/12/05/LF/) (2024-12-05)
- [Updates on SPDK Linux Foundation Transition](https://spdk.io/news/2024/12/16/transition/) (Jim Harris, 2024-12-16)
- [SPDK v25.05: NVMe PCIe interrupt mode, DIF insert/strip, mlx5 accel platform driver](https://spdk.io/release/2025/05/29/v25.05_release/) (2025-05-29)
- [I/O Passthru: Upstreaming a flexible and efficient I/O Path in Linux](https://www.usenix.org/conference/fast24/presentation/joshi) (Joshi et al., USENIX FAST '24)
- [1. Environment Abstraction Layer (EAL) Library](https://doc.dpdk.org/guides/prog_guide/env_abstraction_layer.html) (DPDK 문서, hugepage/IOVA 모드)
- [7. Linux Drivers](https://doc.dpdk.org/guides/linux_gsg/linux_drivers.html) (DPDK 문서, vfio-pci/uio 바인딩)
