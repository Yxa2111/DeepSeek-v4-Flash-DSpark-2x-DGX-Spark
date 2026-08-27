# KV Offload Production Step 10: Coordinated TP safety stop

Date: 2026-08-27

## Trigger

The Step 09 thermal guard correctly stopped rank 0 at 90.9 degrees C, but rank
1 remained alive and emitted one TCPStore broken-pipe traceback per second.  A
TP service is one failure domain: leaving the peer alive wastes power, keeps
memory allocated, delays cooling, and can make a failed startup or safety trip
look like a partially healthy service.

## Change

`guard-kv-offload-node.sh` now accepts an optional `--peer-host`.  After the
local exact container is stopped, the guard uses non-interactive, bounded SSH
to stop the peer container selected by both exact Compose project and exact
Compose service labels.  It validates the project, peer host and container ID;
more than one match fails closed.  A graceful stop has bounded time and falls
back to killing only that exact container.

The guard metadata records both `stop_result` and `peer_stop_result`.  A local
or peer stop failure makes the guard exit with an operational error rather than
claiming a successful safety trigger.  Docker's current `--timeout` spelling
replaces the deprecated `--time` option.

This remains a node-level numeric circuit breaker.  It is not Azusa admission
control and does not inspect requests, sessions or natural-language state.

## Tests

The fake-Docker guard test now also supplies a fake SSH binary and verifies:

- exact project/service label selection on the peer;
- the expected bounded `docker stop --timeout` command;
- persisted successful peer result;
- rejection of a peer value that could be parsed as an SSH option.

The live Step 09 trip is the evidence that peer coordination is necessary; a
second live trip will verify the new cross-node action before promotion.
