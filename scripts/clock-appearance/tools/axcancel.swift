// axcancel <pid>: closes the popover open in System Settings' window, as Escape would
import AppKit
let pid = pid_t(CommandLine.arguments[1])!
func attr<T>(_ e: AXUIElement, _ a: String) -> T? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v as? T : nil }
func find(_ e: AXUIElement, depth: Int = 0) -> AXUIElement? {
    if (attr(e, kAXRoleAttribute) as String?) == "AXPopover" { return e }
    guard depth < 25, let children: [AXUIElement] = attr(e, kAXChildrenAttribute) else { return nil }
    for c in children { if let f = find(c, depth: depth + 1) { return f } }
    return nil
}
guard let window = (attr(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as [AXUIElement]?)?.first, let popover = find(window) else { print("no popover"); exit(1) }
print(AXUIElementPerformAction(popover, kAXCancelAction as CFString) == .success ? "closed" : "failed")
