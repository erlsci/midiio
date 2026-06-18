# Docs: the `timestamp` comment says "seconds since device opened" but it's a monotonic clock

> **Paste-ready GitHub issue.** Title suggestion:
> *"Doc fix: `timestamp` field comment misdescribes the value (it's monotonic, not since-open)"*
>
> Labels you might want: `documentation`, `good first issue`. Line references are
> against `main` at `bb705e8` — worth a quick re-check against current HEAD.

---

Hi Joseph 👋

Tiny one, purely a documentation thing — no code change needed. We just want to
save the next reader a bit of confusion.

## The mismatch

The `timestamp` field is documented as "seconds since device opened":

- on `mm_message` (around `minimidio.h:320`):
  ```c
  double   timestamp;     /* seconds since device opened                   */
  ```
- and on `mm_ump_packet` (around `minimidio.h:345`):
  ```c
  double   timestamp;     /* seconds since device opened, when available */
  ```

But the value that actually gets filled in comes from a host monotonic clock,
not from when the device was opened:

- on macOS via `mm__cm_ts` (around `minimidio.h:712`), which converts a
  `MIDITimeStamp` host time through `mach_timebase_info` — i.e. mach host time,
  whose zero point is roughly system boot;
- on Linux via `clock_gettime(CLOCK_MONOTONIC, …)` (around `minimidio.h:1400`),
  which is also an arbitrary epoch (again, roughly boot).

So the number is a monotonic timestamp with an unspecified starting point — great
for measuring the *difference* between two events, but not "seconds since you
opened this device." Someone who takes the comment at face value and treats it as
a since-open offset would be off by the machine's uptime, which could be days.

## Suggested wording

Something like:

```c
double timestamp;  /* monotonic host timestamp (unspecified epoch);
                      only meaningful as a difference between two timestamps */
```

…on both fields. That's really all — the behavior is fine, it's just the comment
that's misleading. (For what it's worth, our binding already treats it as a
host-monotonic value and only uses deltas, so we're not blocked — just flagging it
for the next person.)

Thanks!
