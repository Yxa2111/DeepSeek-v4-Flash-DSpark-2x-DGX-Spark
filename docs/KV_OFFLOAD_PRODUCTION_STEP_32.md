# KV Offload Production Step 32: finite code-task cancellation A/B

Date: 2026-08-27

## Purpose

Step 16 proved that a coherent survivor kept making novel progress after a
10-to-1 cancellation burst, but both control and survivor exhausted their
8,192-token budgets before producing final content. This step makes
convergence observable by replacing that open-ended migration prompt with a
bounded Go implementation task and a fail-closed completion contract.

## Reproducer contract

Commit `3c10b8a` adds the `finite-code` profile to
`scripts/reproduce-cancelled-chat.py`. The existing migration profile remains
the default.

The finite task asks for a Go state-transition validator and table-driven
tests, fixes the required invariants and four output sections, caps the answer
at 1,400 words, and requires the literal terminal marker:

```text
FINITE_CODE_TASK_COMPLETE
```

The reproducer now fails unless a finite-code survivor has all of:

- successful curl/SSE completion and terminal `[DONE]`;
- `finish_reason=stop`, rather than a length cap;
- non-empty final content;
- the marker as the final non-whitespace text;
- zero final vLLM running and waiting gauges.

The focused parser/contract tests pass, and the complete CPU recipe validation
suite passes. Private reasoning and final traces are stored separately.

## Identical A/B profile

Both arms used the same lane-0 request:

```text
measured repository context: 17,593 tokens
full prompt:                 17,850 tokens
generation limit:            4,096 tokens
thinking:                     enabled, low effort
temperature / top_p:          0 / 1
```

The control launched only lane 0. The cancellation arm launched ten real curl
SSE clients, waited five seconds, sent termination to clients 1 through 9 so
their HTTP connections closed, and allowed the already-running lane 0 to
continue without reconnection or resubmission.

## Live result

| Measurement | Concurrency-1 control | 10-to-1 cancellation |
|---|---:|---:|
| Survivor return code | 0 | 0 |
| SSE `[DONE]` | yes | yes |
| Timed out | no | no |
| Finish reason | `stop` | `stop` |
| Completion contract | pass | pass |
| Prompt tokens | 17,850 | 17,850 |
| Completion tokens | 2,165 | 2,477 |
| Reasoning characters | 134 | 134 |
| Final characters | 6,882 | 8,338 |
| Wall time | 49.05 s | 46.63 s |
| Final running / waiting | 0 / 0 | 0 / 0 |

The short reasoning trace was byte-identical in both arms:

```text
d597a90a8a6605f5ff7b5564c80efcbfc5b9fab8a20c62c15eac08aab078d4c3
```

DSpark produced different final wording despite temperature zero, so final
byte equality is not claimed. Both outputs nevertheless had the same four
required sections, exactly two Go code blocks, one terminal marker, and no
persistent novelty collapse. The validator and generated table-driven tests
from each arm were extracted independently and both passed `go test`.

## Resource and service state

The continuously running guards sampled both arms every two seconds:

| Arm / node | Minimum `MemAvailable` | Peak exposed temperature |
|---|---:|---:|
| Control / head | 15,712,524 KiB | 83.0 C |
| Control / worker | 21,610,060 KiB | 66.0 C |
| 10-to-1 / head | 15,666,500 KiB | 88.2 C |
| 10-to-1 / worker | 21,586,816 KiB | 67.5 C |

All 57 guard samples across the combined window reported typed peer state
`running` and action `none`. The configured guard ceiling was 90 C. After the
test the fixed-image TP=2 service remained healthy, the API answered, and its
running/waiting gauges were zero. Qwen ASR and Grafana were untouched.

## Conclusion

Finite long-code-task convergence after a single 10-to-1 cancellation burst
**passes** for this case. The old survivor did not mechanically loop, did not
remain parked, and did not require a retry; it naturally reached final content
slightly faster than the concurrency-1 control.

This is not a proof that every Core Agent/tool task or every longer reasoning
trajectory converges. It does close the specific open gate left by Step 16:
the same coherent, bounded task now finishes on both sides of a real 10-to-1
HTTP cancellation A/B. No 30-minute soak was run in this step.
