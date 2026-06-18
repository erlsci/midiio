# Slice 02 — ALSA raw I/O — Ledger

*Protocol:* `collaboration-framework/templates/LEDGER_DISCIPLINE.md`.
CC implements against these rows; CDC re-runs every `Verify`.

*Behavioral rows run **inside the midiio-NIF Multipass VM**, at the minimidio
clone root, with the `feat/raw-bytes-api` branch checked out. Source greps run
anywhere. Iteration budget: 5.*

## Ledger

| ID | Criterion | Verify | Significance | Origin | Status | Evidence | Notes |
|----|-----------|--------|--------------|--------|--------|----------|-------|
| A-0 | VM is a viable ALSA test bed (snd-seq + toolchain) | in VM: `ls /dev/snd/seq && pkg-config --modversion alsa && gcc --version \| head -1` (all succeed) | serious | slice-doc test-bed | open | | smoke/confirmation; reuse existing VM |
| A-1 | ALSA defines all 3 raw fns as real (not `MM_NO_BACKEND`) | `awk '/#elif defined\(MM_BACKEND_ALSA\)/,/#elif defined\(MM_BACKEND_WEBMIDI\)/' minimidio.h \| grep -E 'mm_(in_open_raw\|in_open_virtual_raw\|out_send_raw)'` shows defns; none return `MM_NO_BACKEND` | serious | D2–D4 | open | | |
| A-2 | `mm__dev_alsa` gains `snd_midi_event_t* midi_ev` | `awk '/mm__dev_alsa/,/} mm__dev_alsa/' minimidio.h \| grep 'midi_ev'` | correctness | D1 | open | | |
| A-3 | Raw branch added to recv thread, gated on `is_raw` | `sed -n '/mm__alsa_recv_thread/,/^}/p' minimidio.h \| grep 'is_raw'` | serious | D2 | open | | must sit before the struct switch |
| A-4 | `mm_out_send_raw` uses `snd_midi_event_encode` | `grep -n 'snd_midi_event_encode' minimidio.h` | correctness | D3 | open | | |
| A-5 | ALSA `mm_context_caps` advertises `MM_CAP_RAW` | `awk '/#elif defined\(MM_BACKEND_ALSA\)/,/#elif defined\(MM_BACKEND_WEBMIDI\)/' minimidio.h \| sed -n '/mm_context_caps/,/}/p' \| grep 'MM_CAP_RAW'` | polish | D5 | open | | |
| A-6 | Harness + header compile clean on ALSA, no warnings | in VM: `cc tests/raw_loopback.c -lasound -lpthread -Wall -Wextra -o /tmp/raw_loopback; echo exit=$?` (=0, zero warnings) | serious | D6 | open | | |
| A-7 | **T1** short channel msg round-trips byte-exact | `/tmp/raw_loopback \| grep '^PASS T1'` | serious | §5.1 | open | | |
| A-8 | **T2** note-on vel 0 passes through unfolded (`90 3C 00` stays, not `80 …`) | `/tmp/raw_loopback \| grep '^PASS T2'` | serious | §5.1 / U2 | open | | **headline for this backend** |
| A-9 | **T3** >256-byte SysEx round-trips whole, intact `F0…F7` | `/tmp/raw_loopback \| grep '^PASS T3'` | serious | §5.4 | open | | |
| A-10 | **T4** real-time event interleaved with SysEx → own callback + clean SysEx | `/tmp/raw_loopback \| grep '^PASS T4'` | serious | §5.2 | open | | ALSA separates these as events; assert it holds |
| A-11 | **T5** runtime caps query reports `MM_CAP_RAW` | `/tmp/raw_loopback \| grep '^PASS T5'` | polish | D5 | open | | |
| A-12 | **T6** additive: existing ALSA example compiles unchanged AND struct receive still decodes (incl. its existing vel-0 fold) | in VM: `cc examples/monitor.c -lasound -lpthread -o /tmp/monitor; echo exit=$?` (=0) AND `/tmp/raw_loopback \| grep '^PASS T6'` | serious | additive constraint | open | | proves struct path untouched |
| A-13 | No diff to existing struct decode switch / `mm_out_send*` bodies | `git diff` shows only additions + the `if (dev->is_raw)` branch in the recv thread | serious | additive constraint | open | | CDC reads the diff |

## What Worked

_(Filled in at slice close.)_

## Closure

_(Filled in at slice close. Total rows: 14. Done: _ / Deferred: _ / No-op: _.
Closed at commit ___ on ___. CDC verification: ___.)_
