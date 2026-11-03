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
    /// The items drawn in the menu bar, from left to right
    let menuBarItems: [(name: String, frame: CGRect)]

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
    /// wallpaper-light.png and menubar-light.png, and the same for dark
    func write(to url: URL) {
        Self.write(image, to: url)
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
    private var systemItems: [NSStatusItem] = []
    private var safelightItem: NSStatusItem?
    private var done: ((Desktop) -> Void)?

    /// The desktop as it is in Dark or not, with the wallpaper's picture for Dark or not
    init(screen: NSScreen, isDark: Bool, wallpaperIsDark: Bool, wallpaper: URL) {
        self.screen = screen
        self.isDark = isDark
        self.wallpaperIsDark = wallpaperIsDark
        self.wallpaper = wallpaper
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
        var drawn: [(name: String, image: MenuBarImage)] = []
        for isDark in [false, true] {
            var images: [MenuBarImage] = []
            for (item, (name, (frame, place))) in zip(items, zip(names, zip(frames, places))) {
                guard let image = Self.menuBarImage(of: item, movedBy: CGVector(dx: place.minX - frame.minX, dy: place.minY - frame.minY), isDark: isDark) else {
                    fail("Couldn't draw \(name)'s item in the menu bar")
                }
                images.append(image)
                if isDark == self.isDark { drawn.append((name, image)) }
            }
            guard let safelight = images.last, let highlight = Self.menuBarHighlight(around: CGRect(x: right, y: barOnScreen.minY, width: frames[frames.count - 1].width, height: bar.height),
                                                                                     isDark: isDark) else {
                fail("Couldn't draw the menu bar")
            }
            menuBars[isDark] = images.dropLast() + [highlight, safelight]
        }
        for item in systemItems { NSStatusBar.system.removeStatusItem(item) }
        systemItems = []
        safelightItem?.isVisible = false

        guard let safelight = drawn.last, let menuBar = menuBars[isDark] else { fail("Couldn't draw the menu bar") }
        let thickness = NSStatusBar.system.thickness
        // In points from the display's top left: the bottom of the box the icon is centred in
        let tip = CGPoint(x: safelight.image.frame.midX - screen.frame.minX, y: bar.height - (bar.height - thickness) / 2)
        let image = drawDesktop(wallpaperIsDark: wallpaperIsDark, menuBar: menuBar)
        var layers: [Bool: (wallpaper: CGImage, menuBar: CGImage)] = [:]
        for isDark in [false, true] {
            layers[isDark] = (drawDesktop(wallpaperIsDark: isDark, menuBar: []), drawDesktop(wallpaperIsDark: nil, menuBar: menuBars[isDark] ?? []))
        }
        let placed = drawn.reversed().map { ($0.name, CGRect(x: $0.image.frame.minX - screen.frame.minX, y: screen.frame.maxY - $0.image.frame.maxY,
                                                          width: $0.image.frame.width, height: $0.image.frame.height)) }
        guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { fail("The Retina display has no number") }
        let draw = { [self] (wallpaperIsDark: Bool, menuBarIsDark: Bool) in drawDesktop(wallpaperIsDark: wallpaperIsDark, menuBar: menuBars[menuBarIsDark] ?? []) }
        done?(Desktop(image: image, layers: layers, drawn: draw, size: screen.frame.size, scale: screen.backingScaleFactor, displayID: id, arrowTip: tip, menuBarItems: placed))
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
            guard let source = CGImageSourceCreateWithURL(wallpaper as CFURL, nil),
                  let picture = WallpaperManager.picture(in: source, at: WallpaperManager.index(in: source, isDark: wallpaperIsDark)) else {
                fail("Couldn't read the wallpaper \(wallpaper.path)")
            }
            // Fill Screen: scaled to cover the display, in the middle
            let fill = max(CGFloat(width) / CGFloat(picture.width), CGFloat(height) / CGFloat(picture.height))
            let size = CGSize(width: CGFloat(picture.width) * fill, height: CGFloat(picture.height) * fill)
            context.interpolationQuality = .high
            context.draw(picture, in: CGRect(x: (CGFloat(width) - size.width) / 2, y: (CGFloat(height) - size.height) / 2, width: size.width, height: size.height))
        }
        for item in menuBar {
            context.draw(item.image, in: CGRect(x: (item.frame.minX - screen.frame.minX) * scale, y: (item.frame.minY - screen.frame.minY) * scale,
                                                width: item.frame.width * scale, height: item.frame.height * scale))
        }
        guard let image = context.makeImage() else { fail("Couldn't draw the desktop") }
        return image
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
