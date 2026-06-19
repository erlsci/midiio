# Slice 03 — WinMM + WebMIDI raw I/O

*Plan-of-record. Companions: `ledger.md`, `cc-prompt.md`. Prereq: slices 01–02 merged.*
*Design of record:* `../../../minimidio-raw-api-and-findings.md` (§4 API, §5 semantics, §6 per-backend).
*Line numbers against `feat/raw-bytes-api` @ `107107f` (post-slice-02); re-confirm before editing.*

## Goal

Finish the arc: implement the raw door on the two remaining byte-native backends,
WinMM and WebMIDI, leaving every backend either fully raw-capable or honestly
stubbed. Strictly additive.

## The verification reality (read this first)

Unlike CoreMIDI (your Mac) and ALSA (the Multipass VM), **neither of these
backends has an automated runtime-test path in our loop:**

- **WinMM has no virtual ports** (the source itself points to loopMIDI), so the
  virtual-loopback harness cannot run there. Runtime testing needs Windows +
  loopMIDI, done manually.
- **WebMIDI needs a browser** with a Web MIDI implementation; there's no headless
  assert harness.

So slice 03's acceptance bar is, by agreement: **compile-checks + CDC structural
inspection**, with the round-trip behavioral rows **deferred-with-rationale** (a
valid ledger status — reason + re-entry condition recorded, never silently
dropped). Concretely:

- **WinMM:** cross-compile-check with `zig cc -target x86_64-windows-gnu -lwinmm`.
- **WebMIDI:** build-check with `emcc` to wasm.

These catch type/signature/link errors across the whole backend, including the new
raw functions. Runtime correctness rides on the structural audit plus the fact
that both paths are thin byte-forwards over platform APIs that already work for
the struct path.

## In scope

1. **WinMM:** `mm_in_open_raw`, `mm_out_send_raw`, a raw branch in `mm__wm_in_proc`,
   `MM_CAP_RAW` in caps. `mm_in_open_virtual_raw` stays `MM_NO_BACKEND` (no virtual ports).
2. **WebMIDI:** `mm_in_open_raw`, `mm_out_send_raw`, a raw branch in
   `mm__web_dispatch_raw`, `MM_CAP_RAW` in caps. `mm_in_open_virtual_raw` stays
   `MM_NO_BACKEND`.
3. A tiny `tests/raw_compile_check.c` that references all three raw entry points so
   the cross/emcc builds exercise the new call sites.

## Out of scope (deferred, with re-entry)

- **Runtime round-trip on WinMM** → re-entry: a Windows host with loopMIDI.
- **Runtime round-trip on WebMIDI** → re-entry: a browser test (extend the existing
  `examples/web_*` + `serve-wasm.sh`).
- `mm_in_open_virtual_raw` on either backend (neither has virtual ports) →
  permanent `no-op`: documented `MM_NO_BACKEND`, matching `mm_in_open_virtual`.

---

## Design decisions (settled here)

### D1 — WebMIDI (near-free; the plumbing already exists)

The WebMIDI backend is already built on an internal raw-bytes path: each
`onmidimessage` event's `Uint8Array` is handed to a C dispatch as raw bytes by
`mm__web_in_start_js` (line 2182), and `mm__web_out_send_raw_js` (line 2218)
already sends a byte array. So:

- **Inbound:** at the top of `mm__web_dispatch_raw` (line 2233), add
  `if (dev && dev->is_raw) { if (dev->raw_callback) dev->raw_callback(dev, data,
  (size_t)size, ts, dev->userdata); return; }` — **before** the existing
  `!dev->callback` guard and the parse loop. The Web MIDI API delivers exactly
  one complete message per event, so `data[0..size)` is already one framed
  message — no framing needed.
- **`mm_in_open_raw`** (stub at line 2373): mirror `mm_in_open` (line 2355) —
  set `dev->web.input_idx`, `raw_callback`, `is_raw=1`. `mm_in_start` (line 2382)
  already passes `mm__web_dispatch_raw` as the dispatch, which now branches on
  `is_raw`. Nothing else to wire.
- **`mm_out_send_raw`** (stub at line 2379): `return (mm_result)
  mm__web_out_send_raw_js(dev->web.output_idx, data, (int)len);` plus the standard
  guards. (`mm_out_send` already routes through that same JS function.)
- **Caps:** add `MM_CAP_RAW` to WebMIDI `mm_context_caps` (line 2333).
- **`mm_in_open_virtual_raw`:** leave the `MM_NO_BACKEND` stub.

### D2 — WinMM (moderate; framing on both edges)

- **Inbound** — add `if (dev && dev->is_raw) { … return; }` at the top of
  `mm__wm_in_proc` (line 1204), **before** the `if (!dev || !dev->callback)`
  guard, leaving the struct decode untouched:
  - `MIM_DATA`: unpack `p1` into status `s`, `d1`, `d2`; deliver
    `1 + data_bytes(s)` wire bytes via `raw_callback` (real-time / `0xF6` → 1
    byte; `0xF1`/`0xF3`/program/chan-pressure → 2; channel / `0xF2` → 3). Use a
    small `data_bytes(status)` helper (same table as CoreMIDI's
    `mm__cm_raw_data_bytes`).
  - `MIM_LONGDATA`: forward `hdr->lpData[0 .. dwBytesRecorded)` via `raw_callback`,
    then `midiInAddBuffer` as the struct path does.
- **`mm_in_open_raw`** (stub at line ~1285): mirror `mm_in_open` (line 1265) —
  `midiInOpen(..., mm__wm_in_proc, dev, CALLBACK_FUNCTION)`, prepare/add the
  sysex buffer — but set `raw_callback`/`is_raw` instead of `callback`.
- **`mm_out_send_raw`** (stub at line ~1291): frame the byte buffer and emit each
  message — short messages via `midiOutShortMsg` (pack status + up to 2 data bytes
  into the DWORD, same packing as `mm_out_send` at line 1316), and a `F0…F7`
  SysEx via `midiOutLongMsg` (same prepare/long/unprepare dance as
  `mm_out_send_sysex` at line 1347). Walk the buffer with `data_bytes(status)`.
- **Caps:** add `MM_CAP_RAW` to WinMM `mm_context_caps` (line ~1183).
- **`mm_in_open_virtual_raw`:** leave the `MM_NO_BACKEND` stub (WinMM has no
  virtual ports — matches `mm_in_open_virtual`).

### D3 — Compile-check translation unit

`tests/raw_compile_check.c`: `#define MINIMIDIO_IMPLEMENTATION`, include the
header, and in `main` reference `mm_in_open_raw`, `mm_in_open_virtual_raw`,
`mm_out_send_raw`, and `MM_CAP_RAW` (e.g. take their addresses / call them behind
an `if (0)`), so the new call sites are type-checked even though nothing runs.
This is the unit the cross/emcc builds compile.

---

## Risks / watch-items for CDC

- **WinMM raw-output framing** is the one piece of real logic; a wrong
  `data_bytes` count would mis-split the stream. Audit it against the table and
  against `mm_out_send`'s packing.
- **Additive:** `mm__wm_in_proc`'s struct branches, `mm__web_dispatch_raw`'s parse
  loop, and all existing `mm_out_send*` bodies must be byte-unchanged (the raw
  branches are pure insertions).
- **Partial backend support is intentional:** `mm_in_open_virtual_raw` returning
  `MM_NO_BACKEND` on both backends is correct, not a gap — assert it stays a clean
  stub, and that `mm_in_open_raw` / `mm_out_send_raw` are real.
- **Compile-check ≠ runtime:** the deferred behavioral rows are real coverage gaps,
  honestly tracked. CDC confirms the deferral reasons and re-entry conditions, and
  audits the byte-forward logic by inspection in their place.
