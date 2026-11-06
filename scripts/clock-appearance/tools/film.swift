// film <pid> <x,y,w,h> <out>: films part of <pid>'s window (in points from its top left) while Accessibility
// presses its Clock Appearance… button and, 2 s later, closes the popover, as Escape would. It writes
// <out>-open.csv and <out>-close.csv, each frame that changed with its time since the press (or the close)
// and how much of the lock screen it shows (0…1): how far the picture has gone from where it was to where
// it settles, measured along that change, as a fade blends the two. <out>-before.png and <out>-open.png are
// the picture before and with the popover open.
import AppKit
import QuartzCore

setlinebuf(stdout)
let args = CommandLine.arguments
let pid = pid_t(args[1])!
let region = args[2].split(separator: ",").map { CGFloat(Double($0)!) }
let out = args[3]

func attr<T>(_ e: AXUIElement, _ a: String) -> T? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v as? T : nil }
func find(_ e: AXUIElement, depth: Int = 0, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
    if match(e) { return e }
    guard depth < 25, let children: [AXUIElement] = attr(e, kAXChildrenAttribute) else { return nil }
    for c in children { if let f = find(c, depth: depth + 1, match) { return f } }
    return nil
}
func role(_ e: AXUIElement) -> String? { attr(e, kAXRoleAttribute) }
guard let axWindow = (attr(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as [AXUIElement]?)?.first,
      let button = find(axWindow, { role($0) == "AXButton" && [attr($0, kAXTitleAttribute), attr($0, kAXDescriptionAttribute)].contains("Clock Appearance…") }) else {
    print("no Clock Appearance… button"); exit(1)
}

// The window, by its owner, and the part of it to film, in the screen's coordinates from its top left
let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as! [[String: Any]]
guard let info = windows.first(where: { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
                                     && (($0[kCGWindowBounds as String] as? [String: CGFloat])?["Height"] ?? 0) > 500 }),
      let number = info[kCGWindowNumber as String] as? CGWindowID,
      let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { print("no window"); exit(1) }
let rect = CGRect(x: bounds["X"]! + region[0], y: bounds["Y"]! + region[1], width: region[2], height: region[3])

typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
let createImage = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"), to: CreateImage.self)

/// Each capture's pixels, as 8-bit RGBA, with when it was taken
struct Frame { let time: Double; let pixels: [UInt8]; let image: CGImage }
func pixels(_ image: CGImage) -> [UInt8] {
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    data.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return data
}

// Film as fast as the window server gives pictures, on a thread of its own, keeping the times
let lock = NSLock()
var captures: [(Double, CGImage)] = []
var isFilming = true
Thread {
    while lock.withLock({ isFilming }) {
        if let image = createImage(rect, 8, number, 1)?.takeRetainedValue() {
            let time = CACurrentMediaTime()
            lock.withLock { captures.append((time, image)) }
        }
    }
}.start()

var pressTime = 0.0, closeTime = 0.0
DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
    pressTime = CACurrentMediaTime()
    print(AXUIElementPerformAction(button, kAXPressAction as CFString) == .success ? "pressed Clock Appearance… at \(String(format: "%.3f", pressTime))" : "press failed")
}
DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
    closeTime = CACurrentMediaTime()
    // The popover is in the window's tree, or, for an app's own NSPopover, a window of its own
    let popover = find(axWindow, { role($0) == "AXPopover" })
        ?? (attr(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as [AXUIElement]?)?.lazy.compactMap { find($0, { role($0) == "AXPopover" }) }.first
    print(popover.map { AXUIElementPerformAction($0, kAXCancelAction as CFString) == .success ? "closed the popover at \(String(format: "%.3f", closeTime))" : "close failed" } ?? "no popover")
}
DispatchQueue.main.asyncAfter(deadline: .now() + 4.6) {
    lock.withLock { isFilming = false }
    // Only the captures that differ from the one before, each at the time it first showed
    var frames: [Frame] = []
    for (time, image) in lock.withLock({ captures }) {
        let p = pixels(image)
        if frames.last?.pixels != p { frames.append(Frame(time: time, pixels: p, image: image)) }
    }
    print("\(captures.count) captures in 4 s, \(frames.count) different, \(captures.first.map { "\($0.1.width)×\($0.1.height)" } ?? "")")
    func write(_ image: CGImage, _ name: String) {
        try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)-\(name).png"))
    }
    /// The frames between `start` and `end`, each as far along from the last before `start` to the last
    /// before `end` as it is
    func phase(_ name: String, from start: Double, to end: Double, showing: (Double) -> Double) {
        guard let from = frames.last(where: { $0.time < start }), let to = frames.last(where: { $0.time < end }) else { return }
        if name == "open" { write(from.image, "before"); write(to.image, "open") }
        let change = zip(to.pixels, from.pixels).map { Double($0) - Double($1) }
        let length = change.reduce(0) { $0 + $1 * $1 }
        var csv = "time,lockscreen\n"
        for frame in frames where frame.time >= start && frame.time < end {
            let along = zip(zip(frame.pixels, from.pixels), change).reduce(0.0) { $0 + (Double($1.0.0) - Double($1.0.1)) * $1.1 } / max(length, 1)
            csv += String(format: "%.4f,%.4f\n", frame.time - start, showing(along))
        }
        try! csv.write(toFile: "\(out)-\(name).csv", atomically: true, encoding: .utf8)
        print("\(name): \(Int(length.squareRoot())) levels of change, written to \(out)-\(name).csv")
    }
    phase("open", from: pressTime, to: closeTime) { $0 }
    phase("close", from: closeTime, to: .infinity) { 1 - $0 }
    exit(0)
}
dispatchMain()
