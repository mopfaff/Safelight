import Cocoa
import SwiftUI
import ScreenCaptureKit

// Draws the README's screenshots from Safelight's own views: the popover and the Schedule window, in
// the `-appearance` given (dark or light), each written to `-output` as a PNG. scripts/screenshots.sh
// builds this together with a copy of Safelight.swift, NoSystemChanges.swift and FixedTime.swift, and
// runs it once for each appearance: switched while it runs, the popover keeps parts of the one it had.
//
// Run with `-compare old.png new.png`, it says instead whether two screenshots look the same.

setlinebuf(stdout)

/// A picture drawn into a bitmap in Display P3, whose bytes can be read and changed
func bitmap(of image: CGImage) -> CGContext? {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
          let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return context
}

/// Whether two PNGs are the same size with no pixel more than two levels apart: a window's glass picks
/// up a little of what's behind it, so a screenshot of the same thing can come out a level off here
/// and there.
func looksTheSame(_ path: String, _ otherPath: String) -> Bool {
    func pixels(_ path: String) -> CGContext? {
        CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            .flatMap(bitmap)
    }
    guard let one = pixels(path), let other = pixels(otherPath), one.width == other.width, one.height == other.height,
          let oneBytes = one.data?.assumingMemoryBound(to: UInt8.self),
          let otherBytes = other.data?.assumingMemoryBound(to: UInt8.self) else { return false }
    for row in 0..<one.height {
        for byte in 0..<one.width * 4 where abs(Int(oneBytes[row * one.bytesPerRow + byte]) - Int(otherBytes[row * other.bytesPerRow + byte])) > 2 {
            return false
        }
    }
    return true
}

/// A menu bar item as the menu bar draws it, and where on screen
typealias MenuBarImage = (image: CGImage, frame: CGRect)

final class Screenshots: NSObject, NSApplicationDelegate {
    private let output = URL(fileURLWithPath: UserDefaults.standard.string(forKey: "output") ?? ".")
    private let appearance = UserDefaults.standard.string(forKey: "appearance") ?? "dark"
    /// With `-desktopLight` and `-desktopDark`, the files of the desktop's wallpaper in Light and in Dark
    /// (the Dark picture of one with a picture for each): the pictures are then of the popover and the
    /// Schedule window over the top right corner of a desktop with the appearance's wallpaper, each
    /// `-canvases` size of it in turn ("540x675,1128x678", in points), with the menu bar's items along
    /// its top, rather than of the windows alone. The popover's Wallpaper picker shows the two.
    private let desktopLight = UserDefaults.standard.string(forKey: "desktopLight").map { URL(fileURLWithPath: $0) }
    private let desktopDark = UserDefaults.standard.string(forKey: "desktopDark").map { URL(fileURLWithPath: $0) }
    private var desktop: URL? { appearance == "dark" ? desktopDark : desktopLight }
    private let canvases: [CGSize] = (UserDefaults.standard.string(forKey: "canvases") ?? "").split(separator: ",").compactMap {
        let sides = $0.split(separator: "x").compactMap { Double($0) }
        return sides.count == 2 ? CGSize(width: sides[0], height: sides[1]) : nil
    }
    /// With `-scheduleFile`, a file with the schedule the Schedule window shows instead of the default
    /// one, as the demo's scenes write a schedule (scripts/export-schedule.py writes the one Safelight
    /// has on this Mac). The popover then shows that schedule's settings at 21:00.
    private let scheduleFile = UserDefaults.standard.string(forKey: "scheduleFile").map { URL(fileURLWithPath: $0) }
    private let appDelegate = AppDelegate()
    /// The Retina display the windows are put on, so they're drawn at twice their size
    private let screen = NSScreen.screens.first { $0.backingScaleFactor >= 2 } ?? NSScreen.screens[0]
    /// Stand-ins for the menu bar's own items, to the right of Safelight's icon
    private var systemItems: [NSStatusItem] = []
    /// An invisible window the size of Safelight's icon's place in the menu bar, just under the menu bar
    /// of `screen`, for the popover to open under and the menu bar to be drawn above. The icon itself is
    /// in the menu bar of whichever display is in use.
    private var anchor: NSWindow!
    /// A window behind the popover, which is see-through, so it's over the appearance's window
    /// background colour rather than whatever is on screen there
    private var backdrop: NSWindow!
    private var activity: NSObjectProtocol?
    /// When the app last became active or stopped being active, by `systemUptime`
    private var lastActivationChange: TimeInterval = 0
    /// When a window last became key or stopped being key
    private var lastKeyChange: TimeInterval = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Nothing would stop it changing the Mac if the stand-ins weren't the ones called
        guard ColorFilterManager.shared.read() == nil, AppearanceManager.shared.isDark() == nil,
              GammaManager.shared.getNativeBrightness(of: CGMainDisplayID()) == nil else {
            fail("Safelight's copy reaches the system's settings; NoSystemChanges.swift isn't standing in for them")
        }
        guard screen.backingScaleFactor >= 2 else { fail("There's no Retina display to draw the screenshots at twice their size on") }

        // Timers aren't put off while it runs in the background, and its settings start out as the defaults
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Drawing screenshots")
        removeSettings()
        after(60) { self.fail("Timed out") }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.lastActivationChange = ProcessInfo.processInfo.systemUptime
            }
        }

        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.lastKeyChange = ProcessInfo.processInfo.systemUptime
            }
        }

        // Set before any window is made, as the system's would be
        let isDark = appearance == "dark"
        NSApp.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)

        // The app's own menu bar icon and popover, made after the stand-ins as each new item goes to
        // the left of the ones before
        systemItems = Self.makeSystemItems()
        appDelegate.applicationDidFinishLaunching(notification)

        backdrop = NSWindow(contentRect: NSRect(x: screen.frame.midX - 300, y: screen.visibleFrame.maxY - 700, width: 600, height: 700),
                            styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.backgroundColor = .windowBackgroundColor
        backdrop.colorSpace = .displayP3
        backdrop.ignoresMouseEvents = true
        backdrop.orderFrontRegardless()

        // The evening on the default schedule, with the Schedule off so every control is drawn at its brightest
        let controller = ColorController.shared
        controller.tint = 0
        controller.intensity = 0.90
        controller.isColorFilterOn = true
        controller.brightness = 0.68
        if let scheduleFile {
            // Or on the schedule given, as it has them at the time FixedTime.swift keeps it at
            controller.schedule = keyframes(in: scheduleFile)
            guard let evening = ColorKeyframe.settings(in: controller.schedule, at: Double(FixedTime.hour * 60 + FixedTime.minute)) else {
                fail("\(scheduleFile.path) has no keyframes")
            }
            controller.isColorFilterOn = evening.isColorFilterOn
            if evening.isColorFilterOn {
                controller.tint = evening.tint
                controller.intensity = evening.filterIntensity
            }
            controller.brightness = evening.brightness
        }
        controller.chooseAppearance(isDark: isDark) // which only the Appearance picker shows
        // And macOS's own Light and Dark wallpaper, which only the Wallpaper picker shows: it's only
        // read, as the desktop isn't changed unless a picture is chosen
        var wallpaper = URL(fileURLWithPath: "/System/Library/Desktop Pictures/Sonoma.heic")
        if let desktopLight, let desktopDark {
            // The desktop's own, in one wallpaper as Safelight makes it when a picture is chosen for each
            wallpaper = FileManager.default.temporaryDirectory.appendingPathComponent("Safelight Screenshots wallpaper.heic")
            guard WallpaperManager.makeWallpaper(at: wallpaper, light: (desktopLight, false), dark: (desktopDark, true)) else {
                fail("Couldn't make a wallpaper of \(desktopLight.path) and \(desktopDark.path)")
            }
        }
        WallpaperManager.shared.showPictures(of: wallpaper)
        drawOnceInMenuBar()
    }

    /// A schedule's keyframes from a file that has them as the demo's scenes do: a time ("20:30"), whether
    /// the color filter is on, its intensity and tint, the brightness and the appearance (light or dark)
    private func keyframes(in file: URL) -> [ColorKeyframe] {
        struct Keyframe: Decodable {
            let time: String
            let colorFilter: Bool
            let intensity: Float
            let tint: Float
            let brightness: Float
            let appearance: String
        }
        guard let data = try? Data(contentsOf: file), let keyframes = try? JSONDecoder().decode([Keyframe].self, from: data) else {
            fail("Couldn't read a schedule from \(file.path)")
        }
        return keyframes.enumerated().map { index, keyframe in
            let time = keyframe.time.split(separator: ":").compactMap { Int($0) }
            guard time.count == 2, (0..<24).contains(time[0]), (0..<60).contains(time[1]), ["light", "dark"].contains(keyframe.appearance),
                  let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index)) else {
                fail("A keyframe of \(file.path) needs a time like 20:30 and an appearance of light or dark")
            }
            return ColorKeyframe(id: id, minute: time[0] * 60 + time[1], isColorFilterOn: keyframe.colorFilter, intensity: keyframe.intensity,
                                 tint: keyframe.tint, brightness: keyframe.brightness, isDarkAppearance: keyframe.appearance == "dark")
        }
    }

    /// Draws once the menu bar has made room for the items, which it doesn't straight away, and so has
    /// given each its size, and has stopped moving them into place: one caught on its way would be drawn
    /// out of line. And once the wallpaper's pictures have loaded.
    private func drawOnceInMenuBar(lastFrames: [CGRect] = []) {
        let frames = (systemItems + [appDelegate.statusItem].compactMap { $0 }).compactMap { $0.button?.window?.frame }
        guard WallpaperManager.shared.thumbnails != nil,
              frames.count == systemItems.count + 1, frames == lastFrames, let bar = frames.last,
              let menuBar = NSScreen.screens.first(where: { $0.frame.maxY == bar.maxY && $0.frame.minX <= bar.minX && bar.maxX <= $0.frame.maxX })?.frame,
              frames.allSatisfy({ $0.maxY == menuBar.maxY && menuBar.minX <= $0.minX && $0.maxX <= menuBar.maxX }) else {
            return after(0.1) { self.drawOnceInMenuBar(lastFrames: frames) }
        }
        anchor = NSWindow(contentRect: NSRect(x: screen.frame.midX, y: screen.visibleFrame.maxY - bar.height, width: bar.width, height: bar.height),
                          styleMask: .borderless, backing: .buffered, defer: false)
        anchor.isOpaque = false
        anchor.backgroundColor = .clear
        anchor.ignoresMouseEvents = true
        // The popover hangs from the height of the old menu bar, which the menu bar centres in its own
        let thickness = NSStatusBar.system.thickness
        anchor.contentView?.addSubview(NSView(frame: NSRect(x: 0, y: (bar.height - thickness) / 2, width: bar.width, height: thickness)))
        anchor.orderFrontRegardless()

        // The items as they'd be in that menu bar, Safelight's icon in the anchor's place and the others
        // side by side to its right, with the highlight behind Safelight's icon that shows its popover is
        // open. Not as far apart as they are: macOS puts each item back where it last was among the
        // others, so one that has come into the menu bar since, like Focus's, can be between them.
        var left = anchor.frame.minX
        let offsets = frames.reversed().map { frame in
            defer { left += frame.width }
            return CGVector(dx: left - frame.minX, dy: anchor.frame.minY - bar.minY)
        }.reversed()
        let items = zip(systemItems + [appDelegate.statusItem].compactMap { $0 }, offsets).compactMap {
            Self.menuBarImage(of: $0, movedBy: $1)
        }
        guard items.count == systemItems.count + 1, let highlight = Self.menuBarHighlight(around: anchor.frame) else { fail("Couldn't draw the menu bar") }
        draw(menuBar: items.dropLast() + [highlight] + items.suffix(1))
    }

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

    private func draw(menuBar: [MenuBarImage]) {
        let popover = appDelegate.popover
        let place = anchor.contentView!.subviews[0]
        if desktop != nil {
            guard !canvases.isEmpty else { fail("-desktop needs -canvases, like 540x675,1128x678") }
            return drawOverDesktop(canvases, menuBar: menuBar)
        }
        capture("popover-\(appearance)", overBackdrop: true, menuBar: menuBar, show: {
            // At its full size from the start: opened at the size it's made with, it grows upwards, over
            // the menu bar, once SwiftUI has laid it out
            if let view = popover.contentViewController?.view { popover.contentSize = view.fittingSize }
            popover.show(relativeTo: place.bounds, of: place, preferredEdge: .minY)
            return popover.contentViewController?.view.window
        }, then: {
            popover.close()
            self.backdrop.orderOut(nil)
            self.capture("schedule-\(self.appearance)", show: {
                ScheduleWindow.shared.show()
                let window = NSApp.windows.first { $0.title == SystemStrings.schedule }
                if let window {
                    window.setFrameOrigin(NSPoint(x: self.screen.frame.midX - window.frame.width / 2,
                                                  y: self.screen.visibleFrame.midY - window.frame.height / 2))
                    window.makeFirstResponder(nil) // no time field focused
                }
                return window
            }, then: {
                self.finish()
            })
        })
    }

    /// The popover over each size of desktop in turn, the menu bar's items along its top and the popover
    /// in the middle, as "popover-light-desktop-540x675", and then the Schedule window in the middle of
    /// each it fits in with room to spare, without the menu bar's items. The popover stays open from
    /// one size to the next: opened again after another window, it's drawn as it is when it isn't key.
    private func drawOverDesktop(_ canvases: [CGSize], menuBar: [MenuBarImage], schedule: Bool = false) {
        let popover = appDelegate.popover
        let place = anchor.contentView!.subviews[0]
        guard let canvas = canvases.first else {
            if schedule { return finish() }
            popover.close()
            return drawOverDesktop(self.canvases, menuBar: menuBar, schedule: true)
        }
        let name = "\(appearance)-desktop-\(Int(canvas.width))x\(Int(canvas.height))"
        let next = { self.drawOverDesktop(Array(canvases.dropFirst()), menuBar: menuBar, schedule: schedule) }
        // Its top where the top of the screen would be, the anchor's menu bar being the screen's
        let frame = NSRect(x: (anchor.frame.midX - canvas.width / 2).rounded(), y: anchor.frame.maxY - canvas.height, width: canvas.width, height: canvas.height)
        backdrop.setFrame(frame, display: false)
        backdrop.contentView?.wantsLayer = true
        backdrop.contentView?.layer?.contents = desktopPicture(for: canvas)
        backdrop.contentView?.layer?.contentsGravity = .resize
        backdrop.display()
        guard schedule else {
            return capture("popover-\(name)", overDesktop: true, menuBar: menuBar, show: {
                if !popover.isShown {
                    if let view = popover.contentViewController?.view { popover.contentSize = view.fittingSize }
                    popover.show(relativeTo: place.bounds, of: place, preferredEdge: .minY)
                }
                return popover.contentViewController?.view.window
            }, then: next)
        }
        ScheduleWindow.shared.show()
        guard let window = NSApp.windows.first(where: { $0.title == SystemStrings.schedule }) else { fail("Couldn't open the Schedule window") }
        guard window.frame.width + 100 <= canvas.width, window.frame.height + 100 <= canvas.height else {
            window.orderOut(nil)
            return next()
        }
        capture("schedule-\(name)", overDesktop: true, show: {
            ScheduleWindow.shared.show()
            window.setFrameOrigin(NSPoint(x: (frame.midX - window.frame.width / 2).rounded(), y: (frame.midY - window.frame.height / 2).rounded()))
            window.makeFirstResponder(nil) // no time field focused
            return window
        }, then: {
            window.orderOut(nil)
            next()
        })
    }

    /// The top right corner of the desktop, `canvas` in size, on a display the size of the screen: the
    /// wallpaper's picture filling it as macOS's Fill Screen does, scaled to cover it, in the middle
    private func desktopPicture(for canvas: CGSize) -> CGImage {
        guard let desktop, let source = CGImageSourceCreateWithURL(desktop as CFURL, nil),
              let picture = CGImageSourceCreateImageAtIndex(source, WallpaperManager.index(in: source, isDark: appearance == "dark"), nil),
              let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: nil, width: Int(canvas.width) * 2, height: Int(canvas.height) * 2, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            fail("Couldn't read the wallpaper \(self.desktop?.path ?? "")")
        }
        let (width, height) = (screen.frame.width * 2, screen.frame.height * 2)
        let fill = max(width / CGFloat(picture.width), height / CGFloat(picture.height))
        let size = CGSize(width: CGFloat(picture.width) * fill, height: CGFloat(picture.height) * fill)
        context.interpolationQuality = .high
        // The display's top right corner is the picture's: the context's origin is at its bottom left
        context.draw(picture, in: CGRect(x: CGFloat(context.width) - width + (width - size.width) / 2,
                                         y: CGFloat(context.height) - height + (height - size.height) / 2, width: size.width, height: size.height))
        guard let image = context.makeImage() else { fail("Couldn't draw the desktop") }
        return image
    }

    /// Shows a window, and takes its picture once the app has been active for a moment, again if it
    /// stopped being active meanwhile. Only an active app's controls are drawn in the accent colour,
    /// and not straight away. macOS can take the activation back from an app that had nothing on screen
    /// as it opened, which closes the popover, and another app can take it, so it's shown again then.
    private func capture(_ name: String, overBackdrop: Bool = false, overDesktop: Bool = false, menuBar: [MenuBarImage] = [], tries: Int = 10,
                         show: @escaping () -> NSWindow?, then next: @escaping () -> Void) {
        let window = show()
        // In Display P3 rather than the display's own colours, which change when macOS rewrites its
        // profile, and leave out the colours it can't show, like the deepest blue of the Tint slider
        window?.colorSpace = .displayP3
        NSApp.activate(ignoringOtherApps: true)
        after(1) {
            Task { @MainActor in
                let lastChange = self.lastActivationChange
                // Over a desktop the popover stays open from one picture to the next, and a click elsewhere
                // meanwhile leaves it open but no longer key, its controls grey, though the app is active again
                if overDesktop, let window, !window.isKeyWindow { window.makeKey() }
                if NSApp.isActive, ProcessInfo.processInfo.systemUptime - lastChange > 0.75, let window, window.isVisible,
                   !overDesktop || window.isKeyWindow && ProcessInfo.processInfo.systemUptime - self.lastKeyChange > 0.75 {
                    await self.snapshot(window, as: name, overBackdrop: overBackdrop, overDesktop: overDesktop, menuBar: menuBar)
                    if NSApp.isActive, self.lastActivationChange == lastChange { return next() }
                }
                guard tries > 1 else { self.fail("Safelight Screenshots couldn't stay the active app to draw \(name); run it again without clicking elsewhere") }
                self.capture(name, overBackdrop: overBackdrop, overDesktop: overDesktop, menuBar: menuBar, tries: tries - 1, show: show, then: next)
            }
        }
    }

    /// Writes a window as it is on screen, with its shadow, in Display P3. A picture of a window by
    /// itself has its see-through parts over black, so with `overBackdrop` they're over the windows
    /// behind it (the backdrop) instead. The `menuBar` items are drawn above it, without the menu bar.
    /// With `overDesktop`, the picture is the whole backdrop, the desktop, with the window over it.
    @MainActor
    private func snapshot(_ window: NSWindow, as name: String, overBackdrop: Bool, overDesktop: Bool = false, menuBar: [MenuBarImage]) async {
        // Taken with room for the shadow all round, and trimmed to it afterwards
        let margin: CGFloat = 100
        let frame = window.frame
        let rect = overDesktop ? backdrop.frame : menuBar.reduce(frame.insetBy(dx: -margin, dy: -margin)) { $0.union($1.frame) }.integral
        guard let image = Self.windowImage(window, in: rect, withWindowsBelow: overDesktop),
              let pixels = bitmap(of: image), let bytes = pixels.data?.assumingMemoryBound(to: UInt8.self) else {
            fail("Couldn't take a picture of \(name)")
        }
        guard image.width == Int(rect.width) * 2 else { fail("\(name) wasn't drawn at twice its size; is it on a Retina display?") }
        let (rowOffset, columnOffset) = (Int(rect.maxY - frame.maxY) * 2, Int(frame.minX - rect.minX) * 2)

        if overBackdrop {
            // The window's shape, in the colours it has over the backdrop
            guard let shape = Self.windowImage(window).flatMap(bitmap), let shapeBytes = shape.data?.assumingMemoryBound(to: UInt8.self),
                  let colors = Self.windowImage(window, in: frame, withWindowsBelow: true).flatMap(bitmap),
                  let colorBytes = colors.data?.assumingMemoryBound(to: UInt8.self),
                  shape.width == colors.width, shape.height == colors.height else { fail("Couldn't take a picture of \(name) over the backdrop") }
            for row in 0..<shape.height {
                for column in 0..<shape.width {
                    let alpha = UInt32(shapeBytes[row * shape.bytesPerRow + column * 4 + 3])
                    let color = row * colors.bytesPerRow + column * 4
                    let pixel = (row + rowOffset) * pixels.bytesPerRow + (column + columnOffset) * 4
                    for channel in 0..<4 {
                        let over = channel == 3 ? 255 : UInt32(colorBytes[color + channel])
                        bytes[pixel + channel] = UInt8((over * alpha + UInt32(bytes[pixel + channel]) * (255 - alpha)) / 255)
                    }
                }
            }
        }

        // A colour the display can't show, like the deepest blue of the Tint slider, is on screen as the
        // nearest one it can, which changes with the display's colour profile. So the window's colours
        // far from grey, which a display may not be able to show, are from a picture of it in Display P3
        // instead; the rest, which any display can, as on screen, where its glass and edges are drawn
        // a little differently.
        // Not over a desktop: its wallpaper gives the glass colours far from grey too, and the glass is
        // the part to have as on screen.
        guard let own = overDesktop ? pixels : await Self.p3Image(of: window, over: overBackdrop ? [backdrop] : []).flatMap(bitmap),
              let ownBytes = own.data?.assumingMemoryBound(to: UInt8.self),
              overDesktop || own.width == Int(frame.width) * 2 && own.height == Int(frame.height) * 2 else { fail("Couldn't take a picture of \(name) in Display P3") }
        for row in 0..<(overDesktop ? 0 : own.height) {
            for column in 0..<own.width {
                let color = row * own.bytesPerRow + column * 4
                let pixel = (row + rowOffset) * pixels.bytesPerRow + (column + columnOffset) * 4
                let channels = (0..<3).map { ownBytes[color + $0] }
                // Opaque, with a channel at least a quarter of the way from another
                guard ownBytes[color + 3] == 255, bytes[pixel + 3] == 255, channels.max()! - channels.min()! >= 64 else { continue }
                for channel in 0..<3 {
                    bytes[pixel + channel] = channels[channel]
                }
            }
        }

        for item in menuBar {
            pixels.draw(item.image, in: CGRect(x: (item.frame.minX - rect.minX) * 2, y: (item.frame.minY - rect.minY) * 2,
                                               width: item.frame.width * 2, height: item.frame.height * 2))
        }

        // Down to the shadow's edges
        var (top, left, bottom, right) = (pixels.height, pixels.width, -1, -1)
        for row in 0..<pixels.height {
            for column in 0..<pixels.width where bytes[row * pixels.bytesPerRow + column * 4 + 3] > 0 {
                (top, left, bottom, right) = (min(top, row), min(left, column), max(bottom, row), max(right, column))
            }
        }
        let url = output.appendingPathComponent("\(name).png")
        guard bottom >= 0, let trimmed = pixels.makeImage()?.cropping(to: CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { fail("Couldn't write \(name)") }
        CGImageDestinationAddImage(destination, trimmed, nil)
        guard CGImageDestinationFinalize(destination) else { fail("Couldn't write \(url.path)") }
        print("Wrote \(url.path)")
    }

    /// A menu bar item as the menu bar shows it, in the app's appearance, and where on screen, `movedBy`
    /// so much. The menu bar draws it out of the app, where no picture of it can be taken, so its button
    /// draws itself here. Its window is moved there while it does, onto the Retina display, so it's drawn
    /// the same whichever display's menu bar it's in: on one that isn't Retina, the button lines its icon
    /// up with whole points, half a point from where it is on a Retina display.
    private static func menuBarImage(of item: NSStatusItem, movedBy offset: CGVector) -> MenuBarImage? {
        guard let button = item.button, let window = button.window else { return nil }
        let bar = window.frame
        window.setFrameOrigin(NSPoint(x: bar.minX + offset.dx, y: bar.minY + offset.dy))
        defer { window.setFrameOrigin(bar.origin) }
        guard window.backingScaleFactor >= 2 else { return nil }
        button.appearance = NSApp.appearance
        // Its button is the height of the old menu bar, which the menu bar centres in its own
        let frame = button.frame.offsetBy(dx: bar.minX + offset.dx, dy: bar.minY + offset.dy + (bar.height - NSStatusBar.system.thickness) / 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(frame.width * 2), pixelsHigh: Int(frame.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = button.bounds.size
        button.cacheDisplay(in: button.bounds, to: rep)
        return rep.cgImage.map { ($0, frame) }
    }

    /// The highlight the menu bar draws behind an item while it's open, out of the app as well, around
    /// the item's place in the menu bar. As macOS 27 draws it: a capsule 4 points wider than the item and
    /// 24 high, in the colour of the menu bar's text at 17%.
    private static func menuBarHighlight(around place: CGRect) -> MenuBarImage? {
        let size = CGSize(width: place.width + 4, height: 24)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: 2, y: 2)
        context.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: size.height / 2, cornerHeight: size.height / 2, transform: nil))
        context.setFillColor(CGColor(gray: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 1 : 0, alpha: 0.17))
        context.fillPath()
        let frame = CGRect(x: place.midX - size.width / 2, y: place.midY - size.height / 2, width: size.width, height: size.height)
        return context.makeImage().map { ($0, frame) }
    }

    /// `CGWindowListCreateImage`, which the SDK no longer offers to Swift: the screen's own picture, in
    /// the display's colours, with shadows and glass as on screen. With no `rect`, it's the window
    /// alone, without its shadow; with one, it's that part of the screen with the window and its
    /// shadow, and with `withWindowsBelow`, with the windows behind it as well.
    private static func windowImage(_ window: NSWindow, in rect: CGRect? = nil, withWindowsBelow: Bool = false) -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil } // RTLD_DEFAULT
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        let onScreenBelowWindow: UInt32 = 1 << 2, includingWindow: UInt32 = 1 << 3
        let boundsIgnoreFraming: UInt32 = 1 << 0, bestResolution: UInt32 = 1 << 3
        guard let rect else {
            return createImage(.null, includingWindow, UInt32(window.windowNumber), boundsIgnoreFraming | bestResolution)?.takeRetainedValue()
        }
        // In the screen coordinates of Core Graphics, which go down from the top of the main display
        let bounds = CGRect(x: rect.minX, y: NSScreen.screens[0].frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        let windows = withWindowsBelow ? onScreenBelowWindow | includingWindow : includingWindow
        return createImage(bounds, windows, UInt32(window.windowNumber), bestResolution)?.takeRetainedValue()
    }

    /// A window as it is on screen, without its shadow, over the `windowsBelow` it and see-through
    /// elsewhere, in Display P3 whatever the display's colour profile: ScreenCaptureKit draws it in that
    /// space for the picture, with every colour the window has, where `CGWindowListCreateImage` has the
    /// screen's own. It needs no Screen Recording permission for the app's own windows.
    @MainActor
    private static func p3Image(of window: NSWindow, over windowsBelow: [NSWindow] = []) async -> CGImage? {
        guard let content = try? await SCShareableContent.currentProcess,
              let screen = window.screen, let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { return nil }
        let windows = ([window] + windowsBelow).compactMap { window in content.windows.first { $0.windowID == CGWindowID(window.windowNumber) } }
        guard windows.count == windowsBelow.count + 1 else { return nil }
        let filter = SCContentFilter(display: display, including: windows)
        let configuration = SCStreamConfiguration()
        configuration.colorSpaceName = CGColorSpace.displayP3
        configuration.showsCursor = false
        configuration.captureResolution = .best
        // In the display's own coordinates, which go down from its top
        configuration.sourceRect = CGRect(x: window.frame.minX - screen.frame.minX, y: screen.frame.maxY - window.frame.maxY,
                                          width: window.frame.width, height: window.frame.height)
        configuration.width = Int(window.frame.width * CGFloat(filter.pointPixelScale))
        configuration.height = Int(window.frame.height * CGFloat(filter.pointPixelScale))
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private func after(_ seconds: Double, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: body)
    }

    private func removeSettings() {
        if let domain = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: domain) }
    }

    private func finish() {
        removeSettings()
        exit(0)
    }

    private func fail(_ message: String) -> Never {
        print("error: \(message)")
        removeSettings()
        exit(1)
    }
}

let arguments = CommandLine.arguments
if let compare = arguments.firstIndex(of: "-compare"), arguments.count > compare + 2 {
    exit(looksTheSame(arguments[compare + 1], arguments[compare + 2]) ? 0 : 1)
}

let screenshots = Screenshots()
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.delegate = screenshots
NSApplication.shared.run()
