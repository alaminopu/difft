import Foundation

/// One review conversation: the comment that started it plus its replies.
///
/// GitHub returns review comments as a flat list where a reply points at the
/// comment it answers via `in_reply_to_id`. Grouping them back into threads is
/// what lets the comments list show a conversation as one card instead of
/// several disconnected ones.
public struct CommentThread: Identifiable, Equatable, Sendable {
    public let root: ReviewComment
    public let replies: [ReviewComment]

    public init(root: ReviewComment, replies: [ReviewComment]) {
        self.root = root
        self.replies = replies
    }

    public var id: Int { root.id }
    public var path: String { root.path }
    public var line: Int? { root.line }
    /// The resolved flag is merged onto every comment from the thread query,
    /// so the root speaks for the thread.
    public var resolved: Bool { root.resolved }
    public var comments: [ReviewComment] { [root] + replies }

    /// GitHub drops the line anchor once the diff has moved past a comment.
    public var isOutdated: Bool { root.line == nil }

    /// Distinct authors, in the order they first spoke.
    public var participants: [String] {
        var seen: Set<String> = []
        return comments.compactMap { seen.insert($0.author).inserted ? $0.author : nil }
    }

    /// Timestamp of the newest comment, for "most recent activity" ordering.
    public var lastActivityAt: String {
        comments.map(\.createdAt).max() ?? root.createdAt
    }

    /// Rebuilds threads from a flat comment list.
    ///
    /// A reply whose parent is missing (a partial fetch, or a thread whose
    /// root was deleted) becomes its own root rather than being dropped —
    /// silently losing someone's review feedback is the worse failure.
    public static func group(_ comments: [ReviewComment]) -> [CommentThread] {
        let byID = Dictionary(comments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        /// Walks up the reply chain to the comment that started the thread.
        /// The visited set both terminates a cycle in malformed data and
        /// makes every member of that cycle agree on one representative, so
        /// a cycle yields a single thread rather than splintering into one
        /// thread per comment.
        func rootID(of comment: ReviewComment) -> Int {
            var current = comment
            var visited: Set<Int> = [current.id]
            while let parentID = current.inReplyToID, let parent = byID[parentID] {
                guard visited.insert(parent.id).inserted else {
                    return visited.min() ?? current.id
                }
                current = parent
            }
            return current.id
        }

        var rootsInOrder: [Int] = []
        var grouped: [Int: [ReviewComment]] = [:]
        for comment in comments {
            let key = rootID(of: comment)
            if grouped[key] == nil { rootsInOrder.append(key) }
            grouped[key, default: []].append(comment)
        }

        let threads: [CommentThread] = rootsInOrder.compactMap { key in
            guard var members = grouped[key] else { return nil }
            members.sort { $0.createdAt < $1.createdAt }
            // The root is the member whose id is the group key; if that
            // comment itself is missing, the earliest member stands in.
            let rootIndex = members.firstIndex { $0.id == key } ?? 0
            let root = members.remove(at: rootIndex)
            return CommentThread(root: root, replies: members)
        }

        return threads.sorted { a, b in
            if a.path != b.path { return a.path < b.path }
            // Outdated threads (no line anchor) sort after located ones.
            switch (a.line, b.line) {
            case let (x?, y?) where x != y: return x < y
            case (nil, _?): return false
            case (_?, nil): return true
            default: return a.root.createdAt < b.root.createdAt
            }
        }
    }
}
