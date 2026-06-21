# Closing report — arc3/slice2 S2 remediation: `seam_roundtrip` OOB read

> CC's per-fix walk (full table in `s2-remediation-ledger.md`). One CDC S2 on
> `3511273`: my `seam_roundtrip/1` test NIF bypassed `send_nif`'s length pre-check
> and reached an out-of-bounds heap read in `midiio_bytes_to_msg` for truncated
> `F1/F2/F3` — reachable from safe Erlang, leaking adjacent heap. Host: macOS arm64,
> OTP 28. Date: 2026-06-21. Iteration: 1.

## Fix 1 — the seam self-defends (the safety fix)

`midiio_bytes_to_msg` (`c_src/midiio_send.h`) now guards every fixed-length
system-common data-byte read on `len`, mirroring the channel-voice branch's
`len >= 2/3` guard:

```c
case 0xF1: if (len < 2) return 0; ... m->data[0] = bytes[1];
case 0xF2: if (len < 3) return 0; ... bytes[1] | (bytes[2] << 7);
case 0xF3: if (len < 2) return 0; ... m->data[0] = bytes[1];
```

A too-short status is now *unframable* (returns 0 → `{error, unsupported_status}`).
The seam can no longer read past `bytes` for **any** input, regardless of caller —
the implicit "caller pre-validated" precondition is no longer load-bearing for
memory safety. The precondition comment was updated to state the self-defense.

## The proof — ASan flags it pre-fix, clean post-fix (the gate)

The bug was invisible to the functional suite (PropEr + eunit only generated
full-length messages), so green eunit ≠ closed. The standalone ASan harness
(`c_src/test/midiio_asan.c`) now places each truncated `F1/F2/F3` at the **end of a
`malloc(1)` allocation** and calls the seam, so ASan's redzone catches any read of
`bytes[1]`/`bytes[2]`:

- **Pre-fix** (F2 guard reverted to reproduce): `make asan` →
  `AddressSanitizer: heap-buffer-overflow ... READ of size 1 at midiio_send.h:104
  in midiio_bytes_to_msg`.
- **Post-fix:** `make asan` → `ASAN-OK`.

## Fix 3 — the regression test

eunit `seam_roundtrip_truncated_status_test`: `seam_roundtrip(<<16#F1>>)`,
`<<16#F2>>`, `<<16#F3>>`, and a one-data-byte `<<16#F2,16#10>>` all return
`{error, unsupported_status}` (no hang, no crash); a full `<<16#F2,16#10,16#20>>`
still round-trips byte-exact (the guards are inert on valid input). This is the
case that would have caught the bug. All 42 tests green (41 prior + this one).

## Fix 2 — test NIF out of the production surface: L18-BLOCKED, DISCLOSED

The prompt's Fix 2 (gate `seam_roundtrip` to the test build) was attempted two ways
and reverted, with concrete evidence that a clean split is not robust under the
single shared `.so` (NIF-LEARNINGS L18):

1. **Full `-DMIDIIO_TEST` gating + force-rebuild pre_hook** (the slice-5 re-entry
   idea): the C `nif_funcs[]` entry behind `#ifdef MIDIIO_TEST`, the Erlang
   `-nifs`/`-export` behind `-ifdef(TEST)`, the test profile adding the macro, and
   a top-level compile pre_hook removing the `.so`/`.o` to force a per-profile
   rebuild. Result: the pre_hook **breaks rebar3's `{artifacts,…}` check** —
   `Missing artifact priv/midiio_nif.so` (the hook races artifact resolution).
2. **Unexported-NIF gating** (keep `nif_funcs[]`/`-nifs`, gate only `-export`):
   `load_nif` **fails** — `{bad_lib,"Function not found midiio:seam_roundtrip/1"}`;
   it requires the NIF *exported*.

`pc` builds one shared `priv/midiio_nif.so` keyed on source mtime, not CFLAGS, so a
profile macro alone doesn't trigger a rebuild, and the two workarounds above each
break something. **Per the prompt's explicit fallback** ("if a clean compile-time
split isn't achievable under the shared `.so`, say so and fall back to Fix 1 +
Fix 3 alone and disclose"): the test NIFs stay in the surface. This is **surface
hygiene, not a safety hole** — after Fix 1, `seam_roundtrip` is memory-safe for any
input (a pure byte transform with no device access, no OOB). Re-entry: a
per-profile `.so` artifact path. Rationale recorded in `rebar.config`,
`src/midiio.erl`, and NIF-LEARNINGS L23.

## Disposition

9 rows: **7 done, 1 disclosed (row 5, Fix 2 / L18), and the safety invariant
(row 9) closed.** The S2 — an OOB heap read reachable from safe Erlang — is gone,
with the runtime evidence the remediation required (ASan flags pre-fix / clean
post-fix). `send_nif` is behaviorally unchanged for valid input; the Group A
`set_owner` fix and the conformance suite were left untouched per scope.

## Close-out unblocked

The memory-safety-from-safe-Erlang invariant holds again, so arc3/slice2's Group D
close-out (arc 3 / v0.1.0's planning arc) can proceed. New learning: NIF-LEARNINGS
**L23** (self-defending shared seams; ASan as the gate for functionally-invisible
memory bugs).
