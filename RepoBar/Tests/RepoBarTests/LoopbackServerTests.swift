import Darwin
import Foundation
@testable import RepoBarCore
import Testing

struct LoopbackServerTests {
    @Test
    func `parse extracts code and state`() {
        let request = "GET /callback?code=abc&state=xyz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        let parsed = LoopbackServer.parse(request: request)
        #expect(parsed?.code == "abc")
        #expect(parsed?.state == "xyz")
    }

    @Test
    @MainActor
    func `wait for callback returns result`() async throws {
        let (server, redirectURL) = try await Self.startServer()
        defer { server.stop() }

        let expectedCode = "code-1"
        let expectedState = "state-1"

        var components = try #require(URLComponents(url: redirectURL, resolvingAgainstBaseURL: false))
        components.queryItems = [
            URLQueryItem(name: "code", value: expectedCode),
            URLQueryItem(name: "state", value: expectedState)
        ]
        let callbackURL = try #require(components.url)

        let sendTask = Task.detached {
            while !Task.isCancelled {
                do {
                    var request = URLRequest(url: callbackURL)
                    request.timeoutInterval = 0.5
                    _ = try await URLSession.shared.data(for: request)
                    return
                } catch {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        }
        defer { sendTask.cancel() }

        let result = try await server.waitForCallback(timeout: 10)
        #expect(result.code == expectedCode)
        #expect(result.state == expectedState)
    }

    @Test
    @MainActor
    func `wait for callback times out`() async throws {
        let (server, _) = try await Self.startServer()
        defer { server.stop() }

        do {
            _ = try await server.waitForCallback(timeout: 0.05)
            Issue.record("Expected timeout")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        }
    }

    @Test
    @MainActor
    func `start throws port in use`() throws {
        let (port, socket) = try Self.reservePort()
        defer { close(socket) }

        let other = LoopbackServer(port: port)
        do {
            _ = try other.start()
            defer { other.stop() }
            Issue.record("Expected port in use error")
        } catch let error as LoopbackServerError {
            switch error {
            case let .portInUse(errorPort):
                #expect(errorPort == port)
            case .bindFailed:
                Issue.record("Expected portInUse error")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private extension LoopbackServerTests {
    @MainActor
    static func startServer() async throws -> (LoopbackServer, URL) {
        var lastError: Error?
        for _ in 0 ..< 40 {
            let port = Int.random(in: 49152 ... 65000)
            let server = LoopbackServer(port: port)
            do {
                let redirectURL = try server.start()
                return (server, redirectURL)
            } catch {
                lastError = error
                server.stop()
            }
        }
        throw lastError ?? URLError(.cannotConnectToHost)
    }

    static func reservePort() throws -> (port: Int, socket: Int32) {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw POSIXError(.EBADF)
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult != 0 {
            close(sock)
            throw POSIXError(.EADDRINUSE)
        }

        _ = listen(sock, 1)

        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        var boundAddr = sockaddr_in()
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(sock, sockPtr, &len)
            }
        }
        if nameResult != 0 {
            close(sock)
            throw POSIXError(.EINVAL)
        }

        let port = Int(UInt16(bigEndian: boundAddr.sin_port))
        return (port, sock)
    }
}
