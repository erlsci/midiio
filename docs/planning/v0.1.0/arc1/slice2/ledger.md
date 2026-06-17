# Ledger — arc1/slice2: deterministic minimidio vendoring + provenance

> Grep- or run-verifiable acceptance criteria. CC implements and fills **CC
> evidence**; CDC verifies independently (reads the actual files / script runs /
> git log, not CC's summary) and fills **CDC verdict**. A row closes only when CDC
> signs it. Severity: **S1** blocker / **S2** major / **S3** minor. Network-bound
> rows may be **disclosed-deferred** with a re-entry note, never silently passed.
> Five-iteration cap.

## Rows

| # | Acceptance criterion | How to verify | Sev | Status | CC evidence | CDC verdict |
|---|----------------------|---------------|-----|--------|-------------|-------------|
| 1 | `c_src/minimidio.lock` exists with all keys; `commit` is a full 40-char SHA | `cat c_src/minimidio.lock`; assert keys `source,file,commit,version,date,sha256,author,license,retrieved`; `commit` matches `^[0-9a-f]{40}$` | S1 | ☐ open | | |
| 2 | `c_src/minimidio.LICENSE` present, MIT text, fetched at the pinned SHA | read it; assert MIT + `Copyright (c) 2026 Joseph Stewart`; not the project's Apache-2.0 `LICENSE` | S1 | ☐ open | | |
| 3 | In-tree `c_src/minimidio.h` sha256 matches `sha256` in the lock | `make minimidio-verify` exits 0 | S1 | ☐ open | | |
| 4 | `scripts/vendor-minimidio.sh` is POSIX `sh`, no `jq`; resolves ref→full SHA, fetches, writes the 3 files | code read + `sh -n` parse; `grep -i jq` empty; dry-run shows resolve→fetch→write | S1 | ☐ open | | |
| 5 | **R1** — Commit A author derived from the pinned upstream commit; constant is fallback + mismatch warning | code read: author read from the commits-API response; `UPSTREAM_AUTHOR` used only as fallback/cross-check; a real (or `--no-commit`-then-manual) run shows Commit A `--author` = the upstream commit's author | S2 | ☐ open | | |
| 6 | Two-commit attribution shape | after a run: `git log` shows **Commit A** authored by the upstream author touching only `minimidio.h` + `minimidio.LICENSE`; **Commit B** authored by the maintainer touching only `minimidio.lock` | S2 | ☐ open | | |
| 7 | **R2** — re-pinning the current SHA is a true no-op | run `vendor-minimidio.sh <locked-sha>`; assert "already at … nothing to do", no file changes (`git status` clean), no new commits, `retrieved` unchanged | S2 | ☐ open | | |
| 8 | **R3** — version extraction is tolerant | unit-check the extractor: present line → `v0.5.0-dev`; mangled/absent → `version: unknown`, run still succeeds | S3 | ☐ open | | |
| 9 | `--no-commit` / `NO_COMMIT=1` writes files only, prints the two commit commands, makes no commits | run with `--no-commit`; assert no new commits, the two `git commit …` lines printed | S2 | ☐ open | | |
| 10 | `make vendor-minimidio SHA=… / REF=…` wraps the script and passes `NO_COMMIT` through | `make vendor-minimidio SHA=<locked> NO_COMMIT=1`; assert it invokes the script with `--no-commit` | S2 | ☐ open | | |
| 11 | `make minimidio-verify` exits 0 on a clean tree and non-zero on drift | run on tree → 0; mutate a byte in a **temp copy**, point verify at it → non-zero naming expected vs actual sha256 (do not corrupt the real tree) | S1 | ☐ open | | |
| 12 | Error handling: unresolvable ref / HTTP failure / missing tool → abort, no files written, no commits | run with a bogus ref and with a simulated curl failure; assert clear message, `git status` unchanged, temp files cleaned | S2 | ☐ open | | |
| 13 | Refuses to auto-commit when the tree has unrelated dirty `c_src/minimidio.*` changes | dirty `c_src/minimidio.h` in a scratch state, run without `--no-commit`; assert refusal + stash/commit guidance, no commit made | S2 | ☐ open | | |
| 14 | **R4** — baseline lands as Joseph-authored Commit A, not folded into slice-1's NIF commit | inspect git history: the first commit introducing `c_src/minimidio.h` is the upstream-authored Commit A; if already committed otherwise, a **disclosed** note + attribution-starts-next-bump | S2 | ☐ open | | |
| 15 | **R5** — `make minimidio-verify` wired into CI as an offline drift gate | CI config (or documented hook) runs `minimidio-verify`; a stale/hand-edited header fails the build | S3 | ☐ open | | |
| 16 | README "Updating the vendored minimidio" section present and complete | read README; covers file locations, reading the pin, bump/rollback, two-commit attribution + why, `NO_COMMIT`, `minimidio-verify`, "MIT / Joseph Stewart / vendored-not-forked" | S3 | ☐ open | | |
| 17 | **R6 (optional)** — Commit A message carries a `Vendored-from: …@<sha>` (+ sha256) trailer | `git log` of Commit A shows the trailer | S3 | ☐ open | | |

## Notes / disclosed deferrals

- **Network-bound rows (5, 6, 9, 12 partial, 14):** the resolve/fetch/commit path
  needs real upstream + a git repo. If CC's environment can't make real network
  calls or commits, exercise them via `--no-commit` + manual commit and mark the
  live-network portions **disclosed-deferred** with a re-entry command — don't
  silently pass.
- **R4 coordination:** confirm whether slice 1 already committed `c_src/minimidio.h`
  before running the baseline. The clean path is that the header is still
  uncommitted (or committed separately) so Commit A is its first commit. Whatever
  the actual state, record it — this is the one place history can't be redone.
- **Integrity model (disclosed):** integrity rests on HTTPS + GitHub serving the
  pinned SHA's content; the lock's sha256 is trust-on-first-use at vendor time and
  is verified against the tree thereafter. No change requested — just stated.
- Out-of-scope reminder: version-string→SHA, branch/tag mirroring, multi-file
  vendoring, auto-update cron, and any NIF build change are **not** in this ledger.

## Closing

On close, CC writes `closing-report.md` (per-row walk with evidence) and CDC writes
`cdc-verification.md` (independent re-run). Done when all S1 rows are closed and no
S2 remains open without a written disposition.
