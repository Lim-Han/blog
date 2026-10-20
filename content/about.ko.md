+++
title = '소개'
date = 2026-09-06T00:00:00Z
translationKey = 'about'
ShowToc = false
ShowPostNavLinks = false
disableShare = true
hideMeta = true
+++

노드 I/O 스택까지 계측하는 분산 스토리지 엔지니어 임한입니다. 글은 대부분 영어로 씁니다.

## 하는 일

- **분산 스토리지: Ceph RGW → RADOS.** 버그 수정이 아니라 기능을 맡아 upstream에 넣습니다.
- **노드 I/O 스택: io_uring, blk-mq, NVMe, 네트워크 스택.** eBPF로 계측하고, 실제로 막히는 층만 팝니다.
- **커널은 계측이 커널 한계에 닿을 때만.** liburing, io_uring, libceph/rbd.

## 측정 글의 형식

[측정 글](/measurements/)은 질문, 측정 전에 적은 예측, 결과, 원본 데이터, 재현 방법으로 구성됩니다. 환경은 [Lab](/lab/)에, upstream 작업은 [Upstream](/upstream/)에 정리합니다.

## 프로덕션

GPU/AI 클라우드에서 Ceph 8PB(클러스터 5개, RBD·RGW·CephFS)와 IBM Storage Scale, VAST를 운영합니다. QEMU/KVM과 RoCEv2 패브릭도 함께 다룹니다.

## 커뮤니티

**Ubuntu Korea Community** 운영진. [GitHub](https://github.com/Lim-Han) · [LinkedIn](https://www.linkedin.com/in/han-im-cloud/)
