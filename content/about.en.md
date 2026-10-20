+++
title = 'About'
date = 2026-09-06T00:00:00Z
translationKey = 'about'
ShowToc = false
ShowPostNavLinks = false
disableShare = true
hideMeta = true
+++

I'm Han Im, a distributed storage engineer who measures down to the node I/O stack.

## What I work on

- **Distributed storage — Ceph RGW → RADOS.** Owning features upstream, not just fixing bugs.
- **Node I/O stack — io_uring, blk-mq, NVMe, network stack.** Instrumented with eBPF; I dig only into the layer that is actually in the way.
- **Kernel, only when the measurement hits a kernel limit** — liburing, io_uring, libceph/rbd.

## How the measurements work

Each [measurement](/measurements/) has a question, a prediction written before measuring, the result, the raw data, and a way to rerun it. The environment is described on [Lab](/lab/). Upstream work is tracked on [Upstream](/upstream/).

## Production

I run 8PB of Ceph across 5 clusters (RBD, RGW, CephFS) plus IBM Storage Scale and VAST, on a GPU/AI cloud with QEMU/KVM and a RoCEv2 fabric.

## Elsewhere

Organizing team at **Ubuntu Korea Community**. [GitHub](https://github.com/Lim-Han) · [LinkedIn](https://www.linkedin.com/in/han-im-cloud/)
