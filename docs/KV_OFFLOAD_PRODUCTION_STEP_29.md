# KV Offload Production Step 29: Continuously supervised TP guard

Date: 2026-08-27

## Scope

Step 28 proved the peer-loss circuit breaker in a manually launched live test.
This step makes that protection continuous on both DGX Spark nodes without
giving it model restart ownership.  The guard still has one responsibility:
observe typed local/peer container state plus numeric node reserve, then stop
the exact local TP rank when the failure threshold is reached.

No Azusa admission control was added.  The model launch, request scheduler,
KV cache, Qwen ASR and Grafana remain separate owners.

## Implementation

MiaAI commit `d5fcc74` adds:

- `run-kv-offload-guard-supervised.sh`, which creates a new private evidence
  directory for every guard process and holds a nonblocking per-project
  `flock` for the process lifetime;
- `install-kv-offload-guard-user-service.sh`, which installs immutable copies
  of the wrapper and guard plus a project-specific user-systemd unit;
- focused offline tests for exit-status propagation, unique evidence paths,
  symlink rejection, single-instance exclusion, strict unit generation and
  enable/restart commands;
- those tests in the normal CPU-only CI gate.

The wrapper owns `--output`; callers cannot redirect a supervised guard into
an arbitrary or shared path.  The evidence root must be absolute, nonsymlinked
and owned by the service user.  Directories are mode 0700 and the generated
unit is mode 0600.  Each guard exit writes its existing metadata and checksum
manifest before systemd starts a new process.

The unit uses:

```text
Restart=always
RestartSec=5
StartLimitIntervalSec=0
NoNewPrivileges=yes
PrivateTmp=yes
UMask=0077
```

The finite `43200` samples at a two-second interval intentionally rotate the
active evidence set once per day.  The installer does not delete older sets;
retention remains an explicit operational decision.

## Offline verification

The new focused suite passed, the existing node-guard suite passed unchanged,
and the complete CPU recipe gate passed:

```text
KV offload guard user-service tests passed
KV offload node guard tests passed
CI validate passed (CPU recipe gates only).
```

## Live installation

The unit `dspark-kv-peer-guard-kv-offload-step23.service` was enabled on both
nodes with user lingering already enabled.  No login session is therefore
required to keep the user manager alive.

| Setting | Head `192.168.2.168` | Worker `192.168.2.190` |
|---|---|---|
| Compose project | `kv-offload-step23` | `kv-offload-step23` |
| Peer | `192.168.2.190` | `192.168.2.168` |
| Evidence root | `.../step29-head` | `.../step29-worker` |
| Interval | 2 s | 2 s |
| Peer failures | 3 | 3 |
| Resource breaches | 3 | 3 |
| Daily samples | 43,200 | 43,200 |

The head user manager reported `degraded` before installation solely because
the unrelated `update-notifier-crash.service` was already failed.  The new
guard unit itself loaded as `active/running`, passed `systemd-analyze verify`,
and was enabled on both nodes.

Initial independent SSH checks observed 14 head samples and 15 worker samples.
Every retained row had:

```text
peer_state=running
peer_failure_count=0
action=none
```

Both exact model containers remained healthy with their pre-install uptime.
Qwen ASR and Grafana remained running on the head.

## Supervisor recovery injection

The main guard process on each node received `SIGTERM`; no model process or
container received a signal.  Both old runs completed their EXIT trap with:

```text
exit_status=130
trigger_reason=none
stop_result=not_attempted
last_peer_state=running
MANIFEST.sha256=valid
```

Five seconds later, systemd created a new guard process and a new unique
evidence directory on each node.  Both units then reported:

```text
ActiveState=active
SubState=running
NRestarts=1
```

The head model container remained `d84c1d8decc3`, the worker remained
`dc6591eb89a7`, and both retained their original uptime.  The head health
endpoint returned HTTP 200 after the supervisor restart.

## Ownership and operations

The guard deliberately does not start the model.  A safety or peer-loss trip
stops the exact local rank and leaves the complete TP recovery to the existing
two-node stop/start procedure.  The protected profile must use
`DSPARK_RESTART_POLICY=no`; otherwise Docker can race the fail-closed decision
by resurrecting an individual rank.

Useful read-only operations are:

```bash
systemctl --user status dspark-kv-peer-guard-kv-offload-step23.service
journalctl --user -u dspark-kv-peer-guard-kv-offload-step23.service
tail -f /home/yxa/kv-offload-lab/guard-supervised/step29-head/run-*/guard-samples.tsv
```

An intentional maintenance stop is:

```bash
systemctl --user disable --now dspark-kv-peer-guard-kv-offload-step23.service
```

Disabling the guard does not stop the model.  Conversely, stopping the model
does not make a local-absent guard kill or restart any service.

## Gate decision

The continuously supervised TP guard gate **passes**.  It is enabled and
running on both live nodes, survives its own process exit, retains independently
checksummed evidence, and does not mutate the serving TP group during guard
recovery.

The sustained concurrent request soak with the installed guards active was
run in [`KV_OFFLOAD_PRODUCTION_STEP_30.md`](KV_OFFLOAD_PRODUCTION_STEP_30.md).
The guards and persistent recovery passed, but the current unpaced
concurrency-2 hardware envelope failed and remains unqualified.
