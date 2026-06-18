# Bug: note-on with velocity 0 is folded to note-off on some backends but not others

> **Paste-ready GitHub issue.** Title suggestion:
> *"Inconsistent handling of note-on velocity 0 across backends (ALSA/UMP fold to NOTE_OFF, CoreMIDI doesn't)"*
>
> Labels you might want: `bug`, `consistency`. Line references are against `main`
> at `bb705e8` — worth a quick re-check against current HEAD.

---

Hi Joseph 👋

This one's more of a cross-backend consistency thing than a hard crash, but it
surprised us, so here it is. The MIDI spec lets a "note-on with velocity 0" stand
in for a note-off — lots of gear sends it that way to keep running status going.
The question is what minimidio reports when it sees one, and right now the answer
depends on which platform you're on.

## The inconsistency

For the exact same incoming bytes `90 3C 00` (note-on, middle C, velocity 0),
you get a different `mm_message.type` depending on the backend:

- **ALSA (Linux)** folds it to a note-off — around `minimidio.h:1406`:
  ```c
  msg.type = (ev->data.note.velocity > 0) ? MM_NOTE_ON : MM_NOTE_OFF;
  ```
- **The UMP → MIDI-1 conversion** also folds it — around `minimidio.h:665`:
  ```c
  if (msg->type == MM_NOTE_ON && msg->data[1] == 0) msg->type = MM_NOTE_OFF;
  ```
- **CoreMIDI (macOS)** does *not* fold — it just takes the status nibble, so the
  message stays `MM_NOTE_ON` with velocity 0 (around `minimidio.h:786`):
  ```c
  msg.type = (mm_message_type)((s >> 4) & 0x0F);
  ```

(We read the ALSA, UMP, and CoreMIDI paths directly. We didn't line-by-line
re-verify WinMM and WebMIDI, so we're not claiming anything specific about those
two — but the three above already disagree with each other.)

So the same physical event is `MM_NOTE_OFF` on Linux and `MM_NOTE_ON` on macOS.
For something that's meant to be low-level transport, that's a tricky thing to
build on — and the folding is lossy in one direction: once `90 3C 00` has been
turned into `MM_NOTE_OFF`, a downstream consumer can't tell it actually arrived
as a velocity-0 note-on.

## How to see it

Feed `90 3C 00` into each backend's input and compare `msg.type`. Today ALSA and
the UMP path report `MM_NOTE_OFF`; CoreMIDI reports `MM_NOTE_ON`.

## A couple of ways you could go

The way that's friendliest to a low-level transport is **don't fold anywhere** —
report exactly what came in and let the consumer decide whether to treat it as a
note-off. That keeps all backends agreeing and keeps the information intact.

If you'd rather keep the fold as a convenience (which is a totally reasonable
choice for app developers who don't want to think about it), then the ask would
just be to do it **consistently on all backends** and mention it in the docs, so
people know to expect it. Either way, the win is that all four backends behave
the same.

For full transparency about our own bias: we'd personally love the no-fold
version, because our layer wants to own that normalization in one place — and we
*can* normalize a velocity-0 note-on into a note-off ourselves, but only if the
backend hands it to us unfolded in the first place. We can't un-fold what's
already been folded. (This is also one of the things that just goes away if you
adopt the raw-bytes mode we proposed separately.) But honestly, consistency
either direction is the real fix here.

Happy to PR whichever way you prefer!
