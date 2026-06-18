# CC assignment — arc3/slice2: set_owner handoff hardening + virtual-loopback conformance

> Self-contained. Read the arc plan + this prompt, then implement to the ledger.
> This is the **proof slice** — it adds **no new public surface** beyond a tiny
> `set_owner` robustness fix; everything else is conformance evidence that the
> transport delivers what it was sent. It also folds in two CDC residuals from the
> slice-1 re-verification (`set_owner` ownership handoff). CDC verifies on close.

## Posture

Peer-frame, write-to-the-floor. Load **collaboration-framework** + **erlang-
guidelines**. NIF mechanics from the cards, not memory: `otp-erts/nif-resources.md`
(monitor/down, `enif_monitor_process` return codes), `nif-thread-safety.md` (the
per-device lock discipline). Reuse the patterns already in `c_src/midiio_nif.c`
(`set_owner`, `open_input`, `down_device`, `recv_cb`, the inbound seam) and
`c_src/midiio_send.h` / `c_src/midiio_recv.h`. The bytes⇄message bridge is the
one place a subtle corruption breaks *every* message — test it adversarially.

## Required reading

1. `docs/planning/v0.1.0/arc3/arc-plan.md` — slice 2 ("virtual-loopback
   conformance + quirk cases"); the upstream gate note (raw API vs interim adapter).
2. `docs/planning/v0.1.0/arc3/slice1/cdc-reverification.md` — **residuals R1 and
   R2** (the `set_owner` handoff exposure you're closing in row group A).
3. `docs/planning/v0.1.0/DESIGN.md` §9 (the three test layers; the U1–U3/S1
   disclosed-test-limits) + §6 (framing) for the message taxonomy.
4. `midi/workbench/UPSTREAM-minimidio.md` (if reachable) **or**
   `docs/upstream/minimidio-api-and-bugs-bootstrap.md` §7 — U1 (CoreMIDI virtual
   SysEx ~256B cap), U2 (vel-0 fold inconsistency), U3 (real-time-in-SysEx), S1
   (suspected multi-packet inbound SysEx truncation) — the quirk cases here.
5. `c_src/midiio_nif.c` — `set_owner` (the function you're hardening), `open_input`
   (the monitor-arming pattern to mirror), `down_device`, `recv_cb`.

## Group A — `set_owner` ownership-handoff hardening (do this first; it's small)

**The two residuals (slice-1 re-verification).**
- **R2 (silent leak):** `set_owner(Dev, Pid)` demonitors the *old* owner first,
  then arms the new monitor only on success. If `Pid` is **already dead**,
  `enif_monitor_process` returns `>0`, `monitored` stays `0`, and the call returns
  `ok` — leaving a started input with **no monitor and a dead nominal owner**
  (never reclaimed), and having disarmed the previously-good monitor. Re-opens the
  S2 leak through the handoff path.
- **R1 (spurious close):** if `set_owner` races the *old* owner's death, the old
  owner's `down_device` can tear the device down even though ownership just moved
  to a live process. No UAF (cleanup is idempotent), but a live owner loses its
  device.

**The fix — make handoff atomic (monitor-new-BEFORE-demonitor-old).** In
`set_owner`, for inputs, arm the new monitor into a *local* `ErlNifMonitor` first;
commit (drop the old, store the new, write `owner`) only if it succeeds; on
failure leave the existing owner + monitor **fully intact** and return an error:

```c
enif_mutex_lock(res->lock);
if (res->is_input) {
    ErlNifMonitor new_mon;
    int rc = enif_monitor_process(env, res, &pid, &new_mon);  /* >0 dead, <0 unsupported */
    if (rc != 0) {
        enif_mutex_unlock(res->lock);
        return enif_make_tuple2(env, am_error, am_owner_not_alive);  /* old owner/monitor untouched */
    }
    if (res->monitored)
        enif_demonitor_process(env, res, &res->monitor);
    res->monitor    = new_mon;
    res->monitored  = 1;
}
res->owner = pid;
enif_mutex_unlock(res->lock);
return am_ok;
```

This **eliminates R2** (a dead target can no longer disarm a good monitor or leak;
the caller gets `{error, owner_not_alive}` and the device keeps working under the
old owner) and **narrows R1** to the irreducible ERTS demonitor window only (a
death already in delivery when we demonitor — unavoidable, and harmless: idempotent
cleanup). Add the atom `am_owner_not_alive` (declare near `am_not_open`, make it in
`init_statics` ~line 308). Calling `enif_monitor_process` while holding `res->lock`
is safe — a not-alive target returns `>0` synchronously (no `down`), and a live
target's `down` is async and would simply block on the lock until release (no join
on this path, so no deadlock).

**Outputs:** unchanged — they never arm a monitor (`is_input` false → the block is
skipped), `set_owner` just writes `owner`.

**(Optional, S3 polish):** `down_device`'s `res->monitored = 0` write is currently
unlocked — a benign int race with `set_owner`. If cheap, take `res->lock` around
*just that write* in `down_device` (it must **not** hold the lock when it calls
`do_dev_cleanup` — the mutex is non-recursive and cleanup re-locks). Disclose if
you skip it.

## Group B — virtual-loopback conformance (the proof; no new public surface)

Open a **virtual source** (arc-2 `open_output_virtual`) + a **virtual
destination** (`open_input` on `mm_in_open_virtual`) in one VM; `send` each member
of the taxonomy and assert the **exact bytes** arrive in the `{midi_in, Dev,
<<Bytes>>, TsNanos}` term. This is byte-level transport conformance — independent
of `midilib`'s codec (R7), Erlang-drivable so `midi` builds its through-terms
integration test on top (R8).

**Message taxonomy (each a round-trip case, byte-exact):**
- Channel voice: Note Off `8n`, Note On `9n`, Poly Aftertouch `An`, Control Change
  `Bn` (3 bytes each); Program Change `Cn`, Channel Aftertouch `Dn` (2 bytes).
- Pitch Bend `En` — **14-bit, LSB/MSB intact** (test a value with distinct LSB≠MSB).
- System common: Song Position `F2` (**14-bit**), Song Select `F3` (2 bytes),
  Tune Request `F6` (1 byte).
- System real-time: Clock `F8`, Start `FA`, Continue `FB`, Stop `FC`, Active
  Sensing `FE`, Reset `FF` (1 byte each).
- SysEx `F0 … F7` — several lengths (short, mid), byte-exact (large → Group C/U1).

**PropEr** for the bytes⇄message bridge across **both** seams (`midiio_send.h`
outbound, `midiio_recv.h` inbound): generate valid messages; assert no dropped
status, correct data-byte count, 14-bit values intact, SysEx of varied lengths
byte-exact. This closes arc-2/slice2's deferred round-trip property.

## Group C — the upstream quirk cases (U1–U3, S1): each green OR a disclosed expected-fail

Per DESIGN §9, each gets an explicit case with a tracked rationale — a disclosed
expected-fail is a **pass for this slice** (the defect is upstream, not ours):

- **U1 — large SysEx on a CoreMIDI virtual source.** A SysEx > ~256 B over the
  virtual loopback fails on CoreMIDI (upstream stack-`MIDIPacketList` cap). Mark
  **expected-fail / skipped on CoreMIDI** with the U1 reference; it may pass on
  ALSA (vm-test) — assert there if so. Do **not** let it fail CI silently.
- **S1 — inbound SysEx spanning more than one packet.** Drive a > one-packet
  inbound SysEx and assert one intact `F0…F7` arrives. If it truncates, that
  **confirms S1** — disclose it (expected-fail + the repro) rather than papering
  over; this is the case meant to flush the suspected truncation.
- **U2 / R6 — vel-0 note-on pass-through.** Assert `midiio` delivers `9n nn 00`
  **as sent** (no fold to note-off). Normalization is `midi`'s job, not the
  transport's — this guards against a regression into folding. (On ALSA the
  *backend* may fold below us; if so, disclose it as the U2 backend-inconsistency,
  tracked upstream — assert pass-through on the backend under test and note the
  divergence.)
- **U3 — real-time interleaved in SysEx (CoreMIDI).** If feasible over the virtual
  loopback, inject `F8` mid-SysEx and assert the clock is delivered separately and
  the SysEx body excludes it. Likely an expected-fail on CoreMIDI today (upstream)
  — disclose with the U3 reference. If not drivable over virtual ports, mark it
  **not-reproducible-headless** and leave it to the upstream fix.

## Constraints

- **No new public surface** beyond the `set_owner` return-value change (it now can
  return `{error, owner_not_alive}` — update its `-spec` and the moduledoc
  ownership contract). One owner pid; no normalization (R6); no multicast (R3).
- Conformance is **byte-level**, not through `midilib` (keeps midiio independent of
  midilib's codec gaps — R7).
- Disclosed expected-fails must be **tracked** (a tag + the U#/S1 reference), never
  a silent skip.

## Out of scope

UMP / MIDI 2.0; WinMM bring-up; WebMIDI; public virtual ports; `send_batch/2`
(NEW-1); the native `mm_*_raw` swap (lands when the maintainer ships — the seam is
ready, nothing above it changes). Multi-owner fan-out (R3, `midi`'s job).

## Testing

`set_owner` handoff: (1) handoff to a **dead** pid → `{error, owner_not_alive}`
**and** the old owner still reclaims on its death (proves R2 closed, no leak,
monitor preserved); (2) handoff to a **live** pid → re-points so the *new* owner's
death reclaims the device (`uninit_count` increments). The full taxonomy loopback +
PropEr round-trip green. Quirk cases green-or-disclosed. **Run under `make vm-test`**
for the ALSA path. `rebar3 as test check` green; `make asan` `ASAN-OK`.

## Done

`set_owner` handoff is atomic (R2 gone, R1 narrowed to the irreducible window);
the virtual-loopback suite round-trips the taxonomy byte-exact; PropEr closes the
bytes⇄message property on both seams; U1–U3/S1 are each green or a disclosed
expected-fail with a rationale; `check` + `asan` + `vm-test` green. **This closes
arc 3 and completes v0.1.0's planning arc** — confirm the `PROJECT-DEFINITION.md`
success criteria are all met or explicitly-deferred-with-rationale, and the
specified-vs-delivered diff across all three arcs shows no silent drops. Write
`closing-report.md`; capture any new `NIF-LEARNINGS`. Five-iteration cap.
