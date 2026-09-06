import Foundation

/// Decoding helpers for agent-produced JSON.
///
/// The shape comes from a language model, not from a contract we control, so
/// a missing or oddly-typed field must cost that one field — never the whole
/// explanation. Every accessor here falls back rather than throwing.
private extension KeyedDecodingContainer {
    func string(_ key: Key) -> String {
        (try? decodeIfPresent(String.self, forKey: key)) ?? nil ?? ""
    }

    func strings(_ key: Key) -> [String] {
        (try? decodeIfPresent([String].self, forKey: key)) ?? nil ?? []
    }

    func list<T: Decodable>(_ key: Key, of: T.Type) -> [T] {
        (try? decodeIfPresent([T].self, forKey: key)) ?? nil ?? []
    }

    /// Models routinely write a line number as `"42"` rather than `42`.
    func lenientInt(_ key: Key) -> Int? {
        if let n = (try? decodeIfPresent(Int.self, forKey: key)) ?? nil { return n }
        if let s = (try? decodeIfPresent(String.self, forKey: key)) ?? nil { return Int(s) }
        return nil
    }
}

/// A place in the diff worth opening, named by the explanation.
public struct ExplainAnchor: Codable, Equatable, Sendable {
    public let file: String
    public let line: Int?
    public let what: String

    enum CodingKeys: String, CodingKey { case file, line, what }

    public init(file: String, line: Int?, what: String) {
        self.file = file; self.line = line; self.what = what
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file = c.string(.file)
        line = c.lenientInt(.line)
        what = c.string(.what)
    }

    /// An anchor with nothing to say is not worth a row.
    public var isUsable: Bool { !what.isEmpty }
}

/// One coherent slice of the change — a behaviour or concern, which may span
/// several files, rather than one entry per file.
public struct ExplainArea: Codable, Equatable, Sendable {
    public let title: String
    public let detail: String
    public let files: [String]
    public let anchors: [ExplainAnchor]

    enum CodingKeys: String, CodingKey { case title, detail, files, anchors }

    public init(title: String, detail: String, files: [String], anchors: [ExplainAnchor]) {
        self.title = title; self.detail = detail; self.files = files; self.anchors = anchors
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.string(.title)
        detail = c.string(.detail)
        files = c.strings(.files)
        anchors = c.list(.anchors, of: ExplainAnchor.self).filter(\.isUsable)
    }
}

/// One comprehension-gate question.
///
/// The gate is the idea six of the surveyed explain-diff skills share, and
/// cniska's framing is the sharpest: you do not pass on code whose explanation
/// you cannot give. It is not education — it is a check on yourself before you
/// approve.
public struct QuizQuestion: Codable, Equatable, Sendable {
    public let question: String
    public let options: [String]
    /// Index into `options`. Out-of-range means the question is unusable.
    public let answer: Int
    /// Shown after answering, either way — the explanation is where the value
    /// is, not the score.
    public let why: String

    enum CodingKeys: String, CodingKey { case question, options, answer, why }

    public init(question: String, options: [String], answer: Int, why: String) {
        self.question = question; self.options = options; self.answer = answer; self.why = why
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        question = c.string(.question)
        options = c.strings(.options).filter { !$0.isEmpty }
        answer = c.lenientInt(.answer) ?? -1
        why = c.string(.why)
    }

    /// A question needs a stem, at least two choices, and an answer that
    /// points at one of them. Anything less renders as a broken control.
    public var isUsable: Bool {
        !question.isEmpty && options.count >= 2 && options.indices.contains(answer)
    }
}

/// A structured walkthrough of a PR, rendered natively rather than as a wall
/// of chat text.
public struct DiffExplanation: Codable, Equatable, Sendable {
    public let summary: String
    public let motivation: String
    /// Whether `motivation` was read from a stated source (description, commit
    /// messages, linked issue) or reconstructed from the code. A guess
    /// presented as fact is the failure mode every explain-diff skill warns
    /// about, so the view labels it.
    public let motivationInferred: Bool
    /// The one or two places a reviewer must not skim. Ordering, not danger —
    /// `risks` covers danger.
    public let readFirst: [ExplainAnchor]
    public let areas: [ExplainArea]
    public let risks: [ExplainAnchor]
    /// Bulk with no decisions in it — renames, moves, formatting, generated
    /// files — aggregated to one line each so it can be seen and skipped.
    public let mechanical: [String]
    public let outOfScope: [String]
    /// The comprehension gate. Empty is valid — a change with nothing
    /// non-obvious in it has nothing worth asking about.
    public let quiz: [QuizQuestion]
    /// Head SHA this was generated against, so a refresh that moves the
    /// branch on can say the walkthrough predates the current code.
    public let headSHA: String?
    public let generatedAt: Date

    enum CodingKeys: String, CodingKey {
        case summary, motivation, motivationInferred, readFirst, areas, risks
        case mechanical, outOfScope, quiz, headSHA, generatedAt
    }

    public init(summary: String, motivation: String, motivationInferred: Bool = false,
                readFirst: [ExplainAnchor] = [], areas: [ExplainArea],
                risks: [ExplainAnchor], mechanical: [String] = [], outOfScope: [String],
                quiz: [QuizQuestion] = [],
                headSHA: String? = nil, generatedAt: Date = Date()) {
        self.summary = summary; self.motivation = motivation
        self.motivationInferred = motivationInferred; self.readFirst = readFirst
        self.areas = areas; self.risks = risks; self.mechanical = mechanical
        self.outOfScope = outOfScope; self.quiz = quiz
        self.headSHA = headSHA; self.generatedAt = generatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = c.string(.summary)
        motivation = c.string(.motivation)
        motivationInferred = ((try? c.decodeIfPresent(Bool.self, forKey: .motivationInferred)) ?? nil) ?? false
        readFirst = c.list(.readFirst, of: ExplainAnchor.self).filter(\.isUsable)
        areas = c.list(.areas, of: ExplainArea.self).filter { !$0.title.isEmpty || !$0.detail.isEmpty }
        risks = c.list(.risks, of: ExplainAnchor.self).filter(\.isUsable)
        mechanical = c.strings(.mechanical).filter { !$0.isEmpty }
        outOfScope = c.strings(.outOfScope).filter { !$0.isEmpty }
        quiz = c.list(.quiz, of: QuizQuestion.self).filter(\.isUsable)
        // Absent from the agent's own JSON — the app stamps both after
        // parsing, and they survive a round trip through the session store.
        headSHA = (try? c.decodeIfPresent(String.self, forKey: .headSHA)) ?? nil
        generatedAt = ((try? c.decodeIfPresent(Date.self, forKey: .generatedAt)) ?? nil) ?? Date()
    }

    /// Nothing usable came back — distinct from "has not run yet", which the
    /// view renders differently.
    public var isEmpty: Bool {
        summary.isEmpty && motivation.isEmpty && areas.isEmpty
            && risks.isEmpty && readFirst.isEmpty && mechanical.isEmpty
            && outOfScope.isEmpty && quiz.isEmpty
    }

    /// Same explanation, restamped. Used once the run's provenance is known.
    public func stamped(headSHA: String?, at date: Date = Date()) -> DiffExplanation {
        DiffExplanation(summary: summary, motivation: motivation,
                        motivationInferred: motivationInferred, readFirst: readFirst,
                        areas: areas, risks: risks, mechanical: mechanical,
                        outOfScope: outOfScope, quiz: quiz,
                        headSHA: headSHA, generatedAt: date)
    }
}

/// Pulls a fenced ```json block out of an agent's final message.
///
/// Shared by the findings and explanation parsers so the two cannot disagree
/// about what counts as the payload.
public enum JSONBlock {
    public static func extract(from text: String) -> String {
        guard let fence = text.range(of: "```json"),
              let end = text.range(of: "```", range: fence.upperBound..<text.endIndex) else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(text[fence.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum ExplanationParser {
    /// `nil` when the agent produced nothing decodable — the view then keeps
    /// the previous explanation rather than replacing it with a blank one.
    public static func parse(_ finalText: String) -> DiffExplanation? {
        guard let data = JSONBlock.extract(from: finalText).data(using: .utf8),
              let parsed = try? JSONDecoder().decode(DiffExplanation.self, from: data),
              !parsed.isEmpty else { return nil }
        return parsed
    }
}
