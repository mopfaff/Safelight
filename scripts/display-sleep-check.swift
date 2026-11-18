#!/usr/bin/xcrun swift
// Puts the displays to sleep for a few seconds and wakes them, to see what a display sleep does to what
// Safelight sets: whether a monitor keeps its brightness and answers DDC/CI while asleep, when it
// answers again after waking and whether a write then sticks, whether a gamma table set before is still
// there after, and whether the displays are reconfigured (disconnected and connected again) on the way.
//
//   scripts/display-sleep-check.swift [seconds asleep, 10 by default]
//
// The screens go dark meanwhile, so only run it when the Mac's user says so. It doesn't lock the Mac
// unless the Mac locks when its displays sleep. Each monitor gets its brightness back at the end, and
// the gamma tables go back when the script exits.
//
// While asleep, each monitor is read. Once awake, it's read until it answers, then written its
// brightness less 30 at once, and read every half second for six seconds.

import AppKit
import IOKit

setlinebuf(stdout)
let start = Date()
func log(_ message: String) {
    print(String(format: "%6.2f  ", Date().timeIntervalSince(start)) + message)
}

// MARK: DDC/CI, as in ddc-brightness.swift

typealias CreateService = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
typealias TransferI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)!
let createService = unsafeBitCast(dlsym(iokit, "IOAVServiceCreateWithService")!, to: CreateService.self)
let writeI2C = unsafeBitCast(dlsym(iokit, "IOAVServiceWriteI2C")!, to: TransferI2C.self)
let readI2C = unsafeBitCast(dlsym(iokit, "IOAVServiceReadI2C")!, to: TransferI2C.self)
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
        default:
            break
        }
    }
    IOObjectRelease(iterator)
    return services
}

@discardableResult
func send(_ message: [UInt8], to service: CFTypeRef) -> IOReturn {
    var packet = [0x80 | UInt8(message.count)] + message
    packet.append(packet.reduce(0x6E ^ 0x51, ^))
    return writeI2C(service, 0x37, 0x51, &packet, UInt32(packet.count))
}

func brightness(of service: CFTypeRef) -> Int? {
    for attempt in 0..<4 {
        send([0x01, 0x10], to: service)
        usleep(50_000)
        var reply = [UInt8](repeating: 0, count: 11)
        if readI2C(service, 0x37, attempt.isMultiple(of: 2) ? 0 : 0x51, &reply, 11) == kIOReturnSuccess,
           reply[2] == 0x02, reply[3] == 0, reply[4] == 0x10, reply[..<10].reduce(UInt8(0x50), ^) == reply[10] {
            return Int(reply[8]) << 8 | Int(reply[9])
        }
        usleep(20_000)
    }
    return nil
}

func setBrightness(_ value: Int, of service: CFTypeRef) -> IOReturn {
    let value = UInt16(clamping: value)
    return send([0x03, 0x10, UInt8(value >> 8), UInt8(value & 0xFF)], to: service)
}

// MARK: Displays

func onlineDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &displays, &count)
    return displays
}

func name(of display: CGDirectDisplayID) -> String {
    let info = displayInfo(display)?.takeRetainedValue() as NSDictionary?
    return (info?["DisplayProductName"] as? [String: String])?["en_US"] ?? "Display \(display)"
}

struct Monitor {
    let display: CGDirectDisplayID
    let name: String
    let service: CFTypeRef
    let brightness: Int
}

let services = externalServices()
let monitors: [Monitor] = onlineDisplays().compactMap { display in
    let info = displayInfo(display)?.takeRetainedValue() as NSDictionary?
    guard let location = info?["IODisplayLocation"] as? String, let service = services[location],
          let brightness = brightness(of: service) else { return nil }
    return Monitor(display: display, name: name(of: display), service: service, brightness: brightness)
}

/// A gamma table that keeps 95% of the picture, slight enough not to be noticed for the few seconds
/// it's seen
let testScale: CGGammaValue = 0.95
let testTable = (0..<256).map { CGGammaValue($0) / 255 * testScale }

func gammaState(of display: CGDirectDisplayID) -> String {
    var red = [CGGammaValue](repeating: 0, count: 256), green = red, blue = red
    var count: UInt32 = 0
    guard CGGetDisplayTransferByTable(display, 256, &red, &green, &blue, &count) == .success, count > 0 else { return "no table" }
    let top = red[Int(count) - 1]
    if abs(top - testScale) < 0.002 { return "test table kept (top \(String(format: "%.3f", top)))" }
    if abs(top - 1) < 0.002 { return "table reset (top \(String(format: "%.3f", top)))" }
    return "other table (top \(String(format: "%.3f", top)))"
}

func asleep() -> String {
    onlineDisplays().map { "\(name(of: $0)) \(CGDisplayIsAsleep($0) != 0 ? "asleep" : "awake")" }.joined(separator: ", ")
}

for monitor in monitors {
    log("\(monitor.name) (display \(monitor.display)) answers DDC/CI, brightness \(monitor.brightness)")
}
let displays = onlineDisplays()
log("displays: " + displays.map { "\($0) \(name(of: $0))" }.joined(separator: ", "))

// MARK: Watching

CGDisplayRegisterReconfigurationCallback({ display, flags, _ in
    var names: [String] = []
    let all: [(CGDisplayChangeSummaryFlags, String)] = [(.beginConfigurationFlag, "begin"), (.addFlag, "add"), (.removeFlag, "remove"),
        (.enabledFlag, "enabled"), (.disabledFlag, "disabled"), (.setModeFlag, "setMode"), (.movedFlag, "moved"),
        (.setMainFlag, "setMain"), (.mirrorFlag, "mirror"), (.unMirrorFlag, "unMirror"), (.desktopShapeChangedFlag, "desktopShape")]
    for (flag, name) in all where flags.contains(flag) { names.append(name) }
    log("reconfiguration: display \(display) \(names.joined(separator: " "))")
}, nil)

let workspace = NSWorkspace.shared.notificationCenter
var notifications = 0
for notification in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
    workspace.addObserver(forName: notification, object: nil, queue: .main) { note in
        log("notification: \(note.name.rawValue)")
    }
}
NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
    log("notification: didChangeScreenParameters")
}

// MARK: The check

let secondsAsleep = Double(CommandLine.arguments.dropFirst().first ?? "") ?? 10
let ddcQueue = DispatchQueue(label: "ddc")

func run(_ command: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command)
    process.arguments = arguments
    try? process.run()
}

func gammaStates() -> String {
    displays.map { "\(name(of: $0)): \(gammaState(of: $0))" }.joined(separator: ", ")
}

func readMonitors() -> String {
    monitors.map { "\($0.name) DDC \(brightness(of: $0.service).map(String.init) ?? "no answer")" }.joined(separator: ", ")
}

func finish() {
    ddcQueue.async {
        for monitor in monitors {
            _ = setBrightness(monitor.brightness, of: monitor.service)
            usleep(200_000)
            log("\(monitor.name) set back to \(monitor.brightness), reads \(brightness(of: monitor.service).map(String.init) ?? "no answer")")
        }
        exit(0)
    }
}

/// Once a monitor answers after waking, it's written its brightness less 30 at once, and read every
/// half second for six seconds
func afterWake(_ wokeAt: Date) {
    ddcQueue.async {
        func since() -> String { String(format: "+%.2f s after waking: ", Date().timeIntervalSince(wokeAt)) }
        for monitor in monitors {
            var first: Int?
            while first == nil, Date().timeIntervalSince(wokeAt) < 15 {
                first = brightness(of: monitor.service)
                log(since() + "\(monitor.name) DDC \(first.map(String.init) ?? "no answer")")
            }
            guard first != nil else { continue }
            let result = setBrightness(monitor.brightness - 30, of: monitor.service)
            log(since() + "\(monitor.name) written \(monitor.brightness - 30), returned \(String(format: "0x%x", result))")
        }
        for _ in 0..<12 {
            usleep(500_000)
            let reads = readMonitors()
            DispatchQueue.main.sync { log(since() + reads + "; " + gammaStates() + "; " + asleep()) }
        }
        DispatchQueue.main.async { finish() }
    }
}

// The test table, set while awake as Safelight sets one
for display in displays {
    CGSetDisplayTransferByTable(display, 256, testTable, testTable, testTable)
}
log("test gamma tables set: " + gammaStates())

DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    log("putting the displays to sleep")
    run("/usr/bin/pmset", ["displaysleepnow"])
}

DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + secondsAsleep / 2) {
    log("while asleep: " + asleep() + "; " + gammaStates())
    ddcQueue.async {
        let reads = readMonitors()
        log("while asleep: " + reads)
    }
}

// Woken by declaring the user active, and seen to be awake by asking each display every 50 ms, as well
// as by the notification
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + secondsAsleep) {
    log("waking the displays")
    run("/usr/bin/caffeinate", ["-u", "-t", "2"])
    let asked = Date()
    Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
        if displays.allSatisfy({ CGDisplayIsAsleep($0) == 0 }) {
            timer.invalidate()
            log(String(format: "every display awake, %.2f s after asking", Date().timeIntervalSince(asked)))
            afterWake(Date())
        } else if Date().timeIntervalSince(asked) > 30 {
            timer.invalidate()
            log("the displays didn't wake within 30 s")
            finish()
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.run()
