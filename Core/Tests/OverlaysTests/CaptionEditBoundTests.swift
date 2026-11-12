import Testing
@testable import Overlays

// The agent's caption edit is bounded by how much of a line it changes
// (`docs/design/2026-11-12-captions-that-know-what-was-on-screen.md`, decision 3).

@Suite struct CaptionEditBoundTests {
    @Test func aMisheardNameCorrectedIsWithinTheBound() {
        let change = CaptionEditBound.change(from: "Now open Cubernades and pick a cluster",
                                             to: "Now open Kubernetes and pick a cluster")
        #expect(change.changed == 1)
        #expect(change.length == 7)
        #expect(change.allowed == 3)
        #expect(change.isWithinBound)
    }

    @Test func aTwoWordNameMisheardAsTwoWordsFitsEvenInAShortLine() {
        let change = CaptionEditBound.change(from: "Sora demo", to: "Soredemo app")
        #expect(change.allowed == 2)
        #expect(change.isWithinBound)
    }

    @Test func aRewriteOfTheLineIsRefused() {
        let change = CaptionEditBound.change(from: "Now open Cubernades and pick a cluster",
                                             to: "Next we deploy the service to production")
        #expect(change.changed == 7)
        #expect(!change.isWithinBound)
    }

    /// The differing middle runs from the first changed word to the last, so two corrections at
    /// opposite ends of a line count as the whole line between them.
    @Test func twoCorrectionsFarApartCountAsEverythingBetweenThem() {
        let change = CaptionEditBound.change(from: "teh quick brown fox jumps over the lazy dgo",
                                             to: "the quick brown fox jumps over the lazy dog")
        #expect(change.changed == 9)
        #expect(!change.isWithinBound)
    }

    /// A Chinese or Japanese character is a word, or every edit to such a line is a rewrite of it.
    @Test func aLineWithNoSpacesCountsEachCharacterAsAWord() {
        #expect(CaptionEditBound.words("現在打開Soredemo的設定") == ["現", "在", "打", "開", "Soredemo", "的", "設", "定"])
        let name = CaptionEditBound.change(from: "現在打開索瑞德摸的設定頁面", to: "現在打開Soredemo的設定頁面")
        #expect(name.length == 13)
        #expect(name.changed == 4, "four characters became one name")
        #expect(name.allowed == 5)
        #expect(name.isWithinBound)
        let rewrite = CaptionEditBound.change(from: "現在打開索瑞德摸的設定頁面", to: "我們接下來部署服務到正式環境")
        #expect(!rewrite.isWithinBound)
    }

    @Test func theAllowanceIsAThirdRoundedUpAndNeverUnderTwo() {
        #expect([0, 1, 2, 3, 4, 6, 7, 9, 10].map(CaptionEditBound.allowed(length:)) == [2, 2, 2, 2, 2, 2, 3, 3, 4])
    }
}
