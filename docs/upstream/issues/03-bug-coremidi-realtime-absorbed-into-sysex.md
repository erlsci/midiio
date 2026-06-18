# Bug: CoreMIDI swallows real-time bytes that arrive inside a SysEx (and corrupts the SysEx)

> **Paste-ready GitHub issue.** Title suggestion:
> *"CoreMIDI: system real-time bytes inside a SysEx get absorbed into the payload"*
>
> Labels you might want: `bug`, `macos`. Line references are against `main` at
> `bb705e8` — worth a quick re-check against current HEAD.

---

Hi Joseph 👋

Here's a CoreMIDI one that has two unfortunate effects at once. The MIDI spec
allows the single-byte system real-time messages — `F8` (clock), `FA` (start),
`FC` (stop), and friends — to appear *literally anywhere* in the stream,
including right in the middle of a SysEx. A receiver is supposed to act on that
real-time byte immediately and then carry on with the SysEx as if the byte
hadn't been there. On CoreMIDI today, a real-time byte that lands mid-SysEx gets
pulled *into* the SysEx instead.

## What's happening

The CoreMIDI read loop handles real-time bytes correctly when they're at the top
level — there's a nice `if (s >= 0xF8)` block for that (around
`minimidio.h:731`–`:743`). But once it sees an `F0` and starts scanning a SysEx,
the scan just runs forward until it hits `F7`, without checking for real-time
bytes along the way:

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

So if an `F8` clock byte shows up between the `F0` and the `F7`, two things go
wrong:

1. **The clock is lost** — it never gets delivered as a real-time message, so
   anything trying to stay in sync with incoming MIDI clock misses a tick.
2. **The SysEx is corrupted** — that `F8` is now sitting inside the payload bytes
   handed to the consumer, so the SysEx they receive isn't the one that was sent.

The second part is the nastier one — it's not just "a byte got dropped," it's
"the data got poisoned."

## How to see it

On CoreMIDI, send a SysEx with an `F8` injected partway through, e.g.
`F0 7E 00 … F8 … F7`. Then check two things:

- Did an `MM_CLOCK` get delivered? (Today: no.)
- Does the `MM_SYSEX` payload contain a stray `0xF8`? (Today: yes, it does.)

Neither of those is what you'd want.

## A possible fix

Inside the SysEx scan, watch for bytes `>= 0xF8`: when you hit one, deliver it
immediately as its own real-time message and skip it from the SysEx
accumulation, then keep scanning for the `F7`. That gives you both the clock tick
*and* a clean SysEx.

Nice bonus: this is exactly the inbound-framing behavior the raw-bytes API we
proposed separately would need anyway, so if you go that route, fixing this and
implementing raw SysEx framing on CoreMIDI are essentially the same change.

This matters most for anyone slaving to MIDI clock while also receiving SysEx,
but the corruption angle affects any SysEx that happens to share the stream with
real-time traffic. Glad to send a PR if it'd help!
