# Ceph RGW 프론트엔드 비동기 진화: FastCGI·Civetweb에서 Beast 코루틴, optional_yield, SAL Driver까지

> 기준: `github.com/ceph/ceph` `main` 브랜치(2026-10 확인)와 릴리스 태그 v12.2.0(Luminous), v13.2.0(Mimic), v14.2.0(Nautilus), v15.2.0(Octopus), v16.2.0(Pacific), v17.2.0(Quincy), v18.2.0(Reef), v19.2.x(Squid), v20.2.0(Tentacle). 함수·옵션 이름은 해당 태그의 소스에서 직접 grep으로 확인했다. 확인하지 못한 항목은 `[추측/미확인]`으로 표시한다.

## 1. Verdict

RGW(RADOS Gateway)의 HTTP 처리 모델은 "요청 하나가 OS 스레드 하나를 끝까지 점유하는" 동기 모델에서 "Boost.Asio 스택풀 코루틴이 I/O 대기 지점마다 양보하는" 모델로 옮겨 왔다. 이 이동은 한 번의 재작성이 아니라 세 갈래의 점진적 작업이 겹친 결과다.

1. **프론트엔드 교체.** Beast 프론트엔드(`rgw_asio_frontend.cc`, Boost.Beast + Boost.Asio)는 Luminous(v12)에서 `rgw-beast-frontend` experimental feature 플래그 뒤에 들어왔고, Nautilus(v14.2.0)에서 `rgw_frontends`의 기본값이 `civetweb port=7480`에서 `beast port=7480`으로 바뀌었다. Mimic(v13.2.0)까지는 기본값이 여전히 civetweb이었다. Civetweb과 FastCGI 프론트엔드 소스(`rgw_civetweb_frontend.cc`, `rgw_fcgi_process.cc`)는 Quincy(v17.2.0) 태그에서 사라졌다.
2. **백엔드 호출의 비동기화.** 프론트엔드만 비동기여서는 효과가 없다. RGW는 `optional_yield`라는 얇은 래퍼를 함수 시그니처에 하나씩 추가해 가면서, yield context가 있으면 `librados::async_operate()`로 코루틴을 양보시키고 없으면(`null_yield`) 기존 동기 `IoCtx::operate()`로 떨어지는 방식을 택했다. 이 "스레딩(threading through)" 작업은 2023~2025년에도 PR 단위로 계속되고 있다(예: #49769, #52036, #53684, #63926).
3. **코루틴 구현체의 왕복.** Nautilus의 `optional_yield`는 `boost::asio::yield_context`를 감쌌다. 2020년 PR #31580("rgw: beast frontend uses 512k mprotected coroutine stacks")에서 스택 할당자를 커스터마이즈하기 위해 Ceph가 포크한 `spawn::spawn()` / `spawn::yield_context`로 갈아탔고, Octopus(v15)부터 Squid v19.2.0까지 이 포크가 쓰였다. Boost 1.80이 `boost::asio::spawn()`에 StackAllocator 오버로드를 추가하자 PR #55592("rgw: switch back to boost::asio for spawn() and yield_context", 2024-05 머지)로 다시 `boost::asio::yield_context`로 돌아왔고, Squid에는 #60133으로 백포트되어 v19.2.1부터 반영되었다. Tentacle(v20.2.0)과 `main`은 `boost::asio::yield_context`를 쓴다.

스토리지 추상화 계층(SAL, 프로젝트명 Zipper)은 별도 축이다. Octopus(v15.2.0)의 `rgw_sal.h`에 이미 `rgw::sal::RGWStore` / `RGWRadosStore`가 있었고(Pacific v16.2.0도 `RGWStore`), Quincy(v17.2.0)에서 `rgw::sal::Store`로 이름이 정리되었으며, PR #49336("Store -> Driver rename + header cleanup", 2022-12 머지)으로 Reef(v18)에서 `rgw::sal::Driver`로 개명되었다. 현재 `main`의 팩토리(`rgw_sal.cc`)는 `rados`, `dbstore`(SQLite 기반), `posix`, `daos` 드라이버와 `base`/`d4n` 필터를 등록한다. Motr(Seagate CORTX) 드라이버는 PR #71991(2026-10 머지)로 `main`에서 제거되었다.

결론적으로 Beast 전환의 실익은 "느린 클라이언트와 느린 OSD 응답이 스레드를 묶지 않는다"는 데 있지, 막연한 "수십만 연결" 같은 수치에 있지 않다. 그 실익도 호출 경로 전체가 `optional_yield`를 전달할 때만 온전히 얻어진다. 경로 중간에서 `null_yield`로 떨어지면 해당 asio 스레드가 블로킹되며, RGW는 이를 `maybe_warn_about_blocking()` 경고와 개발용 옵션 `rgw_asio_assert_yielding`으로 잡아낸다.

## 2. Problem Statement

### 2.1 동기 프론트엔드의 구조적 문제

RGW는 S3/Swift REST 요청을 RADOS 객체 연산으로 바꾸는 게이트웨이다. PUT 하나에도 사용자·버킷 메타데이터 조회, 버킷 인덱스 준비(`cls_rgw` 호출), head/tail 객체 쓰기, 인덱스 완료 등 여러 번의 OSD 왕복이 필요하다. 각 왕복은 네트워크 지연과 OSD 큐 지연을 포함하므로 밀리초 단위가 흔하다.

FastCGI 시절에는 Apache/nginx 같은 외부 웹 서버가 연결을 받고 RGW는 FastCGI 소켓 뒤에서 요청을 처리했다. 배포가 복잡하고 프로세스 간 데이터 복사가 추가되었다. Firefly(v0.80) 태그에는 `src/rgw/rgw_civetweb.cc`가 존재하며, 이후 임베디드 Civetweb이 기본 프론트엔드가 되었다(Mimic까지 `rgw_frontends` 기본값 `civetweb port=7480`).

Civetweb 프론트엔드는 연결/요청을 고정 크기 스레드 풀의 워커에 묶는 동기 모델이다. 요청 처리 중 RGW 코드가 동기 librados 호출로 OSD 응답을 기다리면 그 스레드는 커널에서 잠든다. 따라서 동시에 처리 가능한 요청 수가 곧 스레드 수였다. 이것이 `rgw_thread_pool_size` 옵션의 원래 의미이고, 2018-06 커밋 "rgw: change default rgw_thread_pool_size to 512"로 기본값이 512가 된 이유다.

### 2.2 문제의 실제 형태

- **느린 클라이언트(slow client)**: 대용량 업로드를 천천히 보내는 클라이언트가 워커 하나를 오래 점유한다. 소켓 read가 블로킹이므로 스레드 수를 넘는 동시 업로드는 대기열에 쌓인다.
- **느린 OSD**: 복구·스크럽·딥스크럽 중이거나 특정 PG가 느릴 때, 그 PG를 건드리는 요청들이 스레드를 묶는다. 한 버킷의 인덱스 샤드가 느리면 그 버킷과 무관한 요청까지 스레드 부족으로 지연된다.
- **스레드 비용**: 수백 개의 pthread는 각자 스택과 스케줄링 비용을 갖는다. 정확한 메모리 사용량은 스택 크기 설정(`ulimit -s` 등)에 따라 다르므로 여기서는 수치를 제시하지 않는다.

### 2.3 "프론트엔드만 바꾸면 끝"이 아닌 이유

Beast 프론트엔드가 소켓 I/O를 비동기로 하더라도, 요청 핸들러 내부에서 `IoCtx::operate()`를 동기로 부르면 asio 워커 스레드가 블로킹된다. asio 스레드는 수가 적으므로(기본 `rgw_thread_pool_size`만큼), 이 블로킹은 Civetweb 시절보다 더 큰 피해를 줄 수 있다. 같은 스레드에 다중화된 다른 코루틴들까지 함께 멈추기 때문이다. 이 때문에 RGW는 핸들러의 모든 호출 경로에 `optional_yield`를 전달하는 장기 리팩터링을 해야 했다. 옵션 `rgw_beast_enable_async`(기본 `true`, level `dev`)의 설명도 이 사정을 드러낸다. 끄면 "the number of concurrent requests will be limited by the thread count"이 된다.

## 3. The Debate

RGW 동시성 모델을 둘러싼 논쟁은 메일링 리스트의 단일 스레드보다는 PR 설명과 리뷰에 흩어져 있다. 아래는 PR 본문과 소스로 확인한 쟁점만 정리한 것이다. Casey Bodley 등 RGW 개발자의 발언은 원문을 확인한 PR 본문만 인용한다.

### 3.1 콜백 리액터 vs 스택풀 코루틴

RGW 요청 핸들러(`RGWOp` 파생 클래스들)는 멀티파트, 버전 관리, 수명 주기, 객체 잠금, 서버 측 암호화가 얽힌 수만 줄의 절차형 코드다. 이를 콜백 체인이나 상태 기계로 재작성하는 비용은 감당하기 어렵다. 스택풀 코루틴은 함수 시그니처에 yield 토큰 하나를 추가하는 것만으로 기존 코드 구조를 유지하면서 양보 지점을 만들 수 있다. 그래서 RGW는 Seastar 같은 future 기반 프레임워크가 아니라 `boost::asio::spawn` 계열을 택했다.

대가는 두 가지다.

- **스택 크기와 오버플로.** 스택풀 코루틴은 고정 크기 스택을 미리 할당한다. RGW 코드 경로(특히 암호화·압축·Lua 스크립트)는 스택을 깊게 쓰므로 너무 작으면 오버플로가 난다. PR #31580은 `boost::context::protected_fixedsize_stack{512*1024}`, 즉 mmap/mprotect 가드 페이지가 있는 512 KiB 스택을 도입했다. 현재 `main`의 `make_stack_allocator()`도 같은 값을 쓴다. 따라서 코루틴 스택은 흔히 말하는 "수십 KB"가 아니라 512 KiB 가상 메모리이며, 물리 메모리는 실제로 닿은 페이지만큼만 쓰인다.
- **블로킹 호출의 전염성.** 코루틴 안에서 동기 호출이 하나라도 남으면 같은 스레드의 다른 코루틴이 모두 멈춘다. 이 때문에 `optional_yield`를 끝까지 전달하는 작업이 수년간 이어졌다.

### 3.2 Ceph 포크(`spawn`) vs 업스트림 `boost::asio::spawn`

PR #31580 당시 `boost::asio::spawn()`은 커스텀 StackAllocator를 받는 오버로드가 없었다. 그래서 Ceph는 `spawn` 서브모듈(`spawn::spawn()`, `spawn::yield_context`)을 만들었다. 이 결정은 이후 유지 비용으로 돌아왔다. Boost 업그레이드마다 포크를 맞춰야 했고, per-op cancellation 같은 업스트림 개선을 쓸 수 없었다. PR #55592 본문은 복귀 이유를 다음과 같이 적는다.

> "in boost 1.80, that same StackAllocator overload was added to `boost::asio::spawn()`, along with other improvements like per-op cancellation. now that boost has everything we need, switch back and drop the spawn submodule"
>
> — PR #55592 설명 (github.com/ceph/ceph/pull/55592, 2024-05-21 머지)

해설: 포크는 기능 공백을 메우는 임시 수단이었고, 업스트림이 같은 기능을 제공하자 즉시 걷어냈다. 같은 PR은 많은 비동기 함수를 `async_completion<>`에서 `async_initiate<>`로 바꿨다고 적는다. 이 변경은 C++20 코루틴 토큰 `boost::asio::use_awaitable`을 쓸 수 있게 하는 전제이기도 하다. `main`의 `librados_asio.h`도 `async_initiate` 기반이다.

### 3.3 스레드 풀 크기: 512에서 128로

Beast + 완전 비동기 경로에서는 동시 요청 수가 스레드 수와 분리된다. 동시성 상한은 `rgw_max_concurrent_requests`(기본 1024)와 dmclock 스케줄러(`rgw_scheduler_type`)가 맡는다. 그렇다면 512개의 asio 스레드는 과하다. 스레드가 많을수록 strand 경합과 컨텍스트 스위칭만 늘어난다. Tracker Bug #65656("Reduce default thread pool size")와 PR #57167("rgw: reduce default thread pool size", 2026-06-25 머지)로 `main`의 기본값은 128이 되었다. 릴리스 태그 v18.2.0, v19.2.0, v20.2.0의 `rgw.yaml.in`은 모두 512다. 따라서 128은 Tentacle 이후 개발 브랜치의 값이며, 다음 메이저 릴리스에 들어갈 것으로 보인다 `[추측/미확인: 릴리스 반영 버전]`.

반론도 있다. `optional_yield`가 전달되지 않는 경로가 남아 있다면, 스레드 수를 줄이는 것은 그 경로의 블로킹 영향을 키운다. 같은 시기에 `rgw_asio_assert_yielding` 같은 진단 옵션과 `null_yield` 제거 PR(예: #64624 "common/async: remove null_yield support for spawn_throttle")이 이어진 것은 이 위험을 줄이려는 작업으로 읽힌다.

### 3.4 Zipper/SAL: 추상화 비용 vs 다중 백엔드

SAL은 RGW 코어가 `librados::IoCtx`와 `cls_rgw` 호출을 직접 부르던 구조를 순수 가상 인터페이스(`rgw::sal::Driver`, `Bucket`, `Object`, `User` 등) 뒤로 숨겼다. PR #46879("RGW Zipper pure virtual base class", 2022-07-05 머지)가 기반 클래스를 순수 가상으로 만든 단계다. 쟁점은 다음과 같았다.

- **리팩터링 리스크**: RADOS 전용 최적화(버킷 인덱스 샤딩, multisite 로그)를 인터페이스로 일반화하기 어렵다. 실제로 `RadosStore` 고유 기능 다수는 `dynamic_cast`로 RADOS 드라이버를 꺼내 쓰는 형태로 남아 있다 `[추측/미확인: 잔존 범위]`.
- **얻는 것**: 테스트·개발용 `dbstore`(SQLite, `SQLiteDB` 클래스가 `sqlite3*` 핸들을 보유), 로컬 파일시스템 위의 `posix` 드라이버, D4N 캐시 필터처럼 RADOS가 없는 백엔드나 RADOS 앞단 필터를 같은 프로토콜 엔진 위에 얹을 수 있다.
- **백엔드 정리**: 외부 스토리지용 드라이버는 수명이 짧았다. Motr(Seagate CORTX) 드라이버는 PR #71991("rgw: Remove the Motr driver", 2026-10-06 머지)로 `main`에서 제거되었다. 같은 PR은 DAOS 드라이버를 제거하지 않고, 대신 cmake에 "The DAOS SAL has been unmaintained and does not compile against DAOS libraries." 경고를 추가했다. 즉 DAOS 드라이버는 소스에 남아 있으나 빌드가 깨진 상태로 표시되어 있다. 확인 시점의 `rgw_sal.cc`에도 `newDaosStore` 선언이 있다.

DBStore를 RocksDB나 NVMe 원시 블록 기반의 초저지연 드라이버로 보는 것은 오해다. DBStore는 SQLite 기반이며 성능용이 아니라 RADOS 없이 RGW를 돌리기 위한 개발·테스트 용도다.

## 4. Implementation Impact

### 4.1 스레드와 io_context 구성 (main 기준)

- `rgw::AppMain`은 `ceph::async::io_context_pool` 하나를 만들고, 그 스레드 수를 `rgw_thread_pool_size`로 정한다(`rgw_appmain.cc`의 `IOContextPoolHolder::get()`). 기본값은 Reef~Tentacle 릴리스에서 512, `main`에서 128이다.
- `RGWAsioFrontend`는 이 풀의 `io_context`를 받아 리스너마다 accept 루프 코루틴을 `boost::asio::spawn(context, ...)`으로 띄운다.
- 연결 하나가 accept되면 `boost::asio::spawn(make_strand(context), std::allocator_arg, make_stack_allocator(), ...)`으로 연결 전용 코루틴을 만든다. strand 위에서 돌기 때문에 한 연결의 핸들러는 동시에 두 스레드에서 실행되지 않는다. 스택은 512 KiB `protected_fixedsize_stack`이다.
- 같은 풀은 RADOS 드라이버(`newRadosStore(&io_context, cct)`)와 D4N 필터에도 전달된다. 즉 HTTP 코루틴과 librados 완료 핸들러가 같은 실행기 위에서 만난다.

### 4.2 요청 처리 콜패스 (main 기준, 단순화)

```
AsioFrontend::accept(Listener&, boost::asio::yield_context)
  └─ boost::asio::spawn(make_strand(context), allocator_arg, make_stack_allocator(), lambda)
       └─ handle_connection(context, env, stream, timeout, header_limit, ..., yield)
            ├─ http::async_read_header(stream, buffer, parser, yield[ec])   // 헤더 대기 중 양보
            ├─ optional_yield y = null_yield;
            │   if (cct->_conf->rgw_beast_enable_async) y = optional_yield{yield};
            ├─ process_request(env, &req, uri_prefix, &client, y, ...)      // RGWOp 실행
            │    └─ RGWOp::execute(y)
            │         └─ (SAL) driver->get_bucket(...), obj->get_obj_attrs(..., y) ...
            │              └─ rgw_rados_operate(dpp, ioctx, oid, std::move(op), y, ...)
            │                   ├─ if (y): librados::async_operate(ex, ioctx, oid, std::move(op),
            │                   │                                   flags, trace_info, yield[ec])
            │                   │          └─ IoCtx::aio_operate() + AioCompletion 콜백이
            │                   │             코루틴을 재개 (librados_asio.h)
            │                   └─ else: maybe_warn_about_blocking(dpp); ioctx.operate(...)  // 동기
            │    └─ 요청 바디는 `StreamIO`(`rgw::asio::ClientIO` 파생)의 `recv_body()`에서
            │         http::async_read_some(stream, buffer, parser, yield[ec])
            └─ 응답: StreamIO::write_data() → boost::asio::async_write(stream, buffer, yield)
```

librados와 코루틴의 실제 연결점은 `librados_asio.h`의 `librados::async_operate()`, `async_read()`, `async_write()`, `async_notify()` 템플릿이다. 이들은 `IoCtx::aio_operate()`를 호출하고, `AioCompletion` 콜백이 완료 핸들러를 실행기로 dispatch하도록 연결한다. 취소 핸들러가 `AioCompletion`을 참조하므로 완료 전 해제 순서도 이 헤더가 관리한다.

### 4.3 `optional_yield`의 정의와 의미

`src/common/async/yield_context.h`의 `optional_yield`는 `boost::asio::yield_context*` 하나를 담는 클래스다. `operator bool()`로 비어 있는지 검사하고, `get_yield_context()`로 꺼낸다. 비어 있는 상수는 `null_yield`다. 이 단순한 타입이 RGW 비동기화의 핵심 장치다.

- 함수 시그니처에 `optional_yield y`를 추가해도 기존 동기 호출자는 `null_yield`를 넘기면 된다. 그래서 전체 코드를 한 번에 바꾸지 않고 경로별로 바꿀 수 있었다.
- 반대로 "비동기화되었다"는 보장이 타입 시스템에 없다. 호출 체인 중간에서 누군가 `null_yield`를 넘기면 조용히 동기 호출이 된다. 이를 잡는 것이 `maybe_warn_about_blocking()`(asio 스레드에서 동기 호출 시 로그)과 `rgw_asio_assert_yielding`(개발용 assert)이다.
- 태그별 래핑 타입: Nautilus `boost::asio::yield_context` → Octopus~Squid v19.2.0 `spawn::yield_context` → Squid v19.2.1+, Tentacle, `main` `boost::asio::yield_context`.

### 4.4 프론트엔드 세대 비교

| 항목 | FastCGI (외부 웹 서버) | Civetweb (임베디드) | Beast (Boost.Asio 코루틴) |
|---|---|---|---|
| 도입/기본값 | 초기 RGW | Firefly(v0.80) 태그에 소스 존재, Mimic까지 기본값 | Luminous experimental, Nautilus(v14.2.0)부터 기본값 |
| 제거 | Quincy(v17.2.0) 태그에서 소스 없음 | Quincy(v17.2.0) 태그에서 소스 없음 | 현행 |
| 동시성 단위 | 웹 서버 프로세스/스레드 + RGW 스레드 | 워커 스레드(`rgw_thread_pool_size`) | 코루틴 (strand 단위), 상한은 `rgw_max_concurrent_requests` |
| 소켓 I/O | 외부 웹 서버 | 블로킹 | `http::async_read_header`/`async_read_some`, 양보 |
| librados 호출 | 동기 | 동기 | `optional_yield` 경로는 `librados::async_operate`, 나머지는 동기 |
| 느린 클라이언트 영향 | 웹 서버 슬롯 점유 | 워커 점유 | 코루틴 스택만 점유 (스레드는 반환) |
| 스택 비용 | 프로세스/스레드 스택 | 스레드 스택 | 코루틴당 512 KiB 가상 (mprotect 가드) |

### 4.5 기능 도입 연표

| 릴리스/시점 | 변경 | 근거 |
|---|---|---|
| Firefly v0.80 | `src/rgw/rgw_civetweb.cc` 존재 | 태그 소스 |
| Luminous v12.2.0 | Beast는 `rgw-beast-frontend` experimental 플래그 필요, 기본 `civetweb port=7480` | `rgw_main.cc`, `options.cc` |
| 2018-06 | `rgw_thread_pool_size` 기본 512 | 커밋 "rgw: change default rgw_thread_pool_size to 512" |
| 2018-09 | Beast가 바디 I/O 중 양보, pause/stop 재작성 | PR #21271 |
| Nautilus v14.2.0 | 기본 `beast port=7480`, `optional_yield`(boost::asio) | `options.cc`, `yield_context.h` |
| 2020-01 (Octopus) | 512 KiB mprotect 스택, `spawn` 포크 | PR #31580 |
| Quincy v17.2.0 | Civetweb·FastCGI 소스 제거, `rgw::sal::Store` | 태그 소스 |
| 2022-07 | SAL 순수 가상 기반 클래스 | PR #46879 |
| Reef v18.2.0 | `Store` → `Driver` 개명 | PR #49336 |
| 2024-05 / v19.2.1 | `boost::asio::spawn`으로 복귀 | PR #55592, #60133 |
| 2026-06 (main) | `rgw_thread_pool_size` 기본 128 | PR #57167, Bug #65656 |

### 4.6 운영상 의미

- Beast 이후 `rgw_thread_pool_size`는 "동시 요청 수"가 아니라 "asio 실행 스레드 수"다. 값을 크게 올려도 동시성이 늘지 않고, 동기 경로가 남은 워크로드에서만 효과가 있다.
- 느린 요청 진단은 스레드 덤프보다 `maybe_warn_about_blocking` 로그와 op tracing이 유용하다.
- 일부 경로(특히 오래된 admin/multisite 코드)는 동기 호출을 남기고 있을 수 있으므로, 버전별 릴리스 노트에서 "optional_yield" 관련 변경을 확인해야 한다.

## 5. Primary References

- [rgw: beast frontend reworks pause/stop and yields during body io · Pull Request #21271 · ceph/ceph](https://github.com/ceph/ceph/pull/21271)
- [rgw: beast frontend uses 512k mprotected coroutine stacks · Pull Request #31580 · ceph/ceph](https://github.com/ceph/ceph/pull/31580)
- [rgw: switch back to boost::asio for spawn() and yield_context · Pull Request #55592 · ceph/ceph](https://github.com/ceph/ceph/pull/55592)
- [RGW Zipper pure virtual base class · Pull Request #46879 · ceph/ceph](https://github.com/ceph/ceph/pull/46879)
- [Store -> Driver rename + header cleanup · Pull Request #49336 · ceph/ceph](https://github.com/ceph/ceph/pull/49336)
- [rgw: reduce default thread pool size · Pull Request #57167 · ceph/ceph](https://github.com/ceph/ceph/pull/57167)
- [Bug #65656: Reduce default thread pool size - rgw - Ceph Tracker](https://tracker.ceph.com/issues/65656)
- [ceph/src/librados/librados_asio.h (main)](https://github.com/ceph/ceph/blob/main/src/librados/librados_asio.h) — `librados::async_operate`
- [ceph/src/common/async/yield_context.h (main)](https://github.com/ceph/ceph/blob/main/src/common/async/yield_context.h) — `optional_yield`, `null_yield`
- [ceph/src/rgw/rgw_asio_frontend.cc (main)](https://github.com/ceph/ceph/blob/main/src/rgw/rgw_asio_frontend.cc) — `handle_connection`, `make_stack_allocator`
- [HTTP Frontends — Ceph Documentation](https://docs.ceph.com/en/latest/radosgw/frontends/)
