# KV Offload Production Step 34: vLLM Prometheus telemetry

Date: 2026-08-28

## Scope

This step adds persistent packed-NVMe KV capacity, pressure, transfer,
duration, eviction, and error metrics to vLLM's existing `/metrics` endpoint,
deploys the thin Python layer to both DGX Spark nodes, and proves real TP=2
store and restart-load observations.

The isolated project remained `kv-offload-step23`. The model revision,
TP=2/DSpark mode, `nvfp4_ds_mla` layout, 262,144-token limit, 8,192-token
scheduler budget, 0.73 memory utilization, 32-GiB-per-rank files, fixed hash
seed, and persistent identity were unchanged. No cache purge occurred.

Qwen ASR and Grafana remained outside the project and were not restarted.

## Runtime and rollback

The independently built head and worker image tag is:

```text
dspark-vllm-gx10:kv-offload-metrics-step34
```

The five changed runtime files had identical SHA-256 values on both nodes:

| File | SHA-256 |
|---|---|
| `metrics.py` | `99fa14418dcfe30cedb1aceb7b61f8fa01ec50363cd2a9e57e467a5011ff916c` |
| `disk_backend.py` | `989975ccfc81917d69b3b0107b2f065dff924063bc264c1a4cca5d25fa6107e8` |
| `manager.py` | `3481bf64f9ad29c75a546aeb2f9361b4e3e0ac7a80da0a066ff3311602559a6e` |
| `worker.py` | `3e7f3093d3df72dd5dcd1ad9951a13a262f19ed712c5d9c89fb720ba93c1dc70` |
| `simple_cpu_offload_connector.py` | `d93561638e0e7c11c334398ad3f5c0ed583c8ebccc3ee9de74734c530163baa1` |

Both pre-change environment files were retained as
`.env.dspark.step34-backup`. The prior
`dspark-vllm-gx10:kv-offload-persistent-lru-step31` images remain locally
available. Rollback requires restoring the two environment copies and
recreating only this Compose project; the persistent files remain compatible.

## Exported metrics

The new `vllm:kv_offload_disk_*` family reports:

- scheduler/rank capacity bytes and slots;
- committed and startup-restored slots;
- per-rank load/store staging bytes and buffer rows;
- per-rank load/store queue depth and in-flight blocks;
- successful transfer bytes, blocks, operations, and duration histograms;
- scheduler LRU evictions;
- per-rank bounded backend errors.

Labels are limited to fixed `scope`, `rank`, `operation`, and `reason` values.
There are no request-, prompt-, hash-, or slot-derived labels.

The worker metrics use vLLM's existing step-level connector stats transport.
A background store completed after the last model step is published on the
next engine step; Prometheus scraping alone does not poll idle TP workers. The
cold test therefore used a tiny follow-up request to flush the completed
interval, after which queue and in-flight gauges were zero.

## Offline gates

| Gate | Result |
|---|---:|
| Anemll ten-patch apply/compile check | passed |
| Runtime file parity on both nodes | passed |
| Metrics aggregation/Prometheus/backend tests | 3 passed |
| Scheduler committed/eviction test | 1 passed |
| Keyed benchmark helper tests | 7 passed |

The benchmark helper now reads `VLLM_API_KEY` or the first normalized
`DSPARK_API_KEYS` entry from the environment and sends it as an Authorization
header without logging it. This lets the deterministic cold/hot gate run
against the keyed production profile without placing a key in command-line
arguments or result JSON.

## Guard event during offline testing

Two interrupted, temporary unit-test containers remained on the head while
the old DSpark service was still resident. The head guard correctly observed
low shared UMA, emitted typed `low_memory`, and converged both exact project
ranks to stopped. The two test containers were identified by image and command
and removed explicitly. The fixed-size KV data and metadata files were
unchanged. This was test harness cleanup, not a model or metrics runtime crash.

Subsequent image deployment and restart testing ran with no temporary test
container beside the service.

## Initial restore and cold store

The first Step 34 start restored exactly 6,017 committed slots in scheduler,
rank-0, and rank-1 metrics. Each scope reported 32,140 capacity slots. The
scheduler reported the configured 34,359,738,368 bytes; each rank reported the
slot-aligned 34,359,459,840 bytes.

A deterministic 8,192-token cold request had TTFT 4.628 s. After the completed
store was sampled, both ranks reported:

| Rank | Store blocks | Store bytes | Operations | Duration sum |
|---|---:|---:|---:|---:|
| 0 | 64 | 68,419,584 | 1 | 0.112934 s |
| 1 | 64 | 68,419,584 | 1 | 0.109337 s |

All three committed gauges advanced from 6,017 to 6,081. Queue and in-flight
gauges converged to zero.

## Restart and real load

After a complete graceful stop/start of both TP ranks, the scheduler log and
all three restore gauges reported 6,081 committed slots. The same prompt then
produced:

| Measurement | Cold | Restart-hot |
|---|---:|---:|
| Prompt tokens | 8,192 | 8,192 |
| External KV hits | 0 | 4,096 |
| Computed prefill tokens | 8,192 | 4,096 |
| TTFT | 4.628 s | 1.974 s |
| Speedup | 1.00x | 2.34x |

The rank-local load samples were:

| Rank | Load blocks | Load bytes | Operations | Duration sum |
|---|---:|---:|---:|---:|
| 0 | 38 | 40,624,128 | 1 | 0.055023 s |
| 1 | 38 | 40,624,128 | 1 | 0.057422 s |

The prompt SHA-256 was
`1864dce336da34126d3faa98ef2a05d8224ee12bb834d1a92d97b30725a5b3b1`
and the completion SHA-256 was
`4c6773e331ed318097c14680de92d192dfdac3c0d7cc3114c020b0014d8a6ff6`
for both cold and hot runs. Each stream contained typed usage, a `length`
finish reason, and terminal `[DONE]`.

## Final operational state

Both `kv-offload-step23-vllm-dspark-1` containers are healthy on the Step 34
image. The API reports zero running and waiting requests. Both peer guards are
active. No CUDA illegal access, persistent metadata mismatch, disk transfer
failure, traceback, or vLLM ERROR was found in the final-start logs.

The data files remain fixed at 34,359,459,840 bytes per rank; the scheduler
index remains 3,089,536 bytes and each rank manifest remains 518,336 bytes.
Qwen ASR container `b159e5a0c520` and Grafana container `2b1c9929ed52` remained
running throughout the controlled deployment restarts.
