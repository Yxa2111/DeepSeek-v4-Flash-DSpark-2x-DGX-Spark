# KV Offload Production Step 18: Live TP peer-loss and recovery

Date: 2026-08-27

## Setup

The Step 17 guard was deployed on both DGX Spark nodes with:

```text
project=kv-offload-step08
interval=2 seconds
peer_check_consecutive=3
min_available_kib=12582912
max_temp_millic=88000
consecutive_breaches=3
```

Both guards first observed the existing ranks as `running`.  A real streaming
request was then left decoding while only the worker's exact canary container
`93f8e52c3c47` was stopped.  Rank 0, Qwen, Grafana, and all other containers
were left untouched by the injection command.

## Fault timeline

All timestamps below are UTC.

| Time | Evidence |
|---|---|
| 06:26:52 | worker exact container finished with exit 137 after bounded stop |
| 06:26:54 | head guard recorded peer `absent`, count 1 |
| 06:26:56 | head guard recorded peer `absent`, count 2 |
| 06:26:59 | head guard recorded peer `absent`, count 3 and `trigger_peer_unavailable` |
| 06:26:59 | head guard began stopping exact local container `3223a3f271d1` |
| 06:27:19 | local container was verified stopped; guard finalized with exit 42 |

The head metadata is internally consistent and its SHA256 manifest verifies:

```text
exit_status=42
trigger_reason=peer_unavailable
stop_result=timed_kill
peer_check_consecutive=3
last_peer_state=absent
peer_stop_result=skipped_peer_unavailable
```

The in-flight client did not hang until its 180-second client timeout.  Its
connection closed with curl exit 18 (outstanding response data) and retained
62,471 bytes of partial SSE.  The private trace SHA256 is
`ce1a37a62105332b57b1eb896e14dac5eae44827a8fed0c10b35e50d19bb9ed8`.

The worker guard correctly changed to `local_absent`, reset its peer-failure
counter, and did not mutate anything.  On the head, the unrelated containers
remained the same running instances throughout the fault:

```text
b159e5a0c520 qwen3-asr-06b
2b1c9929ed52 grafana-grafana-1
```

## Cleanup and recovery

The normal exact-project stop path ran after the fault.  It reported success,
left neither canary container running, and found no residual
`vllm_offload_*.mmap` on either node.  The launcher then recreated both disk
backends successfully during restart.

Correction: the immediate post-stop manual slot-absence check used obsolete
paths (`kv/head` and `kv/worker`) rather than this profile's configured
`kv-cache/head-local` and `kv-cache/worker-local` roots.  Therefore this step
does not claim independent pre-restart proof that both old slot files were
absent; only the exact stop command's success and the subsequent backend
recreation are established.  The next controlled stop must check the actual
configured roots before restart.

Fresh guards were armed before restart.  They reported `local_absent` before
container creation and `running` with a zero peer-failure counter once both
ranks appeared, proving normal startup ordering does not trip the peer-loss
gate.

The normal start path created new rank containers at approximately 06:29:39:

```text
head   bd6ced094ee2  healthy
worker 2be00639e459  healthy
```

It returned zero, `/health` returned success, and the built-in minimal
OpenAI-compatible chat request passed.  The reconstructed cache geometry was:

- head available hot KV: 5.88 GiB;
- worker available hot KV: 5.20 GiB;
- aggregate hot KV capacity: 340,008 tokens;
- disk tier: 32.00 GB and 32,140 slots per rank, direct I/O mode.

During the restart window, the guards stayed above their safety reserve:

| Node | Minimum `MemAvailable` | Peak exposed temperature |
|---|---:|---:|
| head | 18,685,648 KiB | 74.1 C |
| worker | 23,226,836 KiB | 60.6 C |

## Production decision

The live peer-loss functional gate passes:

- persistent loss is detected from typed exact-container state;
- the surviving rank fails closed within the bounded window;
- the client connection terminates instead of hanging indefinitely;
- unrelated services are untouched;
- the normal exact cleanup path reports success and restart restores a healthy
  TP2 API; direct slot-absence evidence remains to be repeated at the corrected
  roots.

The clean-kernel promotion gate does **not** pass.  At 14:33:30 local time,
during the worker's restart/warmup, its kernel recorded two new
`NVRM ... NV_ERR_NO_MEMORY` allocation failures.  No Xid, host OOM kill, guard
trip, or API failure followed, and settled host reserve remained healthy, but
Step 08 explicitly required no new driver allocation failure.  Therefore the
0.73 profile remains a canary configuration and is not production-approved by
this step.  Clock/thermal and startup-memory policy must be resolved before a
sustained soak or promotion claim.
