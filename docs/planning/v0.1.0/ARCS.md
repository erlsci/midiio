# midiio v0.1.0 — Arc & Slice Breakdown

> SDLC step 4 (sequencing). Cuts the project into arcs (coherent capabilities)
> and slices (one-context execution units). Per the methodology, a slice is sized
> to be held in one model context with iteration headroom; "if it won't fit, it
> was two slices." Layout: `docs/planning/v0.1.0/arc<N>/slice<N>/` with slice
> index resetting to 1 each arc. Each slice carries `slice-doc.md`, `ledger.md`,
> `cc-prompt.md`, and (at close) `closing-report.md` + `cdc-verification.md`.

## Ledger philosophy (applies to every slice)

CC implements; CDC verifies independently with evidence access (reads the actual
code/diffs/test output, not CC's summary). Each ledger row is a grep- or
run-verifiable acceptance criterion. Five-iteration cap per slice; needing more
signals the slice was mis-sized. Severity-classified findings; every finding gets
a written disposition before close.

## Arc map

```
arc1  NIF foundation & enumeration   ── no device I/O; proves toolchain + resource model
arc2  Outbound transport             ── send bytes out over the raw seam, dirty-I/O
arc3  Inbound transport & conformance ── recv → enif_send, owner pid, virtual loopback
```

Arcs are strictly ordered: arc2 needs arc1's context resource + build; arc3 needs
arc2's device resource + the raw seam. Within the family, **arc2 is the first
thing midi can integrate against** (outbound send), so it is the priority after
foundation.

---

## Arc 1 — NIF foundation & enumeration

**Capability:** `rebar3 compile` builds and loads the NIF on macOS + Linux; an
Erlang caller can open/close a context and enumerate devices. No I/O yet. This
arc retires all the toolchain and resource-model risk.

**Slice 1 — build skeleton + NIF load + context resource.** *(load-bearing; the
first cc-prompt + ledger are written.)*
The thinnest end-to-end vertical: vendored header, NIF TU, `pc` build producing
`priv/midiio_nif.so`, `-on_load`, stubs; the `midiio_context` resource type
opened in `load`; `context_open/0` + `context_close/1` with a destructor calling
`mm_context_uninit`; `result_string` → atom mapping. Proves: the toolchain
loads, a resource type round-trips, a destructor runs on GC.

**Slice 2 — deterministic minimidio vendoring + provenance.** *(inserted; design
at `arc1/slice2/minimidio-vendoring-design.md`.)* Replace the hand-copied
`c_src/minimidio.h` with a tracked, bumpable, attributed vendoring mechanism:
SHA-pinned lock manifest, a fetch/verify script, a `make` wrapper, sha256 drift
detection, and a two-commit attribution that credits the upstream author. Build
hygiene that the rest of the arc rests on (every later slice compiles this header).

**Slice 1 remediation F1** *(between slice 2 and slice 3).* Add a NIF `upgrade`
callback so `cover` can instrument the module, and raise the coverage gate from a
no-op to a real floor (CDC finding F1). Docs:
`arc1/slice1/F1-remediation-{cc-prompt,ledger}.md`. Lands before slice 3 grows
the module, so every later slice inherits a real coverage gate.

**Slice 3 — enumeration + caps.** *(was slice 2.)* `list_inputs/1`,
`list_outputs/1` (index+name via `mm_in_count`/`mm_in_name` etc.), `caps/1`
returning a map with the **backend atom + capability booleans** (R6). Read-only
discovery against the caller's context; the singleton **registry context** (§2)
is deferred to arc 2 where the per-device-context model needs it (not required
for enumeration).

**Slice 4 — build tooling** *(inserted after slice 3; authored directly, not a
ledger slice).* A styled `make` front end in the midilib house style (ANSI
colours, `╔═╗` headings, `✓`/`→`/`⚠` markers): root `Makefile` + `mk/erlang.mk`
(BEAM: compile/test/lint/coverage/docs/publish via rebar3, with the `as test`
profile baked in) + `mk/minimidio.mk` (the vendored-C download/pin/verify, target
names preserved for CI). Colours use a real ESC byte (`$(shell printf '\033')`)
so they render on macOS + Linux. Offline surface verified in-sandbox; rebar3-backed
targets confirmed by CC on macOS (`workbench/slice4-buildtooling-confirm-cc-prompt.md`).
Ordering only — does not block the arc's capabilities.

**Slice 5 — arc-1 hardening (close-out).** No new device capability; pays down the
debt before arc 2: a **NIF-aware coverage strategy** (exclude the binding module
from the cover gate so it stops eroding), **F2** (gate test-only NIFs behind a
test build), **F3** (scope `plt_extra_apps` to the test profile so bare
`rebar3 dialyzer` works), **relocate `NIF-LEARNINGS.md`** into tracked space, a
**cross-platform CI** matrix (ubuntu + macos) that closes the deferred-Linux pile
(slice-1 row 3, slice-3 row 6, slice-1 row 16 leak) on every push, and **commit
hygiene**. Ends with the **arc-1 close-out check** (specified-vs-delivered diff).
Two items carry disclose-defer latitude (F2 dual-build; headless-ALSA runtime).

## Arc 2 — Outbound transport

**Capability:** open an output device, `send(Dev, <<bytes>>)` a complete message,
have it emitted byte-exact; closing/crashing the owner leaks no handle.

**Slice 1 — device resource + output lifecycle.** `midiio_device` resource type;
`open_output/2`, `close/1`; device keeps context alive (`enif_keep_resource`);
destructor closes the OS handle. The per-device-context model (§2) lands here.

**Slice 2 — `send/2` over the raw seam + dirty-I/O.** Define the internal raw
seam (`midiio_dev_send_raw(dev, bytes, len)`); implement the **interim adapter**
(parse leading byte → route SysEx vs. fill `mm_message` → `mm_out_send`); mark the
NIF `ERL_NIF_DIRTY_JOB_IO_BOUND`; error mapping (§6). The seam is the swap point
for native `mm_out_send_raw` later.

## Arc 3 — Inbound transport & conformance

**Capability:** open an input, receive `{midi_in, Dev, <<bytes>>, Ts}` one
complete message at a time; full virtual-loopback conformance, Erlang-drivable.

**Slice 1 — input lifecycle + recv → enif_send.** `open_input/3` (owner pid),
`start_input/1`, `stop_input/1`, `close/1`, `set_owner/2` (mutex-guarded); the
recv callback builds the term in a process-independent env and
`enif_send(NULL, ...)`; inbound side of the raw seam (serialize `mm_message` →
bytes); integer-ns host-monotonic timestamp (§3).

**Slice 2 — virtual-loopback conformance + quirk cases.** Open a virtual source +
virtual destination in one VM; round-trip the message taxonomy at the byte level;
PropEr for the bytes⇄message bridge; explicit U1–U3 + S1 cases (green or disclosed
expected-fail). Erlang-drivable scaffolding for midi's integration test (R8).

---

## Sizing notes & risks

- **arc1/slice1 is the riskiest per line** — it's all toolchain (does `pc` build
  and load a NIF cleanly under this rebar3 on both OSes?). Kept deliberately thin
  so that risk is isolated and cheap to iterate.
- **arc2/slice2 and arc3/slice1** carry the bytes⇄`mm_message` interim adapter —
  the throwaway code. Isolated behind the seam so the eventual `mm_*_raw` swap is
  a one-file change.
- **arc3/slice2** depends on virtual ports working; U1 caps its large-SysEx
  assertions (disclosed).
- **Open dependency:** `send_batch/2` (NEW-1) is *not* in this breakdown; if midi
  wants sub-message-latency batching it becomes arc2/slice3 or an arc-4 item.

## Deferred arcs (post-v0.1.0, named)

- **arc-W** WinMM backend + CI. **arc-V** virtual ports as public surface.
  **arc-U** UMP. **arc-raw** swap interim adapter → native `mm_*_raw` when
  upstream ships. **arc-web** WebMIDI/Emscripten.
