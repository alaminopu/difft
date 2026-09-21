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
    /// Same, with a body written to the child's stdin and the pipe closed.
    ///
    /// Needed for `gh api --input -`: a review payload carries free-form
    /// markdown and a nested array of line notes, neither of which has an
    /// `-f key=value` spelling.
    func run(_ executable: String, arguments: [String], currentDirectory: URL?,
             stdin: Data?) async throws -> ProcessResult
}

public extension ProcessRunning {
    /// Runners with nothing to say to stdin — the test fakes — inherit this.
    func run(_ executable: String, arguments: [String], currentDirectory: URL?,
             stdin: Data?) async throws -> ProcessResult {
        try await run(executable, arguments: arguments, currentDirectory: currentDirectory)
    }
}

/// Where `gh` keeps its HTTP response cache when Difft is the one running it.
///
/// `gh` stores a handful of responses on disk, among them the `SearchType`
/// introspection it looks up before every `gh pr list --search`. The files are
/// plain HTTP dumps rewritten in place, so one left mangled — by an
/// interrupted write, or by two `gh` processes writing it at once, and Difft
/// runs several at a time — poisons every later search for the 24 hours the
/// entry lives:
///
///     invalid character '{' looking for beginning of object key string
///
/// and nothing in that sentence says a cache was involved. Pointing `gh` at a
/// directory of Difft's own makes the cache something Difft may throw away on
/// sight, without touching what the user's own `gh` has cached in the shell.
public enum GHCache {
    /// `gh` appends its own "gh" component below this.
    public static let home: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Difft",
                                           isDirectory: true)
    }()

    static var directory: URL { home.appendingPathComponent("gh", isDirectory: true) }

    /// Drops the cache. The next `gh` refills it from GitHub.
    public static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// GUI apps launched from Finder inherit LaunchServices' minimal PATH, which
/// misses Homebrew — where `gh` and `claude` usually live. Every subprocess
/// gets this widened environment.
///
/// `executable` only decides whether the `gh` cache redirect applies; the
/// widened PATH is the same for all of them.
public func difftProcessEnvironment(for executable: String = "") -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let extras = ["/opt/homebrew/bin", "/usr/local/bin",
                  "\(NSHomeDirectory())/.local/bin"]
    var path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    for extra in extras where !path.split(separator: ":").map(String.init).contains(extra) {
        path += ":" + extra
    }
    env["PATH"] = path
    // Only `gh` reads this, and only for its response cache — its credentials
    // and config live under XDG_CONFIG_HOME, which is left alone.
    if executable == "gh" || executable.hasSuffix("/gh") {
        env["XDG_CACHE_HOME"] = GHCache.home.path
    }
    return env
}

public final class DefaultProcessRunner: ProcessRunning {
    public init() {}
    public func run(_ executable: String, arguments: [String],
                    currentDirectory: URL?) async throws -> ProcessResult {
        try await run(executable, arguments: arguments,
                      currentDirectory: currentDirectory, stdin: nil)
    }

    public func run(_ executable: String, arguments: [String], currentDirectory: URL?,
                    stdin: Data?) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = [executable] + arguments
            p.currentDirectoryURL = currentDirectory
            p.environment = difftProcessEnvironment(for: executable)
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err
            let input = stdin.map { _ in Pipe() }
            if let input { p.standardInput = input }

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
            do {
                try p.run()
                if let input, let stdin {
                    // Written after launch and closed immediately: a child
                    // reading to EOF blocks forever otherwise, and a payload
                    // larger than the pipe buffer would deadlock a
                    // write-then-launch order.
                    input.fileHandleForWriting.write(stdin)
                    try? input.fileHandleForWriting.close()
                }
            } catch { cont.resume(throwing: error) }
        }
    }
}
