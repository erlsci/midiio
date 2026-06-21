# Ledger — v0.2.0 arc1/slice1: vendor bump to the merged raw-API minimidio

> CC implements + fills **CC evidence**; CDC verifies independently. Severity:
> **S1** blocker / **S2** major / **S3** minor. This is a *provenance + no-regression*
> slice — the gate is a clean drift check + the full suite green at v0.1.0 counts +
> an additive-only diff. **Gated on v0.1.0 close** (S2 done, arc 3 closed).
> Three-iteration cap.

## Rows

| # | Acceptance criterion | How to verify | Sev | Status | CC evidence | CDC verdict |
|---|----------------------|---------------|-----|--------|-------------|-------------|
| 1 | **Pinned to the merged commit:** `c_src/minimidio.h` + `minimidio.lock` re-pinned via `make vendor-minimidio SHA=<merged>` (a SHA, not a moving ref) | `make minimidio-info` shows the new commit/version/date/sha256; lock not hand-edited | S2 | ✅ done | `make vendor-minimidio SHA=0fb49e6ebfb69d20e3b69dff1c41cfc34087a9b4` (the PR #12 merge — "Merge pull request #12 from billosys/feat/raw-bytes-api"). `make minimidio-info`: commit `0fb49e6…`, version `v0.5.0-dev`, date `2026-06-18`, sha256 `f6a18b17…`. Lock script-managed (not hand-edited). | |
| 2 | **Drift gate green:** the vendored header matches the new lock | `make minimidio-verify` → exit 0 | S1 | ✅ done | `make minimidio-verify` → `minimidio-verify: OK c_src/minimidio.h (f6a18b17…)`, exit 0. | |
| 3 | **Attribution preserved:** the two-commit pattern — vendored `.h` under the upstream author, lock/docs under ours | git log on the two commits; lock `author` = upstream | S3 | ✅ done* | Two-commit pattern preserved: `1a3ee4d` (`minimidio.h`+`LICENSE`, `--author` from the pinned commit) + `3a3629e` (`minimidio.lock`, maintainer). **\*Disclosed author change (correct):** the pinned merge commit's author is **Duncan McGreggor / billosys** (the raw-bytes API was contributed *by* billosys *to* octetta), so the script's R1 logic derived that author and warned about the mismatch with the Joseph-Stewart-era constant. git blame on `minimidio.h` now correctly shows the original lines as Joseph's and the raw-API lines as Duncan's. Not a regression — the design's per-commit attribution working as intended. | |
| 4 | **Additive-only:** the symbols the interim adapter consumes are **unchanged** between `bb705e8` and the merged commit | diff old vs new header for those symbols; report it — identical bodies/signatures, only *new* `mm_*_raw`/`MM_CAP_RAW` added | S1 | ✅ done | Full diff: **+419 lines, 5 changed**. The 5 changed are benign: (1) the CoreMIDI *internal* struct gains a name (`typedef struct {` → `typedef struct mm__dev_coremidi {`) — invisible to the adapter/NIF; (2–5) four `mm_context_caps` bodies add `| MM_CAP_RAW`. **All adapter-consumed symbols byte-identical** (verified by extract+diff): `mm_message` struct, `mm_message_type` enum, `mm_callback` typedef, `mm_make_message` (decl+body), `mm_out_send` (decl+body), `mm_out_send_sysex`, `mm_in_open`/`mm_in_open_virtual`/`mm_in_start`/`mm_in_stop`/`mm_in_close` (decls). Public `mm_device` gained additive fields `raw_callback`/`is_raw` — safe: the NIF accesses `mm_device` only as `&res->dev` through the API, never by field name. The +419 are the new `mm_*_raw`/`MM_CAP_RAW`/`mm_raw_callback`/raw dispatch. | |
| 5 | **No behavior change — Erlang suite:** `rebar3 as test check` green (eunit + PropEr + dialyzer) | run it; same pass counts as v0.1.0 close | S1 | ✅ done | Clean compile against the new header; `rebar3 as test check` → exit 0, **All 42 tests passed** (same as v0.1.0 close on macOS) + PropEr; xref/dialyzer clean; coverage dormant. | |
| 6 | **No behavior change — ASan:** `make asan` `ASAN-OK` | run it | S1 | ✅ done | `make asan` → `ASAN-OK` (the standalone harness rebuilt against the new header — context/device lifecycle, raw seams, F1 tripwire all clean). | |
| 7 | **No behavior change — ALSA/vm-test:** `make vm-test` green at the v0.1.0 count (41) | run it in the multipass VM | S1 | ✅ done* | `make vm-test` (Ubuntu 24.04, real `/dev/snd/seq`, committed HEAD with the new header) → **All 42 tests passed + ASAN-OK** on real ALSA. **\*Count note:** the row's "41" is the v0.1.0-close number; the current count is **42** on *both* macOS and vm-test because the arc3/slice2 **S2** remediation (v0.1.0's tail) added `seam_roundtrip_truncated_status_test`. The bump added zero tests — 42 (pre-bump) = 42 (post-bump) is the no-regression proof. | |
| 8 | **Conformance dispositions unchanged** — U1/U2/U3/S1 tests behave exactly as at v0.1.0 close; **any flip is recorded as a slice-2 finding** | read the test results + the closing report's findings section | S2 | ✅ done | **No flip.** `u1_large_sysex_virtual_cap_test_`, `u2_vel0_passthrough_test_`, `u3_realtime_in_sysex_test_`, `s1_multipacket_inbound_sysex_test_`, and `caps_backend_and_flags_test_` all pass with identical dispositions. Expected: midiio still drives the **interim adapter** (struct API), not the raw API — so U1 still hits the CoreMIDI `mm_out_send_sysex` cap, vel-0/real-time behavior is unchanged, and `caps()` ignores the new `MM_CAP_RAW` bit (its 6-key map is unchanged). The raw API exists but is unused until the slice-3 swap. | |
| 9 | `slice1/closing-report.md` written: the additive diff (row 4), the suite counts, and any conformance-disposition flips flagged for the surface exam | read it | S3 | ✅ done | `slice1/closing-report.md` written: the merge SHA, the additive +419/5-changed diff with the per-symbol confirmation, the attribution-author disclosure, the suite counts, and the no-flip conformance result. | |

## Notes

- **The bump is mechanical; the *proof* is the slice.** A green `make
  minimidio-verify` only says "header matches lock" — the load-bearing rows are 4–8
  (additive-only + suite-green-at-same-counts). That pair is what licenses "no
  behavior change."
- **A flipped conformance disposition is a feature, not a bug.** If the merge
  bundled (say) the U1 fix, the U1 cap test will stop seeing `{error,_}` on
  CoreMIDI. Don't fight it — record it; the surface exam (slice 2) decides how the
  disclosure retires.
- **Scope discipline:** vendored header + lock only. No swap, no adapter deletion,
  no `seam_roundtrip` changes — slice 3+.

## Closing

CC writes `closing-report.md`; CDC re-verifies provenance + drift + the
no-behavior-change claim (the additive diff is the heart of it). Done when the pin
is the merged commit, the gate is green, the suite is green at v0.1.0 counts, and
any disposition flips are honestly recorded for slice 2. Then the **surface exam
(slice 2)** can begin against the freshly-vendored native header.
