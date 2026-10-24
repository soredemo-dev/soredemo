import Foundation
import Testing
@testable import Framing

// The guide's text, from the steps that survive the edit. `docs/design/2026-10-25-a-guide-from-the-steps.md`.

private let phrases = GuidePhrases(click: "Click {label}.", clickIn: "Click {label} in {app}.",
                                   choose: "Choose {label}.", chooseIn: "Choose {label} in {app}.",
                                   pictureAlt: "Step {number}")

private func step(_ label: String, _ role: String = "AXButton", _ app: String? = "Keynote") -> GuideStep {
    GuideStep(label: label, role: role, application: app)
}

@Suite struct StepGuideTests {
    @Test func theMarkdownNamesEachStepAndItsApplicationWhenItChanges() {
        let text = StepGuide.markdown(title: "Exporting a movie",
                                      steps: [step("Export"), step("Movie…", "AXMenuItem"), step("Save", "AXButton", "Finder")],
                                      phrases: phrases)
        #expect(text == """
            # Exporting a movie

            1. Click **Export** in Keynote.

               ![Step 1](step-01.png)

            2. Choose **Movie…**.

               ![Step 2](step-02.png)

            3. Click **Save** in Finder.

               ![Step 3](step-03.png)

            """)
    }

    @Test func aMenuItemIsChosenAndEverythingElseIsClicked() {
        #expect(StepGuide.verb(forRole: "AXMenuItem") == .choose)
        #expect(StepGuide.verb(forRole: "AXButton") == .click)
        #expect(StepGuide.verb(forRole: "AXCheckBox") == .click, "no state in the log, so no \"turn on\"")
        #expect(StepGuide.verb(forRole: nil) == .click)
    }

    @Test func picturesAreNumberedSoTheySortInOrder() {
        #expect(StepGuide.pictureName(for: 3) == "step-03.png")
        #expect(StepGuide.pictureName(for: 42) == "step-42.png")
        #expect(StepGuide.pictureName(for: 120) == "step-120.png")
    }

    // MARK: - text from another application is not trusted

    /// A label is another application's text. In Markdown it must not become emphasis or a link.
    @Test func aHostileLabelIsInertInMarkdown() {
        let text = StepGuide.markdown(title: "T", steps: [step("**bold** [x](y) # h")], phrases: phrases)
        #expect(text.contains(##"Click **\*\*bold\*\* \[x\]\(y\) \# h** in Keynote."##))
        #expect(!text.contains("[x](y)"))
    }

    /// In HTML it must not become markup — a guide opened in a browser runs nothing.
    @Test func aHostileLabelIsTextInHTML() {
        let html = StepGuide.html(title: "A & B <i>", steps: [step("<img src=x onerror=alert(1)>"),
                                                                step("</p><script>alert(2)</script>", "AXButton", "Evil \"App\"")],
                                  phrases: phrases)
        #expect(!html.contains("<img src=x"))
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;img src=x onerror=alert(1)&gt;"))
        #expect(html.contains("Evil &quot;App&quot;"))
        #expect(html.contains("<title>A &amp; B &lt;i&gt;</title>"))
        #expect(html.contains(#"<img src="step-01.png" alt="Step 1">"#), "the guide's own markup is intact")
    }

    /// A label across two lines would break a list item out of its list.
    @Test func aLabelWithANewlineStaysOnItsLine() {
        let text = StepGuide.markdown(title: "T", steps: [step("Save\nAs")], phrases: phrases)
        #expect(text.contains("Click **Save As** in Keynote."))
    }

    /// The box sits over its picture, in percentages of it; a step with no box has none.
    @Test func aStepsBoxIsDrawnOverItsPicture() {
        let html = StepGuide.html(title: "T",
                                  steps: [GuideStep(label: "Export", role: "AXButton", application: "Keynote",
                                                    highlight: GuideHighlight(x: 0.3, y: 0.25, width: 0.125, height: 0.05)),
                                          step("Done")],
                                  phrases: phrases)
        #expect(html.contains(#"<span class="box" style="left:30.00%;top:25.00%;width:12.50%;height:5.00%"></span>"#))
        #expect(html.components(separatedBy: #"class="box""#).count == 2, "one box, for the one step that has one")
    }
}
