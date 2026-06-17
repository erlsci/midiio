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
| 1 | `c_src/minimidio.lock` exists with all keys; `commit` is a full 40-char SHA | `cat c_src/minimidio.lock`; assert keys `source,file,commit,version,date,sha256,author,license,retrieved`; `commit` matches `^[0-9a-f]{40}$` | S1 | ✅ done | All 9 keys present (committed in `60fe514`). `grep -qE '^commit: +[0-9a-f]{40}$'` → yes; commit `bb705e81…0907d1d6`, sha256 `3fa1e67f…07d1d6`, version `v0.5.0-dev`, date `2026-06-09`. | |
| 2 | `c_src/minimidio.LICENSE` present, MIT text, fetched at the pinned SHA | read it; assert MIT + `Copyright (c) 2026 Joseph Stewart`; not the project's Apache-2.0 `LICENSE` | S1 | ✅ done | `c_src/minimidio.LICENSE` (committed `eddb88d`) reads `MIT License` / `Copyright (c) 2026 Joseph Stewart`; project `LICENSE` is `# Apache License` — distinct. Fetched from `raw.githubusercontent.com/octetta/minimidio/bb705e81…/LICENSE`. | |
| 3 | In-tree `c_src/minimidio.h` sha256 matches `sha256` in the lock | `make minimidio-verify` exits 0 | S1 | ✅ done | `make minimidio-verify` → `minimidio-verify: OK c_src/minimidio.h (3fa1e67f…)`, exit 0. | |
| 4 | `scripts/vendor-minimidio.sh` is POSIX `sh`, no `jq`; resolves ref→full SHA, fetches, writes the 3 files | code read + `sh -n` parse; `grep -i jq` empty; dry-run shows resolve→fetch→write | S1 | ✅ done | `sh -n scripts/vendor-minimidio.sh` → PARSE OK; `grep -i jq` → only a comment ("No jq"); no bashisms. Dry-run on `bb705e8` resolved→fetched→wrote header+LICENSE+lock. | |
| 5 | **R1** — Commit A author derived from the pinned upstream commit; constant is fallback + mismatch warning | code read: author read from the commits-API response; `UPSTREAM_AUTHOR` used only as fallback/cross-check; a real (or `--no-commit`-then-manual) run shows Commit A `--author` = the upstream commit's author | S2 | ✅ done | `author_from_patch()` reads `From:` from the pinned commit's `.patch` (the commit's own author); `UPSTREAM_AUTHOR` used only as fallback + mismatch warning, never silently substituted; fail-loud if both absent. Commit `eddb88d` `--author` = `Joseph Stewart <joseph.stewart@gmail.com>` (the pinned commit's author). | |
| 6 | Two-commit attribution shape | after a run: `git log` shows **Commit A** authored by the upstream author touching only `minimidio.h` + `minimidio.LICENSE`; **Commit B** authored by the maintainer touching only `minimidio.lock` | S2 | ✅ done | Baseline run: Commit A `eddb88d` author `Joseph Stewart <joseph.stewart@gmail.com>`, touches only `c_src/minimidio.LICENSE` (header already identical from `30f5da8`, so not re-touched — see closing report). Commit B `60fe514` author `Duncan McGreggor`, touches only `c_src/minimidio.lock`. | |
| 7 | **R2** — re-pinning the current SHA is a true no-op | run `vendor-minimidio.sh <locked-sha>`; assert "already at … nothing to do", no file changes (`git status` clean), no new commits, `retrieved` unchanged | S2 | ✅ done | `make vendor-minimidio SHA=bb705e8` (already pinned) → `already at bb705e8 (v0.5.0-dev); nothing to do`; 0 new commits; `git status c_src/` empty; `retrieved` unchanged. | |
| 8 | **R3** — version extraction is tolerant | unit-check the extractor: present line → `v0.5.0-dev`; mangled/absent → `version: unknown`, run still succeeds | S3 | ✅ done | `scripts/test-vendor-minimidio.sh`: present → `v0.5.0-dev`; variant → `v1.20.3-rc2`; absent → `unknown` (no failure). | |
| 9 | `--no-commit` / `NO_COMMIT=1` writes files only, prints the two commit commands, makes no commits | run with `--no-commit`; assert no new commits, the two `git commit …` lines printed | S2 | ✅ done | `vendor-minimidio.sh bb705e8 --no-commit` → wrote LICENSE+lock, printed both `git add … && git commit …` blocks, **0 new commits**, HEAD unchanged. | |
| 10 | `make vendor-minimidio SHA=… / REF=…` wraps the script and passes `NO_COMMIT` through | `make vendor-minimidio SHA=<locked> NO_COMMIT=1`; assert it invokes the script with `--no-commit` | S2 | ✅ done | Baseline ran via `make vendor-minimidio SHA=bb705e8` (wrapper works). `make -n vendor-minimidio SHA=bb705e8 NO_COMMIT=1` → invocation includes `--no-commit`. | |
| 11 | `make minimidio-verify` exits 0 on a clean tree and non-zero on drift | run on tree → 0; mutate a byte in a **temp copy**, point verify at it → non-zero naming expected vs actual sha256 (do not corrupt the real tree) | S1 | ✅ done | Clean tree → exit 0. Tampered **temp copy** (`/tmp/…/drift.h`, sha `bce4308d…`) → exit 1 naming expected `3fa1e67f…` vs actual `bce4308d…`. Real tree never touched (offline test uses a temp copy). | |
| 12 | Error handling: unresolvable ref / HTTP failure / missing tool → abort, no files written, no commits | run with a bogus ref and with a simulated curl failure; assert clear message, `git status` unchanged, temp files cleaned | S2 | ✅ done | Bogus ref `totally-bogus-ref-zzz999` → `could not resolve ref to a commit`, exit 1, 0 commits, clean. Simulated curl failure (fake `curl` exits 7 on PATH) → same abort, 0 commits, `c_src` clean. Missing-tool guarded by `need()` (fail-loud). Temp files removed via EXIT trap. | |
| 13 | Refuses to auto-commit when the tree has unrelated dirty `c_src/minimidio.*` changes | dirty `c_src/minimidio.h` in a scratch state, run without `--no-commit`; assert refusal + stash/commit guidance, no commit made | S2 | ✅ done | Appended a line to `c_src/minimidio.h`, ran `make vendor-minimidio SHA=bb705e8` → `refusing to auto-commit: uncommitted changes to vendored files. … stash or commit them first, or re-run with --no-commit.`, 0 commits; restored via `git checkout`. | |
| 14 | **R4** — baseline lands as Joseph-authored Commit A, not folded into slice-1's NIF commit | inspect git history: the first commit introducing `c_src/minimidio.h` is the upstream-authored Commit A; if already committed otherwise, a **disclosed** note + attribution-starts-next-bump | S2 | ✅ done | `git log --diff-filter=A -- c_src/minimidio.h` → single commit `30f5da8` authored `Joseph Stewart <joseph.stewart@gmail.com>` (made during the slice-1 commit pass, **separate** from the NIF-code commit `27306ba`). The LICENSE baseline then landed as Joseph-authored `eddb88d`. Attribution intact; nothing to retro-fix. | |
| 15 | **R5** — `make minimidio-verify` wired into CI as an offline drift gate | CI config (or documented hook) runs `minimidio-verify`; a stale/hand-edited header fails the build | S3 | ✅ done | `.github/workflows/vendor-check.yml` runs `make minimidio-verify` on push/PR (offline). The gate command is proven to exit non-zero on drift (row 11), so a stale/hand-edited header fails the build. CI *execution* occurs on GitHub push (not runnable in CC's local env). | |
| 16 | README "Updating the vendored minimidio" section present and complete | read README; covers file locations, reading the pin, bump/rollback, two-commit attribution + why, `NO_COMMIT`, `minimidio-verify`, "MIT / Joseph Stewart / vendored-not-forked" | S3 | ✅ done | README "Updating the vendored minimidio" covers: file table, `cat c_src/minimidio.lock`, `make vendor-minimidio SHA=…`/`REF=main` (incl. rollback), two-commit attribution + *why*, `NO_COMMIT=1`, `make minimidio-verify`, and "vendors (does not fork) … MIT, © Joseph Stewart / octetta". | |
| 17 | **R6 (optional)** — Commit A message carries a `Vendored-from: …@<sha>` (+ sha256) trailer | `git log` of Commit A shows the trailer | S3 | ✅ done | `git log -1 eddb88d` body: `Vendored-from: https://github.com/octetta/minimidio@bb705e81…0907d1d6` and `sha256: 3fa1e67f…07d1d6`. | |

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
