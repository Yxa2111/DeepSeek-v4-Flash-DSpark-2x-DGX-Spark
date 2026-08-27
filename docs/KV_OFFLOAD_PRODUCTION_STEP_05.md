# KV offload production Step 05 - local NVMe deployment

Date: 2026-08-27

State: implementation and first live gates complete; production acceptance is
blocked by the head-node loss recorded below. `KV_OFFLOAD_MODE=off` remains the
default.

## Deployment decision

`KV_OFFLOAD_MODE=nvme-local` is now the main parked-session candidate. It uses
the Anemll fork's disk backend for `SimpleCPUOffloadConnector`, with one
process-lifetime slot file on each TP node:

```text
rank 0 packed KV <-> bounded buffers <-> head local NVMe
rank 1 packed KV <-> bounded buffers <-> worker local NVMe
```

This removes the whole-prefix UMA primary tier and cross-node KV relay from the
hot swapping path. `fs-rank0` remains available only for restart-persistent
prefix-cache experiments. The local mode is not restart-persistent: a service
restart invalidates its in-memory block map and checksums and recreates the
slot files.

MiaAI commit `74d246b` adds the opt-in mode and its validated Compose contract.
It emits:

```json
{
  "kv_connector": "SimpleCPUOffloadConnector",
  "kv_role": "kv_both",
  "kv_connector_extra_config": {
    "kv_offload_backend": "disk",
    "disk_path": "/kv-offload/vllm-kv.slots",
    "disk_capacity_bytes": 68719476736,
    "disk_buffer_slots": 2,
    "use_page_cache": false,
    "preallocate_disk": true,
    "lazy_offload": false
  }
}
```

The root paths remain node-local through `KV_OFFLOAD_ROOT` and
`WORKER_KV_OFFLOAD_ROOT`. The runtime appends global rank suffixes, preventing
rank 0 and rank 1 from sharing or overwriting one slot file.

## Switches and bounds

| Variable | Default | Accepted range / meaning |
|---|---:|---|
| `KV_OFFLOAD_MODE` | `off` | `nvme-local` enables this path |
| `KV_OFFLOAD_DISK_BYTES` | 64 GiB/rank | 1-160 GiB, preallocated on each node |
| `KV_OFFLOAD_DISK_BUFFER_SLOTS` | 2 | 1-8 rows per transfer direction |
| `KV_OFFLOAD_DISK_QUEUE_DEPTH` | 2 | 1-64 pending events per direction |
| `KV_OFFLOAD_DISK_ENQUEUE_TIMEOUT_SECONDS` | 30 | 1-300 s before fail-closed |
| `KV_OFFLOAD_DISK_MAX_STORE_BLOCKS` | 64 | 1-4096 packed rows per store event |
| `KV_OFFLOAD_USE_PAGE_CACHE` | `0` | keep `0` on Spark UMA |
| `KV_OFFLOAD_PREALLOCATE_DISK` | `1` | fail startup on ENOSPC |

The lab generator can override these values without modifying or printing the
source `.env.dspark`. The live Step 05 profile used a separate Compose project,
32 GiB/rank, max context 262,144, two sequences, DSpark on, no VL sidecar, and
`restart: no`.

## Verification

Local configuration gates after the mode was added:

```text
test-kv-offload-config.sh:          17 passed, 0 failed
test-create-kv-offload-lab-env.sh:  passed
bash syntax checks:                 passed
git diff --check:                   passed
```

The final runtime source hash matched on both nodes:

```text
6d31666651d84d26019f8f72b5f8d3679ec762a2b0d914b82c31251fdd234773
```

Both ranks reported the expected files and geometry:

- head: `/home/yxa/kv-offload-lab/kv-cache/head-local/vllm-kv.slots.rank_0`;
- worker: `/home/yxa/kv-offload-lab/kv-cache/worker-local/vllm-kv.slots.rank_1`;
- each file: mode `0600`, root owned, 34,359,459,840 bytes allocated;
- each rank: 32,140 slots, 1,065,792-byte payload, 1,069,056-byte disk slot;
- two buffer rows per direction, page cache off.

## Live results

| Case | Result |
|---|---|
| 8K cold | 4.541 s TTFT, all 8,192 prompt tokens computed |
| 8K immediate repeat | 0.363 s TTFT, 7,936 GPU-cached tokens; not an NVMe proof |
| 16K cold/store | 9.821 s TTFT; 186,015,744 bytes written per observed rank |
| 10 clients, cancel 9 | one old request survived; 16.321 s total; running/waiting returned to zero |

The 16K store gives an observed 11,353.5 bytes, or 11.087 KiB, per prompt token
per rank. Capacity planning therefore uses:

| Preallocation per node | Approximate token slots | Practical 1M-session target |
|---:|---:|---:|
| 32 GiB | 3.03M | two plus reserve |
| 64 GiB | 6.05M | five plus reserve |
| 128 GiB | 12.1M | ten plus reserve, after disk-space gate |

This corrects the earlier rough statement that 64 GiB could hold about ten 1M
sessions. The live layout does not support that claim.

The successful cancellation run emitted no I/O, checksum, CUDA, traceback, or
deadlock error on either rank. Its survivor completed after nine peer clients
were disconnected, which directly covers the original “stop high concurrency,
then let one old request continue” failure shape at 8K.

## Production blocker

The follow-up GPU-eviction run completed three distinct 250K cold prompts with
TTFT 155.746 s, 158.653 s, and 153.452 s. During the fourth 250K prompt, the
head (`192.168.2.168`, RoCE `192.168.3.1`) disappeared from both networks. SSH,
ICMP, and worker-to-head RoCE checks all failed. The worker was still consuming
about 102.6 GiB for its TP process and was stopped explicitly, returning its
available memory to about 117 GiB.

This proves a whole-node availability failure occurred under the stress case;
it does not yet prove whether the cause was OOM, GPU/NVRM, thermal, watchdog,
PCIe, power, filesystem, or the new backend. The head did not respond to
Wake-on-LAN. Raw request JSON files remain on the currently unreachable head
under `/home/yxa/kv-offload-lab/miaai/results/step05-local-nvme-*.json` and must
be copied into this repo after recovery.

No service is declared restored. Before any restart, collect previous-boot
kernel and service logs, inspect the old container state, and archive the seed
604 failure evidence. The disk-restore proof and long soak remain incomplete.

## Decision

Keep the feature opt-in and the production deployment off. The runtime path is
substantially more capacity-efficient than the generic filesystem tier and the
small concurrency/cancellation case works, but a feature is not
production-ready while its bounded eviction test can coincide with loss of an
entire node.

No Azusa Core typed admission control is part of this change. Existing vLLM
limits are sufficient for the next controlled runtime tests; an application
queue will only be reconsidered if postmortem and soak data show a requirement
that the runtime cannot express.
