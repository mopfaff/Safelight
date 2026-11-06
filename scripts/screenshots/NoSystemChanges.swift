import Foundation
import CoreGraphics

// Stand-ins for every function Safelight changes the Mac with. Declared in the screenshot app's own
// module, they're the ones its copy of Safelight.swift calls instead of the system's, so drawing the
// screenshots leaves the color filter, brightness and appearance as they were.
// scripts/screenshots.sh checks the built app has no way left to call the system's.

/// Safelight loads MediaAccessibility (the color filter), DisplayServices (brightness), CoreDisplay
/// (which displays it dims under a dark layer), IOKit's IOAVService functions (external monitors'
/// brightness, over DDC) and SkyLight (the appearance) this way; with none of them, it can neither read
/// nor change any of those settings, lays no dark layer over a display, and shows whatever the
/// screenshot app sets it to.
func dlopen(_ path: UnsafePointer<CChar>!, _ mode: Int32) -> UnsafeMutableRawPointer! {
    nil
}

/// Dims a display in software
@discardableResult
func CGSetDisplayTransferByTable(_ display: CGDirectDisplayID, _ tableSize: UInt32, _ redTable: UnsafePointer<CGGammaValue>!, _ greenTable: UnsafePointer<CGGammaValue>!, _ blueTable: UnsafePointer<CGGammaValue>!) -> CGError {
    .success
}

/// Puts back every display's colors, which would undo the dimming of a Safelight that's running
func CGDisplayRestoreColorSyncSettings() {}
