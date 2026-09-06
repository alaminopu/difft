import Foundation

public enum AgentTask: Sendable {
    case clarify(pr: PullRequest, selection: String?, question: String, history: [ChatMessage])
    case review(pr: PullRequest, diffSummary: String)
    /// Walk a reviewer through the PR before they read it. Read-only, and
    /// answers in JSON so the app can render it as a view rather than chat.
    case explain(pr: PullRequest, diffSummary: String)
    /// Write a minimal fix for one review finding. Gets file-edit tools but
    /// no shell — it changes files in the PR's disposable worktree and runs
    /// nothing, so it never needs `--dangerously-skip-permissions`.
    case fix(pr: PullRequest, finding: Finding)

    public var prompt: String {
        switch self {
        case let .clarify(pr, selection, question, history):
            var p = """
            You are helping review GitHub PR #\(pr.number): \(pr.title)

            PR description:
            \(pr.body)

            You are inside a checkout of the PR branch. You may Read/Grep/Glob to build context.
            """
            if !history.isEmpty {
                p += "\n\nConversation so far:\n"
                for m in history { p += "\(m.role): \(m.text)\n" }
            }
            if let sel = selection {
                p += "\n\nThe reviewer selected these diff lines:\n\(sel)\n"
            }
            p += "\nReviewer question: \(question)\nAnswer concisely and concretely."
            return p

        case let .review(pr, diffSummary):
            return """
            Review GitHub PR #\(pr.number): \(pr.title)

            PR description:
            \(pr.body)

            Changed files summary:
            \(diffSummary)

            You are inside a checkout of the PR branch. Read the changed files and review for bugs, \
            security issues, and regressions. Then output your findings as a fenced json block: \
            a JSON array of objects with keys "severity" (high|medium|low), "file", "line" (integer), \
            "explanation". Output the json block even if empty.
            """

        case let .fix(pr, finding):
            return """
            You are fixing one review finding in GitHub PR #\(pr.number): \(pr.title)

            Finding (\(finding.severity)) at \(finding.file):\(finding.line)
            \(finding.explanation)

            You are inside a checkout of the PR branch. Make the smallest change
            that addresses the finding:
            - Edit only what the finding requires; do not refactor around it.
            - Match the surrounding code's style and conventions.
            - If the finding is wrong or the fix needs a decision only the author
              can make, change nothing and say so.
            - Do not commit, stage, or push anything.

            Finish with a short summary: what you changed and why, or why you
            changed nothing.
            """

        case let .explain(pr, diffSummary):
            // Shaped by a survey of 14 published explain-diff skills. Two
            // lineages exist: a teaching one (background/intuition/quiz, output
            // as a standalone HTML page) and a reviewer one. Difft renders its
            // own diff next to this, so the reviewer lineage is the target and
            // the HTML half is dead weight. The load-bearing/mechanical split,
            // "read this first", stated-vs-inferred intent, and the risk
            // taxonomy all come from that reading.
            return """
            You are explaining GitHub PR #\(pr.number) to a reviewer who is about to
            read the diff for the first time.

            Explain the why and the risk. Never the what — the diff carries the what,
            and it is on screen beside your answer. A file-by-file recital is worth
            nothing to this reader.

            Title: \(pr.title)
            Branch: \(pr.headRefName) by \(pr.authorLogin)

            PR description:
            \(pr.body.isEmpty ? "(none)" : pr.body)

            Changed files:
            \(diffSummary)

            You are inside a checkout of the PR branch.

            1. Read the changed files, and enough of what surrounds them to understand
            the change in context: who calls the touched code, what it did before,
            what invariants it relies on. A diff hunk header names the enclosing
            function by a heuristic and is sometimes wrong — trust the file, not the
            header.
            2. Find the spine. Name the one logical change and the problem it solves.
            Intent that is STATED somewhere — the description, commit messages, a
            linked issue, a comment — beats intent you reconstruct from code. Look
            for it before inferring, and set "motivationInferred" to true when you
            end up inferring anyway. A guess presented as fact is the worst thing
            you can do here.
            3. Separate load-bearing from mechanical. Load-bearing means a decision
            was made: a new branch or condition, a changed contract, an ordering or
            concurrency choice, a new dependency. Mechanical means renames, moves,
            formatting, generated files, mass find-and-replace. Mechanical work goes
            in "mechanical" as one aggregated line each — never thirty entries for
            thirty renamed files — and never as an area.
            4. Group the load-bearing work into areas by BEHAVIOUR or CONCERN, not by
            file. One area may span several files; one file may appear in several
            areas. Aim for 2-6 areas; a PR that genuinely does one thing gets one.
            5. Answer with a single fenced json block and nothing after it.

            ```json
            {
              "summary": "Two or three plain sentences: the one logical change and the problem it solves. No file names, no line counts.",
              "motivation": "Why the change exists. Where it is stated, say where. Where it is not discoverable at all, say that plainly rather than inventing one.",
              "motivationInferred": false,
              "readFirst": [
                {"file": "path/from/the/changed-files/list.ext", "line": 42, "what": "The one or two places a reviewer must not skim, and why"}
              ],
              "areas": [
                {
                  "title": "Short name for this slice of the change",
                  "detail": "What it is for, the load-bearing decision and — where it is not obvious — the alternative that was not taken, and what a reviewer should scrutinise. Name the old behaviour and the new one where that is the point.",
                  "files": ["path/from/the/changed-files/list.ext"],
                  "anchors": [
                    {"file": "path/from/the/changed-files/list.ext", "line": 42, "what": "Why this exact line is the one to open"}
                  ]
                }
              ],
              "risks": [
                {"file": "path/or/null", "line": 42, "what": "A concrete way this could go wrong"}
              ],
              "mechanical": ["Renamed 30 files from services/old/ to services/new/", "Reformatted the whole web-frontend directory"],
              "outOfScope": ["Something a reviewer might expect to find here and will not"],
              "quiz": [
                {
                  "question": "A question only someone who grasped the change can answer",
                  "options": ["...", "...", "..."],
                  "answer": 0,
                  "why": "Why that answer is right, and what the others get wrong"
                }
              ]
            }
            ```

            Rules for the content:
            - Every claim must be something you saw in the code. Never describe a
            change the diff does not make, and never quote the diff back — no code
            blocks, no pasted lines. The reader has them.
            - `anchors` and `readFirst` point at the load-bearing edit, not at every
            edit. At most 3 anchors per area, and none at all is fine. Use the NEW
            file's line numbers, and file paths exactly as they appear in the
            changed-files list.
            - `risks` must be concrete and specific to this diff. The ones worth
            finding are usually: an implicit contract or invariant the change now
            depends on, an ordering or concurrency assumption, a migration that has
            to run first, a case that silently behaves differently now, a trust
            dependency where one component assumes something another enforces
            without checking — especially across a process or network boundary, and
            a non-trivial file changed with no matching change to its tests. Never
            "add tests", never "consider performance", never a restatement of what
            the code does. If you find none, return an empty list — that is a real
            answer and a useful one.
            - This is not a code review. Difft has a separate reviewer for defects.
            Name what a reviewer should scrutinise and why; do not hand down a
            verdict, and do not turn into a security audit. If the change touches
            something sensitive, one risk entry saying so is the whole job.
            - Measure length by how much meaning the change carries, not by how many
            lines it touches. A 2000-line reformat with one real decision in it gets
            a short answer.
            - If the diff is genuinely too large to read honestly, say so in
            `summary` and explain the part you did read, rather than producing a
            confident summary of something you skimmed.
            - `quiz` is a comprehension gate, not a lesson: two to four multiple-choice
            questions a reviewer should be able to answer before approving. Ask why
            this shape and not the alternative, what breaks if X changes, where an
            invariant lives. Never syntax, never trivia, never a fact recoverable by
            skimming the diff. Exactly one correct option; distractors must be real
            misunderstandings someone could hold after reading the change, never
            jokes or impossible claims. Vary which index is correct — do not always
            put it first. Return an empty list when the change has nothing
            non-obvious in it; that is a real answer.
            - Be brief. The whole thing should be readable in under two minutes.
            """
        }
    }

    public var cliArguments: [String] {
        let base = ["-p", prompt, "--output-format", "stream-json", "--verbose"]
        switch self {
        case .clarify, .review, .explain:
            return base + ["--allowedTools", "Read,Grep,Glob"]
        case .fix:
            // Edit/Write but deliberately no Bash: the agent changes files in
            // the worktree, it does not run anything.
            return base + ["--allowedTools", "Read,Grep,Glob,Edit,Write"]
        }
    }
}
