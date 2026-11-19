// The storyboard's document window: a real AppKit window with a text document in it (a title bar, a
// scroll view, an NSTextView with rich text), pictured by the window server with its shadow, in Light and
// in Dark, for scripts/demo/storyboard.py to put on the desktop of its stills. It stands in for the real
// app's window the re-shoot will have on the desktop (TextEdit's, say): what it's for is a page of white
// and text, so a tint can be told from another wallpaper.
//
//   DocumentWindow <folder> <width> <height>     writes window-light.png and window-dark.png: the window with
//                                                its shadow, as far as that reaches, in the display's colours,
//                                                see-through round it (storyboard.py finds the window in the
//                                                picture by where it's solid)
//
// The window is never the key or main one (this isn't an app with a Dock icon, and it isn't activated), so
// it should have the look of a window in the background, as a document's window has while Safelight's
// popover is open: Safelight activates itself to show it. It's put with only its top left point on the
// Retina display, at that display's bottom right corner, where its corner is rounded away: the window
// server draws it at that display's scale, and nothing of it shows but, for half a second, the faint edge
// of its shadow. The window server gives a picture of it all the same, asked for the window's own bounds
// (asked for a rectangle of the screen's coordinates there, it gave an empty picture).
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 4, let width = Double(arguments[2]), let height = Double(arguments[3]) else {
    FileHandle.standardError.write("Usage: DocumentWindow <folder> <width> <height>\n".data(using: .utf8)!)
    exit(2)
}
let folder = URL(fileURLWithPath: arguments[1])

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

/// A window that stays where it's put, though that's off the screen
final class PlacedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The document: a heading and a few paragraphs, large, as a page zoomed in to read
func document() -> NSAttributedString {
    let text = NSMutableAttributedString()
    func paragraph(_ string: String, size: CGFloat, weight: NSFont.Weight, colour: NSColor, before: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = before
        style.lineHeightMultiple = 1.12
        text.append(NSAttributedString(string: string + "\n", attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: colour,
                                                                               .paragraphStyle: style]))
    }
    paragraph("Under the safelight", size: 68, weight: .bold, colour: .textColor, before: 0)
    paragraph("Notes from the darkroom", size: 30, weight: .medium, colour: .linkColor, before: 6)
    paragraph("A safelight is the one lamp a darkroom allows. Its light is a deep red or amber, a colour the paper on the bench can’t see, so a print can lie " +
              "open under it for minutes and stay white until the developer brings the picture up.",
              size: 30, weight: .regular, colour: .textColor, before: 34)
    paragraph("Eyes get used to it sooner than you’d think. After a quarter of an hour the room no longer looks red, only dim, and the white of the paper " +
              "looks white again.", size: 30, weight: .regular, colour: .textColor, before: 22)
    paragraph("Bright white light is what’s kept out: one moment of it and every sheet in the open box is grey.", size: 30, weight: .regular, colour: .textColor,
              before: 22)
    paragraph("The same goes for a screen late at night. White is the light that wakes you; under a deep red, dimmed, the page is still there to read and " +
              "the room stays dark.", size: 30, weight: .regular, colour: .textColor, before: 22)
    paragraph("To do: fix the timer · order paper · print the hill photographs", size: 26, weight: .regular, colour: .secondaryLabelColor, before: 34)
    return text
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

guard let screen = NSScreen.screens.first(where: { $0.backingScaleFactor == 2 }) else { fail("The window is pictured at a Retina display's scale, and there's none") }
let createImage: @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { fail("There's no CGWindowListCreateImage") }
    return unsafeBitCast(symbol, to: (@convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?).self)
}()

func picture(_ name: NSAppearance.Name, then done: @escaping () -> Void) {
    // Its top left point on the display's bottom right one
    let frame = NSRect(x: screen.frame.maxX - 1, y: screen.frame.minY + 1 - height, width: width, height: height)
    let window = PlacedWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: name)
    window.title = "Under the safelight"
    window.isReleasedWhenClosed = false
    window.ignoresMouseEvents = true
    window.setFrame(frame, display: false)
    let scroll = NSTextView.scrollableTextView()
    scroll.hasVerticalScroller = false
    scroll.frame = window.contentLayoutRect
    scroll.autoresizingMask = [.width, .height]
    let textView = scroll.documentView as! NSTextView
    textView.isEditable = false
    textView.isSelectable = false
    textView.textContainerInset = NSSize(width: 70, height: 56)
    textView.backgroundColor = .textBackgroundColor
    textView.textStorage?.setAttributedString(document())
    window.contentView = scroll
    window.orderBack(nil)
    window.display()
    guard window.frame == frame else { fail("The window was moved to \(window.frame) from \(frame)") }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        guard window.backingScaleFactor == 2 else { fail("The window is at \(window.backingScaleFactor)x, not the Retina display's") }
        // The window with its shadow, as far as that reaches (a rectangle given in screen coordinates comes
        // back empty where it's off every display)
        let includingWindow: UInt32 = 1 << 3, bestResolution: UInt32 = 1 << 3
        let image = createImage(.null, includingWindow, UInt32(window.windowNumber), bestResolution)?.takeRetainedValue()
        window.orderOut(nil)
        guard let image, image.width >= Int(frame.width) * 2, image.height >= Int(frame.height) * 2 else { fail("Couldn't take the window server's picture of the window") }
        let url = folder.appendingPathComponent(name == .darkAqua ? "window-dark.png" : "window-light.png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { fail("Couldn't write \(url.path)") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { fail("Couldn't write \(url.path)") }
        done()
    }
}

try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
// A moment after starting: the first window of an app that has only just started was drawn as the main one
DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
    picture(.aqua) {
        picture(.darkAqua) { exit(0) }
    }
}
app.run()
