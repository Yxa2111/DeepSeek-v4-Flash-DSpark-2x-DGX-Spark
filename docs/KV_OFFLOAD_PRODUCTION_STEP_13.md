# KV Offload Production Step 13: TP=2 NVMe restore proof

Date: 2026-08-27

## Configuration

- isolated Compose project: `kv-offload-step08`;
- runtime image: `dspark-vllm-gx10:kv-offload-bounded-work`;
- model: `DeepSeek-V4-Flash-0731`, TP=2, DSpark enabled;
- packed KV type: `nvfp4_ds_mla`;
- model length: 262,144;
- GPU memory utilization: 0.73;
- hot KV capacity: 342,084 tokens;
- rank-local NVMe capacity: 32 GiB per rank, direct I/O;
- reversible GPU clock ceiling for thermal A/B: 2,000 MHz;
- guard: 12 GiB minimum available memory, 88 degrees C maximum exposed
  temperature, three consecutive two-second breaches, coordinated TP stop.

## Method

The benchmark generated deterministic token-ID prompts.  Six unique 64,000
token prompts (A through F) were submitted serially, for 384,000 total tokens.
This exceeded the 342,084-token hot pool by 41,916 tokens.  The oldest prompt,
A, was then replayed byte-for-byte with temperature-zero one-token generation.

Raw JSON remains private under `/home/yxa/kv-offload-private/live1`; no prompt,
credential or private environment file is committed.

## Result

| Measurement | Cold A | Replayed A |
|---|---:|---:|
| Prompt tokens | 64,000 | 64,000 |
| TTFT | 36.121 s | 7.217 s |
| External KV tokens | 0 | 53,248 |
| Locally recomputed tokens | 64,000 | 10,752 |
| External hit ratio | 0% | 83.2% |
| TTFT speedup | 1.00x | **5.01x** |

The prompt SHA-256 matched.  The one-token completion SHA-256 also matched:
`4c6773e331ed318097c14680de92d192dfdac3c0d7cc3114c020b0014d8a6ff6`.

Prometheus independently reported 53,248
`external_prefix_cache_hits_total` tokens and 53,248 prompt tokens from
`external_kv_transfer`.  It reported 10,752 computed prefill tokens.

## Per-rank disk evidence

Immediately around the replay, cgroup I/O counters changed as follows:

| Rank | NVMe read delta | Write delta |
|---|---:|---:|
| rank 0 / head | 245,907,456 bytes | 49,291,264 bytes |
| rank 1 / worker | 245,899,264 bytes | 49,176,576 bytes |

The nearly identical rank-local reads are the decisive TP=2 evidence: this was
not a rank-0-only cache hit and not an ordinary hot-prefix hit.  The smaller
writes correspond to storing the 10,752 newly computed suffix.

## Safety observations

Across the six paced cold requests plus replay:

- head peak exposed temperature: 85.6 degrees C;
- worker peak exposed temperature: 73.5 degrees C;
- head minimum `MemAvailable`: 15,962,848 KiB;
- worker minimum `MemAvailable`: 21,694,592 KiB;
- no guard action, cgroup OOM, NVRM allocation error or host loss occurred.

This proves functional packed-KV store/evict/restore on both TP ranks and a
material TTFT gain.  It does not yet promote the service: cancellation, live
fault behavior, clock-cap A/B, longer soak and rollback remain open gates.
