# Difft

A native macOS app for reviewing GitHub pull requests.

Three lines of context rarely tell you whether a change is correct. Difft shows every changed file end to end, with the review conversation anchored where it happened, the branch's commits, and the diff any single commit introduced.

![Side-by-side diff with word-level emphasis](docs/screenshots/diff.png)

## Install

```sh
brew tap alaminopu/difft https://github.com/alaminopu/difft
brew trust --cask alaminopu/difft/difft
brew install --cask difft
xattr -dr com.apple.quarantine /Applications/Difft.app
```

Or [download the latest release](https://github.com/alaminopu/difft/releases/latest) and drag it to Applications, then run that last line.

Difft is ad-hoc signed rather than notarized, so macOS quarantines it however you get it and Gatekeeper refuses to open it until that flag is cleared. Homebrew requires `brew trust` for third-party casks and no longer offers `--no-quarantine`, so both steps are explicit.

**Requires** macOS 14+, [`gh`](https://cli.github.com) authenticated, and a local clone of the repo you want to review. Difft checks at launch and says what is missing.

Point it at your clone with the folder button, and pick a PR.

![The PR overview you land on](docs/screenshots/overview.png)

## Diff

Pure SwiftUI, no web view. Side-by-side or unified, full-file context, word-level emphasis on what actually changed, and a rail for jumping between edits in long files. Click a line to select it, drag or shift-click for a range, right-click to copy, comment, or ask about it.

## Comments

![A review comment anchored to its line in the diff](docs/screenshots/inline-comment.png)

Threads render under the line they belong to, with `inline code` set as code. Reply, resolve, and edit your own without leaving the app. Select lines and right-click to start a new thread. A commit named in prose — "fixed in d59f520cc" — opens that commit's diff here rather than in a browser.

**⇧⌘C** lists every thread grouped by file, filtered by resolved state and searchable across bodies, authors and paths. Each shows the hunk it anchors to, and jumps to the line.

![Every review thread on the PR, grouped by file](docs/screenshots/comments.png)

## Commits

**⇧⌘K** lists commits newest first, grouped by day. Click one for the diff it introduced against its parent.

![Commits grouped by the day they were authored](docs/screenshots/commits.png)

## Assistant

A side panel running your local agent CLI inside a dedicated git worktree of the PR. **Chat** answers questions with read-only access to the code. **Findings** runs a review and lists what it found; click one to jump to the line. **Verify** starts the app and drives a browser to check the PR does what it claims.

Chat and Findings can look at anything and change nothing. Verify runs the PR's code with permission checks disabled, so it asks every time, naming the PR.

**Reports** write a self-contained HTML file to `~/Documents/Difft-reports/` — findings, transcript, evidence, and the full diff, with no external resources.

## Settings

⌘, sets appearance, syntax colours, and the code font and size. The font is pushed into the highlighter rather than applied around it, so it reaches the highlighted code.

## Shortcuts

| | |
| --- | --- |
| `⇧⌘C` `⇧⌘K` | Comments · Commits |
| `⌘0` `⌘R` | Overview · Refresh |
| `⌥⌘0` | Assistant panel |
| `⌘,` `⌘↩` | Settings · Post comment |
| `j` `k` | Next · previous file |

## Development

```sh
swift test        # 170 tests, no network or CLI needed
swift run Difft   # dev build
scripts/release.sh 0.1.0
```

Four targets: `DifftCore` (diff model and parsing, pure logic), `DifftServices` (subprocesses, sessions, reports), `DifftUI` (the renderer), `Difft` (the app).

State lives in `~/Library/Application Support/Difft/` — viewed files, chat, findings, and the PR worktrees — and survives relaunches.
