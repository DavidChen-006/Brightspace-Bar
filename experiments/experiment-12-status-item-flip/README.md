# Experiment 12 — the status item IS the notification

BrightspaceBar's login occasionally hits Microsoft MFA **number matching**: a
2-digit code appears and the human must type it on their phone. We can already
scrape that code headlessly. This experiment answers the remaining question —
**how do we show it with zero interaction?**

A notification banner needs a glance the user may not give, and Do Not Disturb
swallows it outright. An alert steals focus. The menu bar is already in the
eyeline, always visible, and DND has no opinion about it. So the proposal:
repaint the status item itself as the code, then revert when the challenge
resolves.

## Run it

```sh
cd experiment-12-status-item-flip
swift run
```

An accessory app (no Dock icon). A `book.closed` icon appears in the menu bar;
click it for the levers. Every flip prints its main-thread cost to stdout.

## Levers

| Menu item | What it does |
| --- | --- |
| **Show code 20** | Fixed code, for a stable thing to stare at. |
| **Show random code** | A fresh 2-digit code — proves it is drawn live, not a baked image. |
| **Simulate challenge (auto-revert in 8s)** | The real use case: code appears, then the icon returns on its own. |
| **Reset to icon** | Back to normal. |
| **Treatment → switch to …** | Toggles between treatment A and B (below). Repaints in place, so you can A/B mid-challenge. |
| **Blink: off / ON** | Pulses the button at 0.6 s via `appearsDisabled`. Stacks on either treatment. |
| **Quit** | — |

`EXP12_SELFTEST=1 swift run` drives six flips with no human and prints the
timings, then exits. It is a stopwatch, not a test suite.

## The two treatments

- **A — symbol + text.** `lock.badge.exclamationmark` with `.imageLeading` and
  the title `" 20"`. Inherits the menu bar's own text color, so dark/light,
  tinted wallpapers, and reduce-transparency all just work.
- **B — bold red text.** No symbol; an `attributedTitle` of `"🔐 20"` in
  bold monospaced-digit systemRed.

---

# FINDINGS

**Does real-time flipping work? Yes, completely.** Setting `image`, `title`, or
`attributedTitle` on the existing `statusItem.button` repaints immediately. The
status item is never recreated, so it keeps its slot in the menu bar across the
flip — there is no teardown that could flicker or reorder it.

**Is it instant? Yes — measured, not assumed.** From `EXP12_SELFTEST=1`:

```
flip → icon                              2.987 ms
flip → code 39 via A: symbol + text      3.531 ms
flip → code 43 via A: symbol + text      1.957 ms
flip → icon                              1.137 ms
flip → code 90 via B: bold red text     19.418 ms   ← first attributed title
flip → code 86 via B: bold red text      0.799 ms
flip → icon                              1.370 ms
```

Roughly 1–4 ms on the main thread, i.e. under a single frame — visually
instantaneous. The one 19 ms outlier is the *first* attributed title only
(font resolution on first use); every subsequent one is under a millisecond.
If a treatment ever needs to be fast on the very first paint, warm the font.

**Which treatment reads best?** **A (symbol + text) is the better default, B is
the better alarm.** A looks like it belongs in the menu bar, which is exactly
its weakness — a well-behaved icon is easy to not notice.
`lock.badge.exclamationmark` is visibly different in silhouette from
`book.closed`, so the change registers, but quietly. B's red is unmissable in
peripheral vision, and red in the menu bar is rare enough to mean *something is
waiting on you*. Recommendation for the real flow: **B, plus blink**, because a
number-matching prompt is genuinely blocking and times out — this is the one
moment where being loud is correct. Revert to the plain icon the instant the
challenge resolves.

**Blink is cheap.** `appearsDisabled` toggling dims image and title together
without us touching the content, so it stacks on either treatment for free.
Whether a pulse is *too* much is a judgement call — that one is yours to make
by looking.

## Gotchas

- **Timers must be added in `.common` mode.** While a menu is open the run loop
  runs in `.eventTracking`, where a `.default`-mode timer does not fire — the
  auto-revert would appear to hang for as long as the menu stayed open. This
  code preempts it with `RunLoop.main.add(timer, forMode: .common)` rather than
  waiting to be bitten; I did not reproduce the failure first. It matters in the
  real flow, since the user may well have the menu open when a challenge lands.
- **Everything here is main-thread-only.** The scraper will deliver the code
  from a background context; it must hop to the MainActor before touching the
  button.
- **Width changes shift your neighbours.** `.variableLength` means going from
  icon to icon-plus-number widens the item, and every status item to its *left*
  slides. Unavoidable and not visually alarming (it is one brief nudge), but
  worth knowing it is not purely local. Monospaced digits at least stop the item
  resizing again between codes like `11` and `88`.
- **Clearing state needs both title properties.** Setting `title` does not clear
  a previously set `attributedTitle`; `showIcon()` clears both, plus sets
  `imagePosition`, or you get a stale ghost of the other treatment.
- **Treatment A is theme-proof; B is not.** A borrows the system text color. B
  hardcodes `systemRed`, which is a dynamic color and so adapts, but any custom
  color would need checking against light, dark, and tinted menu bars.

## Not tested

- Behavior when the menu bar is full and macOS hides overflow items — if the
  status item is hidden behind the notch or overflow, none of this is visible.
  That is the real risk to this whole approach and deserves its own probe.
- Whether the flip is legible on a notched display when many apps compete for
  bar space.
