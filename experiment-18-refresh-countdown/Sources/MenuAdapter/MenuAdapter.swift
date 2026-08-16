import Foundation
import CourseMenu
import CoursePipeline

// ─────────────────────────────────────────────────────────────────────────────
// SEAM: this actor is where the two packages meet.
//
//   CourseMenu.MenuDataSource   ← the frontend contract this actor conforms to
//   CoursePipeline.Poller/Cache ← the backend machinery this actor drives
//
// Imperative shell only. Every decision is owned elsewhere: "should we fetch?"
// belongs to `PollPolicy`, "what survives a failure?" to `CourseCache`, and
// "what does the menu say?" to `MenuTranslation`. This actor just reads the
// facts and hands them across the seam.
// ─────────────────────────────────────────────────────────────────────────────
public actor MenuAdapter: MenuDataSource {
    /// Asks the scheduler when the next automatic refresh fires; nil when no
    /// timer is running. `@MainActor` because `Timer` is a run-loop object owned
    /// there — the adapter awaits the hop on each snapshot, which costs
    /// microseconds and keeps the date honest (it is read live, never copied).
    public typealias NextRefreshProvider = @MainActor @Sendable () -> Date?

    private let poller: Poller
    private let cache: CourseCache
    private let baseURL: URL
    private let clock: any Clock
    private let nextRefresh: NextRefreshProvider?

    /// One disk read per process lifetime, performed lazily on first use so
    /// construction stays effect-free.
    private var loadedFromDisk = false

    public init(
        poller: Poller, cache: CourseCache, baseURL: URL, clock: any Clock,
        nextRefresh: NextRefreshProvider? = nil
    ) {
        self.poller = poller
        self.cache = cache
        self.baseURL = baseURL
        self.clock = clock
        self.nextRefresh = nextRefresh
    }

    // SEAM: contract method — the GUI's menu-open path. Serves memory/disk only;
    // by design there is no code path from here to a socket.
    public func currentMenu() async -> MenuModel {
        await self.loadIfNeeded()
        return await self.snapshot()
    }

    // SEAM: contract method — the GUI's Refresh click. Maps to `.manual`, which
    // `PollPolicy` ALWAYS honours: a user who explicitly asked gets a fetch,
    // even one second after the last. A future timer path must NOT reuse this
    // method — it would inherit `.manual` and bypass the policy's staleness
    // rule entirely. Give a timer its own `tick(.timer)` call instead.
    public func refresh() async -> MenuModel {
        await self.loadIfNeeded()
        // The poller folds the result into the cache; failure preserves the old
        // list (`.preservedStale`), so there is nothing to catch here and the
        // snapshot below is always the best available data.
        _ = await self.poller.tick(.manual)
        return await self.snapshot()
    }

    /// SEAM: the production timer's path — the `tick(.timer)` the comment above
    /// demands. Separate from `refresh()` because `.manual` always fetches; a
    /// timer wired through it would bypass `PollPolicy`'s staleness rule and
    /// fetch every interval whether or not anything could have changed.
    public func timerTick() async {
        await self.loadIfNeeded()
        _ = await self.poller.tick(.timer)
    }

    /// Warm start: pull the previous run's courses off disk before the first
    /// answer, so a relaunch shows data before any network round trip. Loading
    /// before `refresh()` too means even a failing first refresh cannot blank
    /// a menu that disk could have filled.
    private func loadIfNeeded() async {
        guard !self.loadedFromDisk else { return }
        self.loadedFromDisk = true
        await self.cache.load()
    }

    /// Shell reads the facts (cache state, clock), core translates. The one
    /// crossing from backend state to frontend model.
    private func snapshot() async -> MenuModel {
        MenuTranslation.menu(
            courses: await self.cache.courses,
            lastFetch: await self.cache.lastFetch,
            now: self.clock.now,
            baseURL: self.baseURL,
            nextRefresh: await self.nextRefresh?()
        )
    }
}
