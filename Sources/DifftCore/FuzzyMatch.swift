import Foundation

/// Subsequence matching for the jump palette.
///
/// "fmain" should find `src/air/form/main.py` ahead of `docs/formatting.md`:
/// what a reviewer types is a few letters of the file name, sometimes with a
/// letter of a folder in front, never the path from the root.
public enum FuzzyMatch {
    /// A score for `candidate` against `query`, or nil when the query's
    /// characters do not all appear in order. Higher is better.
    public static func score(query: String, candidate: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return 0 }
        let c = Array(candidate.lowercased())
        guard q.count <= c.count else { return nil }
        let nameStart = (c.lastIndex(of: "/").map { $0 + 1 }) ?? 0

        var score = 0
        var qi = 0
        var previous = -2
        for (i, ch) in c.enumerated() where qi < q.count && ch == q[qi] {
            score += 1
            if i == previous + 1 { score += 4 }              // a run reads as a word
            if i >= nameStart { score += 3 }                 // in the file name
            if i == nameStart { score += 8 }                 // starts the file name
            else if i > 0, "/_-. ".contains(c[i - 1]) { score += 5 }  // starts a segment
            previous = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        // Among equal matches the shorter path is the likelier target.
        return score * 100 - min(c.count, 99)
    }

    /// `items` that match, best first. Stable for equal scores.
    public static func rank<T>(_ items: [T], query: String, by key: (T) -> String) -> [T] {
        var scored: [(item: T, score: Int, offset: Int)] = []
        for (offset, item) in items.enumerated() {
            if let value = score(query: query, candidate: key(item)) {
                scored.append((item, value, offset))
            }
        }
        scored.sort { $0.score == $1.score ? $0.offset < $1.offset : $0.score > $1.score }
        return scored.map(\.item)
    }

    /// Splits "main.py:120" into the text to match and the line to land on.
    public static func splitLine(_ input: String) -> (query: String, line: Int?) {
        guard let colon = input.lastIndex(of: ":"),
              let line = Int(input[input.index(after: colon)...]), line > 0 else {
            return (input, nil)
        }
        return (String(input[..<colon]), line)
    }
}
