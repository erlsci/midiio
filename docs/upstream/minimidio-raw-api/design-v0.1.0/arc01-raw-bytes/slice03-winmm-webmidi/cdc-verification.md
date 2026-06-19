# Slice 03 — WinMM + WebMIDI raw I/O — CDC verification

*Independent verification per LEDGER_DISCIPLINE CDC protocol.*
*Verifier: Claude (CDC), 2026-06-18. Commit under review: `66bb4e1` (parent `107107f`).*

## Verdict

**PASS.** 13 rows validly resolved (11 `done`, 2 `deferred`, 0 silent drops). The
implementation is correct and strictly additive. The one untested logic path
(WinMM output framing, DEF-1) was **independently executed in isolation by CDC**
and is correct. Both deferrals are legitimate with concrete re-entry conditions.
The disclosed heap-buffer deviation is an improvement, not a regression.

**This closes Arc 01** — all four backends are raw-capable (CoreMIDI, ALSA,
WinMM, WebMIDI) or honestly stubbed (`mm_in_open_virtual_raw` on WinMM/WebMIDI,
which have no virtual ports).

## CDC capability boundary (disclosed)

This sandbox has gcc only — no `zig`, `emcc`, ALSA headers, or macOS — so I could
**not** reproduce the compile-check rows (CC-1 `zig cc`, CC-2 `emcc`, CC-3
CoreMIDI/ALSA). Those are accepted on CC's evidence. **But** the WinMM output
framing is pure byte logic, so I transcribed it verbatim and executed it under gcc
(see below) — turning the highest-risk deferred path from "audited" into "run."

## Per-row dispositions

| Row | CDC action | Result |
|-----|-----------|--------|
| WEB-1 | ran grep | ✓ 0 `MM_NO_BACKEND` in WebMIDI raw fns (both real) |
| WEB-2 | read diff | ✓ `if (dev && dev->is_raw)` at top of `mm__web_dispatch_raw`, before the struct guard; verbatim forward |
| WEB-3 | ran grep | ✓ WebMIDI caps `\| MM_CAP_RAW` |
| WEB-4 | read diff | ✓ `mm_in_open_virtual_raw` body unchanged, `return MM_NO_BACKEND;` |
| WIN-1 | ran grep | ✓ 0 `MM_NO_BACKEND` in WinMM raw fns (both real) |
| WIN-2 | read diff | ✓ `if (dev && dev->is_raw)` at top of `mm__wm_in_proc`, before the struct guard |
| WIN-3 | ran grep | ✓ WinMM caps `\| MM_CAP_RAW` |
| WIN-4 | read diff | ✓ `mm_in_open_virtual_raw` body unchanged, `return MM_NO_BACKEND;` |
| CC-1 | **not re-runnable** (no zig) | accept CC evidence (exit 0); warning analysis consistent with slice-01 A2 (the 2 UMP helpers) + the MSVC `#pragma comment` — all pre-existing, 0 new |
| CC-2 | **not re-runnable** (no emcc) | accept CC evidence (exit 0, emits wasm) |
| CC-3 | **not re-runnable** (no macOS/ALSA) | accept CC evidence (both backends still build) |
| ADD-1 | **ran `git diff`** | ✓ exactly 7 deletions = 2 caps lines + 4 stub bodies + 1 stale comment; struct branches, parse loop, `mm_out_send*` bodies byte-unchanged; raw branches pure insertions |
| DEF-1 | **executed framing in isolation** + read | ✓ valid `deferred`; reason (no Windows/loopMIDI) + re-entry concrete; framing algorithm independently verified (below) |
| DEF-2 | read | ✓ valid `deferred`; WebMIDI raw is verbatim-forward over an existing JS sender — minimal residual risk; re-entry concrete (browser test) |

## Independent execution of the WinMM framing (DEF-1's risk)

DEF-1 cannot run without Windows + loopMIDI, so the `mm_out_send_raw` byte-stream
framing was the one piece of real logic with no test. I transcribed
`mm__wm_raw_data_bytes` and the framing loop **verbatim** from the commit into an
isolation harness (`cdc-wm-framing-test.c` in this directory), replacing
`midiOutShortMsg`/`midiOutLongMsg` with recorders, and ran it under gcc. All 8
cases pass:

- T1 note-on `90 3C 40` → one short, byte-exact.
- T2 vel-0 `90 3C 00` → one short, **unfolded** (status stays `0x90`).
- T3 SysEx `F0 7E 00 01 F7` → one long, whole.
- T4 real-time `F8` → one short, 1 byte.
- T5 **mixed stream** `90 3C 40 / F8 / B0 07 7F / F0 7E F7` → split into exactly 4
  messages — the byte-advance is correct across short/long/real-time boundaries.
- T6 program-change + note (`C0 05` then `90 3C 40`) → 2 messages (1-data-byte
  status advances correctly).
- T7 SysEx with embedded `F8` → one long containing the `F8` **verbatim** (byte-exact
  transmission, as the contract requires).
- T8 300-byte SysEx → one long, whole (the heap-buffer no-cap path at the framing level).

This verifies the framing algorithm, the `data_bytes` table, and the byte-advance.
What remains genuinely untested (and honestly deferred) is the actual `midiOut*`
API behavior and real hardware/loopMIDI delivery — unavoidable without Windows.

## Deviation adjudication

**Heap buffer for WinMM SysEx output. ACCEPTED (improvement).** CC sent SysEx via a
`malloc`'d buffer sized to the payload rather than the fixed `wm.sysex_buf`, lifting
the length cap — honoring semantic rule 4 (no cap), exactly as CoreMIDI's U1 fix and
ALSA do. Byte-exact, freed on every path. T8 confirms large SysEx frames whole. A
strict "mirror `mm_out_send_sysex`" reading would have inherited a 4096 cap; this is
the better choice and was disclosed.

## Minor notes (not blockers)

- Truncated trailing message (status with fewer than N data bytes before
  buffer end): framing advances by `1 + nd` and zero-pads the absent bytes.
  Benign for well-formed MIDI streams; matches the input-side and CoreMIDI
  assumptions. No fix needed.
- Embedded real-time inside a SysEx is transmitted verbatim within the
  `midiOutLongMsg` blob (T7). Byte-exact per contract; whether hardware
  interleaves it is the platform's concern, not a framing bug.

## Closure

Slice 03 CDC-verified **PASS** at `66bb4e1`, 2026-06-18. 13 rows valid (11 done,
2 deferred). Compile-check rows accepted on CC evidence (not re-runnable in CDC
env); WinMM framing independently executed. Arc 01 complete.
