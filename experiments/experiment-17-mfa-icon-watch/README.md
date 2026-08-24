# Experiment 17 — how fast does the icon learn?

The daemon writes `BSB_ROOT/cache/mfa.json` mid-login:

```json
{ "number": "20", "mintedAt": "2026-08-15T14:00:00Z" }
```

…and the menu bar has to be showing `20` before David has finished picking up
his phone. Exp 12 already priced the repaint at 1–4 ms, so the only unknown left
is the **transport**: the gap between one process renaming a 60-byte file into
place and this one having repainted. Files are the interface (LADDER-PLAN), the
app is a pure renderer, and this experiment picks the pickup mechanism.

Three candidates, same app, chosen by `EXP17_MODE`:

| Mode | Technique |
| --- | --- |
| `kqueue` | `DispatchSource.makeFileSystemObjectSource` on the cache **directory** |
| `fsevents` | `FSEventStream` on the same directory, latency `0.1`, `NoDefer` |
| `poll` | a 500 ms `Timer` that re-reads the path (the dumb baseline) |

## Run it

```sh
cd experiment-17-mfa-icon-watch
node writer.mjs                                  # all three, in order, then a table
node writer.mjs --mode kqueue                    # one technique
EXP17_WRITES=3 EXP17_IDLE=5 node writer.mjs      # smoke test (~1 min)
```

`writer.mjs` builds the app if needed, then for each technique: makes a fresh
temp root, launches the app, holds still for a 60 s idle window (that is the CPU
measurement), writes `mfa.json` **atomically** 20 times with randomized 1–3 s
gaps, deletes it, kills the app, and moves on. A status item appears in the menu
bar and flips between `🔐 nn` and `book.closed` for about six minutes.

Nothing outside this folder is touched: the root is `mkdtemp`'d under `TMPDIR`,
never the real `BSB_ROOT`.

## What is actually being measured

The writer stamps each file with the wall-clock instant the write **began**; the
app stamps the instant **after** the status item has been repainted. Latency is
the difference, so it contains the whole chain: temp write + rename (~1.2 ms
median, measured separately and reported), kernel notification, dispatch to the
main queue, `read`, JSON parse, and the AppKit repaint. It is end to end on
purpose — the app has no way to be faster than this number, and neither does the
user's eye.

Both processes read CLOCK_REALTIME (`performance.timeOrigin + performance.now()`
in Node, `Date().timeIntervalSince1970` in Swift), because a monotonic clock is
not comparable across two processes. Every detection is appended to
`artifacts/results.jsonl`, which is the evidence behind every number below.

---

# FINDINGS

**kqueue on the directory wins by an order of magnitude, and it is not close.**
20 writes per technique, 60 s idle window, one delete, on this machine
(M-series, macOS 15.6.1, APFS):

| technique | samples | median | p95 | max | delete | idle CPU / 60 s | spurious wakeups | dup | missed |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **kqueue** | 20/20 | **2.6 ms** | **3.5 ms** | **3.8 ms** | 2.9 ms | 13.5 ms | 20 | 0 | 0 |
| fsevents | 20/20 | 12.4 ms | 17.3 ms | 117.5 ms | 15.3 ms | 14.4 ms | 0 | 0 | 0 |
| poll (500 ms) | 20/20 | 179.6 ms | 416.7 ms | 434.8 ms | 256.9 ms | 30.3 ms | 0 | 0 | 0 |

Nothing was missed and nothing double-rendered: all three techniques detected
all 20 writes **and** the delete (the icon reverted to `book.closed` every
time). The `spurious` column is wakeups that found nothing changed — see trap 2;
they cost a `read` and no repaint.

Per-sample spreads, because a median hides the shape:

```
kqueue    3.3 1.4 3.0 1.3 3.8 3.4 3.0 2.2 3.4 0.6 2.6 1.6 1.5 1.2 3.5 1.5 2.8 0.5 3.2 2.8
fsevents  117.5 13.5 12.2 12.7 17.3 11.9 10.4 13.6 12.7 12.1 14.5 16.8 11.8 13.9 10.4 12.4 10.8 10.4 10.8 14.8
poll      417 236 266 180 31 128 171 359 154 402 385 143 335 98 330 142 435 111 153 253
```

kqueue's whole distribution fits inside 4 ms — under a single display frame, so
the number appears in the same repaint the human would have seen if the app had
written the file itself. FSEvents sits at a steady ~12 ms, which is also fine for
a human, **except for its first sample**. Poll is a uniform draw from
[0, 500 ms], exactly as theory says, and its worst case is half a second of a
user staring at a stale menu bar.

**Idle cost does not decide this.** Over a 60 s window with zero writes, the
whole process burned 13.5 ms (kqueue), 14.4 ms (FSEvents) and 30.3 ms (poll) of
CPU. That is 0.02–0.05 % of one core; the two event-driven watchers are
indistinguishable from each other at this resolution, and poll's doubling is
still nothing in absolute terms. **Poll is disqualified by its latency, not by
its cost** — an honest reading, since "polling burns battery" was the answer I
expected to be able to give and the data does not support it at 500 ms. (The
figure is whole-process CPU including the `NSApplication` run loop, not the
watcher in isolation, so treat the differences as an upper bound on the
watcher's own share.)

## Recommendation: kqueue directory source

Use `DispatchSource.makeFileSystemObjectSource` on `BSB_ROOT/cache/`, re-read
`mfa.json` from scratch on every event, and compare content before rendering.

It is 5× faster than FSEvents at the median and 70× faster than polling, it has
no tail (max 3.8 ms vs FSEvents' 117.5 ms), it costs no more at idle than
FSEvents does, its API is thirty lines of Swift with no C callback or context
pointer, and it degrades in the safe direction: kqueue coalesces bursts, so a
flurry of writes yields one wakeup that reads the newest content — which is
precisely right for an app that renders *current state* rather than a log of
transitions. The decisive number is the tail, and specifically **which** sample
carries it: FSEvents' first delivery after a long quiet period cost 117.5 ms in
the main run and 257.4 ms in a targeted replicate (trap 3). In production the
app sits idle for hours and then receives exactly one write — the MFA number.
The single sample FSEvents is worst at is the only sample this feature ever
takes.

## Traps

1. **A kqueue watch on the file itself goes deaf after the first atomic write —
   measured, not assumed.** The app arms a second, deliberately doomed
   descriptor on `mfa.json` the first time it appears and counts what it
   receives. Result, verbatim from the run: *armed on the first write, delivered
   1 event(s) [delete] across the remaining 19 writes + the delete.* A rename
   over the path unlinks the inode the descriptor holds; the descriptor keeps
   pointing at a file nobody can reach any more, and the path it used to name
   goes on changing without it. This is why the directory is the thing to watch,
   and it is the failure mode that would have shipped silently — the icon would
   update once and then never again, which looks like "it works" in a demo.

2. **One atomic write is two directory events, and the first one is a lie.**
   `writeFileSync(tmp)` then `rename(tmp, mfa.json)` both modify the directory.
   kqueue delivered **exactly 20 spurious wakeups for 20 writes** — one per
   write, the temp file's creation, at which moment `mfa.json` still holds the
   old content (or does not exist). Comparing file content before rendering is
   what makes this harmless; without it the app would re-render stale data, and
   on write #1 would read a file that is not there yet. FSEvents recorded zero
   spurious wakeups, because its own ~12 ms delivery delay coalesces the create
   and the rename into a single callback — its slowness accidentally solves a
   problem kqueue hands you to solve yourself.

3. **FSEvents' first delivery after a quiet period is 10–20× its steady-state
   latency, and it reproduces.** Main run: sample 1 = 117.5 ms, samples 2–20 =
   10.4–17.3 ms. Targeted replicate after another 60 s idle window: sample 1 =
   257.4 ms, samples 2–4 = 12.8–15.9 ms
   (`artifacts/fsevents-cold-start-replicate.jsonl`). The 3-write smoke test
   with only a 4 s idle window did **not** show it, so it is a cold-path cost
   tied to the stream having been quiet, not a per-delivery risk. kqueue showed
   nothing comparable under identical conditions (sample 1 = 3.3 ms after the
   same 60 s of silence).

4. **`kFSEventStreamCreateFlagNoDefer` is not optional.** Without it the 0.1 s
   latency parameter is a floor applied to every pickup rather than a debounce
   on what follows the first event, and the measurement becomes a measurement of
   the parameter. With it, FSEvents' 12 ms is its real cost.

5. **FSEvents resolves symlinks; `TMPDIR` is one.** macOS temp roots live under
   `/var/folders/…`, and `/var` is a symlink to `/private/var`. FSEvents reports
   realpath'd paths, so a harness that registers the unresolved path gets events
   whose paths do not match what it asked for. The driver `realpath`s the root
   before handing it over. Irrelevant to the real `BSB_ROOT`, fatal in the test
   harness — the classic way a watcher experiment "proves" a technique broken.

6. **Warm the font or the transport gets blamed for AppKit.** Exp 12 measured
   the *first* `attributedTitle` at 19 ms (font resolution, paid once) and every
   later one under 1 ms. Unwarmed, that 19 ms lands on sample 1 of every run and
   silently becomes the p95 column. The app renders one throwaway number at
   startup for this reason, which is also what makes trap 3 attributable to
   FSEvents rather than to AppKit.

7. **Timers go in `.common` mode** (inherited from exp 12): a `.default`-mode
   timer stops firing while a menu is open, and the menu being open is exactly
   when someone is looking at the icon. Applies to the poll watcher and to any
   revert timer in the real feature.

8. **Delete is a first-class event.** The icon must revert when the challenge
   resolves, and `mfa.json` disappearing is the signal. All three techniques
   caught it (2.9 / 15.3 / 256.9 ms). A watcher armed on the file rather than
   the directory catches this one event and nothing else — see trap 1, which is
   how it convinces you it works.

## Not tested

- **Rapid-fire writes.** Gaps were randomized 1–3 s, so kqueue's coalescing was
  never actually stressed. Coalescing is safe for this feature by construction
  (render current state, not transitions), but "two writes 5 ms apart yield one
  render of the second" is reasoned, not measured.
- **The watched directory being deleted or replaced.** The mask includes
  `.delete`/`.rename` on the directory, but the daemon never does this and
  neither did the harness. If `reset.sh --cache` removes `cache/` wholesale, a
  running watcher is pointed at a dead inode and would need re-arming.
- **Sleep/wake and long-lived streams.** Every run here was a fresh process
  living about two minutes. Whether a kqueue source survives a laptop lid cycle
  intact is a separate probe, and is the one remaining risk to this
  recommendation.
- **Network or non-APFS volumes.** `BSB_ROOT` is local by definition, so this is
  not a gap that matters here.
