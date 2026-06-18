# CC assignment — arc2/slice2 remediation F1: document the single-owner contract

> A focused remediation of CDC finding **F1** (`arc2/slice2/cdc-verification.md`).
> **Document-only** — chosen disposition. This adds **no locking and no behaviour
> change**; it states the ownership contract where callers will see it and records
> the residual risk + its closure path. The code-level fix (the per-device lock)
> lands at its natural site, arc3/slice1, where the owner mutex is added anyway.
> CDC verifies on close.

## The problem (F1, restated)

`send_nif` reads `res->live` **without a lock** and then calls into the device's
`mm_context`/`mm_device`, while `close/1`'s `do_dev_cleanup` tears those handles
down under `g_uninit_lock`. A device handle (`device()`) is an ordinary Erlang
term, so two processes can share one. If process A `send`s (on a dirty scheduler)
while process B `close`s (on a normal scheduler), A can pass the `live` gate and
then dereference an `mm_context` that B is concurrently `mm_context_uninit`-ing —
a **use-after-free reachable from safe Erlang**. The resource *memory* is safe
(it's reachable as an argument, so GC can't free it); the *backend handles inside
it* are not.

This is safe under the design's single-owner contract (`DESIGN.md` §7: "the owning
Erlang process *is* minimidio's one thread for its device"; §2 per-device context;
§4 D3 chose no lock on the realtime send path). It is only reachable by
*violating* that contract — but nothing in midiio currently states the contract to
a caller, and midiio is a **published, standalone Hex library** whose README
invites direct use. **Severity, reassessed:** the CDC logged F1 as S3 and accepted
it; under the standalone-library framing a from-safe-Erlang UAF is closer to
**S2**. The chosen disposition (document now, fix in arc3/slice1) accepts the
residual risk *with the contract made explicit* — not silently.

## Goal

Make the single-owner contract **explicit and discoverable**, and record F1's
status and closure path. Zero code-behaviour change: `send_nif`, `do_dev_cleanup`,
the resource struct, and the tests are untouched.

## Required reading

- `arc2/slice2/cdc-verification.md` — finding F1 and its disposition.
- `arc2/slice1/cdc-verification.md` — the "Relationship to F1" note (cleanup *is*
  lock-guarded; only the send read is not).
- `arc3/arc-plan.md` — crux #2 (the per-device `owner` + mutex). The lock that
  closes F1 is the **same** lock arc 3 adds; this remediation hands it that job.
- `DESIGN.md` §2, §4 (D3), §7 — the per-device-context / no-hot-path-lock /
  single-thread-per-device commitments the contract restates.
- `src/midiio.erl` — the current `-moduledoc`, `send/2` `-doc`, `close/1` `-doc`
  (OTP-27 doc attributes; the moduledoc was last touched in slice 2).

## What to do (documentation + record only)

1. **`-moduledoc` (`src/midiio.erl`):** add a short **"Ownership & concurrency"**
   paragraph stating the contract plainly:
   - a `device()` handle is owned by **one process** (the opener; once
     `set_owner/2` exists in arc 3, the designated owner);
   - **all** operations on a handle (`send/2`, `close/1`, and arc-3 input ops)
     must come from that one process;
   - midiio does **not** serialize cross-process access — the owner process *is*
     the serialization (this is minimidio's "one thread per device" contract,
     §7, surfaced);
   - concurrently `send`-ing and `close`-ing the **same** handle from different
     processes is **undefined behaviour** and may crash the VM. State it as a
     hard contract, not a soft preference. Do **not** claim midiio guards against
     it — it does not.
2. **`send/2` `-doc`:** one line — operate only from the owning process; concurrent
   `send`/`close` on a shared handle is undefined (see the moduledoc).
3. **`close/1` `-doc`:** same one-line caveat, plus: after `close/1` the handle is
   dead (`{error, not_open}` on a second close *from the owner*; concurrent close
   from another process is undefined).
4. **`README.md`:** a brief **Ownership** note (3–4 sentences) — published-library
   users read the README, not the moduledoc. Mirror the contract; link the idea to
   the "per-device process" model.
5. **`docs/NIF-LEARNINGS.md`:** an entry capturing the learning — *the no-lock hot
   path (§4 D3) buys realtime latency but leaves a from-safe-Erlang send/close UAF
   window; the standing mitigation is the single-owner contract; the structural
   close is the per-device lock arc3/slice1 adds for the owner pid, which also
   guards `live`/teardown/send.* This is a real `[GAP]`-class learning earned here.
6. **Record F1's disposition:** in the remediation closing report (at close), state
   the disposition = *documented contract; residual UAF accepted under single-owner;
   structurally closed in arc3/slice1*, and the S3→S2 reassessment. Carry an
   explicit pointer into `arc3/arc-plan.md` so slice 1 there knows it inherits the
   close.

## Out of scope (deferred to arc3/slice1 — disclosed, not dropped)

- **Any locking / code-behaviour change.** Do **not** add a mutex, do **not** touch
  `send_nif` / `do_dev_cleanup` / the resource struct. The per-device lock that
  *actually* closes the UAF is arc3/slice1 work (it needs the owner-pid context to
  be designed once, not twice).
- **The executable concurrency tripwire** (two processes, shared handle,
  send-vs-close under TSan). Considered and **not** included in this disposition
  (document-only). It becomes the green-by-construction test in arc3/slice1.
- Do not relitigate §4 D3 here.

## Done

The contract is stated in the moduledoc + `send/2` + `close/1` docs + README; the
NIF-LEARNINGS entry is added; no code or test behaviour changed (diff is docs +
markdown only); `rebar3 as test check` still green (a docs-only change must not
move xref/dialyzer/eunit/coverage). Update the F1 row record per the ledger. Write
`F1-remediation-closing.md`; CDC verifies. One-iteration job — if it grows past
documentation, stop: that means it wanted to be the arc3/slice1 code fix.

## Ledger

See `F1-remediation-ledger.md`.
