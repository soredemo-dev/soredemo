import Testing
import Render
@testable import Soredemo

// **This check was named in a comment for weeks and did not exist.** `StageStylePicker.apply`
// rebuilds the whole `StageStyle` on every slider move, so a field it forgets to carry is reset
// — silently, and only for the person who had set it. The comment beside `apply` said
// `everyStageStyleFieldSurvivesAChangeToAnother` was the check; nothing by that name was ever
// written, and a field added on 2026-09-25 went straight through the gap it was meant to guard.
//
// **Enumerated by `Mirror`, not by hand.** A written list of fields rots by omission and an
// omission is silent; this one grows by itself the day a field is added.

/// Every field set to something that is NOT `StageStyle.default`'s value, so a field that is
/// reset shows up as a difference. A fixture at the default is the identity element of the
/// operation being tested, and would pass whether or not the code is right.
private let distinctive = StageStyle(
    insetFraction: 0.13, cornerRadius: 27, shadowRadius: 19, shadowOpacity: 0.42,
    background: .solid(red: 0.2, green: 0.4, blue: 0.6), borderOpacity: 0.37,
    deviceModel: .iPad, deviceFinish: .silver, backgroundBlur: 0.61,
    tilt: StageTilt(pitch: 11, yaw: -13, distance: 3.1))

private func fields(_ style: StageStyle) -> [(String, String)] {
    Mirror(reflecting: style).children.map { ($0.label ?? "?", String(describing: $0.value)) }
}

/// The positive control, and it runs first: if any field of the fixture already equals the
/// default's, this suite cannot see that field being reset.
@Test func theFixtureDiffersFromTheDefaultInEveryField() {
    let mine = fields(distinctive)
    let theirs = Dictionary(uniqueKeysWithValues: fields(.default))
    #expect(!mine.isEmpty)
    for (name, value) in mine {
        #expect(theirs[name] != value, """
            `\(name)` is \(value) in both the fixture and StageStyle.default, so this suite \
            cannot tell whether it survives — give the fixture a different value
            """)
    }
}

/// Changing one field must leave every other one exactly as it was.
@Test func everyStageStyleFieldSurvivesAChangeToAnother() {
    let changes: [(String, (StageStyleModel) -> Void)] = [
        ("cornerRadius", { $0.setCornerRadius(31) }),
        ("insetFraction", { $0.setInset(0.2) }),
        ("shadowOpacity", { $0.setShadowOpacity(0.7) }),
        ("borderOpacity", { $0.setBorderOpacity(0.9) }),
        ("backgroundBlur", { $0.setBackgroundBlur(0.3) }),
        ("tilt", { $0.setTiltYaw(21) }),
    ]
    for (changed, change) in changes {
        let model = StageStyleModel()
        model.restore(distinctive)
        try? #require(fields(model.style).map(\.1) == fields(distinctive).map(\.1))
        change(model)
        let after = Dictionary(uniqueKeysWithValues: fields(model.style))
        for (name, value) in fields(distinctive) where name != changed {
            #expect(after[name] == value, """
                moving `\(changed)` reset `\(name)` from \(value) to \(after[name] ?? "gone") \
                — `StageStylePicker.apply` rebuilds the whole struct and did not carry it
                """)
        }
    }
}
