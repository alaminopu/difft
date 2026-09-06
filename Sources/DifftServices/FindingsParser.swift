import Foundation

public enum FindingsParser {
    public static func parse(_ finalText: String) -> [Finding] {
        guard let data = JSONBlock.extract(from: finalText).data(using: .utf8),
              let findings = try? JSONDecoder().decode([Finding].self, from: data) else {
            return []
        }
        // A finding with nothing to say is noise, and one with no location
        // cannot be opened.
        return findings.filter { !$0.explanation.isEmpty && !$0.file.isEmpty }
    }

    /// Result of the verification pass: the survivors, carrying the verdict
    /// each earned. Anything the verifier did not return is discarded, which
    /// is the point of running it.
    public static func parseVerified(_ finalText: String) -> [Finding] {
        struct Verified: Decodable {
            let verdict: String?
            let finding: Finding
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: K.self)
                verdict = (try? c.decodeIfPresent(String.self, forKey: .verdict)) ?? nil
                finding = try Finding(from: decoder)
            }
            enum K: String, CodingKey { case verdict }
        }
        guard let data = JSONBlock.extract(from: finalText).data(using: .utf8),
              let rows = try? JSONDecoder().decode([Verified].self, from: data) else {
            return []
        }
        return rows.compactMap { row -> Finding? in
            let verdict = (row.verdict ?? "").lowercased()
            guard verdict != "rejected" else { return nil }
            let f = row.finding
            guard !f.explanation.isEmpty, !f.file.isEmpty else { return nil }
            return Finding(severity: f.severity, file: f.file, line: f.line,
                           explanation: f.explanation, failureScenario: f.failureScenario,
                           category: f.category,
                           confidence: verdict == "confirmed" ? .confirmed : .plausible)
        }
    }
}
