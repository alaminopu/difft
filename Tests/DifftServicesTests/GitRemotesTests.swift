import XCTest
@testable import DifftServices

final class GitRemotesTests: XCTestCase {
    /// The case this exists for: a fork checkout, where `gh` resolves the
    /// upstream and `origin` is the fork. Fetching `pull/N/head` from `origin`
    /// fails, which silently cost the full-context diff and the head SHA.
    func testPicksTheRemoteMatchingWhatGHResolved() {
        let output = """
        origin\tgit@github.com:someone/air.git (fetch)
        origin\tgit@github.com:someone/air.git (push)
        upstream\tgit@github.com:feldroy/air.git (fetch)
        upstream\tgit@github.com:feldroy/air.git (push)
        """
        XCTAssertEqual(GitRemotes.matching(nameWithOwner: "feldroy/air", in: output), "upstream")
        XCTAssertEqual(GitRemotes.matching(nameWithOwner: "someone/air", in: output), "origin")
    }

    func testHandlesHTTPSAndMissingDotGit() {
        let output = """
        origin\thttps://github.com/acme/tool.git (fetch)
        mirror\thttps://github.com/acme/other (fetch)
        """
        XCTAssertEqual(GitRemotes.matching(nameWithOwner: "acme/tool", in: output), "origin")
        XCTAssertEqual(GitRemotes.matching(nameWithOwner: "acme/other", in: output), "mirror")
    }

    /// GitHub treats owner and repo names case-insensitively, and `gh` does
    /// not necessarily echo back the casing the remote URL was written in.
    func testMatchIsCaseInsensitive() {
        let output = "origin\tgit@github.com:BaseRow/BaseRow.git (fetch)"
        XCTAssertEqual(GitRemotes.matching(nameWithOwner: "baserow/baserow", in: output), "origin")
    }

    /// Several remotes can point at the same repository; `origin` is the
    /// conventional one and picking another would surprise.
    func testPrefersOriginWhenSeveralMatch() {
        let output = """
        backup\tgit@github.com:acme/tool.git (fetch)
        origin\tgit@github.com:acme/tool.git (fetch)
        """
        XCTAssertEqual(GitRemotes.matching(nameWithOwner: "acme/tool", in: output), "origin")
    }

    /// Nothing matched is not an error — the caller falls back to "origin",
    /// which is what the app did before it resolved remotes at all.
    func testNilWhenNothingMatches() {
        XCTAssertNil(GitRemotes.matching(nameWithOwner: "acme/tool",
                                         in: "origin\tgit@github.com:other/thing.git (fetch)"))
        XCTAssertNil(GitRemotes.matching(nameWithOwner: "acme/tool", in: ""))
        XCTAssertNil(GitRemotes.matching(nameWithOwner: "", in: "origin\tx (fetch)"))
    }

    func testSlugParsing() {
        XCTAssertEqual(GitRemotes.slug(from: "git@github.com:a/b.git"), "a/b")
        XCTAssertEqual(GitRemotes.slug(from: "https://github.com/a/b"), "a/b")
        XCTAssertEqual(GitRemotes.slug(from: "ssh://git@github.com/a/b.git"), "a/b")
        XCTAssertEqual(GitRemotes.slug(from: "https://user@github.com/a/b/"), "a/b")
        XCTAssertNil(GitRemotes.slug(from: "notaurl"))
    }
}
