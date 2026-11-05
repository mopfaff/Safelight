// axpress <pid> <title> [read-popup]: presses the first button with that title in System Settings' window (or its sheet); prints the sheet's pop-up value
import AppKit
let pid = pid_t(CommandLine.arguments[1])!, wanted = CommandLine.arguments[2]
func attr<T>(_ e: AXUIElement, _ a: String) -> T? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v as? T : nil }
func find(_ e: AXUIElement, _ match: (AXUIElement) -> Bool, depth: Int = 0) -> AXUIElement? {
    if match(e) { return e }
    guard depth < 25, let children: [AXUIElement] = attr(e, kAXChildrenAttribute) else { return nil }
    for c in children { if let f = find(c, match, depth: depth + 1) { return f } }
    return nil
}
let app = AXUIElementCreateApplication(pid)
guard let window = (attr(app, kAXWindowsAttribute) as [AXUIElement]?)?.first else { exit(1) }
let sheet = find(window) { (attr($0, kAXRoleAttribute) as String?) == "AXSheet" }
if wanted == "-" {
    let popup = find(sheet ?? window) { (attr($0, kAXRoleAttribute) as String?) == "AXPopUpButton" && (attr($0, kAXRoleAttribute) as String?) != nil && find($0, { _ in false }) == nil && ((attr($0, kAXParentAttribute) as AXUIElement?).flatMap { attr($0, kAXRoleAttribute) as String? } == "AXGroup") }
    print((popup.flatMap { attr($0, kAXValueAttribute) as String? }) ?? "no popup")
} else if let button = find(window, { (attr($0, kAXRoleAttribute) as String?) == "AXButton" && ((attr($0, kAXTitleAttribute) as String?) == wanted || (attr($0, kAXDescriptionAttribute) as String?) == wanted) }) {
    print(AXUIElementPerformAction(button, kAXPressAction as CFString) == .success ? "pressed \(wanted)" : "failed")
} else { print("no \(wanted)") }
