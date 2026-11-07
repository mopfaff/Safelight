// Films the real desktop while it changes to another picture, to measure WallpaperAgent's own fade, which
// System Settings › Wallpaper's picture of the desktop shows live, against the one Safelight's previews
// copy (2 s, easing out). It changes the real desktop, so ask first, back up the wallpaper store, and put
// it back afterwards; scripts/wallpaper-preview/desktop-fade.sh does all that.
//
//   desktop-fade film <app> <picture> <out>   films a part of the agent's window for the main display,
//                                  has <app> (this, as an .app) put <picture> on that display's current
//                                  Space half a second in, films until 3.5 s after, and logs, for each
//                                  frame that changed, how far it is from the desktop before to the one
//                                  after, against the agent's fade
//   desktop-fade set <picture> <time file>   (as the .app) writes the time to the file and puts the
//                                  picture on the main display's current Space
//
// Filming needs the right to record the screen, which the shell has and the .app doesn't; setting needs
// an .app with a bundle ID of its own and NSApplication.run(): setDesktopImageURL from a bare binary, or
// before the run loop, silently does nothing. Times are CACurrentMediaTime(), the same in both.
import AppKit
import QuartzCore

setlinebuf(stdout)
let arguments = CommandLine.arguments
let mode = arguments[1]
let out = mode == "film" ? arguments[4] : ""

typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
let createImage = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"), to: CreateImage.self)

/// How far CAMediaTimingFunction(name: .easeOut), the cubic Bézier (0, 0) (0.58, 1), has gone at `x`
func easeOut(_ x: Double) -> Double {
    let x = min(max(x, 0), 1)
    func bezier(_ t: Double, _ a: Double, _ b: Double) -> Double { 3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t }
    var low = 0.0, high = 1.0
    for _ in 0..<60 {
        let middle = (low + high) / 2
        if bezier(middle, 0, 0.58) < x { low = middle } else { high = middle }
    }
    return bezier((low + high) / 2, 0, 1)
}

func pixels(_ image: CGImage) -> [UInt8] {
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    data.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return data
}

func write(_ image: CGImage, _ name: String) {
    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)-\(name).png"))
}

if mode == "set" {
    let picture = URL(fileURLWithPath: arguments[2])
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    DispatchQueue.main.async {
        guard let screen = NSScreen.screens.first else { exit(1) }
        try? String(CACurrentMediaTime()).write(toFile: arguments[3], atomically: true, encoding: .utf8)
        do {
            try NSWorkspace.shared.setDesktopImageURL(picture, for: screen, options: [:])
        } catch {
            try? "couldn't set it: \(error)".write(toFile: arguments[3], atomically: true, encoding: .utf8)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
    }
    app.run()
}

let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Filming the desktop")

DispatchQueue.main.async {
    guard let screen = NSScreen.screens.first else { print("no display"); exit(1) }
    // WallpaperAgent's own window for the display, which it draws the desktop in (on macOS 27, owned by
    // "Wallpaper" and named "Offscreen Wallpaper Window", though it's on screen). What's under every
    // window comes back a flat grey while the desktop is covered, as by a full-screen app.
    let frame = screen.frame
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
    guard let window = list.first(where: { info in
              (info[kCGWindowOwnerName as String] as? String) == "Wallpaper" && (info[kCGWindowName as String] as? String) == "Offscreen Wallpaper Window"
                  && (info[kCGWindowBounds as String] as? [String: CGFloat]).map { $0["X"] == 0 && $0["Y"] == 0 && $0["Width"] == frame.width } == true
          }),
          let backNumber = window[kCGWindowNumber as String] as? UInt32 else { print("no wallpaper window for the main display"); exit(1) }
    // A part of the middle of the main display, at 1x, so frames come fast
    let rect = CGRect(x: frame.midX - 200, y: frame.height / 2 - 125, width: 400, height: 250)
    let lock = NSLock()
    var captures: [(time: Double, image: CGImage)] = []
    var isFilming = true
    Thread {
        while lock.withLock({ isFilming }) {
            if let image = createImage(rect, 8, backNumber, 1 | 16)?.takeRetainedValue() {
                let time = CACurrentMediaTime()
                lock.withLock { captures.append((time, image)) }
            }
        }
    }.start()

    let timeFile = out + "-set-time.txt"
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", arguments[2], "--args", "set", arguments[3], timeFile]
        try? open.run()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
        let captures = lock.withLock { isFilming = false; return captures }
        let written = (try? String(contentsOfFile: timeFile, encoding: .utf8)) ?? "nothing"
        guard let setTime = Double(written) else { print("the .app didn't set it: \(written)"); exit(1) }
        print(String(format: "set %@ at %.3f", (arguments[3] as NSString).lastPathComponent, setTime))
        var frames: [(time: Double, pixels: [UInt8], image: CGImage)] = []
        for capture in captures {
            let p = pixels(capture.image)
            if frames.last?.pixels != p { frames.append((capture.time, p, capture.image)) }
        }
        print("\(captures.count) captures in 3.5 s, \(frames.count) different, \(captures.first.map { "\($0.image.width) by \($0.image.height)" } ?? "")")
        guard let from = frames.last(where: { $0.time < setTime }) ?? frames.first, let to = frames.last else { exit(1) }
        write(from.image, "before")
        write(to.image, "after")
        let change = zip(to.pixels, from.pixels).map { Double($0) - Double($1) }
        let length = change.reduce(0) { $0 + $1 * $1 }
        print("\(Int(length.squareRoot())) levels of change")
        var measured: [(time: Double, along: Double)] = []
        var csv = "time,along\n"
        for frame in frames where frame.time >= setTime {
            let along = zip(zip(frame.pixels, from.pixels), change).reduce(0.0) { $0 + (Double($1.0.0) - Double($1.0.1)) * $1.1 } / max(length, 1)
            measured.append((frame.time - setTime, along))
            csv += String(format: "%.4f,%.4f\n", frame.time - setTime, along)
        }
        try? csv.write(toFile: "\(out).csv", atomically: true, encoding: .utf8)
        // When it started to change, and how far each frame is from the agent's fade starting then
        guard let start = measured.first(where: { $0.along > 0.01 })?.time else { print("it didn't change"); exit(1) }
        let end = measured.first(where: { $0.along > 0.99 })?.time ?? .nan
        print(String(format: "started changing %.3f s after the set, %.3f s from 1%% to 99%%", start, end - start))
        func apart(_ begin: Double) -> (largest: Double, rms: Double) {
            let errors = measured.map { $0.along - easeOut(($0.time - begin) / 2) }
            return (errors.map(abs).max() ?? 0, (errors.reduce(0) { $0 + $1 * $1 } / Double(max(errors.count, 1))).squareRoot())
        }
        let best = stride(from: max(start - 0.2, 0), through: start + 0.1, by: 0.001).min { apart($0).rms < apart($1).rms } ?? start
        // Durations other than 2 s, from the best start, to see that 2 fits best
        func apart(_ begin: Double, duration: Double) -> Double {
            let errors = measured.map { $0.along - easeOut(($0.time - begin) / duration) }
            return (errors.reduce(0) { $0 + $1 * $1 } / Double(max(errors.count, 1))).squareRoot()
        }
        let bestDuration = stride(from: 1.0, through: 3.0, by: 0.01).min { apart(best, duration: $0) < apart(best, duration: $1) } ?? 2
        let (largest, rms) = apart(best)
        print(String(format: "against the agent's fade (2 s, easing out) from %.3f s: %.3f apart at most, %.3f RMS; the duration that fits best from there: %.2f s", best, largest, rms, bestDuration))
        var lastPrinted = -1
        for (time, along) in measured where time >= best {
            let tenth = Int((time - best) * 10)
            if tenth != lastPrinted, time - best <= 2.3 {
                lastPrinted = tenth
                print(String(format: "  %.3f s  %.3f along, the agent's fade %.3f", time - best, along, easeOut((time - best) / 2)))
            }
        }
        exit(0)
    }
}
dispatchMain()
