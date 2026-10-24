import Foundation

/// The words a walkthrough page shows around its steps, already localised by the app.
/// `{number}` and `{total}` are filled here.
public struct WalkthroughWords: Hashable, Sendable {
    public let stepOf: String
    public let next: String
    public let back: String
    public let finished: String
    public let startAgain: String

    public init(stepOf: String, next: String, back: String, finished: String, startAgain: String) {
        self.stepOf = stepOf
        self.next = next
        self.back = back
        self.finished = finished
        self.startAgain = startAgain
    }
}

/// The take as one web page a viewer clicks through: each step a picture with the pressed element
/// as a real button on it, and the next step when it is pressed.
///
/// **One file that fetches nothing.** The pictures are `data:` URIs, the style and the script are
/// inline, and nothing is sent anywhere — the export is a file a person sends, as every other
/// export here is. **The script never holds a label**: every step is a `<section>` the script only
/// shows and hides, so another application's text is in the page as escaped HTML and nowhere a
/// script could run it. See `docs/design/2026-10-23-interactive-walkthrough-export.md`.
public enum WalkthroughDocument {
    public static func html(title: String, steps: [GuideStep], pictures: [String],
                            phrases: GuidePhrases, words: WalkthroughWords) -> String {
        let visible = StepGuide.sentences(steps, phrases: phrases,
                                          label: { "<strong>\(StepGuide.htmlEscaped($0))</strong>" },
                                          application: StepGuide.htmlEscaped)
        let spoken = StepGuide.sentences(steps, phrases: phrases, label: StepGuide.htmlEscaped,
                                         application: StepGuide.htmlEscaped)
        let total = steps.count
        var sections = ""
        for (index, step) in steps.enumerated() {
            let counter = StepGuide.htmlEscaped(words.stepOf
                .replacingOccurrences(of: "{number}", with: "\(index + 1)")
                .replacingOccurrences(of: "{total}", with: "\(total)"))
            let alt = StepGuide.htmlEscaped(phrases.pictureAlt.replacingOccurrences(of: "{number}", with: "\(index + 1)"))
            let picture = index < pictures.count && isImageDataURI(pictures[index])
                ? "<img src=\"\(pictures[index])\" alt=\"\(alt)\">" : ""
            // The box is numbers formatted here; the label reaches the button only escaped.
            let hotspot = step.highlight.map {
                String(format: "<button class=\"hotspot\" aria-label=\"%@\" style=\"left:%.2f%%;top:%.2f%%;width:%.2f%%;height:%.2f%%\"></button>",
                       spoken[index], $0.x * 100, $0.y * 100, $0.width * 100, $0.height * 100)
            } ?? ""
            let back = index > 0 ? "<button class=\"back\">\(StepGuide.htmlEscaped(words.back))</button>" : ""
            sections += """
                <section class="step" data-step="\(index)"\(index == 0 ? "" : " hidden")>
                <p class="counter">\(counter)</p><p class="sentence" dir="auto">\(visible[index])</p>
                <div class="shot">\(picture)\(hotspot)</div>
                <nav>\(back)<button class="next">\(StepGuide.htmlEscaped(words.next))</button></nav>
                </section>

                """
        }
        sections += """
            <section class="step done" data-step="\(total)" hidden>
            <p class="sentence">\(StepGuide.htmlEscaped(words.finished))</p>
            <nav><button class="back">\(StepGuide.htmlEscaped(words.back))</button><button class="again">\(StepGuide.htmlEscaped(words.startAgain))</button></nav>
            </section>

            """
        return """
            <!doctype html>
            <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(StepGuide.htmlEscaped(title))</title>
            <style>
            body{font:16px/1.5 -apple-system,system-ui,sans-serif;max-width:64rem;margin:1.5rem auto;padding:0 1rem;color:#1d1d1f;background:#fff}
            .counter{color:#6e6e73;margin:0}.sentence{font-size:1.15rem;margin:.25rem 0 1rem}
            .shot{position:relative;display:inline-block;max-width:100%}
            .shot img{display:block;max-width:100%;border-radius:8px;box-shadow:0 1px 4px rgba(0,0,0,.2)}
            .hotspot{position:absolute;border:3px solid #ff3b30;border-radius:6px;background:transparent;cursor:pointer;animation:pulse 1.6s ease-in-out infinite}
            .hotspot.hint{background:rgba(255,59,48,.25)}
            nav{display:flex;gap:.5rem;margin-top:1rem}button.next,button.back,button.again{font:inherit;padding:.4rem 1rem;border-radius:8px;border:1px solid #c7c7cc;background:#f5f5f7;cursor:pointer}
            @keyframes pulse{50%{box-shadow:0 0 0 6px rgba(255,59,48,.25)}}
            @media (prefers-reduced-motion:reduce){.hotspot{animation:none}}
            @media (prefers-color-scheme:dark){body{background:#1d1d1f;color:#f5f5f7}button.next,button.back,button.again{background:#2c2c2e;color:#f5f5f7;border-color:#48484a}}
            </style>
            </head><body>
            <h1>\(StepGuide.htmlEscaped(title))</h1>
            \(sections)<script>
            const steps=[...document.querySelectorAll('.step')];let at=0;
            function show(n){if(n<0||n>=steps.length)return;steps[at].hidden=true;at=n;steps[at].hidden=false;
            const target=steps[at].querySelector('.hotspot')||steps[at].querySelector('button.next,button.again');if(target)target.focus();}
            document.addEventListener('click',e=>{const b=e.target.closest('button');
            if(!b){if(e.target.closest('.shot')){const h=steps[at].querySelector('.hotspot');if(h){h.classList.add('hint');setTimeout(()=>h.classList.remove('hint'),900);}}return;}
            if(b.classList.contains('back'))show(at-1);else if(b.classList.contains('again'))show(0);else show(at+1);});
            document.addEventListener('keydown',e=>{if(e.key==='ArrowRight')show(at+1);if(e.key==='ArrowLeft')show(at-1);});
            </script>
            </body></html>

            """
    }

    /// Only an image's `data:` URI becomes a picture: a page that fetches nothing must not be handed
    /// a reference that fetches, or one that runs.
    /// **The payload is checked too**: a prefix alone would let a `"` after it close the attribute.
    static func isImageDataURI(_ reference: String) -> Bool {
        let prefixes = ["data:image/png;base64,", "data:image/jpeg;base64,"]
        guard let prefix = prefixes.first(where: reference.hasPrefix) else { return false }
        let payload = reference.dropFirst(prefix.count)
        return !payload.isEmpty && payload.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=")
        }
    }
}
