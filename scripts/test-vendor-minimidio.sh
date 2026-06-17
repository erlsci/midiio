#!/bin/sh
# Offline unit tests for scripts/vendor-minimidio.sh — no network, no commits.
# Covers R3 (tolerant version extraction) and the --verify drift gate.
#
# Run: sh scripts/test-vendor-minimidio.sh
set -u

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
bad()  { printf 'FAIL - %s\n' "$1"; fail=1; }

ROOT=$(git rev-parse --show-toplevel)
SCRIPT="$ROOT/scripts/vendor-minimidio.sh"

# Source the script as a library; the guard keeps main() from running.
VENDOR_MINIMIDIO_LIB=1 . "$SCRIPT"
set +e   # assert on exit codes ourselves

TMP=$(mktemp -d "${TMPDIR:-/tmp}/vmm-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# ── R3: tolerant version extraction ──────────────────────────────────────────
printf 'minimidio.h - v0.5.0-dev - one-line lib\n' > "$TMP/present.h"
v=$(extract_version "$TMP/present.h")
[ "$v" = "v0.5.0-dev" ] && pass "version present -> $v" || bad "version present -> '$v'"

printf 'x\nfoo - v1.20.3-rc2 - y\n' > "$TMP/variant.h"
v=$(extract_version "$TMP/variant.h")
[ "$v" = "v1.20.3-rc2" ] && pass "version variant -> $v" || bad "version variant -> '$v'"

printf 'no version token here\nsecond line\n' > "$TMP/absent.h"
v=$(extract_version "$TMP/absent.h")
[ "$v" = "unknown" ] && pass "version absent -> unknown" || bad "version absent -> '$v'"

# ── --verify drift gate ──────────────────────────────────────────────────────
if [ -f "$ROOT/c_src/minimidio.lock" ]; then
    ( cd "$ROOT" && sh "$SCRIPT" --verify ) >/dev/null 2>&1 \
        && pass "verify clean tree -> exit 0" || bad "verify clean tree -> nonzero"

    cp "$ROOT/c_src/minimidio.h" "$TMP/drift.h"
    printf '/* tampered */\n' >> "$TMP/drift.h"
    ( cd "$ROOT" && sh "$SCRIPT" --verify "$TMP/drift.h" ) >/dev/null 2>&1
    [ $? -ne 0 ] && pass "verify drift -> nonzero" || bad "verify drift -> exit 0"
else
    printf 'skip - verify tests (no lock yet; run after baseline vendoring)\n'
fi

if [ "$fail" -eq 0 ]; then printf 'all offline tests passed\n'; exit 0; fi
printf 'offline tests FAILED\n'; exit 1
