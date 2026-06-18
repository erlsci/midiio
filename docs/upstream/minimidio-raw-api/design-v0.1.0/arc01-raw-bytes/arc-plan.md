# Arc 01 — Raw-bytes I/O door for minimidio

*Design tree:* `midiio/docs/upstream/minimidio-raw-api/design-v0.1.0/`
*Status:* active — slice 01 in planning
*Roles:* Duncan + Claude (architects / CDC) · Claude Code (IC / implementer)

## Design of record

This arc does **not** restate the design. The plan-of-record is the already-written,
CDC-verified proposal and its issue set:

- `../../minimidio-raw-api-and-findings.md` — the API, the five semantic rules,
  per-backend reality, and the findings. **This is the design doc.**
- `../../issues/00-feature-raw-bytes-api.md` — the feature ticket as filed.

Everything below is *sequencing and decomposition only*. If a design question
arises that the proposal does not answer, it is escalated to an architect
decision and recorded here — not decided by the implementer.

## What the arc delivers

An additive, byte-transparent I/O door alongside minimidio's existing struct and
UMP APIs:

- `mm_raw_callback` typedef, `MM_CAP_RAW` capability bit
- `mm_in_open_raw`, `mm_in_open_virtual_raw`, `mm_out_send_raw`
- Correct inbound framing (one message per callback; system-real-time delivered
  as its own callback; whole SysEx) and uncapped, byte-exact outbound

**Hard constraint for the whole arc: strictly additive.** No existing function's
behavior changes. The known bugs (U1 virtual-SysEx cap, U3 real-time-in-SysEx,
U2 vel-0 fold) are fixed in *separate* PRs against their own tickets. The raw
path simply does the right thing from the start because that is its contract —
that is new correct code, not an edit to the struct path.

## Slice decomposition

Sliced by **backend**, because the verification boundary is "who can compile and
run this," not lines of diff. Ordered by value and testability.

| Slice | Scope | Verified by | Why this order |
|-------|-------|-------------|----------------|
| **01 — CoreMIDI** | Shared scaffolding (typedef, cap bit, device fields, decls) + cross-platform stubs + full CoreMIDI raw I/O + loopback test harness | CC compiles `-framework CoreMIDI` and runs the harness on macOS | Byte-native, highest value, and the one platform we can actually execute today |
| 02 — ALSA | ALSA raw I/O (event↔bytes via `snd_midi_event_*`) | **existing midiio-NIF Multipass VM** (real kernel, `snd-seq`, `libasound2-dev`) | Hardest backend, but now *runtime-verifiable* — the VM the NIF already uses proves the path |
| 03 — WinMM + WebMIDI | Byte-native forwards on the two remaining backends | Windows build / emscripten | Lowest risk; batch the two easy ones |

The shared scaffolding lands **inside slice 01** (not as its own slice): it is
small, and folding it in lets slice 01 be a complete, runnable vertical. Slices
02–03 then only touch their backend's `#ifdef` section plus their stub→real swap.

## Sizing note

Slice 01 is one context with headroom: scaffolding is mechanical, the CoreMIDI
read-proc raw branch is the one piece of real logic, and the harness is modelled
on `examples/virtual.c`. If the read-proc framing turns out to need cross-call
SysEx state beyond what we've specified, that is the signal to split the harness
work into a 01b — but we do not expect it.

## Where the code lands

CC edits `minimidio.h` and adds the test harness **in the minimidio clone**
(`/Users/oubiwann/lab/c/minimidio`), on a feature branch — that branch is the
eventual PR. These planning artifacts stay in `midiio/` and never enter the PR.
