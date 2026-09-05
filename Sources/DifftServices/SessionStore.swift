import Foundation

public final class SessionStore {
    private let directory: URL
    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static func key(repo: String, prNumber: Int) -> String { "\(repo)-pr\(prNumber)" }

    private func fileURL(repo: String, prNumber: Int) -> URL {
        directory.appendingPathComponent(Self.key(repo: repo, prNumber: prNumber) + ".json")
    }

    public func save(_ s: SessionData) throws {
        let repo = URL(fileURLWithPath: s.repoDir).lastPathComponent
        let data = try JSONEncoder().encode(s)
        try data.write(to: fileURL(repo: repo, prNumber: s.pr.number), options: .atomic)
    }

    public func load(repo: String, prNumber: Int) -> SessionData? {
        let url = fileURL(repo: repo, prNumber: prNumber)
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let session = try? JSONDecoder().decode(SessionData.self, from: data) { return session }
        try? FileManager.default.moveItem(at: url, to: URL(fileURLWithPath: url.path + ".bak"))
        return nil
    }
}
