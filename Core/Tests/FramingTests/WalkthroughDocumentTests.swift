import Foundation
import Testing
@testable import Framing

// The walkthrough page. `docs/design/2026-10-23-interactive-walkthrough-export.md`.

private let phrases = GuidePhrases(click: "Click {label}.", clickIn: "Click {label} in {app}.",
                                   choose: "Choose {label}.", chooseIn: "Choose {label} in {app}.",
                                   pictureAlt: "Step {number}")
private let words = WalkthroughWords(stepOf: "Step {number} of {total}", next: "Next", back: "Back",
                                     finished: "You have finished this walkthrough.", startAgain: "Start again")

private func page(_ steps: [GuideStep]) -> String {
    WalkthroughDocument.html(title: "Exporting", steps: steps,
                             pictures: steps.indices.map { "data:image/png;base64,AAA\($0)" },
                             phrases: phrases, words: words)
}

private let box = GuideHighlight(x: 0.3, y: 0.25, width: 0.125, height: 0.05)

@Suite struct WalkthroughDocumentTests {
    @Test func eachStepIsASectionAndOnlyTheFirstIsShown() {
        let html = page([GuideStep(label: "Export", role: "AXButton", application: "Keynote", highlight: box),
                         GuideStep(label: "Movie…", role: "AXMenuItem", application: "Keynote", highlight: box)])
        #expect(html.components(separatedBy: "<section").count == 4, "two steps and the finish")
        #expect(html.contains(#"<section class="step" data-step="0">"#))
        #expect(html.contains(#"<section class="step" data-step="1" hidden>"#))
        #expect(html.contains("Step 1 of 2") && html.contains("Step 2 of 2"))
        #expect(html.contains("Click <strong>Export</strong> in Keynote."))
    }

    /// The thing to press is a real button, labelled with the step's sentence, placed on the box —
    /// so a screen reader can complete the walkthrough too.
    @Test func theHotspotIsALabelledButtonOnTheBox() {
        let html = page([GuideStep(label: "Export", role: "AXButton", application: "Keynote", highlight: box)])
        #expect(html.contains(#"<button class="hotspot" aria-label="Click Export in Keynote." style="left:30.00%;top:25.00%;width:12.50%;height:5.00%"></button>"#))
    }

    /// A step whose element is not on its picture has no hotspot to aim at; Next still advances.
    @Test func aStepWithNoBoxHasNoHotspotButCanStillBeLeft() {
        let html = page([GuideStep(label: "Export", role: "AXButton", application: "Keynote")])
        #expect(!html.contains(#"class="hotspot""#))
        #expect(html.contains(#"<button class="next">Next</button>"#))
    }

    /// Nothing but the page's own: no script source, no stylesheet or image from anywhere.
    @Test func thePageFetchesNothing() {
        let html = page([GuideStep(label: "Export", role: "AXButton", application: "Keynote", highlight: box)])
        #expect(!html.contains("src=\"http") && !html.contains("href=\"http") && !html.contains("<script src"))
        #expect(html.contains(#"<img src="data:image/png;base64,AAA0""#))
    }

    /// Another application's text is text here too: in the sentence, the aria-label and the title.
    @Test func aHostileLabelRunsNothing() {
        let html = page([GuideStep(label: #"<img src=x onerror=alert(1)>" onclick="x"#, role: "AXButton",
                                   application: "</script><script>alert(2)", highlight: box)])
        #expect(!html.contains("<img src=x"))
        #expect(!html.contains("</script><script>"))
        #expect(!html.contains(#"" onclick="x"#))
        #expect(html.contains("&lt;img src=x onerror=alert(1)&gt;&quot; onclick=&quot;x"))
    }

    /// A picture reference that is not a data URI of an image is refused, not written.
    @Test func onlyAnImageDataURIBecomesAPicture() {
        let html = WalkthroughDocument.html(title: "T",
                                            steps: [GuideStep(label: "A", role: nil, application: nil)],
                                            pictures: [#"javascript:alert(1)"#],
                                            phrases: phrases, words: words)
        #expect(!html.contains("javascript:"))
        let smuggled = WalkthroughDocument.html(title: "T",
                                                steps: [GuideStep(label: "A", role: nil, application: nil)],
                                                pictures: [#"data:image/png;base64,AAA" onerror="alert(1)"#],
                                                phrases: phrases, words: words)
        #expect(!smuggled.contains("onerror"), "a quote after the prefix must not close the attribute")
    }
}
