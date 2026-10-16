# NVMe 멀티패스 아키텍처 논쟁: 네이티브 nvme-multipath vs dm-multipath

> 기준 소스: Linux 7.3-rc7 (`torvalds/linux` master, 2026-10 확인) `drivers/nvme/host/multipath.c`, `core.c`, `nvme.h`, `drivers/md/dm-mpath.c`. 기능 도입 버전은 git.kernel.org의 각 릴리스 태그(v4.15, v4.19, v4.20, v5.1, v6.10, v6.11, v6.16) 소스를 직접 대조해 확인했다.

## 1. Verdict

NVMe 멀티패스 논쟁은 "멀티패스는 Device Mapper(DM)라는 범용 계층에 있어야 하는가, 아니면 프로토콜 드라이버 안에 있어야 하는가"에 관한 것이었다. 결론은 **NVMe에 한해서는 드라이버 내장(native) 멀티패스가 표준 경로**가 되었다는 것이다. 다만 dm-multipath가 제거되거나 금지된 것은 아니다. `nvme_core.multipath=N`으로 끄면 각 컨트롤러 경로가 독립 블록 디바이스로 노출되고, dm-multipath를 그 위에 얹는 길은 지금도 열려 있다.

핵심 판단 근거는 세 가지다.

1. **NVMe는 부분 완료(partial completion)가 없다.** Christoph Hellwig는 2017년 8월 RFC에서 이 점을 근거로 들었다. bio나 request를 복제(clone)할 필요 없이 I/O를 적당한 경로로 "재지정(redirect)"하기만 하면 된다. 성공한 명령의 완료 경로에는 멀티패스 코드가 아예 끼지 않는다.
2. **경로 상태가 표준화되어 있다.** NVMe 사양의 ANA(Asymmetric Namespace Access)가 경로별 상태(Optimized / Non-Optimized / Inaccessible / Persistent Loss / Change)를 로그 페이지와 비동기 이벤트(AEN)로 알려 준다. 커널이 이를 직접 해석하면 사용자 공간 데몬(`multipathd`)의 주기적 path checker가 필요 없다.
3. **제출 경로가 단순하다.** 네이티브 경로는 `nvme_ns_head_submit_bio()`에서 SRCU 읽기 구역 안에 경로 하나를 고르고, `bio_set_dev()`로 bio의 대상만 바꾼 뒤 `submit_bio_noacct()`로 다시 넣는다. 요청 복제도 없고, 경로 선택용 전역 락도 없다.

몇 가지 흔한 오해도 정리해 둔다. ① 네이티브 멀티패스는 일반적인 NVMe→block 트리 경로를 거쳐 4.15에 병합되었고, Linus Torvalds가 별도로 "최종 수용" 결정을 내렸다는 근거는 확인되지 않는다. ② 경로 선택은 `rcu_read_lock()`이 아니라 `srcu_read_lock(&head->srcu)`로 보호된다. 4.15 초기 구현부터 SRCU였다. ③ dm-mpath의 성능 저하 폭이나 네이티브 failover 시간을 특정 수치로 제시하는 1차 출처는 찾지 못했다 `[추측/미확인]`. ④ dm-mpath도 경로 실패를 **커널 안의** `fail_path()`에서 즉시 처리한다. 사용자 공간 데몬은 주로 경로 재활성화와 health check를 맡는다. ⑤ 네이티브 멀티패스의 기본 활성화 여부는 배포판마다 다르다. Red Hat 제품 문서에 따르면 RHEL 8은 네이티브 멀티패스가 기본 비활성(`multipath=N`)이고, RHEL 9부터 기본 활성이다.

2024년 이후의 흐름도 짚어 둔다. 경로 선택 정책은 `numa`(기본) → `round-robin`(5.1) → `queue-depth`(6.11)로 늘었다. 6.16에서는 `multipath_always_on` 모듈 파라미터와 헤드 노드별 `delayed_removal_secs`가 추가되어 "경로가 모두 사라졌을 때 I/O를 얼마나 붙잡아 둘 것인가"라는 dm-mpath식 `queue_if_no_path` 요구를 부분적으로 흡수했다. 2026-02-25에는 Oracle의 John Garry가 NVMe 멀티패스 코드를 블록 드라이버 공용 라이브러리 `libmultipath`로 일반화하는 패치 시리즈("[PATCH 00/13] libmultipath: a generic multipath lib for block drivers"와 "[PATCH 00/19] nvme: switch to libmultipath")를 올렸고, 2026년 7월 v3까지 진행되었다. 7.3-rc7 master에는 아직 병합되지 않았다(`drivers/nvme/host/nvme.h`에 `mpath_head` 없음).

---

## 2. Problem Statement

### 2.1 다중 경로 NVMe의 등장
NVMe 1.1 이후 하나의 NVM 서브시스템이 여러 컨트롤러를 가질 수 있게 되었다. 같은 네임스페이스(NSID와 NGUID/EUI-64/UUID가 같은 것)가 여러 컨트롤러를 통해 보이는 구조다. 듀얼 포트 엔터프라이즈 PCIe SSD, 그리고 무엇보다 NVMe-oF(RDMA/FC/TCP) 스토리지 어레이가 이 형태다. 호스트 입장에서 같은 데이터를 가리키는 블록 디바이스가 경로 수만큼 생기므로, 이를 하나로 묶고 장애 시 다른 경로로 넘기는 계층이 반드시 필요하다.

### 2.2 dm-multipath를 NVMe에 그대로 쓸 때의 비용
dm-multipath는 SCSI 시대에 설계된 범용 계층이다. `drivers/md/dm-mpath.c` 기준으로 두 가지 모드가 있다.

- **request 기반(`queue_mode rq`/`mq`, 기본)**: 상위 DM 디바이스가 자체 blk-mq 큐를 갖는다. `multipath_clone_and_map()`이 하위 경로 큐에서 `blk_mq_alloc_request()`로 **새 request를 할당해 clone**한다. 태그 할당이 두 단계(DM 큐와 하위 NVMe 큐)로 일어나고, 완료도 clone → 원본 순서로 두 번 거친다.
- **bio 기반(`queue_mode bio`, 4.8 도입)**: `__multipath_map_bio()`로 bio를 하위 경로에 재지정한다. 이중 request 할당은 없지만, DM 코어의 bio clone(`dm_io`/target_io 할당)과 DM 테이블 참조 비용은 남는다.

이 비용은 SCSI 디스크나 수십 µs 이상 걸리는 FC 어레이에서는 거의 드러나지 않았다. 하지만 4KB 랜덤 읽기 지연이 10µs 안팎인 로컬 NVMe나, 코어당 수백만 IOPS를 노리는 환경에서는 상대적으로 커진다. 다만 dm-multipath를 NVMe에 얹었을 때의 성능 저하 폭을 보여 주는 1차 출처 수치는 찾지 못했으므로 쓰지 않는다 `[추측/미확인]`. Hellwig 본인도 RFC에서 "멀티패스 노드를 써도 일반 nvme 동작 대비 성능 저하가 없다"는 정성적 주장만 했다.

### 2.3 경로 상태 관리 방식의 불일치
SCSI에는 ALUA(Asymmetric Logical Unit Access)가 있고 dm-mpath는 `scsi_dh_alua` 디바이스 핸들러와 `multipathd`의 path checker(`tur`, `directio` 등)로 경로 상태를 관리한다. NVMe에는 ANA라는 별도 메커니즘이 있다.

- ANA 그룹 ID(ANAGRPID)가 네임스페이스마다 붙는다.
- 상태 변화는 AEN(`NVME_AER_NOTICE_ANA`)으로 통지된다.
- 상세 상태는 Get Log Page(`NVME_LOG_ANA`)로 읽는다.
- 경로 관련 오류는 상태 코드 타입 `NVME_SCT_PATH`(예: `NVME_SC_ANA_TRANSITION`, `NVME_SC_ANA_INACCESSIBLE`, `NVME_SC_ANA_PERSISTENT_LOSS`)로 돌아온다.

dm-mpath가 이를 쓰려면 사용자 공간 도구가 NVMe ANA를 이해해야 한다. 이 "관리 모델의 불일치"가 아래 논쟁의 실제 핵심이었다(3.3절 Martin K. Petersen 발언 참고).

### 2.4 Fabrics 특유의 문제
NVMe-oF에서는 링크 단절이 곧 컨트롤러 리셋/재연결로 이어진다(`ctrl_loss_tmo`, `reconnect_delay`, `fast_io_fail_tmo`). 재연결 동안 I/O를 즉시 실패시킬지, 다른 경로로 넘길지, 경로가 하나도 없으면 얼마나 큐잉할지를 정해야 한다. 이 정책이 멀티패스 계층과 전송 드라이버 사이에서 일관되어야 했고, 네이티브 구현은 이를 `nvme_ctrl` 상태 머신(`NVME_CTRL_LIVE`/`RESETTING`/`CONNECTING`/`DELETING`)과 직접 묶었다.

---

## 3. The Debate

논쟁은 두 국면으로 나뉜다. 2017년 8~11월에는 구현 자체가 리뷰되었고(RFC → V5 → 4.15 병합), 2018년 5~6월에는 "네이티브와 dm-multipath를 서브시스템 단위로 골라 쓰게 해 달라"는 패치를 놓고 정면 충돌이 벌어졌다. 아래 인용은 LKML 아카이브(lkml.iu.edu 사본, LWN 패치 미러)에서 본문과 Message-ID를 직접 대조한 것이다.

### 3.1 2017년 RFC: "복제가 필요 없다"는 설계 논거
Christoph Hellwig의 RFC는 2017-08-23에 올라왔다(Message-ID `20170823175815.3646-1-hch@lst.de`, LWN 패치 미러로 확인).

> "Because of that there is no need to clone bios or requests - the I/O path simply redirects the I/O to a suitable path. For successful commands multipath is not in the completion stack at all."
>
> — Christoph Hellwig, "RFC: nvme multipath support", 2017-08-23 ([LWN 미러](https://lwn.net/Articles/731788/))

여기서 "Because of that"이 가리키는 전제는 "NVMe는 SCSI와 달리 부분 완료가 없다"는 문장이다. 커버 레터에는 ANA 제안이 아직 NVMe 회원사 기밀이라 경로 가용성을 당분간 컨트롤러 상태(fabrics의 keep-alive)로만 판단한다고도 적혀 있다. 즉 4.15에 병합된 첫 구현에는 ANA가 없었다. ANA 처리(`nvme_read_ana_log()`, `nvme_update_ana_state()`)는 사양이 공개된 뒤 4.19에서 들어왔다. 시리즈는 V2(LWN 734119), V3(734834), V4(736789), V5(737401)를 거쳤다. 이 단계의 쟁점은 sysfs 노출, 헤드 노드 이름 규칙, 서브시스템 단위 식별처럼 구현 세부였고 dm 진영과의 정면 대립은 아니었다.

### 3.2 2018년 5월: 서브시스템별 스위치 패치와 정면 충돌
4.15에서 네이티브 멀티패스가 들어오면서 전역 스위치 `nvme_core.multipath`도 함께 생겼다. SUSE의 Johannes Thumshirn은 2018-05-25에 이를 서브시스템 단위로 켜고 끌 수 있게 하는 "[PATCH 0/3] Provide more fine grained control over multipathing"을 올렸다(`20180525125322.15398-1-jthumshirn@suse.de`). 1/3은 Thumshirn, 2·3/3은 Mike Snitzer의 sysfs 패치였다. 흔히 "Snitzer 시리즈"로 불리지만, 0/3 커버 레터의 작성자는 Thumshirn이므로 "Thumshirn이 올리고 Snitzer가 공동 기여한 시리즈"가 정확하다. 불과 몇 분 뒤(LKML 아카이브 수신 시각 기준 08:54 → 09:00 EDT) Hellwig가 반대했다.

> "No.  The only reason we even allowed to turn multipathing off is because you complained about installer issues.  The path forward clearly is native multipathing and there will be no additional support for the use cases of not using it."
>
> — Christoph Hellwig, 2018-05-25 (`20180525130535.GA24239@lst.de`)

Snitzer는 같은 날 LSF/MM에서 합의가 있었다며 반박했고, Hellwig는 다시 아키텍처 문제를 꺼냈다.

> "The whole point we have native multipath in nvme is because dm-multipath is the wrong architecture (and has been, long predating you, nothing personal)."
>
> — Christoph Hellwig, 2018-05-25 (`20180525141211.GA25971@lst.de`)

Snitzer의 논거는 성능이 아니라 **운영 생태계**였다. 그는 2018-05-28 메일(`20180529030236.GA28895@redhat.com`)에서 네이티브 경로를 제어할 사용자 공간 인프라가 "literally no userspace infrastructure exists"하다고 지적했다. 그러면서 Red Hat과 SUSE의 입장을 "Plan A(네이티브)를 시도하되 Plan B(dm-multipath)도 공존시키자"로 요약했다. SUSE의 Hannes Reinecke도 자동화가 깊은 호스팅 사업자 등은 성능 손실을 감수하더라도 기존 인프라를 다시 쓰지 않는 쪽을 원한다고 거들었다(`20180529091855.27e6042b@pentland.suse.de`).

### 3.3 Martin K. Petersen: "관리 모델이 다르다"
SCSI 메인테이너 Martin K. Petersen(Oracle)의 개입이 논쟁의 축을 바꿨다. 그는 성능이 아니라 ALUA와 ANA의 책임 분담 차이를 들었다.

> "The whole point of ANA is for things to be plug and play without any admin intervention whatsoever."
>
> — Martin K. Petersen, 2018-05-28 (`yq1muwj45sg.fsf@oracle.com`)

> "With ANA the heavy burden falls entirely on the storage. Most of the things you would currently configure in multipath.conf have no meaning in the context of ANA."
>
> — Martin K. Petersen, 2018-05-31 (`yq17enjut3q.fsf@oracle.com`)

Petersen의 요지는 이렇다. ALUA는 기존 벤더 구현들을 다 수용하려고 일부러 모호하게 만든 사양이라 호스트 쪽 튜닝(`multipath.conf`)이 필요했다. ANA는 상태 전이의 책임을 스토리지 쪽에 둔다. 그러니 `multipathd`/DM이 경로 전이 상태 머신에 끼어드는 것은 사용자에게 이득이 없다. 다만 그는 "Plan B가 필요한 시점이 오면" Thumshirn 패치에 찬성한다는 여지도 남겼다. Hellwig도 2018-05-29 메일(`20180529080952.GA1369@lst.de`)에서 "If our plan A doesn't work we can go back to these patches"라고 썼다.

### 3.4 결과와 이후 흐름
- 서브시스템별 스위치 패치는 병합되지 않았다. 전역 `nvme_core.multipath=N`만 남았고, dm-multipath를 원하는 배포판은 이 파라미터를 썼다(RHEL 8 기본값 N `[추측/미확인]`).
- Snitzer는 앞서 4.8에서 "dm mpath: reinstate bio-based support"로 `queue_mode bio`를 되살렸다. 불변 biovec 이후 bio clone 비용이 내려갔다는 점, 그리고 NVMe 같은 빠른 장치를 겨냥했다는 점이 동기였다. 즉 dm 진영도 NVMe 성능 문제를 인지하고 대응하고 있었다.
- 2024년 queue-depth 정책(6.11)은 Pure Storage의 Thomas Song이 처음 작성했고, Red Hat의 Ewan D. Milne과 John Meneghini가 이어받아 v8까지 다듬었다(`20240625122605.857462-3-jmeneghi@redhat.com`). 커밋 메시지는 round-robin이 지연이 큰 경로에 I/O를 똑같이 쌓아 "This problem is acute with NVMe-oF controllers"라고 동기를 밝힌다. dm-mpath의 `queue-length` path selector와 같은 아이디어를 네이티브 쪽이 흡수한 사례다.
- 6.16의 `multipath_always_on`·`delayed_removal_secs`도 "모든 경로가 사라져도 디바이스 노드를 유지하고 I/O를 붙잡아 두는" dm식 요구를 네이티브 안에서 해결한 것이다. 결국 2018년의 "Plan B"가 요구한 기능 상당수는 네이티브 쪽으로 옮겨 왔다.

---

## 4. Implementation Impact

이하 함수·필드 이름은 Linux 7.3-rc7 `drivers/nvme/host/{multipath.c,core.c,nvme.h}`에서 grep으로 확인했다.

### 4.1 객체 모델: `nvme_subsystem` → `nvme_ns_head` → `nvme_ns`
- `struct nvme_subsystem`: NQN 하나에 대응한다. 경로 선택 정책 `iopolicy`(`enum nvme_iopolicy`)는 **서브시스템 단위**로 저장된다. 모듈 파라미터 `nvme_core.iopolicy`는 새 서브시스템의 기본값만 정한다(`nvme_mpath_default_iopolicy()`).
- `struct nvme_ns_head`: 공유 네임스페이스 하나. `/dev/nvmeXnY` 헤드 gendisk, 경로 목록 `list`, 읽기 측 보호용 `struct srcu_struct srcu`, 경로가 없을 때 bio를 쌓는 `requeue_list`/`requeue_lock`/`requeue_work`, 그리고 NUMA 노드별 캐시 `struct nvme_ns *current_path[]`(flexible array, `nr_node_ids`개)를 가진다. 플래그로 `NVME_NSHEAD_DISK_LIVE`, `NVME_NSHEAD_QUEUE_IF_NO_PATH`가 있다.
- `struct nvme_ns`: 컨트롤러 하나를 통한 경로. 숨겨진 경로 디바이스 `nvmeXcYnZ`와 `ana_state`를 가지며, `ns->ctrl->nr_active`(atomic)는 queue-depth 정책에서 쓴다.

### 4.2 제출 경로 (`nvme_ns_head_submit_bio`)
```
submit_bio(bio → /dev/nvme0n1 헤드)
 └ nvme_ns_head_submit_bio()
    ├ bio_split_to_limits(bio)          # 헤드 큐의 limits로 먼저 분할
    ├ srcu_idx = srcu_read_lock(&head->srcu)
    ├ ns = nvme_find_path(head)
    │    ├ NVME_IOPOLICY_QD → nvme_queue_depth_path()   # nr_active 최소
    │    ├ NVME_IOPOLICY_RR → nvme_round_robin_path()
    │    └ NUMA(기본)      → current_path[node] 캐시, 없으면 __nvme_find_path()
    ├ (ns 있음) bio_set_dev(bio, ns->disk->part0); BIO_REMAPPED; bi_opf |= REQ_NVME_MPATH
    │           submit_bio_noacct(bio)  # 경로 디바이스의 blk-mq로
    ├ (ns 없음, nvme_available_path()) → requeue_list에 추가
    ├ (경로 전무) → bio_io_error()
    └ srcu_read_unlock()
```
- **왜 RCU가 아니라 SRCU인가**: 읽기 구역 안에서 `submit_bio_noacct()`를 호출한다. 이 과정에서 하위 경로 큐의 태그 할당 대기 등으로 잠들 수 있으므로, 잠들 수 있는 읽기 측을 허용하는 SRCU가 필요하다. 경로를 제거할 때는 `list_del_rcu()` 뒤에 `synchronize_srcu(&head->srcu)`로 진행 중인 제출이 빠져나가길 기다린다(core.c·multipath.c 여러 곳).
- `__nvme_find_path()`는 `nvme_path_is_disabled()`인 경로를 건너뛴다(컨트롤러가 `LIVE`/`DELETING`이 아니거나, `NVME_NS_ANA_PENDING`, `!NVME_NS_READY`). 남은 경로 중 `NVME_ANA_OPTIMIZED`를 `node_distance()`가 가장 짧은 순으로 고르고, 없으면 `NVME_ANA_NONOPTIMIZED`를 대안으로 쓴다. 결과는 `rcu_assign_pointer(head->current_path[node], found)`로 캐시되므로, 이후 같은 노드의 I/O는 리스트를 다시 돌지 않는다.
- `REQ_NVME_MPATH` 플래그가 "이 요청은 헤드에서 왔다"는 표식이다. 완료 시 이 플래그가 있어야만 failover 대상이 된다.

### 4.3 완료·failover 경로
1. `nvme_complete_rq()` → `nvme_decide_disposition()`. 상태 0이면 `COMPLETE`. DNR 비트가 서 있거나 재시도 한도를 넘었으면 역시 `COMPLETE`. `REQ_NVME_MPATH`이면서 `nvme_is_path_error()`(상태 코드 타입 `NVME_SCT_PATH`)이거나 큐가 dying이면 `FAILOVER`. 그 밖은 `RETRY`.
2. `nvme_failover_req()`: `nvme_mpath_clear_current_path()`로 캐시를 비우고 `ns->failover` 카운터를 올린다. ANA 오류면 `NVME_NS_ANA_PENDING`을 세우고 `ana_work`를 큐잉해 ANA 로그를 다시 읽게 한다. 그 뒤 `requeue_lock` 아래에서 bio들의 대상을 헤드로 되돌리고 `blk_steal_bios()`로 request에서 떼어 `requeue_list`에 옮긴다. request 자체는 상태 0으로 끝내고, `kblockd_schedule_work(&head->requeue_work)`를 호출한다.
3. `nvme_requeue_work()`가 리스트의 bio를 `submit_bio_noacct()`로 헤드에 다시 넣으면 2.2절 경로 선택이 처음부터 반복된다.

즉 성공 경로에는 멀티패스 코드가 `nvme_mpath_start_request()`/`end_request()`(통계·nr_active) 외에는 없다. 실패 시에만 bio를 "훔쳐서" 재제출한다. failover가 "1ms 미만"이나 "µs 단위"라는 식의 수치는 출처가 없다. 실제 failover 시간은 오류를 감지하는 시점(I/O 타임아웃, keep-alive, 전송 계층 오류)에 좌우되므로 수치로 단정할 수 없다.

### 4.4 경로 소진 시 동작
`nvme_available_path()`는 `LIVE`/`RESETTING`/`CONNECTING` 상태의 컨트롤러가 하나라도 있으면 true다. 단 `NVME_CTRL_FAILFAST_EXPIRED`(fabrics `fast_io_fail_tmo` 만료)인 컨트롤러는 제외한다. 모두 없더라도 `delayed_removal_secs`가 0이 아니면 `NVME_NSHEAD_QUEUE_IF_NO_PATH`로 I/O를 큐잉한다. dm-mpath의 `queue_if_no_path`/`no_path_retry`에 해당하는 기능이다.

### 4.5 비교표: dm-multipath vs native nvme-multipath

| 항목 | dm-multipath (`queue_mode mq`) | dm-multipath (`queue_mode bio`, 4.8+) | native nvme-multipath (4.15+) |
|---|---|---|---|
| 상위 디바이스 | `dm-N` (자체 blk-mq 큐) | `dm-N` (bio 기반) | `nvmeXnY` 헤드 (bio 기반 `submit_bio`) |
| 데이터 경로 | `multipath_clone_and_map()`이 하위 큐에서 request clone | `__multipath_map_bio()`로 bio 재지정, DM 코어 clone | `bio_set_dev()` 후 `submit_bio_noacct()`, clone 없음 |
| 태그 할당 | 2회 (DM 큐 + 경로 큐) | 1회 (경로 큐) | 1회 (경로 큐) |
| 읽기 측 보호 | DM 테이블 참조(`dm_get_live_table`, SRCU) | 동일 | `head->srcu` |
| 경로 상태 출처 | path checker(`multipathd`) + `scsi_dh` + 커널 `fail_path()` | 동일 | 컨트롤러 상태 머신 + ANA 로그/AEN |
| 경로 선택기 | round-robin, queue-length, service-time, historical-service-time | 동일 | numa(기본), round-robin(5.1), queue-depth(6.11) |
| 경로 소진 시 | `queue_if_no_path`, `no_path_retry` | 동일 | `delayed_removal_secs`(6.16), fabrics `ctrl_loss_tmo` |
| 지원 프로토콜 | SCSI/FC/iSCSI/NVMe 등 범용 | 동일 | NVMe(PCIe, RDMA, TCP, FC) 전용 |
| 통계·관측 | 경로별 `dm` 통계, `multipath -ll` | 동일 | 헤드·경로 디바이스 별도 gendisk, `nvme list-subsys`, sysfs `ana_state` |

### 4.6 운영상 함의
- 혼합 환경(로컬 PCIe는 네이티브, 외부 어레이는 dm)을 서브시스템 단위로 나눌 수 없다는 2018년의 한계는 그대로다. 전역 `nvme_core.multipath`만 존재하고, `multipath_always_on`이 켜져 있으면 끌 수조차 없다(`multipath_param_set()`이 거부).
- `iopolicy`가 서브시스템 sysfs 속성이므로 NVMe-oF처럼 경로 지연이 비대칭인 경우 queue-depth를, 로컬 듀얼포트 SSD에는 numa를 서브시스템마다 다르게 줄 수 있다.
- 관측: 경로별 I/O는 숨은 경로 디바이스 `nvmeXcYnZ`의 통계로 보고, failover는 경로별 `multipath_failover_count`(`ns->failover`)와 헤드의 `io_requeue_no_usable_path_count`/`io_fail_no_available_path_count` sysfs 카운터로 추적한다. 트레이스포인트는 `block:block_bio_remap`이 헤드→경로 재매핑마다 찍힌다.

---

## 5. Primary References

lore.kernel.org는 봇 차단으로 자동 확인이 안 된다. 아래 lore 링크의 Message-ID·작성자·날짜는 LKML 아카이브(lkml.iu.edu) 사본의 메일 헤더와 대조했다.

- [RFC: nvme multipath support](https://lwn.net/Articles/731788/) — Christoph Hellwig, 2017-08-23, Message-ID `20170823175815.3646-1-hch@lst.de`
- [nvme multipath support V2](https://lwn.net/Articles/734119/) — LWN 패치 미러, 2017-09
- [nvme multipath support V5](https://lwn.net/Articles/737401/) — LWN 패치 미러, 4.15 병합 직전 판
- [[PATCH 0/3] Provide more fine grained control over multipathing](https://lore.kernel.org/all/20180525125322.15398-1-jthumshirn@suse.de/) — Johannes Thumshirn, 2018-05-25 커버 레터
- [Re: [PATCH 0/3] Provide more fine grained control over multipathing](https://lore.kernel.org/all/20180525130535.GA24239@lst.de/) — Christoph Hellwig, 2018-05-25 ("No.")
- [Re: [PATCH 0/3] Provide more fine grained control over multipathing](https://lore.kernel.org/all/20180525141211.GA25971@lst.de/) — Christoph Hellwig, 2018-05-25 ("wrong architecture")
- [Re: [PATCH 0/3] Provide more fine grained control over multipathing](https://lore.kernel.org/all/yq1muwj45sg.fsf@oracle.com/) — Martin K. Petersen, 2018-05-28
- [Re: [PATCH 0/3] Provide more fine grained control over multipathing](https://lore.kernel.org/all/20180529030236.GA28895@redhat.com/) — Mike Snitzer, 2018-05-28 (EDT)
- [Re: [PATCH 0/3] Provide more fine grained control over multipathing](https://lore.kernel.org/all/yq17enjut3q.fsf@oracle.com/) — Martin K. Petersen, 2018-05-31
- [[PATCH v8 2/2] nvme-multipath: implement "queue-depth" iopolicy](https://lore.kernel.org/all/20240625122605.857462-3-jmeneghi@redhat.com/) — John Meneghini가 게시, 2024-06-25 (작성자 Thomas Song, 커밋 f227345f0a70, Linux 6.11)
- [Linux NVMe multipath](https://docs.kernel.org/admin-guide/nvme-multipath.html) — 커널 공식 관리자 문서
- [drivers/nvme/host/multipath.c](https://github.com/torvalds/linux/blob/master/drivers/nvme/host/multipath.c) — 네이티브 멀티패스 구현 (GitHub 미러)
- [drivers/md/dm-mpath.c](https://github.com/torvalds/linux/blob/master/drivers/md/dm-mpath.c) — dm-multipath 타깃 구현 (GitHub 미러)
