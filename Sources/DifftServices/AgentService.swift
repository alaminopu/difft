import Foundation

public protocol StreamingProcessRunning: Sendable {
    func stream(_ executable: String, arguments: [String], currentDirectory: URL?) -> AsyncThrowingStream<String, Error>
    func cancel()
}

public final class DefaultStreamingProcessRunner: StreamingProcessRunning, @unchecked Sendable {
    private let processLock = NSLock()
    private var process: Process?
    public init() {}

    public func stream(_ executable: String, arguments: [String], currentDirectory: URL?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.environment = difftProcessEnvironment()
            p.arguments = [executable] + arguments
            p.currentDirectoryURL = currentDirectory
            let outPipe = Pipe()
            let errPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe

            let drainQ = DispatchQueue(label: "com.difft.stream-drain")
            var buffer = Data()
            var stderrData = Data()

            let outHandle = outPipe.fileHandleForReading
            let errHandle = errPipe.fileHandleForReading

            outHandle.readabilityHandler = { _ in
                drainQ.async {
                    let chunk = outHandle.availableData
                    if !chunk.isEmpty {
                        buffer.append(chunk)
                        while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                            buffer.removeSubrange(buffer.startIndex...nl)
                            if let line = String(data: lineData, encoding: .utf8) { cont.yield(line) }
                        }
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
                    let outChunk = outHandle.availableData
                    if !outChunk.isEmpty {
                        buffer.append(outChunk)
                        while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                            buffer.removeSubrange(buffer.startIndex...nl)
                            if let line = String(data: lineData, encoding: .utf8) { cont.yield(line) }
                        }
                    }
                    if let lastLine = String(data: buffer, encoding: .utf8), !lastLine.isEmpty { cont.yield(lastLine) }

                    let errChunk = errHandle.availableData
                    if !errChunk.isEmpty {
                        stderrData.append(errChunk)
                    }

                    outHandle.readabilityHandler = nil
                    errHandle.readabilityHandler = nil

                    if proc.terminationStatus != 0 && proc.terminationReason == .exit {
                        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                        cont.finish(throwing: NSError(domain: "Difft.agent", code: Int(proc.terminationStatus),
                                                      userInfo: [NSLocalizedDescriptionKey: "claude exited \(proc.terminationStatus)" + (stderr.isEmpty ? "" : "\n\(stderr)")]))
                    } else {
                        cont.finish()
                    }
                }
            }
            do {
                try p.run()
                processLock.lock()
                self.process = p
                processLock.unlock()
            } catch {
                cont.finish(throwing: error)
            }
        }
    }

    public func cancel() {
        processLock.lock()
        let p = process
        processLock.unlock()
        p?.terminate()
    }
}

public final class AgentService: @unchecked Sendable {
    private let runner: StreamingProcessRunning
    public init(runner: StreamingProcessRunning = DefaultStreamingProcessRunner()) { self.runner = runner }

    public func run(_ task: AgentTask, in worktree: URL) -> AsyncThrowingStream<AgentEvent, Error> {
        let lines = runner.stream("claude", arguments: task.cliArguments, currentDirectory: worktree)
        return AsyncThrowingStream { cont in
            Task {
                do {
                    for try await line in lines {
                        if let event = StreamJSONParser.event(fromLine: line) { cont.yield(event) }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
        }
    }

    public func cancel() { runner.cancel() }
}
