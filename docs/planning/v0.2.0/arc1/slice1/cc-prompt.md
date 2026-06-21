# CC assignment — v0.2.0 arc1/slice1: vendor bump to the merged raw-API minimidio

> Self-contained. A **mechanical, low-risk** re-pin of the vendored single-header
> `minimidio.h` from `bb705e8` to the merged upstream commit that now carries our
> raw-bytes API. This slice does **not** touch the swap — the interim adapter stays
> in place and its behavior must be **byte-for-byte unchanged**. The point is: bump
> the pin, prove nothing changed, refresh the drift gate. CDC verifies on close.

## Gating (read first)

**Do not start until v0.1.0 is closed** — the arc3/slice2 **S2** remediation landed
and re-CDC'd green, arc 3 closed, v0.1.0 sealed at `bb705e8`. Bumping the vendor
before then would invalidate the `bb705e8` line-refs in v0.1.0's CDC docs. (See
`docs/planning/v0.2.0/arc1/arc-plan.md` for the milestone framing.)

## Posture

Peer-frame, write-to-the-floor. Load **collaboration-framework** + **erlang-
guidelines**. This is a *provenance + no-regression* slice: the load-bearing
evidence is (a) a clean drift gate and (b) the full suite green at the **same
counts** as v0.1.0's close, plus an additive-diff confirmation. Reuse the existing
vendoring machinery — do not hand-edit `minimidio.h` or `minimidio.lock`.

## Required reading

1. `docs/planning/v0.2.0/arc1/arc-plan.md` — the arc framing + the stub caveat.
2. `docs/planning/v0.1.0/arc1/slice2/minimidio-vendoring-design.md` + that slice's
   cc-prompt/ledger — the vendoring contract (the two-commit attribution pattern:
   the vendored `.h` is committed under the **upstream author**, the lock/docs under
   ours; the deterministic SHA-pinned lock).
3. `mk/minimidio.mk` + `scripts/vendor-minimidio.sh` — `make vendor-minimidio`,
   `make minimidio-verify`, `make minimidio-info`.
4. `c_src/midiio_send.h` + `c_src/midiio_recv.h` — the interim adapter (the symbols
   it depends on, listed below) — so you can confirm the merge didn't touch them.

## What to do

### 1. Bump the pin

- Obtain the **merge commit SHA** on `octetta/minimidio` `main` (the commit that
  merged our raw-bytes API). **Pin a SHA, not `REF=main`** — the lock is
  deterministic by design; a moving branch defeats it.
- Run `make vendor-minimidio SHA=<merged-sha>`. This rewrites `c_src/minimidio.h`
  and `c_src/minimidio.lock` (new `commit`/`version`/`date`/`sha256`, upstream
  `author` preserved). Follow the two-commit attribution from the vendoring design.
- `make minimidio-verify` → green (the header matches the new lock).
- `make minimidio-info` → shows the new pin.

### 2. Prove it's a no-behavior-change bump (the real work)

The merge is **additive** (new `mm_*_raw` functions + `MM_CAP_RAW`), so every
symbol the interim adapter consumes must be **unchanged**. Confirm by diffing the
old (`bb705e8`) vs new header for exactly these, and report the diff:

- `mm_message` struct + the `MM_*` type enum (the adapter reads/writes these).
- `mm_out_send`, `mm_out_send_sysex`, `mm_make_message` (outbound adapter).
- `mm_in_open`, `mm_in_open_virtual`, `mm_in_start`/`mm_in_stop`/`mm_in_close`, the
  `mm_callback` typedef + the background-thread contract (inbound adapter + recv).
- the caps/enumeration surface midiio already uses.

If any of these changed, that's a finding — **stop and flag it** (the swap exam
will want it); a true no-op bump leaves them identical and only *adds* the raw
symbols.

### 3. Full suite green at the same counts

- `rebar3 as test check` green (eunit + PropEr + dialyzer).
- `make asan` → `ASAN-OK`.
- `make vm-test` → the ALSA suite green (same count as v0.1.0's close — 41).
- The conformance dispositions (U1/U2/U3/S1) must be **unchanged**. **If a
  conformance assertion flips** — e.g. the U1 large-SysEx cap no longer errors
  because the merge happened to also fix it — that is a **finding for slice 2, not
  a failure**: record it, leave the test honest (don't force the old assertion),
  and note it in the closing report for the surface exam to fold in.

## Constraints / out of scope

Touch **only** the vendored header + lock (via the script) and, if a conformance
disposition legitimately flips, the minimal honest test adjustment + a disclosure.
**Do not** start the swap, delete the adapter, touch `seam_roundtrip`, or change
any seam behavior — those are slice 3+, planned after the surface exam (slice 2).

## Done

`minimidio.h`/`lock` pinned to the merged commit; `make minimidio-verify` green;
the adapter-consumed symbols confirmed unchanged (additive-only diff reported);
`rebar3 as test check` + `make asan` + `make vm-test` green at v0.1.0 counts; any
conformance-disposition flip recorded as a slice-2 finding (not papered over).
Write `slice1/closing-report.md` (the additive diff + any flips). CDC re-verifies
the provenance, the drift gate, and the no-behavior-change claim. Three-iteration
cap — a vendor bump that needs more than that means the merge wasn't additive, which
is itself the headline finding.

## Ledger

See `slice1/ledger.md`.
