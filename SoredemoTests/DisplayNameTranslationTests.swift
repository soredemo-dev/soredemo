import Foundation
import Testing
import Capture
import Compositing
import Project
import Render
import Variants
@testable import Soredemo

// **A name looked up at run time is in no scan's sight.** `Text(LocalizedStringKey(x.displayName))`
// is what makes a picker's choices translatable — `Text(x.displayName)` was verbatim, and the
// Shadow slider read "Shadow" in German beside `"Shadow" = "Schatten"` in the German table. But the
// key is a value, not a literal, so `everyPlainUILiteralIsInTheStringTable` cannot see it, and a
// name missing from a table renders in English with nothing failing. This reads the values.
//
// **The list of types is written by hand**, which rots by omission. What keeps it honest is the
// package scan `everyDisplayedVariableSaysWhetherItIsTranslated`: every new display site has to be
// marked `LocalizedStringKey(…)` to pass it, and a grep for that marker is the list to add here.

/// Every table the app ships, by language, read from the built bundle rather than the source tree.
private func stringTables() throws -> [String: [String: String]] {
    var tables: [String: [String: String]] = [:]
    for language in Bundle.main.localizations where language != "Base" {
        let path = try #require(Bundle.main.path(forResource: "Localizable", ofType: "strings",
                                                 inDirectory: nil, forLocalization: language),
                                "\(language) is listed but has no Localizable.strings")
        tables[language] = try #require(NSDictionary(contentsOfFile: path) as? [String: String],
                                        "\(language)'s Localizable.strings did not parse")
    }
    return tables
}

private func missing(_ names: [String], from tables: [String: [String: String]]) -> [String] {
    tables.keys.sorted().flatMap { language in
        names.filter { tables[language]?[$0] == nil }.map { "\(language): \"\($0)\"" }
    }
}

/// Every name the app passes through `LocalizedStringKey(…)` from a model value.
@MainActor private var namesLookedUpAtRunTime: [String] {
    var names: [String] = []
    names += AnnotationShape.allCases.map(\.displayName)
    names += AnnotationInk.allCases.map(\.displayName)
    names += TextAnimation.allCases.map(\.displayName)
    names += TextAnchor.allCases.map(\.displayName)
    names += DeviceFrame.Model.allCases.map(\.displayName)
    names += DeviceFrame.Finish.allCases.map(\.displayName)
    names += CursorStyle.ClickEffect.allCases.map(\.displayName)
    names += CameraOverlayStyle.Background.allCases.map(\.displayName)
    names += CameraOverlayStyle.Shape.allCases.map(\.displayName)
    names += CameraRecorder.Quality.allCases.map(\.displayName)
    names += ExportCodec.allCases.map(\.displayName)
    names += ExportResolution.allCases.map(\.displayName)
    names += ExportFrameRate.allCases.map(\.displayName)
    names += ExportQuality.choices.map(\.displayName)
    names += AudioMix.Source.allCases.map(\.displayName)
    names += [MicrophoneSource.off, .systemDefault].map(\.displayName)
    names += [CameraSource.off.displayName]
    names += AspectVariant.all.map(\.name) + [AspectVariant.matchRecordingName]
    names += StageBackground.presets.map(\.name)
    names += CaptionStyle.presets.map(\.name)
    names += StageWindow.InspectorTab.allCases.map(\.title)
    names += SettingsWindow.Section.allCases.map(\.title)
    names += WallpaperPicker.Source.allCases.map(\.title)
    return names
}

@MainActor @Test func everyNameLookedUpAtRunTimeIsInEveryStringTable() throws {
    let tables = try stringTables()
    // Ten, not "some": a bundle that lost its tables would pass the check below vacuously.
    try #require(tables.count == 10, "found \(tables.count) string tables: \(tables.keys.sorted())")
    let names = namesLookedUpAtRunTime
    try #require(names.count > 60, "only \(names.count) names were gathered")
    let gaps = missing(names, from: tables)
    #expect(gaps.isEmpty, """
        \(gaps.count) name(s) shown through LocalizedStringKey(…) have no entry, so they render in \
        English in that language:
        \(gaps.joined(separator: "\n"))
        """)
}

/// The check's own control: a name in no table is reported, once per language.
@Test func aNameInNoTableIsReportedInEveryLanguage() throws {
    let tables = try stringTables()
    let gaps = missing(["Soredemo control — not a key"], from: tables)
    #expect(gaps.count == tables.count && !tables.isEmpty, "\(gaps)")
}

/// **A counted sentence reads as a sentence, in every language, at every count.**
///
/// Formats every plural key the way the app does — the language's own bundle, the language's
/// own locale — at 1, 2, 5 and 21: the counts that separate English's one/other and Russian's
/// one/few/many. A rule that is missing, misspelled or pointed at the wrong argument shows here
/// as "(s)" left in, a count that is not in the sentence, or two counts that read the same.
@Test func everyPluralReadsAsASentenceInEveryLanguage() throws {
    let english = try #require(Bundle.main.path(forResource: "Localizable", ofType: "stringsdict",
                                                inDirectory: nil, forLocalization: "en"))
    let keys = try #require(NSDictionary(contentsOfFile: english)?.allKeys as? [String]).sorted()
    try #require(keys.count >= 21, "only \(keys.count) plural keys were found in the built app")
    // English only: every English noun here changes between 1 and 2, so a sentence that reads
    // the same at both is a rule that was never chosen. German's "Untertitel" does not change,
    // and nor do several Russian genitives, so the same test there would fail on correct text —
    // that every category is SUPPLIED is `everyPluralIsCompleteInEveryLanguage`'s job.
    let distinguishes: [String: [(Int, Int)]] = ["en": [(1, 2)]]
    var languages = 0
    for language in Bundle.main.localizations where language != "Base" {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let locale = Locale(identifier: language)
        languages += 1
        for key in keys {
            let format = bundle.localizedString(forKey: key, value: nil, table: nil)
            func sentence(_ count: Int) -> String {
                // Arguments in the key's own order: a count for each %lld, a word for each %@.
                var arguments: [any CVarArg] = []
                for specifier in key.matches(of: /%(lld|@)/) {
                    arguments.append(specifier.output.1 == "lld" ? count as any CVarArg : "X" as NSString)
                }
                return String(format: format, locale: locale, arguments: arguments)
            }
            for count in [1, 2, 5, 21] {
                let text = sentence(count)
                #expect(!text.contains("(s)") && !text.contains("(es)") && !text.contains("%"),
                        "\(language) \"\(key)\" at \(count): \(text)")
                #expect(text.contains(String(count)), "\(language) \"\(key)\" at \(count) lost its count: \(text)")
            }
            for (a, b) in distinguishes[language] ?? [] {
                let first = sentence(a).replacingOccurrences(of: String(a), with: "#")
                let second = sentence(b).replacingOccurrences(of: String(b), with: "#")
                #expect(first != second, "\(language) \"\(key)\" reads the same at \(a) and \(b): \(first)")
            }
        }
    }
    #expect(languages == 10, "checked \(languages) languages")
}
