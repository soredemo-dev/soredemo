import AVFoundation
import CoreMediaIO
import Foundation
import IOKit
import IOKit.usb

/// **An iPhone or iPad on the end of a cable, as something this app can record.**
///
/// Screen Studio, Motionik and ScreenKite all ship this and it opens mobile-app demos as a use
/// case. None of the seven open-source projects beside this repo implements it — searched for
/// `AllowScreenCaptureDevices` and `DeviceTypeExternal` across all of them and got nothing — so
/// there was no design to read and this is built from what macOS actually offers.
///
/// ### The one mechanism, and it is a switch rather than an API
///
/// A connected iOS device is invisible to AVFoundation until a process sets
/// `kCMIOHardwarePropertyAllowScreenCaptureDevices`. That is what QuickTime's
/// "Movie Recording → iPhone" turns on. Once it is on, the device appears as an ordinary
/// `AVCaptureDevice` of type `.external` carrying the phone's screen as video and its audio as a
/// separate device.
///
/// Measured on macOS 26 before any of this was written: `CMIOObjectSetPropertyData` returns 0,
/// and with nothing connected the external-device list is empty rather than erroring.
///
/// ### Recording one costs nothing new
///
/// An iOS screen is an `AVCaptureDevice`, and `CameraRecorder` already writes an
/// `AVCaptureDevice` to a movie file with `AVCaptureMovieFileOutput`. So a phone recording is
/// `CameraRecorder.start(camera: .device(uniqueID:name:))` with this type's id — no second
/// capture path, no second writer, no second set of failure modes.
///
/// **What a phone recording does NOT get, said here rather than discovered.** There is no cursor
/// to draw, no accessibility tree to read, and no clicks to zoom to — the automatic framing this
/// app is built around has nothing to work from. Everything else does work: the look, the
/// background, cutting, speed, captions, export. Manual zoom works. A person expecting the
/// automatic zoom they get on a Mac recording will not get it, and that is a property of there
/// being no observations to derive it from rather than a feature that was skipped.
public enum MobileScreen {
    /// A connected device's screen.
    public struct Source: Hashable, Sendable, Codable, Identifiable {
        public let uniqueID: String
        public let name: String
        public var id: String { uniqueID }

        public init(uniqueID: String, name: String) {
            self.uniqueID = uniqueID
            self.name = name
        }

        /// The name to put on a card.
        ///
        /// **The device's own name, whatever it looks like.** Measured over USB on 2026-08-27,
        /// AVFoundation reported this iPad's name as `[226, 150, 161, 226, 150, 161]` — two
        /// U+25A1 WHITE SQUARE characters and nothing else. I took that for a placeholder and
        /// replaced it with a generic label. It is not a placeholder: the device's owner
        /// confirmed it is the name they chose.
        ///
        /// So the rule is the producer-value rule, which this project states plainly and which
        /// I had just broken: an authored value wins over a derived one and is never silently
        /// replaced. Somebody who names their iPad in boxes, in Chinese, in emoji or in nothing
        /// legible at all has named it, and a recorder that decides their name carries no
        /// information is a recorder deciding something that is not its to decide.
        ///
        /// The only fallback left is for a name with no characters in it at all — a card has to
        /// say something, and there is nothing there to say.
        public var displayName: String {
            MobileScreen.isNameUsable(name) ? name : "Mobile device"
        }

        /// What `CameraRecorder` takes. The two types are deliberately distinct even though this
        /// converts freely: a phone is a capture SOURCE and a webcam is an overlay, and letting
        /// one value stand for both is how a phone ends up offered as a face in the corner.
        public var asCaptureDevice: CameraSource {
            .device(uniqueID: uniqueID, name: name)
        }
    }

    /// External video devices that were already visible before screen-capture devices were
    /// allowed — genuine webcams and capture cards.
    ///
    /// **Snapshotted once, before the switch is thrown**, which is the whole classification. See
    /// `isMobileScreen`.
    private nonisolated(unsafe) static var externalsBeforeAllowing: Set<String>?
    private static let lock = NSLock()

    /// Turns on the switch that makes connected iOS devices visible, once per process.
    ///
    /// **Idempotent and cheap to call.** The app calls it before listing sources; calling it
    /// again does nothing, and the snapshot it takes on the first call is what every later
    /// classification is measured against.
    ///
    /// Returns whether the property was set. `false` means this Mac refused, and every list
    /// below will then be empty rather than wrong.
    @discardableResult
    public nonisolated static func allowDevices() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if unsafe externalsBeforeAllowing != nil { return true }

        // **The snapshot comes first.** Anything external and visible right now is a webcam or a
        // capture card, because iOS screens cannot be visible yet — this process has not thrown
        // the switch.
        unsafe externalsBeforeAllowing = Set(
            AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video,
                                             position: .unspecified)
                .devices.map(\.uniqueID))

        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        // Safe here: both pointers are to locals that outlive the synchronous call, and the size
        // passed is `MemoryLayout<UInt32>.size` for a `UInt32` — the framework cannot read past
        // either.
        let status = unsafe CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &allow)
        return status == noErr
    }

    /// What `AVCaptureDevice.modelID` reads for an iOS screen-capture device.
    ///
    /// **Measured, on an iPad over USB, on 2026-08-27.** This string was written into an earlier
    /// version of this file as "widely said and therefore not used" — a branch nobody has run is
    /// a claim rather than a mechanism. It has now been run:
    ///
    ///     CONNECTED  <name>  model=iOS Device  type=AVCaptureDeviceTypeExternal
    ///
    /// Using it removes the limitation the previous rule carried whole: it no longer matters
    /// whether some other application threw the switch before this app launched.
    public static let mobileModelID = "iOS Device"

    /// Whether `device` is a phone or tablet screen rather than a camera.
    public nonisolated static func isMobileScreen(_ device: AVCaptureDevice) -> Bool {
        lock.lock()
        let before = unsafe externalsBeforeAllowing
        lock.unlock()
        return classify(deviceType: device.deviceType, modelID: device.modelID,
                        uniqueID: device.uniqueID, knownBefore: before)
    }

    /// The rule itself, over plain values.
    ///
    /// **Separated from `isMobileScreen` so it can be tested without a phone on the end of a
    /// cable.** `AVCaptureDevice` cannot be constructed, so a predicate that took one could only
    /// be exercised against whatever happened to be plugged into the machine running the tests.
    /// This takes the three facts the rule uses.
    ///
    /// **`modelID` first, the snapshot second.** The model string is a direct answer from the
    /// device and was measured; the snapshot is a heuristic — "it was not visible until this
    /// process allowed screen-capture devices" — which is right whenever it applies and silently
    /// wrong if another application threw the switch first. Keeping it as a fallback costs
    /// nothing and covers a future macOS that stops reporting the model string.
    static func classify(deviceType: AVCaptureDevice.DeviceType, modelID: String,
                         uniqueID: String, knownBefore: Set<String>?) -> Bool {
        guard deviceType == .external else { return false }
        if modelID == mobileModelID { return true }
        guard let knownBefore else { return false }
        return !knownBefore.contains(uniqueID)
    }

    /// Devices that have announced themselves, by unique id.
    private nonisolated(unsafe) static var announced: [String: Source] = [:]
    private nonisolated(unsafe) static var watching = false

    /// Starts listening for phones and tablets arriving and leaving.
    ///
    /// **The notification, not a discovery session, and this is a measured correction rather
    /// than a preference.** On macOS 26, with an iPad connected over USB and unlocked:
    ///
    ///     CONNECTED  <name>  model=iOS Device  type=AVCaptureDeviceTypeExternal
    ///     DiscoverySession(external, .video) -> 0
    ///
    /// The device announces itself and the discovery session does not list it — repeatedly, over
    /// twenty-five seconds, in the same process. An implementation built on enumeration alone
    /// finds nothing however long it waits, which is what the first version of this file did.
    ///
    /// **And the run loop has to be running.** CoreMediaIO discovers these on the main run loop;
    /// a probe that threw the switch and then slept saw nothing for six seconds, and the same
    /// code pumping `RunLoop.main` saw the device at once. In the app this is free — AppKit runs
    /// the loop — but it is the reason a command-line check of this feature reports nothing.
    ///
    /// Idempotent. Safe to call before every listing.
    public nonisolated static func startWatching() {
        allowDevices()
        lock.lock()
        defer { lock.unlock() }
        if unsafe watching { return }
        unsafe watching = true

        NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { note in
                guard let device = note.object as? AVCaptureDevice,
                      isMobileScreen(device) else { return }
                lock.lock()
                unsafe announced[device.uniqueID] = Source(uniqueID: device.uniqueID,
                                                           name: device.localizedName)
                lock.unlock()
            }
        NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: nil,
            queue: .main) { note in
                guard let device = note.object as? AVCaptureDevice else { return }
                lock.lock()
                unsafe announced.removeValue(forKey: device.uniqueID)
                lock.unlock()
            }
    }

    /// Every connected phone or tablet screen.
    ///
    /// The union of what has announced itself and what a discovery session reports. **Both, not
    /// either** — the notification is what actually works today and the session is what would
    /// work if a future macOS started listing these, and a union costs nothing while a choice
    /// would have to be revisited.
    public nonisolated static func available() -> [Source] {
        startWatching()
        lock.lock()
        var found = unsafe announced
        lock.unlock()
        for device in AVCaptureDevice.DiscoverySession(deviceTypes: [.external],
                                                       mediaType: .video, position: .unspecified)
            .devices where isMobileScreen(device) {
            found[device.uniqueID] = Source(uniqueID: device.uniqueID,
                                            name: device.localizedName)
        }
        return found.values.sorted { $0.name < $1.name }
    }

    /// Apple phones and tablets that are on the USB bus but are NOT offering their screens,
    /// by the name USB reports — "iPad", "iPhone".
    ///
    /// **This exists because the empty list has a knowable cause and saying nothing is the worst
    /// answer.** Measured with an iPad plugged in and locked: `ioreg` shows
    /// `iPad@00100000 <class IOUSBHostDevice>`, vendor "Apple Inc.", but the device exposes only
    /// PTP, Apple's USB multiplexor, and two NCM (network-over-USB) interfaces. The
    /// screen-capture interface is simply absent, so `available()` is correctly empty and a
    /// person sees nothing at all — with a cable in their hand.
    ///
    /// The screen interface appears once the device is **unlocked**. Trust is asked once and
    /// remembered, so somebody who has plugged this iPad in before will never see that prompt
    /// again and has no way to guess. It does NOT need Developer Mode; that is for running your
    /// own builds from Xcode and has nothing to do with this — measured, because it is the first
    /// thing anybody searches for.
    ///
    /// **Names, not a count.** "Unlock iPad" is a sentence somebody can act on; "1 device
    /// unavailable" is not.
    public nonisolated static func attachedButUnavailable() -> [String] {
        // **Counted, not name-matched, and a real iPad is why.** The first version compared the
        // USB product string against the capture device's `localizedName` and asked whether one
        // contained the other. Measured with an iPad attached and working:
        //
        //     available=["<the iPad's own name>"]  waiting=["iPad"]
        //
        // USB reports the family — "iPad" — and AVFoundation reports what the person called
        // their device, which in this case shared not one character with it. So a device that
        // was recording perfectly well was also reported as needing to be unlocked, and the menu
        // would have shown a working card beside "unlock it".
        //
        // There is no reliable mapping between the two names, and inventing one would be
        // guessing at what somebody names their iPad. Counting needs no mapping: if three Apple
        // mobile devices are on the bus and two are offering screens, one is waiting.
        //
        // **Dropping from the front is arbitrary and has to be.** Without a name mapping there
        // is no way to say WHICH of three iPads is the locked one, only how many are.
        Array(attachedMobileFamilyNames().dropFirst(available().count))
    }

    /// Every Apple phone or tablet on the USB bus, by the family name USB reports, before any
    /// subtraction.
    ///
    /// **Split from `attachedButUnavailable` so the relationship between the two is checkable.**
    /// With them fused, the only property a test could state was one that is true by
    /// construction — and a check that cannot fail is what this project spends its time
    /// removing. Now: `attachedButUnavailable().count == max(0, attached - offering)`.
    static func attachedMobileFamilyNames() -> [String] {
        var iterator: io_iterator_t = 0
        // Safe here: `&iterator` is an out-parameter IOKit fills with a handle this function
        // owns and releases, and the matching dictionary is consumed by the call.
        guard unsafe IOServiceGetMatchingServices(kIOMainPortDefault,
                                                  IOServiceMatching("IOUSBHostDevice"),
                                                  &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var found: [String] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            // Safe here: `takeRetainedValue` is the correct ownership for a `Create` function,
            // and the result is immediately bridged to a Swift `String` that outlives it.
            func string(_ key: String) -> String? {
                unsafe IORegistryEntryCreateCFProperty(service, key as CFString,
                                                       kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String
            }
            guard string("USB Vendor Name") == "Apple Inc." else { continue }
            guard let product = string("USB Product Name"), isMobileFamily(product) else {
                continue
            }
            found.append(product)
        }
        return found
    }

    /// Whether a device reported any name at all.
    ///
    /// **Deliberately almost everything passes, and that is the correction.** An earlier version
    /// required a letter or a digit, on the strength of an iPad reporting its name as two U+25A1
    /// WHITE SQUARE characters — which looked like a placeholder and was the name its owner had
    /// chosen. Replacing it was the producer-value rule broken: an authored value silently
    /// swapped for a derived one.
    ///
    /// What is left refuses only a name with nothing in it. A card has to say something, and an
    /// empty string is the one case where there is nothing to say.
    static func isNameUsable(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether a USB product name is a phone or tablet.
    ///
    /// Separated so it can be tested without hardware, for `classify`'s reason.
    static func isMobileFamily(_ usbProductName: String) -> Bool {
        let lowered = usbProductName.lowercased()
        return lowered.contains("ipad") || lowered.contains("iphone") || lowered.contains("ipod")
    }

    /// External video devices that are cameras — what a camera picker should offer.
    ///
    /// **This exists because throwing the switch changes what `CameraRecorder.available()`
    /// returns.** Its discovery session already asks for `.external`, so the moment a phone
    /// becomes visible it appears in the camera list and can be chosen as a face in the corner.
    /// That is not a hypothetical: it is what happened the first time `allowDevices()` was
    /// called before the picker was refreshed.
    public nonisolated static func camerasAmong(_ devices: [AVCaptureDevice]) -> [AVCaptureDevice] {
        devices.filter { !isMobileScreen($0) }
    }
}
