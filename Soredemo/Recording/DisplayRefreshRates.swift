import CoreGraphics

/// What every attached display can refresh at.
///
/// **Every display, not the main one, and the rates themselves rather than a ceiling.** This
/// asked `CGMainDisplayID()` for one number, so somebody with a 60 Hz built-in as their main
/// display and a 144 Hz panel beside it was offered 30 and 60 — for a recording of the
/// 144 Hz panel. And a ceiling could only ever pick from a fixed ladder, so that 144 Hz panel
/// was offered 120 and a sixth of its frames were discarded to match a number in an enum.
///
/// The choice is made before the target is picked, so the panel cannot know which display it
/// will be; every display's rate is the honest set. Choosing 144 and then recording the
/// 60 Hz one costs nothing — `minimumFrameInterval` is a ceiling and the panel is the floor,
/// so the recording is 60 either way.
///
/// **A display reporting 0 is dropped, not treated as still.** `CGDisplayMode.refreshRate`
/// answers 0 for several built-in panels rather than their actual rate, and an empty list is
/// what `available(forDisplayRates:)` reads as "this system said nothing".
///
/// **Here rather than in the panel that offers the rates**, because it is a question for the
/// window server, not a piece of a view.
enum DisplayRefreshRates {
    static var current: [Double] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        // `unsafe`: a C function filling a buffer this call owns. Safe — `ids` is sized by the
        // count the first call reported and outlives the second, and the values are only read
        // when the call reports success.
        guard unsafe CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.compactMap { CGDisplayCopyDisplayMode($0)?.refreshRate }.filter { $0 > 0 }
    }
}
