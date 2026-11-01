// The window list and the presses `make-readme-screenshots.sh` needs, with no synthesised input:
// a press goes through accessibility to the element, so nothing reaches whatever app is in front.
//
//   readme-screenshot-ui windows <pid>          id layer x y width height, front to back
//   readme-screenshot-ui press <pid> <name>     the first control whose title, description or
//                                               identifier is <name>
// Exits 2 when there is nothing to press, so a missing control is a failure and not a
// screenshot of whatever was already on screen.
import AppKit
import ApplicationServices

let arguments = CommandLine.arguments
guard arguments.count >= 3, let pid = pid_t(arguments[2]) else {
    print("usage: readme-screenshot-ui windows|press <pid> [name]")
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
        return [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute].contains {
            value(element, $0) as? String == arguments[3]
        }
    }
    guard let target else {
        print("nothing to press: \(arguments[3])")
        exit(2)
    }
    guard AXUIElementPerformAction(target, kAXPressAction as CFString) == .success else {
        print("the press was refused: \(arguments[3])")
        exit(2)
    }
default:
    print("usage: readme-screenshot-ui windows|press <pid> [name]")
    exit(64)
}
