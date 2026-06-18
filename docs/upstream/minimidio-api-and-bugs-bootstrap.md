# Session bootstrap — minimidio raw-bytes API recommendation + bug report

> **This is a conversation bootstrap.** Paste it whole into a fresh CDC-twin
> session. Its job is to give that twin everything it needs to produce the
> **maintainer-facing submission**: (a) a recommended additive *raw-bytes* API for
> minimidio, (b) the implementation guidance to land it, and (c) a consolidated
> list of the (potential) bugs we have found in minimidio so far. The twin does
> **not** need to read the rest of the repo to do this — the substantive content
> is inline below. References to other files are provenance, not prerequisites.
>
> **Audience of the eventual output:** the minimidio maintainer (a responsive,
> single-header MIT project; the author *welcomes corrections* and has **already
> said yes** to adding a raw API — his words: *"I like the no-opinion option"*).
> So the tone is collaborator-to-collaborator, not bug-bounty. Lead with the
> design he already agreed to; attach the bug list as "things we found while
> reading, file or not as you like."

---

## 0. Your mission, and how to work

You are the **CDC twin** on this task — the independent-verification peer. Load
**collaboration-framework** + **erlang-guidelines** for posture (peer frame,
write-to-the-floor, calibrated uncertainty, disclosed deferrals). Your three
deliverables, in priority order:

1. **The raw-API recommendation** (§3–§6 below, polished into a clean proposal the
   maintainer can act on — signatures, semantics, per-backend guidance).
2. **The bug list** (§7 — U1–U3 confirmed, S1 suspected, U4 doc), each with a
   repro sketch and a suggested fix, ready to become GitHub issues or a single
   "findings" note.
3. **A short cover note** tying them together: the raw API *also resolves* two of
   the bugs by construction (U2 vel-0 folding, U3 real-time-in-SysEx), so the two
   submissions are coupled, not independent.

**The one hard caveat** (carry it into the output): every line number below is
against **our pinned vendored copy** — `c_src/minimidio.lock` →
`bb705e81f5c1ac3601b1b75bec45b86d2a15426c`, `v0.5.0-dev`. **Re-confirm every line
reference against upstream HEAD before filing.** The *findings* are structural and
will survive small drift; the *line numbers* will not. Say so explicitly in the
submission.

---

## 1. Context — who we are and why raw bytes

**minimidio** (github.com/octetta/minimidio) is a single-header C MIDI library
spanning CoreMIDI (macOS), WinMM (Windows), ALSA (Linux), and WebMIDI. It is the
**codec-free transport layer** of the *erlsci MIDI family* we are building:

```
minimidio (C, this project)
  └── midiio   (Erlang NIF over minimidio — the transport binding; *us*)
        └── midi (Erlang — semantic layer: codecs, normalization, scheduling)
              └── undermidi / underack / undertone (apps, sequencing, live-coding)
```

`midiio` is an Erlang NIF that wraps minimidio one-to-one and exposes MIDI
transport to the BEAM. All the *meaning* of MIDI (parsing status bytes, running
status, note semantics, SysEx assembly) lives one layer up in `midi`. That means
**`midiio` wants minimidio to be a byte pipe**: hand us the exact bytes that
arrived, send the exact bytes we give you, and stay out of the semantics.

Today minimidio's public surface is **struct-oriented**, not byte-oriented. Both
edges parse/format:

- **Inbound:** the per-backend read path decodes wire bytes into a typed
  `mm_message` (`type`, `data[]`, `sysex`/`sysex_size`) and hands *that* to the
  callback. The raw bytes are gone by the time the callback fires.
- **Outbound:** `mm_out_send(dev, &msg)` takes a typed `mm_message` and *formats*
  it back to bytes via a per-backend switch. The only raw-byte path that exists
  today is `mm_out_send_sysex` (SysEx only).

For a transport binding this is the wrong seam. It forces a **double
conversion** — bytes → `mm_message` (in minimidio) → bytes (in `midi`'s decoder)
on the way in, and the inverse on the way out — and worse, the struct
representation is **lossy and backend-inconsistent** (see U2/U3). We want to
delete the round-trip and own the codec ourselves, once, in `midi`.

This is not a complaint about the struct API — it's a fine convenience layer for
apps that want it. We are asking for an **additive raw mode alongside it**, which
is exactly the "no-opinion" option the maintainer already endorsed.

---

## 2. The need, stated precisely

`midiio` needs three byte-transparent entry points from minimidio:

1. **Raw inbound on a real device** — open input *idx*, and on each arriving MIDI
   message deliver the **exact wire bytes** to a callback (no decode, no folding,
   no swallowing of real-time bytes).
2. **Raw inbound on a virtual destination** — same, for a process-created virtual
   port (this is our CI/loopback path).
3. **Raw outbound** — send an **arbitrary byte buffer** to a device, byte-exact,
   with no per-message formatting and no length cap.

"Byte-transparent" is the whole point, so it's worth pinning what we mean:

- **No velocity-0 folding.** `90 3C 00` is delivered as `90 3C 00`, never silently
  rewritten to a note-off. (`midi` owns that normalization, once, consistently —
  it cannot *un*-fold what minimidio already folded. See U2.)
- **No real-time absorption.** A `F8` clock byte interleaved inside a SysEx is
  delivered as its own thing and is **not** glued into the SysEx payload. (See U3.)
- **No length cap** on outbound (and inbound SysEx reassembled whole). (See U1/S1.)
- **One complete message per inbound callback.** We need framing — give us a
  message at a time, not a raw stream we have to re-frame. (Details in §5.)

---

## 3. How `midiio` consumes it — the seam pattern

So the maintainer understands what's on the other side of the API (and why the
shape matters), here is exactly how `midiio` is built to consume it.

`midiio` deliberately does **not** call minimidio's raw functions directly from
its NIF code. It calls a thin internal **seam** — one outbound function and one
inbound header — and behind that seam today sits an **interim adapter** written
*against the current struct API*. The day minimidio ships the native raw
functions, we swap the adapter's body for a direct call and delete the adapter.
Nothing above the seam changes.

**Outbound seam** (`c_src/midiio_send.h`):

```c
/* The stable seam midiio's NIF calls. Returns 0 on success. */
int midiio_dev_send_raw(mm_device *dev, const uint8_t *bytes, size_t len);
```

- **Today** (interim adapter): this function inspects the status byte, and either
  calls `mm_out_send_sysex` (for `F0…F7`) or reconstructs an `mm_message` and
  calls `mm_out_send` — essentially the *inverse* of minimidio's outbound switch,
  re-implemented on our side. It carries a `MIDIIO_UNSUPPORTED_STATUS` sentinel
  for byte sequences the struct API can't express.
- **After** the raw API lands: the body becomes one line —
  `return mm_out_send_raw(dev, bytes, len);` — and the whole inverse-switch
  adapter is deleted.

**Inbound seam** (`c_src/midiio_recv.h`): a callback shim that minimidio invokes,
which packages the delivered bytes + timestamp and hands them across the NIF
boundary to the owning Erlang process (`enif_send`).

- **Today:** minimidio hands us an `mm_message`; our shim *re-serializes* it back
  to bytes (and is therefore subject to U2/U3 — it can only forward what minimidio
  already (mis)decoded).
- **After:** minimidio's `mm_raw_callback` hands us bytes directly; the shim
  forwards them verbatim. The re-serialization disappears, and U2/U3 stop mattering
  to us *by construction*.

**The takeaway for the maintainer:** the raw API is not a nice-to-have for us — it
is the seam our whole binding is shaped around. We have already built the adapter
so we are unblocked *today*; the native API lets us delete a layer of lossy
conversion on both edges, and makes the family's byte-fidelity guarantee real
rather than best-effort.

---

## 4. The proposed API (additive — nothing existing changes)

Minimal, additive, mirrors the existing struct functions one-to-one:

```c
/* Raw inbound: deliver exact wire bytes for one complete message. */
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

/* Capability bit so callers can detect raw support at runtime. */
#define MM_CAP_RAW (1u << 5)   /* next free bit; confirm against current caps */
```

Design notes for the submission:

- **Additive only.** The existing `mm_message`/`mm_out_send`/`mm_in_open` API is
  untouched. Raw mode is a parallel door. An implementation can even back the
  struct API onto the raw path internally later, but that's the maintainer's call,
  not a requirement.
- **Symmetry.** `mm_out_send_raw` is the outbound twin of the inbound
  `mm_raw_callback`. Same byte view both directions.
- **`MM_CAP_RAW`.** Lets `midiio` (and other callers) feature-detect rather than
  compile-time-assume, so a binding can fall back to its interim adapter on an
  older minimidio. Pick the actual next-free capability bit when implementing.
- **Lifecycle unchanged.** Raw inputs open/close/stop exactly like struct inputs
  (`mm_in_close`, `mm_in_stop`); `dev` carries the mode. No new teardown surface.

---

## 5. Semantics — the five rules the implementation must honor

These are the contract. Each is chosen so `midi` can own MIDI semantics cleanly.

1. **Byte-exact, no folding, on every backend.** Deliver/transmit the literal
   bytes. Specifically **never** fold note-on-velocity-0 to note-off (the U2 bug),
   and never normalize, reorder, or drop status bytes. What went on the wire is
   what crosses the callback.

2. **One complete message per inbound callback (framing).** The callback fires
   once per logical MIDI message:
   - a channel/system message = its full status+data bytes;
   - a SysEx = the **whole** `F0 … F7`, reassembled across packets if the backend
     fragments it (the S1 risk), delivered in one callback;
   - **interleaved system-real-time bytes** (`F8`–`FF`) that arrive *inside*
     another message are delivered as **their own** single-byte callback,
     immediately, and are **excluded** from the surrounding message's bytes (the
     U3 fix). (Phasing note: shipping real-time-as-its-own-callback can be a
     follow-up if it's easier; the *must-not-corrupt-the-SysEx* half is the
     non-negotiable part.)

3. **Timestamp unchanged.** Keep the existing `double timestamp` with its current
   meaning and units — we adapt on our side. (But please fix the *doc* — see U4;
   the struct comment misdescribes what the value is.)

4. **Outbound = one complete message, byte-exact, uncapped.** `mm_out_send_raw`
   transmits the buffer as given. No per-message struct formatting, and critically
   **no length cap** — large SysEx to a **virtual** source must work (the U1 fix
   lives here, or shares code with it).

5. **Virtual ports are first-class.** `mm_in_open_virtual_raw` and raw sends to a
   virtual source must behave identically to real devices, including large SysEx.
   This is the path our CI loopback runs on, so any virtual-only cap (U1) blocks
   our conformance tests even when real hardware is fine.

---

## 6. Per-backend reality — where the work actually is

The four backends are not symmetric, and the submission should acknowledge that so
the maintainer isn't surprised:

- **CoreMIDI (macOS) — byte-native.** The wire is already bytes; the read proc
  *chooses* to decode into `mm_message`. Raw mode is mostly *skipping* that
  decode: deliver `pkt->data` slices directly. This is also where U1 (virtual
  SysEx cap), U3 (real-time-in-SysEx), and S1 (multi-packet SysEx) all live, so
  the raw path and the bug fixes overlap heavily here.
- **WinMM (Windows) — byte-native.** Short messages arrive as packed bytes;
  long/SysEx via `MIM_LONGDATA` buffers. Raw delivery is again "forward the bytes
  you already have." Pass-through is natural.
- **ALSA (Linux) — event-native.** This is the hard one. ALSA's sequencer
  delivers **`snd_seq_event_t`**, not bytes. minimidio already converts
  event→`mm_message`; for raw mode it must convert event→**bytes**
  (`snd_midi_event_decode` / the existing encoder in reverse). So on ALSA the
  byte⇄event conversion *stays inside minimidio* — raw mode can't make it
  byte-native, it just changes the target representation from struct to bytes.
  Worth stating plainly: "raw" on ALSA means "minimidio still owns the
  event/byte codec, but hands you bytes." U2's vel-0 fold (`:1406`) is on this
  path — raw mode must take the *unfolded* branch.
- **WebMIDI — byte-native.** The Web MIDI API is already `Uint8Array` +
  `receiveMessage`; raw mode forwards those bytes.

**Implementation hint for the maintainer:** because three of four backends are
already byte-native, the cleanest internal shape may be a byte-level core with the
struct API layered *on top of* it (decode for convenience), and ALSA's
event/byte codec as the one place real conversion happens. But that's a larger
refactor than he agreed to — the additive functions above are the ask; the
internal factoring is his to choose.

---

## 7. The bug list — (potential) issues found while reading minimidio

> Provenance: these were found while planning `midiio` (transport) and `midi`
> (semantics). None block `midiio`'s *design* — we test around them and disclose
> them as `midi` limitations — but they inform our conformance tests and several
> are worth filing. **Status key:** *Confirmed* = read in source; *Confirmed (CDC)*
> = independently re-verified; *Suspected* = analysis only, needs a repro before
> filing. **Re-confirm all line numbers against upstream HEAD.**
>
> **Coupling to the API (put this up front in the submission):** the raw API in
> §4–§6 *resolves U2 and U3 by construction* — once minimidio delivers exact
> bytes and frames real-time separately, there is nothing to fold and nothing to
> absorb. U1 is an outbound-virtual fix that the `mm_out_send_raw` work should
> sweep up. So "add the raw API" and "fix these bugs" are substantially the same
> body of work, especially on CoreMIDI.

### U1 — CoreMIDI virtual-source SysEx is capped at ~256 bytes
**Severity: Medium (Low for real devices; High for our test path). Backend: CoreMIDI. Status: Confirmed.**

`mm_out_send_sysex` has two branches (`minimidio.h:937–956`):

- **Real device** (`:949–955`): sends via `MIDISendSysex(&dev->cm.sysex_req)` with
  `bytesToSend = size` — Apple's arbitrary-length path; chunks internally.
  **Not buggy.**
- **Virtual source** (`:941–947`): builds a **stack** `MIDIPacketList pl;` and
  calls `MIDIPacketListAdd(&pl, sizeof(pl), …, size, …)`. `sizeof(pl)` is the
  inline single-`MIDIPacket` size (`data[256]`), so `MIDIPacketListAdd` refuses
  any `size` > ~256 and returns `NULL` → the function returns `MM_ERROR`.

So a virtual MIDI source cannot emit a SysEx larger than ~256 bytes; it fails
cleanly with `MM_ERROR` (no crash, no truncation). (Note: the staging `sysex_buf`
is 4096 and the `MIDISendSysex` path is fine — the cap is specific to the
*virtual* branch's stack `MIDIPacketList`.)

**Suggested fix.** In the virtual branch, send large SysEx the same way as the
real path, or build the packet list in a heap buffer sized to `size` (Apple's
`MIDIReceived` accepts a packet list you've allocated large enough). The fixed
stack struct is the only constraint. **This is the same work as `mm_out_send_raw`
on a virtual source** — do them together.

**Repro sketch.** Open a virtual source + a virtual destination in one process;
`mm_out_send_sysex` a 300-byte `F0 … F7`; assert receipt. Expect `MM_ERROR`
(bug) vs full receipt (fixed).

**Family impact.** Real-hardware SysEx is unaffected, but `midiio`'s loopback
conformance test runs over **virtual** ports — so large-SysEx round-trips can't be
validated in CI until this is fixed.

### U2 — Note-on velocity 0 is folded to NOTE_OFF on some backends, not others
**Severity: Medium. Backends: ALSA + UMP fold; CoreMIDI passes through (WinMM/WebMIDI per assessment). Status: Confirmed (CoreMIDI, ALSA, UMP).**

The same physical "note-on, velocity 0" yields a different `mm_message.type` by
platform:

- **ALSA inbound** folds: `msg.type = (ev->data.note.velocity > 0) ? MM_NOTE_ON :
  MM_NOTE_OFF;` (`minimidio.h:1406`).
- **UMP → MIDI-1 conversion** folds: `if (msg->type == MM_NOTE_ON && msg->data[1]
  == 0) msg->type = MM_NOTE_OFF;` (`minimidio.h:665`).
- **CoreMIDI inbound** does **not** fold — keeps `msg.type = (s >> 4) & 0x0F`, so
  `0x9n` with velocity 0 stays `MM_NOTE_ON` (`minimidio.h:784–795`).
- **WinMM / WebMIDI:** pass-through per prior assessment; not re-verified
  line-by-line.

For a library that bills itself as low-level transport this is an
**inconsistency** rather than an outright bug — but it's hard to defend across
backends, and folding is lossy: once `0x90 nn 00` becomes `MM_NOTE_OFF` you can't
recover that it was sent as a note-on.

**Suggested fix (fidelity-preserving).** Do **not** fold in any backend — report
as received, let the consumer decide. (If folding-as-convenience is preferred, do
it *consistently* across all backends and document it — but pass-through is the
honest default for a transport.) **Raw mode resolves this for us outright.**

**Repro sketch.** Feed `90 3C 00` to each backend's input; assert `msg.type` is
identical across all four. Today CoreMIDI reports `MM_NOTE_ON` while ALSA/UMP
report `MM_NOTE_OFF`.

**Family impact.** `midi` will normalize vel-0 note-on ⇒ note_off as its single
canonical rule — but it can only do this for *unfolded* backends; it cannot
un-fold ALSA/UMP. Pass-through upstream lets `midi` own the one normalization
point cleanly.

### U3 — CoreMIDI absorbs real-time bytes interleaved inside a SysEx
**Severity: Medium (High for MIDI-clock slaving). Backend: CoreMIDI. Status: Confirmed (CDC) + Confirmed in source.**

System real-time bytes (`0xF8` clock, `0xFA` start, …) are single-byte and the
spec permits them *anywhere*, including mid-SysEx; the receiver should act on them
immediately and continue the SysEx as if the byte weren't there.

The CoreMIDI read proc handles *top-level* real-time correctly
(`minimidio.h:731–743`), but the SysEx scan just runs forward to `0xF7`:

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

So a real-time byte arriving mid-SysEx is **absorbed into the SysEx payload**
(`:748–751`): lost as a real-time event *and* it corrupts the SysEx body
delivered to the consumer. (Worse than "swallowed" — it poisons the data.)

**Suggested fix.** Inside the SysEx scan, intercept bytes `>= 0xF8`: deliver each
as its own real-time `mm_message` immediately and skip it from the SysEx
accumulation. **This is exactly semantic rule #2 of the raw API** — fixing it and
implementing raw inbound framing on CoreMIDI are the same change.

**Repro sketch.** On CoreMIDI, send a SysEx with an `F8` injected mid-stream
(`F0 7E … F8 … F7`); assert (a) an `MM_CLOCK` is delivered and (b) the `MM_SYSEX`
payload contains no `0xF8`. Today neither holds.

**Family impact.** Bytes are lost below `midiio`, so nothing upstream can recover
them. Disclosed `midi` limitation: MIDI-clock-slave sync is unreliable while
receiving SysEx on CoreMIDI, and inbound SysEx can be corrupted by interleaved
real-time traffic.

### S1 — (Suspected) CoreMIDI inbound SysEx spanning multiple packets may truncate
**Severity: Medium. Backend: CoreMIDI. Status: Suspected — needs a repro before filing.**

The read proc scans for `0xF7` only within the current `pkt->length`
(`minimidio.h:748`). If CoreMIDI delivers a long inbound SysEx split across
packets, the first packet would be emitted as `MM_SYSEX` *without* a terminating
`0xF7`, and the continuation packet — starting with a data byte `< 0x80` — would
fall through to the `j++ /* running status / unknown — skip */` path (`:797`) and
be discarded byte-by-byte.

**Unverified:** depends on CoreMIDI's actual packet-coalescing for inbound SysEx
(the `MIDIPacket.data` declared size is nominal; CoreMIDI can deliver longer
packets). **Do not report as confirmed** — needs a hardware-or-virtual repro with
a >256-byte inbound SysEx first.

**Suggested fix (if confirmed).** Carry SysEx-in-progress state across packets:
when a packet ends without `0xF7`, hold the partial buffer and resume on the next
packet rather than emitting/dropping. (Raw inbound framing, rule #2, needs this
same cross-packet reassembly — so confirming S1 is also a raw-API test.)

**Repro sketch.** Feed a >256-byte SysEx to a CoreMIDI input split across
`MIDIPacket`s; assert one complete `MM_SYSEX` with intact `F0…F7`. Today: expect
truncation + a dropped continuation.

### U4 — (Doc) `mm_message` timestamp comment misdescribes the value
**Severity: Low (documentation). All backends. Status: Confirmed.**

The `mm_message` timestamp field is documented as "seconds since the device was
opened," but the implementation populates it from a host-monotonic clock
(`mach_absolute_time` on macOS / `CLOCK_MONOTONIC`-class on Linux) — i.e. an
**arbitrary monotonic epoch (≈ since boot), not since-open**. A consumer that
trusts the comment and treats the value as a since-open offset will be wrong by
the machine's uptime.

**Suggested fix.** Correct the comment to describe it as a monotonic timestamp
with an unspecified epoch, only meaningful as a *difference* between two
timestamps (which is all anyone needs). No code change required. (`midiio` already
treats it as a host-monotonic value and adapts, so this is purely "save the next
reader the confusion.")

---

## 8. What to produce, and the maintainer relationship

**Output shape.** Produce a single clean markdown document the maintainer can read
top-to-bottom:

1. A two-paragraph **lead**: "you already agreed to a raw API — here's the concrete
   shape, and here's the consumer (`midiio`) that motivates it," plus the coupling
   note (the raw API resolves U2/U3, sweeps up U1).
2. The **API** (§4) + **semantics** (§5) + **per-backend guidance** (§6), polished.
3. The **findings** (§7) as a labeled list with repro sketches — framed as "things
   we found while reading; file or fix as you see fit," not as demands.
4. A closing offer: **we're happy to send a PR** for the raw functions and/or the
   CoreMIDI fixes if that's easier than specifying it back and forth (we already
   have the interim adapter and the repro harness).

**Tone / posture.** Collaborator-to-collaborator. The maintainer is responsive,
the project is one MIT header, and he *welcomes corrections*. Lead with the design
he blessed; keep the bug list humble and repro-backed; flag S1 explicitly as
*suspected, not confirmed* (don't overclaim). Calibrated uncertainty is the house
style — be as precise about what we *haven't* verified as about what we have.

**The hard caveat, restated.** All line numbers are against our pinned vendored
copy (`bb705e8…`, `v0.5.0-dev`). **Re-confirm against upstream HEAD before
filing.** The findings are structural; the line refs will drift.

---

## 9. Provenance (for your reference — not required reading)

The content above is consolidated from two working artifacts in the family repos
(both currently in gitignored `workbench/` dirs, hence this tracked consolidation):

- **`midiio/workbench/UPSTREAM-minimidio-raw-api.md`** — the raw-API proposal
  (signatures, the five semantic rules, per-backend reality). Source for §3–§6.
- **`midi/workbench/UPSTREAM-minimidio.md`** — the bug punch-list (U1–U3 + S1 with
  repro sketches and line refs). Source for §7. U4 (timestamp doc) was noted
  separately during the arc3 recv-path review.

The seam details in §3 are from `midiio`'s own source: `c_src/midiio_send.h`
(`midiio_dev_send_raw`, `MIDIIO_UNSUPPORTED_STATUS`) and `c_src/midiio_recv.h`
(the inbound shim). The arc3 architecture (D1 raw-bytes boundary behind a stable
seam, D2 per-device context) is in `docs/planning/v0.1.0/arc3/arc-plan.md`.
