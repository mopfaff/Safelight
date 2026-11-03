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
// dragged, time the mouse events by it. So the same scene gives the same frames byte for byte.
//
// scripts/make-demo.sh builds this together with a copy of Safelight.swift, RecordedSystem.swift (the
// system as the app sees it, which records what the app would change on each frame), Interposers.c and
// scripts/screenshots/FixedTime.swift, and runs it with `-scene file.json -output directory`. It writes
// directory/frames/0000.png… and directory/log.json. With `-check YES` as well, it compares its first
// frame with the window server's instead (`check`).
//
// The popover is opened under an invisible icon on the Retina display, in an invisible window that
// clicks go through, and drawn as the active app's popover is (`acquireKeyAppearance`), so nothing on
// screen changes and the recorder never becomes the active app.

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
        return found.sorted { $0.frame.minY < $1.frame.minY }
    }
}

/// A slider a scene can name: which of the popover's SwiftUI sliders it is, from the top, the range of
/// its values, and the value it's bound to
struct Control {
    let index: Int
    let range: () -> ClosedRange<Double>
    let value: () -> Double

    static let all: [String: Control] = [
        "Intensity": Control(index: 0, range: {
            let range = ColorFilterManager.shared.intensityRange
            return Double(range.lowerBound)...Double(range.upperBound)
        }, value: { Double(ColorController.shared.intensity) }),
        // While the displays have one brightness
        "Brightness": Control(index: 1, range: { 0...1 }, value: { Double(ColorController.shared.brightness) }),
    ]

    /// Where the slider is drawn, once it's checked to be this control's: its knob has to be where the
    /// control's value puts it, or another slider is where this one was
    func geometry(in host: NSView, named name: String) -> SliderGeometry {
        let sliders = SliderGeometry.all(in: host)
        guard index < sliders.count else { fail("There's no \(name) slider in the popover") }
        let slider = sliders[index]
        let range = range()
        let fraction = (value() - range.lowerBound) / (range.upperBound - range.lowerBound)
        guard abs(slider.knobFraction - fraction) * Double(slider.frame.width - slider.knobWidth) < 1 else {
            fail("The popover's slider number \(index + 1) isn't \(name)'s: its knob is \(slider.knobFraction) of the way along, \(name) is at \(value())")
        }
        return slider
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

    init(canvas: CGSize, scale: CGFloat, windowFrame: CGRect, backdrop: CGImage?) {
        width = Int(canvas.width * scale)
        height = Int(canvas.height * scale)
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
        }
        // Core Animation's y goes up from the bottom; the canvas's down from the top
        place.frame = CGRect(x: windowFrame.minX, y: canvas.height - windowFrame.maxY, width: windowFrame.width, height: windowFrame.height)
        scaled.addSublayer(place)
        CATransaction.commit()
        renderer.layer = root
        renderer.bounds = root.frame
        CATransaction.flush()
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
    private var anchor: NSWindow!
    private var activity: NSObjectProtocol?

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

        // The Mac as the scene has it, for Safelight to read as it opens
        let isDark = scene.appearance == "dark"
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
              AppearanceManager.shared.isDark() == isDark, NSClassFromString("NSGlobalPreferenceTransition") == nil else {
            fail("Safelight's copy reaches the system's settings; RecordedSystem.swift isn't standing in for them")
        }

        // Safelight opening, with its popover, but not its icon in the menu bar, which this has no use
        // for. The popover stays open whatever's clicked.
        appDelegate.applicationDidFinishLaunching(notification)
        appDelegate.statusItem?.isVisible = false
        appDelegate.popover.behavior = .applicationDefined
        appDelegate.popover.animates = false
        // The wallpaper's pictures, which are only read, as the desktop isn't changed unless one is chosen
        WallpaperManager.shared.showPictures(of: URL(fileURLWithPath: scene.settings.wallpaper))
        openOnceLoaded()
    }

    private func openOnceLoaded() {
        guard WallpaperManager.shared.thumbnails != nil else {
            return DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.openOnceLoaded() }
        }
        guard let screen else { return }
        // Where Safelight's icon would be in the menu bar, invisible: the popover hangs from the height
        // of the old menu bar, which the menu bar centres in its own
        let thickness = NSStatusBar.system.thickness
        let iconWidth = appDelegate.statusItem?.button?.frame.width ?? 32
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
        let windowSize = window.frame.size
        let canvasSize = scene.canvas.map { CGSize(width: $0.width, height: $0.height) } ?? windowSize
        let origin = scene.canvas.map { CGPoint(x: $0.popover[0], y: $0.popover[1]) } ?? .zero
        let windowFrame = CGRect(origin: origin, size: windowSize)
        var backdrop: CGImage?
        if let path = scene.canvas?.backdrop {
            guard let image = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) else { fail("Couldn't read the backdrop \(path)") }
            backdrop = image
        }
        let renderer = FrameRenderer(canvas: canvasSize, scale: CGFloat(scale), windowFrame: windowFrame, backdrop: backdrop)

        // Canvas points to the window's and back: the window's y goes up from its bottom
        func inWindow(_ point: CGPoint) -> NSPoint { NSPoint(x: point.x - origin.x, y: windowSize.height - (point.y - origin.y)) }
        func onCanvas(_ point: NSPoint) -> CGPoint { CGPoint(x: origin.x + point.x, y: origin.y + windowSize.height - point.y) }
        func knob(_ control: String, at value: Double?) -> CGPoint {
            guard let found = Control.all[control] else { fail("There's no control called \(control)") }
            let slider = found.geometry(in: host, named: control)
            let range = found.range()
            let fraction = value.map { ($0 - range.lowerBound) / (range.upperBound - range.lowerBound) } ?? slider.knobFraction
            return onCanvas(host.convert(slider.knobCentre(at: fraction), to: nil))
        }
        func resolve(_ place: DemoScene.Place) -> CGPoint {
            switch place {
            case let .point(x, y): CGPoint(x: x, y: y)
            case let .knob(control, value): knob(control, at: value)
            }
        }
        // Mouse events as the window would be sent them, timed by the scene's clock, which every clock
        // read on the main thread gives as well (Interposers.c). Each comes a millisecond after the one
        // before in its frame, as no two real ones come at once.
        var eventsThisFrame = 0
        func send(_ type: NSEvent.EventType, at point: CGPoint, time: Double) {
            let timestamp = Self.clockStart + time + 0.001 * Double(eventsThisFrame)
            eventsThisFrame += 1
            guard let event = NSEvent.mouseEvent(with: type, location: inWindow(point), modifierFlags: [], timestamp: timestamp,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: type == .leftMouseUp ? 0 : 1) else { fail("Couldn't make a mouse event") }
            scene_clock_set(UInt64((timestamp * 1e9).rounded()))
            window.sendEvent(event)
        }

        // Settled, with anything opening the popover set going over
        host._renderForTest(interval: 0)
        for _ in 0..<5 { host._renderForTest(interval: 1) }
        window.displayIfNeeded()
        if UserDefaults.standard.bool(forKey: "check") {
            return check(window: window, frameLayer: frameLayer, renderer: renderer, canvas: canvasSize, windowFrame: windowFrame, backdrop: backdrop)
        }
        pointer = scene.pointer.map(resolve)

        let arrowTipInWindow = window.convertPoint(fromScreen: arrowTipOnScreen)
        let cursor = NSCursor.arrow
        let displays = Self.activeDisplays()
        var log = Log(scene: name, fps: scene.fps, scale: scale, canvas: [canvasSize.width, canvasSize.height],
                      popover: Log.Popover(window: [windowFrame.minX, windowFrame.minY, windowFrame.width, windowFrame.height],
                                           arrowTip: [onCanvas(arrowTipInWindow).x, onCanvas(arrowTipInWindow).y]),
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

        // PNGs are written in the background, while the next frame is drawn
        let writing = DispatchQueue(label: "Writing frames", qos: .userInitiated, attributes: .concurrent)
        let written = DispatchGroup()
        let inFlight = DispatchSemaphore(value: ProcessInfo.processInfo.activeProcessorCount)

        // Drawn once first, as Core Animation takes a while over its first frame, setting up its shaders
        _ = renderer.draw(frameLayer, at: 0)

        let count = Int((scene.duration * Double(scene.fps)).rounded())
        let actions = scene.actions.sorted { $0.at < $1.at }
        for frame in 0..<count {
            let time = Double(frame) / Double(scene.fps)
            eventsThisFrame = 0
            scene_clock_set(UInt64(((Self.clockStart + time) * 1e9).rounded()))

            // The actions that start by now, then where the running ones have the pointer
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
                } else {
                    fail("The action at \(action.at)s neither moves nor drags")
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
            for (action, _, _) in running where time >= action.end - 1e-9 && action.drag != nil {
                isPressed = false
                send(.leftMouseUp, at: pointer ?? .zero, time: time)
            }
            running.removeAll { time >= $0.action.end - 1e-9 }

            guard window.value(forKey: "hasKeyAppearance") as? Bool == true else { fail("The popover stopped looking key at frame \(frame)") }

            // The frame SwiftUI draws a frame's time later. The run loop isn't run in between: its timers
            // and SwiftUI's display link would draw at the real time, and work the app puts off with
            // DispatchQueue.main.async can't run anyway while this, itself on the main queue, does.
            host._renderForTest(interval: frame == 0 ? 0 : 1 / Double(scene.fps))
            window.displayIfNeeded()
            let animations = Self.coreAnimationAnimations(in: frameLayer)
            var pixels = renderer.draw(frameLayer, at: time)
            guard let image = Self.image(&pixels, width: renderer.width, height: renderer.height, pointer: pointer, cursor: cursor, scale: CGFloat(scale)) else { fail("Couldn't draw frame \(frame)") }
            let url = frames.appendingPathComponent(String(format: "%04d.png", frame))
            inFlight.wait()
            writing.async(group: written) {
                Self.writePNG(image, to: url)
                inFlight.signal()
            }

            var sliders: [String: Log.Slider] = [:]
            let drawn = SliderGeometry.all(in: host)
            for (control, found) in Control.all where found.index < drawn.count {
                let range = found.range()
                sliders[control] = Log.Slider(value: found.value(), knob: range.lowerBound + drawn[found.index].knobFraction * (range.upperBound - range.lowerBound))
            }
            let controller = ColorController.shared
            log.frames.append(Log.Frame(
                frame: frame, time: time,
                pointer: pointer.map { Log.PointerState(x: $0.x, y: $0.y, pressed: isPressed) },
                sliders: sliders,
                app: Log.App(isColorFilterOn: controller.isColorFilterOn, tint: Double(controller.tint), intensity: Double(controller.intensity),
                             brightness: Double(controller.brightness), isDarkAppearance: controller.isDarkAppearance),
                system: Log.System(colorFilter: RecordedSystem.colorFilterEnabled && RecordedSystem.colorFilterType == 16,
                                   hue: RecordedSystem.hue, intensity: RecordedSystem.intensity,
                                   appearance: RecordedSystem.theme == 1 ? "dark" : "light",
                                   displays: displays.map { display in
                                       Log.DisplayBrightness(id: display, brightness: RecordedSystem.hasHardwareBrightness(display)
                                           ? Double(RecordedSystem.hardwareBrightness[display] ?? 1)
                                           : Double(RecordedSystem.gammaTables[display]?.last ?? 1))
                                   }),
                calls: RecordedSystem.calls,
                coreAnimation: animations.isEmpty ? nil : animations))
            RecordedSystem.calls = []
        }

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
        removeSettings()
        exit(0)
    }

    /// When the scene starts on the clock its mouse events are timed by, in seconds
    static let clockStart: TimeInterval = 1000

    // MARK: Checking

    /// With `-check`, instead of recording: the first frame, without the pointer, as the window server
    /// draws it on screen over the backdrop and as the recorder draws it, written to check/ beside the
    /// frames, and how far apart they are. The popover and a window with the backdrop are on screen in
    /// the background for a second, so the displays have to be awake. The window server's picture has
    /// the popover window's shadow and, in Dark, its dark rim, which a frame doesn't. On 3 November 2026,
    /// over a part of Sonoma, in Dark, the glass inside them was at most 6 levels from the window
    /// server's, and 461 of 681,768 pixels 3 levels or more.
    private func check(window: NSWindow, frameLayer: CALayer, renderer: FrameRenderer, canvas: CGSize, windowFrame: CGRect, backdrop: CGImage?) {
        guard let backdrop else { fail("-check needs a backdrop in the scene's canvas, or the window server's picture has whatever's on screen behind") }
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

            var pixels = renderer.draw(frameLayer, at: 0)
            guard let drawn = Self.image(&pixels, width: renderer.width, height: renderer.height, pointer: nil, cursor: .arrow, scale: CGFloat(self.scale)),
                  let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
                  let matched = CGContext(data: nil, width: renderer.width, height: renderer.height, bitsPerComponent: 8, bytesPerRow: renderer.width * 4, space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                  let matchedBytes = matched.data?.assumingMemoryBound(to: UInt8.self) else { fail("Couldn't compare the pictures") }
            // The window server's picture in the display's colours, matched to Display P3 as the frame is
            matched.draw(captured, in: CGRect(x: 0, y: 0, width: renderer.width, height: renderer.height))
            guard (0..<renderer.width * renderer.height).contains(where: { matchedBytes[$0 * 4] | matchedBytes[$0 * 4 + 1] | matchedBytes[$0 * 4 + 2] != 0 }) else {
                fail("The window server's picture is black; are the displays asleep?")
            }
            let folder = self.output.appendingPathComponent("check")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            Self.writePNG(captured, to: folder.appendingPathComponent("window-server.png"))
            Self.writePNG(drawn, to: folder.appendingPathComponent("recorder.png"))

            // Everywhere, and inside the popover's glass only, 20 points in from its window's edges, where
            // its shadow isn't
            let inside = windowFrame.insetBy(dx: 20, dy: 20).applying(CGAffineTransform(scaleX: CGFloat(self.scale), y: CGFloat(self.scale)))
            for (name, area) in [("canvas", CGRect(x: 0, y: 0, width: renderer.width, height: renderer.height)), ("glass", inside)] {
                var counts = [0, 0, 0], largest = 0, total = 0
                for row in Int(area.minY)..<Int(area.maxY) {
                    for column in Int(area.minX)..<Int(area.maxX) {
                        let index = (row * renderer.width + column) * 4
                        let difference = (0..<3).map { abs(Int(pixels[index + $0]) - Int(matchedBytes[index + $0])) }.max() ?? 0
                        largest = max(largest, difference)
                        for (level, limit) in [1, 3, 9].enumerated() where difference >= limit { counts[level] += 1 }
                        total += 1
                    }
                }
                print("\(name): \(total) pixels, \(counts[0]) differ, \(counts[1]) by 3 levels or more, \(counts[2]) by 9 or more, at most \(largest)")
            }
            self.removeSettings()
            exit(0)
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
let recorder = Recorder(scene: scene, name: sceneURL.deletingPathExtension().lastPathComponent, output: URL(fileURLWithPath: outputPath))
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.delegate = recorder
NSApplication.shared.run()
