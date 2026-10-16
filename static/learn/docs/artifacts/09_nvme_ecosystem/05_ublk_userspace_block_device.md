# ublk: io_uring 기반 사용자 공간 블록 장치 — 프로토콜, 기능 플래그, 제로카피, 그리고 NBD/TCMU/FUSE와의 비교

> 기준: Linux `torvalds/linux` master(7.3-rc7, 2026-10 확인)의 `drivers/block/ublk_drv.c`(약 6.0k줄), `include/uapi/linux/ublk_cmd.h`, `include/linux/io_uring/cmd.h`. 기능 플래그와 명령의 도입 버전은 git.kernel.org에서 v6.0~v7.2 각 태그의 `ublk_cmd.h`를 받아 이름별 최초 등장 태그를 grep으로 고정했다. 사용자 공간 구현은 `github.com/ublk-org/{ublksrv,libublk-rs,rublk}`, SPDK `lib/ublk/ublk.c`를 대조했다. SPDK ublk target의 스레딩 측면은 별도 문서(→ 07/03, 4.7절)에 있으므로 여기서는 커널 프로토콜 쪽을 중심으로 본다.

## 1. Verdict

ublk는 **blk-mq 요청을 io_uring `IORING_OP_URING_CMD`의 완료(CQE)로 사용자 공간 서버에 전달하고, 서버가 다음 `uring_cmd`를 제출하면서 결과를 돌려주는** 사용자 공간 블록 드라이버 프레임워크다. Ming Lei(Red Hat)가 작성했고 Linux 6.0 merge window에 io_uring pull에 섞여 들어왔다(LWN, 2022-08-08). 첫 커밋은 `71f28f3136aff5890cd56de78abc673f8393cad9`("ublk_drv: add io_uring based userspace block driver", Ming Lei, 2022-07-13)이다.

| 시점 | 변화 | 의미 |
|---|---|---|
| 6.0 | `ublk_drv`, `UBLK_IO_FETCH_REQ`/`UBLK_IO_COMMIT_AND_FETCH_REQ`, `UBLK_F_NEED_GET_DATA`, `UBLK_F_URING_CMD_COMP_IN_TASK` | 기본 프로토콜. 데이터는 커널이 복사 |
| 6.1 | `UBLK_F_USER_RECOVERY`, `UBLK_F_USER_RECOVERY_REISSUE` | 서버가 죽어도 `/dev/ublkbN` 유지 |
| 6.3 | `UBLK_F_UNPRIVILEGED_DEV`, `UBLK_PARAM_TYPE_DEVT` | 비특권 사용자의 장치 생성 |
| 6.4 | `UBLK_F_CMD_IOCTL_ENCODE`, `UBLK_U_CMD_*`/`UBLK_U_IO_*`(ioctl 인코딩) | opcode 충돌 방지, LSM 감사 가능 |
| 6.5 | `UBLK_F_USER_COPY`, `UBLK_U_CMD_GET_FEATURES` | `pread`/`pwrite`로 요청 버퍼에 직접 접근 |
| 6.6 | `UBLK_F_ZONED`, `UBLK_PARAM_TYPE_ZONED` | 존드 블록 장치 |
| 6.13 | `UBLK_F_USER_RECOVERY_FAIL_IO`, `UBLK_S_DEV_FAIL_IO` | 서버 부재 시 즉시 에러 |
| 6.15 | `UBLK_U_IO_REGISTER_IO_BUF`/`UNREGISTER_IO_BUF`(`UBLK_F_SUPPORT_ZERO_COPY`의 실제 구현. 플래그 비트 자체는 6.0 헤더부터 정의되어 있었으나 기능은 없었다) | io_uring 고정 버퍼 테이블 기반 **제로카피** |
| 6.16 | `UBLK_F_AUTO_BUF_REG`, `UBLK_F_PER_IO_DAEMON`, `UBLK_F_QUIESCE`, `UBLK_F_UPDATE_SIZE` | 제로카피 자동화, 태그별 데몬, 무중단 업그레이드 |
| 6.17 | `UBLK_F_BUF_REG_OFF_DAEMON` | 다른 태스크에서 버퍼 등록 |
| 7.0 | `UBLK_F_BATCH_IO`(`UBLK_U_IO_PREP/COMMIT/FETCH_IO_CMDS`), `UBLK_F_INTEGRITY`, `UBLK_F_SAFE_STOP_DEV`, `UBLK_F_NO_AUTO_PART_SCAN` | 배치 전달, PI 메타데이터 |
| 7.1 | `UBLK_F_SHMEM_ZC`, `UBLK_U_CMD_REG_BUF`/`UNREG_BUF` | 공유 메모리 매칭 제로카피 |
| 7.3-rc | `UBLK_F_IO_DESC_SIZE` | `ublksrv_io_desc` 크기 가변화 |

결론:

1. **ublk의 설계 핵심은 "드라이버는 작게, 로직은 사용자 공간에"다.** 커널 쪽은 blk-mq 큐, 태그별 `uring_cmd` 보관, 데이터 이동(복사 또는 버퍼 공유), 수명 관리만 맡는다. 실제 장치 의미(loop, qcow2, 네트워크 스토리지, SPDK bdev)는 전부 서버가 구현한다. 커버 레터는 ublk-loop가 "< 200 lines of loop specific code"로 커널 loop와 같은 기능을 낸다고 적었다.
2. **NBD/TCMU 대비 장점은 전송 경로의 효율이다.** 요청 전달이 소켓이나 SCSI CDB 링이 아니라 io_uring CQE이고, 완료 보고와 다음 요청 대기가 한 SQE(`COMMIT_AND_FETCH`)로 합쳐진다. 서버는 백엔드 I/O에도 같은 io_uring을 쓸 수 있다.
3. **제로카피는 세 번의 설계 시도 끝에 6.15에서 io_uring 고정 버퍼 테이블로 정착했다.** BPF 프로그램 타입(Xiaoguang Wang), fused command(Ming Lei), splice 기반(Pavel Begunkov) 제안이 경쟁했다(LWN, 2023-03-16). 최종안은 Keith Busch의 "io_uring: add support for kernel registered bvecs"(`27cb27b6d5ea401143ca3648983342bb820c4be9`)와 "ublk: zc register/unregister bvec"(`1f6540e2aabb7372e68223a3669019589c3e30ad`), 2025-02-27이다. 요청의 bvec을 io_uring 버퍼 테이블 인덱스로 등록하면 서버는 데이터를 **보지 않고** `IORING_OP_READ_FIXED`/`WRITE_FIXED`나 `IORING_URING_CMD_FIXED`로 백엔드에 넘긴다.
4. **보안 모델이 기능 조합을 제한한다.** `UBLK_F_UNPRIVILEGED_DEV`는 `UBLK_F_USER_COPY`, `UBLK_F_SUPPORT_ZERO_COPY`와 함께 쓸 수 없다. 헤더 주석이 이유를 밝힌다. 서버가 요청 버퍼를 다 채우지 않으면 초기화되지 않은 커널 메모리가 새기 때문이다.
5. **운영상 가장 중요한 기능은 recovery 계열이다.** `USER_RECOVERY`(6.1) → `FAIL_IO`(6.13) → `QUIESCE`(6.16)로 이어지며, 서버 크래시나 업그레이드 중에도 블록 장치를 유지하는 시나리오가 표준 uAPI가 되었다.

---

## 2. Problem Statement

### 2.1 기존 사용자 공간 블록 경로의 한계

| 경로 | 요청 전달 | 데이터 이동 | 구조적 한계 |
|---|---|---|---|
| NBD(`drivers/block/nbd.c`) | TCP/UNIX 소켓으로 NBD 프로토콜 직렬화 | 소켓 send/recv(복사) | 로컬 서버도 소켓 스택을 지남. 연결(`struct nbd_sock`)마다 송수신 경로. 연결 장애 처리(`NBD_ATTR_DEAD_CONN_TIMEOUT`) 복잡 |
| TCMU(`drivers/target/target_core_user.c`, Linux 3.18) | LIO SCSI target → mmap 링에 SCSI CDB | 커널이 링의 데이터 영역에 복사 | SCSI 계층(LIO + iSCSI/loopback fabric)을 반드시 거침. 블록 의미가 아니라 SCSI 에뮬레이션 |
| FUSE | `/dev/fuse` read/write(6.14부터 io_uring 옵션) | 복사(일부 splice) | 파일 시스템 인터페이스. 블록 장치가 필요하면 그 위에 loop를 또 올려야 함 |
| VDUSE(5.15) | virtio virtqueue | bounce buffer | virtio 의미론을 강제. 호스트 노출에는 virtio-vdpa 필요 |
| BUSE 등 out-of-tree | 다양 | 다양 | 메인라인 아님 |

커버 레터에 따르면 Alibaba의 Ziyang Zhang은 "plan to replace TCMU by UBD as a new choice"라고 했다. UBD(ublk의 초기 이름)가 단일 큐에서도 TCMU보다 처리량이 높다는 이유였다.

### 2.2 사용자 공간 블록 드라이버가 필요한 이유

- **복잡한 포맷**: qcow2 같은 이미지 포맷이나 압축·암호화·중복 제거 계층은 커널에 넣기 어렵다. 커버 레터는 "high performance qcow2 support"를 예로 든다.
- **분산 스토리지 클라이언트**: 네트워크 스토리지 클라이언트를 커널 모듈로 유지하는 비용(커널 버전 추종, 크래시 영향 범위)을 피한다.
- **컨테이너**: 컨테이너는 블록 장치(파일 시스템 마운트용)를 원하지만, SPDK나 사용자 공간 스토리지 데몬은 블록 장치를 직접 만들 수 없다. 이전에는 NBD나 NVMe-oF loopback을 거쳤다(→ 07/03, 3.3절).
- **개발·디버깅 생산성**: 드라이버 버그가 커널 패닉 대신 프로세스 크래시로 끝나고, recovery 기능을 쓰면 장치도 유지된다.

### 2.3 io_uring passthrough가 만든 기회

io_uring의 `IORING_OP_URING_CMD`(5.19)와 `struct file_operations::uring_cmd`는 드라이버가 임의의 비동기 명령을 io_uring에 노출하게 해 준다. NVMe passthrough(`NVME_URING_CMD_IO`)에서 이 경로가 효율적이라는 것이 확인되었다. 커버 레터는 이렇게 적는다. "io_uring command which has been proved as very efficient for making nvme passthrough IO to get better IOPS than io_uring(READ/WRITE)". ublk는 방향을 뒤집어, 커널이 사용자 공간에 요청을 "제출"하는 통로로 `uring_cmd`의 완료를 사용한다. 미리 제출해 둔 `UBLK_IO_FETCH_REQ`가 요청 도착 시 완료되는 방식이다.

---
## 3. The Debate

### 3.1 제로카피: 세 가지 제안과 최종 해법

2022년 6.0 시점 ublk는 데이터를 항상 복사했다. LWN의 6.0 기사도 "the ublk protocol is set up to enable zero-copy I/O, but that is not implemented in the current code"라고 적었다. 2023년 초 세 가지 제안이 동시에 나왔다(LWN "Zero-copy I/O for ublk, three different ways", Jonathan Corbet, 2023-03-16).

1. **BPF(Xiaoguang Wang, Alibaba)**: `BPF_PROG_TYPE_UBLK` 프로그램이 커널 안에서 요청을 처리해 사용자 공간 왕복을 없앤다.
2. **fused command(Ming Lei)**: 주 명령 `IORING_OP_FUSED_CMD`와 실제 I/O를 하는 보조 명령을 한 단위로 제출한다. 보조 명령은 주 명령이 빌려준 커널 요청 버퍼를 쓴다. 이후 "generic `IORING_OP_FUSED_CMD`"로 일반화되었다(LWN 927875).
3. **splice 기반(Pavel Begunkov)**: 기존 splice와 io_uring 등록 버퍼를 활용하는 PoC.

LWN 기사가 전하는 반응은 다음과 같다.

> "it all looks a bit complicated and intrusive"
> — Pavel Begunkov의 fused command 평가 (LWN 2023-03-16 기사 내 인용, [lwn.net/Articles/926118](https://lwn.net/Articles/926118/))

> "the right direction to support ublk zero copy"
> — Xiaoguang Wang이 fused command 접근을 평가한 표현 (같은 기사)

해설: io_uring 메인테이너 측(Begunkov)은 SQE 간 의존성과 자원 공유라는 새 의미론을 io_uring 코어에 넣는 것을 꺼렸다. 사용자(Alibaba)는 기능이 필요했다. fused command는 메인라인에 들어가지 않았고, 이후 "sqe group and leased group kbuf"(LWN 993958, 2024) 시도를 거쳐 2025-02 Keith Busch의 방식으로 정리되었다. 핵심은 io_uring의 기존 **등록 버퍼 테이블**(`IORING_REGISTER_BUFFERS2`의 sparse 테이블)에 커널이 요청의 bvec을 직접 꽂는 인터페이스, `io_buffer_register_bvec()`이다(master에는 `io_buffer_register_request()`도 있다). 새 SQE 의미론 없이 기존 `*_FIXED` 연산의 `buf_index`로 접근하므로 io_uring 코어 변경이 작다.

### 3.2 비특권 ublk와 정보 누출

`UBLK_F_UNPRIVILEGED_DEV`(6.3)는 `/dev/ublk-control`을 udev 규칙으로 일반 사용자에게 열어 주는 모델이다. `UBLK_CMD_ADD_DEV`를 제외한 모든 제어 명령은 장치 소유자(`owner_uid`/`owner_gid`, 커널이 `ublk_store_owner_uid_gid()`로 기록)만 쓸 수 있다. 문제는 데이터 경로다. 커널이 복사하는 기본 모드에서는 커널이 버퍼를 채운다. 그러나 USER_COPY나 제로카피에서는 서버가 READ 요청 버퍼를 일부만 채우고 완료하면, 페이지 캐시 페이지에 남아 있던 초기화되지 않은 커널 메모리가 다른 사용자에게 보일 수 있다. 헤더는 두 플래그 모두에 "Not available for UBLK_F_UNPRIVILEGED_DEV"를 명시한다. 그래서 비특권 컨테이너용 ublk는 복사 모드로만 동작하고, 성능과 권한 모델이 교환 관계에 놓인다.

### 3.3 커널 드라이버를 사용자 공간으로 옮기는 것에 대한 시각

LWN 6.0 기사는 의미를 이렇게 짚었다. "whether this mechanism might ultimately facilitate the movement of a number of device drivers out of the kernel"(Jonathan Corbet, 2022-08-08). 블록 계층 쪽에서 반대가 공개적으로 크게 기록되지는 않았다. ublk가 블록 의미를 유지하고(blk-mq 큐, 태그, 타임아웃 `ublk_timeout()`), 커널 쪽 코드가 작으며, 메인테이너(Jens Axboe)가 io_uring과 블록을 함께 맡고 있다는 점이 작용한 것으로 보인다 `[추측/미확인]`. 관측 가능한 논쟁은 주로 io_uring 쪽 인터페이스(제로카피, 배치, 취소)에 대한 것이었다.

### 3.4 ublk vs NBD vs VDUSE: 무엇을 표준 로컬 노출 경로로 삼을 것인가

SPDK는 컨테이너에 장치를 노출하는 경로로 NBD를 오래 써 왔다. 2023년 블로그 "ublk: the new and improved way to serve SPDK storage locally!"(Jim Harris, 2023-03-28)에서 ublk로 방향을 바꿨다(→ 07/03). QEMU 진영은 qemu-storage-daemon에서 NBD, FUSE(6.0), vhost-user-blk(5.2), VDUSE(7.1) export를 모두 제공한다. QEMU master `qapi/block-export.json`에는 ublk export 타입이 없다(2026-10 확인). 선택 기준은 다음과 같다.

- **같은 호스트의 블록 장치가 필요하고 io_uring을 쓸 수 있으면** ublk가 가장 직접적이다.
- **VM과 호스트 양쪽에 같은 백엔드를 붙이고 싶으면** VDUSE가 유리하다(virtio-vdpa/vhost-vdpa 이중 노출, → 09/04, 4.6절).
- **원격 노출이 기본이면** NBD나 NVMe-oF(TCP)가 맞다. ublk는 로컬 전용이다.

---
## 4. Implementation Impact

### 4.1 장치 노드와 제어 경로

| 노드 | 생성 | 역할 |
|---|---|---|
| `/dev/ublk-control` | `misc` 장치(`.name = "ublk-control"`) | 제어 명령 `uring_cmd` 수신(`ublk_ctrl_uring_cmd()`) |
| `/dev/ublkcN` | `ublk_chr_class`, `dev_set_name(dev, "ublkc%d", ...)` | 서버용 char 장치. I/O `uring_cmd`, `mmap`(I/O 디스크립터), USER_COPY용 `read_iter`/`write_iter` |
| `/dev/ublkbN` | `sprintf(disk->disk_name, "ublkb%d", ...)` | 실제 블록 장치(gendisk) |

제어 명령은 `IORING_SETUP_SQE128` 링에서 `/dev/ublk-control`에 `IORING_OP_URING_CMD`로 보낸다. 페이로드는 SQE의 cmd 영역에 들어가는 `struct ublksrv_ctrl_cmd { __u32 dev_id; __u16 queue_id; __u16 len; __u64 addr; __u64 data[1]; ... }`다. master 헤더의 제어 명령은 다음과 같다(모두 `UBLK_U_CMD_` 접두사, ioctl 인코딩).

`GET_QUEUE_AFFINITY`, `GET_DEV_INFO`, `ADD_DEV`, `DEL_DEV`, `START_DEV`, `STOP_DEV`, `SET_PARAMS`, `GET_PARAMS`, `START_USER_RECOVERY`, `END_USER_RECOVERY`, `GET_DEV_INFO2`, `GET_FEATURES`(6.5), `DEL_DEV_ASYNC`(6.9), `UPDATE_SIZE`(6.16), `QUIESCE_DEV`(6.16), `TRY_STOP_DEV`(7.0), `REG_BUF`/`UNREG_BUF`(7.1).

6.0의 원래 opcode는 `UBLK_CMD_ADD_DEV` 같은 평범한 정수였다. 6.4에서 `_IOWR('u', ...)` 인코딩의 `UBLK_U_CMD_*`가 추가되었다. 레거시 opcode는 `CONFIG_BLKDEV_UBLK_LEGACY_OPCODES`(기본 y)로 계속 받는다. Kconfig 도움말은 평범한 인코딩이 "turns out one bad way"였다고 적는다. ioctl 인코딩은 opcode 충돌을 막고 보안 모듈이 io_uring 명령을 감사하는 데도 도움이 된다.

전형적인 생명 주기는 다음과 같다.

1. `ADD_DEV`(`struct ublksrv_ctrl_dev_info`: `nr_hw_queues`, `queue_depth`(최대 `UBLK_MAX_QUEUE_DEPTH` 4096), `flags`=`UBLK_F_*`) → 커널이 `ublk_ctrl_add_dev()`로 `blk_mq_tag_set` 할당, `/dev/ublkcN` 생성
2. `SET_PARAMS`(`struct ublk_params`: `UBLK_PARAM_TYPE_BASIC`(블록 크기, 최대 섹터, 속성 `UBLK_ATTR_READ_ONLY`/`ROTATIONAL`/`VOLATILE_CACHE`/`FUA`), `DISCARD`, `DEVT`, `ZONED`, `DMA_ALIGN`(6.15), `SEGMENT`(6.15), `INTEGRITY`(7.0))
3. 서버가 `/dev/ublkcN`을 열고 큐별 io_uring을 만든 뒤 모든 태그에 `UBLK_U_IO_FETCH_REQ` 제출
4. `START_DEV` → `ublk_ctrl_start_dev()`가 모든 큐가 준비되기를(`ublk_dev_ready()`) 기다린 뒤 gendisk를 추가(`/dev/ublkbN` 등장, `UBLK_F_NO_AUTO_PART_SCAN`이 없으면 파티션 스캔)
5. `STOP_DEV`/`DEL_DEV`(또는 `DEL_DEV_ASYNC`, `TRY_STOP_DEV`)

### 4.2 I/O 경로: FETCH → 요청 도착 → COMMIT_AND_FETCH

I/O 명령은 `UBLK_U_IO_FETCH_REQ`, `UBLK_U_IO_COMMIT_AND_FETCH_REQ`, `UBLK_U_IO_NEED_GET_DATA`, `UBLK_U_IO_REGISTER_IO_BUF`, `UBLK_U_IO_UNREGISTER_IO_BUF`(이상 비배치 모드)이다. 페이로드는 `struct ublksrv_io_cmd { __u16 q_id; __u16 tag; __s32 result; union { __u64 addr; ... }; }`다.

```
[커널]                                                     [서버 큐 스레드]
                                                           io_uring_prep_cmd(FETCH_REQ, q_id, tag, addr=buf)
ublk_ch_uring_cmd() → ublk_ch_uring_cmd_local()            (태그 수만큼 미리 제출, CQE 대기)
  ublk_fetch(): io->cmd = cmd 보관, io_uring_cmd_mark_cancelable()
blk-mq: ublk_queue_rq() / ublk_queue_rqs()
  ublk_prep_req() → ublk_queue_cmd()
  → io_uring_cmd_complete_in_task(cmd, ublk_cmd_tw_cb)    (서버 태스크 컨텍스트로 이동)
ublk_cmd_tw_cb() → ublk_dispatch_req()
  ublk_start_io(): WRITE면 ublk_map_io()로 bio → 서버 버퍼 복사
  (또는 AUTO_BUF_REG면 ublk_auto_buf_dispatch()로 버퍼 등록)
  ublk_complete_io_cmd() → io_uring_cmd_done()   ───CQE──▶  mmap된 ublksrv_io_desc[tag] 읽기
                                                           (op_flags, nr_sectors, start_sector, addr)
                                                           백엔드 I/O 수행 (같은 링의 READ/WRITE 등)
                                                  ◀──SQE── COMMIT_AND_FETCH_REQ(tag, result)
ublk_ch_uring_cmd_local(): 결과 반영
  READ면 ublk_unmap_io()로 서버 버퍼 → bio 복사
  __ublk_complete_rq() → blk_mq_end_request()
  같은 SQE가 다음 요청용 FETCH 역할을 이어받음
```

설계상 중요한 점은 다음과 같다.

- **I/O 디스크립터는 공유 mmap 영역에 있다.** `ublk_ch_mmap()`이 큐별 `ublksrv_io_desc` 배열(offset `UBLKSRV_CMD_BUF_OFFSET`)을 서버에 읽기 전용으로 매핑한다. 커버 레터 기준 디스크립터는 I/O당 24바이트다(`op_flags`, `nr_sectors`/`nr_zones`, `start_sector`, `addr`). 7.3-rc의 `UBLK_F_IO_DESC_SIZE`는 이 크기를 `ublksrv_ctrl_dev_info.io_desc_size`로 가변화한다.
- **완료는 반드시 서버 태스크 컨텍스트에서 이뤄진다.** 블록 계층의 `queue_rq`는 임의 CPU에서 호출되지만, 기본 복사 모드에서 커널이 서버 버퍼(사용자 VA)에 접근하려면 서버의 mm 안에 있어야 한다. 그래서 `io_uring_cmd_complete_in_task()`로 task_work를 건다. `UBLK_F_URING_CMD_COMP_IN_TASK`는 원래 task_work_add 방식과 비교하려고 이 경로를 강제하던 플래그다.
- **`UBLK_F_NEED_GET_DATA`(6.0)**: WRITE에서 커널이 즉시 복사하지 않고 `UBLK_IO_RES_NEED_GET_DATA`로 먼저 알린다. 서버는 버퍼를 준비한 뒤 `UBLK_U_IO_NEED_GET_DATA`로 버퍼 주소를 준다. 태그마다 버퍼를 미리 고정하지 않아도 되므로 메모리를 아낀다.
- **취소**: 서버가 죽으면 io_uring 취소 경로가 `ublk_uring_cmd_cancel_fn()`을 부르고, `ublk_abort_queue()`가 진행 중 요청을 recovery 정책에 따라 실패시키거나 재큐한다. 결과 코드 `UBLK_IO_RES_ABORT`(`-ENODEV`)는 "다시 FETCH하지 말라"는 의미다.

### 4.3 데이터 이동 모드 비교

| 모드 | 플래그(도입) | 데이터 경로 | 서버가 데이터를 보는가 | 비특권 사용 | 비고 |
|---|---|---|---|---|---|
| 커널 복사(기본) | 없음(6.0) | `ublk_map_io()`/`ublk_unmap_io()`가 bio 페이지 ↔ 서버 버퍼(`addr`) 복사 | 예 | 가능 | 큰 블록에서 메모리 대역폭 소모 |
| 지연 버퍼 지정 | `UBLK_F_NEED_GET_DATA`(6.0) | WRITE 시 서버가 버퍼를 나중에 제공 | 예 | 가능 | 메모리 절약 |
| 사용자 복사 | `UBLK_F_USER_COPY`(6.5) | 서버가 `/dev/ublkcN`에 `pread`/`pwrite`(offset `UBLKSRV_IO_BUF_OFFSET` + q_id/tag 인코딩) → `ublk_ch_read_iter()`/`ublk_ch_write_iter()` | 예 | 불가 | 서버가 복사 시점·범위 결정, 메타데이터(`UBLK_F_INTEGRITY` 7.0) 전제 조건 |
| 제로카피 | `UBLK_F_SUPPORT_ZERO_COPY` + `UBLK_U_IO_REGISTER_IO_BUF`(6.15) | 요청 bvec을 io_uring 버퍼 테이블에 등록 → 백엔드 `*_FIXED` 연산 | 아니오 | 불가 | 등록·해제에 `uring_cmd` 2회 추가 |
| 자동 등록 제로카피 | `UBLK_F_AUTO_BUF_REG`(6.16) | FETCH/COMMIT 시 자동 등록·해제(`struct ublk_auto_buf_reg`를 `sqe->addr`로 전달) | 아니오 | 불가 | 추가 명령 2회 제거 |
| 공유 메모리 제로카피 | `UBLK_F_SHMEM_ZC` + `UBLK_U_CMD_REG_BUF`(7.1) | 요청 페이지가 서버가 등록한 공유 메모리와 일치하면 `UBLK_IO_F_SHMEM_ZC` + 버퍼 인덱스/오프셋 전달 | 해당 공유 영역은 예 | 확인 못 함 | `UBLK_SHMEM_BUF_READ_ONLY`(write-sealed memfd) |

제로카피 경로의 수명 규칙은 헤더 주석에 명시되어 있다. "The ublk request is completed when its buffer is unregistered from all io_uring instances and the ublk server issues UBLK_U_IO_COMMIT_AND_FETCH_REQ." 커널은 `ublk_register_io_buf()`에서 해제 콜백 `ublk_io_release()`를 넘기며 버퍼를 등록한다. 6.15~7.2 태그에서는 `io_buffer_register_bvec()`, 7.3-rc1 이후(master)에서는 `io_buffer_register_request()`를 쓴다. 마지막 io_uring 연산이 버퍼 참조를 놓을 때까지 요청 참조(`ublk_get_req_ref()`/`ublk_put_req_ref()`)를 유지한다. 6.15 초기에는 등록·해제가 그 I/O를 담당하는 데몬 태스크에서만 가능했다. 6.17의 `UBLK_F_BUF_REG_OFF_DAEMON`이 이 제약을 풀어, 백엔드 I/O를 다른 스레드의 링에서 내도 된다.

제로카피가 이득인 경우: LWN에 게재된 Ming Lei의 fused command 패치 커버 레터(927875)는 다음 측정을 적었다. ramfs 백엔드 loop에서 64K/512K 블록 시 1~2배, ublk-null 대형 블록에서 5배 IOPS 향상이다(당시 fused 패치 기준이며 6.15 구현의 수치는 아님). 4KiB 랜덤 I/O에서는 복사 비용이 작아 등록·해제 명령 오버헤드와 상쇄될 수 있다. 그래서 AUTO_BUF_REG가 추가되었다.

### 4.4 Recovery와 무중단 업그레이드

| 플래그 | 서버 종료 시 진행 중 I/O | 서버 부재 중 새 I/O | 도입 |
|---|---|---|---|
| (없음) | 장치 제거 | — | 6.0 |
| `UBLK_F_USER_RECOVERY` | 에러 | 큐잉 | 6.1 |
| `UBLK_F_USER_RECOVERY_REISSUE` | 재발행 | 큐잉 | 6.1 |
| `UBLK_F_USER_RECOVERY_FAIL_IO` | 에러 | 에러(`UBLK_S_DEV_FAIL_IO`) | 6.13 |
| `UBLK_F_QUIESCE` (+RECOVERY) | `UBLK_U_CMD_QUIESCE_DEV`로 의도적 정지 | 큐잉 | 6.16 |

절차는 이렇다. 서버가 죽으면 장치 상태가 `UBLK_S_DEV_QUIESCED`(큐잉) 또는 `UBLK_S_DEV_FAIL_IO`가 된다. 새 서버 프로세스가 `UBLK_U_CMD_START_USER_RECOVERY` → `/dev/ublkcN` 재오픈 → 모든 태그 FETCH → `UBLK_U_CMD_END_USER_RECOVERY`를 수행하면 `UBLK_S_DEV_LIVE`로 복귀한다. 내부적으로는 `ublk_nosrv_should_queue_io()`, `ublk_nosrv_should_reissue_outstanding()`, `ublk_queue_reinit()`이 이 정책을 구현한다. REISSUE는 쓰기의 멱등성을 서버가 보장할 때만 안전하다. 같은 쓰기가 두 번 백엔드에 도달할 수 있기 때문이다. `UBLK_F_QUIESCE`의 헤더 주석은 "Typical use case is for supporting to upgrade ublk server application, meantime keep ublk block device persistent during the period"라고 용도를 밝힌다.

### 4.5 스레딩 모델의 진화: 큐별 데몬 → 태그별 데몬 → 배치

- **초기 모델**: 하드웨어 큐 하나 = 서버 스레드 하나 = io_uring 하나. 같은 q_id의 모든 태그는 같은 태스크가 FETCH해야 한다(6.15까지의 큐별 `ubq_daemon` 태스크 개념. 6.16부터는 I/O별 태스크 기록으로 바뀌었다).
- **`UBLK_F_PER_IO_DAEMON`(6.16)**: (q_id, tag)마다 담당 태스크가 달라도 된다. 큐 수보다 스레드가 많거나 적을 때 부하를 분산할 수 있고, 한 스레드가 여러 큐의 태그를 섞어 맡을 수도 있다. libublk-rs README가 이 플래그를 언급한다.
- **`UBLK_F_BATCH_IO`(7.0)**: `UBLK_U_IO_PREP_IO_CMDS`/`UBLK_U_IO_COMMIT_IO_CMDS`/`UBLK_U_IO_FETCH_IO_CMDS`로 여러 태그를 한 `uring_cmd`로 준비·완료·수신한다. 커널 쪽은 `ublk_batch_queue_rqs()`, `ublk_batch_dispatch()`, `ublk_batch_tw_cb()`다. 기존 `FETCH_REQ`/`COMMIT_AND_FETCH_REQ`/`NEED_GET_DATA`는 이 모드에서 지원되지 않는다. 태그당 SQE/CQE 하나라는 원래 프로토콜의 고정 비용을 낮추는 변화다.

### 4.6 사용자 공간 구현체

| 구현 | 언어 | 특징 | 확인 근거 |
|---|---|---|---|
| ublksrv / libublksrv (`ublk-org/ublksrv`, 2022-03 생성) | C/C++20 | 레퍼런스 서버. `ublk add -t null`, `ublk add -t loop -f <file>`, `--unprivileged`. libublksrv로 타깃 작성. 커널 문서가 "ublksrv [1] is one of such implementation"으로 소개 | README, docs.kernel.org/block/ublk.html |
| libublk-rs (`ublk-org/libublk-rs`, 2023-06 생성) | Rust | `UblkCtrlBuilder`/`UblkCtrl`(제어), `UblkDev`, `UblkQueue`(큐 I/O), async/await 기반 태그 처리. README에 `UBLK_F_PER_IO_DAEMON`, `UBLK_F_SHMEM_ZC` 언급 | README |
| rublk (`ublk-org/rublk`, 2023-08 생성) | Rust | libublk 기반 타깃 모음: `null`, `loop`, `zoned`("supported since v6.6"), `qcow2`, `compress`(RocksDB 기반), `vram`(GPU 메모리 블록 장치). `recover` 서브커맨드 | README |
| kublk (`tools/testing/selftests/ublk/`, 6.15) | C | 커널 셀프테스트용 서버. 타깃 `null`, `loop`, `stripe`, `fault_inject`. 옵션에 `auto_zc`, `auto_zc_fallback`, `batch`, `get_data`, `integrity_*`, `io_desc_size` 등 최신 기능 시험 | `kublk.c` |
| nbdublk | C | libnbd 프로젝트의 NBD 클라이언트를 ublk 장치로 노출. 커널 문서가 언급 | docs.kernel.org |
| SPDK ublk target (`lib/ublk/ublk.c`, v23.01) | C | SPDK bdev를 `/dev/ublkbN`로 노출 | 4.7절 |

커널 셀프테스트 서버(kublk)가 6.15에 들어온 것은 의미가 크다. 이전에는 ublk 기능 회귀를 외부 저장소(ublksrv 테스트)로만 잡았다. 이제 새 플래그(AUTO_BUF_REG, BATCH_IO, INTEGRITY 등)가 커널 트리 안의 테스트와 함께 병합된다.

### 4.7 SPDK ublk target

SPDK의 RPC는 `ublk_create_target`(커널 ublk 제어 링과 poller 생성), `ublk_start_disk`(bdev 이름, ublk id, 큐 수, 큐 깊이), `ublk_stop_disk`, `ublk_destroy_target`이다(spdk.io/doc/ublk.html). master `lib/ublk/ublk.c`가 참조하는 플래그와 명령은 `UBLK_F_CMD_IOCTL_ENCODE`, `UBLK_F_NEED_GET_DATA`, `UBLK_F_URING_CMD_COMP_IN_TASK`, `UBLK_F_USER_COPY`, `UBLK_F_USER_RECOVERY`, `UBLK_F_USER_RECOVERY_REISSUE`, `UBLK_IO_FETCH_REQ`, `UBLK_IO_COMMIT_AND_FETCH_REQ`, `UBLK_IO_NEED_GET_DATA`, `UBLK_U_CMD_GET_FEATURES`다. 즉 **SPDK는 6.15 제로카피(`REGISTER_IO_BUF`/`AUTO_BUF_REG`)를 아직 쓰지 않는다**(master grep 기준, 2026-10). SPDK bdev I/O는 SPDK 자체 DMA 메모리(hugepage)를 쓰므로, 커널 bvec을 io_uring 버퍼로 받는 모델과 바로 맞지 않는다. 대신 USER_COPY로 SPDK 버퍼와 요청 페이지 사이를 서버가 원하는 시점에 복사한다. SPDK reactor는 ublk io_uring CQ를 poller로 수거하므로, 인터럽트나 eventfd 없이 폴링 모델과 결합된다(→ 07/03, 4.7절).

### 4.8 대안과의 종합 비교

| 항목 | ublk | NBD | TCMU | FUSE(+loop) | VDUSE(virtio-vdpa) |
|---|---|---|---|---|---|
| 커널 쪽 인터페이스 | blk-mq 드라이버 + `uring_cmd` | blk-mq 드라이버 + 소켓 | LIO SCSI backstore + mmap 링 | VFS + `/dev/fuse` | vDPA 버스 + virtio 장치 |
| 요청 전달 | CQE(미리 제출한 FETCH 완료) | 소켓 메시지 | 링 엔트리 + uio 알림 | read/write 또는 io_uring(6.14) | virtqueue |
| 완료 보고 | 다음 SQE(`COMMIT_AND_FETCH`)와 결합 | 소켓 응답 | 링 엔트리 | write | used ring |
| 데이터 이동 | 복사 / USER_COPY / io_uring 고정 버퍼 제로카피 | 소켓 복사 | 링 데이터 영역 복사 | 복사, 일부 splice | bounce buffer |
| 멀티큐 | 하드웨어 큐 = 서버 큐(또는 태그별 데몬) | 연결 수만큼 | 제한적 | 다중 채널 | virtqueue 수 |
| 서버 재시작 | `USER_RECOVERY` 계열, `QUIESCE` | 재연결(타임아웃 의존) | 제한적 | 마운트 상실 | 장치 재생성 |
| 비특권 | `UNPRIVILEGED_DEV`(복사 모드 한정) | `CAP_SYS_ADMIN` | root | 기본 지원(fusermount) | root |
| 원격 노출 | 불가(로컬) | 가능(본래 용도) | iSCSI 등 fabric 경유 | 불가 | 불가 |
| 존드/PI | `UBLK_F_ZONED`(6.6), `UBLK_F_INTEGRITY`(7.0) | 없음 | SCSI ZBC 에뮬레이션은 서버 몫 | 해당 없음 | virtio-blk zoned(6.3) |

### 4.9 운영상 주의점

- **커널 버전 협상**: 서버는 `UBLK_U_CMD_GET_FEATURES`(6.5+)로 지원 플래그 비트맵을 받아 요청 플래그를 조정해야 한다. 6.4 이하에서는 이 명령이 없으므로 ADD_DEV 실패로 판단해야 한다.
- **io_uring 정책**: 일부 배포판이나 컨테이너 런타임은 seccomp나 `kernel.io_uring_disabled` sysctl로 io_uring을 막는다. 이 경우 ublk 서버 자체가 동작하지 않는다.
- **메모리 회수 교착**: ublk 장치 위의 파일 시스템이 메모리 회수 중 writeback을 내면 서버가 그 I/O를 처리해야 한다. 서버가 메모리 할당에서 막히면 교착이 생긴다. 서버를 `mlockall`하고 버퍼를 미리 할당하는 것이 일반적인 완화책이다. 커널 문서 차원의 공식 권고는 확인하지 못했다 `[추측/미확인]`.
- **CPU 배치**: `UBLK_U_CMD_GET_QUEUE_AFFINITY`로 받은 큐별 CPU 마스크에 서버 큐 스레드를 핀하면, task_work 전달과 완료가 같은 CPU에서 일어나 캐시 지역성이 좋아진다.
- **타임아웃**: blk-mq 타임아웃(`ublk_timeout()`)은 서버가 응답하지 않는 I/O를 처리한다. recovery 플래그 조합에 따라 결과가 에러/재큐로 달라진다.

---

## 5. Primary References

- [lwn.net - An io_uring-based user-space block driver](https://lwn.net/Articles/903855/) — Jonathan Corbet, 6.0 merge window 기사, 2022-08-08
- [lwn.net - ublk: add io_uring based userspace block driver](https://lwn.net/Articles/900690/) — Ming Lei 커버 레터 게시본, 2022-07-11, Message-ID `20220711022024.217163-1-ming.lei@redhat.com`
- [lwn.net - Zero-copy I/O for ublk, three different ways](https://lwn.net/Articles/926118/) — Jonathan Corbet, 제로카피 세 제안 비교, 2023-03-16
- [lwn.net - io_uring/ublk: add generic IORING_OP_FUSED_CMD](https://lwn.net/Articles/927875/) — Ming Lei fused command 패치 게시본(측정치 포함)
- [lwn.net - io_uring: support sqe group and leased group kbuf](https://lwn.net/Articles/993958/) — Ming Lei [PATCH V7 0/8] 게시본, 2024-10
- [kernel.org - Userspace block device driver (ublk driver)](https://docs.kernel.org/block/ublk.html) — ublk 커널 문서
- [git.kernel.org - include/uapi/linux/ublk_cmd.h](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/include/uapi/linux/ublk_cmd.h) — ublk uAPI(플래그, 명령, 구조체)
- [git.kernel.org - drivers/block/ublk_drv.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/block/ublk_drv.c) — ublk 커널 드라이버
- [git.kernel.org - include/linux/io_uring/cmd.h](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/include/linux/io_uring/cmd.h) — `io_buffer_register_*()` 등 uring_cmd 커널 API
- [github.com/torvalds/linux - ublk_drv: add io_uring based userspace block driver](https://github.com/torvalds/linux/commit/71f28f3136aff5890cd56de78abc673f8393cad9) — Ming Lei, 2022-07-13 (6.0)
- [github.com/torvalds/linux - io_uring: add support for kernel registered bvecs](https://github.com/torvalds/linux/commit/27cb27b6d5ea401143ca3648983342bb820c4be9) — Keith Busch, 2025-02-27 (6.15)
- [github.com/torvalds/linux - ublk: zc register/unregister bvec](https://github.com/torvalds/linux/commit/1f6540e2aabb7372e68223a3669019589c3e30ad) — Keith Busch, 2025-02-27 (6.15)
- [GitHub - ublk-org/ublksrv: ublk: userspace block device driver](https://github.com/ublk-org/ublksrv) — C 레퍼런스 서버
- [GitHub - ublk-org/libublk-rs: Rust libublk](https://github.com/ublk-org/libublk-rs) — Rust 라이브러리
- [GitHub - ublk-org/rublk: Rust block device in userspace](https://github.com/ublk-org/rublk) — Rust 타깃 모음
- [spdk.io - ublk Target](https://spdk.io/doc/ublk.html) — SPDK ublk target 문서
- [spdk.io - ublk: the new and improved way to serve SPDK storage locally!](https://spdk.io/news/2023/03/28/ublk/) — Jim Harris, SPDK 블로그, 2023-03-28
- [github.com/spdk/spdk - lib/ublk/ublk.c](https://github.com/spdk/spdk/blob/master/lib/ublk/ublk.c) — SPDK ublk target 구현
