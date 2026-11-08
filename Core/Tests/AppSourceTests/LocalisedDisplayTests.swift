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

/// **AppKit takes plain strings, so a literal handed to it is English in every language.**
///
/// `NSAlert` has no `LocalizedStringKey` overload: `alert.messageText = "Save this recording…"`
/// compiles, draws, and never reaches a table. The unsaved-work alert was English everywhere
/// for that reason, with an English gerund slotted into its question. Each of these positions
/// must be handed `String(localized:)` or a value already built from one.
@Test func noLiteralIsHandedToAppKitUntranslated() throws {
    let needles = ["messageText =", "informativeText =", "addButton(withTitle:",
                   "NSMenuItem(title:", "setActionName(", ".prompt =", ".message =",
                   ".nameFieldLabel =", ".toolTip =", ".placeholderString ="]
    var sites: [String] = []
    var scanned = 0
    for file in try appSourceFiles() {
        let text = try String(contentsOf: file, encoding: .utf8)
        let code = SwiftSourceLexer.codeViewLines(of: text)
        let raw = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for (index, line) in code.enumerated() where index < raw.count {
            for needle in needles {
                guard let hit = line.range(of: needle) else { continue }
                scanned += 1
                // The code view blanks string literals, so the quote is read from the raw line
                // at the same column.
                let column = line.distance(from: line.startIndex, to: hit.upperBound)
                var rest = Array(raw[index]).dropFirst(column).drop { $0 == " " }
                // `x =` at the end of a line, the literal wrapped onto the next one.
                if rest.isEmpty, index + 1 < raw.count {
                    rest = Array(raw[index + 1]).dropFirst(0).drop { $0 == " " }
                }
                if rest.first == "\"" {
                    sites.append("\(pathRelativeToRepositoryRoot(file)):\(index + 1): \(needle)\"…\"")
                }
            }
        }
    }
    try #require(scanned > 5, "only \(scanned) AppKit string positions were seen — the needles stopped matching")
    #expect(sites.isEmpty, """
        A literal handed straight to AppKit is shown as written, in every language:
        \(sites.joined(separator: "\n"))
        Wrap it in String(localized:) and add the key to every table.
        """)
}

/// **Two literals joined with `+` are a `String`, and a `String` is never looked up.**
///
/// `Label("\(name) is connected. " + "Unlock it…")` reads like one sentence, and its comment
/// said it was one; the `+` made it a `String`, SwiftUI's verbatim overload drew it, and it was
/// English in every language. The line limit is what invites the split. One literal over the
/// limit is the house answer (ContentView says so where it does it). `print(` is skipped: a
/// debug line on stderr is not read by anybody in another language.
@Test func noSentenceIsTwoLiteralsJoinedWithAPlus() throws {
    var sites: [String] = []
    var scanned = 0
    for file in try appSourceFiles() {
        let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
        var inPrint = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }
            if trimmed.hasPrefix("print(") { inPrint = true }
            defer { if trimmed.hasSuffix(")") { inPrint = false } }
            let next = index + 1 < lines.count ? lines[index + 1].trimmingCharacters(in: .whitespaces) : ""
            let joinsOnThisLine = trimmed.contains("\" + \"")
            let joinsAcrossLines = trimmed.hasSuffix("\"") && next.hasPrefix("+ \"")
                || trimmed.hasSuffix("\" +") && next.hasPrefix("\"")
            guard joinsOnThisLine || joinsAcrossLines else { continue }
            scanned += 1
            if !inPrint { sites.append("\(pathRelativeToRepositoryRoot(file)):\(index + 1)") }
        }
    }
    try #require(scanned > 0, "no literal concatenation was seen at all — not even the print( lines this skips")
    #expect(sites.isEmpty, """
        These join string literals with +, which makes a String no table is consulted for:
        \(sites.joined(separator: "\n"))
        Write the sentence as one literal, even over the line limit.
        """)
}

/// The CLDR plural categories each shipped language distinguishes for integers — what a
/// `.stringsdict` rule has to supply for the language to choose a form at all.
private let pluralCategories: [String: Set<String>] = [
    "en": ["one", "other"], "ja": ["other"], "zh-Hans": ["other"], "zh-Hant": ["other"],
]

/// **Every plural is complete in every language, and has a plain fallback.**
///
/// "1 captions", "%lld субтитр(ов)" and "sous-titre(s)" were the tables' answer to a count
/// until 2026-09-27. The counts now go through `Localizable.stringsdict`; this checks its shape
/// — the same keys in every language, each also in `Localizable.strings` (what the source scans read,
/// and the fallback), and each rule carrying every category its language has. Whether the rules
/// produce the right sentence is `everyPluralReadsAsASentenceInEveryLanguage`, in the app.
@Test func everyPluralIsCompleteInEveryLanguage() throws {
    let resources = repositoryRoot.appending(path: "Soredemo/Resources")
    func plist(_ language: String) throws -> [String: Any] {
        let url = resources.appending(path: "\(language).lproj/Localizable.stringsdict")
        let data = try Data(contentsOf: url)
        // `unsafe`: `format:` is an optional pointer out-parameter, passed nil.
        return try #require(try unsafe PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                            "\(language)'s stringsdict is not a dictionary")
    }
    func stringsKeys(_ language: String) throws -> Set<String> {
        let url = resources.appending(path: "\(language).lproj/Localizable.strings")
        let table = try #require(NSDictionary(contentsOf: url) as? [String: String])
        return Set(table.keys)
    }
    let english = Set(try plist("en").keys)
    try #require(english.count >= 21, "only \(english.count) plural keys in English — the file stopped parsing")
    // The table covers exactly the languages on disk: one added without its plural categories, or
    // one removed and left here, fails rather than being skipped or checked against nothing.
    let onDisk = Set(try FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "lproj" }.map { $0.deletingPathExtension().lastPathComponent })
    try #require(Set(pluralCategories.keys) == onDisk, "plural categories for \(pluralCategories.keys.sorted()), tables for \(onDisk.sorted())")
    for (language, categories) in pluralCategories {
        let table = try plist(language)
        #expect(Set(table.keys) == english, "\(language)'s plural keys differ from English's")
        let fallback = try stringsKeys(language)
        for key in english.sorted() {
            #expect(fallback.contains(key), "\(language): \"\(key)\" has no Localizable.strings fallback")
            guard let entry = table[key] as? [String: Any],
                  let format = entry["NSStringLocalizedFormatKey"] as? String else {
                Issue.record("\(language): \"\(key)\" has no NSStringLocalizedFormatKey")
                continue
            }
            let variables = format.matches(of: /#@(\w+)@/).map { String($0.output.1) }
            #expect(!variables.isEmpty, "\(language): \"\(key)\" names no plural variable in \(format)")
            for variable in variables {
                let rule = entry[variable] as? [String: Any] ?? [:]
                let supplied = Set(rule.keys).intersection(["zero", "one", "two", "few", "many", "other"])
                #expect(categories.isSubset(of: supplied),
                        "\(language): \"\(key)\" variable \(variable) lacks \(categories.subtracting(supplied).sorted())")
            }
        }
    }
}

/// The format specifiers in a string, positions dropped and sorted: `%2$lld of %1$@` and
/// `%@ of %lld` are the same arguments. `%%` is a literal percent sign, not an argument.
private func specifiers(_ text: String) -> [String] {
    text.replacingOccurrences(of: "%%", with: "")
        .matches(of: /%(?:\d+\$)?(lld|ld|d|@|lf|f|s)/).map { String($0.output.1) }.sorted()
}

/// **Every translation takes the arguments its key gives it.**
///
/// A translation with one `%@` where the key has two draws a stray argument or garbage, and one
/// with `%@` where the key passes an integer can crash `String(format:)`. Nothing else in this
/// suite reads the VALUES of the tables — every other check is about whether a key exists.
/// The reordering case (`%2$lld … %1$lld`) is legal and allowed; a different set is not.
@Test func everyTranslationTakesTheArgumentsItsKeyGives() throws {
    let resources = repositoryRoot.appending(path: "Soredemo/Resources")
    var mismatches: [String] = []
    var compared = 0
    for language in pluralCategories.keys.sorted() {
        let url = resources.appending(path: "\(language).lproj/Localizable.strings")
        let table = try #require(NSDictionary(contentsOf: url) as? [String: String],
                                 "\(language)'s Localizable.strings did not parse")
        for (key, value) in table {
            compared += 1
            if specifiers(key) != specifiers(value) {
                mismatches.append("\(language): \"\(key)\" → \"\(value)\"")
            }
        }
    }
    // Every table read, at about its real size (858 keys each on 2026-11-08) — a guard on the
    // parse, not a count to keep in step: it was a fixed 5000 for ten tables until the owner kept
    // four, and a fixed number would have failed the day the languages changed.
    try #require(compared >= pluralCategories.count * 800,
                 "only \(compared) entries compared across \(pluralCategories.count) tables")
    #expect(mismatches.isEmpty, """
        \(mismatches.count) translation(s) take different arguments from their key:
        \(mismatches.sorted().joined(separator: "\n"))
        """)
}
