# Next Vertical Slice 3: The Course Component

The graph shipped (v1: a strip under each course). Seeing it run in stub mode
exposed what is actually wrong, and experiment 9 answered how to fix it. This
document is the resulting plan.

---

## 1. The bottleneck, and its answer

**Problem.** Hovering a course does not include its graph. The title is a
native `NSMenuItem` and the graph is a separate inert item below it, so they
can never highlight as one unit. No configuration fixes this.

**Answer (experiment 9, MEASURED).** A custom-rendered menu item — one
`NSMenuItem` whose `view` hosts the whole component — gives hover unity, and
**a plain `NSView` is enough**; RepoBar's SwiftUI hosting machinery is not
required to achieve it.

Everything AppKit refuses to do for a view-backed item turned out small:

| Piece | Who does it |
|---|---|
| Highlight capsule | Hand-drawn (inset 6/2, radius 6, `selectedContentBackgroundColor`) |
| Highlight signal | `NSMenuDelegate.menu(_:willHighlight:)` → flag on the view → `needsDisplay` |
| Click | `mouseUp` → `cancelTracking()` + `performActionForItem(at:)` |
| Submenu arrow | Hand-drawn chevron (RepoBar draws its own too) |
| Text/cell colors on hover | Hand-swapped; accent-on-accent is invisible otherwise |

**Cost of a view-backed row:** it replaces native rendering entirely. All or
nothing — which is why the boundary lines had to become their own rows (§3).

---

## 2. Issues this slice fixes

1. **Hover unity** — title + graph highlight together. The reason for the slice.
2. **The graph must always be present.** A missing strip is indistinguishable
   from a bug; an empty strip honestly says "nothing due." Mechanism:
   `GraphTranslation` emits the window for every state including
   `.neverFetched`, so the decision stays in the pure layer and the renderer
   never invents cells.
3. **Submenu uniformity** — every course gets at least `[Open Course Home]` +
   "No assignments". Two interaction models for identical-looking rows is
   confusing.
4. **Visual separation** — a grey line between courses, with breathing room.
5. **Grid, not strip** — a GitHub-style 7-row grid holds a full semester in
   the width a 28-day strip needs, and month + weekday labels resolve the
   read-rows-or-columns ambiguity.

---

## 3. Locked decisions

### 3.1 Boundaries are standalone hairline rows

A 1pt line, inset ~14pt from both edges, centred inside its own short inert
row (≈10pt tall) — the ChatGPT/RepoBar anatomy.

*Rejected:* drawing the line inside each component's own bounds. Measured
tradeoffs, both seen live in experiment 9:

| | In-component line | Standalone line row |
|---|---|---|
| Spacing | Glued to content; padding must be carved from the component's layout | Row height *is* the padding |
| Hover | Line sits inside the capsule; must be hidden while highlighted | Row is disabled; hover skips it |
| Stacking | Top+bottom lines double at every boundary | One line per boundary, explicit |
| Native rows | Impossible — they cannot draw without losing native rendering | Works for any row |
| Cost | Shorter menu description | Boundaries become structure you must place (fence-post cases are yours) |

The native-row row is decisive: a menu that mixes native and custom rows
**must** use standalone boundaries.

**Consequence for the real port:** the hairline becomes contract vocabulary —
a `MenuRow` case placed by the pure translation layer — not something a
component view decides.

**Colour caveat (MEASURED):** `NSColor.separatorColor` renders near-white in
dark menus and reads as a bright line. Experiment 9 uses a fixed
`NSColor(white: 0.5, alpha: 0.6)`; the real port needs a dynamic colour
(`NSColor(name:dynamicProvider:)`) so light mode does not get a heavy line.

### 3.2 Cell rendering: immediate mode, no cache, no per-cell objects

Five techniques were considered:

1. `NSRect.fill()` — paint freehand each draw
2. `NSBezierPath` — paint with a stencil (rounded corners, strokes, batched fills)
3. `CALayer` per cell — fridge magnets: stored, individually addressable
4. `NSView` per cell — magnets that are also doorbells: stored + interactive
5. Render once to `CGImage`, cache by fingerprint — photograph the mural

**Chosen: #2.** The governing rule is `derivation cost × read frequency`:
~112 rects of integer arithmetic, in a menu that is closed 99% of the time.
Both terms are tiny.

- *No stored cells (#3/#4)* — cells have no identity and no interaction, and
  data changes wholesale on refresh, so objects would be pure bookkeeping.
  Stored state can also drift from its source; derived state cannot.
- *No raster cache (#5)* — RepoBar's conditions (371 cells × N repos,
  redrawn on every hover/appearance/resize) do not hold here. **The one cache
  that earns its keep already exists at the right altitude: `MenuModel`'s
  `Equatable` skip-rebuild.** Its key is the whole model; its avoided cost is
  building dozens of menu items.
- *Rarely-changing assignments do not justify a cache.* Rare writes make a
  cache harmless, not worthwhile; value comes from expensive derivation ×
  frequent reads.

**If per-cell interaction is ever wanted** (hover a day for "Homework 3 — due
Sep 12"), the first move is still derivation: `cellRects()` is a pure
function, so hit-testing is a point-in-rect search over freshly computed
rects. Stored objects only become necessary for independent animation or
per-cell accessibility. **Explicitly out of scope for this slice.**

### 3.3 The contract stays 1-D and positional

The grid is an *interpretation of a list*, not a structure. RepoBar stores a
flat `[HeatmapCell]` and derives `column = i / 7, row = i % 7` at draw time;
the same array renders as a strip or a grid purely by changing that
arithmetic.

**Rejected: the backend emitting a 2-D array.** It reads convenient — indices
become cells for free — but it moves *geometry* into the backend. "16 weeks
instead of 4" or "strip instead of grid" would become a backend change, and
the pure mapping layer would know about menu widths.

The seam that keeps the frontend dumb without leaking shape:

> **Backend emits N cells; index = day offset from window start; the window
> starts on a week boundary and N is a multiple of 7.**

That promise is all a grid renderer needs. Semantic decisions (which day,
which tier, which is today) stay backend; geometry decisions (columns, cell
size, labels) stay frontend.

**Positional identity is confirmed** — `GraphCell` carries `tier` and
`isToday`, no date. Cheap to compare, tiny contract. The accepted cost: the
array is meaningless without the window start, so a future tooltip needs
either `windowStart` alongside the cells or richer cells.

### 3.4 Backend must compute the calendar — there is no endpoint for it

Experiment 8 already settled this: the D2L calendar route answers HTTP 200
for every course and window and returns **zero assignment due dates** (its
only events were three standalone announcements with `AssociatedEntity:
null`). There is no GitHub-style pre-bucketed calendar to fetch. Deadlines
come from `dropbox/folders/` and the quizzes route, and bucketing them into
days is ours to do — which is exactly what `GraphTranslation` already does.

### 3.5 Component structure: adopt Peter's layering, minus the measurement tax

Experiment 9 proved a plain `NSView` suffices *today*. But the component is
going to grow content whose height depends on width — long course names that
wrap, and later symbols/badges that reflow. That is precisely the case where
declarative layout beats manual frame arithmetic.

So the real port mirrors RepoBar's layering, with the seam in the same place
he put it:

```
NSMenuItem                        AppKit
└ MenuItemHostingView             AppKit    — adapter in; owns highlight + click
  └ CourseCardView                SwiftUI   — title now; badges/symbols later
    └ CourseGraphView             SwiftUI   — sizing + accessibility label only
      └ GraphRasterView           NSViewRepresentable — adapter back out
        └ GraphRasterNSView       AppKit    — the actual cells, drawn
```

Rationale, and it is Peter's own conclusion independently reached:
**SwiftUI wins for heterogeneous layout that reflows; direct drawing wins for
dense uniform geometry.** RepoBar bails out of SwiftUI for its heatmap for
exactly this reason — the cells are AppKit drawing in *both* designs. Only
the surroundings differ.

The intermediate SwiftUI layers start nearly empty, carrying the title and
comments naming what belongs there later (badges, due-count, status symbols).

**Known debt, accepted deliberately:** choosing SwiftUI means content no
longer reports a fixed height, so heights must eventually be *measured*
(`sizeThatFits` at a given width) rather than calculated. Deferred until a
real wrapping case exists; until then heights stay arithmetic. When it lands,
it is RepoBar's `measuredHeight` pattern: measure at width → pixel-round →
cache keyed by (width, content version) → write `view.frame`.

**Why height is a question at all:** a menu item is exactly as tall as its
view's `frame.height` — AppKit computes nothing and honours whatever you set
(a `.zero` frame renders an invisible row). Fixed content can be calculated;
wrapping content must be measured, because height genuinely depends on width.

---

## 4. Work the backend still owes

1. **Week-aligned window.** The window currently starts at *today*, so grid
   rows would not correspond to weekdays and labels would be wrong. Adopt
   RepoBar's `alignedRange` idea — flipped forward, injected clock, no
   `Date()` — so the window begins on a week boundary.
2. **Semester-length window.** `windowDays = 28` becomes ~16 weeks (112), a
   multiple of 7. A grid holds it in roughly the width the strip needed.
3. **Always emit the window** — `.neverFetched` yields empty cells, not `[]`
   (§2.2).

---

## 5. Rendering details not yet met

- **Coordinate system.** `NSView`'s y-axis runs bottom-up by default, so
  "row 0 at top" is `bounds.height - … - row * step`. Overriding `isFlipped`
  to `true` is a real alternative; `CourseComponentView` chose not to, which
  is why its layout reads as subtraction.
- **Draw order.** Today's outline must stroke *after* its fill, or the fill
  erases it.
- **Highlight palette swap.** Accent-coloured cells vanish against the accent
  capsule. RepoBar's fix — white-alpha cells + `selectedMenuItemTextColor`
  text while highlighted — is required, not cosmetic.
- **Labels.** M/W/F row labels and month column labels mean reserving a left
  gutter and a top row, so the cell origin is not the component's edge.
  MEASURED in experiment 9: a 16×7 grid with labels fits in ~330pt and reads
  clearly at 8pt cells.

---

## 6. What is taken from RepoBar, and what is not

**Taken:** the capsule metrics (6/2/6, radius 6), the hand-drawn chevron, the
white-alpha highlighted palette, separator-as-its-own-item, recompute the
window from `now`, `i / 7, i % 7`, the layering seam (§3.5), and — later —
the `measuredHeight` pattern.

**Not taken, with reasons that are all one rule (their machinery answers
scale problems we do not have):**

| Dropped | Why |
|---|---|
| Raster cache (CGImage, NSCache, FNV keys, generation counters) | Derivation is microseconds; menus are closed almost always |
| Count-bucketing into 5 intensity tiers | Ours is categorical (`CellTier`), not a scalar |
| 7×53 grid, backward window, draw-time date filtering | Ours is forward-looking and windowed upstream |
| Accent-tone settings plumbing | No preferences window exists |

**Written fresh, because the domain demands it:** the today marker (contribution
graphs have no concept of "now"), categorical tiers (commits are counts;
coursework has kinds), and weekday row labels.

---

## 7. Build order

```
1. COMPONENT VIEW — the hosting layering of §3.5, title only, hover unity,
   click, chevron. Replaces the standalone strip item.
                    ↓
2. BOUNDARIES — hairline as contract vocabulary + a dynamic grey.
                    ↓
3. BACKEND WINDOW — week alignment, semester length, always-emit (§4).
                    ↓
4. GRID + LABELS — cells, today outline, palette swap, M/W/F + months (§5).
                    ↓
5. POLICY FLIPS — always-present graph, submenu uniformity (§2.2, §2.3).
                   Cheap, independent, testable through existing suites.
```

Order matters: the component view comes first because the grid's labels and
dividers live inside it — building grid rendering into the current standalone
strip item would be work thrown away immediately.

**Test consequences (seam S6):** the standalone strip item disappears into the
component, so `MenuAssemblerGraphTests`' assertions relocate rather than die
("course item + strip item" becomes "course item whose view carries the
cells"). The newly hand-owned surfaces — highlight delegate, `mouseUp`
forwarding, chevron — are plain methods and are testable headless.
