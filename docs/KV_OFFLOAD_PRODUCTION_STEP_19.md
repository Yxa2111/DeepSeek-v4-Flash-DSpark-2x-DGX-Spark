# KV Offload Production Step 19: Bounded clock A/B

Date: 2026-08-27

## Scope

This is a bounded operating-envelope check prompted by the recovered head's
prior hard shutdown and the uncapped thermal trip in Step 09.  It is not a KV
offload optimization.  Its only purpose is to choose a safe clock ceiling for
the remaining long soak.

Each condition used one unique-seed 64,000-token cold prompt followed by
exactly 128 generated tokens.  The request JSON, model, runtime, hot/disk cache
geometry, host state, and two-second guard/telemetry remained unchanged.
Starting board temperatures were allowed to return to approximately 60 C on
the head before each run.

## Result

| Clock policy | 64K TTFT | Approx. prefill | Decode | Head peak exposed temp | Head peak power |
|---|---:|---:|---:|---:|---:|
| 1,800 MHz ceiling | 37.533 s | 1,705 tok/s | 65.2 tok/s | 82.6 C | 30.09 W |
| 2,000 MHz ceiling | 38.292 s | 1,671 tok/s | 66.5 tok/s | 83.7 C | 36.90 W |
| unlocked boost | 32.823 s | 1,950 tok/s | 64.3 tok/s | **88.9 C** | **63.20 W** |

Worker peak exposed temperatures were 68.5 C, 68.7 C, and 73.7 C
respectively.  All requests computed all 64,000 prompt tokens, produced all
128 completion tokens, returned cleanly, and left zero requests queued.

These are single-run thermal probes, not a statistically powered performance
benchmark.  In particular, 1.8 versus 2.0 GHz is within observed run-to-run
variation: the earlier six-request 2.0 GHz restore campaign had cold TTFTs
near 35.1-36.1 seconds.  The decode windows are also only about two seconds.

The unlocked result is nevertheless operationally decisive.  Its head power
nearly doubled relative to the capped cases and a single 64K cold prefill
crossed the independent 88 C safety line.  It recovered on the next sample,
so the three-consecutive-sample guard did not stop the service, but default
boost has no reliable thermal margin for a sustained long-context workload.

Private raw reports are retained at:

```text
/home/yxa/kv-offload-private/live1/clock-1800.json
/home/yxa/kv-offload-private/live1/clock-2000.json
/home/yxa/kv-offload-private/live1/clock-unlocked.json
```

## Decision and remaining blocker

Both nodes were restored to a 2,000 MHz maximum clock after the A/B.  That is
the soak-only ceiling because it is the already exercised compromise: materially
more thermal margin than boost without an established throughput loss versus
1.8 GHz.  `nvidia-smi -lgc` is runtime state and is not persistent across a
reboot; this step does not claim a production deployment mechanism for it.

No further clock experimentation is planned.  The mainline blocker remains
UMA/driver allocation behavior: the worker recorded two new
`NV_ERR_NO_MEMORY` messages at 14:37:03 local time during the 2.0 GHz cold
request.  Clock selection cannot be credited with fixing memory allocation.
Before soak, the canary must move to a lower-memory profile that can start with
the 12-GiB host reserve and complete a cold 64K request without a new NVRM
allocation failure.
