# Ledger — arc3/slice2 S2 remediation: `seam_roundtrip` OOB read from safe Erlang

> CC implements + fills **CC evidence**; CDC re-verifies independently. Severity:
> **S1** blocker / **S2** major / **S3** minor. This is a **memory-safety** fix —
> rows 1–3 gate on **ASan runtime evidence** (OOB pre-fix, clean post-fix), not
> code-read alone. Three-iteration cap.

## Rows

| # | Acceptance criterion | How to verify | Sev | Status | CC evidence | CDC verdict |
|---|----------------------|---------------|-----|--------|-------------|-------------|
| 1 | **Fix 1 — seam self-defends:** `midiio_bytes_to_msg` guards the `0xF1`/`0xF2`/`0xF3` `bytes[1]`/`bytes[2]` reads on `len`, returning `0` (unframable) when too short | code read: `if (len < 2/3) return 0;` on each of F1/F2/F3, mirroring the channel-voice `len >= 2/3` guard | S2 | ✅ done | `c_src/midiio_send.h`: `case 0xF1: if (len < 2) return 0;` (`:101`), `case 0xF2: if (len < 3) return 0;` (`:103`), `case 0xF3: if (len < 2) return 0;` (`:106`) — mirrors the channel-voice `len >= 2/3` guard. The precondition comment updated to state the self-defense. | |
| 2 | **OOB read gone (the proof):** `seam_roundtrip(<<16#F2>>)` (and `<<16#F1>>`,`<<16#F3>>`) no longer reads past the input binary | **`make asan`**: a truncated-`F1/F2/F3` call flags heap-buffer-overflow (read) **pre-fix** and is **ASAN-OK post-fix** | S2 | ✅ done | `midiio_asan.c` truncated-status block places each of `F1/F2/F3` at the END of a `malloc(1)` allocation and calls `midiio_bytes_to_msg(one, 1, &m)`. **Pre-fix** (F2 guard reverted): ASan flags `heap-buffer-overflow ... READ of size 1 at midiio_send.h:104 in midiio_bytes_to_msg`. **Post-fix:** `make asan` → `ASAN-OK`. | |
| 3 | **Regression test added:** truncated-status cases assert `{error, unsupported_status}` (or `badarg`); no hang/crash; runs under ASan | read the eunit case; `make asan` exercises it | S2 | ✅ done | eunit `seam_roundtrip_truncated_status_test`: `seam_roundtrip(<<16#F1>>)`/`<<16#F2>>`/`<<16#F3>>`/`<<16#F2,16#10>>` → `{error, unsupported_status}`; a full `<<16#F2,16#10,16#20>>` still `{ok, …}`. The C harness counterpart runs under `make asan` (row 2). | |
| 4 | **`send_nif` behavior unchanged for valid input:** the new guards are inert on the pre-validated send path | code read + the full taxonomy loopback still byte-exact; the guards never reject a well-formed message | S2 | ✅ done | The guards only fire for too-short fixed-length statuses, which `send_nif` already rejects via `midiio_expected_len` before the seam — so they are never the rejecter for a well-formed message. The full taxonomy loopback (`taxonomy_byte_exact_loopback_test_`) + PropEr (300 numtests) still pass byte-exact. | |
| 5 | **Fix 2 — test NIF out of the production surface:** `seam_roundtrip` (C fn + `nif_funcs[]` entry + Erlang `-nifs`/`-export`) gated to the test build; OR the L18 single-`.so` constraint disclosed with Fix 1+3 carrying the safety | code read: the production module/`.so` no longer exports `seam_roundtrip/1`; or a disclosed-rationale note if L18 blocks a clean split | S3 | ⏸ disclosed | **L18 blocks a clean split — disclosed, Fix 1+3 carry the safety (per the prompt's fallback).** Two gating approaches were attempted and reverted with concrete evidence: (a) full `-DMIDIIO_TEST` gating + a force-rebuild pre_hook → breaks rebar3's `{artifacts,…}` check (`Missing artifact priv/midiio_nif.so`); (b) unexported-NIF gating → `load_nif` fails `{bad_lib,"Function not found midiio:seam_roundtrip/1"}` (it requires the NIF exported). pc builds one shared `.so` keyed on source mtime, not CFLAGS, so a profile macro doesn't trigger a rebuild. **`seam_roundtrip` is now memory-safe for any input (Fix 1, ASan-proven)**, so its presence in the surface is hygiene, not a safety hole. Re-entry: a per-profile `.so` artifact path. Rationale recorded in `rebar.config` + `src/midiio.erl` + NIF-LEARNINGS L23. | |
| 6 | The PropEr property still drives both seams (in the test build) — `prop_seam_roundtrip` unaffected by the gating | `rebar3 as test proper -m midiio_prop` green; the eunit `seam_roundtrip_property_test_` still gates in `check` | S3 | ✅ done | `seam_roundtrip` stays in the surface (Fix 2 disclosed), so `prop_seam_roundtrip` is unaffected: `rebar3 as test proper -m midiio_prop` green; `seam_roundtrip_property_test_` gates in `check` (42 tests). | |
| 7 | All 41 existing tests still green; `rebar3 as test check` green; `make asan` `ASAN-OK` | run all three | S1 | ✅ done | `rebar3 as test check` → exit 0, **42 tests** (41 prior + the truncated-status regression) + PropEr, dialyzer clean, coverage dormant; `make asan` → `ASAN-OK`. | |
| 8 | `NIF-LEARNINGS` entry: a test-only NIF must not ship in the production surface, and a seam with an implicit "caller pre-validated" precondition must self-defend (the OOB-via-new-caller class) | read the new entry | S3 | ✅ done | `docs/NIF-LEARNINGS.md` **L23** — self-defending shared seams (the OOB-via-new-caller class) + ASan-as-the-gate-for-invisible-bugs, with the Fix-2/L18 hygiene corollary. | |
| 9 | **Arc 3 / v0.1.0 close-out unblocked:** the memory-safety-from-safe-Erlang invariant holds again; `arc3/slice2/ledger.md` Group D close-out can proceed | read the amended slice-2 ledger + `s2-remediation-closing.md` | S1 | ✅ done | The OOB-from-safe-Erlang is closed (Fix 1, ASan-proven); `s2-remediation-closing.md` written; the slice-2 Group D close-out (arc 3 / v0.1.0 planning arc) is unblocked. | |

## Notes

- **Fix 1 is the safety fix; Fix 2 is hygiene.** If L18 (the shared single-`.so`
  across profiles) makes a clean production/test split impractical, Fix 1 + Fix 3
  fully close the OOB — disclose the path taken. Don't grind on Fix 2 at the cost
  of the slice.
- **Scope discipline:** only the F1/F2/F3 guards, the `seam_roundtrip` gating, and
  the new test. The Group A `set_owner` fix, the send/recv seam behavior for valid
  input, and the conformance suite are correct — leave them.
- **Why ASan is the gate (rows 2–3):** the defect is invisible to functional tests
  (the corpus only sends well-formed messages), so green eunit ≠ closed. The OOB
  must be *demonstrated* pre-fix under ASan and *absent* post-fix.

## Closing

CC writes `s2-remediation-closing.md`; CDC re-verifies (the truncated-status repro
must be OOB pre-fix / ASan-clean post-fix; `send_nif` unchanged for valid input).
Done when the OOB is gone with runtime evidence, the test NIF is off the production
surface (or L18 disclosed), `check` + `asan` are green — and **arc 3 / v0.1.0's
planning arc can close.**
