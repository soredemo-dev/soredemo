import Foundation
import Testing

/// **The build-provenance file in the tree is the placeholder, not a stamp.**
///
/// `scripts/build-provenance.sh stamp` bakes a commit and a time into the app for the length of
/// one build. A stamped copy left in the tree was committed with unrelated work more than forty
/// times, so the committed baseline read "5ee4041-dirty" and a plain Xcode build reported that
/// as its own identity — a plausible value where a refusal belonged. Both build scripts now put
/// the placeholder back on exit; this fails if one did not, or a stamp is about to be committed.
@Test func appProvenanceIsCommittedAsThePlaceholder() throws {
    let file = repositoryRoot.appending(path: "Soredemo/App/BuildProvenance.swift")
    let text = try String(contentsOf: file, encoding: .utf8)
    let values = text.components(separatedBy: .newlines).filter { $0.contains("static let") }
    try #require(values.count == 2, "expected builtAt and commit, found \(values)")
    for value in values {
        #expect(value.contains("UNBUILT"), """
            \(value.trimmingCharacters(in: .whitespaces)) — a stamped value is in the tree. Run \
            scripts/build-provenance.sh placeholder, and do not commit the stamp.
            """)
    }
}
