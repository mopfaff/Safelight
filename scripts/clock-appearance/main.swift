// Draws Safelight's Clock Appearance… popover in the background and writes a PNG of it, as it lies on the
// screen: Clock popover <light|dark> <out.png>, or Clock gallery <light|dark> <out.png> for the Wallpaper
// window, whose Clock Appearance… scripts/clock-appearance.sh presses through Accessibility.
//   ORIGIN=x,y,w,h  the window, in AppKit's screen coordinates (popover: where System Settings' window is)
//   BACKDROP=png    popover: the window's picture (System Settings' window without its popover), which the
//                   popover's glass takes its colours from, as System Settings' does
//   ANCHOR=x,y,w,h  popover: the button it hangs from, in points from the window's top left
//   FONT=soft…rail, WEIGHT=0…1, LARGE=0…2  the clock to show, instead of macOS's
import AppKit
import SwiftUI
setlinebuf(stdout)
let args = CommandLine.arguments
let mode = args[1], isDark = args[2] == "dark", out = args[3]
let environment = ProcessInfo.processInfo.environment
func numbers(_ key: String) -> [CGFloat]? {
    environment[key].map { $0.split(separator: ",").map { CGFloat(Double($0)!) } }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Drawing the popover")
WallpaperManager.shared.refresh()
let clock = LockScreenClock.shared
if let font = environment["FONT"].flatMap(ClockFont.init(rawValue:)) { clock.setFont(font) }
if let weight = environment["WEIGHT"].flatMap(Double.init) { clock.setNormalizedWeight(weight) }

let frame = numbers("ORIGIN") ?? [200, 200, 508, 720]
let window: NSWindow
if mode == "gallery" {
    window = NSWindow(contentRect: NSRect(x: frame[0], y: frame[1], width: 508, height: 720), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = SystemStrings.wallpaper
    window.contentView = NSHostingView(rootView: WallpaperGallery())
} else {
    window = NSWindow(contentRect: NSRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3]), styleMask: [.borderless], backing: .buffered, defer: false)
    let anchor = numbers("ANCHOR") ?? [200, 100, 145.5, 24]
    let backdrop = environment["BACKDROP"].flatMap { NSImage(contentsOfFile: $0) }
    backdrop?.size = NSSize(width: frame[2], height: frame[3])
    window.backgroundColor = .clear
    window.contentView = NSHostingView(rootView: ZStack(alignment: .topLeading) {
        if let backdrop {
            Image(nsImage: backdrop)
        }
        Color.clear
            .frame(width: anchor[2], height: anchor[3])
            .popover(isPresented: .constant(true), arrowEdge: .bottom) {
                ClockAppearancePopover()
            }
            .offset(x: anchor[0], y: anchor[1])
    }
    .frame(width: frame[2], height: frame[3], alignment: .topLeading))
}
window.orderFrontRegardless()

typealias CreateImage = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
let createImage = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray"), to: CreateImage.self)
/// The app's windows as they lie on the screen, the popover over the window, cut to the popover's frame
/// (or the window's and the popover's together, for the gallery)
func capture() {
    let windows = NSApp.windows.filter { $0.isVisible }.sorted { $0.windowNumber == window.windowNumber ? false : $1.windowNumber == window.windowNumber }
    let popover = windows.first { $0 !== window }
    var rect = popover?.frame ?? window.frame
    if mode == "gallery" { rect = rect.union(window.frame) }
    let screenHeight = NSScreen.screens[0].frame.height
    let cgRect = CGRect(x: rect.minX, y: screenHeight - rect.maxY, width: rect.width, height: rect.height)
    let numbers = windows.map { UnsafeRawPointer(bitPattern: UInt($0.windowNumber)) } as [UnsafeRawPointer?]
    let array = numbers.withUnsafeBufferPointer { CFArrayCreate(nil, UnsafeMutablePointer(mutating: $0.baseAddress), $0.count, nil)! }
    if let image = createImage(cgRect, array, 1)?.takeRetainedValue() {
        try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
        print("wrote", out, image.width, image.height, "popover at", popover.map { NSStringFromRect($0.frame) } ?? "none")
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + (Double(environment["DELAY"] ?? "") ?? 3)) {
    capture()
    exit(0)
}
app.run()
_ = activity
