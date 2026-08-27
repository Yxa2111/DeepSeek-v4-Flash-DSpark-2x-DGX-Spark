# KV offload production Step 07 - head-node unclean shutdown postmortem

Date: 2026-08-27

State: complete as an incident record. The Step 05 pressure run is rejected as
an NVMe-restore acceptance result. The most likely failure class is the DGX
Spark unified-memory cliff; a thermal or power fault is not excluded because
no independent temperature trace survived the event.

All timestamps below are UTC. Raw journals, the bounded old-container log, host
inventories, and their SHA-256 manifest remain outside git in private evidence
storage. Only the reviewed findings are recorded here.

## What happened

The isolated `kv-offload-step05` TP=2 service used the local packed-NVMe image,
`MAX_MODEL_LEN=262144`, `MAX_NUM_SEQS=2`, and an effective
`GPU_MEMORY_UTILIZATION_TEXT=0.81`. Its rank-local slot files were preallocated
to 34,359,459,840 bytes each. The slot backend used `O_DIRECT`, so the file was
not intended to consume 32 GiB of page cache.

The service started at 03:26:56. Three unique approximately 250K-token requests
completed:

| Seed | Completion time | Cold TTFT |
|---|---:|---:|
| 601 | 03:38:28 | 155.746 s |
| 602 | 03:41:08 | 158.653 s |
| 603 | 03:43:42 | 153.452 s |

Seed 604 began at 03:43:43. Health and metrics endpoints still answered at
03:45:35 and 03:45:22 respectively, but the request did not complete. The host
then disappeared from both management and RoCE networks and required a
physical power-on. It next booted at 04:56:05.

The fourth request was the first shape expected to push the roughly 1.01M-token
GPU prefix pool through eviction. Because it never completed and the original
seed was never repeated, this run proves disk stores only; it does not prove a
disk lookup/load or a restored-prefix TTFT.

## Preserved evidence

The previous boot remained available after recovery and was captured before
starting or deleting any experiment state.

Evidence that the termination was unclean:

- `last -x` labels the previous session `crash`; there is no matching orderly
  shutdown record.
- The previous journal has no systemd shutdown, poweroff, or reboot sequence;
  application output ends while the service was healthy.
- On the next boot, journald reported that `system.journal` was corrupted or
  uncleanly shut down and replaced it.
- The old container was `Exited (255)` only after the next boot, with
  `OOMKilled=false`. That field cannot absolve host-level UMA exhaustion: the
  whole host vanished before Docker could classify a container exit.
- No pstore record, kernel panic, Xid, or filesystem/NVMe error was recovered
  at the failure boundary.

Evidence of dangerously low UMA headroom:

- At 03:40:27, `sar` recorded only 5,495,932 KiB `MemAvailable`, 879,728 KiB
  free, and 91.02% memory used.
- The same interval was swapping at 564.93 pages/s in and 96.90 pages/s out.
- NVIDIA's kernel driver emitted `NV_ERR_NO_MEMORY` from
  `_memdescAllocInternal` at 03:30:44 and 03:30:50 during service startup.
- Earlier in the same boot, before this experiment, a separate memory-pressure
  episode repeatedly invoked the host OOM killer, killed user services and a
  vLLM worker, and caused journald and snapd watchdog failures. It demonstrates
  that this boot already had a reproducible UMA-exhaustion failure mode, but it
  is not counted as part of the Step 05 workload.

No temperature series was running on either node. Temperatures measured after
the reboot are not evidence of the pre-shutdown temperature. Public DGX Spark
reports include both UMA-OOM hard hangs and thermal/power-protection shutdowns
with the same externally visible signature, so thermal and power diagnostics
remain mandatory before a production soak.

## Root-cause classification

The current classification is **probable host unified-memory exhaustion or
driver allocation starvation**, confidence medium-high.

This classification follows the numeric pre-failure memory/swap trajectory and
the two driver allocation failures. It is stronger than a generic “automatic
shutdown” label, but it is not proof of a final kernel OOM at 03:45 because no
such final record survived. The absence of an Xid or Docker `OOMKilled` bit is
not contradictory on a shared-memory GB10 host that became unresponsive as a
whole.

Thermal/power protection is a secondary open hypothesis. It can be closed only
with independent, fsync-backed temperature sampling through the failure window
and the NVIDIA DGX Spark field diagnostic. A passing short inference or a
post-reboot temperature reading is not sufficient.

## Cleanup performed after capture

The old project was not running. Its container and logs were retained for
traceability. After verifying the exact rank-0 slot pathname and size, the
ephemeral file

```text
/home/yxa/kv-offload-lab/kv-cache/head-local/vllm-kv.slots.rank_0
34,359,459,840 bytes
```

was removed through a root container bind-mounted only to the configured
rank-local directory. Its absence was verified. Rank 1 had already been removed
with the same exact-path procedure while the head was offline. These files are
process-lifetime cache, not durable session storage, and cannot be recovered.

## Corrective gates before the next pressure run

1. Build and run the bounded-work image on both nodes; compare installed source
   hashes, not only independently built OCI IDs.
2. Lower the isolated lab utilization far enough to preserve at least 12 GiB
   `MemAvailable` on each settled node. `0.80` is no longer assumed safe merely
   because it is below the recipe's 0.835 serving default; the next run starts
   lower and promotes only from measured headroom.
3. Run independent, finite, fsync-backed telemetry on both nodes before model
   start. Preserve `MemAvailable`, swap, PSI, cgroup memory/I/O, all exposed ACPI
   thermal zones, GPU temperature/utilization, and NVRM/OOM messages.
4. Add a node-safety guard that stops only the exact experiment project after a
   numeric low-memory or high-temperature threshold persists. This is a host
   circuit breaker, not Azusa admission control.
5. Set the experiment container's OOM preference so the disposable vLLM rank is
   selected before host daemons if the kernel must reclaim a process.
6. Measure the settled GPU KV capacity, then exceed it with the smallest prompt
   set possible. Abort rather than add another context if the host reserve gate
   is approached.
7. Require disk-read growth on both ranks, an external hit/load, a materially
   lower restored TTFT than cold prefill, and deterministic target-only output
   equality before calling restore successful.
8. Run NVIDIA field diagnostics before the 24-hour soak. A PowerStress or
   ThermalStress failure blocks production and is handled as hardware/firmware
   remediation or RMA, not as an offload-code bug.

The stable deployment remains unchanged and `KV_OFFLOAD_MODE=off` remains the
default.
