# Slice 02 — ALSA raw I/O — Ledger

*Protocol:* `collaboration-framework/templates/LEDGER_DISCIPLINE.md`.
CC implements against these rows; CDC re-runs every `Verify`.

*Behavioral rows run **inside the midiio-NIF Multipass VM**, at the minimidio
clone root, with the `feat/raw-bytes-api` branch checked out. Source greps run
anywhere. Iteration budget: 5.*

## Ledger

| ID | Criterion | Verify | Significance | Origin | Status | Evidence | Notes |
|----|-----------|--------|--------------|--------|--------|----------|-------|
| A-0 | VM is a viable ALSA test bed (snd-seq + toolchain) | in VM: `ls /dev/snd/seq && pkg-config --modversion alsa && gcc --version \| head -1` (all succeed) | serious | slice-doc test-bed | done | `midiio-test` (Ubuntu 24.04, aarch64): `/dev/snd/seq` present, alsa 1.2.11, gcc 13.3.0. `pkg-config` was missing — installed via `apt-get install pkg-config` (sanctioned provisioning) | smoke/confirmation; reuse existing VM |
| A-1 | ALSA defines all 3 raw fns as real (not `MM_NO_BACKEND`) | `awk '/#elif defined\(MM_BACKEND_ALSA\)/,/#elif defined\(MM_BACKEND_WEBMIDI\)/' minimidio.h \| grep -E 'mm_(in_open_raw\|in_open_virtual_raw\|out_send_raw)'` shows defns; none return `MM_NO_BACKEND` | serious | D2–D4 | done | 107107f; 3 defns in ALSA section; `grep -c MM_NO_BACKEND` over those fns = 0 | |
| A-2 | `mm__dev_alsa` gains `snd_midi_event_t* midi_ev` | `awk '/mm__dev_alsa/,/} mm__dev_alsa/' minimidio.h \| grep 'midi_ev'` | correctness | D1 | done | 107107f; `snd_midi_event_t* midi_ev;` in `mm__dev_alsa` | |
| A-3 | Raw branch added to recv thread, gated on `is_raw` | `sed -n '/mm__alsa_recv_thread/,/^}/p' minimidio.h \| grep 'is_raw'` | serious | D2 | done | 107107f; `if (dev->is_raw) {` — placed after the `#endif` of the is_ump branch and **before** `switch (ev->type)` | must sit before the struct switch |
| A-4 | `mm_out_send_raw` uses `snd_midi_event_encode` | `grep -n 'snd_midi_event_encode' minimidio.h` | correctness | D3 | done | 107107f; `snd_midi_event_encode(dev->al.midi_ev, …)` in `mm_out_send_raw` | |
| A-5 | ALSA `mm_context_caps` advertises `MM_CAP_RAW` | `awk '/#elif defined\(MM_BACKEND_ALSA\)/,/#elif defined\(MM_BACKEND_WEBMIDI\)/' minimidio.h \| sed -n '/mm_context_caps/,/}/p' \| grep 'MM_CAP_RAW'` | polish | D5 | done | 107107f; `caps = … \| MM_CAP_RAW;` | |
| A-6 | Harness + header compile on ALSA, no **new** warnings from the raw additions | in VM: `cc tests/raw_loopback.c -lasound -lpthread -Wall -Wextra -o /tmp/raw_loopback; echo exit=$?` (=0); compare warnings against a base-`bb705e8` build — raw code adds zero | serious | D6 / slice-01 CDC (A2 lesson) | done | 107107f; exit=0, **warnings=0**. Base bb705e8 trivial-TU build on ALSA also 0 warnings → raw adds 0. (No CoreMIDI-style residual: the UMP helpers are *used* on the ALSA backend.) | pre-existing base warnings don't count |
| A-7 | **T1** short channel msg round-trips byte-exact | `/tmp/raw_loopback \| grep '^PASS T1'` | serious | §5.1 | done | 107107f (in VM); `PASS T1` | |
| A-8 | **T2** note-on vel 0 passes through unfolded (`90 3C 00` stays, not `80 …`) | `/tmp/raw_loopback \| grep '^PASS T2'` | serious | §5.1 / U2 | done | 107107f (in VM); `PASS T2` — `snd_midi_event_decode` of a vel-0 note-on yields `90 3C 00`, unfolded | **headline for this backend** |
| A-9 | **T3** >256-byte SysEx round-trips whole, intact `F0…F7` | `/tmp/raw_loopback \| grep '^PASS T3'` | serious | §5.4 | done | 107107f (in VM); `PASS T3` (300-byte SysEx, one callback, intact) | |
| A-10 | **T4** real-time event interleaved with SysEx → own callback + clean SysEx | `/tmp/raw_loopback \| grep '^PASS T4'` | serious | §5.2 | done | 107107f (in VM); `PASS T4` — F8 mid-stream encodes/decodes as its own 1-byte event; SysEx payload F8-free | ALSA separates these as events; assert it holds |
| A-11 | **T5** runtime caps query reports `MM_CAP_RAW` | `/tmp/raw_loopback \| grep '^PASS T5'` | polish | D5 | done | 107107f (in VM); `PASS T5` | |
| A-12 | **T6** additive: existing ALSA example compiles unchanged AND struct receive still decodes (incl. its existing vel-0 fold) | in VM: `cc examples/monitor.c -lasound -lpthread -o /tmp/monitor; echo exit=$?` (=0) AND `/tmp/raw_loopback \| grep '^PASS T6'` | serious | additive constraint | done | 107107f (in VM); monitor exit=0; `PASS T6` (struct note-on decodes to MM_NOTE_ON ch5 0x40/0x65) | proves struct path untouched |
| A-13 | No diff to existing struct decode switch / `mm_out_send*` bodies | `git diff` shows only additions + the `if (dev->is_raw)` branch in the recv thread | serious | additive constraint | done | 107107f; `git diff bb705e8` deletions = D5 caps line (A-5) + 3 old stub bodies (replaced per A-1) only; struct decode switch & `mm_out_send`/`_sysex`/`_ump` bodies byte-unchanged | CDC reads the diff |

## What Worked

- **ALSA's canonical byte↔event coder gave U2 passthrough for free.**
  `snd_midi_event_decode` of a velocity-0 note-on yields `90 3C 00` unfolded —
  the fold lives only in the hand-written struct switch, which the raw path
  bypasses entirely. The headline correctness win (A-8) needed no special code.
- **`snd_midi_event_no_status(decoder, 1)`** was the one non-obvious must-do:
  without it the decoder uses running status and drops repeated status bytes,
  which the byte-exact T1/T2 comparisons would have caught. Setting it made
  every event self-contained.
- **`snd_midi_event_encode` assembled a whole 300-byte `F0…F7` into one variable
  SysEx event** and split off the interleaved `F8` as its own event — so T3 and
  T4 both fell out of the encoder/decoder pair with no manual framing.
- **Two-context harness** is the portable loopback shape: it sidesteps ALSA's
  own-client enumeration exclusion and works unchanged on CoreMIDI too.

## Closure

Total rows: 14. Done: 14. Deferred: 0. No-op: 0.
Closed at commit `107107f` (minimidio `feat/raw-bytes-api`) on 2026-06-18.
Behavioral rows (A-0, A-6–A-12) run in the `midiio-test` Multipass VM
(Ubuntu 24.04, aarch64). CDC verification: _pending_ — see `closing-report.md`.
Two disclosed deviations from the slice-doc, neither a logic change: (D1) the
harness uses **two contexts** instead of one (ALSA hides own-client ports from
enumeration), and (D2) the raw input is closed before T6 (ALSA drains one event
queue per client). A-6 is clean (literal zero warnings) on this backend.
