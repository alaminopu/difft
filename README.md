# Difft

A native macOS app for reviewing GitHub pull requests.

Difft shows every changed file in full — not just the changed hunks. Changes are highlighted inline, line numbers meet at a draggable center gutter, and review comments appear as cards anchored to the exact line they belong to.

![Difft showing a side-by-side diff](docs/screenshots/screenshot.png)

## Features

### Diff viewer

Pure SwiftUI — no web view.

- Side-by-side or unified layout
- Full-file context, not just hunks
- Syntax highlighting that follows system appearance
- Word-level emphasis on what actually changed
- A change-overview rail for jumping between edits in long files
- Draggable split between the old and new sides
- Click a line to select it, drag or shift-click for a range, right-click to copy

### Pull requests

PRs load through the `gh` CLI, so there is no OAuth flow and no tokens to manage.

- Filter the list by title, number, or author
- The overview page renders the PR description as markdown
- Changed files show as a collapsible tree with per-folder counts
- Viewed checkboxes and comment badges on each file

### Review comments

Inline comments from GitHub render under the line they anchor to, threads and all, with code blocks syntax-highlighted. Reply and resolve without leaving the app.

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

## Requirements

- macOS 14 or later
- [`gh`](https://cli.github.com), installed and authenticated — check with `gh auth status`
- A local clone of the repository whose PRs you want to review

Difft checks these at launch and tells you what is missing.

## Install

```sh
git clone git@github.com:alamin-br/difft.git
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
swift test        # 78 tests — no network or CLI needed, subprocesses are faked
swift run Difft   # dev build
```

State lives in `~/Library/Application Support/Difft/` — viewed files, chat history, findings, verdicts, and the PR worktrees. All of it survives relaunches.
