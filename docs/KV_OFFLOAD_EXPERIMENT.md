# NVMe KV offload experiment

Status: Phase 0 scaffolding. Defaults remain `KV_OFFLOAD_MODE=off` and
`DSPARK_SPECULATION=dspark`. Do not point the production service at an
experimental image until the two-node cold-start gate passes.

## Repository boundary

- The Anemll fork owns runtime truth: packed KV geometry, CPU/GPU transfer,
  filesystem keys, TP rank ownership, and the built image.
- This MiaAI fork owns deployment truth: node-local mounts, validated switches,
  two-node synchronization, A/B profiles, metrics collection, and rollback.
- vLLM remains pinned through Anemll's `upstream.lock`. We carry a narrow patch
  series first; a separate vLLM fork is only needed when a fix is ready to send
  upstream.

## Phase 0 switches

| Variable | Default | Experimental value | Purpose |
|---|---:|---:|---|
| `KV_OFFLOAD_MODE` | `off` | `fs-poc` | Add `OffloadingConnector` with CPU staging and filesystem L2 |
| `KV_OFFLOAD_ROOT` | node-local cache path | absolute path | Head-node NVMe directory |
| `WORKER_KV_OFFLOAD_ROOT` | head value | absolute path | Worker-node NVMe directory |
| `KV_OFFLOAD_CPU_BYTES` | `536870912` | bytes | Small UMA staging tier, not capacity expansion |
| `KV_OFFLOAD_READ_THREADS` | `8` | 1-128 | Filesystem read-priority workers |
| `KV_OFFLOAD_WRITE_THREADS` | `4` | 1-128 | Filesystem write-priority workers |
| `KV_OFFLOAD_PYTHONHASHSEED` | `0` | fixed uint32 | Stable block filenames across restart |
| `DSPARK_KV_OFFLOAD_DIAG` | `0` | `1` | Metadata-only Anemll packed/rank/key logs |
| `DSPARK_SPECULATION` | `dspark` | `off` | Target-only control that omits `--speculative-config` |

`fs-poc` deliberately uses `offload_prompt_only=true` and
`kv_load_failure_policy=recompute`. Decode-phase KV may be recomputed; a failed
external load must not corrupt or terminate an Agent turn.

The filesystem tier currently has no disk-capacity eviction policy. Use a
dedicated test directory, record its size before and after every case, and
remove it only as an explicit cleanup step.

## First two-node matrix

Use identical token IDs and one test image digest for all rows:

| Case | Offload | Speculation | What it isolates |
|---|---|---|---|
| A | off | dspark | unchanged runtime/control |
| B | fs-poc | dspark | real DSpark packed store/restart/load path |
| C | fs-poc | off | whether the DSpark draft group causes the miss |

For B and C:

1. Start with empty, dedicated head/worker directories.
2. Submit a unique long prompt and wait for all stores to finish.
3. Record file count, physical bytes, logical KV estimate, metrics, and the
   structured diagnostics from both ranks.
4. Restart the same image/config without deleting the directories.
5. Resubmit the byte-identical prompt and then the same prefix plus a short
   suffix.
6. Compare cold TTFT, hot TTFT, prefill tokens/s, load/store bytes and time,
   output equality, and rank/key diagnostics.

The experiment is not a hit merely because files exist. A valid restart hit
requires all of the following:

- external prefix-cache hits increase;
- `vllm:kv_offload_load_bytes` increases on the hot request;
- both ranks reach the same terminal hit/load state;
- hot TTFT is materially lower than cold TTFT;
- generated output remains equal under the deterministic correctness probe;
- no diagnostic record reports `bounds_ok=false`.

## Decision sequence

1. If whole-packed bounds and sizing differ across ranks, fix allocation/view
   ownership first.
2. If bounds match but filesystem keys differ, fix stable hashing/rank namespace.
3. If DSpark-on misses and target-only hits, exclude or version the ephemeral
   draft group.
4. Only if whole-packed round trips fail with matching keys do we replace it
   with per-group transfer geometry.
5. After correctness, add disk capacity/eviction and measure write
   amplification before any production admission-control work.
