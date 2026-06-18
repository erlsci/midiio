# Feature request: an additive raw-bytes I/O door (`mm_*_raw`)

> **Paste-ready GitHub issue.** Title suggestion:
> *"Feature: additive raw-bytes I/O (`mm_in_open_raw` / `mm_out_send_raw`) for byte-transparent transport"*
>
> Labels you might want: `enhancement`. Line references are against `main` at
> `bb705e8` — worth a quick double-check against current HEAD when you read it.

---

Hi Joseph 👋

First off, thanks for minimidio — a single-header, cross-platform MIDI library
that stays out of your way is exactly the thing we were hoping existed, and it
mostly does. We're building on top of it and wanted to open this up because you
mentioned you were open to a "no-opinion" raw mode ("I like the no-opinion
option"), and we'd love to help make that concrete.

This is a feature request *plus* an offer to do the work — we're happy to send
the PR. I'll explain who we are, why raw bytes matter for us, what we'd propose
adding, and (importantly) why it's a small, additive change that fits a pattern
already in your codebase.

## Who's asking, and why

We're building a small family of MIDI libraries in Erlang. The relevant piece is
`midiio`, an Erlang binding that wraps minimidio so the Erlang VM can talk MIDI.
The design choice we've made is that **all the *meaning* of MIDI — parsing
status bytes, running status, note on/off normalization, assembling SysEx —
lives in our own layer, not in the transport.** We want one place that owns those
rules, so they're consistent everywhere.

That means the ideal shape for us is for minimidio to be a **byte pipe**: when
bytes arrive on the wire, hand us those exact bytes; when we want to send bytes,
send exactly those bytes. We'll do all the interpreting ourselves.

Right now minimidio's public API is built around the `mm_message` struct, which
is a really nice convenience layer — it decodes incoming bytes into a typed
message, and re-encodes a typed message back to bytes on the way out. For an app
that wants that convenience, it's great, and we're not asking you to change it.
But for us it means a round trip we'd rather skip: bytes → `mm_message` → bytes
on the way in, and the reverse on the way out. And in a couple of spots that
decode loses information we can't get back (more on that in the linked bug
issues). So we'd love a way to bypass the decode and just deal in bytes.

## What we'd propose adding

Just three functions, one callback type, and one capability bit. Everything
existing stays exactly as it is — this is a parallel door, not a remodel:

```c
/* Raw inbound: hand us the exact wire bytes for one complete message. */
typedef void (*mm_raw_callback)(mm_device* dev,
                                const uint8_t* data, size_t len,
                                double timestamp, void* userdata);

/* Open a real input device in raw mode. */
mm_result mm_in_open_raw(mm_context* ctx, mm_device* dev, uint32_t idx,
                         mm_raw_callback cb, void* userdata);

/* Open a virtual input (destination) in raw mode. */
mm_result mm_in_open_virtual_raw(mm_context* ctx, mm_device* dev,
                                 mm_raw_callback cb, void* userdata);

/* Raw outbound: send an arbitrary byte buffer, byte-for-byte, no length cap. */
mm_result mm_out_send_raw(mm_device* dev, const uint8_t* data, size_t len);

/* Capability bit so callers can check for raw support at runtime. */
#define MM_CAP_RAW (1u << 5)
```

A couple of small notes on the shape:

- **`MM_CAP_RAW = 1u << 5` is just the next free bit.** Your capability enum
  (around `minimidio.h:334`) currently goes up to `MM_CAP_VIRTUAL_OUT = 1u << 4`,
  so `1u << 5` is open. If you add other capabilities before this lands, just
  grab whatever's next.
- **The callback carries `timestamp` as a parameter** rather than inside a
  struct, simply because there's no `mm_message` in raw mode to hold it. Same
  value, same meaning as today — we just need it surfaced somehow.
- **Lifecycle doesn't change at all.** Raw inputs would open/start/stop/close
  with the same `mm_in_start` / `mm_in_stop` / `mm_in_close` you already have;
  the device just remembers it's in raw mode.

## Why this should be a small change for you

Here's the part we think makes this an easy "yes": **you've already built this
exact pattern once.** minimidio already has a parallel door for Universal MIDI
Packets — `mm_in_open_ump`, `mm_out_send_ump`, `mm_ump_callback`, and
`MM_CAP_UMP` all sit alongside the regular struct API. The raw-bytes door is the
same idea, one more time: a `_raw` sibling for each entry point, its own callback
type, its own capability bit. No new concept to introduce — just the same move
you made for UMP, applied to plain bytes.

And on three of your four backends, "raw" is mostly *less* work, not more,
because the wire is already bytes:

- **CoreMIDI, WinMM, WebMIDI** are byte-native — raw mode is basically
  "forward the bytes you already have" instead of decoding them into a struct
  first.
- **ALSA** is the one exception, since its sequencer hands you `snd_seq_event_t`
  events rather than bytes. There, minimidio would still own the event↔byte
  conversion (you can't avoid it on ALSA) — raw mode just changes the target
  from "struct" to "bytes." Totally fine, just worth being upfront that ALSA
  isn't free the way the others are.

## The semantics we'd be counting on

If it's helpful, here are the behaviors our layer would rely on. None of these
are surprising — they're just "be a faithful byte pipe":

1. **Byte-exact, no rewriting.** Whatever was on the wire is what crosses the
   callback — no folding note-on-velocity-0 into note-off, no reordering, no
   dropping status bytes.
2. **One complete message per inbound callback.** A channel/system message comes
   as its full bytes; a SysEx comes as the whole `F0 … F7` (reassembled if the
   backend split it across packets); and a real-time byte (`F8`–`FF`) that lands
   in the middle of something else comes as its own little one-byte callback and
   is kept *out* of the surrounding message.
3. **Timestamp keeps its current meaning** — we'll adapt to whatever it is on
   our side.
4. **Outbound is byte-exact and uncapped** — no per-message reformatting, and no
   size limit (large SysEx to a virtual port needs to work).
5. **Virtual ports behave like real ones**, including for large SysEx — that's
   the path our automated tests run on.

(If staging it is easier, the "real-time byte gets its own callback" part can be
a follow-up — the part we'd really need from day one is just that a real-time
byte must never get glued into a SysEx payload.)

## A nice side effect

A couple of the issues we filed separately (note-on velocity-0 being folded
inconsistently across backends, and CoreMIDI absorbing real-time bytes into
SysEx) basically *disappear* once raw mode exists, because there's nothing left
to fold or absorb when you're forwarding literal bytes. And the virtual-port
SysEx size limit we hit lives in the same CoreMIDI packet-list code that
`mm_out_send_raw` would touch. So if you ever tackle this, it sweeps up a few
other things along the way. We've cross-linked those issues so you can see how
they connect.

## We're happy to do the work

We've already got a working harness and an interim adapter on our side, so we're
not blocked — but we'd much rather land this natively in minimidio than carry an
adapter forever. If you're up for it, just let us know and we'll open a PR for
the raw functions (and, if you like, the related CoreMIDI fixes). No pressure on
shape or timing — it's your library and your taste; we're glad to follow your
lead on naming and details.

Thanks again, and for being open to the no-opinion door. 🎹
