import Cocoa
import SwiftUI
import QuartzCore
import Metal

// Records Safelight's real popover frame by frame, as a scene file (scripts/demo/scenes/*.json) has it
// change: each frame sets the pointer and sends the mouse events it makes, has SwiftUI lay out and draw
// one frame later (`_renderForTest`, its clock for tests, so its animations follow the scene's time
// rather than the real one), and has Core Animation draw the popover's window off screen (`CARenderer`),
// glass and all, into a PNG with the pointer drawn over it. Meanwhile every clock the main thread reads
// gives the scene's time (Interposers.c), as AppKit's gestures, which move the knob's glass as it's
// dragged, time the mouse events by it, and work the main thread puts on the main queue runs when the
// scene's time reaches it. So the same scene gives the same frames byte for byte. When the scene changes
// the appearance, the app does it as on the Mac, and macOS's part is played as AppearanceTransition.swift
// has it, which the log says frame by frame for scripts/demo/compose.py to draw. AppKit's switches, which
// SwiftUI draws in hosting views of AppKit's own, are moved on a frame at a time as well
// (`SwitchAnimations`). The popover's window grows and shrinks from its top with what's in it (taller
// with the displays adjusted independently), and the canvas has room for it at its largest.
//
// scripts/make-demo.sh builds this together with a copy of Safelight.swift, RecordedSystem.swift (the
// system as the app sees it, which records what the app would change on each frame), Interposers.c and
// scripts/screenshots/FixedTime.swift, and runs it with `-scene file.json -output directory`. It writes
// directory/frames/0000.png… and directory/log.json, and for a scene on the desktop, desktop.png and its
// layers, and the desktop round the popover in each appearance, backdrops/, and with "otherDisplays", each
// other display's desktop, desktop-<its number>.png (Desktop.swift). Instead of recording, with `-check
// YES` as well it writes the window server's picture of the first frame and its own
// (`captureOverBackdrop`), and with `-windowServer folder` it takes what the window server draws round
// the popover, unless it has already (`captureWindowServer`), in the appearance `-appearance` gives and
// over the wallpaper's picture for the one `-wallpaperAppearance` gives, if they're given, and at the
// size `-adjustsDisplaysIndependently YES` or `NO` gives it (which Safelight reads as it opens).
//
// The popover is opened under an invisible icon on the Retina display, in an invisible window that
// clicks go through, and drawn as the active app's popover is (`acquireKeyAppearance`), so nothing on
// screen changes and the recorder never becomes the active app; only the two window-server pictures put
// it on screen, for a second each.

setlinebuf(stdout)

func fail(_ message: String) -> Never {
    print("error: \(message)")
    if let domain = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: domain) }
    exit(1)
}

/// A SwiftUI slider in the popover as it's drawn: where it is in the hosting view (which is flipped), and
/// where its knob is along it
struct SliderGeometry {
    let frame: CGRect
    let knobX: CGFloat
    let knobWidth: CGFloat

    /// How far along the knob is drawn, from 0 at the left end to 1 at the right
    var knobFraction: Double { Double(knobX / (frame.width - knobWidth)) }

    /// The middle of the knob, in the hosting view, when it's `fraction` of the way along
    func knobCentre(at fraction: Double) -> CGPoint {
        CGPoint(x: frame.minX + knobWidth / 2 + CGFloat(fraction) * (frame.width - knobWidth), y: frame.midY)
    }

    /// The SwiftUI sliders in a hosting view from top to bottom, found by how macOS 27 draws one: a layer
    /// whose first sublayer is the track, 6 points high and as wide as the slider, and with a knob 20 by 16
    /// points with round ends, which is a `LiftLayer` while it's held
    static func all(in host: NSView) -> [SliderGeometry] {
        guard let root = host.layer else { return [] }
        var found: [SliderGeometry] = []
        func walk(_ layer: CALayer) {
            let sublayers = layer.sublayers ?? []
            if let track = sublayers.first, abs(track.frame.height - 6) < 0.01, abs(track.frame.width - layer.bounds.width) < 0.01,
               let knob = sublayers.last(where: { "\(type(of: $0))" == "LiftLayer" || ($0.frame.size == CGSize(width: 20, height: 16) && $0.cornerRadius == 8) }) {
                found.append(SliderGeometry(frame: root.convert(layer.bounds, from: layer), knobX: knob.frame.minX, knobWidth: knob.frame.width))
                return
            }
            sublayers.forEach(walk)
        }
        walk(root)
        // A Brightness slider is drawn twice in the same place, a copy behind it for its shadow
        // (`BrightnessSlider`): it's one slider here
        var sliders: [SliderGeometry] = []
        for slider in found.sorted(by: { $0.frame.minY < $1.frame.minY }) {
            if let last = sliders.last, abs(last.frame.minX - slider.frame.minX) < 0.5, abs(last.frame.minY - slider.frame.minY) < 0.5, abs(last.frame.width - slider.frame.width) < 0.5 {
                continue
            }
            sliders.append(slider)
        }
        return sliders
    }

    /// The first AppKit slider of class `type` in a hosting view, as its cell draws it: its track, as
    /// high as its knob, and where its knob is along it
    static func appKit(_ type: NSSlider.Type, in host: NSView) -> SliderGeometry? {
        func find(_ view: NSView) -> NSSlider? {
            view.isMember(of: type) ? view as? NSSlider : view.subviews.lazy.compactMap(find).first
        }
        guard let slider = find(host), let cell = slider.cell as? NSSliderCell else { return nil }
        let knob = cell.knobRect(flipped: slider.isFlipped)
        let track = cell.trackRect
        return SliderGeometry(frame: slider.convert(CGRect(x: track.minX, y: knob.minY, width: track.width, height: knob.height), to: host),
                              knobX: knob.minX - track.minX, knobWidth: knob.width)
    }
}

/// A slider a scene can name: which of the popover's sliders it is, the range of its values, and the
/// value it's bound to
struct Control {
    /// One of the popover's SwiftUI sliders, by its place from the top, or an AppKit slider of its own
    /// class, as Tint is (System Settings' hue slider)
    enum Kind {
        case swiftUI(index: Int)
        case appKit(NSSlider.Type)
    }
    let kind: Kind
    let range: () -> ClosedRange<Double>
    let value: () -> Double

    /// The sliders the popover shows now: Brightness while the displays have one brightness, and while
    /// they're adjusted independently, one for each display instead, named after it ("Brightness DELL
    /// SE2216H"), from the top down in the order the app lists them
    static var all: [String: Control] {
        let controller = ColorController.shared
        var all = [
            "Intensity": Control(kind: .swiftUI(index: 0), range: {
                let range = ColorFilterManager.shared.intensityRange
                return Double(range.lowerBound)...Double(range.upperBound)
            }, value: { Double(controller.intensity) }),
            // In degrees, as the app has it
            "Tint": Control(kind: .appKit(ColorScaleSlider.self), range: { 0...360 }, value: { Double(controller.tint) }),
        ]
        if controller.independentDisplays.isEmpty {
            all["Brightness"] = Control(kind: .swiftUI(index: 1), range: { 0...1 }, value: { Double(controller.brightness) })
        }
        for (index, display) in controller.independentDisplays.enumerated() {
            all["Brightness \(display.name)"] = Control(kind: .swiftUI(index: 1 + index), range: { 0...1 }, value: { Double(controller[brightnessOf: display.key]) })
        }
        return all
    }

    /// Where the slider is drawn, if it is
    func drawn(in host: NSView) -> SliderGeometry? {
        switch kind {
        case let .swiftUI(index):
            let sliders = SliderGeometry.all(in: host)
            return index < sliders.count ? sliders[index] : nil
        case let .appKit(type):
            return SliderGeometry.appKit(type, in: host)
        }
    }

    /// Where the slider is drawn, once it's checked to be this control's: its knob has to be where the
    /// control's value puts it, or another slider is where this one was
    func geometry(in host: NSView, named name: String) -> SliderGeometry {
        guard let slider = drawn(in: host) else { fail("There's no \(name) slider in the popover") }
        let range = range()
        let fraction = (value() - range.lowerBound) / (range.upperBound - range.lowerBound)
        guard abs(slider.knobFraction - fraction) * Double(slider.frame.width - slider.knobWidth) < 1 else {
            fail("The popover's slider that should be \(name)'s isn't: its knob is \(slider.knobFraction) of the way along, \(name) is at \(value())")
        }
        return slider
    }
}

/// A button in the popover a scene can click, by its name, as it's drawn: its frame in the hosting
/// view, which is flipped. SwiftUI gives the hosting view no elements for accessibility, which would
/// name them, while nothing asks it for them, so they're found by how they're drawn. "Light" and "Dark"
/// are the Appearance picker's thumbnails, the first two of the popover's rounded ones the size the
/// picker has them (the Wallpaper picker's are the same size, under them), left and right. The switches,
/// "Schedule", "Color filters" and "Adjust independently", are AppKit's (NSSwitch), from the top down,
/// each checked to be on or off as the setting it's named after is.
func buttonFrame(named name: String, in host: NSView) -> CGRect? {
    let switchNames = [SystemStrings.schedule, SystemStrings.colorFilters, SystemStrings.adjustIndependently]
    if let index = switchNames.firstIndex(of: name) {
        func switches(in view: NSView) -> [NSSwitch] { (view as? NSSwitch).map { [$0] } ?? view.subviews.flatMap(switches) }
        let found = switches(in: host).sorted { $0.convert($0.bounds, to: host).minY < $1.convert($1.bounds, to: host).minY }
        let controller = ColorController.shared
        let states = [controller.isAutoMode, controller.isColorFilterOn, controller.adjustsDisplaysIndependently]
        guard found.count == switchNames.count, zip(found, states).allSatisfy({ ($0.state == .on) == $1 }) else { return nil }
        return found[index].convert(found[index].bounds, to: host)
    }
    guard let root = host.layer, let index = ["Light", "Dark"].firstIndex(of: name) else { return nil }
    var thumbnails: [CGRect] = []
    func walk(_ layer: CALayer) {
        if layer.bounds.size == AppearancePicker.thumbnailSize, layer.cornerRadius == AppearancePicker.thumbnailCornerRadius {
            thumbnails.append(root.convert(layer.bounds, from: layer))
        }
        layer.sublayers?.forEach(walk)
    }
    walk(root)
    // Each thumbnail's clip, and the picture in it, have that shape
    let distinct = thumbnails.reduce(into: [CGRect]()) { found, frame in if !found.contains(frame) { found.append(frame) } }
        .sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
    guard distinct.count >= 2, distinct[0].minY == distinct[1].minY else { return nil }
    return distinct[index]
}

/// AppKit's switches (NSSwitch) are drawn by SwiftUI views of AppKit's own, each in a hosting view of
/// its own (`_NSCoreHostingView`) that the popover's `_renderForTest` doesn't reach: while one animates
/// (its knob growing as it's pressed, and sliding over with a spring when it's switched, about half a
/// second), SwiftUI moves it on each of the display's frames from a display link, which only fires as
/// the run loop runs. So each frame of a shot, every such hosting view in the popover is moved on by the
/// frame's time and drawn, as the popover is (Interposers.c, `scene_render_core_host`).
enum SwitchAnimations {
    /// Moves on each of AppKit's own hosting views in `view` by `interval` seconds; how many there were
    @discardableResult
    static func render(in view: NSView, interval: Double) -> Int {
        var rendered = 0
        if NSStringFromClass(type(of: view)).contains("_NSCoreHostingView") {
            let result = scene_render_core_host(Unmanaged.passUnretained(view).toOpaque(), interval)
            guard result == 0 else { fail("Couldn't have SwiftUI draw AppKit's \(type(of: view.superview ?? view)) (\(result))") }
            rendered += 1
        }
        return view.subviews.reduce(rendered) { $0 + render(in: $1, interval: interval) }
    }
}

/// The app, which takes the mouse events of a shot from the scene while it's recorded. An AppKit
/// control tracks the mouse while it's pressed in a loop of its own: an NSSlider's (as Tint's
/// ColorScaleSlider overrides mouseDown) checks the button is down (`NSEvent.pressedMouseButtons`, which
/// asks the window server), then waits for each event in turn (`nextEvent(matching:…)` with no end,
/// in the event-tracking mode) and looks for any more already there to skip to the latest (with no
/// date, in a coalescing mode), until the button goes up. So while a shot's recorded, the button is
/// the scene's, and those calls are answered by `eventSource` instead, which hands over the frame's
/// events, and once there are none left, draws the frame and starts the next, for a loop that waits.
final class RecorderApplication: NSApplication {
    /// The scene's events, by what's asked for, when, and whether to take it, while a shot's recorded
    static var eventSource: ((_ mask: NSEvent.EventTypeMask, _ until: Date?, _ dequeue: Bool) -> NSEvent?)?
    /// Whether the scene has the button down, while a shot's recorded
    static var isPressed: (() -> Bool)?

    override func nextEvent(matching mask: NSEvent.EventTypeMask, until expiration: Date?, inMode mode: RunLoop.Mode, dequeue deqFlag: Bool) -> NSEvent? {
        if let source = Self.eventSource { return source(mask, expiration, deqFlag) }
        return super.nextEvent(matching: mask, until: expiration, inMode: mode, dequeue: deqFlag)
    }

    /// `NSEvent.pressedMouseButtons` from the scene while it's recorded
    static func takeButtonsFromScene() {
        let selector = NSSelectorFromString("pressedMouseButtons")
        guard let method = class_getClassMethod(NSEvent.self, selector) else { fail("NSEvent has no pressedMouseButtons to answer for the scene") }
        typealias Getter = @convention(c) (AnyClass, Selector) -> Int
        let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        let scene: @convention(block) (AnyClass) -> Int = { type in
            guard let isPressed = RecorderApplication.isPressed else { return original(type, selector) }
            return isPressed() ? 1 : 0
        }
        method_setImplementation(method, imp_implementationWithBlock(scene))
    }
}

/// Draws a layer tree off screen with Core Animation, as the window server would draw it: `canvas`
/// points at `scale` pixels to the point, into an 8-bit Display P3 picture. A layer of AppKit's is
/// moved into it for each frame (`draw`) and put back afterwards, as Core Animation only draws a layer
/// that's in its tree, and doesn't scale the tree's own root.
final class FrameRenderer {
    let width: Int, height: Int
    private let queue: MTLCommandQueue
    private let texture: MTLTexture
    private let renderer: CARenderer
    private let root = CALayer()
    /// Where the window's layer goes, at its place on the canvas
    private let place = CALayer()
    private let canvasHeight: CGFloat
    /// The backdrop as one picture, and in layers, once the desktop changes (`showDesktop`): each
    /// appearance's wallpaper, the Dark one over the Light one, and each one's menu bar over them
    private var picture: CALayer?
    private var wallpapers: [Bool: CALayer] = [:]
    private var menuBars: [Bool: CALayer] = [:]

    init(canvas: CGSize, scale: CGFloat, windowFrame: CGRect, backdrop: CGImage?, layers: [Bool: (wallpaper: CGImage, menuBar: CGImage)] = [:]) {
        width = Int(canvas.width * scale)
        height = Int(canvas.height * scale)
        canvasHeight = canvas.height
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fail("There's no Metal device to draw with") }
        self.queue = queue
        let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        description.usage = [.renderTarget, .shaderRead]
        description.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: description) else { fail("Couldn't make a texture to draw in") }
        self.texture = texture
        renderer = CARenderer(mtlTexture: texture, options: [kCARendererMetalCommandQueue as String: queue,
                                                              kCARendererColorSpace as String: CGColorSpace(name: CGColorSpace.displayP3)!])

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let scaled = CALayer()
        scaled.anchorPoint = .zero
        scaled.frame = CGRect(origin: .zero, size: canvas)
        scaled.transform = CATransform3DMakeScale(scale, scale, 1)
        root.addSublayer(scaled)
        if let backdrop {
            let picture = CALayer()
            picture.frame = scaled.bounds
            picture.contents = backdrop
            scaled.addSublayer(picture)
            self.picture = picture
        }
        for (kind, contents) in [(0, layers.mapValues(\.wallpaper)), (1, layers.mapValues(\.menuBar))] {
            for isDark in [false, true] {
                guard let image = contents[isDark] else { continue }
                let layer = CALayer()
                layer.frame = scaled.bounds
                layer.contents = image
                layer.isHidden = true
                scaled.addSublayer(layer)
                if kind == 0 { wallpapers[isDark] = layer } else { menuBars[isDark] = layer }
            }
        }
        // Core Animation's y goes up from the bottom; the canvas's down from the top
        place.frame = CGRect(x: windowFrame.minX, y: canvas.height - windowFrame.maxY, width: windowFrame.width, height: windowFrame.height)
        scaled.addSublayer(place)
        CATransaction.commit()
        renderer.layer = root
        renderer.bounds = root.frame
        CATransaction.flush()
    }

    /// The window's place on the canvas from now on, as it grows or shrinks with what's in it
    func moveWindow(to frame: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Core Animation's y goes up from the bottom; the canvas's down from the top
        place.frame = CGRect(x: frame.minX, y: canvasHeight - frame.maxY, width: frame.width, height: frame.height)
        CATransaction.commit()
    }

    /// The desktop behind the popover from now on: the wallpaper `dark` of the way from its Light picture
    /// to its Dark one, and the menu bar in Dark or not, in layers instead of the one picture
    func showDesktop(dark: Double, menuBarIsDark: Bool) {
        guard let light = wallpapers[false], let darkLayer = wallpapers[true], menuBars.count == 2 else { fail("There's no desktop in layers to change") }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture?.isHidden = true
        light.isHidden = false
        darkLayer.isHidden = dark == 0
        darkLayer.opacity = Float(dark)
        menuBars[false]?.isHidden = menuBarIsDark
        menuBars[true]?.isHidden = !menuBarIsDark
        CATransaction.commit()
    }

    /// The frame with `layer` (the window's) in it, drawn at `time`, its rows from the top down, premultiplied
    func draw(_ layer: CALayer, at time: CFTimeInterval) -> [UInt8] {
        guard let owner = layer.superlayer, let index = owner.sublayers?.firstIndex(of: layer) else { fail("The popover's layer isn't in its window") }
        func move(_ body: () -> Void) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            body()
            CATransaction.commit()
            CATransaction.flush()
        }
        move { place.addSublayer(layer) }
        defer { move { owner.insertSublayer(layer, at: UInt32(index)) } }

        // Cleared first, as Core Animation only draws over it
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let clear = queue.makeCommandBuffer(), let encoder = clear.makeRenderCommandEncoder(descriptor: pass) else { fail("Couldn't clear the texture") }
        encoder.endEncoding()
        clear.commit()

        renderer.beginFrame(atTime: time, timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        guard let done = queue.makeCommandBuffer() else { fail("Couldn't wait for the frame") }
        done.commit()
        done.waitUntilCompleted()

        let rowBytes = width * 4
        var drawn = [UInt8](repeating: 0, count: rowBytes * height)
        texture.getBytes(&drawn, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        // The texture's rows go up from the bottom
        var rows = [UInt8](repeating: 0, count: rowBytes * height)
        for row in 0..<height {
            rows.replaceSubrange((height - 1 - row) * rowBytes ..< (height - row) * rowBytes, with: drawn[row * rowBytes ..< (row + 1) * rowBytes])
        }
        return rows
    }
}

// MARK: - The log

struct Log: Encodable {
    let scene: String
    let fps: Int
    /// Pixels to the point
    let scale: Int
    /// Points
    let canvas: [Double]
    let popover: Popover
    /// The desktop the canvas is part of, for a scene on the desktop
    let desktop: DesktopInfo?
    let pointer: Pointer
    let displays: [Display]
    /// What Safelight changed as it opened, before the first frame
    let opening: [RecordedSystem.Call]
    var frames: [Frame] = []

    struct Popover: Encodable {
        /// Its window on the canvas: x, y, width, height, in points from the top left
        let window: [Double]
        /// The tip of its arrow, where it hangs from Safelight's icon in the menu bar
        let arrowTip: [Double]
    }

    struct DesktopInfo: Encodable {
        /// desktop.png, beside the frames: the display the popover is on, as macOS shows it
        let image: String
        let display: UInt32
        /// In points, and its pixels to the point
        let size: [Double]
        let scale: Int
        /// The canvas on the desktop, and the popover's window: x, y, width, height, in points from its top left
        let canvas: [Double]
        let popover: [Double]
        let menuBar: [MenuBarItem]
        /// Where the display is, as the displays are arranged, in points from its own top left (so 0, 0),
        /// and its size in millimetres, as it tells macOS
        let frame: [Double]
        let millimetres: [Double]
        /// The Mac's other displays, for a scene with "otherDisplays": true, each with its own desktop
        let others: [OtherDisplay]?
        /// For a scene with a clock of its own, the menu bar's clock for each minute it shows, which
        /// menubar-light.png and menubar-dark.png are without
        let clocks: [MenuBarClock]?
    }

    struct MenuBarClock: Encodable {
        /// What it says, as the frames' `menuBarClock` has it
        let title: String
        /// Its picture in Light and in Dark, beside the frames (clock/light-0000.png…), and where it goes on
        /// the desktop: x, y, width, height, in points from its top left
        let light: String
        let dark: String
        let frame: [Double]
    }

    struct OtherDisplay: Encodable {
        /// Its desktop, beside the frames, drawn as it shows it: the wallpaper, and the menu bar's items as
        /// the menu bar of a display without the active app shows them
        let image: String
        let display: UInt32
        let name: String
        /// In points, and its pixels to the point
        let size: [Double]
        let scale: Int
        /// Where it is as the displays are arranged, in points from the top left of the popover's display,
        /// and its size in millimetres, as it tells macOS
        let frame: [Double]
        let millimetres: [Double]
    }

    struct MenuBarItem: Encodable {
        let name: String
        let frame: [Double]
    }

    struct Pointer: Encodable {
        /// macOS's own arrow, as drawn on each frame, and its hot spot in points from its top left
        let image: String
        let hotSpot: [Double]
    }

    struct Display: Encodable {
        let id: UInt32
        let name: String
        /// How Safelight sets its brightness: "DisplayServices" (the backlight) or "gamma table" (in software)
        let brightnessBy: String
    }

    struct Frame: Encodable {
        let frame: Int
        let time: Double
        /// For a scene with a clock of its own, how far it's run, in seconds from the first frame, the time
        /// of day it reads, and what the menu bar's clock says
        let clockTime: Double?
        let timeOfDay: String?
        let menuBarClock: String?
        /// Where the pointer is on the canvas, and whether it's pressed, unless there's none
        let pointer: PointerState?
        /// Each slider's value, which the app has, and the value its knob is drawn at, which follows it
        /// with a spring
        let sliders: [String: Slider]
        /// The settings as Safelight has them
        let app: App
        /// What Safelight has had the Mac apply, by this frame: the stand-ins' settings
        let system: System
        /// The calls Safelight made to change them during this frame
        let calls: [RecordedSystem.Call]
        /// Animations Core Animation is running in the popover, which would follow the real clock
        let coreAnimation: [String]?
        /// The appearance the popover is drawn in
        let popover: String
        /// Its window on the canvas, as it grows or shrinks with what's in it: x, y, width, height, in
        /// points from the top left
        let window: [Double]
        /// For a scene on the desktop, how the desktop is: the wallpaper, from 0, its picture for Light,
        /// to 1, its picture for Dark, and the menu bar's appearance
        let desktop: DesktopState?
        /// The picture of the screen macOS shows over it while the appearance changes, from the frame
        /// drawn last before it was taken, and how much of it shows, while any does
        let screenPicture: ScreenPicture?
    }

    struct DesktopState: Encodable, Equatable {
        let wallpaper: Double
        let menuBar: String
    }

    struct ScreenPicture: Encodable {
        let frame: Int
        let opacity: Double
    }

    struct PointerState: Encodable {
        let x: Double, y: Double
        let pressed: Bool
    }

    struct Slider: Encodable {
        let value: Double
        let knob: Double
    }

    struct App: Encodable {
        let isColorFilterOn: Bool
        let tint: Double
        let intensity: Double
        let brightness: Double
        let isDarkAppearance: Bool
        let adjustsDisplaysIndependently: Bool
        /// Each display's own brightness while they're adjusted independently, by its name
        let displayBrightness: [String: Double]?
    }

    struct System: Encodable {
        let colorFilter: Bool
        /// Color Tint's hue, 0...1
        let hue: Double
        let intensity: Double
        let appearance: String
        /// Each display's brightness: its backlight's, or what its gamma table leaves of white
        let displays: [DisplayBrightness]
    }

    struct DisplayBrightness: Encodable {
        let id: UInt32
        let brightness: Double
    }
}

// MARK: - The recorder

final class Recorder: NSObject, NSApplicationDelegate {
    private let scene: DemoScene
    private let name: String
    private let output: URL
    private let appDelegate = AppDelegate()
    /// The Retina display the popover is drawn for, at twice its size
    private let screen = NSScreen.screens.first { $0.backingScaleFactor >= 2 }
    private let scale = 2
    /// The popover's appearance as the scene opens, or the one the window server's pictures are taken in
    private var appearance = "dark"
    /// Whether the desktop shows the wallpaper's picture for Dark as the scene opens
    private var wallpaperIsDark = true
    private var anchor: NSWindow!
    private var activity: NSObjectProtocol?
    /// For a scene on the desktop, what draws it, and the desktop once drawn
    private var desktopMaker: DesktopMaker?
    private var desktop: Desktop?

    init(scene: DemoScene, name: String, output: URL) {
        self.scene = scene
        self.name = name
        self.output = output
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard screen != nil else { fail("There's no Retina display to draw the popover at twice its size for") }
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "AppleAccentColor") != nil, defaults.integer(forKey: "AppleAccentColor") == DemoScene.accentColors[scene.accentColor],
              defaults.string(forKey: "AppleLocale") == scene.locale, defaults.stringArray(forKey: "AppleLanguages")?.first == scene.language else {
            fail("Open the recorder with -AppleAccentColor, -AppleLocale and -AppleLanguages as the scene has them, as scripts/make-demo.sh does")
        }
        // Timers aren't put off while it runs in the background, and its settings start out as the defaults
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Recording a demo")
        removeSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { fail("Timed out opening the popover") }

        // The Mac as the scene has it, for Safelight to read as it opens, or for the window server's
        // pictures, in the appearance it's told to take them in, with the wallpaper's picture for the
        // one it's told to
        let isDark = (UserDefaults.standard.string(forKey: "appearance") ?? scene.appearance) == "dark"
        wallpaperIsDark = (UserDefaults.standard.string(forKey: "wallpaperAppearance") ?? (isDark ? "dark" : "light")) == "dark"
        appearance = isDark ? "dark" : "light"
        let wallpaper = wallpaperFile()
        RecordedSystem.colorFilterEnabled = scene.settings.colorFilter
        RecordedSystem.colorFilterType = 16 // Color Tint
        RecordedSystem.hue = scene.settings.tint / 360
        RecordedSystem.intensity = scene.settings.intensity
        RecordedSystem.theme = isDark ? 1 : 0
        for display in Self.activeDisplays() where RecordedSystem.hasHardwareBrightness(display) {
            RecordedSystem.hardwareBrightness[display] = Float(scene.settings.brightness)
        }
        // Set before any window is made, as the system's would be
        NSApp.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)

        // Nothing would stop it changing the Mac if the stand-ins weren't the ones called
        guard let filter = ColorFilterManager.shared.read(), filter.intensity == Float(scene.settings.intensity),
              AppearanceManager.shared.isDark() == isDark, NSClassFromString("NSGlobalPreferenceTransition") === RecordedPreferenceTransition.self else {
            fail("Safelight's copy reaches the system's settings; RecordedSystem.swift isn't standing in for them")
        }

        // On the desktop, the menu bar's items are drawn beside Safelight's icon, the stand-ins made
        // before it as each new item goes to the left
        if scene.desktop {
            guard scene.canvas == nil, let screen else { fail("A scene on the desktop has its canvas worked out from it, so it can't have one of its own") }
            desktopMaker = DesktopMaker(screen: screen, isDark: isDark, wallpaperIsDark: wallpaperIsDark, wallpaper: wallpaper,
                                        otherScreens: scene.otherDisplays ? NSScreen.screens.filter { $0 != screen } : [], clockTitles: clockTitles())
            desktopMaker?.addSystemItems()
        }

        // Safelight opening, with its popover, but not its icon in the menu bar, which this only needs
        // for drawing the desktop's. The popover stays open whatever's clicked.
        appDelegate.applicationDidFinishLaunching(notification)
        appDelegate.popover.behavior = .applicationDefined
        appDelegate.popover.animates = false
        // The wallpaper's pictures, which are only read, as the desktop isn't changed unless one is chosen
        WallpaperManager.shared.showPictures(of: wallpaper)
        if let desktopMaker, let item = appDelegate.statusItem {
            desktopMaker.make(with: item) { desktop in
                self.desktop = desktop
                self.openOnceLoaded()
            }
        } else {
            appDelegate.statusItem?.isVisible = false
            openOnceLoaded()
        }
    }

    /// What the menu bar's clock says through a scene with a clock of its own, each once, in order; none
    /// for any other scene, whose clock says 21:00
    private func clockTitles() -> [String] {
        guard scene.clock != nil else { return [] }
        let count = Int((scene.duration * Double(scene.fps)).rounded())
        var titles: [String] = []
        for frame in 0..<count {
            let title = DesktopMaker.clockTitle(at: wallClock(scene.clockTime(at: Double(frame) / Double(scene.fps))))
            if titles.last != title { titles.append(title) }
        }
        return titles
    }

    /// The scene's wallpaper: its file, or for one picture for Light and another for Dark, a wallpaper
    /// with both, made as Safelight's Wallpaper row makes it, beside the frames
    private func wallpaperFile() -> URL {
        switch scene.settings.wallpaper {
        case let .file(path):
            return URL(fileURLWithPath: path)
        case let .pair(light, dark):
            let made = output.appendingPathComponent("wallpaper.heic")
            guard WallpaperManager.makeWallpaper(at: made, light: (URL(fileURLWithPath: light), false), dark: (URL(fileURLWithPath: dark), true)) else {
                fail("Couldn't make a wallpaper of \(light)'s picture for Light and \(dark)'s for Dark")
            }
            return made
        }
    }

    private func openOnceLoaded() {
        guard WallpaperManager.shared.thumbnails != nil else {
            return DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.openOnceLoaded() }
        }
        guard let screen else { return }
        // Where Safelight's icon would be in the menu bar, invisible: the popover hangs from the height
        // of the old menu bar, which the menu bar centres in its own
        let thickness = NSStatusBar.system.thickness
        // As wide as its place in the menu bar, which is the same whichever display's menu bar has it
        let iconWidth = appDelegate.statusItem?.button?.window?.frame.width ?? 32
        anchor = NSWindow(contentRect: NSRect(x: screen.frame.midX, y: screen.visibleFrame.maxY - thickness, width: iconWidth, height: thickness),
                          styleMask: .borderless, backing: .buffered, defer: false)
        anchor.isOpaque = false
        anchor.backgroundColor = .clear
        anchor.alphaValue = 0
        anchor.ignoresMouseEvents = true
        anchor.orderFrontRegardless()

        let popover = appDelegate.popover
        guard let place = anchor.contentView, let view = popover.contentViewController?.view else { fail("Couldn't open the popover") }
        // At its full size from the start, as it otherwise grows once SwiftUI has laid it out
        popover.contentSize = view.fittingSize
        popover.show(relativeTo: place.bounds, of: place, preferredEdge: .minY)
        guard let window = view.window, let host = view as? NSHostingView<MenuView> else { fail("Couldn't open the popover") }
        // Drawn here, not on screen, where it's invisible and clicks go through it
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        // In Display P3 rather than the display's own colours, which change when macOS rewrites its profile
        window.colorSpace = .displayP3
        let arrowTip = place.convert(NSPoint(x: place.bounds.midX, y: place.bounds.minY), to: nil)
        recordOnceShown(window: window, host: host, arrowTipOnScreen: anchor.convertPoint(toScreen: arrowTip))
    }

    /// Records once AppKit has put the popover's window on screen and given its frame a layer, which
    /// it does a moment after it's shown, and has drawn it as the active app's popover is: with its
    /// controls in their colours rather than grey. AppKit does that for a window that becomes key
    /// (`acquireKeyAppearance`), and this has it do it without the window becoming key or the app
    /// active. Done any earlier, AppKit could take it back as it put the window on screen, and its
    /// controls only change over once the main queue has run.
    private func recordOnceShown(window: NSWindow, host: NSHostingView<MenuView>, arrowTipOnScreen: NSPoint, tries: Int = 100) {
        guard window.isVisible, window.contentView?.superview?.layer != nil else {
            guard tries > 0 else { fail("The popover didn't open") }
            return DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.recordOnceShown(window: window, host: host, arrowTipOnScreen: arrowTipOnScreen, tries: tries - 1)
            }
        }
        let acquireKeyAppearance = NSSelectorFromString("acquireKeyAppearance")
        guard window.responds(to: acquireKeyAppearance), window.backingScaleFactor == CGFloat(scale) else { fail("Couldn't draw the popover as it's drawn when it's open") }
        window.perform(acquireKeyAppearance)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Kept from the window server (Interposers.c), or the user's own window would lose its key look
            guard key_appearances_kept() > 0 else { fail("AppKit told the window server the popover looks key in a way Interposers.c doesn't stop") }
            self.record(window: window, host: host, arrowTipOnScreen: arrowTipOnScreen)
        }
    }

    // MARK: Recording

    /// The pointer, on the canvas, and whether it's pressed
    private var pointer: CGPoint?
    private var isPressed = false
    /// The actions under way, with where each moves the pointer from and to
    private var running: [(action: DemoScene.Action, from: CGPoint, to: CGPoint)] = []
    private var started = 0

    private func record(window: NSWindow, host: NSHostingView<MenuView>, arrowTipOnScreen: NSPoint) {
        guard let frameLayer = window.contentView?.superview?.layer else { fail("The popover has no layer to draw") }
        // With a clock of its own, the wall clock reads the first key's time of day at the first frame
        if let start = scene.clock?.first?.seconds {
            scene_wall_clock_set(UInt64(DemoScene.day + start - Self.clockStart))
        }
        let windowSize = window.frame.size
        // The popover at its largest in the shot, as the canvas has room for it to grow: it's taller while
        // the displays are adjusted independently, so if the scene switches that, its size the other way,
        // which it's switched to and back for, leaving the app and what it has set as they were
        var largest = windowSize
        if scene.clicks(SystemStrings.adjustIndependently) {
            let controller = ColorController.shared
            let (calls, gammaTables, hardwareBrightness) = (RecordedSystem.calls, RecordedSystem.gammaTables, RecordedSystem.hardwareBrightness)
            func switched() {
                controller.adjustsDisplaysIndependently.toggle()
                host._renderForTest(interval: 0)
                window.displayIfNeeded()
            }
            switched()
            largest = CGSize(width: max(largest.width, window.frame.width), height: max(largest.height, window.frame.height))
            switched()
            RecordedSystem.calls = calls
            guard window.frame.size == windowSize, RecordedSystem.gammaTables == gammaTables, RecordedSystem.hardwareBrightness == hardwareBrightness else {
                fail("Switching Adjust independently and back to measure the popover didn't leave it as it was")
            }
        }
        // Where the arrow's tip is in the window, from its top left
        let arrowTipInWindow = window.convertPoint(fromScreen: arrowTipOnScreen)
        let arrowTip = CGPoint(x: arrowTipInWindow.x, y: windowSize.height - arrowTipInWindow.y)
        var canvasSize = scene.canvas.map { CGSize(width: $0.width, height: $0.height) } ?? windowSize
        var origin = scene.canvas.map { CGPoint(x: $0.popover[0], y: $0.popover[1]) } ?? .zero
        var backdrop: CGImage?
        if let path = scene.canvas?.backdrop {
            guard let image = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) else { fail("Couldn't read the backdrop \(path)") }
            backdrop = image
        }
        // On the desktop, the canvas is the popover's surroundings there, under Safelight's icon
        var desktopInfo: Log.DesktopInfo?
        if let desktop {
            let popover = desktop.popover(size: windowSize, arrowTip: arrowTip)
            let canvas = desktop.canvas(around: CGRect(origin: popover.origin, size: largest))
            (canvasSize, origin, backdrop) = (canvas.frame.size, canvas.popover, canvas.backdrop)
            desktopInfo = Log.DesktopInfo(image: "desktop.png", display: desktop.displayID, size: [desktop.size.width, desktop.size.height], scale: Int(desktop.scale),
                                          canvas: [canvas.frame.minX, canvas.frame.minY, canvas.frame.width, canvas.frame.height],
                                          popover: [popover.minX, popover.minY, popover.width, popover.height],
                                          menuBar: desktop.menuBarItems.map { Log.MenuBarItem(name: $0.name, frame: [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height]) },
                                          frame: [0, 0, desktop.size.width, desktop.size.height], millimetres: [desktop.millimetres.width, desktop.millimetres.height],
                                          others: scene.otherDisplays ? desktop.others.map { other in
                                              Log.OtherDisplay(image: "desktop-\(other.displayID).png", display: other.displayID, name: other.name,
                                                               size: [other.frame.width, other.frame.height], scale: Int(other.scale),
                                                               frame: [other.frame.minX, other.frame.minY, other.frame.width, other.frame.height],
                                                               millimetres: [other.millimetres.width, other.millimetres.height])
                                          } : nil,
                                          clocks: desktop.clocks.isEmpty ? nil : desktop.clocks.enumerated().map { number, clock in
                                              Log.MenuBarClock(title: clock.title, light: "clock/" + Desktop.clockPicture(number, isDark: false),
                                                               dark: "clock/" + Desktop.clockPicture(number, isDark: true),
                                                               frame: [clock.frame.minX, clock.frame.minY, clock.frame.width, clock.frame.height])
                                          })
        }
        let windowFrame = CGRect(origin: origin, size: windowSize)
        let canvasOnDesktop = desktopInfo.map { CGRect(x: $0.canvas[0], y: $0.canvas[1], width: $0.canvas[2], height: $0.canvas[3]) }
        let renderer = FrameRenderer(canvas: canvasSize, scale: CGFloat(scale), windowFrame: windowFrame, backdrop: backdrop,
                                     layers: canvasOnDesktop.flatMap { desktop?.canvasLayers($0) } ?? [:])

        // Canvas points to the window's and back: the window's y goes up from its bottom, which moves as it
        // grows or shrinks from its top
        func inWindow(_ point: CGPoint) -> NSPoint { NSPoint(x: point.x - origin.x, y: window.frame.height - (point.y - origin.y)) }
        func onCanvas(_ point: NSPoint) -> CGPoint { CGPoint(x: origin.x + point.x, y: origin.y + window.frame.height - point.y) }
        func knob(_ control: String, at value: Double?) -> CGPoint {
            guard let found = Control.all[control] else { fail("There's no control called \(control)") }
            let slider = found.geometry(in: host, named: control)
            let range = found.range()
            let fraction = value.map { ($0 - range.lowerBound) / (range.upperBound - range.lowerBound) } ?? slider.knobFraction
            return onCanvas(host.convert(slider.knobCentre(at: fraction), to: nil))
        }
        /// A button's frame on the canvas
        func button(_ name: String) -> CGRect {
            guard let frame = buttonFrame(named: name, in: host) else { fail("There's no button called \(name) in the popover") }
            let inWindow = host.convert(frame, to: nil)
            let topLeft = onCanvas(NSPoint(x: inWindow.minX, y: inWindow.maxY))
            return CGRect(origin: topLeft, size: inWindow.size)
        }
        func resolve(_ place: DemoScene.Place) -> CGPoint {
            switch place {
            case let .point(x, y): CGPoint(x: x, y: y)
            case let .knob(control, value): knob(control, at: value)
            case let .button(name): CGPoint(x: button(name).midX, y: button(name).midY)
            }
        }
        // Mouse events as the window would be sent them, timed by the scene's clock, which every clock
        // read on the main thread gives as well (Interposers.c), from when each is handled. Each comes a
        // millisecond after the one before in its frame, as no two real ones come at once. A frame's are
        // made first, then handled in turn (`handle`).
        var eventsThisFrame = 0
        var pending: [(event: NSEvent, nanoseconds: UInt64)] = []
        func send(_ type: NSEvent.EventType, at point: CGPoint, time: Double) {
            let timestamp = Self.clockStart + time + 0.001 * Double(eventsThisFrame)
            eventsThisFrame += 1
            guard let event = NSEvent.mouseEvent(with: type, location: inWindow(point), modifierFlags: [], timestamp: timestamp,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: type == .leftMouseUp ? 0 : 1) else { fail("Couldn't make a mouse event") }
            pending.append((event, UInt64((timestamp * 1e9).rounded())))
        }

        // Settled, with anything opening the popover set going over
        host._renderForTest(interval: 0)
        for _ in 0..<5 { host._renderForTest(interval: 1) }
        window.displayIfNeeded()
        if UserDefaults.standard.bool(forKey: "check") {
            return captureOverBackdrop(window: window, frameLayer: frameLayer, renderer: renderer, canvas: canvasSize, windowFrame: windowFrame, backdrop: backdrop,
                                       desktopCanvas: desktopInfo?.canvas, into: output) { self.finish() }
        }
        if let folder = UserDefaults.standard.string(forKey: "windowServer") {
            return captureWindowServer(window: window, frameLayer: frameLayer, renderer: renderer, canvas: canvasSize, windowFrame: windowFrame, backdrop: backdrop,
                                       desktopCanvas: desktopInfo?.canvas, into: URL(fileURLWithPath: folder))
        }
        pointer = scene.pointer.map(resolve)

        // With a schedule, the Schedule switch is on as the shot begins, as it's been since some time before:
        // the keyframes are the Schedule's, and Safelight has set the Mac from them for the time of day the
        // scene's clock reads at its first frame, which it's set to now. Then its timer sets the Mac every
        // minute (`minutes`), as it does from when Safelight opens, here from a whole minute.
        var scheduleTimer: Timer?
        if let keyframes = scene.schedule {
            let controller = ColorController.shared
            do {
                controller.schedule = try keyframes.enumerated().map { index, keyframe in
                    guard ["light", "dark"].contains(keyframe.appearance), let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index)) else {
                        fail("A keyframe's appearance is light or dark, not \(keyframe.appearance)")
                    }
                    return ColorKeyframe(id: id, minute: try keyframe.minute(), isColorFilterOn: keyframe.colorFilter, intensity: Float(keyframe.intensity),
                                         tint: Float(keyframe.tint), brightness: Float(keyframe.brightness), isDarkAppearance: keyframe.appearance == "dark")
                }
            } catch {
                fail("The scene's schedule: \(error)")
            }
            guard let timer = Mirror(reflecting: controller).children.first(where: { $0.label == "timer" })?.value as? Timer, timer.isValid, timer.timeInterval == 60 else {
                fail("Couldn't find the Schedule's timer, which sets the Mac every minute")
            }
            scheduleTimer = timer
            scene_clock_set(Self.clockNanoseconds(0))
            controller.isAutoMode = true
            // Settled, with the switch over and the sliders dimmed
            host._renderForTest(interval: 0)
            for _ in 0..<5 {
                host._renderForTest(interval: 1)
                SwitchAnimations.render(in: host, interval: 1)
            }
            window.displayIfNeeded()
            guard controller.isAutoMode, !controller.isChangingAppearance, controller.isDarkAppearance == (appearance == "dark") else {
                fail("The Schedule has the Mac in another appearance than the scene's as it begins")
            }
        }

        let cursor = NSCursor.arrow
        let displays = Self.activeDisplays()
        var log = Log(scene: name, fps: scene.fps, scale: scale, canvas: [canvasSize.width, canvasSize.height],
                      popover: Log.Popover(window: [windowFrame.minX, windowFrame.minY, windowFrame.width, windowFrame.height],
                                           arrowTip: [onCanvas(arrowTipInWindow).x, onCanvas(arrowTipInWindow).y]),
                      desktop: desktopInfo,
                      pointer: Log.Pointer(image: "NSCursor.arrow", hotSpot: [cursor.hotSpot.x, cursor.hotSpot.y]),
                      displays: displays.map { display in
                          Log.Display(id: display, name: NSScreen.screens.first { Self.id(of: $0) == display }?.localizedName ?? "",
                                      brightnessBy: RecordedSystem.hasHardwareBrightness(display) ? "DisplayServices" : "gamma table")
                      },
                      opening: RecordedSystem.calls)
        RecordedSystem.calls = []

        let frames = output.appendingPathComponent("frames")
        try? FileManager.default.removeItem(at: frames)
        do {
            try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        } catch {
            fail("Couldn't make \(frames.path): \(error)")
        }
        desktop?.write(to: output.appendingPathComponent("desktop.png"))
        if let canvasOnDesktop { desktop?.writeBackdrops(around: canvasOnDesktop, into: output.appendingPathComponent("backdrops")) }

        // PNGs are written in the background, while the next frame is drawn
        let writing = DispatchQueue(label: "Writing frames", qos: .userInitiated, attributes: .concurrent)
        let written = DispatchGroup()
        let inFlight = DispatchSemaphore(value: ProcessInfo.processInfo.activeProcessorCount)

        // Drawn once first, as Core Animation takes a while over its first frame, setting up its shaders
        _ = renderer.draw(frameLayer, at: 0)

        let count = Int((scene.duration * Double(scene.fps)).rounded())
        let actions = scene.actions.sorted { $0.at < $1.at }
        var frame = 0

        /// With a clock of the scene's, which runs faster than the shot, the popover is drawn on the scene's
        /// clock up to `target` (seconds from the first frame) as the display would have drawn it meanwhile:
        /// a display frame at a time (1/fps) through the second after anything changed (the Schedule's
        /// timer, or work on the main queue), longer than any of its animations runs (an AppKit switch's,
        /// about half a second), then the rest in one go. SwiftUI moves an animation on by less than a long
        /// interval, so in one step of a minute or so a switch was still half over. Main queue work due
        /// meanwhile runs at its time. `drawing`, for the frame itself: drawn at `target` even if it's
        /// been drawn at that time, as the Schedule may have changed something since.
        var renderedAt = 0.0
        var animatingUntil = 0.0
        var drawnOnce = false
        func advance(to target: Double, drawing: Bool) {
            let displayFrame = 1 / Double(scene.fps)
            func step(to time: Double) {
                let nanoseconds = Self.clockNanoseconds(time)
                let ran = scene_main_queue_work_run()
                scene_main_queue_run(nanoseconds)
                if scene_main_queue_work_run() != ran { animatingUntil = max(animatingUntil, time + 1) }
                scene_clock_set(nanoseconds)
                host._renderForTest(interval: drawnOnce ? time - renderedAt : 0)
                switchFrames += SwitchAnimations.render(in: host, interval: drawnOnce ? time - renderedAt : 0)
                renderedAt = time
                drawnOnce = true
            }
            while renderedAt + displayFrame < min(target, animatingUntil) - 1e-9 {
                step(to: renderedAt + displayFrame)
            }
            if target > renderedAt || drawing { step(to: target) }
        }

        /// Starts the frame: the actions that start by now, then where the running ones have the
        /// pointer, as the frame's events
        func begin() {
            let time = Double(frame) / Double(scene.fps)
            eventsThisFrame = 0
            let now = Self.clockNanoseconds(scene.clockTime(at: time))
            // The Schedule's timer each minute since the last frame, and the main queue's work that's due
            // by now, in the order the run loop would have run them, the popover drawn up to each minute
            if let scheduleTimer, frame > 0 {
                let previous = Self.clockNanoseconds(scene.clockTime(at: Double(frame - 1) / Double(scene.fps)))
                for firing in Self.minutes(startingAt: scene.clock?.first?.seconds ?? 0, after: previous, upTo: now) {
                    advance(to: Double(firing) / 1e9 - Self.clockStart, drawing: false)
                    scene_clock_set(firing)
                    scheduleTimer.fire()
                    animatingUntil = Double(firing) / 1e9 - Self.clockStart + 1
                }
            }
            scene_main_queue_run(now)
            scene_clock_set(now)

            while started < actions.count, actions[started].at <= time + 1e-9 {
                let action = actions[started]
                started += 1
                guard let from = pointer else { fail("An action at \(action.at)s needs the pointer, but there's none") }
                if let control = action.drag {
                    guard let found = Control.all[control], let to = action.to else { fail("A drag at \(action.at)s needs a control and a value to drag it to") }
                    let start = knob(control, at: nil)
                    guard hypot(start.x - from.x, start.y - from.y) < 3 else { fail("The pointer isn't on \(control)'s knob at \(action.at)s") }
                    if let expected = action.from, abs(found.value() - expected) > 1e-4 { fail("\(control) is at \(found.value()), not \(expected), at \(action.at)s") }
                    running.append((action, from, knob(control, at: to)))
                    isPressed = true
                    send(.leftMouseDown, at: from, time: time)
                } else if let place = action.move {
                    running.append((action, from, resolve(place)))
                } else if let place = action.click {
                    let on: Bool
                    switch place {
                    case let .button(name): on = button(name).contains(from)
                    default: on = hypot(resolve(place).x - from.x, resolve(place).y - from.y) < 3
                    }
                    guard on else { fail("The pointer isn't on what's clicked at \(action.at)s") }
                    running.append((action, from, from))
                    isPressed = true
                    send(.leftMouseDown, at: from, time: time)
                } else {
                    fail("The action at \(action.at)s neither moves, drags nor clicks")
                }
            }
            for (action, from, to) in running {
                let progress = action.duration > 0 ? action.easing((time - action.at) / action.duration) : 1
                let point = CGPoint(x: from.x + (to.x - from.x) * progress, y: from.y + (to.y - from.y) * progress)
                if point != pointer {
                    pointer = point
                    send(isPressed ? .leftMouseDragged : .mouseMoved, at: point, time: time)
                }
            }
            for (action, _, _) in running where time >= action.end - 1e-9 && (action.drag != nil || action.click != nil) {
                isPressed = false
                send(.leftMouseUp, at: pointer ?? .zero, time: time)
            }
            running.removeAll { time >= $0.action.end - 1e-9 }
        }

        /// The first of the frame's events still to handle that's one of `mask`'s, taken if `dequeue`,
        /// with the clock at its time, and the button down from when its press is taken till its release is
        var isButtonDown = false
        func take(_ mask: NSEvent.EventTypeMask = .any, dequeue: Bool = true) -> NSEvent? {
            guard let index = pending.firstIndex(where: { mask.contains(NSEvent.EventTypeMask(type: $0.event.type)) }) else { return nil }
            let (event, nanoseconds) = pending[index]
            if dequeue {
                pending.remove(at: index)
                scene_main_queue_run(nanoseconds)
                scene_clock_set(nanoseconds)
                if event.type == .leftMouseDown { isButtonDown = true }
                if event.type == .leftMouseUp { isButtonDown = false }
            }
            return event
        }

        /// Draws the frame and logs it, and moves on to the next
        func finish() {
            let time = Double(frame) / Double(scene.fps)
            // How far the scene's clock has run, which may be faster than the shot
            let clock = scene.clockTime(at: time)
            guard window.value(forKey: "hasKeyAppearance") as? Bool == true else { fail("The popover stopped looking key at frame \(frame)") }

            // The frame SwiftUI draws a frame's time later on the scene's clock. The run loop isn't run in
            // between: its timers and SwiftUI's display link would draw at the real time. Work on the main
            // queue is kept for the scene's clock instead (Interposers.c), and what's due by now runs first.
            scene_main_queue_run(scene_clock_now())
            if scene.clock == nil {
                host._renderForTest(interval: frame == 0 ? 0 : 1 / Double(scene.fps))
                switchFrames += SwitchAnimations.render(in: host, interval: frame == 0 ? 0 : 1 / Double(scene.fps))
            } else {
                advance(to: clock, drawing: true)
            }
            window.displayIfNeeded()
            // The popover's window grows and shrinks with what's in it, from its top, where its arrow is
            if window.frame.size != windowNow.size {
                guard window.frame.maxY == windowTop, window.frame.minX == windowLeft else { fail("The popover's window moved at frame \(frame), rather than only growing or shrinking") }
                windowNow.size = window.frame.size
                guard windowNow.maxX <= canvasSize.width, windowNow.maxY <= canvasSize.height else { fail("The popover's window grew past the canvas at frame \(frame)") }
                renderer.moveWindow(to: windowNow)
            }
            let animations = Self.coreAnimationAnimations(in: frameLayer)
            // The desktop behind the glass as it is now, in layers once it's changed
            var desktopState: Log.DesktopState?
            if desktop != nil {
                let state = Log.DesktopState(wallpaper: AppearanceTransition.wallpaper(at: clock, from: startingDesktop.wallpaper), menuBar: menuBarIsDark ? "dark" : "light")
                if state != startingDesktop || desktopInLayers {
                    renderer.showDesktop(dark: state.wallpaper, menuBarIsDark: menuBarIsDark)
                    desktopInLayers = true
                }
                desktopState = state
            }
            let screenPicture = AppearanceTransition.all.last.flatMap { transition in
                let opacity = transition.pictureOpacity(at: clock)
                return opacity > 0 ? Log.ScreenPicture(frame: transition.snapshotFrame, opacity: opacity) : nil
            }
            let popoverAppearance = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
            var pixels = renderer.draw(frameLayer, at: clock)
            // On the desktop, scripts/demo/compose.py draws the pointer, over the window server's shadow,
            // and wherever it is on the desktop
            guard let image = Self.image(&pixels, width: renderer.width, height: renderer.height, pointer: scene.desktop ? nil : pointer, cursor: cursor,
                                         scale: CGFloat(scale)) else { fail("Couldn't draw frame \(frame)") }
            let url = frames.appendingPathComponent(String(format: "%04d.png", frame))
            inFlight.wait()
            writing.async(group: written) {
                Self.writePNG(image, to: url)
                inFlight.signal()
            }

            var sliders: [String: Log.Slider] = [:]
            for (control, found) in Control.all {
                guard let drawn = found.drawn(in: host) else { continue }
                let range = found.range()
                sliders[control] = Log.Slider(value: found.value(), knob: range.lowerBound + drawn.knobFraction * (range.upperBound - range.lowerBound))
            }
            let controller = ColorController.shared
            log.frames.append(Log.Frame(
                frame: frame, time: time,
                clockTime: scene.clock == nil ? nil : clock, timeOfDay: scene.clock == nil ? nil : Self.timeOfDay(clock, startingAt: scene.clock?.first?.seconds ?? 0),
                menuBarClock: scene.clock == nil ? nil : DesktopMaker.clockTitle(at: wallClock(clock)),
                pointer: pointer.map { Log.PointerState(x: $0.x, y: $0.y, pressed: isPressed) },
                sliders: sliders,
                app: Log.App(isColorFilterOn: controller.isColorFilterOn, tint: Double(controller.tint), intensity: Double(controller.intensity),
                             brightness: Double(controller.brightness), isDarkAppearance: controller.isDarkAppearance,
                             adjustsDisplaysIndependently: controller.adjustsDisplaysIndependently,
                             displayBrightness: controller.independentDisplays.isEmpty ? nil
                                 : Dictionary(controller.independentDisplays.map { ($0.name, Double(controller[brightnessOf: $0.key])) }) { first, _ in first }),
                system: Log.System(colorFilter: RecordedSystem.colorFilterEnabled && RecordedSystem.colorFilterType == 16,
                                   hue: RecordedSystem.hue, intensity: RecordedSystem.intensity,
                                   appearance: RecordedSystem.theme == 1 ? "dark" : "light",
                                   displays: displays.map { display in
                                       Log.DisplayBrightness(id: display, brightness: RecordedSystem.hasHardwareBrightness(display)
                                           ? Double(RecordedSystem.hardwareBrightness[display] ?? 1)
                                           : Double(RecordedSystem.gammaTables[display]?.last ?? 1))
                                   }),
                calls: RecordedSystem.calls,
                coreAnimation: animations.isEmpty ? nil : animations,
                popover: popoverAppearance, window: [windowNow.minX, windowNow.minY, windowNow.width, windowNow.height],
                desktop: desktopState, screenPicture: screenPicture))
            RecordedSystem.calls = []
            RecordedPreferenceTransition.framesDrawn = frame + 1
            frame += 1
        }

        // While an AppKit control tracks the mouse, its loop takes the events, and once it waits for
        // more than the frame has, the frame's drawn and the next one started
        // The app's appearance changes as AppKit changes it when it's told, on the scene's clock, and the
        // menu bar's with it; the wallpaper changes over by itself (AppearanceTransition.swift)
        var menuBarIsDark = appearance == "dark"
        var windowNow = windowFrame
        var switchFrames = 0
        let (windowTop, windowLeft) = (window.frame.maxY, window.frame.minX)
        RecordedPreferenceTransition.now = { (Double(scene_clock_now()) / 1e9 - Self.clockStart) }
        RecordedPreferenceTransition.changeAppAppearance = { isDark in
            NSApp.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
            menuBarIsDark = isDark
        }
        let startingDesktop = Log.DesktopState(wallpaper: wallpaperIsDark ? 1 : 0, menuBar: appearance)
        var desktopInLayers = false
        scene_main_queue_hold()
        RecorderApplication.isPressed = { isButtonDown }
        RecorderApplication.eventSource = { mask, until, dequeue in
            while true {
                if let event = take(mask, dequeue: dequeue) { return event }
                // A loop that only looks for more gets none
                guard let until, until > Date() else { return nil }
                guard frame + 1 < count else { fail("The scene ends while AppKit is still tracking the mouse: let go of it before") }
                finish()
                begin()
            }
        }
        while frame < count {
            begin()
            while let event = take() { window.sendEvent(event) }
            finish()
        }
        RecorderApplication.eventSource = nil
        RecorderApplication.isPressed = nil
        let mainQueueWork = scene_main_queue_work_run()
        let mainQueueLeft = scene_main_queue_release()

        written.wait()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(log).write(to: output.appendingPathComponent("log.json"))
        } catch {
            fail("Couldn't write the log: \(error)")
        }
        // The slider's knob would follow the real clock if the main thread weren't reading the scene's
        guard scene_clock_readings() > 0 else { fail("Nothing read the scene's clock; see Interposers.c") }
        print("Recorded \(count) frames of \(renderer.width)×\(renderer.height) to \(frames.path)")
        print("The main queue's work: \(mainQueueWork) ran on the scene's clock, \(mainQueueLeft) still due as it ended")
        print("AppKit's switches drawn on the scene's clock: \(switchFrames) times")
        removeSettings()
        exit(0)
    }

    /// When the scene starts on the clock its mouse events are timed by, in seconds
    static let clockStart: TimeInterval = 1000

    /// The scene's clock, as Interposers.c gives it, `clock` seconds after the first frame, in nanoseconds
    static func clockNanoseconds(_ clock: Double) -> UInt64 {
        UInt64(((clockStart + clock) * 1e9).rounded())
    }

    /// What the wall clock reads `clock` seconds after the first frame, with a scene clock of its own
    private func wallClock(_ clock: Double) -> Date {
        Date(timeIntervalSince1970: DemoScene.day + (scene.clock?.first?.seconds ?? 0) + clock)
    }

    /// The time of day `clock` seconds after a first frame at `start` seconds after midnight: HH:MM:SS.sss
    static func timeOfDay(_ clock: Double, startingAt start: Double) -> String {
        let milliseconds = Int(((start + clock) * 1000).rounded()) % 86_400_000
        return String(format: "%02d:%02d:%02d.%03d", milliseconds / 3_600_000, milliseconds / 60_000 % 60, milliseconds / 1000 % 60, milliseconds % 1000)
    }

    /// When the Schedule's timer fires between two frames, after `previous` and up to `now` on the scene's
    /// clock, in nanoseconds, with the first frame at `start` seconds after midnight: on each whole minute
    /// of the time of day, as if Safelight had opened on one
    static func minutes(startingAt start: Double, after previous: UInt64, upTo now: UInt64) -> [UInt64] {
        let minute: Int64 = 60_000_000_000
        let base = Int64(clockNanoseconds(0))
        // The time of day at the first frame, which is on a whole second
        let dayStart = Int64(start) * 1_000_000_000
        var next = (dayStart + Int64(previous) - base) / minute + 1
        var firings: [UInt64] = []
        while next * minute - dayStart + base <= Int64(now) {
            firings.append(UInt64(next * minute - dayStart + base))
            next += 1
        }
        return firings
    }

    // MARK: Checking

    /// The first frame, without the pointer, as the window server draws it on screen over the backdrop
    /// (window-server.png, in the display's colours) and as the recorder draws it (recorder.png), written
    /// into `folder` with the backdrop and where the window is on it (about.json). The popover and a
    /// window with the backdrop are on screen in the background for a second, so the displays have to
    /// be awake. The window server's picture has the popover window's shadow and rims, which a frame
    /// doesn't; scripts/demo/compose.py compares the two (`check`) and takes the window server's picture
    /// of the popover's edge, which is the same on every frame (`WindowServerLayer`).
    private func captureOverBackdrop(window: NSWindow, frameLayer: CALayer, renderer: FrameRenderer, canvas: CGSize, windowFrame: CGRect, backdrop: CGImage?,
                                     desktopCanvas: [Double]?, into folder: URL, then done: @escaping () -> Void) {
        guard let backdrop else { fail("Comparing with the window server needs a backdrop in the scene's canvas, or the window server's picture has whatever's on screen behind") }
        // The canvas on screen, with the popover's window where it is on it
        let onScreen = NSRect(x: window.frame.minX - windowFrame.minX, y: window.frame.maxY + windowFrame.minY - canvas.height,
                              width: canvas.width, height: canvas.height)
        let behind = NSWindow(contentRect: onScreen, styleMask: .borderless, backing: .buffered, defer: false)
        behind.ignoresMouseEvents = true
        behind.contentView?.wantsLayer = true
        behind.contentView?.layer?.contents = backdrop
        behind.level = window.level
        behind.order(.below, relativeTo: window.windowNumber)
        guard behind.frame == onScreen else { fail("The backdrop's window was moved to \(behind.frame) from \(onScreen); give the canvas no room above the popover, where the menu bar is") }
        window.alphaValue = 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            guard let symbol = Darwin.dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { fail("There's no CGWindowListCreateImage") } // RTLD_DEFAULT
            let createImage = unsafeBitCast(symbol, to: CreateImage.self)
            // In Core Graphics' screen coordinates, which go down from the top of the main display
            let bounds = CGRect(x: onScreen.minX, y: NSScreen.screens[0].frame.maxY - onScreen.maxY, width: onScreen.width, height: onScreen.height)
            let onScreenBelowWindow: UInt32 = 1 << 2, includingWindow: UInt32 = 1 << 3, bestResolution: UInt32 = 1 << 3
            let captured = createImage(bounds, onScreenBelowWindow | includingWindow, UInt32(window.windowNumber), bestResolution)?.takeRetainedValue()
            window.alphaValue = 0
            behind.orderOut(nil)
            guard let captured, captured.width == renderer.width, captured.height == renderer.height else { fail("Couldn't take the window server's picture") }
            guard let bytes = Self.pixels(of: captured), bytes.enumerated().contains(where: { $0.offset % 4 != 3 && $0.element != 0 }) else {
                fail("The window server's picture is black; are the displays asleep?")
            }

            var pixels = renderer.draw(frameLayer, at: 0)
            guard let drawn = Self.image(&pixels, width: renderer.width, height: renderer.height, pointer: nil, cursor: .arrow, scale: CGFloat(self.scale)) else {
                fail("Couldn't draw the first frame")
            }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            Self.writePNG(captured, to: folder.appendingPathComponent("window-server.png"))
            Self.writePNG(drawn, to: folder.appendingPathComponent("recorder.png"))
            Self.writePNG(backdrop, to: folder.appendingPathComponent("backdrop.png"))
            var about: [String: Any] = ["appearance": self.appearance, "scale": self.scale, "display": self.screen.flatMap(Self.id) ?? 0,
                                        "window": [windowFrame.minX, windowFrame.minY, windowFrame.width, windowFrame.height]]
            about["canvas"] = desktopCanvas
            if let data = try? JSONSerialization.data(withJSONObject: about, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: folder.appendingPathComponent("about.json"))
            }
            print("Captured the window server's picture of the popover over the backdrop into \(folder.path)")
            done()
        }
    }

    /// A picture's pixels, drawn in Display P3, 8 bits a channel
    private static func pixels(of image: CGImage) -> [UInt8]? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) else { return nil }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    private func finish() -> Never {
        removeSettings()
        exit(0)
    }

    /// With `-windowServer folder`, instead of recording: what the window server draws round the
    /// popover's window, which a frame doesn't have, for scripts/demo/compose.py to add to the frames.
    /// Its shadow and its rims: a hard dark one round it and, inside its edge, a faint white one, as
    /// AppKit asks for it (`SLSTransactionSetWindowShadowProperties`: density 0.3, radius 8, 4 points
    /// down; rim 0.85, 2 points; inner rim 0.1, 3 points, on 3 November 2026). The popover is on screen
    /// for a second, over nothing, and two pictures of it are taken, in the display's colours: with
    /// its shadow (with-shadow.png, the window's frame and `margin` points round it) and without
    /// (alone.png). Their difference is what the window server adds. Only the inner rim depends on
    /// whether the window looks key, which the window server isn't told (Interposers.c), so Interposers.c
    /// gives the popover's window its key look's rims whether it looks key or not. Written into a folder
    /// of `folder` named after the appearance and the window's size, as they're the same for every frame
    /// and every scene, once: nothing is shown if that folder has them already. For a scene on the
    /// desktop, then the popover over the desktop round it (`captureOverBackdrop`), into a folder there
    /// for that desktop (desktop, desktop-2, …), unless one has it over the same desktop already.
    private func captureWindowServer(window: NSWindow, frameLayer: CALayer, renderer: FrameRenderer, canvas: CGSize, windowFrame: CGRect, backdrop: CGImage?,
                                     desktopCanvas: [Double]?, into folder: URL) {
        let place = folder.appendingPathComponent("\(appearance)-\(Int(window.frame.width))x\(Int(window.frame.height))")
        // Then, on the desktop, the popover over the desktop round it, unless it's been taken over the same
        func overDesktop() {
            guard let backdrop, desktopCanvas != nil else { finish() }
            let wanted = Self.pixels(of: backdrop)
            var number = 1
            var desktop: URL { place.appendingPathComponent(number == 1 ? "desktop" : "desktop-\(number)") }
            while FileManager.default.fileExists(atPath: desktop.path) {
                let taken = CGImageSourceCreateWithURL(desktop.appendingPathComponent("backdrop.png") as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                if taken.flatMap(Self.pixels) == wanted {
                    print("The window server's picture of the popover over the desktop is already in \(desktop.path)")
                    finish()
                }
                number += 1
            }
            captureOverBackdrop(window: window, frameLayer: frameLayer, renderer: renderer, canvas: canvas, windowFrame: windowFrame, backdrop: backdrop,
                                desktopCanvas: desktopCanvas, into: desktop) { self.finish() }
        }
        guard !FileManager.default.fileExists(atPath: place.appendingPathComponent("about.json").path) else {
            print("The window server's shadow round the popover is already in \(place.path)")
            return overDesktop()
        }
        let margin: CGFloat = 48
        let rect = window.frame.insetBy(dx: -margin, dy: -margin)
        window.alphaValue = 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard active_shadows_given() > 0 else { fail("AppKit gave the popover's window its shadow in a way Interposers.c doesn't see") }
            typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            guard let symbol = Darwin.dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { fail("There's no CGWindowListCreateImage") } // RTLD_DEFAULT
            let createImage = unsafeBitCast(symbol, to: CreateImage.self)
            let includingWindow: UInt32 = 1 << 3, boundsIgnoreFraming: UInt32 = 1 << 0, bestResolution: UInt32 = 1 << 3
            // In Core Graphics' screen coordinates, which go down from the top of the main display
            let bounds = CGRect(x: rect.minX, y: NSScreen.screens[0].frame.maxY - rect.maxY, width: rect.width, height: rect.height)
            let withShadow = createImage(bounds, includingWindow, UInt32(window.windowNumber), bestResolution)?.takeRetainedValue()
            let alone = createImage(.null, includingWindow, UInt32(window.windowNumber), boundsIgnoreFraming | bestResolution)?.takeRetainedValue()
            window.alphaValue = 0
            let scale = Int(window.backingScaleFactor)
            guard let withShadow, let alone, withShadow.width == Int(rect.width) * scale, alone.width == Int(window.frame.width) * scale,
                  alone.height == Int(window.frame.height) * scale else { fail("Couldn't take the window server's pictures of the popover") }
            try? FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
            Self.writePNG(withShadow, to: place.appendingPathComponent("with-shadow.png"))
            Self.writePNG(alone, to: place.appendingPathComponent("alone.png"))
            let about: [String: Any] = ["margin": margin, "scale": scale, "window": [window.frame.width, window.frame.height], "appearance": self.appearance,
                                        "display": NSScreen.screens.first { $0.frame.intersects(window.frame) }?.localizedName ?? ""]
            if let data = try? JSONSerialization.data(withJSONObject: about, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: place.appendingPathComponent("about.json"))
            }
            print("Captured the window server's shadow round the popover into \(place.path)")
            // A moment later, as the popover's window has just been hidden
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { overDesktop() }
        }
    }

    // MARK: Drawing

    /// A frame's pixels as a picture, with the pointer drawn over them
    private static func image(_ pixels: inout [UInt8], width: Int, height: Int, pointer: CGPoint?, cursor: NSCursor, scale: CGFloat) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        if let pointer {
            // In points from the top left, as the canvas is
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            let size = cursor.image.size
            cursor.image.draw(in: NSRect(x: pointer.x - cursor.hotSpot.x, y: pointer.y - cursor.hotSpot.y, width: size.width, height: size.height),
                              from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        return context.makeImage()
    }

    private static func writePNG(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { fail("Couldn't write \(url.path)") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { fail("Couldn't write \(url.path)") }
    }

    /// The animations Core Animation itself is running in a layer tree, which a frame drawn at the
    /// scene's time would show at the wrong point; SwiftUI's own follow its clock for tests
    private static func coreAnimationAnimations(in layer: CALayer) -> [String] {
        (layer.animationKeys() ?? []).map { "\(type(of: layer)).\($0)" } + (layer.sublayers ?? []).flatMap(coreAnimationAnimations)
    }

    // MARK: Displays

    static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return Array(displays.prefix(Int(count)))
    }

    static func id(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func removeSettings() {
        if let domain = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: domain) }
    }
}

let arguments = UserDefaults.standard
guard let scenePath = arguments.string(forKey: "scene"), let outputPath = arguments.string(forKey: "output") else {
    fail("Usage: Recorder -scene scene.json -output directory")
}
let sceneURL = URL(fileURLWithPath: scenePath)
let scene: DemoScene
do {
    scene = try DemoScene.load(sceneURL)
} catch {
    fail("Couldn't read \(scenePath): \(error)")
}
// Made first, so it's the app, which takes a shot's events from the scene
let application = RecorderApplication.shared
guard application is RecorderApplication else { fail("The app was made before the recorder's could be") }
RecorderApplication.takeButtonsFromScene()
let recorder = Recorder(scene: scene, name: sceneURL.deletingPathExtension().lastPathComponent, output: URL(fileURLWithPath: outputPath))
application.setActivationPolicy(.accessory)
application.delegate = recorder
application.run()
