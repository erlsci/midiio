# Arc plan — v0.2.0 arc 1: native raw integration

> **Milestone framing.** v0.1.0 shipped midiio against an *interim adapter* behind
> a stable raw seam — by design, before upstream had a raw API (the
> `TODO(upstream)` markers in `c_src/midiio_send.h` / `c_src/midiio_recv.h` named
> exactly this day). The minimidio raw-bytes API we proposed has now been **merged
> upstream**, so v0.2.0 arc 1 swaps the binding onto the native API and deletes the
> adapter. v0.1.0 stays frozen at minimidio `bb705e8` — this arc opens against the
> merged upstream.
>
> **Gating:** this arc starts **after v0.1.0 closes** (the arc3/slice2 **S2**
> micro-remediation landed + re-CDC'd green, arc 3 closed). Do not bump the vendor
> mid-close-out — it would invalidate the `bb705e8` line-refs in v0.1.0's CDC docs.

## Why this arc exists (the convergence)

The interim adapter is the inverse-switch that translates bytes⇄`mm_message` on
both edges so midiio could drive minimidio's *struct* API as if it were a byte
pipe. The native raw API makes it a real byte pipe. Swapping to it doesn't just
simplify — it **deletes the exact code a whole cluster of defects lives in**:

- the arc3/slice2 **S2** (the `seam_roundtrip`/`midiio_bytes_to_msg` OOB read) — in
  the adapter, gone when the adapter is deleted;
- **U2** (vel-0 fold) and **U3** (real-time-in-SysEx) — the raw API was *designed*
  not to do these (byte-exact, real-time framed separately), so they're resolved
  by construction on the backends that ship raw;
- **U1** (CoreMIDI virtual-source SysEx >256 B cap) — addressed by the raw
  send path upstream.

So this arc is both a simplification *and* a defect-retirement. Several disclosed
v0.1.0 limitations should close here — but **only as evidence confirms**, per
backend (see the stub caveat).

## Slice sequence (staged — the swap is planned only after we see the surface)

**Slice 1 — vendor bump (mechanical, low-risk).** Re-pin the vendored
`c_src/minimidio.h` to the merged upstream commit via the existing scripted
vendoring (`make vendor-minimidio SHA=<merged>`), refresh `minimidio.lock`
(commit/version/date/sha256/attribution) and the `make minimidio-verify` drift
gate. **No behavior change**: the merge is additive, so the struct API the interim
adapter consumes is unchanged — the full suite must stay green at the same counts.
This is the "perform a vendored update" step, isolated from the swap. Slice 1
docs: `slice1/cc-prompt.md` + `slice1/ledger.md`.

**Slice 2 — surface exam (CDC/architect analysis, not a CC implementation slice).**
With the native header now vendored, read it in detail and produce
`slice2/surface-delta.md`: **what landed vs what we proposed** — exact signatures,
the `MM_CAP_RAW` bit value, per-backend reality (notably `mm_in_open_virtual_raw`
ships *stubbed* on WinMM/WebMIDI per the upstream arc-01 slice-03 work), the
callback shape/timestamp semantics, and any maintainer reshaping or renames. This
deliverable decides the swap's shape; it is analysis, so the architect/CDC writes
it rather than handing it to CC. **No swap planning precedes this.**

**Slice 3+ — the swap (planned AFTER slice 2, from what landed).** Placeholder
until the exam. Expected shape (to be confirmed/revised by `surface-delta.md`):
swap `midiio_dev_send_raw`'s body to `mm_out_send_raw`; repoint the inbound seam to
`mm_in_open_raw` + `mm_raw_callback`; **delete** the interim adapter
(`midiio_bytes_to_msg`, `midiio_msg_to_bytes`), the `seam_roundtrip` test NIF, and
the bytes⇄message PropEr property (there is no bytes⇄message bridge once the seam
is byte-passthrough); rework conformance to assert true byte-passthrough; and close
the U1/U2/U3 disclosures *on the backends where the raw API delivers*. Slice count
TBD by the exam (likely lifecycle/seam swap, then conformance rework).

## The stub caveat (flag for the exam, real for the swap)

`mm_in_open_virtual_raw` is stubbed (`MM_NO_BACKEND`) on WinMM/WebMIDI — no virtual
ports there. midiio's conformance **loopback runs over virtual ports**, but only on
its tested backends: **CoreMIDI and ALSA, where `*_virtual_raw` is real.** So the
stub does not bite midiio's CI. The swap must still handle "raw-virtual absent"
gracefully (feature-detect via `MM_CAP_RAW` / keep the interim path where native
raw-virtual isn't available) — but for the backends midiio actually tests, native
raw-virtual exists. Confirm exact per-backend availability in the exam.

## Success criteria (v0.2.0 arc 1)

1. Vendored at the merged upstream commit; `make minimidio-verify` green; provenance
   + attribution correct.
2. The interim adapter (`midiio_bytes_to_msg` / `midiio_msg_to_bytes`) and the
   `seam_roundtrip` test NIF are **deleted**; the seam is native byte-passthrough.
3. Conformance still byte-exact across the full taxonomy — now a true passthrough,
   not an adapter round-trip — green on macOS (CoreMIDI) + Linux (ALSA, vm-test).
4. U1/U2/U3 disclosures closed on the backends where the raw API resolves them,
   with evidence; any residual (e.g. a still-stubbed path) re-disclosed.
5. No regression: F1 close, the recv lifecycle, `set_owner` handoff, and the
   crash-safety criteria all still hold; ASan/TSan clean.
6. `MM_CAP_RAW` feature-detection wired so a future older-minimidio build degrades
   predictably (decide scope in the exam).

## Out of scope (still)

UMP/MIDI 2.0; WinMM/WebMIDI bring-up + CI; `send_batch/2` (NEW-1); public virtual
ports as a surface. These remain named non-goals; the native swap doesn't pull
them in.

## Close-out

Arc 1 of v0.2.0 closes when the binding runs on the native raw API, the interim
adapter is gone, conformance is green as true passthrough, and the
resolved-by-construction defects are closed-with-evidence. Then the seam's
`TODO(upstream)` markers are discharged — the design's central bet (ship behind a
stable seam, swap when upstream lands) is paid off in full.
