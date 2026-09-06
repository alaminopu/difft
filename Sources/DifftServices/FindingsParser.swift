import Foundation

public enum FindingsParser {
    public static func parse(_ finalText: String) -> [Finding] {
        guard let data = JSONBlock.extract(from: finalText).data(using: .utf8),
              let findings = try? JSONDecoder().decode([Finding].self, from: data) else {
            return []
        }
        return findings
    }
}
