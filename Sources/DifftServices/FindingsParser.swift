import Foundation

public enum FindingsParser {
    public static func parse(_ finalText: String) -> [Finding] {
        let candidate: String
        if let fenceStart = finalText.range(of: "```json"),
           let fenceEnd = finalText.range(of: "```", range: fenceStart.upperBound..<finalText.endIndex) {
            candidate = String(finalText[fenceStart.upperBound..<fenceEnd.lowerBound])
        } else {
            candidate = finalText
        }
        guard let data = candidate.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let findings = try? JSONDecoder().decode([Finding].self, from: data) else {
            return []
        }
        return findings
    }
}
