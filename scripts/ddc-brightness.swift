#!/usr/bin/xcrun swift
// Reads, or sets, the brightness of external monitors over DDC/CI, as Safelight does, to check what
// Safelight has set a monitor to, or to set one back after a test.
//
//   scripts/ddc-brightness.swift              each external display's brightness, as its monitor has it
//   scripts/ddc-brightness.swift 3 60         sets display 3 (its CGDirectDisplayID) to 60, then reads it
//
// Only on Apple silicon. A display with nothing to send DDC/CI through, or whose monitor doesn't
// answer, says so.

import AppKit
import IOKit

typealias CreateService = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
typealias TransferI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)!
let createService = unsafeBitCast(dlsym(iokit, "IOAVServiceCreateWithService")!, to: CreateService.self)
let writeI2C = unsafeBitCast(dlsym(iokit, "IOAVServiceWriteI2C")!, to: TransferI2C.self)
let readI2C = unsafeBitCast(dlsym(iokit, "IOAVServiceReadI2C")!, to: TransferI2C.self)
let coreDisplay = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)!
let displayInfo = unsafeBitCast(dlsym(coreDisplay, "CoreDisplay_DisplayCreateInfoDictionary")!,
                                to: (@convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?).self)

/// Each external display's IOAVService, by its framebuffer's place in the I/O Registry, which its
/// DCPAVServiceProxy comes after
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

func send(_ message: [UInt8], to service: CFTypeRef) {
    var packet = [0x80 | UInt8(message.count)] + message
    packet.append(packet.reduce(0x6E ^ 0x51, ^))
    _ = writeI2C(service, 0x37, 0x51, &packet, UInt32(packet.count))
}

/// The monitor's brightness, read with no subaddress and then with 0x51 as one, as Safelight reads it
func brightness(of service: CFTypeRef) -> (current: Int, maximum: Int)? {
    for attempt in 0..<4 {
        send([0x01, 0x10], to: service)
        usleep(50_000)
        var reply = [UInt8](repeating: 0, count: 11)
        if readI2C(service, 0x37, attempt.isMultiple(of: 2) ? 0 : 0x51, &reply, 11) == kIOReturnSuccess,
           reply[2] == 0x02, reply[3] == 0, reply[4] == 0x10, reply[..<10].reduce(UInt8(0x50), ^) == reply[10] {
            return (Int(reply[8]) << 8 | Int(reply[9]), Int(reply[6]) << 8 | Int(reply[7]))
        }
        usleep(20_000)
    }
    return nil
}

var count: UInt32 = 0
CGGetOnlineDisplayList(0, nil, &count)
var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
CGGetOnlineDisplayList(count, &displays, &count)
let services = externalServices()
let arguments = CommandLine.arguments.dropFirst().compactMap { Int($0) }

for display in displays where CGDisplayIsBuiltin(display) == 0 {
    if arguments.count == 2 && arguments[0] != Int(display) { continue }
    let info = displayInfo(display)?.takeRetainedValue() as NSDictionary?
    let name = (info?["DisplayProductName"] as? [String: String])?["en_US"] ?? "Display"
    guard let location = info?["IODisplayLocation"] as? String, let service = services[location] else {
        print("\(display) \(name): nothing to send DDC/CI through")
        continue
    }
    if arguments.count == 2 {
        let value = UInt16(clamping: arguments[1])
        send([0x03, 0x10, UInt8(value >> 8), UInt8(value & 0xFF)], to: service)
        usleep(100_000)
    }
    if let brightness = brightness(of: service) {
        print("\(display) \(name): \(brightness.current) of \(brightness.maximum)")
    } else {
        print("\(display) \(name): doesn't answer")
    }
}
