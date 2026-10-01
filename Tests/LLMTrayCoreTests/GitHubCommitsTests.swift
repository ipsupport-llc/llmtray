import XCTest
@testable import LLMTrayCore

final class GitHubCommitsTests: XCTestCase {
    /// Only a tip ahead of the commit in use is an update: one behind (a
    /// branch left behind), the same, or rewritten history isn't.
    func testOnlyAheadIsNewer() {
        XCTAssertTrue(GitHubCommits.isNewer(compareStatus: "ahead"))
        XCTAssertFalse(GitHubCommits.isNewer(compareStatus: "behind"))
        XCTAssertFalse(GitHubCommits.isNewer(compareStatus: "identical"))
        XCTAssertFalse(GitHubCommits.isNewer(compareStatus: "diverged"))
        XCTAssertFalse(GitHubCommits.isNewer(compareStatus: ""))
    }
}
