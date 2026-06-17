# Ledger — arc1/slice3: device enumeration + capabilities

> CC implements + fills **CC evidence**; CDC verifies independently (reads code /
> test output, not CC's summary). Severity: **S1** blocker / **S2** major / **S3**
> minor. Headless-CI rows note where an empty device list is acceptable.
> Five-iteration cap.

## Rows

| # | Acceptance criterion | How to verify | Sev | Status | CC evidence | CDC verdict |
|---|----------------------|---------------|-----|--------|-------------|-------------|
| 1 | `list_inputs/1` returns a list of `{Index, Name}`; `Index` is `non_neg_integer`, `Name` is `binary` | eunit: shape assert against an open context; each elem `{I, N}` with `is_integer(I)`, `is_binary(N)`. Empty list is acceptable (headless CI). | S1 | ☐ open | | |
| 2 | `list_outputs/1` same shape | eunit shape assert | S1 | ☐ open | | |
| 3 | Indices are ascending and contiguous `0..N-1` for the snapshot | eunit: the index column equals `lists:seq(0, length-1)` | S2 | ☐ open | | |
| 4 | A name lookup miss on an in-range index still yields an entry (not dropped) | code read: the loop emits an entry for every index `< count` regardless of `mm_*_name` result; behaviour documented | S2 | ☐ open | | |
| 5 | `caps/1` returns a map with the 6 keys (`backend, midi1, ump, midi2, virtual_in, virtual_out`) | eunit: `is_map`, all 6 keys present; values are atom (backend) / booleans | S1 | ☐ open | | |
| 6 | `backend` is the correct atom for the host OS | eunit: on macOS → `coremidi`; on Linux → `alsa`. (Per-OS assert; the other OS's branch is verified by code read where CC lacks that host.) | S1 | ☐ open | | |
| 7 | Capability flags decode `mm_context_caps` correctly | eunit: on CoreMIDI, `midi1=true, virtual_in=true, virtual_out=true, ump=false` (matches `minimidio.h:817`); booleans match the bitset decode | S2 | ☐ open | | |
| 8 | Bad handle → `badarg` (not a crash of the VM, not a silent wrong answer) | eunit: `?assertError(badarg, midiio:list_inputs(make_ref()))` and same for `list_outputs`/`caps` | S2 | ☐ open | | |
| 9 | All new atoms (backend + map keys) pre-made in `load`; none built from input | code read: the backend + key atoms are made in `load`; no `enif_make_atom` on a runtime value | S2 | ☐ open | | |
| 10 | `-nifs`/`-export`/`nif_error` stubs + `-spec` for all three new functions | grep `src/midiio.erl`: three new entries, stub bodies `?NOT_LOADED`, a `-spec` each | S2 | ☐ open | | |
| 11 | No normalization / no caching — fresh query each call | code read: each call re-queries `mm_*_count`/`mm_*_name`; no stored index table; values passed through unmodified | S3 | ☐ open | | |
| 12 | `rebar3 xref` clean | run; zero findings | S2 | ☐ open | | |
| 13 | `rebar3 dialyzer` clean (the `caps/1` map spec checks) | run; zero warnings | S2 | ☐ open | | |
| 14 | `rebar3 eunit` green | run; all tests pass | S1 | ☐ open | | |
| 15 | `rebar3 as test check` green **with the real coverage gate** (post-F1) | run the alias; exit 0, `min_coverage > 0` met by the new code too | S1 | ☐ open | | |

## Notes / disclosed deferrals

- **Headless CI:** rows 1–3 accept an empty device list — there may be no MIDI
  ports on a CI runner. The *shape* and the *caps* (rows 5–7) are the
  deterministic, always-assertable surface. Populated enumeration (real ports) is
  a manual/hardware check, or arrives with the virtual-loopback test in arc 3.
- **Per-OS rows (6, 7):** assert on the host CC has; verify the other OS's branch
  by code read and mark it for the CDC/Linux pass (same pattern as slice 1 row 3).
- **Depends on F1 remediation** for row 15 to mean anything — if F1 hasn't landed,
  note that row 15's coverage gate is still `0` and flag it, don't silently pass.
- Out of scope: device open/close, I/O, raw seam, virtual ports, UMP, registry
  context, hotplug.

## Closing

On close, CC writes `closing-report.md`; CDC writes `cdc-verification.md`. Done
when all S1 rows close and no S2 remains open without a written disposition.
