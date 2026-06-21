# CDC re-verification — arc3/slice2 S2 remediation (`seam_roundtrip` OOB read)

> Independent re-verification of commit `2db04cc` against the S2 finding in
> `cdc-verification.md`. Verdict on the close of the memory-safety hole that held
> arc 3 / v0.1.0's planning arc CONDITIONAL.
>
> **Verdict: PASS — S2 closed, with independent runtime evidence.** The OOB read is
> gone; the fix is complete; the regression test and the valid-path invariance hold.
> Fix 2 (gating the test NIF out of production) is disclosed-deferred on the L18
> single-`.so` constraint, which is **acceptable per the remediation's own
> pre-agreed fallback** — Fix 1 carries the safety, and `seam_roundtrip` is now
> memory-safe for any input, so its presence in the surface is hygiene, not a hole.
> **Arc 3 / v0.1.0's planning arc can close.**

## ✅ Fix 1 — the seam self-defends (verified by code-read AND independent ASan)

`midiio_bytes_to_msg` (`c_src/midiio_send.h`) now guards every data-byte read on
`len`: `case 0xF1: if (len < 2) return 0;`, `case 0xF2: if (len < 3) return 0;`,
`case 0xF3: if (len < 2) return 0;` — mirroring the channel-voice branch's
`len >= 2/3` guard. I confirmed by grep that **no unguarded `bytes[n>0]` read
remains**: `bytes[0]` is behind `seam_roundtrip`'s `size==0` check; channel-voice
and F1/F2/F3 are guarded; SysEx and the single-byte real-time statuses read no data
bytes. The implicit "caller pre-validated" precondition is no longer load-bearing
for memory safety.

**Independent runtime evidence (not a rerun of CC's).** Because `midiio_send.h`
deliberately doesn't include `minimidio.h`, I compiled the **real committed header**
against a minimal ALSA-free type stub and drove `midiio_bytes_to_msg` with truncated
`F1/F2/F3` placed at the end of a `malloc(1)` (so the ASan redzone catches any read
past byte 0):

- **Post-fix (committed header):** `F1/F2/F3 → framed=0`, **ASan clean, exit 0.**
- **Pre-fix (I removed only the F2 `len < 3` guard):** ASan fires
  `heap-buffer-overflow ... READ of size 1 ... 0 bytes to the right of 1-byte
  region` in `midiio_bytes_to_msg` (at the `bytes[1] | (bytes[2] << 7)` line),
  allocated by `malloc(1)`.

So the guard *is* the thing that closes the OOB, and the committed code is clean.
This retires the runtime-evidence boundary I had to disclose on the slice-1/slice-2
verifications — for this fix I reproduced the result rather than relying on the
reported run. (Minor: my repro cites the F2 read at `:105`; CC's report says `:104`
— the same read, immaterial.)

The in-repo gate (`c_src/test/midiio_asan.c`, the truncated-status block placing
each status at the end of a `malloc(1)`) is the right shape and matches my
standalone repro; `make asan` is `ASAN-OK` post-fix per CC and corroborated here.

## ✅ Regression test + valid-path invariance

`seam_roundtrip_truncated_status_test` asserts `{error, unsupported_status}` for
`<<F1>>`, `<<F2>>`, `<<F3>>`, **and** the one-data-byte `<<F2,10>>` (also too
short), and `{ok, <<F2,10,20>>}` for the full message — so it pins both the
fix and its inertness on valid input. `send_nif` is unchanged: the new guards fire
only for too-short fixed-length statuses, which `send_nif` already rejects via
`midiio_expected_len` *before* the seam, so they are never the rejecter for a
well-formed message (the taxonomy loopback + PropEr still pass byte-exact). 42 tests
+ `check` + ASan green.

## 🟡 Fix 2 — disclosed-deferred (L18), acceptable per the agreed fallback

The remediation prompt + ledger explicitly allowed: *if L18 (the `pc` single shared
`.so`, keyed on mtime not CFLAGS) blocks a clean production/test split, Fix 1 + Fix
3 carry the safety — disclose.* CC attempted two gating routes and reverted both
with concrete evidence: full `-DMIDIIO_TEST` + force-rebuild pre_hook breaks
rebar3's `{artifacts,…}` check (`Missing artifact priv/midiio_nif.so`); an
unexported-NIF gate fails `load_nif` (`{bad_lib,"Function not found …
seam_roundtrip/1"}` — the NIF must be exported to load). Both are real `pc`/rebar3
constraints, not a lack of effort. So `seam_roundtrip` stays in the surface — but
after Fix 1 it is memory-safe for **any** input (size-checked, all reads guarded,
SysEx via a size-exact `enif_make_new_binary`, non-SysEx into `buf[3]` writing ≤3),
so its presence is **hygiene, not a memory-safety hole**. Disposition accepted.
Tracked re-entry (a per-profile `.so` artifact path) is the correct future fix;
NIF-LEARNINGS **L23** captures the lesson (self-defending shared seams + ASan as the
gate for functionally-invisible bugs). I did not re-audit the disclosure-comment
edits in `rebar.config` / `src/midiio.erl` (comments per CC's report); the green
`check` covers behavioral regressions there.

## Bottom line

The S2 memory-safety hole is **genuinely closed**, confirmed by an independent
ASan repro of the exact pre/post behavior on the committed code. The regression
guard is in place, the valid send path is unchanged, and the test-NIF-in-surface
residual is disclosed hygiene (safe for any input), deferred on a real L18
constraint with a tracked re-entry. **PASS.** The arc3/slice2 Group D close-out is
unblocked: **arc 3 and v0.1.0's planning arc can close.** That also unblocks the
v0.2.0 arc1/slice1 vendor bump (which was gated on the v0.1.0 close).
