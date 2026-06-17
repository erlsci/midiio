# arc1/slice5 — arc-1 hardening (the close-out slice)

> Plan-of-record. Parent: `ARCS.md` (Arc 1, final slice). This slice carries no
> new device capability — it pays down the debt accumulated across slices 1–4 and
> the two CDC passes so arc 1 closes on a clean quality floor before arc 2
> (outbound) begins. Six independent items; each is separately verifiable, and
> two carry explicit disclose-defer latitude.

## Why a hardening slice

Three kinds of debt accumulated and will get *more* expensive if carried into
arc 2:

- **The coverage gate is eroding** (slice-1 F1 set 30; slice 3 lowered it to 20;
  it trends to 0 as each slice adds NIFs). Fixing the *strategy* now stops the
  decay before arc 2 adds the send/recv NIFs.
- **A growing deferred-Linux pile** (slice-1 row 3, slice-3 row 6, slice-1 row 16
  leak-half) — all "no Linux host" deferrals. A CI job closes them durably and
  keeps them closed.
- **Small disclosed items** (F2, F3) and **artifact hygiene** (NIF-LEARNINGS.md
  sits in gitignored `workbench/`; slice-4 tooling + CDC docs uncommitted).

## The six items

1. **NIF-aware coverage strategy.** Stop line-gating the NIF-binding module
   (`midiio` is ~all `?NOT_LOADED` stubs, structurally near-zero coverage that
   decays). Exclude it from the cover metric so the gate measures real-logic
   modules (none yet → dormant; meaningful when the arc-2/3 gen_server + helpers
   land). Keep cover *reporting* on. Document that the NIF surface is gated by
   **eunit + ASan**, not by `midiio.beam` line %. (Implements `NIF-LEARNINGS` L17;
   CDC slice-3 recommendation.)
2. **F2 — gate the test-only NIFs.** `result_atom/1` and `uninit_count/0` exist
   only for eunit; keep them out of the shipped default surface (test build only).
   *(S3; disclose-defer latitude — see cc-prompt.)*
3. **F3 — fix the dialyzer profile root cause.** Scope `{plt_extra_apps,[eunit,
   proper]}` to the test profile so a bare `rebar3 dialyzer` works (it currently
   fails "Could not find application: proper"). Plus commit the already-made
   `make asan` `-framework CoreFoundation` fix.
4. **Relocate `NIF-LEARNINGS.md`** out of gitignored `workbench/` into a tracked
   path so the guide-handoff artifact is version-controlled and shareable.
5. **Cross-platform CI** (ubuntu + macos matrix): run `rebar3 as test check` and
   the ASan harness. Closes the deferred-Linux rows (slice-1 row 3, slice-3
   row 6, slice-1 row 16 leak) on every push — the durable answer to the pile.
   *(Headless-ALSA caveat — see cc-prompt; disclose-defer latitude on the ALSA
   *runtime* if the runner can't provide a sequencer.)*
6. **Commit hygiene.** Commit slice-4 tooling, the CDC verification docs, the
   ARCS updates, and this slice.

## Acceptance

Every ledger row closed (or disclosed-deferred with a re-entry note); arc 1's
capability composes (the close-out check in the cc-prompt); `rebar3 as test
check` green with a coverage gate that no longer erodes. CDC verifies.
