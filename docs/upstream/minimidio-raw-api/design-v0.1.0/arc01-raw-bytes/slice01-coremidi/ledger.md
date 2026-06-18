# Slice 01 — CoreMIDI raw I/O — Ledger

*Protocol:* `collaboration-framework/templates/LEDGER_DISCIPLINE.md`.
CC implements against these rows and reports a per-row disposition with evidence.
CDC re-runs every `Verify` independently. No row advances on a bare "done."

*Verify commands assume CWD = the minimidio clone root* (`/Users/oubiwann/lab/c/minimidio`),
on macOS with the Xcode CLT. Source greps are reproducible anywhere.
*Iteration budget: 5.*

## Ledger

| ID | Criterion | Verify | Significance | Origin | Status | Evidence | Notes |
|----|-----------|--------|--------------|--------|--------|----------|-------|
| F-1 | `mm_raw_callback` typedef exists with the agreed signature | `grep -nE 'typedef void \(\*mm_raw_callback\)\(mm_device\* dev,' minimidio.h` | correctness | slice-doc D1 | done | f71c3c0; matches `minimidio.h:359` | |
| F-2 | `MM_CAP_RAW = 1u << 5` added to cap enum | `grep -nE 'MM_CAP_RAW *= *1u << 5' minimidio.h` | correctness | D1 | done | f71c3c0; `minimidio.h:340` | |
| F-3 | `mm_device` gains `raw_callback` + `is_raw` | `grep -n 'mm_raw_callback raw_callback' minimidio.h && grep -nE 'int +is_raw' minimidio.h` | correctness | D1 | done | f71c3c0; `raw_callback`@536, `is_raw`@542 | |
| F-4 | Three raw functions publicly declared | `grep -c -E 'mm_(in_open_raw|in_open_virtual_raw|out_send_raw)' minimidio.h` (≥ 6: 3 decls + ≥3 defs) | correctness | D1 | done | f71c3c0; grep -c = 16 (≥6); 3 decls @580/597/607 | |
| F-5 | CoreMIDI device struct gains `sysex_pos` accumulator | `awk '/mm__dev_coremidi/,/} mm__dev_coremidi/' minimidio.h \| grep 'sysex_pos'` | correctness | D4 | done | f71c3c0; first match = `size_t sysex_pos;` in `mm__dev_coremidi`. NB: struct given a leading tag so it falls inside the awk range — see report | tag addition disclosed |
| F-6 | CoreMIDI `mm_context_caps` advertises `MM_CAP_RAW` | `sed -n '/^uint32_t mm_context_caps/,/^}/p' minimidio.h \| grep 'MM_CAP_RAW'` | polish | D5 | done | f71c3c0; `return … \| MM_CAP_RAW;` | |
| F-7 | WinMM/ALSA/WebMIDI define raw stubs returning `MM_NO_BACKEND` | CDC reads diff: each non-CoreMIDI section defines all 3 raw fns, body `return MM_NO_BACKEND;` | polish | D6 | done | f71c3c0; WinMM @1284/1287/1290, ALSA @1750/1753/1756, WebMIDI @2253/2256/2259; all `return MM_NO_BACKEND;` | grep-assisted, CDC confirms by section |
| F-8 | Harness + header compile clean, no warnings | `cc tests/raw_loopback.c -framework CoreMIDI -Wall -Wextra -o /tmp/raw_loopback; echo exit=$?` (exit=0, zero warnings) | serious | D7 | done\* | f71c3c0; exit=0 **with `-framework CoreFoundation` added** (AMENDMENT A1); 2 warnings remain — both pre-existing UMP helpers (`mm__ump_word_count_from_type`, `mm__ump_midi1_to_message`), reproduced on base bb705e8; **zero** new warnings from raw code | \*see report: caveat + amendments A1 (CF flag) & A2 (pre-existing warnings) |
| F-9 | **T1** short channel msg round-trips byte-exact (`90 3C 40` in = `90 3C 40` out) | `/tmp/raw_loopback \| grep '^PASS T1'` | serious | proposal §5.1 | done | f71c3c0; `PASS T1` | |
| F-10 | **T2** note-on velocity 0 passes through unfolded (`90 3C 00` stays `90 3C 00`, not `80 …`) | `/tmp/raw_loopback \| grep '^PASS T2'` | serious | §5.1 / U2 | done | f71c3c0; `PASS T2` | |
| F-11 | **T3** >256-byte SysEx round-trips whole, one callback, intact `F0…F7` | `/tmp/raw_loopback \| grep '^PASS T3'` | serious | §5.4 / U1 | done | f71c3c0; `PASS T3` (300-byte SysEx, one callback, intact) | the no-cap proof |
| F-12 | **T4** `F8` mid-SysEx → own 1-byte callback AND SysEx payload contains no `F8` | `/tmp/raw_loopback \| grep '^PASS T4'` | serious | §5.2 / U3 | done | f71c3c0; `PASS T4` | |
| F-13 | **T5** runtime caps query reports `MM_CAP_RAW` set | `/tmp/raw_loopback \| grep '^PASS T5'` | polish | D5 | done | f71c3c0; `PASS T5` | |
| F-14 | **T6** additive: existing examples compile unchanged AND struct-mode receive still decodes correctly | `cc examples/monitor.c -framework CoreMIDI -o /tmp/monitor; echo exit=$?` (=0) AND `/tmp/raw_loopback \| grep '^PASS T6'` | serious | arc-plan additive constraint | done\* | f71c3c0; monitor exit=0 **with `-framework CoreFoundation`** (AMENDMENT A1); `PASS T6` | \*CF-flag amendment A1 applies to monitor link too |
| F-15 | No diff to existing struct read/send logic | `git diff` shows only additions (new fns, new fields, the `if (dev->is_raw)` dispatch line) — no edits inside the existing struct decode loop or `mm_out_send*` bodies | serious | additive constraint | done | f71c3c0; +186/-2; decode loop & all `mm_out_send*` bodies byte-unchanged; the 2 edits are the D5 caps line (F-6) + the struct tag (F-5) — both disclosed; dispatch is a pure insertion | CDC reads the diff |

## What Worked

- **Mirroring the `_ump` door exactly** made the shared scaffolding (D1)
  mechanical and low-risk — every new field/decl had an existing twin to sit
  beside, so the additive constraint was easy to honour.
- **One dispatch line + an untouched decode loop.** Putting all raw framing
  in a new `mm__cm_raw_dispatch` and gating it with a single
  `if (dev && dev->is_raw)` line kept the existing struct path byte-for-byte
  identical (F-15), which is exactly what the additive rule wanted.
- **Intra-process virtual loopback works on CoreMIDI** (Darwin 24.6.0) — the
  empirically-unproven assumption in slice-doc §D7 held, so no topology
  amendment was needed. `mm_out_open_virtual` source → `mm_in_open_raw` on it
  round-trips, including a 300-byte SysEx through the `MIDIReceived` branch.
- **The harness distinguishing "no bytes" from "wrong bytes"** meant every
  green run is real evidence, and would have made a loopback failure
  diagnosable rather than ambiguous.

## Closure

Total rows: 15. Done: 15 (two — F-8, F-14 — carry a disclosed
`-framework CoreFoundation` link amendment; F-8 also carries a pre-existing
warnings caveat). Deferred: 0. No-op: 0.
Closed at commit `f71c3c0` (minimidio `feat/raw-bytes-api`) on 2026-06-18.
CDC verification: **PASS** (2026-06-18) — see `cdc-verification.md`. All 15 rows
independently validated (source rows re-run; behavioral rows verified by
inspection of a non-vacuous, race-free harness + an implementation audit, since
CDC has no macOS to re-execute). Amendments A1 (CoreFoundation link flag) and A2
(pre-existing UMP unused-function warnings) accepted as legitimate
command/criterion corrections, not spec-softening. Cleared to proceed to slice 02.
