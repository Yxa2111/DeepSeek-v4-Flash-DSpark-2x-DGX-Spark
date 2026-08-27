# KV Offload Production Step 11: Failed-start convergence

Date: 2026-08-27

## Trigger

At `GPU_MEMORY_UTILIZATION_TEXT=0.72`, rank 1 had only 4.02 GiB available for
KV while the 262,144-token startup contract required 4.43 GiB.  vLLM correctly
rejected the configuration, but rank 0 exited first and rank 1 remained alive,
emitting repeated TCPStore broken-pipe errors.  The launcher continued polling
until it was interrupted manually.

## Change

The launcher now checks, after every failed API probe, that both the head and
worker each have exactly one running container selected by exact Compose
project and service labels.  A missing or ambiguous rank is an immediate
startup failure.

The existing ERR path now preserves the original failure status, prints both
ranks' startup logs, and calls the normal two-node stop script with the legacy
project sweep pinned to the same exact project.  This reuses its bounded rank
stop and exact KV mmap/slot cleanup.  API timeout uses the same convergence path
instead of leaving ranks behind.

## Expected behavior

For a future asymmetric capacity failure:

1. the first poll after one rank exits detects the split state;
2. recent logs from both nodes are emitted once;
3. both exact project containers are removed;
4. only captured mmap files and the two exact rank slot files are removed;
5. the launcher returns the original nonzero startup status.

This closes the observed failure mode without adding a service restart loop or
touching unrelated Docker projects.
