import Foundation

public enum AgentEvent: Equatable, Sendable {
    case textDelta(String)
    /// `detail` is a short human-readable summary of the tool's input (the
    /// command for Bash, the path for Read/Edit, the pattern for Grep…) —
    /// a bare list of "Bash" lines says nothing about what the agent is doing.
    case toolUse(name: String, detail: String?)
    case result(isError: Bool, text: String)
    case unknown(String)
}

public enum StreamJSONParser {
    public static func event(fromLine line: String) -> AgentEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any],
              let type = obj["type"] as? String else {
            return .unknown(trimmed)
        }
        switch type {
        case "assistant":
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]],
                  let first = content.first, let itemType = first["type"] as? String else {
                return .unknown(trimmed)
            }
            if itemType == "text", let text = first["text"] as? String { return .textDelta(text) }
            if itemType == "tool_use", let name = first["name"] as? String {
                return .toolUse(name: name, detail: toolDetail(name: name, input: first["input"] as? [String: Any]))
            }
            return .unknown(trimmed)
        case "result":
            let isError = obj["is_error"] as? Bool ?? false
            let text = obj["result"] as? String ?? ""
            return .result(isError: isError, text: text)
        default:
            return .unknown(trimmed)
        }
    }

    /// Picks the field that best describes what a tool call is doing.
    static func toolDetail(name: String, input: [String: Any]?) -> String? {
        guard let input else { return nil }
        let keysByTool: [String: [String]] = [
            "Bash": ["description", "command"],
            "Read": ["file_path"],
            "Edit": ["file_path"],
            "Write": ["file_path"],
            "NotebookEdit": ["notebook_path"],
            "Grep": ["pattern"],
            "Glob": ["pattern"],
            "WebFetch": ["url"],
            "WebSearch": ["query"],
            "Task": ["description"],
            "Skill": ["skill"],
        ]
        let candidates = keysByTool[name] ?? ["description", "command", "file_path", "pattern", "url", "query"]
        for key in candidates {
            if let value = input[key] as? String, !value.isEmpty {
                return value.replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
