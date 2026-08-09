import Logging

/// Lightweight opt-in logger controlled by user settings.
public actor DiagnosticsLogger {
    public static let shared = DiagnosticsLogger()
    private var enabled = false
    private let log = RepoBarLogging.logger("diagnostics")

    public func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
    }

    public func message(_ text: String) {
        guard self.enabled else { return }

        self.log.info("\(text)")
    }
}
