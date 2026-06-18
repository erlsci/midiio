# Ledger — arc2/slice2 remediation F1: document the single-owner contract

> **STRUCTURAL CLOSE LANDED (arc3/slice1, 2026-06-18).** The documented contract
> this remediation stated is now enforced by a per-device `ErlNifMutex`:
> `send_nif`'s live-check-and-use and `do_dev_cleanup`'s teardown run under
> `res->lock`. The send-vs-close UAF is gone — F1 tripwire ASan/TSan-clean +
> 25 BEAM rounds clean. See `arc3/slice1/`.

> CC implements + fills **CC evidence**; CDC verifies independently. Disposition:
> **document-only** (no locking, no behaviour change). Severity reassessed S3→S2
> (from-safe-Erlang UAF in a published library); document-now / structural-close-in
> -arc3/slice1. One-iteration job.

## Rows

| # | Acceptance criterion | How to verify | Sev | Status | CC evidence | CDC verdict |
|---|----------------------|---------------|-----|--------|-------------|-------------|
| 1 | `-moduledoc` states the single-owner contract: one owning process per `device()`; all ops from it; midiio does not serialize cross-process access; concurrent `send`/`close` on a shared handle is **undefined** | read `src/midiio.erl` moduledoc: an "Ownership & concurrency" paragraph with all four points, stated as a hard contract (no claim that midiio guards it) | S2 | ☐ | | |
| 2 | `send/2` `-doc` caveats: operate only from the owning process; concurrent `send`/`close` on a shared handle is undefined (refers to moduledoc) | read the `send/2` `-doc` | S2 | ☐ | | |
| 3 | `close/1` `-doc` caveats: same ownership note; handle dead after close; concurrent cross-process close is undefined | read the `close/1` `-doc` | S2 | ☐ | | |
| 4 | `README.md` has an **Ownership** note (3–4 sentences) mirroring the contract | grep `README.md` for the ownership section | S3 | ☐ | | |
| 5 | `docs/NIF-LEARNINGS.md` entry: no-lock hot path (§4 D3) → send/close UAF window; mitigation = single-owner contract; structural close = arc3/slice1 per-device lock | read the new learnings entry | S3 | ☐ | | |
| 6 | F1 record updated: disposition (documented contract; residual UAF accepted under single-owner; closed in arc3/slice1) + the S3→S2 reassessment, in `F1-remediation-closing.md`; pointer added to `arc3/arc-plan.md` | read the closing report + grep `arc3/arc-plan.md` for the F1 inheritance pointer | S2 | ☐ | | |
| 7 | **No code/behaviour change** — docs only | `git diff` touches only `src/midiio.erl` doc attributes, `README.md`, `docs/NIF-LEARNINGS.md`, and planning docs; `c_src/*` and `test/*` unchanged; `send_nif`/`do_dev_cleanup`/the resource struct untouched | S1 | ☐ | | |
| 8 | `rebar3 as test check` still green (a docs-only change must not move xref/dialyzer/eunit/coverage) | run the alias; exit 0; same test count as slice-2 close | S2 | ☐ | | |

## Notes / disclosed deferrals

- **The actual fix is deferred to arc3/slice1, by decision.** This ledger closes
  the *disclosure* gap (the contract is now explicit), not the UAF. The per-device
  lock that closes the UAF is arc3/slice1 work (same lock as the owner mutex —
  designed once, with owner semantics, not twice). Row 6 carries the pointer so it
  is tracked, not dropped.
- **No tripwire test** in this disposition (document-only was chosen over
  tripwire-now). The green-by-construction concurrency test lands in arc3/slice1.
- **CDC's standing note:** the record should reflect the honest S2 severity even
  though the disposition is document-only — so the residual risk is named, not
  laundered. (CDC raised this; recorded here for the closing report.)

## Closing

CC writes `F1-remediation-closing.md`; CDC writes `F1-remediation-cdc.md`. Done
when the contract is discoverable in the moduledoc + function docs + README, the
learning is recorded, F1's disposition + closure pointer are written, and the diff
is provably docs-only with `check` still green.
