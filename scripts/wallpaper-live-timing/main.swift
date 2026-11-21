import Cocoa

// Picks wallpapers on the real desktop, as the Wallpaper window's tiles do, and logs when each was
// picked and when macOS was asked to put it on each display, with the time of day to the millisecond,
// to set against WallpaperAgent's own log. scripts/wallpaper-live-timing.sh builds this together with
// a copy of Safelight.swift that calls `liveSet` before each request, and
// scripts/screenshots/NoSystemChanges.swift, runs it, and puts the desktop back.

setlinebuf(stdout)

let clock = DateFormatter()
clock.dateFormat = "HH:mm:ss.SSS"
func liveLog(_ what: String) {
    print("\(clock.string(from: Date()))  \(what)")
}

/// Called by the copy of Safelight.swift before each request to macOS
func liveSet(_ file: URL, _ screen: NSScreen, _ options: [NSWorkspace.DesktopImageOptionKey: Any]) {
    let onAllSpaces = options.first { $0.key.rawValue.contains("AllSpaces") }?.value as? Bool == true
    liveLog("set  \(WallpaperManager.uuid(of: screen)?.prefix(8) ?? "?")  \(onAllSpaces ? "all Spaces" : "shown Space")  \(file.deletingLastPathComponent().lastPathComponent.prefix(8))")
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Timing wallpapers on the desktop")

let manager = WallpaperManager.shared
let items = WallpaperLibrary.shared.sections.flatMap { $0.items + ($0.row ?? []) }
// The appearance the Mac has, so the picture picked is the one on the desktop
let isDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"

for screen in NSScreen.screens {
    liveLog("display  \(WallpaperManager.uuid(of: screen)?.prefix(8) ?? "?")  \(screen.localizedName)")
}

/// Pictures that are on every Mac or already on this one, outside other apps' containers, each with
/// its picture for Light and its picture for Dark: four pictures that all look different
let pictures: [(id: String, appearance: WallpaperManager.AppearanceOption)] = [
    ("picture:Sonoma", .light), ("picture:Ventura Graphic", .light), ("picture:Sonoma", .dark), ("picture:Ventura Graphic", .dark),
]
var picked = 0
func pick(_ label: String) {
    let picture = pictures[picked % pictures.count]
    picked += 1
    guard let item = items.first(where: { $0.id == picture.id }) else {
        liveLog("no wallpaper \(picture.id)")
        return
    }
    liveLog("pick  \(label)  \(picture.id) \(picture.appearance.rawValue)")
    manager.choose(item, isDark: isDark, options: WallpaperManager.PictureOptions(appearance: picture.appearance))
}

func at(_ time: TimeInterval, _ block: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + time, execute: block)
}

// One to start from, then on every Space, as a Mac with Show on all Spaces on has it
at(0.5) { pick("start") }
at(4) {
    liveLog("Show on all Spaces on")
    manager.setShowsOnAllSpaces(true)
}
// One at a time, each with time for every Space to have it
at(14) { pick("alone 1") }
at(24) { pick("alone 2") }
at(34) { pick("alone 3") }
// One after the other, as when trying wallpapers
at(44) { pick("in a row 1") }
at(45.5) { pick("in a row 2") }
at(47) { pick("in a row 3") }
at(58) {
    liveLog("end")
    exit(0)
}
app.run()
