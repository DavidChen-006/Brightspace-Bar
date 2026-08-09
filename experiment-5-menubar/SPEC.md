# Experiment 5 — BrightspaceBar: the menu bar app

The thin vertical's last mile. An icon in the macOS menu bar; click it; see your classes.

## Why there is no Flask or FastAPI

The question came up, so it is answered here permanently. Those are Python HTTP
servers. Using one would mean shipping a Python process inside a menu-bar app,
binding a localhost port, and having the dropdown break whenever the server is not
running — worse on every axis.

**The API is a Swift protocol plus `Sendable` value types, in-process**, exactly as
RepoBar does it (`RepoBarCore` ← `RepoBar`). Schema design is the same discipline;
the schema is expressed in types instead of JSON. `MenuModel` *is* the response body.

## The contract — frozen

`Sources/CourseMenu/` is the whole API surface between backend and GUI:

- `MenuModel` — `rows: [MenuRow]`, `Equatable`, `Sendable`
- `MenuRow` — `.course`, `.sectionHeader`, `.message`, `.status`, `.separator`, `.command`
- `CourseRow` — `id`, `title`, `subtitle?`, **non-optional `url`**
- `MenuCommand` — `.refresh`, `.quit`
- `MenuDataSource` — `currentMenu()` (cheap, no network) and `refresh()` (may do I/O)
- `StubMenuDataSource` — seeded realistic data so the GUI runs with no backend

**The architectural rule that makes this work: `BrightspaceBar` depends on
`CourseMenu` only.** It cannot import `Course`, `CourseSource`, `URLSession`, cookies,
or JWTs — `Package.swift` does not give it access. So the GUI is genuinely developed
against the contract, and backend detail cannot leak into view code later.

Three deliberate decisions worth knowing:

- **`CourseRow.url` is non-optional.** D2L's `OrgUnit.HomeUrl` is null for 25 of 27 real
  enrollments, so the backend must derive `{baseUrl}/d2l/home/{id}` *before* building a
  row. A row therefore cannot exist without a working click target, and the GUI needs no
  "what if there's no URL" branch.
- **`MenuCommand` is data, not a closure**, so `MenuModel` stays `Equatable` — which is
  what lets the app skip rebuilding an unchanged menu.
- **`MenuModel.placeholder` is not empty.** A dropdown with zero rows reads as a crashed
  app, so even "nothing to show" carries a message and a way out.

## Phase 2 — the GUI, against stubs only

### The seam to build (fixed here so the test writer and builder agree)

```swift
/// Opening a URL is a side effect. Inject it so clicks are assertable.
public protocol URLOpening: Sendable {
    func open(_ url: URL)
}

/// MenuModel → NSMenu. Owns no status item and no app lifecycle, which is precisely
/// what makes it testable in a plain test process.
@MainActor
public struct MenuAssembler {
    public init(opener: any URLOpening, onCommand: @escaping @MainActor (MenuCommand) -> Void)
    public func assemble(_ model: MenuModel) -> NSMenu
}
```

**`MenuAssembler` must never touch `NSStatusItem`.** `NSMenu` can be constructed and
inspected in a unit test; `NSStatusItem` requires a real UI session and would make the
suite unrunnable headless. Keep the status item in a separate `StatusBarController`
that the unit tests do not import — it is covered by the launch smoke test instead.

### What the GUI mechanics tests must cover

Mechanics only. Nothing about networks, cookies, or the real backend.

- row count and order match the model, one `NSMenuItem` per `MenuRow`
- `.course` renders `title` and, when present, `subtitle`; a nil `subtitle` must not
  print `nil` or crash. **You choose the exact display format — document and pin it.**
- `.separator` produces `NSMenuItem.isSeparatorItem == true`
- `.sectionHeader`, `.status`, and `.message` are **not selectable** (disabled, no action)
- `.command` rows are enabled and carry an action
- clicking a course row calls `URLOpening.open` **once**, with that row's exact URL
- clicking the row for course *n* opens course *n*'s URL — not an off-by-one neighbour.
  Use at least three courses so an index bug cannot pass by luck
- `.refresh` and `.quit` invoke `onCommand` with the matching case
- `MenuModel.placeholder` yields a menu with rows, never zero
- assembling the same model twice yields structurally equal menus (determinism)
- a model with 27 courses assembles without truncation

### Bundling — already proven, do not re-litigate

`swift build` emits a bare Mach-O executable; macOS will not treat that as an app. The
minimum viable bundle is `Contents/MacOS/<exe>`, `Contents/Info.plist`, and an ad-hoc
signature. `Scripts/run.sh` does exactly that and is already written and working.

`Package.swift` embeds `Info.plist` into `__TEXT,__info_plist` via
`-Xlinker -sectcreate` — RepoBar's trick (`Package.swift:54-57`) — so the binary carries
`LSUIElement` without an Xcode project. Verified working in a scratch proof: both a bare
executable and an assembled bundle install a status item and stay alive.
`NSApplication.setActivationPolicy(.accessory)` gives the no-Dock-icon behaviour at
runtime as well.

### Definition of done for phase 2

1. `swift test` green, including every case above.
2. `./Scripts/run.sh --smoke` passes — builds, bundles, launches, still alive after 3 s.
3. `./Scripts/run.sh` puts a **real icon in the menu bar** that opens a dropdown listing
   the seeded stub courses, and clicking one opens Brightspace in the browser.
4. No dependency added to `Package.swift`. RepoBar's eleven are for avatars, GraphQL,
   Sparkle, and SQLite — none of which this needs. Custom-drawn rows are a later
   concern; plain `NSMenuItem` titles get correct highlighting and sizing for free.

Follow RepoBar for **architecture and style** — `@MainActor` isolation, `self.`
qualification, small focused files, `MenuStyle`-type constants over magic numbers — while
taking none of its dependencies and none of its `NSHostingView` row-hosting machinery.

## Phase 3 — wiring

An adapter target bridges the two packages. Only at this point does
`experiment-4-course-pipeline` enter `Package.swift`, as `.package(path:)`.

```
CourseMenu ← BrightspaceBar
     ↑
MenuAdapter → CoursePipeline (Poller, CourseCache, BrightspaceCourseSource)
```

The adapter conforms to `MenuDataSource` and owns the one translation the contract
deliberately excludes: `[Course] → MenuModel`, including deriving each `url` from `id`,
grouping by term, and formatting the `.status` freshness line.

The end-to-end test is written **first**, from a success story stated in plain language,
against the real 27-course data.

Wiring code must carry comments marking every seam, so the join between frontend and
backend is obvious on inspection.

### The success story — plain language, then assertions

> David clicks the book icon in his menu bar. His Purdue courses are listed, newest term
> first, each showing its course code and name. He clicks *Data Engineering* and
> Brightspace opens to that course. He quits and relaunches: the menu appears instantly
> with the same courses, before the network has answered. Later, offline, he clicks the
> icon — his courses are still there, with a line telling him how stale they are.

Each sentence is a testable claim:

| Story | Assertion |
|---|---|
| "courses are listed" | 27 `.course` rows from the real fixture bytes |
| "newest term first" | term-code order descending; untermed courses last |
| "code and name" | row title is `CS 17600 — Data Engineering` shape |
| "clicking opens that course" | row URL is `{baseUrl}/d2l/home/{id}` for that id |
| "appears instantly" | `currentMenu()` performs no network call |
| "before the network answered" | a cold `currentMenu()` returns `.placeholder`, never zero rows |
| "still there, offline" | after a failing refresh, the previous courses remain |
| "how stale they are" | a `.status` row is present and reflects `lastFetch` |

### The seams to build

```swift
/// The pure heart of the wiring, and where every data assertion lands.
public enum MenuTranslation {
    public static func menu(
        courses: [Course], lastFetch: Date?, now: Date, baseURL: URL
    ) -> MenuModel
}

/// The shell: owns experiment 4's Poller + CourseCache, conforms to the contract.
public actor MenuAdapter: MenuDataSource {
    public init(poller: Poller, cache: CourseCache, baseURL: URL, clock: any Clock)
    public func currentMenu() async -> MenuModel
    public func refresh() async -> MenuModel
}

/// Production `Clock`. Experiment 4 defines the protocol but ships no concrete clock,
/// because nothing in it was allowed to call `Date()`.
public struct SystemClock: Clock { public var now: Date { Date() } }
```

`MenuTranslation` is where `url` gets derived from `id` — the contract makes
`CourseRow.url` non-optional precisely to force that here rather than in view code.

### Term grouping — and the label we are NOT inventing

Course codes look like `wl.202510.CS.17600.LE1`; the second component is the term. Five
appear in real data (`202510`, `202520`, `202530`, `202610`, `202620`), and four courses
have no term at all (`stars_2025`, `scholarly_project_milestones`,
`honors_college_orientation_2024`, `wl.nc.civics.test`).

**Group by term code, sorted descending, untermed courses last under a final group.**
Do **not** map `202610` to "Fall 2025" or similar: Purdue's term encoding has not been
verified here, and a confidently wrong term name is worse than a raw code. Use the code
itself as the header, or a neutral label. If someone later confirms the encoding, that is
a one-function change inside `MenuTranslation`.

### Definition of done for phase 3

1. The end-to-end test is green.
2. `./Scripts/run.sh` shows the **real** classes from the live tenant in the dropdown.
3. `swift test` still passes hermetically — the GUI and contract suites must not acquire
   a network dependency. The live end-to-end case is gated on `BS_LIVE`, as in
   experiment 4.
4. **Architecture is enforced, not just intended.** A test asserts that no file under
   `Sources/BrightspaceBar/` except `main.swift` imports `MenuAdapter` or
   `CoursePipeline`. `main.swift` is the composition root and is allowed to see both
   sides; view code is not. Swift cannot express this, so a test does.
5. Wiring code carries comments marking every seam, so the frontend/backend join is
   obvious on inspection.
