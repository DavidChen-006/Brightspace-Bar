# Next Vertical Slice 3: The Course Component (custom rendering)

Issues checkpointed after seeing graph slice v1 running in stub mode
(2026-08-10). The solutions are NOT all decided — that is deliberate.
Experiment 9 exists to answer the open questions before the slice is planned.

## The bottleneck

**Hover does not include the strip.** The course title is a native `NSMenuItem`
and the graph is a separate inert item, so they can never highlight as one
unit. No configuration fixes this; the only path to "the course + graph feels
like one component" is a custom-rendered menu item — one `NSMenuItem` whose
`view` hosts the whole component.

Custom rendering is the bottleneck. Every other issue below is either solved
by it (hover unity, dividers, grid labels) or is a cheap policy flip that can
land any time after it. Solve the bottleneck first.

## Issues (checkpointed so they are not forgotten)

1. **Hover unity.** Hovering a course must highlight title + graph together,
   like RepoBar's repo rows. This is the whole reason for the slice.

2. **The graph must always be present.** SCLA and Civics showing no graph at
   all is wrong — an empty strip says "nothing due," a missing strip is
   indistinguishable from a bug. Every visible course renders its window,
   including never-fetched. (Proposed mechanism, to confirm at wiring time:
   `GraphTranslation` emits the window for every state including
   `.neverFetched`, so the decision stays in the pure layer and the renderer
   never invents cells. The stub seeds change to match.)

3. **Submenu uniformity.** Every course gets at least
   `[Open Course Home]` + "No assignments" — no legacy plain-clickable rows.
   Two interaction models for identical-looking rows is confusing. (Today a
   submenu-less course IS clickable — the click opens course home directly —
   but the inconsistency stands.)

4. **Visual separation.** Lines above and below each course component, with
   ample spacing — RepoBar's divided-row feel. Lives inside the component
   view, so it arrives with the custom rendering.

5. **Grid, not strip.** GitHub-style 7-row week-aligned grid. The strip caps
   at ~4 weeks because one row is all the menu's width holds; a 7-row grid
   holds a full semester (~16 week-columns) in roughly the same width — the
   window scale the feature always wanted. The reading-order problem ("do I
   read rows or columns?") is solved the way GitHub solves it: abbreviated
   weekday labels on rows (M/W/F) and month labels over the columns. Labels
   require custom drawing — same bottleneck, same slice. The window logic
   gains the week-alignment RepoBar's `alignedRange` already has (deliberately
   skipped for the strip; ports the same way, injected clock, sign flipped).

## Open seams — the experiment answers these

- **S1 — What does a custom view cost?** Does an `NSMenuItem` with a custom
  view coexist with: highlight (must the view draw its own?), click routing,
  an attached submenu and its arrow, keyboard navigation, accessibility?
  Which of these does RepoBar's `MenuItemHostingView` machinery actually
  solve, and which turn out to be free?
- **S2 — How thin can the port be?** RepoBar hosts SwiftUI
  (`MenuItemHostingView` + hosting view + highlight environment). Is that
  machinery necessary, or does a plain `NSView` component (house style: no
  SwiftUI) get hover unity with less?
- **S3 — Does the port survive restyling?** Can the borrowed code be
  reshaped into house style — pure layout functions, injected values, no
  ambient state — or does AppKit force compromises worth documenting?
- **S4 — Metrics parity.** Can a custom row visually match native rows
  (font, inset, height) closely enough that a mixed native/custom menu looks
  intentional? Determines whether migration can be incremental.
- **S5 — Grid legibility.** Cell size, label size, and total width of a
  semester grid at menu width — probed in the same playground once the
  component renders.
- **S6 — What happens to MenuAssembler?** The standalone strip item
  presumably disappears into the component. What do the existing structural
  tests become?

## Experiment 9 (playground, disposable)

`experiment-9-custom-menu-item/`, sibling of experiments 1–8. Hyper-focused:
**one row, "Purdue Civics Knowledge Test"** — chosen because nothing about it
needs a backend. A minimal menu-bar app whose dropdown holds a few native
rows plus ONE custom-rendered course component (title + strip in a single
hoverable item, dividers), so native and custom sit side by side in the same
menu for direct visual comparison.

Port from RepoBar as literally as needed to get it rendering; restyle only
if cheap (thinnest experiment wins — S3 can be answered by inspection).
Findings land in the experiment's README, numbered against the seams above.
The real port into BrightspaceBar is a fresh implementation informed by the
findings, exactly as experiments 1–8 became the app.

## After the experiment

Re-plan the slice with answers in hand. Expected shape: hosting/component
view first, grid + labels inside it second, then the two policy flips
(always-graph, always-submenu) — the flips are cheap, independent, and
testable through the existing suites.
