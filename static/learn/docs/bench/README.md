# bench/ — 문서 수치 재현 키트 (Linux 스토리지·네트워크 I/O)

`artifacts/` 문서에 나오는 정량 주장(IOPS, 지연, 손익분기 등)을 **사용자의 Linux 장비에서 같은 형태로 다시 재 보기** 위한 스크립트 모음이다. 목표는 문서의 절대값을 그대로 맞추는 것이 아니다. **같은 조건 축(블록 크기, 폴링, 등록 자원, 코어 수, 커널 설정)을 바꿨을 때 비율과 방향이 문서와 같은지** 확인하는 데 있다.

- 모든 스크립트는 Linux 전용이다. macOS 등에서는 `-n`(dry-run)으로 실행 명령만 확인할 수 있다.
- 각 스크립트 머리 주석과 `-h`가 재현 대상 주장, 옵션, 전제 조건을 설명한다.
- 이 키트는 작성 환경(macOS)에서 실행 검증을 하지 않았다. `bash -n`, `shellcheck`, `python3 -m py_compile`, dry-run, 합성 데이터로 한 `summarize.py` 테스트만 통과했다. 첫 실행은 반드시 `-n`으로 명령을 확인하고, 짧은 `--runtime`과 `--runs 1`로 시작하길 권한다.

---

## 1. 안전 경고 (반드시 읽을 것)

| 위험 | 해당 스크립트 | 보호 장치 |
|---|---|---|
| **raw 장치 쓰기 = 장치의 모든 데이터 파괴** | `03 --mode mixed/both` | `ALLOW_WRITE=1` 환경 변수 **와** `--i-understand-data-loss` 옵션이 모두 필요하다. 장치가 마운트·스왑·holder(dm/md/LVM) 사용 중이면 거부한다. 실행 전 10초 대기한다. |
| raw 장치 읽기 | `01 02 03(randread) 05 06` | 데이터를 바꾸지 않는다. fio에는 `--readonly`를 함께 넘기고, t/io_uring은 소스상 `O_RDONLY`로 연다. 마운트된 장치는 결과가 오염되므로 기본 거부한다(`ALLOW_BUSY_READ=1`로 허용). |
| 파일 시스템 위 파일 쓰기 | `04` | `FILE_DIR` 아래 `bench_pagecache.dat` 파일 하나에만 쓰고, 종료 시 지운다(`--keep-file`로 유지). 여유 공간이 `SIZE` 이상 필요하다. `drop_caches`를 실행하므로 같은 머신의 다른 작업 성능에 잠시 영향을 준다. |
| 커널 드라이버 분리 | `08` (SPDK) | 장치를 nvme 드라이버에서 떼면 그 장치의 `/dev/nvme*`와 파일 시스템이 사라진다. `--bind`와 `--i-understand-unbind`가 모두 있을 때만 하며, namespace가 하나라도 사용 중이면 거부하고, 종료 시 `setup.sh reset`으로 되돌린다. |
| sysfs 런타임 변경 | `01/02 --tune-block`, `03`(scheduler, `--wbt`), `06 --rq-affinity-sweep` | 바꾼 값은 원래 값을 기록해 두었다가 종료(EXIT trap) 시 복원한다. 강제 종료(`kill -9`)나 전원 차단 시에는 복원되지 않는다. `results/*/commands.log`에 바꾼 명령이 남는다. |
| 부트 파라미터·모듈 파라미터 | `05`(IOMMU), `06`(poll_queues) | **스크립트가 바꾸지 않는다.** `--how-to`로 방법만 출력한다. |
| 네트워크 송신 | `07` | 지정한 목적지로 수 초간 TCP 트래픽을 보낸다. 운영 네트워크에서는 사전 협의가 필요하다. |

`DEVICE`는 항상 명시해야 한다. 기본 장치를 추측하지 않는다.

---

## 2. 구성

```
bench/
├── README.md
├── common/
│   ├── lib.sh              # 공통 함수: dry-run, 안전 검사, CPU/NUMA 선택, sysfs 변경·복원, fio 반복 실행
│   └── env_capture.sh      # 환경 기록 → results/<run>/env.txt, env.json
├── jobs/                   # fio job 파일 (값은 환경 변수 ${VAR}로 주입, 실행 명령에 env VAR=... 로 기록)
│   ├── engines.fio         # 02: libaio / io_uring(+fb, poll, sqpoll) / io_uring_cmd(+fb, poll, sqpoll)
│   ├── scheduler.fio       # 03: randread, mixed_reader + mixed_writer
│   ├── pagecache.fio       # 04: seqread / randread / seqwrite (direct·uncached 전환)
│   ├── iommu.fio           # 05: 4K 다중 CPU, 128K 순차, 4K QD1
│   └── latency.fio         # 06: io_uring irq/poll, pvsync2 irq/hipri
├── 01_iouring_peak_iops.sh
├── 02_engine_compare.sh
├── 03_scheduler_mixed_rw.sh
├── 04_buffered_vs_direct_vs_dontcache.sh
├── 05_iommu_mode_compare.sh
├── 06_poll_queues_irq.sh
├── 07_msg_zerocopy.sh
├── 08_spdk_perf.sh
└── analyze/summarize.py    # 결과 → Markdown 표 (표준 라이브러리만)
```

결과는 `bench/results/<YYYYMMDD-HHMMSS>-<실험명>/`에 저장된다(`RESULTS_ROOT`로 변경 가능).

| 파일 | 내용 |
|---|---|
| `meta.txt` | 실행 인자, RUNS/RUNTIME 등 |
| `commands.log` | 실제로 실행한 명령 전체(환경 변수 포함). 그대로 복사해 재실행할 수 있다 |
| `env.txt`, `env.json` | 환경 기록 (아래 5절) |
| `<tag>.run<N>.json` | fio JSON 원본 |
| `<tag>.run<N>.tio.log` | t/io_uring 출력 원본 |
| `<tag>.run<N>.spdk.log` | spdk_nvme_perf 출력 원본 |
| `<tag>.run<N>.sys.json` | (04) kswapd CPU 초, pgscan/pgsteal, Cached 증가량 |
| `zerocopy.csv` | (07) 크기·zerocopy 여부별 처리량과 CPU |
| `_warmup.*`, `_prep.json` | 워밍업·준비 실행. 분석에서 제외된다 |
| `NOTES.md` | 그 실행의 조건과 해석 포인트 |
| `summary.md` | `summarize.py` 출력 |

---

## 3. 사전 준비

### 3.1 공통

- root 권한(`sudo -E`로 환경 변수 유지), bash ≥ 4.2, python3 ≥ 3.6(`summarize.py`, 04의 RWF_DONTCACHE 확인)
- `fio`: 기본 ≥ 3.0, `io_uring_cmd`는 ≥ 3.31, 04의 `uncached` 옵션 파싱은 ≥ 3.17, **RWF_DONTCACHE 실제 적용은 ≥ 3.40**
  (fio 3.17~3.38 의 `uncached`는 2019년 미병합 `RWF_UNCACHED` 시절 옵션이고 3.39 에서는 soft-deprecated 로 무시된다. 3.40 부터 `RWF_DONTCACHE`를 붙인다.)
- `t/io_uring`: 배포판 fio 패키지에는 보통 없다. fio 소스에서 빌드한다.
  ```sh
  git clone https://github.com/axboe/fio && cd fio && ./configure && make && make t/io_uring
  export TIO=$PWD/t/io_uring
  ```
  libaio 개발 헤더가 있어야 `-a1`(legacy aio) 변형이 동작한다.
- `nvme-cli`(환경 기록의 `id-ctrl`/`smart-log`), `util-linux`(`taskset`, `lsblk`), `numactl`(선택)
- debugfs 마운트(선택, poll hctx 정확한 확인용): `mount -t debugfs none /sys/kernel/debug`
- `kernel.io_uring_disabled`(6.6+)가 0 이어야 한다(1이면 root만, 2면 사용 불가).

### 3.2 실험별 커널·도구 요구

| 스크립트 | 커널 | 도구 | 비고 |
|---|---|---|---|
| 01 | io_uring 5.1+, `/dev/ngXnY` 5.13+, passthrough(`-u1`) 5.19+, passthrough 폴링 6.1+ | t/io_uring | `-p1`은 `nvme.poll_queues>0` 필요. 512B 측정은 512B LBA 포맷 필요 |
| 02 | 5.1+, uring_cmd 5.19+, uring_cmd fixedbufs/폴링 6.1+ | fio ≥ 3.31 | fio io_uring 엔진은 `COOP_TASKRUN`, `SINGLE_ISSUER\|DEFER_TASKRUN`을 자동 시도한다(3.33~master 소스에서 확인) |
| 03 | blk-mq 스케줄러(mq-deadline, kyber, bfq 모듈) | fio | 쓰기 모드는 빈 장치 필요 |
| 04 | DONTCACHE: 인터페이스 6.14, **6.15는 전역 비활성**, XFS 6.16+, ext4 6.17+ | fio ≥ 3.40 (dontcache), python3 | 스크립트가 `preadv2(RWF_DONTCACHE)`로 실제 지원을 확인하고 미지원이면 건너뛴다 |
| 05 | `iommu.strict=` 4.20+, sysfs `DMA-FQ` 5.15+ | fio | 모드마다 재부팅 필요 |
| 06 | `poll_queues`/`write_queues` 5.0+ | fio | `/sys/block/*/queue/io_poll` 쓰기는 현재 커널에서 무시된다 |
| 07 | MSG_ZEROCOPY TCP 4.14+, `IORING_OP_SEND_ZC` 6.0+ | `msg_zerocopy`(커널 selftest), 선택: liburing `examples/send-zerocopy` | 두 호스트 권장 |
| 08 | vfio-pci(IOMMU) 또는 uio | SPDK 빌드 (`build/bin/spdk_nvme_perf`, `scripts/setup.sh`) | 선택 실험 |

### 3.3 도구 빌드 메모

- `msg_zerocopy`: 커널 소스에서 `make -C tools/testing/selftests/net msg_zerocopy` (또는 `gcc -O2 -o msg_zerocopy tools/testing/selftests/net/msg_zerocopy.c`). `MSG_ZEROCOPY_BIN`으로 경로 지정. loopback 모드는 `KSFT_NET_DIR`에 `msg_zerocopy`와 `msg_zerocopy.sh`가 있어야 한다.
- `send-zerocopy`: liburing 소스(`git clone https://github.com/axboe/liburing && ./configure && make`) 후 `examples/send-zerocopy`. `SENDZC_BIN`으로 경로 지정.
- SPDK: `git clone https://github.com/spdk/spdk --recursive && cd spdk && sudo scripts/pkgdep.sh && ./configure && make`. 커널 경로 비교(`--kernel-dev`)에서 `-R`(io_uring)을 쓰려면 SPDK를 liburing 지원으로 빌드해야 한다(`./configure --with-uring` [추측/미확인: configure 옵션 이름은 SPDK 버전별로 확인]).

---

## 4. 공통 사용법

```sh
cd bench
sudo -E DEVICE=/dev/nvme0n1 TIO=~/fio/t/io_uring ./01_iouring_peak_iops.sh -n          # 명령만 확인
sudo -E DEVICE=/dev/nvme0n1 TIO=~/fio/t/io_uring ./01_iouring_peak_iops.sh --runs 1 --runtime 10
python3 analyze/summarize.py results/<디렉터리>
```

| 환경 변수 | 기본값 | 의미 |
|---|---|---|
| `DEVICE` | (필수) | 대상 블록 장치. 01은 공백으로 여러 개 지정 가능 |
| `RUNS` | 3 | 변형당 반복 횟수 |
| `RUNTIME` | 30 | 측정 1회 길이(초) |
| `RAMP` | 5 | fio `ramp_time`(초), SPDK `-a`(warmup) |
| `WARMUP` | 10 | 실험 시작 전 워밍업 1회(초), 0이면 생략 |
| `DRY_RUN` | 0 | 1 이면 `-n`과 같다 |
| `ALLOW_WRITE` | 0 | 쓰기 테스트 허용(추가로 `--i-understand-data-loss` 필요) |
| `ALLOW_BUSY_READ` | 0 | 마운트된 장치에 읽기 테스트 허용 |
| `FIO`, `TIO` | `fio`, 자동 탐색 | 도구 경로 |
| `RESULTS_ROOT` | `bench/results` | 결과 위치 |
| `NO_DROP_CACHES` | 0 | 04에서 실행 사이 `drop_caches` 생략 |

각 스크립트는 다음을 공통으로 한다.

1. **preflight**: Linux·root·도구 버전·커널 버전 확인, 장치 존재·사용 중 여부, io_uring 비활성 sysctl, poll 큐 존재, `/dev/ngXnY` 존재
2. **CPU 고정**: 장치의 NUMA 노드(`/sys/class/nvme/<ctrl>/device/numa_node`)에서 CPU를 고른다(CPU0은 가능하면 피함). fio는 `cpus_allowed`(+`cpus_allowed_policy=split`), t/io_uring은 `taskset -c`
3. **워밍업**: `WARMUP`초 1회 + 매 측정의 `ramp_time`
4. **반복**: `RUNS`회. `summarize.py`가 평균과 변동계수(CV)를 보인다
5. **원본 보존**: fio JSON, t/io_uring 로그, SPDK 로그를 그대로 저장한다

---

## 5. 환경 기록 (`common/env_capture.sh`)

각 실행 시작 시 자동으로 호출된다. 단독 실행: `sudo ./common/env_capture.sh results/env-now /dev/nvme0n1`.

기록 항목: 커널 버전·`/proc/cmdline`·커널 config 일부(`CONFIG_HZ`, 선점 모델, `RETPOLINE`/`PAGE_TABLE_ISOLATION`, `IOMMU_DEFAULT_*`, `BLK_WBT`, `BLK_CGROUP`), CPU 모델·`lscpu`·SMT, NUMA, CPU governor·pstate·turbo·cpuidle, `/sys/devices/system/cpu/vulnerabilities/*`, 메모리·dirty 설정, `io_uring_disabled`, IOMMU 부팅 메시지(`Default domain type`, `TLB invalidation policy`)와 장치별 `iommu_group/type`, nvme 모듈 파라미터(`poll_queues`, `write_queues`, `io_queue_depth`), 장치별 queue 속성(`scheduler`, `nomerges`, `iostats`, `wbt_lat_usec`, `rq_affinity`, `io_poll` 등), `mq/*/cpu_list`, debugfs hctx 타입, NVMe 모델·펌웨어·PCIe 링크, `nvme id-ctrl`(시리얼은 기본 마스킹), `smart-log` 온도, NVMe IRQ별 `smp_affinity_list`·`effective_affinity_list`·파일 모드, irqbalance 상태, 도구 버전. `NETIF=eth0`이면 `ethtool -i/-k/-l/-c`, `optmem_max`, `ulimit -l`도 기록한다.

이 스크립트는 읽기만 하며 설정을 바꾸지 않는다.

---

## 6. 측정 위생

문서 수치와 비교하기 전에 다음을 맞추고 `env.txt`로 확인한다.

- CPU governor `performance`, turbo/boost 상태 고정, 깊은 C-state 영향 인지(QD1 지연에 크게 작용)
- 다른 부하가 없는 유휴 시스템. 같은 장치를 쓰는 다른 프로세스 없음
- 장치 온도: 장시간 실행 시 스로틀(`nvme smart-log`)
- 쓰기 측정(03 mixed)은 steady state 전후로 결과가 크게 다르다. 문서(09/06 4.8)의 권고대로 전체 용량 순차 쓰기 2회 + 랜덤 쓰기로 사전 조건화한 뒤 측정한다(스크립트는 사전 조건화를 하지 않는다)
- 투기 실행 완화(`mitigations=`), `CONFIG_HZ`, 선점 모델이 FAST '24와 다르면 절대값이 달라진다
- CV가 5%를 넘으면 반복 수를 늘리거나 원인을 찾는다

---

## 7. 결과 해석 원칙

1. **절대값보다 비율**: 같은 장비 안에서 "block 대비 passthrough", "irq 대비 poll", "none 대비 bfq", "buffered 대비 dontcache"의 비율을 문서의 비율과 비교한다.
2. **조건이 하나라도 다르면 다른 주장이다**: 512B vs 4K, 1코어 vs 다코어, 폴링 여부, 등록 자원, SQPOLL 코어 산정, 장치 종류(Optane vs NAND), 커널 설정을 `NOTES.md`와 `env.txt`에 대조한다.
3. **장치가 먼저 포화되면 소프트웨어 차이가 사라진다**: NAND SSD 4K 랜덤 읽기는 장치 한계(사양서 IOPS)에 먼저 닿는 경우가 많다. 이때는 IOPS가 같아도 `sys%`(CPU 비용)가 차이를 보여 준다. 01의 `nop`(-N1) 결과는 "장치가 무한히 빠를 때" 상한이다.
4. **도구 병목**: fio는 장치당 수백만 IOPS 영역에서 자체가 병목이 될 수 있다(09/06 3.2). 02(fio)와 01(t/io_uring)의 같은 조건 결과 차이가 도구 비용이다.
5. **SQPOLL은 코어를 하나 더 쓴다**: 02의 SQPOLL 결과는 `sqthread_poll_cpu` 코어를 포함해 "2코어 결과"로 읽는다.
6. **t/io_uring 출력 `IOS/call=a/b`**: 시스템 콜당 제출/수거 개수. 32/32에 가까워야 배치가 동작한 것이다.

---

## 8. 스크립트 ↔ 문서 주장 매핑

문서 표기 `→ NN/MM`은 `artifacts/NN_*/MM_*.md`를 뜻한다.

| 스크립트 | 문서 주장 (→ 문서) | 원래 측정 조건 | 사용자 장비에서 달라질 수 있는 점 |
|---|---|---|---|
| `01` `--profile axboe2021 --variants poll` | "3.5M+ IOPS per core" (→ 09/06 3.3, 4.9; LWN 866114) | `taskset -c 0 t/io_uring -b512 -d128 -c32 -s32 -p1 -F1 -B1`, AMD 서버, 2021-08 bio 재활용 패치셋 커널 | 장치 IOPS 한계(Optane급이 아니면 장치가 먼저 포화), 512B LBA 포맷 여부, poll 큐 수, 이후 커널의 최적화(수치는 이후 버전에서 올라감), CPU 클럭·mitigations |
| `01` `--variants poll,pt_poll --profile axboe2021` (+`--tune-block`) | FAST '24 단일 코어 피크 block 2.9M vs passthrough 3.9M(+35%), 최적화 설정 3.83M vs 5M (→ 03/02 4.6) | Ryzen 9 5900X, Optane P5800X 400GB, Linux 6.2, 512B randread, QD128, batch 32, FB+Poll. 최적화 = `CONFIG_RETPOLINE`·`CONFIG_PAGE_TABLE_ISOLATION` 끔 | 커널 config(재컴파일 필요, 스크립트 범위 밖), 장치. `--tune-block`은 iostats/nomerges/wbt만 바꾸며 FAST '24의 "강제 선점 끄기, HZ=100, blk-cgroup 제거"는 커널 재빌드가 필요하다 |
| `01` `--profile 4k --variants poll` | Gen5 NVMe raw 4K 폴링 단일 코어 ~3.2M IOPS (→ 11/01 2.3; 커밋 36f199c8d0ee) | 특정 Gen5 SSD, t/io_uring, 단일 코어 폴링 | 장치 세대, 커널(7.3 개발 주기 기준) |
| `01` 여러 `DEVICE` + `--threads N` | Haas & Leis 12.5M IOPS(8 SSD, SPDK), 폴링 io_uring 16스레드 근접 (→ 09/06 4.9) | 64코어 AMD, PM1733 ×8, 4KiB, 자체 도구 | SSD 수와 PCIe 레인. 스레드 수에 따른 확장 추세만 비교 가능 |
| `02` | io_uring_cmd는 블록 계층 우회, SQPOLL·폴링 큐·fio 병목 함정 (→ 09/06 4.6, 4.8) | 정성적 + 체크리스트 | 정량 기준 없음. 엔진 간 비율과 sys%로 판단 |
| `02` `--qd-sweep "16 128"`, `--sqpoll-batch2`, `--bs 512` | FAST '24: passthrough 큐 깊이 확장 QD16 +19% / QD128 +31%, SQPOLL(batch 2) +136% (→ 03/02 4.6) | 위 FAST '24 조건. 원 실험은 t/io_uring 기반이며 SQPOLL 스레드는 별도 코어(`IORING_SETUP_SQ_AFF`) | fio 자체 오버헤드(t/io_uring에는 SQPOLL 옵션이 없어 fio로 대체), 장치 포화 |
| `03 --mode randread` | BFQ/mq-deadline/Kyber 최대 50% 오버헤드 (Ren & Trivedi CHEOPS '23, → 09/06 3.1 표) | Intel Optane SSD, fio | 장치 속도(느린 장치에서는 스케줄러 비용이 숨음), numjobs·QD, 커널 버전별 스케줄러 최적화 |
| `03 --mode mixed` | 쓰기 버스트 뒤의 동기 읽기 지연, Kyber·wbt는 장치에 들어가는 쓰기 수를 제한 (→ 02/02 2.1, 3.2, 4.3, 4.5) | 정성적(문서는 수치를 제시하지 않음) | 장치 내부 쓰기 버퍼·FTL, 사전 조건화 상태. 결과는 "방향"만 비교 |
| `04` (Cached·kswapd 지표) | RWF_DONTCACHE: 캐시 오염 방지, 워킹셋 > 메모리에서 32코어 중 ~28코어가 kswapd (Axboe 2024, → 11/02 1, 2.4) | 메모리보다 큰 워킹셋의 버퍼드 읽기, 32코어 | `SIZE`가 RAM보다 작으면 kswapd 차이 없음(기본 16G). 파일 시스템·커널 버전별 DONTCACHE 지원 |
| `04` `--workloads seqwrite` | dontcache 쓰기 p99.9 buffered 23ms vs dontcache 93ms, 7.2에서 flusher 방식으로 변경 (→ 11/02 3.6; 커밋 e1bf79628453) | 커밋 메시지의 측정 환경 | 커널이 v7.1 이하인지 v7.2 이상인지가 결과를 가른다. 장치 쓰기 속도 |
| `04 --dio-path` | raw 4K 폴링 ~3.2M vs ext4/XFS 파일 ~1.92M, 단순 DIO 경로 후 ext4 2.19M (→ 11/01 2.3) | Gen5 NVMe, t/io_uring 단일 코어 폴링 | `DEVICE`는 `FILE_DIR`이 있는 장치여야 의미가 있다(마운트된 장치를 읽기만 하므로 이 경우에는 사용 중 검사를 하지 않는다. 다른 I/O가 없는 상태에서 실행할 것). 커널에 iomap 단순 경로가 있는지(7.3 개발 주기) |
| `05` (모드별 재부팅 후 반복) | strict/lazy/identity 비용 차이, x86 기본 lazy(DMA-FQ, FQ 256항목/10ms) (→ 12/01 1, 3.1, 3.2, 3.5) | Peleg ATC '15: Linux 3.17.2, 10GbE netperf TCP_RR 270 동시 요청, 16코어 | NVMe로 측정하므로 네트워크 수치와 직접 비교 불가. IOVA rcache(4.7+)·FQ 덕에 현대 커널의 차이는 훨씬 작을 수 있다. 장치가 먼저 포화되면 sys%만 차이 |
| `06` (inspect, `--probe-managed`) | NVMe 큐 IRQ는 managed, `smp_affinity` 쓰기 `-EPERM`, irqbalance가 못 옮김 (→ 12/02 1, 3.1) | 커널 소스(`irq_can_set_affinity_usr()`) | 드라이버가 managed IRQ를 쓰지 않는 환경(일부 가상화 NVMe 등)에서는 쓰기가 성공한다 |
| `06` (hctx·IRQ 수) | poll 큐는 IRQ 벡터를 쓰지 않음, `HCTX_TYPE_POLL` (→ 12/02 1, 3.4, 4.2) | 커널 소스 | debugfs가 없으면 모듈 파라미터로만 추정 |
| `06` (QD1 irq vs poll) | 10µs급 장치에서는 폴링이 현실적, 폴링 큐 없으면 hipri 효과 없음 (→ 12/02 3.5, 4.7; 09/06 4.8) | 정성적 | 장치 지연 수준(NAND 수십 µs면 상대 이득 작음), C-state |
| `07 tx/rx` | MSG_ZEROCOPY는 약 10 KB 이상 쓰기에서만 효과 (→ 04/02 1, 3.1; 커널 문서) | 커널 문서의 일반론(특정 장비 수치 아님) | NIC scatter-gather·IOMMU·CPU·링크 속도. 링크가 포화되면 처리량이 같아지고 CPU 효율만 차이 |
| `07 loopback` | 로컬로 루프되는 패킷은 지연 복사되어 같은 호스트 벤치마크에서는 개선이 보이지 않음 (→ 04/02 3.1) | 커널 selftest `msg_zerocopy.sh` | 없음(기능 확인) |
| `07 --engine uring` | SEND_ZC의 작은 메시지 손익은 1차 출처 수치 없음, 실측 필요 (→ 04/02 1, 4.4 표) | 없음 | 문서에 기준값이 없으므로 측정값 자체가 결과 |
| `08` | FAST '24: 장치 2개·장치당 1코어 block 7.55M / passthrough·SPDK 10M, 1코어로 2장치 block 4.4M / passthrough 6M / SPDK 포화 (→ 03/02 4.6, 07/03) | Optane P5800X ×2, 512B randread, SPDK perf | 장치 2개 필요, Optane급 장치 필요 |
| `08` | SPDK 단일 스레드 10.39M IOPS (→ 07/01 2.1) | Xeon 8280L, P4600 ×21, 4KiB, 장치당 QD128 | 장치 21개 필요. 단일 장치로는 "SPDK 1코어가 장치를 포화시키는가"만 확인 |

---

## 9. 단일 머신에서 재현할 수 없거나 어려운 주장

| 주장 | 이유 |
|---|---|
| Haas & Leis 12.5M IOPS (→ 09/06 4.9) | SSD 8개와 64코어가 필요하다. 01은 장치·스레드 수에 따른 확장 추세만 본다 |
| SPDK 10.39M IOPS / 단일 시스템 80M·120M IOPS (→ 07/01) | 장치 21~24개와 특정 서버가 필요하다 |
| FAST '24 2장치 실험 (→ 03/02 4.6) | Optane P5800X 2개가 필요하다. NAND SSD에서는 장치가 먼저 포화되어 경로 차이가 사라진다 |
| FAST '24 "최적화 설정"과 추가 설정(강제 선점 끄기, HZ=100, wbt·blk-cgroup 제거) | 커널 재컴파일이 필요하다. 스크립트는 런타임으로 바꿀 수 있는 iostats/nomerges/wbt만 다룬다 |
| Peleg ATC '15 IOMMU 수치(16코어 23% → 93%) (→ 12/01) | Linux 3.17과 당시 IOVA 할당기, 10GbE netperf가 조건이다. 현대 커널에는 개선(rcache, FQ)이 이미 들어가 있어 같은 격차를 재현할 수 없다. 05는 현재 커널의 모드 간 차이만 잰다 |
| 200Gbps NIC IOTLB miss 20% 손실 (→ 12/01 3.4) | 200Gbps NIC와 상대 호스트가 필요하다 |
| MSG_ZEROCOPY 손익분기 (→ 04/02) | **두 호스트**가 필요하다. 루프백·veth는 지연 복사되므로 단일 호스트로는 손익분기를 잴 수 없다(07 loopback은 이 사실만 확인) |
| io_uring zcrx 메모리 대역폭 ~50% 감소 (→ 04/02 2.1) | 특정 NIC(Broadcom BCM57504), DDIO 비활성, 두 호스트가 필요하다. 이 키트에 포함하지 않았다 |
| kthread NAPI p99.9 3.69ms → 550µs (→ 12/02 3.6) | 100Gbps NIC, tcp_rr 1000 flow 부하 생성기(두 호스트)가 필요하다. 포함하지 않았다 |
| cinterrupts NVMe interrupt coalescing 100µs 단위 (→ 12/02) | `nvme set-feature -f 8`로 장치 설정을 바꿔야 하며 장치 지원 여부가 다르다. 포함하지 않았다 |
| Ren & Trivedi "고부하에서 io_uring이 SPDK보다 10배 이상 느림" (→ 09/06 3.1) | 다수 장치·코어 확장 실험이다. 01·02·08을 같은 장치에서 돌려 단일 장치 비율만 볼 수 있다 |
| Axboe kswapd 28/32코어 (→ 11/02 2.4) | 메모리보다 큰 워킹셋과 많은 코어가 필요하다. `--size`를 RAM의 2배 이상으로 주면 경향은 볼 수 있다. `--memcg`는 memcg 직접 회수라 kswapd 지표와는 다르다 |
| DEFER_TASKRUN/COOP_TASKRUN 효과 (→ 01/02) | 문서가 정량 수치를 제시하지 않는다. fio io_uring 엔진은 이 플래그를 자동 적용하며 끌 수 없다. liburing `send-zerocopy -d`로 네트워크 경로에서만 on/off 비교가 가능하다 |
| 동기 `RWF_HIPRI` 폴링 | 현재 커널 `block/fops.c`에서 `IOCB_HIPRI → REQ_POLLED`는 비동기 경로에만 있다. 06의 `pvsync2_hipri`는 대조군이다 |

---

## 10. 옵션 검증 출처

스크립트와 job 파일의 옵션·경로는 다음 원본과 대조했다(2026-10 기준 master).

- fio `HOWTO.rst`: `hipri`, `fixedbufs`, `registerfiles`, `sqthread_poll`, `sqthread_poll_cpu`, `cmd_type`, `userspace_reap`(`iodepth_batch_complete=0`일 때만 동작), `uncached`(`RWF_DONTCACHE`, 6.14+), `nowait`, `iodepth_batch_submit`, `iodepth_batch_complete_min/max`, `cpus_allowed_policy`, `percentile_list`, `new_group`, `--readonly`, `--section`, `--output-format=json`, job 파일 `${VAR}` 환경 변수 확장
- fio `engines/io_uring.c`: `uncached`가 `!td->o.odirect`일 때만 `RWF_DONTCACHE`를 붙임, `COOP_TASKRUN`·`SINGLE_ISSUER|DEFER_TASKRUN` 자동 시도. fio 태그별 확인: `io_uring_cmd`는 3.31부터 HOWTO에 등장, `uncached`→`RWF_DONTCACHE`는 3.40부터
- fio `examples/uring-cmd-ng.fio`: `/dev/ngXnY`에 `direct` 미사용. 커널 `fs/open.c`의 `do_dentry_open()`은 `FMODE_CAN_ODIRECT` 없는 파일의 `O_DIRECT` open을 `-EINVAL`로 거부하므로 jobs/engines.fio는 io_uring_cmd 섹션에 `direct=1`을 두지 않는다
- fio `t/io_uring.c`: getopt 문자열 `"e:d:s:c:b:p:B:F:H:n:N:O:t:T:a:r:D:R:X:S:P:V:u:h?"`, 기본값(depth 128, batch 32/32, bs 4096, polled 1, fixedbufs 1, register_files 1, register_ring 1, runtime 0=무제한), 장치를 `O_RDONLY`로 open, aio 모드는 폴링·등록 자원 미지원, 출력 형식 `IOPS=..., BW=..., IOS/call=a/b`와 `Maximum IOPS=`
- Linux `block/blk-sysfs.c`: `scheduler`, `nomerges`, `iostats`, `rq_affinity`, `io_poll`(쓰기 무시: "writes to the poll attribute are ignored"), `io_poll_delay`, `wbt_lat_usec`
- Linux `drivers/nvme/host/pci.c`: `poll_queues`, `write_queues`(0644), `io_queue_depth`, 리셋 시 파라미터 샘플링과 `nr_maps < 3`이면 poll 큐 추가 불가
- Linux `drivers/nvme/host/sysfs.c`: `reset_controller`
- Linux `drivers/iommu/iommu.c`: `early_param("iommu.passthrough")`, `early_param("iommu.strict")`, 그룹 `type` 값 `identity|DMA|DMA-FQ|auto`, `CAP_SYS_ADMIN`+`CAP_SYS_RAWIO`
- Linux `kernel/irq/proc.c`: `irq_can_set_affinity_usr()`가 거짓이면 쓰기 비트 없음, 쓰기 `-EPERM`
- Linux `block/fops.c`: `IOCB_HIPRI → REQ_POLLED`는 `__blkdev_direct_IO_async()`에만 존재
- Linux `block/{mq-deadline,kyber-iosched,bfq-iosched}.c`: elevator 이름 `mq-deadline`, `kyber`, `bfq`, kyber `read_lat_nsec`/`write_lat_nsec`
- Linux `include/uapi/linux/fs.h`: `RWF_DONTCACHE = 0x00000080`
- Linux `tools/testing/selftests/net/msg_zerocopy.c`/`.sh`: getopt `"46c:C:D:i:l:mp:rs:S:t:vzZ:"`, 기본 포트 8000, `-t`는 `200 + 초×1000` ms, `-Z` 기대값 불일치 시 exit 1, 출력 `tx=... (... MB) txc=... zc=y|n`
- liburing `examples/send-zerocopy.c`: getopt `"46D:p:s:t:n:z:I:b:l:dC:T:Ryv"`, 출력 `packets=... (MB=...), rps=... (MB/s=...)`
- SPDK `app/spdk_nvme_perf/perf.c`: `-q -o -w -t -c -r -a(warmup) -L(sw latency) -R(uring)`, 커널 장치 위치 인자, 출력 `Total : IOPS MiB/s avg min max`; `scripts/setup.sh`의 `PCI_ALLOWED`, `reset`, `HUGEMEM`
