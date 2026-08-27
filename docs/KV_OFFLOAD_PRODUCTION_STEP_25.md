# KV Offload Production Step 25: Coordinated persistent-cache purge

Date: 2026-08-27

## Scope

This step adds the explicit destructive operation that Step 23 and Step 24
left open.  Normal stop and `KV_OFFLOAD_MODE=off` rollback continue to preserve
persistent cache files.  Permanent removal is now a separate typed operation:

```text
scripts/purge-persistent-kv.sh
```

It targets only one named TP=2 Compose project, one confirmed cache identity,
two configured node-local roots, and the five fixed persistent artifacts.

## Fixed deletion set

```text
head:
  vllm-kv.slots.index
  vllm-kv.slots.rank_0.meta
  vllm-kv.slots.rank_0

worker:
  vllm-kv.slots.rank_1.meta
  vllm-kv.slots.rank_1
```

There is no wildcard, recursive removal, directory deletion or discovery by
prompt-derived hash.  Roots must be absolute, non-root, canonical directories
that do not traverse symlinks or contain Docker bind-option delimiters.

## Two-phase contract

The command defaults to dry-run.  Before the first deletion it requires all of
the following on both nodes:

1. passwordless bounded-time SSH to the worker;
2. zero running **or stopped** `vllm-dspark` containers for the exact Compose
   project;
3. canonical non-symlink cache roots, if the roots exist;
4. every existing target is a regular mode-0600, single-link file;
5. every readable manifest/index has the fixed magic, version, header digest
   and the exact `--confirm-identity` value;
6. the typed confirmation equals `KV_OFFLOAD_CACHE_IDENTITY` in the selected
   private env.

A valid but different metadata identity is never bypassed.  A separate
`--allow-unverified-metadata` flag exists only for recovery when metadata is
missing or corrupt; it cannot authorize deletion of a valid different cache.

Execution order is intentionally asymmetric:

1. remove and sync the head scheduler index;
2. remove and sync worker rank 1 manifest/data;
3. remove and sync head rank 0 manifest/data;
4. verify the exact artifact set is absent on both nodes.

Deleting the scheduler authority first means a later node/I/O failure can
leave orphan rank rows, but cannot leave a restart-visible cache hit.  The
command exits nonzero at the first failure and is safe to rerun.

## Invocation

Preflight only:

```bash
scripts/purge-persistent-kv.sh \
  --env-file .env.dspark \
  --project kv-offload-step23 \
  --confirm-identity dsv4-0731-r9e165c30-nvfp4-dspark-tp2-kv09
```

Deletion requires the additional explicit flag:

```bash
scripts/purge-persistent-kv.sh \
  --env-file .env.dspark \
  --project kv-offload-step23 \
  --confirm-identity dsv4-0731-r9e165c30-nvfp4-dspark-tp2-kv09 \
  --execute
```

An `off` rollback env may be used so an operator can disable the feature before
purging.  Other cache modes are rejected.

## Offline gates

`scripts/test-purge-persistent-kv.sh` has 11 CPU regression cases:

- dry-run performs both-node preflight and no deletion;
- scheduler-first exact execution ordering;
- a remaining exact-project container rejects before metadata access;
- both metadata preflights complete before deletion;
- worker-delete failure stops after scheduler invalidation;
- typed identity mismatch rejection;
- broad-root rejection;
- shell quoting for a root containing spaces;
- real fixed-header acceptance;
- valid different identity rejection even with recovery enabled;
- corrupt metadata requires the explicit recovery flag.

Results:

```text
scripts/test-purge-persistent-kv.sh
RESULT: 11 passed, 0 failed

scripts/ci-validate.sh
CI validate passed (CPU recipe gates only).
```

The tool and its test are included in the CI shell-syntax matrix and the test
is part of the normal CPU gate.

## Live fail-closed probes

The tool was deployed to the isolated `kv-offload-step23` project while both
TP ranks were healthy.  A dry-run attempt returned nonzero at the first head
container check:

```text
rc=1
refusing purge: head still has a container for project kv-offload-step23
```

The API remained healthy and all five artifacts remained present.  Qwen ASR
and Grafana were untouched.

The exact project was then stopped on both nodes without purging.  With zero
running/stopped project containers, the same dry run validated:

```text
head:   rank_0 data + rank_0 manifest + scheduler index
worker: rank_1 data + rank_1 manifest
result: both-node preflight passed
```

Thus both sides of the operational gate pass: a live service cannot be purged,
and a stopped compatible cache can be fully attested without modification.
The first real `--execute` deletion is reserved for the deliberate corruption
recovery drill in the next production step.

