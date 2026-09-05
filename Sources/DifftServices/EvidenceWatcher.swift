import Foundation

public final class EvidenceWatcher: @unchecked Sendable {
    private let directory: URL
    private var timer: Timer?
    public var onChange: (@Sendable ([URL]) -> Void)?

    public init(directory: URL) { self.directory = directory }

    public static func currentPNGs(in directory: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "png" }
                   .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public static func verdict(in directory: URL) -> (verdict: String, summary: String)? {
        struct V: Codable { let verdict: String; let summary: String }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("verdict.json")),
              let v = try? JSONDecoder().decode(V.self, from: data) else { return nil }
        return (v.verdict, v.summary)
    }

    public func start() {
        stop()
        let dir = directory
        var lastNames: [String] = []
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            let pngs = Self.currentPNGs(in: dir)
            let names = pngs.map(\.lastPathComponent)
            if names != lastNames { lastNames = names; self?.onChange?(pngs) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() { timer?.invalidate(); timer = nil }
}
