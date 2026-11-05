// axdump <pid> [maxdepth]: System Settings' sheet as Accessibility sees it, each element's role, title and frame (window-relative)
import AppKit
let pid = pid_t(CommandLine.arguments[1])!, maxDepth = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 30
let app = AXUIElementCreateApplication(pid)
func attr<T>(_ e: AXUIElement, _ a: String) -> T? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v as? T : nil }
func frame(_ e: AXUIElement) -> CGRect? {
    guard let p: AXValue = attr(e, kAXPositionAttribute), let s: AXValue = attr(e, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero; AXValueGetValue(p, .cgPoint, &pt); AXValueGetValue(s, .cgSize, &sz); return CGRect(origin: pt, size: sz)
}
guard let windows: [AXUIElement] = attr(app, kAXWindowsAttribute), let window = windows.first, let wf = frame(window) else { exit(1) }
func dump(_ e: AXUIElement, _ depth: Int) {
    let role: String = attr(e, kAXRoleAttribute) ?? "?"
    let sub: String = attr(e, kAXSubroleAttribute) ?? ""
    let title: String = attr(e, kAXTitleAttribute) ?? attr(e, kAXDescriptionAttribute) ?? ""
    let value: Any? = attr(e, kAXValueAttribute) as CFTypeRef?
    var line = String(repeating: " ", count: depth) + role + (sub.isEmpty ? "" : "/" + sub)
    if !title.isEmpty { line += " \"\(title)\"" }
    if let v = value as? String, !v.isEmpty { line += " =\"\(v.prefix(40))\"" } else if let v = value as? NSNumber { line += " =\(v)" }
    if let f = frame(e) { line += String(format: "  [%.2f, %.2f  %.2f x %.2f]", f.minX - wf.minX, f.minY - wf.minY, f.width, f.height) }
    print(line)
    guard depth < maxDepth, let children: [AXUIElement] = attr(e, kAXChildrenAttribute) else { return }
    for c in children { dump(c, depth + 1) }
}
// The sheet, or the whole window
let sheets: [AXUIElement] = (attr(window, kAXChildrenAttribute) as [AXUIElement]? ?? []).filter { (attr($0, kAXRoleAttribute) as String?) == "AXSheet" }
dump(sheets.first ?? window, 0)
