# Next Vertical Slice: Course Activity Graph

The next vertical slice created by adding quizzes is the **graph**.

RepoBar has a GitHub-style activity graph; Brightspace Bar needs the same idea
pointed at the future instead of the past: cells represent upcoming assignments
and quizzes rather than past commits. The quiz slice (shipped, `2c1e598`) is what
makes this possible — the code now distinguishes the two kinds via `ItemKind`,
and that distinction needs to exist visually in the GUI.

---

# Core Goal

For every course in the main menu, display an activity graph underneath the
course name, representing upcoming course work based on:

- due date
- activity type (assignment vs quiz, extensible to tests later)
- current date

Today's cell must be clearly indicated without obscuring its activity state.

---

# Locked-In Design Decisions

These came out of the design review. They are decided; the stages below build on
them.

## 1. The cell data structure — highest tier wins

A day with both an assignment and a quiz renders as the more important kind.
This is a ranked enum, not an intensity scale:

```swift
// Lives in CourseMenu (the contract cannot import AssignmentPipeline;
// MenuAdapter maps ItemKind → CellTier, like every other contract value).
public enum CellTier: Int, Comparable, Equatable, Sendable {
    case assignment = 1
    case quiz = 2
    // a future `case test = 3` slots in with no other change

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct GraphCell: Equatable, Sendable {
    public let tier: CellTier?    // nil = empty day
    public let isToday: Bool      // orthogonal — see below
}
```

The fill rule is one expression in the mapping:

```text
itemsDueThatDay.map(\.tier).max()
```

Assignment + quiz on the same day → `.quiz` because `2 > 1`. Nothing due → `nil`.

## 2. Today's cell — an outline, orthogonal to the fill

`isToday` is a separate field, never a fill value. The renderer draws fill from
`tier` and the outline from `isToday` independently, so the invariant

> the today indicator must not destroy or obscure the underlying activity state

holds by construction and is trivially testable in the pure layer.

```text
normal cell:      today:
                  ╔═╗
[■]               ║■║
                  ╚═╝
```

## 3. The window — borrow RepoBar's shape, flipped forward

RepoBar's window logic (`HeatmapSpan.swift` / `HeatmapFilter`) is the right
structure to take: a pure function `range(span:now:calendar:)` returning a
`{start, end}` pair, plus a one-liner `filter(cells, range)`. The window "shifts"
with the date automatically because the range is recomputed from `now` on every
translation — there is no stored state to move.

Two mandatory adaptations:

- **Flip the direction.** RepoBar looks backward (trailing contributions); ours
  looks forward (today → +N, upcoming work). One sign change.
- **Map onto this codebase's style.** RepoBar writes `now: Date = Date()` as a
  defaulted parameter. That defaulted `Date()` is illegal here — nothing calls
  `Date()` except `SystemClock`. The port takes `now` and `timeZone` as required
  parameters, which `MenuTranslation` already receives and threads through. That
  is what makes the window logic testable with `TestClock` like everything else.

Timezone rule: due dates arrive as UTC instants; cells are **local calendar
days**, bucketed via the injected `timeZone`. Test the 11 PM-due-date boundary —
it is the classic off-by-one.

## 4. The fake boundary — the seam already exists

The feared problem — "jam fake data between the endpoint returning and the
parser, with test scaffolding polluting production" — does not exist in this
codebase. Nothing downstream of the fetch knows HTTP exists: `Poller`,
`CourseCache`, `AssignmentFetcher`, `AssignmentStore`, and `MenuTranslation` all
consume the `CourseSource` / `AssignmentSource` **protocols** and receive plain
`[Course]` / `[Assignment]` values. `BrightspaceCourseSource` is just one
conformance; the entire network path lives inside it.

So: no interception, no fake server, no transport seam. Fakes are additional
conformances of production protocols, chosen once in `main.swift` (the
composition root, the one file allowed to see everything) under a dev flag —
exactly how `BRIGHTSPACEBAR_STUB=1` already picks `StubMenuDataSource` today.
Production code never branches on them. Proof the seam is load-bearing
architecture rather than test scaffolding: `CompositeAssignmentSource` shipped
through it as a production feature, and the future WKWebView login is another
planned swap at the same kind of seam (`SessionProviding`).

Two fakes at two existing boundaries, for two different jobs:

| Fake | Boundary | Used for |
|---|---|---|
| `StubMenuDataSource` (exists) seeded with `GraphCell`s | contract level — hands the GUI a finished `MenuModel` | Stage 2: iterating on the renderer |
| `SeededCourseSource` / `SeededAssignmentSource` (new, ~40 lines each) | source level — plain values, dates relative to the injected now | Stage 5: E2E — real store, real fetcher, real mapping, fake network only |

**Shape fidelity is owned elsewhere and already solved**: the parsers are tested
against real captured bytes (`dropbox-folders-440703.json`,
`quizzes-412690.json`, and the `*-with-due-date.json` variants), and `BS_LIVE=1`
contract tests catch drift if Brightspace changes shape. The seeded fakes do not
go through the parser, and that is fine — every line of new graph code sits
downstream of the values boundary, so the seeded source exercises 100% of the
new feature. Rebuilding the server, a local HTTP fake, or a mock client would
all fake a boundary the existing seams make unnecessary.

Fixture dates drifting out of the window over time is solved by the injected
clock: tests pin `TestClock` to the fixtures' era; only the live stub seeds
dates relative to real today.

## 5. The RepoBar port — much thinner than it looks

`HeatmapRasterNSView` is ~540 lines and roughly 450 of them are performance
machinery (async CGImage rendering, `NSCache`, render-key memoization, pixel
snapping, generation counters) for redrawing 371-cell year grids across many
repos. Brightspace Bar has ~6 courses × a few dozen cells. **Do not port the
raster engine.** A plain `draw(_:)` filling rects is sufficient.

Worth taking:

- The `NSMenuItem.view` hosting technique (`MenuItemHostingView`) — the real new
  GUI capability Brightspace Bar lacks; `MenuAssembler` currently builds plain
  text items, and highlight-state handling inside menu item views is the fiddly
  part RepoBar already solved.
- The window/range logic shape (decision 3 above).
- The layout math *ideas* (`HeatmapLayout`, ~80 pure testable lines) — as
  structure, not code, and only the parts the chosen orientation needs.
- The palette-per-appearance *structure* (light/dark/highlighted) — not the
  palette itself, because RepoBar maps a scalar count into 5 intensity buckets
  and ours maps a category (`CellTier`), a fundamentally different function.

Everything taken from RepoBar gets mapped onto this codebase's style: pure
decision functions, injected clock and timezone, plain `Equatable` contract
values, effects at the edges.

## 6. Where the pieces live

- `CourseMenu`: `MenuModel` gains a per-course `[GraphCell]` — plain `Equatable`
  values like everything else there (which also preserves the
  skip-rebuild-on-unchanged behavior for free).
- `MenuAdapter` / `MenuTranslation`: the pure date→cell mapping. No new module —
  this is the same shape of responsibility `MenuTranslation` already owns
  ([Course] + items + now + timeZone → menu values), and it is small. A new
  module only if it visibly outgrows that.
- `BrightspaceBar`: the cell-drawing view and `NSMenuItem.view` wiring.

---

# The One Decision Still Open: Orientation

The mockups show a single-row strip:

```text
Course A
[ ][ ][■][ ][□][ ][ ][...]
```

GitHub uses a 7-row week grid. For "upcoming few weeks" in a narrow menu item
the strip is probably right, and it makes RepoBar's 7×53 grid math mostly
irrelevant. Decide this consciously during the stage-2 renderer investigation —
it determines which RepoBar layout code even applies, and whether the window's
start should be week-aligned.

---

# Dependency Graph (updated)

Still sequential — each step unlocks the next. But stage 1 shrank: it is no
longer "design a Brightspace test double" (that question is answered above), it
is "seed the existing stub."

```text
0. QUIZ SLICE — DONE (2c1e598; ItemKind, CompositeAssignmentSource, QuizPipeline)
                    ↓
1. SEED THE STUB
   StubMenuDataSource gets deterministic today-relative items
   (today → assignment, tomorrow → quiz, +3 → assignment, +5 → quiz,
   one day with BOTH kinds to prove highest-tier-wins visually).
                    ↓
2. FRONTEND RENDERER
   Port the NSMenuItem.view hosting technique from RepoBar; plain
   draw(_:) cells; fill from tier, outline from isToday.
   Decide strip vs grid here. Verify visually via BRIGHTSPACEBAR_STUB=1.
                    ↓
3. INTERFACE / SCHEMA
   Mostly decided already (GraphCell, CellTier, window shape).
   What remains: span length, cell count, and whatever the renderer
   investigation revealed about layout needs.
                    ↓
4. BACKEND MAPPING
   Pure logic in MenuTranslation: items + now + timeZone → [GraphCell].
   Window range computed fresh each translation (RepoBar's shape, flipped
   forward, injected clock). Local-day bucketing; highest-tier-wins;
   isToday stamped.
                    ↓
5. FINAL WIRING + E2E
   SeededCourseSource / SeededAssignmentSource behind a dev flag in
   main.swift. Extend the existing MenuAdapter EndToEndTests pattern
   (fixtures → parser → store → translation) to assert graph cells at the
   MenuModel boundary, with TestClock pinned. The last visual inch is
   human-verified via the seeded modes, consistent with how the app has
   been verified so far.
```

---

# End-to-End Test

The E2E lands at the `MenuModel` boundary by extending
`MenuAdapter/Tests/EndToEndTests`, which already runs fixtures → parser → store
→ translation. It begins red at stage 3–4 and goes green at stage 5. It proves:

```text
seeded/fixture course data
      ↓
assignments + quizzes parsed (fixtures) or seeded (values)
      ↓
correct local-day bucketing under the injected timeZone
      ↓
highest tier wins on multi-kind days
      ↓
window range is correct for the pinned TestClock date
      ↓
today's cell carries isToday without losing its tier
      ↓
the course's MenuModel carries the expected [GraphCell]
```

Rendering itself (strip drawing, outline, palette) is verified visually with
the deterministic stub seeds, where the expected picture is known in advance.

---

# Honest Caveat

Real courses currently have `null` due dates, so in production this graph will
render empty until instructors set deadlines. That does not argue against
building it now — but it means the seeded modes remain the only way to *see* it
working for a while, so the stub seeding is worth keeping good.
