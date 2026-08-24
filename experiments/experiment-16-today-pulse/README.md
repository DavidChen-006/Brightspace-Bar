# Experiment 16 — the today pulse

The grid's rule is **calm-until-touched**: nothing moves unless the cursor asks
it to. This experiment licenses exactly one exception. The today cell breathes
— a slow sine on its outline's alpha and width, plus an optional soft halo —
so "you are here" is findable at a glance, in peripheral vision, without ever
being read as an alarm.

Today is the one cell that is always relevant, which is the whole argument for
the exception. If the breath turns out to be noticeable while you are reading
some *other* cell, the exception has failed and the static outline of exp 9
wins.

Exp 14's mechanics are carried in unchanged — hover outline, hover bubble,
haptic strum at 90ms minimum interval — because David judges the *combination*,
not the pulse alone.

## Run it

```sh
swift run
```

A `circle.circle` icon appears in the menu bar. Open it and look at the
top-left of the grid (row 3 of column 1 — "HW 3 — Vector Fields (due today)").
Then look *away* from it, at the far end of the semester, and decide whether
the breath is still pulling at you.

## Tuning knobs

All in `PulseGridView`, all named constants:

| Knob | Value | Why this value |
|---|---|---|
| `pulsePeriod` | 3.0 s | A resting human breath. Under ~2s starts reading as a blink, i.e. as a warning. |
| `pulseInterval` | 1/30 s | The per-frame alpha step is under 0.02 — below the banding threshold on an 8pt square, so 60fps buys nothing but wakeups. |
| `outlineAlphaMin/Max` | 0.55 → 1.0 | The floor is deliberately not 0: today must never *disappear*. The trough is exp 9's static outline; the pulse only adds above it. |
| `outlineWidthMin/Max` | 1.0 → 1.8 pt | In phase with alpha — out of phase they read as two competing animations. Grows **inward** (inset by width/2) so the 8pt footprint never changes and no neighbour shifts. |
| `haloPeakAlpha` | 0.22 | Set to 0 to delete the halo entirely. It is a knob because at 2.5pt of inflation the halo crosses the 2pt gutter and touches its neighbours; 0.22 keeps that reading as bloom rather than as a second ring. |
| `haloInflate` / `haloWidth` | 2.5 / 1.5 pt | — |

Ease is a pure cosine, `(1 - cos(2πt/P)) / 2`. No linear segments: a triangle
wave of the same period feels mechanical precisely because its velocity jumps
at the turnarounds, and the turnarounds are where breathing lives.

## The phase clock is free-running

The sine reads `ProcessInfo.processInfo.systemUptime` directly and is **never
reset**. Only the *timer* is gated by the menu, not the phase. So the menu
opens onto a breath already in progress — mid-inhale as often as not — instead
of kicking from the trough every single time. That kick is the tell that turns
a presence into an animation, and it costs nothing to avoid.

## Constraints carried in from earlier experiments

- **`.common` mode or nothing.** Exp 12 measured that `.default`-mode timers
  never fire while a menu is open (menus spin the run loop in `.eventTracking`).
  The pulse timer is created with `Timer(timeInterval:target:selector:…)` and
  added via `RunLoop.main.add(timer, forMode: .common)`. Get this wrong and the
  cell is frozen for the entire life of the menu — indistinguishable from the
  feature not existing.
- **Target/action, not a block.** The block form of `Timer` is `@Sendable`, and
  this view is `@MainActor`; target/action sidesteps laundering `self` across
  isolation for zero benefit.
- **Timer gated to menu-open.** `MenuController` owns it via
  `menuWillOpen` / `menuDidClose`. The menu is shut 99% of the time and an
  invisible 30fps redraw is pure battery.
- **Partial invalidation.** Only the today cell's rect (inflated 6pt past the
  halo) is invalidated. `draw(_:)` still renders the whole row — AppKit just
  clips it — so the hover bubble and hover outline stay correct.
- Sync top level in `main.swift` (the exp-5 lesson: a top-level `await` starves
  the MainActor and blanks the menu).

## FINDINGS

Feel verdicts *(pending David's eye)*: is 3.0s calm or sleepy; is 0.55 a high
enough floor; does the halo read as bloom or as a smudge; and the real test —
is it still unobtrusive when you are looking at a different cell?

Measured here, by driving a scratchpad copy of this app that pops its own menu
open and closes it again from a `.common` timer (the machine has no
accessibility grant, so the real UI could not be clicked):

1. **The `.common`-mode timer fires at full rate during menu tracking.** 426
   ticks across a ~14s menu-open window = 30.0/s, exactly the requested rate.
   Exp 12's finding holds and the workaround holds with it.
2. **Every tick produced a real frame.** The log prints ticks and `draw(_:)`
   calls side by side; they tracked 1:1 the whole way (426 ticks / 427 frames,
   the extra frame being the initial menu display). So
   `setNeedsDisplay(rect:)` is *not* coalesced away during `.eventTracking` —
   the invalidation path works inside a tracking menu, not just the timer.
3. **`cancelTracking()` also works from a `.common` timer**, which is how the
   probe closed its own menu. Useful to know for any future auto-dismiss.
4. **CPU: 0.0% idle, ~6–7% while the menu is open and pulsing** (debug build,
   `top -l 3 -s 2`). Idle being a flat zero is the gate doing its job. The 6–7%
   is higher than one 8pt cell deserves and is inflated by the unoptimised
   debug build plus a full-row `draw(_:)` per frame; if it stays high in
   release with ~8 rows, the fix is a CALayer for the today cell rather than a
   faster timer.

No debt to record on the gating — `menuWillOpen`/`menuDidClose` was
straightforward and is in place.
