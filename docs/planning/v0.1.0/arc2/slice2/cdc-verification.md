# CDC verification — arc2/slice2 (`send/2` over the raw seam + dirty-I/O)

> Independent verification with evidence access (read the committed code/diffs and
> the eunit sources directly; re-ran the adapter logic in isolation; OTP/ALSA-
> coupled runs accepted on CC's macOS + Linux-VM + CI evidence where the sandbox
> can't reproduce them — no root, no OTP, no `libasound2-dev`). Commits reviewed:
> `46b6352` (implementation) + `da6ca42` (ledger evidence + closing report).
> **Verdict: PASS.** Slice 2 is **CDC-closed**; arc 2's capability is delivered.
> One S3 watch-item is raised with a disposition (below); it does not block close.

## Independently reproduced (not accepted on summary)

- **The adapter is correct — verified by execution, not just by reading.** I
  compiled the **real** `c_src/midiio_send.h` against a mocked minimidio backend
  (`cdc_seam_check.c`, run under `-fsanitize=address,undefined`) and asserted its
  output against a length/type table **re-derived from the MIDI spec, not from
  CC's code**. All pass, clean:
  - `midiio_expected_len` agrees on all 23 status bytes (3/2/3 for channel
    classes; 2/3/2/1 for `F1/F2/F3/F6`; 1 for the six real-time bytes; 0 for
    `F0` + every reserved byte) — **rows 3, 5**.
  - channel `0x95 60 100` → `MM_NOTE_ON`, channel 5, data `{60,100}` — **row 3**.
  - SysEx routes to `mm_out_send_sysex` with the **whole binary, same pointer,
    same length**, untouched — **row 4**.
  - `F2 10 20` → `MM_SONG_POSITION`, `song_position == 0x10 | (0x20<<7)` — **row 5**.
  - the nine system types map to their **unique enum constants** (not a nibble
    shift) — **row 5**.
  - `0xF4` → the `MIDIIO_UNSUPPORTED_STATUS` sentinel with **zero** `mm_out_send`
    / `mm_out_send_sysex` calls — **row 7**. This is the single most bug-prone
    line (the throwaway adapter) and it is provably right.

- **Seam structure (rows 1, 19)** — read `midiio_send.h`: one static-inline
  `midiio_dev_send_raw`; the adapter lives entirely in its body; `TODO(upstream)`
  marks the one-line swap. `send_nif` (`midiio_nif.c:518`) does only
  resource/binary/length/live checks + result mapping — **no** `mm_message` or
  `mm_out_send` anywhere in the wrapper. The seam is genuinely the sole adapter
  site.

- **Dirty-I/O (row 2)** — `nif_funcs[]` (`midiio_nif.c:586`):
  `{"send", 2, send_nif, ERL_NIF_DIRTY_JOB_IO_BOUND}`. The only dirty NIF.

- **Wrapper error/crash discipline (rows 6–9)** — read `send_nif`: empty /
  leading-data-byte / known-status-wrong-length → `enif_make_badarg` (crash,
  decided *before* the seam so it lands clean in Erlang-land); closed → `{error,
  not_open}` via the unlocked `live` gate; unframable → `{error,
  {unsupported_status, B}}` with the **pre-made** `am_unsupported_status`
  (`:223`) and `B` an **integer** (`enif_make_uint`); `MM_INVALID_ARG` →
  `invalid_arg`. Matches `DESIGN.md` §6 exactly.

- **eunit faithfulness (rows 3–9)** — read `test/midiio_tests.erl:219–279`. Each
  case targets exactly its row with specific assertions (`F4 →
  {unsupported_status,16#F4}`; 5000-byte payload → `invalid_arg`;
  `?assertError(badarg, …)` for the three malformed shapes). Not a rubber stamp —
  the tests assert the right things.

- **Erlang surface (row 11)** — `src/midiio.erl`: `send/2` in `-nifs` + `-export`,
  `?NOT_LOADED` stub, `-spec` = the slice-doc union, moduledoc updated off the
  "later arcs" line.

## Accepted on CC's evidence (sandbox cannot reproduce)

No OTP/rebar3, no `libasound2-dev`, no root in the verification sandbox — so the
following are accepted on CC's macOS + Linux-multipass-VM + CI evidence, same
posture as the arc1/slice5 CDC: **row 14** (real-hardware *audible* send —
explicitly deferred, sound: no instrument on the box, and the send-to-wire path
is exercised by the virtual sends + ASan), **row 15** (xref + dialyzer clean),
**rows 16–17** (eunit 26/26 on macOS *and* on Linux/ALSA via `make vm-test`;
`rebar3 as test check` exit 0), and the **Linux LeakSanitizer** leg of **row 18**.
I independently exercised the row-18 adapter logic under ASan/UBSan; the
backend-coupled `mm_*` portion of the harness is accepted on the VM run.

## The disclosed seam-typing refinement — endorsed

CC typed the seam `mm_device *dev` rather than the slice-doc's `midiio_dev_res
*res`. **Endorsed — keep it.** The three reasons are sound, and reason (b) is one
I relied on directly: an `mm_device*` seam is callable from a harness (and from my
own `cdc_seam_check.c`) that has no `midiio_dev_res` type, whereas a
`midiio_dev_res*` seam would force the adapter to be duplicated for testing. It
also matches the shape native `mm_out_send_raw` will almost certainly have
(`mm_out_send` itself takes `mm_device*`), making the seam *more* re-pointable,
not less. Name and arity unchanged; the wrapper passes `&res->dev`. This is a
properly-disclosed expansion, not a silent deviation or a scope drop.

## Finding F1 (S3) — the send path's safety rests on an unenforced caller contract

**Observation.** `send_nif` reads `res->live` **without a lock** and then calls
into the device/context, while `close/1`'s `do_dev_cleanup` tears the device down
under `g_uninit_lock`. CC's row-13 rationale — *"the per-device process serializes
open/send/close"* — is correct **and load-bearing**: it is the *only* thing that
makes the unlocked read safe. `midiio` does not *enforce* single-owner. If two
processes share a device handle and one calls `send` (on a dirty scheduler) while
the other calls `close` (on a normal scheduler), the `send` can read `live==1`,
pass the gate, and then dereference an `mm_context`/`mm_device` that `close` is
concurrently `mm_context_uninit`-ing — a use-after-free, not a tagged error. The
resource *memory* is safe (it's reachable as an argument, so GC can't free it),
but the *backend handles inside it* are not.

**Why this is not a blocker.** This is the documented, accepted no-lock-on-the-
realtime-send-path decision (`DESIGN.md` §4 / §7: "the owning Erlang process *is*
minimidio's one thread for its device"). Under that contract the race cannot
occur. Slice 2 introduces no new defect; it is simply the first slice where `send`
makes the standing assumption *reachable in C*, so the verification record should
name it rather than leave it implicit.

**Disposition: ACCEPT under the single-owner contract; track forward.** Two
concrete watch-items for arc 3, where the threading model grows:
1. Arc 3 adds `set_owner/2` and a recv thread that (correctly, per the plan)
   reads `owner` **under a mutex**. That makes the asymmetry explicit — *owner* is
   lock-protected across threads but *live* is not. When CC implements the arc-3
   resource-struct change, confirm the chosen invariant is written down: either
   (a) document "one owner process per device; sharing a handle is undefined," or
   (b) bring the `live` read under the same per-resource lock as `owner`. Position:
   (a) is sufficient for v0.1.0 and cheaper; (b) only if midiio ever exposes
   shared handles.
2. If `midi`'s per-device `gen_server` ever issues `send` from a *different*
   process than the one that may `close` (e.g. a supervisor terminating the owner
   mid-send), that violates the contract — flag it at the `midi` integration
   boundary (R-items), not here.

## CDC observations (no action — design boundaries, recorded for the spec)

- **No data-byte range validation.** `<<0x90, 0x80, 0x80>>` (data bytes with the
  high bit set) is sent verbatim. This is **correct** per the codec-free /
  no-normalization contract (R6; midilib owns wire-correctness) — the wrapper's
  let-it-crash applies to *framing* it can detect from the status byte, not to
  data-byte validity. Recorded so it's a documented boundary, not an oversight.
- **SysEx terminator not checked.** The wrapper requires `size >= 2` but does not
  assert a trailing `0xF7`; the bytes go out exactly as given. Same rationale —
  byte-exact transport, caller owns well-formedness.

## Close

All S1 rows independently confirmed or accepted-on-evidence with rationale; no S2
open without a written disposition; one S3 (F1) accepted-and-tracked. The
disclosed seam-typing refinement is endorsed. **Slice 2 is CDC-closed.**

**Arc-2 close-out gate:** arc 2's capability — open → send → close, byte-exact, no
handle leak on owner crash — is delivered across slices 1–2. Arc 2 can run its
specified-vs-delivered close-out **once arc2/slice1 also has CDC sign-off** (its
`cdc-verification.md` is still outstanding — the one remaining item before the
arc-2 diff). Carry F1 into the arc-3 plan's crux #2 (owner/mutex) as a named
input.
