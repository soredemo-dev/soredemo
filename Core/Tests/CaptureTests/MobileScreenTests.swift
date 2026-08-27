import AVFoundation
import Foundation
import Testing
@testable import Capture

/// **The hardware half of this lives in the cross-boundary probe, not here, and that is not
/// tidiness — it is a deadlock.**
///
/// `MobileScreen.allowDevices()` sets `kCMIOHardwarePropertyAllowScreenCaptureDevices`, which
/// starts the CoreMediaIO plug-in host: a process-global side effect on the same subsystem
/// AVFoundation and ScreenCaptureKit use. `swift test` runs every target in ONE process and
/// Swift Testing runs suites concurrently, so throwing that switch alongside the capture and
/// compositing suites hung 71 tests across the whole run at 0% CPU — none of them these, which
/// passed in 0.16 seconds when run alone.
///
/// So the switch is thrown in `scripts/cross-boundary-digest-probe.swift` § 20, which is a
/// separate process and is exactly what that instrument is for. What is left here is the rule
/// itself, over plain values, which needs no hardware and no switch.

/// The classification rule itself, over plain values — the part that can be checked without a
/// phone on the end of a cable.
///
/// `AVCaptureDevice` cannot be constructed, so every check above that goes through one is
/// exercised against whatever is plugged into the machine running the tests. On a laptop with no
/// phone that is nothing, and those checks pass without deciding anything. These do not.
@Suite struct MobileScreenClassificationTests {
    private let webcam = "0x1234567890"
    private let phone = "00008120-000A1B2C3D4E5F6G"

    /// **The rule: external, and not visible before the switch was thrown.**
    @Test func aDeviceThatAppearedOnlyAfterTheSwitchIsAPhone() {
        #expect(MobileScreen.classify(deviceType: .external, modelID: "Unknown", uniqueID: phone,
                                      knownBefore: [webcam]))
    }

    /// **A webcam that was already there is not**, however external it is. This is the case that
    /// keeps a USB camera out of the phone list.
    @Test func anExternalDeviceThatWasAlreadyVisibleIsACamera() {
        #expect(!MobileScreen.classify(deviceType: .external, modelID: "Some Webcam", uniqueID: webcam,
                                       knownBefore: [webcam]))
    }

    /// Built-in and Continuity cameras are cameras whatever the snapshot says — the device type
    /// is checked first, and it has to be, or a snapshot taken late would reclassify the FaceTime
    /// camera as a phone.
    @Test func aBuiltInOrContinuityCameraIsNeverAPhoneWhateverTheSnapshotSays() {
        for type in [AVCaptureDevice.DeviceType.builtInWideAngleCamera, .continuityCamera] {
            #expect(!MobileScreen.classify(deviceType: type, modelID: MobileScreen.mobileModelID,
                                           uniqueID: "anything", knownBefore: []),
                    "\(type.rawValue) classified as a phone against an empty snapshot")
        }
    }

    /// **Before the switch has ever been thrown, nothing is a phone.** A `nil` snapshot means
    /// this process has not made any iOS device visible, so an external device present now is
    /// something that was always there.
    @Test func nothingIsAPhoneBeforeTheSwitchHasBeenThrown() {
        #expect(!MobileScreen.classify(deviceType: .external, modelID: "Unknown", uniqueID: phone,
                                       knownBefore: nil))
    }

    /// The limit the SNAPSHOT rule carries, which the model string now covers: if another
    /// application threw the switch first, a connected phone is in the snapshot and the fallback
    /// alone reads it as a camera. A real device reports `modelID` and never reaches this.
    ///
    /// This is not a bug to be fixed by this rule — there is no way to un-throw the switch to
    /// check, and no supported property that says "this is a phone". It is pinned so that the
    /// day somebody adds a `modelID` branch, the behaviour it changes is written down.
    @Test func aPhoneAlreadyVisibleBecauseAnotherAppThrewTheSwitchReadsAsACamera() {
        #expect(!MobileScreen.classify(deviceType: .external, modelID: "Unknown", uniqueID: phone,
                                       knownBefore: [webcam, phone]), """
            The known limit has changed. If that is deliberate — a modelID branch, say — this \
            test is where the new behaviour gets written down.
            """)
    }
}

/// `MobileScreen.Source` — a connected device, as a value.
///
/// A pure type, so all of it is testable without a cable. It stayed in this file when the
/// hardware checks moved to the probe, and it has to: the entry rule requires every public type
/// in `Capture` to be exercised by a test in `Tests/CaptureTests`, and a type only the probe
/// touches would satisfy nothing.
@Suite struct MobileScreenSourceTests {
    private let source = MobileScreen.Source(uniqueID: "00008120-000A1B2C3D4E5F6G",
                                             name: "Jesse\u{2019}s iPad")

    /// **A phone is a capture SOURCE and a webcam is an overlay.** They convert freely and stay
    /// distinct types on purpose: letting one value stand for both is how a phone ends up
    /// offered as a face in the corner.
    @Test func aSourceConvertsToACaptureDeviceWithoutBecomingACamera() {
        #expect(source.asCaptureDevice == .device(uniqueID: source.uniqueID, name: source.name))
        #expect(source.asCaptureDevice.uniqueID == source.uniqueID)
    }

    /// Identified by the device's id, not its name. Two iPads can carry the same name; nothing
    /// carries the same unique id, and a list keyed on names would collapse them into one row.
    @Test func aSourceIsIdentifiedByItsDeviceIdRatherThanItsName() {
        #expect(source.id == source.uniqueID)
        let sameName = MobileScreen.Source(uniqueID: "different", name: source.name)
        #expect(sameName.id != source.id)
        #expect(sameName != source)
    }

    /// Codable, because a project made from a phone recording names what it was recorded from —
    /// and the name is a person's own words about their device, which must survive a round trip
    /// including whatever is in it.
    @Test func aSourceSurvivesARoundTripWithItsNameIntact() throws {
        let round = try JSONDecoder().decode(
            MobileScreen.Source.self, from: JSONEncoder().encode(source))
        #expect(round == source)
        #expect(round.name == "Jesse\u{2019}s iPad", "a curly apostrophe did not survive")
    }
}

/// Recognising a phone or tablet by the name USB reports.
///
/// **Why this matters more than it looks.** Measured with an iPad plugged in and locked: the
/// device is on the bus — `ioreg` shows `iPad@00100000`, vendor "Apple Inc." — and exposes PTP,
/// Apple's USB multiplexor and two network-over-USB interfaces. The screen-capture interface is
/// absent, so the capture list is correctly empty and a person sees nothing at all with a cable
/// in their hand. This is what turns that silence into "unlock it and tap Trust".
@Suite struct MobileFamilyNameTests {
    @Test func theThreeFamiliesAreRecognised() {
        #expect(MobileScreen.isMobileFamily("iPad"))
        #expect(MobileScreen.isMobileFamily("iPhone"))
        #expect(MobileScreen.isMobileFamily("iPod touch"))
    }

    /// **Case-insensitively**, because the USB product string is whatever the device reports and
    /// this app does not get to decide how Apple spells it this year.
    @Test func theMatchIsCaseInsensitive() {
        #expect(MobileScreen.isMobileFamily("IPAD"))
        #expect(MobileScreen.isMobileFamily("iphone"))
    }

    /// A real device reports the plain family name, but a longer one must still match — the
    /// alternative is a table of model strings that goes stale every September.
    @Test func aLongerProductNameStillMatches() {
        #expect(MobileScreen.isMobileFamily("iPad Pro"))
        #expect(MobileScreen.isMobileFamily("Apple iPhone 17 Pro"))
    }

    /// **Everything else is not a phone**, including the Apple accessories most likely to be on
    /// the same bus. A keyboard prompting "unlock your iPad and tap Trust" is worse than no
    /// prompt at all.
    @Test func otherAppleHardwareIsNotAPhone() {
        for name in ["Magic Keyboard", "Magic Trackpad", "Studio Display", "AirPods",
                     "Apple Watch Magnetic Charger", "USB-C Digital AV Multiport Adapter"] {
            #expect(!MobileScreen.isMobileFamily(name), "\(name) read as a phone")
        }
        #expect(!MobileScreen.isMobileFamily(""))
    }
}


/// The measured rule: `modelID == "iOS Device"`.
///
/// **Measured on 2026-08-27, on an iPad over USB**, after an earlier version of this file
/// deliberately refused to use the string because nothing here had ever seen one:
///
///     CONNECTED  <name>  model=iOS Device  type=AVCaptureDeviceTypeExternal
///
/// It is the primary rule now, and it removes the snapshot rule's whole limitation — it no
/// longer matters whether another application threw the switch first.
@Suite struct MobileScreenModelIDTests {
    @Test func theMeasuredModelStringIdentifiesAPhoneOnItsOwn() {
        #expect(MobileScreen.classify(deviceType: .external,
                                      modelID: MobileScreen.mobileModelID,
                                      uniqueID: "anything",
                                      // Even in the snapshot — the case the fallback gets wrong.
                                      knownBefore: ["anything"]), """
            A device reporting modelID "\(MobileScreen.mobileModelID)" was read as a camera \
            because it was in the before-snapshot. The model string is a direct answer from the \
            device and must win over the heuristic.
            """)
    }

    /// **The model string does not override the device type.** A built-in camera reporting
    /// anything at all is still a camera; the phone list is external devices only.
    @Test func theModelStringDoesNotOverrideTheDeviceType() {
        #expect(!MobileScreen.classify(deviceType: .builtInWideAngleCamera,
                                       modelID: MobileScreen.mobileModelID,
                                       uniqueID: "x", knownBefore: nil))
    }

    /// Exact, not a prefix or a case-insensitive contains. A webcam calling itself
    /// "iOS Device Companion" is not a phone, and loosening this to catch a hypothetical
    /// variant would be guessing at a string nobody has measured.
    @Test func theModelStringIsMatchedExactly() {
        for near in ["ios device", "iOS Device Companion", "Apple iOS Device", " iOS Device"] {
            #expect(!MobileScreen.classify(deviceType: .external, modelID: near,
                                           uniqueID: "x", knownBefore: nil),
                    "\(near) matched the model rule")
        }
    }
}

/// Whether a device reported any name at all.
///
/// **These tests were written backwards first, and the correction is the point.** A real iPad
/// over USB on 2026-08-27 reported its name as `[226, 150, 161, 226, 150, 161]` — two U+25A1
/// WHITE SQUARE characters. I read that as a placeholder, wrote a rule requiring a letter or a
/// digit, and replaced the name with a generic label. Its owner then said: that IS my device
/// name.
///
/// Replacing it was the producer-value rule broken — an authored value silently swapped for a
/// derived one — in the one place where the authored value looked wrong to me. Which is exactly
/// where that rule is for.
@Suite struct MobileScreenNameTests {
    /// **A name made of boxes is a name.** This is the measured case, and it is here as the
    /// thing that must NOT be replaced rather than as the thing that must.
    @Test func aNameThatLooksLikeNothingIsStillTheNameSomebodyChose() {
        let boxes = "\u{25A1}\u{25A1}"
        #expect(MobileScreen.isNameUsable(boxes))
        #expect(MobileScreen.Source(uniqueID: "x", name: boxes).displayName == boxes, """
            The device's own name was replaced with a generic label. Its owner named it; a \
            recorder does not get to decide their name carries no information.
            """)
    }

    /// The only fallback: nothing at all. A card has to say something.
    @Test func onlyAnEmptyNameFallsBack() {
        #expect(!MobileScreen.isNameUsable(""))
        #expect(!MobileScreen.isNameUsable("   "))
        #expect(!MobileScreen.isNameUsable("\n\t"))
        #expect(MobileScreen.Source(uniqueID: "x", name: "").displayName == "Mobile device")
    }

    /// Every script, every symbol, emoji alone — all names. The rule that rejected emoji was
    /// part of the same mistake.
    @Test func everyKindOfNameIsKept() {
        for name in ["Jesse\u{2019}s iPad", "\u{5C0F}\u{660E}\u{7684} iPad", "\u{30A2}\u{30A4}\u{30D1}\u{30C3}\u{30C9}",
                     "\u{0627}\u{0644}\u{0622}\u{064A}\u{0628}\u{0627}\u{062F}", "iPad 2", "\u{1F600}",
                     "\u{2014}\u{2014}\u{2014}", "\u{25A1}"] {
            #expect(MobileScreen.isNameUsable(name), "\(name) was rejected")
            #expect(MobileScreen.Source(uniqueID: "x", name: name).displayName == name,
                    "\(name) was replaced")
        }
    }
}
