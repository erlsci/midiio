# CDC verification — arc1/slice2 (minimidio vendoring)

> Independent CDC with evidence access: I read `scripts/vendor-minimidio.sh`,
> `c_src/minimidio.lock`, the `Makefile`/CI workflow, and ran the **offline-safe**
> checks myself — deliberately avoiding the live network/commit paths so I don't
> mutate the working tree (CC already exercised those live; the git history is the
> evidence, and I verified the *artifacts* of that run).

## Overall verdict: **PASS** (high-quality slice)

All 17 rows hold. The script is clean, idiomatic POSIX sh; the integrity gate is
real; attribution is correct and verified first-hand in git history. One S3
recommendation (harden a disclosed footgun); CC's two peer-flags are both
soundly resolved. Slice is already committed (`7fb52e9`, `eddb88d`, `60fe514`,
`02eb97a`).

## Independently reproduced (ran the checks myself)

- **POSIX / no bashisms (row 4):** `sh -n scripts/vendor-minimidio.sh` → exit 0;
  `jq` appears only in a comment; the lone `[[:space:]]` is a POSIX character
  class inside `sed`, not a `[[ ]]` test. Confirmed.
- **Verify gate, happy path (rows 3, 11):** `make minimidio-verify` →
  `OK c_src/minimidio.h (3fa1e67f…)`, exit 0 on the real tree.
- **Verify gate, drift (row 11):** a tampered **temp copy** hashes to
  `49d7b83b…` ≠ the lock's `3fa1e67f…` — the gate would (and does) reject it.
  Real tree untouched.
- **Attribution, first-hand (rows 6, 14 / R4):**
  `git log --diff-filter=A -- c_src/minimidio.h` → the **single** introducing
  commit is `30f5da8 Joseph Stewart <joseph.stewart@gmail.com>`, and it predates
  the slice-1 NIF-code commit `c3b6072`. The two-commit shape is in history:
  `eddb88d` (Joseph, LICENSE) + `60fe514` (Duncan, lock). R4 confirmed without
  relying on CC's summary.
- **Lock shape (row 1):** all 9 keys present; `commit` is a full 40-char SHA;
  sha256 matches the tree.

## Code-read confirmations

- **R1 (author from pinned commit):** `author_from_patch` reads `From:` from the
  commit's `.patch`, cross-checks `UPSTREAM_AUTHOR`, **warns on mismatch**, and
  fails loud if both are absent — never silently substitutes. Intent satisfied.
- **R2 (true no-op):** short-circuits when `lock commit == resolved SHA` **and**
  the in-tree header's sha256 matches (`:174–179`), before any mutation/commit.
- **R3 (tolerant version):** `extract_version` → `unknown` fallback (`:64–68`).
- **Atomicity / fail-before-mutation:** fetch into `mktmp` temps, `mv` into place,
  `trap … EXIT INT TERM` cleanup; dirty-tree guard refuses auto-commit when
  vendored files are uncommitted (`:183–189`).
- **R6 (provenance trailer):** Commit A message carries
  `Vendored-from: …@<sha>` + `sha256:` (`:222–225`).
- **resolve_sha** uses the `application/vnd.github.sha` media type → plain-text
  SHA, no jq; validates 40 hex chars.

## CC's two peer-flags — dispositions

**Flag 1 — author/date read from the commit `.patch`, not the commits-API JSON.
Disposition: APPROVED.** Same source of truth (the pinned commit's own
`From:`/`Date:`), and robustly parseable in POSIX sh without jq — arguably
*better* than JSON-in-sh. R1's letter said "commits-API `commit.author`"; the
`.patch` of the same commit is the identical fact in a sh-friendly form. R1's
intent (derive from the pinned commit, constant as fallback + mismatch warning)
is fully met. No change requested.

**Flag 2 — the `VENDOR_MINIMIDIO_LIB=1` sourced-guard footgun. Severity: S3.
Disposition: accept as-is for the slice; recommend a cheap hardening.**
Line 267 (`[ "${VENDOR_MINIMIDIO_LIB:-0}" = 1 ] || main "$@"`) means an
**externally exported** `VENDOR_MINIMIDIO_LIB=1` makes the script a silent no-op
(exit 0) — and for `--verify` that's a *false green on the integrity gate*, the
one direction that matters here. Likelihood is low (obscure name) and CC fixed
the test's own leak (`unset` after sourcing) and disclosed it. But "silent no-op
+ disables an integrity gate" is worth defusing cheaply. Recommended (any one):
1. Have the **CI gate assert the gate actually ran** — grep the step output for
   `minimidio-verify: OK` rather than trusting exit 0. Strongest mitigation;
   catches *any* silent no-op, not just this cause.
2. Rename the sentinel to a collision-proof, underscore-prefixed name
   (`__MIDIIO_VENDOR_SOURCED`).
3. `unset VENDOR_MINIMIDIO_LIB` immediately after the guard check so it can't
   propagate further.
Not a blocker; (1) is the belt-and-suspenders I'd pick.

## Rows accepted on CC's live-run evidence (not re-run, to avoid mutating the tree)

Rows 5, 7, 9, 10, 12, 13 exercise the live network/commit/no-commit paths. I
verified their **artifacts** (the four commits, the lock, the LICENSE, the
`--no-commit` print structure in code) and read the code paths; I did not re-run
the network/commit flows because doing so in the working tree is destructive and
CC already produced the evidence. The code supports every claim.

## Bottom line

Sound slice, no rework needed. The single actionable item is the S3 footgun —
I'd take CC up on the offer and add CI-output assertion (mitigation 1). The
`.patch` author-parsing is a good call and should be noted as the accepted form
of R1.
