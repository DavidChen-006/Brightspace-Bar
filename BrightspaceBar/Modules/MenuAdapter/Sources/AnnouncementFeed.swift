import Foundation
import AssignmentPipeline
import CoursePipeline

/// The announcements half of the backend, assembled as one thing.
///
/// The same argument `AssignmentFeed` makes, for the same pair of objects:
/// `AnnouncementFetcher` and `AnnouncementStore` are always used together — the
/// fetcher writes what the store holds, and the adapter reads both — but a
/// caller handed two parameters can pass a fetcher wired to a *different* store
/// than the one being read. That failure is silent: announcements fetch
/// successfully, land in the wrong store, and every section stays empty.
///
/// So the pair is built here, from the two things that genuinely vary per call
/// (a source and a clock). `nil` where one of these is expected means the app
/// simply has no announcements feature — which is how every test written before
/// it keeps passing.
public struct AnnouncementFeed: Sendable {
    let fetcher: AnnouncementFetcher
    let store: AnnouncementStore

    public init(source: any AnnouncementSource, clock: any Clock) {
        let store = AnnouncementStore(clock: clock)
        self.store = store
        self.fetcher = AnnouncementFetcher(source: source, store: store)
    }
}
