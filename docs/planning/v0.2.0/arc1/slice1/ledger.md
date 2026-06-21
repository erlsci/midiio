# Ledger — v0.2.0 arc1/slice1: vendor bump to the merged raw-API minimidio

> CC implements + fills **CC evidence**; CDC verifies independently. Severity:
> **S1** blocker / **S2** major / **S3** minor. This is a *provenance + no-regression*
> slice — the gate is a clean drift check + the full suite green at v0.1.0 counts +
> an additive-only diff. **Gated on v0.1.0 close** (S2 done, arc 3 closed).
> Three-iteration cap.

## Rows

| # | Acceptance criterion | How to verify | Sev | Status | CC evidence | CDC verdict |
|---|----------------------|---------------|-----|--------|-------------|-------------|
| 1 | **Pinned to the merged commit:** `c_src/minimidio.h` + `minimidio.lock` re-pinned via `make vendor-minimidio SHA=<merged>` (a SHA, not a moving ref) | `make minimidio-info` shows the new commit/version/date/sha256; lock not hand-edited | S2 | ☐ | | |
| 2 | **Drift gate green:** the vendored header matches the new lock | `make minimidio-verify` → exit 0 | S1 | ☐ | | |
| 3 | **Attribution preserved:** the two-commit pattern — vendored `.h` under the upstream author, lock/docs under ours | git log on the two commits; lock `author` = upstream | S3 | ☐ | | |
| 4 | **Additive-only:** the symbols the interim adapter consumes are **unchanged** between `bb705e8` and the merged commit — `mm_message` + `MM_*` enum, `mm_out_send`, `mm_out_send_sysex`, `mm_make_message`, `mm_in_open`/`mm_in_open_virtual`/`mm_in_start`/`mm_in_stop`/`mm_in_close`, the `mm_callback` typedef, the caps/enum surface | diff old vs new header for those symbols; report it — identical bodies/signatures, only *new* `mm_*_raw`/`MM_CAP_RAW` added | S1 | ☐ | | |
| 5 | **No behavior change — Erlang suite:** `rebar3 as test check` green (eunit + PropEr + dialyzer) | run it; same pass counts as v0.1.0 close | S1 | ☐ | | |
| 6 | **No behavior change — ASan:** `make asan` `ASAN-OK` | run it | S1 | ☐ | | |
| 7 | **No behavior change — ALSA/vm-test:** `make vm-test` green at the v0.1.0 count (41) | run it in the multipass VM | S1 | ☐ | | |
| 8 | **Conformance dispositions unchanged** — U1/U2/U3/S1 tests behave exactly as at v0.1.0 close; **any flip is recorded as a slice-2 finding**, the test left honest (not forced back to the old assertion), and disclosed | read the test results + the closing report's findings section | S2 | ☐ | | |
| 9 | `slice1/closing-report.md` written: the additive diff (row 4), the suite counts, and any conformance-disposition flips flagged for the surface exam | read it | S3 | ☐ | | |

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
