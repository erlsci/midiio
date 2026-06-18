# Slice 01 — CoreMIDI raw I/O — Closing Report (CC → CDC)

*Implementer (CC) hand-back for independent verification.*
*Implementation commit: `f71c3c0` on branch `feat/raw-bytes-api` in the
minimidio clone (`/Users/oubiwann/lab/c/minimidio`), parent `bb705e8`.*
*Environment: macOS / Darwin 24.6.0, arm64, Apple clang (Xcode CLT).*

All 15 ledger rows reached a final status: **15 done**, 0 deferred, 0 no-op.
Two rows (F-8, F-14) are `done` with a disclosed **amendment** to their Verify
command; F-8 additionally carries a **caveat**. Both are detailed below and
must be ruled on by CDC. Nothing was silently worked around.

---

## Amendments raised (CDC must rule)

### A1 — Verify commands omit `-framework CoreFoundation` (affects F-8, F-14)

On this Xcode CLT, `-framework CoreMIDI` alone does **not** resolve the
CoreFoundation symbols (`_CFRelease`, `_CFStringCreateWithCString`,
`_CFStringGetCString`) that minimidio's CoreMIDI backend already uses in
`mm_context_init` / `mm__cm_name` / the open functions. This is **pre-existing**
and unrelated to the raw work:

- Base `bb705e8` header compiled into a trivial TU fails to link with
  `-framework CoreMIDI` alone and links with `-framework CoreFoundation` added.
- The repo README documents `cc my_app.c -framework CoreMIDI -o my_app`, which
  reproduces the same link failure here — so the project's own documented macOS
  build command is incomplete on the current CLT (likely worked on an older
  SDK/macOS that re-exported CoreFoundation).

**Proposed amendment:** add `-framework CoreFoundation` to the F-8 and F-14
Verify commands:

```
cc tests/raw_loopback.c -framework CoreMIDI -framework CoreFoundation -Wall -Wextra -o /tmp/raw_loopback
cc examples/monitor.c   -framework CoreMIDI -framework CoreFoundation -o /tmp/monitor
```

With this single addition both commands exit 0. I verified with the corrected
commands; evidence below uses them.

### A2 — F-8 "zero warnings" collides with 2 pre-existing warnings

Under `-Wall -Wextra`, the CoreMIDI translation unit emits **two**
`-Wunused-function` warnings, for `mm__ump_word_count_from_type` and
`mm__ump_midi1_to_message`. These are shared UMP helpers used only by the ALSA
backend, so they are dead on a CoreMIDI build. They are **pre-existing**:
compiling base `bb705e8` with `-Wall -Wextra` produces the identical two
warnings. The raw slice introduces **zero** new warnings.

Silencing them would require editing unrelated, out-of-scope shared code (this
slice is strictly additive and explicitly must not touch the existing
non-raw functions). **Proposed amendment:** scope F-8's "zero warnings" to
"no new warnings from the raw additions; the 2 pre-existing UMP-helper warnings
are tracked separately," or fix them in an independent cleanup PR.

I have marked F-8 `done` because the harness and all raw code are warning-clean
and the binary builds and runs; I am flagging the literal "zero warnings"
sub-clause as **not** met as written. CDC should decide whether that is a
`done` or a `deferred`.

---

## Two disclosed edits to existing lines (context for F-15)

The diff is +186 / −2. The two deletions are **not** in any protected region
(the struct decode loop or the `mm_out_send*` bodies are byte-for-byte
unchanged). They are:

1. **D5 caps line** (mandated by the design, verified by F-6):
   `return MM_CAP_MIDI1 | MM_CAP_VIRTUAL_IN | MM_CAP_VIRTUAL_OUT;`
   → `… | MM_CAP_RAW;`
2. **CoreMIDI struct tag** (required for F-5's `awk` Verify to work):
   `typedef struct {` → `typedef struct mm__dev_coremidi {`. The struct was
   anonymous (unlike the tagged ALSA/WebMIDI device structs). Without a leading
   tag, `awk '/mm__dev_coremidi/,/} mm__dev_coremidi/'` starts and ends on the
   same closing-brace line and never sees the body, so `sysex_pos` would not be
   found. Adding the tag is behaviour-preserving, introduces no field/meaning
   change, and matches the other backends' convention.

The `if (dev && dev->is_raw) { … return; }` dispatch is a **pure insertion**
before the existing `if (!dev || !dev->callback) return;` (the `dev &&` guard
keeps it NULL-safe since it precedes the original NULL check).

---

## Per-row walk (all 15)

> SHA `f71c3c0` for every row. Verify commands run with CWD = the minimidio
> clone root. F-8/F-14 outputs use the A1-amended (CoreFoundation) command.

**F-1 — `mm_raw_callback` typedef — DONE.**
`grep` → `minimidio.h:359 typedef void (*mm_raw_callback)(mm_device* dev,`.
Signature matches D1 (data, len, timestamp, userdata).

**F-2 — `MM_CAP_RAW = 1u << 5` — DONE.**
`grep` → `minimidio.h:340  MM_CAP_RAW          = 1u << 5,  /* … */`.

**F-3 — device gains `raw_callback` + `is_raw` — DONE.**
`grep` → `mm_raw_callback raw_callback;` @536 and `int  is_raw;` @542 in
`struct mm_device`, beside `ump_callback` / `is_ump`.

**F-4 — three raw functions publicly declared — DONE.**
`grep -c` = **16** (≥ 6). The three public declarations are at lines
580 (`mm_in_open_raw`), 597 (`mm_in_open_virtual_raw`), 607 (`mm_out_send_raw`).

**F-5 — CoreMIDI struct gains `sysex_pos` — DONE (with disclosed tag edit).**
`awk … | grep sysex_pos` first match = `size_t  sysex_pos;  /* raw path:
cross-packet SysEx accumulator */`. See "disclosed edits" re the struct tag
that makes the awk range cover the body.

**F-6 — CoreMIDI `mm_context_caps` advertises `MM_CAP_RAW` — DONE.**
`sed … | grep` → `return MM_CAP_MIDI1 | MM_CAP_VIRTUAL_IN | MM_CAP_VIRTUAL_OUT
| MM_CAP_RAW;`. (Only the CoreMIDI caps fn gains the bit; WinMM/ALSA/WebMIDI
do not — correct per D6.)

**F-7 — WinMM/ALSA/WebMIDI raw stubs return `MM_NO_BACKEND` — DONE.**
Each non-CoreMIDI section defines all three raw functions with body
`return MM_NO_BACKEND;`:
- WinMM: `mm_in_open_raw`@1284, `mm_in_open_virtual_raw`@1287, `mm_out_send_raw`@1290
- ALSA: @1750 / @1753 / @1756
- WebMIDI: @2253 / @2256 / @2259

CoreMIDI carries the real implementations (@972, @1131, @1080). CDC: confirm by
reading each section in the diff.

**F-8 — harness + header compile clean — DONE\* (amendments A1 + A2).**
`cc tests/raw_loopback.c -framework CoreMIDI -framework CoreFoundation -Wall
-Wextra -o /tmp/raw_loopback` → **exit=0**. Warnings: **2**, both pre-existing
UMP-helper `-Wunused-function` (reproduced on base `bb705e8`); zero new
warnings from raw code. See A1 (CF flag) and A2 (warnings) above. **This is the
one row I am least comfortable marking `done`** — the literal "zero warnings"
is not met; I mark it `done` only on the in-scope reading (raw code is clean,
builds, runs) and defer the literal clause to CDC.

**F-9 — T1 short message byte-exact — DONE.**
`/tmp/raw_loopback | grep '^PASS T1'` → `PASS T1`. Sends `90 3C 40`, receives
exactly `90 3C 40`.

**F-10 — T2 velocity-0 unfolded — DONE.**
`PASS T2`. Sends `90 3C 00`, receives exactly `90 3C 00` (status byte still
`0x90`, not folded to `0x80`).

**F-11 — T3 >256-byte SysEx whole, one callback — DONE (the no-cap proof).**
`PASS T3`. 300-byte SysEx (`F0` + 298 + `F7`) sent via `mm_out_send_raw` on the
virtual source (the `MIDIReceived` branch, where the U1 cap lived); received in
**exactly one** callback, length 300, intact `F0…F7`, payload byte-identical.

**F-12 — T4 F8 mid-SysEx — DONE.**
`PASS T4`. Buffer `F0 7E 00 01 02 F8 03 04 F7` yields a standalone 1-byte `F8`
callback **and** a SysEx callback whose payload contains no `0xF8`.

**F-13 — T5 caps query reports `MM_CAP_RAW` — DONE.**
`PASS T5`. `mm_context_caps(&ctx) & MM_CAP_RAW` is non-zero at runtime.

**F-14 — T6 additive: example compiles + struct decode intact — DONE\* (A1).**
`cc examples/monitor.c -framework CoreMIDI -framework CoreFoundation -o
/tmp/monitor` → **exit=0**; `/tmp/raw_loopback | grep '^PASS T6'` → `PASS T6`.
A struct-mode `mm_in_open` on the **same** virtual source still decodes a
note-on to `MM_NOTE_ON` (ch 5, data 0x40/0x65) — the shared read proc is
unbroken. (A1: monitor needs the CoreFoundation flag, same as F-8.)

**F-15 — no diff to existing struct read/send logic — DONE.**
`git diff` = +186/−2. The struct decode `while` loop in `mm__cm_read_proc` and
all `mm_out_send` / `mm_out_send_sysex` / `mm_out_send_ump` bodies are
byte-for-byte unchanged. The only existing-line edits are the D5 caps line
(F-6) and the struct tag (F-5), both disclosed above; the dispatch line is a
pure insertion. CDC: read the diff to confirm.

---

## Coverage beyond the numbered rows

The harness also runs a non-ledger **coverage case** exercising
`mm_in_open_virtual_raw` + `mm_out_open` (the `MIDISend` branch): a CC message
sent to a raw virtual destination round-trips byte-exact. It prints
`[coverage] … round-trip OK` to **stderr** (kept off stdout so only the six
`PASS T<n>` lines appear there). This ensures `mm_in_open_virtual_raw` is
genuinely exercised, not just compiled.

## Items I am uncertain about (named, per protocol)

1. **F-8 literal "zero warnings"** — not met as written (2 pre-existing
   warnings). Marked `done` on the in-scope reading; flagged as A2. This is the
   row most likely to warrant a status change by CDC.
2. **F-8 / F-14 link flag (A1)** — I changed the Verify command (added
   `-framework CoreFoundation`). If CDC's environment re-exports CoreFoundation
   via CoreMIDI, the original commands may pass there; the amendment is
   nonetheless correct on the stated "macOS with Xcode CLT" target here.
3. **Single-packet vs multi-packet SysEx (S1).** T3's 300-byte SysEx passed,
   but I did not confirm whether CoreMIDI delivered it as one packet or several
   on this run; the cross-packet accumulator (`cm.sysex_pos`) is implemented
   and correct by construction, but the test does not *force* fragmentation, so
   the multi-packet reassembly path is exercised only if CoreMIDI chose to
   fragment. Worth a dedicated repro in a later slice (matches the S1 note).

## Hand-back

Ledger fully closed (15/15 final). Two amendments (A1, A2) await a CDC ruling.
Requesting independent verification per LEDGER_DISCIPLINE CDC protocol:
re-run every `done` row's Verify (with the A1 flag), read the diff for F-7/F-15,
and rule on A1/A2 and the F-8 caveat.
