# KV offload production Step 08 - DGX Spark node reserve guard

Date: 2026-08-27

State: implementation and CPU-only validation complete. Live threshold and
two-node convergence validation are next.

## Purpose and ownership

Step 07 found only about 5.5 GiB `MemAvailable`, active swap traffic, and
driver `NV_ERR_NO_MEMORY` messages before the head became unresponsive. The
correct containment layer is the DGX Spark node because CPU, GPU, CUDA
workspace, model weights, and KV all share the same 128-GB physical pool.

This step does **not** add Azusa admission control. vLLM/Anemll still owns
request scheduling, KV eviction, and transfer backpressure. The new script is a
last-resort host circuit breaker for the disposable canary: it acts only on
numeric kernel/thermal state and stops only the exact Compose project
container.

## Changes

MiaAI commit `004487b` adds three complementary protections.

### Safer lab allocation

Newly generated private lab profiles now start at:

```text
GPU_MEMORY_UTILIZATION_TEXT=0.72
DSPARK_OOM_SCORE_ADJ=800
DSPARK_RESTART_POLICY=no
```

The old 0.80 lab default was not itself the failed value—the recovered run had
an effective 0.81—but it was too close to claim a 12-GiB host reserve without
measurement. `0.72` is a conservative discovery point. It may be promoted only
after both loaded nodes have settled above the reserve gate. The production
env and Compose default remain unchanged: normal deployments still use
`oom_score_adj=0`, and KV offload remains off.

A positive OOM score makes the disposable vLLM container a better kernel OOM
victim than host daemons. It cannot prevent firmware thermal shutdown or a GPU
driver/UVM livelock, so it is secondary to the proactive reserve guard.

### Fsync-backed evidence

`sample-kv-offload-telemetry.sh` now calls `sync -d` after its header and every
sample. Each row has 22 fields and adds:

- GPU temperature;
- GPU utilization;
- GPU power draw;
- SM clock;

to the existing host `MemAvailable`, swap, memory PSI, exact container cgroup
memory/OOM, block-I/O counters, and maximum exposed ACPI thermal-zone value.
The NVIDIA query is bounded by a three-second timeout and leaves fields empty
instead of stalling the sampler if the driver is unavailable.

### Exact-project circuit breaker

`guard-kv-offload-node.sh` defaults to:

| Gate | Default |
|---|---:|
| minimum `MemAvailable` | 12,582,912 KiB (12 GiB) |
| maximum exposed thermal-zone value | 90,000 milli-Celsius |
| consecutive breaches | 3 |
| sample interval | 2 s |
| graceful Docker stop timeout | 20 s |
| finite sample count | 1,800 |

Memory and temperature have independent consecutive counters. A recovered
sample resets only its corresponding counter. Missing temperature sensors do
not create a false high-temperature event; missing or nonnumeric
`MemAvailable` fails the guard as a configuration/observability error.

Container discovery is restricted to one validated hexadecimal ID matching
both the Compose project label and the expected service name. Multiple matches
fail closed. On a persistent breach, the guard:

1. fsyncs the triggering row and action record;
2. gracefully stops that exact ID;
3. if and only if graceful stop fails, kills that exact ID;
4. verifies Docker reports it not running;
5. exits 42 with structured `trigger_reason` and `stop_result` metadata.

If the reserve is already unsafe before the project container appears, the
guard records the trigger and exits 42 without mutating any unrelated service.
Configuration or stop failures use other nonzero statuses, so orchestration
does not confuse a safety trip with an implementation error.

The guard never restarts the project. With `DSPARK_RESTART_POLICY=no`, a
stopped rank remains stopped. The peer rank should converge when TP disconnects;
the external controller must still run the existing exact two-node stop path
before a later restart.

## Two-node launch sequence

Start one telemetry sampler and one guard independently on each node before
starting the canary. Use new private output directories on every run. For a
24-hour maximum window at a two-second interval:

```bash
./scripts/sample-kv-offload-telemetry.sh \
  --output /home/yxa/kv-offload-lab/telemetry/step08-head \
  --project kv-offload-step08 \
  --interval 2 \
  --samples 43200

./scripts/guard-kv-offload-node.sh \
  --output /home/yxa/kv-offload-lab/guard/step08-head \
  --project kv-offload-step08 \
  --interval 2 \
  --samples 43200 \
  --min-available-kib 12582912 \
  --max-temp-millic 90000 \
  --consecutive 3
```

The worker uses separate `step08-worker` directories. These commands are shown
in the foreground intentionally; deployment orchestration may supervise them,
but must preserve their exit status and private artifacts rather than hiding
them behind an untracked background shell.

After model load and warmup, the run is accepted for restore testing only when
both nodes remain above 12 GiB for a settled observation window, neither guard
has exited, swap is not steadily growing, and there is no new NVRM allocation
failure. If 0.72 does not leave that reserve, lower utilization again; do not
weaken the reserve to make the model fit.

The 90 C gate is deliberately below public reports of hidden package sensors
crossing the mid-90s before protective shutdown. Exposed ACPI zones may not
equal the field diagnostic's hidden hotspot, so passing this guard is not a
substitute for NVIDIA PowerStress and ThermalStress.

## Verification

Focused gates:

```text
test-guard-kv-offload-node.sh:        passed
test-sample-kv-offload-telemetry.sh:  passed (22 columns)
test-create-kv-offload-lab-env.sh:    passed
docker compose oom_score_adj render:  800
git diff --check:                     passed
```

The guard test proves a two-sample low-memory trigger, exact ID graceful stop,
no unnecessary kill, exit 42, private manifest integrity, a safe no-container
run, and fail-closed multiple-container selection. The full CPU recipe suite
also passed after adding both new scripts to CI:

```text
CI validate passed (CPU recipe gates only)
```

## Remaining live gates

1. Build and identify the bounded-work image on the recovered head.
2. Exercise the guard against a disposable benign container on each node and
   verify exact local stop plus TP peer convergence.
3. Load the model at 0.72 with both telemetry streams and guards already live;
   record settled reserve and the actual GPU KV capacity.
4. Prove disk restore with the smallest eviction shape allowed by that capacity.
5. Pass cancellation, live ENOSPC/checksum, field diagnostic, soak, and rollback
   gates before any production canary.
