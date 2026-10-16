# NVMe FDP, 쓰기 수명 힌트, 그리고 write stream: 리눅스 데이터 배치 인터페이스 10년의 왕복

> 기준 소스: Linux 7.3-rc7 (`torvalds/linux` master, 2026-10 확인) `drivers/nvme/host/core.c`, `block/fops.c`, `block/blk-sysfs.c`, `include/linux/blk_types.h`, `include/uapi/linux/{fcntl.h,io_uring.h}`, `io_uring/rw.c`, `fs/fcntl.c`, `fs/f2fs/{data.c,segment.c}`. 도입·제거 버전은 git.kernel.org `plain/<path>?h=vX.Y` 태그별 grep과 GitHub 커밋 메시지로 확인했다. FDP 규격 사실관계는 NVM Express가 게시한 FMS 2023 발표 자료 기준이다.

## 1. Verdict

리눅스의 "호스트가 데이터 수명을 장치에 알려 쓰기 증폭을 줄인다"는 시도는 세 번 시작됐다. 그중 두 번은 접혔다.

1. **2016–2017: NVMe Streams Directive + `F_SET_RW_HINT`.** Jens Axboe가 숫자 stream ID 대신 상대적 수명 힌트 4종(`RWH_WRITE_LIFE_SHORT`~`EXTREME`)을 fcntl로 노출했다. NVMe 드라이버는 이를 Streams Directive로 변환했다. **4.13**에 머지됐다.
2. **2022: 제거.** "No vendor ever really shipped working support for this"(Axboe 머지 메시지)라는 이유로 NVMe streams 지원과 per-bio 힌트가 **5.18**에서 제거됐다. `request.write_hint`는 6.2에서 제거됐다. `F_SET_RW_HINT` fcntl은 inode에 값을 저장하는 기능만 남았다. `F_{GET,SET}_FILE_RW_HINT`는 uAPI 헤더에 상수만 남고 `fs/fcntl.c`에서 처리가 사라졌다.
3. **2024: 힌트 복원.** Bart Van Assche가 UFS(SCSI) 수요를 근거로 `bio->bi_write_hint`를 **6.9**에서 되살렸다. 같은 6.9에 SCSI `sd`의 데이터 수명 지원이 들어갔다.
4. **2025: write stream.** NVMe FDP(Flexible Data Placement, TP4146)를 블록 계층·io_uring에 일반화한 **write stream**이 **6.16**에 머지됐다. 구성 요소는 `bio->bi_write_stream`, `queue_limits.max_write_streams`/`write_stream_granularity`, io_uring SQE의 `write_stream` 필드다. 커밋에는 "[hch: renamed hints to streams, removed stacking]"이라는 메모가 남아 있다. 힌트와 stream을 별개 개념으로 분리한 것이 이번 시도의 핵심이다. 첫 파일시스템 사용자는 **7.2**의 f2fs다(`f2fs_io_type_to_write_stream()`).

결론은 이렇다. FDP는 ZNS보다 채택 장벽이 훨씬 낮다. 하위 호환이 되고, 힌트를 무시해도 정상 동작하며, 랜덤 쓰기도 허용한다. 장치 WAF(Write Amplification Factor) 개선이 실측된 사례도 있다. Meta CacheLib의 EuroSys '25 논문은 "an ideal device write amplification of ~1 can be achieved with FDP"라고 보고했다. Keith Busch는 LSFMM+BPF 2025에서 Meta가 구매하는 모든 SSD가 FDP를 지원한다고 말했다(단 기본은 비활성).

그러나 리눅스 범용 스택의 통합은 여전히 얕다. 2026-10 현재 write stream을 쓰는 경로는 세 가지뿐이다. 블록 디바이스 direct I/O(io_uring `write_stream`), NVMe 패스스루, 그리고 f2fs다. 주요 범용 FS(XFS, ext4, btrfs)의 iomap 경로는 아직 연결되지 않았다. "태그가 희소 자원인데 누가 배분하는가"라는 2017년의 질문도 그대로 남아 있다.

---

## 2. Problem Statement

### 2.1 쓰기 증폭의 근원: 수명이 다른 데이터의 혼재
FTL은 덮어쓰기를 새 페이지에 쓰고 옛 페이지를 무효화한다. erase block(또는 superblock) 안에 수명이 다른 데이터가 섞이면 문제가 생긴다. GC는 살아 있는 데이터를 다른 곳으로 옮긴 뒤에야 블록을 지울 수 있다. 장치가 쓴 NAND 바이트를 호스트가 보낸 바이트로 나눈 값이 WAF(CacheLib 논문의 용어로 DLWA)다. 논문은 "A DLWA of 2 causes the SSD to fail twice as fast compared to DLWA of 1"이라고 정리한다. 또 실제 CacheLib 운영 환경은 "50% of the Flash capacity is overprovisioned to keep DLWA within acceptable levels of ~1.3"이었다고 보고한다. WAF를 낮추는 전통적 수단은 두 가지였다. 오버프로비저닝으로 용량을 버리거나, TRIM/Deallocate로 무효 데이터를 알리는 것이다.

### 2.2 세 가지 해법의 스펙트럼
| 해법 | 호스트가 하는 일 | 장치가 하는 일 | 하위 호환 |
|---|---|---|---|
| 오버프로비저닝 | 없음 (용량 포기) | 전부 | 예 |
| Streams Directive (NVMe 1.3) | 쓰기에 stream ID 첨부 | 매핑·GC, stream별 블록 분리 | 예 |
| FDP (TP4146) | 쓰기에 placement handle 첨부, 로그로 효과 확인 | 매핑·GC, Reclaim Unit 단위 분리 | 예 |
| ZNS | zone 순차 쓰기, GC, active zone 관리 | 거친 매핑, 신뢰성 | 아니오 |

NVM Express의 FMS 2023 "Flexible Data Placement: State of the Union"(Google·Meta·Samsung 공동 발표)은 FDP의 출신을 이렇게 설명한다. Google은 "SMART FTL Proposal", Meta는 "Direct Placement Mode Proposal"을 각각 냈다. 두 회사가 "merged their independent learnings into Flexible Data Placement"했다는 것이다. 같은 자료는 "TP4146 is fully ratified"라고 쓰고, 2022-12-12자 NVMe 2.0 Ratified TPs 묶음을 링크한다.

### 2.3 리눅스 쪽 문제: 정보를 장치까지 운반할 경로
데이터 수명을 가장 잘 아는 것은 애플리케이션(RocksDB의 SST 레벨, CacheLib의 small/large object 엔진)이나 파일시스템(저널, 메타데이터, 핫/콜드 데이터)이다. 이 정보가 장치에 닿으려면 다음 단계를 모두 거쳐야 한다.
1. 사용자 공간 API (fcntl, `RWF_*`, io_uring SQE 필드)
2. VFS (`struct kiocb`, `struct inode`)
3. 블록 계층 (`struct bio`, `struct request`, 병합 규칙)
4. 드라이버 (NVMe DTYPE/DSPEC 필드, SCSI GROUP NUMBER)

중간 어느 계층이라도 정보를 버리면 기능은 사라진다. 2022년 제거 당시에는 소비자(드라이버)가 없어 운반 경로 전체가 사라졌다. 2024–2025년 복원은 경로를 다시 깔면서 "힌트(hint)"와 "stream(장치 자원 식별자)"을 분리하는 방향으로 진행됐다.

### 2.4 왜 이전 시도는 실패했나
LSFMM+BPF 2025 보도(LWN "Flexible data placement")에 따르면 Martin Petersen은 실패 원인을 이렇게 짚었다. 예컨대 8개 정도의 태그를 장치 위 여러 파일시스템이 나눠 써야 하는데, "the tag values are a scarce resource"라는 것이다. Busch는 다른 원인을 들었다. 예전 장치는 피드백 수단이 없어 힌트가 효과가 있는지 측정할 수 없었다. FDP는 이 문제에 대한 답으로 장치 로그 페이지(통계·이벤트)를 함께 정의했다.

---

## 3. The Debate

### 3.1 2016–2017: 숫자 stream ID인가, 수명 힌트인가
Axboe는 2016-03-04 "[PATCH 0/11] Update version of write stream ID patchset"에서 처음 숫자 stream ID를 노출하려 했다. 1년 뒤 방향을 바꿨다. 2017-06-26의 "[PATCHSET v10] Add support for write life time hints" 커버 레터는 이렇게 설명한다.

> "Contrary to previous patches, we're not exposing numeric stream values anymore. I've previously advocated for just doing a set of hints that makes sense instead."
>
> "The idea is that these are relative values, so an application can use them as they see fit. The underlying device can then place data appropriately, or be free to ignore the hint. It's just a hint."
>
> — Jens Axboe, 2017-06-26 (LWN 게시본: https://lwn.net/Articles/726477/)

같은 커버 레터는 동기를 두 가지로 든다. 하나는 NVMe 1.3에서 Directives가 비준된 것이다. 다른 하나는 Facebook 내부 테스트에서 "up to a 25% reduction in NAND writes in a RocksDB setup"이 나온 것이다. Christoph Hellwig의 우려를 반영해 NVMe `streams` 모듈 파라미터를 추가하고 기본값을 off로 두었다. 이 파라미터의 흔적은 5.17까지 `module_param(streams, bool, 0644)`로 남아 있다. 이 설계가 4.13에 들어갔다. 핵심은 VFS가 장치 자원(stream 번호)을 모르고 의미(수명)만 운반하며, 드라이버가 의미를 장치 자원으로 사상한다는 것이다.

### 3.2 2022: "아무도 쓰지 않는다"
5년 뒤 Hellwig가 NVMe streams 지원 제거 패치를 냈다. Keith Busch의 2022-03-03 답장(linux-nvme)에 원문이 인용되어 있다.

> "> This support was added for RocksDB, but RocksDB ended up not using it. At the same time drives on the open marked (vs those build for OEMs for non-Linux support) that actually support streams are extremly rare. Don't bloat the nvme driver for it.
>
> Fine with me. It looks like the early interest in streams never really materialized, so it's unlikely we'll hear any complaints. … And without nvme, there doesn't appear to be a real user for the write_hint anymore. All you can really do with it now is prevent merging, which doesn't seem useful."
>
> — Keith Busch (Christoph Hellwig 원문 인용 포함), 2022-03-03, https://lists.infradead.org/pipermail/linux-nvme/2022-March/030256.html

(원문의 "marked", "extremly" 오탈자는 그대로 두었다.)

Axboe는 5.18 머지 태그(`for-5.18/write-streams-2022-03-18`, 2022-03-26 Linus 머지)에서 결정을 요약했다. "No vendor ever really shipped working support for this, and they are not interested in supporting it." 그는 논쟁점도 하나 남겼다. 파일 단위 fcntl(`F_{GET,SET}_FILE_RW_HINT`)이 다시 `-EINVAL`을 돌려주게 된다는 점이다. 그는 "it's always a bit controversial"이라고 인정했다. 동시에 "No known applications use these functions"라는 판단으로 강행했다. 이 머지에는 네 커밋이 포함됐다. `nvme: remove support or stream based temperature hint`, `block: remove the per-bio/request write hint`, `fs: remove kiocb.ki_hint`, `fs: remove fs.f_write_hint`다. `struct request`의 `write_hint`는 2022-10 Bart Van Assche의 "block: Remove request.write_hint"(6.2)로 마저 정리됐다.

이 결정이 주는 교훈은 분명하다. 커널은 **실제 소비자가 없는 인터페이스를 유지하지 않는다.** 하드웨어 생태계가 따라오지 않으면 uAPI도 기능을 잃는다.

### 3.3 2024: UFS가 힌트를 되살리다
2년 뒤 반대 방향의 요구가 모바일에서 나왔다. Christian Brauner의 6.9 머지 태그 `vfs-6.9.rw_hint`(2024-03-04)는 Van Assche 시리즈의 근거를 이렇게 옮긴다.

> "UFS devices are widely used in mobile applications, e.g. in smartphones. UFS vendors need data lifetime information to achieve good performance. Providing data lifetime information to UFS devices can result in up to 40% lower write amplification."
>
> — `vfs-6.9.rw_hint` 머지 커밋 메시지, 2024-03-04 (https://github.com/torvalds/linux/commit/86835c39e08e)

이 시리즈가 한 일은 다음과 같다.
- `enum rw_hint`를 `include/linux/rw_hint.h`로 분리했다.
- 블록 디바이스에 대한 `F_SET_RW_HINT`를 지원했다.
- `bio.bi_write_hint`를 복원했다. 커밋에 따르면 `struct bio`의 구멍을 메워 크기 증가가 없다.

SCSI `sd`의 GROUP NUMBER 기반 데이터 수명 지원도 같은 6.9에 들어갔다(`drivers/scsi/sd.c`의 "stream" 문자열이 v6.8 0회, v6.9 22회; `permanent_stream_count`와 `rq->write_hint` 기반 GROUP NUMBER 선택이 v6.9에 처음 나타난다).

### 3.4 2024–2025: FDP를 힌트로 운반할 것인가, stream으로 운반할 것인가
FDP 장치가 시장에 나오자 Busch는 처음에 복원된 write hint를 FDP placement handle로 사상하려 했다. LWN의 LSFMM+BPF 2025 보도(Jake Edge, 2025-05-02)는 이 대립을 이렇게 기록한다.
- Busch는 "currently a no-op"인 기존 write-hints 인터페이스를 FDP에 쓰고 싶었다고 말했다.
- Hellwig는 애플리케이션이 준 태그 값을 올바르게 사상하려면 파일시스템이 개입해야 한다고 주장했다.
- Busch는 파일시스템 개입이 낫지만 "lots of work"가 든다고 답했다. 애플리케이션에 맡기는 쪽이 "an easier path, with some of the benefits"라는 것이다.
- Josef Bacik은 btrfs가 태그 중재자가 되기를 원치 않았다. 블록 계층이 중재하기를 바랐다.

결과는 6.16 커밋에 남아 있다. Busch의 `block: introduce max_write_streams queue limit`(2025-05-06)에는 Hellwig의 손질 내역이 "[hch: renamed hints to streams, removed stacking]"으로 적혀 있다. 즉 다음 세 가지가 결정됐다.
1. 의미 기반 힌트(`bi_write_hint`, `RWH_*`)와 장치 자원 번호(`bi_write_stream`)는 **별개 필드**다.
2. stream 수는 장치가 광고한다(`max_write_streams`).
3. DM 같은 스택 장치로의 전파(stacking)는 일단 뺀다.

시리즈는 Kanchan Joshi가 정리해 올렸다(`Link: …/20250506121732.8211-4-joshi.k@samsung.com`). Jens Axboe의 `for-6.16/block-20250523` 머지에 "Add support for block write streams via FDP (flexible data placement)"로 들어갔다.

### 3.5 ZNS vs FDP: 같은 문제, 다른 계약
FMS 2023 FDP 자료는 Streams·FDP·ZNS를 나란히 비교한 표를 싣고 있다. 요약하면 다음과 같다.

| 항목 | ZNS | FDP | Streams |
|---|---|---|---|
| 규칙 위반 쓰기 | 오류 | 로그에 기록 | 기록 안 됨 |
| WAF=1 | 보장 | 피드백으로 달성 가능 | 피드백 없이 달성 가능 |
| 하위 호환 | 아니오 | 예 | 예 |
| 장치의 데이터 이동 | 호스트에 이동 요청 알림 | 이동 사실을 사후 로그 | 정보 없음 |
| 배치 식별자 | LBA 자체 | LBA와 무관 | LBA와 무관 |
| 단위 | Zone (capacity ≤ size) | Reclaim Unit (capacity = size) | Stream Granularity Size |
| 쓰기 패턴 | 순차만, 경계 넘기 불가 | 순차·랜덤·덮어쓰기, 경계 넘기 허용 | 순차·랜덤·덮어쓰기 |
| QD>1의 LBA 결정 | 완료 시 (Zone Append) | 제출 시 | 제출 시 |
| 다중 namespace 공유 | zone은 한 namespace 전용 | RU를 여러 namespace가 공유 | stream은 한 namespace 전용 |
| API 상태 | stateful | stateless | stateless |
| FTL 매핑 테이블 | 전체 불필요 | 전체 필요 | 전체 필요 |

FDP가 채택에 유리한 이유는 이 표에 다 있다. 장치 DRAM 절감(ZNS의 장점)을 포기하는 대신, 다음 성질을 얻었다.
- 힌트를 무시하는 소프트웨어도 그대로 동작한다.
- 덮어쓰기와 랜덤 쓰기가 가능하다.
- active zone 같은 상태를 관리하지 않는다.

FMS 자료 표현으로는 "If the $$$ to update SW is greater that SSD WAF savings, then do not update the SW"다. 소프트웨어를 고칠지 말지를 호스트가 경제성으로 고르게 한 것이다.

---

## 4. Implementation Impact

### 4.1 FDP 규격의 실체 (TP4146a, FMS 2023 자료와 CacheLib 논문 기준)
- **Endurance Group**: FDP가 켜지는 단위다. FDP 설정은 namespace가 아니라 endurance group 단위 Set Features(`NVME_FEAT_FDP`)로 켠다. FDP를 켜거나 끌 때 기존 namespace를 지우고 다시 만들어야 한다고 알려져 있다 [추측/미확인: 규격 원문 미확인]. Busch는 LSFMM에서 "It takes a few minutes to configure it for a new drive"라고 했다.
- **Reclaim Unit(RU)**: 장치가 한 번에 지우고 재사용하는 NAND 단위다. 크기는 FDP Configurations 로그의 `RUNS`(Reclaim Unit Nominal Size)로 광고된다.
- **Reclaim Group(RG)**: RU의 묶음이다. 보통 다이·채널 등 물리 병렬 단위에 대응한다.
- **Reclaim Unit Handle(RUH)**: 현재 쓰기 중인 RU를 가리키는 포인터다. 호스트는 쓰기 명령에 **Placement Handle**(namespace별로 RUH를 가리키는 인덱스)과 RG를 묶은 **Placement Identifier**를 붙인다.
- **RUH 유형**: CacheLib 논문 §3은 두 가지를 설명한다.
  - **Initially Isolated**: 처음에만 분리되고, GC 시 다른 initially-isolated RUH의 데이터와 섞일 수 있다. 구현이 가장 싸다.
  - **Persistently Isolated**: GC 후에도 분리가 유지된다. 대신 컨트롤러가 RUH별 추적을 해야 해서 비싸다.
- **피드백**: FDP Statistics 로그(libnvme `struct nvme_fdp_stats_log`의 `hbmw` Host Bytes with Metadata Written, `mbmw` Media Bytes with Metadata Written, `mbe` Media Bytes Erased)로 실측 WAF를 계산할 수 있다. FDP Events 로그로 RU 교체나 규칙 위반 같은 사건을 볼 수 있다. Busch가 강조한 "previous efforts … lacked for any kind of feedback mechanism"에 대한 답이 이것이다.

### 4.2 NVMe 드라이버 경로 (Linux 7.3-rc7 `drivers/nvme/host/core.c`)
네임스페이스 스캔 시 컨트롤러 `CTRATT`에 `NVME_CTRL_ATTR_FDPS`가 있으면 `nvme_query_fdp_info()`를 호출한다.

```
nvme_query_fdp_info(ns, info)
  ├─ nvme_get_features(ctrl, NVME_FEAT_FDP, info->endgid, …, &fdp)
  │     └─ !(fdp.flags & FDPCFG_FDPE) 이면 FDP 미사용으로 종료
  ├─ nvme_query_fdp_granularity(ctrl, info, fdp.fdpcidx)
  │     ├─ nvme_get_log_lsi(…, NVME_LOG_FDP_CONFIGS, …)  // 헤더 → 전체 2회 읽기
  │     ├─ fdpcidx 범위 검사, 설명자 순회
  │     ├─ desc->nrg > 1 → "FDP NRG > 1 not supported" (stream 미등록)
  │     └─ info->runs = desc->runs
  ├─ I/O Management Receive (nvme_cmd_io_mgmt_recv, MO = NVME_IO_MGMT_RECV_MO_RUHS)
  │     └─ Reclaim Unit Handle Status: nruhsd, ruhsd[i].pid
  ├─ head->nr_plids = min(nruhsd, NVME_MAX_PLIDS)        // NVME_MAX_PLIDS = U8_MAX
  ├─ head->plids[i] = ruhsd[i].pid
  └─ head->write_stream_granularity = min(info->runs, U32_MAX)
nvme_update_ns_info_block()
  └─ lim.max_write_streams = head->nr_plids; lim.write_stream_granularity = …
```

쓰기 명령 구성(`nvme_setup_rw()` 계열)은 다음과 같다.
```
if (op == nvme_cmd_write && ns->head->nr_plids) {
    u16 write_stream = req->bio->bi_write_stream;
    if (WARN_ON_ONCE(write_stream > ns->head->nr_plids)) return BLK_STS_INVAL;
    if (write_stream) {
        dsmgmt |= ns->head->plids[write_stream - 1] << 16;   // DSPEC = placement id
        control |= NVME_RW_DTYPE_DPLCMT;                       // DTYPE = Data Placement
    }
}
```

5.17까지의 Streams 경로(`nvme_assign_write_stream()`)와 구조가 거의 같다. 옛 경로는 `req->write_hint - 1`을 DSPEC에 넣고 `NVME_RW_DTYPE_STREAMS`를 세웠다. 차이는 두 가지다. 첫째, **번호의 출처**가 수명 힌트에서 장치가 광고한 placement ID 배열로 바뀌었다. 둘째, **기본값이 off인 모듈 파라미터가 없다.** 장치가 FDP를 켜면 바로 쓸 수 있다. 소스 주석은 `bi_write_stream`이 u8이라서 255를 넘는 placement handle은 고를 수 없다고 명시한다. 2026년에도 수정이 이어졌다. `nvme: fix FDP fdpcidx bounds check`(2026-05-28), `nvme: fix racy access to FDP placement id array`(2026-08-18)가 그 예로, 아직 젊은 코드임을 보여 준다.

### 4.3 블록 계층·VFS·io_uring 운반 경로 (6.16+)
| 계층 | 필드/인터페이스 | 확인 위치 |
|---|---|---|
| io_uring uAPI | SQE `__u8 write_stream` (+ `__pad4[3]`) | `include/uapi/linux/io_uring.h` |
| io_uring 준비 | `rw->kiocb.ki_write_stream = READ_ONCE(sqe->write_stream)` | `io_uring/rw.c` |
| VFS | `struct kiocb::ki_write_stream` | `block/fops.c` 사용처 |
| 블록 디바이스 direct I/O | `ki_write_stream > bdev_max_write_streams()` 이면 `-EINVAL` | `blkdev_direct_IO` 경로 (`block/fops.c`) |
| bio | `u8 bi_write_stream` (`enum rw_hint bi_write_hint` 바로 뒤) | `include/linux/blk_types.h` |
| 장치 한도 | `queue_limits.max_write_streams`, `write_stream_granularity` | `block/blk-sysfs.c` |
| sysfs | `/sys/block/<disk>/queue/max_write_streams`, `write_stream_granularity` (RO, ABI 문서 Date: November 2024) | `Documentation/ABI/stable/sysfs-block` |

`block/fops.c`에는 실용적인 폴백도 있다. SQE에 stream을 지정하지 않았는데 장치가 stream을 지원하면, inode의 `i_write_hint`(즉 `F_SET_RW_HINT` 값)가 `max_write_streams` 이하일 때 그 값을 stream 번호로 쓴다. 주석은 "This assumes no file system is mounted that would use the streams differently"라고 경고한다. 그래서 블록 디바이스 raw 접근에서는 2017년 fcntl 힌트가 사실상 FDP placement 선택기로 재활용된다. 6.16 태그에 이미 이 폴백이 있다.

ABI 문서는 granularity를 이렇게 정의한다. "the size that should be discarded or overwritten together to avoid write amplification in the device." 애플리케이션은 stream별 데이터를 이 단위로 모아 무효화해야 이득을 본다.

### 4.4 파일시스템 통합 현황 (7.3-rc7 grep 기준)
- **f2fs** (7.2부터, v7.1 `fs/f2fs/data.c` 0회 → v7.2 1회): `f2fs_io_type_to_write_stream()`이 DATA 타입에만 stream을 붙인다. 장치 stream 수가 온도 분류 수(`NR_TEMP_TYPE`, hot/warm/cold)보다 적으면 COLD에 마지막 stream을, 나머지에 `HOT + 1`을 준다. 충분하면 `temp + 1`로 1:1 사상한다. 같은 bio에 의미 힌트(`bi_write_hint`, `f2fs_io_type_to_rw_hint()`)도 함께 붙인다. f2fs는 "hint와 stream을 동시에 쓰는" 첫 사례다.
- **iomap 기반 FS(XFS 등)·ext4·btrfs**: `fs/iomap/direct-io.c`는 `bi_write_hint`만 전달하고 `write_stream`은 전달하지 않는다(grep 0회). `fs/xfs/xfs_file.c`, `fs/ext4/inode.c`, `fs/btrfs/bio.c`에서도 `write_stream`은 0회다. LSFMM 2025에서 Joshi가 말한 "connecting up FDP to filesystem I/O in the iomap interface is still an unsolved problem"이 2026-10에도 유효하다.
- **ext4**: 2024-09 커밋 `ext4: pass write-hint for buffered IO`가 있다. 하지만 이는 의미 힌트 경로이며 FDP stream과는 별개다.

### 4.5 사용자 공간 도구와 애플리케이션
- **nvme-cli `fdp` 플러그인**: `nvme fdp configs | usage | stats | events | status | update | set-events | feature`(`plugins/fdp/fdp.c`). `stats`는 endurance group 단위 FDP Statistics 로그를 읽어 실측 WAF 계산에 쓴다.
- **I/O Passthru 경로**: FMS 2023 자료에 따르면 FDP는 "Upstream since 5.19 … Full Support through I/O Passthru"였다. 즉 6.16 이전에도 `/dev/ngXnY` + `IORING_OP_URING_CMD`로 DTYPE/DSPEC를 직접 채우면 FDP를 쓸 수 있었다. CacheLib 논문의 구현도 이 방식으로, placement handle을 uring_cmd I/O에 붙여 제출한다. 같은 자료는 xNVMe(v0.7+), QEMU FDP 에뮬레이션(v8.0+), fio 지원도 열거한다.
- **CacheLib**: 논문 §3은 small object cache와 large object cache를 서로 다른 RUH로 분리했다고 설명한다. 이 변경은 "merged in the upstream repository and deployed at scale"이라고 한다. 같은 논문 §3.5는 한계로 "The FDP technical proposal was ratified at the end of 2022"와 장치가 이제 막 나오고 있다는 점(Samsung PM9D3a 등)을 든다.

### 4.6 레거시 vs 현행 인터페이스 비교
| 항목 | 4.13–5.17 (Streams) | 5.18–6.8 (공백기) | 6.9+ (힌트 복원) | 6.16+ (write stream) |
|---|---|---|---|---|
| 사용자 공간 지정 | `F_SET_RW_HINT`, `F_SET_FILE_RW_HINT` (uAPI의 `RWF_WRITE_LIFE_NOT_SET`은 `RWH_*` 별칭일 뿐 `RWF_SUPPORTED`에 포함된 per-I/O 플래그가 아님) | `F_SET_RW_HINT`(inode 저장만) | `F_SET_RW_HINT` (블록 디바이스 포함) | io_uring SQE `write_stream`, 또는 bdev에서 `F_SET_RW_HINT` 폴백 |
| VFS 운반 | `kiocb.ki_hint`, `file.f_write_hint` | 없음 (제거) | `inode.i_write_hint` | `kiocb.ki_write_stream` |
| bio/request | `bi_write_hint`, `rq->write_hint` | `rq->write_hint`만 6.1까지 잔존 | `bi_write_hint`, `rq->write_hint` 복원 | `bi_write_stream` (u8) 추가 |
| 의미 | 상대 수명 (SHORT…EXTREME) | - | 상대 수명 | 장치 자원 번호 (1..max_write_streams) |
| 소비 드라이버 | NVMe Streams Directive (`NVME_RW_DTYPE_STREAMS`, 모듈 파라미터 `streams` 기본 off) | 없음 | SCSI `sd` (UFS 데이터 수명) | NVMe FDP (`NVME_RW_DTYPE_DPLCMT`) |
| 장치 자원 광고 | 드라이버 내부 `nr_streams` | - | - | sysfs `max_write_streams`, `write_stream_granularity` |
| 병합 영향 | 힌트 다르면 병합 금지 | - | `bi_write_hint` 다르면 병합 금지 (`blk-merge.c`) | `bi_write_stream` 다르면 병합 금지 (`blk-merge.c`) |

### 4.7 운영상 트레이드오프
1. **stream 수가 적다.** FDP 장치의 RUH 수는 보통 한 자릿수에서 수십 개 수준이다 [추측/미확인: 대표 값은 장치별]. 리눅스는 u8 한도로 최대 255개까지만 표현한다. 여러 테넌트와 파일시스템이 나눠 쓰는 중재 정책은 커널에 없다. 2026-10 현재 이 정책은 운영자나 애플리케이션 몫이다.
2. **단일 Reclaim Group만 지원한다.** FDP 설정 설명자의 `nrg`(Reclaim Group 수)가 1보다 크면 드라이버가 stream을 등록하지 않는다("FDP NRG > 1 not supported"). 다중 RG를 활용하는 고급 배치는 패스스루로만 가능하다.
3. **DM·MD 스택을 지나지 못한다.** "removed stacking"에 따라 LVM/dm-crypt 위에서는 `max_write_streams`가 전파되지 않는다고 보는 것이 안전하다 [추측/미확인: DM 타깃별 최신 상태 미확인].
4. **효과를 측정해야 한다.** Petersen이 지적했듯 장치·FS·애플리케이션 조합마다 결과가 다르다. `nvme fdp stats`로 `mbmw/hbmw`를 전후 비교하는 것이 FDP 도입의 기본 절차다.
5. **ZNS와 비교하면** FDP는 장치 DRAM과 OP 비용을 그대로 남긴다. 대신 소프트웨어 수정 범위를 "쓰기 경로에 번호 하나"로 줄였다. 시장 신호(Meta 구매 SSD 전량 FDP 지원, 주요 벤더 지원)는 FDP 쪽이 더 강하다. 다만 이는 LSFMM 발언 기준이며, 출하 통계로는 확인하지 못했다.

### 4.8 연표
| 시점 | 사건 |
|---|---|
| 2016-03 | Axboe "Update version of write stream ID patchset" (숫자 stream ID 방식) |
| 2017 (NVMe 1.3) | Directives/Streams 비준 (Axboe 2017 커버 레터 서술) |
| 4.13 | `F_{GET,SET}_RW_HINT`, `F_{GET,SET}_FILE_RW_HINT`, NVMe Streams 지원 |
| 5.18 | NVMe streams, per-bio 힌트, `ki_hint`, `f_write_hint` 제거 (`for-5.18/write-streams`) |
| 5.19 | I/O Passthru(uring_cmd) → FDP를 패스스루로 사용 가능 (FMS 2023 자료) |
| 6.2 | `request.write_hint` 제거 |
| 2022-12 | TP4146 FDP 비준 (NVMe 2.0 Ratified TPs 2022-12-12) |
| 6.9 | `bi_write_hint` 복원, `rw_hint.h`, bdev `F_SET_RW_HINT`, SCSI sd 데이터 수명 |
| 6.16 | block write streams: `max_write_streams`, `write_stream_granularity`, `bi_write_stream`, io_uring `write_stream`, NVMe FDP |
| 7.2 | f2fs가 write stream 사용 |

---

## 5. Primary References

- [lwn.net - Flexible data placement](https://lwn.net/Articles/1018642/) — Jake Edge, LSFMM+BPF 2025, 2025-05-02
- [lwn.net - Add support for write life time hints](https://lwn.net/Articles/726477/) — Jens Axboe, [PATCHSET v10], 2017-06-26
- [lwn.net - Update version of write stream ID patchset](https://lwn.net/Articles/679136/) — Jens Axboe, 2016-03-04
- [lists.infradead.org - [PATCH] nvme: remove support or stream based temperature hint](https://lists.infradead.org/pipermail/linux-nvme/2022-March/030256.html) — Keith Busch 답장(linux-nvme 공식 아카이브), 2022-03-03
- [github.com/torvalds/linux - Merge tag 'for-5.18/write-streams-2022-03-18'](https://github.com/torvalds/linux/commit/561593a048d7) — 5.18 NVMe streams·write hint 제거 머지, 2022-03-26
- [github.com/torvalds/linux - Merge tag 'vfs-6.9.rw_hint'](https://github.com/torvalds/linux/commit/86835c39e08e) — 6.9 `bi_write_hint` 복원 머지, 2024-03-04
- [github.com/torvalds/linux - block: introduce max_write_streams queue limit](https://github.com/torvalds/linux/commit/d2f526ba27d2) — 6.16 write stream 시리즈, Keith Busch, 2025-05-06
- [github.com/torvalds/linux - block: introduce a write_stream_granularity queue limit](https://github.com/torvalds/linux/commit/c23acfac1078) — 6.16 write stream granularity, Christoph Hellwig, 2025-05-06
- [github.com/torvalds/linux - drivers/nvme/host/core.c](https://github.com/torvalds/linux/blob/master/drivers/nvme/host/core.c) — `nvme_query_fdp_info()`, FDP 쓰기 경로
- [github.com/torvalds/linux - block/fops.c](https://github.com/torvalds/linux/blob/master/block/fops.c) — 블록 디바이스 direct I/O의 write stream 검사·폴백
- [nvmexpress.org - Flexible Data Placement: State of the Union (FMS 2023)](https://nvmexpress.org/wp-content/uploads/FMS-2023-Flexible-Data-Placement-FDP-Overview.pdf) — Google·Meta·Samsung FDP 공동 발표 자료
- [arxiv.org - Towards Efficient Flash Caches with Emerging NVMe Flexible Data Placement SSDs](https://arxiv.org/abs/2503.11665) — EuroSys '25 (DOI 10.1145/3689031.3696091)
- [github.com/linux-nvme - nvme-cli plugins/fdp/fdp.c](https://github.com/linux-nvme/nvme-cli/blob/master/plugins/fdp/fdp.c) — nvme-cli `fdp` 플러그인
- [kernel.org - sysfs-block ABI](https://www.kernel.org/doc/Documentation/ABI/stable/sysfs-block) — `max_write_streams`, `write_stream_granularity` ABI 정의
