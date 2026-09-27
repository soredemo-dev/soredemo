import Foundation
import Testing
@testable import Soredemo

// The update check's decisions, from a response to GitHub's `releases/latest` — which is data
// written by whoever controls the release, so every field is treated as untrusted.

private func release(tag: String, page: String) -> Data {
    Data(#"{"tag_name": "\#(tag)", "html_url": "\#(page)", "name": "anything"}"#.utf8)
}
private let page = "https://github.com/soredemo-dev/soredemo/releases/tag/v1.2.0"

@Test func versionsCompareAsNumbersNotText() throws {
    let v = { (s: String) throws in try #require(ReleaseVersion(s), "\(s) did not parse") }
    #expect(try v("1.10") > (try v("1.9")), "1.10 is newer than 1.9, though it sorts earlier as text")
    #expect(try v("v1.2.0") == (try v("1.2")), "a leading v and a trailing zero do not make a new version")
    #expect(try v("2") > (try v("1.99.99")))
    #expect(ReleaseVersion("") == nil && ReleaseVersion("latest") == nil && ReleaseVersion("1..2") == nil)
}

@Test func aNewerReleaseIsOfferedWithItsPage() {
    #expect(UpdateVerdict.from(status: 200, body: release(tag: "v1.2.0", page: page), current: "1.0")
            == .available(version: "1.2.0", page: URL(string: page)!))
}

@Test func theSameOrAnOlderReleaseIsUpToDate() {
    #expect(UpdateVerdict.from(status: 200, body: release(tag: "v1.0", page: page), current: "1.0") == .upToDate)
    #expect(UpdateVerdict.from(status: 200, body: release(tag: "v0.9", page: page), current: "1.0") == .upToDate)
}

@Test func aRepositoryWithNoReleaseIsItsOwnAnswer() {
    #expect(UpdateVerdict.from(status: 404, body: Data(), current: "1.0") == .noReleaseYet)
}

/// **The page is opened only if it is this project's release page.** Anything else in the
/// response is somebody else's link, and following it is what the check must never do.
@Test func aPageThatIsNotThisProjectsReleasePageIsRefused() {
    for foreign in ["https://example.com/soredemo.dmg",
                    "http://github.com/soredemo-dev/soredemo/releases/tag/v9",
                    "https://github.com/someone-else/soredemo/releases/tag/v9",
                    "https://github.com.evil.example/soredemo-dev/soredemo/releases/tag/v9",
                    "https://github.com/soredemo-dev/soredemo/archive/v9.zip"] {
        #expect(UpdateVerdict.from(status: 200, body: release(tag: "v9", page: foreign), current: "1.0")
                == .unreadable, "\(foreign)")
    }
}

@Test func aResponseThatCannotBeReadIsUnreadableNotUpToDate() {
    #expect(UpdateVerdict.from(status: 200, body: Data("not json".utf8), current: "1.0") == .unreadable)
    #expect(UpdateVerdict.from(status: 200, body: release(tag: "nightly", page: page), current: "1.0") == .unreadable)
    #expect(UpdateVerdict.from(status: 500, body: Data(), current: "1.0") == .unreadable)
    #expect(UpdateVerdict.from(status: 200, body: release(tag: "v2", page: page), current: "") == .unreadable)
}
