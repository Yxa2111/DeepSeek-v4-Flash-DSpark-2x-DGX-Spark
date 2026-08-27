# KV Offload Production Step 09: Live thermal gate and stop-path repair

Date: 2026-08-27

## Scope

This step restarted the isolated `kv-offload-step08` TP=2 service after the
head node returned, established the smallest viable KV reservation, and ran
the first sustained long-prefill safety gate.  No production environment was
changed and unrelated Qwen/Grafana containers were left running.

## Startup result

`GPU_MEMORY_UTILIZATION_TEXT=0.72` failed closed during KV sizing: rank 1 had
4.02 GiB available while one 262,144-token request required 4.43 GiB.  The
smallest tested increment, `0.73`, started successfully:

- GPU KV cache: 337,477 tokens;
- maximum concurrency at 262,144 tokens: 1.29x;
- rank 0 available KV memory: 6.11 GiB;
- rank 1 available KV memory: 5.16 GiB;
- rank-local disk tier: 32.00 GiB and 32,140 slots on each node;
- initial settled `MemAvailable`: about 18.7 GiB head / 24.0 GiB worker.

The first deterministic 120,000-token cold request completed in 65.484 s TTFT
(about 1,833 prompt tokens/s) and returned HTTP 200.

## Safety-gate result

During the second consecutive 120,000-token cold prefill, the head thermal
sensor reported 90.8, 90.8, then 90.9 degrees C at two-second intervals.  The
numeric guard emitted `trigger_high_temperature` and stopped the exact rank-0
container before the host became unresponsive.  At the trigger, head
`MemAvailable` remained about 15.4 GiB, so this was a thermal gate, not the
12-GiB low-memory gate.  Rank 1 was then stopped explicitly.

Conclusion: `0.73` is a viable boot setting but is **not promoted** for
continuous long-prefill service under the current cooling conditions.  A
restore or soak result collected without a coordinated thermal guard would not
be production evidence.

## Stop-path defect and repair

The failed-start cleanup exposed a deterministic shell bug.  When no
`vllm_offload_*.mmap` descriptor existed, `capture_project_mmaps` still read one
empty record from `printf`.  Its short-circuit expression returned status 1;
under `set -e` that aborted the stop before either rank was removed.

The capture loops now use an explicit `if`, for which an empty capture is a
successful no-op.  The regression test exports a fake Docker command into the
capture subshell and verifies that zero mmap paths do not abort cleanup.  The
stop cleanup test is also part of `scripts/ci-validate.sh` now.

## Gate status

- TP=2 0.73 boot: pass;
- NVMe backend initialization on both ranks: pass;
- one 120K cold request: pass;
- sustained thermal gate: fail safely;
- cold/evict/disk-restore proof: pending;
- promotion: blocked pending coordinated peer shutdown and cooler live test.
