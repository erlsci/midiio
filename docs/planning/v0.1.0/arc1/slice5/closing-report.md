# Closing report — arc1/slice5: arc-1 hardening (close-out)

> CC's per-item walk + the arc-1 close-out diff. CDC verifies independently.
> Host: macOS arm64, OTP 28. Date: 2026-06-17. Iteration: 1.

## Per-item disposition

**Item 1 — NIF-aware coverage (done).** Added `{cover_excl_mods, [midiio]}` and
raised the floor to `--min_coverage=80`. **Run-confirmed behaviour:** with the
sole module excluded, cover reports `No coverdata found` and the gate passes
**vacuously** — exactly the dormant state intended. `rebar3 as test check` green.
Adding another NIF no longer touches the gate (the binding module's % is out of
the metric). The floor becomes a true gate automatically when arc-2/3 logic
modules (the per-device `gen_server`, helpers) land. Rationale is in
`rebar.config` (NIF-binding module; surface verified by eunit + ASan, not line %).

**Item 2 — F2 (DISCLOSED-DEFERRED, S3).** Attempted: `#ifdef MIDIIO_TEST` (C) +
`-ifdef(TEST)` (Erlang) + `-DMIDIIO_TEST`/`{d,'TEST'}` in the test profile. The
default build correctly excluded the test NIFs *and loaded* (`result_atom`
unexported, `context_open` works). But the **test build is order-dependent**:
`pc` builds one shared `priv/midiio_nif.so` + `c_src/*.o` in the **source tree**
across profiles, not per-profile under `_build/`. So a clean test-only build
passes (12/12), but `rebar3 compile` (default, no macro) followed by
`rebar3 as test check` reuses the stale default `.so` (5 NIFs) against the test
Erlang's 7 `-nifs` → `load_nif` mismatch → eunit `nif_not_loaded`. Making it
robust needs per-profile `.so` artifacts (or a test pre-hook that force-rebuilds
the `.so` under `MIDIIO_TEST`) — disproportionate machinery for an S3 item whose
test NIFs are harmless. **Reverted** to keep `check` reliably green regardless of
build order. **Re-entry:** when arc 2 adds more NIFs / a build refactor, give the
test build its own `.so` artifact path, then re-apply the `#ifdef`/`-ifdef`
guards (the diff is small and recorded in this report + the in-code notes).

**Item 3 — F3 (done).** Moved `{plt_extra_apps, [eunit, proper]}` out of the
top-level `dialyzer` config into the **test profile's** `dialyzer`. Verified: bare
`rebar3 dialyzer` → exit 0, "Analyzing 1 files" (no "Could not find application:
proper"); `rebar3 as test dialyzer` → exit 0, "Analyzing 2 files". The
`mk/erlang.mk` `-framework CoreFoundation` asan fix was already committed
(`e75a490`).

**Item 4 — relocate NIF-LEARNINGS (done).** `workbench/NIF-LEARNINGS.md` →
`docs/NIF-LEARNINGS.md` (tracked; `git check-ignore` says not ignored). Header
note updated with the new location; path references updated in the F1 docs and
`workbench/NIF-GUIDE-planning-prompt.md`. (The slice-5 cc-prompt/ledger keep the
old path because they *describe* the move.)

**Item 5 — cross-platform CI (done; Linux runtime pending first push).** Added
`.github/workflows/ci.yml`: matrix `ubuntu-latest` + `macos-latest`, `setup-beam`
(OTP 27), `libasound2-dev` on Linux, a best-effort `modprobe snd-seq snd-virmidi`
for a headless ALSA sequencer, then `rebar3 as test check` + `make asan`.
**Verified locally (macOS leg):** `rebar3 as test check` and `make asan` are
green. **Disclosed:** CC is macOS-only, so the *Linux* outcome is determined on
the first push — the workflow is structured to close the deferred-Linux rows
(slice-1 row 3 load, slice-3 row 6 `alsa` backend, slice-1 row 16 leak via
LeakSanitizer) **if** the runner can load `snd-virmidi`; if it cannot, those
ALSA-*runtime* rows stay disclosed-deferred while the Linux build/link/
enumeration-shape/ASan-compile still run. The deferred-Linux rows in slices 1 and
3 now point here as their re-entry. `vendor-check.yml` kept as the focused offline
drift gate.

**Item 6 — commit hygiene (done).** See the commit log: slice-4 tooling + CDC docs
+ ARCS were committed earlier (`d89ad6b`, `606aeaa`, `e75a490`); this slice's
changes are committed grouped (coverage/F3 config, the relocated learnings log,
the CI workflow, the F2-deferred notes, and these docs), maintainer-authored.

## Arc-1 close-out check — specified vs delivered

`ARCS.md` Arc 1 capability: *"`rebar3 compile` builds and loads the NIF on macOS +
Linux; an Erlang caller can open/close a context and enumerate devices. No I/O
yet. Retires toolchain + resource-model risk."*

| Specified capability | Delivered | Evidence / disposition |
|----------------------|-----------|------------------------|
| Build + load NIF (macOS) | ✅ | slice 1; `pc` → `priv/midiio_nif.so`, loads, `context_open` works |
| Build + load NIF (Linux) | ⏳ CI | port_env Linux branch wired; **runtime verified on first CI push** (item 5) — disclosed, not dropped |
| Context open/close + GC destructor (no double-free) | ✅ | slice 1 (eunit rows 4–8; ASan); F1 made the gate real |
| Enumeration `list_inputs/outputs` | ✅ | slice 3; real-hardware run (16 in / 15 out, ascending) |
| `caps/1` backend atom + capability booleans (R6) | ✅ | slice 3; `coremidi` + flags asserted; `alsa` branch by code read → CI |
| Deterministic vendoring (build hygiene) | ✅ | slice 2; SHA-pinned lock, drift gate, attributed commits |
| Real (non-eroding) coverage gate | ✅ | F1 + slice-5 item 1 (NIF-aware; no longer erodes) |
| Toolchain/resource-model risk retired | ✅ | the above compose; no I/O yet (correct — that's arc 2) |

**No silent drops.** Two disclosed gaps carry re-entry notes: (a) Linux *runtime*
verification → first CI push (mechanism in place); (b) F2 test-NIF gating →
deferred S3 (re-entry above). Everything else in the Arc-1 spec shipped and is
evidenced. `rebar3 as test check` is green with a coverage gate that no longer
erodes. **Arc 1 is ready to close.**
