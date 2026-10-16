# v2 독립 교차 검수 종합 (2026-10-15)

대상: 37편 (도메인 문서 35편 + synthesis 2편). 각 도메인은 해당 문서를 작성하지 않은 별도 에이전트가 검수했다. 지침: `review/v2_crossreview_brief.md`. 도메인별 상세 판정표는 같은 디렉토리의 각 파일에 있다.

## 판정 합계

| 범위 | 검토 주장 | CONFIRMED | WRONG | IMPRECISE | UNVERIFIABLE |
|---|---|---|---|---|---|
| 01 io_uring | 96 | 90 | 2 | 2 | 2 |
| 05 eBPF tracing | 54 | 47 | 2 | 2 | 3 |
| 02 blk-mq | 75 | 68 | 1 | 3 | 3 |
| 03 NVMe passthrough | 81 | 71 | 1 | 4 | 5 |
| 04 network stack | 115 | 105 | 2 | 6 | 2 |
| 06 Ceph | 108 | 104 | 0 | 4 | 0 |
| 10 storage systems | 90 | 83 | 0 | 7 | 0 |
| 07 SPDK | 85 | 78 | 0 | 4 | 3 |
| 08 GPU direct storage | 91 | 77 | 1 | 6 | 7 |
| 09 NVMe ecosystem | 166 | 155 | 2 | 8 | 1 |
| synthesis | 95 | 83 | 2 | 6 | 4 |
| **합계** | **1,056** | **961 (91.0%)** | **13 (1.2%)** | **52 (4.9%)** | **30 (2.8%)** |

- WRONG과 IMPRECISE 65건은 모두 수정했다. UNVERIFIABLE은 `[추측/미확인]` 태그를 붙였거나, 검수 중 사실을 확인해 해소했다.
- v1 검수 당시 문제 문서의 오류율과 비교하면, 남은 오류는 주로 버전 경계(예: 6.0 vs 6.1), 개수 세기, 조건 누락 같은 미세한 수준이다.

## 인용 대조

| 항목 | 대조 수 | 불일치 |
|---|---|---|
| 인용 블록 (`> "..."`) | 86 | 1 (BaM 초록 문구 변형 → 원문 복원) |
| 인라인 인용 (일부 도메인) | 약 125 | 3 (DAOS SAL 경고문, ZenFS 삽입어, Hellwig 발언 두 구절 혼합 → 모두 원문 복원) |

## 대표 수정 사례
- `IORING_OP_SENDMSG_ZC`: Linux 6.1 (6.0은 `SEND_ZC`)
- io_uring opcode 수: 65 (66 아님)
- `prio_aging_expire`: Linux 5.16
- `ep->lock` 변경 이력: 6.16-rc5 병합 → revert → 6.18 재병합
- NewStore/BlueStore 소스 등장: v10.0.0–v10.0.2 / v10.0.3
- `io_buffer_register_bvec()` 사용 구간: 6.15–7.2 (7.3-rc1부터 `io_buffer_register_request()`)
- Haas & Leis(PVLDB 2023) 12.5M IOPS: 이론치가 아니라 SPDK로 **실측**한 값 (사양 기대치 12M). 09 도메인 검수자의 오판을 synthesis 검수자가 반박했고, 총괄이 논문 PDF로 직접 확인해 확정했다.

## 공개용 정리
- 본문의 v1 메타 서술은 모두 제거하고 `review/changelog/<도메인>.md`로 옮겼다. 본문에 남은 "v1"은 기술 용어뿐이다(`[PATCHSET v1]`, cgroup v1, msgr v1 주소, VFIO migration v1).
- 상호 참조는 `(→ NN/MM)` 형식으로 통일했다. 참고문헌은 `- [실제 제목](URL) — 설명` 형식이다. 비표준 미확인 태그는 `[추측/미확인]` 하나로 통일했다 (총 112곳).
- 37편 모두 `verify_gate`를 통과했다 (파일 단위와 디렉토리 단위).

## 알려진 한계
- lore.kernel.org(Anubis)와 dl.acm.org(403)는 자동 확인이 불가하다. 각각 아카이브 사본(LWN, infradead, lkml.iu.edu, 커밋 Link 태그)과 Crossref/저자 PDF로 대조했다.
- LWN `/ml/` 메일 아카이브가 사람 확인 페이지를 추가해 링크 검사에서 401이 난다. 내용은 다른 경로로 확인했다.
- 일부 inline 버전 표기("5.1", "v5.1")는 `Linux 6.16` 형식으로 기계적으로 바꾸지 않았다. 의미 오류는 없다.
- ACM 논문 일부는 URL 없이 DOI만 적었다 (봇 차단 때문).

---

# v3 커버리지 확장 검수 추가 (2026-10-16)

신규 9편(도메인 11·12·13 8편 + 10/04 Lustre)을 같은 방식으로 독립 검수했다.

| 범위 | 검토 주장 | CONFIRMED | WRONG | IMPRECISE | UNVERIFIABLE |
|---|---|---|---|---|---|
| 11 filesystems·page cache | 87 | 83 | 1 | 2 | 1 |
| 12 platform I/O tuning | 58 | 53 | 0 | 5 | 0 |
| 13 block stack·fabrics·memory | 90 | 81 | 1 | 8 | 0 |
| 10/04 Lustre | 30 | 26 | 0 | 4 | 0 |
| **신규 소계** | **265** | **243** | **2** | **19** | **1** |
| **전체 누계 (v2 + v3)** | **1,321** | **1,204 (91.1%)** | **15 (1.1%)** | **71 (5.4%)** | **31 (2.3%)** |

- 신규 인용 블록 35개 대조, 불일치 0. 전체 누계 121개 중 불일치 1(v2 BaM, 복원 완료).
- 신규 WRONG 2건: ext4 large folio 성능 수치의 표 열 혼동(11/02), dm-mpath·dm-crypt atomic write 지원 버전 6.14→6.19(13/01).
- synthesis 00/01은 신규 도메인을 반영해 갱신했다(01: 지도·연결표·결정 매트릭스·연표·미해결 문제 확장, 00: BlueStore와 페이지 캐시 관계, IOMMU·IRQ 비용, Ceph `async+rdma` 상태).
- 현재 문서 46편(도메인 44 + synthesis 2), 약 99만 자, `[추측/미확인]` 146곳. 전 디렉토리 `verify_gate` 통과.
