# IRQ affinity, 큐 매핑, CPU 격리: MSI-X managed interrupt에서 blk-mq 큐 맵, NAPI·RSS, 인터럽트 병합까지

> 기준: Linux `master`(v7.3-rc7). 이름과 동작은 로컬 트리(v7.2-rc5+76, 커밋 `11028ab62899e`)의 `kernel/irq/{affinity,manage,cpuhotplug,proc}.c`, `lib/group_cpus.c`, `include/linux/interrupt.h`, `include/linux/sched/isolation.h`, `block/blk-mq-cpumap.c`, `block/blk-mq.c`, `drivers/nvme/host/pci.c`, `drivers/nvme/target/admin-cmd.c`, `net/core/net-sysfs.c`, `include/uapi/linux/netdev.h`, `Documentation/core-api/irq/managed_irq.rst`, `Documentation/networking/{napi,scaling}.rst`에서 grep으로 확인했다. `enum hk_type`은 git.kernel.org master(v7.3-rc7)에서 다시 대조했다. 도입 버전은 `git log -S`로 찾은 커밋에 `git describe --contains`를 적용해 고정했다.

## 1. Verdict

고성능 I/O에서 인터럽트 문제는 "인터럽트가 많다"가 아니라 **"인터럽트가 어느 CPU에서, 어느 큐의 완료를, 언제 처리하느냐"**다. 리눅스는 스토리지와 네트워크에서 서로 다른 답을 냈다.

1. **스토리지는 커널이 결정한다(managed interrupt).** NVMe·virtio·SCSI HBA는 `pci_alloc_irq_vectors_affinity(..., PCI_IRQ_AFFINITY, &affd)`로 벡터를 받는다. 커널은 `irq_create_affinity_masks()` → `group_cpus_evenly()`로 NUMA·클러스터를 고려해 CPU 집합을 나누고, 각 벡터에 `is_managed`를 붙인다. 이 IRQ의 `/proc/irq/N/smp_affinity`는 쓰기 권한이 없고, 쓰려 하면 `-EPERM`이다(`irq_can_set_affinity_usr()`). 그래서 irqbalance 같은 사용자 공간 밸런서가 이 IRQ를 옮길 수 없다. blk-mq는 같은 마스크를 그대로 써서 CPU→hctx 맵을 만든다(6.14+ `blk_mq_map_hw_queues()`, 그 전에는 `blk_mq_pci_map_queues()`). 따라서 **제출 CPU = 완료 IRQ CPU**가 구조적으로 보장된다.
2. **네트워크는 사용자가 결정한다.** 트리에서 `drivers/net`이 `PCI_IRQ_AFFINITY`를 쓰는 곳은 wangxun `libwx` 하나뿐이다. NIC는 `ethtool -L`로 채널 수를, `ethtool -X`로 RSS 간접 테이블을, sysfs로 RPS/RFS/XPS를 런타임에 바꾼다. IRQ affinity는 irqbalance나 운영자가 정한다. 6.15부터는 코어가 IRQ affinity와 aRFS rmap을 저장·복원하는 `netif_enable_irq_affinity()`/`irq_affinity_auto`가 생겼다.
3. **CPU hotplug에서 managed IRQ는 "옮기지 않고 끈다".** 마스크의 마지막 CPU가 내려가면 IRQ는 `IRQD_MANAGED_SHUTDOWN`으로 꺼지고 마스크는 그대로 남는다(4.13, `c5cb83bb337c`). 이것이 안전하려면 그 전에 큐가 비어 있어야 한다. 5.8의 `blk_mq_hctx_notify_offline()`(`bf0beec0607d`)이 `CPUHP_AP_BLK_MQ_ONLINE` 단계에서 `BLK_MQ_S_INACTIVE`를 세우고 in-flight 요청을 비운다.
4. **CPU 격리와 managed IRQ의 충돌은 아직 부분적으로만 풀렸다.** `isolcpus=managed_irq,<list>`(5.6, `11ea68f553e2`)는 best-effort다. 마스크에 온라인 housekeeping CPU가 있을 때만 격리 CPU를 피한다. NVMe가 격리 CPU에 큐를 아예 만들지 않게 하는 Daniel Wagner의 "blk: honor isolcpus configuration"(`isolcpus=io_queue`) 시리즈는 일부 헬퍼(`blk_mq_num_possible_queues()`, 6.17)만 병합됐다. v7.3-rc7의 `enum hk_type`에는 `HK_TYPE_IO_QUEUE`가 없다.
5. **"폴링 큐"와 "읽기/쓰기 분리 큐"는 IRQ 예산의 재배분이다.** nvme `poll_queues`·`write_queues`(5.0, Jens Axboe)는 하드웨어 큐를 `HCTX_TYPE_POLL`/`HCTX_TYPE_READ`/`HCTX_TYPE_DEFAULT` 세트로 나눈다. 폴링 큐는 IRQ 벡터를 쓰지 않으므로 `blk_mq_map_queues()`로 매핑된다. 인터럽트 큐 세트는 `irq_affinity.calc_sets = nvme_calc_irq_sets`로 각각 전체 CPU에 퍼진다.
6. **인터럽트 병합은 장치 종류마다 쓸모가 다르다.** NIC의 `ethtool -C`(adaptive-rx 포함)와 NAPI의 `gro_flush_timeout`/`napi_defer_hard_irqs`, 6.13의 `irq-suspend-timeout`은 일상적인 튜닝 수단이다. NVMe의 Interrupt Coalescing(Feature 08h)은 PCIe 컨트롤러 필수 기능이지만 aggregation time이 100µs 단위다. 그래서 10µs급 장치에서는 쓸 수 없다고 OSDI '21 cinterrupts 논문이 지적했다. Linux nvme 호스트 드라이버는 이 기능을 설정하지 않는다.

---

## 2. Problem Statement

### 2.1 인터럽트 하나가 지불하는 비용

NVMe 4KiB 읽기의 완료 경로는 "MSI-X 메시지 → 해당 CPU의 IDT 벡터 → `nvme_irq()` → CQ 순회 → `blk_mq_complete_request()` → (필요하면 IPI/softirq) → bio 완료 → 깨우기"다. 여기서 비용이 커지는 경우는 세 가지다.

- **원격 완료**: IRQ가 제출 CPU가 아닌 CPU에서 처리되면 `struct request`, 태그 비트맵, 사용자 버퍼 메타데이터가 캐시 라인 단위로 건너간다. blk-mq는 `QUEUE_FLAG_SAME_COMP`(sysfs `rq_affinity`=1)일 때 캐시를 공유하지 않는 CPU로 IPI를 보내 완료를 넘긴다. 이 IPI 자체가 추가 비용이다.
- **간섭**: 지연에 민감한 애플리케이션 스레드가 있는 CPU에 다른 장치의 IRQ가 떨어지면 꼬리 지연이 커진다. DPDK/SPDK 폴링 코어, 실시간 작업, `nohz_full` 코어가 대표적이다.
- **IRQ 폭주**: 작은 I/O가 수백만 IOPS로 들어오면 완료 하나당 인터럽트 하나로는 CPU가 인터럽트 진입·탈출에 묶인다. 병합(coalescing)과 폴링은 이 비용을 지연과 맞바꾼다.

### 2.2 벡터 공간과 CPU 수

x86은 CPU당 256개의 IDT 벡터만 있고, 그중 일부는 커널이 예약한다. 128코어 서버의 NVMe 하나가 큐당 IRQ를 원하면 128개 벡터가 필요하다. `Documentation/core-api/irq/managed_irq.rst`(7.1에서 추가)는 문제가 평소가 아니라 **suspend나 대량 CPU offline 때** 생긴다고 설명한다. 보조 CPU가 모두 내려가면 일반 IRQ는 남은 CPU 하나로 몰리고, 그 CPU의 벡터가 고갈되면 suspend가 실패한다. managed IRQ는 "마지막 CPU가 내려가면 끈다"는 규칙으로 이 문제를 피한다.

### 2.3 큐 수 < CPU 수

NVMe 컨트롤러는 보통 수십~128개의 I/O 큐를 지원한다. CPU가 더 많으면 여러 CPU가 하나의 hctx를 공유해야 한다. 이때 "어떤 CPU들을 묶을 것인가"가 NUMA 지역성과 캐시 공유를 좌우한다. 2단계 맵(sw ctx → hw ctx)의 일반 구조는 02/01에서 다뤘다(→ 02/01). 이 문서는 이 맵이 **IRQ affinity에서 파생된다**는 점과 그 결과를 다룬다.

### 2.4 네트워크의 다른 제약

NIC는 스토리지와 달리 수신이 **비요청(unsolicited)**이다. 어떤 CPU가 패킷을 받을지는 하드웨어 해시(RSS)가 정하고, 그 CPU가 애플리케이션 스레드가 있는 CPU라는 보장은 없다. 그래서 네트워크는 RPS(소프트웨어 해시 분산), RFS(소켓을 읽는 CPU로 조향), aRFS(하드웨어 n-tuple 필터로 RFS 가속), XPS(송신 큐 선택)라는 별도의 조향 계층이 필요하다. NAPI는 "IRQ 한 번 → 폴링으로 배치 처리"라는 병합 모델을 소프트웨어로 제공한다. 이 처리를 softirq에서 할지 커널 스레드에서 할지가 2020년대의 쟁점이었다.

---

## 3. The Debate

### 3.1 누가 IRQ affinity를 정하는가: 커널 vs 사용자 공간

2016년 이전에는 드라이버가 `pci_enable_msix_range()`로 벡터를 받고 `irq_set_affinity_hint()`로 "힌트"만 주었다. 실제 배치는 irqbalance가 했다. 그 결과 blk-mq의 CPU→큐 맵과 IRQ 배치가 따로 놀았다. 큐 3번에 묶인 CPU에서 제출한 I/O의 완료가 전혀 다른 소켓에서 처리될 수 있었다. Christoph Hellwig와 Thomas Gleixner가 이 모델을 뒤집었다.

| 버전 | 커밋 | 변화 |
|---|---|---|
| 4.8 | `9c2555835bb3` (Thomas Gleixner) | `IRQD_AFFINITY_MANAGED`: 커널이 관리하는 affinity 플래그 |
| 4.8 | `4fe0d154880b` (Christoph Hellwig) | `pci_alloc_irq_vectors()`의 `PCI_IRQ_AFFINITY` 플래그 |
| 4.10 | `402723ad5c62` (Christoph Hellwig) | `pci_alloc_irq_vectors_affinity()` + `struct irq_affinity`(pre/post vectors) |
| 4.13 | `c5cb83bb337c` (Thomas Gleixner) | CPU hotplug에서 managed IRQ는 이동 대신 shutdown |
| 5.0 | `6da4b3ab9a6e` (Jens Axboe) | `nr_sets`/`set_size[]`: 한 장치에 여러 IRQ 세트 |
| 5.1 | `c66d4bd110a1` (Ming Lei) | `calc_sets` 콜백: 할당 가능한 벡터 수에 맞춰 세트 재계산 |
| 5.6 | `11ea68f553e2` (Ming Lei) | `isolcpus=managed_irq` |
| 5.8 | `bf0beec0607d` (Ming Lei) | blk-mq: hctx의 마지막 CPU가 내려가기 전에 I/O drain |
| 6.3 | `f7b3ea8cf72f` (Ming Lei) | 분산 알고리즘을 `lib/group_cpus.c`의 `group_cpus_evenly()`로 분리 |
| 6.14 | `1452e9b470c9` (Daniel Wagner) | `blk_mq_map_hw_queues()`: 버스별 `*_map_queues` 헬퍼 통합 |
| 7.0 | `89802ca36c96` (Wangyang Guo) | `group_cpus_evenly()` 클러스터 인식 |
| 7.1 | `bb6a85b4b652` (Sebastian Andrzej Siewior) | `Documentation/core-api/irq/managed_irq.rst` |

이 모델의 대가는 **사용자 제어권 상실**이다. Ming Lei의 5.6 커밋 메시지는 이 사실을 전제로 시작한다.

> "The affinity of managed interrupts is completely handled in the kernel and cannot be changed via the /proc/irq/* interfaces from user space. As the kernel tries to spread out interrupts evenly accross CPUs on x86 to prevent vector exhaustion, it can happen that a managed interrupt whose affinity mask contains both isolated and housekeeping CPUs is routed to an isolated CPU."
>
> — Ming Lei, [11ea68f553e2 "genirq, sched/isolation: Isolate from handling managed interrupts"](https://github.com/torvalds/linux/commit/11ea68f553e2) (2020-01-20, v5.6)

해설: 이 문장이 irqbalance와 managed IRQ의 관계를 정리한다. 커널은 `/proc/irq/N/smp_affinity`를 만들 때 `irq_can_set_affinity_usr()`가 거짓이면 쓰기 비트(`S_IWUSR`)를 주지 않는다. 쓰기 경로 `write_irq_affinity()`도 `-EPERM`을 반환한다. 따라서 irqbalance가 NVMe 큐 IRQ를 옮기지 못하는 것은 irqbalance의 정책이 아니라 커널 인터페이스의 결과다. irqbalance가 managed IRQ를 내부적으로 어떻게 식별하고 건너뛰는지는 irqbalance 버전마다 다를 수 있다 [추측/미확인]. 운영상 결론은 같다. NVMe IRQ 배치를 바꾸려면 IRQ가 아니라 **CPU 집합**(isolcpus, hotplug, 큐 수)을 바꿔야 한다.

### 3.2 hotplug에서의 계약: "드라이버가 먼저 큐를 멈춘다"

managed IRQ를 shutdown하려면 그 IRQ로 완료가 더 오지 않아야 한다. Ming Lei의 5.8 커밋 메시지는 Gleixner가 처음부터 내건 조건을 인용한다.

> "That was the constraint of managed interrupts from the very beginning: The driver/subsystem has to quiesce the interrupt line and the associated queue _before_ it gets shutdown in CPU unplug and not fiddle with it until it's restarted by the core when the CPU is plugged in again."
>
> — Thomas Gleixner의 발언, Ming Lei의 [bf0beec0607d "blk-mq: drain I/O when all CPUs in a hctx are offline"](https://github.com/torvalds/linux/commit/bf0beec0607d) 커밋 메시지에 인용 (2020-05-29, v5.8)

해설: 5.8 이전의 blk-mq는 이 계약을 지키지 못했다. 기존의 `CPUHP_BLK_MQ_DEAD`는 CPU가 이미 내려간 뒤에 실행되는 단계여서, 마지막 CPU가 사라질 때 hctx에 남은 요청의 완료 IRQ가 꺼진 채 타임아웃을 기다릴 수 있었다. 해결책은 CPU가 내려가기 **전**에 도는 `CPUHP_AP_BLK_MQ_ONLINE` 단계를 추가하는 것이었다. 이 단계에서 해당 hctx를 비활성으로 표시하고 in-flight 요청이 끝나기를 기다린다. dm-rq와 loop처럼 다른 큐 위에 쌓이는 드라이버는 `BLK_MQ_F_STACKING`으로 이 drain에서 빠졌다.

### 3.3 CPU 격리: `managed_irq`는 충분한가

`isolcpus=managed_irq`는 IRQ의 **유효 대상(effective affinity)**만 바꾼다. 커널은 여전히 격리 CPU를 포함한 모든 CPU에 큐를 만들고, 격리 CPU에서 제출한 I/O는 그 CPU의 큐 IRQ를 받는다. 실시간·통신 워크로드는 격리 CPU에 큐 자체가 없기를 원한다. 큐가 있으면 커널 스레드나 실수로 실행된 프로세스의 I/O가 격리 CPU에 인터럽트를 만든다. Daniel Wagner의 시리즈는 이 요구에서 나왔다.

> "The nvme-pci driver is ignoring the isolcpus configuration. There were several attempts to fix this in the past [1][2]. This is another attempt but this time trying to address the feedback and solve it in the core code."
>
> — Daniel Wagner, [blk: honor isolcpus configuration](https://lwn.net/Articles/1004820/) v5 cover letter (2025-01-10)

해설: 같은 cover letter는 새 `isolcpus=io_queue` 옵션이 정말 필요한지, 기존 `managed_irq`로 충분한지 스스로 묻는다. 핵심은 `group_cpus_evenly()`가 housekeeping CPU만으로 그룹을 만들게 하는 것이다. 그러면 격리 CPU는 어떤 큐 마스크에도 처음부터 들어가지 않는다. 반대 논거는 hotplug와의 상호작용이다. 격리 CPU만 남는 상황에서 그 CPU들이 I/O를 할 큐가 없으면 I/O가 멈춘다. 2026년 10월 기준으로 병합된 것은 준비 작업뿐이다. `blk_mq_num_possible_queues()`/`blk_mq_num_online_queues()`(`3f27c1de5df2`, 6.17), nvme-pci의 해당 헬퍼 사용(`4082c98c1fef`), `group_cpus_evenly()`가 초기화한 마스크 수를 반환하도록 한 변경(`b6139a6abf67`)이다. `HK_TYPE_IO_QUEUE`와 `io_queue` 옵션은 master에 없다.

### 3.4 폴링 큐와 읽기/쓰기 분리: IRQ 세트의 재배분

Jens Axboe는 2018년 5.0 사이클에서 blk-mq에 다중 큐 맵(`HCTX_TYPE_DEFAULT/READ/POLL`, `e20ba6e1da02` Christoph Hellwig)을 넣고 NVMe에 두 가지 용도를 붙였다. `write_queues` 커밋의 동기는 NVMe의 기본 중재 방식이다.

> "NVMe does round-robin between queues by default, which means that sharing a queue map for both reads and writes can be problematic in terms of read servicing. It's much easier to flood the queue with writes and reduce the read servicing."
>
> — Jens Axboe, [3b6592f70ad7 "nvme: utilize two queue maps, one for reads and one for writes"](https://github.com/torvalds/linux/commit/3b6592f70ad7) (2018-10-31, v5.0)

해설: 읽기와 쓰기를 다른 SQ 세트에 넣으면 컨트롤러의 큐 간 round-robin이 읽기 큐에 공정한 몫을 준다. 쓰기 폭주가 같은 SQ 안에서 읽기를 굶기지 못한다. 다만 **같은 CPU**에서 읽기용·쓰기용 hctx가 각각 생기므로 IRQ 벡터 수가 늘어난다. 벡터가 모자라면 `nvme_calc_irq_sets()`가 `write_queues`를 줄인다. `poll_queues` 커밋(`4b04cc6a8f86`)은 "And now we finally have poll support without triggering interrupts!"라고 썼다. 이 커밋에서 기본값은 폴링 큐 1개였지만, 2주 뒤 `a4668d9ba4be` "nvme: default to 0 poll queues"(v5.0-rc 주기)가 0으로 바꿨다. 따라서 릴리스된 v5.0부터 현재까지 기본값은 0이다. 폴링 큐와 `REQ_POLLED`의 의미는 02/03에서 다뤘다(→ 02/03).

### 3.5 NVMe 인터럽트 병합: 표준은 있지만 쓸 수 없다

NVMe는 Interrupt Coalescing(Feature 08h)을 표준화했다. 하지만 Tai, Smolyar, Wei, Tsafrir의 OSDI '21 논문 "Optimizing Storage Performance with Calibrated Interrupts"는 이 기능이 실용적이지 않다고 지적한다. 근거는 두 가지다. 첫째, aggregation time의 단위가 100µs라서 원래 10µs 걸리는 작은 요청이 100µs 지연된다(논문의 실험 환경에서 10배). 둘째, threshold와 timeout이 정적이라 부하가 threshold를 채우지 못하는 순간 모든 완료가 timeout만큼 늦어진다. 실험 환경은 Intel Optane DC P4800X 375GB, Xeon E5-2660 v4, Linux 5.0.8이다. 하드웨어 인터럽트는 전용 코어가 IPI로 흉내 내는 방식으로 에뮬레이션했다. 논문은 요청 단위로 "지연 민감" 비트를 주는 2비트 인터페이스 변경(cinterrupts)을 제안했다. 초록 기준으로 처리량 최대 35% 증가와 CPU 사용 최대 30% 감소(기존 인터럽트 방식 대비), 그리고 인터럽트 병합을 쓰는 경우 대비 지연 최대 37% 감소를 보고했다. Linux nvme 호스트 드라이버는 Feature 08h를 설정하지 않는다. nvmet은 이 기능을 PCI 컨트롤러에서만 받는다. 소스 주석은 "not supported for fabrics controllers and mandatory for PCI controllers"라고 쓴다.

### 3.6 softirq냐 kthread냐: threaded NAPI

NAPI 폴링은 전통적으로 `NET_RX_SOFTIRQ`에서 돈다. softirq 시간은 스케줄러가 그 CPU의 부하로 제대로 보지 못한다. Wei Wang(Google)의 "implement kthread based napi poll"(v10, 2021-02-04)은 NAPI마다 커널 스레드를 두는 방안을 냈고, 5.12에 `29863d41bb6e`로 병합됐다. cover letter의 측정 조건은 다음과 같다. 56 하이퍼스레드 호스트, 100Gbps NIC(rx 큐 8개, 단일 NUMA 노드), tcp_rr 1000 flow, RPS/RFS 끔, 스레드 고정 없음. 결과는 다음과 같다.

| 부하 | 모드 | QPS | p50 | p99 | p99.9 |
|---|---|---|---|---|---|
| 1B/1B | softirq | 2.75M | 337µs | 1.04ms | 3.69ms |
| 1B/1B | kthread | 2.67M | 371µs | 455µs | 550µs |
| 5KB/5KB | softirq | 1.46M | 678µs | 969µs | 2.78ms |
| 5KB/5KB | kthread | 1.44M | 695µs | 891µs | 1.06ms |

해설: 처리량과 중앙값은 약간 손해다. 하지만 p99.9가 3.69ms에서 550µs로 줄었다. 스케줄러가 NAPI 스레드를 보고 사용자 스레드를 다른 CPU로 옮길 수 있게 된 결과다. 이후 확장으로 6.13의 per-NAPI 설정(`napi_defer_hard_irqs`, `gro_flush_timeout`을 netlink로, Joe Damato)과 `irq-suspend-timeout`(Martin Karsten·Joe Damato), 6.19의 threaded busy poll(`NETDEV_NAPI_THREADED_BUSY_POLL`)이 들어왔다. LWN(2025-02-11)은 IRQ suspension 모드에서 시스템이 "consistent (and relatively low) latency as well as if it were running in a full busy-wait mode, but with CPU utilization that is much closer to the full interrupt-deferral case"를 낸다고 정리했다. epoll busy poll과의 관계는 04/03을 참조한다(→ 04/03).

---

## 4. Implementation Impact

### 4.1 벡터 할당과 마스크 계산 (Linux 7.3-rc7 기준)

```
nvme_setup_io_queues()
  └─ nvme_setup_irqs(dev, nr_io_queues)                      drivers/nvme/host/pci.c
       struct irq_affinity affd = { .pre_vectors = 1,          ← admin 큐 IRQ (non-managed)
                                    .calc_sets = nvme_calc_irq_sets, .priv = dev };
       irq_queues = 1 + (nr_io_queues - poll_queues)           ← 폴링 큐는 벡터 없음
       pci_alloc_irq_vectors_affinity(pdev, 1, irq_queues,
                                      PCI_IRQ_ALL_TYPES | PCI_IRQ_AFFINITY, &affd)
         └─ irq_create_affinity_masks(nvecs, affd)             kernel/irq/affinity.c
              ├─ affd->calc_sets(affd, affvecs)                → set_size[DEFAULT], set_size[READ]
              ├─ pre_vectors  → irq_default_affinity (irqaffinity= 로 지정)
              ├─ for each set: group_cpus_evenly(set_size[i], &nr_masks)   lib/group_cpus.c
              │     1) present CPU를 NUMA 노드·클러스터 단위로 균등 분배
              │     2) 나머지 possible CPU(아직 없는 hotplug 슬롯)를 분배
              ├─ post_vectors → irq_default_affinity
              └─ masks[pre..nvecs-post].is_managed = 1
```

`struct irq_affinity`의 필드는 `pre_vectors`, `post_vectors`, `nr_sets`, `set_size[IRQ_AFFINITY_MAX_SETS]`(최대 4), `calc_sets`, `priv`다. `group_cpus_evenly()`는 present CPU뿐 아니라 **possible CPU 전체**를 덮는다. 나중에 hotplug로 들어올 CPU도 이미 어느 큐에 속해 있다. 그래서 managed IRQ 시스템에서는 CPU를 온라인으로 올려도 큐 재구성이 필요 없다. 대신 possible CPU 수가 실제보다 크게 잡힌 VM(예: 펌웨어가 최대 vCPU 수를 광고)에서는 각 큐에 비어 있는 CPU가 섞여 실제 CPU당 큐 수가 줄어든다.

nvme가 쓰는 큐 수 상한은 `nvme_max_io_queues()` = `blk_mq_num_possible_queues(0) + nr_write_queues + nr_poll_queues`다(6.17 이후). 컨트롤러가 Set Features(Number of Queues)로 허락한 수와 할당된 벡터 수가 이를 더 줄인다.

### 4.2 IRQ 세트 → blk-mq 큐 맵

`nvme_pci_map_queues()`는 `set->map[HCTX_TYPE_DEFAULT/READ/POLL]`을 차례로 채운다.

| 맵 | 큐 수 | 매핑 함수 | IRQ | 무엇이 들어오나 |
|---|---|---|---|---|
| `HCTX_TYPE_DEFAULT` | `write_queues`=0이면 모든 IRQ 큐, 아니면 `write_queues` 수 | `blk_mq_map_hw_queues(map, dev->dev, offset)` | managed, 세트 0 | 읽기/쓰기 공용, 또는 쓰기·기타 |
| `HCTX_TYPE_READ` | `nrirqs - write_queues` (`write_queues`>0일 때만) | `blk_mq_map_hw_queues()` | managed, 세트 1 | `REQ_OP_READ` |
| `HCTX_TYPE_POLL` | `poll_queues` (최소 1개의 IRQ 큐는 남김) | `blk_mq_map_queues()` | 없음 | `REQ_POLLED` (io_uring IOPOLL 등) |

`blk_mq_map_hw_queues()`는 `dev->bus->irq_get_affinity`(PCI는 `pci_device_irq_get_affinity()`, virtio는 `virtio_irq_get_affinity()`)로 벡터마다 마스크를 얻어 `qmap->mq_map[cpu]`에 기록한다. 실패하면 `blk_mq_map_queues()`로 돌아간다. `blk_mq_map_queues()`도 `group_cpus_evenly()`를 쓰므로 IRQ가 없는 폴링 큐도 같은 NUMA 친화 분배를 받는다. 6.14 이전에는 이 역할을 `block/blk-mq-pci.c`의 `blk_mq_pci_map_queues()`와 `block/blk-mq-virtio.c`의 `blk_mq_virtio_map_queues()`가 따로 했다. 지금은 두 파일 모두 트리에 없다.

결과적으로 **각 세트는 독립적으로 전체 CPU를 덮는다.** `write_queues=4`이고 IRQ 큐가 32개면 CPU마다 READ hctx 하나(28개 중 하나)와 DEFAULT hctx 하나(4개 중 하나)가 생긴다. 쓰기 큐 하나를 여러 CPU가 공유하게 되므로 쓰기 쪽 큐 락·태그 경합은 늘어난다.

### 4.3 완료 지역성: `rq_affinity`

managed IRQ가 있어도 큐 하나를 여러 CPU가 공유하면 완료 IRQ는 그중 한 CPU(effective affinity)에서만 처리된다. `blk_mq_complete_need_ipi()`는 다음 순서로 판단한다.

1. `QUEUE_FLAG_SAME_COMP`가 꺼져 있으면(`rq_affinity`=0) IRQ CPU에서 바로 완료한다.
2. `force_irqthreads()`(threadirqs, PREEMPT_RT)이면 IPI를 보내지 않는다. softirq를 원격으로 올리면 ksoftirqd 깨우기가 되어 더 나쁘기 때문이다.
3. 같은 CPU이거나, `QUEUE_FLAG_SAME_FORCE`가 꺼진 상태(`rq_affinity`=1)에서 캐시를 공유하고 용량이 같은 CPU면 로컬에서 완료한다.
4. 그 밖에는 제출 CPU로 IPI를 보낸다. `rq_affinity`=2는 항상 제출 CPU에서 완료하도록 강제한다.

큐가 CPU 수만큼 있으면 1~3단계에서 대부분 끝난다. 큐가 부족하거나 `managed_irq` 격리로 IRQ가 다른 CPU에 가 있으면 4단계 IPI가 늘어난다.

### 4.4 CPU offline/online 시퀀스

```
CPU N offline 요청
 ├─ CPUHP_AP_BLK_MQ_ONLINE teardown: blk_mq_hctx_notify_offline(N)        block/blk-mq.c
 │    hctx의 다른 CPU가 온라인이면 return
 │    set_bit(BLK_MQ_S_INACTIVE) + smp_mb__after_atomic()
 │    while (blk_mq_hctx_has_requests(hctx)) msleep(5)   ← pm_wakeup_pending()이면 -EBUSY로 중단
 │    (새 요청: blk_mq_get_tag()가 INACTIVE를 보고 태그를 반납 → __blk_mq_alloc_requests()가 msleep(3) 후 재시도)
 ├─ ... CPU가 stop_machine 단계에 들어감
 └─ irq_migrate_all_off_this_cpu() → migrate_one_irq()                      kernel/irq/cpuhotplug.c
      affinity ∩ online == ∅ ?
        managed     → irqd_set_managed_shutdown(); irq_shutdown_and_deactivate()  (마스크 유지)
        non-managed → affinity = cpu_online_mask (affinity "broken")

CPU N online
 └─ irq_affinity_online_cpu(N) → irq_restore_affinity_of_irq()
      managed && N ∈ affinity → irq_startup_managed() (shutdown 상태였다면)
      hk_should_isolate()이면 housekeeping CPU로 다시 조정
```

이 경로를 운영에서 보면 다음과 같다. 큐가 CPU 하나에만 묶인 구성(큐 수 ≥ CPU 수)에서 그 CPU를 끄면 해당 큐의 IRQ가 **꺼진다**. `/proc/irq/N/effective_affinity_list`는 의미 없는 값(예: 0)을 보이고 `smp_affinity_list`는 원래 CPU로 남는다. debugfs `/sys/kernel/debug/irq/irqs/N`의 dstate에 `IRQD_MANAGED_SHUTDOWN`이 보인다. 이는 정상이다. 꺼진 큐로 가는 I/O는 그 CPU가 없으므로 생기지 않는다.

### 4.5 CPU 격리 적용 지점

| 메커니즘 | 커맨드라인 | 커널 내부 | managed IRQ에 대한 효과 |
|---|---|---|---|
| 기본 IRQ affinity | `irqaffinity=<list>` | `irq_default_affinity` | `pre_vectors`/`post_vectors`(admin 큐 등)와 non-managed IRQ에만 적용 |
| 스케줄러 도메인 격리 | `isolcpus=domain,<list>` | `HK_TYPE_DOMAIN(_BOOT)` | 없음. 큐와 IRQ는 그대로 생김 |
| managed IRQ 회피 | `isolcpus=managed_irq,<list>` | `HK_TYPE_MANAGED_IRQ`, `irq_do_set_affinity()`, `hk_should_isolate()` | 마스크에 온라인 housekeeping CPU가 있으면 그쪽으로 effective affinity 이동. best-effort |
| 틱·RCU·워크큐 소음 제거 | `nohz_full=<list>` (또는 `isolcpus=nohz`) | `HK_TYPE_KERNEL_NOISE` (`TICK`/`TIMER`/`RCU`/`MISC`/`WQ` 별칭) | 없음. 격리 CPU에서 I/O를 내면 그 CPU에서 IRQ가 남 |
| 큐 자체 미생성 | (`isolcpus=io_queue`, 미병합) | `HK_TYPE_IO_QUEUE` 없음 (v7.3-rc7) | - |

`irq_do_set_affinity()`의 소스 주석이 `managed_irq`의 의미를 정확히 정한다. 마스크가 housekeeping CPU와 겹치면 격리 CPU를 빼고 housekeeping CPU만 남긴다. 겹치지 않거나 겹치는 housekeeping CPU가 모두 오프라인이면 원래 마스크를 쓴다. 이 경우 격리 CPU는 **자기가 직접 낸 I/O의 완료만** 받는다. 결국 격리 CPU에서 I/O를 하지 않는 한 `managed_irq`와 `domain` 조합으로 IRQ 간섭은 사라진다. 그러나 큐와 그 메모리는 격리 CPU 몫으로 계속 존재한다.

### 4.6 네트워크 조향 계층

`Documentation/networking/scaling.rst`가 정의하는 다섯 가지 메커니즘과 NAPI 설정을 함께 정리하면 다음과 같다.

| 메커니즘 | 도입 | 결정 주체 | 설정 지점 | 언제 쓰나 |
|---|---|---|---|---|
| RSS | 하드웨어 | NIC 해시 → 간접 테이블 → rx 큐/IRQ | `ethtool -L`(채널), `ethtool -X`(간접 테이블·해시 키) | 기본. 큐 수 ≈ 처리 코어 수 |
| RPS | 2.6.35 (`0a9627f2649a`, Tom Herbert) | 커널 softirq에서 해시 → 대상 CPU 백로그 | `/sys/class/net/<dev>/queues/rx-<n>/rps_cpus` | rx 큐가 CPU보다 적을 때 |
| RFS | 2.6.35 (`fec5e652e58f`) | 소켓을 마지막으로 읽은 CPU로 조향 | `/proc/sys/net/core/rps_sock_flow_entries`, `rx-<n>/rps_flow_cnt` | 애플리케이션 CPU와 처리 CPU를 맞출 때 |
| aRFS | 드라이버 + `ndo_rx_flow_steer` | NIC n-tuple 필터로 RFS 결정을 하드웨어에 반영 | `ethtool -K <dev> ntuple on` + RFS 설정. 6.15부터 코어가 rmap 관리(`rx_cpu_rmap_auto`) | RFS의 소프트웨어 IPI를 없애고 싶을 때 |
| XPS | 2.6.38 (`1d24eb4815d1`) | 송신 CPU(또는 rx 큐)별 tx 큐 선택 | `tx-<n>/xps_cpus`, `tx-<n>/xps_rxqs` | tx 큐 락 경합과 완료 지역성 |
| threaded NAPI | 5.12 (`29863d41bb6e`) | NAPI 폴링을 kthread로 | `/sys/class/net/<dev>/threaded`, netdev-genl `napi-set threaded` | softirq가 사용자 스레드와 섞여 꼬리 지연이 클 때 |
| SW IRQ 병합 | `napi_defer_hard_irqs`(5.8, `6f8b12d661d0`, Eric Dumazet), per-NAPI(6.13) | 빈 폴링 N회까지 IRQ를 다시 켜지 않고 타이머 재폴링 | sysfs `napi_defer_hard_irqs`·`gro_flush_timeout`, netdev-genl `defer-hard-irqs`·`gro-flush-timeout` | 높은 패킷률에서 IRQ 수 감소 |
| IRQ suspension | 6.13 (`5dc51ec86df6`, Martin Karsten) | 애플리케이션이 busy poll로 데이터를 받는 동안 IRQ 정지 | netdev-genl `irq-suspend-timeout` + `SO_PREFER_BUSY_POLL`/`EPIOCSPARAMS` | epoll 기반 고부하 서버 |
| threaded busy poll | 6.19 | NAPI kthread가 계속 폴링 | `napi-set threaded busy-poll` | AF_XDP·포워딩, 전용 코어 |

NIC IRQ는 non-managed이므로 운영자가 `/proc/irq/N/smp_affinity_list`로 rx 큐 IRQ를 원하는 CPU에 둘 수 있다. irqbalance도 이 IRQ를 옮긴다. 저지연 서버에서 흔한 패턴은 irqbalance를 끄거나 NIC IRQ를 제외하고, rx 큐 IRQ를 애플리케이션 스레드와 같은 NUMA 노드의 CPU에 1:1로 고정하는 것이다. 이때 XPS를 같은 매핑으로 맞춘다. 6.15의 `netif_enable_irq_affinity()`(`bd7c00605ee0`, Ahmed Zaki)는 드라이버가 큐를 다시 만들 때(`ethtool -L` 등) 사용자 affinity를 코어가 보존하게 했다. 전에는 이 동작이 드라이버마다 달랐다.

### 4.7 인터럽트 병합 비교

| 대상 | 장치 측 | 소프트웨어 측 | 단위·한계 | Linux 기본 |
|---|---|---|---|---|
| NVMe PCIe | Feature 08h Interrupt Coalescing: TIME(cdw11[15:8]), THR(cdw11[7:0]). Feature 09h Interrupt Vector Configuration: 벡터별 CD(Coalescing Disable) | 폴링 큐(`poll_queues`) + io_uring IOPOLL, `io_comp_batch` 배치 완료 | TIME은 100µs 단위(cinterrupts 논문). 정적 설정 | 호스트 드라이버가 설정하지 않음. `nvme set-feature -f 8`로 수동 설정 가능 |
| NIC | `ethtool -C rx-usecs/rx-frames/tx-usecs`, `adaptive-rx/tx` | NAPI 배치, `napi_defer_hard_irqs`, IRQ suspension | 드라이버별. DIM(`lib/dim`, `net_dim()`)이 적응형 프로파일 제공 | 드라이버 기본값. 상당수가 adaptive |
| RDMA CQ | 장치 CQ moderation (`modify_cq`) | `rdma_dim()` (`ib_device->use_cq_dim`) | 장치별 | 드라이버가 DIM을 켠 경우만 |

NVMe가 10µs 이하 지연에 도달한 뒤에는 장치 측 병합보다 폴링이 현실적인 대안이 됐다. 폴링은 CPU 시간을 내고, 폴링할 주체(IOPOLL 루프, SQPOLL, 또는 SPDK 같은 사용자 공간 드라이버)가 필요하다.

### 4.8 실무 튜닝 패턴

1. **NVMe 큐 배치 확인**: `/sys/block/nvme0n1/mq/<n>/cpu_list`로 hctx마다 CPU 집합을 본다. `/proc/interrupts`의 `nvme0q<n>` 행과 `/proc/irq/<irq>/effective_affinity_list`를 대조한다. 큐 수가 CPU 수보다 적으면 hctx마다 같은 NUMA 노드의 CPU가 묶여 있어야 정상이다.
2. **NVMe IRQ를 옮기려 하지 말 것**: managed IRQ는 쓰기 불가다. 대신 (a) 애플리케이션을 원하는 CPU에 고정하고 I/O를 그 CPU에서 내거나, (b) `isolcpus=managed_irq,<list>`로 격리 CPU를 effective affinity에서 빼거나, (c) 큐 수를 바꾼다. `write_queues`/`poll_queues`는 0644 모듈 파라미터이고, `nvme_setup_io_queues()`가 컨트롤러 리셋 때마다 다시 읽는다(`dev->nr_write_queues = write_queues`). 그래서 값을 바꾼 뒤 `/sys/class/nvme/nvme0/reset_controller`로 적용할 수 있다.
3. **저지연 폴링 구성**: `nvme.poll_queues=<N>`과 io_uring `IORING_SETUP_IOPOLL`을 함께 쓴다. 폴링 큐는 IRQ가 없으므로 폴링하지 않는 I/O(일반 read/write, 파일시스템 메타데이터)는 DEFAULT/READ 큐로 간다. 폴링 큐는 벡터를 쓰지 않지만 IRQ 큐 수를 그만큼 줄인다.
4. **읽기 지연 보호**: 쓰기 폭주가 읽기 꼬리 지연을 키우는 혼합 부하에서는 `nvme.write_queues=<N>`로 SQ 세트를 분리한다. 효과는 컨트롤러의 중재 방식(기본 round-robin)에 달려 있다.
5. **완료 CPU 고정**: 큐가 CPU보다 적고 제출 CPU 캐시 지역성이 중요하면 `rq_affinity=2`를 쓴다. IPI 비용과 맞바꾸므로 측정한 뒤 결정한다.
6. **격리 코어 구성**(DPDK/SPDK/실시간): `isolcpus=domain,managed_irq,<list> nohz_full=<list> irqaffinity=<housekeeping>`가 기본형이다. 격리 CPU에서는 커널 블록 I/O를 내지 않는다. NIC IRQ는 non-managed이므로 `irqaffinity=`와 irqbalance 설정(격리 CPU 제외)이 적용된다.
7. **네트워크 꼬리 지연**: softirq와 애플리케이션이 같은 CPU에서 경쟁하면 `threaded`=1을 켜고 NAPI kthread를 별도 CPU에 고정한다. 높은 패킷률에서는 `napi_defer_hard_irqs`+`gro_flush_timeout`, epoll 서버는 `irq-suspend-timeout`과 `SO_PREFER_BUSY_POLL`을 검토한다.
8. **VM**: possible vCPU 수가 실제보다 크면 `group_cpus_evenly()`가 빈 CPU를 큐에 섞는다(4.1절). 게스트에서 virtio-blk/virtio-scsi 큐 수를 실제 vCPU 수에 맞추는 것이 먼저다.

### 4.9 버전 연표

| 버전 | 변화 |
|---|---|
| 2.6.35 / 2.6.38 | RPS·RFS / XPS (Tom Herbert) |
| 4.8 | `IRQD_AFFINITY_MANAGED`, `PCI_IRQ_AFFINITY` |
| 4.10 | `pci_alloc_irq_vectors_affinity()` |
| 4.13 | managed IRQ hotplug shutdown/restart |
| 5.0 | `HCTX_TYPE_*` 다중 맵, nvme `write_queues`·`poll_queues`, IRQ 세트(`nr_sets`) |
| 5.1 | `irq_affinity.calc_sets` |
| 5.6 | `isolcpus=managed_irq` |
| 5.8 | `blk_mq_hctx_notify_offline()`, `CPUHP_AP_BLK_MQ_ONLINE` |
| 5.8 | NAPI `napi_defer_hard_irqs` |
| 5.12 | threaded NAPI |
| 5.18 | housekeeping 플래그를 `enum hk_type`으로 정리 (`04d4e665a609`, Frederic Weisbecker) |
| 6.3 | `group_cpus_evenly()`를 `lib/`로 이동 |
| 6.13 | per-NAPI 설정(netdev-genl), IRQ suspension |
| 6.14 | `blk_mq_map_hw_queues()` (버스별 헬퍼 제거) |
| 6.15 | `netif_enable_irq_affinity()`, 코어 aRFS rmap 관리 |
| 6.17 | `blk_mq_num_possible_queues()`/`blk_mq_num_online_queues()` |
| 6.19 | threaded NAPI busy poll |
| 7.0 | `group_cpus_evenly()` 클러스터 인식 |
| 7.1 | managed interrupt 공식 문서 |

---

## 5. Primary References

- [Affinity managed interrupts](https://docs.kernel.org/core-api/irq/managed_irq.html) — managed IRQ, hotplug shutdown, `isolcpus=managed_irq` 공식 문서 (7.1)
- [Scaling in the Linux Networking Stack](https://docs.kernel.org/networking/scaling.html) — RSS/RPS/RFS/aRFS/XPS 공식 문서
- [NAPI](https://docs.kernel.org/networking/napi.html) — threaded NAPI, SW IRQ 병합, IRQ suspension, threaded busy poll
- [The kernel's command-line parameters](https://docs.kernel.org/admin-guide/kernel-parameters.html) — `isolcpus=`, `nohz_full=`, `irqaffinity=`
- [Optimizing Storage Performance with Calibrated Interrupts](https://www.usenix.org/conference/osdi21/presentation/tai) — Tai, Smolyar, Wei, Tsafrir, OSDI '21. NVMe 인터럽트 병합의 한계와 cinterrupts
- [blk: honor isolcpus configuration](https://lwn.net/Articles/1004820/) — Daniel Wagner v5 cover letter (2025-01-10, LWN 미러)
- [implement kthread based napi poll](https://lwn.net/Articles/845214/) — Wei Wang v10 cover letter (2021-02-04, LWN 미러). softirq vs kthread 측정
- [Smarter IRQ suspension in the networking stack](https://lwn.net/Articles/1008399/) — Jonathan Corbet, LWN, 2025-02-11
- [Add support for multiple queue maps](https://lwn.net/Articles/769836/) — Jens Axboe 패치 시리즈 (LWN 미러). `HCTX_TYPE_*` 다중 맵
- [kernel/irq/affinity.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/kernel/irq/affinity.c) — 커널 소스(master)
- [kernel/irq/cpuhotplug.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/kernel/irq/cpuhotplug.c) — 커널 소스(master)
- [lib/group_cpus.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/lib/group_cpus.c) — 커널 소스(master)
- [block/blk-mq-cpumap.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/block/blk-mq-cpumap.c) — 커널 소스(master)
- [drivers/nvme/host/pci.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/nvme/host/pci.c) — 커널 소스(master)
- [include/linux/sched/isolation.h](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/include/linux/sched/isolation.h) — 커널 소스(master)
- [c5cb83bb337c genirq/cpuhotplug: Handle managed IRQs on CPU hotplug](https://github.com/torvalds/linux/commit/c5cb83bb337c) — 커밋
- [11ea68f553e2 genirq, sched/isolation: Isolate from handling managed interrupts](https://github.com/torvalds/linux/commit/11ea68f553e2) — 커밋
- [bf0beec0607d blk-mq: drain I/O when all CPUs in a hctx are offline](https://github.com/torvalds/linux/commit/bf0beec0607d) — 커밋
- [3b6592f70ad7 nvme: utilize two queue maps, one for reads and one for writes](https://github.com/torvalds/linux/commit/3b6592f70ad7) — 커밋
- [4b04cc6a8f86 nvme: add separate poll queue map](https://github.com/torvalds/linux/commit/4b04cc6a8f86) — 커밋
- [1452e9b470c9 blk-mq: introduce blk_mq_map_hw_queues](https://github.com/torvalds/linux/commit/1452e9b470c9) — 커밋
- [29863d41bb6e net: implement threaded-able napi poll loop support](https://github.com/torvalds/linux/commit/29863d41bb6e) — 커밋
