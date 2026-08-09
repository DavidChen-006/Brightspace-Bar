@testable import RepoBar
import Testing

struct StatValueFormatterTests {
    @Test
    func `passes through values below one thousand`() {
        #expect(StatValueFormatter.compact(0) == "0")
        #expect(StatValueFormatter.compact(42) == "42")
        #expect(StatValueFormatter.compact(999) == "999")
    }

    @Test
    func `keeps one decimal below ten thousand`() {
        #expect(StatValueFormatter.compact(1000) == "1K")
        #expect(StatValueFormatter.compact(1500) == "1.5K")
        #expect(StatValueFormatter.compact(1999) == "2K")
        #expect(StatValueFormatter.compact(9999) == "10K")
    }

    @Test
    func `rounds thousands to nearest instead of truncating`() {
        #expect(StatValueFormatter.compact(10000) == "10K")
        #expect(StatValueFormatter.compact(10500) == "11K")
        #expect(StatValueFormatter.compact(19999) == "20K")
        #expect(StatValueFormatter.compact(99500) == "100K")
        #expect(StatValueFormatter.compact(123_456) == "123K")
    }

    @Test
    func `rolls rounded thousands up into millions`() {
        #expect(StatValueFormatter.compact(999_499) == "999K")
        #expect(StatValueFormatter.compact(999_500) == "1M")
        #expect(StatValueFormatter.compact(999_999) == "1M")
    }

    @Test
    func `keeps one decimal below ten million`() {
        #expect(StatValueFormatter.compact(1_000_000) == "1M")
        #expect(StatValueFormatter.compact(1_500_000) == "1.5M")
        #expect(StatValueFormatter.compact(9_999_999) == "10M")
    }

    @Test
    func `rounds millions and caps oversized counts`() {
        #expect(StatValueFormatter.compact(10_500_000) == "11M")
        #expect(StatValueFormatter.compact(99_999_999) == "100M")
        #expect(StatValueFormatter.compact(999_000_000) == "999M")
        #expect(StatValueFormatter.compact(1_000_000_000) == "999M")
    }

    @Test
    func `caps Int.max without integer overflow`() {
        #expect(StatValueFormatter.compact(Int.max) == "999M")
    }
}
