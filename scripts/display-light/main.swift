import AppKit
import AVFoundation
import CoreMedia
import IOKit

// scripts/display-light.sh's app: measures how fast each display's light changes, with the Studio
// Display camera watching the room and whoever's in front, lit by the displays.
//
// The camera sets its exposure itself, within a fifth of a second, whatever it's asked, and says
// nothing of it, so a frame's average brightness hardly moves for a slow change. But it brightens or
// darkens the whole picture at once, while a display lights some places more than others. So each
// frame is split into a grid, and what's measured is the brightness of the places a display lights
// most over that of the places it lights least: the exposure cancels out. The places are the ones
// that darkened most and least the moment the display's picture was blacked out. Only these
// measurements are kept, never the frames.

setlinebuf(stdout)

// MARK: DDC (the Dell)
typealias CreateService = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
typealias TransferI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)!
let createService = unsafeBitCast(dlsym(iokit, "IOAVServiceCreateWithService")!, to: CreateService.self)
let writeI2C = unsafeBitCast(dlsym(iokit, "IOAVServiceWriteI2C")!, to: TransferI2C.self)
let coreDisplay = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)!
let displayInfo = unsafeBitCast(dlsym(coreDisplay, "CoreDisplay_DisplayCreateInfoDictionary")!,
                                to: (@convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?).self)
func externalServices() -> [String: CFTypeRef] {
    var services: [String: CFTypeRef] = [:]
    var iterator = io_iterator_t()
    IORegistryEntryCreateIterator(IORegistryGetRootEntry(kIOMainPortDefault), kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator)
    var framebuffer: String?
    while case let entry = IOIteratorNext(iterator), entry != 0 {
        defer { IOObjectRelease(entry) }
        var name = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(entry, &name)
        switch String(cString: name) {
        case "IOMobileFramebufferShim", "AppleCLCD2":
            var path = [CChar](repeating: 0, count: 512)
            IORegistryEntryGetPath(entry, kIOServicePlane, &path)
            framebuffer = String(cString: path)
        case "DCPAVServiceProxy":
            let place = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            if place == "External", let location = framebuffer, let service = createService(kCFAllocatorDefault, entry)?.takeRetainedValue() {
                services[location] = service
                framebuffer = nil
            }
        default: break
        }
    }
    IOObjectRelease(iterator)
    return services
}

/// The Dell, over DDC, and the Studio Display, through DisplayServices
let dell: CGDirectDisplayID = 3
let studio: CGDirectDisplayID = 2
let dellService = externalServices()[(displayInfo(dell)?.takeRetainedValue() as NSDictionary?)?["IODisplayLocation"] as! String]!
/// Writes the Dell's brightness, and again 50 ms later, as Safelight writes it
func setDell(_ value: Int) {
    func write() {
        var packet: [UInt8] = [0x84, 0x03, 0x10, 0, UInt8(value)]
        packet.append(packet.reduce(0x6E ^ 0x51, ^))
        _ = writeI2C(dellService, 0x37, 0x51, &packet, UInt32(packet.count))
    }
    write()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { write() }
}
let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
let setStudio = unsafeBitCast(dlsym(ds, "DisplayServicesSetBrightness"), to: (@convention(c) (CGDirectDisplayID, Float) -> Int32).self)
let getStudio = unsafeBitCast(dlsym(ds, "DisplayServicesGetBrightness"), to: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32).self)
var studioOriginal: Float = 1
_ = getStudio(studio, &studioOriginal)

func hostNow() -> Double { CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) }

// MARK: Camera
/// Each frame's brightness in a grid of places, kept in memory only for the measurements
let columns = 16, rows = 12
final class Frames: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let lock = NSLock()
    var frames: [(time: Double, cells: [Double])] = []
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let width = CVPixelBufferGetWidthOfPlane(pixels, 0), height = CVPixelBufferGetHeightOfPlane(pixels, 0)
        var sums = [Int](repeating: 0, count: columns * rows), counts = [Int](repeating: 0, count: columns * rows)
        for y in stride(from: 0, to: height, by: 2) {
            let row = base + y * rowBytes
            let cellRow = y * rows / height * columns
            for x in stride(from: 0, to: width, by: 2) {
                let cell = cellRow + x * columns / width
                sums[cell] += Int(row[x]); counts[cell] += 1
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        let cells = zip(sums, counts).map { Double($0) / Double(max($1, 1)) }
        lock.lock(); frames.append((time, cells)); lock.unlock()
    }
}
let recorder = Frames()
let session = AVCaptureSession()

func startCamera() {
    guard let camera = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified)
            .devices.first(where: { $0.localizedName.contains("Studio Display") }),
          let input = try? AVCaptureDeviceInput(device: camera) else { print("No Studio Display camera"); exit(1) }
    session.beginConfiguration()
    session.addInput(input)
    let output = AVCaptureVideoDataOutput()
    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
    output.alwaysDiscardsLateVideoFrames = true
    output.setSampleBufferDelegate(recorder, queue: DispatchQueue(label: "frames", qos: .userInteractive))
    session.addOutput(output)
    session.commitConfiguration()
    // The smallest pictures at the most frames a second, held there: the camera takes only the exact
    // durations it lists
    if let format = camera.formats.min(by: { CMVideoFormatDescriptionGetDimensions($0.formatDescription).width < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width }),
       let fastest = format.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
        try? camera.lockForConfiguration()
        camera.activeFormat = format
        camera.activeVideoMinFrameDuration = fastest.minFrameDuration
        camera.activeVideoMaxFrameDuration = fastest.minFrameDuration
        camera.unlockForConfiguration()
        print("camera at \(CMVideoFormatDescriptionGetDimensions(format.formatDescription).width) wide, \(Int(fastest.maxFrameRate.rounded())) frames a second")
    }
    session.startRunning()
    run()
}

// MARK: Covers
var covers: [CGDirectDisplayID: NSWindow] = [:]
/// Fills a display with white or black, over everything, without taking focus
func cover(_ display: CGDirectDisplayID, _ color: NSColor) {
    let window = covers[display] ?? {
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display }!
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        covers[display] = window
        return window
    }()
    window.backgroundColor = color
    window.orderFrontRegardless()
    window.display()
}

// MARK: The run
enum Kind { case blackout, brightness }
struct Step { let time: Double; let display: CGDirectDisplayID; let kind: Kind; let name: String }
var steps: [Step] = []
var startTime = 0.0
/// Does `action` `seconds` into the run, noting it as a step to measure
func at(_ seconds: Double, _ display: CGDirectDisplayID? = nil, _ kind: Kind = .brightness, _ name: String = "", _ action: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        if let display { steps.append(Step(time: hostNow(), display: display, kind: kind, name: name)) }
        action()
    }
}

/// The Dell's cover for calibrating and checking: white, as under grey (tried on 2026-11-06) it lights
/// the room too little to tell a 10% change from noise. The places near the camera's top, where white
/// would make them clip, are left out of the measure instead.
let unclipped = NSColor.white

/// Scales the Dell's picture by `scale` through its gamma table, at once, as Safelight dims a display
/// in software
func setDellPicture(_ scale: Double) {
    let table = (0..<256).map { CGGammaValue(Double($0) / 255 * scale) }
    CGSetDisplayTransferByTable(dell, 256, table, table, table)
}
let isCalibrating = CommandLine.arguments.contains("--calibrate-dell")

/// For the Dell's dimming assist: how its light compares with its picture scaled in software, step by
/// step, and how its backlight moves after a value is written once and when written as a slider moves
func calibrateDell() {
    print("Calibrating the Dell; both screens flash for about a minute")
    cover(dell, unclipped); cover(studio, .black); setDellPicture(1)
    at(1.5, dell, .blackout, "blackout") { setDellPicture(0) }
    at(2.2, dell, .blackout, "picture 1") { setDellPicture(1) }
    // The picture scaled in software, at full backlight
    let scales = [1.0, 0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2, 0.1, 0.05, 0.0]
    for (i, scale) in scales.enumerated() {
        at(3.0 + Double(i) * 0.5, dell, .blackout, "picture \(scale)") { setDellPicture(scale) }
    }
    at(9.0, dell, .blackout, "picture 1") { setDellPicture(1) }
    // The backlight, from 100 down to 0 a tenth at a time, each given time to settle
    for (i, level) in stride(from: 90, through: 0, by: -10).enumerated() {
        at(10.0 + Double(i) * 1.5, dell, .brightness, "level \(level)") { setDell(level) }
    }
    // Single writes, as a click on a slider or a key press
    let jumps: [(Double, Int, Int)] = [(25.0, 0, 100), (29.5, 100, 0), (34.5, 0, 50), (37.5, 50, 100), (40.5, 100, 50), (43.5, 50, 40), (45.0, 40, 50), (46.5, 50, 100)]
    for (time, from, to) in jumps {
        at(time, dell, .brightness, "jump \(from) \(to)") { setDell(to) }
    }
    // Written as a slider moves: ten values, 50 ms apart
    for (time, from, to) in [(50.0, 100, 50), (53.0, 50, 100)] {
        at(time, dell, .brightness, "drag \(from) \(to)") {}
        for i in 1...10 { at(time + Double(i - 1) * 0.05) { setDell(from + (to - from) * i / 10) } }
    }
    // The picture scaled again, to see the measure hasn't drifted
    for (i, scale) in [1.0, 0.5, 0.2, 1.0].enumerated() {
        at(56.0 + Double(i) * 0.5, dell, .blackout, "picture \(scale)") { setDellPicture(scale) }
    }
    at(58.0) { finish() }
}

/// Steps the Dell through Safelight's own GammaManager, which helps its backlight along when dimming,
/// as a slider and the brightness keys do, and the Studio Display through DisplayServices to compare
let isCheckingAssist = CommandLine.arguments.contains("--assist")
func checkAssist() {
    print("Checking the Dell's dimming assist; both screens flash for about 40 s")
    cover(dell, unclipped); cover(studio, .black)
    let gamma = GammaManager.shared
    gamma.monitorFound = { displayID, _ in if displayID == dell { gamma.setBrightness([dell: 1]) } }
    gamma.setBrightness([dell: 1])
    at(2.0, dell, .blackout, "Dell picture blacked out") { cover(dell, .black) }
    at(3.0, dell, .blackout, "Dell picture back") { cover(dell, .white) }
    at(4.5, dell, .brightness, "Dell slider 1 -> 0") { gamma.setBrightness([dell: 0]) }
    at(9.0, dell, .brightness, "Dell slider 0 -> 1") { gamma.setBrightness([dell: 1]) }
    at(13.5, dell, .brightness, "Dell slider 1 -> 0.5") { gamma.setBrightness([dell: 0.5]) }
    at(16.5, dell, .brightness, "Dell slider 0.5 -> 1") { gamma.setBrightness([dell: 1]) }
    at(19.5, dell, .brightness, "Dell key 1 -> 0.9375") { _ = gamma.setMonitor(dell, to: 0.9375, fading: true) }
    at(21.0, dell, .brightness, "Dell key 0.9375 -> 1") { _ = gamma.setMonitor(dell, to: 1, fading: true) }
    at(22.5, dell, .brightness, "Dell key held 1 -> 0.625") {}
    for i in 1...6 { at(22.5 + Double(i - 1) * 0.0833) { _ = gamma.setMonitor(dell, to: 1 - 0.0625 * Float(i), fading: true) } }
    at(25.5) { _ = gamma.setMonitor(dell, to: 1, fading: false) }
    at(29.0) { cover(dell, .black); cover(studio, .white) }
    at(31.0, studio, .blackout, "Studio Display picture blacked out") { cover(studio, .black) }
    at(32.0, studio, .blackout, "Studio Display picture back") { cover(studio, .white) }
    at(33.5, studio, .brightness, "Studio Display 1 -> 0") { _ = setStudio(studio, 0) }
    at(36.5, studio, .brightness, "Studio Display 0 -> 1") { _ = setStudio(studio, 1) }
    at(39.5) { finish() }
}

/// The null test for the Dell's BacklightResponse: with its picture already scaled to look like a step,
/// that step is written and the picture scaled back up as its response says its backlight comes down.
/// If the response is right, the light doesn't change; the camera, which only has to see whether it
/// does, can tell to a few percent. A 10% dip of the picture after each shows how much a change reads.
let isNulling = CommandLine.arguments.contains("--null-dell")
var compensation: Timer?
func nullDell() {
    guard let response = BacklightResponse.of(dell) else { print("No BacklightResponse for the Dell"); exit(1) }
    print("Null-testing the Dell's BacklightResponse; both screens flash for about a minute")
    cover(dell, unclipped); cover(studio, .black); setDellPicture(1)
    // The places it lights picked once the camera has settled on the Dell's light
    at(3.0, dell, .blackout, "blackout") { setDellPicture(0) }
    at(3.7, dell, .blackout, "picture 1") { setDellPicture(1) }
    var time = 4.7
    for level in [0, 0.2, 0.4, 0.6, 0.8, 0.9] as [Float] {
        let scale = response.pictureScale(at: level)
        let travel = response.delay + Double((1 - level) / response.pace)
        at(time) { setDellPicture(Double(scale)) }
        at(time + 2.0, dell, .brightness, "null \(level) travel \(String(format: "%.2f", travel))") {
            let written = hostNow()
            setDell(Int((level * 100).rounded()))
            compensation?.invalidate()
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
                let elapsed = hostNow() - written
                let backlight = elapsed < response.delay ? 1 : max(level, 1 - Float(elapsed - response.delay) * response.pace)
                setDellPicture(Double(min(1, scale / response.pictureScale(at: backlight))))
                if backlight <= level { setDellPicture(1); timer.invalidate() }
            }
            RunLoop.main.add(timer, forMode: .common)
            compensation = timer
        }
        at(time + 2.0 + travel + 0.8, dell, .blackout, "probe \(level)") { setDellPicture(0.9) }
        at(time + 2.0 + travel + 0.95) { setDellPicture(1) }
        at(time + 2.0 + travel + 1.3) { setDell(100) }
        time += 2.0 + travel + 1.3 + travel + 0.4
    }
    at(time) { finish() }
}

func run() {
    if isCalibrating { calibrateDell(); return }
    if isNulling { nullDell(); return }
    if isCheckingAssist { checkAssist(); return }
    print("Studio Display brightness at the start: \(studioOriginal); both screens flash for 36 s")
    cover(dell, .white); cover(studio, .black)
    at(2.5, dell, .blackout, "Dell picture blacked out") { cover(dell, .black) }
    at(4.0, dell, .blackout, "Dell picture back") { cover(dell, .white) }
    at(6.0, dell, .brightness, "Dell 100 -> 0") { setDell(0) }
    at(9.0, dell, .brightness, "Dell 0 -> 100") { setDell(100) }
    at(12.0, dell, .brightness, "Dell 100 -> 50") { setDell(50) }
    at(15.0, dell, .brightness, "Dell 50 -> 100") { setDell(100) }
    at(18.0) { cover(dell, .black); cover(studio, .white) }
    at(20.5, studio, .blackout, "Studio Display picture blacked out") { cover(studio, .black) }
    at(22.0, studio, .blackout, "Studio Display picture back") { cover(studio, .white) }
    at(24.0, studio, .brightness, "Studio Display 1 -> 0") { _ = setStudio(studio, 0) }
    at(27.0, studio, .brightness, "Studio Display 0 -> 1") { _ = setStudio(studio, 1) }
    at(30.0, studio, .brightness, "Studio Display 1 -> 0.5") { _ = setStudio(studio, 0.5) }
    at(33.0, studio, .brightness, "Studio Display 0.5 -> 1") { _ = setStudio(studio, 1) }
    at(36.0) { finish() }
}

func finish() {
    session.stopRunning()
    covers.values.forEach { $0.orderOut(nil) }
    setDell(100)
    _ = setStudio(studio, studioOriginal)
    if isCalibrating || isCheckingAssist || isNulling { CGDisplayRestoreColorSyncSettings() }
    recorder.lock.lock(); let taken = recorder.frames; recorder.lock.unlock()
    print("frames: \(taken.count)")
    func average(_ cells: [Double], _ places: [Int]) -> Double { places.map { cells[$0] }.reduce(0, +) / Double(places.count) }
    func frames(from start: Double, to end: Double) -> [(time: Double, cells: [Double])] { taken.filter { $0.time >= start && $0.time < end } }
    func averageCells(_ frames: [(time: Double, cells: [Double])]) -> [Double] {
        (0..<columns * rows).map { cell in frames.map { $0.cells[cell] }.reduce(0, +) / Double(max(frames.count, 1)) }
    }

    for display in [dell, studio] {
        // The places the display lights most and least: those that darkened most and least in the
        // frames just after its picture was blacked out, before the camera's exposure caught up
        guard let blackout = steps.first(where: { $0.display == display && $0.kind == .blackout }) else { continue }
        let before = averageCells(frames(from: blackout.time - 0.3, to: blackout.time))
        let firstAfter = frames(from: blackout.time, to: blackout.time + 0.4).dropFirst(3).prefix(2)
        let after = averageCells(Array(firstAfter))
        // Not the places at the camera's top (video levels end at 235), which can't get any brighter
        let darkening = (0..<columns * rows).filter { before[$0] < 225 }
            .sorted { log(after[$0] / max(before[$0], 1)) < log(after[$1] / max(before[$1], 1)) }
        let lit = Array(darkening.prefix(darkening.count / 6)), unlit = Array(darkening.suffix(darkening.count / 6))
        print(String(format: "\n%@: the places it lights most darkened by %.0f%%, the ones it lights least by %.0f%%",
                     display == dell ? "Dell" : "Studio Display",
                     (1 - average(after, lit) / average(before, lit)) * 100, (1 - average(after, unlit) / average(before, unlit)) * 100))
        /// The display's light, whatever the camera's exposure: the lit places over the unlit ones
        func light(_ cells: [Double]) -> Double { log(average(cells, lit) / average(cells, unlit)) }

        // Calibrating, every step and every frame's measure is printed, for working out the model
        if isCalibrating || isNulling {
            let start = steps.first?.time ?? 0
            for step in steps { print(String(format: "E %.4f %@", step.time - start, step.name)) }
            for frame in taken { print(String(format: "M %.4f %.5f", frame.time - start, light(frame.cells))) }
            continue
        }

        for (index, step) in steps.enumerated() where step.display == display {
            // Until the next step, as a backlight can take seconds
            let next = steps.dropFirst(index + 1).first?.time ?? step.time + 3
            let settle = step.kind == .blackout ? min(1.4, next - step.time - 0.05) : min(4.4, next - step.time - 0.05)
            let from = frames(from: step.time - 0.3, to: step.time).map { light($0.cells) }
            let to = frames(from: step.time + settle - 0.5, to: step.time + settle).map { light($0.cells) }
            guard !from.isEmpty, !to.isEmpty else { continue }
            let start = from.reduce(0, +) / Double(from.count), end = to.reduce(0, +) / Double(to.count)
            let curve = frames(from: step.time, to: step.time + settle).map { ($0.time - step.time, (light($0.cells) - start) / (end - start)) }
            func reach(_ fraction: Double) -> String {
                curve.first { $0.1 >= fraction }.map { String(format: "%4.0f", $0.0 * 1000) } ?? "   -"
            }
            print(String(format: "%@ (change %.3f): 10%% at %@ ms, 50%% at %@ ms, 90%% at %@ ms", step.name, end - start, reach(0.1), reach(0.5), reach(0.9)))
            let shown = curve.count > 40 ? stride(from: 0, to: curve.count, by: 3).map { curve[$0] } : curve
            print("  " + shown.map { String(format: "%.0f:%.2f", $0.0 * 1000, $0.1) }.joined(separator: " "))
        }
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
switch AVCaptureDevice.authorizationStatus(for: .video) {
case .authorized: DispatchQueue.main.async { startCamera() }
case .notDetermined:
    AVCaptureDevice.requestAccess(for: .video) { granted in
        DispatchQueue.main.async { if granted { startCamera() } else { print("No camera access"); exit(1) } }
    }
default: print("No camera access: allow Display Light in System Settings › Privacy & Security › Camera"); exit(1)
}
app.run()
