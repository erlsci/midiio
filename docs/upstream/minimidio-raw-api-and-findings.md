# minimidio — a raw‑bytes API, and a few findings from reading the source

*To: Joseph Stewart / octetta (minimidio maintainer)*
*From: the erlsci MIDI family (Duncan McGreggor et al.), building `midiio` on top of minimidio*

> **Provenance & verification.** Every line reference below is against
> minimidio `main` at commit **`bb705e81f5c1ac3601b1b75bec45b86d2a15426c`**
> (the "add badge" commit, 2026‑06‑09). At the time of writing this is also the
> live HEAD of `octetta/minimidio`, so the references should line up with what
> you see today — but commits move, so please re‑confirm against current HEAD
> before acting on any specific line number. The *findings* are structural and
> will survive small drift; the *line numbers* will not.
>
> This note was produced through a human‑directed, AI‑assisted workflow — the
> same shape your own `AUTHORSHIP.md` describes. Flagging that up front in the
> same spirit you do.

---

## 1. The short version

You already said yes to a "no‑opinion" raw API — *"I like the no‑opinion
option."* This note turns that into a concrete, additive shape you can act on:
three byte‑transparent entry points (`mm_in_open_raw`, `mm_in_open_virtual_raw`,
`mm_out_send_raw`) plus one callback typedef and one capability bit. Nothing in
the existing `mm_message` / `mm_out_send` / `mm_in_open` API changes.

The reason it matters to us, concretely: `midiio` is an Erlang NIF that exposes
minimidio's transport to the BEAM, and it deliberately owns *all* MIDI semantics
one layer up (in a sibling library, `midi`) — status‑byte parsing, running
status, note normalization, SysEx assembly. So `midiio` wants minimidio to be a
**byte pipe**: hand us the exact bytes that arrived, send the exact bytes we
give you, stay out of the meaning. Today's struct‑oriented surface forces a
double conversion (bytes → `mm_message` → bytes on the way in, and the inverse
on the way out), and the struct representation is lossy in a couple of places
(see U2/U3 below). A raw door lets us delete that round‑trip and own the codec
ourselves, once.

**One thing worth putting up front: the raw API and the bug list are largely
the same body of work.** Delivering exact bytes resolves U2 (velocity‑0 folding)
and U3 (real‑time bytes corrupting SysEx) *by construction* — there is nothing
to fold and nothing to absorb once you're forwarding literal bytes. And the
`mm_out_send_raw` work on CoreMIDI naturally sweeps up U1 (the virtual‑source
SysEx size cap), because they touch the same packet‑list code. So you can read
sections 2–3 as "the API" and section 4 as "bugs," but on CoreMIDI especially
they land in the same few functions.

**This mirrors a pattern you've already shipped.** minimidio already has a
*parallel‑door* convention: alongside the MIDI‑1.0 struct API sits the UMP door
— `mm_in_open_ump`, `mm_out_send_ump`, `mm_ump_callback`, `MM_CAP_UMP`
(`minimidio.h:566, 582, 355, 336`). The raw‑bytes API is simply the **third**
door, built the same way: a `_raw` sibling for each relevant entry point, its
own callback type, its own capability bit. No new architectural concept — the
same move you made for UMP, applied to bytes.

---

## 2. The proposed API (additive — nothing existing changes)

Minimal, and one‑to‑one with the struct functions it parallels:

```c
/* Raw inbound: deliver the exact wire bytes for one complete message. */
typedef void (*mm_raw_callback)(mm_device* dev,
                                const uint8_t* data, size_t len,
                                double timestamp, void* userdata);

/* Open a real input device in raw mode. */
mm_result mm_in_open_raw(mm_context* ctx, mm_device* dev, uint32_t idx,
                         mm_raw_callback cb, void* userdata);

/* Open a virtual input (destination) in raw mode. */
mm_result mm_in_open_virtual_raw(mm_context* ctx, mm_device* dev,
                                 mm_raw_callback cb, void* userdata);

/* Raw outbound: send an arbitrary byte buffer, byte-exact, no length cap. */
mm_result mm_out_send_raw(mm_device* dev, const uint8_t* data, size_t len);

/* Capability bit so callers can feature-detect raw support at runtime. */
#define MM_CAP_RAW (1u << 5)
```

Notes on the shape, with the relevant existing code for reference:

- **`MM_CAP_RAW = 1u << 5` is the next free bit.** The current capability enum
  (`minimidio.h:334–339`) runs `MM_CAP_MIDI1 (1u<<0)` … `MM_CAP_VIRTUAL_OUT
  (1u<<4)`; `1u<<5` is unused. (We confirmed this against HEAD; if you add other
  caps before this lands, just take the next free bit.)
- **The callback gains an explicit `timestamp` parameter.** Your existing
  `mm_callback` (`minimidio.h:354`) carries the timestamp *inside* `mm_message`.
  Raw mode has no struct to carry it, so it moves to a parameter. Same value,
  same meaning (see semantic rule 3) — just relocated. `mm_raw_callback` is
  otherwise the byte‑level twin of `mm_ump_callback` (`minimidio.h:355`).
- **Lifecycle is unchanged.** Raw inputs open/start/stop/close exactly like
  struct inputs (`mm_in_start` / `mm_in_stop` / `mm_in_close`); the `mm_device`
  carries the mode, the same way it already carries a `mm_callback` *and* a
  `mm_ump_callback` side by side (`minimidio.h:528–529`). No new teardown
  surface.
- **Additive only.** The struct API is a fine convenience layer and stays
  exactly as is. Raw mode is a parallel door, not a replacement. If you ever
  wanted to back the struct API onto a raw core internally, that's your call —
  it is explicitly *not* part of this ask.

---

## 3. Semantics — the five rules the implementation should honor

These are the contract that lets the consumer own MIDI meaning cleanly.

1. **Byte‑exact, no folding, on every backend.** Deliver/transmit the literal
   bytes. In particular, never fold note‑on‑velocity‑0 to note‑off (U2), and
   never normalize, reorder, or drop status bytes. What went on the wire is what
   crosses the callback.

2. **One complete message per inbound callback (framing).** The callback fires
   once per logical MIDI message:
   - a channel/system message → its full status + data bytes;
   - a SysEx → the **whole** `F0 … F7`, reassembled across packets if the
     backend fragments it (the S1 risk), delivered in one callback;
   - **interleaved system‑real‑time bytes** (`F8`–`FF`) that arrive *inside*
     another message → delivered as their **own** single‑byte callback,
     immediately, and excluded from the surrounding message's bytes (the U3
     fix).

   *Phasing note:* real‑time‑as‑its‑own‑callback can be a follow‑up if that's
   easier to stage. The non‑negotiable half is the *must‑not‑corrupt‑the‑SysEx*
   part — a clock byte must never end up inside a SysEx payload.

3. **Timestamp unchanged.** Keep the existing `double timestamp`, with its
   current meaning and units; we adapt on our side. (One small request that's
   independent of the raw work: please fix the *doc comment* — see U4. The value
   is a monotonic host timestamp, not "seconds since device opened.")

4. **Outbound = one complete message, byte‑exact, uncapped.** `mm_out_send_raw`
   transmits the buffer as given — no per‑message struct formatting, and
   critically **no length cap**. A large SysEx to a *virtual* source must work
   (this is where the U1 fix lives, or shares code with it).

5. **Virtual ports are first‑class.** `mm_in_open_virtual_raw` and raw sends to
   a virtual source must behave identically to real devices, including large
   SysEx. This is the path our CI loopback runs on, so any virtual‑only cap (U1)
   blocks conformance tests even when real hardware is fine.

---

## 4. Per‑backend reality — where the work actually is

The four backends are not symmetric, so the effort is lopsided:

- **CoreMIDI (macOS) — byte‑native.** The wire is already bytes; the read proc
  (`mm__cm_read_proc`, around `minimidio.h:718`) *chooses* to decode into
  `mm_message`. Raw inbound is mostly *skipping* that decode and delivering
  `pkt->data` slices directly. This is also where U1, U3, and S1 all live, so the
  raw path and the bug fixes overlap heavily here. Most of the real work is on
  this backend.
- **WinMM (Windows) — byte‑native.** Short messages arrive as packed bytes;
  long/SysEx via `MIM_LONGDATA` buffers. Raw delivery is "forward the bytes you
  already have." Pass‑through is natural.
- **ALSA (Linux) — event‑native.** The hard one. ALSA's sequencer delivers
  `snd_seq_event_t`, not bytes; minimidio already converts event → `mm_message`,
  and for raw mode it would convert event → **bytes** instead. So on ALSA the
  byte⇄event codec *stays inside minimidio* — "raw" here means "minimidio still
  owns the event/byte conversion, but hands you bytes." Worth stating plainly so
  it's not a surprise. (The U2 vel‑0 fold at `minimidio.h:1406` is on this path;
  raw mode takes the unfolded branch.)
- **WebMIDI — byte‑native.** The Web MIDI API is already `Uint8Array` +
  `receiveMessage`; raw mode forwards those bytes.

**An optional observation, not a request:** because three of four backends are
already byte‑native, the cleanest *internal* shape might eventually be a
byte‑level core with the struct API layered on top of it (decode for
convenience), and ALSA's event/byte codec as the one place real conversion
happens. But that's a larger refactor than you agreed to — the additive
functions in section 2 are the actual ask; the internal factoring is entirely
yours to choose.

---

## 5. Findings from reading the source

These turned up while we were planning `midiio` (transport) and `midi`
(semantics). None of them block our *design* — we test around them and disclose
them as `midi` limitations — but they shape our conformance tests, and a few
seem worth filing. Take them as "things we noticed while reading," to fix or
file as you see fit.

**Status key:** *Confirmed* = read in source and independently re‑verified
against `bb705e8`. *Suspected* = analysis only; needs a runtime repro before it
should be treated as real.

### U1 — CoreMIDI virtual‑source SysEx is capped at ~256 bytes
**Severity: Medium (Low for real devices; High for a virtual‑port test path). Backend: CoreMIDI. Status: Confirmed.**

`mm_out_send_sysex` (`minimidio.h:937`) admits any `size ≤ MM_SYSEX_BUF_SIZE`
(= 4096, guard at `:939`), then branches:

- **Virtual source** (`:941–948`): builds a **stack** `MIDIPacketList pl;` and
  calls `MIDIPacketListAdd(&pl, sizeof(pl), …, (ByteCount)size, …)` (`:944`).
  `sizeof(pl)` is the inline single‑`MIDIPacket` size (`data[256]`), so
  `MIDIPacketListAdd` refuses any `size` beyond ~256 bytes and returns `NULL`,
  so the `if (!p)` guard returns `MM_ERROR` (`:946`).
- **Real device** (`:949–955`): sends via `MIDISendSysex(&dev->cm.sysex_req)`
  with `bytesToSend = size` — Apple's arbitrary‑length path, which chunks
  internally. **Not affected.**

So a virtual MIDI source can't emit a SysEx between ~257 and 4096 bytes: it
fails cleanly with `MM_ERROR` (no crash, no truncation). Note the staging
`sysex_buf` is 4096 and the *real*‑device path is fine — the cap is specific to
the virtual branch's stack `MIDIPacketList`.

**Suggested fix.** In the virtual branch, build the packet list in a heap buffer
sized to `size` (Apple's `MIDIReceived` accepts a packet list you've allocated
large enough), or otherwise lift the single‑packet limit. **This is the same
work as `mm_out_send_raw` on a virtual source** — worth doing together.

**Repro sketch.** Open a virtual source + a virtual destination in one process;
`mm_out_send_sysex` a 300‑byte `F0 … F7`; assert receipt. Today: `MM_ERROR`;
fixed: full receipt.

*(Aside, not a bug: the struct `mm_out_send` path at `:929–930` uses the same
stack `MIDIPacketList` + `sizeof(pl)` idiom, but only ever carries ≤3‑byte
messages, so it's never near the cap. Flagging only so the fix to U1 isn't
mistaken for needing to touch that path too.)*

### U2 — Note‑on velocity 0 is folded to NOTE_OFF on some backends, not others
**Severity: Medium. Backends: ALSA and UMP fold; CoreMIDI passes through (WinMM/WebMIDI per prior assessment, not re‑verified line‑by‑line). Status: Confirmed at all three cited sites.**

The same physical "note‑on, velocity 0" yields a different `mm_message.type` by
platform:

- **ALSA inbound** folds: `msg.type = (ev->data.note.velocity > 0) ? MM_NOTE_ON
  : MM_NOTE_OFF;` (`minimidio.h:1406`).
- **UMP → MIDI‑1 conversion** folds: `if (msg->type == MM_NOTE_ON &&
  msg->data[1] == 0) msg->type = MM_NOTE_OFF;` (`minimidio.h:665`).
- **CoreMIDI inbound** does **not** fold — `msg.type = (mm_message_type)((s >>
  4) & 0x0F);` keeps `0x9n`‑with‑velocity‑0 as `MM_NOTE_ON` (`minimidio.h:786`).

For a library that bills itself as low‑level transport this is an
*inconsistency* more than an outright bug, but it's hard to defend across
backends, and folding is lossy: once `90 nn 00` becomes `MM_NOTE_OFF` a consumer
can't recover that it arrived as a note‑on.

**Suggested fix (fidelity‑preserving).** Don't fold in any backend — report as
received and let the consumer decide. (If folding‑as‑convenience is preferred,
do it *consistently* across all four backends and document it — but
pass‑through is the honest default for a transport.) The raw API resolves this
for us outright.

**Repro sketch.** Feed `90 3C 00` to each backend's input; assert `msg.type` is
identical across all four. Today CoreMIDI reports `MM_NOTE_ON` while ALSA/UMP
report `MM_NOTE_OFF`.

### U3 — CoreMIDI absorbs real‑time bytes interleaved inside a SysEx
**Severity: Medium (High if you're slaving to MIDI clock). Backend: CoreMIDI. Status: Confirmed.**

System real‑time bytes (`F8` clock, `FA` start, …) are single‑byte and the spec
permits them *anywhere*, including mid‑SysEx; a receiver should act on them
immediately and continue the SysEx as if the byte weren't there.

The CoreMIDI read proc handles *top‑level* real‑time correctly (`if (s >= 0xF8)`
… `minimidio.h:731–743`), but the SysEx scan just runs forward to `0xF7`:

```c
if (s == 0xF0) {
    size_t start = j;
    while (j < pkt->length && pkt->data[j] != 0xF7) j++;   /* :748 */
    if (j < pkt->length) j++;
    msg.type = MM_SYSEX; msg.sysex = &pkt->data[start];
    msg.sysex_size = j - start;                            /* :751 */
    dev->callback(dev, &msg, dev->userdata); continue;
}
```

A real‑time byte arriving mid‑SysEx is therefore **absorbed into the SysEx
payload** (`:748–751`): lost as a real‑time event *and* it corrupts the SysEx
body handed to the consumer. (Worse than "swallowed" — it poisons the data.)

**Suggested fix.** Inside the SysEx scan, intercept bytes `≥ 0xF8`: deliver each
as its own real‑time message immediately and skip it from the SysEx
accumulation. This is exactly semantic rule 2 of the raw API — fixing it and
implementing raw inbound framing on CoreMIDI are the same change.

**Repro sketch.** On CoreMIDI, send a SysEx with an `F8` injected mid‑stream
(`F0 7E … F8 … F7`); assert (a) an `MM_CLOCK` is delivered and (b) the
`MM_SYSEX` payload contains no `0xF8`. Today neither holds.

### S1 — *(Suspected)* CoreMIDI inbound SysEx spanning multiple packets may truncate
**Severity: Medium. Backend: CoreMIDI. Status: Suspected — needs a runtime repro before filing.**

The SysEx scan looks for `0xF7` only within the current `pkt->length`
(`minimidio.h:748`). If CoreMIDI ever delivers a long inbound SysEx split across
`MIDIPacket`s, the first packet would be emitted as `MM_SYSEX` *without* a
terminating `0xF7`, and the continuation packet — starting with a data byte
`< 0x80` — would fall through every status guard to the final `j++; /* running
status byte / unknown — skip */` (`minimidio.h:797`) and be discarded
byte‑by‑byte.

**Why this is more than idle speculation:** the **ALSA** backend explicitly
carries SysEx‑in‑progress state across chunks — it accumulates into
`da->sysex_buf` / `da->sysex_pos` and only emits once it sees a trailing `0xF7`
(`minimidio.h:1492–1510`). CoreMIDI has **no** equivalent cross‑packet
accumulator. That asymmetry is exactly the shape you'd expect if multi‑packet
inbound SysEx were mishandled on CoreMIDI.

**Why it's still only Suspected:** whether it actually fires depends on
CoreMIDI's runtime packet‑coalescing for inbound SysEx (the `MIDIPacket.data`
declared size is nominal; CoreMIDI can deliver longer packets, and may coalesce
in practice). We have **not** reproduced it on hardware or a virtual port, so
please don't treat it as confirmed — but it's worth a repro because raw inbound
framing (rule 2) needs the same cross‑packet reassembly regardless.

**Repro sketch.** Feed a >256‑byte SysEx to a CoreMIDI input split across
`MIDIPacket`s; assert one complete `MM_SYSEX` with intact `F0…F7`. Expected if
buggy: truncation plus a dropped continuation.

### U4 — *(Doc)* the `timestamp` comment misdescribes the value
**Severity: Low (documentation). All backends. Status: Confirmed.**

The timestamp fields are documented as "seconds since device opened," but the
implementation populates them from a host‑monotonic clock — an arbitrary
monotonic epoch (≈ since boot), not since‑open:

- on macOS via `mm__cm_ts` (`minimidio.h:712`), which converts a
  `MIDITimeStamp` host time through `mach_timebase_info`;
- on Linux via `clock_gettime(CLOCK_MONOTONIC, …)` (`minimidio.h:1400`).

The misleading comment appears at **two** sites, not one:

- `mm_message.timestamp` — *"seconds since device opened"* (`minimidio.h:320`);
- `mm_ump_packet.timestamp` — *"seconds since device opened, when available"*
  (`minimidio.h:345`).

A consumer who trusts either comment and treats the value as a since‑open offset
will be wrong by the machine's uptime.

**Suggested fix.** Correct both comments to describe a monotonic timestamp with
an unspecified epoch, meaningful only as a *difference* between two timestamps
(which is all anyone needs). No code change required. (`midiio` already treats it
as host‑monotonic and adapts — this is purely to save the next reader the
confusion.)

---

## 6. Offer

We're happy to send a PR rather than spec this back and forth — we already have
the interim adapter (`midiio` calls a thin internal seam today, backed by the
current struct API, that we'll collapse to a one‑line `mm_out_send_raw` call
once the native function lands) and a repro harness for the findings above. Say
the word and we'll open one for the raw functions, the CoreMIDI fixes, or both —
whatever's most useful to you. A draft PR description is appended below so you
can see the shape we'd propose.

Thanks for building minimidio, and for being open to the raw door — it's exactly
the seam our whole binding is shaped around.

---

## Appendix — draft PR description

*(Provided so you can see the shape we'd open. Easily split into separate PRs
— raw‑API vs. CoreMIDI fixes — if you'd rather stage them.)*

> ### Add an additive raw‑bytes I/O door (`mm_*_raw`) + CoreMIDI SysEx/real‑time fixes
>
> **What & why.** Adds a byte‑transparent parallel door alongside the existing
> struct and UMP APIs, for callers that want to own MIDI semantics themselves
> (e.g. language bindings). Mirrors the established `_ump` pattern: a `_raw`
> sibling per entry point, a `mm_raw_callback` typedef, and an `MM_CAP_RAW`
> capability bit. **No existing API changes.**
>
> **New public surface.**
> - `typedef void (*mm_raw_callback)(mm_device*, const uint8_t* data, size_t len, double timestamp, void* userdata);`
> - `mm_result mm_in_open_raw(mm_context*, mm_device*, uint32_t idx, mm_raw_callback, void* userdata);`
> - `mm_result mm_in_open_virtual_raw(mm_context*, mm_device*, mm_raw_callback, void* userdata);`
> - `mm_result mm_out_send_raw(mm_device*, const uint8_t* data, size_t len);`
> - `#define MM_CAP_RAW (1u << 5)` *(next free capability bit)*
>
> **Semantics.** Byte‑exact (no velocity‑0 folding, no status normalization);
> one complete message per inbound callback; SysEx reassembled whole across
> packets; interleaved system‑real‑time (`F8`–`FF`) delivered as its own
> single‑byte callback and excluded from any surrounding SysEx; outbound
> byte‑exact with no length cap; virtual ports first‑class. Timestamp keeps its
> current meaning, surfaced as a callback parameter.
>
> **Coupling to fixes.** This PR also resolves, on CoreMIDI:
> - **U1** — virtual‑source SysEx capped at ~256 bytes (stack `MIDIPacketList` /
>   `sizeof(pl)` in `mm_out_send_sysex`); fixed by sizing the packet list to the
>   payload. Same code path as raw virtual output.
> - **U3** — real‑time bytes interleaved in a SysEx absorbed into the payload;
>   fixed by intercepting `≥ 0xF8` inside the SysEx scan. Same code path as raw
>   inbound framing.
>
> And carries the **U2** (don't fold velocity‑0 in ALSA/UMP) and **U4**
> (timestamp doc‑comment) changes as small independent commits.
>
> **Backends.** CoreMIDI/WinMM/WebMIDI are byte‑native (forward existing bytes);
> ALSA converts `snd_seq_event_t` → bytes inside minimidio (the one place real
> conversion stays).
>
> **Not included.** No internal refactor of the struct API onto a raw core —
> kept strictly additive. **S1** (suspected multi‑packet inbound SysEx
> truncation on CoreMIDI) is *not* addressed here pending a confirmed repro;
> happy to follow up if it reproduces.
>
> **Testing.** Virtual‑port loopback harness: large‑SysEx round‑trip (U1),
> mid‑SysEx `F8` injection (U3), cross‑backend velocity‑0 type assertion (U2).
>
> **Provenance.** Human‑directed, AI‑assisted — consistent with the project's
> `AUTHORSHIP.md`.
