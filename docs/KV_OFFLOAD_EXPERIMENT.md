# NVMe KV offload experiment

Status: Step 04 implementation. Defaults remain `KV_OFFLOAD_MODE=off` and
`DSPARK_SPECULATION=dspark`. `fs-rank0` is an explicit opt-in and requires an
Anemll image carrying patch 0005 or later.

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
| `KV_OFFLOAD_MODE` | `off` | `fs-rank0` | Add filesystem L2 plus multi-node rank-zero staging |
| `KV_OFFLOAD_ROOT` | node-local cache path | absolute path | Head-node NVMe directory |
| `WORKER_KV_OFFLOAD_ROOT` | head value | absolute path | Worker-node NVMe directory |
| `KV_OFFLOAD_CPU_BYTES` | `536870912` | bytes | Small UMA staging tier, not capacity expansion |
| `KV_OFFLOAD_READ_THREADS` | `8` | 1-128 | Filesystem read-priority workers |
| `KV_OFFLOAD_WRITE_THREADS` | `4` | 1-128 | Filesystem write-priority workers |
| `KV_OFFLOAD_PYTHONHASHSEED` | `0` | fixed uint32 | Stable block filenames across restart |
| `KV_OFFLOAD_MAX_TRANSFER_CHUNK_BYTES` | `67108864` | 1-256 MiB | Hard upper bound for each TP relay payload |
| `DSPARK_KV_OFFLOAD_DIAG` | `0` | `1` | Metadata-only Anemll packed/rank/key logs |
| `DSPARK_SPECULATION` | `dspark` | `off` | Target-only control that omits `--speculative-config` |

`fs-rank0` deliberately uses `offload_prompt_only=true`,
`distributed_staging=rank0`, and
`kv_load_failure_policy=recompute`. Decode-phase KV may be recomputed; a failed
external load must not corrupt or terminate an Agent turn.

The filesystem tier currently has no disk-capacity eviction policy. Use a
dedicated test directory, record its size before and after every case, and
remove it only as an explicit cleanup step.

Create a private lab env from the current production env without editing the
source file or printing its secrets:

```bash
LAB_DSPARK_VLLM_IMAGE=dspark-vllm-gx10:kv-offload-rank-zero-staging \
LAB_WORKER_DIR=/home/yxa/kv-offload-lab/miaai \
LAB_KV_OFFLOAD_ROOT=/home/yxa/kv-offload-lab/kv-cache/head \
LAB_WORKER_KV_OFFLOAD_ROOT=/home/yxa/kv-offload-lab/kv-cache/worker \
  ./scripts/create-kv-offload-lab-env.sh \
  /home/yxa/dsv4-2x/.env.dspark .env.dspark
```

The generated file is mode 600, removes old values for every experimental key,
and appends one validated override for each. Its safe first-boot profile is
`MAX_MODEL_LEN=262144`, `MAX_NUM_SEQS=2`, 8192 batch tokens, no VL sidecar, no
boot warmup, and `restart: no`. Use a separate Compose project name for the lab
so its containers cannot alias the production project.

## First two-node matrix

Use identical token IDs and one test image digest for all rows:

| Case | Offload | Speculation | What it isolates |
|---|---|---|---|
| A | off | dspark | unchanged runtime/control |
| B | fs-rank0 | dspark | real TP2 rank-zero store/restart/load path |
| C | fs-rank0 | off | target-only correctness and DSpark variance control |

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
- target-only generated output remains equal under the deterministic
  correctness probe; DSpark-on output is compared against its own repeat
  variance and is not assumed bit-identical;
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

The completed Step 04 record and exact live measurements are in
[`KV_OFFLOAD_PRODUCTION_STEP_04.md`](KV_OFFLOAD_PRODUCTION_STEP_04.md).
