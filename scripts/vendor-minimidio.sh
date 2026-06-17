#!/bin/sh
# vendor-minimidio.sh — deterministic vendoring of minimidio.h with provenance.
#
# Usage:
#   scripts/vendor-minimidio.sh <ref> [--no-commit]   vendor a branch/tag/commit
#   scripts/vendor-minimidio.sh --verify [FILE]        check FILE (default the
#                                                      vendored header) vs the lock
#
# minimidio has no upstream tags, so the deterministic pin is the full commit
# SHA. This writes c_src/minimidio.{h,LICENSE,lock} atomically, then makes two
# attributed commits:
#   A) minimidio.h + minimidio.LICENSE — authored by the upstream commit's author
#   B) minimidio.lock                  — authored by the current git user
# With --no-commit it writes the files and prints the two commit commands instead.
#
# POSIX sh; needs curl, git, sed, awk, and sha256sum or shasum. No jq, no bashisms.

set -eu

# ── Configuration ───────────────────────────────────────────────────────────
OWNER=octetta
REPO=minimidio
SOURCE_URL="https://github.com/${OWNER}/${REPO}"
API="https://api.github.com/repos/${OWNER}/${REPO}"
RAW="https://raw.githubusercontent.com/${OWNER}/${REPO}"
# Verified from the upstream git history for the current pin. Used only as the
# offline fallback and as a cross-check that warns on mismatch — the live author
# is read from the pinned commit itself (see author_from_patch / R1).
UPSTREAM_AUTHOR="Joseph Stewart <joseph.stewart@gmail.com>"
LICENSE_ID="MIT"

# Repo-relative paths (resolved against the git toplevel; works from any CWD).
HEADER_PATH="c_src/minimidio.h"
LICENSE_PATH="c_src/minimidio.LICENSE"
LOCK_PATH="c_src/minimidio.lock"

# ── Small helpers ───────────────────────────────────────────────────────────
err()  { printf '%s\n' "vendor-minimidio: $*" >&2; }
die()  { err "$*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"; }
today() { date +%Y-%m-%d; }
mktmp() { mktemp "${TMPDIR:-/tmp}/vendor-minimidio.XXXXXX"; }

cd_top() {
    _top=$(git rev-parse --show-toplevel 2>/dev/null) \
        || die "not inside a git repository"
    cd "$_top" || die "cannot cd to repo top: $_top"
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

lock_get() {
    # Print the value for key $1 from the lock file (empty if absent).
    [ -f "$LOCK_PATH" ] || return 0
    sed -n "s/^$1:[[:space:]]*//p" "$LOCK_PATH" | head -n1
}

extract_version() {
    # R3: tolerant. First vMAJOR.MINOR... token in the first 5 lines, else 'unknown'.
    _v=$(head -n 5 "$1" | grep -oE 'v[0-9]+\.[0-9]+[^ ]*' | head -n1 || true)
    if [ -n "$_v" ]; then printf '%s\n' "$_v"; else printf 'unknown\n'; fi
}

author_from_patch() {
    # R1: the upstream commit's author (From: line of the commit patch). Falls
    # back to UPSTREAM_AUTHOR; warns on mismatch; never silently substitutes.
    _a=$(sed -n 's/^From: //p' "$1" 2>/dev/null | head -n1 || true)
    if [ -n "$_a" ]; then
        [ "$_a" = "$UPSTREAM_AUTHOR" ] \
            || err "WARNING: pinned commit author '$_a' != expected '$UPSTREAM_AUTHOR'"
        printf '%s\n' "$_a"
    elif [ -n "$UPSTREAM_AUTHOR" ]; then
        err "WARNING: author not found in commit patch; using fallback constant"
        printf '%s\n' "$UPSTREAM_AUTHOR"
    else
        die "no upstream author available (commit patch and fallback both empty)"
    fi
}

date_from_patch() {
    # Best-effort upstream author date as YYYY-MM-DD; 'unknown' if unparseable.
    _d=$(sed -n 's/^Date: //p' "$1" 2>/dev/null | head -n1 || true)
    [ -n "$_d" ] || { printf 'unknown\n'; return 0; }
    printf '%s\n' "$_d" | awk '
        BEGIN { split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", M, " ");
                for (i = 1; i <= 12; i++) mon[M[i]] = sprintf("%02d", i) }
        { mo = mon[$3];
          if (mo == "" || $4 !~ /^[0-9]{4}$/ || $2 !~ /^[0-9]+$/) { print "unknown"; next }
          printf "%s-%s-%02d\n", $4, mo, $2 }'
}

resolve_sha() {
    # Resolve a ref (branch/tag/short or full SHA) to a full 40-char commit SHA
    # via the GitHub API "sha" media type. Fails loudly if it does not resolve.
    _ref=$1
    _sha=$(curl -fsSL -m 20 -H "Accept: application/vnd.github.sha" \
               "${API}/commits/${_ref}" 2>/dev/null || true)
    case "$_sha" in
        "" | *[!0-9a-f]*) die "could not resolve ref to a commit: '$_ref'" ;;
    esac
    [ "${#_sha}" -eq 40 ] || die "resolved value is not a 40-char SHA: '$_sha'"
    printf '%s\n' "$_sha"
}

write_lock() {
    # $1=outfile 2=sha 3=version 4=date 5=hsha 6=author
    cat > "$1" <<EOF
# minimidio vendoring lock — managed by scripts/vendor-minimidio.sh; do not edit by hand
source:    ${SOURCE_URL}
file:      minimidio.h
commit:    $2
version:   $3
date:      $4
sha256:    $5
author:    $6
license:   ${LICENSE_ID}
retrieved: $(today)
EOF
}

# ── verify subcommand ───────────────────────────────────────────────────────
do_verify() {
    _file=${1:-}
    # Resolve a relative FILE against the caller's CWD before we cd to the top.
    if [ -n "$_file" ]; then
        case "$_file" in /*) ;; *) _file="$PWD/$_file" ;; esac
    fi
    cd_top
    _file=${_file:-$HEADER_PATH}
    [ -f "$LOCK_PATH" ] || die "no lock at $LOCK_PATH; vendor first"
    [ -f "$_file" ]     || die "file to verify not found: $_file"
    _want=$(lock_get sha256)
    [ -n "$_want" ] || die "lock has no sha256 entry"
    _have=$(sha256_of "$_file")
    if [ "$_want" = "$_have" ]; then
        printf 'minimidio-verify: OK %s (%s)\n' "$_file" "$_have"
        return 0
    fi
    err "DRIFT: $_file does not match the lock"
    err "  expected (lock): $_want"
    err "  actual   (file): $_have"
    return 1
}

# ── vendor (main path) ──────────────────────────────────────────────────────
do_vendor() {
    REF=""
    NO_COMMIT=0
    for arg in "$@"; do
        case "$arg" in
            --no-commit) NO_COMMIT=1 ;;
            -*) die "unknown option: $arg" ;;
            *) if [ -z "$REF" ]; then REF=$arg; else die "unexpected extra argument: $arg"; fi ;;
        esac
    done
    [ -n "$REF" ] || die "usage: vendor-minimidio.sh <ref> [--no-commit] | --verify [FILE]"

    need curl; need git; need sed; need awk
    command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 \
        || die "need sha256sum or shasum"

    cd_top

    SHA=$(resolve_sha "$REF")
    SHORT=$(printf '%s' "$SHA" | cut -c1-7)

    # R2: genuine no-op when already pinned here and the in-tree header matches.
    if [ -f "$LOCK_PATH" ] && [ -f "$HEADER_PATH" ] \
       && [ "$(lock_get commit)" = "$SHA" ] \
       && [ "$(lock_get sha256)" = "$(sha256_of "$HEADER_PATH")" ]; then
        printf 'already at %s (%s); nothing to do\n' "$SHORT" "$(lock_get version)"
        return 0
    fi

    # Dirty-tree guard (auto-commit only): refuse if tracked vendored files have
    # uncommitted modifications, so a hand edit is not silently clobbered/swept in.
    if [ "$NO_COMMIT" -eq 0 ]; then
        if ! git diff --quiet -- "$HEADER_PATH" "$LICENSE_PATH" "$LOCK_PATH" \
           || ! git diff --cached --quiet -- "$HEADER_PATH" "$LICENSE_PATH" "$LOCK_PATH"; then
            err "refusing to auto-commit: uncommitted changes to vendored files."
            die "stash or commit them first, or re-run with --no-commit."
        fi
    fi

    # Fetch into temps; fail before any mutation of the tree.
    TMP_H=$(mktmp); TMP_LIC=$(mktmp); TMP_PATCH=$(mktmp); TMP_LOCK=$(mktmp)
    trap 'rm -f "$TMP_H" "$TMP_LIC" "$TMP_PATCH" "$TMP_LOCK"' EXIT INT TERM

    curl -fsSL -m 30 "${RAW}/${SHA}/minimidio.h" -o "$TMP_H" \
        || die "failed to fetch minimidio.h at $SHORT"
    curl -fsSL -m 30 "${RAW}/${SHA}/LICENSE" -o "$TMP_LIC" \
        || die "failed to fetch LICENSE at $SHORT"
    # The commit patch is best-effort (author + date only); do not fail on it.
    curl -fsSL -m 30 "${SOURCE_URL}/commit/${SHA}.patch" -o "$TMP_PATCH" 2>/dev/null || true

    [ -s "$TMP_H" ]   || die "fetched minimidio.h is empty"
    [ -s "$TMP_LIC" ] || die "fetched LICENSE is empty"

    VERSION=$(extract_version "$TMP_H")
    HSHA=$(sha256_of "$TMP_H")
    AUTHOR=$(author_from_patch "$TMP_PATCH")
    DATE=$(date_from_patch "$TMP_PATCH")

    write_lock "$TMP_LOCK" "$SHA" "$VERSION" "$DATE" "$HSHA" "$AUTHOR"
    mv "$TMP_H"    "$HEADER_PATH"
    mv "$TMP_LIC"  "$LICENSE_PATH"
    mv "$TMP_LOCK" "$LOCK_PATH"
    rm -f "$TMP_PATCH"
    trap - EXIT INT TERM

    printf 'vendored minimidio.h %s @ %s\n  sha256 %s\n  author %s\n' \
        "$VERSION" "$SHORT" "$HSHA" "$AUTHOR"

    _a_subject="vendor minimidio.h ${VERSION} @ ${SHORT}"
    # R6: in-message provenance trailer on Commit A.
    _a_msg="${_a_subject}

Vendored-from: ${SOURCE_URL}@${SHA}
sha256: ${HSHA}"
    _b_msg="chore(minimidio): bump lock to ${SHORT} (${VERSION})"

    if [ "$NO_COMMIT" -eq 1 ]; then
        printf '\n--no-commit: files written, not committed. To commit, run:\n\n'
        printf '  git add %s %s\n' "$HEADER_PATH" "$LICENSE_PATH"
        printf "  git commit --author='%s' -m '%s'\n\n" "$AUTHOR" "$_a_subject"
        printf '  git add %s\n' "$LOCK_PATH"
        printf "  git commit -m '%s'\n" "$_b_msg"
        return 0
    fi

    # Commit A — upstream-authored: header + license (only what actually changed).
    git add -- "$HEADER_PATH" "$LICENSE_PATH"
    if git diff --cached --quiet -- "$HEADER_PATH" "$LICENSE_PATH"; then
        printf 'commit A skipped: %s and %s already at this revision\n' \
            "$HEADER_PATH" "$LICENSE_PATH"
    else
        git commit -q --author="$AUTHOR" -m "$_a_msg" -- "$HEADER_PATH" "$LICENSE_PATH"
        printf 'committed A (author %s)\n' "$AUTHOR"
    fi

    # Commit B — maintainer: the lock.
    git add -- "$LOCK_PATH"
    if git diff --cached --quiet -- "$LOCK_PATH"; then
        printf 'commit B skipped: %s unchanged\n' "$LOCK_PATH"
    else
        git commit -q -m "$_b_msg" -- "$LOCK_PATH"
        printf 'committed B (maintainer): %s\n' "$LOCK_PATH"
    fi
}

main() {
    if [ "${1:-}" = "--verify" ]; then
        shift
        do_verify "${1:-}"
    else
        do_vendor "$@"
    fi
}

# Run unless sourced for unit tests (which set VENDOR_MINIMIDIO_LIB=1).
[ "${VENDOR_MINIMIDIO_LIB:-0}" = 1 ] || main "$@"
