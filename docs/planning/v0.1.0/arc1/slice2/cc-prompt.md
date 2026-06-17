# CC assignment — arc1/slice2: deterministic minimidio vendoring + provenance

> The assignment the implementing context (CC) receives. Self-contained. Read the
> design + refinements first, then implement to the ledger. CDC verifies
> independently on close.

## Posture

Peer-frame, write-to-the-floor. Load the **collaboration-framework** and
**erlang-guidelines** skills. This slice is shell + build hygiene + git, not
Erlang/C — but the same discipline applies: let it crash on bad input (abort
loudly, mutate nothing), no defensive swallowing, surface anything you can't meet
as a disclosed deferral rather than a silent drop.

## Required reading (evidence, not summaries)

1. `docs/planning/v0.1.0/arc1/slice2/minimidio-vendoring-design.md` — the full
   spec, **including the "Architect refinements (2026-06-17)" section (R1–R6)**.
   The refinements are binding, not optional (except R6, marked optional).
2. `docs/planning/v0.1.0/arc1/slice1/ledger.md` — context: slice 1 hand-copied
   `c_src/minimidio.h` into the tree and built the NIF against it. Note its commit
   status (R4 below).
3. `workbench/minimidio/AUTHORSHIP.md` — confirms the upstream author (Joseph
   Stewart / octetta); no email recorded there (the verified email comes from the
   upstream git logs / the pinned commit — R1).

## What to build

Implement the five components exactly as the design specifies, **with the R1–R6
refinements applied**:

1. **`c_src/minimidio.lock`** — plain `key: value` manifest (shell-readable, no
   `jq`): `source, file, commit (full 40-char SHA), version, date, sha256, author,
   license, retrieved`. Tool-managed; header comment says "do not edit by hand."
2. **Vendored files under `c_src/`** — `minimidio.h` (compiled header),
   `minimidio.LICENSE` (upstream MIT text, fetched at the same SHA),
   `minimidio.lock`.
3. **`scripts/vendor-minimidio.sh`** — POSIX `sh`, no `jq`; needs `curl` + `git` +
   a sha256 tool (`sha256sum` or `shasum -a 256`). Interface:
   `vendor-minimidio.sh <ref> [--no-commit]`. Resolve `<ref>`→full SHA (+author+date
   from the GitHub commits API, **R1**), fetch header + LICENSE at that SHA, derive
   `version` (**tolerant, R3**) + sha256, write the three files atomically
   (temp + move), then make the two attributed commits (or print them under
   `--no-commit`). **True no-op when already at the pinned SHA (R2).**
4. **`Makefile`** — minimal, vendoring-chores only (does **not** replace rebar3):
   `vendor-minimidio SHA=<commit>` / `REF=<branch|tag>` (passes `NO_COMMIT=1`
   through as `--no-commit`); `minimidio-verify` (recompute sha256 of
   `c_src/minimidio.h`, compare to the lock, non-zero on drift).
5. **README section** — "Updating the vendored minimidio": where the files live,
   how to read the pin (`cat c_src/minimidio.lock`), how to bump/roll back
   (`make vendor-minimidio SHA=<sha>` / `REF=main`), the two-commit attribution and
   why, `NO_COMMIT=1` and `make minimidio-verify`, and the statement that minimidio
   is MIT (Joseph Stewart / octetta), **vendored, not forked**.

## Binding refinements (recap — see the design for full text)

- **R1** Commit A's `--author` is read from the **pinned upstream commit** (GitHub
  commits API `commit.author.{name,email}`); the verified
  `UPSTREAM_AUTHOR="Joseph Stewart <joseph.stewart@gmail.com>"` constant is the
  offline fallback + a cross-check that **warns on mismatch**. Never silently
  substitute. If neither source is available, fail loudly.
- **R2** Re-pinning the SHA already in the lock (with a matching in-tree sha256) is
  a **genuine no-op**: write nothing, commit nothing, don't churn `retrieved`.
- **R3** `version` is best-effort (`v[0-9]+\.[0-9]+[^ ]*` in the first ~5 lines);
  `unknown` if absent — never fail the run on it.
- **R4** Coordinate the baseline: `c_src/minimidio.h` must land as the
  **Joseph-authored Commit A** (the first commit introducing the file), **not**
  folded into slice 1's NIF-code commit. Check the file's commit status first; if
  it's already committed under another author, **disclose it** and start attribution
  at the next bump (history is not retro-attributed).
- **R5** Wire `make minimidio-verify` into **CI** (offline drift gate); optionally a
  rebar3 pre-compile hook, but keep it off the hot path if it adds latency.
- **R6 (optional)** Add a
  `Vendored-from: https://github.com/octetta/minimidio@<full-sha>` (+ sha256)
  trailer to Commit A's message.

## Constraints

- POSIX `sh` only; no `bash`-isms, no `jq`. Fail loudly on missing `curl`/`git`/
  sha256 tool.
- **Fail before any mutation**: validate ref resolution + fetch success before
  writing; use temp files + atomic move; on any error, no files written and no
  commits.
- **Refuse to auto-commit** when the working tree has unrelated dirty changes
  touching `c_src/minimidio.*` (tell the user to stash/commit first).
- All network steps (resolve/fetch) are exercised manually against real upstream;
  the offline-testable surface is `minimidio-verify` + the `--no-commit` dry run +
  re-pin idempotence.

## Out of scope (do not build)

Version-string→SHA resolution; mirroring branches/tags; multi-file vendoring beyond
`minimidio.h` + `LICENSE`; auto-update bots/CI cron; any change to how the NIF is
built (rebar3 + `pc` stays as-is).

## Done = every ledger row closed with evidence. If a row can't be met (e.g.,
network-dependent attribution can't be exercised in your environment), mark it
**disclosed-deferred** with a re-entry note — never silently passed. Five-iteration
cap.
