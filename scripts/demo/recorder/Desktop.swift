import Cocoa

// The desktop a scene with `"desktop": true` shows the popover on: the Retina display as macOS shows it
// with Safelight's popover open, in Display P3 at the display's own size in pixels, for scripts/demo/
// compose.py to put each frame on, and for the popover's glass to show through as it's recorded.
//
// - The wallpaper is the scene's (`settings.wallpaper`, Sonoma unless it says otherwise, which the
//   popover's Wallpaper row shows too), its picture for the scene's appearance as Safelight picks it
//   (`WallpaperManager.index(in:isDark:)`), filling the display as macOS's Fill Screen does: scaled to
//   cover it, in the middle. macOS scales with a filter of its own, which no Core Graphics quality
//   matches exactly (78–81% of pixels within 2 levels of its Fit to Screen, 2026-11-01), so this is
//   Core Graphics' high quality.
// - The menu bar is drawn as scripts/screenshots/main.swift draws it, with the same stand-ins for
//   Wi-Fi, Spotlight, Control Center and the clock: each status item's button draws itself, as the
//   menu bar draws them out of the app where no picture can be taken, and the capsule behind
//   Safelight's icon shows its popover is open. The items are at the right of the menu bar, Safelight's
//   to the left of the stand-ins. The menu bar has no background of its own, as on macOS 27 by default,
//   nor the Apple menu and the active app's menus at its left.
// - The popover hangs from Safelight's icon as the real one does: its window's top at the bottom of the
//   22-point box the icon is drawn in, which the menu bar centres in its own (26 points down a menu bar
//   of 30), and its arrow under the middle of the icon.
//
// - The Mac's other displays, for a scene with "otherDisplays": true, each have their own desktop: the
//   same wallpaper filling it, and the same items in its menu bar, each as far from its right edge as on
//   the popover's display, as macOS shows every status item on every display's menu bar. Its menu bar is
//   one without the active app, which the popover's isn't once it's opened there, and macOS draws that
//   one's items without the capsule (only the active menu bar has the item's own window; the others show
//   a copy of it) and adds their ink to what's under them, at 0.2782 of it, rather than putting it over:
//   measured on 3 November 2026 from captures of a status item on the Studio Display's menu bar while
//   it wasn't the active one, against the item's own picture at twice the size, where it was within 1
//   level everywhere and the same as most pixels. On a display at half the scale, as the Dell is, the copy
//   is made from the item's picture at twice the size, which is taken here at half its size by averaging
//   each 2 by 2 pixels: that's closest of the ways tried (mean 1.2 levels off, but up to 18 at the edges
//   of letters), so the copy's own scaling isn't matched exactly. How far from the right edge the copies
//   are wasn't measured for these items: a copy of an item to the left of a dozen others on this Mac was
//   3.5 points further from the Dell's right edge than the item was from the Studio Display's.
//
// The stand-ins and Safelight's icon are in the menu bar for the moment it takes to draw them, as with
// scripts/screenshots.sh. Nothing else is on screen.

/// The desktop as drawn, and where things are on it, in points from its top left
struct Desktop {
    /// The desktop with the popover's appearance, as the scene opens: its menu bar, and its wallpaper
    /// unless the recorder was told otherwise
    let image: CGImage
    /// For each appearance, Dark or not, the wallpaper's picture alone, filling the display, and the
    /// menu bar alone, over nothing, for a scene whose appearance changes, as macOS fades the wallpaper
    /// over to its other picture by itself, while the menu bar is redrawn under the screen's picture
    let layers: [Bool: (wallpaper: CGImage, menuBar: CGImage)]
    /// The desktop drawn as `image` is, with the wallpaper's picture for Dark or not and the menu bar in
    /// Dark or not, as the window server's pictures of the popover over the desktop are taken over it
    let drawn: (_ wallpaperIsDark: Bool, _ menuBarIsDark: Bool) -> CGImage
    /// The display's size in points, and its pixels to the point
    let size: CGSize
    let scale: CGFloat
    let displayID: CGDirectDisplayID
    /// The middle of Safelight's icon in the menu bar, at the bottom of the box it's drawn in, where the
    /// popover's arrow points
    let arrowTip: CGPoint
    /// Each item's place in the menu bar, from left to right
    let menuBarItems: [(name: String, frame: CGRect)]
    /// Its size in millimetres, as it tells macOS
    let millimetres: CGSize
    /// The other displays, drawn as their desktops show, if they were asked for
    let others: [OtherDesktop]

    /// Another display's desktop: where it is as the displays are arranged, in points from the top left of
    /// the popover's display, its size in millimetres, and its pixels to the point
    struct OtherDesktop {
        let image: CGImage
        let displayID: CGDirectDisplayID
        let name: String
        let frame: CGRect
        let millimetres: CGSize
        let scale: CGFloat
    }

    /// How much of a status item's ink a menu bar without the active app adds to what's under it
    static let inactiveMenuBarInk: CGFloat = 0.2782

    /// Where the clock's last letter ends, in points from the right of the display. Measured on the Studio
    /// Display's menu bar on 3 November 2026, which had the microphone's orange dot to the right of the
    /// clock: so it's where the clock would be with something recording, a little further left than
    /// without.
    static let clockEndFromRight: CGFloat = 24

    /// The room left round the popover's window on the canvas the recorder draws: for its glass to sample
    /// the desktop beyond its edges, as the window server's does. None above, where the menu bar is,
    /// and which a window behind the popover can't be put over for -check.
    static let canvasMargin: CGFloat = 40

    /// The popover's window on the desktop, on whole points, `arrowTip` being where its arrow's tip is in
    /// the window, from its top left
    func popover(size window: CGSize, arrowTip tip: CGPoint) -> CGRect {
        CGRect(x: (arrowTip.x - tip.x).rounded(), y: (arrowTip.y - tip.y).rounded(), width: window.width, height: window.height)
    }

    /// The part of the desktop around the popover's window the recorder draws, its window's top left on
    /// it, and the desktop there, for its glass to show
    func canvas(around popover: CGRect) -> (frame: CGRect, popover: CGPoint, backdrop: CGImage) {
        let frame = CGRect(x: popover.minX - Self.canvasMargin, y: popover.minY,
                           width: popover.width + 2 * Self.canvasMargin, height: popover.height + Self.canvasMargin)
            .intersection(CGRect(origin: .zero, size: size))
        let pixels = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
        guard let backdrop = image.cropping(to: pixels) else { fail("Couldn't cut the popover's surroundings out of the desktop") }
        return (frame, CGPoint(x: popover.minX - frame.minX, y: popover.minY - frame.minY), backdrop)
    }

    /// The part of each of `layers` the recorder draws for the canvas `frame`
    func canvasLayers(_ frame: CGRect) -> [Bool: (wallpaper: CGImage, menuBar: CGImage)] {
        let pixels = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
        return layers.mapValues { layers in
            guard let wallpaper = layers.wallpaper.cropping(to: pixels), let menuBar = layers.menuBar.cropping(to: pixels) else {
                fail("Couldn't cut the popover's surroundings out of the desktop")
            }
            return (wallpaper, menuBar)
        }
    }

    /// Writes the part of the desktop round the popover, `canvas`, for each wallpaper picture and menu bar,
    /// drawn as the window server's pictures of the popover are taken over it, into `folder`, as
    /// wallpaper-light-menubar-dark.png and so on, for scripts/demo/compose.py to find those pictures by
    func writeBackdrops(around canvas: CGRect, into folder: URL) {
        let pixels = CGRect(x: canvas.minX * scale, y: canvas.minY * scale, width: canvas.width * scale, height: canvas.height * scale)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for wallpaperIsDark in [false, true] {
            for menuBarIsDark in [false, true] {
                guard let backdrop = drawn(wallpaperIsDark, menuBarIsDark).cropping(to: pixels) else { fail("Couldn't cut the popover's surroundings out of the desktop") }
                Self.write(backdrop, to: folder.appendingPathComponent("wallpaper-\(wallpaperIsDark ? "dark" : "light")-menubar-\(menuBarIsDark ? "dark" : "light").png"))
            }
        }
    }

    /// Writes the desktop as a PNG, in Display P3, and its layers beside it, named after the appearance:
    /// wallpaper-light.png and menubar-light.png, and the same for dark, and each other display's beside
    /// it, desktop-<its number>.png
    func write(to url: URL) {
        Self.write(image, to: url)
        for other in others {
            Self.write(other.image, to: url.deletingLastPathComponent().appendingPathComponent("desktop-\(other.displayID).png"))
        }
        for (isDark, layers) in layers {
            let folder = url.deletingLastPathComponent()
            Self.write(layers.wallpaper, to: folder.appendingPathComponent("wallpaper-\(isDark ? "dark" : "light").png"))
            Self.write(layers.menuBar, to: folder.appendingPathComponent("menubar-\(isDark ? "dark" : "light").png"))
        }
    }

    private static func write(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { fail("Couldn't write \(url.path)") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { fail("Couldn't write \(url.path)") }
    }
}

/// Draws the desktop: puts the stand-ins in the menu bar beside Safelight's icon, waits for the menu bar
/// to lay them out, has their buttons draw themselves, and takes them out again
final class DesktopMaker {
    private let screen: NSScreen
    private let isDark: Bool
    private let wallpaperIsDark: Bool
    private let wallpaper: URL
    private let otherScreens: [NSScreen]
    private var systemItems: [NSStatusItem] = []
    private var safelightItem: NSStatusItem?
    private var done: ((Desktop) -> Void)?

    /// The desktop as it is in Dark or not, with the wallpaper's picture for Dark or not, and the same on
    /// each of `otherScreens`
    init(screen: NSScreen, isDark: Bool, wallpaperIsDark: Bool, wallpaper: URL, otherScreens: [NSScreen] = []) {
        self.screen = screen
        self.isDark = isDark
        self.wallpaperIsDark = wallpaperIsDark
        self.wallpaper = wallpaper
        self.otherScreens = otherScreens
    }

    /// The stand-ins, made before Safelight opens, as each new item goes to the left of the ones before
    func addSystemItems() {
        systemItems = Self.makeSystemItems()
    }

    /// Draws the desktop once the menu bar has laid out the stand-ins and `safelightItem`, then takes
    /// them out of it
    func make(with safelightItem: NSStatusItem, then done: @escaping (Desktop) -> Void) {
        self.safelightItem = safelightItem
        self.done = done
        drawOnceInMenuBar()
    }

    /// As scripts/screenshots/main.swift waits: until the menu bar has given each item its size and stopped
    /// moving them into place, as one caught on its way would be drawn out of line
    private func drawOnceInMenuBar(lastFrames: [CGRect] = [], tries: Int = 100) {
        let items = systemItems + [safelightItem].compactMap { $0 }
        let frames = items.compactMap { $0.button?.window?.frame }
        guard frames.count == items.count, frames == lastFrames, let bar = frames.last,
              let menuBar = NSScreen.screens.first(where: { $0.frame.maxY == bar.maxY && $0.frame.minX <= bar.minX && bar.maxX <= $0.frame.maxX })?.frame,
              frames.allSatisfy({ $0.maxY == menuBar.maxY && menuBar.minX <= $0.minX && $0.maxX <= menuBar.maxX }) else {
            guard tries > 0 else { fail("The menu bar didn't lay out the stand-ins and Safelight's icon") }
            return DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.drawOnceInMenuBar(lastFrames: frames, tries: tries - 1) }
        }

        // From the right of the Retina display's menu bar, the clock's last letter where the real one's
        // is, leftwards, side by side on whole points; Safelight's the leftmost
        let barOnScreen = CGRect(x: screen.frame.minX, y: screen.frame.maxY - bar.height, width: screen.frame.width, height: bar.height)
        let trial = CGVector(dx: barOnScreen.maxX - frames[0].maxX, dy: barOnScreen.minY - frames[0].minY)
        guard let clock = Self.menuBarImage(of: items[0], movedBy: trial, isDark: isDark), let clockInk = Self.inkRight(of: clock.image) else {
            fail("Couldn't draw the clock's stand-in")
        }
        let inkFromLeft = clock.frame.minX - (frames[0].minX + trial.dx) + clockInk / screen.backingScaleFactor
        var right = (barOnScreen.maxX - Desktop.clockEndFromRight - inkFromLeft + frames[0].width).rounded()
        let names = ["Clock", "Control Center", "Spotlight", "Wi-Fi", "Safelight"]
        var places: [CGRect] = []
        for frame in frames {
            places.append(CGRect(x: right - frame.width, y: barOnScreen.minY, width: frame.width, height: frame.height))
            right = places[places.count - 1].minX
        }
        // Each item drawn in Light and in Dark, the capsule behind Safelight's icon, the others as they are
        var menuBars: [Bool: [MenuBarImage]] = [:]
        var itemsAlone: [Bool: [MenuBarImage]] = [:]
        for isDark in [false, true] {
            var images: [MenuBarImage] = []
            for (item, (name, (frame, place))) in zip(items, zip(names, zip(frames, places))) {
                guard let image = Self.menuBarImage(of: item, movedBy: CGVector(dx: place.minX - frame.minX, dy: place.minY - frame.minY), isDark: isDark) else {
                    fail("Couldn't draw \(name)'s item in the menu bar")
                }
                images.append(image)
            }
            guard let safelight = images.last, let highlight = Self.menuBarHighlight(around: CGRect(x: right, y: barOnScreen.minY, width: frames[frames.count - 1].width, height: bar.height),
                                                                                     isDark: isDark) else {
                fail("Couldn't draw the menu bar")
            }
            menuBars[isDark] = images.dropLast() + [highlight, safelight]
            itemsAlone[isDark] = images
        }
        for item in systemItems { NSStatusBar.system.removeStatusItem(item) }
        systemItems = []
        safelightItem?.isVisible = false

        guard let safelight = places.last, let menuBar = menuBars[isDark] else { fail("Couldn't draw the menu bar") }
        let thickness = NSStatusBar.system.thickness
        // In points from the display's top left: the bottom of the box the icon is centred in, under the
        // middle of its place in the menu bar. macOS lays the items out in the active display's menu bar,
        // and gives a button half a point more on a Retina display than on the Dell, while each item's
        // place in the menu bar is the same on both, so the shot doesn't depend on which one that is.
        let tip = CGPoint(x: safelight.midX - screen.frame.minX, y: bar.height - (bar.height - thickness) / 2)
        let image = drawDesktop(wallpaperIsDark: wallpaperIsDark, menuBar: menuBar)
        var layers: [Bool: (wallpaper: CGImage, menuBar: CGImage)] = [:]
        for isDark in [false, true] {
            layers[isDark] = (drawDesktop(wallpaperIsDark: isDark, menuBar: []), drawDesktop(wallpaperIsDark: nil, menuBar: menuBars[isDark] ?? []))
        }
        let placed = zip(names, places).reversed().map { ($0, CGRect(x: $1.minX - screen.frame.minX, y: screen.frame.maxY - $1.maxY, width: $1.width, height: $1.height)) }
        guard let id = Self.number(of: screen) else { fail("The Retina display has no number") }
        let draw = { [self] (wallpaperIsDark: Bool, menuBarIsDark: Bool) in drawDesktop(wallpaperIsDark: wallpaperIsDark, menuBar: menuBars[menuBarIsDark] ?? []) }
        let others = otherScreens.map { other in
            guard let number = Self.number(of: other) else { fail("A display has no number") }
            return Desktop.OtherDesktop(image: drawDesktop(on: other, wallpaperIsDark: wallpaperIsDark, inactiveMenuBar: itemsAlone[isDark] ?? []), displayID: number,
                                        name: other.localizedName,
                                        frame: CGRect(x: other.frame.minX - screen.frame.minX, y: screen.frame.maxY - other.frame.maxY, width: other.frame.width, height: other.frame.height),
                                        millimetres: CGDisplayScreenSize(number), scale: other.backingScaleFactor)
        }
        done?(Desktop(image: image, layers: layers, drawn: draw, size: screen.frame.size, scale: screen.backingScaleFactor, displayID: id, arrowTip: tip, menuBarItems: placed,
                      millimetres: CGDisplayScreenSize(id), others: others))
    }

    private static func number(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Another display's desktop: the wallpaper's picture filling it, and the items in its menu bar as the
    /// menu bar of a display without the active app shows them, from `items`, drawn at twice the size for
    /// the popover's display, each as far from the right edge of its menu bar as there, and their ink added
    /// to the wallpaper at `Desktop.inactiveMenuBarInk`
    private func drawDesktop(on other: NSScreen, wallpaperIsDark: Bool, inactiveMenuBar items: [MenuBarImage]) -> CGImage {
        let scale = other.backingScaleFactor
        let width = Int(other.frame.width * scale), height = Int(other.frame.height * scale)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            fail("Couldn't make a picture of \(other.localizedName)'s desktop")
        }
        drawWallpaper(wallpaperIsDark, in: context, width: width, height: height)
        context.setBlendMode(.plusLighter)
        context.setAlpha(Desktop.inactiveMenuBarInk)
        for item in items {
            guard let image = Self.scaled(item.image, by: scale / screen.backingScaleFactor) else { fail("Couldn't draw \(other.localizedName)'s menu bar") }
            // As far from the top right of the display as on the popover's, on its whole pixels
            let x = ((item.frame.minX - screen.frame.maxX + other.frame.maxX - other.frame.minX) * scale).rounded()
            let y = ((item.frame.minY - screen.frame.maxY + other.frame.maxY - other.frame.minY) * scale).rounded()
            context.draw(image, in: CGRect(x: x, y: y, width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        guard let image = context.makeImage() else { fail("Couldn't draw \(other.localizedName)'s desktop") }
        return image
    }

    /// A picture at `factor` of its size, 1 or ½, each pixel at half the size the average of the 2 by 2
    /// it's made from, premultiplied, as they are
    private static func scaled(_ image: CGImage, by factor: CGFloat) -> CGImage? {
        if factor == 1 { return image }
        guard factor == 0.5, image.bitsPerComponent == 8, image.bitsPerPixel == 32, let space = image.colorSpace,
              let data = image.dataProvider?.data as Data? else { return nil }
        let width = image.width / 2, height = image.height / 2
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            for y in 0..<height {
                for x in 0..<width {
                    for channel in 0..<4 {
                        var sum = 0
                        for (dy, dx) in [(0, 0), (0, 1), (1, 0), (1, 1)] {
                            sum += Int(source[(2 * y + dy) * image.bytesPerRow + (2 * x + dx) * 4 + channel])
                        }
                        bytes[(y * width + x) * 4 + channel] = UInt8((sum + 2) / 4)
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                       bitmapInfo: image.bitmapInfo, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The wallpaper's picture for Dark or not filling the display, with the menu bar's items drawn over
    /// it, or with no wallpaper, the items over nothing
    private func drawDesktop(wallpaperIsDark: Bool?, menuBar: [MenuBarImage]) -> CGImage {
        let scale = screen.backingScaleFactor
        let width = Int(screen.frame.width * scale), height = Int(screen.frame.height * scale)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: (wallpaperIsDark == nil ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue) else {
            fail("Couldn't make a picture of the desktop")
        }
        if let wallpaperIsDark {
            drawWallpaper(wallpaperIsDark, in: context, width: width, height: height)
        }
        for item in menuBar {
            context.draw(item.image, in: CGRect(x: (item.frame.minX - screen.frame.minX) * scale, y: (item.frame.minY - screen.frame.minY) * scale,
                                                width: item.frame.width * scale, height: item.frame.height * scale))
        }
        guard let image = context.makeImage() else { fail("Couldn't draw the desktop") }
        return image
    }

    /// The wallpaper's picture for Dark or not, filling a display `width` by `height` pixels
    private func drawWallpaper(_ isDark: Bool, in context: CGContext, width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(wallpaper as CFURL, nil),
              let picture = WallpaperManager.picture(in: source, at: WallpaperManager.index(in: source, isDark: isDark)) else {
            fail("Couldn't read the wallpaper \(wallpaper.path)")
        }
        // Fill Screen: scaled to cover the display, in the middle
        let fill = max(CGFloat(width) / CGFloat(picture.width), CGFloat(height) / CGFloat(picture.height))
        let size = CGSize(width: CGFloat(picture.width) * fill, height: CGFloat(picture.height) * fill)
        context.interpolationQuality = .high
        context.draw(picture, in: CGRect(x: (CGFloat(width) - size.width) / 2, y: (CGFloat(height) - size.height) / 2, width: size.width, height: size.height))
    }

    /// How far from the left a picture's last column with anything drawn in it ends, in pixels
    private static func inkRight(of image: CGImage) -> CGFloat? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        for column in stride(from: image.width - 1, through: 0, by: -1) where (0..<image.height).contains(where: { bytes[($0 * image.width + column) * 4 + 3] > 0 }) {
            return CGFloat(column + 1)
        }
        return nil
    }

    // MARK: As scripts/screenshots/main.swift draws the menu bar

    /// Wi-Fi, Spotlight, Control Center and the clock, as on a new Mac, from right to left. The clock
    /// says 21:00, as FixedTime.swift does, on a day of its own, so the picture is the same every day.
    private static func makeSystemItems() -> [NSStatusItem] {
        let date = DateComponents(calendar: .current, year: 2026, month: 12, day: 21, hour: 21).date ?? Date()
        let dayFormatter = DateFormatter(), timeFormatter = DateFormatter()
        dayFormatter.setLocalizedDateFormatFromTemplate("EEEdMMM")
        timeFormatter.setLocalizedDateFormatFromTemplate("jmm")
        let clock = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        clock.button?.title = dayFormatter.string(from: date) + "  " + timeFormatter.string(from: date)
        return [clock] + ["switch.2", "magnifyingglass", "wifi"].map { symbol in
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            return item
        }
    }

    /// A menu bar item as the menu bar shows it, in Dark or Light, and where on screen, `movedBy` so much.
    /// Its button draws itself, its window moved onto the Retina display while it does.
    private static func menuBarImage(of item: NSStatusItem, movedBy offset: CGVector, isDark: Bool) -> MenuBarImage? {
        guard let button = item.button, let window = button.window else { return nil }
        let bar = window.frame
        window.setFrameOrigin(NSPoint(x: bar.minX + offset.dx, y: bar.minY + offset.dy))
        defer { window.setFrameOrigin(bar.origin) }
        guard window.backingScaleFactor >= 2 else { return nil }
        button.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        // Its button is the height of the old menu bar, which the menu bar centres in its own
        let frame = button.frame.offsetBy(dx: bar.minX + offset.dx, dy: bar.minY + offset.dy + (bar.height - NSStatusBar.system.thickness) / 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(frame.width * 2), pixelsHigh: Int(frame.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = button.bounds.size
        button.cacheDisplay(in: button.bounds, to: rep)
        return rep.cgImage.map { ($0, frame) }
    }

    /// The highlight the menu bar draws behind an item while it's open, around the item's place in the
    /// menu bar: a capsule 4 points wider than the item and 24 high, in the colour of the menu bar's text
    /// at 17%
    private static func menuBarHighlight(around place: CGRect, isDark: Bool) -> MenuBarImage? {
        let size = CGSize(width: place.width + 4, height: 24)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: 2, y: 2)
        context.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: size.height / 2, cornerHeight: size.height / 2, transform: nil))
        context.setFillColor(CGColor(gray: isDark ? 1 : 0, alpha: 0.17))
        context.fillPath()
        let frame = CGRect(x: place.midX - size.width / 2, y: place.midY - size.height / 2, width: size.width, height: size.height)
        return context.makeImage().map { ($0, frame) }
    }
}

/// A menu bar item as the menu bar draws it, and where on screen
typealias MenuBarImage = (image: CGImage, frame: CGRect)
