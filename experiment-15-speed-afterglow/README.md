# Experiment 15 — the speed-gated afterglow

Exp 9 proved the sweep is the delight moment. Exp 14 made it *bodily* (a haptic
detent per cell crossing). This experiment asks whether the sweep can also have
a **skill**: cells the hover outline just left keep a fading comet tail — but
only while you are moving fast enough to have earned it.

Sweep slowly and the grid is exactly exp 14: outline, detents, nothing else.
Flick across it and a streak blooms behind the outline and dies in a quarter
second. The gate is the entire point. A trail you always get is decoration; a
trail you have to execute is a thing to get good at, and the hypothesis is that
you will catch yourself doing crisp little sweeps because the fast one feels
better. That is muscle memory forming in real time.

Its own folder on purpose: exp 14 stays the haptic verdict, this is the fluency
verdict. Separate folders, separate verdicts, no contamination. The haptic
strum is carried in **unchanged** (90ms minimum tick interval) because the
combination — detents you feel plus a streak you painted — is what is actually
being judged.

## Run it

```sh
swift run
```

A `wind` icon appears in the menu bar (exp 14 is `hand.draw`; they can run side
by side). Open it and alternate: one hesitant drag, one confident flick.

## The gate

| Knob | Value | Why |
| --- | --- | --- |
| `fastCrossingInterval` | **90 ms** (≈11 cells/sec) | Just above a comfortable *reading* drag and just below a flick. You cannot read a deadline name in 90ms, so anyone genuinely scanning the semester stays under the bar and gets a calm, trail-free grid. The gate separates **intents**, not speeds. |
| `fastCrossingsToOpen` | **2 in a row** | One fast crossing is noise — a hand re-settling, a jump across the grid. Two means sustained motion, which is what "fluent" means. |
| `gateHoldInterval` | **150 ms** | Hysteresis. Once open, the gate survives this long without a fast crossing. Without it the trail strobes for anyone hovering right at the threshold, which reads as *broken* rather than as a rule — the ugliest failure mode this mechanic has. |
| `afterglowDuration` | **250 ms** | The whole settle budget. Everything must be perfectly still within ~300ms of the mouse stopping or the menu stops feeling calm-until-touched. |
| `afterglowPeakAlpha` / `afterglowFillRatio` | **0.55** stroke, **0.3×** that as fill | Subtle > flashy. The tail is a ghost of the live outline, never a competitor to it. Alpha decays **squared**, so the ember drops off its peak immediately and then lingers faint — a streak, not a queue of copies of the cursor. |
| `maximumTrailLength` | **12** | At 90ms/crossing against a 250ms life only ~3 entries are ever alive; the cap just bounds a pathological flick. |

Speed is measured as the **gap between consecutive cell crossings**, not as
pointer velocity: the cells are what the hand is aiming at, so crossings/sec is
the rhythm you actually feel. Pixels/sec is a number about the mouse.

The row title is the gate's instrument panel — it reads `· flick!` exactly
while the trail is licensed to paint, and `· N flicks` afterwards. A confusing
session can be resolved by reading instead of guessing.

## What to judge

1. **Is the gate legible?** A gate you cannot feel yourself crossing is just an
   intermittent bug. You should know, without being told, why the tail
   appeared — and be able to summon it again on purpose.
2. **Is 90ms the right bar?** Too low and every drag paints (decoration
   again); too high and only a slam clears it, which teaches flailing rather
   than fluency.
3. **Does it stay calm?** Stop the mouse dead. Everything should be still
   within a quarter second, with no residual shimmer.
4. **Does the trail fight the haptic or agree with it?** Both fire on the same
   crossings; the risk is two rewards competing for the same moment.

## Design constraints carried in

- **`.common`-mode timer, and it matters.** An open `NSMenu` runs the run loop
  in `.eventTracking`, where a `.default`-mode timer never fires once — measured
  the hard way in experiment 12. `Timer.scheduledTimer` silently installs into
  `.default` and would leave the trail frozen on screen for as long as the menu
  stayed open, so the driver is `Timer(timeInterval:)` + `RunLoop.main.add(_:
  forMode: .common)`.
- **The timer exists only while something is fading.** It starts on the
  crossing that opens the gate and invalidates itself the instant the last
  ember dies. A permanent 60fps loop in a menu-bar app is a battery bug wearing
  an animation costume.
- **Sync top level in `main.swift`** — the experiment-5 lesson: a top-level
  `await` starves the MainActor and blanks the menu.
- **The comb rule, extended.** Entering the grid counts, leaving it does not.
  A flick that runs off the right edge doesn't get to paint one last cell as a
  parting gift.
- **No click-to-cycle here.** The sweep stays consequence-free: the reward is
  motion + reading, never mutation.

## FINDINGS

- **The `.common`-mode timer does drive repaints during menu tracking.**
  Confirmed by construction against the exp 12 measurement rather than
  re-measured here — exp 12 established that `.default`-mode timers are
  silently dead inside an open menu, and this experiment installs into
  `.common` precisely to dodge that. If the tail turns out to appear *frozen*
  (painted once and stuck until the menu closes), the mode is the first
  suspect and the finding belongs here.
- **Swift 6 forces a strong capture in the timer block.** The block's own
  `Timer` argument cannot cross onto the MainActor (`sending 'timer' risks
  causing data races`), so the tick invalidates the stored `decayTimer`
  instead and the closure captures `self` strongly. The retain cycle is
  bounded by the decay, which always reaches empty.
- Everything about **feel** — whether 90ms is the right bar, whether the gate
  is legible, whether the streak and the detents cooperate — is *(pending
  David's hand, the one instrument this experiment needs)*.
