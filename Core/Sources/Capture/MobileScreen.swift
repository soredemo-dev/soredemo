import AVFoundation
import CoreMediaIO
import Foundation
import IOKit
import IOKit.usb

/// An iPhone or iPad on the end of a cable, as something this app can record.
///
/// A connected iOS device is invisible to AVFoundation until a process sets
/// `kCMIOHardwarePropertyAllowScreenCaptureDevices`; after that it is an ordinary
/// `AVCaptureDevice` of type `.external`, so `CameraRecorder` writes it with no
/// second capture path and no second set of failure modes.
///
/// **What a phone recording does NOT get, said here rather than discovered.** No
/// cursor, no accessibility tree, no clicks — so the automatic framing has nothing
/// to work from. Everything else works, manual zoom included.
///
/// Every rule in this file was measured on a real device;
/// `docs/design/recording-a-phone.md` holds the runs.
public enum MobileScreen {
    /// Which kind of device this is.
    ///
    /// **From USB, because the capture device does not say.** `AVCaptureDevice` reports
    /// `modelID` as the flat string "iOS Device" for every one of these — measured — and
    /// `localizedName` is whatever its owner called it, which on the machine this was written
    /// for is two box characters. Neither tells a phone from a tablet. The USB product string
    /// does: it is the plain family name, "iPad" or "iPhone".
    public enum Family: String, Hashable, Sendable, Codable, CaseIterable {
        case iPhone, iPad, iPod

        /// The SF Symbol for a card. Getting this wrong is small and visible: an iPhone glyph
        /// over an iPad is the first thing somebody notices and the last thing they trust.
        public var symbolName: String {
            switch self {
            case .iPhone: "iphone"
            case .iPad: "ipad"
            case .iPod: "ipodtouch"
            }
        }

        /// Matches the USB product string, which is the family name and nothing else.
        public init?(usbProductName: String) {
            let lowered = usbProductName.lowercased()
            // **iPod before iPhone**: "iPod touch" contains neither of the others, but ordering
            // the checks by specificity is what keeps a future "iPhone Pod" from mis-sorting.
            if lowered.contains("ipad") { self = .iPad }
            else if lowered.contains("ipod") { self = .iPod }
            else if lowered.contains("iphone") { self = .iPhone }
            else { return nil }
        }

        /// **Validated on decode** (D6 rule 8), and the reason is forward compatibility rather
        /// than ceremony. The synthesised `Decodable` for a raw-value enum throws on a value it
        /// does not know — so a project written by a future version that has learned about, say,
        /// a Vision device would fail to OPEN here, over an icon. `Source` decodes this with
        /// `try?` so an unrecognised family becomes `nil`, which is exactly what `nil` already
        /// means: could not be told apart. This initialiser is what makes that shape possible.
        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let known = Family(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "unknown device family \(raw)")
            }
            self = known
        }
    }

    /// A connected device's screen.
    public struct Source: Hashable, Sendable, Codable, Identifiable {
        public let uniqueID: String
        public let name: String
        /// `nil` when it could not be told apart — several devices attached at once, and no way
        /// to say which capture device is which. Named rather than guessed: a card showing an
        /// iPhone glyph over somebody's iPad is small, visible, and the kind of wrongness that
        /// makes everything beside it look unreliable.
        public let family: Family?
        public var id: String { uniqueID }

        public init(uniqueID: String, name: String, family: Family? = nil) {
            self.uniqueID = uniqueID
            self.name = name
            self.family = family
        }

        /// The SF Symbol for a card, falling back to a generic one when the family is unknown.
        public var symbolName: String { family?.symbolName ?? "ipad.and.iphone" }

        /// **A family this build does not recognise decodes as `nil`, not as a failure.** A
        /// project written by a later version that knows about a device kind this one does not
        /// must still open; the icon is the only thing lost, and `nil` already means "could not
        /// be told apart".
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.uniqueID = try container.decode(String.self, forKey: .uniqueID)
            self.name = try container.decode(String.self, forKey: .name)
            self.family = try? container.decodeIfPresent(Family.self, forKey: .family)
        }

        /// The name to put on a card: the device's own name, whatever it looks like.
        ///
        /// The producer-value rule. An iPad whose name is two U+25A1 characters has
        /// been named, and a recorder that decides that name carries no information
        /// is deciding something that is not its to decide. The only fallback is for
        /// a name with no characters in it at all.
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
    /// Measured on an iPad over USB, 2026-08-27; an earlier version wrote this
    /// string down as "widely said and therefore not used".
    public static let mobileModelID = "iOS Device"

    /// Whether `device` is a phone or tablet screen rather than a camera.
    public nonisolated static func isMobileScreen(_ device: AVCaptureDevice) -> Bool {
        lock.lock()
        let before = unsafe externalsBeforeAllowing
        lock.unlock()
        return classify(deviceType: device.deviceType, modelID: device.modelID,
                        uniqueID: device.uniqueID, knownBefore: before)
    }

    /// The rule itself, over plain values — separated from `isMobileScreen` so it
    /// can be tested without a phone on the end of a cable.
    ///
    /// `modelID` first, the snapshot second: the model string is a direct answer
    /// from the device, and the snapshot is a heuristic that is silently wrong if
    /// another application threw the switch first.
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
    /// The notification, not a discovery session — measured, the device announces
    /// itself and the session does not list it. And the run loop has to be running,
    /// which is free in the app and the reason a command-line check reports nothing.
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
                // **Resolved only when there is exactly one.** With two iPads attached there
                // is no mapping between a USB product string and a capture device's unique id,
                // and picking one would be a coin toss shown as an icon.
                let families = attachedMobileFamilyNames().compactMap(Family.init(usbProductName:))
                let family = families.count == 1 ? families[0] : nil
                lock.lock()
                unsafe announced[device.uniqueID] = Source(uniqueID: device.uniqueID,
                                                           name: device.localizedName,
                                                           family: family)
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
            let families = attachedMobileFamilyNames().compactMap(Family.init(usbProductName:))
            found[device.uniqueID] = Source(uniqueID: device.uniqueID,
                                            name: device.localizedName,
                                            family: families.count == 1 ? families[0] : nil)
        }
        return found.values.sorted { $0.name < $1.name }
    }

    /// Apple phones and tablets that are on the USB bus but are NOT offering their
    /// screens, by the name USB reports — "iPad", "iPhone".
    ///
    /// A locked device exposes no screen-capture interface at all, so the device
    /// list is correctly empty and a person sees nothing with a cable in their hand.
    /// Names rather than a count: "Unlock iPad" is a sentence somebody can act on.
    public nonisolated static func attachedButUnavailable() -> [String] {
        // Counted, not name-matched, and a real iPad is why: USB reports the family
        // ("iPad") and AVFoundation reports what the person called their device,
        // which shared not one character with it. Counting needs no mapping between
        // the two. Dropping from the front is arbitrary and has to be — there is no
        // way to say WHICH of three iPads is locked, only how many are.
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
    /// Deliberately almost everything passes. An earlier version required a letter
    /// or a digit, on the strength of an iPad whose name really was two U+25A1
    /// characters — the producer-value rule broken. Only a name with nothing in it
    /// is refused.
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
