import Foundation
import Testing

/// **No file in this repository names a project it was read beside.** Code, tests, documents,
/// scripts and configuration alike — the owner's decision of 2026-11-11, before the repository was
/// made public. Ideas from elsewhere are described as ideas; whose they were is kept outside.
///
/// **The list holds hashes, not names**, so the check does not publish what it forbids: FNV-1a over
/// the UTF-8 of a lower-cased word, or of two words joined by a single `-`, `.` or `_`, which is how a
/// hyphenated or dotted name is caught. A few names are also ordinary English words when lower case — "cap" is
/// a limit — so those are matched only as a capitalised whole word, in a second set.
///
/// The commercial products in `noSourceFileNamesACompetitor` are a different rule: they may be named
/// in a dated survey under `docs/`, and only the source is kept free of them.
private let referenceHashes: Set<UInt64> = [
    0xd467_e34a_3285_d91b, 0x64cd_c8b0_33cc_e6db, 0xab88_5bfc_66d3_d48d, 0xb8d7_16f9_347a_1849,
    0x40b1_63b5_9821_432d, 0x0efd_90c7_ccc7_1ffe, 0x4c45_6857_a875_81d0, 0x742d_c3a1_93db_61d2,
    0x90eb_9df3_1c17_51e8, 0xe9be_18d3_6035_d152, 0x935a_dfab_42c3_a8a6, 0xed69_c64f_8dd9_85e4,
    0x46b2_844c_93b1_c740, 0xf154_f774_72a0_7dbe, 0x85cd_c9f9_bb9e_52ea, 0xc278_d62f_249d_83ee,
    0x00ff_3351_4762_4293, 0x1141_048a_5fde_e83a, 0x5e1b_9c28_13f0_7863,
]

/// Matched as written, capitalised and whole: their lower-case forms are everyday words.
private let capitalisedReferenceHashes: Set<UInt64> = [
    0x0bec_2319_aa9d_a8bb, 0x2fcd_a019_bf49_54e5, 0x10aa_1fc0_5a17_f96c,
]

/// A typographic term that happens to begin with one of the capitalised words above.
private let typographicPhrases = ["Cap height", "Cap-height"]

/// Directories that are build output, tooling state or not this repository's — and any directory
/// whose name begins `.build`, which is what every gate's private build path is called.
private let notTheRepository: Set<String> = [".git", "DerivedData", "dist", ".claude",
                                             "worktrees", "node_modules", ".swiftpm"]

func fnv1a64(_ text: String) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return hash
}

/// The words in `text` that are a reference project's name, as written there.
func referenceNames(in text: String) -> [String] {
    var prose = text
    for phrase in typographicPhrases { prose = prose.replacingOccurrences(of: phrase, with: " ") }
    // Each word, and whether the next one follows it across exactly one joining character.
    var words: [(text: String, joinedToNext: Bool)] = []
    var current = "", gap = ""
    for character in prose {
        if character.isLetter || character.isNumber {
            if current.isEmpty, !words.isEmpty { words[words.count - 1].joinedToNext = ["-", ".", "_"].contains(gap) }
            current.append(character)
            gap = ""
        } else {
            if !current.isEmpty { words.append((current, false)); current = "" }
            gap.append(character)
        }
    }
    if !current.isEmpty { words.append((current, false)) }
    var found: [String] = []
    for (index, word) in words.enumerated() {
        if referenceHashes.contains(fnv1a64(word.text.lowercased())) || capitalisedReferenceHashes.contains(fnv1a64(word.text)) {
            found.append(word.text)
        } else if word.joinedToNext, index + 1 < words.count {
            let joined = word.text + words[index + 1].text
            if referenceHashes.contains(fnv1a64(joined.lowercased())) { found.append(joined) }
        }
    }
    return found
}

/// Every text file under the repository root that is the repository's own: a file with a NUL in
/// its first 8 KB, or that is not UTF-8, is not text and is skipped.
func repositoryTextFiles() throws -> [(path: String, text: String)] {
    let enumerator = try #require(FileManager.default.enumerator(
        at: repositoryRoot, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]))
    var files: [(path: String, text: String)] = []
    while let url = enumerator.nextObject() as? URL {
        if notTheRepository.contains(url.lastPathComponent) || url.lastPathComponent.hasPrefix(".build") {
            enumerator.skipDescendants()
            continue
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) < 4_000_000,
              let data = try? Data(contentsOf: url), !data.prefix(8000).contains(0),
              let text = String(data: data, encoding: .utf8) else { continue }
        let path = url.path(percentEncoded: false).replacingOccurrences(of: repositoryRoot.path(percentEncoded: false), with: "")
        files.append((path, text))
    }
    return files
}

@Test func noFileInTheRepositoryNamesAReferenceProject() throws {
    let files = try repositoryTextFiles()
    try #require(files.count > 500, "only \(files.count) text files were read — the scan would pass vacuously")
    var offenders: [String] = []
    for file in files {
        for (number, line) in file.text.components(separatedBy: "\n").enumerated() {
            // The name itself is not printed: a public CI log is a publication too.
            for name in referenceNames(in: line) {
                offenders.append("\(file.path):\(number + 1) — \(name.prefix(1))… (\(name.count) letters)")
            }
        }
    }
    #expect(offenders.isEmpty, """
        \(offenders.count) line(s) name a project this one was read beside. Describe the idea, not \
        whose it was:

        \(offenders.joined(separator: "\n"))
        """)
}

/// The check's own controls, so a green above means "none named" and not "nothing could be seen".
/// Each name is assembled reversed at run time, so this file never spells it.
@Test func theNameScanSeesANameItsHyphenatedFormAndItsCapitalisedFormAndNothingElse() {
    let name = String("reimlap".reversed())
    #expect(referenceNames(in: "as \(name) does") == [name])
    #expect(referenceNames(in: "the \(name.uppercased()) editor") == [name.uppercased()])
    let first = String("nepo".reversed()), second = String("edils".reversed())
    #expect(referenceNames(in: "\(first)-\(second) reads it") == [first + second], "a hyphenated name")
    #expect(referenceNames(in: "\(first): \(second) reads it") == [], "two words across a colon and a space are two words")
    let capital = String("paC".reversed())
    #expect(referenceNames(in: "as \(capital) does") == [capital])
    #expect(referenceNames(in: "the depth cap, the cap") == [], "the everyday word is not a name")
    #expect(referenceNames(in: "\(capital) height of the type") == [], "the typographic term is not a name")
    #expect(referenceNames(in: "Capture and encapsulate") == [], "a longer word containing it is not it")
}
