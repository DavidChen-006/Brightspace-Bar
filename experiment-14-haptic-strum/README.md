# Experiment 14 — the strum

Exp 9 proved the sweep (hover outline gliding cell to cell) is the delight
moment. This experiment upgrades it from *visual*-continuous to
*bodily*-continuous: an `NSHapticFeedbackManager` `.alignment` tick fires at
every cell-boundary crossing, so dragging across the semester feels like
running a thumbnail down a comb — the grid grows detents.

Its own folder on purpose: exp 9 is the input probe (click-to-cycle), this is
the feel probe. Separate folders, separate verdicts, no contamination.

## Run it

```sh
swift run
```

A `hand.draw` icon appears in the menu bar. Open it and sweep the grid
**on the built-in trackpad**.

## What to judge

1. **Do ticks fire at all during menu tracking?** Menus run a special
   event-tracking loop; haptics were designed for ordinary windows. Every
   fired detent is logged (and counted in the row title), so feel can be
   compared against fact: title says 30 detents but the hand felt nothing →
   fired-but-imperceptible; title stays at 0 → suppressed.
2. **Detents or buzz?** Slow sweep should feel like distinct teeth; a fast
   flick crosses several cells per frame — does it degrade into noise?
3. **The comb rule:** entering the grid ticks, leaving it doesn't (a comb
   ticks when a tooth is reached, not when the thumb lifts).

## Hardware honesty

Haptics exist only on Force Touch trackpads. On an external mouse the strum
silently degrades to the visual sweep — which is why the haptic must stay a
*layer* on the interaction, never the interaction itself.

## Design constraints carried in

- `.alignment` pattern (subtlest of the three) — texture, not event.
- `performanceTime: .now` — deferred times would smear fast crossings into
  one mush.
- **No click-to-cycle here.** The sweep must stay consequence-free: the
  reward is motion + reading, never mutation. Editing stays exp 9's boring,
  deliberate gesture.

## FINDINGS

*(pending David's hand — the one instrument this experiment needs)*
