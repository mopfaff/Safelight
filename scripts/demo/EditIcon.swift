import AppKit

// Writes Safelight's icon as macOS draws an app's, 1024 pixels across, in Display P3, into the file given,
// for the demo edit's end card (scripts/demo/edit.py). scripts/make-demo.sh --edit builds it into an app
// with Safelight's icon, compiled from Safelight/AppIcon.icon, as only an app's own icon is drawn this
// large: the .icns stops at 256. Only an app macOS can open gets its own icon; one it can't is drawn
// with a no-entry sign over it, so the app is signed and registered first.

guard CommandLine.arguments.count == 2 else {
    print("error: give the file to write")
    exit(2)
}
guard Bundle.main.bundlePath.hasSuffix(".app") else {
    print("error: run from the app scripts/make-demo.sh --edit builds, which has Safelight's icon")
    exit(2)
}
let size = 1024
guard let space = CGColorSpace(name: CGColorSpace.displayP3),
      let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    print("error: couldn't make a picture to draw in")
    exit(1)
}
context.interpolationQuality = .high
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath).draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
    print("error: couldn't write \(url.path)")
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    print("error: couldn't write \(url.path)")
    exit(1)
}
