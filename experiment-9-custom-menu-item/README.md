# experiment-9-custom-menu-item

**Question:** can a custom-rendered `NSMenuItem` give hover unity — course
title + graph highlighting as ONE component — and what does it cost?
(NewVertical-3.md, seams S1–S6.)

**Answer: yes, with a plain NSView — no SwiftUI hosting needed.** See
`artifacts/render.png` for the four rendered states (strip/grid ×
normal/highlighted).

## Run it

```sh
./Scripts/run.sh            # menu-bar app; click the grid icon
./Scripts/run.sh --smoke    # build, launch, verify alive, kill
./Scripts/run.sh --selftest # headless: popup geometry, hit-testing, deep links
./Scripts/run.sh --probe    # opens the menu itself and measures it; artifacts/probe.log
./Scripts/run.sh --render   # redraws artifacts/popup.png
EXP9_RENDER=out.png ./.build/debug/Exp9   # offscreen render of the components
```

The dropdown holds native rows AND two custom components side by side, so the
difference is judged in one menu: hover the native `CS 17600` row, then hover
`Purdue Civics Knowledge Test` (strip + submenu) and `SCLA 10100` (7×16
GitHub grid with M/W/F + month labels).

**To see the cell-hover popup:** open the menu and hover the
`DAVID 10000 — Rendering Playground` row's grid. Counting columns from the left
edge of the grid and rows from the top:

| Hover | Column | Row | What appears |
|---|---|---|---|
| The list case | **4th** | **3rd** (just below `M`) | a two-row card: *HW 5 — Gradients* (Assignment) + *Quiz 5 — Lagrange Multipliers* (Quiz) |
| The crowded day | **7th** | **3rd** | a three-row card, ending in *Lab Practical 2* (Test) |
| A single item | 1st | 3rd (the outlined "today" cell) | one row: *HW 3 — Vector Fields* |

Grey cells carry nothing and show no card. Move onto a card's row to light it,
click the row to open that item's real Brightspace page and close the menu, or
move the pointer off the cell and card to dismiss it.

## Findings, by seam

**S1 — what a custom view costs.** An `NSMenuItem` with a `view` renders
NOTHING natively; every piece is hand-supplied, and each was small:

| Piece | Who does it | Status |
|---|---|---|
| Highlight background | Hand-drawn capsule (`selectedContentBackgroundColor`, inset 6/2, radius 6) | MEASURED (render) |
| Highlight *signal* | `NSMenuDelegate.menu(_:willHighlight:)` flips a flag on each component view | REASONED — standard delegate contract; confirm live by hovering |
| Click | `mouseUp` → `menu.cancelTracking()` + `performActionForItem(at:)` | REASONED — the canonical view-item pattern; confirm live by clicking |
| Submenu arrow | Hand-drawn chevron | MEASURED by proxy: RepoBar hand-draws its own chevron (`MenuItemContainerView.showsSubmenuIndicator`), which is why theirs exists at all |
| Submenu opening on hover | AppKit (tracking is item-based, not view-based) | REASONED; confirm live |
| Text/graph colors under highlight | Hand-switched to `selectedMenuItemTextColor` + white-alpha cell palette (RepoBar's highlighted-palette trick) | MEASURED (render) — accent-on-accent invisibility is real and the palette swap fixes it |

**S2 — how thin can the port be?** Thinner than RepoBar. A plain `NSView`
with one `draw(_:)` achieves hover unity; `NSHostingController`,
`MenuItemContainerView`, the `@Observable` highlight state, and the
measurement/caching machinery (~200 lines) are SwiftUI-hosting overhead we
don't need. What we actually keep from RepoBar: the metrics (6/2/6 capsule),
the hand-drawn chevron idea, and the white-alpha highlighted palette. The
`measuredHeight`/`sizeThatFits` machinery is unnecessary because our heights
are static arithmetic — `NSMenuItem` honors the view's frame as-is.

**S3 — does it survive house style?** Yes, cleanly. Geometry is already a
pure static function (`fittingSize`, `cellRects`) over injected values; the
view's `draw(_:)` is a thin shell over it. Nothing forced ambient state; the
only impurity is the dynamic system colors, which resolve at draw time by
design. The real port should split `CourseComponentLayout` (pure, testable
headless — the `GraphStripLayout` pattern) from the drawing shell.

**S4 — metrics parity.** `NSFont.menuFont(ofSize: 0)`, 14pt text inset, 6/2/6
capsule. In the offscreen render this reads native-adjacent; the live
side-by-side against real rows is the judgment that matters — David judges.
One known gap: native rows' exact capsule metrics may drift by OS version;
ours are constants.

**S5 — grid legibility.** MEASURED (render): a 16-week × 7 grid with
single-letter M/W/F row labels and month labels over the columns fits in
~330pt — comfortably menu-width — and reads clearly at 8pt cells. The
GitHub-style labels resolve the read-rows-or-columns ambiguity exactly as
hoped. A semester grid is viable.

**S6 — what happens to MenuAssembler.** The standalone strip item disappears:
a `.course` row becomes ONE item carrying a component view (title + graph +
hairlines), with the submenu still attached to that item. `MenuAssembler`
keeps its structure — it swaps `linkItem(...)` for `componentItem(...)` on
course rows; click routing still travels via `representedObject`. The
existing structural tests change from "course item + strip item" to "course
item whose view carries the cells"; MenuAssemblerGraphTests' assertions
mostly relocate rather than die. The new hand-owned surfaces (highlight
delegate, click forwarding, chevron) need tests of their own — the delegate
and mouseUp paths are plain methods, callable headless.

## S7 — the cell-hover popup

**Question:** hover ONE cell of the grid and get a card listing everything due
that day, whose rows are themselves hoverable and clickable straight through to
Brightspace. An open `NSMenu` runs a modal tracking loop, so every step of that
sentence was in doubt.

**Answer: yes, and every step is measured.** The card is drawn *inside* the menu
item view. No popover, no panel, no second window.

### What works, and how it was proven

The whole path was measured with nobody at the keyboard: `--probe` opens the
menu itself, then posts real `NSEvent`s into our own queue with
`NSApp.postEvent` — which, unlike `CGEventPost`, needs no Accessibility
permission (this machine has none: `AXIsProcessTrusted() == false`).

| Piece | Mechanism | Status |
|---|---|---|
| Code running mid-tracking | A timer added *only* to `.eventTracking` | MEASURED — fires, `runLoopMode=NSEventTrackingRunLoopMode`; the menu's loop services timers |
| Which cell the pointer is on | `cellIndex(at:)`, the pure inverse of `cellRects()` | MEASURED — `--selftest`: 10 seeded days, every card row's centre hit-tests back to its own index |
| Pointer motion inside an open menu | `NSTrackingArea` + `mouseMoved` | MEASURED — injected `mouseMoved` → `hoveredCell=23 popupAnchor=23` |
| Card rows take clicks | `mouseUp`, tested against row rects **before** cells | MEASURED — injected down+up on row 1 → *Quiz 5 — Lagrange Multipliers*, correct `qi`/`ou` |
| Opening the link, then closing | `cancelTracking()` first, `NSWorkspace.open` second | MEASURED — `popUp` returned immediately after the click; the menu closed cleanly, no stuck tracking |
| Dismissal | Pointer outside the union of cell + card | REASONED — the geometry is selftested, the live feel is David's call |

Row rects are tested **before** cell rects in `mouseUp` for a reason: the card is
painted over the grid, so a row click would otherwise fall through to whatever
cell sits underneath it.

### The alternatives, and why they lost anyway

The repo's standing assumption was that nothing can float above an open menu.
**That is false, and both alternatives display fine:**

| Surface | Result | Status |
|---|---|---|
| `NSPanel`, borderless, level 102 | Shows, and the window server puts it **front-most, above the menu's own window** (level 101) | MEASURED |
| `NSPopover` from a view inside the menu window | `isShown=true`, its window lands at level 101 and **in front of** the menu | MEASURED |
| Either one *receiving a click* | — | **UNMEASURED** — an injected click must name a `windowNumber`, so it proves nothing about which window the tracking loop would route a real click to; deciding it needs HID-level synthetic input, i.e. Accessibility permission |

So the in-view card was not chosen because the others are impossible. It was
chosen because it is the only one with **no unmeasured step**: it needs no
window, raises no click-routing question, and cannot outlive the menu — when
tracking ends the view goes away and the card goes with it. A panel would have
to be dismissed by hand on every path that closes the menu.

Two smaller negative findings, both of which cost a run:

- **`CGWarpMouseCursorPosition` is useless for measuring hover.** It moves the
  cursor and posts no event: the cursor landed on the cell and the view's state
  stayed `hoveredCell=nil`. `NSApp.postEvent` is the tool.
- **A lone injected `leftMouseUp` is discarded** by the tracking loop. Only the
  `leftMouseDown` + `leftMouseUp` pair reaches the view.
- **`willHighlight` fires *between* the hover and the click.** Clearing the card
  when the item loses its highlight reads like free insurance; it tore the card
  down before `mouseUp` could read which row was under the pointer, and killed
  the click path outright. Dismissal belongs to `mouseExited` alone. `--probe`
  caught this as a regression, which is the argument for the probe existing.

### Views do not clip — the clamp is a choice

The card is clamped inside the row. The first version of this README was going
to say that was forced, because a menu item view's drawing is clipped to its
frame. **It is not.** macOS 15 ships `NSView.clipsToBounds == false`: the
selftest paints two identical bands, one inside the frame and one 14pt below it,
and *both* survive into the bitmap.

That check originally passed for the wrong reason — it sampled the bitmap in
points while the bitmap is Retina, so it read an empty row and concluded
"clipped". A control band inside the bounds, which must be found for the result
to mean anything, is what exposed it. **Any negative pixel assertion in this
repo wants a positive control next to it.**

The clamp stays anyway: an overhanging card would paint over neighbouring menu
rows whose redraws we do not control, and whether the *menu window* clips it is
still unmeasured. Overhang is a lever the port may pull, not a fact it inherits.

### What this costs the contract

NewVertical-3 §3.3 keeps cells positional — tier and `isToday`, no date, no
name — and notes that a tooltip would need "either `windowStart` alongside the
cells or richer cells". **This took the richer-cells branch:** `DayCell` grew
`items: [WorkItem]`, each carrying title, kind, and a URL built with the
templates experiment 7 verified. Geometry stayed frontend; nothing about menu
widths leaked backward.

## Caveats

- Offscreen render ≠ the real menu: no vibrancy, no real NSMenu chrome. The
  live app is left running for the authoritative visual check.
- `screencapture` cannot photograph menus without the Screen Recording
  permission (measured: windows and menus silently omitted) — hence the
  `EXP9_RENDER` mode.
- Disposable by design. The real port into BrightspaceBar is a fresh
  implementation informed by these findings, not a copy of this code.

### Popup caveats (S7)

- **The card holds about three rows.** It must clear the row's title, which
  leaves ~73pt in a ~102pt row at a 20pt row height. A day with four or more
  items needs a taller course row, a scrolling card, or the overhang lever.
- **Card rows are drawn, not real menu items.** No VoiceOver, no keyboard
  navigation, no `NSMenuDelegate` signal per row. A production port owes
  accessibility a separate answer; `NSMenuDelegate` will not supply one.
- **Whether native tooltips are suppressed during tracking is still open.** The
  per-cell `addToolTip` registration and its logging callback are still in
  place, but `--probe` never dwells with a real pointer, so its silence proves
  nothing. It needs a human resting on a cell for a second.
- Cells that carry work are deliberately **not** tier-cyclable — the earlier
  click-to-cycle probe now applies only to empty days, so a cell's colour
  cannot come to disagree with the card listing its items.
- `artifacts/popup.png` is an offscreen render: real card, no menu chrome.
