# Zoned Storage: SMR에서 ZNS로, 그리고 리눅스 zoned block device 모델 · zonefs · ZenFS

> 기준 소스: Linux 7.3-rc7 (`torvalds/linux` master, 2026-10 확인) `block/blk-zoned.c`, `include/uapi/linux/blkzoned.h`, `include/linux/blkdev.h`, `drivers/nvme/host/zns.c`, `Documentation/filesystems/{zonefs,f2fs}.rst`, `fs/xfs/Kconfig`. 도입 버전은 git.kernel.org의 `plain/<path>?h=vX.Y` 태그별 grep으로 고정했다. 논문 수치는 Bjørling et al., USENIX ATC '21 본문(pp. 689–703)에서 옮겼다.

## 1. Verdict

Zoned storage는 "장치가 순차 쓰기 제약을 숨기지 않고 호스트에 드러낸다"는 계약이다. SMR(Shingled Magnetic Recording) HDD가 먼저 이 계약을 들고 왔고, NVMe ZNS(Zoned Namespace) SSD가 같은 추상화를 플래시로 가져왔다. 리눅스는 4.10부터 이 둘을 하나의 **zoned block device** 모델로 묶었다. 이후 10년 가까이 블록 계층·파일시스템·디바이스 매퍼·사용자 공간 라이브러리가 차례로 따라왔다.

핵심 결론은 다음과 같다.

1. **커널 모델은 성숙했다.** zone 유형 3종, zone condition 7종(+6.19의 캐시 전용 `BLK_ZONE_COND_ACTIVE`), `REQ_OP_ZONE_APPEND`(5.8), zone 관리 ioctl(`BLKREPORTZONE`/`BLKRESETZONE` 4.10, `BLKOPENZONE`/`BLKCLOSEZONE`/`BLKFINISHZONE` 5.5, `BLKREPORTZONEV2` 6.19)이 안정 uAPI다.
2. **쓰기 순서 보장 메커니즘이 6.10에서 바뀌었다.** 4.16~6.9는 mq-deadline 스케줄러 안의 **zone write locking**이 같은 zone에 대한 쓰기를 한 번에 하나로 제한했다. 6.10부터는 블록 계층 상단의 **zone write plugging**(`struct blk_zone_wplug`)이 BIO 단계에서 zone별로 쓰기를 직렬화한다. 그래서 더 이상 특정 I/O 스케줄러에 의존하지 않는다. 6.10 태그의 `block/mq-deadline.c`에는 "zone" 문자열이 0회 나온다(6.9는 40줄, 46회).
3. **소프트웨어 스택은 넓게 갖춰졌다.** zonefs(5.6), f2fs(4.10, ZNS zone capacity 대응은 이후), btrfs zoned 모드(5.12, 기반 코드는 5.11), dm-zoned(4.13), XFS 실시간 서브볼륨 기반 zoned 지원(6.15), RocksDB용 ZenFS, 사용자 공간 `libzbd`가 있다.
4. **채택 범위는 좁다.** ZNS는 호스트가 GC·배치·active zone 한도를 직접 관리해야 한다. 그래서 LSM-tree나 로그 구조 파일시스템처럼 원래 순차 쓰기를 하는 소프트웨어에서만 이득이 분명하다. 업계는 "호스트 수정이 덜 필요한" 대안으로 NVMe FDP(Flexible Data Placement)를 함께 밀고 있다(→ 09/02). SMR HDD는 대규모 사업자의 콜드 스토리지에서 계속 쓰인다. ZNS SSD는 범용 서버 시장에서 널리 보급되었다고 말할 근거가 1차 자료에 없다 [추측/미확인: 출하량 통계는 확인하지 못함].

ZNS 논문(ATC '21)의 대표 결과는 "zone-specialized RocksDB(ZenFS)의 99.9 백분위 랜덤 읽기 지연이 블록 인터페이스 SSD 대비 2–4배 낮고, 쓰기 처리량은 2배"다. 같은 물리 하드웨어를 ZNS(OP 0%)와 블록 인터페이스(OP 7%/28%)로 펌웨어만 바꿔 비교했다. 이 수치는 **해당 장치·해당 워크로드 조건의 결과**다. 일반 SSD 대비 보편적 이득으로 읽으면 안 된다.

---

## 2. Problem Statement

### 2.1 블록 인터페이스 세금(block interface tax)
NAND 플래시는 페이지 단위로 쓰고 erase block 단위로 지운다. 덮어쓰기가 불가능하다. 기존 SSD는 FTL(Flash Translation Layer)이 LBA→물리 주소 매핑을 유지해 "임의 위치 덮어쓰기"라는 블록 인터페이스 환상을 제공한다. ZNS 논문 §2.1과 §3.1이 이 비용을 정리한다.

- **매핑 테이블 DRAM**: 완전 연관(fully-associative) 매핑은 "often requires 1GB of mappings per 1TB of media capacity"(논문 §3.1). 순차 쓰기만 허용하는 zone이면 erase block 단위나 하이브리드의 거친 매핑으로 충분하다.
- **오버프로비저닝(OP)**: GC를 위해 사용자에게 보이지 않는 용량을 남긴다. 논문 Table 3 기준으로 같은 2 TiB 미디어가 블록 SSD에서는 1.92 TB(OP 7%) 또는 1.60 TB(OP 28%), ZNS에서는 2 TB(OP 0%)로 노출된다.
- **장치 내부 GC와 쓰기 증폭**: 호스트가 수명이 다른 데이터를 같은 erase block에 섞어 쓰면, 장치 GC가 유효 페이지를 옮기며 WAF(Write Amplification Factor)를 키운다. 그 결과 꼬리 지연이 튄다.
- **호스트 측 중복 작업**: LSM-tree(RocksDB)나 로그 구조 파일시스템(f2fs)은 이미 자체 GC/compaction을 한다. 그 아래에서 FTL이 또 GC를 하는 "로그 위의 로그" 문제가 생긴다.

### 2.2 SMR HDD의 동일한 문제
SMR HDD는 트랙을 기와처럼 겹쳐 기록 밀도를 높인다. 그 대가로 한 트랙을 쓰면 인접 트랙이 손상되어 영역(zone) 내 순차 쓰기만 안전하다. T10 ZBC(SCSI)와 T13 ZAC(ATA)가 이를 표준화했다. 유형은 세 가지다.
- **drive-managed**: 장치가 숨긴다.
- **host-aware**: 순차 선호, 랜덤도 허용.
- **host-managed**: 순차 필수.

리눅스 uAPI의 `BLK_ZONE_TYPE_SEQWRITE_REQ`/`SEQWRITE_PREF`가 이 구분을 반영한다. `struct blk_zone`이 64바이트인 이유도 주석에 적혀 있다. "to match the ZBC, ZAC and ZNS defined zone descriptor"(`include/uapi/linux/blkzoned.h`).

### 2.3 플래시 zone만의 추가 제약
ZNS는 SMR과 같은 모델을 쓰지만, 플래시 고유의 제약 두 가지를 추가로 노출한다.

- **Zone Capacity < Zone Size**: 블록 계층은 zone 크기가 2의 거듭제곱이기를 요구한다. 반면 플래시 erase block 묶음의 실제 쓰기 가능 용량은 그렇지 않을 수 있다. 그래서 ZNS는 zone마다 "writeable zone capacity"를 따로 둔다. 논문 평가 장치는 zone size 2048 MiB에 zone capacity 1077 MiB였다(Table 3). 커널은 5.9에서 `struct blk_zone`에 `capacity` 필드와 `BLK_ZONE_REP_CAPACITY` 플래그를 추가했다.
- **Active/Open zone 한도**: 부분적으로 쓰인 zone(open 또는 closed = active)마다 XOR 엔진, SRAM/DRAM 쓰기 버퍼, 패리티를 보존할 전력 커패시터가 필요하다. 논문은 "ZNS SSDs are expected to have 8-32 active zones"라고 쓴다. 평가 장치의 Max Active Zones는 14였다. SMR HDD에는 이런 한도가 없다. 그래서 커널 속성 값이 0(무한)이다.

### 2.4 호스트 소프트웨어가 떠안는 것
zone 모델에서 호스트는 다음을 직접 해야 한다.
1. 각 zone의 write pointer 위치에 정확히 맞춰 쓰기
2. 같은 zone에 대한 다중 in-flight 쓰기의 순서 보장
3. zone 리셋 전에 유효 데이터를 옮기는 GC
4. active zone 수를 장치 한도 안에 유지하기

리눅스 커널의 과제는 이 부담을 어디까지 블록 계층이 흡수하고, 어디부터 파일시스템·애플리케이션에 넘길지 정하는 것이었다.

---

## 3. The Debate

### 3.1 쓰기 순서를 어디서 보장할 것인가: 스케줄러의 zone write locking vs BIO 단계의 zone write plugging
zoned 장치에 같은 zone 쓰기 두 개가 동시에 나가면 문제가 생긴다. 블록 계층·드라이버·HBA 어디서든 순서가 뒤바뀌면 두 번째 쓰기는 write pointer 불일치로 실패한다. zonedstorage.io의 스케줄러 문서에 따르면 이 문제의 해법은 세 단계를 거쳤다.
- **4.10**: SCSI 디스크 드라이버(`sd_zbc`) 안의 zone write lock
- **4.16**: blk-mq 지원과 함께 I/O 스케줄러로 이동 (legacy `deadline`과 `mq-deadline` 모두; 5.0 이후로는 `mq-deadline`만 남음) (LWN "blk-mq support for ZBC disks")
- **6.10**: zone write plugging으로 교체

zone write locking의 근본 한계는 **request 단위**라는 점이었다. 같은 zone에 이미 쓰기 request가 디스패치되어 있으면, 다음 쓰기는 스케줄러 안에서 대기했다. 이 대기 중에도 request는 스케줄링 태그를 붙잡고 있었다. 결과적으로 사용자는 zoned 장치에 반드시 mq-deadline을 써야 했다. 빠른 NVMe ZNS 장치에서 `none` 스케줄러를 쓸 수 없었던 것이다.

Damien Le Moal이 2024-04-05 linux-block에 올린 v6 커버 레터는 설계 근거를 이렇게 적었다.

> "Unlike ZWL which operates on requests, ZWP operates on BIOs. A zone write plug is simply a BIO list that is atomically manipulated using a spinlock and a kblockd submission work."
>
> "Untangle zone write ordering from the block IO schedulers. This allows removing the restriction on using only mq-deadline for zoned block devices. Any block IO scheduler, including "none" can be used."
>
> — Damien Le Moal, "[PATCH v6 00/28] Zone write plugging", 2024-04-05 (LWN 게시본: https://lwn.net/Articles/968580/)

커버 레터에서 확인할 수 있는 요점은 세 가지다.
1. **태그를 쥐지 않는다.** 대기 중인 BIO는 태그를 잡지 않으므로, 다른 zone의 읽기·쓰기가 막히지 않는다.
2. **Zone Append 에뮬레이션을 일원화한다.** 그때까지 SCSI(`sd_zbc`)와 device mapper가 각자 갖고 있던 에뮬레이션을 제거했다.
3. **bio 기반 드라이버(DM)는 선택적으로 쓴다.** 이 원칙은 현재 소스의 `disk_need_zone_resources()` 주석에도 남아 있다. 내용은 "All request-based zoned devices need zone resources … BIO-based device drivers (e.g. DM devices) are normally responsible for handling zone write ordering"이다.

같은 커버 레터의 측정 결과는 다음과 같다(6.9.0-rc2 기반 block/for-next 대비).
- **zoned null_blk**: ZWP+`none`이 4KB QD1 순차 쓰기에서 +180%. 다중 잡 랜덤 쓰기는 null_blk 내부 spinlock 경합으로 −18%.
- **1 TB NVMe ZNS(2GB zone, max open/active 14)**: ZWP+mq-deadline이 ZWL과 사실상 동일(±3%). `none`도 대부분 ±5% 이내.

즉 **실제 ZNS 장치에서 처리량이 크게 오른 것은 아니다.** 얻은 것은 스케줄러 선택의 자유, 코드 단순화, 에뮬레이션 일원화다. "6.10 이후 ZNS가 빨라졌다"고 일반화하면 안 된다.

이 설계는 이후에도 다듬어졌다. 2026-02-21 Le Moal의 "[PATCH 0/8] Improve zoned (SMR) HDD write throughput" 시리즈는 zone마다 work를 두는 대신 단일 kthread에서 모든 쓰기 BIO를 내보내는 모드를 추가했다. 이 모드는 sysfs 속성 `zoned_qd1_writes`로 제어한다. 커버 레터는 SMR HDD의 raw 블록·XFS 테스트에서 "up to 40% over the current zone write plugging"이라고 적었다. 태그별 grep으로 확인하면 `disk_zone_wplugs_worker()`는 v7.0에 없고 v7.1에 있다. 따라서 **7.1 머지**로 본다.

### 3.2 Zone Append: 순서 대신 "위치를 장치가 정한다"
QD1 직렬화는 장치 병렬성을 버린다. NVMe ZNS가 도입한 Zone Append 명령은 시작 LBA로 zone의 시작 주소를 준다. 장치가 실제로 쓴 위치는 완료 시 돌려준다. 같은 zone에 여러 Append를 동시에 내도 된다. Johannes Thumshirn의 2020-04-27 시리즈(LWN 게시본 "[PATCH v8 00/11] Introduce Zone Append for writing to zoned block devices")는 이 의미를 이렇게 설명한다.

> "Upon completion the block device will respond with the position the data has been placed in the zone. This from a high level perspective can be seen like a file system's block allocator"
>
> — Johannes Thumshirn, 2020-04-27 (https://lwn.net/Articles/818709/)

같은 시리즈는 SCSI·null_blk에 Zone Append를 **에뮬레이션**하기로 했다. 상위 계층이 장치 종류와 관계없이 단일 쓰기 경로를 갖게 하려는 것이다. 이 결정으로 `REQ_OP_ZONE_APPEND`가 5.8에 들어갔다(v5.7 `blk_types.h` 0회, v5.8 1회). 커널 사용자는 두 계층에서 확인된다.
- **btrfs**: `btrfs_use_zone_append()`가 참이면 `fs/btrfs/bio.c`에서 `bio->bi_opf |= REQ_OP_ZONE_APPEND`를 설정한다.
- **NVMe 드라이버**: Zone Append를 지원하지 않는 ZNS 네임스페이스는 **읽기 전용으로 강제**한다. `nvme_query_zone_info()`는 Commands Supported and Effects 로그의 `iocs[nvme_cmd_zone_append]`에 `NVME_CMD_EFFECTS_CSUPP`가 없으면 `NVME_NS_FORCE_RO`를 세운다. 이때 "Zone Append not supported for zoned namespace:%u. Forcing to read-only mode" 경고를 낸다.

반면 사용자 공간 쪽은 다르다. 일반 `write()`/`io_uring` 쓰기 경로에서 Zone Append를 내고 기록 위치를 돌려받는 범용 syscall 인터페이스는 메인라인에 없다. 이 시점에 사용자 공간에서 Zone Append를 직접 내려면 NVMe 패스스루(`/dev/ngXnY` + `IORING_OP_URING_CMD`)를 써야 한다. 2020년 io_uring용 zone append 제안이 있었지만 메인라인에 들어가지 않았다 [추측/미확인: 해당 스레드 결론은 직접 확인하지 못함].

### 3.3 2의 거듭제곱 zone 크기 논쟁
NVMe ZNS 규격 자체는 zone 크기를 2의 거듭제곱으로 강제하지 않는다. 리눅스는 강제한다. 현재 `nvme_query_zone_info()`도 `!is_power_of_2(zi->zone_size)`이면 "invalid zone size" 경고와 함께 `-ENODEV`를 반환한다. 그래서 ZNS 장치는 Zone Capacity로 실사용 용량을 줄이는 방식을 쓴다.

Samsung의 Pankaj Raghav는 npo2(non-power-of-2) 지원 패치를 여러 차례 올렸다. LWN의 LSFMM+BPF 2023 보도("Zoned storage and filesystems", 2023-05)는 반대 논리를 이렇게 전한다.
- Le Moal은 플래시 zone이 기존 SMR 순차 zone과 같아 보여야 한다고 봤다. UFS 벤더가 펌웨어 기능 추가를 피하려고 npo2를 민다고 지적했다. 그는 이렇게 물었다. "Do we want to take the burden of dealing with the non-power-of-two, instead of the drive vendors doing it?"
- Christoph Hellwig도 강하게 반대했다고 참석자가 전했다.
- 최종 결정은 Axboe에게 있다는 말로 세션이 끝났다.

Le Moal은 같은 자리에서 "effectively everything on the market today has zones that are sized as a power of two"라고 말했다. "there are few deployed flash-based zoned-storage systems"라는 상황 인식도 기사에 기록되어 있다. 2026-10 현재 master의 `zns.c`가 여전히 2의 거듭제곱을 요구한다. 따라서 npo2 지원은 **메인라인에 들어가지 않았다.**

### 3.4 어느 계층이 zone을 감출 것인가
zone 제약을 어디서 흡수하느냐에 따라 네 가지 진영이 생겼다.

| 접근 | 대표 구현 | zone을 보는 주체 | 장점 | 비용/한계 |
|---|---|---|---|---|
| 장치 매퍼로 감춤 | dm-zoned (4.13) | dm 타깃 | 기존 파일시스템 그대로 사용 | 장치 내 GC 성격의 재기록을 호스트가 수행, 랜덤 쓰기 성능·쓰기 증폭 |
| zone-aware 범용 FS | f2fs (4.10), btrfs (5.12; ZNS는 5.16), XFS (6.15) | 파일시스템 할당기 | POSIX 호환 유지, 애플리케이션 무수정 | FS 메타데이터 배치·GC·ENOSPC 처리 복잡 |
| 얇은 FS | zonefs (5.6) | 애플리케이션(파일=zone) | POSIX 파일 API로 zone 직접 접근, 오버헤드 최소 | 시퀀셜 파일은 append-only, 버퍼드 쓰기 불가 |
| 애플리케이션 전용 백엔드 | RocksDB ZenFS, `libzbd` | 애플리케이션 | 데이터 수명 정보를 가장 잘 활용 | 애플리케이션마다 구현 필요, 이식성 낮음 |

LWN의 "Accessing zoned block devices with zonefs"(2019)와 "New zonefs file system"(커버 레터)은 zonefs의 목표를 이렇게 설명한다. 블록 디바이스 ioctl 대신 익숙한 파일 API를 주자는 것이다. f2fs·btrfs처럼 완전한 FS를 쓰지 않으면서 LSM-tree류 애플리케이션이 zone을 쓰게 하려는 중간 지점이다. LSFMM 2023 보도에서는 btrfs 진영(Naohiro Aota)이 다른 문제를 보고했다. ZNS에서는 zone을 예약 시점에 활성화하는 바람에 "Btrfs on ZNS can report ENOSPC even when there is still space on the device"라는 것이다. active zone 한도가 범용 FS에 얼마나 까다로운지 보여 주는 실례다.

### 3.5 ZNS의 경쟁자: FDP
2022년 이후 하이퍼스케일러와 SSD 벤더는 ZNS의 "호스트가 모든 것을 한다" 모델 대신 NVMe FDP(TP4146)를 표준화했다. FDP에서 호스트는 쓰기에 placement handle만 붙이고, GC와 매핑은 여전히 장치가 한다. 기존 블록 인터페이스와 호환되므로 소프트웨어 수정량이 훨씬 적다. ZNS가 주는 WAF≈1·OP 0% 같은 극단적 이득은 포기하는 대신, 채택 장벽을 낮춘 셈이다. 상세 비교는 별도 문서(→ 09/02)에 있다.

---

## 4. Implementation Impact

### 4.1 uAPI: zone 유형·상태와 ioctl (Linux 7.3-rc7 `include/uapi/linux/blkzoned.h`)
`struct blk_zone`(64바이트)의 필드는 다음과 같다.
- `start`, `len`, `wp`: 512B 섹터 단위
- `type`, `cond`, `non_seq`, `reset`
- `capacity`: 5.9 추가

zone 유형은 `BLK_ZONE_TYPE_CONVENTIONAL`(0x1), `BLK_ZONE_TYPE_SEQWRITE_REQ`(0x2), `BLK_ZONE_TYPE_SEQWRITE_PREF`(0x3)이다. 상태(condition)는 ZBC/ZAC/ZNS의 ZC1~ZC7에 대응한다.

| 값 | 상수 | 의미 | active 자원 점유 |
|---|---|---|---|
| 0x0 | `BLK_ZONE_COND_NOT_WP` | conventional zone (write pointer 없음) | - |
| 0x1 | `BLK_ZONE_COND_EMPTY` | 비어 있음 (ZC1) | 아니오 |
| 0x2 | `BLK_ZONE_COND_IMP_OPEN` | 쓰기로 암묵적 open (ZC2) | open+active |
| 0x3 | `BLK_ZONE_COND_EXP_OPEN` | open 명령으로 명시적 open (ZC3) | open+active |
| 0x4 | `BLK_ZONE_COND_CLOSED` | 부분 기록 후 close (ZC4) | active |
| 0xD | `BLK_ZONE_COND_READONLY` | 읽기 전용 (ZC6) | - |
| 0xE | `BLK_ZONE_COND_FULL` | 가득 참 또는 finish (ZC5) | 아니오 |
| 0xF | `BLK_ZONE_COND_OFFLINE` | 접근 불가 (ZC7) | - |
| 0xFF | `BLK_ZONE_COND_ACTIVE` | 6.19: 캐시된 보고에서만 IMP/EXP_OPEN·CLOSED를 뭉뚱그려 표시 | active |

ioctl과 도입 버전은 태그별 grep으로 확인했다.

| ioctl | 번호 | 인자 | 도입 |
|---|---|---|---|
| `BLKREPORTZONE` | `_IOWR(0x12,130)` | `struct blk_zone_report` | 4.10 (현재 주석상 DEPRECATED) |
| `BLKRESETZONE` | `_IOW(0x12,131)` | `struct blk_zone_range` | 4.10 |
| `BLKGETZONESZ` / `BLKGETNRZONES` | 132 / 133 | `__u32` | 4.20 |
| `BLKOPENZONE` / `BLKCLOSEZONE` / `BLKFINISHZONE` | 134 / 135 / 136 | `struct blk_zone_range` | 5.5 |
| `BLKREPORTZONEV2` | `_IOWR(0x12,142)` | `struct blk_zone_report` (`flags`를 입력으로 사용) | 6.19 |

`BLKREPORTZONEV2`에 `BLK_ZONE_REP_CACHED`를 주면 장치에 REPORT ZONES를 보내지 않는다. 대신 커널이 zone write plug로 추적하는 상태(`blkdev_report_zones_cached()`)로 답한다. 이 경우 open/closed 구분은 `BLK_ZONE_COND_ACTIVE`로 합쳐진다. 수만 개 zone을 가진 SMR HDD에서 마운트·검사 시 REPORT ZONES 비용을 줄이려는 변경으로 보인다 [추측/미확인: 동기는 커밋 메시지로 확인하지 않음]. 권한 측면에서 zone 관리 ioctl은 `blkdev_zone_mgmt_ioctl()`에서 쓰기 모드(`BLK_OPEN_WRITE`)로 연 디바이스를 요구한다.

장치 한도는 `struct queue_limits`의 `max_open_zones`, `max_active_zones`, `max_hw_zone_append_sectors`로 노출된다. sysfs에서는 `/sys/block/<dev>/queue/{zoned,chunk_sectors,nr_zones,max_open_zones,max_active_zones,zone_append_max_bytes}`로 볼 수 있다. zoned 여부는 6.11부터 `BLK_FEAT_ZONED` 기능 플래그로 표현된다(v6.10 `blkdev.h` 0회, v6.11 3회). 7.1의 `zoned_qd1_writes`는 쓰기 가능한 queue 속성(`QUEUE_RW_ENTRY`)이다.

### 4.2 NVMe ZNS 드라이버 매핑 (`drivers/nvme/host/zns.c`, 5.9 도입)
`nvme_query_zone_info()`는 Identify(CNS `NVME_ID_CNS_CS_NS`, CSI `NVME_CSI_ZNS`)로 `struct nvme_id_ns_zns`를 읽는다. 이어서 다음을 수행한다.
- `zoc`(Zone Operation Characteristics)가 0이 아니면 지원하지 않는 장치로 보고 `-ENODEV`를 반환한다.
- `lbafe[lbaf].zsze`(zone size)가 2의 거듭제곱이 아니면 `-ENODEV`를 반환한다.
- `max_open_zones = mor + 1`, `max_active_zones = mar + 1`로 설정한다. NVMe 값은 0-based다.
- 컨트롤러별 Zone Append 한도를 정한다. `nvme_set_max_append()`가 ZNS Identify Controller의 `zasl`을 읽어 `1 << (zasl + 3)` 섹터로 둔다. `zasl`이 0이면 `max_hw_sectors`를 쓴다.
- Zone Append 미지원 장치는 `NVME_NS_FORCE_RO`로 읽기 전용 처리한다(3.2절).

REPORT ZONES는 `nvme_ns_report_zones()`가 Zone Management Receive 명령으로 처리한다. reset/open/close/finish는 `nvme_setup_zone_mgmt_send()`가 Zone Management Send로 변환한다.

### 4.3 쓰기 콜패스: zone write plugging (Linux 6.10+, 7.3-rc7 기준)
```
blk_mq_submit_bio()
  ├─ __bio_split_to_limits()             // 분할 (zone 경계·chunk_sectors 고려)
  ├─ blk_mq_attempt_bio_merge()
  ├─ bio_needs_zone_write_plugging(bio)?
  │    └─ blk_zone_plug_bio(bio, nr_segs)
  │         ├─ REQ_OP_ZONE_APPEND && !bdev_emulates_zone_append()
  │         │     → blk_zone_wplug_handle_native_zone_append(); return false (바로 디스패치)
  │         └─ REQ_OP_WRITE / WRITE_ZEROES / (에뮬레이션 대상 ZONE_APPEND)
  │               → blk_zone_wplug_handle_write()
  │                   ├─ conventional zone이면 플러그 안 함
  │                   ├─ disk_get_or_alloc_zone_wplug()   // 해시 테이블 + mempool
  │                   ├─ BLK_ZONE_WPLUG_PLUGGED이면 bio_list에 추가 후 return true
  │                   └─ blk_zone_wplug_prepare_bio()
  │                        ├─ 가득 찬 zone이면 실패
  │                        ├─ 에뮬레이션: bi_sector += wp_offset, REQ_OP_WRITE|REQ_NOMERGE,
  │                        │   BIO_EMULATES_ZONE_APPEND 플래그
  │                        ├─ 일반 쓰기: bio_offset_from_zone_start(bio) != wp_offset → 실패
  │                        └─ wp_offset += bio_sectors(bio); PLUGGED 설정 후 디스패치
  └─ blk_zone_write_plug_init_request(rq)  // 이후 머지된 BIO까지 추적
완료: blk_zone_write_plug_bio_endio() → disk_zone_wplug_unplug_bio()
      → 다음 BIO를 bio_work(kblockd) 또는 7.1+ qd1 모드에서는 disk_zone_wplugs_worker() kthread로 제출
```

`struct blk_zone_wplug`의 구성은 다음과 같다.
- 연결: `hlist_node node`(해시), `list_head entry`(활성 목록)
- 대기열과 제출: `bio_list`, `work_struct bio_work`
- 수명: `rcu_head`, `refcount_t ref`
- 동기화: `spinlock_t lock`
- 상태: `flags`(`BLK_ZONE_WPLUG_PLUGGED`/`NEED_WP_UPDATE`/`DEAD`), `zone_no`, `wp_offset`, `cond`

해시 크기는 `BLK_ZONE_WPLUG_MAX_HASH_BITS`(9) 이하이고, 기본 mempool 크기는 `BLK_ZONE_WPLUG_DEFAULT_POOL_SIZE`(128)다.

수명 관리는 참조 카운트로 한다. 해시 테이블에 있으면 기본 참조 1을 유지한다. zone이 reset·finish되거나 가득 차면 `DEAD`를 세우고 초기 참조를 버린다. 마지막 사용자가 떠나면 RCU 유예 기간 뒤 해제된다. 쓰기 오류로 write pointer를 잃으면 `NEED_WP_UPDATE`를 세운다. 이후 `disk_zone_wplug_sync_wp_offset()`이 REPORT ZONES로 위치를 다시 맞춘다.

`REQ_NOWAIT` BIO는 처리가 특별하다. 플러그될 수 있으면 `REQ_NOWAIT`를 지우고 목록에 넣는다. io_uring 비동기 제출이 `-EAGAIN`으로 돌아오면서 순서가 깨지는 일을 막기 위해서다.

### 4.4 레거시 vs 신규: zone write locking과 zone write plugging

| 항목 | Zone write locking (4.16–6.9) | Zone write plugging (6.10+) |
|---|---|---|
| 동작 단위 | `struct request` | `struct bio` |
| 구현 위치 | mq-deadline 스케줄러 (`dd_*` 경로) | `block/blk-zoned.c` (블록 계층 공통) |
| 스케줄러 제약 | zoned 장치는 mq-deadline 필수 | `none`·bfq·kyber 등 무엇이든 가능 |
| 대기 중 쓰기의 태그 점유 | 스케줄링 태그 점유 | 태그 미점유 (BIO 리스트에 대기) |
| Zone Append 에뮬레이션 | `sd_zbc`·DM이 각자 구현 | 블록 계층 단일 구현 (`BIO_EMULATES_ZONE_APPEND`) |
| write pointer 추적 | 드라이버별 캐시 (sd) | zone별 `wp_offset` (플러그가 존재하는 동안) |
| bio 기반(DM) 장치 | 별도 구현 | 선택 사용 (`disk_need_zone_resources()`) |
| 실측 영향 (커버 레터) | 기준 | ZNS: mq-deadline에서 ±3%, null_blk+`none`: 최대 +180% |

### 4.5 zonefs 내부와 제약 (`fs/zonefs/`, 5.6 도입)
- **구조**: 마운트 시 zone 정보만으로 트리를 만든다. 디렉터리는 `cnv`(conventional)와 `seq`(sequential) 두 개뿐이다. zone 하나가 파일 하나다. 연속한 conventional zone은 하나의 파일로 묶을 수 있다(aggregation). 디렉터리 생성·rename·삭제는 불가하다.
- **쓰기 규칙**: `seq` 파일 크기는 write pointer 위치다. 쓰기는 파일 끝에서만 가능하다(append only). page cache writeback은 순차 패턴을 보장하지 않으므로 버퍼드 쓰기와 쓰기 가능한 공유 mmap을 막는다(`zonefs.rst`). 결과적으로 시퀀셜 파일 쓰기는 `O_DIRECT`여야 한다. truncate는 0(zone reset)이나 zone capacity(finish → FULL)로만 허용된다.
- **자원 한도**: sysfs `max_wro_seq_files`/`nr_wro_seq_files`, `max_active_seq_files`/`nr_active_seq_files`로 장치 한도와 사용량을 보여 준다. `explicit-open` 마운트 옵션을 쓰면 쓰기용 open 시 zone을 명시적으로 open한다. 그래서 장치 한도를 넘으면 쓰기 시점 I/O 오류 대신 `open()` 시점에 실패한다.
- **오류 처리**: `errors=remount-ro`(기본), `zone-ro`, `zone-offline`, `repair`로 zone 단위 장애 대응 정책을 고른다.

### 4.6 f2fs, btrfs, XFS, dm-zoned
- **f2fs**: section을 zone에 정렬한다. ZNS의 zone capacity가 zone size보다 작으면, capacity 뒤에서 시작하는 segment를 마운트 시 "permanently used"로 표시한다. 그래서 할당도 GC도 하지 않는다(`f2fs.rst` "NVMe Zoned Namespace devices"). ZNS에는 conventional zone이 없다. 따라서 메타데이터를 둘 일반 블록 장치를 함께 묶는 multi-device 구성이 필요하다 [추측/미확인: mkfs 옵션 문서는 직접 확인하지 않음].
- **btrfs**: 블록 그룹을 zone에 매핑한다. 데이터 쓰기에 `REQ_OP_ZONE_APPEND`를 쓴다(`btrfs_use_zone_append()`). `max_zone_append_size`가 extent 크기를 제한한다. 슈퍼블록은 고정 위치 덮어쓰기가 불가하므로 전용 zone 쌍에 로그처럼 기록한다 [추측/미확인: 세부 구조는 LWN "Btrfs on zoned block devices" 요약 기준].
- **XFS**: 6.15에서 실시간 서브볼륨 기반 zoned 할당기(`fs/xfs/xfs_zone_alloc.c`)가 들어왔다. `fs/xfs/Kconfig`는 이렇게 설명한다. 실시간 서브볼륨은 zoned 장치가, 메타데이터는 일반 블록 장치가 맡는다. 단 SMR HDD는 앞쪽 conventional zone을 main 장치로 쓸 수 있다.
- **dm-zoned**: host-managed 장치 위에 랜덤 쓰기 가능한 일반 블록 장치를 에뮬레이션한다. conventional zone(또는 별도 일반 장치)을 버퍼·메타데이터로 쓰고 재기록(reclaim)을 호스트에서 수행한다(`docs.kernel.org` dm-zoned 문서).

### 4.7 사용자 공간: libzbd와 ZenFS
- **libzbd**: `zbd_open()`, `zbd_get_info()`, `zbd_report_zones()`/`zbd_list_zones()`, `zbd_reset_zones()`/`zbd_open_zones()`/`zbd_close_zones()`/`zbd_finish_zones()`를 제공한다. 사실상 4.1절 ioctl의 얇은 래퍼다. `gzbd`/`gzbd-viewer` GUI 도구도 함께 있다.
- **ZenFS**: RocksDB `FileSystem` 플러그인이다. `ROCKSDB_PLUGINS=zenfs`로 빌드하고 `zenfs mkfs --zbd=<dev> --aux_path=<path>`로 만든다. `db_bench --fs_uri=zenfs://dev:<dev>`(또는 `zonefs:`, `uuid:`)로 쓴다. README는 libzbd 의존성과 "kernel 5.9 or later"(ZNS의 경우)를 요구한다. 또 쓰기 재정렬을 막기 위해 "The IO scheduler must be set to deadline"이라고 안내한다. 그러나 이는 **6.9 이하 기준의 낡은 지침**이다. 6.10+에서는 zone write plugging이 순서를 보장하므로 스케줄러 강제가 필요 없다. ZNS 논문 §4에 따르면 ZenFS는 저널·WAL·compaction에 최소 active zone 3개가 필요하다. 6개로도 동작하지만 12개를 넘으면 성능 이득이 거의 없었다. 논문 Table 1의 ZNS 지원 코드 변경량은 ZenFS 3,276줄 추가, 커널 647줄 추가였다.
- 저장소 상태(GitHub API, 2026-10 조회): zenfs 마지막 push 2025-03-27, libzbd 2024-05-30. 둘 다 아카이브되지 않았지만 개발 활동은 뜸하다.

### 4.8 채택의 실제 한계와 운영 트레이드오프
1. **장치 가용성**: LSFMM 2023에서 Le Moal은 "few deployed flash-based zoned-storage systems"라는 인식을 공유했다. ZNS SSD는 소수 벤더의 데이터센터 모델에 머물렀다 [추측/미확인: 제품 목록·출하량 미확인]. 반면 zoned UFS(Android)는 리눅스 zoned 경로의 새 수요처다(LWN "Improve write performance for zoned UFS devices").
2. **Active zone 한도**: 8–32 수준(논문)이다. 쓰기 스트림이 많은 멀티테넌트 워크로드는 금방 한도에 부딪힌다. btrfs의 ENOSPC 문제가 그 실례다.
3. **호스트 GC 비용**: 장치 WAF가 줄어도 호스트 compaction·GC의 CPU·대역폭 비용은 그대로 남는다. 이득을 보려면 소프트웨어가 수명이 같은 데이터를 한 zone에 모아야 한다.
4. **2의 거듭제곱 zone 크기 + 큰 zone**: 1–2GB zone은 reset 단위가 크다. 그만큼 GC 시 이동량이 많다.
5. **도구 지원**: `blkzone`(util-linux), `nvme zns` 플러그인(nvme-cli), fio의 `zonemode=zbd`, QEMU ZNS 에뮬레이션이 있다. 운영 표준 툴체인은 갖춰졌다.

### 4.9 연표 (메인라인, 태그 grep 기준)

| 커널 | 변경 |
|---|---|
| 4.10 | zoned block device 지원, `BLKREPORTZONE`/`BLKRESETZONE`, f2fs zoned, SCSI zone write lock |
| 4.13 | dm-zoned |
| 4.16 | zone write locking을 mq-deadline으로 이동 |
| 4.20 | `BLKGETZONESZ`, `BLKGETNRZONES` |
| 5.5 | `BLKOPENZONE`/`BLKCLOSEZONE`/`BLKFINISHZONE` |
| 5.6 | zonefs |
| 5.8 | `REQ_OP_ZONE_APPEND`, SCSI Zone Append 에뮬레이션 |
| 5.9 | NVMe ZNS (`drivers/nvme/host/zns.c`), `capacity` 필드·`BLK_ZONE_REP_CAPACITY` |
| 5.12 | btrfs zoned 모드 (SMR; 일부 코드는 5.11). ZNS 지원은 5.16 (LWN 2023) |
| 6.10 | zone write plugging, mq-deadline zone write locking 제거 |
| 6.11 | `BLK_FEAT_ZONED` 기능 플래그 |
| 6.15 | XFS zoned (실시간 서브볼륨) |
| 6.19 | `BLKREPORTZONEV2`, `BLK_ZONE_REP_CACHED`, `BLK_ZONE_COND_ACTIVE` |
| 7.1 | 단일 kthread 쓰기 제출 (`disk_zone_wplugs_worker()`, sysfs `zoned_qd1_writes`) |

---

## 5. Primary References

- [usenix.org - ZNS: Avoiding the Block Interface Tax for Flash-based SSDs](https://www.usenix.org/conference/atc21/presentation/bjorling) — Bjørling et al., USENIX ATC '21, pp. 689–703 ([PDF](https://www.usenix.org/system/files/atc21-bjorling.pdf))
- [lwn.net - Zone write plugging](https://lwn.net/Articles/968580/) — Damien Le Moal, [PATCH v6 00/28], 2024-04-05
- [lwn.net - Improve zoned (SMR) HDD write throughput](https://lwn.net/Articles/1059914/) — Damien Le Moal, 2026-02-21
- [lwn.net - Introduce Zone Append for writing to zoned block devices](https://lwn.net/Articles/818709/) — Johannes Thumshirn, [PATCH v8 00/11], 2020-04-27
- [lwn.net - Zoned storage and filesystems](https://lwn.net/Articles/932748/) — LSFMM+BPF 2023
- [lwn.net - Accessing zoned block devices with zonefs](https://lwn.net/Articles/794364/) — zonefs 설계와 목표 소개
- [lwn.net - Btrfs on zoned block devices](https://lwn.net/Articles/853308/) — btrfs zoned 모드 구조 요약
- [lwn.net - blk-mq support for ZBC disks](https://lwn.net/Articles/742159/) — 4.16 zone write locking의 blk-mq 이동
- [lwn.net - Improve write performance for zoned UFS devices](https://lwn.net/Articles/1029301/) — zoned UFS 쓰기 성능 개선 시리즈
- [kernel.org - ZoneFS - Zone filesystem for Zoned block devices](https://docs.kernel.org/filesystems/zonefs.html) — zonefs 커널 문서(마운트 옵션, 오류 처리)
- [kernel.org - dm-zoned](https://docs.kernel.org/admin-guide/device-mapper/dm-zoned.html) — dm-zoned 타깃 문서
- [github.com/torvalds/linux - block/blk-zoned.c](https://github.com/torvalds/linux/blob/master/block/blk-zoned.c) — zone write plugging 구현
- [github.com/torvalds/linux - include/uapi/linux/blkzoned.h](https://github.com/torvalds/linux/blob/master/include/uapi/linux/blkzoned.h) — zone uAPI(ioctl, 구조체, condition)
- [github.com/torvalds/linux - drivers/nvme/host/zns.c](https://github.com/torvalds/linux/blob/master/drivers/nvme/host/zns.c) — NVMe ZNS 드라이버 매핑
- [zonedstorage.io - NVMe Zoned Namespaces (ZNS) Devices](https://zonedstorage.io/docs/introduction/zns) — ZNS 개념 소개
- [zonedstorage.io - Write Ordering Control](https://zonedstorage.io/docs/linux/sched) — zone write locking/plugging 연혁과 스케줄러 설정
- [zonedstorage.io - Zoned Block Device User Interface](https://zonedstorage.io/docs/linux/zbd-api) — zoned block device ioctl·sysfs 인터페이스
- [github.com/westerndigitalcorporation - zenfs](https://github.com/westerndigitalcorporation/zenfs) — RocksDB ZenFS 플러그인 저장소
- [github.com/westerndigitalcorporation - libzbd](https://github.com/westerndigitalcorporation/libzbd) — zoned block device 사용자 공간 라이브러리
