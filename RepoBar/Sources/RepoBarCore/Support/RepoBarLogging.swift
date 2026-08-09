import Foundation
import Logging
import os

public enum LogVerbosity: String, CaseIterable, Codable, Equatable {
    case error
    case warning
    case info
    case debug
    case trace

    public var label: String {
        switch self {
        case .error: "Errors only"
        case .warning: "Warnings"
        case .info: "Info"
        case .debug: "Debug"
        case .trace: "Trace"
        }
    }

    public var logLevel: Logging.Logger.Level {
        switch self {
        case .error: .error
        case .warning: .warning
        case .info: .info
        case .debug: .debug
        case .trace: .trace
        }
    }
}

public enum RepoBarLogging {
    private static let state = LogState()

    public static func bootstrapIfNeeded() {
        self.state.bootstrapIfNeeded()
    }

    public static func configure(verbosity: LogVerbosity, fileLoggingEnabled: Bool) {
        self.state.configure(verbosity: verbosity, fileLoggingEnabled: fileLoggingEnabled)
    }

    public static func logger(_ label: String) -> Logging.Logger {
        self.state.bootstrapIfNeeded()
        return Logging.Logger(label: label)
    }

    public static func logFileURL() -> URL? {
        self.state.logFileURL
    }
}

private final class LogState: @unchecked Sendable {
    private let lock = NSLock()
    private var isBootstrapped = false
    private var logLevel: Logging.Logger.Level = .info
    private var fileLoggingEnabled = false
    private var fileHandle: FileHandle?
    private(set) var logFileURL: URL?
    private let subsystem = "com.steipete.repobar"
    private let dateFormatter = ISO8601DateFormatter()

    func bootstrapIfNeeded() {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard !self.isBootstrapped else { return }

        self.isBootstrapped = true
        LoggingSystem.bootstrap { label in
            RepoBarLogHandler(label: label, state: self)
        }
    }

    func configure(verbosity: LogVerbosity, fileLoggingEnabled: Bool) {
        self.lock.lock()
        self.logLevel = verbosity.logLevel
        let shouldToggleFile = self.fileLoggingEnabled != fileLoggingEnabled
        self.fileLoggingEnabled = fileLoggingEnabled
        if shouldToggleFile {
            if fileLoggingEnabled {
                self.openFileHandle()
            } else {
                self.closeFileHandle()
            }
        }
        self.lock.unlock()
    }

    func currentLogLevel() -> Logging.Logger.Level {
        self.lock.lock()
        let level = self.logLevel
        self.lock.unlock()
        return level
    }

    func updateLogLevel(_ level: Logging.Logger.Level) {
        self.lock.lock()
        self.logLevel = level
        self.lock.unlock()
    }

    func osLogger(category: String) -> os.Logger {
        os.Logger(subsystem: self.subsystem, category: category)
    }

    func logToFile(_ line: String) {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.fileLoggingEnabled, let handle = self.fileHandle else { return }

        if let data = line.data(using: .utf8) {
            handle.write(data)
        }
    }

    func formattedTimestamp() -> String {
        self.lock.lock()
        let timestamp = self.dateFormatter.string(from: Date())
        self.lock.unlock()
        return timestamp
    }

    private func openFileHandle() {
        guard let url = self.resolveLogFileURL() else { return }

        self.logFileURL = url
        let directory = url.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: directory.path) == false {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
        if FileManager.default.fileExists(atPath: url.path) == false {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            self.fileHandle = handle
        }
    }

    private func closeFileHandle() {
        try? self.fileHandle?.close()
        self.fileHandle = nil
        self.logFileURL = nil
    }

    private func resolveLogFileURL() -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }

        let directory = base.appending(path: "RepoBar/Logs", directoryHint: .isDirectory)
        return directory.appending(path: "repobar.log", directoryHint: .notDirectory)
    }
}

private struct RepoBarLogHandler: LogHandler {
    let label: String
    var metadata: Logging.Logger.Metadata = [:]
    var logLevel: Logging.Logger.Level {
        get { self.state.currentLogLevel() }
        set { self.state.updateLogLevel(newValue) }
    }

    var metadataProvider: Logging.Logger.MetadataProvider?

    private let state: LogState
    private let osLogger: os.Logger

    init(label: String, state: LogState, metadataProvider: Logging.Logger.MetadataProvider? = nil) {
        self.label = label
        self.state = state
        self.metadataProvider = metadataProvider
        self.osLogger = state.osLogger(category: label)
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { self.metadata[key] }
        set { self.metadata[key] = newValue }
    }

    func log(event: Logging.LogEvent) {
        let combined = self.mergedMetadata(extra: event.metadata)
        let renderedMessage = self.renderMessage(event.message, metadata: combined)
        self.osLogger.log(level: self.osLogType(for: event.level), "\(renderedMessage, privacy: .public)")
        let fileLine = self.renderFileLine(level: event.level, message: renderedMessage)
        self.state.logToFile(fileLine)
    }

    private func mergedMetadata(extra: Logging.Logger.Metadata?) -> Logging.Logger.Metadata {
        var merged = self.metadata
        if let provided = self.metadataProvider?.get() {
            merged.merge(provided, uniquingKeysWith: { _, new in new })
        }
        if let extra {
            merged.merge(extra, uniquingKeysWith: { _, new in new })
        }
        return merged
    }

    private func renderMessage(_ message: Logging.Logger.Message, metadata: Logging.Logger.Metadata) -> String {
        guard metadata.isEmpty == false else { return message.description }

        let metadataText = metadata
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\(self.stringify($0.value))" }
            .joined(separator: " ")
        return "\(message.description) [\(metadataText)]"
    }

    private func renderFileLine(level: Logging.Logger.Level, message: String) -> String {
        let timestamp = self.state.formattedTimestamp()
        return "[\(timestamp)] [\(level.rawValue)] [\(self.label)] \(message)\n"
    }

    private func stringify(_ value: Logging.Logger.Metadata.Value) -> String {
        switch value {
        case let .string(string):
            return string
        case let .stringConvertible(convertible):
            return convertible.description
        case let .array(array):
            return "[" + array.map(self.stringify).joined(separator: ", ") + "]"
        case let .dictionary(dictionary):
            let entries = dictionary
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\(self.stringify($0.value))" }
            return "{" + entries.joined(separator: ", ") + "}"
        }
    }

    private func osLogType(for level: Logging.Logger.Level) -> OSLogType {
        switch level {
        case .trace, .debug:
            .debug
        case .info, .notice:
            .info
        case .warning:
            .default
        case .error:
            .error
        case .critical:
            .fault
        }
    }
}
