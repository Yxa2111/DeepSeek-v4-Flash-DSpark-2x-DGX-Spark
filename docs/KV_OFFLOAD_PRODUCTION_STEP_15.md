# KV Offload Production Step 15: Synthetic-loop control

Date: 2026-08-27

## Observation

The long cancelled-concurrency run retained one 32,000-token request after
closing nine peers.  The survivor generated all 16,384 requested tokens in
199.23 seconds, returned `[DONE]`, and left zero running/waiting requests.

Its text was nevertheless degenerate: 16,378 of 16,381 parsed words were the
single token `z`.  The calibrated 8-gram detector reported a persistent loop
from about its 352-token position.

## Control

That result is not sufficient to blame cancellation.  The reproducer's
completion-mode prompt is random token IDs and deliberately sets
`temperature=0` plus `ignore_eos=true`.  A new concurrency-1 mode was added to
submit the exact deterministic prompt without any peer or cancellation.

The single-request control generated 4,096 tokens and independently collapsed
to the same shape:

- 4,092 of 4,094 parsed words were `z`;
- only `z`, `kappa`, and `rho` appeared;
- loop onset was again about token 351;
- the request completed normally and the server returned idle.

DSpark scheduling made the first few tokens nondeterministic, so the byte
prefix was not identical, but the collapse class and onset were.

## Conclusion

The random-token completion probe is valid for transport cancellation and
scheduler cleanup, but invalid as a causal reasoning-loop test.  It forces the
same degenerate continuation with concurrency 1.  Therefore:

- cancellation cleanup gate: pass;
- evidence that cancellation caused this synthetic loop: rejected;
- historical Agent reasoning-loop gate: still open;
- next test: coherent chat/code task, reasoning stream captured separately,
  concurrency-1 control versus 10-to-1 cancellation A/B.
