import Foundation
import DifftCore

public struct ReportInput {
    public let session: SessionData
    public let files: [FileDiff]
    public init(session: SessionData, files: [FileDiff]) {
        self.session = session; self.files = files
    }
}

public enum ReportBuilder {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&#x27;")
    }

    public static func defaultURL(repoName: String, prNumber: Int, date: Date,
                                  timeZone: TimeZone = .current) -> URL {
        // Local calendar date by default: a report generated at 00:30 local
        // should not be named for yesterday (UTC).
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Difft-reports/\(repoName)-pr\(prNumber)-\(fmt.string(from: date)).html")
    }

    public static func html(for input: ReportInput) -> String {
        let s = input.session
        let severityOrder = ["high": 0, "medium": 1, "low": 2]
        let findings = s.findings.sorted { (severityOrder[$0.severity] ?? 3) < (severityOrder[$1.severity] ?? 3) }

        var out = """
        <!doctype html><html><head><meta charset="utf-8"><title>Difft report — PR #\(s.pr.number)</title>
        <style>
        body { font: 14px -apple-system, sans-serif; margin: 2rem auto; max-width: 60rem; }
        table { border-collapse: collapse; width: 100%; }
        td, th { border: 1px solid #ddd; padding: 6px; text-align: left; vertical-align: top; }
        .sev-high { color: #cf222e; font-weight: 700; } .sev-medium { color: #9a6700; } .sev-low { color: #57606a; }
        pre { background: #f6f8fa; padding: 8px; overflow-x: auto; }
        .add { background: #dafbe1; } .del { background: #ffebe9; }
        </style></head><body>
        <h1>PR #\(s.pr.number): \(escape(s.pr.title))</h1>
        <p>Branch <code>\(escape(s.pr.headRefName))</code> by \(escape(s.pr.authorLogin))
        """
        out += "</p>\n<h2>Findings (\(findings.count))</h2>\n"
        if findings.isEmpty {
            out += "<p>No findings.</p>\n"
        } else {
            out += "<table><tr><th>Severity</th><th>Location</th><th>Explanation</th></tr>\n"
            for f in findings {
                out += "<tr><td class=\"sev-\(escape(f.severity))\">\(escape(f.severity))</td>"
                out += "<td><code>\(escape(f.file)):\(f.line)</code></td><td>\(escape(f.explanation))</td></tr>\n"
            }
            out += "</table>\n"
        }

        if !s.chat.isEmpty {
            out += "<h2>Q&amp;A transcript</h2>\n"
            for m in s.chat {
                let chip = m.contextChip.map { " <code>\(escape($0))</code>" } ?? ""
                out += "<p><strong>\(escape(m.role))\(chip):</strong> \(escape(m.text))</p>\n"
            }
        }

        out += "<h2>Files (\(input.files.count))</h2>\n<ul>\n"
        for f in input.files {
            let mark = s.viewedFiles.contains(f.path) ? "✅" : "⬜️"
            out += "<li>\(mark) <code>\(escape(f.path))</code> (+\(f.additions)/−\(f.deletions))</li>\n"
        }
        out += "</ul>\n<h2>Diff</h2>\n<details><summary>Show full diff</summary>\n"
        for f in input.files {
            out += "<h4><code>\(escape(f.path))</code></h4><pre>"
            for hunk in f.hunks {
                out += escape(hunk.header) + "\n"
                for line in hunk.lines {
                    let cls = line.kind == .addition ? "add" : line.kind == .deletion ? "del" : ""
                    let sign = line.kind == .addition ? "+" : line.kind == .deletion ? "-" : " "
                    out += "<span class=\"\(cls)\">\(sign)\(escape(line.text))</span>\n"
                }
            }
            out += "</pre>\n"
        }
        out += "</details>\n</body></html>"
        return out
    }
}
