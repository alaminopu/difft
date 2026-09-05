# Difft — macOS GitHub PR Review App — Design Spec

Date: 2026-08-29
Status: approved in brainstorming session, pending implementation plan

## Purpose

A native macOS app for reviewing GitHub pull requests locally:

1. View code changes clearly (side-by-side/unified diff, syntax highlighting).
2. Ask Claude clarification questions about the changes, anchored to selected lines.
3. Have Claude run a full review and verify UI changes in a real browser.
4. Generate a self-contained HTML report.

## Decisions made

| Decision | Choice |
|---|---|
| App shell | Native SwiftUI, macOS 14+, Swift 5.10, Xcode project |
| Diff rendering | Pure SwiftUI renderer (approach B) — no WKWebView |
| Claude integration | `claude` CLI subprocess, `-p --output-format stream-json` |
| Verification depth | Checkout PR into git worktree, Claude runs app + drives browser |
| PR source | Any GitHub repo via `gh` CLI; auth is the user's existing `gh auth` |
| Report | Local self-contained HTML file; no posting to GitHub in v1 |

## Architecture

Five modules:

1. **GitHubService** — wraps `gh` CLI subprocess (`gh pr list/view/diff/checkout`).
   No OAuth code. Parses unified diff output into the DiffCore model.
2. **DiffCore** — pure Swift, no UI. Model: `FileDiff`, `Hunk`,
   `Line(kind: context/add/del, oldNo, newNo)`. Computes side-by-side row pairing
   and word-level intra-line diff (Myers over tokens). Unit-testable.
3. **DiffUI** — pure SwiftUI diff renderer (detail below).
4. **AgentService** — spawns `claude` CLI per task inside the PR worktree.
   Task types: clarify, review, verify. Streams events to UI.
5. **ReportBuilder** — collects findings, Q&A, screenshots into one HTML file.

Data flow: pick PR → `gh` fetches diff + metadata → DiffCore parses → DiffUI
renders → user reads, checks off files, selects lines, asks questions →
AgentService answers / reviews / verifies in worktree → ReportBuilder writes
HTML → open in browser.

State: one `ReviewSession` observable object per PR (diff model, chat
transcript, findings, file-viewed flags). Persisted as JSON under
`~/Library/Application Support/Difft/sessions/` so reopening a PR restores
progress. Corrupt session file → renamed `.bak`, fresh session.

## Window layout

Three-pane `NavigationSplitView`:

- **Left sidebar**: PR picker (repo path or URL field + `gh pr list` results);
  changed-file tree with per-file +/− counts and viewed checkboxes; progress
  bar ("12/34 files viewed").
- **Center**: diff pane for the selected file. Toolbar: side-by-side/unified
  toggle, font size, j/k next/prev file keys. (Whitespace toggle cut from v1:
  `gh pr diff` has no ignore-whitespace mode, so it would need a local
  re-diff — not worth it yet.)
- **Right panel** (collapsible), three tabs:
  - **Claude** — chat transcript, streaming answers, context chips showing the
    attached selection.
  - **Findings** — review findings list (severity, file:line); click jumps the
    diff to that line.
  - **Verify** — verification run status, live agent log tail, screenshot grid.
- Bottom status bar: PR title/number/branch, agent state (idle/running +
  cancel), report button.

Selection interaction: drag over line-number gutter selects a range; a floating
"Ask Claude" button appears; the question box pre-fills a context chip like
`file.swift:120-134`. Selected hunk text plus surrounding context goes into the
prompt automatically.

## Diff renderer (approach B core)

- **Rendering:** each file is a lazy `List` of fixed-height monospaced rows,
  one row per line pair. No eager `ScrollView`+`VStack`. Keeps 5k-line diffs
  cheap.
- **Side-by-side:** one list; each row contains left(old) + right(new) halves
  aligned by DiffCore's pairing (context pairs 1:1; del/add blocks paired
  index-wise; unpaired side renders filler). One scroll surface — no synced
  scroll problem.
- **Unified:** same row model, single column, kind-colored background.
- **Syntax highlighting:** Highlightr per line, language from file extension.
  Per-line highlighting loses multi-line token state (e.g. block comments) —
  accepted v1 tradeoff, documented as known issue. Results cached per line,
  computed off-main-actor on file open; rows show plain text until ready.
  Cache is LRU-bounded.
- **Word-level diff:** DiffCore computes intra-line ranges for paired del/add
  lines; renderer overlays brighter background via AttributedString runs,
  merged with syntax colors.
- **Selection:** custom gesture on the gutter — tap sets anchor, drag or
  shift-tap extends. Selected rows tinted; selection state lives in
  ReviewSession. Cmd-C copies selected lines as plain text.
- **Perf target:** open a 300-file / 10k-line PR without beachball. Per-file
  diffs parsed lazily on first view.

## AgentService

**Process model:** `Process` running
`claude -p <prompt> --output-format stream-json --verbose` with cwd = PR
worktree. Newline-delimited JSON parsed off main actor; published as an
`AgentEvent` stream (text delta, tool use, result). Cancel = SIGTERM. One
agent task at a time per session (serial); UI disables triggers while running.

**Worktree:** on first agent task for a PR, `gh pr checkout` into
`git worktree add ~/Library/Application Support/Difft/worktrees/<repo>-pr<N>`
from the user's local clone (clone path asked once per repo, stored). Cleanup
button plus auto-prune of worktrees older than 7 days.

**Task types:**

1. **Clarify** — prompt carries PR title/body, selected lines with 30 lines of
   context, the user question, chat history. Read-only tools
   (`--allowedTools Read,Grep,Glob`) so it can explore the worktree. Answer
   streams into chat.
2. **Review** — full-review prompt: diff summary + instruction to read changed
   files in the worktree; output findings as a JSON block (severity, file,
   line, explanation). Parsed into the Findings tab. Read-only tools.
3. **Verify** — full toolset. Prompt: "PR claims <title/body>. Start the app
   per the repo's own CLAUDE.md/skill instructions, drive the browser,
   screenshot before/after evidence into ./difft-evidence/, write a verdict
   JSON." Claude Code's own browser tools/skills do the driving — the app
   implements no browser logic. The app watches the evidence directory and
   shows screenshots live in the Verify tab.

**Permissions:** clarify/review run `--permission-mode default` with the
read-only allowlist. Verify runs `--dangerously-skip-permissions` inside the
worktree ONLY after an explicit per-run confirmation dialog ("agent will run
code from this PR — sandbox risk"). The dialog is mandatory every run; nothing
is remembered.

**Failure handling:** nonzero exit or malformed JSON → task marked failed, raw
output viewable, retry button. Missing `claude` binary → onboarding sheet with
install instructions.

## ReportBuilder

One self-contained HTML file at
`~/Documents/Difft-reports/<repo>-pr<N>-<date>.html`. Inline CSS; screenshots
base64-embedded. Sections: header (PR meta, verdict badge), findings table
(severity-sorted, linked diff snippets), verification evidence (screenshots +
agent verdict), Q&A transcript, per-file review status, collapsed full diff.
Template is a Swift string builder — no templating dependency. "Generate
report" writes the file and opens it via `NSWorkspace.open`.

## Error handling

- Launch onboarding checks: `gh` exists, `gh auth status` ok, `claude` exists —
  each with fix instructions.
- Network/`gh` failures → per-action error banners; never crash the session.
- Unparseable file diffs (binary, mode change, rename) → file listed with a
  badge, placeholder in renderer, never blocks other files.

## Testing

- **DiffCore:** unit tests on captured `gh pr diff` fixtures — rename, binary,
  mode change, huge lines, empty file, multi-hunk pairing, word-diff ranges.
- **AgentService:** stream-json parser tests on captured claude CLI output
  fixtures; fake-process injection for cancel/failure paths.
- **ReportBuilder:** golden-file HTML test.
- **DiffUI:** minimal smoke tests; main confidence from DiffCore since rows
  are dumb renderers.
- Manual perf check on a 300-file PR before v1 is called done.

## Out of scope (v1)

Posting to GitHub, GitLab support, multi-PR tabs, importing GitHub inline
comments, approve/merge actions, diff editing, App Store signing/distribution.
