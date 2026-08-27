# KV Offload Production Step 26: Live identity-mismatch recovery

Date: 2026-08-27

## Scope

This step closes the live cache-identity gate left open by Step 24.  It proves
that an operator cannot start the same TP=2 persistent files under a different
compatibility identity, that the failed launch converges both ranks without
deleting the cache, and that the original identity can subsequently restore
and serve the same prefix.

The test used the isolated `kv-offload-step23` project and the existing five
files from the successful 64K restart campaign.  Qwen ASR and Grafana remained
outside the project.

## Fault injection

The standard lab-env generator created a separate mode-0600 env with every
runtime and geometry value unchanged except the cache identity:

```text
expected: dsv4-0731-r9e165c30-nvfp4-dspark-tp2-kv09
injected: dsv4-0731-r9e165c30-nvfp4-dspark-tp2-kv09-wrong
```

The correct `.env.dspark` was not edited.  No data, manifest or index byte was
deliberately modified for this gate.

## Expected failed start

Both ranks started model loading and derived their live packed-KV geometry.
During connector initialization, worker rank 1 opened its existing manifest
and failed before API readiness with:

```text
ValueError: persistent KV metadata identity mismatch for
/kv-offload/vllm-kv.slots.rank_1.meta
```

The launcher returned nonzero and invoked its existing failed-TP-start
convergence path.  The exact `kv-offload-step23` containers were absent on both
nodes afterward.  The peer's subsequent TCPStore/broken-pipe diagnostics were
consequences of the intentional rank failure, not a second root cause.

No API became ready under the wrong identity.  The runtime did not silently
unlink, truncate, reinitialize or adopt the old files.

## Cache preservation check

After failed-start convergence, the exact artifact set remained:

| Node | Artifact | Size | Mode | Links |
|---|---|---:|---:|---:|
| head | `vllm-kv.slots.rank_0` | 34,359,459,840 | 0600 | 1 |
| head | `vllm-kv.slots.rank_0.meta` | 518,336 | 0600 | 1 |
| head | `vllm-kv.slots.index` | 3,089,536 | 0600 | 1 |
| worker | `vllm-kv.slots.rank_1` | 34,359,459,840 | 0600 | 1 |
| worker | `vllm-kv.slots.rank_1.meta` | 518,336 | 0600 | 1 |

The Step 25 purge dry-run was then run with the original env and identity.  It
reparsed and accepted both rank manifests and the scheduler index, proving
that the failed wrong-identity launch did not replace their identity headers.

## Correct-identity recovery

The exact same image and original env were started without purge.  Both ranks
opened their previous files with `persistent=True`; the new scheduler logged:

```text
Restored 2002 committed persistent KV slots
```

The committed count is the scheduler authority at that shutdown boundary; it
is intentionally not inferred from the larger rank-manifest population.  API
startup and the launcher's minimal request passed.

Request A was then regenerated with the original size and seed:

| Measurement | Original cold A | After mismatch recovery |
|---|---:|---:|
| Prompt tokens | 64,000 | 64,000 |
| TTFT | 33.905 s | 7.171 s |
| External KV tokens | 0 | 53,248 |
| Computed prefill tokens | 64,000 | 10,752 |
| External hit ratio | 0% | 83.2% |
| TTFT speedup | 1.00x | **4.73x** |

Prompt SHA-256 matched:

```text
8437f4c38ec62d4a0776adab76686fc994eee69b28a3d741d8f5ba28d5bd6059
```

The deterministic one-token completion SHA-256 also matched:

```text
4c6773e331ed318097c14680de92d192dfdac3c0d7cc3114c020b0014d8a6ff6
```

This proves the negative and positive halves together: an incompatible
identity is rejected, while returning to the compatible identity recovers the
previous external prefix rather than forcing a purge.

## Safety observations

During the correct-identity recovery and replay:

- head minimum `MemAvailable`: 16,076,816 KiB;
- worker minimum `MemAvailable`: 21,527,144 KiB;
- head maximum exposed temperature: 80.1 C;
- worker maximum exposed temperature: 60.9 C;
- neither guard triggered and both peers remained typed `running`;
- the API remained healthy after the replay;
- Qwen ASR and Grafana remained running.

The guard on the intentionally failed worker observed peer loss during launch
cleanup.  That is correct fail-closed behavior for the faulted run and did not
delete persistent files.

## Gate decision

The live identity mismatch and same-identity recovery gate **passes**.
Remaining storage-fault work is now narrower: deliberately corrupt one rank's
payload, prove checksum rejection, execute the coordinated purge, restart with
empty files and prove clean recomputation.

