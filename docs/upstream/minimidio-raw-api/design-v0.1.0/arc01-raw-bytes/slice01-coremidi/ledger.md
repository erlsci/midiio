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
| F-1 | `mm_raw_callback` typedef exists with the agreed signature | `grep -nE 'typedef void \(\*mm_raw_callback\)\(mm_device\* dev,' minimidio.h` | correctness | slice-doc D1 | open | | |
| F-2 | `MM_CAP_RAW = 1u << 5` added to cap enum | `grep -nE 'MM_CAP_RAW *= *1u << 5' minimidio.h` | correctness | D1 | open | | |
| F-3 | `mm_device` gains `raw_callback` + `is_raw` | `grep -n 'mm_raw_callback raw_callback' minimidio.h && grep -nE 'int +is_raw' minimidio.h` | correctness | D1 | open | | |
| F-4 | Three raw functions publicly declared | `grep -c -E 'mm_(in_open_raw|in_open_virtual_raw|out_send_raw)' minimidio.h` (≥ 6: 3 decls + ≥3 defs) | correctness | D1 | open | | |
| F-5 | CoreMIDI device struct gains `sysex_pos` accumulator | `awk '/mm__dev_coremidi/,/} mm__dev_coremidi/' minimidio.h \| grep 'sysex_pos'` | correctness | D4 | open | | |
| F-6 | CoreMIDI `mm_context_caps` advertises `MM_CAP_RAW` | `sed -n '/^uint32_t mm_context_caps/,/^}/p' minimidio.h \| grep 'MM_CAP_RAW'` | polish | D5 | open | | |
| F-7 | WinMM/ALSA/WebMIDI define raw stubs returning `MM_NO_BACKEND` | CDC reads diff: each non-CoreMIDI section defines all 3 raw fns, body `return MM_NO_BACKEND;` | polish | D6 | open | | grep-assisted, CDC confirms by section |
| F-8 | Harness + header compile clean, no warnings | `cc tests/raw_loopback.c -framework CoreMIDI -Wall -Wextra -o /tmp/raw_loopback; echo exit=$?` (exit=0, zero warnings) | serious | D7 | open | | |
| F-9 | **T1** short channel msg round-trips byte-exact (`90 3C 40` in = `90 3C 40` out) | `/tmp/raw_loopback \| grep '^PASS T1'` | serious | proposal §5.1 | open | | |
| F-10 | **T2** note-on velocity 0 passes through unfolded (`90 3C 00` stays `90 3C 00`, not `80 …`) | `/tmp/raw_loopback \| grep '^PASS T2'` | serious | §5.1 / U2 | open | | |
| F-11 | **T3** >256-byte SysEx round-trips whole, one callback, intact `F0…F7` | `/tmp/raw_loopback \| grep '^PASS T3'` | serious | §5.4 / U1 | open | | the no-cap proof |
| F-12 | **T4** `F8` mid-SysEx → own 1-byte callback AND SysEx payload contains no `F8` | `/tmp/raw_loopback \| grep '^PASS T4'` | serious | §5.2 / U3 | open | | |
| F-13 | **T5** runtime caps query reports `MM_CAP_RAW` set | `/tmp/raw_loopback \| grep '^PASS T5'` | polish | D5 | open | | |
| F-14 | **T6** additive: existing examples compile unchanged AND struct-mode receive still decodes correctly | `cc examples/monitor.c -framework CoreMIDI -o /tmp/monitor; echo exit=$?` (=0) AND `/tmp/raw_loopback \| grep '^PASS T6'` | serious | arc-plan additive constraint | open | | guards the shared read proc |
| F-15 | No diff to existing struct read/send logic | `git diff` shows only additions (new fns, new fields, the `if (dev->is_raw)` dispatch line) — no edits inside the existing struct decode loop or `mm_out_send*` bodies | serious | additive constraint | open | | CDC reads the diff |

## What Worked

_(Filled in at slice close.)_

## Closure

_(Filled in at slice close. Total rows: 15. Done: _ / Deferred: _ / No-op: _.
Closed at commit ___ on ___. CDC verification: ___.)_
