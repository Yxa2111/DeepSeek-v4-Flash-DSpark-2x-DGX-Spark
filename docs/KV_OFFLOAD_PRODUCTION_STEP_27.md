# KV Offload Production Step 27: Rank corruption, purge and clean rebuild

Date: 2026-08-27

## Scope

This step closes the supervised persistent-storage fault gate left by Step 26.
It selects one disk slot that is provably part of the existing deterministic
64K prefix, changes exactly one byte on worker rank 1, proves that the runtime
rejects the payload checksum during a real load, executes the coordinated
five-file purge from Step 25, and proves a clean full recomputation.

The isolated Compose project was `kv-offload-step23`.  The model image,
revision, TP=2 geometry, fixed hash seed and cache identity were unchanged.
Qwen ASR and Grafana remained outside the project.

## Deterministic slot selection

The scheduler index header was parsed without printing cache hashes or prompt
content.  Its live geometry was:

```text
group block sizes: 256, 64, 64, 4, 8
hash block size:   4
scheduler block:   256
committed slots:   2002
hash length:       36 bytes including group ID
PYTHONHASHSEED:    0
```

Request A was regenerated through the service tokenizer with the same 64,000
token size and seed.  The runtime image's own SHA-256 chain-hash code mapped
the group-0 prefix continuously through 57,088 tokens.  The 32,768-token
boundary mapped to slot 257, so the fault target was part of the actual A
load rather than a random committed row.

Worker rank 1's manifest independently confirmed that slot 257 was committed,
its fixed metadata-record CRC was valid, and the data and metadata files were
private regular files with mode 0600 and one link.  The packed geometry was:

```text
logical payload bytes: 1,065,792
aligned slot bytes:    1,069,056
```

The runtime checksums the complete aligned slot, including its tail padding.
An initial read-only diagnostic that checked only logical payload bytes was
therefore rejected as an invalid test assumption.  Rechecking four committed
slots with the runtime's complete aligned range passed before mutation.

## One-byte fault injection

The exact Compose project was stopped on both nodes first; zero running or
stopped project containers were present.  Persistent files remained intact.
A capability-dropped, network-disabled container then opened only the worker
cache root and changed one byte at relative offset 4,096 in slot 257:

```text
slot:                    257
absolute file offset:    274,751,488
checksum matched before: yes
byte changed and fsynced: yes
checksum mismatched after: yes
manifest record unchanged: yes
```

No metadata, scheduler index, rank-0 payload or other slot was modified.

## Live checksum rejection

The service started normally under the same valid identity.  Both workers
opened their persistent files, the scheduler restored 2,002 committed slots,
and the API became ready.  This is expected: payload CRCs are checked on load,
not by scanning the 32-GiB files at startup.

The first replay of A selected 53,248 external tokens.  Worker rank 1 then
failed load event 0 with:

```text
KV disk checksum mismatch for slot 257
```

The error propagated through the worker, multiprocess executor and EngineCore
as a failed KV disk load event.  No completion text, finish reason, usage
record or SSE `[DONE]` was returned.  The head API became unavailable instead
of consuming the corrupt KV or producing model output.  This proves
fail-closed payload handling on the real TP=2 packed path.

The head container exited, while the remote worker container remained alive
and emitted TCPStore peer-loss diagnostics until the exact two-node stop
command removed it.  Runtime peer convergence is therefore a separate open
production item; checksum rejection itself passed.

## Benchmark false-green correction

The replay also exposed a test-harness defect.  The previous
`benchmark-kv-offload.py` treated a clean HTTP-200 stream EOF as success even
when the engine died before sending a completion.  Its private report showed
an empty completion, empty usage and no finish reason despite exit status 0.

Commit `8bdaf9d` changes the benchmark to require all of:

- at least one choice event;
- a non-empty finish reason;
- prompt, completion and total token usage;
- the terminal SSE `[DONE]` marker.

Premature EOF now raises an error.  Five focused unit tests pass, including
the exact EOF-before-`[DONE]` regression and a complete-stream control.  The
entire CPU recipe validation suite also passes.  The corrected client then
accepted the later clean live recomputation only after a complete terminal
stream and typed usage were present.

## Coordinated purge

After the checksum failure, the exact project was stopped on both nodes.  The
purge dry-run accepted the five fixed artifacts, private-file invariants and
the exact compatibility identity.  The execute phase then removed, in order:

1. head scheduler index;
2. worker rank-1 manifest and payload;
3. head rank-0 manifest and payload.

Both roots were checked afterward and all five files were absent.  Removing
the scheduler authority first guarantees that an interrupted purge cannot
leave a restart-visible prefix.  The deleted KV is intentionally not
recoverable except by model recomputation; model weights and deployment
configuration were untouched.

## Empty restart and clean recomputation

The same persistent profile recreated five new files.  Before the 64K test:

| Durable object | Committed records |
|---|---:|
| scheduler index | 0 |
| rank-0 manifest | 0 |
| rank-1 manifest | 0 |

All metadata files had mode 0600 and one link.  Startup contained zero
`Restored ... committed persistent KV slots` messages.

Request A then completed through the corrected benchmark:

| Measurement | Original cold A | Post-purge clean A |
|---|---:|---:|
| Prompt tokens | 64,000 | 64,000 |
| TTFT | 33.905 s | 33.812 s |
| External KV tokens | 0 | 0 |
| Computed prefill tokens | 64,000 | 64,000 |
| Finish reason | `length` | `length` |
| Completion tokens | 1 | 1 |

The prompt SHA-256 remained:

```text
8437f4c38ec62d4a0776adab76686fc994eee69b28a3d741d8f5ba28d5bd6059
```

The deterministic completion SHA-256 also remained:

```text
4c6773e331ed318097c14680de92d192dfdac3c0d7cc3114c020b0014d8a6ff6
```

After the store settled, the rebuilt scheduler contained 384 committed rows
and both rank manifests contained 448 rows.  The API remained healthy.

## Safety observations

During the empty restart and clean recomputation:

- head minimum `MemAvailable`: 15,975,368 KiB;
- worker minimum `MemAvailable`: 21,178,308 KiB;
- head maximum exposed temperature: 83.9 C;
- worker maximum exposed temperature: 67.2 C;
- neither guard triggered;
- Qwen ASR and Grafana remained running.

Private raw reports and guard records remain under the isolated live lab
directories.  No prompt, block hash, KV payload or private environment file is
committed.

## Gate decision

The one-rank corruption detection, coordinated purge, empty restart and clean
recompute gate **passes**.  The benchmark false-green regression is fixed and
covered by the full offline validation suite.

This does not yet make the complete deployment production-ready.  A fatal
post-start TP rank failure does not automatically converge the peer container,
and the sustained concurrency stability gate is still open.  Those are the
next operational gates; they are not evidence against the storage correctness
proved here.
