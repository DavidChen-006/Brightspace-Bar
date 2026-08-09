import RepoBarCore
import Testing

struct RepoDetailCacheStateCoverageTests {
    @Test
    func `cache freshness needs refresh`() {
        #expect(CacheFreshness.fresh.needsRefresh == false)
        #expect(CacheFreshness.stale.needsRefresh == true)
        #expect(CacheFreshness.missing.needsRefresh == true)
    }

    @Test
    func `missing is all missing`() {
        let state = RepoDetailCacheState.missing
        #expect(state.openPulls == .missing)
        #expect(state.release == .missing)
    }
}
