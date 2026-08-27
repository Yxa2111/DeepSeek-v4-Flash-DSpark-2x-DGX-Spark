# KV Offload Production Step 30: Fail-closed sustained-soak result

Date: 2026-08-27

## Scope

This step runs the remaining 30-minute serving gate with the Step 29 guards
continuously supervised on both nodes.  It reuses the existing
`stability-quick.py` workload rather than adding a new benchmark:

```text
context ladder: 8K, 32K, 64K
soak prompt:    8K
concurrency:    2
duration:       30 minutes configured
decode:         48 tokens per soak request
```

The live profile remained `MAX_MODEL_LEN=262144`, `MAX_NUM_SEQS=2`,
`MAX_NUM_BATCHED_TOKENS=8192`, `GPU_MEMORY_UTILIZATION_TEXT=0.73`, DSpark and
`nvme-persistent`.  `DSPARK_RESTART_POLICY=no` prevented Docker from racing a
guard decision.  No admission-control change, clock experiment or guard
threshold change was made.

## Harness correction

Before the live run, commit `0c912c2` made the stability gate fail closed.
Every chat stream must now contain:

- at least one choice event;
- a nonnull finish reason;
- prompt, completion and total token usage;
- terminal SSE `[DONE]`.

A response that happens to emit `SOAK_OK` before an early disconnect cannot
pass.  The first failed concurrent round terminates the soak instead of
repeatedly requesting an unavailable service until the deadline.

Each checkpoint is written to a private temporary file, fsynced, atomically
renamed and followed by a directory fsync.  `SIGTERM` is converted to a
truthful interrupted checkpoint.  The report schema is version 2.

Six focused stream/checkpoint tests, the earlier truthful-state tests and the
complete CPU recipe gate passed:

```text
Ran 6 tests ... OK
test-stability-quick-state: 5 passed
CI validate passed (CPU recipe gates only).
```

## Completed live work

Readiness and the complete context ladder passed:

| Target | Prompt tokens | TTFT | Decode | Complete stream |
|---:|---:|---:|---:|---|
| 8,192 | 8,216 | 4.063 s | 61.4 tok/s | yes |
| 32,768 | 32,792 | 16.495 s | 71.4 tok/s | yes |
| 64,000 | 64,025 | 32.583 s | 83.9 tok/s | yes |

The soak began at 13:55:47 UTC.  Fourteen full concurrency-2 rounds completed,
representing 28 requests.  Every completed request had `stream_complete=true`
and `finish_reason=stop`.

| Soak measurement | Result |
|---|---:|
| Complete rounds | 14 |
| Complete requests | 28 |
| Median per-round decode | 27.25 tok/s |
| Minimum / maximum per-round decode | 26.73 / 38.00 tok/s |
| Median request TTFT | 7.894 s |

## Fail-closed stop

The configured 30 minutes did not complete.  The head guard retained these
final samples:

| UTC | Exposed maximum | Consecutive count | Action |
|---|---:|---:|---|
| 13:57:44 | 89.6 C | 0 | none |
| 13:57:46 | 90.7 C | 1 | none |
| 13:57:48 | 91.0 C | 2 | none |
| 13:57:51 | 92.3 C | 3 | `trigger_high_temperature` |

At 13:57:51 the head guard gracefully stopped only the exact head container.
The API then terminated both in-flight streams.  Round 15 consequently failed
with `chat stream ended without a choice event`; the corrected harness recorded
`complete=false`, `rounds_ok=false`, `ok=false` and exited immediately.

The worker independently observed peer states `absent` with counts 1, 2 and 3,
then invoked `trigger_peer_unavailable` at 13:58:01 and gracefully stopped its
exact rank.  Both guard evidence sets have valid SHA-256 manifests.  Their
typed terminal state was:

| Node | Trigger | Local stop | Peer result |
|---|---|---|---|
| Head | `high_temperature` | `graceful_stop` | `stopped_or_absent` |
| Worker | `peer_unavailable` | `graceful_stop` | `skipped_peer_unavailable` |

The tested window retained at least 15.54 GiB `MemAvailable` on the head and
20.14 GiB on the worker.  Neither guard's retained kernel journal contained an
NVRM, Xid, OOM-kill or out-of-memory line.  This isolates the gate failure from
KV capacity, host-memory exhaustion and an offload checksum failure.

## Recovery and persistent KV check

The normal exact two-node stop path removed stopped Compose resources without
purging persistent KV.  The unchanged profile restarted successfully and the
scheduler reported:

```text
Restored 3593 committed persistent KV slots
```

Both ranks became healthy, the launcher's minimal request passed, and both
supervised guards returned to `active/running` with `NRestarts=2`.  Qwen ASR
and Grafana retained their original head containers.

Two deterministic probes make the recovery boundary explicit:

| Probe | External hit | Computed | TTFT | Result |
|---|---:|---:|---:|---|
| historical 64K A | 0 | 64,000 | 35.236 s | correct hash, but not present in restored prefix map |
| recent `soak-r14-c0` | 4,096 | 4,117 | 2.059 s | complete `SOAK_OK 14-0` |

The 64K A prompt and one-token completion hashes still matched the Step 27
baseline.  Its lack of an external hit is retained as a negative result; this
step does not assume why that older entry was absent.  The recent exact replay
proves that the guard stop and restart did preserve usable persistent KV for a
prefix committed immediately before the failure.

Private raw reports remain mode 0600 under
`/home/yxa/kv-offload-private/step30`.  Their SHA-256 values are retained in
the operator record, not committed with prompts or private environment data.

## Gate decision

The fail-closed harness, dual-node containment, restart and recent-prefix KV
recovery **pass**.  The configured unpaced 30-minute concurrency-2 serving
envelope **fails** after about two minutes of soak and is not production
qualified on the current head hardware/cooling state.

This is not fixed by weakening the guard, adding Azusa admission control or
calling fourteen partial rounds a completed soak.  Production promotion still
requires either a hardware/cooling correction followed by the same unchanged
30-minute gate, or an explicitly lower serving envelope whose workload and
tradeoff are accepted as the intended production contract.
