# KV Offload Production Step 14: Cancelled-concurrency gate

Date: 2026-08-27

## Live result

The existing cancellation reproducer opened ten real streaming HTTP clients
against the TP=2 NVMe service.  Each submitted an 8,192-token prompt and asked
for 512 generated tokens.  After five seconds, clients 1 through 9 were sent
TERM, which closes their HTTP connections; client 0 was retained as the old
surviving request.

The survivor completed normally in 20.315 seconds, emitted the SSE `[DONE]`
frame, did not time out, and curl returned 0.  Ten seconds after completion,
both `num_requests_running` and `num_requests_waiting` were zero.  The API and
both guards remained healthy.  This passes the short form of the reported
"cancel a concurrency burst, old request keeps running" scenario.

It does not by itself clear the historical reasoning-loop report: 512 output
tokens is below the calibrated loop onsets.  A longer survivor must be judged
from its generated text, not just its return code.

## Instrumentation change

`reproduce-cancelled-concurrency.py` now parses the survivor's completion SSE
and records its text hash, character count, finish reason and usage without
putting the text into the JSON summary.  `--survivor-trace` optionally writes
the synthetic survivor text to a private file so `loop_detector.py` can judge
long runs.  Unit tests cover SSE text, finish-reason and usage extraction.

Raw live output remains under `/home/yxa/kv-offload-private/live1` and is not
committed.
