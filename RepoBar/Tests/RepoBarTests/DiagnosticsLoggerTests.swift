import Foundation
@testable import RepoBarCore
import Testing

struct DiagnosticsLoggerTests {
    @Test
    func `logger can be enabled and disabled`() async {
        let logger = DiagnosticsLogger.shared
        await logger.setEnabled(false)
        await logger.message("should not log")

        await logger.setEnabled(true)
        await logger.message("should log")

        await logger.setEnabled(false)
    }
}
