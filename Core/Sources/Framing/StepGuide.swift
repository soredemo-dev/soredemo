import Foundation

/// One line of a guide: what was pressed, what kind of thing it was, in which application, and
/// where on its picture it is.
public struct GuideStep: Hashable, Sendable {
    public let label: String
    public let role: String?
    public let application: String?
    /// The pressed element's box on the step's picture, or `nil` when it is not on it.
    public let highlight: GuideHighlight?

    public init(label: String, role: String?, application: String?, highlight: GuideHighlight? = nil) {
        self.label = label
        self.role = role
        self.application = application
        self.highlight = highlight
    }
}

/// A box as fractions of a picture, top-left origin — `Render.WalkthroughHotspot.Box`'s numbers,
/// carried here because this module does not depend on `Render`.
public struct GuideHighlight: Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// The sentences a guide is written in, already localised by the app — the package has no
/// strings table and should not have one. `{label}`, `{app}` and `{number}` are filled in here,
/// escaped for the format, and nowhere else.
public struct GuidePhrases: Hashable, Sendable {
    public let click: String
    public let clickIn: String
    public let choose: String
    public let chooseIn: String
    /// A picture's alternative text, with `{number}`.
    public let pictureAlt: String

    public init(click: String, clickIn: String, choose: String, chooseIn: String, pictureAlt: String) {
        self.click = click
        self.clickIn = clickIn
        self.choose = choose
        self.chooseIn = chooseIn
        self.pictureAlt = pictureAlt
    }
}

/// A step-by-step guide's text, in Markdown and in HTML.
///
/// **A label is another application's text, and is escaped for the format it lands in.** A
/// control's title can be anything that application chose — a link's text, a file's name — so in
/// Markdown it could become emphasis or a link, and in HTML markup that runs when the guide is
/// opened in a browser. These two functions are the only writers of a guide and they interpolate
/// a label nowhere but through the escapes below.
/// See `docs/design/2026-10-25-a-guide-from-the-steps.md`.
public enum StepGuide {
    public enum Verb: Hashable, Sendable { case click, choose }

    /// A menu item is chosen; anything else is clicked. **Two verbs, not twenty**: "turn on" for a
    /// checkbox would need its state, which the log does not hold, and a wrong verb is worse than
    /// a plain one.
    public static func verb(forRole role: String?) -> Verb {
        role == "AXMenuItem" ? .choose : .click
    }

    /// `step-01.png` — two digits at least, so a folder lists the pictures in order.
    public static func pictureName(for number: Int) -> String {
        "step-" + (number < 10 ? "0\(number)" : "\(number)") + ".png"
    }

    public static func markdown(title: String, steps: [GuideStep], phrases: GuidePhrases) -> String {
        let items = sentences(steps, phrases: phrases, label: { "**\(markdownEscaped($0))**" },
                              application: markdownEscaped).enumerated().map { index, sentence in
            let number = index + 1
            let alt = phrases.pictureAlt.replacingOccurrences(of: "{number}", with: "\(number)")
            return "\(number). \(sentence)\n\n   ![\(markdownEscaped(alt))](\(pictureName(for: number)))"
        }
        // One blank line between items and one newline at the end, as a Markdown file has.
        return "# \(markdownEscaped(title))\n\n" + items.joined(separator: "\n\n") + "\n"
    }

    /// A self-contained page: no script, no stylesheet or font from anywhere, nothing fetched.
    public static func html(title: String, steps: [GuideStep], phrases: GuidePhrases) -> String {
        var items = ""
        for (index, sentence) in sentences(steps, phrases: phrases, label: { "<strong>\(htmlEscaped($0))</strong>" },
                                          application: htmlEscaped).enumerated() {
            let number = index + 1
            let alt = htmlEscaped(phrases.pictureAlt.replacingOccurrences(of: "{number}", with: "\(number)"))
            // The box is numbers this function formats — no text from anywhere reaches a style.
            let box = steps[index].highlight.map {
                String(format: "<span class=\"box\" style=\"left:%.2f%%;top:%.2f%%;width:%.2f%%;height:%.2f%%\"></span>",
                       $0.x * 100, $0.y * 100, $0.width * 100, $0.height * 100)
            } ?? ""
            items += "<li><p>\(sentence)</p><div class=\"shot\"><img src=\"\(pictureName(for: number))\" alt=\"\(alt)\">\(box)</div></li>\n"
        }
        return """
            <!doctype html>
            <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(htmlEscaped(title))</title>
            <style>body{font:16px/1.5 -apple-system,system-ui,sans-serif;max-width:52rem;margin:2rem auto;padding:0 1rem;color:#1d1d1f}
            li{margin:0 0 2rem}.shot{position:relative;display:inline-block;max-width:100%}
            img{display:block;max-width:100%;border-radius:8px;box-shadow:0 1px 4px rgba(0,0,0,.2)}
            .box{position:absolute;border:3px solid #ff3b30;border-radius:6px;box-sizing:border-box;pointer-events:none}
            @media (prefers-color-scheme:dark){body{background:#1d1d1f;color:#f5f5f7}}</style>
            </head><body>
            <h1>\(htmlEscaped(title))</h1>
            <ol>
            \(items)</ol>
            </body></html>

            """
    }

    /// Each step's sentence, with its label and — on the first step and wherever the application
    /// changes — its application, both already escaped by the caller's format.
    static func sentences(_ steps: [GuideStep], phrases: GuidePhrases,
                                  label: (String) -> String,
                                  application: (String) -> String) -> [String] {
        var previous: String?
        return steps.map { step in
            let shown = step.application.map(oneLine)
            let namesApplication = shown != nil && shown != previous
            previous = shown ?? previous
            let template: String = switch (verb(forRole: step.role), namesApplication) {
            case (.click, false): phrases.click
            case (.click, true): phrases.clickIn
            case (.choose, false): phrases.choose
            case (.choose, true): phrases.chooseIn
            }
            return template
                .replacingOccurrences(of: "{label}", with: label(oneLine(step.label)))
                .replacingOccurrences(of: "{app}", with: application(shown ?? ""))
        }
    }

    /// A label on one line: a newline inside one would break its list item out of the list.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    /// Every character Markdown gives a meaning to mid-line, backslash-escaped.
    static func markdownEscaped(_ text: String) -> String {
        let special: Set<Character> = ["\\", "`", "*", "_", "[", "]", "(", ")", "#", "<", ">", "!", "|"]
        return String(text.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
    }

    static func htmlEscaped(_ text: String) -> String {
        var escaped = ""
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            default: escaped.append(character)
            }
        }
        return escaped
    }
}
