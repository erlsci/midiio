# CC assignment — Slice 03: WinMM + WebMIDI raw I/O for minimidio

You are the implementer (IC) for the final two backends of the raw-bytes feature.
Slices 01 (CoreMIDI) and 02 (ALSA) already landed; WinMM and WebMIDI currently
have stub raw functions returning `MM_NO_BACKEND`. Make them real (except the
virtual-raw functions, which stay stubs — neither backend has virtual ports),
compile-check them, and report per-row with evidence. Raise an amendment request
rather than working around the ledger.

## Read first (in this order)

1. `collaboration-framework/templates/LEDGER_DISCIPLINE.md` — the protocol.
2. `./ledger.md` — your 13 rows (note: DEF-1/DEF-2 are **deferred** by design).
3. `./slice-doc.md` — full design, decisions D1–D3.
4. Design of record: `../../../minimidio-raw-api-and-findings.md` (§5 semantics, §6).

## Where to work

- Same clone/branch: `/Users/oubiwann/lab/c/minimidio`, `feat/raw-bytes-api`.
- Add `tests/raw_compile_check.c` (a tiny TU that references all three raw entry
  points so the cross/emcc builds type-check the new call sites).

## Verification reality (important)

Neither backend has an in-loop runtime path: **WinMM has no virtual ports**
(loopMIDI is required, manual on Windows) and **WebMIDI needs a browser**. So your
bar is **compile-checks + correct, reviewable code**, and the round-trip rows
(DEF-1, DEF-2) are **deferred-with-rationale** — mark them `deferred` with the
re-entry conditions from the ledger; do not fake a runtime pass, and do not drop
them silently.

- WinMM compile-check: `zig cc tests/raw_compile_check.c -target x86_64-windows-gnu -lwinmm -Wall -Wextra -o /tmp/wm.exe`
- WebMIDI build-check: `emcc tests/raw_compile_check.c -sASYNCIFY -o /tmp/web.js`

(If a toolchain is missing, say so and mark that compile row `deferred` with the
reason — don't guess at a result.)

## The one hard rule: strictly additive

Do not modify `mm__wm_in_proc`'s struct decode branches, `mm__web_dispatch_raw`'s
parse loop, or any `mm_out_send*` body. The raw branches are pure insertions at
the top of the input handlers, guarded by `if (dev && dev->is_raw)`. ADD-1 verifies this.

## What to build (full detail in slice-doc.md)

**WebMIDI (D1 — mostly wiring; the raw plumbing already exists):**
- `mm__web_dispatch_raw` (line 2233): add at the very top
  `if (dev && dev->is_raw) { if (dev->raw_callback) dev->raw_callback(dev, data, (size_t)size, ts, dev->userdata); return; }`.
  Web MIDI delivers one complete message per event → no framing.
- `mm_in_open_raw` (stub line 2373): mirror `mm_in_open` (2355) — set
  `web.input_idx`, `raw_callback`, `is_raw=1`. `mm_in_start` already dispatches to
  `mm__web_dispatch_raw`.
- `mm_out_send_raw` (stub line 2379): guards, then
  `return (mm_result)mm__web_out_send_raw_js(dev->web.output_idx, data, (int)len);`.
- Caps (line 2333): add `MM_CAP_RAW`. Leave `mm_in_open_virtual_raw` a stub.

**WinMM (D2 — framing on both edges):**
- `mm__wm_in_proc` (line 1204): add `if (dev && dev->is_raw) { … return; }` before
  the `!dev->callback` guard. `MIM_DATA` → unpack `p1` into `1 + data_bytes(s)`
  wire bytes, deliver via `raw_callback`. `MIM_LONGDATA` → forward
  `hdr->lpData[0..dwBytesRecorded)`, then `midiInAddBuffer`. Add a small
  `data_bytes(status)` helper (same table as CoreMIDI's `mm__cm_raw_data_bytes`).
- `mm_in_open_raw` (stub line ~1285): mirror `mm_in_open` (1265) with
  `raw_callback`/`is_raw`.
- `mm_out_send_raw` (stub line ~1291): frame the buffer — short messages via
  `midiOutShortMsg` (pack like `mm_out_send`, line 1316), `F0…F7` via
  `midiOutLongMsg` (prepare/long/unprepare like `mm_out_send_sysex`, line 1347).
- Caps (line ~1183): add `MM_CAP_RAW`. Leave `mm_in_open_virtual_raw` a stub.

**Compile-check TU (D3):** `tests/raw_compile_check.c` — `#define
MINIMIDIO_IMPLEMENTATION`, include the header, and in `main` reference all three
raw functions + `MM_CAP_RAW` (behind `if (0)` is fine) so the call sites compile.

## Reporting (closing-report.md)

Per-row walk of all 13 rows — final status + evidence. DEF-1/DEF-2 → `deferred`
with reason + re-entry. WEB-4/WIN-4 → `done` (verified stubs). Fill the ledger
Evidence column as you go; name any uncertainty; then hand back to CDC.

## If you get stuck

Five-iteration budget. The only real logic is WinMM `mm_out_send_raw` framing — if
it fights you past iteration 3, flag it. WebMIDI should be nearly mechanical.
