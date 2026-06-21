# CDC verification — arc3/slice2 (set_owner handoff + virtual-loopback conformance)

> Independent code-read of commit `3511273` against the slice-2 ledger and the
> slice-1 re-verification residuals (R1/R2). The Group A fix, the seam refactor,
> and the conformance suite are all read first-hand.
>
> **Verdict: CONDITIONAL — one S2 to close, then PASS.** The proof slice is strong:
> Group A (`set_owner` atomic handoff) is exactly right, the send-seam refactor is
> behavior-preserving, the taxonomy/PropEr conformance is thorough, and the U3
> disposition is honest. **But** the new `seam_roundtrip/1` test NIF is exported in
> the *production* module and bypasses `send_nif`'s length pre-check, making an
> **out-of-bounds heap read reachable from safe Erlang** for truncated `0xF1/F2/F3`
> input. That violates the project's foundational "safe Erlang causes no memory
> unsafety" invariant (the same one the whole F1/S1/S2 lineage defends), so the
> "v0.1.0 criteria all met" close-out should wait on this one cheap fix.
>
> **Evidence boundary (disclosed):** I verified logic + the test sources by
> code-read. I did **not** re-run the runtime — this sandbox has no ALSA
> `/dev/snd/seq` and no Erlang. The 41-test ALSA run (U1/U2/S1 ALSA legs, taxonomy,
> deadlock) rests on CC's reported `make vm-test`. The newly-found S2 is **not**
> covered by that run (the corpus only sends well-formed messages — see below).

## 🔴 S2 — `seam_roundtrip/1` (production-exported test NIF) → OOB heap read from safe Erlang

`midiio_bytes_to_msg` (`c_src/midiio_send.h`) reads `bytes[1]`/`bytes[2]`
**unguarded** for the system-common statuses that carry data bytes:

```c
case 0xF1: ... m->data[0] = bytes[1]; return 1;                    /* :96  */
case 0xF2: ... m->song_position = bytes[1] | (bytes[2] << 7); ...  /* :97–98 */
case 0xF3: ... m->data[0] = bytes[1]; return 1;                    /* :99  */
```

The function's comment (`:62`) states the precondition out loud — it "indexes
`bytes[1]`/`bytes[2]` directly for the statuses that carry them" — i.e. it assumes
the **caller already length-validated**. The original caller, `send_nif`, honors
that: it runs `midiio_expected_len(b)` and `enif_make_badarg`s a wrong-length
message *before* the seam (the channel-voice branch `:90` is itself guarded with
`len >= 2/3`, but F1/F2/F3 are not — they lean entirely on the caller).

The new `seam_roundtrip` NIF (`c_src/midiio_nif.c`) is now wired into the
**production** surface — added to `nif_funcs[]`, and to `-nifs`/`-export` in
`src/midiio.erl` — and it calls `midiio_bytes_to_msg` directly with **only** an
`in.size == 0` check, skipping the length gate:

```c
if (!enif_inspect_binary(env, argv[0], &in) || in.size == 0) return badarg;
if (!midiio_bytes_to_msg(in.data, in.size, &m)) ...   /* no expected_len check */
```

**Reachable from safe Erlang:** `midiio:seam_roundtrip(<<16#F2>>)` → `in.size == 1`
→ `midiio_bytes_to_msg` reads `bytes[1]` and `bytes[2]`, **2 bytes past** the
1-byte heap binary. `<<16#F1>>` / `<<16#F3>>` read 1 byte past. Worse than a bare
read: the OOB bytes are written into `m` and re-emitted into the returned binary
(`song_position`/`data[0]`), so adjacent heap is **leaked back to Erlang**. ASan
on a build that exercised this call would flag a heap-buffer-overflow (read); the
existing suite never does — PropEr's `midi_message()` and the eunit property only
generate **full-length, well-formed** messages, so the hole is latent under green
tests + clean ASan. This is exactly the defect class independent code-read exists
to catch.

**Severity: S2.** Out-of-bounds *read* (not a write — no RCE/corruption), but
reachable from safe Erlang and leaking heap bytes, via an exported NIF. It doesn't
break any of the 5 enumerated functional criteria, but it violates the project's
cross-cutting memory-safety-from-safe-Erlang posture, so it gates the clean
close-out.

**Fix (cheap; do both — defense in depth + surface hygiene):**
1. **Make `midiio_bytes_to_msg` self-defending** (the must): guard the F1/F2/F3
   `bytes[1]`/`bytes[2]` reads on `len`, returning `0` (unframable) when too short
   — the same shape as the channel-voice `len >= 2/3` guard already on `:90`. The
   shared seam should never read OOB regardless of caller; this closes it at the
   source.
2. **Keep the test NIF out of the production binary** (strongly recommended):
   `seam_roundtrip` is test-only — gate the C function + its `nif_funcs[]` entry
   and the Erlang `-nifs`/`-export` behind a test build (e.g. a `-DMIDIIO_TEST`
   compile guard / a test-profile-only module), so the production surface doesn't
   carry it. This removes the reachable path entirely and drops dead weight.
3. **Regression test:** `seam_roundtrip(<<16#F1>>)`, `<<16#F2>>`, `<<16#F3>>` →
   `{error, unsupported_status}` (or `badarg`), run under ASan — the test that
   would have caught this.

## ✅ Group A — `set_owner` atomic handoff (R1/R2): correct

`set_owner` (`midiio_nif.c`) is verbatim the prescribed monitor-new-before-
demonitor-old shape: for inputs it arms `enif_monitor_process(env, res, &pid,
&new_mon)` into a **local** `new_mon`; on non-zero (dead target / no down) it
unlocks and returns `{error, owner_not_alive}` with the **old owner + monitor
untouched**; only on success does it demonitor the old, store `new_mon`, set
`monitored = 1`, then write `owner`. **R2 is closed** (a dead target can no longer
disarm a good monitor or silently leak), **R1 is narrowed** to the irreducible
ERTS demonitor window. The lock-held `enif_monitor_process` call is safe (the
comment's reasoning is correct: dead → synchronous non-zero, no `down`; live →
async `down` blocks on the lock, no join on this path). The two tests prove it:
`set_owner_dead_handoff_preserves_old_owner_test_` (dead handoff rejected **and**
the old owner's still-armed monitor reclaims on its death) and
`set_owner_live_handoff_redirects_reclaim_test_` (live re-point → new owner's death
reclaims). `am_owner_not_alive` + `-spec`/`@doc` updated. Row 6 (unlocked
`down_device` `monitored=0`) is reasonably disclosed-skipped — benign int race, no
memory-safety gain from locking it.

## ✅ Group B — send-seam refactor is inert; conformance is thorough

I traced the `midiio_bytes_to_msg` extraction branch-by-branch against the old
`midiio_dev_send_raw`: SysEx → `mm_out_send_sysex(dev, bytes, len)`, channel voice
→ `mm_make_message` + `mm_out_send`, system common/real-time → identical field
fills + `mm_out_send`, unframable → `MIDIIO_UNSUPPORTED_STATUS`. **Every production
send path emits the identical `mm_out_send*` call it did before** — the refactor is
behavior-preserving (the only new reachability is the S2 above, via the new
*caller*, not the extraction). The taxonomy loopback asserts byte-exact `Got ==
Sent` across the full message set with 14-bit (pitch bend `E0 7F 3F`, song position
`F2 10 20`, LSB≠MSB) and varied SysEx lengths; `prop_seam_roundtrip` drives both
seams purely (`bytes_to_msg` → `msg_to_bytes`) over a generator that covers the
taxonomy, gated under `check` at 300 numtests. Solid.

## ✅ Group C — quirks honestly dispositioned

- **U1** (`u1_large_sysex_virtual_cap_test_`): 400-B SysEx asserts `{error,_}` on
  CoreMIDI (the ~256-B virtual cap, tracked) and byte-exact on ALSA — backend-
  branched, not silent. Correct.
- **U2** (`u2_vel0_passthrough_test_`): `90 3C 00` asserted to pass through on
  CoreMIDI (midiio never folds); ALSA's backend fold (`→ 80 3C 00`) disclosed and
  accepted per-backend. Correct — the assertion that *midiio* doesn't fold is the
  one that matters.
- **U3** (`u3_realtime_in_sysex_test_`): **the honest finding, and it holds up.**
  The byte-complete-message send API structurally cannot inject a real-time byte
  *mid-SysEx-transmission* on the wire, so the CoreMIDI read-proc never sees the
  combined `[F0…F8…F7]` packet the absorption defect requires — U3 is genuinely
  **not reproducible over the virtual loopback**. CC correctly asserts the
  invariant that *does* hold (no delivered SysEx absorbed the F8) and discloses
  that the defect remains real for real-hardware combined packets (resolved by raw
  inbound framing upstream), rather than encoding a false "expect absorption"
  assertion. This is the right call. Caveat worth recording: this test is a
  *disclosure + invariant check, not a U3 regression guard* — a true guard needs
  real hardware. CC stated exactly this.
- **S1** (`s1_multipacket_inbound_sysex_test_`): CoreMIDI not-reproducible (blocked
  by U1's send-side cap on the virtual source — disclosed); ALSA drives a 1000-B
  SysEx and asserts one intact `F0…F7`. Per CC's run it passed on ALSA — so S1's
  truncation did not manifest on ALSA, and remains *suspected/untested on
  CoreMIDI* (the honest state). Correct.

## v0.1.0 close-out

Four of the five enumerated criteria are met and well-evidenced; the
specified-vs-delivered diff across arcs 1–3 shows no silent drops, with the
deferrals (native `mm_*_raw` swap, UMP/WinMM/WebMIDI, `send_batch`) named non-goals
behind the ready seam. The **memory-safety-from-safe-Erlang invariant** that
underwrites the whole arc is, however, currently violated by the exported
`seam_roundtrip` NIF (S2 above). So: **do not declare the v0.1.0 planning arc
closed until the S2 is fixed** — it's a one-guard-plus-gate change. Everything else
is PASS-quality.

## Bottom line

Excellent slice — the `set_owner` hardening lands cleanly, the refactor is safe,
and the U3 honesty is exactly the posture we want. **CONDITIONAL** on one cheap
S2: the production-exported `seam_roundtrip` NIF reaches an unguarded OOB read in
`midiio_bytes_to_msg` for truncated `0xF1/F2/F3` from safe Erlang. Self-defend the
seam (guard the F1/F2/F3 reads on `len`), keep the test NIF out of the production
build, add the truncated-status regression test under ASan, then re-CDC and close
arc 3 / v0.1.0. Recommend folding this into a micro-remediation rather than a new
slice. A second `make vm-test` witness on the macpro would also retire my disclosed
runtime-evidence boundary.
