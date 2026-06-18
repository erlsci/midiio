# Slice 01 — CoreMIDI raw I/O — CDC verification

*Independent verification of CC's closed ledger, per LEDGER_DISCIPLINE CDC protocol.*
*Verifier: Claude (CDC), 2026-06-18. Commit under review: `f71c3c0` (parent `bb705e8`).*

## Verdict

**PASS.** All 15 rows validly closed. Two amendments (A1, A2) accepted as
legitimate Verify-command / criterion corrections — not spec-softening. The
implementation is correct and strictly additive. No silent drops (15 opened,
15 closed). Two disclosed behavioral caveats below; neither blocks the slice.

## CDC capability boundary (disclosed)

The CDC context (this sandbox) has **no macOS / CoreMIDI**, so I cannot *execute*
the behavioral rows (F-8 compile, F-9…F-14 run). My independent verification of
those rows is therefore **by inspection, not re-execution**: I read the harness
source to confirm the tests are non-vacuous and race-free, and I audited the
implementation to confirm it is correct on the paths the tests exercise. This is
weaker than re-running and is recorded as such. The source-grep and diff rows
(F-1…F-7, F-15) I reproduced fully and independently.

## Per-row dispositions

| Row | CDC action | Result |
|-----|------------|--------|
| F-1 typedef | ran grep | ✓ `minimidio.h:359`, signature matches |
| F-2 cap bit | ran grep | ✓ `:340`, `MM_CAP_RAW = 1u << 5` |
| F-3 device fields | ran grep | ✓ `raw_callback`@536, `is_raw`@542 |
| F-4 decls | ran grep -c | ✓ 16 (≥6); 3 public decls @580/597/607 |
| F-5 cm `sysex_pos` | ran awk range | ✓ field present in `mm__dev_coremidi`; the struct tag added so the awk range resolves is behavior-preserving (verified in diff) |
| F-6 caps advertise RAW | ran sed/grep | ✓ CoreMIDI caps `… \| MM_CAP_RAW` |
| F-7 stubs | read diff per section | ✓ WinMM/ALSA/WebMIDI each define all 3 raw fns `{ …; return MM_NO_BACKEND; }` |
| F-8 compile clean | **inspection + A1/A2** | ✓ with caveats — see amendments |
| F-9 T1 byte-exact | read harness | ✓ non-vacuous: reset→send→`wait_for_raw`→`len==3 && memcmp==0` |
| F-10 T2 vel-0 unfold | read harness | ✓ asserts exact `90 3C 00` *and* `bytes[0]==0x90` (fold guard) |
| F-11 T3 large SysEx | read harness + impl | ✓ asserts `count==1 && len==N && F0…F7`; impl uses heap-sized packet list (no cap) |
| F-12 T4 RT framing | read harness + impl | ✓ asserts F8 own callback + no F8 in SysEx; impl checks `>=0xF8` *before* sysex-accumulate (correct ordering) |
| F-13 T5 runtime caps | read harness | ✓ `caps & MM_CAP_RAW` |
| F-14 T6 additive | read harness + diff | ✓ struct-mode decode asserted (type/chan/data); existing example compiles (A1 flag) |
| F-15 no struct-path diff | **read full diff** | ✓ struct decode loop & all `mm_out_send*` bodies byte-unchanged; only 2 edits (caps line F-6, struct tag F-5), both disclosed; dispatch is a pure 1-line insertion |

## Implementation audit (beyond the ledger — what the tests don't force)

I read `mm__cm_raw_dispatch` and `mm_out_send_raw` line by line:

- **Framing order is correct.** `if (b >= 0xF8)` is checked *before* the
  sysex-in-progress branch, so a real-time byte mid-SysEx is delivered as its own
  callback and excluded from the payload — the U3-correct behavior, by construction.
- **SysEx accumulation is bounds-safe.** The `sysex_pos >= MM_SYSEX_BUF_SIZE`
  check precedes every write; max write index is 4095. Cross-packet/cross-call
  state lives in `cm.sysex_pos`, so a fragmented SysEx reassembles whole.
- **Channel/system framing matches the `data_byte_count` table** in slice-doc D4;
  `msg[3]` is never overrun (max status + 2 data).
- **`mm_out_send_raw`** sizes the packet list on the heap (`sizeof(MIDIPacketList)
  + len`), frees on every path (no leak), and branches `MIDIReceived` (virtual) /
  `MIDISend` (real). The heap sizing is the genuine U1-avoidance.
- **Opens** mirror the struct opens, set `is_raw=1` with `callback` left NULL; the
  dispatch line intercepts before the `!dev->callback` early-return.

**Three benign edge cases found** (none in scope, none a regression — recorded for
completeness):

1. A SysEx exceeding `MM_SYSEX_BUF_SIZE` (4096) drops on overflow, after which a
   later lone `F7` emits a spurious 1-byte callback. Only triggers above the
   documented buffer limit (matches the existing struct/ALSA cap). 
2. A single MIDI message split across CoreMIDI packets would deliver truncated.
   CoreMIDI does not split complete short messages across packets in practice, and
   the existing struct read proc shares this assumption — not a new defect.
3. `mm_out_send_raw` with `len > 65535` (UInt16 packet length) is untested; far
   beyond MIDI/SysEx norms.

## Amendment adjudications

**A1 — `-framework CoreFoundation` missing from F-8/F-14 Verify commands. ACCEPTED.**
The Verify commands inherited minimidio's own README build line, which omits
`-framework CoreFoundation`; on the current Xcode CLT, `CFRelease`/`CFString…`
don't resolve without it. I confirmed the symbols are CoreFoundation and that the
base `bb705e8` uses them identically — so this is a *ledger-command* defect, not an
implementation defect. The corrected commands are the canonical ones.
*Side finding (separate from this slice):* minimidio's README build commands may
be incomplete on current toolchains — candidate for a tiny doc note to the
maintainer, independent of this work.

**A2 — F-8 "zero warnings" unmet (2 pre-existing `-Wunused-function`). ACCEPTED.**
Structurally confirmed: `mm__ump_word_count_from_type` and `mm__ump_midi1_to_message`
exist on base `bb705e8` (5 refs), are untouched by this diff (0 hits), and are
referenced only at lines 1540/1550/1881 — all inside ALSA UMP paths that compile
out on macOS, so they are defined-but-unused on the CoreMIDI build. **Zero new
warnings come from the raw code.** F-8's literal "zero warnings" mis-specified the
intent (it tested whole-header cleanliness, which was already false at base). The
correct criterion is *"no NEW warnings from the raw additions"* — which is met.
This is criterion correction, not spec-softening, because the failing part is
outside what the slice changes.

## Follow-ups for the arc (not blockers)

- **Ledger wording, slice 02 onward:** state F-8-equivalent as *"no new warnings
  from the slice's additions"* and include `-framework CoreFoundation` (and for
  ALSA, `-lasound -lpthread`) in compile Verify commands.
- **Coverage gap (concur with CC):** T3 proves whole-SysEx delivery but does not
  *force* multi-packet fragmentation; the cross-packet accumulator is verified by
  inspection (correct), not by execution. Same shape as the S1 note. Acceptable.
- **Optional maintainer notes:** the README link-flag gap and the 2 pre-existing
  unused-function warnings are minor, pre-existing, and could ride along in the
  eventual PR or a separate doc — not this slice's responsibility.

## Closure

Slice 01 CDC-verified **PASS** at `f71c3c0`, 2026-06-18. 15/15 rows valid.
Amendments A1, A2 accepted. Implementation correct and additive. Behavioral rows
carry the disclosed "verified by inspection + CC execution, not re-executed by
CDC" caveat. Cleared to proceed to slice 02.
