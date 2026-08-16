import Foundation
import Testing
import CoursePipeline
import AssignmentPipeline

// ═════════════════════════════════════════════════════════════════════════════
// DaemonAnnouncementSource — the same cache file, read for a different section.
//
// PRIORITY: correctness of the mapping across the two-language boundary, the
// same priority `DaemonAssignmentSourceTests` defends and for the same reason —
// nothing in either language checks the other. What is different is WHERE the
// mapping can go wrong. The announcement wire shape is three fields, so there
// is no `kind` string to mistranslate and no precomputed URL to ignore; the
// risk concentrates in the one field that is neither a number nor a string:
// `date`, which arrives as a string that may be null, may carry fractional
// seconds, and must never take a row down with it when it is unreadable.
//
// The second priority is that ABSENT and EMPTY stay apart. The daemon omits a
// course whose news route failed and writes `[]` for one that answered with
// nothing, and those two mean opposite things to a menu.
//
// SCOPE: small — reads a file from a temp `BSB_ROOT`. Only the no-spawn test
// starts a process, and that one is medium.
// ═════════════════════════════════════════════════════════════════════════════

private let scholarly = 440_703
private let civics = 412_690

@Suite("DaemonAnnouncementSource — the cache, keyed by course")
struct DaemonAnnouncementSourceTests {

    // MARK: - The mapping

    @Test("a course's announcements decode with every field mapped")
    func announcementsDecode() async throws {
        // Arrange
        let world = DaemonWorld()
        world.seedCache(data: AnnouncementJSON.cache, status: DaemonJSON.freshStatus)

        // Act
        let items = try await world.announcementSource().fetchAnnouncements(courseId: civics)

        // Assert — id and title transcribed from the live `news/` capture.
        #expect(items.map(\.id) == [AnnouncementJSON.dueDateErrorID])
        #expect(items.first?.title == AnnouncementJSON.dueDateErrorTitle)
        #expect(items.first?.date == AnnouncementTruth.dueDateErrorPosted)
    }

    @Test("the course id is stamped from the request, not read from the payload")
    func theCourseIdIsStamped() async throws {
        // Arrange — the daemon keys announcements by course and does not repeat
        // the id inside them. An unstamped row renders a correct headline whose
        // link opens course 0.
        let world = DaemonWorld()
        world.seedCache(data: AnnouncementJSON.cache, status: DaemonJSON.freshStatus)

        // Act
        let items = try await world.announcementSource().fetchAnnouncements(courseId: scholarly)

        // Assert
        #expect(items.allSatisfy { $0.courseId == scholarly })
    }

    @Test("the daemon's newest-first order survives the decode")
    func theOrderIsPreserved() async throws {
        // Arrange — the daemon sorts, and it sorts for a reason: the menu shows
        // the top few. A decoder that reordered (or that a dictionary's ordering
        // leaked into) would silently pick different ones.
        let world = DaemonWorld()
        world.seedCache(data: AnnouncementJSON.cache, status: DaemonJSON.freshStatus)

        // Act
        let items = try await world.announcementSource().fetchAnnouncements(courseId: scholarly)

        // Assert
        #expect(items.map(\.id) == [AnnouncementJSON.urduID, 1_967_175, 1_919_993])
        #expect(items.first?.date == AnnouncementTruth.urduPosted)
    }

    @Test("a null date stays nil rather than becoming an epoch")
    func aMissingDateIsNil() async throws {
        // Arrange — the daemon writes null when D2L sent neither a start date nor
        // a created one. A sentinel here would date the row to 1970 and sort it
        // to the bottom of anything that reads the field.
        let world = DaemonWorld()
        world.seedCache(data: AnnouncementJSON.cache, status: DaemonJSON.freshStatus)

        // Act
        let items = try await world.announcementSource().fetchAnnouncements(courseId: scholarly)

        // Assert
        #expect(items.last?.date == nil)
    }

    @Test("a date carrying fractional seconds still decodes")
    func fractionalSecondsAreAccepted() async throws {
        // Arrange — the daemon normalizes to whole seconds today, but D2L is not
        // consistent about them and a passthrough tomorrow must not cost a course
        // its announcements. Same two-attempt shape as the assignment side.
        let world = DaemonWorld()
        world.seedCache(
            data: AnnouncementJSON.oneItem("""
                { "id": 1, "title": "Office hours moved", "date": "2026-03-11T14:22:31.417Z" }
                """),
            status: DaemonJSON.freshStatus
        )

        // Act
        let items = try await world.announcementSource().fetchAnnouncements(courseId: scholarly)

        // Assert
        #expect(items.first?.date == AnnouncementTruth.fractionalPosted)
    }

    @Test("an unreadable date costs the date, never the announcement")
    func anUnparseableDateIsSurvivable() async throws {
        // Arrange — the asymmetry this whole pipeline runs on: a missing id or
        // title is fatal, an unreadable date is one missing line. An announcement
        // still reads perfectly well without a timestamp.
        let world = DaemonWorld()
        world.seedCache(
            data: AnnouncementJSON.oneItem("""
                { "id": 1, "title": "Office hours moved", "date": "next Tuesday" }
                """),
            status: DaemonJSON.freshStatus
        )

        // Act
        let items = try await world.announcementSource().fetchAnnouncements(courseId: scholarly)

        // Assert
        #expect(items.count == 1)
        #expect(items.first?.title == "Office hours moved")
        #expect(items.first?.date == nil)
    }

    @Test("unknown item fields are ignored, not fatal")
    func futureFieldsDoNotBreakTheDecode() async throws {
        // Arrange — the daemon will grow fields (a body, an author); a decoder
        // that rejects them makes every daemon release a breaking one.
        let world = DaemonWorld()
        world.seedCache(
            data: AnnouncementJSON.oneItem("""
                { "id": 1, "title": "Office hours moved", "date": null,
                  "author": "Dr. Reyes", "isPinned": true }
                """),
            status: DaemonJSON.freshStatus
        )

        // Act
        let items = try await world.announcementSource().fetchAnnouncements(courseId: scholarly)

        // Assert
        #expect(items.map(\.id) == [1])
    }

    // MARK: - Empty, absent, and broken

    @Test("a course with an empty list has posted nothing — that is data, not a failure")
    func anEmptyListIsData() async throws {
        // Arrange — the daemon writes `[]` for a course whose news route answered
        // and had nothing. `AnnouncementsState.loaded([])` says exactly that.
        let world = DaemonWorld()
        world.seedCache(data: AnnouncementJSON.cache, status: DaemonJSON.freshStatus)

        // Act
        let items = try await world.announcementSource()
            .fetchAnnouncements(courseId: AnnouncementJSON.quietCourseID)

        // Assert
        #expect(items.isEmpty)
    }

    @Test("a course absent from the map throws rather than reporting no announcements")
    func anAbsentCourseIsAFailure() async {
        // Arrange — the daemon omits a course whose news route failed, so absent
        // means "unknown". Answering `[]` would empty a section that was showing
        // real posts a minute ago; throwing folds to `.failed(lastKnown:)`, which
        // keeps them.
        let world = DaemonWorld()
        world.seedCache(data: AnnouncementJSON.cache, status: DaemonJSON.freshStatus)

        // Act
        let error = await courseSourceError {
            _ = try await world.announcementSource().fetchAnnouncements(courseId: 999_999)
        }

        // Assert
        #expect(error?.isTransport == true, "got \(String(describing: error))")
    }

    @Test("a cache written before announcements existed reads as unknown, not as corrupt")
    func anOlderCacheIsNotMalformed() async {
        // Arrange — the shape every install has on disk between the app updating
        // and the next daemon run landing. It is a perfectly valid cache that
        // simply has not been asked the question yet, and calling it malformed
        // would report corruption for a file nothing is wrong with. Unknown is
        // the same answer an absent course gets, and it folds the same way.
        let world = DaemonWorld()
        world.seedCache(
            data: AnnouncementJSON.cacheWithoutAnnouncements, status: DaemonJSON.freshStatus
        )

        // Act
        let error = await courseSourceError {
            _ = try await world.announcementSource().fetchAnnouncements(courseId: scholarly)
        }

        // Assert
        #expect(error?.isTransport == true, "got \(String(describing: error))")
    }

    @Test("a missing data.json throws transport")
    func aMissingCacheIsTransport() async {
        // Arrange — nothing has ever run: no file, no data.
        let world = DaemonWorld()

        // Act
        let error = await courseSourceError {
            _ = try await world.announcementSource().fetchAnnouncements(courseId: scholarly)
        }

        // Assert
        #expect(error?.isTransport == true, "got \(String(describing: error))")
    }

    @Test("a corrupt data.json throws malformedBody")
    func aCorruptCacheIsMalformed() async {
        // Arrange
        let world = DaemonWorld()
        world.seedCache(data: "{ \"announcements\": { \"440703\": [", status: DaemonJSON.freshStatus)

        // Act
        let error = await courseSourceError {
            _ = try await world.announcementSource().fetchAnnouncements(courseId: scholarly)
        }

        // Assert
        #expect(error?.isMalformedBody == true, "got \(String(describing: error))")
    }

    @Test("an announcement with no id fails the course rather than losing a row silently")
    func aMissingIdIsFatal() async {
        // Arrange — the id is what keys the row and what a future per-item link
        // would be built from. Serving the rest is indistinguishable from the
        // instructor having deleted one.
        let world = DaemonWorld()
        world.seedCache(
            data: AnnouncementJSON.oneItem("""
                { "title": "Office hours moved", "date": null }
                """),
            status: DaemonJSON.freshStatus
        )

        // Act
        let error = await courseSourceError {
            _ = try await world.announcementSource().fetchAnnouncements(courseId: scholarly)
        }

        // Assert
        #expect(error?.isMalformedBody == true, "got \(String(describing: error))")
    }

    @Test("an announcement with no title fails the course")
    func aMissingTitleIsFatal() async {
        // Arrange — the title IS the row. A nameless announcement renders a blank
        // line that opens a page.
        let world = DaemonWorld()
        world.seedCache(
            data: AnnouncementJSON.oneItem("""
                { "id": 1, "date": null }
                """),
            status: DaemonJSON.freshStatus
        )

        // Act
        let error = await courseSourceError {
            _ = try await world.announcementSource().fetchAnnouncements(courseId: scholarly)
        }

        // Assert
        #expect(error?.isMalformedBody == true, "got \(String(describing: error))")
    }

    // MARK: - The status file speaks for the run that wrote the cache

    @Test("a needs-login status throws sessionExpired")
    func needsLoginIsSessionExpired() async {
        // Arrange — checked BEFORE the bytes, exactly as the assignment source
        // checks it: data from the last good run is still on disk and must not be
        // served as if it were fresh.
        let world = DaemonWorld()
        world.seedCache(data: AnnouncementJSON.cache, status: DaemonJSON.status("needs-login"))

        // Act
        let error = await courseSourceError {
            _ = try await world.announcementSource().fetchAnnouncements(courseId: scholarly)
        }

        // Assert
        #expect(error?.isSessionExpired == true, "got \(String(describing: error))")
    }

    @Test("an error status throws transport")
    func anErrorStatusIsTransport() async {
        // Arrange
        let world = DaemonWorld()
        world.seedCache(
            data: AnnouncementJSON.cache,
            status: DaemonJSON.status("error", error: "the token mint answered HTTP 502")
        )

        // Act
        let error = await courseSourceError {
            _ = try await world.announcementSource().fetchAnnouncements(courseId: scholarly)
        }

        // Assert
        #expect(error?.isTransport == true, "got \(String(describing: error))")
    }

    @Test("a missing status.json does not stop a good cache being read")
    func theStatusFileIsOptional() async throws {
        // Arrange — the data file is the payload, the status file is the report.
        let world = DaemonWorld()
        world.seedCache(data: AnnouncementJSON.cache)

        // Act
        let items = try await world.announcementSource().fetchAnnouncements(courseId: scholarly)

        // Assert
        #expect(items.count == 3)
    }

    // MARK: - Freshness and cost

    @Test("the cache is re-read on every call")
    func everyCallReadsTheFileAgain() async throws {
        // Arrange
        let world = DaemonWorld()
        world.seedCache(data: AnnouncementJSON.cache, status: DaemonJSON.freshStatus)
        let source = world.announcementSource()
        _ = try await source.fetchAnnouncements(courseId: scholarly)

        // Act — a daemon run lands while the app is up.
        world.seedCache(
            data: AnnouncementJSON.oneItem("""
                { "id": 42, "title": "Just posted", "date": null }
                """)
        )
        let items = try await source.fetchAnnouncements(courseId: scholarly)

        // Assert
        #expect(items.map(\.id) == [42])
    }

    @Test("fetching announcements never spawns the daemon")
    func announcementsCostNothing() async throws {
        // Arrange — one real spawn, through the course source, exactly as a
        // refresh does. Every course's announcements are already in the file it
        // wrote, and this section must not add a second reason to climb the
        // login ladder per visible course.
        let world = DaemonWorld()
        world.stage(data: AnnouncementJSON.cache, status: DaemonJSON.freshStatus)
        _ = try await world.courseSource().fetchCourses()
        let afterTheRefresh = world.spawnCount

        // Act — the fan-out.
        let source = world.announcementSource()
        for courseId in [scholarly, civics, AnnouncementJSON.quietCourseID] {
            _ = try? await source.fetchAnnouncements(courseId: courseId)
        }

        // Assert
        #expect(afterTheRefresh == 1)
        #expect(world.spawnCount == 1, "an announcement fetch spawned the daemon")
    }
}
