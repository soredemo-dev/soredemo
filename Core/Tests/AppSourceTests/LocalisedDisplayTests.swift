import CheckerLexer
import Foundation
import Testing

/// The SwiftUI initialisers and modifiers that put a string in front of a person, each spelled
/// with the character before its name so `SubText(` and `.helpful(` do not match.
private let displayNeedles = [
    "Text(", "Label(", "Button(", "Toggle(", "Section(", "Picker(", "TextField(", "Menu(",
    "LabeledContent(", ".help(", ".accessibilityLabel(", ".accessibilityHint(", ".navigationTitle(",
]

/// Callees whose value is not a string, so passing one as the first argument says nothing about
/// localisation: `.accessibilityLabel(Text(title))` is judged at the inner `Text(`.
private let nonStringCallees: Set<String> = ["Text", "Image", "LocalizedStringKey"]

/// One argument a display site was handed, as the scan reads it.
private enum FirstArgument: Equatable {
    case literal
    case labelled
    case lookedUp
    case unmarked(String)
}

/// `code` is the lexer's view, where a string literal — quotes included — is blanked to spaces;
/// `raw` is the same line as written, column for column, which is the only place a quote shows.
private func firstArgument(in code: Substring, raw: [Character], next: String,
                           localKeys: Set<String>) -> FirstArgument? {
    var column = code.base.distance(from: code.base.startIndex, to: code.startIndex)
    while column < raw.count, raw[column] == " " { column += 1 }
    if column < raw.count, raw[column] == "\"" || raw[column] == "#" { return .literal }
    let rest = code.dropFirst(column - code.base.distance(from: code.base.startIndex, to: code.startIndex))
    guard let head = rest.first else { return nil }
    guard head.isLetter || head == "_" else { return .unmarked(String(rest.prefix(24))) }
    let chain = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
    let last = String(chain.split(separator: ".").last ?? chain)
    let after = rest.dropFirst(chain.count)
    if after.first == ":", !chain.contains(".") { return .labelled }
    if after.first == "(", nonStringCallees.contains(last) || localKeys.contains(last) { return .lookedUp }
    let bare = after.first == ")" || after.first == ","
    if bare && localKeys.contains(last) { return .lookedUp }
    if bare && (after.hasPrefix(", format:") || after.hasPrefix(", style:")) { return .lookedUp }
    // `cond ? Text("a") : Text("b")`: the compiler already makes both branches one type.
    let ternary = (rest + " " + next).drop { $0 != "?" }.dropFirst().drop { $0 == " " }
    if ternary.hasPrefix("Text(") { return .lookedUp }
    return .unmarked(String(rest.prefix(40)))
}

/// Types whose value is already looked up, or is resolved by `Text` itself.
private let localisedTypes = ["LocalizedStringKey", "LocalizedStringResource", "Text"]

/// Names this file declares as one of `localisedTypes` — a parameter or property typed with it,
/// or a function returning one.
private func localisedNames(in lines: [String]) -> Set<String> {
    var names: Set<String> = []
    func identifierEnds(_ text: Substring) -> Bool {
        !(text.first.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false)
    }
    for line in lines {
        for type in localisedTypes {
            var search = line[...]
            while let colon = search.range(of: ": \(type)") {
                defer { search = search[colon.upperBound...] }
                guard identifierEnds(search[colon.upperBound...]) else { continue }
                let before = search[search.startIndex..<colon.lowerBound]
                let name = before.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                if !name.isEmpty { names.insert(String(name.reversed())) }
            }
            if let arrow = line.range(of: "-> \(type)"), identifierEnds(line[arrow.upperBound...]),
               let function = line.range(of: "func ") {
                let name = line[function.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                if !name.isEmpty { names.insert(String(name)) }
            }
        }
    }
    return names
}

private func unmarkedDisplaySites(in text: String, file: String) -> (sites: [String], scanned: Int) {
    let lines = SwiftSourceLexer.codeViewLines(of: text)
    let rawLines = text.replacingOccurrences(of: "\r\n", with: "\n")
        .components(separatedBy: "\n").map(Array.init)
    guard rawLines.count == lines.count else {
        return (["\(file): the lexer's \(lines.count) lines do not align with \(rawLines.count)"], 0)
    }
    let keys = localisedNames(in: lines)
    var sites: [String] = []
    var scanned = 0
    for (index, line) in lines.enumerated() {
        for needle in displayNeedles {
            var search = line[...]
            while let hit = search.range(of: needle) {
                defer { search = search[hit.upperBound...] }
                if !needle.hasPrefix("."), hit.lowerBound > line.startIndex {
                    let before = line[line.index(before: hit.lowerBound)]
                    if before.isLetter || before.isNumber || before == "_" || before == "." { continue }
                }
                guard let argument = firstArgument(in: search[hit.upperBound...], raw: rawLines[index],
                                                   next: index + 1 < lines.count ? lines[index + 1] : "",
                                                   localKeys: keys)
                else { continue }
                scanned += 1
                if case .unmarked(let text) = argument {
                    sites.append("\(file):\(index + 1): \(needle)\(text)")
                }
            }
        }
    }
    return (sites, scanned)
}

/// **Every string a display site is handed says whether it is translated.**
///
/// SwiftUI's `Text(_ content: some StringProtocol)` shows its argument VERBATIM: it never reaches
/// a string table. A literal is a `LocalizedStringKey`, a variable is not — so
/// `Text(shape.displayName)` was English in all ten languages, and `slider("Shadow", …)` was
/// English in German while `"Shadow" = "Schatten"` sat in the German table. Measured 2026-09-26
/// by launching with `-AppleLanguages (de)` beside a positive control that did translate.
///
/// A compile-time ban was tried first: an `@available(*, unavailable)` `Text.init<S: StringProtocol>`
/// in the app module is never chosen over SwiftUI's, with or without `@_disfavoredOverload`,
/// and `Text(s)` compiled clean either way. So the rule lives here.
///
/// Every non-literal argument is one of: `Text(verbatim:)` — already localised, or the person's
/// own words; `LocalizedStringKey(…)` — a key looked up at run time; or a name this file
/// declares `: LocalizedStringKey`. There is no exemption list, because each site can say which.
@Test func everyDisplayedVariableSaysWhetherItIsTranslated() throws {
    var sites: [String] = []
    var scanned = 0
    for file in try appSourceFiles() {
        let found = unmarkedDisplaySites(in: try String(contentsOf: file, encoding: .utf8),
                                         file: pathRelativeToRepositoryRoot(file))
        sites += found.sites
        scanned += found.scanned
    }
    try #require(scanned > 300, """
        only \(scanned) display sites were read across the app target — the needles have stopped \
        matching, and a scan that reads nothing finds nothing.
        """)
    #expect(sites.isEmpty, """
        \(sites.count) display site(s) are handed a String that SwiftUI shows verbatim, so it is \
        English in every language even when the key is in the tables:
        \(sites.joined(separator: "\n"))
        Write Text(verbatim: x) when x is already localised or is the person's own text, or \
        Text(LocalizedStringKey(x)) when x is a key; a helper's parameter can be LocalizedStringKey.
        """)
}

/// The scan's own controls: each shape it must refuse, and each it must pass, as source text.
@Test(arguments: [
    ("Text(title)", true), ("Text(shape.displayName).tag(shape)", true),
    ("Label(failure, systemImage: \"x\")", true), ("Button(source.displayName) { }", true),
    (".help(tip)", true), ("Text(on ? \"a\" : \"b\")", true), ("Text(String(localized: \"a\"))", true),
    ("Text(\"Shadow\")", false), ("Text(verbatim: name)", false),
    ("Text(LocalizedStringKey(shape.displayName))", false), ("Button(action: go) { }", false),
    (".accessibilityLabel(Text(\"x\"))", false), ("Text(date, style: .time)", false),
    ("SubText(title)", false), ("let t: LocalizedStringKey = \"a\"; Text(t)", false),
    ("static func f(_ v: Int) -> LocalizedStringKey { \"a\" }; Button(Self.f(1)) { }", false),
    ("static func g(_ v: Int) -> String { \"a\" }; Button(Self.g(1)) { }", true),
    ("Text(Self.label(shape))", true),
    (".help(on ? Text(\"a\") : Text(\"b\"))", false), (".help(on\n  ? Text(\"a\") : Text(\"b\"))", false),
    (".help(on ? \"a\" : \"b\")", true), ("var tip: Text { Text(\"a\") }; .help(tip)", false),
    ("let tip: TextAnchor = .a; .help(tip)", true),
])
func theDisplayScanTellsAMarkedSiteFromAnUnmarkedOne(source: String, isUnmarked: Bool) {
    let found = unmarkedDisplaySites(in: source, file: "fixture.swift")
    #expect(found.sites.isEmpty == !isUnmarked, "\(source) → \(found.sites)")
}

/// **No view decides what a sentence means by reading its words.**
///
/// The recorder panel showed a failure when `statusText` contained "could not". Every status
/// sentence is `String(localized:)`, so in nine of ten languages that never matched and no
/// failure was shown. A status now says whether it is a problem where it is written; this is
/// the shape of the old mistake — a string-content test on a status value — so it cannot return.
@Test func noViewReadsAStatusSentenceToDecideWhatItMeans() throws {
    var sites: [String] = []
    var scanned = 0
    for file in try appSourceFiles() {
        let lines = SwiftSourceLexer.codeViewLines(of: try String(contentsOf: file, encoding: .utf8))
        for (index, line) in lines.enumerated() {
            for probe in [".contains(", ".hasPrefix(", ".hasSuffix(", ".range(of:"] {
                var search = line[...]
                while let hit = search.range(of: probe) {
                    defer { search = search[hit.upperBound...] }
                    scanned += 1
                    let receiver = line[..<hit.lowerBound].reversed()
                        .prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                    let name = String(receiver.reversed())
                    if name.hasSuffix("Text") || name.hasSuffix("Status") || name == "status" {
                        sites.append("\(pathRelativeToRepositoryRoot(file)):\(index + 1): \(name)\(probe)")
                    }
                }
            }
        }
    }
    try #require(scanned > 20, "only \(scanned) string tests were seen in the app — the probes stopped matching")
    #expect(sites.isEmpty, """
        These read a status sentence's words to decide something, which works in English only:
        \(sites.joined(separator: "\n"))
        Say it where the status is written instead — RecordingCoordinator.Status.problem(_:).
        """)
}
