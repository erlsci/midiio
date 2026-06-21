# Closing report — v0.2.0 arc1/slice1: vendor bump to the merged raw-API minimidio

> A mechanical, low-risk re-pin of `c_src/minimidio.h` from `bb705e8` to the
> upstream commit that merged our raw-bytes API. **No swap** — the interim adapter
> stays and its behavior is byte-for-byte unchanged. The load-bearing evidence is
> the additive-only diff + the suite green at the same counts. Host: macOS arm64
> (CoreMIDI), OTP 28; Linux/ALSA via `make vm-test`. Date: 2026-06-21. Iteration: 1.

## The bump

- **Merged commit:** `0fb49e6ebfb69d20e3b69dff1c41cfc34087a9b4` — "Merge pull
  request #12 from billosys/feat/raw-bytes-api" on `octetta/minimidio` `main`,
  which brought in the CoreMIDI / ALSA / WinMM / WebMIDI `mm_*_raw` implementations.
  Pinned by SHA (not `REF=main`), per the deterministic-lock design. (Two later
  commits on main add examples/docs only; the prompt specifies the merge commit.)
- `make vendor-minimidio SHA=0fb49e6…` rewrote `c_src/minimidio.h` +
  `c_src/minimidio.lock` (commit `0fb49e6…`, version `v0.5.0-dev`, date
  `2026-06-18`, sha256 `f6a18b17…`). Two attributed commits: `1a3ee4d` (header +
  LICENSE) and `3a3629e` (lock).
- `make minimidio-verify` → `OK` (header matches the new lock). `make
  minimidio-info` → the new pin.

## Provenance note (disclosed — correct, not a regression)

The vendoring script's R1 logic derives the commit author from the pinned commit
and **warns on mismatch** with the `UPSTREAM_AUTHOR` constant. Here it warned:
the pinned merge commit is authored by **Duncan McGreggor / billosys**, not Joseph
Stewart. That is correct — the raw-bytes API was contributed *by* billosys *to*
octetta/minimidio, so the merge that produced this header state is the maintainer's.
`git blame` on `c_src/minimidio.h` now correctly shows the original library lines as
Joseph Stewart's and the raw-API additions as Duncan's. The lock's `author` field
reflects the pinned commit (Duncan McGreggor). The design's per-commit attribution
working as intended — the warning is the human-review checkpoint, exercised here.

## Additive-only proof (the heart of the slice)

Full diff `bb705e8` → `0fb49e6`: **+419 lines, 5 changed lines.** The 5 changed are
benign and fully enumerated:

1. CoreMIDI **internal** struct gains a tag name: `typedef struct {` →
   `typedef struct mm__dev_coremidi {`. Invisible to the adapter and the NIF.
2–5. Four `mm_context_caps` bodies add `| MM_CAP_RAW` (the new capability bit).

Every symbol the interim adapter consumes is **byte-identical** (verified by
extract-and-diff):

| Symbol | Result |
|--------|--------|
| `mm_message` struct | identical |
| `mm_message_type` enum (the `MM_*` values) | identical |
| `mm_callback` typedef | identical |
| `mm_make_message` (decl + body) | identical |
| `mm_out_send` (decl + body) | identical |
| `mm_out_send_sysex` (decl) | identical |
| `mm_in_open` / `mm_in_open_virtual` / `mm_in_start` / `mm_in_stop` / `mm_in_close` (decls) | identical |

The public `mm_device` struct gained two **additive** fields (`mm_raw_callback
raw_callback;`, `int is_raw;`). Safe: the NIF accesses `mm_device` only as
`&res->dev` passed through the minimidio API — it never reads a `mm_device` field
by name (confirmed by grep), so additive fields can't shift anything it relies on.
The +419 lines are the new raw door (`mm_*_raw`, `MM_CAP_RAW`, `mm_raw_callback`,
the per-backend raw dispatch). **The merge is additive-only; nothing the adapter
touches changed.**

## No behavior change

- `rebar3 as test check` → exit 0, **42/42** (same as the pre-bump count) + PropEr,
  xref + dialyzer clean, coverage dormant.
- `make asan` → `ASAN-OK` (standalone harness rebuilt against the new header).
- `make vm-test` (Ubuntu 24.04, real ALSA) → **42/42 + ASAN-OK**.
- *Count reconciliation:* the ledger's "41" is the v0.1.0-close number; the current
  count is 42 on both platforms because the arc3/slice2 **S2** remediation (v0.1.0's
  tail) added `seam_roundtrip_truncated_status_test`. The bump added zero tests;
  42 (pre) = 42 (post) is the no-regression proof.

## Conformance dispositions — no flip

U1, U2, U3, S1, and `caps_backend_and_flags` all pass with **identical
dispositions**. Expected, and worth stating for the surface exam: midiio still
drives the **interim adapter** (the struct API), not the new raw API. So —

- **U1** (CoreMIDI virtual-source SysEx >256 B cap): still hit, because the adapter
  sends via `mm_out_send_sysex` (struct path), not the new cap-free
  `mm_out_send_raw`. The cap is *resolved upstream on the raw path*, but midiio
  won't reach it until the slice-3 swap.
- **U2 / U3**: adapter behavior byte-unchanged; the raw API's by-construction fixes
  aren't in play yet.
- **caps**: `caps()` decodes only the 6 known bits and ignores the new `MM_CAP_RAW`
  (bit 5), so its map is unchanged and the assertion holds.

**No disclosure flip to record for slice 2** — the raw API is present but unused;
the disclosures retire only when the swap repoints the seam (slice 3+). This is the
correct outcome for a no-swap vendor bump.

## Disposition

All 9 ledger rows done (row 7 with the count note). The pin is the merged commit,
the drift gate is green, the diff is additive-only, the full suite is green at the
same counts on macOS + ALSA, and no conformance disposition flipped. The freshly
vendored native header is now in place for the **slice-2 surface exam**. Scope held:
only the vendored header + lock changed (via the script) — no swap, no adapter
deletion, no `seam_roundtrip` change.
