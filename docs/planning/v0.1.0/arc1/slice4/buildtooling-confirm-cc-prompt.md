# Throwaway confirmation — slice-4 build tooling (Makefile + mk/*.mk)

> Not a slice. The architect authored the build tooling directly (root
> `Makefile`, `mk/erlang.mk`, `mk/minimidio.mk`) in the midilib house style and
> verified the **offline** surface in a Linux sandbox (rendering, box alignment,
> `minimidio-verify`, `minimidio-info`, `check-tools`, and `make -n` dry-runs of
> every rebar3 target). This prompt asks CC to confirm the parts that need a real
> **macOS + OTP** box. Quick pass; report findings, don't redesign.

## What to run (and what "pass" looks like)

1. **Rendering + layout.** `make help`, `make info`, `make check-tools`. Confirm
   the ANSI colours and the `╔═╗` boxes render correctly on macOS (the colour
   vars bake a real ESC byte via `$(shell printf '\033')`, so they should — this
   is the one cross-platform risk). Confirm the box right-border `║` lines up.
2. **The rebar3-backed targets actually run green** (the architect verified the
   *invocations*, not execution — no OTP in the sandbox):
   - `make build` → `rebar3 compile` (app + NIF).
   - `make test` → `eunit` + `proper` (both under `as test`).
   - `make lint` → `xref` + `dialyzer`.
   - `make check` → `minimidio-verify` then `rebar3 as test check` (should be the
     same green gate slice 1/2 produced).
   - `make coverage` → `rebar3 as test coverage` (real `min_coverage` post-F1).
   - `make clean` → cleans, no error.
3. **`make asan`** → builds + runs the CoreMIDI ASan harness on macOS → `ASAN-OK`.
4. **`make publish` confirm-gate** — run it and answer **N**; confirm it prints
   the warning box and **aborts** without publishing. (Do NOT publish.)

## What to report back (don't fix unprompted)

- Any target that errors, and the error.
- Any colour/box misrender on macOS.
- **Is `ex_doc` configured?** `make docs` is best-effort-skip; tell us whether
  ex_doc is wired (so we decide whether to add it) or correctly skips.
- **Is a formatter configured?** `make format` best-effort-skips; report whether
  `rebar3 fmt`/erlfmt exists or it skips. (If we want erlfmt, that's a separate
  follow-up, not this pass.)
- Confirm the CI gate still works: `.github/workflows/vendor-check.yml` calls
  `make minimidio-verify` — unchanged target name, should still pass.

## Notes

- Target names `minimidio-verify` / `vendor-minimidio` were **preserved** (CI +
  README depend on them); they just moved into `mk/minimidio.mk` and gained
  styled output.
- The old root `Makefile` (the two bare vendoring targets from slice 2) was
  replaced by the new top-level Makefile that `include`s the two modules.
- This is throwaway: once confirmed, no artifact needs to survive except the
  three build files themselves.
