public enum DiffParser {
    public static func parse(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var allLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Real `gh pr diff` output ends with a trailing newline, which
        // `split(omittingEmptySubsequences: false)` turns into a spurious
        // final "" element that would otherwise parse as a phantom context
        // line past the end of the last hunk. Drop only that one trailing
        // empty element (not any that are genuinely part of the diff).
        if allLines.last == "" { allLines.removeLast() }
        var lines = allLines[...]

        while let start = lines.firstIndex(where: { $0.hasPrefix("diff --git ") }) {
            lines = lines[start...]
            let header = lines.removeFirst()
            let next = lines.firstIndex(where: { $0.hasPrefix("diff --git ") }) ?? lines.endIndex
            let body = Array(lines[lines.startIndex..<next])
            lines = lines[next...]
            if let file = parseFile(headerLine: header, body: body) { files.append(file) }
        }
        return files
    }

    private static func parseFile(headerLine: String, body: [String]) -> FileDiff? {
        var kind: FileChangeKind = .modified
        var renameFrom: String?
        var path: String?

        for line in body {
            if line.hasPrefix("new file mode") { kind = .added }
            else if line.hasPrefix("deleted file mode") { kind = .deleted }
            else if line.hasPrefix("Binary files ") { kind = .binary }
            else if line.hasPrefix("rename from ") { renameFrom = String(line.dropFirst("rename from ".count)) }
            else if line.hasPrefix("rename to ") { path = String(line.dropFirst("rename to ".count)) }
            else if line.hasPrefix("+++ b/") { path = String(line.dropFirst("+++ b/".count)) }
            else if line.hasPrefix("--- a/"), kind == .deleted { path = String(line.dropFirst("--- a/".count)) }
        }
        if let from = renameFrom { kind = .renamed(from: from) }
        if path == nil {
            // binary or degenerate: take second path from "diff --git a/x b/x"
            let parts = headerLine.dropFirst("diff --git ".count).split(separator: " ")
            if let b = parts.last, b.hasPrefix("b/") { path = String(b.dropFirst(2)) }
        }
        guard let filePath = path else { return nil }
        return FileDiff(path: filePath, kind: kind, hunks: parseHunks(body))
    }

    private static func parseHunks(_ body: [String]) -> [Hunk] {
        var hunks: [Hunk] = []
        var header = ""
        var current: [DiffLine] = []
        var oldNo = 0, newNo = 0
        var inHunk = false

        func flush() {
            if inHunk { hunks.append(Hunk(header: header, lines: current)); current = [] }
        }

        for line in body {
            if line.hasPrefix("@@") {
                flush(); inHunk = true; header = line
                // "@@ -a,b +c,d @@ ..."
                let nums = line.split(separator: " ").dropFirst().prefix(2)
                if let o = nums.first { oldNo = Int(o.dropFirst().split(separator: ",")[0]) ?? 0 }
                if let n = nums.dropFirst().first { newNo = Int(n.dropFirst().split(separator: ",")[0]) ?? 0 }
            } else if inHunk {
                if line.hasPrefix("+") {
                    current.append(DiffLine(kind: .addition, oldNumber: nil, newNumber: newNo, text: String(line.dropFirst())))
                    newNo += 1
                } else if line.hasPrefix("-") {
                    current.append(DiffLine(kind: .deletion, oldNumber: oldNo, newNumber: nil, text: String(line.dropFirst())))
                    oldNo += 1
                } else if line.hasPrefix(" ") || line.isEmpty {
                    current.append(DiffLine(kind: .context, oldNumber: oldNo, newNumber: newNo, text: String(line.dropFirst(line.isEmpty ? 0 : 1))))
                    oldNo += 1; newNo += 1
                } else if line.hasPrefix("\\") {
                    continue // "\ No newline at end of file"
                } else {
                    inHunk = false; flush()
                }
            }
        }
        flush()
        return hunks
    }
}
