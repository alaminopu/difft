# Difft

A native macOS app for reviewing GitHub pull requests.

Difft shows every changed file in full — not just the changed hunks. Changes are highlighted inline, line numbers meet at a draggable center gutter, and review comments appear as cards anchored to the exact line they belong to. Alongside the diff you get every review thread in one list, the branch's commits, and the diff any single commit introduced.

![Side-by-side diff with word-level emphasis](docs/screenshots/diff.png)

## Features

### Diff viewer

Pure SwiftUI — no web view.

- Side-by-side or unified layout
- Full-file context, not just hunks
- Syntax highlighting that follows your Light or Dark choice
- Word-level emphasis on what actually changed
- A change-overview rail for jumping between edits in long files
- Draggable split between the old and new sides
- Click a line to select it, drag or shift-click for a range, right-click to copy or comment
- Your choice of monospaced font and size, applied to the syntax highlighting itself

### Pull requests

PRs load through the `gh` CLI, so there is no OAuth flow and no tokens to manage.

- Filter the list by title, number, or author
- The overview page renders the PR description as markdown
- Changed files show as a collapsible tree with per-folder counts
- Viewed checkboxes, and a badge per file showing its review threads

![PR overview with the description rendered as markdown](docs/screenshots/overview.png)

### Review comments

Inline comments from GitHub render under the line they anchor to, threads and all, with code blocks syntax-highlighted — and `inline code` set as code, since half a review sentence is usually identifiers.

![A review comment anchored to its line in the diff](docs/screenshots/inline-comment.png)

Reply and resolve without leaving the app. Your own comments get an **Edit** action; other people's do not, so there is no button that could only fail.

**Write a comment from the diff.** Select lines, right-click, *Comment on selection*. The composer names exactly where it will land. Because GitHub anchors review comments to the new file, a selection covering pure deletions narrows to the lines that can carry one.

**Commits named in prose are links.** "Fixed in d59f520cc" opens that commit's diff *in the app*, not a browser — resolved from the PR's commits, or from the worktree when the comment names a commit from elsewhere.

**All comments in one place** (⇧⌘C) answers the question you have before you know which file to open: what has been said at all. Every thread, grouped by file.

- Filter by all, unresolved, or resolved
- Search across comment bodies, authors, and paths
- Replies fold into their thread instead of scattering
- Each thread shows the diff hunk it anchors to, so you get the code without leaving the list
- Jump straight from a thread to its line in the diff
- Comments GitHub can no longer anchor, because the diff moved past them, are marked outdated rather than dropped

![Every review thread on the PR, grouped by file](docs/screenshots/comments.png)

### Commits

**All commits** (⇧⌘K) lists the PR's commits newest first, grouped by the day they were authored. Search by message, author, or sha prefix, and expand any commit to read its full message.

![Commits grouped by the day they were authored](docs/screenshots/commits.png)

Click a commit to see the diff it introduced against its own parent — the same full-file context as the PR diff, with its own list of changed files. Review comments are left out there on purpose: they anchor to lines in the PR head, so on an earlier commit they would point at the wrong code.

### Settings

⌘, opens preferences:

- **Appearance** — Light, Dark, or Match System
- **Syntax colours** — Atom One, Xcode, GitHub, Nord, or Solarized, each a light/dark pair
- **Code font** — any monospaced font installed on your Mac, defaulting to SF Mono, with a preview of the characters that separate a good one from a bad one
- **Size** — 9 to 18pt

The font and size are pushed into the syntax highlighter rather than applied around it, so they reach the highlighted code itself.

### Assistant

A side panel with three tools, each running inside a dedicated git worktree of the PR:

| Tool | What it does |
| --- | --- |
| **Chat** | Answers questions about the PR, with read-only access to the code. Attach a line selection as context by right-clicking it. |
| **Findings** | Runs a full review and lists what it found — severity, file, line, explanation. Click a finding to jump to that line in the diff. |
| **Verify** | Starts the app and drives a browser to check that the PR does what it claims, collecting screenshots as evidence. |

Chat and Findings are read-only. They can look at anything and change nothing.

Verify is the exception: it runs the PR's code with permission checks disabled, so it is gated behind an explicit confirmation that names the PR — every run, no remembering.

Cancel any run from the panel. The subprocess is terminated and state returns to idle.

### Reports

One click writes a self-contained HTML file to `~/Documents/Difft-reports/` and opens it in your browser. It holds the findings, the question-and-answer transcript, verification evidence, review status, and the full diff. No external resources, so it is safe to share.

## Keyboard shortcuts

| Keys | Action |
| --- | --- |
| `⇧⌘C` | All review comments |
| `⇧⌘K` | All commits |
| `⌘0` | Back to the PR overview |
| `⌘R` | Refresh the PR |
| `⌥⌘0` | Show or hide the assistant panel |
| `⌘,` | Settings |
| `⌘↩` | Post the comment you are writing |
| `j` / `k` | Next / previous file in the diff |

## Requirements

- macOS 14 or later
- [`gh`](https://cli.github.com), installed and authenticated — check with `gh auth status`
- A local clone of the repository whose PRs you want to review

Difft checks these at launch and tells you what is missing.

## Install

```sh
git clone git@github.com:alaminopu/difft.git
cd difft
scripts/package.sh
cp -R dist/Difft.app /Applications/
```

Open the app, point it at your repo clone with the folder button in the sidebar, and pick a PR.

## Development

Difft is a Swift package with four targets:

| Target | Contents |
| --- | --- |
| `DifftCore` | Diff model, parser, row pairing, selection — pure logic, fully tested |
| `DifftServices` | Subprocesses, sessions, report builder |
| `DifftUI` | The diff renderer |
| `Difft` | The app |

```sh
swift test        # 170 tests — no network or CLI needed, subprocesses are faked
swift run Difft   # dev build
```

State lives in `~/Library/Application Support/Difft/` — viewed files, chat history, findings, verdicts, and the PR worktrees. All of it survives relaunches.
