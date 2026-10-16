+++
title = '소개'
date = 2026-09-06T00:00:00Z
translationKey = 'about'
ShowToc = false
ShowPostNavLinks = false
disableShare = true
hideMeta = true
+++

안녕하세요, 클라우드 인프라팀에서 Storage Engineer로 일하고 있는 임한입니다. GPU·AI 클라우드 워크로드를 서빙하는 **1PiB+ 규모 프로덕션 Ceph 클러스터 5개**(RBD, RGW, CephFS)를 운영하며, QEMU/KVM 가상화를 RoCEv2 패브릭 위에서 구성하고 있습니다.

이 블로그는 엔지니어링 노트입니다. 프로덕션에서 마주친 문제를 표면적인 해결이 아니라 그 밑바닥의 커널·스토리지 내부 구조까지 파고들어 기록합니다.

## 다루는 주제

- **Ceph 내부 구조 & 운영** — CRUSH, BlueStore, PG/upmap 밸런싱, mClock 스케줄링, cephadm
- **Linux I/O 스택** — O_DIRECT, 페이지 캐시, io_uring, blk-mq
- **NVMe & 스토리지 하드웨어**
- **RDMA / RoCEv2 네트워킹**
- **GPU 데이터 경로** — GPUDirect Storage, NIXL, AI 인퍼런스 데이터 이동

## 커뮤니티

**Ubuntu Korea Community** 운영진으로도 활동하고 있습니다.

[GitHub](https://github.com/Lim-Han)와 [LinkedIn](https://www.linkedin.com/in/han-im-cloud/)에서도 찾으실 수 있습니다.
