# Experiment 4 — The course pipeline: parse → cache → poll

## What this proves

That everything between "we have a JWT" and "a menu could render this" works, with
**zero GUI**. Three concerns, each built as a functional core with side effects at the
edge, each swappable between a scriptable fake and the real Brightspace tenant.

Prior experiments already established the ground truth, so none of it is in question here:

| Fact | Established by |
|---|---|
| Cookie → JWT is a plain HTTP POST, no browser | Exp 2 (green) |
| JWT lasts exactly 3600 s, no refresh token | Exp 2 |
| `myenrollments` returns 27 courses, 14,938 bytes | Exp 2, re-confirmed Exp 3 |
| No `ETag` / `Last-Modified`; `cache-control: no-cache, no-store` | Exp 3 (green) |
| Dead session on the **mint** = HTTP 200 + HTML stub | Exp 2, fixture captured |
| Bad JWT on the **API** = honest 401 + `problem+json` | fixture captured |

## Ground rules — all agents

1. **Work only inside `/Users/davidchen/PaperShelf/experiment-4-course-pipeline/`.** You may
   READ `../brightspace-mcp-server/`, `../experiment-1-fresh-cookie/`,
   `../experiment-2-cookie-to-jwt/`, `../experiment-3-etag-probe/`, and `../RepoBar/`.
   Never write outside this folder. The folder must stay deletable with no collateral damage.
2. **`Sources/CoursePipeline/Contracts.swift` is frozen.** Three concerns are being built
   in parallel against those declarations. Do not edit it. If you believe it is wrong,
   say so in your report and work around it — do not unilaterally change a shared seam.
3. **Swift 6.2, macOS 15, SPM, `swift-testing` (`import Testing`). Zero external
   dependencies** — swift-testing ships with the toolchain, so `Package.swift` needs no
   `dependencies` array. Do not add one.
4. **Nothing in `Sources/` may call `Date()`, `Date.now`, or `DispatchQueue.main.asyncAfter`
   directly.** Take the `Clock` protocol. Tests must never `sleep`. Time is an input.
5. **GET only** against `/d2l/api/**`. The single permitted POST is the token mint.
6. **Never log or commit the cookie, the CSRF token, or a JWT body.** JWT length only.
   Do not copy `session.json` into this folder.
7. Run `swift build` and `swift test` from the package root. **Do not run `swift build`
   while another agent is building** — the orchestrator sequences you; stay in your lane.

## Fixtures — real, captured from the live tenant

Under `Tests/CoursePipelineTests/Fixtures/`. Use these; do not invent payload shapes.

- **`myenrollments-200.json`** (14,938 B) — the genuine success body. 27 items.
  `PagingInfo` is `{"Bookmark":"1498777","HasMoreItems":false}`.
  Each item is `{ OrgUnit, Access, PinDate }` where
  `OrgUnit = { Id, Type{Id,Code,Name}, Name, Code, HomeUrl, ImageUrl }` and
  `Access = { IsActive, StartDate, EndDate, CanAccess, ClasslistRoleName, LISRoles, LastAccessed }`.
  Note the MCP's `EnrollmentItem` interface in `../brightspace-mcp-server/src/tools/get-my-courses.ts`
  is **incomplete** — it omits `HomeUrl`, `ImageUrl`, `PinDate`, `CanAccess`, `LISRoles`.
  Trust the fixture over that interface.
- **`session-expired-stub.html`** (294 B) — what the token mint returns for a dead
  session, at **HTTP 200**. Contains `sessionExpired=1`.
- **`bogus-bearer-response.txt`** — `STATUS 401` plus the RFC 7807 body.

## Concern 1 — Parsing

**Module:** `Sources/CoursePipeline/EnrollmentParser.swift`

**Frozen seam:**
```swift
public struct EnrollmentParser: Sendable {
    public init()
    public func parse(_ data: Data) throws -> [Course]
}
```

Pure. No I/O, no clock, no network. `Data` in, `[Course]` out, or throws
`CourseSourceError`.

The end-to-end test must cover at minimum:

- the real fixture parses to **exactly 27** courses, and a named spot-check matches
  (id `412690`, code `wl.nc.civics.test`, `homeUrl` ending `/d2l/home/412690`)
- `homeUrl` is preserved **exactly as sent, including nulls**. Measured ground truth:
  `OrgUnit.HomeUrl` is non-null in only **2 of 27** items (`412690`, `440703` — both
  non-semester shell courses); every real class is `null`. An earlier draft of this SPEC
  wrongly asserted it was always populated. **The parser must not synthesize it.**
  `OrgUnit.ImageUrl` is non-null 27/27 and embeds the same `Id`, so deriving
  `{baseUrl}/d2l/home/{id}` is sound — but that is a click-layer policy decision, not the
  job of a parser whose contract is faithful preservation. The app's click action must
  derive from `id`, not read `homeUrl`.
- the `session-expired-stub.html` bytes throw `.sessionExpired` — **not**
  `.malformedBody`, and emphatically not an empty array
- truncated JSON (first half of the fixture) throws `.malformedBody`
- valid JSON of the wrong shape (`{"foo":1}`) throws `.malformedBody`
- empty `Data()` throws `.malformedBody`
- `{"Items":[]}` returns `[]` successfully — a real user with no courses is not an error,
  and this case must be distinguishable from the stub case above
- an item missing a required field is handled per a decision you state and defend
  (skip the item, or fail the whole parse — pick one, document why, test it)
- unknown/extra JSON keys are ignored rather than causing failure (D2L will add fields)

## Concern 2 — Caching

**Module:** `Sources/CoursePipeline/CourseCache.swift`

**Frozen seam:**
```swift
public actor CourseCache {
    public init(fileURL: URL, clock: Clock, staleAfter: TimeInterval)
    /// Read the persisted list off disk. Never throws — a missing or corrupt file
    /// is an empty cache, not a crash.
    public func load() async
    public var courses: [Course] { get }
    public var lastFetch: Date? { get }
    public var isStale: Bool { get }
    /// Fold a fetch result in. Returns what happened; see `CacheOutcome`.
    public func apply(_ result: Result<[Course], CourseSourceError>) async -> CacheOutcome
}
```

Persist as JSON, written **atomically** (`.atomic` — RepoBar does exactly this at
`RepoDetailCacheStore.swift:57`; read it). File holds the courses plus `fetchedAt`.

The end-to-end test must cover at minimum:

- cold start, no file → `courses == []`, `lastFetch == nil`, `isStale == true`
- warm start → `load()` restores the previous list and `lastFetch`
- `apply(.success(same))` → `.unchanged`, and **the file's mtime does not change**
  (proving no needless rewrite)
- `apply(.success(different))` → `.updated`, file rewritten, `lastFetch` advanced
- 27 → 26 courses → `.updated`, and the dropped course is gone. **This is the case the
  real backend physically cannot produce** — it is the reason a fake exists
- `apply(.failure(.sessionExpired))` → `.preservedStale`, **courses unchanged**,
  `lastFetch` NOT advanced, file untouched. The regression this guards is a blank menu
  that persists to disk
- same for `.failure(.transport)` and `.failure(.httpStatus(500))`
- `apply(.success([]))` → `.updated` with an empty list. A genuinely empty enrollment is
  legitimate; only *failures* preserve stale data. Prove these two paths differ
- corrupt file on disk (truncated JSON, then valid JSON of the wrong shape) → `load()`
  yields an empty cache, no crash, no throw
- staleness purely as a function of the injected clock: at `staleAfter - 1`s not stale,
  at `staleAfter + 1`s stale. **No sleeping**
- each test uses its own temp directory and cleans up

## Concern 3 — Polling

**Modules:** `Sources/CoursePipeline/PollPolicy.swift` (pure) and
`Sources/CoursePipeline/Poller.swift` (shell)

**Frozen seam:**
```swift
public struct PollPolicy: Sendable {
    public init(interval: TimeInterval)
    /// The whole decision, as a pure function. No clock, no state, no I/O.
    public func shouldFetch(trigger: PollTrigger, lastFetch: Date?, now: Date) -> Bool
}
```

`Poller` is the imperative shell: it owns a `CourseSource` and a `CourseCache`, asks
`PollPolicy`, and on a yes calls the source and folds the result into the cache. It must
expose something a test can drive one tick at a time — no real timers in tests.

Required policy behaviour (state and defend anything else):

- `.manual` always fetches, even one second after the last one. A user who clicks
  Refresh gets a fetch
- `.launch` fetches when `lastFetch == nil`
- `.menuOpened` and `.timer` fetch only when older than `interval`
- boundary: exactly `interval` old — pick inclusive or exclusive, document, test
- a `lastFetch` in the future (clock skew, laptop sleep) must not wedge the poller
  permanently

The end-to-end test must cover at minimum:

- **the real end-to-end chain**: `FakeCourseSource` → `Poller` → real `EnrollmentParser`
  bytes → real `CourseCache` → assert the cache holds 27 courses. This is the whole
  vertical minus the GUI, and it is the headline assertion of this experiment
- a failing source leaves a previously-good cache intact
- two ticks inside one interval produce exactly **one** source call (assert a call count
  on the fake — this is what "polling works" actually means)
- a tick after the interval produces a second call
- source returns 27, then 26 → cache ends at 26
- source succeeds, then fails, then succeeds → cache goes 27, holds 27, then updates
- `.manual` bypasses the interval
- concurrent triggers do not produce overlapping in-flight fetches (state your
  concurrency decision and test it)

**`FakeCourseSource`** lives in the test target, conforms to `CourseSource`, and must be
scriptable: queue up successes, failures, and raw fixture bytes; count calls; optionally
delay. Keep it small.

## Contract tests — the anti-drift rule

A fake that drifts from reality gives you a green suite and a broken app. So write the
`CourseSource` behavioural assertions **once**, parameterised over the source, and run
them against both the fake and the real adapter.

The real-adapter run is an integration test gated on an env var (swift-testing
`.enabled(if:)`), so `swift test` stays hermetic and offline by default:

```
BS_LIVE=1 swift test
```

## Concern 3.5 — The real adapter (built after the three are green)

`Sources/CoursePipeline/BrightspaceCourseSource.swift`, conforming to `CourseSource`:
mint a JWT from a cookie + CSRF token, GET `myenrollments`, hand the bytes to
`EnrollmentParser`. A direct port of `../experiment-2-cookie-to-jwt/src/mint-and-call.mjs`
— read it rather than reinventing. Guard the mint's 200-stub case. Reads its session from
`SESSION_JSON` (default `../experiment-1-fresh-cookie/artifacts/session.json`).

Verified by exactly one live run, not by unit tests.

## Definition of done

1. `swift test` green offline, with no network access and no `session.json` present.
2. All three concerns' end-to-end suites green, including every case listed above.
3. `BS_LIVE=1 swift test` green against the real tenant, proving the fake did not drift.
4. `README.md`: the commands, the module layout, the policy decisions and their
   rationale, and a short **Findings** section.
5. No file outside this folder written.
