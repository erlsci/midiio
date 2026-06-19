# Slice 02 — ALSA raw I/O — CDC verification

*Independent verification of CC's closed ledger, per LEDGER_DISCIPLINE CDC protocol.*
*Verifier: Claude (CDC), 2026-06-18. Commit under review: `107107f` (parent `f71c3c0`).*

## Verdict

**PASS.** All 14 rows validly closed. Both disclosed deviations (D1 two-context
harness, D2 close-raw-input-before-T6) are legitimate, ALSA-forced adaptations —
verified at the source, not papering over a defect. The implementation is correct
and strictly additive (struct decode switch and `mm_out_send*` bodies byte-for-byte
unchanged). No silent drops (14 opened, 14 closed).

**Notably, D1 is CC correcting an architect error in this slice's own slice-doc**
(§D6 assumed single-context self-loopback works on ALSA; it cannot). The slice-doc
has been corrected to match — see the note appended to its §D6.

## CDC capability boundary (disclosed)

CDC has no ALSA/Linux runtime in this environment, so the behavioral rows
(A-6 compile, A-7…A-12 run in the Multipass VM) are verified **by inspection plus
CC's VM execution, not re-executed by CDC**: I read the harness to confirm the
tests are non-vacuous and audited the implementation for correctness. The source
rows (A-1…A-5) and the additive claim (A-13) I reproduced fully from the commit.

## Per-row dispositions

| Row | CDC action | Result |
|-----|------------|--------|
| A-0 VM viable | accept (CC evidence) | ✓ pkg-config install sanctioned by slice-doc; toolchain otherwise complete |
| A-1 raw fns real | ran grep | ✓ 3 fns defined in ALSA section; **zero** `MM_NO_BACKEND` in their bodies |
| A-2 `midi_ev` field | ran awk | ✓ on `mm__dev_alsa` |
| A-3 `is_raw` recv branch | read diff | ✓ gated, placed before the struct switch, own `snd_seq_event_input` + `continue` |
| A-4 `snd_midi_event_encode` | ran grep | ✓ in `mm_out_send_raw` |
| A-5 caps advertise RAW | ran awk/grep | ✓ ALSA caps `… \| MM_CAP_RAW` |
| A-6 compile, no new warnings | inspection + CC VM | ✓ CC reports literal zero (UMP helpers *are* used on ALSA, so no F-8-style residual) |
| A-7 T1 byte-exact | read harness | ✓ non-vacuous; reset→send→`wait_for_raw`→exact compare |
| A-8 T2 vel-0 unfold | read harness + impl | ✓ asserts `90 3C 00` *and* status `0x90`; `snd_midi_event_decode` doesn't fold — U2 passthrough for free |
| A-9 T3 large SysEx | read harness + impl | ✓ asserts `count==1 && len==N && F0…F7 && payload intact`; encoder/decoder uncapped to buffer |
| A-10 T4 RT framing | read harness | ✓ asserts standalone F8 + clean SysEx; ALSA separates RT as own events |
| A-11 T5 runtime caps | read harness | ✓ |
| A-12 T6 additive | read harness + diff | ✓ struct decode asserted (type/chan/data); raw input closed first (D2) |
| A-13 no struct-path diff | **read full diff** | ✓ struct switch & `mm_out_send*` bodies byte-unchanged — see scope note below |

## Implementation audit (beyond the ledger)

- **Raw inbound branch** reads its own event and `continue`s, so the struct
  path's `snd_seq_event_input` is never reached in raw mode — no double-read, no
  lost event. SysEx accumulates whole (bounds-checked, drop-on-overflow, mirrors
  the struct accumulator); non-SysEx events go through `snd_midi_event_decode`
  into a 16-byte buffer (ample for any non-SysEx message).
- **`no_status(1)`** is set on the decoder in both raw opens → each event decodes
  with a full status byte (byte-exact framing, no running-status compression).
- **`mm_out_send_raw`** lazily allocates the coder, `reset_encode`s per call (no
  stale running-status state between calls), loops `snd_midi_event_encode`,
  sends each event via the existing helper. Byte-exact, no cap.
- **Lifecycle:** `midi_ev` allocated in raw opens / lazily in send, freed in both
  `mm_in_close` and `mm_out_close`, each null-guarded and NULLed after — no leak,
  no double-free.

## Deviation adjudications

**D1 — two contexts instead of one. ACCEPTED (and it fixes my design error).**
Verified at source: `mm__alsa_enum` contains `if (cid == al->client_id) continue;`
— the caller's own client is filtered out of enumeration, so a context cannot
discover its *own* virtual source. The slice-doc §D6 single-context loopback was
therefore impossible on ALSA. CC's two-context wiring (separate sender/receiver
clients in one process) is the correct adaptation, is *more* faithful to real
usage (genuine cross-client subscription), and CC re-ran it on macOS/CoreMIDI —
all six cases still pass, so slice 01's behavioral guarantees survive the shared
harness rework. Test intent unchanged.

**D2 — close the raw input before T6. ACCEPTED.** ALSA drains one event queue per
client; a still-running raw recv thread in the receiver client would race the
struct input opened for T6 and could steal the note. Closing the raw input first
is correct sequencing, pre-existing backend behavior, and a no-op on CoreMIDI. It
does not weaken T6, which still fully asserts struct-mode decode.

## Scope note (precision on A-13)

A-13's text protects "the struct decode switch and `mm_out_send*` bodies" — those
are byte-for-byte unchanged (confirmed in the diff). Two *other* existing
functions, `mm_in_close` and `mm_out_close`, each gained one guarded line
(`if (dev->al.midi_ev) { snd_midi_event_free(...); }`). For struct devices
`midi_ev` is always NULL, so these are no-ops — behavior-preserving and necessary
lifecycle. Recorded for completeness; not a violation of the additive guarantee.

## Follow-ups (not blockers)

- Minor inconsistency: `mm_in_open_raw` creates its port with
  `SND_SEQ_PORT_TYPE_APPLICATION` only, while `mm_in_open_virtual_raw` (and the
  struct opens) use `… | MIDI_GENERIC`. PORT_TYPE is informational; harmless, but
  worth aligning for tidiness in a later pass.
- The host clone is left mounted at `midiio-test:/home/ubuntu/minimidio` for
  re-runs (CC's note); unmount when done.

## Closure

Slice 02 CDC-verified **PASS** at `107107f`, 2026-06-18. 14/14 rows valid.
Deviations D1, D2 accepted. Implementation correct and additive. Behavioral rows
carry the disclosed "verified by inspection + CC VM execution, not re-executed by
CDC" caveat. Arc 01 now has CoreMIDI + ALSA landed; slice 03 (WinMM + WebMIDI)
remains.
