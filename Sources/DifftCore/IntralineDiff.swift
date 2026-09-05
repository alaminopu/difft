public enum IntralineDiff {
    /// Above this, a "replacement" is really two unrelated lines that happened
    /// to land opposite each other, and marking them up helps nobody.
    ///
    /// Deletions and additions are paired by index, not by similarity, so a
    /// rewritten block pairs line 1 of the old text with line 1 of the new
    /// text however different they are. The token diff then finds only
    /// incidental matches — a space here, a `the` there — and paints most of
    /// both lines, which is noise on top of the row tint that already says
    /// "this changed".
    ///
    /// Measured on real pairs: genuine edits leave at least one side 0-33%
    /// changed, while coincidental pairs run 56-78% on *both* sides. The test
    /// is therefore on the lesser of the two — a real edit keeps one side
    /// largely intact.
    static let maxChangedFraction = 0.5

    public static func changedRanges(old: String, new: String) -> (old: [Range<Int>], new: [Range<Int>]) {
        let oldTokens = tokenize(old), newTokens = tokenize(new)
        let common = lcs(oldTokens.map(\.text), newTokens.map(\.text))
        let oldRanges = ranges(tokens: oldTokens, commonIndices: common.old)
        let newRanges = ranges(tokens: newTokens, commonIndices: common.new)

        let oldFraction = changedFraction(oldRanges, of: old.count)
        let newFraction = changedFraction(newRanges, of: new.count)
        if min(oldFraction, newFraction) > maxChangedFraction { return ([], []) }

        return (oldRanges, newRanges)
    }

    private static func changedFraction(_ ranges: [Range<Int>], of length: Int) -> Double {
        guard length > 0 else { return 0 }
        return Double(ranges.reduce(0) { $0 + $1.count }) / Double(length)
    }

    private struct Token { let text: String; let range: Range<Int> }

    private static func tokenize(_ s: String) -> [Token] {
        var tokens: [Token] = []
        var start = 0
        var currentIsWord: Bool?
        var buffer = ""
        for (i, ch) in s.enumerated() {
            let isWord = ch.isLetter || ch.isNumber || ch == "_"
            if let cw = currentIsWord, cw == isWord, isWord {
                buffer.append(ch)
            } else {
                if !buffer.isEmpty { tokens.append(Token(text: buffer, range: start..<i)) }
                buffer = String(ch); start = i
            }
            currentIsWord = isWord
        }
        if !buffer.isEmpty { tokens.append(Token(text: buffer, range: start..<s.count)) }
        return tokens
    }

    private static func lcs(_ a: [String], _ b: [String]) -> (old: Set<Int>, new: Set<Int>) {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return ([], []) }
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n { for j in 1...m {
            dp[i][j] = a[i-1] == b[j-1] ? dp[i-1][j-1] + 1 : max(dp[i-1][j], dp[i][j-1])
        }}
        var oldIdx = Set<Int>(), newIdx = Set<Int>()
        var i = n, j = m
        while i > 0, j > 0 {
            if a[i-1] == b[j-1] { oldIdx.insert(i-1); newIdx.insert(j-1); i -= 1; j -= 1 }
            else if dp[i-1][j] >= dp[i][j-1] { i -= 1 } else { j -= 1 }
        }
        return (oldIdx, newIdx)
    }

    private static func ranges(tokens: [Token], commonIndices: Set<Int>) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for (i, tok) in tokens.enumerated() where !commonIndices.contains(i) {
            if let last = out.last, last.upperBound == tok.range.lowerBound {
                out[out.count - 1] = last.lowerBound..<tok.range.upperBound
            } else {
                out.append(tok.range)
            }
        }
        return out
    }
}
