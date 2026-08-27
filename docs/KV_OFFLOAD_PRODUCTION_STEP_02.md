# Production KV offload Step 02: runtime integration

Date: 2026-08-27
Runtime branch: `Yxa2111/dspark-vllm-gx10:experiment/packed-kv-offload-tp2`
Deployment branch: `experiment/nvme-kv-offload`

## Outcome

MiaAI can start an image whose core coordinator already contains the typed
DSpark ephemeral-group contract. The issue-26 hybrid-SWA startup hotfix now
recognizes that exact implementation as a safe built-in superset and leaves it
unchanged. Legacy stock and issue-26-v1 images retain the existing annotate or
revert behavior; unknown/partial implementations still fail closed.

This compatibility change does not enable KV offload by default and does not
promote the experimental image to production.

## Integration conflict and resolution

The first two-node start exited cleanly with code 1 on both nodes:

```text
hybrid min-hit assign anchor not found; refusing to patch
```

That was expected fail-closed behavior against an unknown coordinator shape,
but the new runtime shape is known: it preserves issue-26-v2's invariant that
every stable/SWA group may reduce `curr_hit_length`; only a typed DSpark draft
group may skip an exact zero-hit veto.

`patches/hotfix-dsv4-issue26-hybrid-swa-min.py` now recognizes the complete
production block, including the stable `curr_hit_length` assignment. It prints:

```text
[issue26-hotfix-v2] safely superseded by production contract
```

and performs no rewrite. Matching only the exemption condition or marker is
insufficient; the script continues to reject partial shapes.

## Tests

`scripts/test-issue26-swa-min-v2.py` now has six cases:

- revert issue-26-v1;
- annotate pinned stock;
- idempotent issue-26-v2;
- accept the complete production ephemeral contract without mutation;
- reject a partial ephemeral marker;
- document that v1 skipped the stable/SWA shrink.

Result:

```text
Ran 6 tests in 0.002s
OK
```

The second two-node start passed entrypoint integration on both ranks, reached
the OpenAI-compatible API, and completed a minimal chat request. Runtime group
semantics and their nine image-level tests are documented in the Anemll
Step-02 record.

## Findings deferred to later steps

The 9.5K boot long-chunk arm took 256 seconds and created enough unified-memory
and swap pressure to make the head's user-space services temporarily
unresponsive. The warmup summary was not accepted as a pass.

Inspection also showed that every worker-side B/C/D/E/F filesystem cache root
contained zero files. The pinned runtime coordinates CPU staging via host-local
`/dev/shm` and selects local CUDA device index as a slot rank; on two one-GPU
nodes that is rank 0 on both hosts. Filesystem persistence is scheduler/head
owned. Therefore the current path has no certified TP1 cross-restart payload
and must not be used as a production two-node cache.

Step 03 will close request cancellation/deferred cleanup. Step 04 must provide
global-rank, per-node staging and bounded transfers before the restart benchmark
is considered a correctness gate.
