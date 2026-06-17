# midiio v0.1.0 — Design

> SDLC step 3 (architectural commitments). Answers every midiio bootstrap §5
> open question with a **Decision / Why / Alternatives rejected**, and resolves
> the three forks D1–D3. Reasoning and source citations are in
> `workbench/RESEARCH-nif.md` (Findings A–C, line refs), the NIF concept cards,
> and `workbench/RESPONSE-to-midi-needs.md` (the midi R-items); this doc commits,
> it does not re-derive.
>
> Decisions are committed but **reviewable** — anything marked ⚑ is a genuine
> fork where I took a position; flag disagreement and it's a cheap change at this
> stage.

## 0. Resolved forks (context for everything below)

- **D1 — codec boundary: RESOLVED → raw bytes.** Both midi's decode path (R1 +
  "no structured terms") and the README's standalone promise require a bytes
  boundary. The maintainer is adding native `mm_in_open_raw` / `mm_out_send_raw`
  ("no opinion" mode). midiio targets a **stable internal raw seam** now,
  implemented over the current struct API by an isolated interim adapter, swapped
  for the native calls when they land — no change above the seam.
- **D2 — one mm_context per device. ⚑** See §2.
- **D3 — outbound dirty-scheduler strategy. ⚑** See §4.

## 1. NIF surface (§5.1)

**Decision.** MVP surface, all returning `{ok, _}` / `{error, atom()}` unless
noted:

```
midiio:context_open()            -> {ok, Ctx}    %% Ctx = opaque context resource
midiio:context_close(Ctx)        -> ok
midiio:caps(Ctx)                 -> #{...}        %% backend atom + capability flags
midiio:list_inputs(Ctx)          -> [{Index, Name}]
midiio:list_outputs(Ctx)         -> [{Index, Name}]
midiio:open_output(Ctx, Index)   -> {ok, Dev}    %% Dev = opaque device resource
midiio:open_input(Ctx, Index, OwnerPid) -> {ok, Dev}
midiio:start_input(Dev)          -> ok
midiio:stop_input(Dev)           -> ok
midiio:close(Dev)                -> ok
midiio:send(Dev, Bytes)          -> ok | {error, _}   %% one complete message
midiio:set_owner(Dev, Pid)       -> ok
```

Inbound arrives as messages, not returns: `{midi_in, Dev, <<Bytes>>, TsNanos}`.

**Why.** This is the minimum that lets midi drive per-device processes: open →
hold handle → send/receive bytes → close. `send/2` is uniform (no normal-vs-SysEx
split exposed; R4). Naming mirrors `mm_*` where it helps.

**Alternatives rejected.** Exposing `send_sysex` separately (R4 says routing is a
transport concern). Index-based send (R2 says identity is the handle). A combined
`open/3` with a direction flag (two functions read clearer and dialyze better).

**Deferred surface (tracked):** `open_virtual_input/output`, `open_input_ump`,
`send_batch/2`, WebMIDI. Listed in `PROJECT-DEFINITION.md`.

## 2. Resource objects & context ownership (§5.2) ⚑

**Decision.** Two resource types, opened in the NIF `load` callback:
`midiio_context` (wraps `mm_context`) and `midiio_device` (wraps `mm_device` +
the owner `ErlNifPid` + a mutex). **One `mm_context` per device** for I/O, plus
**one long-lived "registry" context** (singleton) used only for enumeration.
The device resource calls `enif_keep_resource` on its context at open and
`enif_release_resource` in its destructor. Destructors: device →
`mm_*_close`; context → `mm_context_uninit`.

**Why.** minimidio's `mm_device.ctx` is a raw back-pointer
(`RESEARCH-nif.md` §2), so the device must keep its context alive — `enif_keep_/
release_resource` is the exact mechanism (nif-resources card). **Per-device
context** is forced by Finding C: ALSA's `snd_seq_drain_output` operates on the
*context-level* `seq` handle shared by all devices on that context, and ALSA's
`snd_seq_t` is not safe for concurrent multi-thread use. With one context per
device, each device-process owns its own `seq` handle and minimidio's "one thread
only" contract is satisfied with zero shared mutable state — no locking on the
hot path. The enumeration wrinkle (ALSA enumeration needs a live `seq`; CoreMIDI
doesn't) is handled by the singleton registry context.

**Cost (disclosed).** Each open device is a separate ALSA client / CoreMIDI
`MIDIClient`, so it shows up separately in `aconnect -l` / Audio MIDI Setup. We
accept this; it's the honest price of the no-shared-state guarantee.

**Alternatives rejected.** One context per VM with all I/O serialized through a
single owner process: re-centralizes, fights the per-device model, and needs a
mutex around every send anyway. One context per VM with a mutex-guarded shared
`seq`: lock contention on the realtime send path; rejected unless per-device
contexts prove too heavy in practice (revisit signal: client-count limits).

## 3. Inbound threading & term shape (§5.3)

**Decision.** The recv callback (CoreMIDI read-proc thread / ALSA per-device
`pthread`) builds a term in a **process-independent environment**
(`enif_alloc_env` per delivery) and calls `enif_send(NULL, &owner, msg_env,
term)`, then `enif_free_env`. Term: `{midi_in, Dev, <<Bytes>>, TsNanos}` where
`Dev` is `enif_make_resource(msg_env, dev_res)`, `Bytes` is one complete
status-complete message, `TsNanos` is host-monotonic integer nanoseconds. The
owner `ErlNifPid` lives in the device resource, read under the resource mutex.

**Why.** `enif_send` from a non-ERTS thread requires `caller_env = NULL` and a
process-independent `msg_env` that is invalidated on success (nif-thread-safety
card). One message per delivery, status present (R1) — trivially satisfied since
minimidio is one-`mm_message`-per-callback. SysEx pointer is callback-lifetime
only, so we copy it into the binary during the callback (Finding A.3).

**Timestamp (R5).** Emit **integer nanoseconds, host-monotonic** (corrected
domain — the struct's "since open" comment is wrong; the value is mach /
`CLOCK_MONOTONIC` since boot, `RESPONSE-to-midi-needs.md` R5). Raw, not rebased,
so devices on a host share an origin (cross-device merge needs no per-device
correction) and the value may be directly comparable to midi's
`erlang:monotonic_time` send clock — to be verified, not yet promised. Zero/absent
(some CoreMIDI paths) passes through as `0` = "now".

**Alternatives rejected.** Structured fields in the term (R1, not codec-free).
Multicast delivery (R3). Float seconds (term-land drift; R5).

## 4. Outbound threading (§5.4) ⚑

**Decision.** `send/2` is a **dirty I/O NIF** (`ERL_NIF_DIRTY_JOB_IO_BOUND`).
For v0.1.0 it is *statically* dirty on all backends.

**Why.** ALSA's send ends in `snd_seq_drain_output`, which can block under
backpressure (Finding C / §7); a blocking syscall can't be chunked/yielded, so
dirty-I/O is the correct tool (dirty-nif-schedulers card: I/O-bound blocking is
the textbook case). The per-device process already serializes calls into one
device, so no concurrency concern. Static-dirty is the simplest correct choice
to ship.

**⚑ The known tradeoff (D3).** A static dirty flag taxes the *fast*
CoreMIDI/WinMM sends with dirty-scheduler dispatch latency too. For realtime MIDI
that latency may matter. The alternative — a regular NIF that conditionally
`enif_schedule_nif`s to dirty only on the backend that can block (ALSA) — is more
code and more moving parts. **Position:** ship static-dirty in v0.1.0, measure
dispatch latency against a realtime budget, and only add the conditional fast
path if measurement shows it's needed. Flag if you'd rather build the split now.

**Alternatives rejected.** sp_midi's queue-and-drain worker thread: more code,
and the dirty scheduler gives us the same non-blocking property for free
(`RESEARCH-nif.md` §7).

## 5. Device identity & refresh (§5.5)

**Decision.** Identity is the **opaque device resource handle** returned by
`open_*`, echoed as `Dev` in every `{midi_in, ...}` (R2). Index and name are
enumeration/display only and may shift on hotplug. Enumeration is a fresh query
each call (no cached index table). No "refresh" call in v0.1.0; re-enumerate to
get a current list, then open by current index.

**Why.** minimidio enumerates by shifting index; a stable handle is the only safe
identity (R2). Caching indices races hotplug; re-query is cheap.

**Alternatives rejected.** Name-as-identity (names duplicate and shift). A
hotplug-notification API (deferred; minimidio has no event for it).

## 6. Error mapping (§5.6)

**Decision.** One atom per `mm_result`, mechanically from `mm_result_string`:
`success` → `ok`; `error|invalid_arg|no_backend|out_of_range|already_open|
not_open|alloc_failed` → `{error, Atom}`. Outbound `send/2`: closed/wrong
direction → `{error, not_open}`; unrecognized status byte (can't determine
length) → `{error, {unsupported_status, B}}`; genuinely malformed input → **let
it crash** (the device process restarts under its supervisor). No normalization
of any kind (R6).

**Why.** The 8 result codes map 1:1 and cleanly (`RESEARCH-nif.md` §1).
Let-it-crash for malformed input keeps the NIF thin and pushes correctness to the
encoder upstream (midilib); predictable operational failures get tagged returns.

**Alternatives rejected.** Coarse `ok|error` (loses diagnosability). Defensive
swallowing of bad input (anti-pattern; hides encoder bugs).

## 7. Lifecycle & reentrancy (§5.7)

**Decision.** The owning Erlang process *is* minimidio's "one thread" for its
device. Owner set at `open_input`, re-settable via `set_owner/2` (mutex-guarded,
since the recv thread reads the pid). On owner death: baseline is GC of the
handle → destructor closes the device and releases the context. We may add
`enif_monitor_process` (resource `down` callback) for prompt cleanup if GC
latency proves too lax — noted, not in v0.1.0.

**Why.** Maps minimidio's per-device single-thread contract onto the per-device
process exactly. The mutex is required (nif-thread-safety: mutable resource state
read across threads). The "do not call stop/close from within the callback"
contract (`minimidio.h:353`) is satisfied — `enif_send` only posts.

**Alternatives rejected.** Monitor-based cleanup as the baseline (more
machinery than GC-of-handle needs for v0.1.0).

## 8. Build wiring (§5.8) ⚑

**Decision.** Vendor `minimidio.h` into `c_src/`. Compile a single NIF TU
(`c_src/midiio_nif.c`, with `#define MINIMIDIO_IMPLEMENTATION`) via the
**`pc` (port_compiler) rebar3 plugin**, with `port_specs` per-OS:
`-framework CoreMIDI` (Darwin), `-lasound -lpthread` (Linux). `rebar3 compile`
produces `priv/midiio_nif.so`; `-on_load` calls `erlang:load_nif` with
`code:priv_dir(midiio)` (nif-loading card). Erlang stubs call
`erlang:nif_error(nif_not_loaded)`.

**Why.** `pc` is the standard rebar3 path for NIFs and handles `port_specs`
per-OS cleanly; no cmake, no download (the sp_midi anti-pattern is gone — one
vendored header). ⚑ If you'd prefer a plain Makefile via rebar hooks (more
control, less magic), say so — `pc` is my default for the lower ceremony.

**Alternatives rejected.** cmake (unjustified for one header). Downloading
minimidio at build time (vendoring is the standing decision; keeps the source in
-tree and readable).

## 9. Testing (§5.9)

**Decision.** Three layers. (a) **eunit** for pure Erlang (arg validation, error
mapping, stub behavior). (b) **Virtual-port byte-level loopback** as the
conformance core: open a virtual source + virtual destination in one VM, send
each message type, assert the exact bytes arrive — **Erlang-drivable** so midi
can build its through-terms integration test on top (R8). (c) **PropEr** for the
bytes⇄message round-trip through the seam (no dropped status, correct data-byte
count, 14-bit values intact). CI runs (a)+(c) everywhere and (b) where a virtual
backend exists (macOS, Linux). The U1–U3 quirks get explicit cases: each is green
or a disclosed expected-fail with a tracked rationale.

**Why.** The bytes⇄message bridge is where a subtle corruption would silently
break every message (R8); property tests + loopback target exactly that.
Byte-level (not through-midilib) keeps midiio's conformance independent of
midilib's codec gaps (R7).

**Disclosed test limits.** Large-SysEx loopback can't pass on CoreMIDI until U1
(virtual-source cap) is fixed upstream — tracked as a skipped/expected-fail.
Inbound SysEx > one packet (S1) gets a case to flush the suspected truncation.
No-hardware CI cannot test real devices; the virtual loopback is the CI proxy.

## 10. Web / UMP scope (§5.10)

**Decision.** Both **deferred** from v0.1.0. Native CoreMIDI + ALSA first; WinMM
next; WebMIDI and raw UMP explicitly later. If a UMP timestamp is ever delivered,
it follows R5's domain rules.

**Why.** UMP is ALSA-only upstream today and WebMIDI needs the Emscripten
toolchain; neither is on the critical path for midi/undermidi v1. Named and
tracked, not dropped.

## Cross-cutting commitments (from midi's R-items)

- One complete message per inbound delivery, status present (R1).
- `Dev` handle is identity, echoed inbound (R2).
- Single owner pid, settable + re-settable (R3).
- `send/2` takes a binary, routes internally (R4).
- Integer-nanosecond host-monotonic timestamp, documented domain (R5).
- Zero normalization; expose backend atom + caps (R6).
- SysEx: transport-level byte tests now; through-terms round-trip gated on
  midilib (R7).
- Erlang-drivable virtual-loopback scaffolding (R8).
- **Open question handed back to midi:** outbound send granularity / batch
  (NEW-1) — affects whether `send_batch/2` is in a later arc.
