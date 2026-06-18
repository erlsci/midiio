# Question / possible issue: does CoreMIDI handle a SysEx split across multiple packets?

> **DRAFT — your call whether to file this yet.** Unlike the other four, this one
> is **not confirmed** — we haven't reproduced it, it's reasoning from the source.
> We've written it as a *question* rather than a bug report on purpose. Two
> reasonable options: (a) file it as-is, as a friendly "have you run into this?",
> or (b) hold it until we (or you) actually reproduce it, then file a proper bug.
> We'd lean toward (b) unless you'd rather give Joseph the heads-up early.
>
> Title suggestion (if filed):
> *"Question: how does the CoreMIDI reader handle an inbound SysEx that spans multiple MIDIPackets?"*
>
> Line references are against `main` at `bb705e8`.

---

Hi Joseph 👋

This is a question more than a bug report — we noticed something while reading
the CoreMIDI input path and we genuinely don't know whether it bites in practice,
so we wanted to ask rather than assert.

## What we're wondering about

The CoreMIDI read loop scans for the closing `F7` of a SysEx only within the
current packet's length (around `minimidio.h:748`):

```c
while (j < pkt->length && pkt->data[j] != 0xF7) j++;
```

That's perfectly fine if CoreMIDI always hands you a complete SysEx inside a
single `MIDIPacket`. But *if* CoreMIDI ever delivers a long inbound SysEx split
across two or more packets, we think the current code might mishandle it:

- The first packet ends before any `F7` shows up, so it'd get emitted as an
  `MM_SYSEX` that's missing its terminator and cut short.
- The continuation packet would start with a data byte (`< 0x80`), which doesn't
  match any of the status-byte branches, so it'd fall through to the very last
  line of the loop — `j++; /* running status byte / unknown — skip */` (around
  `minimidio.h:797`) — and get discarded byte by byte.

So the worry is: a big incoming SysEx could come out truncated, with the tail
silently dropped.

## Why we *suspect* it but can't confirm it

The reason we think this is worth a look: your **ALSA** backend already handles
the multi-chunk case deliberately. It accumulates SysEx data into
`da->sysex_buf` / `da->sysex_pos` across events and only emits once it sees the
trailing `F7` (around `minimidio.h:1492`–`:1510`). The CoreMIDI path doesn't have
an equivalent "remember the SysEx in progress across packets" mechanism — so the
two backends would behave differently if CoreMIDI does fragment long SysEx.

But here's the honest part: **whether CoreMIDI actually splits inbound SysEx
across packets depends on its runtime behavior, which we haven't tested.** The
`MIDIPacket.data` declared size is nominal, and CoreMIDI can deliver longer
packets and may well coalesce a SysEx into one packet in practice. So we can't
say "this is broken" — only "this looks like it *would* break *if* CoreMIDI
fragments, and we're not sure it does."

## How someone could settle it

Feed a SysEx larger than ~256 bytes into a CoreMIDI input under conditions that
force it across multiple `MIDIPacket`s, and check whether you get one complete
`MM_SYSEX` with an intact `F0 … F7`. If it comes through whole, great — there's
nothing here. If it comes through truncated with a dropped tail, then it's a real
bug and the fix would be to carry SysEx-in-progress state across packets, the
same way ALSA already does.

If you happen to already know off the top of your head whether CoreMIDI coalesces
inbound SysEx, that'd answer the whole question — you've got far more time in this
code than we do. Either way, no claim here, just a heads-up and a question. 🙂
