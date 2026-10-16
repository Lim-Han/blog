# RADOS 메신저의 진화와 msgr2 프로토콜: AsyncMessenger, msgr2.1 프레임, Crimson 멀티샤드 연결

> 기준: `github.com/ceph/ceph` `main`(2026-10 확인)과 릴리스 태그 v11.2.0(Kraken), v12.2.0(Luminous), v14.2.0/v14.2.11(Nautilus), v15.2.0/v15.2.5(Octopus), v16.2.0(Pacific), v17.2.0(Quincy). 프로토콜 서술은 docs.ceph.com의 "msgr2 protocol (msgr2.0 and msgr2.1)" 개발 문서와 `src/msg/async/frames_v2.h`, `crypto_onwire.cc`를 대조했다. 확인하지 못한 항목은 `[추측/미확인]`으로 표시한다.

## 1. Verdict

RADOS 메신저는 세 번의 큰 변화를 거쳤다.

1. **스레딩 모델: SimpleMessenger → AsyncMessenger.** 연결마다 reader/writer 스레드를 두던 `SimpleMessenger`는 Kraken(v11.2.0)에서 `ms_type` 기본값이 `async`가 되며 기본 자리에서 물러났고(Luminous v12.2.0부터 `async+posix`), `src/msg/simple/SimpleMessenger.cc`는 Octopus(v15.2.0) 태그에서 사라졌다. `AsyncMessenger`는 소수의 워커 스레드(`ms_async_op_threads`, 기본 3)가 각자 `EventCenter`(Linux에서는 `EventEpoll`)를 돌리며 다수의 연결을 다중화한다.
2. **와이어 프로토콜: msgr1 → msgr2(Nautilus v14) → msgr2.1 프레임 리비전.** msgr2는 Nautilus에서 도입되었다. 모니터는 IANA 할당 포트 3300에서 v2를, 레거시 6789에서 v1을 받는다. 연결 모드는 `crc`와 `secure` 두 가지다. `secure`는 **AES-128-GCM** 하나만 쓴다(`crypto_onwire.cc`의 `AES128GCM_OnWireTxHandler`, 키 16바이트, IV 12바이트, 태그 16바이트). "AES-256-GCM"이나 "AES-CTR" 같은 다른 스위트는 소스에 없다. msgr2.1은 새 암호 스위트나 "하이브리드 모드"가 아니라 **프레임 포맷 리비전(rev1)**이다. msgr2.0이 첫 세그먼트의 CRC를 epilogue로 옮기면서 생긴 문제와 GCM nonce 재사용 위험을 고쳤다(PR #35078 "New msgr2 crc and secure modes (msgr2.1)", 2020-06 머지, Octopus·Nautilus 백포트 #35720/#35733). 태그 소스 기준으로 v14.2.11, v15.2.5에는 `is_rev1`이 있고 v14.2.0, v15.2.0에는 없다.
3. **온와이어 압축.** PR #36517("msgr: added support in on-wire compression for osd-osd communication", 2021-08 머지)로 msgr2 핸드셰이크에 `COMPRESSION_REQUEST`/`COMPRESSION_DONE` 태그가 추가되었다. v17.2.0(Quincy) 태그의 `frames_v2.h`에 처음 나타난다. 기본값은 `ms_osd_compress_mode=none`이고, 암호화와 압축이 둘 다 켜지면 압축이 무시된다(`ms_compress_secure=false`).

"피어 간 단일 연결" 불변식과 Crimson의 thread-per-core 모델 사이의 긴장은 실제로 존재한다. 그러나 "커뮤니티가 샤드당 독립 소켓으로 재설계하기로 했다"는 식의 서술은 근거가 없다. 실제 구현(PR #51916 "crimson/net: support connections in multiple shards", 2023-07 머지, Reef 백포트 #53949)은 연결 수를 늘리지 않는다. 핸드셰이크(`ProtocolV2`)는 메신저 전용 샤드에서 하고, 핸드셰이크 이후의 메시지 I/O(`IOHandler`)는 `seastar::connected_socket`이 위치한 샤드에서 수행한다. 연결은 여전히 피어당 하나이고, 작업 샤드만 분산된다.

또한 AsyncMessenger 송신 경로에 `SO_ZEROCOPY`/`MSG_ZEROCOPY`는 쓰이지 않는다. `main`의 `src/msg/async/*`에 해당 플래그가 없다. `PosixStack.cc`는 `::sendmsg(fd, &msg, MSG_NOSIGNAL | (more ? MSG_MORE : 0))`로 보낸다. `MSG_ZEROCOPY` 송신 경로는 PR #70638에서 **draft RFC**로 제안된 상태다(2026-07 생성, 기본 비활성).

## 2. Problem Statement

### 2.1 SimpleMessenger의 2N 스레드

`SimpleMessenger`는 연결(`Pipe`)마다 reader 스레드와 writer 스레드를 하나씩 띄웠다. OSD 하나는 동일 PG를 공유하는 피어 OSD, 클라이언트, 모니터와 동시에 연결되므로 큰 클러스터에서 스레드 수는 연결 수의 두 배로 늘어난다. 문제는 메모리보다 스케줄링이다. 대부분 잠든 수천 개 스레드가 이벤트마다 깨어나고 잠들며, 송신 큐 락과 디스패치 큐 락이 경합한다. 수치는 클러스터 규모와 커널 설정에 따라 달라 여기서는 제시하지 않는다.

### 2.2 msgr1 프로토콜의 한계

msgr1은 내부 신뢰망을 전제로 설계되었다.

- **기밀성 없음.** CephX 인증은 했지만 이후 트래픽은 평문이다. 선택적으로 메시지 서명(`cephx_sign_messages`)은 가능했으나 암호화는 없었다.
- **확장성 없는 핸드셰이크.** 기능 협상 구조가 고정되어 있어 새 인증 방식이나 암호 모드를 넣기 어렵다.
- **포트·주소 모델.** 모니터 포트 6789 하나와 단일 주소 표현. msgr2는 `entity_addrvec_t`(v2와 v1 주소를 함께 광고)로 이를 바꿨다.

### 2.3 msgr2.0 자체의 결함

msgr2.0도 완전하지 않았다. 개발 문서의 "Issues" 절은 두 가지를 지적한다. 첫째, 메시지 헤더(`ceph_msg_header2`)를 담은 첫 세그먼트의 CRC를 epilogue로 옮긴 탓에, 프레임 전체를 읽기 전에는 헤더를 신뢰할 수 없었다. 수신 측이 트랜잭션 ID로 사용자 버퍼를 찾아 페이로드를 바로 흩어 넣는(scatter) 최적화를 하려면 헤더가 먼저 검증되어야 한다. 둘째, abort 플래그(`late_flags`)가 어떤 CRC에도 포함되지 않아, 비트 하나가 뒤집히면 완료된 프레임이 버려지거나 abort된 프레임이 전달될 수 있었다. secure 모드에는 nonce 문제가 있었다. msgr2.0-secure의 nonce는 4바이트 카운터 + 8바이트 고정 필드로 구성되었고, 카운터가 짧아 하루 안에 한 바퀴 돌 수 있었다. 문서는 그 결과를 다음과 같이 적는다.

> "Because the counter field is only four bytes long, it can wrap and then repeat in under a day, leading to GCM nonce reuse and therefore a potential complete loss of both authenticity and confidentiality for the connection. This was addressed by disconnecting before the counter repeats (CVE-2020-1759)."
>
> — "msgr2 protocol (msgr2.0 and msgr2.1)", docs.ceph.com/en/latest/dev/msgr2/ (2026-10 확인)

해설: 이 결함은 암호 알고리즘이 아니라 nonce 구성의 문제다. msgr2.0에서는 카운터가 돌기 전에 연결을 끊는 방식으로 막았고, msgr2.1은 NIST 권고대로 4바이트 고정 필드 + 8바이트 카운터로 바꿨다. 소스의 `AES128GCM_OnWireTxHandler`에 있는 `new_nonce_format` 필드("64-bit counter?" 주석)가 이 두 형식을 구분한다.

### 2.4 단일 연결 불변식과 thread-per-core

RADOS는 두 엔티티 사이에 하나의 세션을 유지한다. 이 덕분에 메시지 순서 보장, lossless 연결의 재연결·재전송(`SESSION_RECONNECT`, 시퀀스 번호), 장애 감지가 단순해진다. 문제는 Seastar 기반 Crimson OSD처럼 각 코어가 자기 PG만 처리하는 구조에서 나타난다. 소켓 하나가 한 코어에 묶이면, 다른 코어의 PG로 가는 메시지는 코어 간 전달이 필요하다. Seastar의 `connected_socket`은 생성된 샤드에서 다른 샤드로 옮길 수 없다는 제약도 있다(PR #51916 설명).

## 3. The Debate

아래 논점은 공식 문서와 PR 본문으로 확인한 범위에서만 서술한다.

### 3.1 암호화 비용과 모드 선택

msgr2 설계의 기본 결정은 "모든 연결은 crc 모드로 시작하고, 인증 단계에서 협상으로 secure 모드를 고를 수 있다"는 것이다. 모드 선택은 옵션으로 연결 종류별로 나뉜다.

| 옵션 | 대상 | 기본값 (main) |
|---|---|---|
| `ms_cluster_mode` | 데몬 간 통신 | `crc secure` |
| `ms_service_mode` | 데몬이 클라이언트 연결을 받을 때 허용 모드 | `crc secure` |
| `ms_client_mode` | 클라이언트가 데몬에 연결할 때 | `crc secure` |
| `ms_mon_cluster_mode` | 모니터 간 | `secure crc` |
| `ms_osd_compress_mode` | OSD 간 압축 | `none` |
| `ms_osd_compression_algorithm` | 압축 알고리즘 | `snappy` |
| `ms_compress_secure` | secure 모드에서 압축 허용 | `false` |

목록 앞쪽이 선호 순위이므로, 기본 설정에서 OSD 데이터 경로는 crc 모드다. 모니터 간 통신만 secure를 우선한다. 공식 문서(Messenger v2)는 crc 모드가 CephX 상호 인증과 crc32c 무결성 검사를 제공하지만, 기밀성과 악의적 중간자 방어는 제공하지 않는다고 명시한다. 같은 문서는 secure 모드에 대해 "In Nautilus, secure mode uses the AES-GCM stream cipher, which is generally very fast on modern processors"라고 적는다. 즉 "암호화 비용이 너무 커서 하이브리드 모드를 만들었다"는 흔한 서사와 달리, 실제 설계는 처음부터 연결 종류별 모드 선택을 운영자에게 맡기는 쪽이었다. 데이터 경로까지 secure로 바꿀 때의 CPU 비용은 하드웨어(AES-NI 유무)와 메시지 크기에 따라 다르고, 이 문서는 공식 벤치마크를 확인하지 못했다 `[추측/미확인: secure 모드의 처리량 영향 수치]`.

### 3.2 msgr2.0 → msgr2.1: 프레임을 다시 바꾸는 비용

msgr2.0의 결함(2.3절)을 고치려면 와이어 포맷을 바꿔야 했다. 이미 Nautilus가 배포된 상태에서 포맷을 바꾸면 혼합 버전 클러스터의 호환성이 문제가 된다. 선택된 방법은 msgr2 기능 비트(`CEPH_MSGR2_FEATURE_REVISION_1`)로 rev1을 협상하는 것이다. `ProtocolV2.cc`는 `HAVE_MSGR2_FEATURE(peer_supported_features, REVISION_1)`로 `is_rev1`을 정하고, `frames_v2.h`의 `FrameAssembler`(Crimson은 `crimson/net/FrameAssemblerV2`)가 rev0과 rev1 포맷을 모두 처리한다. 기능 비트는 `src/include/msgr.h`의 `DEFINE_MSGR2_FEATURE(0, 1, REVISION_1)`, `DEFINE_MSGR2_FEATURE(1, 1, COMPRESSION)`이다. 문서도 "supported but not required"라고 적어 msgr2.0과 msgr2.1 피어가 공존할 수 있게 했다. 대가는 코드 복잡도다. epilogue 구조체만 `epilogue_crc_rev0_block_t`, `epilogue_crc_rev1_block_t`, `epilogue_secure_rev0_block_t`, `epilogue_secure_rev1_block_t` 네 가지가 남았다.

### 3.3 압축과 암호화의 충돌

압축을 암호화 앞에 두면 압축률이 평문 내용에 대한 정보를 흘린다(CRIME/BREACH 계열 공격과 같은 원리). msgr2 문서는 "Combining compression with encryption introduces security implications."라고 적고, 구성 문서는 둘 다 켜졌을 때 기본적으로 압축을 무시한다고 설명한다. 압축의 동기로 문서가 드는 예는 퍼블릭 클라우드에서 NVMe 대역폭에 비해 네트워크 대역폭이 작은 인스턴스다. 즉 압축은 보안 기능이 아니라 대역폭이 병목인 환경을 위한 선택 기능이다.

### 3.4 Crimson: 연결을 늘릴 것인가, 작업 샤드를 옮길 것인가

Crimson OSD는 Seastar 샤드마다 PG 집합을 맡는다. 피어당 한 연결을 유지하면서 다중 코어를 활용하는 방법으로 두 가지가 가능하다.

- **(A) 샤드별 연결**: 피어 쌍마다 코어 수만큼 연결을 만든다. 코어 간 전달은 없지만, 재연결·순서 보장·장애 감지 로직이 연결 집합 단위로 복잡해지고, 클래식 OSD 및 클라이언트와의 호환이 문제가 된다.
- **(B) 연결은 하나, I/O 샤드는 분산**: 핸드셰이크와 연결 등록은 한 샤드에서 원자적으로 처리하고, 각 연결의 메시지 I/O는 소켓이 위치한 샤드에서 처리한다.

PR #51916은 (B)를 택했고, 그 이유를 다음과 같이 적는다.

> "Generally, all handshakes in protocol v2 are done in a dedicated shard for a Crimson Messenger as before, hopefully this will make further integrations with Crimson OSD simpler, because the dependent logic (such as the authentication) in OSD is not sharded, and the internal connection registration as well as replacements can remain atomic."
>
> — PR #51916 설명 (github.com/ceph/ceph/pull/51916, 2023-07-02 머지)

해설: 인증 같은 OSD 쪽 로직이 샤딩되어 있지 않으므로 핸드셰이크까지 분산하면 결국 코어 간 동기화가 필요해진다. 그래서 연결 상태 기계는 한 곳에 두고, 핸드셰이크 이후 데이터 경로만 분산했다. 같은 PR 설명은 `connected_socket`이 생성 후 다른 샤드로 옮겨질 수 없어서, lossless 연결의 작업 샤드는 재연결·재수락 시점에만 바뀔 수 있다고 적는다. 메시지가 도착한 연결의 샤드와 대상 PG의 샤드가 다르면 여전히 코어 간 전달이 필요하다. 이 비용이 실제 워크로드에서 얼마인지는 PR의 TODO("Understand the performance impacts")로 남아 있었다.

### 3.5 MSG_ZEROCOPY: 아직 RFC

PR #70638("msg/async: MSG_ZEROCOPY send path + PSP secure-mode scaffolding (RFC)")은 2026-07 draft로 올라왔다. 본문은 대용량 송신(RGW GET, EC full-stripe read)에서 커널 소켓 복사가 DRAM 대역폭을 소모한다는 동기를 들고, 모든 변경이 "strictly default-off / no-op on the wire"라고 밝힌다. 또한 secure 모드에서는 `crypto_onwire`의 AEAD가 암호화 중 페이로드를 복사하므로 제로카피 이득이 없다고 지적하고, 커널 PSP(NIC 인라인 AEAD) 기반 모드를 위한 골격을 제안한다. 본문은 이 시리즈의 코드가 AI 보조로 작성되었다고 명시하며 신중한 리뷰를 요청한다. 머지되지 않은 제안이므로 Ceph의 현재 동작으로 서술해서는 안 된다.

## 4. Implementation Impact

### 4.1 AsyncMessenger 구조 (main 기준)

- `NetworkStack`(기본 `ms_type=async+posix` → `PosixNetworkStack`)이 `Worker` 객체들을 만든다. 워커 수는 `ms_async_op_threads`(기본 3)다.
- 각 `Worker`는 `EventCenter` 하나를 소유하고 루프에서 `EventCenter::process_events()`를 호출한다. `EventCenter`는 OS별 `EventDriver`(Linux는 `EventEpoll`, BSD 계열은 kqueue 구현)를 감싸며, `create_file_event()`로 소켓 fd의 읽기/쓰기 이벤트를 등록한다. 다른 스레드가 이 워커에 작업을 넘길 때는 `dispatch_event_external()`을 쓴다.
- 연결은 `AsyncConnection` 객체이고, 프로토콜 상태 기계는 `ProtocolV1` 또는 `ProtocolV2`가 맡는다. 한 연결은 생성 시 배정된 워커 하나에서만 I/O가 처리된다.
- 송신: 상위 계층이 `Connection::send_message()`를 부르면 `ProtocolV2::send_message()`가 메시지를 큐에 넣고, 워커 스레드의 `write_event()` → `write_message()`가 프레임을 조립해 `PosixConnectedSocketImpl`의 `::sendmsg(..., MSG_NOSIGNAL | MSG_MORE?)`로 보낸다. `MSG_ZEROCOPY`는 쓰지 않는다.
- 수신: `read_frame()` → `read_frame_segment()` → `handle_read_frame_segment()` → `handle_message()`. 디코딩된 메시지는 `ms_can_fast_dispatch()`가 참이면 `DispatchQueue::fast_dispatch()`로 워커 스레드에서 바로 상위 Dispatcher(예: OSD)에 넘어가고, 아니면 `DispatchQueue`에 enqueue되어 별도 디스패치 스레드가 처리한다. OSD의 클라이언트 op는 fast dispatch 경로로 들어와 `ShardedOpWQ`에 넣어진다.

### 4.2 msgr2 프레임 레이아웃

`frames_v2.h`의 `preamble_block_t`는 packed 구조로 정확히 32바이트다.

```
preamble_block_t (32 bytes, packed)
  __u8        tag;                 // Tag::HELLO ... Tag::MESSAGE ... Tag::COMPRESSION_DONE
  __u8        num_segments;        // 1..4
  segment_t   segments[4];         // 각 { __le32 length; __le16 alignment; } = 6 bytes
  __u8        flags;               // FRAME_EARLY_DATA_COMPRESSED 등
  __u8        _reserved;
  ceph_le32   crc;                 // preamble CRC32-C

MAX_NUM_SEGMENTS = 4
MESSAGE 프레임의 세그먼트 인덱스 (SegmentIndex::Msg):
  HEADER = 0  (ceph_msg_header2)
  FRONT  = 1
  MIDDLE = 2
  DATA   = 3  (페이지 정렬 가능: segment_t::PAGE_SIZE_ALIGNMENT = 4096)
```

세그먼트는 header/front/data 세 개가 아니라 header/front/middle/data 네 개다. 또한 "OSD 맵 에포크"는 preamble 필드가 아니다.

rev0과 rev1의 차이는 다음과 같다.

| 항목 | msgr2.0 (rev0) | msgr2.1 (rev1) |
|---|---|---|
| crc 모드 첫 세그먼트 CRC | epilogue에 위치 → 헤더를 프레임 끝까지 검증 불가 | 첫 세그먼트 바로 뒤에 위치 → 헤더 먼저 검증 |
| crc 모드 epilogue | `late_flags` + CRC 4개 (`epilogue_crc_rev0_block_t`) | 세그먼트가 2개 이상일 때만, `late_status` + CRC 3개 (`epilogue_crc_rev1_block_t`) |
| abort 표시 | `late_flags`, CRC 보호 없음 | `late_status` (`FRAME_LATE_STATUS_*`, 예약 비트로 비트 오류 검출) |
| secure 모드 암호화 단위 | 프레임 전체를 하나로 | preamble(+48바이트 inline 버퍼), 첫 세그먼트 나머지, 그 외를 각각 별도 nonce·태그로 |
| GCM nonce | 4바이트 카운터 + 8바이트 고정 (CVE-2020-1759, 카운터 반복 전 끊기로 완화) | 4바이트 고정 + 8바이트 카운터 (NIST 권고 형식) |
| 협상 | 기본 | `CEPH_MSGR2_FEATURE_REVISION_1`, 필수 아님 |

`FRAME_PREAMBLE_INLINE_SIZE = 48`은 secure rev1에서 `ceph_msg_header2`가 inline 버퍼 안에 들어가도록 `static_assert`로 강제된다. 덕분에 작은 제어 프레임이나 메시지 헤더는 한 번의 복호화로 읽을 수 있다. 수신 측이 헤더를 먼저 검증할 수 있게 되면서, 트랜잭션 ID로 미리 등록된 수신 버퍼에 데이터를 바로 흩어 넣는 경로가 다시 안전해졌다. 이는 사용자 공간 버퍼로의 scatter이지 NIC DMA 제로카피가 아니므로, "Zero-copy DMA 수신"이라는 표현은 과장이다.

### 4.3 세대별 비교

| 항목 | SimpleMessenger (msgr1) | AsyncMessenger + msgr1 | AsyncMessenger + msgr2 | crimson::net (ProtocolV2) |
|---|---|---|---|---|
| 동시성 | 연결당 reader/writer 스레드 | `ms_async_op_threads`개 워커 + epoll | 동일 | Seastar 샤드, 핸드셰이크는 메신저 샤드, I/O는 소켓 샤드 |
| 기본값 시기 | Kraken 이전 | Kraken(v11.2.0) `ms_type=async` | Nautilus(v14) v2 바인딩 | Crimson OSD 전용 |
| 소스 제거 | Octopus(v15.2.0) 태그에서 없음 | 현행 (v1은 `ms_bind_msgr1=true` 기본) | 현행 | 현행 |
| 암호화 | 없음 (메시지 서명만 선택) | 없음 | secure 모드 AES-128-GCM | ProtocolV2 secure 모드 (클래식과 같은 프로토콜) |
| 압축 | 없음 | 없음 | Quincy(v17)부터 협상 가능, 기본 `none` | `[추측/미확인: crimson 압축 지원 여부]` |
| 송신 시스템 콜 | 블로킹 `sendmsg` | 논블로킹 `sendmsg` (+`MSG_MORE`) | 동일 | Seastar 네이티브/POSIX 스택 |
| MSG_ZEROCOPY | 없음 | 없음 | 없음 (PR #70638 RFC draft) | 없음 |

### 4.4 기능 도입 연표

| 시점 | 변경 | 근거 |
|---|---|---|
| Kraken v11.2.0 | `ms_type` 기본 `async` | `config_opts.h` |
| Luminous v12.2.0 | 기본 `async+posix` | `options.cc` |
| Nautilus v14.2.0 | msgr2 도입, 모니터 3300 포트, crc/secure 모드 | 릴리스 공지, Messenger v2 문서 |
| Octopus v15.2.0 | SimpleMessenger 소스 제거 | 태그 소스 |
| 2020-06 / v15.2.5, v14.2.11 | msgr2.1 (rev1) | PR #35078, #35720, #35733 |
| 2021-08 / Quincy v17 | OSD 간 온와이어 압축 | PR #36517 |
| 2023-07 / Reef 백포트 | crimson/net 멀티샤드 연결 | PR #51916, #53949 |
| 2026-07 | MSG_ZEROCOPY + PSP 골격 RFC (미머지) | PR #70638 |

### 4.5 운영상 의미

- 기본 설정의 OSD 간 트래픽은 crc 모드다. 규정상 기밀성이 필요하면 `ms_cluster_mode`, `ms_service_mode`, `ms_client_mode`를 `secure`로 바꿔야 하며, CPU 비용을 사전에 측정해야 한다.
- 압축은 secure와 동시에 쓰이지 않는 것이 기본이다. 네트워크 병목이 확실한 환경에서만 `ms_osd_compress_mode=force`를 검토한다.
- 커널 클라이언트(`libceph`, krbd/CephFS)는 별도 구현이며, msgr2 구현(`net/ceph/messenger_v2.c`, Ilya Dryomov)은 Linux v5.11 태그에 처음 존재하고 v5.10 태그에는 없다(git.kernel.org 태그별 확인).

## 5. Primary References

- [msgr2 protocol (msgr2.0 and msgr2.1) — Ceph Documentation](https://docs.ceph.com/en/latest/dev/msgr2/)
- [Messenger v2 — Ceph Documentation](https://docs.ceph.com/en/latest/rados/configuration/msgr2/)
- [Ceph.io — v14.2.0 Nautilus released](https://ceph.io/en/news/blog/2019/v14-2-0-nautilus-released/)
- [New msgr2 crc and secure modes (msgr2.1) · Pull Request #35078 · ceph/ceph](https://github.com/ceph/ceph/pull/35078)
- [msgr: added support in on-wire compression for osd-osd communication · Pull Request #36517 · ceph/ceph](https://github.com/ceph/ceph/pull/36517)
- [crimson/net: support connections in multiple shards · Pull Request #51916 · ceph/ceph](https://github.com/ceph/ceph/pull/51916)
- [msg/async: MSG_ZEROCOPY send path + PSP secure-mode scaffolding (RFC) · Pull Request #70638 · ceph/ceph](https://github.com/ceph/ceph/pull/70638) — draft, 미머지
- [ceph/src/msg/async/frames_v2.h (main)](https://github.com/ceph/ceph/blob/main/src/msg/async/frames_v2.h) — `preamble_block_t`, `MAX_NUM_SEGMENTS`, epilogue 구조체
- [ceph/src/msg/async/crypto_onwire.cc (main)](https://github.com/ceph/ceph/blob/main/src/msg/async/crypto_onwire.cc) — `AES128GCM_OnWireTxHandler`
