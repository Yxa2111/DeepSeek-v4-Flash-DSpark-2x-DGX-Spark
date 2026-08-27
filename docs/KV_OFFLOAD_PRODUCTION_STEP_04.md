# KV offload production Step 04 - TP2 rank-zero deployment

Date: 2026-08-27

State: complete for the deployment and transfer slice. This is still an
experimental opt-in; `KV_OFFLOAD_MODE=off` remains the default.

## Deployment contract

`KV_OFFLOAD_MODE=fs-rank0` emits a vLLM `TieringOffloadingSpec` with:

- `distributed_staging=rank0`;
- `offload_prompt_only=true`;
- `kv_load_failure_policy=recompute`;
- validated 512 MiB UMA staging by default;
- a validated 1-256 MiB transfer-chunk range, defaulting to 64 MiB;
- one head-local filesystem tier. The worker bind mount exists for a symmetric
  Compose layout but must contain no `.bin` data in rank-zero mode.

The lab-env generator creates a mode-600 file from the existing deployment
without printing credentials. Its safe first-boot profile is 262,144 max
tokens, two sequences, 8,192 batched tokens, no VL sidecar, no boot warmup,
`restart: no`, and a separate Compose project.

The Anemll runtime patch is the source of truth for packed layout and TP relay.
This repo only owns validated configuration, mounts, start/stop behavior,
benchmarks, and rollback.

## Local validation

```text
test-kv-offload-config.sh:          11 passed, 0 failed
test-create-kv-offload-lab-env.sh:  passed
bash syntax checks:                 passed
git diff --check:                   passed
```

## Two-node evidence

Environment:

- head: `192.168.2.168`;
- worker: `192.168.2.190` (RoCE peer `192.168.3.2`);
- model: DeepSeek-V4-Flash-0731;
- TP=2, `nvfp4_ds_mla`, DSpark enabled;
- runtime tag: `dspark-vllm-gx10:kv-offload-rank-zero-staging`;
- filesystem cache retained across an orderly two-node stop/start.

The accepted restart probe uses the same 512-token prompt on both sides of the
restart. The prompt SHA-256 is
`98eca1de1a8406216ccd6318299a320abd17823e4d963103342cfeec8619db91`.

| Measurement | cold | restart-hot |
|---|---:|---:|
| TTFT | 0.440 s | 0.255 s |
| total elapsed | 0.863 s | 0.701 s |
| prefill KV computed | 512 | 1 |
| external prefix hits | 0 | 511 |
| KV load bytes | 0 | 46,894,848 |
| KV load worker count | 0 | 2 |

The head cache contained 67 `.bin` files and used 137 MiB after all probes.
The worker cache contained zero `.bin` files. Logs on both ranks contained no
traceback, CUDA illegal-memory access, load failure, or bounds failure.

Artifacts:

- `results/step04-rank0-hot-512.json`: cold 512-token run before restart;
- `results/step04-rank0-hot-after-restart-512.json`: accepted hot restore;
- `results/step04-rank0-cold-256.json` and
  `results/step04-rank0-hot-256.json`: alignment-boundary diagnostic;
- `results/step04-rank0-cold-8k.json`: primary-tier capacity failure probe;
- `results/step04-flush.json`: scheduler flush probe.

The names of the first 512 artifact retain the exploratory `hot` phase label,
but its metrics show a full 512-token prefill and store with no external hit;
it is the cold half of the accepted pair.

## Findings carried into Step 05/06

1. A 512 MiB primary tier exposes 251 rows. An 8K request attempted a larger
   atomic store and logged `cannot store blocks`, so the filesystem received no
   KV for that request. We need chunked staging and must reduce generic
   heterogeneous-group write amplification.
2. Every filesystem row is 2,134,016 bytes. The 256-token probe wrote 22 rows,
   or about 44.8 MiB, confirming that physical layout matters more than raw
   token count.
3. The current stop path removes containers but not the shared mmap. Crashed
   experiments had also accumulated multi-GiB stale mappings. Startup/stop must
   safely collect only unreferenced mappings before production enablement.
4. Cold and hot DSpark completion hashes were different despite greedy request
   settings. Final correctness therefore uses speculation-off equality plus a
   separate DSpark repeat-variance gate; it must not infer corruption from one
   speculative hash mismatch.
5. Filesystem capacity, eviction, integrity, atomic publication, and soak
   behavior remain unimplemented production gates.

## Rollback

Set `KV_OFFLOAD_MODE=off` and restart the dedicated project. This removes the
connector arguments and restores the existing runtime path. Cache deletion is
not part of rollback and must remain an explicit, separately targeted cleanup.

No Azusa Core admission control is introduced by this step.
