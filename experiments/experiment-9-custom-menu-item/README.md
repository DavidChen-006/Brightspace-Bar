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
EXP9_RENDER=out.png ./.build/debug/Exp9   # offscreen render of the components
```

The dropdown holds native rows AND two custom components side by side, so the
difference is judged in one menu: hover the native `CS 17600` row, then hover
`Purdue Civics Knowledge Test` (strip + submenu) and `SCLA 10100` (7×16
GitHub grid with M/W/F + month labels).

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

## Caveats

- Offscreen render ≠ the real menu: no vibrancy, no real NSMenu chrome. The
  live app is left running for the authoritative visual check.
- `screencapture` cannot photograph menus without the Screen Recording
  permission (measured: windows and menus silently omitted) — hence the
  `EXP9_RENDER` mode.
- Disposable by design. The real port into BrightspaceBar is a fresh
  implementation informed by these findings, not a copy of this code.
