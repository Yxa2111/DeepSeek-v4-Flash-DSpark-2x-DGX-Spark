# KV Offload Production Step 24: TP=2 restart-persistent NVMe proof

Date: 2026-08-27

## Scope

This step exercised the `nvme-persistent` deployment mode from Step 23 against
the restart-persistent packed-KV runtime from Anemll Step 09.  The acceptance
target was deliberately narrower than a general stability claim: retain a
committed DeepSeek V4 prefix across a complete two-rank service stop/start,
then prove that the restarted request reads both rank-local NVMe files and
returns the same deterministic output.

The isolated Compose project was `kv-offload-step23`.  Qwen ASR and Grafana on
the head were outside the project and remained running throughout.

## Exact profile

```text
image=dspark-vllm-gx10:kv-offload-persistent-step09
model=deepseek-ai/DeepSeek-V4-Flash-0731
revision=9e165c30e2704aec5d9d593cce3eebd58bbef1cb
TP=2
KV_CACHE_DTYPE=nvfp4_ds_mla
DSpark=enabled
MAX_MODEL_LEN=262144
MAX_NUM_SEQS=2
MAX_NUM_BATCHED_TOKENS=8192
GPU_MEMORY_UTILIZATION_TEXT=0.73
KV_OFFLOAD_MODE=nvme-persistent
KV_OFFLOAD_DISK_BYTES=34359738368 per rank
PYTHONHASHSEED=0
KV_OFFLOAD_CACHE_IDENTITY=dsv4-0731-r9e165c30-nvfp4-dspark-tp2-kv09
```

The runtime reported 345,848 hot-KV tokens on the restarted service.  Each
rank opened a 32-GiB direct-I/O packed slot file with persistence enabled.

## Interrupted-store boundary before restart

Four unique 64,000-token cold requests, A through D, completed.  Their
2,048 scheduler records were durably committed.  A fifth request, E, reached
the rank data/manifest path, but the independent head guard stopped the exact
test project after three 88 C breaches before its scheduler commit became
durable.

After both ranks were stopped, the retained metadata contained:

| Durable object | Valid records |
|---|---:|
| scheduler index | 2,048 |
| rank 0 manifest | 2,112 |
| rank 1 manifest | 2,112 |

The extra 64 rank-local rows were therefore orphan data, not published cache
hits.  This is the live counterpart of the offline commit-order tests: worker
durability alone cannot make a prefix visible after an interrupted store.

All five expected files remained present with mode `0600` and one link each:
rank 0 data and manifest plus the scheduler index on the head, and rank 1 data
and manifest on the worker.

## Complete service restart

Both TP containers were started again with the same image, fixed hash seed,
cache identity and exact files.  No purge or metadata rewrite occurred.  The
scheduler logged:

```text
Restored 2048 committed persistent KV slots
```

Both workers opened their previous packed rank files with
`persistent=True`, the API became healthy, and the launcher's minimal request
passed.  There was no new identity, checksum, CUDA, OOM or TP error during this
startup and replay window.

## Deterministic replay result

Request A was regenerated from the same token corpus, size and seed, then sent
once after restart.  The process restart had eliminated any in-memory hot
prefix; a hit could only come from the restored scheduler index and rank-local
NVMe data.

| Measurement | Cold A | Restarted A |
|---|---:|---:|
| Prompt tokens | 64,000 | 64,000 |
| TTFT | 33.905 s | 6.838 s |
| External KV tokens | 0 | 53,248 |
| Locally recomputed tokens | 64,000 | 10,752 |
| External hit ratio | 0% | 83.2% |
| TTFT speedup | 1.00x | **4.96x** |
| TTFT reduction | - | **79.8%** |

The prompt SHA-256 matched across both requests:

```text
8437f4c38ec62d4a0776adab76686fc994eee69b28a3d741d8f5ba28d5bd6059
```

The deterministic one-token completion SHA-256 also matched:

```text
4c6773e331ed318097c14680de92d192dfdac3c0d7cc3114c020b0014d8a6ff6
```

Prometheus independently reported 53,248 external prefix-cache hits and
10,752 computed prefill tokens for the replay.

## Per-rank NVMe evidence

Cgroup I/O counters were sampled immediately before and after the replay:

| Rank | Read delta | Write delta |
|---|---:|---:|
| rank 0 / head | 255,311,872 bytes | 49,176,576 bytes |
| rank 1 / worker | 246,489,088 bytes | 49,291,264 bytes |

Both ranks performed a near-symmetric quarter-gigabyte read.  The smaller
writes correspond to persisting the newly computed suffix.  This rules out a
rank-0-only mapping and an ordinary in-memory prefix hit.

## Safety and retained state

During the restarted replay guard window:

- head minimum `MemAvailable`: 16,463,376 KiB;
- worker minimum `MemAvailable`: 22,068,928 KiB;
- head maximum exposed temperature: 78.8 C;
- worker maximum exposed temperature: 58.5 C;
- neither guard triggered and both peers remained typed `running`;
- the service remained healthy after the replay;
- Qwen ASR and Grafana retained their original running scope.

Private raw JSON, I/O snapshots and guard records remain under
`/home/yxa/kv-offload-private/step23`.  No prompt, cache hash, KV payload or
private environment file is committed.

## Gate decision

The TP=2 restart-persistence functional gate **passes** for a committed 64K
DeepSeek V4 packed prefix.  The live interrupted-store observation also passes:
orphan rank rows were not restored because the scheduler index had not
committed them.

This does not close the remaining production gates:

- a deliberate identity mismatch still needs an exact live failure/recovery
  exercise;
- one-rank payload corruption still needs supervised purge and clean
  recomputation evidence;
- coordinated exact-path purge is not yet implemented in the recipe;
- the 30-minute concurrency-2 stability gate remains rejected by the head's
  cooling envelope;
- the separate high-concurrency long-reasoning loop has not been reproduced or
  fixed by this KV work.

