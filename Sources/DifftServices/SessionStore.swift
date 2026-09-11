import Foundation

public final class SessionStore: @unchecked Sendable {
    private let directory: URL
    /// Serialises writes so two saves of the same session cannot interleave,
    /// and keeps the encode off whatever actor asked for it.
    private let writeQueue = DispatchQueue(label: "com.difft.session-store", qos: .utility)
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

    /// Save without blocking the caller.
    ///
    /// Ticking a file viewed encoded the entire session — PR body, whole chat
    /// transcript, every finding — and wrote it atomically (temp file plus
    /// rename, so a real disk round trip) on the main actor, per click. The
    /// data is a value type, so the snapshot handed over here cannot be
    /// mutated out from under the write.
    public func saveInBackground(_ s: SessionData, onFailure: ((Error) -> Void)? = nil) {
        writeQueue.async { [weak self] in
            do { try self?.save(s) }
            catch {
                guard let onFailure else { return }
                DispatchQueue.main.async { onFailure(error) }
            }
        }
    }

    public func load(repo: String, prNumber: Int) -> SessionData? {
        let url = fileURL(repo: repo, prNumber: prNumber)
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let session = try? JSONDecoder().decode(SessionData.self, from: data) { return session }
        try? FileManager.default.moveItem(at: url, to: URL(fileURLWithPath: url.path + ".bak"))
        return nil
    }
}
