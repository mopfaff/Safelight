// flicker <seconds> <kill-at> [store-to-copy]: films the desktop under every window on the main display and
// restarts WallpaperAgent at kill-at (copying a store in first, if given); prints how far each frame is from the first
import AppKit
typealias F = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
let create = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"), to: F.self)
let seconds = Double(CommandLine.arguments[1])!, killAt = Double(CommandLine.arguments[2])!
let store = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : nil
let f = NSScreen.screens[0].frame
let rect = CGRect(x: f.midX - 400, y: f.midY - 300, width: 800, height: 600)
func grab() -> [UInt8]? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
    guard let back = list.filter({ ($0[kCGWindowLayer as String] as! Int) >= -2147483600 }).last,
          let image = create(rect, 4, back[kCGWindowNumber as String] as! UInt32, 1 << 4 /* nominal resolution */)?.takeRetainedValue() else { return nil }
    let w = 80, h = 60
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .medium
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return px
}
func wallpaperWindows() -> Int {
    (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]).filter { ($0[kCGWindowOwnerName as String] as? String)?.hasPrefix("Wallpaper") == true }.count
}
let start = Date(); var first: [UInt8]?; var killed = false
while Date().timeIntervalSince(start) < seconds {
    let t = Date().timeIntervalSince(start)
    if !killed && t >= killAt {
        if let store { _ = try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/Library/Application Support/com.apple.wallpaper/Store/Index.plist.tmp"); 
            let dst = NSHomeDirectory() + "/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
            _ = try? FileManager.default.removeItem(atPath: dst); try! FileManager.default.copyItem(atPath: store, toPath: dst) }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/killall"); p.arguments = ["-9", "WallpaperAgent"]; try! p.run(); p.waitUntilExit()
        killed = true; print(String(format: "%6.3f KILL", t))
    }
    guard let px = grab() else { print(String(format: "%6.3f none", t)); continue }
    if first == nil { first = px }
    var diff = 0, maxd = 0, sum = [0, 0, 0]
    for i in stride(from: 0, to: px.count, by: 4) {
        let d = (0..<3).map { abs(Int(px[i + $0]) - Int(first![i + $0])) }.max()!
        diff += d > 8 ? 1 : 0; maxd = max(maxd, d)
        for c in 0..<3 { sum[c] += Int(px[i + c]) }
    }
    let n = px.count / 4
    print(String(format: "%6.3f mean %3d %3d %3d  changed %4.1f%%  max %3d  wp-windows %d", t, sum[0] / n, sum[1] / n, sum[2] / n, Double(diff) * 100 / Double(n), maxd, wallpaperWindows()))
}
