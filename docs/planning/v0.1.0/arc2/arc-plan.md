# Arc 2 — Outbound transport (plan-of-record)

> SDLC step 4 for arc 2. Capability: open an output device, `send(Dev, <<bytes>>)`
> a complete MIDI message, have it emitted byte-exact; a crashing owner leaks no
> OS handle. This is **the first thing `midi` can integrate against**, so it's the
> priority after the arc-1 foundation. Design refs: `DESIGN.md` §1 (surface), §2
> (resources / D2), §4 (outbound threading / D3), §6 (errors).

## The crux: the device/context model (concretizing D2) ⚑

DESIGN §2 (D2) decided **one `mm_context` per device**, driven by Finding C: ALSA's
`snd_seq_drain_output` operates on the *context-level* `seq` handle, which
`snd_seq` does not make safe for concurrent multi-thread use — so two
device-processes sending through devices that **share** a context would race on
that handle. Arc 2 is where D2 becomes concrete. Verified against the source
(`mm_out_open` sets `dev->ctx=ctx` and builds the port on `ctx`'s client/seq;
`mm_out_close` disposes only the port):

**Decision (⚑ — confirm before CC builds):** the **device resource embeds its own
`mm_context`**:

```c
typedef struct { mm_context ctx; mm_device dev; int live; } midiio_dev_res;
/* open:    mm_context_init(&r->ctx, name);  mm_out_open(&r->ctx, &r->dev, idx)
   destroy: if (open) mm_out_close(&r->dev);  if (live) mm_context_uninit(&r->ctx) */
```

Each device is fully isolated — its own `MIDIClient` / `snd_seq` handle — so the
per-device gen_server model satisfies minimidio's "one thread only" contract with
**zero shared mutable state and no lock on the realtime send path.** This *refines*
DESIGN §2's "device keeps the context alive via `enif_keep_resource`": because the
context is **embedded** (not a separate Erlang resource), there is no
cross-resource keep/release dance — simpler and tighter. The index is a global
ordinal (`MIDIGetDestination(idx)` / ALSA system-port enumeration), valid against
the fresh context.

- **Cost (disclosed):** each open device is a separate system MIDI client (visible
  in `aconnect -l` / Audio MIDI Setup). Mitigation: name each per-device context
  distinctly (e.g. `midiio-out:<index>` or the destination name) so the clients
  are legible, not 16 identical "midiio".
- **Alternative considered & rejected:** open all devices on one shared user
  context → one system client, but concurrent sends race on `ctx->al.seq` (ALSA),
  forcing a context-level mutex on the realtime send path (lock contention,
  shared mutable state). CoreMIDI's `MIDISend` is thread-safe so it'd tolerate
  sharing, but per-device context is the *uniform* safe choice that doesn't
  special-case backends. Rejected unless the system-client count proves a real
  problem in practice (revisit signal: users opening dozens of devices).

The user-facing `context_open/0` context stays as the **enumeration/registry**
context (slice 3 uses it for `list_*`/`caps`); device contexts are internal and
embedded. → `open_output` therefore takes a **bare index** (`open_output(Index)`),
not `(Ctx, Index)` — the device owns its context, and the index is global. *(This
refines DESIGN §1's `open_output(Ctx, Index)`; flag if you'd rather keep the Ctx
param for grouping/forward-compat.)*

## Slice breakdown

**Slice 1 — output device resource + lifecycle.** The `midiio_device` resource
type (opened in `init_statics`, `RT_CREATE`/`RT_TAKEOVER` per the F1 pattern);
`open_output(Index) -> {ok, Dev}`; `close(Dev) -> ok | {error, not_open}`; the
embedded per-device context; a `live`-flag-guarded destructor (`mm_out_close` then
`mm_context_uninit`); error mapping (`out_of_range`, etc.); per-device context
naming. **No send yet.** This slice lands the per-device-context model and the
crashing-owner-leaks-nothing guarantee.

**Slice 2 — `send(Dev, <<bytes>>)` over the raw seam + dirty-I/O.** Define the
internal **raw seam** (`midiio_dev_send_raw(dev, bytes, len)`); implement the
**interim adapter** (parse the leading byte → route SysEx to `mm_out_send_sysex`
vs. fill an `mm_message` for `mm_out_send`); mark the send NIF
`ERL_NIF_DIRTY_JOB_IO_BOUND` (D3 — ALSA `drain_output` can block); error mapping
(`not_open`, `{unsupported_status, B}`, let-malformed-crash). The seam is the swap
point for native `mm_out_send_raw` when upstream ships it.

> **Slice-2 upstream gate:** if the maintainer has shipped `mm_*_raw` by then, the
> seam targets it directly (near-zero MIDI knowledge in C); if not, the interim
> adapter lives behind the seam as designed. **Either way slice 1 is unaffected**
> — it's pure lifecycle, no send.

## What's deliberately out of arc 2

Inbound (recv / `enif_send` / owner pid) → arc 3. Virtual ports, UMP, batch send
→ deferred. The byte-level virtual-loopback conformance test → arc 3 (it needs the
inbound path to assert receipt); slice-2's send is verified by error/shape tests +
a real-hardware send on macOS until then.

## Close-out

Arc 2 closes when a `midi`-shaped caller can `open_output` → `send` bytes →
`close`, byte-exact, with no handle leak on owner crash — and the
specified-vs-delivered diff shows no silent drops.
