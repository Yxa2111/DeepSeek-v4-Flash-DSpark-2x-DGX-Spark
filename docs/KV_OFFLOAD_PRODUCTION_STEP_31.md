# KV Offload Production Step 31: restart LRU retention fix

Date: 2026-08-27

## Scope

This step diagnoses and closes the historical-prefix miss observed after
restart. It deploys Anemll commit `ed06419` under a new image tag, retains the
existing persistent files and compatibility identity, proves that new writes
consume unused disk slots instead of evicting restored records, and then
proves the new prefix survives a second complete TP=2 restart.

The isolated Compose project remained `kv-offload-step23`. Qwen ASR and
Grafana remained outside that project and were not restarted.

## Failure signature

The scheduler advertised 32,140 direct-I/O slots but restored only 3,593. All
valid records occupied slots 1 through 3,593. A cold deterministic 64K request
completed and stored KV, yet the valid scheduler count stayed at 3,593.

That ruled out real disk-capacity pressure: 28,547 slots, or 88.8% of the
configured pool, were still empty. It also separated this defect from the
already-fixed TP rank mapping, packed transfer geometry and DSpark ephemeral
group issues.

The Anemll root cause was the restart-time BlockPool queue. Durable mappings
were restored into the hash map, but the corresponding blocks were left at
the head of the free/eviction queue. The next store selected those restored
low slots before unused slots.

## Runtime change

Anemll commit `ed06419` collects restored blocks, touches them out of the free
queue, and frees them back to its hash-bearing LRU tail. Empty no-hash blocks
therefore remain the first allocation candidates.

The new runtime image was built independently on both nodes as:

```text
dspark-vllm-gx10:kv-offload-persistent-lru-step31
```

Both images contained the same patched `manager.py` SHA-256:

```text
f5e2487809e234d3d21439ad2e35bdfee958f27531b4a8feff8074aca2640ea8
```

The prior image and a copy of each node's prior environment file were retained
for rollback. The cache identity, model revision, 262,144-token service limit,
TP=2 geometry, DSpark mode, fixed hash seed and 32-GiB-per-rank capacity were
unchanged.

## Offline gates

The ordered Anemll patch stack applied to its pinned vLLM commit and passed
compile checks. In the real Anemll Python/torch runtime with the local
DeepSeek V4 configuration:

| Test | Result |
|---|---:|
| Focused empty-slot-before-restored-slot regression | 1 passed |
| Complete simple-offload scheduler suite | 33 passed |

## First fixed-image restart and allocation proof

The first complete two-rank restart retained all five persistent files and
logged:

```text
Allocating 32140 offload blocks (32.00 GB, mode=eager, backend=disk)
Restored 3593 committed persistent KV slots
```

Deterministic request A was not present in those mappings, so its first request
under the fixed image correctly recomputed all 64,000 prompt tokens. The
important result is the index transition after the store settled:

| Durable object | Before A | After A |
|---|---:|---:|
| Scheduler valid records | 3,593 | 3,854 |
| Highest valid scheduler slot | 3,593 | 3,854 |
| Rank-0 manifest valid records | - | 3,898 |
| Rank-1 manifest valid records | - | 3,898 |

The scheduler used slots 3,594 through 3,854 instead of overwriting restored
low slots. This is a direct live proof of the repaired LRU invariant, not an
inference from lower TTFT.

## Second restart and prefix replay

Both project ranks were stopped without running the purge path. The data,
manifests and scheduler index remained fixed-size and present. A second start
logged:

```text
Restored 3854 committed persistent KV slots
```

The byte-identical A replay then produced:

| Measurement | Before second restart | After second restart |
|---|---:|---:|
| Prompt tokens | 64,000 | 64,000 |
| External KV hits | 0 | 53,248 |
| Computed prefill tokens | 64,000 | 10,752 |
| TTFT | 32.765 s | 7.590 s |
| TTFT speedup | 1.00x | **4.32x** |

The prompt SHA-256 stayed
`8437f4c38ec62d4a0776adab76686fc994eee69b28a3d741d8f5ba28d5bd6059`
and the deterministic one-token completion stayed
`4c6773e331ed318097c14680de92d192dfdac3c0d7cc3114c020b0014d8a6ff6`.
The stream included typed usage, a finish reason and terminal `[DONE]`.

## Operational state and decision

The fixed image is currently serving on both ranks and the API is healthy.
Both peer-guard services are active. Qwen ASR and Grafana remained running
through both DSpark restarts.

The premature post-restart eviction bug is **fixed**. This result does not
override Step 30's separate rejection of the unpaced concurrency-2 thermal
envelope. Per the current test scope, no additional 30-minute soak was run in
this step.
