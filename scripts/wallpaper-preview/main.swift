import Cocoa
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

// Picks wallpapers for Light, as the Wallpaper window's tiles do, and logs each picture the appearance's
// picture shows meanwhile, writing each to the folder given as a PNG. scripts/wallpaper-preview.sh
// builds this together with a copy of Safelight.swift whose desktop is `fakeDesktop`, and
// scripts/screenshots/NoSystemChanges.swift.
//
//   <folder> list                   lists what can be picked
//   <folder> <id>[@dark|@fit] ...   picks each, one after the other, after a colour to start from
//   <folder> --frames[=dark] <id> ...  the same, also filming the Wallpaper window's Light preview
//                                   (`DesktopPreview`) in a window of its own, frame by frame, in
//                                   Light or Dark, and logging how far each frame is from the picture
//                                   before to the next, against WallpaperAgent's own fade

setlinebuf(stdout)

/// The desktop the copy of Safelight.swift reads and puts its wallpapers on, for every display
var fakeDesktop: URL? = nil
/// Every wallpaper put on it, in turn
var fakeSets: [URL] = []

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
var picks = Array(CommandLine.arguments.dropFirst(2))
/// Whether to film the preview, and in which appearance
var filmAppearance: NSAppearance.Name?
if let first = picks.first, first.hasPrefix("--frames") {
    filmAppearance = first == "--frames=dark" ? .darkAqua : .aqua
    picks.removeFirst()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// So App Nap doesn't hold back the timer that watches the picture
let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Timing the wallpaper's picture")

let manager = WallpaperManager.shared
let items = WallpaperLibrary.shared.sections.flatMap { $0.items + ($0.row ?? []) }

if picks == ["list"] {
    // Once each, though a wallpaper can be in more than one section
    var listed: Set<String> = []
    for item in items {
        let kind: String
        var isOnMac = true
        switch item.light {
        case .file:
            kind = "picture"
        case .download(_, let file):
            kind = "download"
            isOnMac = FileManager.default.isReadableFile(atPath: file.path)
        case .aerial(let id, _):
            kind = "aerial"
            isOnMac = FileManager.default.isReadableFile(atPath: WallpaperLibrary.downloadedVideo(ofAerial: id).path) || WallpaperLibrary.shippedVideo(ofAerial: id) != nil
        case .color:
            kind = "colour"
        case .drawn:
            kind = "drawn"
        case .asset:
            kind = "photo"
        }
        let line = [item.id, item.name, kind, isOnMac ? "on the Mac" : "fetched", item.badge == .dynamic ? "Light and Dark" : nil, item.isPicture ? "can be placed" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        if listed.insert(line).inserted {
            print(line)
        }
    }
    exit(0)
}

func save(_ image: CGImage, named name: String) {
    let file = folder.appendingPathComponent(name).appendingPathExtension("png")
    guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

/// A picture's pixels as the Wallpaper window's 160 by 100 pt preview fills it at 2x, in sRGB
func filled(_ image: CGImage) -> [UInt8] {
    let width = 320, height = 200
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
          let data = context.data else { return [] }
    let scale = max(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
    let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: (CGFloat(width) - size.width) / 2, y: (CGFloat(height) - size.height) / 2, width: size.width, height: size.height))
    return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
}

/// How far apart two pictures are as the preview fills them: the mean and largest difference of their
/// channels, in levels
func difference(_ a: CGImage, _ b: CGImage) -> (mean: Double, largest: Int) {
    let a = filled(a), b = filled(b)
    var total = 0, largest = 0, count = 0
    for index in a.indices where index % 4 != 3 {
        let difference = abs(Int(a[index]) - Int(b[index]))
        total += difference
        largest = max(largest, difference)
        count += 1
    }
    return (Double(total) / Double(max(count, 1)), largest)
}

/// What the appearance's picture shows in Light
func lightPicture() -> CGImage? {
    if case .picture(let image)? = manager.thumbnails?.light { return image }
    return nil
}

/// Calls `pick`, then logs each picture Light's shows, every 5 ms, until a second and a half after the
/// wallpaper is on the desktop, so its own pictures have been read
func trace(_ label: String, pick: () -> Void, then next: @escaping () -> Void) {
    let start = Date()
    let setsBefore = fakeSets.count
    var last = lightPicture()
    var shown: [CGImage] = []
    var setAt: Double?
    /// When the first new picture showed, and when the last did
    var firstShown: Double?, lastShown: Double?
    film?.start()
    let filmStart = CACurrentMediaTime()
    pick()
    let placement = manager.options(isDark: false).placement.map { ", \($0.kind)" } ?? ""
    print("\(label): choice \(manager.choice(isDark: false) ?? "none")\(placement)")
    Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { timer in
        let time = Date().timeIntervalSince(start)
        if setAt == nil, fakeSets.count > setsBefore {
            setAt = time
            print(String(format: "  %.3f s  wallpaper on the desktop", time))
        }
        let now = lightPicture()
        if let now, now !== last {
            shown.append(now)
            save(now, named: "\(label) \(shown.count)")
            print(String(format: "  %.3f s  picture %d, %d by %d", time, shown.count, now.width, now.height))
            firstShown = firstShown ?? CACurrentMediaTime()
            lastShown = CACurrentMediaTime()
        }
        last = now
        // A picture that's fetched can take a while; while filming, until each fade is over
        guard setAt.map({ time > $0 + 1.5 }) ?? (time > 120) else { return }
        if film != nil, let lastShown, CACurrentMediaTime() < lastShown + 2.5 { return }
        timer.invalidate()
        if setAt == nil {
            print("  not on the desktop after 120 s")
        }
        for index in shown.indices.dropFirst() {
            let (mean, largest) = difference(shown[index - 1], shown[index])
            print(String(format: "  picture %d to %d: %.2f levels apart on average, %d at most", index, index + 1, mean, largest))
        }
        if let film {
            analyse(film.stop(), from: firstShown ?? filmStart, label: label)
        }
        next()
    }
}


// MARK: Filming the preview

/// The Wallpaper window's Light preview as `WallpaperGallery.preview` draws it: what the desktop shows,
/// changing as it does (`DesktopPreview`), or while Safelight can't tell, an empty frame
struct FilmedPreview: View {
    @ObservedObject var wallpaper = WallpaperManager.shared
    static let size = CGSize(width: 160, height: 100)

    var body: some View {
        ZStack {
            if let picture = wallpaper.thumbnails?.light {
                DesktopPreview(thumbnail: picture, size: Self.size)
            } else {
                Rectangle()
                    .fill(.quaternary)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
let createImage = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"), to: CreateImage.self)

/// Films a window of its own, in the bottom left corner of the main display, in front without taking
/// the focus, as fast as the window server gives pictures, on a thread of its own
final class Film: @unchecked Sendable {
    let window: NSWindow
    private let lock = NSLock()
    private var captures: [(time: Double, image: CGImage)] = []
    private var isFilming = false

    init(appearance: NSAppearance.Name) {
        app.appearance = NSAppearance(named: appearance)
        window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 8, y: 8), size: FilmedPreview.size), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: FilmedPreview())
        window.orderFrontRegardless()
    }

    func start() {
        lock.withLock { captures = []; isFilming = true }
        let number = CGWindowID(window.windowNumber)
        Thread { [self] in
            while lock.withLock({ isFilming }) {
                if let image = createImage(.null, 8, number, 1)?.takeRetainedValue() {
                    let time = CACurrentMediaTime()
                    lock.withLock { captures.append((time, image)) }
                }
            }
        }.start()
    }

    func stop() -> [(time: Double, image: CGImage)] {
        lock.withLock { isFilming = false; return captures }
    }
}

let film = filmAppearance.map(Film.init(appearance:))

/// How far CAMediaTimingFunction(name: .easeOut), the cubic Bézier (0, 0) (0.58, 1), has gone at `x`
func easeOut(_ x: Double) -> Double {
    let x = min(max(x, 0), 1)
    let (x1, y1, x2, y2) = (0.0, 0.0, 0.58, 1.0)
    func bezier(_ t: Double, _ a: Double, _ b: Double) -> Double { 3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t }
    var low = 0.0, high = 1.0
    for _ in 0..<60 {
        let middle = (low + high) / 2
        if bezier(middle, x1, x2) < x { low = middle } else { high = middle }
    }
    return bezier((low + high) / 2, y1, y2)
}

/// Each capture's pixels, as 8-bit RGBA in its own colour space, where the window server blends them
func pixels(_ image: CGImage) -> [UInt8] {
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    data.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return data
}

/// Logs the frames filmed from `start` (the first new picture's time) on: for each that differs from the
/// one before, its time and how far it is from the first frame to the last, measured along that change,
/// as a fade blends the two, next to how far WallpaperAgent's fade is then; and saves a frame every
/// quarter of a second
func analyse(_ captures: [(time: Double, image: CGImage)], from start: Double, label: String) {
    var frames: [(time: Double, pixels: [UInt8], image: CGImage)] = []
    for capture in captures {
        let p = pixels(capture.image)
        if frames.last?.pixels != p { frames.append((capture.time, p, capture.image)) }
    }
    guard let from = frames.last(where: { $0.time < start }) ?? frames.first, let to = frames.last else { return }
    let change = zip(to.pixels, from.pixels).map { Double($0) - Double($1) }
    let length = change.reduce(0) { $0 + $1 * $1 }
    print("  filmed: \(captures.count) captures, \(frames.count) different, \(to.image.width) by \(to.image.height), \(Int(length.squareRoot())) levels of change")
    var measured: [(time: Double, along: Double)] = []
    var lastSaved = -1, lastPrinted = -1
    for frame in frames where frame.time >= start {
        let along = zip(zip(frame.pixels, from.pixels), change).reduce(0.0) { $0 + (Double($1.0.0) - Double($1.0.1)) * $1.1 } / max(length, 1)
        let time = frame.time - start
        measured.append((time, along))
        let tenth = Int(time * 10)
        if tenth != lastPrinted, time <= 2.5 {
            lastPrinted = tenth
            print(String(format: "  %.3f s  %.3f along, the agent's fade %.3f", time, along, easeOut(time / 2)))
        }
        let quarter = Int(time / 0.25)
        if quarter != lastSaved, quarter <= 9 {
            lastSaved = quarter
            save(frame.image, named: "\(label) frame \(String(format: "%.2f", time))")
        }
    }
    /// How far the frames are from the agent's fade starting `shift` seconds after the first new picture
    func apart(_ shift: Double) -> (largest: Double, rms: Double) {
        let errors = measured.map { $0.along - easeOut(($0.time - shift) / 2) }
        return (errors.map(abs).max() ?? 0, (errors.reduce(0) { $0 + $1 * $1 } / Double(max(errors.count, 1))).squareRoot())
    }
    guard !measured.isEmpty else { return }
    let (largest, rms) = apart(0)
    let best = stride(from: -0.1, through: 0.1, by: 0.001).min { apart($0).rms < apart($1).rms } ?? 0
    let (bestLargest, bestRMS) = apart(best)
    print(String(format: "  against the agent's fade from the first new picture: %.3f apart at most, %.3f RMS; starting %+.0f ms from it fits best: %.3f at most, %.3f RMS", largest, rms, best * 1000, bestLargest, bestRMS))
}

var steps: [() -> Void] = []

/// Takes the next step half a second after the last, or quits after the last
func takeNextStep() {
    guard !steps.isEmpty else { exit(0) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: steps.removeFirst())
}

steps.append {
    trace("start colour", pick: { manager.setColor(NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1), isDark: false) }, then: takeNextStep)
}
for pick in picks {
    let parts = pick.split(separator: "@", maxSplits: 1).map(String.init)
    let id = parts[0], option = parts.count > 1 ? parts[1] : nil
    // A wallpaper can be in more than one section, and only some are pictures that can be placed
    let item = (option == "fit" ? items.first { $0.id == id && $0.isPicture } : nil) ?? items.first { $0.id == id }
    guard let item else {
        print("No wallpaper \(id): see the IDs with list")
        exit(1)
    }
    var options: WallpaperManager.PictureOptions?
    switch option {
    case "dark":
        options = WallpaperManager.PictureOptions(appearance: .dark)
    case "fit":
        options = WallpaperManager.PictureOptions(placement: WallpaperManager.Placement(kind: .fit, color: CGColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1)))
    case nil:
        break
    default:
        print("Unknown option @\(option ?? ""): use @dark or @fit")
        exit(1)
    }
    steps.append {
        trace(pick.replacingOccurrences(of: ":", with: " ").replacingOccurrences(of: "/", with: " "), pick: { manager.choose(item, isDark: false, options: options) }, then: takeNextStep)
    }
}
takeNextStep()
app.run()
