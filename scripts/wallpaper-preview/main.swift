import Cocoa
import ImageIO
import UniformTypeIdentifiers

// Picks wallpapers for Light, as the Wallpaper window's tiles do, and logs each picture the appearance's
// picture shows meanwhile, writing each to the folder given as a PNG. scripts/wallpaper-preview.sh
// builds this together with a copy of Safelight.swift whose desktop is `fakeDesktop`, and
// scripts/screenshots/NoSystemChanges.swift.
//
//   <folder> list                   lists what can be picked
//   <folder> <id>[@dark|@fit] ...   picks each, one after the other, after a colour to start from

setlinebuf(stdout)

/// The desktop the copy of Safelight.swift reads and puts its wallpapers on, for every display
var fakeDesktop: URL? = nil
/// Every wallpaper put on it, in turn
var fakeSets: [URL] = []

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let picks = Array(CommandLine.arguments.dropFirst(2))

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
        }
        last = now
        // A picture that's fetched can take a while
        guard setAt.map({ time > $0 + 1.5 }) ?? (time > 120) else { return }
        timer.invalidate()
        if setAt == nil {
            print("  not on the desktop after 120 s")
        }
        for index in shown.indices.dropFirst() {
            let (mean, largest) = difference(shown[index - 1], shown[index])
            print(String(format: "  picture %d to %d: %.2f levels apart on average, %d at most", index, index + 1, mean, largest))
        }
        next()
    }
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
