# CC assignment — arc3/slice2 S2 remediation: `seam_roundtrip` OOB read from safe Erlang

> A focused remediation of **one S2** from `arc3/slice2/cdc-verification.md` on
> commit `3511273`: the production-exported `seam_roundtrip/1` test NIF bypasses
> `send_nif`'s length pre-check and reaches an **out-of-bounds heap read** in
> `midiio_bytes_to_msg` for truncated `0xF1/F2/F3` input — reachable from safe
> Erlang, leaking adjacent heap back into the returned binary. Everything else in
> slice 2 is **correct — do not touch it.** CDC re-verifies on close. This is the
> last gate before arc 3 / v0.1.0's planning arc closes.

## Posture

Peer-frame, write-to-the-floor. Load **collaboration-framework** + **erlang-
guidelines**. This is a memory-safety fix — the acceptance evidence is an **ASan
run that flags the bug pre-fix and is clean post-fix**, not code-read alone. Where
the test-build gating mechanics are uncertain, take them from how the project
already conditionally compiles (the `mk/*.mk` / rebar `port_compiler` setup) and
**report what actually gates**, rather than assuming.

## The bug (precise)

`midiio_bytes_to_msg` (`c_src/midiio_send.h`) reads `bytes[1]`/`bytes[2]`
**unguarded** for the system-common statuses that carry data bytes:

```c
case 0xF1: ... m->data[0] = bytes[1];                       /* :96    */
case 0xF2: ... bytes[1] | (bytes[2] << 7);                  /* :97–98 */
case 0xF3: ... m->data[0] = bytes[1];                       /* :99    */
```

The function comment (`:62`) states the precondition — it assumes the **caller
already length-validated**. `send_nif` honors that (its `midiio_expected_len` gate
`badarg`s a wrong-length message before the seam). The new `seam_roundtrip` NIF
(`c_src/midiio_nif.c`) does **not** — it checks only `in.size == 0`, then calls
`midiio_bytes_to_msg` directly. And it is exported in the **production** surface
(`nif_funcs[]` + `-nifs`/`-export` in `src/midiio.erl`).

**Repro (safe Erlang):** `midiio:seam_roundtrip(<<16#F2>>)` → `in.size == 1` →
reads 2 bytes past the 1-byte heap binary; `<<16#F1>>` / `<<16#F3>>` read 1 byte
past. The OOB bytes are re-emitted into the returned binary (heap info-leak). The
existing suite never hits it — PropEr + the eunit property only generate
full-length messages — so it's latent under all-green + clean ASan.

## Required reading

1. `docs/planning/v0.1.0/arc3/slice2/cdc-verification.md` — the S2 finding (this).
2. `c_src/midiio_send.h` — `midiio_bytes_to_msg` (the F1/F2/F3 branch + the `:62`
   precondition comment + the channel-voice `len >= 2/3` guard on `:90`, the
   pattern to mirror); `midiio_expected_len`.
3. `c_src/midiio_nif.c` — `seam_roundtrip` + the `nif_funcs[]` table; `send_nif`
   (the length-gate that the seam relies on).
4. `src/midiio.erl` — the `-nifs`/`-export` lists carrying `seam_roundtrip/1`.

## Fix 1 — self-defend `midiio_bytes_to_msg` (the must)

Guard the F1/F2/F3 data-byte reads on `len`; return `0` (unframable) when the
input is too short — the same shape as the channel-voice branch already on `:90`.
The shared seam must never read OOB **regardless of caller**:

```c
case 0xF1: if (len < 2) return 0; m->type = MM_MTC_QUARTER_FRAME; m->data[0] = bytes[1]; return 1;
case 0xF2: if (len < 3) return 0; m->type = MM_SONG_POSITION;
           m->song_position = (uint16_t)(bytes[1] | (bytes[2] << 7)); return 1;
case 0xF3: if (len < 2) return 0; m->type = MM_SONG_SELECT; m->data[0] = bytes[1]; return 1;
```

Returning `0` makes `seam_roundtrip` answer `{error, unsupported_status}` and keeps
`send_nif`'s behavior identical for valid input (it already pre-validates, so the
new guards are never the thing that rejects a well-formed message). **Verify
`send_nif` is unchanged in behavior** for the full taxonomy (the guards must be
inert on the validated path).

## Fix 2 — keep the test NIF out of the production binary (strongly recommended)

`seam_roundtrip` is a **test-only** entry point (its sole purpose is the PropEr
bytes⇄message property). It should not be in the shipped surface:

- Gate the C function **and** its `nif_funcs[]` entry behind a test build (e.g. a
  `-DMIDIIO_TEST` compile flag wired in the test profile only — confirm against
  how the project's `port_compiler`/`mk` build separates profiles; note L18, the
  single-`.so`-across-profiles hazard — if a clean compile-time split isn't
  achievable under the shared `.so`, say so and fall back to Fix 1 + Fix 3 alone
  and disclose).
- Mirror the gate on the Erlang side: `seam_roundtrip/1` out of the production
  `-nifs`/`-export`, available only in the test build.

If the single-`.so` constraint (L18) makes a clean production/test split
impractical, **Fix 1 + Fix 3 still fully close the memory-safety hole** — Fix 2 is
surface hygiene, not the safety fix. Disclose whichever path you take and why.

## Fix 3 — the regression test (the point)

Add a truncated-status case (eunit, runs under `make asan`):

- `midiio:seam_roundtrip(<<16#F1>>)`, `<<16#F2>>`, `<<16#F3>>` →
  `{error, unsupported_status}` (or `badarg` if you route it that way) — **no
  hang, no crash, ASan-clean.** This is the test that would have caught it. If
  `seam_roundtrip` is gated to the test build (Fix 2), the test lives there too.
- Keep all 41 existing tests green.

## Constraints / out of scope

Touch only `midiio_bytes_to_msg`'s F1/F2/F3 guards, the `seam_roundtrip` gating,
and the new test. **Do not** change the send/recv seam behavior for valid input,
the Group A `set_owner` fix, or the conformance suite. No new public surface.

## Done

`midiio_bytes_to_msg` is self-defending (no OOB read for any `len`); `make asan`
flags the truncated-`F2` read **before** the fix and is `ASAN-OK` after; the
regression test is green; `seam_roundtrip` is out of the production surface (or the
L18 constraint is disclosed with Fix 1+3 carrying the safety); all 41 tests +
PropEr still green; `rebar3 as test check` green. Update `arc3/slice2/ledger.md`
(append the S2 remediation rows / mark Group D close-out unblocked) and write a
short `s2-remediation-closing.md`. CDC re-verifies — the truncated-status repro
must be OOB pre-fix and clean post-fix. Capture a `NIF-LEARNINGS` entry if the
test-NIF-in-production-surface lesson isn't already there. Three-iteration cap.

## Ledger

See `s2-remediation-ledger.md`.
