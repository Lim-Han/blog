---
title: "{{ replace (path.Base .File.Dir) "-" " " | title }}"
date: {{ .Date }}
draft: true
layers: []        # rgw, rados, bluestore, io_uring, blk-mq, nvme, network, ebpf
question: ""      # 한 줄 질문
prediction: ""    # 측정 전 예측
result: ""        # 한 줄 결론
env:
  cpu: ""
  memory: ""
  nvme_model: ""
  kernel: ""
  ceph_version: ""
  ceph_sha: ""
  fio_version: ""
  liburing_version: ""
repro: ""         # 재현 repo/commit 링크
---

## Question

<!-- front matter의 question을 풀어 쓴다. 왜 이 질문인가. -->

## Prediction

<!-- 측정 전에 쓴다. 숫자와 근거. 쓴 뒤에는 고치지 않는다. -->

## Setup

Lab environment: see [Lab](/lab/).

{{`{{< env >}}`}}

## Method

<!-- fio jobfile, bpftrace/bcc 스크립트는 이 폴더에 두고 이름으로 참조한다. -->

## Results

## Prediction vs Result

{{`{{< predict-vs-result >}}`}}
- metric: ""
  predicted: 0
  measured: 0
  unit: ""
{{`{{< /predict-vs-result >}}`}}

## Analysis

## Limitations

## Reproduce

Repro: <!-- front matter repro -->

{{`{{< rawdata >}}`}}
