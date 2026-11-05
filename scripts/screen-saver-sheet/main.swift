// Draws Safelight's Screen Saver sheet as the Wallpaper window presents it, in the background, and writes
// a PNG of the sheet's window: Sheet <light|dark> <out.png> [choice]. The choice is the screen saver both
// appearances have (`saver:Drift`, `drawn:sequoia`, `screen-saver:automatic`…); without one, the sheet
// shows the screen saver macOS has. ORIGIN=x,y puts the window behind the sheet there, in AppKit's screen
// coordinates, as a Dark sheet's background takes a tint from the wallpaper behind it. GALLERY=1 draws the
// Wallpaper window instead.
import AppKit
import SwiftUI
setlinebuf(stdout)
let args = CommandLine.arguments
let isDark = args[1] == "dark"
let out = args[2]
if args.count > 3 {
    UserDefaults.standard.set(try! PropertyListEncoder().encode(ScreenSaverManager.Choices(light: args[3], dark: args[3])), forKey: "ScreenSaverChoices")
} else {
    UserDefaults.standard.removeObject(forKey: "ScreenSaverChoices")
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
WallpaperManager.shared.refresh()
let origin = ProcessInfo.processInfo.environment["ORIGIN"].map { $0.split(separator: ",").map { CGFloat(Double($0)!) } } ?? [200, 200]
let parent = NSWindow(contentRect: NSRect(x: origin[0], y: origin[1], width: 508, height: 720), styleMask: [.titled, .closable], backing: .buffered, defer: false)
parent.title = SystemStrings.wallpaper
if ProcessInfo.processInfo.environment["GALLERY"] != nil {
    parent.contentView = NSHostingView(rootView: WallpaperGallery())
} else {
    // As SwiftUI presents it, with the bar at the bottom it draws for Done
    parent.contentView = NSHostingView(rootView: Color.clear.frame(width: 508, height: 720).sheet(isPresented: .constant(true)) { ScreenSaverSheet() })
}
parent.orderFrontRegardless()
typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
let createImage = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"), to: CreateImage.self)
// Once the thumbnails have loaded
DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
    let window = parent.attachedSheet ?? parent
    if let image = createImage(.null, 8, UInt32(window.windowNumber), 1)?.takeRetainedValue() {
        try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
        print("wrote", out, image.width, image.height)
    }
    exit(0)
}
app.run()
