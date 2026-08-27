# NVMe KV offload experiment

Status: Step 08 node guard complete offline; guarded live revalidation is next.
Defaults remain `KV_OFFLOAD_MODE=off` and
`DSPARK_SPECULATION=dspark`. `nvme-local` is the primary process-lifetime
parked-session candidate and requires an Anemll image carrying patch 0006;
`fs-rank0` remains the restart-persistent prefix experiment.

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
| `KV_OFFLOAD_MODE` | `off` | `nvme-local` | Per-rank process-lifetime local NVMe swapping |
| `KV_OFFLOAD_ROOT` | node-local cache path | absolute path | Head rank slot-file directory |
| `WORKER_KV_OFFLOAD_ROOT` | head value | absolute path | Worker rank slot-file directory |
| `KV_OFFLOAD_DISK_BYTES` | 64 GiB | 1-160 GiB | Preallocated capacity per rank/node |
| `KV_OFFLOAD_DISK_BUFFER_SLOTS` | `2` | 1-8 | Bounded aligned rows per transfer direction |
| `KV_OFFLOAD_USE_PAGE_CACHE` | `0` | `0` or `1` | Keep `0` on Spark UMA |
| `KV_OFFLOAD_PREALLOCATE_DISK` | `1` | `0` or `1` | Keep `1` so ENOSPC is a startup failure |
| `DSPARK_KV_OFFLOAD_DIAG` | `0` | `1` | Metadata-only Anemll packed/rank/key logs |
| `DSPARK_SPECULATION` | `dspark` | `off` | Target-only control that omits `--speculative-config` |

`nvme-local` deliberately disables page cache and uses only bounded aligned
staging rows. It is not restart-persistent. The older `fs-rank0` mode uses
`KV_OFFLOAD_CPU_BYTES`, read/write thread, stable-hash, and relay-chunk options;
it deliberately uses `offload_prompt_only=true`,
`distributed_staging=rank0`, and
`kv_load_failure_policy=recompute`. Decode-phase KV may be recomputed; a failed
external load must not corrupt or terminate an Agent turn.

Use a dedicated test directory and record its allocated bytes before and after
every case. The local slot file has a hard capacity and is ephemeral; the
generic filesystem tier still has no disk-capacity eviction policy.

Create a private lab env from the current production env without editing the
source file or printing its secrets:

```bash
LAB_DSPARK_VLLM_IMAGE=dspark-vllm-gx10:kv-offload-local-nvme \
LAB_WORKER_DIR=/home/yxa/kv-offload-lab/miaai \
LAB_KV_OFFLOAD_ROOT=/home/yxa/kv-offload-lab/kv-cache/head-local \
LAB_WORKER_KV_OFFLOAD_ROOT=/home/yxa/kv-offload-lab/kv-cache/worker-local \
LAB_KV_OFFLOAD_MODE=nvme-local \
LAB_KV_OFFLOAD_DISK_BYTES=34359738368 \
  ./scripts/create-kv-offload-lab-env.sh \
  /home/yxa/dsv4-2x/.env.dspark .env.dspark
```

The generated file is mode 600, removes old values for every experimental key,
and appends one validated override for each. Its safe first-boot profile is
`MAX_MODEL_LEN=262144`, `MAX_NUM_SEQS=2`, 8192 batch tokens, no VL sidecar, no
boot warmup, and `restart: no`. Use a separate Compose project name for the lab
so its containers cannot alias the production project.

## Completed Step 04 matrix (historical generic tier)

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

## Step 04 diagnostic sequence (completed)

1. If whole-packed bounds and sizing differ across ranks, fix allocation/view
   ownership first.
2. If bounds match but filesystem keys differ, fix stable hashing/rank namespace.
3. If DSpark-on misses and target-only hits, exclude or version the ephemeral
   draft group.
4. Only if whole-packed round trips fail with matching keys do we replace it
   with per-group transfer geometry.
5. After correctness, add disk capacity/eviction and measure write
   amplification before any production admission-control work.

The completed Step 04 restart-prefix record is in
[`KV_OFFLOAD_PRODUCTION_STEP_04.md`](KV_OFFLOAD_PRODUCTION_STEP_04.md). The
local-NVMe implementation, live capacity measurements, and head-node failure
are recorded in
[`KV_OFFLOAD_PRODUCTION_STEP_05.md`](KV_OFFLOAD_PRODUCTION_STEP_05.md). Exact
forced-stop cleanup, rollback, and the remaining production gates are in
[`KV_OFFLOAD_PRODUCTION_STEP_06.md`](KV_OFFLOAD_PRODUCTION_STEP_06.md).
The recovered-head unclean-shutdown analysis and revised resource gates are in
[`KV_OFFLOAD_PRODUCTION_STEP_07.md`](KV_OFFLOAD_PRODUCTION_STEP_07.md).
The numeric DGX Spark reserve guard, fsync-backed telemetry, and safer lab
profile are in
[`KV_OFFLOAD_PRODUCTION_STEP_08.md`](KV_OFFLOAD_PRODUCTION_STEP_08.md).
