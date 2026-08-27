# KV Offload Production Step 28: Live TP peer-loss convergence

Date: 2026-08-27

## Scope

Step 27 proved that a fatal head-side KV load failure leaves the remote TP
worker container alive.  This step exercises the typed peer-loss circuit
breaker implemented in Step 17 against the live two-node persistent profile.
The target is bounded process convergence, not request admission control.

The test used only the isolated `kv-offload-step23` Compose project.  The
freshly rebuilt persistent cache, Qwen ASR and Grafana were retained.

## Guard profile

One existing node guard ran on each Spark with:

```text
project=kv-offload-step23
peer_check_consecutive=3
interval_seconds=2
peer selected by exact Compose project and service labels
```

The remote query uses bounded, non-interactive SSH and returns typed states.
It does not parse Docker logs, API text, model output or natural language.
Both guards first recorded at least three `running` peer samples, proving that
the negative test did not begin from an already degraded cluster.

## Fault injection

The worker's single exact `vllm-dspark` container was resolved by both project
and service labels, then stopped with Docker's bounded graceful-stop command.
No head, Qwen, Grafana or unrelated container was selected by the injection.

The worker-side guard observed that its own exact container was absent and
reported `local_absent`.  It reset the peer counter and took no second action,
which is the intended launch/maintenance-safe behavior.

## Head convergence

The head guard retained this sequence:

| UTC | Peer state | Consecutive failures | Action |
|---|---|---:|---|
| 13:31:51 | `running` | 0 | none |
| 13:31:53 | `absent` | 1 | none |
| 13:31:55 | `absent` | 2 | none |
| 13:31:58 | `absent` | 3 | `trigger_peer_unavailable` |

Its final typed result was:

```text
exit_status=42
trigger_reason=peer_unavailable
stop_result=graceful_stop
last_peer_state=absent
peer_stop_result=skipped_peer_unavailable
```

Thus the surviving rank stopped about five seconds after the first typed peer
absence.  It did not keep model memory allocated or continue a TCPStore error
loop.  The failed peer path was not reused to claim a redundant remote stop.

## State preservation and recovery

After both ranks had stopped:

- the API was unavailable, as required for a failed TP group;
- Qwen ASR and Grafana were still running;
- all five persistent KV files retained their original sizes, mode 0600 and
  one link;
- the normal exact-project stop command removed the two stopped containers;
- no purge ran.

The normal start path then recreated the TP group.  The scheduler logged:

```text
Restored 384 committed persistent KV slots
```

Both containers became healthy and the launcher's minimal inference passed.
A deterministic 64K replay through the corrected benchmark produced:

| Measurement | Result |
|---|---:|
| External KV tokens | 45,056 |
| Locally computed tokens | 18,944 |
| TTFT | 14.353 s |
| Prompt tokens | 64,000 |
| Completion tokens | 1 |
| Finish reason | `length` |

The prompt and completion SHA-256 values matched the Step 27 cold baseline.
The smaller external prefix than the earlier 53,248-token campaign is
consistent with the post-purge cache containing only one completed A store and
384 scheduler rows; it is not a corruption or recovery mismatch.

## Gate decision

The live TP peer-loss circuit-breaker gate **passes**.  With guards active on
both nodes, stopping either exact rank causes its survivor to fail closed in a
bounded interval, while normal local absence is not treated as a peer fault.
The complete group can then restart from its persistent cache.

The remaining deployment gap is operational: the guards must be installed as
continuously supervised services rather than launched manually for a test.
The sustained concurrency stability gate also remains separate.
