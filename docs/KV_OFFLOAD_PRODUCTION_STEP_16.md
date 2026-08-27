# KV Offload Production Step 16: Coherent cancellation A/B

Date: 2026-08-27

## Purpose

The random-token completion probe in Step 15 established HTTP cancellation
and scheduler cleanup, but it made both the control and the survivor collapse
to repeated `z` tokens.  This step replaces it with a coherent chat/code task
and captures the reasoning stream separately from final-answer content.

The task asks for a finite production migration design for a synthetic Go
repository.  Its generated repository inventory measures 35,257 tokens; the
full request measures 35,474 prompt tokens.  Sampling is normal chat sampling
(`temperature=0.6`, `top_p=0.95`) with thinking enabled, rather than the
completion probe's deterministic random-token continuation.

## Reproducer

`scripts/reproduce-cancelled-chat.py` supports both sides of the A/B:

- concurrency 1: no peer request exists and no cancellation is sent;
- concurrency 10: ten real HTTP/SSE requests start, then clients 1-9 are
  terminated after five seconds while client 0 continues;
- survivor reasoning and final content are stored as separate private traces;
- the report records hashes, usage, finish reason, timeout/completion state,
  elapsed wall time, and final vLLM running/waiting gauges.

`scripts/test-reproduce-cancelled-chat.py` covers reasoning/content aliases,
finish reason, and streamed usage parsing.  `scripts/ci-validate.sh` compiles
both scripts and runs the parser test.

## Live A/B result

Both runs used the same model, generated repository context, 8,192-token
generation budget, and capped 2.0 GHz GPU clock.  The only intentional
difference was the 10-to-1 cancellation burst.

| Measurement | Concurrency-1 control | 10-to-1 cancellation |
|---|---:|---:|
| Survivor completed SSE (`[DONE]`) | yes | yes |
| Survivor timed out | no | no |
| Finish reason | `length` | `length` |
| Completion tokens | 8,192 | 8,192 |
| Reasoning characters | 33,452 | 33,650 |
| Final-answer characters | 0 | 0 |
| Wall time | 201.77 s | 196.41 s |
| Final running / waiting | 0 / 0 | 0 / 0 |
| Head peak exposed temperature | 87.4 C | 87.7 C |
| Worker peak exposed temperature | 77.4 C | 78.8 C |
| Head minimum `MemAvailable` | 16,017,052 KiB | 15,977,908 KiB |
| Worker minimum `MemAvailable` | 21,664,288 KiB | 21,659,616 KiB |

The calibrated reasoning detector classified both traces identically as a
heavy tail, not a repetition loop:

- rolling novelty stayed approximately 98-100 percent throughout;
- novelty never collapsed persistently;
- the traces kept producing new analysis until the generation limit.

Private raw reports and traces are under
`/home/yxa/kv-offload-private/live1/coherent-{control,cancel10}.*`; only their
measurements and hashes are represented by this tracked record.

## Conclusion and boundary

This coherent A/B did **not** reproduce cancellation-induced mechanical
looping.  Cancelling nine clients left exactly one request running, the
survivor continued making novel reasoning progress, returned a complete SSE
stream, and the scheduler converged to zero running/waiting requests.

It is not a proof that all long Agent tasks converge.  Both sides exhausted
the 8,192-token reasoning budget before producing final content, so this case
shows equivalent non-repeating progress rather than finite task completion.
Increasing the generation budget at the current 2.0 GHz cap is also not a safe
next move without more thermal margin: the head already reached 87.7 C against
the independent 88 C, three-consecutive-sample shutdown threshold.

Therefore the evidence status is:

- coherent 10-to-1 HTTP cancellation and cleanup: **pass**;
- cancellation-induced repetition in this A/B: **not reproduced**;
- finite long-task convergence: **not established**;
- historical Agent loop production gate: **still open**, requiring a retained
  real Agent trace or a thermally safer longer-budget test.
