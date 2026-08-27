# KV Offload Production Step 23: restart-persistent deployment mode

Date: 2026-08-27

## Outcome

MiaAI now exposes the Anemll Step 09 persistence protocol as one atomic mode:

```text
KV_OFFLOAD_MODE=nvme-persistent
KV_OFFLOAD_PYTHONHASHSEED=0
KV_OFFLOAD_CACHE_IDENTITY=<operator-owned compatibility identity>
```

Implementation commit: `352e130`.

This step is deployment and offline-validation evidence.  It does not yet
claim a TP=2 hit across a complete service restart.

## Why this is a mode, not an independent boolean

The runtime connector still receives the explicit boolean
`disk_persistence=true`.  MiaAI derives that boolean only from the typed mode
`nvme-persistent`.  The existing modes keep their exact meanings:

| Mode | Disk backend | Restart retention |
|---|---|---|
| `off` | none | no cache activity |
| `nvme-local` | packed rank-local NVMe | process lifetime only |
| `nvme-persistent` | packed rank-local NVMe | durable rank manifests and scheduler index |
| `fs-rank0` | generic filesystem tier | historical diagnostic path |

This keeps rollback atomic.  An operator cannot accidentally select
`KV_OFFLOAD_MODE=off` while leaving a second persistence switch active.

## Identity contract

Persistent mode refuses to start without a 1-256 character identity containing
only letters, digits and `._:@+-`.  It also refuses an absent, non-numeric or
random `PYTHONHASHSEED`.

The identity must change whenever any compatibility input changes, including:

- model and tokenizer revision;
- KV dtype or packed-layout implementation;
- TP world size;
- scheduler/hash block geometry;
- a runtime change that invalidates serialized block hashes.

For the first live gate the planned identity is:

```text
dsv4-0731-r9e165c30-nvfp4-dspark-tp2-kv09
```

The value contains no prompt-derived data and is safe to log.  Block hashes and
KV payloads remain private.

## Generated connector configuration

The mode produces a `SimpleCPUOffloadConnector` configuration with:

- `kv_offload_backend=disk`;
- rank-local `/kv-offload/vllm-kv.slots.rank_N` files;
- bounded queue, transfer rows and store-event size;
- direct I/O by default;
- startup preallocation by default;
- `disk_persistence=true`;
- the validated cache identity;
- `lazy_offload=false`.

The launcher now prepares and verifies writable node-local roots for every
enabled offload mode, not only the historical filesystem mode.  The worker
receives the same normalized private env and uses its own root mount.

## Offline gates

```text
bash -n patches/kv-offload-config.sh \
  start-deepseek-v4-flash-dspark.sh \
  scripts/create-kv-offload-lab-env.sh \
  scripts/test-kv-offload-config.sh \
  scripts/test-create-kv-offload-lab-env.sh

bash scripts/test-kv-offload-config.sh
# RESULT: 24 passed, 0 failed

bash scripts/test-create-kv-offload-lab-env.sh
# KV offload lab env generator tests passed
```

The negative matrix includes missing identity, shell/JSON injection characters,
random hash seed, invalid capacity, queue, timeout, store bound, page-cache
flag and preallocation flag.

## Rollback and retention boundary

Changing the isolated lab profile to `KV_OFFLOAD_MODE=off` and recreating the
two containers prevents the connector from opening the persistent files.  It
does not delete them.  This makes rollback non-destructive and permits later
forensics or a return to the same compatible identity.

Deletion remains a separate explicit exact-path operation after both ranks are
stopped.  The coordinated purge gate and the full two-node restart A/B are
still required before promotion.
