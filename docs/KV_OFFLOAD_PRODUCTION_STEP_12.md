# KV Offload Production Step 12: Live peer-stop proof

Date: 2026-08-27

## Live proof

Two disposable containers were created on the head and worker with only these
labels:

- Compose project `kv-offload-peer-probe`;
- Compose service `vllm-dspark`.

The head guard was forced through its numeric low-memory path for one sample
and pointed at the worker RoCE address.  It exited with the contractual status
42.  Both exact containers were stopped, head metadata recorded
`peer_stop_result=stopped_or_absent`, and the temporary containers were then
removed.  The concurrently running Qwen/Grafana projects were untouched.

This proves the SSH route, exact remote label selection and cross-node action,
not merely a fake-command unit path.

## Stop-result accuracy

Both probe containers ignored TERM until Docker's timeout and exited 137.
Docker still returned success from `docker stop`, so classifying success solely
from the CLI return code incorrectly called the outcome graceful.  The guard
now reads the exact container's persisted exit code:

- exit 137 after a successful stop request: `timed_kill`;
- another stopped exit: `graceful_stop`;
- explicit fallback `docker kill`: `forced_kill`.

The unit suite covers exit 137 independently.  This does not change which
container is targeted; it makes the durable incident record truthful.
