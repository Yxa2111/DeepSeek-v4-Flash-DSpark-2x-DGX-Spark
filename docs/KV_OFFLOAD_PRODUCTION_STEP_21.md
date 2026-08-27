# KV Offload Production Step 21: Sustained-load gate and truthful interruption state

Date: 2026-08-27

## Scope

This step did not attempt another clock optimization.  It ran the production
stability gate selected after Step 20: the lower-UMA `nvme-local` profile, the
already bounded 1.8 GHz graphics clock, the independent 88 C node guard, and a
30-minute, two-request concurrent text soak.

The purpose of the temperature guard is only fail-closed hardware protection.
Temperature is not treated as an application performance metric and its
threshold was not weakened to make the test pass.

## Command and profile

The isolated `kv-offload-step08` project used:

```text
GPU_MEMORY_UTILIZATION_TEXT=0.72
MAX_MODEL_LEN=196608
MAX_NUM_SEQS=2
MAX_NUM_BATCHED_TOKENS=8192
KV_OFFLOAD_MODE=nvme-local
KV_OFFLOAD_DISK_BYTES=34359738368 per rank
```

The client gate was:

```text
stability-quick.py
  --ladder 8192,32768,64000
  --decode-tokens 64
  --soak-minutes 30
  --soak-prompt-tokens 8192
  --soak-concurrency 2
  --skip-vl
```

Qwen ASR and Grafana on the head were explicitly out of scope and remained on
their original container IDs throughout the stop path.

## Completed evidence

Readiness passed, then every context-ladder case passed:

| Target | Actual prompt | TTFT | Prefill | Decode | Result |
|---:|---:|---:|---:|---:|---|
| 8,192 | 8,216 | 4.511 s | 1,821 tok/s | 61.2 tok/s | pass |
| 32,768 | 32,792 | 18.548 s | 1,768 tok/s | 70.1 tok/s | pass |
| 64,000 | 64,025 | 36.956 s | 1,732 tok/s | 69.8 tok/s | pass |

Seven complete concurrent soak rounds also passed.  Each round returned the
expected typed `SOAK_OK` response for both requests.  Per-round median decode
rates were 26.48, 26.17, 25.93, 26.88, 27.08, 27.56, and 27.32 tok/s.

No NVRM allocation error, Xid, cgroup OOM, or host OOM was recorded during this
interval.  There was also no KV I/O, checksum, scheduler, or TP communication
error before the guard action.

## Why the 30-minute gate failed

During round 8, the head guard observed three qualifying high-temperature
samples and invoked `trigger_high_temperature`.  The independent telemetry
stream corroborated a peak board-sensor sample of 88.5 C at 07:01:15 UTC while
the GPU was under sustained load.  The head guard stopped only its exact rank.

The worker then observed the peer rank as absent for three consecutive checks,
invoked `trigger_peer_unavailable`, and stopped its exact rank.  The client was
interrupted immediately after the service became unavailable; therefore:

- the seven completed rounds are valid passing round evidence;
- the configured 30-minute soak did **not** complete;
- this run is **not** a production stability pass;
- current chassis cooling cannot sustain this unpaced two-request workload,
  even at the previously selected 1.8 GHz clock ceiling.

After both guard processes exited, the normal exact-project stop path removed
both 34,359,459,840-byte rank-local slot files.  No offload mmap remained.
Qwen ASR and Grafana were still running and unchanged.

## Harness correctness fix

The interrupted report exposed a separate test-harness bug.  After each good
round, `stability-quick.py` persisted `phases.soak.ok=true` even though the
configured duration had not elapsed.  A consumer could therefore mistake a
partial report for a completed soak.

Soak checkpoints now persist four separate typed fields:

```json
{
  "rounds_ok": true,
  "complete": false,
  "interrupted": true,
  "ok": false
}
```

`ok` can become true only after the configured deadline and only when all
rounds passed.  `KeyboardInterrupt` is durably recorded with an interruption
timestamp, failure record, and exit code 130.  The CPU regression test covers
partial, interrupted, completed, failed, and empty soak states.

## Gate decision

The packed KV implementation remains functionally accepted by the lower-UMA
eviction/restore A/B from Step 20.  This step rejects promotion of the current
**sustained concurrency-2 operating envelope**.  It does not invalidate the KV
restore result.

The remaining platform decision is explicit rather than hidden in application
logic: either improve the head's cooling, or choose a lower sustained serving
envelope.  This project does not add Azusa admission control and does not keep
changing clock or guard thresholds to manufacture a green soak.
