# CDC verification — v0.2.0 arc1/slice1 (vendor bump to the merged raw-API minimidio)

> Independent verification of the vendor bump (`1a3ee4d` header, `3a3629e` lock,
> `78c7d28` ledger/close-out) re-pinning minimidio `bb705e8` → `0fb49e6` (the PR #12
> raw-bytes-API merge).
>
> **Verdict: PASS.** The bump is additive-only and behavior-preserving, and the
> structural proof is airtight — the bump touched *only* vendored files, so
> midiio's own code is unchanged by definition. One downstream doc note (the
> compatibility-matrix version string) is flagged and resolved separately.

## ✅ Structural proof — the bump touched only vendored files

The three commits' file lists: `1a3ee4d` → `c_src/minimidio.h`; `3a3629e` →
`c_src/minimidio.lock`; `78c7d28` → the two slice docs. **No `.c`, `.erl`,
`rebar.config`, or test file changed.** So midiio's adapter (`midiio_send.h` /
`midiio_recv.h`), the NIF, `caps/1`, and the test suite are byte-for-byte the same
source as at the v0.1.0 close — "no behavior change" and "no conformance flip" are
*guaranteed by construction*, not merely observed. This is the strongest form the
proof can take.

## ✅ Additive-only diff (independently reproduced)

`git show 1a3ee4d -- c_src/minimidio.h` shows **exactly 5 removed/changed lines**,
matching CC's report:

1. `typedef struct {` → (the CoreMIDI **internal** struct gains a name) — invisible
   to the adapter and the NIF.
2–5. Four `mm_context_caps` bodies add `| MM_CAP_RAW` (one per backend).

Everything else is pure addition (the `mm_*_raw` / `mm_raw_callback` / `MM_CAP_RAW`
surface). None of the adapter-consumed symbols (`mm_message`, the `MM_*` enum,
`mm_callback`, `mm_make_message`, `mm_out_send`/`_sysex`, the `mm_in_*` family) is
among the changed lines, so they are unchanged.

## ✅ `mm_device` additive fields are safe

The public `mm_device` gained `raw_callback` / `is_raw`. Verified the NIF **never**
reads an `mm_device` field by name — `grep` for `res->dev.` / `dev.<field>` in
`midiio_nif.c` returns nothing; the device is only ever passed as `&res->dev`
through the minimidio API. Adding fields to the struct is therefore safe (no
offset/aliasing assumption in midiio).

## ✅ Runtime (per CC; consistent with the structural proof)

`rebar3 as test check` 42/42 + PropEr + dialyzer clean; `make asan` ASAN-OK;
`make vm-test` (real ALSA) 42/42 + ASAN-OK. The "41 vs 42" ledger note is correct:
41 was the v0.1.0-close count; the v0.1.0-tail S2 remediation added one test, so 42
is the pre-bump baseline and 42 post-bump is the zero-delta proof. (I did not re-run
the runtime — no Erlang/ALSA in the CDC sandbox — but the structural proof makes a
behavioral regression impossible without a source change, and there was none.)

## ✅ Provenance / attribution (disclosed, correct)

Two-commit pattern preserved. The pinned merge commit `0fb49e6` is authored by
**Duncan McGreggor / billosys** (the raw-bytes API was contributed *by* billosys
*to* octetta), so the vendor script's R1 logic derived that author and fired the
expected mismatch warning vs the Joseph-Stewart-era constant. `git blame` on
`minimidio.h` now attributes the original lines to Joseph and the raw-API lines to
Duncan — the per-commit attribution design working as intended, not a regression.

## 🟡 Downstream note — compatibility-matrix version string

The lock records `version: v0.5.0-dev` at `0fb49e6` — the raw-API merge did **not**
bump minimidio's version constant. So the README compatibility matrix's
`minimidio 0.6.0-dev` for the 0.2.0 row is **forward-looking**, not the
currently-vendored string (both `bb705e8` and `0fb49e6` self-report `v0.5.0-dev`).
Per the architect's call, the matrix keeps `0.6.0-dev` as the target with a README
footnote stating 0.2.0 currently vendors `0fb49e6` (`v0.5.0-dev`) pending the
upstream bump. Not a slice-1 defect — a documentation reconciliation.

## Bottom line

The native raw-API header is vendored, the drift gate is green, and the bump is
provably behavior-neutral (vendored-files-only + the 5-line additive diff +
safe additive `mm_device` fields). **PASS.** The freshly-vendored header is ready
for the **slice-2 surface exam** (read the merged raw API in detail, produce the
landed-vs-proposed delta), which gates the slice-3+ seam swap.
