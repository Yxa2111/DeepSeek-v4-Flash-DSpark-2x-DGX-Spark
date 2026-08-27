# KV Offload Production Step 22: Rollback drill and project checkpoint

Date: 2026-08-27

## Repository boundary

The implementation is intentionally split across two independent forks:

| Repository | Branch | Responsibility | Current tip |
|---|---|---|---|
| `Yxa2111/dspark-vllm-gx10` (Anemll fork) | `experiment/packed-kv-offload-tp2` | vLLM runtime: packed KV semantics, bounded direct-I/O NVMe backend, cancellation and failure cleanup | `ce97d33` |
| `Yxa2111/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark` (MiaAI fork) | `experiment/nvme-kv-offload` | deployment recipe: image wiring, per-rank paths, lifecycle, guards, telemetry and live acceptance | this step's commit |

MiaAI consumes and configures the Anemll runtime; Anemll does not depend on the
MiaAI recipe.  Runtime data-layout changes belong in the Anemll fork, while
machine topology and operational policy belong in the MiaAI fork.

## Rollback drill

A private mode-600 environment was generated from the Step 20 environment
without printing or changing secrets.  The only functional rollback change
was:

```text
KV_OFFLOAD_MODE=off
GPU_MEMORY_UTILIZATION_TEXT=0.72
MAX_MODEL_LEN=196608
MAX_NUM_SEQS=2
MAX_NUM_BATCHED_TOKENS=8192
```

Both TP ranks launched and loaded the target and DSpark draft weights.  The
runtime then rejected the worker memory contract before API readiness:

```text
head available KV:   4.84 GiB
worker available KV: 3.56 GiB
required for 196608: 4.17 GiB
estimated worker max model length: 42240
```

This is a failed rollback gate.  `KV_OFFLOAD_MODE=off` did remain semantically
off: neither node created a rank-local NVMe slot or offload mmap.  The failure
was a fail-closed vLLM capacity check, not an offload I/O or packed-layout
error.

The startup script detected the failed TP initialization and converged both
nodes through the exact-project stop path.  Final state:

- no `kv-offload-step08` container or compose resource on either node;
- no rank-local slot file and no offload mmap on either node;
- no new NVRM, Xid, cgroup OOM, or host OOM record;
- Qwen ASR and Grafana retained their original running container IDs;
- the temporary 1.8 GHz graphics-clock ceiling was reset on both nodes;
- both long-running experiment telemetry samplers were stopped.

The safe rollback procedure is therefore not “toggle only `KV_OFFLOAD_MODE`
while retaining the 196K profile.”  It must restore a separately validated
off-mode profile (including its model-length and UMA budget) or the previous
known-good deployment as one atomic configuration.

## Consolidated result table

| Area | Evidence | Result | Production meaning |
|---|---|---|---|
| Fork and ownership boundary | Independent Anemll runtime and MiaAI recipe forks; clean tracked branches | pass | Upstream sync and local patches can be managed separately |
| Packed KV semantics | DSpark ephemeral group excluded from reusable-prefix veto; heterogeneous packed groups retained | pass | Avoids false whole-prefix miss from draft KV |
| Bounded local NVMe backend | Per-rank direct I/O, bounded buffers/queue/store batch, checksum/generation validation | pass | No unbounded UMA or page-cache growth by design |
| Offline failure gates | Cancellation, timeout, checksum rejection, ENOSPC cleanup and scheduler bounds | pass | Backend fails closed and releases work |
| TP lifecycle | Exact-project stop, failed-start convergence, slot/mmap cleanup | pass | Split-rank resurrection and broad container deletion are avoided |
| Host protection | UMA reserve guard, three-sample thermal gate, typed peer-state circuit breaker | pass | Exact rank stops on persistent local or peer failure |
| Live TP2 NVMe path | Both ranks opened their own 32 GiB direct-I/O tier | pass | Rank-local packed storage works on the two Sparks |
| Live eviction and restore | 256K unique cold tokens exceeded the 219,677-token hot pool; replay hit external KV on both ranks | pass | Real eviction was forced; result is not a RAM-only cache hit |
| Restore performance | 64K cold A TTFT 35.872 s; restored A 6.803 s; 83.2% external hit | pass, **5.27x TTFT** | Reusing a parked Agent prefix is materially faster than recompute |
| Restore correctness | Cold/restored completion SHA256 identical; near-equal head/worker NVMe I/O deltas | pass | Restored packed KV preserved this deterministic completion |
| Cancelled concurrency / loop gate | Survivor completion plus coherent cancellation A/B and synthetic-loop control | pass for tested cases | No tested cancellation path reproduced an endless model loop |
| Live peer loss | Three typed absent checks stopped the surviving exact rank; restart recovered | pass | A dead peer cannot leave the other TP rank serving indefinitely |
| Context ladder | 8K/32K/64K passed at 1.73–1.82K prefill tok/s | pass | Lower-UMA canary handles bounded long prompts |
| Sustained concurrency-2 soak | Seven rounds passed; round 8 triggered the independent head thermal guard | **fail** | Current cooling does not qualify for an unpaced 30-minute c2 envelope |
| Off-mode 196K rollback | Worker KV 3.56 GiB versus 4.17 GiB required | **fail** | Rollback needs a separately validated off-mode UMA/model-length profile |
| One-million-token target | Not exercised by the 196,608-token canary | not proven | Do not claim 1M active-context production readiness |

## Current decision

The software backend has passed its bounded-work, live two-rank eviction,
restore, correctness, cancellation, and peer-failure gates.  It is suitable for
continued experimental parked-session work.

Production promotion is **not approved** by this checkpoint.  The remaining
gaps are explicit:

1. qualify a sustainable hardware operating envelope or improve head cooling;
2. validate a complete 30-minute soak at the intended sustained load;
3. validate an atomic off-mode rollback profile;
4. repeat capacity, correctness, and restore tests at the intended long-context
   target, eventually including the 1M contract.

No Azusa admission-control change is included or required by this branch.
