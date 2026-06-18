# Bug: CoreMIDI virtual source can't send SysEx larger than ~256 bytes

> **Paste-ready GitHub issue.** Title suggestion:
> *"CoreMIDI: `mm_out_send_sysex` fails for SysEx > ~256 bytes on a virtual source"*
>
> Labels you might want: `bug`, `macos`. Line references are against `main` at
> `bb705e8` — worth a quick re-check against current HEAD.

---

Hi Joseph 👋

Found this one while building automated tests over virtual MIDI ports, and
wanted to pass it along. Short version: on macOS/CoreMIDI, sending a SysEx
message bigger than ~256 bytes through a **virtual source** fails cleanly with
`MM_ERROR`. Sending the same SysEx to a **real device** works fine, and so does
anything under ~256 bytes — so it's easy to miss unless you happen to be on the
virtual-port path with a big payload.

## What's going on

`mm_out_send_sysex` (around `minimidio.h:937`) first accepts any payload up to
`MM_SYSEX_BUF_SIZE`, which is 4096 — so a 300-byte or 1000-byte SysEx sails past
the initial size check. Then it splits into two paths:

- **Real device** (around `:949`–`:955`): sends via
  `MIDISendSysex(&dev->cm.sysex_req)` with `bytesToSend = size`. That's Apple's
  arbitrary-length path — it chunks internally and handles big payloads fine.
- **Virtual source** (around `:941`–`:948`): builds a packet list on the stack
  and adds the data with `MIDIPacketListAdd(&pl, sizeof(pl), …, size, …)`.

The catch is in that second path. `sizeof(pl)` is the size of a single inline
`MIDIPacket`, whose `data` field is only 256 bytes. So when `size` is bigger than
that, `MIDIPacketListAdd` doesn't have room, returns `NULL`, and the function
bails out with `MM_ERROR`:

```c
if (dev->is_virtual) {
    /* Virtual source: push sysex as a packet directly to subscribers */
    MIDIPacketList pl; MIDIPacket* p = MIDIPacketListInit(&pl);
    p = MIDIPacketListAdd(&pl, sizeof(pl), p, 0, (ByteCount)size,
                          dev->cm.sysex_buf);
    if (!p) return MM_ERROR;   /* <- large SysEx lands here */
    return (MIDIReceived(dev->cm.virt_ep, &pl) == noErr) ? MM_SUCCESS : MM_ERROR;
}
```

So it's not a crash or a silent truncation — it fails honestly with `MM_ERROR`.
But it does mean a virtual source can't emit, say, a full patch dump.

(Just to head off a red herring: the regular `mm_out_send` path uses the same
stack-packet-list idiom, but it only ever carries 1–3 byte channel/system
messages, so it never gets near the limit. This is really only about big SysEx on
the virtual branch.)

## How to see it

1. In one process, open a virtual source and a virtual destination.
2. Send a 300-byte SysEx (`F0` … 298 data bytes … `F7`) with
   `mm_out_send_sysex`.
3. Watch what comes back.

Today you get `MM_ERROR` and nothing arrives. The hoped-for behavior is the full
300 bytes round-tripping through.

## A possible fix

In the virtual branch, build the packet list in a heap buffer sized to the actual
payload instead of relying on the fixed stack `MIDIPacketList`. `MIDIReceived`
is happy to take a packet list you've allocated large enough — so it's really
just the stack-allocated single packet that's the constraint. (The real-device
path is already fine and wouldn't need to change.)

Worth mentioning: if you ever pick up the raw-bytes API we proposed separately,
`mm_out_send_raw` on a virtual source would need exactly this same "size the
buffer to the data" handling — so the two could share the fix.

Totally understand if large virtual-source SysEx isn't a priority for most users
— for us it matters because our test loopback runs over virtual ports, so it's
the one place we can't validate big-SysEx round-trips until this is sorted.
Happy to send a PR if that'd help!
