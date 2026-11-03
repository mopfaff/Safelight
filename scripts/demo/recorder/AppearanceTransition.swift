import Cocoa

// How the screen changes over from one appearance to the other as macOS does it, when Safelight sets it
// the way System Settings does (`AppearanceManager.setDark`), for the recorder to log on each frame and
// scripts/demo/compose.py to draw. Read from macOS 27.2's code (3 November 2026):
//
// 1. `+[NSGlobalPreferenceTransition transition]` (AppKit) calls SkyLight's
//    `SLSCopyBeginGlobalPreferenceTransitionCompletionBlock`, which asks the window server to begin a
//    transition and waits for its answer. The window server has AquaAppearanceHelper
//    (SkyLight.framework/Resources/AquaAppearanceHelper.app) put a window over each display, in a
//    Space of its own above everything (`NSLocalGlobalPreferenceTransition`), holding a picture of the
//    display as it is (`-[NSGlobalPreferenceTransitionOverlay initOnScreen:]`: SLDisplayCreateImage as
//    the contents of a plain CALayer), and only then answers. So from then on, the screen shows that
//    picture, whatever the apps draw underneath; the pointer, which no picture of a display has, stays
//    on top.
// 2. The app sets the theme without telling anyone (`SLSSetAppearanceThemeNotifying(theme, false)`), then
//    `-postChangeNotification:completionHandler:` posts the change to every app at once
//    (`SLSPostCoordinatedDistributedNotification`, 0.5 s to answer), and AppKit in each redraws its
//    windows in the new appearance, under the picture. Once all have answered, or 0.5 s has gone by,
//    its completion block lets go of the transition (AquaAppearanceHelper watches for that, and gives up
//    waiting after 1 s anyway) and calls the app's completion handler.
// 3. AquaAppearanceHelper then fades the picture out (`-[NSGlobalPreferenceTransitionOverlay
//    endPresentation]`): its layer's opacity to 0 in a CATransaction of `NSGlobalPreferenceTransitionDuration`,
//    0.5 s unless set, which isn't, as an implicit animation, whose timing is Core Animation's default
//    curve (`CALayerCreateImplicitAnimation`: kCAMediaTimingFunctionDefault, 0.25, 0.1, 0.25, 1).
//
// Filmed on this Mac (Studio Display, 3 November 2026, scripts/demo/check.py switch: four switches, Light
// to Dark and back twice, with Safelight's Light/Dark wallpaper on the desktop): the begin call held the
// app 64–75 ms; the change's completion came 503–530 ms after it was posted (the 0.5 s AppKit gives the
// apps had run out every time); a square of window background seen through the picture followed Core
// Animation's default curve over 0.5 s, blended in encoded values (closer than in light on all four),
// from 489–548 ms after the post; the wallpaper dissolved linearly in 1.97–2.01 s, its channels in step
// (so in encoded values too), from 320–400 ms after the post going to Dark, 205–301 ms going to Light.
// The film caught a picture every ~50 ms at best during the change, so these times are ±25 ms.
//
// The wallpaper changes over to its picture for the new appearance by itself, once it's told of the change,
// read from macOS 27.2's wallpaper code (3 November 2026, version 313.1.14): WallpaperAgent hears
// `AppleInterfaceThemeChangedNotification` (WallpaperFoundation's SystemAppearanceObserver, on the main
// queue, with no delay), passes it on as a change of properties only to WallpaperImageExtension, whose
// DynamicWallpaper (`apple_desktop:apr`) sets its image layer to the other picture
// (`setCurrentIndex(_:animated: true)`): the layer's `contents`, in a CATransaction of 2 s with the
// linear timing function, so an implicit animation dissolves the old picture into the new one, each
// channel (1 − p) · old + p · new, p = t / 2 s. Nothing waits on purpose; logs had it begin ~35 ms after
// the notification when the picture for the other appearance was rendered already, 1.4–1.6 s after when
// it had to be rendered first (a wallpaper never shown in that appearance yet). See `wallpaper(at:from:)`.

/// AppKit's `NSGlobalPreferenceTransition` as the recorder's copy of Safelight sees it
/// (`NSClassFromString` in RecordedSystem.swift): it notes when the screen's picture is taken and when
/// the change is posted, has the app change its appearance as AppKit would on being told, and calls the
/// completion handler when macOS would, all on the scene's clock, which the main queue runs on while a
/// shot is recorded (Interposers.c)
final class RecordedPreferenceTransition: NSObject {
    /// Changes the app's appearance, as AppKit does when it's told of the change; set by the recorder
    static var changeAppAppearance: ((_ isDark: Bool) -> Void)?
    /// The scene's time now, in seconds from its first frame, and how many frames have been drawn; set
    /// by the recorder
    static var now: () -> Double = { 0 }
    static var framesDrawn = 0

    @objc class func transition() -> RecordedPreferenceTransition {
        RecordedSystem.record("SLSCopyBeginGlobalPreferenceTransitionCompletionBlock")
        guard framesDrawn > 0 else { fail("The appearance changes before the first frame, which the screen's picture would be of") }
        AppearanceTransition.all.append(AppearanceTransition(began: now(), snapshotFrame: framesDrawn - 1))
        return RecordedPreferenceTransition()
    }

    /// Posted as soon as the transition has begun, which holds the app for `AppearanceTransition.beginning`
    /// while AquaAppearanceHelper puts up the picture. The scene's clock doesn't move on during that, so
    /// the post counts from then, and the app hears of the change and is called back that much later.
    @objc(postChangeNotification:completionHandler:)
    func postChangeNotification(_ notification: UInt, completionHandler: @escaping @convention(block) () -> Void) {
        RecordedSystem.record("SLSPostCoordinatedDistributedNotification", Double(notification))
        guard let transition = AppearanceTransition.all.last else { fail("The appearance change was posted without a transition begun") }
        let isDark = RecordedSystem.theme == 1
        let posted = max(Self.now(), transition.began + AppearanceTransition.beginning)
        AppearanceTransition.all[AppearanceTransition.all.count - 1].posted = posted
        AppearanceTransition.all[AppearanceTransition.all.count - 1].isDark = isDark
        // AppKit hears of it on the main thread, once what's running there now is done
        let wait = posted - Self.now()
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { Self.changeAppAppearance?(isDark) }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait + AppearanceTransition.answered) { completionHandler() }
    }
}

/// One change of appearance, on the scene's clock, in seconds from its first frame
struct AppearanceTransition {
    /// When the screen's picture was taken, and the frame it's of: the one drawn last before then
    var began: Double
    var snapshotFrame: Int
    /// When the change was posted to every app, and to which appearance
    var posted: Double?
    var isDark = false

    static var all: [AppearanceTransition] = []

    /// How long the begin call holds the app, as AquaAppearanceHelper puts up the picture: filmed 64–75 ms
    static let beginning: Double = 0.068
    /// How long after the change is posted the completion comes, every app having answered that it's
    /// redrawn or the 0.5 s AppKit gives them having run out: filmed 503–530 ms
    static let answered: Double = 0.514
    /// How long after the change is posted the screen's picture begins to fade: filmed 489–548 ms
    static let fadeDelay: Double = 0.524
    /// How long the picture takes to fade out (`NSGlobalPreferenceTransitionDuration`'s default)
    static let fadeDuration: Double = 0.5

    /// How much of the screen's picture shows over what's under it at `time`: all of it from when it's
    /// taken till it begins to fade, then less and less along Core Animation's default curve
    func pictureOpacity(at time: Double) -> Double {
        guard time >= began else { return 0 }
        guard let posted else { return 1 }
        let fading = (time - posted - Self.fadeDelay) / Self.fadeDuration
        return fading <= 0 ? 1 : fading >= 1 ? 0 : 1 - Self.defaultTiming(fading)
    }

    /// How far the wallpaper is from its picture for Light (0) to its picture for Dark (1) at `time`,
    /// having been at `start` before any change: dissolving linearly to the new appearance's picture
    /// over `wallpaperDuration`, from `wallpaperDelay` after the change is posted
    static func wallpaper(at time: Double, from start: Double) -> Double {
        var value = start
        for transition in all {
            let delay = transition.isDark ? wallpaperDelayToDark : wallpaperDelayToLight
            guard let posted = transition.posted, time > posted + delay else { continue }
            let target = transition.isDark ? 1.0 : 0.0
            let progress = min((time - posted - delay) / wallpaperDuration, 1)
            value += (target - value) * progress
        }
        return value
    }

    /// The wallpaper's dissolve: 2 s (WallpaperFoundation's image layer), from when the change is posted,
    /// with its picture for the other appearance rendered already (shown in it before): filmed 320–400 ms
    /// going to Dark, 205–301 ms going to Light. The first time a wallpaper's shown in an appearance, its
    /// picture is rendered first, and it began ~1.2 s after the post.
    static let wallpaperDelayToDark: Double = 0.36
    static let wallpaperDelayToLight: Double = 0.25
    static let wallpaperDuration: Double = 2

    /// Core Animation's default timing curve, kCAMediaTimingFunctionDefault: the cubic Bézier with
    /// control points (0.25, 0.1) and (0.25, 1)
    static func defaultTiming(_ x: Double) -> Double {
        func point(_ a: Double, _ b: Double, _ s: Double) -> Double { 3 * a * s * (1 - s) * (1 - s) + 3 * b * s * s * (1 - s) + s * s * s }
        var (low, high) = (0.0, 1.0)
        for _ in 0..<60 {
            let middle = (low + high) / 2
            if point(0.25, 0.25, middle) < x { low = middle } else { high = middle }
        }
        return point(0.1, 1, (low + high) / 2)
    }
}
