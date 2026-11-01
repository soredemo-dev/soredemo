// The window list, presses and the one click `make-readme-screenshots.sh` needs. A press goes
// through accessibility to the element, so nothing reaches whatever app is in front.
//
//   readme-screenshot-ui windows <pid>          id layer x y width height, front to back
//   readme-screenshot-ui press <pid> <name>     the first control whose title, description or
//                                               identifier is <name>
//   readme-screenshot-ui front <pid>            brings that app to the front
//   readme-screenshot-ui click <pid> <name>     one click on the middle of the first element named
//                                               <name>, refused unless that app's window is the
//                                               topmost one there — for the scripted take, whose
//                                               steps are real clicks
//   readme-screenshot-ui click-menu-bar <x> <y>  one click at a point in the menu bar, refused
//                                               unless the menu bar is the topmost window there —
//                                               so it can land on no app's window — and the pointer
//                                               put back where it was
// Exits 2 when there is nothing to press, so a missing control is a failure and not a
// screenshot of whatever was already on screen.
import AppKit
import ApplicationServices

let arguments = CommandLine.arguments
let usage = "usage: readme-screenshot-ui windows|press|front|click <pid> [name] | click-menu-bar <x> <y>"
guard arguments.count >= 3, let pid = pid_t(arguments[2]) else {
    print(usage)
    exit(64)
}

func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
}

func first(under element: AXUIElement, depth: Int = 0, where match: (AXUIElement) -> Bool) -> AXUIElement? {
    if match(element) { return element }
    guard depth < 40, let children = value(element, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
    for child in children {
        if let found = first(under: child, depth: depth + 1, where: match) { return found }
    }
    return nil
}

/// The topmost on-screen window containing a point, front to back as the window server lists them.
/// **Not the Dock's display-sized window**: it is transparent, lies over everything at the Dock's
/// level, and passes clicks through — counting it, every point on screen is "the Dock".
func topmostWindow(at point: CGPoint) -> [String: Any]? {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.first { window in
        guard let bounds = window[kCGWindowBounds as String] as? [String: Double] else { return false }
        let rect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0,
                          height: bounds["Height"] ?? 0)
        if window[kCGWindowOwnerName as String] as? String == "Dock", rect == CGDisplayBounds(CGMainDisplayID()) {
            return false
        }
        return rect.contains(point)
    }
}

/// One left click, the pointer put back where the person left it.
func click(at point: CGPoint) {
    let back = CGEvent(source: nil)?.location
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        usleep(60_000)
    }
    if let back { CGWarpMouseCursorPosition(back) }
}

func named(_ element: AXUIElement, _ name: String) -> Bool {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute].contains {
        value(element, $0) as? String == name
    }
}

switch arguments[1] {
case "windows":
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for window in windows where window[kCGWindowOwnerPID as String] as? pid_t == pid {
        guard let id = window[kCGWindowNumber as String] as? Int,
              let layer = window[kCGWindowLayer as String] as? Int,
              let bounds = window[kCGWindowBounds as String] as? [String: Double] else { continue }
        print(id, layer, Int(bounds["X"] ?? 0), Int(bounds["Y"] ?? 0),
              Int(bounds["Width"] ?? 0), Int(bounds["Height"] ?? 0))
    }
case "press" where arguments.count == 4:
    let app = AXUIElementCreateApplication(pid)
    let pressable: Set = ["AXButton", "AXMenuItem", "AXMenuButton", "AXRadioButton", "AXCheckBox",
                          "AXPopUpButton", "AXLink", "AXMenuBarItem"]
    let target = first(under: app) { element in
        guard let role = value(element, kAXRoleAttribute) as? String, pressable.contains(role) else { return false }
        return named(element, arguments[3])
    }
    guard let target else {
        print("nothing to press: \(arguments[3])")
        exit(2)
    }
    guard AXUIElementPerformAction(target, kAXPressAction as CFString) == .success else {
        print("the press was refused: \(arguments[3])")
        exit(2)
    }
case "front":
    guard AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString,
                                       kCFBooleanTrue) == .success else {
        print("could not bring \(pid) to the front")
        exit(2)
    }
case "click" where arguments.count == 4:
    let app = AXUIElementCreateApplication(pid)
    guard let element = first(under: app, where: { named($0, arguments[3]) }),
          let position = value(element, kAXPositionAttribute), let size = value(element, kAXSizeAttribute) else {
        print("nothing to click: \(arguments[3])")
        exit(2)
    }
    var origin = CGPoint.zero, extent = CGSize.zero
    AXValueGetValue(position as! AXValue, .cgPoint, &origin)
    AXValueGetValue(size as! AXValue, .cgSize, &extent)
    let point = CGPoint(x: origin.x + extent.width / 2, y: origin.y + extent.height / 2)
    guard topmostWindow(at: point)?[kCGWindowOwnerPID as String] as? pid_t == pid else {
        print("refused: \(pid) is not the topmost window at \(Int(point.x)), \(Int(point.y))")
        exit(2)
    }
    click(at: point)
case "click-menu-bar" where arguments.count == 4:
    guard let x = Double(arguments[2]), let y = Double(arguments[3]) else { print(usage); exit(64) }
    let point = CGPoint(x: x, y: y)
    let top = topmostWindow(at: point)
    let owner = top?[kCGWindowOwnerName as String] as? String ?? "nothing"
    let name = top?[kCGWindowName as String] as? String ?? ""
    guard owner == "Window Server", name == "Menubar" else {
        print("refused: the topmost window at \(Int(x)), \(Int(y)) is \(owner) \(name), not the menu bar")
        exit(2)
    }
    click(at: point)
default:
    print(usage)
    exit(64)
}
