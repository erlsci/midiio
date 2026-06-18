# Slice 02 — ALSA raw I/O — Closing Report (CC → CDC)

*Implementer (CC) hand-back for independent verification.*
*Implementation commit: `107107f` on branch `feat/raw-bytes-api` (parent
`f71c3c0`, the slice-01 close). Source greps reproducible anywhere; behavioral
rows run in the `midiio-test` Multipass VM (Ubuntu 24.04.4 LTS, aarch64).*

All 14 ledger rows reached a final status: **14 done**, 0 deferred, 0 no-op.
No row carries an amendment to its Verify command (contrast slice 01's F-8/F-14).
There are **two disclosed deviations from the slice-doc** — both in the *harness*
wiring, neither a change to the library logic or to test intent — described next.

---

## Disclosed deviations from the slice-doc (CDC please confirm)

### D1 — Harness uses two contexts, not one (slice-doc §D6 assumed one)

The slice-doc's §D6 topology is single-context: create a virtual source in a
context, then find it in *that same context's* input list via `mm_in_name` and
open it with `mm_in_open_raw`. **That cannot work on ALSA**: `mm__alsa_enum`
deliberately skips the caller's own client (`if (cid == al->client_id)
continue;`), so a port created in a context is invisible to that context's own
enumeration. Empirically the single-context harness failed at setup with
"virtual source did not appear in input list".

Fix (harness only, public API only): use **two `mm_context`s** — a sender that
owns the virtual source and a receiver that enumerates it cross-client and opens
the raw input. This is ordinary cross-client sequencer routing on ALSA and works
identically on CoreMIDI (two MIDI clients in one process). T1–T6 are unchanged
in intent and byte content. Because this is shared test code, I re-ran the whole
harness on **macOS/CoreMIDI** too — all six cases still pass there (so slice 01's
behavioral guarantees hold under the reworked harness).

### D2 — Raw input closed before T6

ALSA delivers events to a **client** (one `snd_seq_t` queue), and each minimidio
input port runs its own recv thread draining that shared queue. With the raw
input *and* a struct input open in one receiver context, the two threads race to
consume events; the raw thread would pull the struct note and route it to the
raw callback, leaving the struct capture empty (this is exactly what failed
first). T6's intent is "the struct path still decodes," so the harness closes the
raw input before opening the struct input — one recv thread in the receiver for
the struct check. This is pre-existing ALSA backend behavior (multiple inputs per
context share one drain), not introduced by the raw work, and is a no-op on
CoreMIDI's per-port delivery.

### Provisioning note (A-0)

The VM lacked `pkg-config` (used only by A-0's Verify); installed with
`sudo apt-get install -y pkg-config`. The slice-doc explicitly sanctions
`apt-get` provisioning. `gcc`, `libasound2-dev`, `libasound.so`, and
`/dev/snd/seq` were already present.

---

## Additive proof (A-13 context)

`git diff bb705e8 -- minimidio.h` deletions are only:
1. the D5 caps line (`… VIRTUAL_OUT;` → `… VIRTUAL_OUT | MM_CAP_RAW;`),
   verified by A-5; and
2. the three one-line ALSA raw **stub** bodies from slice 01, replaced by real
   implementations — which is precisely what A-1 requires.

The per-type `switch (ev->type)` in `mm__alsa_recv_thread` (including the
existing vel-0 fold), and the `mm_out_send` / `mm_out_send_sysex` /
`mm_out_send_ump` bodies, are **byte-for-byte unchanged**. The raw inbound branch
is a pure insertion before the switch; the two `snd_midi_event_free` calls added
to `mm_in_close` / `mm_out_close` are additions to lifecycle teardown (guarded by
`if (dev->al.midi_ev)`, so struct devices — where `midi_ev` is NULL — are
unaffected).

---

## Per-row walk (all 14)

> SHA `107107f`. Source rows run at the clone root (any host). Behavioral rows
> run in the `midiio-test` VM at `/home/ubuntu/minimidio` (host clone mounted),
> built `-lasound -lpthread`.

**A-0 — VM viable test bed — DONE.**
In VM: `/dev/snd/seq` present; `pkg-config --modversion alsa` → `1.2.11`;
`gcc --version` → `13.3.0`. (pkg-config installed first — see note above.)

**A-1 — ALSA defines all 3 raw fns, none `MM_NO_BACKEND` — DONE.**
`awk` over the ALSA section shows `mm_in_open_raw`, `mm_in_open_virtual_raw`,
`mm_out_send_raw` definitions; `grep -c MM_NO_BACKEND` across those three = **0**.

**A-2 — `mm__dev_alsa` gains `snd_midi_event_t* midi_ev` — DONE.**
`awk '/mm__dev_alsa/,/} mm__dev_alsa/' | grep midi_ev` → `snd_midi_event_t*
midi_ev;`.

**A-3 — raw branch in recv thread, gated on `is_raw`, before the switch — DONE.**
`sed -n '/mm__alsa_recv_thread/,/^}/p' | grep is_raw` → `if (dev->is_raw) {`.
Placed after the `#endif` closing the `is_ump` branch and before
`switch (ev->type)`.

**A-4 — `mm_out_send_raw` uses `snd_midi_event_encode` — DONE.**
`grep -n snd_midi_event_encode` → one hit, inside `mm_out_send_raw`'s encode
loop.

**A-5 — ALSA `mm_context_caps` advertises `MM_CAP_RAW` — DONE.**
ALSA caps line: `uint32_t caps = MM_CAP_MIDI1 | MM_CAP_VIRTUAL_IN |
MM_CAP_VIRTUAL_OUT | MM_CAP_RAW;`.

**A-6 — harness builds on ALSA, no new warnings — DONE (clean, literal zero).**
In VM: `cc tests/raw_loopback.c -lasound -lpthread -Wall -Wextra` → exit=0,
**warnings=0**. A base-`bb705e8` trivial-TU build on ALSA with the same flags also
yields 0 warnings, so the raw additions add zero. (Unlike CoreMIDI/F-8, there is
no residual: the `mm__ump_*` helpers are *used* on the ALSA backend, so they do
not warn.)

**A-7 — T1 short message byte-exact — DONE.** `PASS T1` (`90 3C 40` round-trips).

**A-8 — T2 velocity-0 unfolded — DONE (the backend headline).** `PASS T2`:
`90 3C 00` stays `90 3C 00` — `snd_midi_event_decode` does not fold to note-off.
This is the meaningful one for ALSA, the backend that folds in struct mode.

**A-9 — T3 >256-byte SysEx whole — DONE.** `PASS T3`: 300-byte `F0…F7` sent via
`mm_out_send_raw` (encoded to one variable SysEx event), received in one callback,
intact and byte-identical.

**A-10 — T4 real-time interleaved with SysEx — DONE.** `PASS T4`: the mid-stream
`F8` is encoded/delivered as its own 1-byte event; the SysEx payload contains no
`F8`.

**A-11 — T5 caps query reports `MM_CAP_RAW` — DONE.** `PASS T5`.

**A-12 — T6 additive: example compiles + struct decode intact — DONE.**
In VM: `cc examples/monitor.c -lasound -lpthread -o /tmp/monitor` → exit=0;
`PASS T6` (struct-mode `mm_in_open` decodes the note-on to `MM_NOTE_ON`, ch 5,
data 0x40/0x65). The struct path is unbroken.

**A-13 — no diff to existing struct decode switch / `mm_out_send*` bodies — DONE.**
See "Additive proof" above. The only deletions are the D5 caps line and the
replaced slice-01 stubs; protected regions are byte-unchanged.

---

## Coverage beyond the numbered rows

The harness also runs a non-ledger coverage case exercising
`mm_in_open_virtual_raw` (a raw virtual destination on the receiver) +
`mm_out_open` (a real output on the sender) → a CC round-trips byte-exact. Prints
`[coverage] … round-trip OK` to **stderr** so stdout carries only the `PASS T<n>`
lines. Passed on both backends.

## Items I am uncertain about (named, per protocol)

1. **The two harness deviations (D1, D2).** I'm confident they're necessary and
   correct (and re-verified on macOS), but they *are* changes to shared slice-01
   test code, so CDC should confirm they don't weaken any slice-01 row. The
   slice-01 cases still print `PASS T1…T6` on macOS under the reworked harness.
2. **SysEx chunking on receive.** A-9 passed, but on this run the 300-byte SysEx
   evidently arrived as a single `SND_SEQ_EVENT_SYSEX` event; the cross-event
   accumulator (D2 inbound) is implemented and correct by construction, but the
   test did not *force* multi-event fragmentation. A dedicated fragmenting repro
   would strengthen it (carries over the slice-01 S1 note).
3. **`snd_midi_event_encode` "needs more bytes" path.** The encode loop breaks on
   `used <= 0`. For the tested inputs every byte was consumed; a deliberately
   truncated/partial buffer is not exercised. Not in scope for T1–T6, noted for
   completeness.

## Hand-back

Ledger fully closed (14/14 final, all `done`). Requesting independent CDC
verification per LEDGER_DISCIPLINE: re-run the source greps (A-1…A-5, A-13) on
any host and the behavioral rows (A-0, A-6…A-12) in the VM, and rule on the two
disclosed harness deviations (D1, D2).
