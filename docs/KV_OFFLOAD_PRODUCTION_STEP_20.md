# KV Offload Production Step 20: Lower-UMA restore canary

Date: 2026-08-27

## Motivation and profile

The 0.73 / 262,144-token profile functionally restored KV from both NVMe
devices, but fresh starts and cold prefills continued to produce worker
`NV_ERR_NO_MEMORY` messages.  A private canary profile was generated from the
existing secret-bearing environment without printing or changing secrets:

```text
GPU_MEMORY_UTILIZATION_TEXT=0.72
MAX_MODEL_LEN=196608
MAX_NUM_SEQS=2
MAX_NUM_BATCHED_TOKENS=8192
KV_OFFLOAD_MODE=nvme-local
KV_OFFLOAD_DISK_BYTES=34359738368 per rank
```

Reducing the model-length contract is necessary for this experiment because
0.72 at 262,144 was previously rejected: rank 1 had 4.02 GiB available while
the startup contract required 4.43 GiB.  This is a safe soak canary, not the
final one-million-token production profile.

## Corrected rollback evidence

Before stopping the prior profile, the actual configured slot paths were
resolved from its private environment and sampled directly:

```text
/home/yxa/kv-offload-lab/step08/kv-cache/head-local/vllm-kv.slots.rank_0
/home/yxa/kv-offload-lab/step08/kv-cache/worker-local/vllm-kv.slots.rank_1
```

Both files existed at 34,359,459,840 bytes.  Guards were terminated cleanly,
the normal exact-project stop returned success, and the same exact paths were
then absent.  Neither node had a residual `vllm_offload_*.mmap`; Qwen and
Grafana retained their original running container IDs.  This closes the path
error corrected after Step 18.

## Startup result

The lower profile started normally with guards already armed:

- head available KV memory: 4.71 GiB;
- worker available KV memory: 4.20 GiB;
- aggregate hot KV capacity: 219,677 tokens;
- maximum concurrency at 196,608 tokens: 1.12x;
- 32.00 GB / 32,140 direct-I/O disk slots per rank;
- minimum startup/run `MemAvailable`: 16,648,748 KiB head and
  22,571,768 KiB worker;
- no startup NVRM, Xid, cgroup OOM, host OOM, or guard action.

The launcher returned zero, both ranks became healthy, and the built-in
minimal OpenAI-compatible request passed.

## Eviction and restore result

Four distinct 64,000-token prompts A-D were submitted serially.  Their 256,000
total tokens exceed the 219,677-token hot pool by 36,323 tokens.

| Cold prompt | TTFT | External hit | Computed prompt tokens |
|---|---:|---:|---:|
| A | 35.872 s | 0 | 64,000 |
| B | 34.984 s | 0 | 64,000 |
| C | 35.020 s | 0 | 64,000 |
| D | 35.101 s | 0 | 64,000 |

Replaying A byte-for-byte produced:

| Measurement | Value |
|---|---:|
| TTFT | 6.803 s |
| Speedup versus cold A | **5.27x** |
| External KV hit | 53,248 / 64,000 tokens (83.2%) |
| Recomputed suffix | 10,752 tokens |
| Head NVMe read / write delta | 246,009,856 / 49,405,952 bytes |
| Worker NVMe read / write delta | 245,882,880 / 49,270,784 bytes |

Cold and restored A produced the same one-token completion SHA256:
`4c6773e331ed318097c14680de92d192dfdac3c0d7cc3114c020b0014d8a6ff6`.
The nearly equal physical I/O deltas are independent evidence that both TP
ranks restored local packed KV from disk.

No NVRM allocation failure appeared during the four cold requests or replay.
Private raw reports remain under
`/home/yxa/kv-offload-private/live1/lowmem-*.json`.

## Gate decision

The lower-UMA restore canary passes its memory and functional gates and can
proceed to a paced soak.  It does not prove the final 1M active-context target.

The four cold requests were separated by only 15 seconds.  Their accumulated
load produced one isolated 89.5 C head sample at 06:55:05 UTC; the next sample
recovered, so the three-sample guard did not trigger.  This is not a new clock
research branch: the soak will use the already measured 1.8 GHz ceiling plus
cool-down pacing, retain the 88 C independent guard, and abort rather than
weaken that threshold.
