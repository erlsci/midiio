# Design — deterministic minimidio vendoring + provenance

> Status: approved (2026-06-17). Spec for a single implementation plan.
> Next step after spec sign-off: `writing-plans`.

## Context

`midiio` compiles a vendored single-file C library, `c_src/minimidio.h`, into its
NIF. The file was copied in by hand, with no record of which upstream revision it
came from, no way to bump or roll back deterministically, and no mechanism to
credit its upstream author. We need vendoring that is:

1. **Tracked** — the exact upstream revision in use is recorded.
2. **Bumpable/reversible** — pull a different revision (up for upgrades, down for
   rollbacks) by a single deterministic command.
3. **Correctly attributed** — every addition/update of the C file is committed
   with the upstream developer's identity, so git history names them as the
   creator of that code.
4. **Documented** — the README explains how to choose a version and update the
   copy.

### Upstream facts (determine the design)

- Repo: `https://github.com/octetta/minimidio` (default branch `main`).
- License: **MIT**, `Copyright (c) 2026 Joseph Stewart`.
- Author of `minimidio.h`: **Joseph Stewart `<joseph.stewart@gmail.com>`** (GitHub
  `octetta`) — all commits to the file. The email is **verified from the upstream
  git logs** (`AUTHORSHIP.md` names him but records no email). It is correct for
  the current pin and serves as the seed/fallback constant; the tool still derives
  the author from the *pinned commit* as the source of truth so it stays correct
  across future bumps (see Architect refinement R1).
- **No git tags or releases.** "Versions" are identified only by a header string
  (line 2, e.g. `minimidio.h - v0.5.0-dev`) plus the commit SHA.
- Currently vendored revision: commit `bb705e81f5c1ac3601b1b75bec45b86d2a15426c`,
  version `v0.5.0-dev`, dated 2026-06-09. Our `c_src/minimidio.h` is byte-identical
  to upstream at that commit (sha256
  `3fa1e67f636ec958b6f09c1b11657584805dac7db37dc31130faa7860907d1d6`).

**Consequence:** the only deterministic, reproducible pin is the **commit SHA**.
The version string is human-facing metadata, not a reliable handle. The mechanism
therefore pins by SHA and records the version string alongside.

## Decisions (approved forks)

| Fork | Decision |
|------|----------|
| Pinning model | SHA as source of truth, in a lock manifest; version string + date recorded for humans. |
| Attribution | **Two commits** per update: the C file (+ its LICENSE) authored as the upstream developer; our metadata (lock) authored by the maintainer. |
| Tooling form | A POSIX `sh` script wrapped by a `make` target. |
| Commit step | Auto-commit by default; `NO_COMMIT=1` escape hatch writes files only and prints the commit commands. |

## Architect refinements (2026-06-17)

Hardening *within* the approved forks — none of these change the pinning model,
the two-commit attribution, the `sh`+`make` form, or the auto-commit default.

- **R1 — derive the upstream author from the pinned commit (robustness, not a
  fix).** The hardcoded `joseph.stewart@gmail.com` is **verified** from the
  current upstream git logs, so it's correct today and is fine as the seed/fallback
  `UPSTREAM_AUTHOR` constant. The improvement: the script already hits the GitHub
  commits API for the date — read `commit.author.{name,email}` from the *same*
  response and use that as Commit A's `--author`, so attribution tracks whatever
  the pinned commit actually records and can't drift stale across future bumps.
  Keep the constant as an offline fallback + a cross-check that **warns on
  mismatch**; never silently substitute a different identity. If both the API and
  the constant are unavailable, fail loudly rather than attribute to a guess.
- **R2 — true no-op idempotence.** If `<ref>` resolves to the SHA already in the
  lock *and* the in-tree `minimidio.h` sha256 matches, short-circuit: print
  "already at `<sha>`, nothing to do", write nothing, commit nothing. Do **not**
  rewrite `retrieved` on a no-op (it would churn the lock into an empty-content
  commit). Re-pinning the current SHA must be a genuine no-op.
- **R3 — tolerant version extraction.** Read `version` best-effort (grep the first
  ~5 lines for a `v[0-9]+\.[0-9]+[^ ]*` token); if absent or the header format
  changed, record `version: unknown` and continue. The SHA + sha256 are the pin;
  the version string must never fail the run.
- **R4 — coordinate the initial baseline with slice 1.** slice 1 hand-copied
  `c_src/minimidio.h`. That file must **not** ride in slice 1's NIF-code commit:
  the first vendoring run produces the (byte-identical) header + LICENSE as the
  Joseph-authored **Commit A**, which should be the first commit introducing
  `c_src/minimidio.h`. If the header is already committed under another author,
  history can't be retro-attributed — disclose it and accept that attribution
  starts at the next bump. Confirm the file's commit status before the baseline run.
- **R5 — gate drift in CI.** `make minimidio-verify` is offline and cheap; run it
  as a CI step (and optionally a rebar3 pre-compile hook) so a hand-edited or stale
  header fails the build, not just a manual check. Keep it off the hot
  `rebar3 compile` path if a hook adds latency — a dedicated CI step suffices.
- **R6 (optional) — in-message provenance.** Add a
  `Vendored-from: https://github.com/octetta/minimidio@<full-sha>` trailer (plus
  the sha256) to Commit A's message, so provenance is legible in `git log` without
  opening the lock — belt-and-suspenders with the author attribution.

## Components

### 1. Lock manifest — `c_src/minimidio.lock`

Plain `key: value` text (shell-readable without `jq`). Tool-managed.

```
# minimidio vendoring lock — managed by scripts/vendor-minimidio.sh; do not edit by hand
source:    https://github.com/octetta/minimidio
file:      minimidio.h
commit:    bb705e81f5c1ac3601b1b75bec45b86d2a15426c
version:   v0.5.0-dev
date:      2026-06-09
sha256:    3fa1e67f636ec958b6f09c1b11657584805dac7db37dc31130faa7860907d1d6
author:    Joseph Stewart <joseph.stewart@gmail.com>
license:   MIT
retrieved: 2026-06-17
```

- `commit` — the deterministic pin (full 40-char SHA).
- `version` — extracted from header line 2.
- `date` — upstream commit date (best-effort; from `git ls-remote`/API resolution).
- `sha256` — integrity hash of the vendored `c_src/minimidio.h`; powers drift detection.
- `retrieved` — date the pull was performed.

### 2. Vendored files (all under `c_src/`)

- `minimidio.h` — the header that gets compiled (unchanged role).
- `minimidio.LICENSE` — upstream MIT license text, fetched at the same SHA. MIT
  requires preserving the copyright notice; vendoring the license is how we do it.
  Named to disambiguate from the project's own top-level `LICENSE`.
- `minimidio.lock` — the manifest above.

### 3. Script — `scripts/vendor-minimidio.sh`

POSIX `sh`, no `jq` dependency; requires `curl` and `git`. Single responsibility:
fetch a pinned revision, verify it, write the three files, and (by default) make
the two attributed commits.

**Interface:** `scripts/vendor-minimidio.sh <ref> [--no-commit]` where `<ref>` is a
branch, tag, or commit SHA.

**Steps:**

1. **Resolve `<ref>` to a full immutable commit SHA, then read its date.**
   - Named refs (branch/tag): `git ls-remote https://github.com/octetta/minimidio.git <ref>`
     → full SHA. Commit SHAs (full or short) are resolved via the GitHub commits
     API (`/repos/octetta/minimidio/commits/<ref>`), taking the first `"sha"` field.
   - With the full SHA in hand, query the GitHub commits API once
     (`/commits/<full-sha>`) for the author `"date"` (best-effort; the lock still
     pins on SHA + sha256 if the date lookup is unavailable). The hardcoded
     `UPSTREAM_AUTHOR` constant is cross-checked against the API author name/email
     and warns on mismatch.
   - Fail loudly if the ref does not resolve.
2. **Fetch at the resolved SHA** from
   `https://raw.githubusercontent.com/octetta/minimidio/<full-sha>/minimidio.h` and
   `.../LICENSE`. Abort on any non-200 / curl error (no partial writes).
3. **Derive metadata:** `version` from header line 2; `sha256` via `sha256sum` or
   `shasum -a 256` (whichever exists — macOS/Linux).
4. **Write** `c_src/minimidio.h`, `c_src/minimidio.LICENSE`, `c_src/minimidio.lock`.
5. **Commit (unless `--no-commit`):**
   - **Commit A** — `git add c_src/minimidio.h c_src/minimidio.LICENSE` then
     `git commit --author="Joseph Stewart <joseph.stewart@gmail.com>" -m "vendor minimidio.h <version> @ <short-sha>"`.
   - **Commit B** — `git add c_src/minimidio.lock` then
     `git commit -m "chore(minimidio): bump lock to <short-sha> (<version>)"`
     (authored by the current git user).
   - `--no-commit`: write files only; print the two commands above for the human
     to run.
6. **Print a summary:** old SHA → new SHA, version, sha256, files written, commit
   mode.

**Upstream author identity** is a clearly-marked constant at the top of the script
(`UPSTREAM_AUTHOR="Joseph Stewart <joseph.stewart@gmail.com>"`), also written into
the lock. If the resolution path can cheaply read the upstream commit author, the
script warns on mismatch; it does not silently diverge.

### 4. Make targets — `Makefile`

The repo currently has no Makefile; this introduces a minimal one (it does not
replace rebar3 for building — it only wraps vendoring chores).

- `make vendor-minimidio SHA=<commit>` or `make vendor-minimidio REF=<branch/tag>`
  → runs the script with that ref. `NO_COMMIT=1` is passed through as `--no-commit`.
- `make minimidio-verify` → recompute the sha256 of `c_src/minimidio.h` and compare
  to `c_src/minimidio.lock`; exit non-zero on drift. CI-friendly; proves the in-tree
  header still matches its pinned revision.

### 5. README section — "Updating the vendored minimidio"

Covers: where the files live (`c_src/minimidio.{h,LICENSE,lock}`); how to read the
current pin (`cat c_src/minimidio.lock`); how to bump or roll back (find the commit
on GitHub, then `make vendor-minimidio SHA=<sha>`; or `REF=main` for latest); the
two-commit attribution and why; the `NO_COMMIT=1` and `make minimidio-verify`
helpers; and a statement that minimidio is MIT, authored by Joseph Stewart /
octetta, and is **vendored, not forked**.

## Data flow

```
make vendor-minimidio SHA=<x>
  -> scripts/vendor-minimidio.sh <x>
       resolve <x> --------------------> full SHA + date   (git ls-remote / GitHub API)
       fetch header + LICENSE @ SHA ----> raw.githubusercontent.com   (curl)
       derive version + sha256
       write c_src/minimidio.{h,LICENSE,lock}
       commit A (author=upstream): minimidio.h + LICENSE
       commit B (author=maintainer): minimidio.lock
```

`make minimidio-verify`: read `sha256`/`commit` from lock → hash `c_src/minimidio.h`
→ compare → ok / drift.

## Error handling

- Unresolvable ref, network/HTTP failure, or missing `curl`/`git`/`sha256` tool →
  abort with a clear message; **no files written, no commits** (fail before any
  mutation; use a temp file + atomic move).
- A dirty working tree touching `c_src/minimidio.*` when about to auto-commit →
  refuse and tell the user to stash/commit first (avoid sweeping unrelated changes
  into the attributed commits).
- `minimidio-verify` drift → non-zero exit naming expected vs actual sha256.

## Testing

- **`minimidio-verify` happy path:** against the current tree, exits 0.
- **Drift detection:** mutate a byte of `c_src/minimidio.h` in a scratch copy →
  verify exits non-zero. (Test operates on a temp copy; does not corrupt the tree.)
- **`--no-commit` dry run:** run the script with `--no-commit` pointed at the
  already-pinned SHA → files unchanged (idempotent), correct commit commands
  printed, no commits made.
- **Re-pin idempotence:** vendoring the currently-pinned SHA produces no content
  change and a byte-identical lock (modulo `retrieved` date).
- **Attribution shape:** after a real (or `--no-commit`-then-manual) run, `git log`
  shows Commit A authored by `Joseph Stewart <joseph.stewart@gmail.com>` touching
  only `minimidio.h` + `minimidio.LICENSE`.

Network-dependent steps (resolve/fetch) are exercised manually against real
upstream during rollout; the offline-testable surface is verify + dry-run.

## Rollout notes

- The mechanism pulls from GitHub, **not** from `workbench/` (now git-ignored), so
  it has no dependency on the untracked local clone.
- **Initial baseline:** seed `c_src/minimidio.lock` with the verified current values
  (SHA `bb705e81…`, sha256 `3fa1e67f…`). To honor attribution from the start, the
  initial `c_src/minimidio.h` + `LICENSE` should land via a Joseph-authored Commit A,
  kept separate from the slice-1 NIF commits.
- `c_src/minimidio.LICENSE` must be fetched during the initial run (it is not yet
  in the tree).

## Out of scope

- Resolving a header version string → SHA (not reliable without upstream tags; the
  human looks up the commit on GitHub).
- Mirroring upstream branches/tags, multi-file vendoring beyond `minimidio.h` +
  `LICENSE`, or auto-update bots/CI cron.
- Changing how the NIF is built (rebar3 + `pc` is unchanged).
