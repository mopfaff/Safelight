import Foundation
import CoreGraphics
import ApplicationServices

// Stand-ins for every function Safelight changes the Mac with, as scripts/screenshots/NoSystemChanges.swift
// has, but these keep a Mac of their own: the recorder's copy of Safelight.swift reads the scene's
// settings from them and writes its changes to them, so the screen and the settings are left as they
// were, and each change the app would make is recorded as it's made (`RecordedSystem.calls`).
// Declared in the recorder's own module, they're the ones the copy calls instead of the system's.
// scripts/make-demo.sh checks the built app has no way left to call the system's.

/// The Mac the recorder's copy of Safelight sees, and what it's asked to change
enum RecordedSystem {
    /// MediaAccessibility's Color Filters settings: the switch and filter type of category 1 (Color),
    /// and Color Tint's hue (0...1) and intensity
    static var colorFilterEnabled = false
    static var colorFilterType = 16
    static var hue = 0.0
    static var intensity = 1.0
    /// SkyLight's appearance theme: 0 Light, 1 Dark
    static var theme: Int32 = 0
    static var switchesAutomatically = false
    /// Each display's brightness as DisplayServices has it, for the ones it sets the brightness of
    static var hardwareBrightness: [CGDirectDisplayID: Float] = [:]
    /// Each display's gamma table as Safelight last set it, by the value it gives white: its software
    /// dimming. None while the displays have their own colours.
    static var gammaTables: [CGDirectDisplayID: [CGGammaValue]] = [:]

    /// A call the app made to change the system, in the order made
    struct Call: Encodable {
        let function: String
        let arguments: [Double]
    }
    static var calls: [Call] = []

    fileprivate static func record(_ function: String, _ arguments: Double...) {
        calls.append(Call(function: function, arguments: arguments))
    }

    /// The displays DisplayServices sets the brightness of: Apple's own, as the built-in display and
    /// the Studio Display are. Other displays are dimmed in software, as the Dell is.
    static func hasHardwareBrightness(_ display: CGDirectDisplayID) -> Bool {
        CGDisplayIsBuiltin(display) != 0 || CGDisplayVendorNumber(display) == 0x610
    }
}

/// Where each framework Safelight loads is, by the made-up handle `dlopen` gives for it
private let frameworks: [String: Int] = [
    "/System/Library/Frameworks/MediaAccessibility.framework/MediaAccessibility": 1,
    "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices": 2,
    "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight": 3,
]

/// MediaAccessibility, DisplayServices and SkyLight are given handles of their own, which `dlsym`
/// answers with the stand-ins below. CoreDisplay (which displays get a dark layer rather than dimming
/// in software, as Sidecar's iPad does) and SidecarCore aren't loaded, so every display is dimmed in
/// software or by DisplayServices, and no dark window ever covers a real one.
func dlopen(_ path: UnsafePointer<CChar>!, _ mode: Int32) -> UnsafeMutableRawPointer! {
    frameworks[String(cString: path)].flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
}

/// MediaAccessibility's limits for Color Tint's intensity on macOS 27, `kMADisplayFilterPrefSingleColorIntensityMin`
/// and `Max`, as read from it
private let intensityRange: UnsafeMutablePointer<Double> = {
    let range = UnsafeMutablePointer<Double>.allocate(capacity: 2)
    range.initialize(from: [0.25, 1.0], count: 2)
    return range
}()

func dlsym(_ handle: UnsafeMutableRawPointer!, _ symbol: UnsafePointer<CChar>!) -> UnsafeMutableRawPointer! {
    let name = String(cString: symbol)
    func function<T>(_ body: T) -> UnsafeMutableRawPointer { unsafeBitCast(body, to: UnsafeMutableRawPointer.self) }
    switch (Int(bitPattern: handle), name) {
    // The color filter
    case (1, "MADisplayFilterPrefGetCategoryEnabled"):
        return function({ category in category == 1 && RecordedSystem.colorFilterEnabled } as @convention(c) (Int) -> Bool)
    case (1, "MADisplayFilterPrefSetCategoryEnabled"):
        return function({ category, isEnabled in
            RecordedSystem.record("MADisplayFilterPrefSetCategoryEnabled", Double(category), isEnabled ? 1 : 0)
            if category == 1 { RecordedSystem.colorFilterEnabled = isEnabled }
        } as @convention(c) (Int, Bool) -> Void)
    case (1, "MADisplayFilterPrefGetType"):
        return function({ category in category == 1 ? RecordedSystem.colorFilterType : 0 } as @convention(c) (Int) -> Int)
    case (1, "MADisplayFilterPrefSetType"):
        return function({ category, type in
            RecordedSystem.record("MADisplayFilterPrefSetType", Double(category), Double(type))
            if category == 1 { RecordedSystem.colorFilterType = type }
        } as @convention(c) (Int, Int) -> Void)
    case (1, "MADisplayFilterPrefGetSingleColorHue"):
        return function({ RecordedSystem.hue } as @convention(c) () -> Double)
    case (1, "MADisplayFilterPrefSetSingleColorHue"):
        return function({ hue in
            RecordedSystem.record("MADisplayFilterPrefSetSingleColorHue", hue)
            RecordedSystem.hue = hue
        } as @convention(c) (Double) -> Void)
    case (1, "MADisplayFilterPrefGetSingleColorIntensity"):
        return function({ RecordedSystem.intensity } as @convention(c) () -> Double)
    case (1, "MADisplayFilterPrefSetSingleColorIntensity"):
        return function({ intensity in
            RecordedSystem.record("MADisplayFilterPrefSetSingleColorIntensity", intensity)
            RecordedSystem.intensity = intensity
        } as @convention(c) (Double) -> Void)
    case (1, "kMADisplayFilterPrefSingleColorIntensityMin"):
        return UnsafeMutableRawPointer(intensityRange)
    case (1, "kMADisplayFilterPrefSingleColorIntensityMax"):
        return UnsafeMutableRawPointer(intensityRange + 1)

    // Brightness
    case (2, "DisplayServicesCanChangeBrightness"):
        return function({ display in RecordedSystem.hasHardwareBrightness(display) } as @convention(c) (CGDirectDisplayID) -> Bool)
    case (2, "DisplayServicesGetBrightness"):
        return function({ display, brightness in
            guard let value = RecordedSystem.hardwareBrightness[display] else { return 1 }
            brightness?.pointee = value
            return 0
        } as @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>?) -> Int32)
    case (2, "DisplayServicesSetBrightness"):
        return function({ display, brightness in
            guard RecordedSystem.hasHardwareBrightness(display) else { return 1 }
            RecordedSystem.record("DisplayServicesSetBrightness", Double(display), Double(brightness))
            RecordedSystem.hardwareBrightness[display] = brightness
            return 0
        } as @convention(c) (CGDirectDisplayID, Float) -> Int32)

    // The appearance
    case (3, "SLSGetAppearanceThemeLegacy"):
        return function({ RecordedSystem.theme } as @convention(c) () -> Int32)
    case (3, "SLSSetAppearanceThemeNotifying"):
        return function({ theme, notifies in
            RecordedSystem.record("SLSSetAppearanceThemeNotifying", Double(theme), notifies ? 1 : 0)
            RecordedSystem.theme = theme
        } as @convention(c) (Int32, Bool) -> Void)
    case (3, "SLSGetAppearanceThemeSwitchesAutomatically"):
        return function({ RecordedSystem.switchesAutomatically } as @convention(c) () -> Bool)
    case (3, "SLSSetAppearanceThemeSwitchesAutomatically"):
        return function({ switches in
            RecordedSystem.record("SLSSetAppearanceThemeSwitchesAutomatically", switches ? 1 : 0)
            RecordedSystem.switchesAutomatically = switches
        } as @convention(c) (Bool) -> Void)

    // Nothing else is there, so the app does without it
    default:
        return nil
    }
}

/// Dims a display in software
@discardableResult
func CGSetDisplayTransferByTable(_ display: CGDirectDisplayID, _ tableSize: UInt32, _ redTable: UnsafePointer<CGGammaValue>!, _ greenTable: UnsafePointer<CGGammaValue>!, _ blueTable: UnsafePointer<CGGammaValue>!) -> CGError {
    let table = Array(UnsafeBufferPointer(start: redTable, count: Int(tableSize)))
    RecordedSystem.record("CGSetDisplayTransferByTable", Double(display), Double(table.last ?? 1))
    RecordedSystem.gammaTables[display] = table
    return .success
}

/// Puts back every display's colors
func CGDisplayRestoreColorSyncSettings() {
    RecordedSystem.record("CGDisplayRestoreColorSyncSettings")
    RecordedSystem.gammaTables = [:]
}

/// Every display that's connected, whether it's awake or not: the system's list leaves out the ones
/// that are asleep, so the app would set no brightness and its slider would start at 1 when the Mac had
/// left its displays to sleep while recording. The scene's displays are always awake.
func CGGetActiveDisplayList(_ maxDisplays: UInt32, _ activeDisplays: UnsafeMutablePointer<CGDirectDisplayID>?, _ displayCount: UnsafeMutablePointer<UInt32>?) -> CGError {
    CGGetOnlineDisplayList(maxDisplays, activeDisplays, displayCount)
}

/// Without System Settings' fade (`NSGlobalPreferenceTransition`), which tells every app on the Mac the
/// appearance has changed and fades the whole screen, the appearance is set the plain way, through the
/// SkyLight stand-in above
func NSClassFromString(_ aClassName: String) -> AnyClass? {
    aClassName == "NSGlobalPreferenceTransition" ? nil : Foundation.NSClassFromString(aClassName)
}

/// The brightness keys need Accessibility permission, which the recorder never has or asks for, so it
/// never catches the real keys
func AXIsProcessTrustedWithOptions(_ options: CFDictionary?) -> Bool {
    false
}
