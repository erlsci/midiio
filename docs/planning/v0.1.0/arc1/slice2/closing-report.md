# Closing report — arc1/slice2: deterministic minimidio vendoring + provenance

> CC's per-row walk with evidence. CDC verifies independently against the actual
> files / script runs / git log (not this summary) and writes `cdc-verification.md`.
>
> Host: macOS (Darwin 24.6, arm64). Tools: curl, git, sha256sum + shasum, GNU make,
> /bin/sh. Network + GitHub reachable, so the full live path (resolve → fetch →
> commit) was exercised — **no network rows deferred**. Date: 2026-06-17.
> Iteration: 1.

## What was built

| Artifact | Role |
|----------|------|
| `scripts/vendor-minimidio.sh` | POSIX `sh` vendoring tool: resolve ref→SHA, fetch header+LICENSE, derive author/date from the pinned commit, tolerant version, atomic write, R2 no-op, dirty-tree guard, two attributed commits / `--no-commit`, `--verify`. |
| `Makefile` | `vendor-minimidio` (SHA=/REF=, NO_COMMIT pass-through) and `minimidio-verify`. Vendoring chores only — does not build the project. |
| `.github/workflows/vendor-check.yml` | CI drift gate (R5): runs `make minimidio-verify` on push/PR. |
| `scripts/test-vendor-minimidio.sh` | Offline unit tests: R3 version extraction + `--verify` drift gate. |
| `c_src/minimidio.lock` | Provenance manifest (9 keys, SHA-pinned). |
| `c_src/minimidio.LICENSE` | Upstream MIT license text at the pinned SHA. |
| README "Updating the vendored minimidio" | The human-facing update workflow. |

## Commits produced (in order)

- `7fb52e9` — tooling (script, Makefile, CI, test, README), maintainer-authored.
- `eddb88d` — **Commit A**, author `Joseph Stewart <joseph.stewart@gmail.com>`:
  `c_src/minimidio.LICENSE` (with the R6 `Vendored-from:` trailer).
- `60fe514` — **Commit B**, author maintainer: `c_src/minimidio.lock`.
- (this report + the test-harness fix + the filled ledger land in the closing commit.)

`30f5da8` (from the slice-1 commit pass) is the first commit introducing
`c_src/minimidio.h`, authored by Joseph Stewart — the baseline R4 attribution.

## Per-row walk

All 17 rows are **done**. Highlights and the rows that needed judgement:

- **Rows 1–4 (S1):** lock has all 9 keys with a 40-char SHA; `minimidio.LICENSE`
  is upstream MIT (≠ the project's Apache `LICENSE`); `make minimidio-verify`
  exits 0; the script parses clean under `sh -n`, is `jq`-free, and its dry-run
  resolves→fetches→writes.
- **Row 5 (R1):** the upstream author is read from the *pinned commit itself*
  (the `From:` line of `<sha>.patch`), not hardcoded. `UPSTREAM_AUTHOR` is only a
  fallback + a cross-check that warns on mismatch; if both the commit and the
  constant are unavailable the run fails loudly rather than guessing.
  Implementation note: I read author+date from the commit's `.patch`
  representation rather than parsing the commits-API JSON, because it is the same
  source of truth (the pinned commit) and parses robustly in POSIX `sh` without
  `jq`. SHA resolution uses the API `application/vnd.github.sha` media type.
- **Row 6 (two-commit shape):** Commit A `eddb88d` (Joseph) touched **only**
  `minimidio.LICENSE` — not also `minimidio.h` — because the header was already
  committed byte-identical by `30f5da8`, so there was nothing to re-stage. The
  attribution is intact across the two Joseph-authored commits (`30f5da8` header,
  `eddb88d` license). On a *future content bump* Commit A will touch both files.
- **Row 7 (R2 no-op):** re-pinning the locked SHA prints "already at … nothing to
  do", writes nothing, commits nothing, leaves `retrieved` untouched.
- **Rows 8–13:** R3 tolerant version (present/variant/absent→`unknown`);
  `--no-commit` writes + prints + 0 commits; the `make` wrapper passes
  `NO_COMMIT`→`--no-commit`; `minimidio-verify` 0 on clean / non-zero on a
  tampered **temp copy** (real tree untouched); bogus-ref and simulated-curl-
  failure both abort with no mutation; the dirty-tree guard refuses to
  auto-commit a hand-edited header.
- **Row 14 (R4):** clean — the only commit introducing `minimidio.h` is the
  Joseph-authored `30f5da8`, separate from the slice-1 NIF commit `27306ba`.
  Nothing to retro-attribute.
- **Row 15 (R5):** the CI workflow runs the gate; the gate command is proven to
  fail on drift (row 11). CI *execution* happens on GitHub push — not runnable in
  CC's local environment, but the config and the underlying command are verified.
- **Rows 16–17:** README section complete; Commit A carries the `Vendored-from:`
  + sha256 trailer.

## Disposition summary

- 17 rows total. **Done: 17.** Deferred: 0. No-op: 0. All S1 and S2 rows closed.
- No silent drops; no spec-softening. The one place history can't be redone (R4)
  was already correct from slice 1.

## Disclosed deviations / notes

1. **Author/date source (R1):** read from the commit `.patch` (`From:`/`Date:`),
   not the commits-API JSON — same pinned-commit source of truth, chosen for
   robust `jq`-free parsing. SHA resolution still uses the GitHub API.
2. **Baseline Commit A scope (row 6):** touched only the LICENSE because the
   header was already Joseph-authored in `30f5da8`. Disclosed above.
3. **CI execution (row 15):** the gate config + command are verified locally; the
   GitHub-side run is exercised on the first push.
4. **Test-harness bug found & fixed during exercise:** the offline test sources
   the script with `VENDOR_MINIMIDIO_LIB=1` to access its functions. Under
   `/bin/sh` that assignment *persists and is exported* past the `.` builtin, so
   child `sh "$SCRIPT"` calls inherited it and their own guard short-circuited
   `main` — making `--verify` subprocess checks exit 0 without running (a false
   pass on the happy path, a false fail on drift). Fixed by `unset
   VENDOR_MINIMIDIO_LIB` immediately after sourcing. The vendoring script itself
   was never wrong; only the test's use of it. Noted as a real-but-unlikely
   footgun (an externally-exported `VENDOR_MINIMIDIO_LIB=1` would no-op the tool).

## What worked

- Reading provenance from the commit `.patch` sidestepped fragile JSON parsing
  and kept the tool `jq`-free while still satisfying R1 ("author from the pinned
  commit").
- Coordinating the slice-1 commit layering ahead of time (Joseph-authored
  `minimidio.h` in its own commit) made R4 a no-op here instead of an
  unfixable-history problem.
- The offline test caught a genuine environment-semantics bug (`VAR=val . file`
  export persistence under `/bin/sh`) that a manual `bash` check had masked —
  exactly the false-pass the verification discipline exists to catch.
