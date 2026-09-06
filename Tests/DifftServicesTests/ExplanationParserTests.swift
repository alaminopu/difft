import XCTest
@testable import DifftServices

final class ExplanationParserTests: XCTestCase {
    private func wrap(_ json: String) -> String {
        "Here is the walkthrough.\n\n```json\n\(json)\n```\n"
    }

    func testParsesAFullWalkthrough() {
        let e = ExplanationParser.parse(wrap("""
        {
          "summary": "Replaces the polling loop with a file watcher.",
          "motivation": "The loop woke every 2s and kept the disk hot.",
          "areas": [
            {
              "title": "Watcher replaces the timer",
              "detail": "Old: a Timer re-listed the directory. New: FSEvents.",
              "files": ["Sources/Watch.swift", "Sources/App.swift"],
              "anchors": [{"file": "Sources/Watch.swift", "line": 42, "what": "The callback"}]
            }
          ],
          "risks": [{"file": "Sources/Watch.swift", "line": 60, "what": "No debounce on rapid writes"}],
          "outOfScope": ["Windows support"]
        }
        """))
        XCTAssertEqual(e?.summary, "Replaces the polling loop with a file watcher.")
        XCTAssertEqual(e?.areas.count, 1)
        XCTAssertEqual(e?.areas.first?.files.count, 2)
        XCTAssertEqual(e?.areas.first?.anchors.first?.line, 42)
        XCTAssertEqual(e?.risks.first?.what, "No debounce on rapid writes")
        XCTAssertEqual(e?.outOfScope, ["Windows support"])
    }

    func testParsesABareObjectWithNoFence() {
        let e = ExplanationParser.parse(#"{"summary": "Bumps a dependency."}"#)
        XCTAssertEqual(e?.summary, "Bumps a dependency.")
        XCTAssertTrue(e?.areas.isEmpty ?? false)
    }

    /// The shape comes from a model, so one odd field must cost that field and
    /// nothing more.
    func testMissingAndMistypedFieldsDegradeRatherThanFail() {
        let e = ExplanationParser.parse(wrap("""
        {
          "summary": "Adds a cache.",
          "areas": [
            {"title": "Cache", "anchors": [{"file": "a.swift", "line": "17", "what": "insert"}]}
          ],
          "risks": [{"what": "Unbounded growth"}]
        }
        """))
        XCTAssertEqual(e?.summary, "Adds a cache.")
        XCTAssertEqual(e?.motivation, "")
        XCTAssertEqual(e?.areas.first?.detail, "")
        XCTAssertEqual(e?.areas.first?.files, [])
        // A line written as a string still resolves.
        XCTAssertEqual(e?.areas.first?.anchors.first?.line, 17)
        // A risk with no file is still a risk.
        XCTAssertEqual(e?.risks.first?.what, "Unbounded growth")
        XCTAssertEqual(e?.risks.first?.file, "")
        XCTAssertNil(e?.risks.first?.line)
    }

    /// Entries carrying no text are noise in the view, so they are dropped
    /// during decode rather than rendered as empty rows.
    func testEmptyEntriesAreDropped() {
        let e = ExplanationParser.parse(wrap("""
        {
          "summary": "S",
          "areas": [{"title": "", "detail": ""}, {"title": "Real", "detail": "d"}],
          "risks": [{"file": "a.swift", "line": 1, "what": ""}],
          "outOfScope": ["", "Kept"]
        }
        """))
        XCTAssertEqual(e?.areas.count, 1)
        XCTAssertEqual(e?.areas.first?.title, "Real")
        XCTAssertTrue(e?.risks.isEmpty ?? false)
        XCTAssertEqual(e?.outOfScope, ["Kept"])
    }

    func testNilWhenNothingUsableCameBack() {
        XCTAssertNil(ExplanationParser.parse(""))
        XCTAssertNil(ExplanationParser.parse("I could not read the diff."))
        XCTAssertNil(ExplanationParser.parse(wrap("[]")))
        // A well-formed but entirely empty object is not a walkthrough, and
        // must not overwrite a good one from an earlier run.
        XCTAssertNil(ExplanationParser.parse(wrap(#"{"summary": "", "areas": []}"#)))
    }

    func testProseAfterTheBlockIsIgnored() {
        let text = wrap(#"{"summary": "S"}"#) + "\nLet me know if you want more detail."
        XCTAssertEqual(ExplanationParser.parse(text)?.summary, "S")
    }

    /// The explanation is persisted with the session, so it has to survive a
    /// round trip — including the stamps the app adds after parsing.
    func testRoundTripsThroughCodable() throws {
        let original = ExplanationParser.parse(wrap("""
        {
          "summary": "S", "motivation": "M",
          "areas": [{"title": "T", "detail": "D", "files": ["a"], "anchors": []}],
          "risks": [{"file": "a", "line": 3, "what": "R"}],
          "outOfScope": ["O"]
        }
        """))!.stamped(headSHA: "abc1234")
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(DiffExplanation.self, from: data)
        XCTAssertEqual(back.headSHA, "abc1234")
        XCTAssertEqual(back.summary, original.summary)
        XCTAssertEqual(back.areas, original.areas)
        XCTAssertEqual(back.risks, original.risks)
        XCTAssertEqual(back.generatedAt.timeIntervalSince1970,
                       original.generatedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    /// The load-bearing/mechanical split, "read this first", and the
    /// stated-vs-inferred flag are the parts the survey of published
    /// explain-diff skills converged on. Each has to survive the parser.
    func testParsesReviewerFields() {
        let e = ExplanationParser.parse(wrap("""
        {
          "summary": "S",
          "motivation": "Reconstructed from the call sites.",
          "motivationInferred": true,
          "readFirst": [{"file": "a.swift", "line": 9, "what": "The ordering assumption"}],
          "areas": [{"title": "T", "detail": "D", "files": ["a.swift"], "anchors": []}],
          "risks": [],
          "mechanical": ["Renamed 30 files from old/ to new/"],
          "outOfScope": []
        }
        """))
        XCTAssertEqual(e?.motivationInferred, true)
        XCTAssertEqual(e?.readFirst.first?.line, 9)
        XCTAssertEqual(e?.mechanical, ["Renamed 30 files from old/ to new/"])
        XCTAssertTrue(e?.risks.isEmpty ?? false)
    }

    /// Explanations written before these fields existed are already on disk.
    func testOlderExplanationsStillDecode() throws {
        let e = try XCTUnwrap(ExplanationParser.parse(wrap("""
        {"summary": "S", "motivation": "M", "areas": [{"title": "T", "detail": "D"}],
         "risks": [], "outOfScope": []}
        """)))
        XCTAssertFalse(e.motivationInferred)
        XCTAssertTrue(e.readFirst.isEmpty)
        XCTAssertTrue(e.mechanical.isEmpty)
        XCTAssertEqual(e.areas.count, 1)
    }

    /// A walkthrough that is only mechanical notes is still a walkthrough —
    /// `isEmpty` must not throw it away.
    func testMechanicalOnlyIsNotEmpty() {
        let e = ExplanationParser.parse(wrap(#"{"mechanical": ["Reformatted everything"]}"#))
        XCTAssertEqual(e?.mechanical.count, 1)
    }


    /// The gate only works if a question is well-formed. A stem with one
    /// option, or an answer index pointing past the end, would render as a
    /// broken control — those are dropped at decode.
    func testQuizDropsUnusableQuestions() {
        let e = ExplanationParser.parse(wrap("""
        {
          "summary": "S",
          "quiz": [
            {"question": "Why this shape?", "options": ["A", "B", "C"], "answer": 2, "why": "because"},
            {"question": "No options", "options": [], "answer": 0, "why": "x"},
            {"question": "Out of range", "options": ["A", "B"], "answer": 7, "why": "x"},
            {"question": "", "options": ["A", "B"], "answer": 0, "why": "x"}
          ]
        }
        """))
        XCTAssertEqual(e?.quiz.count, 1)
        XCTAssertEqual(e?.quiz.first?.answer, 2)
        XCTAssertEqual(e?.quiz.first?.options.count, 3)
    }

    func testQuizSurvivesPersistence() throws {
        let e = try XCTUnwrap(ExplanationParser.parse(wrap("""
        {"summary": "S", "quiz": [{"question": "Q", "options": ["A", "B"], "answer": 1, "why": "W"}]}
        """)))
        let back = try JSONDecoder().decode(DiffExplanation.self, from: JSONEncoder().encode(e))
        XCTAssertEqual(back.quiz, e.quiz)
    }

}
