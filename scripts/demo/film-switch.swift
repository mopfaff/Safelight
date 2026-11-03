// Films macOS changing the appearance the way Safelight changes it (System Settings' way,
// `AppearanceManager.setDark`), to time what the screen does, for recorder/AppearanceTransition.swift:
// Light to Dark, then a few seconds later back to Light. It CHANGES THE REAL SCREEN, so ask the user
// first. scripts/demo/check.py switch builds it, runs it and reads what it writes.
//
// While it runs, as often as it can, on the Retina display (each picture taken costs 11 ms or more, 50
// during the change), it measures:
// - a square of its own, 40 points, in the display's bottom left corner, in front of every window, in
//   the window background colour, which AppKit redraws in the new appearance under macOS's picture of
//   the screen: what's seen there, the picture and all, gives how much of the picture shows, as
//   1 − |seen − after| / |before − after|. (AquaAppearanceHelper's window holding the picture is in a
//   Space of its own, and the window list gives it no bounds, so it can't be taken alone.)
// - by turns, the wallpaper, the mean colour of a strip of the desktop under every window (what's below
//   the backmost window of the normal level), so the user's windows aren't in it, and the menu bar, the
//   mean colour of its right end, where the clock is, as seen.
// Each with the times it asked for the pictures and got them, on the clock mach_absolute_time keeps, in
// seconds, beside the times it began the transition, set the theme, posted the change and was called
// back. Nothing is written but those numbers.
//
// It runs AppKit's event loop, as an app does, so it answers the change as Safelight does: without it,
// the change's completion never came, and AquaAppearanceHelper gave up waiting after 1 s.
//
//   film-switch <out.json> [--pause SECONDS] [--dry]    --dry films for a moment without changing anything
import Cocoa

setlinebuf(stdout)

func fail(_ message: String) -> Never {
    print("error: \(message)")
    exit(1)
}

func now() -> Double {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    return Double(mach_absolute_time()) * Double(timebase.numer) / Double(timebase.denom) / 1e9
}

guard CommandLine.arguments.count >= 2 else { fail("Usage: film-switch out.json [--pause seconds] [--dry]") }
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let pause = CommandLine.arguments.firstIndex(of: "--pause").flatMap { Double(CommandLine.arguments[$0 + 1]) } ?? 4
let isDry = CommandLine.arguments.contains("--dry")

// SkyLight's appearance theme, as Safelight's AppearanceManager reads and sets it
let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
func function<T>(_ name: String, _ type: T.Type) -> T {
    guard let symbol = dlsym(skyLight, name) ?? dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { fail("There's no \(name)") }
    return unsafeBitCast(symbol, to: type)
}
let getTheme = function("SLSGetAppearanceThemeLegacy", (@convention(c) () -> Int32).self)
let setTheme = function("SLSSetAppearanceThemeNotifying", (@convention(c) (Int32, Bool) -> Void).self)
typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
let createImage = function("CGWindowListCreateImage", CreateImage.self)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
guard getTheme() == 0 else { fail("The Mac is in Dark; this films Light to Dark and back") }
// Put back as it was, whatever happens
signal(SIGINT) { _ in setTheme(0, true); exit(1) }
signal(SIGTERM) { _ in setTheme(0, true); exit(1) }

guard let screen = NSScreen.screens.first(where: { $0.backingScaleFactor >= 2 }) else { fail("There's no Retina display") }
// In Core Graphics' coordinates, which go down from the top of the main display
let top = NSScreen.screens[0].frame.maxY
let display = CGRect(x: screen.frame.minX, y: top - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
let desktopRect = CGRect(x: display.midX - 300, y: display.maxY - 260, width: 600, height: 120)
let menuBarRect = CGRect(x: display.maxX - 160, y: display.minY + 4, width: 140, height: 22)
// The square, and the part of it measured, inside its edge
let squareFrame = NSRect(x: screen.frame.minX + 8, y: screen.frame.minY + 8, width: 40, height: 40)
let squareRect = CGRect(x: squareFrame.minX + 10, y: top - squareFrame.maxY + 10, width: 20, height: 20)
let square = NSWindow(contentRect: squareFrame, styleMask: .borderless, backing: .buffered, defer: false)
square.backgroundColor = .windowBackgroundColor
square.level = .statusBar
square.ignoresMouseEvents = true
square.hasShadow = false

/// The mean of each channel of a picture, 0...1, and of its alpha, drawn in its own colours
func mean(_ image: CGImage?) -> [Double]? {
    guard let image, let space = image.colorSpace?.model == .rgb ? image.colorSpace : CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = context.data else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = data.assumingMemoryBound(to: UInt8.self)
    var sums = [Double](repeating: 0, count: 4)
    for i in 0..<(image.width * image.height) {
        for c in 0..<4 { sums[c] += Double(bytes[i * 4 + c]) }
    }
    return sums.map { $0 / Double(image.width * image.height) / 255 }
}

/// The backmost window of the normal level on screen, everything below which is the desktop
func backmostWindow() -> UInt32? {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.last { ($0[kCGWindowLayer as String] as? Int) == 0 }.flatMap { $0[kCGWindowNumber as String] as? UInt32 }
}

struct Sample: Encodable {
    /// When the pictures were asked for, and when they came
    let time: Double
    let after: Double
    /// What's seen in the square, macOS's picture of the screen and all
    let square: [Double]?
    let desktop: [Double]?
    let menuBar: [Double]?
}

let lock = NSLock()
var samples: [Sample] = []
var filming = true
var showsSquare = false
let below = backmostWindow()
if below == nil { print("No window of the normal level is on screen: the desktop's strip is taken with everything over it") }
let onScreenOnly: UInt32 = 1 << 1, onScreenBelowWindow: UInt32 = 1 << 2

let filmer = Thread {
    var turn = 0
    while lock.withLock({ filming }) {
        let time = now()
        turn += 1
        var seen: [Double]?, desktop: [Double]?, menuBar: [Double]?
        if lock.withLock({ showsSquare }) {
            seen = mean(createImage(squareRect, onScreenOnly, 0, 0)?.takeRetainedValue())
        }
        if turn % 2 == 0 {
            desktop = mean((below.map { createImage(desktopRect, onScreenBelowWindow, $0, 0) } ?? createImage(desktopRect, onScreenOnly, 0, 0))?.takeRetainedValue())
        } else {
            menuBar = mean(createImage(menuBarRect, onScreenOnly, 0, 0)?.takeRetainedValue())
        }
        let after = now()
        lock.withLock { samples.append(Sample(time: time, after: after, square: seen, desktop: desktop, menuBar: menuBar)) }
    }
}
filmer.qualityOfService = .userInteractive
filmer.start()

var calledBack: [String: Double] = [:]

/// Changes the appearance as Safelight does: the transition first, then the theme set without telling
/// anyone, then the change posted, which calls back once every app has redrawn
func change(toDark isDark: Bool) -> [String: Double] {
    var times: [String: Double] = [:]
    times["begin"] = now()
    guard let transitionClass = NSClassFromString("NSGlobalPreferenceTransition") as? NSObject.Type,
          let transition = transitionClass.perform(NSSelectorFromString("transition"))?.takeUnretainedValue() as? NSObject else {
        fail("There's no NSGlobalPreferenceTransition")
    }
    times["begun"] = now()
    setTheme(isDark ? 1 : 0, false)
    times["set"] = now()
    let post = NSSelectorFromString("postChangeNotification:completionHandler:")
    typealias PostChange = @convention(c) (NSObject, Selector, UInt, @escaping @convention(block) () -> Void) -> Void
    let key = isDark ? "toDark" : "toLight"
    unsafeBitCast(transition.method(for: post), to: PostChange.self)(transition, post, 0) {
        let time = now()
        lock.withLock { calledBack[key] = time }
    }
    times["posted"] = now()
    return times
}

/// Runs the steps one after another on the main queue, `seconds` apart, while AppKit's event loop runs
func steps(_ list: [(seconds: Double, step: () -> Void)]) {
    guard let (seconds, step) = list.first else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        step()
        steps(Array(list.dropFirst()))
    }
}

struct Film: Encodable {
    let display: String
    let rects: [String: [Double]]
    let toDark: [String: Double]
    let toLight: [String: Double]
    let samples: [Sample]
}

/// Stops filming, checks the Mac is back in Light, and writes what was filmed
func finish() -> Never {
    lock.withLock { filming = false }
    Thread.sleep(forTimeInterval: 0.1)
    square.orderOut(nil)
    guard getTheme() == 0 else { setTheme(0, true); fail("The Mac didn't go back to Light by itself; it was set back") }

    let film = lock.withLock {
        Film(display: screen.localizedName,
             rects: ["desktop": desktopRect, "menuBar": menuBarRect, "square": squareRect].mapValues { [$0.minX, $0.minY, $0.width, $0.height] },
             toDark: toDark.merging(["calledBack": calledBack["toDark"] ?? .nan]) { $1 },
             toLight: toLight.merging(["calledBack": calledBack["toLight"] ?? .nan]) { $1 },
             samples: samples)
    }
    let encoder = JSONEncoder()
    encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    do {
        try encoder.encode(film).write(to: output)
    } catch {
        fail("Couldn't write \(output.path): \(error)")
    }
    let span = (samples.last?.time ?? 0) - (samples.first?.time ?? 0)
    print("Filmed \(samples.count) samples in \(String(format: "%.1f", span)) s (\(String(format: "%.0f", Double(samples.count) / max(span, 0.001))) a second) into \(output.path)")
    exit(0)
}

print(isDry ? "Filming for 2 s, changing nothing" : "Filming: Light for 1 s, then Dark for \(pause) s, then Light for \(pause) s")
var toDark: [String: Double] = [:], toLight: [String: Double] = [:]
steps([
    (0, { square.orderFrontRegardless(); lock.withLock { showsSquare = true } }),
    (1, { if !isDry { toDark = change(toDark: true) } }),
    (isDry ? 1 : pause, { if !isDry { toLight = change(toDark: false) } }),
    (isDry ? 0 : pause, { finish() }),
])
app.run()
