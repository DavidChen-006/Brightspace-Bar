import Foundation
import Testing
import CoursePipeline
import AssignmentPipeline

// ═════════════════════════════════════════════════════════════════════════════
// DaemonAssignmentSource — one cache file, read per course, never spawned for.
//
// PRIORITY: correctness of the mapping across the two-language boundary. The
// daemon's item shape is NOT the Swift model's — `title` vs `name`, `kind` as a
// string vs `ItemKind`, a precomputed `url` Swift ignores, and two fields
// (`isHidden`, `groupTypeId`) the daemon does not send at all. Nothing in either
// language checks the other, so every one of those differences is a place where
// a silent wrong answer can appear: a quiz rendered with an assignment's deep
// link opens a page that does not exist.
//
// The second priority is cost. `fetchAssignments` is called once per visible
// course — 27 times on David's account — and all 27 answers are already inside
// the ONE `data.json` the course fetch just produced. A source that spawned the
// daemon per course would climb the ladder 27 times per refresh. That is pinned
// with a spawn counter rather than left to the reviewer's eye.
//
// SCOPE: small — reads a file from a temp `BSB_ROOT`. Only the no-spawn test
// starts a process, and that one is medium.
// ═════════════════════════════════════════════════════════════════════════════

private let scholarly = 440_703
private let civics = 412_690

@Suite("DaemonAssignmentSource — the cache, keyed by course")
struct DaemonAssignmentSourceTests {

    // MARK: - The mapping

    @Test("a course's assignments decode with every field mapped")
    func assignmentsDecode() async throws {
        // Arrange
        let world = DaemonWorld()
        world.seedCache(data: DaemonJSON.cache, status: DaemonJSON.freshStatus)

        // Act
        let items = try await world.assignmentSource().fetchAssignments(courseId: scholarly)

        // Assert — ids and names transcribed from experiment 7's live capture.
        #expect(items.map(\.id) == [445_296, 445_297, 529_524, DaemonJSON.quizID])
        #expect(items[0].name == "Upload your CITI Certificate to Complete Module 2")
        #expect(items[1].name == "Report on your PURC Experience.")
        #expect(items[2].name == "Getting Started on Scholarly Project Ideation")
        // `title` on the wire becomes `name` in the model. A decoder that kept
        // looking for `name` would find nothing and fail the whole course.
        #expect(items[3].name == DaemonJSON.quizName)
    }

    @Test("the course id is stamped from the request, not read from the payload")
    func theCourseIdIsStamped() async throws {
        // Arrange — the daemon keys items by course and does not repeat the id
        // inside them. An unstamped item renders a perfectly correct row that
        // opens course 0.
        let world = DaemonWorld()
        world.seedCache(data: DaemonJSON.cache, status: DaemonJSON.freshStatus)

        // Act
        let items = try await world.assignmentSource().fetchAssignments(courseId: scholarly)

        // Assert
        #expect(items.allSatisfy { $0.courseId == scholarly })
    }

    @Test("kind quiz becomes an item stamped .quiz, in the daemon's order")
    func quizzesKeepTheirKind() async throws {
        // Arrange — the fetcher merges assignments-first, then quizzes, and that
        // order is load-bearing: `MenuModel` is `Equatable` and drives the
        // skip-rebuild, so an order that varied between refreshes would repaint
        // the menu forever.
        let world = DaemonWorld()
        world.seedCache(data: DaemonJSON.cache, status: DaemonJSON.freshStatus)

        // Act
        let items = try await world.assignmentSource().fetchAssignments(courseId: scholarly)

        // Assert
        #expect(items.map(\.kind) == [.assignment, .assignment, .assignment, .quiz])
    }

    @Test("the daemon sends no visibility or group data, so neither is invented")
    func theFieldsTheDaemonDoesNotSendAreNeutral() async throws {
        // Arrange — `isHidden` and `groupTypeId` exist in the Swift model
        // because the network path preserved them; the daemon's contract drops
        // them. They must land on the neutral value, never on a guess: a `true`
        // here would hide rows the moment a display policy starts reading it.
        let world = DaemonWorld()
        world.seedCache(data: DaemonJSON.cache, status: DaemonJSON.freshStatus)

        // Act
        let items = try await world.assignmentSource().fetchAssignments(courseId: scholarly)

        // Assert
        #expect(items.allSatisfy { $0.isHidden == false })
        #expect(items.allSatisfy { $0.groupTypeId == nil })
    }

    @Test("a null due date stays nil rather than becoming an epoch")
    func aMissingDueDateIsNil() async throws {
        // Arrange — nil is the NORMAL case: every real assignment in every
        // reachable course has `DueDate: null`.
        let world = DaemonWorld()
        world.seedCache(data: DaemonJSON.cache, status: DaemonJSON.freshStatus)

        // Act
        let items = try await world.assignmentSource().fetchAssignments(courseId: scholarly)

        // Assert
        #expect(items[0].dueDate == nil)
    }

    @Test("an ISO-8601 due date decodes to the right instant")
    func aDueDateDecodes() async throws {
        // Arrange
        let world = DaemonWorld()
        world.seedCache(data: DaemonJSON.cache, status: DaemonJSON.freshStatus)

        // Act
        let items = try await world.assignmentSource().fetchAssignments(courseId: scholarly)

        // Assert — `2026-09-15T23:59:00Z`, computed independently with python3
        // and already pinned in `Truth`. This is the one shape the daemon emits
        // (it normalizes to whole seconds).
        #expect(items[3].dueDate == Truth.groupProjectDue)
    }

    @Test("a due date carrying fractional seconds still decodes")
    func fractionalSecondsAreAccepted() async throws {
        // Arrange — D2L is not consistent about them and this codebase has been
        // bitten twice by a strict parser. The daemon normalizes today; a
        // passthrough tomorrow must not cost a course its rows.
        let world = DaemonWorld()
        world.seedCache(
            data: DaemonJSON.oneItem("""
                { "id": 1, "title": "HW 3", "dueDate": "2026-03-01T04:59:00.000Z",
                  "url": "https://purdue.brightspace.com/x", "kind": "assignment" }
                """),
            status: DaemonJSON.freshStatus
        )

        // Act
        let items = try await world.assignmentSource().fetchAssignments(courseId: scholarly)

        // Assert
        #expect(items.first?.dueDate == Truth.homework3Due)
    }

    @Test("an unreadable due date costs the date, never the course")
    func anUnparseableDateIsSurvivable() async throws {
        // Arrange — the same asymmetry both existing parsers use: a missing id
        // or name is fatal, an unreadable date is one missing line.
        let world = DaemonWorld()
        world.seedCache(
            data: DaemonJSON.oneItem("""
                { "id": 1, "title": "HW 3", "dueDate": "next Tuesday",
                  "url": "https://purdue.brightspace.com/x", "kind": "assignment" }
                """),
            status: DaemonJSON.freshStatus
        )

        // Act
        let items = try await world.assignmentSource().fetchAssignments(courseId: scholarly)

        // Assert
        #expect(items.count == 1)
        #expect(items.first?.dueDate == nil)
    }

    @Test("the deep link Swift derives matches the one the daemon computed")
    func theTwoLinkBuildersAgree() async throws {
        // Arrange — the URL is built twice, once in Node and once in Swift, and
        // only the Swift one is ever clicked. Nothing else in either suite would
        // notice them drifting apart.
        let world = DaemonWorld()
        world.seedCache(data: DaemonJSON.cache, status: DaemonJSON.freshStatus)

        // Act
        let items = try await world.assignmentSource().fetchAssignments(courseId: scholarly)
        let derived = AssignmentLink.url(
            courseId: scholarly, assignmentId: items[0].id, baseURL: Truth.baseURL
        )

        // Assert
        #expect(derived.absoluteString == DaemonJSON.citiURL)
        #expect(derived.absoluteString == Truth.citiURL)
    }

    @Test("unknown item fields are ignored, not fatal")
    func futureFieldsDoNotBreakTheDecode() async throws {
        // Arrange — the daemon will grow fields; a decoder that rejects them
        // makes every daemon release a breaking one.
        let world = DaemonWorld()
        world.seedCache(
            data: DaemonJSON.oneItem("""
                { "id": 1, "title": "HW 3", "dueDate": null, "url": "https://purdue.brightspace.com/x",
                  "kind": "assignment", "points": 30, "submitted": false }
                """),
            status: DaemonJSON.freshStatus
        )

        // Act
        let items = try await world.assignmentSource().fetchAssignments(courseId: scholarly)

        // Assert
        #expect(items.map(\.id) == [1])
    }

    // MARK: - Empty, absent, and broken

    @Test("a course with an empty list has no work — that is data, not a failure")
    func anEmptyListIsData() async throws {
        // Arrange — the daemon writes `[]` for a course whose routes answered
        // and had nothing. `AssignmentsState.loaded([])` says exactly that.
        let world = DaemonWorld()
        world.seedCache(data: DaemonJSON.cache, status: DaemonJSON.freshStatus)

        // Act
        let items = try await world.assignmentSource().fetchAssignments(courseId: DaemonJSON.emptyCourseID)

        // Assert
        #expect(items.isEmpty)
    }

    @Test("a course absent from the map throws rather than reporting no work")
    func anAbsentCourseIsAFailure() async {
        // Arrange — the fetcher OMITS a course whose dropbox and quiz routes
        // both failed (`if (outcome.ok) assignments[course.id] = outcome.items`).
        // Absent therefore means "unknown", and answering `[]` would empty a
        // submenu that was showing real work a minute ago. Throwing folds to
        // `.failed(lastKnown:)`, which keeps it.
        let world = DaemonWorld()
        world.seedCache(data: DaemonJSON.cache, status: DaemonJSON.freshStatus)

        // Act
        let error = await courseSourceError {
            _ = try await world.assignmentSource().fetchAssignments(courseId: 999_999)
        }

        // Assert
        #expect(error?.isTransport == true, "got \(String(describing: error))")
    }

    @Test("a missing data.json throws transport")
    func aMissingCacheIsTransport() async {
        // Arrange — nothing has ever run: no file, no data. The
        // `FileSessionProvider` precedent maps a missing file to `.transport`.
        let world = DaemonWorld()

        // Act
        let error = await courseSourceError {
            _ = try await world.assignmentSource().fetchAssignments(courseId: scholarly)
        }

        // Assert
        #expect(error?.isTransport == true, "got \(String(describing: error))")
    }

    @Test("a corrupt data.json throws malformedBody")
    func aCorruptCacheIsMalformed() async {
        // Arrange
        let world = DaemonWorld()
        world.seedCache(data: "{ \"assignments\": { \"440703\": [", status: DaemonJSON.freshStatus)

        // Act
        let error = await courseSourceError {
            _ = try await world.assignmentSource().fetchAssignments(courseId: scholarly)
        }

        // Assert
        #expect(error?.isMalformedBody == true, "got \(String(describing: error))")
    }

    @Test("an item with no id fails the course rather than losing a row silently")
    func aMissingIdIsFatal() async {
        // Arrange — without an id the row can never be clicked, and a course has
        // a handful of items, so serving the rest is indistinguishable from an
        // instructor deleting them. Same rule as `AssignmentParser`.
        let world = DaemonWorld()
        world.seedCache(
            data: DaemonJSON.oneItem("""
                { "title": "HW 3", "dueDate": null, "url": "https://purdue.brightspace.com/x",
                  "kind": "assignment" }
                """),
            status: DaemonJSON.freshStatus
        )

        // Act
        let error = await courseSourceError {
            _ = try await world.assignmentSource().fetchAssignments(courseId: scholarly)
        }

        // Assert
        #expect(error?.isMalformedBody == true, "got \(String(describing: error))")
    }

    @Test("an item with no title fails the course")
    func aMissingTitleIsFatal() async {
        // Arrange — a nameless row renders blank.
        let world = DaemonWorld()
        world.seedCache(
            data: DaemonJSON.oneItem("""
                { "id": 1, "dueDate": null, "url": "https://purdue.brightspace.com/x",
                  "kind": "assignment" }
                """),
            status: DaemonJSON.freshStatus
        )

        // Act
        let error = await courseSourceError {
            _ = try await world.assignmentSource().fetchAssignments(courseId: scholarly)
        }

        // Assert
        #expect(error?.isMalformedBody == true, "got \(String(describing: error))")
    }

    @Test("an unrecognized kind fails the course rather than guessing a deep link")
    func anUnknownKindIsFatal() async {
        // Arrange — `kind` decides which of the two deep-link templates the row
        // opens. A third kind (a graded discussion, a checklist) defaulted to
        // `.assignment` would render a `db=` link to a page that does not exist,
        // and look completely normal doing it. Failing preserves the last known
        // list until the Swift side learns the new kind.
        let world = DaemonWorld()
        world.seedCache(
            data: DaemonJSON.oneItem("""
                { "id": 1, "title": "Week 3 Discussion", "dueDate": null,
                  "url": "https://purdue.brightspace.com/x", "kind": "discussion" }
                """),
            status: DaemonJSON.freshStatus
        )

        // Act
        let error = await courseSourceError {
            _ = try await world.assignmentSource().fetchAssignments(courseId: scholarly)
        }

        // Assert
        #expect(error?.isMalformedBody == true, "got \(String(describing: error))")
    }

    // MARK: - The status file speaks for the run that wrote the cache

    @Test("a needs-login status throws sessionExpired")
    func needsLoginIsSessionExpired() async {
        // Arrange — there is no exit code to read here, so `status.json` is the
        // only channel. Data from the last good run is still on disk and must
        // not be served as if it were fresh.
        let world = DaemonWorld()
        world.seedCache(data: DaemonJSON.cache, status: DaemonJSON.status("needs-login"))

        // Act
        let error = await courseSourceError {
            _ = try await world.assignmentSource().fetchAssignments(courseId: scholarly)
        }

        // Assert
        #expect(error?.isSessionExpired == true, "got \(String(describing: error))")
    }

    @Test("an error status throws transport")
    func anErrorStatusIsTransport() async {
        // Arrange
        let world = DaemonWorld()
        world.seedCache(
            data: DaemonJSON.cache,
            status: DaemonJSON.status("error", error: "the token mint answered HTTP 502")
        )

        // Act
        let error = await courseSourceError {
            _ = try await world.assignmentSource().fetchAssignments(courseId: scholarly)
        }

        // Assert
        #expect(error?.isTransport == true, "got \(String(describing: error))")
    }

    @Test("a missing status.json does not stop a good cache being read")
    func theStatusFileIsOptional() async throws {
        // Arrange — the data file is the payload, the status file is the report.
        let world = DaemonWorld()
        world.seedCache(data: DaemonJSON.cache)

        // Act
        let items = try await world.assignmentSource().fetchAssignments(courseId: scholarly)

        // Assert
        #expect(items.count == 4)
    }

    @Test("a corrupt status.json is tolerated, matching the daemon's own rule")
    func aCorruptStatusIsTolerated() async throws {
        // Arrange — phase 1 pinned the same tolerance on the writing side.
        let world = DaemonWorld()
        world.seedCache(data: DaemonJSON.cache, status: "{ not json")

        // Act
        let items = try await world.assignmentSource().fetchAssignments(courseId: scholarly)

        // Assert
        #expect(items.count == 4)
    }

    // MARK: - Freshness and cost

    @Test("the cache is re-read on every call")
    func everyCallReadsTheFileAgain() async throws {
        // Arrange
        let world = DaemonWorld()
        world.seedCache(data: DaemonJSON.cache, status: DaemonJSON.freshStatus)
        let source = world.assignmentSource()
        _ = try await source.fetchAssignments(courseId: scholarly)

        // Act — a daemon run lands while the app is up.
        world.seedCache(
            data: DaemonJSON.oneItem("""
                { "id": 42, "title": "Newly posted", "dueDate": null,
                  "url": "https://purdue.brightspace.com/x", "kind": "assignment" }
                """)
        )
        let items = try await source.fetchAssignments(courseId: scholarly)

        // Assert
        #expect(items.map(\.id) == [42])
    }

    @Test("fetching assignments never spawns the daemon")
    func assignmentsCostNothing() async throws {
        // Arrange — one real spawn, through the course source, exactly as a
        // refresh does. All 27 courses' answers are already in the file it wrote.
        let world = DaemonWorld()
        world.stage(data: DaemonJSON.cache, status: DaemonJSON.freshStatus)
        _ = try await world.courseSource().fetchCourses()
        let afterTheRefresh = world.spawnCount

        // Act — the fan-out.
        let source = world.assignmentSource()
        for courseId in [scholarly, civics, DaemonJSON.emptyCourseID] {
            _ = try? await source.fetchAssignments(courseId: courseId)
        }

        // Assert — a source that spawned per course would climb the login ladder
        // once per visible course, 27 times a refresh.
        #expect(afterTheRefresh == 1)
        #expect(world.spawnCount == 1, "an assignment fetch spawned the daemon")
    }
}
