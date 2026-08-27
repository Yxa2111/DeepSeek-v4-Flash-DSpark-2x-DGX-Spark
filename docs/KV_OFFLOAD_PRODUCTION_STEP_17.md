# KV Offload Production Step 17: TP peer-loss circuit breaker

Date: 2026-08-27

State: implementation and CPU-only fault tests complete.  Live two-node fault
injection is the next independent step.

## Gap

The existing node guard owns numeric UMA-memory and exposed-temperature
containment.  When either threshold trips, it stops the exact local Compose
container and asks the peer node to stop the matching rank.  It did not detect
the inverse failure: a worker container or peer node could disappear first
while the local TP rank remained allocated and unusable.

TP=2 is one failure domain.  A single surviving rank cannot serve requests,
can retain most model memory, and may spin on transport errors.  This is a
deployment-layer liveness invariant, not request/session admission control.

## Change

`guard-kv-offload-node.sh` adds the opt-in setting:

```text
--peer-check-consecutive COUNT
```

Zero, the default, preserves prior behavior.  A positive value requires
`--peer-host`.  While the exact local project/service container is running,
each sample performs a bounded non-interactive SSH query for the peer container
using the same exact Compose project and service labels.  The typed result is
one of:

- `running`;
- `absent`;
- `multiple`;
- `invalid`;
- `unreachable`;
- `local_absent` when there is no local rank to protect.

Only `running` resets the peer-failure counter.  A configured number of
consecutive non-running results triggers `peer_unavailable`, fsyncs the sample,
stops the exact local container, verifies it is no longer running, and exits
42.  It deliberately does not attempt a second peer stop through the already
failed peer path; metadata records `peer_stop_result=skipped_peer_unavailable`.
With a guard on both nodes, either side of a network partition independently
fails closed locally.

The remote query is bounded by a six-second outer timeout, three-second SSH
connect timeout, one connection attempt, and `BatchMode=yes`.  Project and host
values retain their existing strict validation.  The peer check is skipped and
its counter reset until a local exact container exists, which lets guards start
before the TP service without treating normal launch ordering as a failure.

Every sample now retains `peer_state` and `peer_failure_count`; final metadata
retains the configured threshold and last state.  Memory and temperature keep
their independent counters and higher action priority.

## Offline fault tests

The fake Docker/SSH suite proves:

1. two consecutive unreachable peer checks stop only the exact local ID;
2. the action is typed as `peer_unavailable` and exits 42;
3. the failed peer path is not reused for a misleading coordinated-stop claim;
4. one transient SSH failure followed by `running` resets the counter and does
   not stop anything;
5. a positive peer threshold without a peer host is rejected;
6. all previous low-memory, timed-kill, safe/no-container, multiple-container,
   and peer-stop tests still pass.

Focused result:

```text
KV offload node guard tests passed
```

## Live acceptance

Run new guards on both nodes with `--peer-check-consecutive 3`, then stop only
the worker's exact canary container.  Accept only if:

- the head records three typed peer failures and exits 42;
- the head exact canary container stops within the bounded window;
- no Qwen, Grafana, or other Compose project changes state;
- both ranks can subsequently be cleaned and restarted through the normal
  exact-project path;
- the restarted service passes health and a small inference request.
