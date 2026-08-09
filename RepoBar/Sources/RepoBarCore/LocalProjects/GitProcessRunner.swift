#if os(macOS)
    import Foundation

    struct GitProcessOutput {
        let stdout: String
        let stderr: String
        let terminationStatus: Int32
    }

    enum GitProcessRunner {
        static func run(
            _ arguments: [String],
            in directory: URL,
            environment: [String: String]? = nil,
            timeout: TimeInterval? = nil
        ) throws -> GitProcessOutput {
            let process = Process()
            process.executableURL = GitExecutableLocator.shared.url
            process.arguments = arguments
            process.currentDirectoryURL = directory
            if let environment {
                process.environment = environment
            }

            return try Self.run(process, timeout: timeout)
        }

        static func run(
            executableURL: URL,
            arguments: [String],
            in directory: URL,
            timeout: TimeInterval? = nil
        ) throws -> GitProcessOutput {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.currentDirectoryURL = directory
            return try Self.run(process, timeout: timeout)
        }

        private static func run(_ process: Process, timeout: TimeInterval?) throws -> GitProcessOutput {
            let tempDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("repobar-git-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDirectory) }

            let stdoutURL = tempDirectory.appendingPathComponent("stdout")
            let stderrURL = tempDirectory.appendingPathComponent("stderr")
            FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

            let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)
            defer {
                try? stdoutHandle.close()
                try? stderrHandle.close()
            }

            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle

            let didExit = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in didExit.signal() }

            do {
                try process.run()
            } catch {
                throw error
            }

            if let timeout {
                let timeoutResult = didExit.wait(timeout: .now() + timeout)
                if timeoutResult == .timedOut {
                    process.terminate()
                    _ = didExit.wait(timeout: .now() + 1)
                    throw GitProcessRunnerError.timedOut(timeout: timeout)
                }
            } else {
                process.waitUntilExit()
            }

            try? stdoutHandle.close()
            try? stderrHandle.close()
            let stdoutData = (try? Data(contentsOf: stdoutURL)) ?? Data()
            let stderrData = (try? Data(contentsOf: stderrURL)) ?? Data()
            return GitProcessOutput(
                stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                stderr: String(data: stderrData, encoding: .utf8) ?? "",
                terminationStatus: process.terminationStatus
            )
        }
    }

    enum GitProcessRunnerError: Error {
        case timedOut(timeout: TimeInterval)
    }

#endif
