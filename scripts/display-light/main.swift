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

func run() {
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
        let darkening = (0..<columns * rows).sorted { log(after[$0] / max(before[$0], 1)) < log(after[$1] / max(before[$1], 1)) }
        let lit = Array(darkening.prefix(columns * rows / 6)), unlit = Array(darkening.suffix(columns * rows / 6))
        print(String(format: "\n%@: the places it lights most darkened by %.0f%%, the ones it lights least by %.0f%%",
                     display == dell ? "Dell" : "Studio Display",
                     (1 - average(after, lit) / average(before, lit)) * 100, (1 - average(after, unlit) / average(before, unlit)) * 100))
        /// The display's light, whatever the camera's exposure: the lit places over the unlit ones
        func light(_ cells: [Double]) -> Double { log(average(cells, lit) / average(cells, unlit)) }

        for step in steps where step.display == display {
            let settle = step.kind == .blackout ? 1.4 : 2.9
            let from = frames(from: step.time - 0.3, to: step.time).map { light($0.cells) }
            let to = frames(from: step.time + settle - 0.5, to: step.time + settle).map { light($0.cells) }
            guard !from.isEmpty, !to.isEmpty else { continue }
            let start = from.reduce(0, +) / Double(from.count), end = to.reduce(0, +) / Double(to.count)
            let curve = frames(from: step.time, to: step.time + settle).map { ($0.time - step.time, (light($0.cells) - start) / (end - start)) }
            func reach(_ fraction: Double) -> String {
                curve.first { $0.1 >= fraction }.map { String(format: "%4.0f", $0.0 * 1000) } ?? "   -"
            }
            print(String(format: "%@ (change %.3f): 10%% at %@ ms, 50%% at %@ ms, 90%% at %@ ms", step.name, end - start, reach(0.1), reach(0.5), reach(0.9)))
            print("  " + curve.prefix(40).map { String(format: "%.0f:%.2f", $0.0 * 1000, $0.1) }.joined(separator: " "))
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
