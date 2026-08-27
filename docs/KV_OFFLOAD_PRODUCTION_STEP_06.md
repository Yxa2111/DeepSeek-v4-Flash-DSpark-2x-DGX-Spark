# KV offload production Step 06 - lifecycle, rollback, and acceptance

Date: 2026-08-27

State: in progress. Exact forced-stop cleanup is implemented and tested;
postmortem, NVMe-restore proof, and soak gates are blocked until the head node
returns.

## Lifecycle problem

The runtime unlinks its local slot file during orderly shutdown. A forced
container removal cannot execute that Python cleanup and can leave a
root-owned 32-160 GiB preallocated file. The older generic offload path can
also leave a root-owned named mmap in host IPC. Blind cleanup such as
`rm /dev/shm/vllm_offload_*` is not acceptable because another service or
experiment may own a matching object.

MiaAI commit `232b6f0` makes stop cleanup exact:

1. Before removing a project container, inspect that running container's open
   file descriptors.
2. Accept only canonical
   `/dev/shm/vllm_offload_[A-Za-z0-9._-]+.mmap` targets and de-duplicate them
   per node.
3. Stop both TP ranks and sweep the exact Compose project.
4. Through host IPC, remove only the mmap paths captured in step 1.
5. In `nvme-local` mode, bind only the validated configured root and remove
   exactly `vllm-kv.slots.rank_0` on the head and
   `vllm-kv.slots.rank_1` on the worker.
6. Any worker, capture, or cleanup failure increments the stop failure count;
   the command exits nonzero rather than reporting a clean stop.

Roots must be absolute and cannot contain newline, carriage return, colon, or
comma. Missing roots and missing exact files are idempotent no-ops. Cleanup
never uses a wildcard for deletion.

MiaAI commit `d2a36da` adds a read-only recovery collector. It deliberately
does not start, stop, restart, delete, or inspect container environment values.
It records previous-boot kernel/warning/Docker/network journals, reboot history,
current memory/swap/PSI, storage, network, thermal, NVIDIA/NVMe visibility,
failed units, coredumps, limited Compose state, and bounded old container logs.
The private output is mode 700 with mode-600 files and a SHA-256 manifest; raw
journals/logs must be reviewed for prompt or secret content before anything is
copied into git.

MiaAI commit `74eb59b` makes newly generated lab profiles use
`GPU_MEMORY_UTILIZATION_TEXT=0.80` instead of inheriting the 0.835 text-serving
default. The value is validated as a decimal strictly between zero and one.
`0.80` is already supported by this recipe's vision-coexistence profile; here
it provides more UMA reserve and a smaller GPU-prefix pool, so the first real
disk-restore proof can force eviction with less total context pressure. It does
not change the production env.

Anemll commit `0260ffa` and MiaAI commit `c2c6ae5` close the remaining
unbounded-work path. The runtime now caps each store event at 64 packed rows,
keeps at most two queued events per load/store direction, and waits at most 30
seconds for queue space before failing the engine explicitly. With the live
roughly 1 MiB packed row, one active store, two queued stores, and one blocked
enqueue retain at most about 260 MiB/rank before timeout, rather than growing
with prompt count. The launcher validates all three ranges and passes real JSON
numbers into the connector. These are runtime/deployment data-plane bounds,
not Azusa request admission control.

Run it on the recovered head before restarting the project:

```bash
./scripts/collect-kv-offload-postmortem.sh \
  --output /home/yxa/kv-offload-lab/postmortem/step05-head-$(date +%Y%m%dT%H%M%S) \
  --boot -1 \
  --project kv-offload-step05
```

## Deterministic cleanup gate

`scripts/test-stop-kv-offload-cleanup.sh` sources the guarded stop script with
mocked Docker/SSH endpoints and verifies:

- canonical mmap acceptance and traversal/deleted-suffix rejection;
- safe root validation and bind-option injection rejection;
- exact per-node path de-duplication;
- head and worker rank-specific slot filenames;
- no destructive wildcard in any emitted removal command;
- fail-closed behavior before Docker when the root is unsafe.

Result:

```text
test-stop-kv-offload-cleanup.sh:   13 passed, 0 failed
test-collect-kv-offload-postmortem.sh: passed
test-kv-offload-config.sh:         20 passed, 0 failed
test-create-kv-offload-lab-env.sh: passed
bash syntax checks:                passed
git diff --check:                  passed
```

The exact seven-patch worker image also passed seven backend cases plus one
bounded-and-resumable scheduler case (`8 passed`). A four-block store was split
into two events of two rows without losing the deferred blocks.

During Step 05, one stale generic mmap was removed manually only after the
owning service had stopped:

```text
/dev/shm/vllm_offload_1787798233982470445.mmap
535,638,016 bytes
```

It was ephemeral staging and is not recoverable or a restart-persistent prefix
object. This exact cleanup motivated the automated capture-before-stop rule.

## Rollback

Rollback does not require an image rebuild:

1. stop the dedicated project with
   `stop-deepseek-v4-flash-dspark.sh` so both ranks and exact ephemeral files
   converge;
2. set `KV_OFFLOAD_MODE=off` in the private deployment env;
3. restart the existing stable image/profile;
4. verify `/health`, model identity, both TP ranks, running/waiting metrics,
   and absence of old project containers.

The new slot backend is process-lifetime state, so deleting its exact rank
files loses no durable session store. Generic `fs-rank0` `.bin` prefix objects
are a different experimental tier and are not deleted by this rollback.

## Remaining acceptance gates

1. Recover the head without starting the experiment and archive
   `journalctl -b -1 -k`, previous-boot warnings, `last -x`, NVRM/Xid, OOM,
   thermal, watchdog, PCIe, filesystem, and old container evidence.
2. Correct the confirmed failure mechanism before further high-pressure runs.
3. Start a new isolated lab project at 0.80 utilization and record its actual
   KV token capacity before choosing prompt sizes. Force eviction with the
   smallest contexts that exceed that pool, while sampling memory, swap,
   temperature, GPU, disk-I/O, and kernel telemetry throughout. Do not begin by
   repeating the 4x250K pressure shape.
4. Prove a real disk load after that bounded GPU-prefix eviction: increased disk read bytes,
   a connector load/hit, lower TTFT than cold prefill, and identical
   target-only output under deterministic settings.
5. Repeat the ten-client cancel-nine survivor shape across short, 100K, and
   250K prompts; require all request, transfer, staging, and scheduler gauges to
   return to baseline after every round.
6. Run a bounded 24-hour mixed prefill/decode/cancel soak with ENOSPC and
   checksum fault injection. Any I/O failure must surface as a terminal engine
   failure, never an indefinitely pending request.
7. Re-run the full pinned scheduler/tiering regression tree with a local model
   fixture rather than network-backed model metadata.
8. Only then enable `nvme-local` for a production canary; `off` remains the
   default until the canary and rollback drill pass.

No Azusa Core change is included. The acceptance problem is currently within
vLLM/Anemll and the two-node deployment lifecycle.
