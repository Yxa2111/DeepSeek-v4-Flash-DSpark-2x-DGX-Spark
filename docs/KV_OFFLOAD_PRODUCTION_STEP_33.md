# KV Offload Production Step 33: isolated 1M profile gate

Date: 2026-08-27

## Purpose

This step attempts the remaining one-million-token serving gate on the current
restart-persistent packed-NVMe image, then restores the validated lower-UMA
service regardless of outcome. It does not reuse the repository's historical
900K result as evidence for this newer runtime and co-resident host state.

## Isolated profile

The current environment was copied for exact rollback before changing only
these serving geometry fields:

```text
MAX_MODEL_LEN=1048576
MAX_NUM_SEQS=1
MAX_NUM_BATCHED_TOKENS=8192
GPU_MEMORY_UTILIZATION_TEXT=0.835
```

The image, DeepSeek V4 Flash 0731 revision, TP=2, DSpark, `nvfp4_ds_mla`,
fixed hash seed, persistent cache identity and 32-GiB-per-rank NVMe files were
unchanged. Boot shape warmup remained disabled. Qwen ASR and Grafana remained
running outside the isolated Compose project.

The 0.835 value is the documented historical 1M recipe value. Lowering it is
not a valid way to force this gate: the current multi-group runtime already
needs substantially more hot KV memory than the validated 0.73 / 262K profile,
and vLLM must have enough blocks for at least one configured maximum-length
request.

## Live failure

Both ranks joined the TP group and loaded the model. Near the end of startup,
memory dropped sharply while the service was still unavailable. The two
independent guards observed the following last three samples:

| Node | `MemAvailable` samples | Peak temperature in the three samples |
|---|---|---:|
| Head | 7,096,332 / 6,892,900 / 6,687,168 KiB | 70.1 C |
| Worker | 11,646,256 / 11,470,476 / 11,386,580 KiB | 54.2 C |

Every value was below the configured 12-GiB host reserve. Both guards reached
three consecutive breaches and emitted typed `trigger_low_memory` at
15:30:32 UTC. The head rank required the bounded timed-kill path; the worker
rank stopped gracefully, and the peer-stop path converged the exact project.

The head kernel independently recorded at 15:30:24 UTC:

```text
NVRM: nvCheckOkFailedNoLog: Check failed: Out of memory
[NV_ERR_NO_MEMORY] returned from _memdescAllocInternal
```

No high-temperature counter advanced. This gate failed because of shared UMA
allocation pressure, not the thermal threshold.

The OpenAI API never became ready, so no 1M prompt was submitted. That is the
correct fail-closed ordering: a single-request capacity test cannot pass when
the configured server itself cannot retain the required host reserve. The
result is therefore:

```text
1M profile startup under the 12-GiB reserve: fail
current-image 1M single-request completion: not established
```

## Rollback and retained data

The exact pre-test environment copies were restored on both nodes:

```text
MAX_MODEL_LEN=262144
MAX_NUM_SEQS=2
MAX_NUM_BATCHED_TOKENS=8192
GPU_MEMORY_UTILIZATION_TEXT=0.73
```

No persistent cache purge was run. All five data/metadata files remained
present. The restored service logged 4,122 committed persistent KV slots,
became healthy, and reported zero running and waiting requests. Both peer
guards are active. Qwen ASR and Grafana retained their running services.

The rollback startup was operationally successful but not allocator-clean.
The head recorded `NV_ERR_NO_MEMORY` at 15:36:22 and 15:36:23 UTC, and the
worker recorded it twice at 15:36:28 UTC. These warnings were non-fatal in the
lower profile: settled `MemAvailable` recovered to approximately 17.5 GiB on
the head and 23.3 GiB on the worker, with typed guard state `running` and no
action. They remain an explicit runtime/driver gap rather than being hidden by
the healthy API result.

The recovered lower-UMA runtime currently reports 378,162 hot KV tokens. This
live value, rather than the older README's approximately 2.49M-token number,
is the relevant capacity observation for this patched image and current host
coexistence state.

## Decision

The current two-Spark co-resident environment is **not qualified for a 1M
active-context service profile** with this runtime while preserving the
12-GiB host reserve. NVMe persistence still helps parked prefixes, but it does
not remove the startup/hot-KV memory needed for an active maximum-length
request.

A future 1M retry must first change the memory equation in a measured way:
reduce runtime/model/KV footprint or free material UMA on the serving nodes,
then pass startup before spending ten-plus minutes on a full prompt. Weakening
the guard or presenting the historical 900K run as a current result is not an
acceptable workaround. No 30-minute soak was run in this step.
