import AppKit
import IOKit

// The entry point of scripts/ddc-writes.sh's copy of Safelight: it presses the brightness keys and drags
// a slider for the first external monitor Safelight sets over DDC, and logs every value written to the
// monitor, when, and where its slider was. Only the monitor's own brightness changes, and it's put back
// where it was.

// Only IOKit (DDC) and CoreDisplay (where each display is in the I/O Registry) load, so there's no
// DisplayServices, color filter or appearance to change
func dlopen(_ path: UnsafePointer<CChar>!, _ mode: Int32) -> UnsafeMutableRawPointer! {
    let name = String(cString: path)
    return name.hasSuffix("/IOKit") || name.hasSuffix("/CoreDisplay") ? Darwin.dlopen(path, mode) : nil
}
/// Dims a display in software, as the Studio Display would be without DisplayServices
@discardableResult
func CGSetDisplayTransferByTable(_ display: CGDirectDisplayID, _ tableSize: UInt32, _ redTable: UnsafePointer<CGGammaValue>!, _ greenTable: UnsafePointer<CGGammaValue>!, _ blueTable: UnsafePointer<CGGammaValue>!) -> CGError {
    .success
}
func CGDisplayRestoreColorSyncSettings() {}
/// No permission, so no event tap catches the real keys: presses go to BrightnessKeys.shared.handlePress
func AXIsProcessTrustedWithOptions(_ options: CFDictionary?) -> Bool { false }

/// Each brightness written to the monitor, and when
struct Write { let time: TimeInterval; let value: Int }
var writes: [Write] = []
let writesLock = NSLock()
typealias TransferI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
let writeI2C = unsafeBitCast(Darwin.dlsym(Darwin.dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY), "IOAVServiceWriteI2C")!, to: TransferI2C.self)
/// The monitor's IOAVService, from Safelight's first write, to set it as its own buttons would
var monitorService: CFTypeRef?
let loggingWriteI2C: TransferI2C = { service, address, subaddress, data, length in
    monitorService = service
    let bytes = data.assumingMemoryBound(to: UInt8.self)
    // Length, "set VCP feature", brightness, the value (two bytes), checksum
    if length == 6 && bytes[1] == 0x03 && bytes[2] == 0x10 {
        writesLock.lock()
        writes.append(Write(time: ProcessInfo.processInfo.systemUptime, value: Int(bytes[3]) << 8 | Int(bytes[4])))
        writesLock.unlock()
    }
    return writeI2C(service, address, subaddress, data, length)
}
/// Hands Safelight's DDC code the logging write
func dlsym(_ handle: UnsafeMutableRawPointer?, _ symbol: UnsafePointer<CChar>) -> UnsafeMutableRawPointer? {
    String(cString: symbol) == "IOAVServiceWriteI2C" ? unsafeBitCast(loggingWriteI2C, to: UnsafeMutableRawPointer.self) : Darwin.dlsym(handle, symbol)
}

setlinebuf(stdout)
_ = NSApplication.shared
let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Timing DDC writes")
// The copy's own settings (the ddc-writes domain), emptied by the script
UserDefaults.standard.set(true, forKey: "adjustsDisplaysIndependently")
UserDefaults.standard.set(false, forKey: "isAutoMode")
/// Where Safelight's copy sees the pointer: over the monitor, once it's found
var fakePointer = NSPoint(x: -100_000, y: -100_000)
let controller = ColorController.shared

func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
func after(_ seconds: TimeInterval, _ block: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: block)
}

var monitor: Display!
var sliderLog: [(TimeInterval, Float)] = []
let sliderTimer = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
    if let monitor { sliderLog.append((now(), controller[brightnessOf: monitor.key])) }
}
RunLoop.main.add(sliderTimer, forMode: .common)

func press(_ isUp: Bool) {
    if !BrightnessKeys.shared.handlePress(isUp, false) { print("  (a key press wasn't taken)") }
}

/// Prints the writes since `start`, and the slider every 50 ms
func report(_ name: String, from start: TimeInterval) {
    writesLock.lock(); let taken = writes; writes = []; writesLock.unlock()
    let slider = sliderLog.filter { $0.0 >= start }
    sliderLog = []
    print("\n\(name): \(taken.count) writes")
    print("  ms:value   ", taken.map { String(format: "%4.0f:%-3d", ($0.time - start) * 1000, $0.value) }.joined(separator: " "))
    if taken.count > 2 {
        let gaps = zip(taken.dropFirst(), taken).map { ($0.time - $1.time) * 1000 }.sorted()
        print(String(format: "  between writes: shortest %.1f ms, median %.1f ms", gaps.first!, gaps[gaps.count / 2]))
    }
    print("  slider     ", stride(from: 0, to: slider.count, by: 6).map { String(format: "%4.0f:%.3f", (slider[$0].0 - start) * 1000, slider[$0].1) }.joined(separator: " "))
}

/// Waits for Safelight to find a monitor whose brightness it sets over DDC, with its slider where the monitor is
func waitForMonitor(_ tries: Int = 0) {
    if let found = controller.displays.first(where: { GammaManager.shared.setMonitor($0.id, to: controller[brightnessOf: $0.key], fading: false) }),
       let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == found.id }) {
        monitor = found
        fakePointer = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
        print("Display \(found.id) (\(found.name)) is a monitor set over DDC, at \(controller[brightnessOf: found.key])")
        after(0.5) { test() }
    } else if tries < 100 {
        after(0.1) { waitForMonitor(tries + 1) }
    } else {
        print("No external monitor answered over DDC")
        exit(1)
    }
}

func test() {
    let original = controller[brightnessOf: monitor.key]
    let maximum: Float = 100 // the Dell's, as most monitors'
    writesLock.lock(); writes = []; writesLock.unlock()

    // 1. One press of brightness down: a sixteenth
    let t1 = now()
    let target1 = ((original * 16 - 0.01).rounded(.up) - 1) / 16
    press(false)
    after(0.6) {
        report("One press of brightness down, \(original) to \(target1)", from: t1)
        // 2. Brightness down held: five more presses 83 ms apart, as macOS's key repeat sends them
        let t2 = now()
        for i in 0..<5 { after(Double(i) * 0.0833) { press(false) } }
        after(1.0) {
            report("Brightness down held for five more presses", from: t2)
            // 3. A press, then the slider held 60 ms in: the monitor is set back to where the slider stopped
            let t3 = now()
            press(false)
            after(0.06) {
                controller.isUserDraggingSlider = true
                after(0.3) {
                    controller.isUserDraggingSlider = false
                    report("A press, then the slider held 60 ms in", from: t3)
                    // 4. The slider dragged up by 0.4 over half a second, 120 moves a second
                    let t4 = now()
                    let from = controller[brightnessOf: monitor.key]
                    controller.isUserDraggingSlider = true
                    for i in 1...60 {
                        after(Double(i) / 120) { controller[brightnessOf: monitor.key] = min(from + 0.4 * Float(i) / 60, 1) }
                    }
                    after(0.7) {
                        controller.isUserDraggingSlider = false
                        report("The slider dragged up by 0.4 over 0.5 s", from: t4)
                        // 5. Back where it was, at once, as a click on the slider sets it
                        let t5 = now()
                        controller[brightnessOf: monitor.key] = original
                        after(0.3) {
                            report("The slider clicked back to \(original)", from: t5)
                            // 6. The monitor's own buttons move it, its slider follows once Safelight reads
                            // it, and a click back to where Safelight last set it sets it there again
                            let buttons = Int((original * maximum).rounded()) - 20
                            var packet: [UInt8] = [0x84, 0x03, 0x10, UInt8(buttons >> 8), UInt8(buttons & 0xFF)]
                            packet.append(packet.reduce(0x6E ^ 0x51, ^))
                            _ = writeI2C(monitorService!, 0x37, 0x51, &packet, UInt32(packet.count))
                            after(2.5) {
                                print("\nThe monitor's buttons set it to \(buttons), and its slider followed to \(controller[brightnessOf: monitor.key])")
                                let t6 = now()
                                controller[brightnessOf: monitor.key] = original
                                after(0.3) {
                                    report("The slider clicked back to \(original)", from: t6)
                                    GammaManager.shared.finishSettingMonitors()
                                    exit(0)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

waitForMonitor()
RunLoop.main.run()
