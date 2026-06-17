# Ledger — arc1/slice1: build skeleton + NIF load + context resource

> Grep- or run-verifiable acceptance criteria. CC implements and fills the
> **CC evidence** column; CDC verifies independently (reads the actual code /
> build output / test run, not CC's summary) and fills **CDC verdict**. A row
> closes only when CDC signs it. Severity: **S1** blocker / **S2** major /
> **S3** minor. Five-iteration cap on the slice.

## Rows

| # | Acceptance criterion | How to verify | Sev | Status | CC evidence | CDC verdict |
|---|----------------------|---------------|-----|--------|-------------|-------------|
| 1 | `rebar3 compile` produces the NIF shared object in `priv/` on the host OS | `ls priv/midiio_nif.*` after a clean `rebar3 compile`; check `pc` ran | S1 | ☐ open | | |
| 2 | macOS artifact is loadable: `erlang:load_nif/2` finds it (`.so` vs `.dylib` resolved) | `rebar3 shell` on Darwin; `midiio:context_open()` ≠ `nif_not_loaded` error | S1 | ☐ open | | |
| 3 | NIF loads on Linux | `rebar3 shell` on Linux; `midiio:context_open()` returns `{ok, Ref}` | S1 | ☐ open | | |
| 4 | `context_open/0` returns `{ok, Ref}` with an opaque resource term | eunit: assert `{ok, R}` and `is_reference(R) orelse is_binary(R)` is false (opaque resource), no exception | S1 | ☐ open | | |
| 5 | `context_close/1` returns `ok` on a live context | eunit round-trip open→close | S2 | ☐ open | | |
| 6 | Double `context_close/1` returns `{error, not_open}` (no crash) | eunit: open, close, close again; assert tagged error | S2 | ☐ open | | |
| 7 | Destructor runs on GC without double-uninit | eunit: open, drop ref, `erlang:garbage_collect/0` + sleep; instrument dtor (counter via `enif_fprintf`/atomic) and assert exactly one uninit; no VM crash | S1 | ☐ open | | |
| 8 | Resource type opened **only** in `load`; `live` flag guards uninit | code read: `enif_open_resource_type` appears once, in `load`; both close and dtor check `live` | S2 | ☐ open | | |
| 9 | `mm_result` → atom mapping covers all 8 codes | eunit drives an introspection NIF or unit-tests the mapping helper; assert each atom | S3 | ☐ open | | |
| 10 | `-on_load`, `-nifs([context_open/0, context_close/1])`, and `nif_error` stubs present | grep `src/midiio.erl` for the three; assert stub bodies call `erlang:nif_error/1` | S2 | ☐ open | | |
| 11 | `-spec` on every exported function | grep specs; dialyzer sees them | S3 | ☐ open | | |
| 12 | `rebar3 xref` clean | run; zero undefined/unused | S2 | ☐ open | | |
| 13 | `rebar3 dialyzer` clean | run; zero warnings | S2 | ☐ open | | |
| 14 | `rebar3 eunit` green | run; all tests pass | S1 | ☐ open | | |
| 15 | `rebar3 check` (the alias: compile→xref→dialyzer→eunit→coverage) green | run the alias end to end | S1 | ☐ open | | |
| 16 | No memory error under a sanitizer pass on the open/close/GC cycle | build the TU with `-fsanitize=address` (or run under `valgrind` on Linux); open/close/GC loop; zero leaks/errors | S2 | ☐ open | | |

## Notes / disclosed deferrals

- Rows 2 and 3 require both OSes. If only one host is available to CC, the
  other-OS rows are **disclosed-deferred** (not closed, not dropped) and handed
  to CDC or a follow-up — never silently passed.
- Row 16 (sanitizer) is the cheap insurance on the destructor/refcount logic that
  is the whole point of this slice; keep it.
- Out-of-scope reminder: enumeration, devices, I/O, the raw seam, dirty NIFs, and
  `enif_send` are **not** in this ledger by design (later slices).

## Closing

On close, CC writes `closing-report.md` (per-row walk with evidence) and CDC
writes `cdc-verification.md` (independent re-run). The slice is done when all S1
rows are closed and no S2 remains open without a written disposition.
