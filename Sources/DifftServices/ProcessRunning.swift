import Foundation

public struct ProcessResult: Equatable, Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout; self.stderr = stderr; self.exitCode = exitCode
    }
}

public protocol ProcessRunning: Sendable {
    func run(_ executable: String, arguments: [String], currentDirectory: URL?) async throws -> ProcessResult
}

/// GUI apps launched from Finder inherit LaunchServices' minimal PATH, which
/// misses Homebrew — where `gh` and `claude` usually live. Every subprocess
/// gets this widened environment.
public func difftProcessEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let extras = ["/opt/homebrew/bin", "/usr/local/bin",
                  "\(NSHomeDirectory())/.local/bin"]
    var path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    for extra in extras where !path.split(separator: ":").map(String.init).contains(extra) {
        path += ":" + extra
    }
    env["PATH"] = path
    return env
}

public final class DefaultProcessRunner: ProcessRunning {
    public init() {}
    public func run(_ executable: String, arguments: [String], currentDirectory: URL?) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = [executable] + arguments
            p.currentDirectoryURL = currentDirectory
            p.environment = difftProcessEnvironment()
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err

            let drainQ = DispatchQueue(label: "com.difft.process-drain")
            var stdoutData = Data()
            var stderrData = Data()

            let outHandle = out.fileHandleForReading
            let errHandle = err.fileHandleForReading

            outHandle.readabilityHandler = { _ in
                drainQ.async {
                    let chunk = outHandle.availableData
                    if !chunk.isEmpty {
                        stdoutData.append(chunk)
                    }
                }
            }

            errHandle.readabilityHandler = { _ in
                drainQ.async {
                    let chunk = errHandle.availableData
                    if !chunk.isEmpty {
                        stderrData.append(chunk)
                    }
                }
            }

            p.terminationHandler = { proc in
                drainQ.async {
                    let stdoutChunk = outHandle.availableData
                    if !stdoutChunk.isEmpty {
                        stdoutData.append(stdoutChunk)
                    }
                    let stderrChunk = errHandle.availableData
                    if !stderrChunk.isEmpty {
                        stderrData.append(stderrChunk)
                    }

                    outHandle.readabilityHandler = nil
                    errHandle.readabilityHandler = nil

                    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                    cont.resume(returning: ProcessResult(stdout: stdout, stderr: stderr, exitCode: proc.terminationStatus))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}
