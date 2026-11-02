import SwiftUI
import Cocoa
import ApplicationServices
import Foundation // Required for dynamic library loading
import ServiceManagement
import UniformTypeIdentifiers
import AVFoundation // For the aerials' pictures
import Metal // For Macintosh and Sequoia, drawn as macOS draws them
import MetalKit
import ModelIO
import simd
import Photos // For the Photos library's albums, which Add Photo… offers to shuffle
import PhotosUI
import QuickLookThumbnailing // For thumbnails of large pictures, as System Settings makes them
#if canImport(Sparkle) // Not in scripts/screenshots.sh's copy, which leaves updates out
import Sparkle
#endif

// MARK: - 1. App Entry Point
@main
struct SafelightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - 2. App Delegate (Menu Bar Logic)
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover = NSPopover()
    #if canImport(Sparkle)
    private let updates = Updates()
    #endif
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if canImport(Sparkle)
        // First, as it may quit to open the installed copy instead
        Updates.leaveTranslocation()
        updates.start()
        // Closed first like Customize…, so Sparkle's window isn't left behind it
        updates.willCheckForUpdates = { [weak self] in self?.popover.performClose(nil) }
        #endif

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            // The app icon's dial, as a symbol drawn by scripts/make-icon.py
            let image = NSImage(named: "safelight.dial")
            image?.accessibilityDescription = SystemStrings.display
            button.image = image
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        
        popover.contentSize = NSSize(width: 320, height: 260)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuView(customizeSchedule: { [weak self] in
            self?.popover.performClose(nil)
            ScheduleWindow.shared.show()
        }, chooseWallpaper: { [weak self] isDark in
            self?.popover.performClose(nil)
            WallpaperWindow.shared.show(isDark: isDark)
        }, options: { [weak self] in
            self?.optionItems() ?? []
        }))
        // So the wallpaper's pictures are there the first time the popover opens, and the names of System
        // Settings' wallpapers they're from
        WallpaperManager.shared.refresh()
        DispatchQueue.global(qos: .utility).async {
            _ = WallpaperLibrary.shared
        }
        // Shuffles that change at login do now, and the others carry on where they were
        WallpaperShuffler.shared.resume()
    }
    
    /// A click opens the popover; a right-click or Control-click opens the menu instead.
    @objc func statusItemClicked(_ sender: AnyObject?) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
        } else {
            togglePopover(sender)
        }
    }
    
    private func showMenu() {
        popover.performClose(nil)
        
        let menu = NSMenu()
        menu.items = optionItems()
        
        // Attached only while it's open, so a plain click still reaches the popover.
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }
    
    /// The status item's menu, which the ⋯ button in the popover's corner opens too. Made each time
    /// it opens, as Open at Login can also be changed in System Settings › General › Login Items.
    func optionItems() -> [NSMenuItem] {
        let about = NSMenuItem(title: SystemStrings.aboutApp, action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        let openAtLogin = NSMenuItem(title: SystemStrings.openAtLogin, action: #selector(toggleOpenAtLogin(_:)), keyEquivalent: "")
        openAtLogin.target = self
        openAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
        var items = [about, .separator(), openAtLogin]
        #if canImport(Sparkle)
        items += updates.menuItems
        #endif
        #if DEBUG
        let scheduleLayout = NSMenuItem(title: "Schedule Layout…", action: #selector(showScheduleLayout(_:)), keyEquivalent: "")
        scheduleLayout.target = self
        let controlColors = NSMenuItem(title: "Control Colours…", action: #selector(showControlColors(_:)), keyEquivalent: "")
        controlColors.target = self
        items += [.separator(), scheduleLayout, controlColors]
        #endif
        let quit = NSMenuItem(title: SystemStrings.quitApp, action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        return items + [.separator(), quit]
    }
    
    /// AppKit's About panel, with the version and the copyright line from Info.plist, and the credits
    @objc private func showAbout(_ sender: NSMenuItem) {
        // Closed first like Customize…, so the panel isn't left behind it
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        // The build number is only there for Sparkle, so it isn't shown, as "1.0 (2)" would be
        NSApp.orderFrontStandardAboutPanel(options: [.credits: Self.credits, .version: ""])
    }
    
    /// Links to the source code, its issues and GitHub Sponsors, as the README has, one to a line so
    /// none breaks in two. Sparkle's licence, which asks to come with every copy of it, comes in the
    /// app's resources as Sparkle License.txt instead.
    private static var credits: NSAttributedString {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let credits = NSMutableAttributedString()
        let links = [
            (SystemStrings.sourceCode, "https://github.com/mopfaff/Safelight"),
            (SystemStrings.reportAnIssue, "https://github.com/mopfaff/Safelight/issues"),
            ("GitHub Sponsors", "https://github.com/sponsors/mopfaff"),
        ]
        for (title, url) in links {
            if credits.length > 0 {
                credits.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            }
            credits.append(NSAttributedString(string: title, attributes: [.font: font, .link: URL(string: url)!]))
        }
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))
        return credits
    }
    
    @objc private func toggleOpenAtLogin(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Safelight: couldn't change Open at Login: \(error)")
        }
        // The user turned it off in Login Items before; only they can allow it again there.
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
    
    #if DEBUG
    @objc private func showScheduleLayout(_ sender: NSMenuItem) {
        ScheduleLayoutWindow.shared.show()
    }

    // The popover opens beside the panel too, after the menu has closed, so its controls can be seen
    // changing
    @objc private func showControlColors(_ sender: NSMenuItem) {
        ControlColorsWindow.shared.show()
        DispatchQueue.main.async {
            if !self.popover.isShown { self.togglePopover(nil) }
        }
    }
    #endif

    @objc func quit(_ sender: Any?) {
        ColorController.shared.reset()
        NSApplication.shared.terminate(nil)
    }
    
    @objc func togglePopover(_ sender: AnyObject?) {
        if let button = statusItem?.button {
            if popover.isShown {
                popover.performClose(sender)
            } else {
                #if DEBUG
                // While the Control Colours panel is open, clicking in it leaves the popover open
                popover.behavior = ControlColorsWindow.shared.isVisible ? .semitransient : .transient
                #endif
                // With Show on all Spaces off, the wallpaper of the display it opens on, whose menu bar
                // was clicked. It may have been changed in System Settings since.
                if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) {
                    WallpaperManager.shared.selectDisplay(WallpaperManager.uuid(of: screen))
                }
                WallpaperManager.shared.refresh()
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Ensure software dimming is cleared when the app is force-quit
        GammaManager.shared.reset()
        // With Sequoia's looks through the day for Light on the desktop, which only Safelight takes off in Dark
        WallpaperManager.shared.putOwnFileBack()
    }
}

// MARK: - Updates
#if canImport(Sparkle)
/// Keeps Safelight up to date with Sparkle, from the feed in Info.plist. With Automatic Updates on, as
/// it is to begin with, it looks at the latest GitHub release once a day, downloads anything newer in
/// the background, and installs it the next time Safelight quits, so an update never resets the screen
/// while it's in use. It installs only a disk image signed with the key whose public half is in
/// Info.plist (SUPublicEDKey); scripts/release.sh signs each one.
final class Updates: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate, NSMenuItemValidation {
    private var controller: SPUStandardUpdaterController!
    /// Called when Check for Updates… is chosen, before Sparkle's window opens
    var willCheckForUpdates: () -> Void = {}

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    }

    /// Starts checking, once Safelight knows it isn't about to reopen from elsewhere.
    func start() {
        controller.startUpdater()
    }

    /// macOS runs an app that isn't notarized from a hidden, read-only copy of itself (App
    /// Translocation) for as long as it has the quarantine flag it was downloaded with, even once the
    /// user has allowed it with Open Anyway and copied it into Applications. Sparkle can't replace that
    /// copy, so Safelight would never update. So when it starts that way, it takes the flag off the
    /// copy that's installed, as Sparkle does with each update it installs, and opens that one
    /// instead. From a disk image, which is read-only, it carries on as it is.
    static func leaveTranslocation() {
        // In the Security framework, which AppKit has loaded already, but not in its public headers
        typealias IsTranslocatedURL = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> DarwinBoolean
        typealias CreateOriginalPathForURL = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let loaded = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let isTranslocatedURL = dlsym(loaded, "SecTranslocateIsTranslocatedURL").map({ unsafeBitCast($0, to: IsTranslocatedURL.self) }),
              let createOriginalPathForURL = dlsym(loaded, "SecTranslocateCreateOriginalPathForURL").map({ unsafeBitCast($0, to: CreateOriginalPathForURL.self) })
        else { return }

        let running = Bundle.main.bundleURL as CFURL
        var isTranslocated = false
        guard isTranslocatedURL(running, &isTranslocated, nil).boolValue, isTranslocated,
              let installed = createOriginalPathForURL(running, nil)?.takeRetainedValue() as URL?,
              removexattr(installed.path, "com.apple.quarantine", XATTR_NOFOLLOW) == 0
        else { return }
        if let files = FileManager.default.enumerator(at: installed, includingPropertiesForKeys: nil) {
            for case let file as URL in files {
                removexattr(file.path, "com.apple.quarantine", XATTR_NOFOLLOW)
            }
        }

        // Opened once this copy has quit, so the two never run at once
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        reopen.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open \"$2\"",
                            "sh", String(getpid()), installed.path]
        if (try? reopen.run()) != nil {
            exit(0)
        }
    }

    /// For the status item's menu: the Automatic Updates switch, and Check for Updates…, which looks
    /// right away and shows what it finds.
    var menuItems: [NSMenuItem] {
        let automaticUpdates = NSMenuItem(title: SystemStrings.automaticUpdates, action: #selector(toggleAutomaticUpdates(_:)), keyEquivalent: "")
        automaticUpdates.target = self
        automaticUpdates.state = isAutomatic ? .on : .off
        let checkForUpdates = NSMenuItem(title: SystemStrings.checkForUpdates, action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        checkForUpdates.target = self
        return [automaticUpdates, checkForUpdates]
    }

    @objc private func checkForUpdates(_ sender: NSMenuItem) {
        willCheckForUpdates()
        controller.checkForUpdates(sender)
    }

    /// Check for Updates… is dimmed while Sparkle is checking already, as it is when it targets Sparkle
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(checkForUpdates(_:)) || controller.updater.canCheckForUpdates
    }

    /// Sparkle keeps checking and installing as two settings; the switch is on when both are. Sparkle's
    /// own update window can turn installing off by itself.
    private var isAutomatic: Bool {
        controller.updater.automaticallyChecksForUpdates && controller.updater.automaticallyDownloadsUpdates
    }

    /// Off, Safelight looks for updates only when asked to. Sparkle only changes installing while
    /// checking is on, so installing goes off first and on second.
    @objc private func toggleAutomaticUpdates(_ sender: NSMenuItem) {
        let updater = controller.updater
        if isAutomatic {
            updater.automaticallyDownloadsUpdates = false
            updater.automaticallyChecksForUpdates = false
        } else {
            updater.automaticallyChecksForUpdates = true
            updater.automaticallyDownloadsUpdates = true
        }
    }

    #if DEBUG
    /// A Debug build only looks when asked: an update it found by itself would replace the build being
    /// worked on with the release when it quits, and scripts/run.sh would then launch that instead.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if updateCheck == .updatesInBackground {
            throw CocoaError(.userCancelled)
        }
    }
    #endif

    /// Safelight has no Dock icon, so Sparkle shows an update it found by itself behind the app in use
    /// rather than taking the focus from it. Saying that's all right keeps Sparkle from warning about it.
    var supportsGentleScheduledUpdateReminders: Bool { true }
}
#endif

// MARK: - 3. UI (Menu View)
struct MenuView: View {
    @ObservedObject var controller = ColorController.shared
    let customizeSchedule: () -> Void
    /// Opens the Wallpaper window to choose the wallpaper's picture for Dark, or for Light
    let chooseWallpaper: (_ isDark: Bool) -> Void
    /// The status item's menu, for the ⋯ button
    let options: () -> [NSMenuItem]
    
    var body: some View {
        VStack(spacing: 20) {
            
            // --- AUTO TOGGLE ---
            HStack {
                Text(SystemStrings.schedule)
                    .fontWeight(.medium)
                Spacer()
                Button(action: customizeSchedule) {
                    Label(SystemStrings.customize, systemImage: "gearshape")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(SystemStrings.customize)
                Toggle(SystemStrings.schedule, isOn: $controller.isAutoMode)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            
            Divider()

            // The slider labels share one column, as wide as the longest of them in the system language.
            Grid(alignment: .leading, verticalSpacing: 16) {
                // --- COLOR FILTER SECTION ---
                // These drive System Settings › Accessibility › Display › Color Filters (Color Tint).
                // 1. ON/OFF (the "Color filters" switch)
                GridRow {
                    HStack {
                        Text(SystemStrings.colorFilters)
                            .fontWeight(.medium)
                        Spacer()
                        Toggle(SystemStrings.colorFilters, isOn: $controller.isColorFilterOn)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .controlTint(hue: controller.tint, for: .colorFiltersSwitch)
                            .disabled(controller.isAutoMode)
                    }
                    .gridCellColumns(2)
                }

                // 2. INTENSITY
                GridRow(alignment: .top) {
                    Text(SystemStrings.intensity)
                        .fontWeight(.medium)
                        .frame(minWidth: 75, alignment: .leading)
                        .padding(.top, 4)

                    intensitySlider
                        .controlTint(hue: controller.tint, for: .intensitySlider)
                        .disabled(controller.isAutoMode)
                }

                // 3. TINT
                GridRow {
                    Text(SystemStrings.tint)
                        .fontWeight(.medium)
                        .frame(minWidth: 75, alignment: .leading)

                    TintSlider(value: $controller.tint)
                        .disabled(controller.isAutoMode)
                        .opacity(controller.isAutoMode ? 0.6 : 1.0)
                }

                Divider()
                    .padding(.vertical, 4)

                // --- BRIGHTNESS SECTION ---
                // This drives System Settings › Displays' Brightness: one slider for every display, or
                // while they're adjusted independently, one for each, under its name.
                if controller.independentDisplays.isEmpty {
                    GridRow {
                        Text(SystemStrings.brightness)
                            .fontWeight(.medium)
                            .frame(minWidth: 75, alignment: .leading)

                        brightnessSlider(value: $controller.brightness)
                    }
                } else {
                    GridRow(alignment: .firstTextBaseline) {
                        Text(SystemStrings.brightness)
                            .fontWeight(.medium)
                            .frame(minWidth: 75, alignment: .leading)

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(controller.independentDisplays) { display in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(display.name)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    brightnessSlider(value: $controller[brightnessOf: display.key])
                                }
                            }
                        }
                    }
                }

                // Only there with more than one display to adjust, unless it's on already
                if controller.displays.count > 1 || controller.adjustsDisplaysIndependently {
                    GridRow {
                        HStack {
                            Text(SystemStrings.adjustIndependently)
                                .fontWeight(.medium)
                            Spacer()
                            Toggle(SystemStrings.adjustIndependently, isOn: $controller.adjustsDisplaysIndependently)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .controlTint(Color(hue: 42 / 360, saturation: 0.55, brightness: 0.8).opacity(0.2), for: .adjustIndependentlySwitch)  // a muted gold
                        }
                        .gridCellColumns(2)
                    }
                }

                Divider()
                    .padding(.vertical, 4)

                // --- APPEARANCE SECTION ---
                // This drives System Settings › Appearance (Light and Dark).
                GridRow(alignment: .top) {
                    Text(SystemStrings.appearance)
                        .fontWeight(.medium)
                        .frame(minWidth: 75, alignment: .leading)

                    AppearancePicker(isDark: Binding(
                        get: { controller.isDarkAppearance },
                        set: { controller.chooseAppearance(isDark: $0) }
                    ))
                    .disabled(controller.isAutoMode || controller.isChangingAppearance)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }

                Divider()
                    .padding(.vertical, 4)

                // --- WALLPAPER SECTION ---
                // This sets System Settings › Wallpaper to a picture for Light and one for Dark, each
                // under the Appearance picker's thumbnail of the same name. macOS fades the desktop over
                // between them as the appearance changes, whatever changes it.
                GridRow(alignment: .top) {
                    Text(SystemStrings.wallpaper)
                        .fontWeight(.medium)
                        .frame(minWidth: 75, alignment: .leading)

                    WallpaperPicker(choosePicture: chooseWallpaper)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            Divider()

            // --- ACTION BUTTONS ---
            HStack {
                Button(SystemStrings.reset) {
                    controller.reset()
                }
                .buttonStyle(.bordered)

                Spacer()

                // Quit is in here, with the rest of the status item's menu, so it can be found
                // without a right-click
                OptionsButton(items: options)
                    .help(SystemStrings.options)
            }
        }
        .padding()
        .frame(width: 320)
        .animation(.easeInOut, value: controller.isAutoMode)
    }

    /// System Settings' Intensity slider: seven tick marks evenly spaced from end to end, with Low and
    /// High as the names of the first and last. Before macOS 26, which has no tick labels, Low and High
    /// go under the ends of a plain slider.
    @ViewBuilder
    private var intensitySlider: some View {
        let range = ColorFilterManager.shared.intensityRange
        if #available(macOS 26.0, *) {
            let spacing = (range.upperBound - range.lowerBound) / 6
            Slider(value: $controller.intensity, in: range) {
                Text(SystemStrings.intensity)
            } ticks: {
                SliderTick(SystemStrings.low, range.lowerBound)
                SliderTickContentForEach((1...5).map { range.lowerBound + spacing * Float($0) }, id: \.self) {
                    SliderTick($0)
                }
                SliderTick(SystemStrings.high, range.upperBound)
            }
            .labelsHidden()
        } else {
            VStack(spacing: 2) {
                Slider(value: $controller.intensity, in: range)

                HStack {
                    Text(SystemStrings.low).font(.system(size: 10)).foregroundColor(.secondary)
                    Spacer()
                    Text(SystemStrings.high).font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
        }
    }

    private func brightnessSlider(value: Binding<Float>) -> some View {
        Slider(
            value: value,
            in: 0.0...1.0,
            onEditingChanged: { isEditing in
                controller.isUserDraggingSlider = isEditing
            }
        )
        .controlTint(.white, hasShadow: true, for: .brightnessSliders)
        .disabled(controller.isAutoMode)
    }
}

// MARK: - Options Button
/// The ⋯ in the popover's corner: a pull-down, like Finder's Action button, that opens the status
/// item's menu under itself. It opens as the mouse goes down, and an item can be chosen by dragging to
/// it and letting go, as in any menu.
struct OptionsButton: NSViewRepresentable {
    let items: () -> [NSMenuItem]

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = Button(frame: .zero, pullsDown: true)
        button.isBordered = false
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        button.imagePosition = .imageOnly
        // The colour SwiftUI gives the gear button's icon
        button.contentTintColor = .secondaryLabelColor
        button.setAccessibilityLabel(SystemStrings.options)
        button.menu?.delegate = context.coordinator
        button.menu?.items = [Coordinator.titleItem()]
        return button
    }

    // Only as big as the ⋯, so it lines up with the edge as Quit did. A pop-up button takes all the
    // width it's offered, and asks for room round its image besides.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        nsView.image?.size ?? nsView.intrinsicContentSize
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.items = items
    }

    /// Without the 5 points a pop-up button keeps to the left of its bezel: borderless, it centres the
    /// ⋯ in its whole frame, which put it that much short of the edge
    final class Button: NSPopUpButton {
        override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }
    }

    final class Coordinator: NSObject, NSMenuDelegate {
        var items: () -> [NSMenuItem] = { [] }

        /// A pull-down shows its first item on the button, not in the menu
        static func titleItem() -> NSMenuItem {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: SystemStrings.options)
            return item
        }

        /// Made afresh each time it opens, as the status item's menu is
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.items = [Self.titleItem()] + items()
        }
    }
}

// MARK: - Tint Slider (System Settings' Hue Slider)
/// The control System Settings › Accessibility › Display uses for Color Tint's Tint slider (its
/// `HueSliderRepresentable`), set up the same way: a `HueSlider` over 0–360° with its track drawn as
/// a hue scale, and a single tick mark at 180° that the slider snaps to on its own, like any NSSlider
/// with tick marks.
struct TintSlider: NSViewRepresentable {
    @Binding var value: Float // degrees
    /// Like `Slider`'s: called with true when the slider is pressed, and with false when it's let go.
    var onEditingChanged: (Bool) -> Void = { _ in }

    /// `NSColorScaleSliderCell`'s scale type for a hue track.
    private static let hueScaleType = 7

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> HueSlider {
        let slider = HueSlider(
            value: 360, minValue: 0, maxValue: 360,
            target: context.coordinator, action: #selector(Coordinator.valueDidChange(_:))
        )
        slider.controlSize = .small
        slider.numberOfTickMarks = 1
        slider.allowsTickMarkValuesOnly = false
        slider.tickMarkPosition = .above
        slider.isContinuous = true
        slider.altIncrementValue = 1
        if let cell = slider.cell, cell.responds(to: NSSelectorFromString("setDrawsTrackAsColorScaleType:")) {
            cell.setValue(NSColor.red, forKey: "color")
            cell.setValue(Self.hueScaleType, forKey: "drawsTrackAsColorScaleType")
        }
        return slider
    }

    func updateNSView(_ slider: HueSlider, context: Context) {
        context.coordinator.valueDidChangeHandler = { value = Float($0) }
        slider.onEditingChanged = onEditingChanged
        slider.doubleValue = Double(value)
        slider.isEnabled = context.environment.isEnabled
    }

    final class Coordinator: NSObject {
        var valueDidChangeHandler: (Double) -> Void = { _ in }

        @objc func valueDidChange(_ sender: NSSlider) {
            valueDidChangeHandler(sender.doubleValue)
        }
    }
}

/// AppKit's `NSColorScaleSlider` (not in the public headers), rebuilt from its parts so it can say when
/// it's pressed and let go: that class is an NSSlider whose cell, `NSColorScaleSliderCell`, draws the
/// track and takes the settings the slider passes on, with these alignment insets. A plain slider
/// stands in if AppKit ever stops shipping the cell.
final class HueSlider: NSSlider {
    private static let colorScaleCellClass = NSClassFromString("NSColorScaleSliderCell") as? NSSliderCell.Type

    var onEditingChanged: (Bool) -> Void = { _ in }

    override class var cellClass: AnyClass? {
        get { colorScaleCellClass ?? super.cellClass }
        set { super.cellClass = newValue }
    }

    override var alignmentRectInsets: NSEdgeInsets {
        Self.colorScaleCellClass == nil ? super.alignmentRectInsets : NSEdgeInsets(top: 1, left: 1, bottom: 4, right: 1)
    }

    override func mouseDown(with event: NSEvent) {
        onEditingChanged(true)
        super.mouseDown(with: event) // tracks the mouse until it's let go
        onEditingChanged(false)
    }
}

// MARK: - Time Field
/// A time of day as hours and minutes in a field with a stepper, like `DatePicker`'s `.stepperField`
/// style, but with the time centred in the field: AppKit puts it 1.5 pt high, so the selected hour or
/// minute touches the top of the field.
struct TimeField: NSViewRepresentable {
    var label: String
    @Binding var selection: Date
    /// Whether the field takes the keyboard as soon as it's in a window, with its hours selected to type over
    var isFocusedOnAppear = false

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TimeFieldPicker {
        let picker = TimeFieldPicker()
        picker.becomesFirstResponderInWindow = isFocusedOnAppear
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .hourMinute
        // Only as wide as the time and its stepper, like DatePicker
        picker.setContentHuggingPriority(.required, for: .horizontal)
        picker.setContentHuggingPriority(.required, for: .vertical)
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.dateDidChange(_:))
        picker.setAccessibilityLabel(label)
        return picker
    }

    func updateNSView(_ picker: TimeFieldPicker, context: Context) {
        context.coordinator.dateDidChangeHandler = { selection = $0 }
        // Only the time zone is taken from the environment, as the picker's calendar, which it reads as
        // changed each time, selects the hours again whenever it's set
        if picker.timeZone != context.environment.timeZone {
            picker.timeZone = context.environment.timeZone
        }
        if picker.dateValue != selection {
            picker.dateValue = selection
        }
        picker.isEnabled = context.environment.isEnabled
    }

    final class Coordinator: NSObject {
        var dateDidChangeHandler: (Date) -> Void = { _ in }

        @objc func dateDidChange(_ sender: NSDatePicker) {
            dateDidChangeHandler(sender.dateValue)
        }
    }
}

/// A date picker set up as any other, field and all, but with a `TimeFieldCell`.
final class TimeFieldPicker: NSDatePicker {
    var becomesFirstResponderInWindow = false

    override class var cellClass: AnyClass? {
        get { TimeFieldCell.self }
        set { super.cellClass = newValue }
    }

    // SwiftUI puts the picker in the window while it updates the view, so the picker takes the keyboard
    // straight after, rather than make the field it takes it from end editing in the middle of the update
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard becomesFirstResponderInWindow, window != nil else { return }
        becomesFirstResponderInWindow = false
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
            self.needsDisplay = true // or its hours aren't shown selected until something else redraws it
            self.scrollToVisible(self.bounds) // in case the rows scroll
        }
    }
}

/// A date picker cell that draws its text and selection lower down, in the middle of its field.
/// AppKit only draws them along with the field, so the cell draws in three goes: a cell of its own
/// draws the field with no text, this cell draws its stepper, and then its text and selection without
/// the field, lower down. Clicks are still matched to the hours and minutes where AppKit puts them,
/// which is only 1.5 pt higher.
final class TimeFieldCell: NSDatePickerCell {
    private static let textDrop: CGFloat = 1.5
    /// The width AppKit gives the stepper at the right of the cell, which takes in the gap between it
    /// and the field
    private static let stepperWidth = NSStepperCell().cellSize.width

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        // Split where the stepper starts, with room all round, as AppKit draws a little past the frame
        let canvas = cellFrame.insetBy(dx: -cellFrame.width, dy: -cellFrame.height)
        let (stepperArea, fieldArea) = canvas.divided(atDistance: canvas.maxX - (cellFrame.maxX - Self.stepperWidth), from: .maxXEdge)

        let fieldCell = NSDatePickerCell()
        fieldCell.datePickerStyle = datePickerStyle
        fieldCell.datePickerElements = datePickerElements
        fieldCell.controlSize = controlSize
        fieldCell.font = font
        fieldCell.isEnabled = isEnabled
        fieldCell.isBezeled = isBezeled
        fieldCell.textColor = .clear
        draw(clippedTo: fieldArea) {
            fieldCell.draw(withFrame: cellFrame, in: controlView)
        }
        // The stepper is this cell's own, so it shows the arrow being pressed
        draw(clippedTo: stepperArea) {
            super.draw(withFrame: cellFrame, in: controlView)
        }
        // Without the field, which is put back straight after, before anything lays the cell out again
        let isBezeled = isBezeled
        self.isBezeled = false
        draw(clippedTo: fieldArea) {
            super.draw(withFrame: cellFrame.offsetBy(dx: 0, dy: controlView.isFlipped ? Self.textDrop : -Self.textDrop), in: controlView)
        }
        self.isBezeled = isBezeled
    }

    private func draw(clippedTo area: NSRect, _ drawing: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        area.clip()
        drawing()
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - Appearance Picker (System Settings' Appearance Thumbnails)
/// The Light and Dark of the picker in System Settings › Appearance (its `AppearanceThemePicker`, which
/// comes with Auto and can't be had without it), rebuilt from its parts: System Settings' thumbnails,
/// each over its shadow, with the highlight in it drawn in the accent colour, a ring in that colour around
/// the one that's chosen, and its name underneath. Disabled, it dims the way that picker does while the
/// appearance is changing.
struct AppearancePicker: View {
    @Binding var isDark: Bool

    private static let artwork = Bundle(path: SystemStrings.appearanceSettings)
    /// The Wallpaper picker's thumbnails are this size too, so they line up under these
    static let thumbnailSize = CGSize(width: 67, height: 44)
    static let thumbnailCornerRadius: CGFloat = 5

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            option(SystemStrings.light, thumbnail: "AppearanceLight", isDark: false)
            option(SystemStrings.dark, thumbnail: "AppearanceDark", isDark: true)
        }
    }

    private func option(_ name: String, thumbnail: String, isDark: Bool) -> some View {
        let isSelected = self.isDark == isDark
        return Button {
            self.isDark = isDark
        } label: {
            VStack(spacing: 1) {
                Group {
                    if let artwork = Self.artwork, artwork.image(forResource: thumbnail) != nil {
                        // Loaded by name: with `Image(nsImage:)` the picker's dimming takes 0.3 s longer to be over
                        ZStack {
                            Image(thumbnail, bundle: artwork)
                                .clipShape(RoundedRectangle(cornerRadius: Self.thumbnailCornerRadius))
                            Image("selectionColor_mask", bundle: artwork)
                                .renderingMode(.template)
                                .foregroundStyle(Color.accentColor)
                        }
                    } else {
                        // A plain window colour stands in if System Settings ever stops shipping the thumbnails
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(white: isDark ? 0.15 : 0.95))
                            .strokeBorder(.separator)
                    }
                }
                .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
                .padding(3.5)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
                // Around a thumbnail with no ring, and behind either of them when the picker is dimmed
                .shadow(color: .black.opacity(0.33), radius: isSelected ? 0 : 2)

                Text(name)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// A thumbnail scaled down to `height`, as an image for the Schedule window's `AppearanceSegments`:
    /// drawn as here, with its corners and the highlight in it in the accent colour, and redrawn each
    /// time it's shown, so it follows the accent colour. Its name is what VoiceOver reads for it.
    static func thumbnail(isDark: Bool, height: CGFloat) -> NSImage {
        let thumbnail = artwork?.image(forResource: isDark ? "AppearanceDark" : "AppearanceLight")
        let highlight = artwork?.image(forResource: "selectionColor_mask")
        let scale = height / thumbnailSize.height
        let size = NSSize(width: (thumbnailSize.width * scale).rounded(), height: height)

        let image = NSImage(size: size, flipped: false) { rect in
            let cornerRadius = cornerRadius(ofThumbnail: height)
            guard let thumbnail else {
                // The same plain window colour stands in
                let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
                NSColor(white: isDark ? 0.15 : 0.95, alpha: 1).setFill()
                outline.fill()
                NSColor.separatorColor.setStroke()
                outline.stroke()
                return true
            }
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).addClip()
            thumbnail.draw(in: rect)
            if let highlight, let context = NSGraphicsContext.current?.cgContext {
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                highlight.draw(in: rect)
                NSColor.controlAccentColor.setFill()
                rect.fill(using: .sourceAtop)
                context.endTransparencyLayer()
            }
            return true
        }
        image.accessibilityDescription = isDark ? SystemStrings.dark : SystemStrings.light
        return image
    }

    /// The radius of the corners of a thumbnail scaled down to `height`
    static func cornerRadius(ofThumbnail height: CGFloat) -> CGFloat {
        thumbnailCornerRadius * height / thumbnailSize.height
    }
}

/// Light and Dark for a keyframe in the Schedule window: a segmented control with the Appearance
/// picker's thumbnails in its segments. It's AppKit's own control rather than a segmented `Picker`,
/// whose segments leave 5 pt either side of an image, so the segments' widths can be set: each
/// thumbnail leaves `border` above and below it, and its segment is that much wider either side.
/// AppKit's selection would fill the chosen segment out to corners of its own, far rounder than the
/// thumbnail's, and right up to the thumbnail, hard to tell from the blue in it. So `Cell` draws the
/// control instead, as AppKit's own looks but with a thin ring around the chosen thumbnail, a gap
/// between them, and corners that follow the thumbnail's.
struct AppearanceSegments: NSViewRepresentable {
    @Binding var isDark: Bool

    private static let ringWidth: CGFloat = 2
    private static let gap: CGFloat = 1
    private static let border = ringWidth + gap
    /// The height of a segmented control, which each segment is
    private static let controlHeight = NSSegmentedControl(labels: [""], trackingMode: .selectOne, target: nil, action: nil).fittingSize.height
    private static let thumbnailHeight = controlHeight - 2 * border
    private static let thumbnails = [false, true].map { AppearancePicker.thumbnail(isDark: $0, height: thumbnailHeight) }
    private static let segmentWidths = thumbnails.map { $0.size.width + 2 * border }
    /// The corners of the track, the ring and a pressed segment, around the thumbnail's
    private static let cornerRadius = AppearancePicker.cornerRadius(ofThumbnail: thumbnailHeight) + border

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = Control(
            images: Self.thumbnails, trackingMode: .selectOne,
            target: context.coordinator, action: #selector(Coordinator.selectionDidChange(_:))
        )
        for (segment, width) in Self.segmentWidths.enumerated() {
            control.setWidth(width, forSegment: segment)
            control.setToolTip(segment == 1 ? SystemStrings.dark : SystemStrings.light, forSegment: segment)
        }
        control.setAccessibilityLabel(SystemStrings.appearance)
        return control
    }

    // The size is given rather than asked of the control. One made while SwiftUI is updating, as a
    // row added with + is, takes the widths set above only afterwards, and until then measures as if
    // its segments had their own widths (80 pt instead of 68 when it happened); once they arrive it
    // doesn't say its size has changed, so the row kept the wider frame, with the segments centred in
    // it, out of line.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: Self.segmentWidths.reduce(0, +), height: Self.controlHeight)
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selectionDidChangeHandler = { isDark = $0 }
        control.selectedSegment = isDark ? 1 : 0
        control.isEnabled = context.environment.isEnabled
    }

    final class Coordinator: NSObject {
        var selectionDidChangeHandler: (Bool) -> Void = { _ in }

        @objc func selectionDidChange(_ sender: NSSegmentedControl) {
            selectionDidChangeHandler(sender.selectedSegment == 1)
        }
    }

    final class Control: NSSegmentedControl {
        override class var cellClass: AnyClass? {
            get { Cell.self }
            set {}
        }
    }

    /// Draws the control in place of AppKit, which still handles clicks, keys, tooltips and VoiceOver.
    /// Its track, the pressed segment and the selection in a window that isn't key are the colours of
    /// AppKit's own on macOS 27, and disabled, the thumbnails and ring are half as opaque, as there.
    final class Cell: NSSegmentedCell {
        /// The segment under the pointer while the control is pressed, darker until it's let go,
        /// or until the pointer leaves the control
        private var pressedSegment: Int?

        override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
            NSColor.secondarySystemFill.setFill()
            NSBezierPath(roundedRect: cellFrame, xRadius: cornerRadius, yRadius: cornerRadius).fill()

            let context = NSGraphicsContext.current?.cgContext
            let isKey = controlView.window?.isKeyWindow ?? false
            for segment in 0..<segmentCount {
                guard let image = image(forSegment: segment) else { continue }
                let imageRect = imageRect(of: image, inSegment: segment, of: cellFrame)
                let outline = outline(around: imageRect)
                if segment == pressedSegment {
                    NSColor.labelColor.withAlphaComponent(0.16).setFill()
                    outline.fill()
                }

                // In a layer of its own, as drawing an image sets the context's alpha to its own
                context?.saveGState()
                context?.setAlpha(isEnabled ? 1 : 0.5)
                context?.beginTransparencyLayer(auxiliaryInfo: nil)
                if isSelected(forSegment: segment) {
                    let ringRect = imageRect.insetBy(dx: -border + ringWidth, dy: -border + ringWidth)
                    outline.append(NSBezierPath(roundedRect: ringRect, xRadius: cornerRadius - ringWidth, yRadius: cornerRadius - ringWidth))
                    outline.windingRule = .evenOdd
                    (isKey ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.12)).setFill()
                    outline.fill()
                }
                image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                context?.endTransparencyLayer()
                context?.restoreGState()
            }
        }

        // Around the segment the arrow keys are on, as AppKit's own is, but with the corners above.
        // AppKit only says which that is privately; without it, the ring is AppKit's own.
        override func drawFocusRingMask(withFrame cellFrame: NSRect, in controlView: NSView) {
            guard responds(to: NSSelectorFromString("_keySegment")), let segment = value(forKey: "_keySegment") as? Int,
                  (0..<segmentCount).contains(segment), let image = image(forSegment: segment) else {
                super.drawFocusRingMask(withFrame: cellFrame, in: controlView)
                return
            }
            outline(around: imageRect(of: image, inSegment: segment, of: cellFrame)).fill()
        }

        override func startTracking(at startPoint: NSPoint, in controlView: NSView) -> Bool {
            press(at: startPoint, in: controlView)
            return super.startTracking(at: startPoint, in: controlView)
        }

        override func continueTracking(last lastPoint: NSPoint, current currentPoint: NSPoint, in controlView: NSView) -> Bool {
            press(at: currentPoint, in: controlView)
            return super.continueTracking(last: lastPoint, current: currentPoint, in: controlView)
        }

        override func stopTracking(last lastPoint: NSPoint, current stopPoint: NSPoint, in controlView: NSView, mouseIsUp flag: Bool) {
            press(at: nil, in: controlView)
            super.stopTracking(last: lastPoint, current: stopPoint, in: controlView, mouseIsUp: flag)
        }

        private func press(at point: NSPoint?, in controlView: NSView) {
            let segment = point.flatMap { point in
                (0..<segmentCount).first { frame(ofSegment: $0, in: controlView.bounds).contains(point) }
            }
            if segment != pressedSegment {
                pressedSegment = segment
                controlView.needsDisplay = true
            }
        }

        private func frame(ofSegment segment: Int, in cellFrame: NSRect) -> NSRect {
            let x = (0..<segment).reduce(cellFrame.minX) { $0 + width(forSegment: $1) }
            return NSRect(x: x, y: cellFrame.minY, width: width(forSegment: segment), height: cellFrame.height)
        }

        /// A segment's thumbnail, in the middle of it
        private func imageRect(of image: NSImage, inSegment segment: Int, of cellFrame: NSRect) -> NSRect {
            let frame = frame(ofSegment: segment, in: cellFrame)
            return NSRect(x: frame.midX - image.size.width / 2, y: frame.midY - image.size.height / 2,
                          width: image.size.width, height: image.size.height)
        }

        /// A thumbnail and the border around it, which the ring and a pressed segment fill
        private func outline(around imageRect: NSRect) -> NSBezierPath {
            NSBezierPath(roundedRect: imageRect.insetBy(dx: -border, dy: -border), xRadius: cornerRadius, yRadius: cornerRadius)
        }
    }
}

// MARK: - Wallpaper Picker
/// The wallpaper's picture for Light and its picture for Dark, side by side like the Appearance picker's
/// thumbnails, and the same size, so each is under the thumbnail of the same name, with its corners and
/// the shadow of one that isn't chosen. Clicking one opens the Wallpaper window to choose its picture,
/// and pointing at one names the wallpaper it's from. A shuffle of System Settings' shows its thumbnail,
/// as System Settings does. While the wallpaper is one whose pictures Safelight can't tell, each is an
/// empty frame with a + in it. A picture chosen shows as soon as it's chosen, while it's made.
struct WallpaperPicker: View {
    @ObservedObject var wallpaper = WallpaperManager.shared
    let choosePicture: (_ isDark: Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            option(SystemStrings.light, picture: wallpaper.thumbnails?.light, isDark: false)
            option(SystemStrings.dark, picture: wallpaper.thumbnails?.dark, isDark: true)
        }
    }

    private func option(_ name: String, picture: WallpaperManager.Thumbnail?, isDark: Bool) -> some View {
        Button {
            choosePicture(isDark)
        } label: {
            VStack(spacing: 1) {
                Group {
                    if let picture {
                        DesktopThumbnail(thumbnail: picture, size: AppearancePicker.thumbnailSize)
                    } else {
                        Rectangle()
                            .fill(.quaternary)
                            .overlay {
                                Image(systemName: "plus")
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .frame(width: AppearancePicker.thumbnailSize.width, height: AppearancePicker.thumbnailSize.height)
                .clipShape(RoundedRectangle(cornerRadius: AppearancePicker.thumbnailCornerRadius))
                .padding(3.5) // where the Appearance picker has its ring
                .shadow(color: .black.opacity(picture == nil ? 0 : 0.33), radius: 2)

                Text(name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(wallpaper.choice(isDark: isDark).flatMap { WallpaperLibrary.shared.name(of: $0) } ?? "")
    }
}

/// What the desktop shows in an appearance, filling its frame as the picture fills the screen, or a
/// shuffle's thumbnail
struct DesktopThumbnail: View {
    let thumbnail: WallpaperManager.Thumbnail
    let size: CGSize

    var body: some View {
        switch thumbnail {
        case .picture(let picture):
            Image(decorative: picture, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        case .shuffle(let files):
            ShuffleThumbnail(files: files, size: size)
        }
    }
}

// MARK: - Wallpaper Window
/// The window the Wallpaper picker's pictures open, for choosing the picture for Light or for Dark from
/// System Settings › Wallpaper's own, in its sections, or from Photos or a file.
final class WallpaperWindow: NSObject, ObservableObject {
    static let shared = WallpaperWindow()
    /// Whether it's choosing the picture for Dark, or for Light
    @Published var isDark = false
    private var window: NSWindow?

    func show(isDark: Bool) {
        self.isDark = isDark
        YourPhotos.shared.reload()
        WallpaperManager.shared.lookForDownloads()
        if window == nil {
            let hostingController = NSHostingController(rootView: WallpaperGallery())
            hostingController.sizingOptions = [.minSize, .maxSize]
            let window = NSWindow(contentViewController: hostingController)
            window.styleMask.remove(.resizable)
            window.title = SystemStrings.wallpaper
            window.isReleasedWhenClosed = false
            window.setContentSize(hostingController.sizeThatFits(in: window.contentMaxSize)) // so it's centred at its size
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Asks for a picture of the user's own, as System Settings › Wallpaper's Choose File… does, in a sheet
    func addPhoto() {
        guard let window else { return }
        let isDark = isDark
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let file = panel.url else { return }
            WallpaperManager.shared.setPicture(file, isDark: isDark)
        }
    }

    /// Asks for a folder, as System Settings › Wallpaper's Choose Folder… does, in a sheet, and shuffles
    /// its pictures
    func chooseFolder() {
        guard let window else { return }
        let isDark = isDark
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let folder = panel.url else { return }
            WallpaperShuffler.shared.start(PhotoSet.shuffle(ofFolder: folder), isDark: isDark)
        }
    }

    /// Opens the Colours panel for any colour, as System Settings › Wallpaper's custom colour does
    func chooseColor() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.orderFront(nil)
    }

    private var colorChange: DispatchWorkItem?
    private var fillColorChange: DispatchWorkItem?

    /// Places the picture of the appearance being chosen with another colour around it once it's been
    /// left alone for a moment, as a colour is made into a wallpaper (`colorChanged(_:)`)
    func setFillColor(_ color: CGColor) {
        fillColorChange?.cancel()
        let isDark = isDark
        let change = DispatchWorkItem {
            let wallpaper = WallpaperManager.shared
            var options = wallpaper.options(isDark: isDark)
            options.placement?.color = color
            wallpaper.setOptions(options, isDark: isDark)
        }
        fillColorChange = change
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: change)
    }

    /// Makes a wallpaper in the colour once it's been left alone for a moment, as the panel sends every
    /// colour it passes through while one is dragged to, and each wallpaper takes a moment to make
    @objc private func colorChanged(_ panel: NSColorPanel) {
        colorChange?.cancel()
        let color = panel.color
        let isDark = isDark
        let change = DispatchWorkItem {
            WallpaperManager.shared.setColor(color, isDark: isDark)
        }
        colorChange = change
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: change)
    }
}

/// The Wallpaper window's contents, laid out the way System Settings › Wallpaper's own code lays out its
/// pane, with its measures. Above, the wallpaper's pictures for Light and for Dark, with a ring around
/// the one being chosen, while Show on all Spaces is off, the display they're of, and under them System
/// Settings' options for its wallpaper, and Show on all Spaces. Under them, scrolling, System Settings'
/// sections: each a row of its wallpapers
/// that scrolls sideways, until Show All shows them all, four to a row (eight colours to a row). Each
/// wallpaper's thumbnail is System Settings' own, whichever appearance is being chosen, and the ring is
/// around the one the desktop has.
struct WallpaperGallery: View {
    @ObservedObject var wallpaper = WallpaperManager.shared
    @ObservedObject var window = WallpaperWindow.shared
    @ObservedObject var photos = YourPhotos.shared
    @ObservedObject var shuffler = WallpaperShuffler.shared
    @ObservedObject var photoSets = PhotoLibrarySets.shared
    /// The sections showing all their wallpapers, not only a row
    @State private var expandedSections: Set<String> = []
    /// The colour being chosen to go around the appearance's picture, until the picture is placed with it
    @State private var fillColor: CGColor?
    @State private var isChoosingPhoto = false
    @State private var photo: PhotosPickerItem?
    /// Whether the sections have the focus, as System Settings' list of them takes it when the window
    /// becomes key and whenever a wallpaper is clicked: only there are the rings in the accent colour
    @FocusState private var isListFocused: Bool
    @State private var scrolling = WallpaperScrolling()
    /// The section a tile was last chosen in, by a click or the arrow keys, which the arrow keys move on
    /// from: a wallpaper can be in more than one, as the Mac wallpapers are in Mac and in Pictures
    @State private var chosenSection: String?
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.layoutDirection) private var layoutDirection

    /// System Settings' pane: its width, its margins, and the room between its sections, and between
    /// a section's title and its thumbnails, and between thumbnails. Its scroll bar is over its sections
    /// even when scroll bars are always shown, as the Wallpaper window's is.
    private static let width: CGFloat = 508
    private static let margin: CGFloat = 20
    private static let sectionSpacing: CGFloat = 20
    private static let spacing: CGFloat = 10
    /// How far below a whole pixel System Settings' list of sections starts, where the top of its pane
    /// leaves it. SwiftUI rounds each row to the pixels from there, so the sections start as far down
    /// here to be rounded the same way: the names, the rings and the colours' circles then fall on the
    /// same pixels. It isn't in System Settings' code, as it follows from the height of its pane's top,
    /// which this window doesn't share; it's the offset that makes every row match System Settings'
    /// pixels and the frames it reports to Accessibility.
    private static let listOffset: CGFloat = 5.0 / 16
    /// Its thumbnails, four to a row, and its colours, eight to a row
    private static let thumbnailSize = CGSize(width: 107.5, height: 71)
    private static let colorSize: CGFloat = 48.75
    private static let thumbnailCornerRadius: CGFloat = 4
    private static let previewSize = CGSize(width: 160, height: 100)
    private static let previewCornerRadius: CGFloat = 8
    /// Where a preview has room for the ring around it, as the Appearance picker's thumbnails do
    private static let ringPadding: CGFloat = 3.5
    /// The sections' own coordinates, those of the pane's scroll view's content
    private static let sections = "sections"

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                preview(SystemStrings.light, picture: wallpaper.thumbnails?.light, isDark: false)
                preview(SystemStrings.dark, picture: wallpaper.thumbnails?.dark, isDark: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 16)
            displayPicker
            options
            Divider()
            // Read here, as the sections are drawn by the scroll view's own hosting view, whose updates
            // come from this one's
            let expandedSections = expandedSections
            PaneScrollView(didMake: { scrolling.pane = $0 }) {
                // System Settings' GroupList: its sections centred, so a grid narrower than the pane's
                // margins leave is in the middle. It takes up to 5 points off each margin for a pane
                // narrower than 500 points, which this one never is.
                VStack(spacing: Self.sectionSpacing) {
                    ForEach(WallpaperLibrary.shared.sections) { section in
                        group(section, isExpanded: expandedSections.contains(section.id))
                    }
                }
                .padding(EdgeInsets(top: Self.margin + Self.listOffset, leading: Self.margin, bottom: Self.margin - Self.listOffset, trailing: Self.margin))
                .coordinateSpace(.named(Self.sections))
                // Focusable with no focus ring, as System Settings' list is: SwiftUI draws the selection
                // colour in the accent colour only in a view with the focus in the key window, and grey
                // anywhere else
                .focusable()
                .focusEffectDisabled()
                .focused($isListFocused)
                .onMoveCommand(perform: move)
                // Each section as tall as it needs, as in a SwiftUI scroll view, which offers its content
                // no height: offered the height of its frame, the sideways rows would share out what's
                // over or short, and each draw its wallpapers in the middle of what it's given
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: Self.width, height: 720)
        .photosPicker(isPresented: $isChoosingPhoto, selection: $photo, matching: .images, preferredItemEncoding: .current)
        .onChange(of: photo) { _, photo in
            guard let photo else { return }
            wallpaper.choose(photo, isDark: window.isDark)
            self.photo = nil
        }
        // Your Photos' shuffle on the desktop shows its newest photos once they're read
        .onChange(of: photos.items) {
            wallpaper.refresh()
        }
        .onChange(of: wallpaper.isChanging) { _, isChanging in
            if !isChanging {
                fillColor = nil
            }
        }
        .onChange(of: window.isDark) {
            fillColor = nil
        }
    }

    /// The wallpaper's picture for Light or for Dark, the size of System Settings' picture of the
    /// desktop, ringed while it's the one being chosen, as the Appearance picker's thumbnails are. The
    /// ring turns the sections' grey while the window isn't key, as theirs does; the Appearance picker's
    /// stays in the accent colour. Clicking it chooses it instead.
    private func preview(_ name: String, picture: WallpaperManager.Thumbnail?, isDark: Bool) -> some View {
        let isSelected = window.isDark == isDark
        return Button {
            window.isDark = isDark
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    if let picture {
                        DesktopThumbnail(thumbnail: picture, size: Self.previewSize)
                    } else {
                        Rectangle()
                            .fill(.quaternary)
                    }
                }
                .frame(width: Self.previewSize.width, height: Self.previewSize.height)
                .clipShape(RoundedRectangle(cornerRadius: Self.previewCornerRadius))
                .padding(Self.ringPadding)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: Self.previewCornerRadius + Self.ringPadding)
                            .strokeBorder(appearsActive ? Color.accentColor : Color(nsColor: .unemphasizedSelectedContentBackgroundColor), lineWidth: 3)
                    }
                }
                .shadow(color: .black.opacity(0.33), radius: isSelected ? 0 : 2)

                Text(name)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// System Settings' pop-up under its picture of the desktop, as wide as that, for the display whose
    /// wallpaper is shown and chosen, while Show on all Spaces is off and there's more than one. A
    /// built-in display goes by System Settings' name for it there.
    @ViewBuilder
    private var displayPicker: some View {
        if !wallpaper.showsOnAllSpaces && wallpaper.displays.count > 1 {
            let picker = Picker(SystemStrings.display, selection: Binding { wallpaper.place(for: nil) } set: { wallpaper.selectDisplay($0) }) {
                ForEach(wallpaper.displays) { display in
                    Text(CGDisplayIsBuiltin(display.id) != 0 ? SystemStrings.builtInDisplay : display.name)
                        .tag(display.key as String?)
                }
            }
            .labelsHidden()
            Group {
                // As wide as it's given, as AppKit's pop-up was before macOS 26
                if #available(macOS 26.0, *) {
                    picker.buttonSizing(.flexible)
                } else {
                    picker
                }
            }
            .frame(width: Self.previewSize.width)
            .padding(.top, 12)
        }
    }

    /// System Settings' options for the wallpaper the appearance being chosen has, in a grouped box as
    /// System Settings has them beside its picture of the desktop, the first beside the wallpaper's name,
    /// and after them Show on all Spaces, which is the whole wallpaper's.
    private var options: some View {
        Form {
            Section {
                Group {
                    switch optionKind {
                    case .shuffle(let shuffle):
                        shuffleInterval(shuffle)
                        if shuffle.id == WallpaperShuffle.colors {
                            gradientToggle
                        } else if !shuffle.isAerials {
                            placementPicker(SystemStrings.picture)
                        }
                    case .dynamic(let item):
                        appearancePicker(item)
                        if item.id == WallpaperManager.DrawnWallpaper.macintosh.rawValue {
                            macintoshColorsPicker
                        }
                    case .color:
                        gradientToggle
                    case .picture(let name):
                        placementPicker(name)
                    case nil:
                        EmptyView()
                    }
                }
                Toggle(SystemStrings.showOnAllSpaces, isOn: Binding { wallpaper.showsOnAllSpaces } set: { wallpaper.setShowsOnAllSpaces($0) })
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .scrollContentBackground(.hidden)
        // As tall as its rows, not the window
        .fixedSize(horizontal: false, vertical: true)
    }

    /// What the options are for: a shuffle, a wallpaper with a picture for each appearance, a colour, or
    /// a picture, which is placed on the display
    private enum OptionKind {
        case shuffle(WallpaperShuffle)
        case dynamic(WallpaperItem)
        case color(WallpaperItem)
        case picture(name: String)
    }

    /// What the appearance being chosen has, as far as it has options here. A shuffle has them while
    /// it's Safelight's, as System Settings' own are macOS's to change, and a picture of the user's own
    /// while the wallpaper has kept it as it was before it was placed.
    private var optionKind: OptionKind? {
        let isDark = window.isDark
        guard let choice = wallpaper.choice(isDark: isDark) else { return nil }
        let library = WallpaperLibrary.shared
        if let shuffle = library.shuffle(choice) ?? PhotoSet.name(of: choice).map({ WallpaperShuffle(id: choice, name: $0, thumbnails: []) }) {
            return shuffler.shuffle(isDark: isDark) != nil ? .shuffle(shuffle) : nil
        }
        guard let item = library.item(choice) ?? photos.items.first(where: { $0.id == choice }) else {
            return WallpaperItem.isOwnPicture(choice) && wallpaper.canPlaceAgain(isDark: isDark) ? .picture(name: library.name(of: choice) ?? SystemStrings.picture) : nil
        }
        if item.badge == .dynamic {
            return .dynamic(item)
        } else if case .color = item.light {
            return .color(item)
        }
        return item.isPicture ? .picture(name: item.name) : nil
    }

    /// How often the appearance being chosen changes its picture, while it's a shuffle's, as System
    /// Settings shows beside a shuffle
    private func shuffleInterval(_ shuffle: WallpaperShuffle) -> some View {
        let interval = Binding {
            shuffler.shuffle(isDark: window.isDark)?.interval ?? WallpaperShuffle.defaultInterval(for: shuffle.id)
        } set: {
            shuffler.setInterval($0, isDark: window.isDark)
        }
        return Picker(shuffle.name, selection: interval) {
            ForEach(WallpaperShuffle.intervals(for: shuffle.id), id: \.self) { interval in
                Text(interval.title)
                    .tag(interval)
            }
        }
    }

    /// Which of its pictures a wallpaper with one for each appearance shows in the appearance being
    /// chosen: its own (Automatic), or its Light one or its Dark one, as System Settings offers for it
    private func appearancePicker(_ item: WallpaperItem) -> some View {
        let isDark = window.isDark
        let options = wallpaper.options(isDark: isDark)
        let appearance = Binding {
            options.appearance ?? .automatic
        } set: {
            var changed = options
            changed.appearance = $0
            wallpaper.setOptions(changed, isDark: isDark)
        }
        return Picker(item.name, selection: appearance) {
            ForEach(WallpaperManager.AppearanceOption.allCases, id: \.self) { option in
                Text(SystemStrings.appearanceOption(option, of: item.id))
                    .tag(option)
            }
        }
    }

    /// Macintosh's colours, as System Settings offers them
    private var macintoshColorsPicker: some View {
        let isDark = window.isDark
        let options = wallpaper.options(isDark: isDark)
        let colors = Binding {
            options.macintoshColors ?? wallpaper.macintoshColors ?? MacintoshWallpaper.defaultColors
        } set: {
            var changed = options
            changed.macintoshColors = $0
            wallpaper.setOptions(changed, isDark: isDark)
        }
        return Picker(SystemStrings.macintoshColor, selection: colors) {
            ForEach(MacintoshWallpaper.colors, id: \.self) { colors in
                Text(SystemStrings.macintoshColors(colors))
                    .tag(colors)
            }
        }
    }

    /// Whether a colour is shown as a gradient, as System Settings offers for its colours
    private var gradientToggle: some View {
        let isDark = window.isDark
        let options = wallpaper.options(isDark: isDark)
        return Toggle(SystemStrings.gradient, isOn: Binding {
            options.isGradient == true
        } set: {
            var changed = options
            changed.isGradient = $0
            wallpaper.setOptions(changed, isDark: isDark)
        })
    }

    /// How the appearance's picture is placed on a display of another shape, as System Settings offers
    /// for a picture, with the colour around one that doesn't fill it, beside its name. The colour shows
    /// as it's chosen, and the picture is placed with it a moment later (`WallpaperWindow.setFillColor`).
    private func placementPicker(_ name: String) -> some View {
        let isDark = window.isDark
        let options = wallpaper.options(isDark: isDark)
        let placement = options.placement ?? WallpaperManager.Placement()
        let kind = Binding {
            placement.kind
        } set: {
            var changed = options
            changed.placement = WallpaperManager.Placement(kind: $0, color: placement.color ?? wallpaper.defaultFillColor)
            wallpaper.setOptions(changed, isDark: isDark)
        }
        let color = Binding {
            fillColor ?? placement.color ?? wallpaper.defaultFillColor
        } set: {
            fillColor = $0
            window.setFillColor($0)
        }
        return LabeledContent(name) {
            HStack(spacing: 8) {
                if placement.hasColor {
                    ColorPicker(SystemStrings.fillColor, selection: color, supportsOpacity: false)
                        .labelsHidden()
                }
                Picker(name, selection: kind) {
                    ForEach(WallpaperManager.Placement.Kind.allCases, id: \.self) { kind in
                        Text(SystemStrings.placement(kind))
                            .tag(kind)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    /// A section, as System Settings' GroupView lays one out: its header, its title with Show All beside
    /// it when there's more than a row, on one baseline, and 10 points under it, a row of its wallpapers
    /// that scrolls sideways under the margins, or all of them. A section whose wallpapers have no names
    /// under them has 10 points more below.
    private func group(_ section: WallpaperLibrary.Section, isExpanded: Bool) -> some View {
        let columns = columns(of: section)
        let count = tiles(of: section, isExpanded: true).count
        let hidesNames = !(section.kind == .pictures || section.kind == .shuffles)
        return VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(section.title)
                    .lineLimit(1)
                    .fontWeight(.medium)
                Spacer()
                if count > columns || section.row.map({ $0.count < section.items.count }) == true {
                    Button(isExpanded ? SystemStrings.showLess : String(format: SystemStrings.showAll, "\(count)")) {
                        if isExpanded {
                            expandedSections.remove(section.id)
                        } else {
                            expandedSections.insert(section.id)
                        }
                    }
                    .buttonStyle(ShowAllButtonStyle())
                }
            }
            .contentShape(Rectangle())
            if isExpanded {
                let width = section.kind == .colors ? Self.colorSize : Self.thumbnailSize.width
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: Self.spacing), count: columns), alignment: .leading, spacing: Self.spacing) {
                    ForEach(tiles(of: section, isExpanded: true)) { tile in
                        view(of: tile, in: section)
                    }
                }
                .padding(.bottom, hidesNames ? 10 : 0)
                .padding(.top, 10)
            } else {
                // The width of the window, scrolling under its margins
                ScrollView(.horizontal) {
                    LazyHStack(spacing: Self.spacing) {
                        ForEach(tiles(of: section, isExpanded: false)) { tile in
                            view(of: tile, in: section)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.top, 10)
                }
                .padding(.horizontal, -Self.margin)
                .contentMargins(.horizontal, Self.margin, for: .automatic)
                .padding(.bottom, hidesNames ? 10 : 0)
                .scrollClipDisabled()
                .scrollIndicators(.never)
                // By the wallpaper at its leading edge, as System Settings keeps it
                .scrollPosition(Binding { scrolling.rows[section.id] ?? ScrollPosition(idType: String.self) } set: { scrolling.rows[section.id] = $0 },
                                anchor: .leading)
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.sections)) } action: { frame in
            scrolling.sectionFrames[section.id] = frame
        }
    }

    /// One of a section's tiles: Add Photo…, a shuffle, the custom colour, or a wallpaper. Each goes by
    /// its ID in its row, as the ID it's chosen by does.
    private enum Tile: Identifiable {
        case addPhoto
        case shuffle(WallpaperShuffle)
        case customColor
        case item(WallpaperItem)

        var id: String {
            switch self {
            case .addPhoto: "add-photo"
            case .shuffle(let shuffle): shuffle.id
            case .customColor: WallpaperItem.customColor
            case .item(let item): item.id
            }
        }
    }

    /// A section's tiles, in System Settings' order: Add Photo… and then the photos' shuffle, or the
    /// colours' shuffle and then the custom colour, before the wallpapers, those of its row or all of them
    private func tiles(of section: WallpaperLibrary.Section, isExpanded: Bool) -> [Tile] {
        let items = section.kind == .photos ? photos.items : section.items
        let shown = (isExpanded ? nil : section.row) ?? items
        let shuffles = (section.kind == .photos ? Array(photos.shuffle.map { [$0] } ?? []) : section.shuffles).map(Tile.shuffle)
        switch section.kind {
        case .pictures:
            return shown.map(Tile.item)
        case .shuffles:
            return shuffles
        case .photos:
            return [.addPhoto] + shuffles + shown.map(Tile.item)
        case .colors:
            return shuffles + [.customColor] + shown.map(Tile.item)
        }
    }

    /// A tile as its section draws it
    @ViewBuilder
    private func view(of tile: Tile, in section: WallpaperLibrary.Section) -> some View {
        let showsName = section.kind == .pictures || section.kind == .shuffles
        switch tile {
        case .addPhoto:
            addPhoto
        case .shuffle(let shuffle) where section.kind == .colors:
            circleButton("arrow.triangle.2.circlepath", name: shuffle.name, id: shuffle.id) {
                choose(tile, in: section)
            }
        case .shuffle(let shuffle):
            thumbnail(shuffle, showsName: showsName, in: section)
        case .customColor:
            circleButton("plus", name: SystemStrings.customColor, id: WallpaperItem.customColor) {
                choose(tile, in: section)
            }
        case .item(let item) where section.kind == .colors:
            swatch(item, in: section)
        case .item(let item):
            thumbnail(item, showsName: showsName, in: section)
        }
    }

    /// Chooses a tile in a section, as clicking it does: the custom colour opens the Colours panel. Add
    /// Photo… has a menu to be opened instead, and a photo that's gone can't be chosen.
    private func choose(_ tile: Tile, in section: WallpaperLibrary.Section) {
        switch tile {
        case .addPhoto:
            return
        case .shuffle(let shuffle):
            shuffler.start(shuffle, isDark: window.isDark)
        case .customColor:
            window.chooseColor()
        case .item(let item):
            guard !isMissing(item) else { return }
            wallpaper.choose(item, isDark: window.isDark)
        }
        chosenSection = section.id
    }

    // MARK: Arrow keys

    /// The arrow keys, as System Settings' list takes them: they choose the tile beside the one chosen,
    /// left or right in its row, or in its row of the grid Show All shows, up or down in the grid, and
    /// at its top or bottom, or from a row, the tile in the same place in the section above or below.
    /// A row scrolls to the tile chosen in it, and the list to a section moved to. Nothing chosen in the
    /// sections, they do nothing.
    private func move(_ direction: MoveCommandDirection) {
        var direction = direction
        if layoutDirection == .rightToLeft {
            direction = direction == .left ? .right : direction == .right ? .left : direction
        }
        guard let choice = wallpaper.choice(isDark: window.isDark) else { return }
        let sections = WallpaperLibrary.shared.sections
        let hasChoice = { (section: WallpaperLibrary.Section) in
            self.tiles(of: section, isExpanded: true).contains { $0.id == choice }
        }
        guard let sectionIndex = sections.firstIndex(where: { $0.id == chosenSection && hasChoice($0) }) ?? sections.firstIndex(where: hasChoice) else { return }
        let section = sections[sectionIndex]
        let isExpanded = expandedSections.contains(section.id)
        let tiles = tiles(of: section, isExpanded: isExpanded)
        guard let index = tiles.firstIndex(where: { $0.id == choice }) else { return }
        let columns = columns(of: section)
        let (row, column) = index.quotientAndRemainder(dividingBy: columns)

        /// The tile in the same place in the section above or below
        func move(toSection otherIndex: Int) {
            guard sections.indices.contains(otherIndex) else { return }
            let other = sections[otherIndex]
            let isOtherExpanded = expandedSections.contains(other.id)
            let otherTiles = self.tiles(of: other, isExpanded: isOtherExpanded)
            let place = isExpanded ? column : index
            let target = if direction == .up && isOtherExpanded {
                // In the grid's last row that has that place, or the one before
                lastIndex(inColumn: self.index(place % columns, from: section, to: other), count: otherTiles.count, columns: self.columns(of: other))
            } else {
                self.index(place, from: section, to: other)
            }
            guard otherTiles.indices.contains(target) else { return }
            choose(otherTiles[target], in: other)
            // Once the options above are those of the new choice, which can make the pane shorter
            DispatchQueue.main.async {
                scrolling.show(section: other.id)
            }
        }

        if isExpanded {
            let rows = Int((Double(tiles.count) / Double(columns)).rounded(.up))
            switch direction {
            case .left where column >= 1:
                choose(tiles[index - 1], in: section)
            case .right where column < columns - 1 && index + 1 < tiles.count:
                choose(tiles[index + 1], in: section)
            case .up where row >= 1:
                choose(tiles[index - columns], in: section)
            case .up:
                move(toSection: sectionIndex - 1)
            case .down where row < rows - 1 && index + columns < tiles.count:
                choose(tiles[index + columns], in: section)
            case .down:
                move(toSection: sectionIndex + 1)
            default:
                break
            }
        } else {
            switch direction {
            case .left where index >= 1:
                scrollRow(of: section, toShow: index - 1)
                choose(tiles[index - 1], in: section)
            case .right where index + 1 < tiles.count:
                scrollRow(of: section, toShow: index + 1)
                choose(tiles[index + 1], in: section)
            case .up:
                move(toSection: sectionIndex - 1)
            case .down:
                move(toSection: sectionIndex + 1)
            default:
                break
            }
        }
    }

    /// How many tiles a row of a section's grid has
    private func columns(of section: WallpaperLibrary.Section) -> Int {
        section.kind == .colors ? 8 : 4
    }

    /// The index of the tile a section's row is scrolled to, at its leading edge; 0 for a grid
    private func offset(of section: WallpaperLibrary.Section) -> Int {
        guard !expandedSections.contains(section.id), let id = scrolling.rows[section.id]?.viewID(type: String.self) else { return 0 }
        return tiles(of: section, isExpanded: false).firstIndex { $0.id == id } ?? 0
    }

    /// A place in a section, as an index in its row, or a column of its grid, moved to the same place in
    /// view in another section, as System Settings moves it: a colour takes half a wallpaper's place,
    /// so a place among the colours is halved, and one moved to them doubled
    private func index(_ place: Int, from section: WallpaperLibrary.Section, to other: WallpaperLibrary.Section) -> Int {
        let shift = offset(of: other) - offset(of: section)
        switch (section.kind == .colors, other.kind == .colors) {
        case (true, false):
            return place / 2 + shift
        case (false, true):
            return (place + shift) * 2
        default:
            return place + shift
        }
    }

    /// The index of the last tile of a grid in a column, or the first tile if none of its rows but the
    /// first reaches that column
    private func lastIndex(inColumn column: Int, count: Int, columns: Int) -> Int {
        guard count >= 2 else { return count - 1 }
        var index = count - 1
        while index % columns != column {
            guard index > 1 else { return 0 }
            index -= 1
        }
        return index
    }

    /// Scrolls a section's row as little as shows one of its tiles, at its leading edge or as the last of
    /// the tiles that fit
    private func scrollRow(of section: WallpaperLibrary.Section, toShow index: Int) {
        let tiles = tiles(of: section, isExpanded: false)
        let columns = columns(of: section)
        let offset = offset(of: section)
        let leading = index < offset ? index : index > offset + columns - 1 ? index - columns + 1 : nil
        guard let leading else { return }
        var position = scrolling.rows[section.id] ?? ScrollPosition(idType: String.self)
        withAnimation(.default) {
            position.scrollTo(id: tiles[leading].id, anchor: .leading)
            scrolling.rows[section.id] = position
        }
    }

    /// A wallpaper's thumbnail, with its name under it, and badges as System Settings has: at the bottom
    /// left, whether it's dynamic or a video, and at the bottom right, whether it's yet to be downloaded,
    /// or how much of it has been. Once macOS has downloaded it, it can be taken off the Mac again.
    private func thumbnail(_ item: WallpaperItem, showsName: Bool, in section: WallpaperLibrary.Section) -> some View {
        let removeDownload = wallpaper.canRemoveDownloads(of: item) ? { wallpaper.removeDownloads(of: item) } : nil
        return tile(id: item.id, name: item.name, showsName: showsName, badge: item.badge, isDownloaded: wallpaper.isDownloaded(item), isMissing: isMissing(item),
                    removeDownload: removeDownload) {
            choose(.item(item), in: section)
        } thumbnail: {
            Group {
                if isMissing(item) {
                    Rectangle()
                        .fill(.background)
                        .overlay {
                            Image(systemName: "exclamationmark.icloud")
                                .font(.system(size: 20))
                                .foregroundStyle(.tertiary)
                        }
                } else {
                    WallpaperThumbnail(file: item.thumbnail)
                }
            }
            .modifier(ThumbnailClip(size: Self.thumbnailSize, cornerRadius: Self.thumbnailCornerRadius))
        }
    }

    /// A shuffle's thumbnail: four of its pictures under the symbol for shuffling
    private func thumbnail(_ shuffle: WallpaperShuffle, showsName: Bool, in section: WallpaperLibrary.Section) -> some View {
        tile(id: shuffle.id, name: shuffle.name, showsName: showsName, badge: shuffle.isAerials ? .video : nil) {
            choose(.shuffle(shuffle), in: section)
        } thumbnail: {
            ShuffleThumbnail(files: shuffle.thumbnails, size: Self.thumbnailSize, cornerRadius: Self.thumbnailCornerRadius)
        }
    }

    /// A thumbnail as System Settings draws one, with its badges, and its name under it. One macOS has
    /// downloaded has Remove Download in its context menu, and in a … menu in the download badge's place
    /// while the pointer is over it, as System Settings has; while it's the one chosen, there's no …
    /// and the context menu's is dimmed.
    private func tile(id: String, name: String, showsName: Bool, badge: WallpaperItem.Badge?, isDownloaded: Bool = true, isMissing: Bool = false,
                      removeDownload: (() -> Void)? = nil, action: @escaping () -> Void, @ViewBuilder thumbnail: () -> some View) -> some View {
        let isSelected = wallpaper.choice(isDark: window.isDark) == id
        let thumbnail = thumbnail()
        return HoverReader { isHovering in
            // As System Settings' GroupItemView: SwiftUI's own spacing above the name
            VStack {
                thumbnail
                    // Its badges are over its rings, as System Settings has them
                    .overlay {
                        SelectionRings(shape: RoundedRectangle(cornerRadius: Self.thumbnailCornerRadius, style: .continuous), isSelected: isSelected,
                                       isOutlined: true, style: .selection)
                    }
                    .overlay(alignment: .bottomLeading) {
                        if let badge {
                            ThumbnailBadge(image: badge == .dynamic ? ThumbnailBadge.dynamic : Image(systemName: "play.rectangle.fill"))
                                .padding([.bottom, .leading], 5)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Group {
                            // Only while what's being made is downloaded, as System Settings shows nothing
                            // else while it puts a wallpaper on the desktop
                            if wallpaper.changingChoice == id && (!isDownloaded || wallpaper.downloadProgress != nil) {
                                progress
                                    .frame(width: 13, height: 13)
                            } else if !isDownloaded {
                                ThumbnailBadge(image: Image(systemName: "arrow.down.circle"))
                            } else if let removeDownload, isHovering, !isSelected {
                                removeDownloadMenu(removeDownload)
                            }
                        }
                        .padding([.bottom, .trailing], 5)
                    }
                if showsName {
                    Text(name)
                        .font(.caption)
                        .lineLimit(2, reservesSpace: true)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: Self.thumbnailSize.width)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .contentShape(Rectangle())
            .choosable(name, isSelected: isSelected, focusing: $isListFocused, action: action)
            // As it was as a button, while it can't be chosen
            .disabled(isMissing)
            .opacity(isMissing ? 0.5 : 1)
        }
        .contextMenu {
            if let removeDownload {
                Button(SystemStrings.removeDownload, action: removeDownload)
                    .disabled(isSelected)
            }
        }
        .help(name)
    }

    /// System Settings' … over a downloaded wallpaper, drawn as its badges are, with its one item
    private func removeDownloadMenu(_ removeDownload: @escaping () -> Void) -> some View {
        Menu {
            Button(SystemStrings.removeDownload, action: removeDownload)
        } label: {
            ThumbnailBadge(image: Image(systemName: "ellipsis"))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    /// Whether a photo of the user's is gone, with no copy of it left: Your Photos' are the only
    /// wallpapers with no thumbnail
    private func isMissing(_ item: WallpaperItem) -> Bool {
        item.lightThumbnail == nil && photos.items.contains(item)
    }

    /// One of System Settings' colours, as its ThumbnailView draws one: a circle filled with it
    private func swatch(_ item: WallpaperItem, in section: WallpaperLibrary.Section) -> some View {
        let isSelected = wallpaper.choice(isDark: window.isDark) == item.id
        return Circle()
            .fill(Color(cgColor: item.lightThumbnail.flatMap(WallpaperManager.swatchColor) ?? .clear))
            .frame(width: Self.colorSize, height: Self.colorSize)
            .overlay {
                SelectionRings(shape: Circle(), isSelected: isSelected, style: .selection)
            }
            .contentShape(Circle())
            .choosable(item.name, isSelected: isSelected, focusing: $isListFocused) {
                choose(.item(item), in: section)
            }
            .help(item.name)
    }

    /// Your Photos' first tile, whose menu, as System Settings' does, offers a photo from Photos or a
    /// picture from a file, or a set to shuffle: a folder's pictures, or the Photos library's Favourites,
    /// a shared album's or another album's, which it lists once it may read the library, asking as soon
    /// as the tile shows, as System Settings does. System Settings lists people as well, which Photos
    /// gives only to Apple's own apps.
    private var addPhoto: some View {
        Menu {
            Section(SystemStrings.singlePhoto) {
                Button(SystemStrings.chooseFromPhotos) {
                    isChoosingPhoto = true
                }
                Button(SystemStrings.chooseFile) {
                    window.addPhoto()
                }
            }
            Section(SystemStrings.photoSets) {
                Button(SystemStrings.chooseFolder, systemImage: "folder") {
                    window.chooseFolder()
                }
                if let favorites = photoSets.lists.favorites {
                    photoSetButton(favorites, systemImage: "heart")
                }
                ForEach(photoSets.lists.sharedAlbums) { album in
                    photoSetButton(album, systemImage: "rectangle.stack.badge.person.crop")
                }
                ForEach(photoSets.lists.albums) { album in
                    photoSetButton(album, systemImage: "rectangle.stack")
                }
            }
            // With their symbols, which a menu leaves out otherwise
            .labelStyle(.titleAndIcon)
        } label: {
            // As System Settings' AddPhotoButton
            VStack(spacing: 5) {
                Image(systemName: "photo.badge.plus")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 26))
                Text(SystemStrings.addPhoto)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(5)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
        .background(RoundedRectangle(cornerRadius: Self.thumbnailCornerRadius, style: .continuous).fill(.quinary))
        .task {
            await photoSets.load()
        }
    }

    /// One of the Photos library's sets in Add Photo…'s menu, which shuffles its photos
    private func photoSetButton(_ set: WallpaperShuffle, systemImage: String) -> some View {
        Button(set.name, systemImage: systemImage) {
            shuffler.start(set, isDark: window.isDark)
        }
    }

    /// One of Colours' first two swatches, a symbol in a grey circle, as System Settings' CircleButton
    /// draws them: the colours' shuffle, and the custom colour, which opens the Colours panel. Each is
    /// ringed while it's chosen, the custom colour while the appearance has any colour of the user's own.
    private func circleButton(_ symbol: String, name: String, id: String, action: @escaping () -> Void) -> some View {
        let isSelected = wallpaper.choice(isDark: window.isDark) == id
        return Button(action: action) {
            ZStack {
                Circle()
                    .fill(.quaternary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Image(systemName: symbol)
                    .font(.system(size: 26))
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }
            .frame(width: Self.colorSize, height: Self.colorSize)
            .overlay {
                SelectionRings(shape: Circle(), isSelected: isSelected, style: .tint)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// In the download badge's place on the picture being downloaded: how much of it has, or a spinner
    /// until that's known
    private var progress: some View {
        Group {
            if let fraction = wallpaper.downloadProgress {
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
            } else {
                ProgressView()
            }
        }
        .controlSize(.small)
        .colorScheme(.dark)
    }
}

/// Where the Wallpaper window's rows are scrolled to, each by the wallpaper at its leading edge, as
/// System Settings keeps them, and where its sections are in the pane, whose scroll view is AppKit's,
/// so the arrow keys can scroll to the one they move to
@Observable final class WallpaperScrolling {
    var rows: [String: ScrollPosition] = [:]
    @ObservationIgnored var sectionFrames: [String: CGRect] = [:]
    @ObservationIgnored weak var pane: NSScrollView?

    /// Scrolls the pane as little as shows a section, as SwiftUI's `scrollTo(id:)` does, which System
    /// Settings scrolls its list with, in SwiftUI's default animation of a scroll, which measures as
    /// easing in and out over 0.21 s whatever the distance
    func show(section id: String) {
        guard let pane, let frame = sectionFrames[id] else { return }
        let clipView = pane.contentView
        var bounds = clipView.bounds
        if frame.minY < bounds.minY || frame.height > bounds.height {
            bounds.origin.y = frame.minY
        } else if frame.maxY > bounds.maxY {
            bounds.origin.y = frame.maxY - bounds.height
        } else {
            return
        }
        let origin = clipView.constrainBoundsRect(bounds).origin
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.21
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clipView.animator().setBoundsOrigin(origin)
        }
        pane.reflectScrolledClipView(clipView)
    }
}

/// A scroll view as System Settings' panes have: its content runs under the scroll bar even when scroll
/// bars are always shown, and the bar's track and knob are see-through over it. System Settings asks
/// SwiftUI for it with a modifier only Apple's own code can use, which has AppKit lay the content out as
/// it does for scroll bars shown only while scrolling; SwiftUI's ScrollView otherwise keeps its content
/// beside the bar. So here the scroll view is AppKit's, its content laid out that way.
struct PaneScrollView<Content: View>: NSViewRepresentable {
    /// Given the scroll view once it's made
    var didMake: (NSScrollView) -> Void = { _ in }
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = UnderScrollerScrollView()
        scrollView.contentView = FlippedClipView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        let hostingView = NSHostingView(rootView: content)
        hostingView.sizingOptions = .intrinsicContentSize
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = hostingView
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            hostingView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
        didMake(scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        (scrollView.documentView as? NSHostingView<Content>)?.rootView = content
    }
}

/// Lays its content out under its vertical scroll bar, as AppKit does when scroll bars show only while
/// scrolling, whichever the user has chosen
final class UnderScrollerScrollView: NSScrollView {
    // Scrolling up or down over a row that scrolls sideways scrolls this instead, as it did when this
    // was SwiftUI's: a SwiftUI scroll view passes a scroll on along an axis it can't scroll only to a
    // scroll view that asks for it
    override func wantsForwardedScrollEvents(for axis: NSEvent.GestureAxis) -> Bool {
        axis == .vertical
    }

    override func tile() {
        super.tile()
        contentView.frame = bounds
    }
}

/// So a scroll view's content starts at its top
final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// System Settings › Wallpaper's Show All and Show Less: plain text, smaller and greyer than the title
struct ShowAllButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}

/// A thumbnail's pictures as System Settings' ThumbnailView and ShuffleImagesPreviewView frame them: at
/// the thumbnail's size, its corners rounded, then clipped to its frame. What goes over them, a shuffle's
/// symbol and the rings, isn't clipped.
struct ThumbnailClip: ViewModifier {
    let size: CGSize
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .clipped()
            .contentShape(shape)
    }
}

/// What System Settings draws over a thumbnail's edge while it's the one chosen: a ring in `style`, the
/// selection colour, the accent colour while the list it's in has the focus in the key window and grey
/// otherwise, or for Colours' two buttons the accent colour, which doesn't turn grey, and under it a
/// thinner one just inside, in white, or in black in Dark mode, which parts it from the picture. The
/// picture keeps its size under them. Otherwise a picture has a faint line around its edge, and a
/// colour has nothing.
struct SelectionRings<S: Shape, Style: ShapeStyle>: View {
    let shape: S
    let isSelected: Bool
    var isOutlined = false
    let style: Style
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if isSelected {
                shape.stroke(colorScheme == .dark ? Color.black : .white, style: StrokeStyle(lineWidth: 1.5))
                    .padding(1)
                shape.stroke(style, style: StrokeStyle(lineWidth: 2))
            } else if isOutlined {
                shape.stroke((colorScheme == .dark ? Color.white : .black).opacity(0.08), style: StrokeStyle(lineWidth: 1))
            }
        }
    }
}

extension View {
    /// One of the Wallpaper window's wallpapers, chosen with a click as System Settings' GroupItemView is:
    /// with a tap rather than as a button, inside which SwiftUI draws the selection colour grey even while
    /// the list has the focus. The list then takes the focus, as there. VoiceOver has it as a button.
    func choosable(_ name: String, isSelected: Bool, focusing isListFocused: FocusState<Bool>.Binding, action: @escaping () -> Void) -> some View {
        let choose = {
            action()
            isListFocused.wrappedValue = true
        }
        return gesture(TapGesture().onEnded(choose))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(name)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction {
                choose()
            }
    }
}

/// Its content, told whether the pointer is over it
struct HoverReader<Content: View>: View {
    @ViewBuilder let content: (_ isHovering: Bool) -> Content
    @State private var isHovering = false

    var body: some View {
        content(isHovering)
            .onHover { isHovering = $0 }
    }
}

/// A symbol System Settings draws in a thumbnail's corner, as its ContentBadge and DownloadBadge draw
/// one: white, with a shadow to stand out on any picture
struct ThumbnailBadge: View {
    let image: Image

    /// A dynamic wallpaper's: macOS's symbol for Light and Dark, which isn't in the public set, so it's
    /// named as System Settings names it
    static let dynamic = Image(_internalSystemName: "appearance")

    var body: some View {
        image
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.primary)
            .environment(\.colorScheme, .dark)
            .shadow(color: .black.opacity(0.65), radius: 2)
            .frame(width: 13, height: 13)
    }
}

/// A shuffle's thumbnail, as System Settings' ShuffleImagesPreviewView draws one: its first two pictures
/// side by side, and once it has four, its last two under them, each filling its share, under the
/// symbol for shuffling
struct ShuffleThumbnail: View {
    let files: [URL?]
    let size: CGSize
    /// Its corners' radius as a thumbnail of System Settings', or nil where what shows it rounds them
    var cornerRadius: CGFloat?

    var body: some View {
        let files = files.compactMap { $0 }
        let hasTwoRows = files.count > 3
        let pictures = Grid(alignment: .center, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(files.prefix(2), id: \.self) { cell($0, hasTwoRows: hasTwoRows) }
            }
            if files.count >= 4 {
                GridRow {
                    ForEach(files.suffix(2), id: \.self) { cell($0, hasTwoRows: hasTwoRows) }
                }
            }
        }
        Group {
            if let cornerRadius {
                pictures.modifier(ThumbnailClip(size: size, cornerRadius: cornerRadius))
            } else {
                pictures.frame(width: size.width, height: size.height)
            }
        }
        .overlay {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: min(size.width / 2, size.height / 2) * 0.75, weight: .semibold))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
        }
    }

    /// One of its pictures, half as wide as it, and half as tall when it has two rows, with no fade
    private func cell(_ file: URL, hasTwoRows: Bool) -> some View {
        WallpaperThumbnail(file: file, hasTransition: false)
            .frame(width: size.width / 2, height: hasTwoRows ? size.height / 2 : size.height)
            .clipped()
    }
}

/// A thumbnail in the Wallpaper window, as System Settings' ThumbnailImageView draws one: nothing until
/// its picture has loaded in the background, as System Settings loads it, then the picture filling the
/// thumbnail's frame (and beyond it, for whoever frames it to clip), or if it couldn't be, an iCloud
/// symbol. A picture loaded before is kept for the next, and is there from the start.
struct WallpaperThumbnail: View {
    let file: URL?
    /// Whether the picture fades in once it has loaded: a wallpaper's does, a shuffle's pictures don't
    var hasTransition = true
    @State private var state: LoadState

    private enum LoadState {
        case loading, failed
        case loaded(CGImage)
    }

    private static let cache = NSCache<NSURL, CGImage>()

    init(file: URL?, hasTransition: Bool = true) {
        self.file = file
        self.hasTransition = hasTransition
        _state = State(initialValue: Self.cached(file).map(LoadState.loaded) ?? .loading)
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                Color.clear
            case .failed:
                Image(systemName: "exclamationmark.icloud")
                    .font(.system(size: 20))
                    .opacity(0.2)
            case .loaded(let image):
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(hasTransition ? .opacity.animation(.default) : .identity)
            }
        }
        .task(id: file) {
            if let image = Self.cached(file) {
                state = .loaded(image)
                return
            }
            state = await Self.image(of: file).map(LoadState.loaded) ?? .failed
        }
    }

    private static func cached(_ file: URL?) -> CGImage? {
        file.flatMap { cache.object(forKey: $0 as NSURL) }
    }

    /// Its picture as System Settings loads it: one at least `quickLookSize` pixels each way from Quick
    /// Look, `maxPixelSize` square, and any other (or one Quick Look can't do) from ImageIO, at its size
    /// up to `maxPixelSize` on its longer side
    private static func image(of file: URL?) async -> CGImage? {
        guard let file else { return nil }
        let (maxPixelSize, quickLookSize) = (maxPixelSize, quickLookSize)
        let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            let source = CGImageSourceCreateWithURL(file as CFURL, nil).flatMap { CGImageSourceGetCount($0) > 0 ? $0 : nil }
            let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
            let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
            if source == nil || (width >= quickLookSize && height >= quickLookSize) {
                let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: maxPixelSize, height: maxPixelSize), scale: 1,
                                                           representationTypes: .thumbnail)
                if let image = try? await QLThumbnailGenerator().generateBestRepresentation(for: request).cgImage {
                    return image
                }
            }
            let longerSide = max(width, height)
            return source.flatMap {
                CGImageSourceCreateThumbnailAtIndex($0, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: longerSide == 0 ? maxPixelSize : min(maxPixelSize, longerSide),
                ] as CFDictionary)
            }
        }.value
        if let image {
            cache.setObject(image, forKey: file as NSURL)
        }
        return image
    }

    /// The most pixels System Settings loads a picture with on a side, and the fewest each way of one it
    /// has Quick Look load
    private static let maxPixelSize = 512
    private static let quickLookSize = 1024
}

// MARK: - Schedule Window
/// The window the gear button next to the Schedule switch opens.
final class ScheduleWindow: NSObject, NSWindowDelegate {
    static let shared = ScheduleWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            // The window can't be resized: it takes the editor's size, and follows it as rows come and go
            // (and, in Debug builds, as the Schedule Layout panel changes it)
            let hostingController = NSHostingController(rootView: ScheduleEditor())
            hostingController.sizingOptions = [.minSize, .maxSize]
            let window = NSWindow(contentViewController: hostingController)
            window.styleMask.remove(.resizable)
            window.title = SystemStrings.schedule
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(hostingController.sizeThatFits(in: window.contentMaxSize)) // so it's centred at its size
            window.center()
            self.window = window
        }
        guard let window else { return }
        let isOpen = window.isVisible || window.isMiniaturized
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Each opening starts with no time selected, where the window would select the first row's, or
        // keep the one selected when it closed. Already open, it keeps the one being typed.
        if !isOpen {
            window.makeFirstResponder(nil)
        }
    }

    // The window grows downwards as rows are added, and to the right as columns are, so one near the
    // bottom or right of the screen moves to stay on it
    func windowDidResize(_ notification: Notification) {
        guard let window, let visibleFrame = window.screen?.visibleFrame else { return }
        var origin = window.frame.origin
        if window.frame.minY < visibleFrame.minY {
            origin.y = visibleFrame.minY
        }
        if window.frame.maxX > visibleFrame.maxX {
            origin.x = max(visibleFrame.maxX - window.frame.width, visibleFrame.minX)
        }
        if origin != window.frame.origin {
            window.setFrameOrigin(origin)
        }
    }

    // Undo and Redo (⌘Z and ⇧⌘Z) in the window take back and put back changes to the schedule
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        ColorController.shared.scheduleUndoManager
    }

    func windowDidResignKey(_ notification: Notification) {
        ColorController.shared.endScheduleEdit()
    }
}

/// The Schedule's keyframes, a row each, under a preview of the day they make.
struct ScheduleEditor: View {
    @ObservedObject var controller = ColorController.shared
    #if DEBUG
    @ObservedObject private var layoutTuner = ScheduleLayoutTuner.shared
    private var layout: ScheduleLayout { layoutTuner.layout }
    #else
    private let layout = ScheduleLayout.standard
    #endif
    /// The keyframe the + button added last, whose time is ready to type as soon as its row is in
    @State private var addedKeyframeID: ColorKeyframe.ID?

    // Laid out like a grouped Form, whose sections are never wider than about 700 pt, so the window
    // can be as wide as the columns need
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: layout.boxSpacing) {
                ScheduleDayView(schedule: controller.schedule, displays: brightnessColumns.map { $0?.key })
                    .scheduleBox(padding: layout.boxPadding)

                // Each column after the first is set off from the one before by its own gap
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: layout.rowSpacing) {
                    GridRow {
                        Text(SystemStrings.time)
                        Text(SystemStrings.colorFilters)
                            .padding(.leading, layout.gapBeforeColorFilters)
                        Text(SystemStrings.intensity)
                            .padding(.leading, layout.gapBeforeIntensity)
                        Text(SystemStrings.tint)
                            .padding(.leading, layout.gapBeforeTint)
                        ForEach(brightnessColumns, id: \.self) { display in
                            Text(display?.name ?? SystemStrings.brightness)
                                .padding(.leading, layout.gapBeforeBrightness)
                        }
                        Text(SystemStrings.appearance)
                            .padding(.leading, layout.gapBeforeAppearance)

                        // Add heads the column of the keyframes' Delete buttons
                        Button {
                            addedKeyframeID = controller.addKeyframe()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .help(SystemStrings.add)
                        .accessibilityLabel(SystemStrings.add)
                        .padding(.leading, layout.gapBeforeDelete)
                    }
                    .foregroundStyle(.secondary)

                    ForEach($controller.schedule) { $keyframe in
                        // A grouped Form's lighter line between rows
                        Rectangle()
                            .fill(Color(nsColor: .quinaryLabelColor))
                            .frame(height: 1)
                            .gridCellUnsizedAxes(.horizontal)

                        GridRow {
                            TimeField(label: SystemStrings.time, selection: time(of: keyframe.id), isFocusedOnAppear: keyframe.id == addedKeyframeID)
                                .environment(\.timeZone, Self.utc)

                            Toggle(SystemStrings.colorFilters, isOn: $keyframe.isColorFilterOn)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .controlTint(hue: keyframe.tint, for: .scheduleColorFiltersSwitches)
                                .padding(.leading, layout.gapBeforeColorFilters)

                            // Holding any of the sliders shows its keyframe on screen until it's let go
                            Slider(value: $keyframe.intensity, in: ColorFilterManager.shared.intensityRange) {
                                Text(SystemStrings.intensity)
                            } onEditingChanged: { isEditing in
                                controller.preview(isEditing ? keyframe.id : nil)
                            }
                            .labelsHidden()
                            .controlTint(hue: keyframe.tint, for: .scheduleIntensitySliders)
                            .disabled(!keyframe.isColorFilterOn)
                            .frame(width: layout.intensityWidth)
                            .padding(.leading, layout.gapBeforeIntensity)

                            TintSlider(value: $keyframe.tint) { isEditing in
                                controller.preview(isEditing ? keyframe.id : nil)
                            }
                            .disabled(!keyframe.isColorFilterOn)
                            .opacity(keyframe.isColorFilterOn ? 1.0 : 0.6)
                            .frame(width: layout.tintWidth)
                            .padding(.leading, layout.gapBeforeTint)

                            ForEach(brightnessColumns, id: \.self) { display in
                                Slider(value: display.map { $keyframe[brightnessOf: $0.key] } ?? $keyframe.brightness, in: 0.0...1.0) {
                                    Text(display?.name ?? SystemStrings.brightness)
                                } onEditingChanged: { isEditing in
                                    controller.preview(isEditing ? keyframe.id : nil)
                                }
                                .labelsHidden()
                                .controlTint(.white, hasShadow: true, for: .scheduleBrightnessSliders)
                                .frame(width: layout.brightnessWidth)
                                .padding(.leading, layout.gapBeforeBrightness)
                            }

                            AppearanceSegments(isDark: $keyframe.isDarkAppearance)
                                .fixedSize()
                                .padding(.leading, layout.gapBeforeAppearance)

                            Button {
                                controller.deleteKeyframe(keyframe.id)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help(SystemStrings.delete)
                            .accessibilityLabel(SystemStrings.delete)
                            .disabled(controller.schedule.count == 1)
                            .padding(.leading, layout.gapBeforeDelete)
                        }
                    }
                }
                // Only as wide as its columns and gaps (offered more, a Grid shares it out between
                // all its columns), and the window with it
                .fixedSize(horizontal: true, vertical: false)
                .scheduleBox(padding: layout.boxPadding)
            }
            .padding(.horizontal, layout.sideMargin)
            .padding(.top, layout.topMargin)
            .padding(.bottom, layout.bottomMargin)
        }
        .frame(maxHeight: maxHeight)
        .fixedSize()
    }

    /// A Brightness column for each display while they're adjusted independently, headed by its name,
    /// or one for all of them
    private var brightnessColumns: [Display?] {
        controller.independentDisplays.isEmpty ? [nil] : controller.independentDisplays
    }

    // As tall as its rows, until the window fills the height of the screen, and then they scroll
    private var maxHeight: CGFloat {
        guard let screen = NSScreen.main else { return .infinity }
        return NSWindow.contentRect(forFrameRect: screen.visibleFrame, styleMask: [.titled, .closable, .miniaturizable]).height
    }

    // Times of day are edited as times on the first day of 2001 in UTC, which has no daylight saving
    // changes to skip or repeat a time, so every time reads back as it was set.
    private static let utc = TimeZone(identifier: "UTC")!

    // Setting a time slides its row to its new place, so the keyframe is found by its ID, not by the
    // place it had when the row was drawn.
    private func time(of id: ColorKeyframe.ID) -> Binding<Date> {
        Binding(
            get: { Date(timeIntervalSinceReferenceDate: Double(controller.schedule.first { $0.id == id }?.minute ?? 0) * 60) },
            set: { date in
                withAnimation {
                    controller.setMinute((Int((date.timeIntervalSinceReferenceDate / 60).rounded(.down)) % 1440 + 1440) % 1440, ofKeyframe: id)
                }
            }
        )
    }
}

/// The day the Schedule makes, from midnight to midnight: a strip of roughly how white looks on screen
/// through it, a line at the current time, and a dot under each keyframe. While the displays are
/// adjusted independently, the strip has a band for each, from the top down in the order of their columns.
struct ScheduleDayView: View {
    let schedule: [ColorKeyframe]
    /// The `Display.key` of each band, or nil for one band for all displays
    let displays: [String?]

    private let stripHeight: CGFloat = 36

    var body: some View {
        TimelineView(.everyMinute) { timeline in
            Canvas { context, size in
                let outline = Path(roundedRect: CGRect(x: 0, y: 0, width: size.width, height: stripHeight), cornerRadius: 6)
                func x(ofMinute minute: Double) -> CGFloat { size.width * minute / 1440 }

                context.drawLayer { strip in
                    strip.clip(to: outline)
                    let bandHeight = stripHeight / CGFloat(max(displays.count, 1))
                    for x in 0..<Int(size.width.rounded(.up)) {
                        guard let settings = ColorKeyframe.settings(in: schedule, at: Double(x) / size.width * 1440) else { continue }
                        for (band, display) in displays.enumerated() {
                            let pixel = CGRect(x: CGFloat(x), y: CGFloat(band) * bandHeight, width: 1, height: bandHeight)
                            strip.fill(Path(pixel), with: .color(settings.previewColor(ofDisplay: display)))
                        }
                    }

                    let now = Calendar.current.dateComponents([.hour, .minute], from: timeline.date)
                    let nowX = x(ofMinute: Double(now.hour! * 60 + now.minute!))
                    strip.fill(Path(CGRect(x: nowX - 1, y: 0, width: 2, height: stripHeight)), with: .color(.accentColor))
                }
                context.stroke(outline, with: .style(.separator))

                for keyframe in schedule {
                    let dot = CGRect(x: x(ofMinute: Double(keyframe.minute)) - 2.5, y: stripHeight + 4, width: 5, height: 5)
                    context.fill(Path(ellipseIn: dot), with: .style(.secondary))
                }

                // Midnight, 6, noon, 6 and midnight, the ends kept inside the strip
                for hour in stride(from: 0, through: 24, by: 6) {
                    let date = Calendar.current.date(bySettingHour: hour % 24, minute: 0, second: 0, of: timeline.date) ?? timeline.date
                    let label = Text(date.formatted(.dateTime.hour())).font(.system(size: 10)).foregroundColor(.secondary)
                    let anchor: UnitPoint = hour == 0 ? .topLeading : hour == 24 ? .topTrailing : .top
                    context.draw(label, at: CGPoint(x: x(ofMinute: Double(hour * 60)), y: stripHeight + 13), anchor: anchor)
                }
            }
        }
        .frame(height: stripHeight + 27)
    }
}

private extension View {
    /// One of the Schedule window's boxes, drawn like a section of a grouped Form, as wide as the window has room for.
    func scheduleBox(padding: CGFloat) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(scheduleBoxFill, in: RoundedRectangle(cornerRadius: 12, style: .circular))
    }
}

/// A grouped Form's sections are a touch darker in light mode, and lighter in dark mode, than the window.
private let scheduleBoxFill = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.03) : NSColor(white: 0, alpha: 0.03)
})

// MARK: - Schedule Layout
/// The widths of the Schedule window's sliders and the space around its boxes, rows and columns,
/// which the window takes its size from. Debug builds can change them in the Schedule Layout panel to
/// try others out; release builds always use `standard`, which matches a grouped Form.
struct ScheduleLayout: Equatable {
    var sideMargin: CGFloat = 28
    var topMargin: CGFloat = 20
    var bottomMargin: CGFloat = 20
    var boxPadding: CGFloat = 10
    var boxSpacing: CGFloat = 28
    var intensityWidth: CGFloat = 160
    var tintWidth: CGFloat = 160
    var brightnessWidth: CGFloat = 160
    var rowSpacing: CGFloat = 15
    var gapBeforeColorFilters: CGFloat = 40
    var gapBeforeIntensity: CGFloat = 40
    var gapBeforeTint: CGFloat = 40
    var gapBeforeBrightness: CGFloat = 40
    var gapBeforeAppearance: CGFloat = 40
    var gapBeforeDelete: CGFloat = 40

    static let standard = ScheduleLayout()
}

#if DEBUG
extension ScheduleLayout {
    /// The tighter spacing the Schedule window had as a grouped Form, before it could be changed.
    static let compact = ScheduleLayout(
        boxSpacing: 10,
        intensityWidth: 120, tintWidth: 120, brightnessWidth: 120,
        rowSpacing: 10,
        gapBeforeColorFilters: 16, gapBeforeIntensity: 16, gapBeforeTint: 16,
        gapBeforeBrightness: 16, gapBeforeAppearance: 16, gapBeforeDelete: 16
    )

    /// Layouts the Schedule Layout panel can switch to at once.
    static let templates: [(name: String, layout: ScheduleLayout)] = [
        ("Spacious", .standard),
        ("Compact", .compact),
    ]
}
#endif

#if DEBUG
/// The layout the Schedule window has in Debug builds, kept between launches until it's restored.
final class ScheduleLayoutTuner: ObservableObject {
    static let shared = ScheduleLayoutTuner()

    /// A value the panel has a slider for, and the key it's saved under.
    struct Field: Identifiable {
        let key: String
        let name: String
        let keyPath: WritableKeyPath<ScheduleLayout, CGFloat>
        let range: ClosedRange<CGFloat>
        var id: String { key }
    }

    static let windowFields = [
        Field(key: "sideMargin", name: "Sides", keyPath: \.sideMargin, range: 0...80),
        Field(key: "topMargin", name: "Top", keyPath: \.topMargin, range: 0...80),
        Field(key: "bottomMargin", name: "Bottom", keyPath: \.bottomMargin, range: 0...80),
    ]

    static let boxFields = [
        Field(key: "boxPadding", name: "Inside each box", keyPath: \.boxPadding, range: 0...40),
        Field(key: "boxSpacing", name: "Between boxes", keyPath: \.boxSpacing, range: 0...40),
    ]

    static let widthFields = [
        Field(key: "intensityWidth", name: SystemStrings.intensity, keyPath: \.intensityWidth, range: 60...300),
        Field(key: "tintWidth", name: SystemStrings.tint, keyPath: \.tintWidth, range: 60...300),
        Field(key: "brightnessWidth", name: SystemStrings.brightness, keyPath: \.brightnessWidth, range: 60...300),
    ]

    static let gapFields = [
        Field(key: "gapBeforeColorFilters", name: SystemStrings.colorFilters, keyPath: \.gapBeforeColorFilters, range: 0...80),
        Field(key: "gapBeforeIntensity", name: SystemStrings.intensity, keyPath: \.gapBeforeIntensity, range: 0...80),
        Field(key: "gapBeforeTint", name: SystemStrings.tint, keyPath: \.gapBeforeTint, range: 0...80),
        Field(key: "gapBeforeBrightness", name: SystemStrings.brightness, keyPath: \.gapBeforeBrightness, range: 0...80),
        Field(key: "gapBeforeAppearance", name: SystemStrings.appearance, keyPath: \.gapBeforeAppearance, range: 0...80),
        Field(key: "gapBeforeDelete", name: SystemStrings.delete, keyPath: \.gapBeforeDelete, range: 0...80),
    ]

    static let rowSpacingField = Field(key: "rowSpacing", name: "Row spacing", keyPath: \.rowSpacing, range: 0...30)

    private static let fields = windowFields + boxFields + widthFields + gapFields + [rowSpacingField]

    private static let defaultsKey = "scheduleLayout"

    @Published var layout: ScheduleLayout {
        didSet { save() }
    }

    private init() {
        var layout = ScheduleLayout.standard
        let saved = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: Double] ?? [:]
        for field in Self.fields {
            if let value = saved[field.key] { layout[keyPath: field.keyPath] = value }
        }
        self.layout = layout
    }

    // Saved as numbers by name, so `defaults read Mo.Safelight scheduleLayout` shows them
    private func save() {
        guard layout != .standard else {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
            return
        }
        let values = Self.fields.map { ($0.key, Double(layout[keyPath: $0.keyPath])) }
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: values), forKey: Self.defaultsKey)
    }
}

/// Sliders for the Schedule window's layout, which moves as they're dragged. Each changes only the
/// width or space it's named for, and the window grows and shrinks to fit.
struct ScheduleLayoutPanel: View {
    @ObservedObject var tuner = ScheduleLayoutTuner.shared

    var body: some View {
        Form {
            Section {
                Picker("Template", selection: template) {
                    ForEach(ScheduleLayout.templates, id: \.name) { template in
                        Text(template.name).tag(Optional(template.name))
                    }
                    // Only there to name values that aren't a template's
                    if templateName == nil {
                        Text("Custom").tag(String?.none)
                    }
                }
            }

            Section("Space to the window's edges") {
                ForEach(ScheduleLayoutTuner.windowFields, content: row)
            }

            Section("Space around the boxes") {
                ForEach(ScheduleLayoutTuner.boxFields, content: row)
            }

            Section("Width of each slider") {
                ForEach(ScheduleLayoutTuner.widthFields, content: row)
            }

            Section("Space before each column") {
                row("All columns", value: allGaps, in: 0...80, isChanged: ScheduleLayoutTuner.gapFields.contains(where: isChanged), help: "Sets every column's gap at once") {
                    for field in ScheduleLayoutTuner.gapFields { reset(field) }
                }
                ForEach(ScheduleLayoutTuner.gapFields, content: row)
            }

            Section {
                row(ScheduleLayoutTuner.rowSpacingField)
            } footer: {
                Button(SystemStrings.restoreDefaults) {
                    tuner.layout = .standard
                }
                .disabled(tuner.layout == .standard)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ field: ScheduleLayoutTuner.Field) -> some View {
        row(field.name, value: $tuner.layout[dynamicMember: field.keyPath], in: field.range, isChanged: isChanged(field), help: "Standard: \(Int(ScheduleLayout.standard[keyPath: field.keyPath])) pt") {
            reset(field)
        }
    }

    /// A slider and stepper for one value, which reads in bold once it's been changed, with a button
    /// to put it back that's there only then.
    private func row(_ name: String, value: Binding<CGFloat>, in range: ClosedRange<CGFloat>, isChanged: Bool, help: String, reset: @escaping () -> Void) -> some View {
        LabeledContent(name) {
            HStack {
                // Rounded to whole points as it's dragged; a `step` would draw a tick mark for each one
                Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0.rounded() }), in: range)
                    .frame(width: 150)
                Text("\(Int(value.wrappedValue)) pt")
                    .monospacedDigit()
                    .fontWeight(isChanged ? .bold : .regular)
                    .frame(width: 52, alignment: .trailing)
                Stepper(name, value: value, in: range, step: 1)
                    .labelsHidden()

                // Hidden rather than left out while there's nothing to reset, so the rows stay lined up
                Button(action: reset) {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("Reset")
                .accessibilityLabel("Reset \(name)")
                .opacity(isChanged ? 1 : 0)
                .disabled(!isChanged)
            }
        }
        .help(help)
    }

    private func isChanged(_ field: ScheduleLayoutTuner.Field) -> Bool {
        tuner.layout[keyPath: field.keyPath] != ScheduleLayout.standard[keyPath: field.keyPath]
    }

    private func reset(_ field: ScheduleLayoutTuner.Field) {
        tuner.layout[keyPath: field.keyPath] = ScheduleLayout.standard[keyPath: field.keyPath]
    }

    /// The template the layout is, if it's one of them.
    private var templateName: String? {
        ScheduleLayout.templates.first { $0.layout == tuner.layout }?.name
    }

    /// Choosing a template sets every value to its own.
    private var template: Binding<String?> {
        Binding(
            get: { templateName },
            set: { name in
                if let template = ScheduleLayout.templates.first(where: { $0.name == name }) {
                    tuner.layout = template.layout
                }
            }
        )
    }

    /// Every column's gap at once, reading as the widest of them.
    private var allGaps: Binding<CGFloat> {
        Binding(
            get: { ScheduleLayoutTuner.gapFields.map { tuner.layout[keyPath: $0.keyPath] }.max() ?? 0 },
            set: { gap in
                for field in ScheduleLayoutTuner.gapFields { tuner.layout[keyPath: field.keyPath] = gap }
            }
        )
    }
}

/// The floating panel with `ScheduleLayoutPanel`, from Schedule Layout… in the status item's menu.
final class ScheduleLayoutWindow {
    static let shared = ScheduleLayoutWindow()
    private var panel: NSPanel?

    func show() {
        ScheduleWindow.shared.show()
        if panel == nil {
            let hostingController = NSHostingController(rootView: ScheduleLayoutPanel())
            hostingController.sizingOptions = [.minSize, .maxSize]
            let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            panel.contentViewController = hostingController
            panel.title = "Schedule Layout"
            panel.isFloatingPanel = true
            panel.isReleasedWhenClosed = false
            panel.setContentSize(hostingController.sizeThatFits(in: panel.contentMaxSize))
            panel.center()
            panel.setFrameAutosaveName("ScheduleLayout") // back where it was left, if it's been moved
            self.panel = panel
        }
        panel?.makeKeyAndOrderFront(nil)
    }
}
#endif

// MARK: - Control Colours
/// A switch or slider drawn in a colour of its own, or in each of the Schedule window's rows. Debug
/// builds can draw each in the accent colour instead, in the Control Colours panel.
enum TintedControl: String, CaseIterable, Identifiable {
    case colorFiltersSwitch
    case intensitySlider
    case brightnessSliders
    case adjustIndependentlySwitch
    case scheduleColorFiltersSwitches
    case scheduleIntensitySliders
    case scheduleBrightnessSliders

    var id: String { rawValue }
}

extension View {
    /// Draws `control` in `color`, with a soft shadow if `hasShadow`, which sets a white slider apart
    /// from a light background, unless a Debug build is set to draw it in the accent colour, with no
    /// shadow, as macOS would.
    func controlTint(_ color: Color, hasShadow: Bool = false, for control: TintedControl) -> some View {
        modifier(ControlTint(color: color, hasShadow: hasShadow, control: control))
    }

    /// Draws `control` in the colour filter's hue, `tint` degrees round the colour wheel, so it shows
    /// the tint that's applied.
    func controlTint(hue tint: Float, for control: TintedControl) -> some View {
        controlTint(Color(hue: Double(tint) / 360, saturation: 1.0, brightness: 1.0), for: control)
    }
}

private struct ControlTint: ViewModifier {
    let color: Color
    let hasShadow: Bool
    let control: TintedControl
    #if DEBUG
    @ObservedObject private var controlColors = ControlColors.shared
    #endif

    func body(content: Content) -> some View {
        #if DEBUG
        if controlColors.accentColored.contains(control) {
            content
        } else {
            tinted(content)
        }
        #else
        tinted(content)
        #endif
    }

    @ViewBuilder
    private func tinted(_ content: Content) -> some View {
        if hasShadow {
            content
                .tint(color)
                .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
        } else {
            content
                .tint(color)
        }
    }
}

#if DEBUG
extension TintedControl {
    static let popover: [TintedControl] = [.colorFiltersSwitch, .intensitySlider, .brightnessSliders, .adjustIndependentlySwitch]
    static let schedule: [TintedControl] = [.scheduleColorFiltersSwitches, .scheduleIntensitySliders, .scheduleBrightnessSliders]

    var name: String {
        switch self {
        case .colorFiltersSwitch, .scheduleColorFiltersSwitches: SystemStrings.colorFilters
        case .intensitySlider, .scheduleIntensitySliders: SystemStrings.intensity
        case .brightnessSliders, .scheduleBrightnessSliders: SystemStrings.brightness
        case .adjustIndependentlySwitch: SystemStrings.adjustIndependently
        }
    }

    /// What Custom draws it in.
    var customColor: String {
        switch self {
        case .colorFiltersSwitch, .intensitySlider, .scheduleColorFiltersSwitches, .scheduleIntensitySliders: "the filter's hue"
        case .brightnessSliders, .scheduleBrightnessSliders: "white, with a soft shadow"
        case .adjustIndependentlySwitch: "a muted gold"
        }
    }
}

/// The switches and sliders Debug builds draw in the accent colour, kept between launches until
/// they're all Custom again. Release builds draw every one in its own colour.
final class ControlColors: ObservableObject {
    static let shared = ControlColors()
    private static let defaultsKey = "controlColors"

    /// Choices the panel can make for every control at once.
    static let presets: [(name: String, accentColored: Set<TintedControl>)] = [
        ("Custom", []),
        // The filter's hue only on the controls that show the tint
        ("Mixed", [.brightnessSliders, .adjustIndependentlySwitch, .scheduleBrightnessSliders]),
        ("Accent Colour", Set(TintedControl.allCases)),
    ]

    @Published var accentColored: Set<TintedControl> {
        didSet { save() }
    }

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        accentColored = Set(saved.compactMap(TintedControl.init))
    }

    // Saved by name, so `defaults read Mo.Safelight controlColors` shows them
    private func save() {
        guard !accentColored.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
            return
        }
        let names = TintedControl.allCases.filter(accentColored.contains).map(\.rawValue)
        UserDefaults.standard.set(names, forKey: Self.defaultsKey)
    }
}

/// Custom or Accent Colour for each switch and slider that has a colour of its own, which it takes on
/// as it's chosen, and presets that choose for every one at once.
struct ControlColorsPanel: View {
    @ObservedObject var controlColors = ControlColors.shared

    var body: some View {
        Form {
            Section {
                Picker("Preset", selection: preset) {
                    ForEach(ControlColors.presets, id: \.name) { preset in
                        Text(preset.name).tag(Optional(preset.name))
                    }
                    // Only there to name choices that aren't a preset's
                    if presetName == nil {
                        Text("Individual").tag(String?.none)
                    }
                }
            }

            Section("Popover") {
                ForEach(TintedControl.popover, content: row)
            }

            Section("Schedule window") {
                ForEach(TintedControl.schedule, content: row)
            }
        }
        .formStyle(.grouped)
        .frame(width: 470)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ control: TintedControl) -> some View {
        Picker(control.name, selection: usesAccentColor(control)) {
            Text("Custom").tag(false)
            Text("Accent Colour").tag(true)
        }
        .pickerStyle(.segmented)
        .help("Custom: \(control.customColor)")
    }

    private func usesAccentColor(_ control: TintedControl) -> Binding<Bool> {
        Binding(
            get: { controlColors.accentColored.contains(control) },
            set: { usesAccentColor in
                if usesAccentColor {
                    controlColors.accentColored.insert(control)
                } else {
                    controlColors.accentColored.remove(control)
                }
            }
        )
    }

    /// The preset the choices are, if they're one of them.
    private var presetName: String? {
        ControlColors.presets.first { $0.accentColored == controlColors.accentColored }?.name
    }

    /// Choosing a preset makes every choice its own.
    private var preset: Binding<String?> {
        Binding(
            get: { presetName },
            set: { name in
                if let preset = ControlColors.presets.first(where: { $0.name == name }) {
                    controlColors.accentColored = preset.accentColored
                }
            }
        )
    }
}

/// The floating panel with `ControlColorsPanel`, from Control Colours… in the status item's menu.
final class ControlColorsWindow {
    static let shared = ControlColorsWindow()
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible == true }

    func show() {
        if panel == nil {
            let hostingController = NSHostingController(rootView: ControlColorsPanel())
            hostingController.sizingOptions = [.minSize, .maxSize]
            let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            panel.contentViewController = hostingController
            panel.title = "Control Colours"
            panel.isFloatingPanel = true
            panel.isReleasedWhenClosed = false
            panel.setContentSize(hostingController.sizeThatFits(in: panel.contentMaxSize))
            panel.center()
            panel.setFrameAutosaveName("ControlColors") // back where it was left, if it's been moved
            self.panel = panel
        }
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }
}
#endif

// MARK: - 4. Logic Controller
class ColorController: ObservableObject {
    static let shared = ColorController()
    
    // Mirror of the system Color Tint filter, kept the way System Settings keeps it: `intensity` is
    // the value the system stores, and `tint` is in degrees (0–360), stored as degrees / 360.
    @Published var isColorFilterOn: Bool = false { didSet { updateColorFilter() } }
    @Published var intensity: Float = 1.0 { didSet { colorSliderChanged() } }
    @Published var tint: Float = 0.0      { didSet { colorSliderChanged() } }
    @Published var brightness: Float = 1.0 { didSet { updateBrightness() } }
    /// Each display's own brightness, by its `Display.key`, while the displays are adjusted independently
    @Published var displayBrightness: [String: Float] = [:] { didSet { updateBrightness() } }

    /// The displays the Mac draws to, kept up to date as they're connected, disconnected and arranged
    @Published private(set) var displays: [Display] = Display.connected()
    /// Whether each display has a brightness of its own, in the Schedule too, rather than all of them
    /// having one. Saved as it's changed.
    @Published var adjustsDisplaysIndependently = UserDefaults.standard.bool(forKey: ColorController.adjustsDisplaysIndependentlyDefaultsKey) {
        didSet { displayAdjustmentChanged() }
    }
    private static let adjustsDisplaysIndependentlyDefaultsKey = "adjustsDisplaysIndependently"

    /// The displays with a brightness of their own, in the order their sliders are shown, or none while
    /// they all have one
    var independentDisplays: [Display] { adjustsDisplaysIndependently ? displays : [] }

    // Mirror of the system appearance: Dark or Light, whether it was chosen or Auto switched to it.
    @Published private(set) var isDarkAppearance: Bool = false
    /// True from when an appearance is chosen here until the screen has changed over to it.
    @Published private(set) var isChangingAppearance: Bool = false
    
    @Published var isAutoMode: Bool = false {
        didSet {
            scheduledIsDarkAppearance = nil
            scheduledDisplayBrightness = [:]
            if isAutoMode { applyAutoSettings() }
        }
    }

    /// The appearance the Schedule has for now, once it's been set. It's set again only when this
    /// changes, so an appearance chosen in System Settings or Control Center stays until then, rather
    /// than the screen fading back within the minute.
    private var scheduledIsDarkAppearance: Bool?
    /// Each display's brightness on the Schedule when it last set them, while they're adjusted
    /// independently. A display stepped with the brightness keys stays where they put it until the
    /// Schedule moves on, as the display macOS sets the brightness of does.
    private var scheduledDisplayBrightness: [String: Float] = [:]

    var isUserDraggingSlider: Bool = false
    /// The keyframe on screen while one of its sliders in the Schedule window is held down. Meanwhile
    /// the settings above aren't written to the system or read back from it, so they're what comes back.
    private var previewedKeyframeID: ColorKeyframe.ID?
    /// The display whose slider is being moved to where the system has set it, so it isn't set again
    private var syncingDisplay: CGDirectDisplayID?
    private var isSyncingColorFilter: Bool = false
    
    /// The displays the Mac sets the brightness of itself, which a slider follows as the system changes it
    private var displaysWithSystemBrightness: Set<CGDirectDisplayID> = []
    private var brightnessFollowers: [CGDirectDisplayID: BrightnessFollower] = [:]
    /// Where the brightness keys have put each display whose slider is still easing over to it
    private var brightnessKeyTargets: [String: Float] = [:]

    /// The display the Brightness slider follows while the displays have one brightness: the main
    /// display, or if it's dimmed in software, the first that the Mac sets the brightness of itself
    private var leadDisplay: CGDirectDisplayID? {
        let mainDisplay = CGMainDisplayID()
        if displaysWithSystemBrightness.contains(mainDisplay) { return mainDisplay }
        return displays.first { displaysWithSystemBrightness.contains($0.id) }?.id
    }
    
    private var timer: Timer?
    private var syncTimer: Timer?

    /// The Schedule's keyframes in time order, saved as they're edited. A keyframe whose time changes
    /// moves to its new place at once, and its row in the Schedule window with it.
    @Published var schedule: [ColorKeyframe] = ColorController.loadSchedule() {
        didSet {
            let sorted = schedule.sorted { $0.minute < $1.minute }
            if sorted != schedule { schedule = sorted }
            registerUndo(toSchedule: oldValue)
            if let data = try? JSONEncoder().encode(schedule) {
                UserDefaults.standard.set(data, forKey: Self.scheduleDefaultsKey)
            }
            applyAutoSettings()
            showPreview()
        }
    }

    private static let scheduleDefaultsKey = "schedule"

    /// Takes back and puts back changes to the schedule, for Undo and Redo in the Schedule window.
    let scheduleUndoManager = UndoManager()

    /// Changes that are undone in one go: the ones made while a slider is held, and the ones made to
    /// one keyframe's time straight after each other.
    private enum ScheduleEdit: Equatable {
        case slider
        case time(ColorKeyframe.ID)
    }
    private var timeEdit: ScheduleEdit?
    /// The edit the last change to the schedule was part of, which the next change may carry on.
    private var lastScheduleEdit: ScheduleEdit?

    private static func loadSchedule() -> [ColorKeyframe] {
        guard let data = UserDefaults.standard.data(forKey: scheduleDefaultsKey),
              let schedule = try? JSONDecoder().decode([ColorKeyframe].self, from: data),
              !schedule.isEmpty else { return ColorKeyframe.defaultSchedule }
        return schedule.sorted { $0.minute < $1.minute }
    }

    init() {
        displaysWithSystemBrightness = Set(displays.map(\.id).filter(GammaManager.shared.canSetBrightness))
        // Each display's slider starts where the display is, and the displays dimmed in software aren't
        // yet. Set first, as setting either sets the displays, and with only `brightness` they'd all take it.
        if adjustsDisplaysIndependently {
            self.displayBrightness = Dictionary(displays.map { ($0.key, GammaManager.shared.getNativeBrightness(of: $0.id) ?? 1.0) }) { first, _ in first }
        }
        if let leadDisplay, let nativeBrightness = GammaManager.shared.getNativeBrightness(of: leadDisplay) {
            self.brightness = nativeBrightness
        }
        
        // Follow displays being connected, disconnected and rearranged
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.displaysDidChange()
        }
        // An iPad's name can arrive after its display, which until then has macOS's own name for it
        NotificationCenter.default.addObserver(
            forName: Sidecar.connectedDevicesChangedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            if let self, Display.connected() != displays { displaysDidChange() }
        }

        // Follow changes made in System Settings (or anywhere else) to the color filter
        syncWithSystemColorFilter()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer = observer else { return }
                Unmanaged<ColorController>.fromOpaque(observer).takeUnretainedValue().syncWithSystemColorFilter()
            },
            ColorFilterManager.settingsChangedNotification as CFString,
            nil,
            .deliverImmediately
        )

        // And the same for the appearance, which Auto changes at sunrise and sunset too
        syncWithSystemAppearance()
        DistributedNotificationCenter.default().addObserver(
            forName: AppearanceManager.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.syncWithSystemAppearance()
        }
        
        timer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.applyAutoSettings()
        }

        // While the displays are adjusted independently, the brightness keys set the one under the pointer
        BrightnessKeys.shared.handlePress = { [weak self] isUp, isFine in
            self?.brightnessKeyPressed(isUp: isUp, isFine: isFine) ?? false
        }
        if adjustsDisplaysIndependently {
            BrightnessKeys.shared.start(askingPermission: false)
        }

        // 🚀 UPGRADE: 120 FPS polling (0.0083 seconds)
        let smoothSyncTimer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            self?.syncWithSystemBrightness()
            self?.easeTowardBrightnessKeyTargets()
        }
        RunLoop.main.add(smoothSyncTimer, forMode: .common)
        self.syncTimer = smoothSyncTimer
    }
    
    func syncWithSystemBrightness() {
        guard !isAutoMode, !isUserDraggingSlider, previewedKeyframeID == nil else {
            brightnessFollowers = [:]
            return 
        }
        
        // Each display the Mac sets the brightness of moves its own slider, or while the displays have
        // one brightness, the one the Brightness slider follows moves it
        if adjustsDisplaysIndependently {
            for display in displays where displaysWithSystemBrightness.contains(display.id) {
                follow(display.id, from: self[brightnessOf: display.key]) { self[brightnessOf: display.key] = $0 }
            }
        } else if let leadDisplay {
            follow(leadDisplay, from: brightness) { brightness = $0 }
        }
    }

    /// Moves a slider at `current` after the brightness the system has set a display to.
    private func follow(_ displayID: CGDirectDisplayID, from current: Float, by setBrightness: (Float) -> Void) {
        guard let systemBrightness = GammaManager.shared.getNativeBrightness(of: displayID) else { return }
        var follower = brightnessFollowers[displayID] ?? BrightnessFollower(systemBrightness: systemBrightness)
        if let brightness = follower.follow(systemBrightness, from: current) {
            syncingDisplay = displayID
            setBrightness(brightness)
            syncingDisplay = nil
        }
        brightnessFollowers[displayID] = follower
    }

    /// Steps the display under the pointer the way macOS steps the one it sets the brightness of: by a
    /// sixteenth, or a quarter of that with Option-Shift, from between two steps to the next one along.
    /// Returns false to leave the key to macOS: while the displays have one brightness, as they all
    /// follow the display macOS sets, and when that display is under the pointer and its only one.
    private func brightnessKeyPressed(isUp: Bool, isFine: Bool) -> Bool {
        guard adjustsDisplaysIndependently,
              let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let display = displays.first(where: { $0.id == number.uint32Value }),
              displaysWithSystemBrightness != [display.id] else { return false }

        let steps: Float = isFine ? 64 : 16
        let current = brightnessKeyTargets[display.key] ?? self[brightnessOf: display.key]
        let step = isUp ? (current * steps + 0.01).rounded(.down) + 1 : (current * steps - 0.01).rounded(.up) - 1
        brightnessKeyTargets[display.key] = min(max(step / steps, 0), 1)
        return true
    }

    /// Moves each slider the brightness keys have stepped a frame further over to where they put it,
    /// easing over as a slider following a key press on the display macOS sets does. Holding a slider
    /// stops them where they are.
    private func easeTowardBrightnessKeyTargets() {
        guard !brightnessKeyTargets.isEmpty else { return }
        guard !isUserDraggingSlider, previewedKeyframeID == nil else {
            brightnessKeyTargets = [:]
            return
        }
        for (display, target) in brightnessKeyTargets {
            let brightness = BrightnessFollower.ease(from: self[brightnessOf: display], to: target)
            self[brightnessOf: display] = brightness
            if brightness == target { brightnessKeyTargets[display] = nil }
        }
    }

    /// A display's brightness while the displays are adjusted independently, which is `brightness`
    /// until it's been set
    subscript(brightnessOf display: String) -> Float {
        get { displayBrightness[display] ?? brightness }
        set { displayBrightness[display] = newValue }
    }

    /// The displays carry on from where they are: split, each starts at the brightness they all had,
    /// and joined, they all take the brightness of the one the Brightness slider follows. Split, the
    /// brightness keys are caught as well, with permission, which macOS asks for the first time.
    private func displayAdjustmentChanged() {
        UserDefaults.standard.set(adjustsDisplaysIndependently, forKey: Self.adjustsDisplaysIndependentlyDefaultsKey)
        brightnessFollowers = [:]
        brightnessKeyTargets = [:]
        scheduledDisplayBrightness = [:]
        if adjustsDisplaysIndependently {
            displayBrightness = Dictionary(displays.map { ($0.key, brightness) }) { first, _ in first }
            // After the switch has redrawn, as macOS's request for permission comes up over it
            DispatchQueue.main.async { [weak self] in
                if self?.adjustsDisplaysIndependently == true { BrightnessKeys.shared.start(askingPermission: true) }
            }
        } else {
            BrightnessKeys.shared.stop()
            if let display = displays.first(where: { $0.id == leadDisplay }) ?? displays.first {
                brightness = self[brightnessOf: display.key]
            }
        }
        applyAutoSettings()
    }

    /// Lists the displays again, and sets them all again, as the system puts back the colors of a
    /// display it changes. A display connected for the first time while they're adjusted independently
    /// starts where it is.
    private func displaysDidChange() {
        displays = Display.connected()
        displaysWithSystemBrightness = Set(displays.map(\.id).filter(GammaManager.shared.canSetBrightness))
        brightnessFollowers = [:]
        GammaManager.shared.reset()

        let newDisplays = displays.filter { displayBrightness[$0.key] == nil }
        if adjustsDisplaysIndependently && !newDisplays.isEmpty {
            displayBrightness.merge(newDisplays.map { ($0.key, GammaManager.shared.getNativeBrightness(of: $0.id) ?? 1.0) }) { current, _ in current }
        }
        applyAutoSettings()
        updateBrightness()
        showPreview()
    }
    
    func applyAutoSettings() {
        guard isAutoMode else { return }
        
        let now = Date()
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        guard let settings = ColorKeyframe.settings(in: schedule, at: Double(hour * 60 + minute)) else { return }

        self.tint = settings.tint
        self.intensity = settings.filterIntensity
        self.isColorFilterOn = settings.isColorFilterOn
        self.brightness = settings.brightness
        if adjustsDisplaysIndependently {
            let scheduled = Dictionary(displays.map { ($0.key, settings.brightness(of: $0.key)) }) { first, _ in first }
            // One the Schedule hasn't moved on for stays where it is, which is elsewhere if the brightness keys stepped it
            self.displayBrightness = Dictionary(uniqueKeysWithValues: scheduled.map { display, brightness in
                (display, scheduledDisplayBrightness[display] == brightness ? displayBrightness[display] ?? brightness : brightness)
            })
            scheduledDisplayBrightness = scheduled
        }
        if settings.isDarkAppearance != scheduledIsDarkAppearance {
            scheduledIsDarkAppearance = settings.isDarkAppearance
            applyScheduledAppearance()
        }
    }

    /// Adds a keyframe at the next free half hour, set to what the schedule already has there, and returns its ID.
    @discardableResult
    func addKeyframe() -> ColorKeyframe.ID {
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let nextHalfHour = ((now.hour! * 60 + now.minute!) / 30 + 1) * 30
        let taken = Set(schedule.map(\.minute))
        let minute = (0..<48).lazy.map { (nextHalfHour + $0 * 30) % 1440 }.first { !taken.contains($0) } ?? nextHalfHour % 1440

        let settings = ColorKeyframe.settings(in: schedule, at: Double(minute))
            ?? ColorKeyframe.Settings(intensity: isColorFilterOn ? intensity : 0, tint: tint, brightness: brightness, displayBrightness: displayBrightness, isDarkAppearance: isDarkAppearance)
        let keyframe = ColorKeyframe(
            minute: minute,
            isColorFilterOn: settings.isColorFilterOn,
            intensity: settings.filterIntensity,
            tint: settings.tint,
            brightness: settings.brightness,
            displayBrightness: settings.displayBrightness,
            isDarkAppearance: settings.isDarkAppearance
        )
        schedule.append(keyframe)
        return keyframe.id
    }

    /// The schedule always keeps at least one keyframe.
    func deleteKeyframe(_ id: ColorKeyframe.ID) {
        guard schedule.count > 1 else { return }
        schedule.removeAll { $0.id == id }
    }

    /// Sets a keyframe's time. Setting the same keyframe's time again straight after is undone with it.
    func setMinute(_ minute: Int, ofKeyframe id: ColorKeyframe.ID) {
        guard let index = schedule.firstIndex(where: { $0.id == id }) else { return }
        timeEdit = .time(id)
        schedule[index].minute = minute
        timeEdit = nil
    }

    /// Registers the way back from a change to the schedule, unless it carries on the edit the last
    /// change was part of. Undoing puts `previous` back, which registers the way forward for Redo.
    private func registerUndo(toSchedule previous: [ColorKeyframe]) {
        // Putting the keyframes in time order sets the schedule a second time, which isn't a change of its own
        guard schedule != previous.sorted(by: { $0.minute < $1.minute }) else { return }
        let edit = previewedKeyframeID == nil ? timeEdit : .slider
        defer { lastScheduleEdit = edit }
        if let edit, edit == lastScheduleEdit { return }

        scheduleUndoManager.registerUndo(withTarget: self) { controller in
            // Rows that stay slide to the places their times put them back in, as they do when a time is set
            let keepsRows = Set(previous.map(\.id)) == Set(controller.schedule.map(\.id))
            withAnimation(keepsRows ? .default : nil) { controller.schedule = previous }
        }
    }

    /// Makes the next change to the schedule one to undo by itself, whatever the last one was.
    func endScheduleEdit() {
        lastScheduleEdit = nil
    }

    /// Shows the keyframe with this ID on screen, following its edits, until this is called with nil,
    /// which puts back the settings that were there before (or the Schedule's for now, if it's on).
    func preview(_ id: ColorKeyframe.ID?) {
        endScheduleEdit() // each hold of a slider is undone by itself
        previewedKeyframeID = id
        if id == nil {
            updateColorFilter()
            updateBrightness()
        } else {
            showPreview()
        }
    }

    private func showPreview() {
        guard let keyframe = schedule.first(where: { $0.id == previewedKeyframeID }) else { return }
        ColorFilterManager.shared.write(ColorFilterManager.State(isOn: keyframe.isColorFilterOn, hue: keyframe.tint / 360, intensity: keyframe.intensity))
        GammaManager.shared.setBrightness(brightnessByDisplay(keyframe.brightness, keyframe.displayBrightness))
    }

    /// Dragging Intensity or Tint turns the filter on, the way raising Intensity from zero used to.
    private func colorSliderChanged() {
        if !isColorFilterOn && !isAutoMode && !isSyncingColorFilter {
            isColorFilterOn = true // its didSet writes the new slider values as well
        } else {
            updateColorFilter()
        }
    }
    
    func updateColorFilter() {
        guard !isSyncingColorFilter, previewedKeyframeID == nil else { return }
        ColorFilterManager.shared.write(ColorFilterManager.State(isOn: isColorFilterOn, hue: tint / 360, intensity: intensity))
    }

    func syncWithSystemColorFilter() {
        guard previewedKeyframeID == nil, let state = ColorFilterManager.shared.read() else { return }

        isSyncingColorFilter = true
        if isColorFilterOn != state.isOn { isColorFilterOn = state.isOn }
        if abs(tint - state.hue * 360) > 0.0001 { tint = state.hue * 360 }
        if abs(intensity - state.intensity) > 0.0001 { intensity = state.intensity }
        isSyncingColorFilter = false
    }
    
    func updateBrightness() {
        guard previewedKeyframeID == nil else { return }
        GammaManager.shared.setBrightness(brightnessByDisplay(brightness, displayBrightness), skippingHardwareOf: syncingDisplay)
    }

    /// Each display's brightness: `brightness` for all of them, or while they're adjusted independently,
    /// each one's own from `displayBrightness`, if it has one.
    private func brightnessByDisplay(_ brightness: Float, _ displayBrightness: [String: Float]) -> [CGDirectDisplayID: Float] {
        Dictionary(displays.map { display in
            (display.id, adjustsDisplaysIndependently ? displayBrightness[display.key] ?? brightness : brightness)
        }) { first, _ in first }
    }

    /// Chooses Light or Dark in System Settings' order: the choice shows at once, the picker dims, and
    /// only when it has does the screen change over, after which the picker comes back. The screen
    /// fades from a picture of itself, so the choice has to be showing before that's taken, or it only
    /// appears as the fade ends. Choices made before the screen has changed over are ignored.
    func chooseAppearance(isDark: Bool) {
        guard !isChangingAppearance else { return }
        guard isDark != isDarkAppearance else {
            AppearanceManager.shared.setDark(isDark) // nothing to change over to, but this turns Auto off
            return
        }

        isDarkAppearance = isDark
        withAnimation(.default, completionCriteria: .logicallyComplete) {
            isChangingAppearance = true
        } completion: { [weak self] in
            self?.changeSystemAppearance(isDark: isDark)
        }
    }

    /// Changes the screen over to the Schedule's appearance in the same order. The picker is dimmed
    /// already while the Schedule is on, but whatever changed the Schedule's appearance (a row in the
    /// Schedule window, or the Schedule switch) shows it first for as long as the picker would dim.
    private func applyScheduledAppearance() {
        guard isAutoMode, let isDark = scheduledIsDarkAppearance, !isChangingAppearance else { return }
        guard isDark != isDarkAppearance else {
            AppearanceManager.shared.setDark(isDark) // nothing to change over to, but Auto would change it at sunset
            return
        }

        isDarkAppearance = isDark
        isChangingAppearance = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.changeSystemAppearance(isDark: isDark)
        }
    }

    private func changeSystemAppearance(isDark: Bool) {
        AppearanceManager.shared.setDark(isDark) { [weak self] in
            guard let self else { return }
            isChangingAppearance = false
            syncWithSystemAppearance()
            // The Schedule moved on to another appearance before the screen had changed over
            if scheduledIsDarkAppearance != isDark { applyScheduledAppearance() }
        }
    }

    func syncWithSystemAppearance() {
        guard !isChangingAppearance, let isDark = AppearanceManager.shared.isDark() else { return }
        if isDarkAppearance != isDark { isDarkAppearance = isDark }
    }
    
    func reset() {
        isAutoMode = false
        brightnessFollowers = [:]
        brightnessKeyTargets = [:]
        isColorFilterOn = false
        brightness = 1.0
        displayBrightness = [:]
    }
}

/// Follows a display's brightness as the system changes it (with the brightness keys, Control Center
/// or System Settings) for a slider to show: it keeps up while the system's slider is dragged, and eases
/// over to a jump made with a click or a key.
struct BrightnessFollower {
    private var lastSystemBrightness: Float
    private var lastNativeUpdateTime: TimeInterval = 0
    private var targetSystemBrightness: Float?

    init(systemBrightness: Float) {
        lastSystemBrightness = systemBrightness
    }

    /// Where a slider at `current` moves to now that the display is at `systemBrightness`, or nil if it stays.
    mutating func follow(_ systemBrightness: Float, from current: Float) -> Float? {
        var current = current
        var newBrightness: Float?
        let stepChange = abs(systemBrightness - lastSystemBrightness)
        
        // 1. Did the native brightness just move?
        if stepChange > 0.001 {
            let now = Date().timeIntervalSinceReferenceDate
            let timeSinceLastUpdate = now - lastNativeUpdateTime
            
            lastNativeUpdateTime = now
            lastSystemBrightness = systemBrightness
            
            // If updates are firing rapidly (< 50ms apart), the user is continuously dragging.
            if timeSinceLastUpdate < 0.05 {
                // Abort any ongoing animations and snap instantly to perfectly follow the drag!
                targetSystemBrightness = nil
                current = systemBrightness
                newBrightness = systemBrightness
            } else {
                // The value changed after being idle. This is the first frame of a new interaction.
                if stepChange > 0.04 {
                    // Large jump -> A Click or Keyboard Tap. Start the ease-out animation!
                    targetSystemBrightness = systemBrightness
                } else {
                    // Small jump -> The very beginning of a slow drag. Snap instantly.
                    current = systemBrightness
                    newBrightness = systemBrightness
                }
            }
        } 
        
        // 2. Process the ease-out animation if we have a target
        if let target = targetSystemBrightness {
            newBrightness = Self.ease(from: current, to: target)
            if newBrightness == target { targetSystemBrightness = nil }
        } else if stepChange <= 0.001 {
            // 3. Not animating, and no native movement this frame.
            // Clean up any microscopic drift to ensure 100% sync.
            let delta = abs(current - systemBrightness)
            if delta > 0.002 {
                newBrightness = systemBrightness
            }
        }
        return newBrightness
    }

    /// One frame of a slider's ease-out from `current` over to `target`, which it lands on exactly.
    static func ease(from current: Float, to target: Float) -> Float {
        let diff = target - current

        // Snap to the target once we are visually indistinguishable from it
        if abs(diff) < 0.002 { return target }

        var step = diff * 0.12
        let minSpeed: Float = 0.002

        if abs(step) < minSpeed {
            step = diff > 0 ? minSpeed : -minSpeed
        }

        // CRITICAL FIX: Prevent Overshoot
        // This stops the minSpeed from making the slider vibrate/jitter at the very end
        if abs(step) > abs(diff) {
            step = diff
        }

        return current + step
    }
}

/// A point on the Schedule: the settings it reaches `minute` minutes after midnight. In between, the
/// settings move steadily from one keyframe to the next, and from the last round midnight to the first,
/// except the appearance, which can't: it changes over at each keyframe and stays until the next.
struct ColorKeyframe: Identifiable, Codable, Equatable {
    var id = UUID()
    var minute: Int
    var isColorFilterOn: Bool
    var intensity: Float // kept while the filter is off, for when it's turned back on
    var tint: Float      // degrees
    var brightness: Float
    /// Each display's own brightness, by its `Display.key`, for while the displays are adjusted
    /// independently. Kept while they aren't, for when they are again.
    var displayBrightness: [String: Float] = [:]
    var isDarkAppearance: Bool

    /// A display's brightness, which is `brightness` until it's been given its own
    subscript(brightnessOf display: String) -> Float {
        get { displayBrightness[display] ?? brightness }
        set { displayBrightness[display] = newValue }
    }

    static let defaultSchedule: [ColorKeyframe] = [
        ColorKeyframe(minute: 5 * 60 + 30,  isColorFilterOn: true,  intensity: 0.90, tint: 0,   brightness: 0.82, isDarkAppearance: true),
        ColorKeyframe(minute: 6 * 60,       isColorFilterOn: false, intensity: 0.25, tint: 180, brightness: 1.00, isDarkAppearance: false),
        ColorKeyframe(minute: 18 * 60,      isColorFilterOn: false, intensity: 0.25, tint: 180, brightness: 1.00, isDarkAppearance: false),
        ColorKeyframe(minute: 18 * 60 + 30, isColorFilterOn: true,  intensity: 0.80, tint: 0,   brightness: 0.92, isDarkAppearance: true),
        ColorKeyframe(minute: 20 * 60 + 30, isColorFilterOn: true,  intensity: 0.90, tint: 0,   brightness: 0.68, isDarkAppearance: true)
    ]

    struct Settings {
        /// 0 where the filter is off, so fading to or from an off keyframe passes the filter's lowest
        /// intensity part way, and that's where the filter switches.
        var intensity: Float
        var tint: Float
        var brightness: Float
        /// The brightness of each display either keyframe has one of its own for
        var displayBrightness: [String: Float] = [:]
        /// The appearance of the keyframe at or before this time
        var isDarkAppearance: Bool

        /// A display's brightness, or with no display, the brightness for all of them
        func brightness(of display: String?) -> Float {
            display.flatMap { displayBrightness[$0] } ?? brightness
        }

        /// The system filter bottoms out at its "Low" intensity, so below that the schedule switches it off
        var isColorFilterOn: Bool { intensity >= ColorFilterManager.shared.intensityRange.lowerBound }
        var filterIntensity: Float {
            let intensityRange = ColorFilterManager.shared.intensityRange
            return min(max(intensity, intensityRange.lowerBound), intensityRange.upperBound)
        }

        /// Roughly how white looks on a display with these settings, for the Schedule window's preview.
        func previewColor(ofDisplay display: String? = nil) -> Color {
            Color(hue: Double(tint) / 360, saturation: isColorFilterOn ? Double(filterIntensity) : 0, brightness: Double(brightness(of: display)))
        }
    }

    /// The settings `schedule` has reached `minute` minutes after midnight, or nil if it's empty.
    static func settings(in schedule: [ColorKeyframe], at minute: Double) -> Settings? {
        let keyframes = schedule.sorted { $0.minute < $1.minute }
        guard !keyframes.isEmpty else { return nil }

        // The keyframes either side of `minute`, either of which may be across midnight from it
        let startIndex = keyframes.lastIndex { Double($0.minute) <= minute }
        let start = keyframes[startIndex ?? keyframes.count - 1]
        let end = keyframes[((startIndex ?? -1) + 1) % keyframes.count]
        let startMinute = Double(start.minute) - (startIndex == nil ? 1440 : 0)
        var endMinute = Double(end.minute)
        if endMinute <= startMinute { endMinute += 1440 }
        let progress = Float((minute - startMinute) / (endMinute - startMinute))

        // An off keyframe's tint doesn't show, so fading to or from one holds the other one's tint,
        // and the tint takes the short way round the hue circle, so red to pink doesn't pass through green
        let startTint = start.isColorFilterOn || !end.isColorFilterOn ? start.tint : end.tint
        let endTint = end.isColorFilterOn || !start.isColorFilterOn ? end.tint : start.tint
        var tintChange = (endTint - startTint).truncatingRemainder(dividingBy: 360)
        if tintChange > 180 { tintChange -= 360 } else if tintChange < -180 { tintChange += 360 }
        var tint = (startTint + tintChange * progress).truncatingRemainder(dividingBy: 360)
        if tint < 0 { tint += 360 }

        let startIntensity = start.isColorFilterOn ? start.intensity : 0
        let endIntensity = end.isColorFilterOn ? end.intensity : 0
        let displays = Set(start.displayBrightness.keys).union(end.displayBrightness.keys)
        return Settings(
            intensity: startIntensity + (endIntensity - startIntensity) * progress,
            tint: tint,
            brightness: start.brightness + (end.brightness - start.brightness) * progress,
            displayBrightness: Dictionary(uniqueKeysWithValues: displays.map { display in
                (display, start[brightnessOf: display] + (end[brightnessOf: display] - start[brightnessOf: display]) * progress)
            }),
            isDarkAppearance: start.isDarkAppearance
        )
    }
}

extension ColorKeyframe {
    /// Keyframes saved before they had an appearance come back Dark where the color filter is on, as
    /// in the default schedule, and ones saved before displays had a brightness each come back without.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        minute = try container.decode(Int.self, forKey: .minute)
        isColorFilterOn = try container.decode(Bool.self, forKey: .isColorFilterOn)
        intensity = try container.decode(Float.self, forKey: .intensity)
        tint = try container.decode(Float.self, forKey: .tint)
        brightness = try container.decode(Float.self, forKey: .brightness)
        displayBrightness = try container.decodeIfPresent([String: Float].self, forKey: .displayBrightness) ?? [:]
        isDarkAppearance = try container.decodeIfPresent(Bool.self, forKey: .isDarkAppearance) ?? isColorFilterOn
    }
}

// MARK: - 5. System Manager (Gamma & Hardware Brightness)
/// A display the Mac draws to. Mirrored displays are one of these, and take its brightness.
struct Display: Identifiable, Hashable {
    let id: CGDirectDisplayID
    /// The display's UUID, which, unlike its ID, stays the same while it's unplugged and between launches
    let key: String
    /// Its name in System Settings › Displays
    let name: String

    /// The displays from left to right, as they're arranged in System Settings › Displays.
    static func connected() -> [Display] {
        NSScreen.screens
            .sorted { ($0.frame.minX, -$0.frame.maxY) < ($1.frame.minX, -$1.frame.maxY) }
            .compactMap { screen in
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                      let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
                      let key = CFUUIDCreateString(nil, uuid) as String? else { return nil }
                let sidecarName = isSidecar(number.uint32Value) ? Sidecar.deviceName : nil
                return Display(id: number.uint32Value, key: key, name: sidecarName ?? screen.localizedName)
            }
    }

    /// Whether a display is an iPad used with Sidecar, which System Settings tells by its vendor and
    /// model codes, "aapl" and "iPad"
    static func isSidecar(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(displayID) == 0x6161_706C && CGDisplayModelNumber(displayID) == 0x6950_6164
    }
}

/// The iPad used with Sidecar, as the private SidecarCore framework knows it. System Settings names a
/// Sidecar display after it ("iPad"), rather than "Sidecar Display (AirPlay)" as macOS otherwise does.
enum Sidecar {
    /// Posted when an iPad is connected with Sidecar, or disconnected
    static let connectedDevicesChangedNotification = Notification.Name("SidecarDisplayManagerConnectedDevicesChangedNotification")

    private static let manager: NSObject? = {
        let sharedManager = NSSelectorFromString("sharedManager")
        guard dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore", RTLD_LAZY) != nil,
              let managerClass = NSClassFromString("SidecarDisplayManager") as? NSObject.Type,
              managerClass.responds(to: sharedManager) else { return nil }
        return managerClass.perform(sharedManager)?.takeUnretainedValue() as? NSObject
    }()

    /// The connected iPad's name, as it's called on the iPad. Like System Settings, this takes the first
    /// iPad connected, as Sidecar connects one at a time.
    static var deviceName: String? {
        guard let manager, manager.responds(to: NSSelectorFromString("connectedDevices")),
              let device = (manager.value(forKey: "connectedDevices") as? [NSObject])?.first,
              device.responds(to: NSSelectorFromString("name")),
              let name = device.value(forKey: "name") as? String, !name.isEmpty else { return nil }
        return name
    }
}

class GammaManager {
    static let shared = GammaManager()

    /// The brightness each display was last set to, so one that hasn't changed isn't set again
    private var lastBrightness: [CGDirectDisplayID: Float] = [:]
    /// The displays dimmed in software, and how far
    private var softwareBrightness: [CGDirectDisplayID: Float] = [:]
    /// The dark layer over each display that's sent its picture, as dimming it in software can't reach it
    private var dimmingWindows: [CGDirectDisplayID: DimmingWindow] = [:]
    /// Whether each display is sent its picture, as it was when last asked
    private var streamedDisplays: [CGDirectDisplayID: Bool] = [:]

    private var setBrightnessFunc: (@convention(c) (CGDirectDisplayID, Float) -> Int32)?
    private var getBrightnessFunc: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32)?
    private var canChangeBrightnessFunc: (@convention(c) (CGDirectDisplayID) -> Bool)?
    private var displayInfoFunc: (@convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?)?

    init() {
        if let handle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY),
           let sym = dlsym(handle, "CoreDisplay_DisplayCreateInfoDictionary") {
            self.displayInfoFunc = unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?).self)
        }
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        if let handle = handle {
            if let sym = dlsym(handle, "DisplayServicesSetBrightness") {
                self.setBrightnessFunc = unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID, Float) -> Int32).self)
            }
            if let sym = dlsym(handle, "DisplayServicesGetBrightness") {
                self.getBrightnessFunc = unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32).self)
            }
            if let sym = dlsym(handle, "DisplayServicesCanChangeBrightness") {
                self.canChangeBrightnessFunc = unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID) -> Bool).self)
            }
        }
    }
    
    /// Whether the Mac sets this display's brightness itself, rather than it being dimmed in software
    func canSetBrightness(of displayID: CGDirectDisplayID) -> Bool {
        canChangeBrightnessFunc?(displayID) ?? false
    }

    func getNativeBrightness(of displayID: CGDirectDisplayID) -> Float? {
        guard let getFunc = getBrightnessFunc else { return nil }
        var brightness: Float = 1.0
        let result = getFunc(displayID, &brightness)
        return result == 0 ? brightness : nil
    }

    /// Sets each display to its brightness, a display that mirrors another to that one's, and leaves
    /// out any display without one. `skippedHardware` is a display the system has set already, which is
    /// only dimmed in software if it can't be set directly.
    func setBrightness(_ displayBrightness: [CGDirectDisplayID: Float], skippingHardwareOf skippedHardware: CGDirectDisplayID? = nil) {
        let displays = getAllDisplays()
        lastBrightness = lastBrightness.filter { displays.contains($0.key) }
        var newSoftwareBrightness = softwareBrightness.filter { displays.contains($0.key) }
        for (displayID, window) in dimmingWindows where !displays.contains(displayID) || !isStreamed(displayID) {
            window.close()
            dimmingWindows[displayID] = nil
        }

        for displayID in displays {
            let mirrorSet = CGDisplayPrimaryDisplay(displayID)
            guard let brightness = displayBrightness[displayID]
                    ?? displayBrightness.first(where: { CGDisplayPrimaryDisplay($0.key) == mirrorSet })?.value else { continue }
            if let lastBrightness = lastBrightness[displayID], abs(brightness - lastBrightness) < 0.001 {
                continue
            }

            lastBrightness[displayID] = brightness

            // A display that's sent its picture is dimmed under a dark layer, which the displays mirroring
            // it show as well, so they're left as they are. It keeps a tenth of the picture, as under a
            // darker layer the iPad looks black.
            if isStreamed(mirrorSet) {
                if displayID == mirrorSet { setDimmingWindow(of: displayID, to: max(brightness, 0.1)) }
                newSoftwareBrightness[displayID] = nil
                continue
            }

            var hardwareBrightnessSucceeded = false

            if canSetBrightness(of: displayID) {
                if displayID != skippedHardware {
                    if let setBrightnessFunc = setBrightnessFunc {
                        let result = setBrightnessFunc(displayID, brightness)
                        if result == 0 { hardwareBrightnessSucceeded = true }
                    }
                } else {
                    hardwareBrightnessSucceeded = true
                }
            }

            let softwareBrightness = hardwareBrightnessSucceeded ? 1.0 : max(brightness, 0.05)
            newSoftwareBrightness[displayID] = softwareBrightness < 0.999 ? softwareBrightness : nil
        }

        // A display's own colors can only be put back along with every other display's, so the ones
        // still dimmed are then dimmed again
        let needsGlobalRestore = softwareBrightness.keys.contains { displays.contains($0) && newSoftwareBrightness[$0] == nil }
        if needsGlobalRestore {
            CGDisplayRestoreColorSyncSettings()
        }
        for (displayID, softwareBrightness) in newSoftwareBrightness where needsGlobalRestore || self.softwareBrightness[displayID] != softwareBrightness {
            let table = calculateGammaTable(brightness: softwareBrightness)
            CGSetDisplayTransferByTable(displayID, UInt32(table.count), table, table, table)
        }
        softwareBrightness = newSoftwareBrightness
    }

    func reset() {
        CGDisplayRestoreColorSyncSettings()
        dimmingWindows.values.forEach { $0.close() }
        dimmingWindows = [:]
        streamedDisplays = [:]
        lastBrightness = [:]
        softwareBrightness = [:]
    }

    /// Whether a display is sent its picture, as Sidecar's iPad and AirPlay displays are. It's sent
    /// before the display's colors are adjusted, so dimming it in software doesn't change it.
    private func isStreamed(_ displayID: CGDirectDisplayID) -> Bool {
        if let isStreamed = streamedDisplays[displayID] { return isStreamed }
        let info = displayInfoFunc?(displayID)?.takeRetainedValue() as NSDictionary?
        let isStreamed = info?["kCGDisplayIsVirtualDevice"] as? Bool ?? false
        streamedDisplays[displayID] = isStreamed
        return isStreamed
    }

    /// Lays a dark layer over a display that lets `brightness` of its picture through, or none at full brightness
    private func setDimmingWindow(of displayID: CGDirectDisplayID, to brightness: Float) {
        guard brightness < 0.999,
              let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }) else {
            dimmingWindows.removeValue(forKey: displayID)?.close()
            return
        }
        let window = dimmingWindows[displayID] ?? DimmingWindow()
        window.setFrame(screen.frame, display: false)
        window.alphaValue = CGFloat(1 - brightness)
        window.orderFrontRegardless()
        dimmingWindows[displayID] = window
    }

    private func getAllDisplays() -> [CGDirectDisplayID] {
        var displayCount: UInt32 = 0
        var result = CGGetActiveDisplayList(0, nil, &displayCount)
        if result != .success { return [CGMainDisplayID()] }
        
        let allocated = Int(displayCount)
        let activeDisplays = UnsafeMutablePointer<CGDirectDisplayID>.allocate(capacity: allocated)
        result = CGGetActiveDisplayList(displayCount, activeDisplays, &displayCount)
        
        if result != .success {
            activeDisplays.deallocate()
            return[CGMainDisplayID()]
        }
        
        var displays: [CGDirectDisplayID] = []
        for i in 0..<Int(displayCount) {
            displays.append(activeDisplays[i])
        }
        
        activeDisplays.deallocate()
        return displays
    }
    
    private func calculateGammaTable(brightness: Float) -> [CGGammaValue] {
        let tableSize = 256
        return (0..<tableSize).map { i in
            Float(i) / Float(tableSize - 1) * brightness
        }
    }
}

/// A black layer over a whole display that clicks go through, which darkens its picture as dimming it in
/// software does: over everything (the menu bar and full-screen apps too) and on every Space.
final class DimmingWindow: NSWindow {
    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        backgroundColor = .black
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }
}

// MARK: - Brightness Keys
/// Catches the brightness keys before macOS acts on them, so a key can set a display macOS doesn't.
/// Catching keys takes permission in System Settings › Privacy & Security › Accessibility; until
/// it's given, they're left to macOS.
final class BrightnessKeys {
    static let shared = BrightnessKeys()

    /// What a press does: brightness up or down, a quarter step (with Option-Shift) or not. Returns
    /// whether it set a display, in which case macOS doesn't see the key. Called on the main thread.
    var handlePress: (_ isUp: Bool, _ isFine: Bool) -> Bool = { _, _ in false }

    /// Apple's keyboards send the brightness keys as these key codes; others send them as media keys,
    /// like the volume keys
    private static let brightnessUpKeyCode: Int64 = 144
    private static let brightnessDownKeyCode: Int64 = 145

    private var tap: CFMachPort?
    /// Checks for permission while it's waited for
    private var permissionTimer: Timer?
    /// The keys (up or down) whose press was handled here, so their release is kept from macOS as
    /// well. Only touched on the tap's thread.
    private var handledKeys: Set<Bool> = []

    /// Starts catching the keys, or once there's permission, if there isn't yet. `askingPermission`
    /// puts up macOS's request for it, which leads to System Settings.
    func start(askingPermission: Bool) {
        guard tap == nil else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: askingPermission] as CFDictionary

        // At the head of the session's taps, where the keys arrive before macOS acts on them
        let keys = CGEventMask(1 << NX_SYSDEFINED) | CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard AXIsProcessTrustedWithOptions(options), let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: keys,
            callback: { _, type, event, _ in
                BrightnessKeys.shared.handle(type, event) ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else {
            permissionTimer = permissionTimer ?? Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.start(askingPermission: false)
            }
            return
        }
        permissionTimer?.invalidate()
        permissionTimer = nil
        self.tap = tap

        // Every key goes through the tap, so it runs on a thread of its own: typing never waits on
        // the main thread, which only hears about the brightness keys. The thread ends with the tap.
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopRun()
        }
        thread.name = "Brightness Keys"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap) // which takes it off its thread's run loop, and so ends the thread
        self.tap = nil
    }

    /// Whether `event` is a brightness key dealt with here. Presses with Option alone (which opens
    /// Displays settings), Control or Command go on to macOS.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout {
            DispatchQueue.main.async { [self] in
                if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            }
            return false
        }
        guard let (isUp, isPress) = brightnessKey(type, event) else { return false }
        guard isPress else { return handledKeys.remove(isUp) != nil }

        let modifiers = event.flags
        let isFine = modifiers.contains([.maskAlternate, .maskShift])
        guard !modifiers.contains(.maskControl), !modifiers.contains(.maskCommand),
              isFine || !modifiers.contains(.maskAlternate),
              DispatchQueue.main.sync(execute: { handlePress(isUp, isFine) }) else {
            handledKeys.remove(isUp)
            return false
        }
        handledKeys.insert(isUp)
        return true
    }

    /// Which brightness key `event` is, if it's one, and whether it's a press (or its repeat while
    /// the key is held) or a release.
    private func brightnessKey(_ type: CGEventType, _ event: CGEvent) -> (isUp: Bool, isPress: Bool)? {
        if type == .keyDown || type == .keyUp {
            switch event.getIntegerValueField(.keyboardEventKeycode) {
            case Self.brightnessUpKeyCode: return (true, type == .keyDown)
            case Self.brightnessDownKeyCode: return (false, type == .keyDown)
            default: return nil
            }
        }
        guard type.rawValue == UInt32(NX_SYSDEFINED),
              let keyEvent = NSEvent(cgEvent: event),
              Int32(keyEvent.subtype.rawValue) == NX_SUBTYPE_AUX_CONTROL_BUTTONS else { return nil }
        let key = Int32((keyEvent.data1 & 0xFFFF0000) >> 16)
        guard key == NX_KEYTYPE_BRIGHTNESS_UP || key == NX_KEYTYPE_BRIGHTNESS_DOWN else { return nil }
        // 0xA is a press, 0xB a release
        return (key == NX_KEYTYPE_BRIGHTNESS_UP, (keyEvent.data1 & 0xFF00) >> 8 == 0xA)
    }
}

// MARK: - 6. Color Filter Manager (Accessibility Color Filters)
/// Reads and writes the Color Tint filter in System Settings › Accessibility › Display › Color Filters.
/// System Settings drives it through these MediaAccessibility functions (exported, but not in the
/// public headers), and the OS applies the filter itself, so it keeps working outside this app.
class ColorFilterManager {
    static let shared = ColorFilterManager()
    
    /// Darwin notification MediaAccessibility posts whenever any display filter setting changes.
    static let settingsChangedNotification = "com.apple.mediaaccessibility.displayFilterSettingsChanged"
    
    struct State {
        var isOn: Bool
        var hue: Float
        var intensity: Float
    }
    
    /// The range of System Settings' Intensity slider (`kMADisplayFilterPrefSingleColorIntensityMin`...`Max`).
    private(set) var intensityRange: ClosedRange<Float> = 0.25...1.0
    
    // The on/off switch and filter type are stored per category. Category 1 is "Color",
    // and type 16 within it is "Color Tint".
    private let colorCategory = 1
    private let colorTintType = 16
    
    private var getCategoryEnabledFunc: (@convention(c) (Int) -> Bool)?
    private var setCategoryEnabledFunc: (@convention(c) (Int, Bool) -> Void)?
    private var getTypeFunc: (@convention(c) (Int) -> Int)?
    private var setTypeFunc: (@convention(c) (Int, Int) -> Void)?
    private var getHueFunc: (@convention(c) () -> Double)?
    private var setHueFunc: (@convention(c) (Double) -> Void)?
    private var getIntensityFunc: (@convention(c) () -> Double)?
    private var setIntensityFunc: (@convention(c) (Double) -> Void)?
    
    init() {
        guard let handle = dlopen("/System/Library/Frameworks/MediaAccessibility.framework/MediaAccessibility", RTLD_LAZY) else { return }
        
        func load<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        
        getCategoryEnabledFunc = load("MADisplayFilterPrefGetCategoryEnabled", as: (@convention(c) (Int) -> Bool).self)
        setCategoryEnabledFunc = load("MADisplayFilterPrefSetCategoryEnabled", as: (@convention(c) (Int, Bool) -> Void).self)
        getTypeFunc = load("MADisplayFilterPrefGetType", as: (@convention(c) (Int) -> Int).self)
        setTypeFunc = load("MADisplayFilterPrefSetType", as: (@convention(c) (Int, Int) -> Void).self)
        getHueFunc = load("MADisplayFilterPrefGetSingleColorHue", as: (@convention(c) () -> Double).self)
        setHueFunc = load("MADisplayFilterPrefSetSingleColorHue", as: (@convention(c) (Double) -> Void).self)
        getIntensityFunc = load("MADisplayFilterPrefGetSingleColorIntensity", as: (@convention(c) () -> Double).self)
        setIntensityFunc = load("MADisplayFilterPrefSetSingleColorIntensity", as: (@convention(c) (Double) -> Void).self)
        
        if let minSym = dlsym(handle, "kMADisplayFilterPrefSingleColorIntensityMin"),
           let maxSym = dlsym(handle, "kMADisplayFilterPrefSingleColorIntensityMax") {
            intensityRange = Float(minSym.load(as: Double.self))...Float(maxSym.load(as: Double.self))
        }
    }
    
    /// `isOn` is only true when the Color Filters switch is on *and* the filter type is Color Tint.
    func read() -> State? {
        guard let getCategoryEnabled = getCategoryEnabledFunc, let getType = getTypeFunc,
              let getHue = getHueFunc, let getIntensity = getIntensityFunc else { return nil }
        
        let isOn = getCategoryEnabled(colorCategory) && getType(colorCategory) == colorTintType
        return State(isOn: isOn, hue: Float(getHue()), intensity: Float(getIntensity()))
    }
    
    /// Writes only what differs from the system, so slider drags don't re-post unchanged values.
    func write(_ state: State) {
        guard let current = read(),
              let setCategoryEnabled = setCategoryEnabledFunc, let setType = setTypeFunc,
              let setHue = setHueFunc, let setIntensity = setIntensityFunc else { return }
        
        if abs(state.hue - current.hue) > 0.0001 {
            setHue(Double(state.hue))
        }
        if abs(state.intensity - current.intensity) > 0.0001 {
            setIntensity(Double(state.intensity))
        }
        if state.isOn != current.isOn {
            if state.isOn {
                setType(colorCategory, colorTintType)
                setCategoryEnabled(colorCategory, true)
            } else {
                // Only reached when Color Tint is the active filter, so e.g. a Grayscale filter is left alone
                setCategoryEnabled(colorCategory, false)
            }
        }
    }
}

// MARK: - 7. Appearance Manager (Light & Dark Appearance)
/// Reads and sets the appearance in System Settings › Appearance. System Settings sets it through these
/// SkyLight functions (exported, but not in the public headers), and has AppKit fade the whole screen
/// from the old appearance to the new one.
class AppearanceManager {
    static let shared = AppearanceManager()

    /// Distributed notification the system posts whenever the appearance changes.
    static let changedNotification = Notification.Name("AppleInterfaceThemeChangedNotification")

    // `SLSAppearanceTheme`'s two values
    private let lightTheme: Int32 = 0
    private let darkTheme: Int32 = 1

    private var getThemeFunc: (@convention(c) () -> Int32)?
    private var setThemeFunc: (@convention(c) (Int32, Bool) -> Void)?
    private var getSwitchesAutomaticallyFunc: (@convention(c) () -> Bool)?
    private var setSwitchesAutomaticallyFunc: (@convention(c) (Bool) -> Void)?

    init() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return }

        func load<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }

        getThemeFunc = load("SLSGetAppearanceThemeLegacy", as: (@convention(c) () -> Int32).self)
        setThemeFunc = load("SLSSetAppearanceThemeNotifying", as: (@convention(c) (Int32, Bool) -> Void).self)
        getSwitchesAutomaticallyFunc = load("SLSGetAppearanceThemeSwitchesAutomatically", as: (@convention(c) () -> Bool).self)
        setSwitchesAutomaticallyFunc = load("SLSSetAppearanceThemeSwitchesAutomatically", as: (@convention(c) (Bool) -> Void).self)
    }

    /// Whether the appearance is Dark right now, which with Auto depends on the time of day.
    func isDark() -> Bool? {
        getThemeFunc.map { $0() == darkTheme }
    }

    /// Choosing Light or Dark turns Auto off, as it does in System Settings, even if that's what Auto
    /// has it set to already. `completion` is called on the main thread once the screen has changed over.
    func setDark(_ isDark: Bool, completion: @escaping () -> Void = {}) {
        guard let current = self.isDark(), let setTheme = setThemeFunc else { return completion() }

        if getSwitchesAutomaticallyFunc?() == true {
            setSwitchesAutomaticallyFunc?(false)
        }
        guard isDark != current else { return completion() }

        // System Settings' steps: `NSGlobalPreferenceTransition` (not in the public headers) takes a
        // picture of the screen, the appearance is set without telling anyone, and then the transition
        // tells every app and fades the picture out over them as they redraw. Without it, the
        // appearance is set the plain way, and apps change over one by one.
        let makeTransition = NSSelectorFromString("transition")
        let postChange = NSSelectorFromString("postChangeNotification:completionHandler:")
        if let transitionClass = NSClassFromString("NSGlobalPreferenceTransition") as? NSObject.Type,
           transitionClass.responds(to: makeTransition),
           let transition = transitionClass.perform(makeTransition)?.takeUnretainedValue() as? NSObject,
           transition.responds(to: postChange) {
            setTheme(isDark ? darkTheme : lightTheme, false)
            // The transition keeps the completion handler until the fade is over, so it has to be escaping
            typealias PostChange = @convention(c) (NSObject, Selector, UInt, @escaping @convention(block) () -> Void) -> Void
            unsafeBitCast(transition.method(for: postChange), to: PostChange.self)(transition, postChange, 0) {
                DispatchQueue.main.async(execute: completion)
            }
        } else {
            setTheme(isDark ? darkTheme : lightTheme, true)
            completion()
        }
    }
}

// MARK: - 8. Wallpaper Manager (A Picture for Light and One for Dark)
/// Gives the desktop a picture for Light and another for Dark, made the way macOS's own Light and Dark
/// wallpapers are (Sonoma's, for one): both pictures in one HEIC file, with XMP metadata saying which is
/// which. macOS then changes the desktop over to the other picture itself whenever the appearance
/// changes, whatever changed it: Safelight, System Settings, Control Center or Auto. It fades from one
/// picture to the other over about two seconds, starting as the rest of the screen fades. Safelight
/// writes that file in its Application Support folder and puts it on every Space of every display, as
/// choosing a picture in System Settings › Wallpaper does with Show on all Spaces on, or with it off,
/// on the Space each display is showing. Each picture can be one of the user's own, or one of System
/// Settings' own wallpapers (`WallpaperLibrary`), fetched first if it has to be, shown with System
/// Settings' options for it (`PictureOptions`). With Sequoia set to Automatic for Light, which changes
/// its look with the time of day, the desktop has another file in Light, which macOS changes through
/// Sequoia's looks itself as the sun moves (`makeSunWallpaper`, `followAppearance`).
final class WallpaperManager: ObservableObject, @unchecked Sendable { // Its state only changes on the main thread
    static let shared = WallpaperManager()

    /// The pictures the desktop has in Light and in Dark, scaled down for the popover, while Safelight
    /// can tell them (`Desktop`): for a shuffle, its thumbnail, and for a wallpaper macOS draws as it's
    /// shown, like Sequoia's, System Settings' thumbnails of it. Nil while it can't, as for a kind of
    /// wallpaper it doesn't know. An appearance a change has just been asked for shows what it will
    /// have as soon as that's drawn (`previews`), as System Settings shows a wallpaper on its picture of
    /// the desktop as soon as it's clicked.
    var thumbnails: Thumbnails? {
        guard var thumbnails = desktopThumbnails else { return nil }
        guard !previews.isEmpty else { return thumbnails }
        let place = place(for: nil)
        for (isDark, preview) in previews where preview.place == place {
            if isDark {
                thumbnails.dark = preview.thumbnail
            } else {
                thumbnails.light = preview.thumbnail
            }
        }
        return thumbnails
    }
    /// What the desktop shown has (`show`)
    @Published private var desktopThumbnails: Thumbnails?
    /// For each appearance, what the latest change asked for will show, until it's on the desktop, and
    /// the desktop's own pictures have been read again
    @Published private var previews: [Bool: (change: UUID, place: String?, thumbnail: Thumbnail)] = [:]
    /// What an appearance will show once a change is made, drawn away from the main thread for a
    /// display of a size, in pixels, from the picture the wallpaper's made with, as its picture will be
    /// drawn then (`thumbnails(of:)`), so it looks the same once it's on the desktop
    private typealias Preview = (_ screenSize: CGSize) async -> Thumbnail?

    /// A change asked for: for which appearance, where it goes (`place(for:)`), and the choice it's
    /// remembered as, with the options it's shown with
    private struct Change {
        let id = UUID()
        let isDark: Bool
        let place: String?
        let choice: String?
        let options: PictureOptions
    }
    /// The change whose wallpaper is being made, from when it's asked for until it's on the desktop
    @Published private var changing: Change?
    /// The changes asked for meanwhile, made one after the other once it's on the desktop, as only one
    /// can be made at a time: for each appearance and place, the last choice asked for, and after it
    /// the last change of its options (`wait`)
    @Published private var waiting: [Waiting] = []
    /// A change waiting: whether it's a choice, or a change of a choice's options, what makes it, and
    /// what tells one asked for again meanwhile that it won't be made
    private struct Waiting {
        let change: Change
        let isChoice: Bool
        let make: () -> Void
        let drop: () -> Void
    }
    /// True from when a picture is chosen until the wallpaper with it is on the desktop
    var isChanging: Bool {
        changing != nil
    }
    /// While a wallpaper is being made for the display shown, the choice it's made for, as one shuffling
    /// on another display may be made meanwhile
    var changingChoice: WallpaperItem.ID? {
        changing.flatMap { $0.place == place(for: nil) ? $0.choice : nil }
    }
    /// How much of the picture has downloaded, while it's one macOS downloads when it's chosen
    @Published private(set) var downloadProgress: Double?
    /// For each wallpaper Safelight made, by the name of its folder, the wallpapers of System Settings'
    /// whose pictures it has for Light and for Dark, or the shuffles they're from, or the user's own
    /// pictures (`WallpaperItem.ownPicture(named:)`) or colour (`WallpaperItem.customColor`), and the
    /// options each is shown with. Each wallpaper has its own, as with Show
    /// on all Spaces off, each Space can have a different one. Kept between launches.
    @Published private var choices: [String: Choices] {
        didSet { UserDefaults.standard.set(try? PropertyListEncoder().encode(choices), forKey: Self.choicesKey) }
    }
    /// The choices kept before each wallpaper had its own, which are the wallpaper's that was on the
    /// desktop then, until another is made
    private var earlierChoices: Choices?
    /// Whether a wallpaper made here goes on every Space, as System Settings' Show on all Spaces, or
    /// only on the Space each display is showing. Kept between launches, and set as System Settings
    /// has its own whenever that changes, or its wallpaper does (`followSystemSettings`).
    @Published private(set) var showsOnAllSpaces: Bool {
        didSet { UserDefaults.standard.set(showsOnAllSpaces, forKey: Self.showsOnAllSpacesKey) }
    }
    /// The display whose wallpaper is shown and chosen while Show on all Spaces is off, by its UUID, as
    /// System Settings' pop-up under its picture of the desktop chooses one: the one the popover last
    /// opened on, or another chosen in the Wallpaper window. The main display's until then, or while it
    /// isn't connected (`place(for:)`).
    @Published private(set) var selectedDisplay: String?
    /// The displays, for choosing one, kept up to date as they're connected and disconnected
    @Published private(set) var displays = Display.connected()
    struct Thumbnails {
        var light: Thumbnail
        var dark: Thumbnail
    }

    /// What the desktop's pictures show for an appearance: a picture, or as System Settings shows a
    /// shuffle, four of its pictures (`ShuffleThumbnail`)
    enum Thumbnail {
        case picture(CGImage)
        case shuffle([URL?])
    }

    struct Choices: Codable {
        var light: WallpaperItem.ID?
        var dark: WallpaperItem.ID?
        var lightOptions: PictureOptions?
        var darkOptions: PictureOptions?

        func choice(isDark: Bool) -> WallpaperItem.ID? {
            isDark ? dark : light
        }

        func options(isDark: Bool) -> PictureOptions {
            (isDark ? darkOptions : lightOptions) ?? PictureOptions()
        }

        mutating func set(_ choice: WallpaperItem.ID?, options: PictureOptions, isDark: Bool) {
            if isDark {
                (dark, darkOptions) = (choice, options)
            } else {
                (light, lightOptions) = (choice, options)
            }
        }
    }

    /// System Settings' options for how an appearance shows its wallpaper, each where the wallpaper has
    /// it: which of its pictures, for one with a picture for each appearance, Macintosh's colours (its
    /// colorScheme option's ID), whether a colour is shown as a gradient, and how a picture is placed on
    /// the display. An appearance keeps them from one choice to the next, as System Settings keeps its
    /// options.
    struct PictureOptions: Codable, Equatable {
        var appearance: AppearanceOption?
        var macintoshColors: String?
        var isGradient: Bool?
        var placement: Placement?

        /// Whether the appearance shows a wallpaper's picture for Dark, of one with a picture for each
        func showsDark(isDark: Bool) -> Bool {
            switch appearance ?? .automatic {
            case .automatic: isDark
            case .light: false
            case .dark: true
            }
        }
    }

    /// System Settings' choice of which picture a wallpaper with one for each appearance shows: the
    /// appearance's own (Automatic), or always its Light one or its Dark one
    enum AppearanceOption: String, Codable, CaseIterable {
        case automatic, light, dark

        /// As System Settings has it set, from which picture its wallpaper shows in Light and in Dark
        init(lightShowsDark: Bool, darkShowsDark: Bool) {
            self = lightShowsDark == darkShowsDark ? (darkShowsDark ? .dark : .light) : .automatic
        }
    }

    /// How macOS places a picture on a display of another shape, as System Settings › Wallpaper offers
    /// for a picture: filling the display, all of it on the display with the fill colour around it,
    /// stretched to the display's shape, or at its own size in the middle with the fill colour around
    /// it. Tile has been left out, as AppKit can't ask macOS for it, so what it looks like can't be told.
    /// macOS places a wallpaper file as a whole, and its own wallpapers are square, to fill a display
    /// either way up, so Safelight draws each appearance's picture placed (`placedPicture`), and the
    /// wallpaper with both fills the display. A placed picture is drawn for each display's size, as
    /// macOS places it on each, so each display has a wallpaper of its own then (`file(of:for:)`).
    struct Placement: Codable, Equatable {
        enum Kind: String, Codable, CaseIterable {
            case fill, fit, stretch, center
        }

        var kind = Kind.fill
        /// Around a picture fitted or in the middle, when one is set
        var color: CGColor?

        /// Whether the fill colour shows, and System Settings offers it
        var hasColor: Bool {
            kind == .fit || kind == .center
        }

        private enum CodingKeys: CodingKey {
            case kind, color
        }

        /// Its colour kept in Display P3, the Colours panel's
        private static let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .fill
            color = try container.decodeIfPresent([CGFloat].self, forKey: .color).flatMap { CGColor(colorSpace: Self.colorSpace, components: $0) }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind)
            try container.encodeIfPresent(color?.converted(to: Self.colorSpace, intent: .defaultIntent, options: nil)?.components, forKey: .color)
        }

        /// As a display's desktop image options say
        init(_ options: [NSWorkspace.DesktopImageOptionKey: Any]) {
            let scaling = (options[.imageScaling] as? NSNumber).flatMap { NSImageScaling(rawValue: $0.uintValue) }
            switch scaling {
            case .scaleAxesIndependently?: kind = .stretch
            case .scaleNone?: kind = .center
            case .scaleProportionallyUpOrDown? where (options[.allowClipping] as? NSNumber)?.boolValue == false: kind = .fit
            default: kind = .fill
            }
            color = (options[.fillColor] as? NSColor)?.cgColor
        }

        init(kind: Kind = .fill, color: CGColor? = nil) {
            (self.kind, self.color) = (kind, color)
        }
    }

    /// What the desktop has, when Safelight can tell the picture it shows in Light and in Dark
    enum Desktop: Equatable {
        /// A wallpaper Safelight made, or a picture file macOS shows as it is, placed on the display as
        /// the display's options say (a wallpaper made here fills it): its picture for each appearance,
        /// or its only one in both
        case file(URL, placement: Placement = Placement())
        /// One of System Settings' wallpapers, as macOS shows it in each appearance: its own picture for
        /// each, or while it's set to Light or Dark, that one's in both
        case item(WallpaperItem, lightShowsDark: Bool, darkShowsDark: Bool)
        /// A colour of the user's own
        case color(CGColor)
        /// A colour, of the user's own or of System Settings', shown with Gradient on
        case gradient(CGColor, isCustom: Bool)
        /// One of System Settings' shuffles, which shows the same picture in both appearances until it
        /// changes, as often as it's set to
        case shuffle(WallpaperShuffle, interval: WallpaperShuffle.Interval)
        /// A wallpaper macOS draws as it's shown: its own look in each appearance, or while it's set to
        /// Light or Dark, that one's in both, in Macintosh's colours (its colorScheme option)
        case drawn(DrawnWallpaper, lightShowsDark: Bool, darkShowsDark: Bool, colors: String?)
    }

    /// The wallpapers System Settings has that macOS draws as they're shown, from 3D models and little
    /// programs, so there's no picture of them on the Mac to put in a wallpaper of Safelight's. They're
    /// drawn here as macOS draws them.
    enum DrawnWallpaper: String {
        case sequoia = "drawn:sequoia"
        case macintosh = "drawn:macintosh"

        var name: String {
            switch self {
            case .sequoia: SystemStrings.sequoia
            case .macintosh: SystemStrings.macintosh
            }
        }
    }

    private static let choicesKey = "WallpaperChoicesByWallpaper"
    private static let earlierChoicesKey = "WallpaperChoices"
    private static let showsOnAllSpacesKey = "WallpaperShowsOnAllSpaces"

    init() {
        let defaults = UserDefaults.standard
        choices = defaults.data(forKey: Self.choicesKey).flatMap { try? PropertyListDecoder().decode([String: Choices].self, from: $0) } ?? [:]
        earlierChoices = defaults.data(forKey: Self.earlierChoicesKey).flatMap { try? PropertyListDecoder().decode(Choices.self, from: $0) }
        showsOnAllSpaces = defaults.object(forKey: Self.showsOnAllSpacesKey) as? Bool ?? true
        // Another Space can have another wallpaper, and the shuffles run on the Space whose wallpaper has them
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
            WallpaperShuffler.shared.schedule()
        }
        // A wallpaper with Sequoia's looks through the day for Light has another file in Dark, put on as
        // soon as the appearance changes, and again a second later, should it not have read as changed yet
        DistributedNotificationCenter.default().addObserver(forName: AppearanceManager.changedNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.refresh() }
        }
        // The display chosen may have gone, and each display shuffles by itself. An iPad's name can
        // arrive after its display.
        for name in [NSApplication.didChangeScreenParametersNotification, Sidecar.connectedDevicesChangedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                let displays = Display.connected()
                if displays != self.displays {
                    self.displays = displays
                }
                refresh()
                WallpaperShuffler.shared.schedule()
            }
        }
    }

    /// Whether the Mac has the Dark appearance now
    private static var isDark: Bool {
        AppearanceManager.shared.isDark() ?? (UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark")
    }

    /// The choices a wallpaper Safelight made has, by any of its files
    private func choices(of wallpaper: URL) -> Choices {
        choices[Self.wallpaperFolder(of: wallpaper).lastPathComponent] ?? earlierChoices ?? Choices()
    }

    /// What the desktop of the display shown has (`place(for:)`), which `thumbnails` are of, drawn the
    /// shape of a display of what size, in pixels
    private var shown: Desktop?
    private var shownSize = CGSize.zero
    /// Each display's picture file as macOS named it when it was last looked at, by the display's UUID
    private var lastRead: [String: URL] = [:]
    /// For each display a wallpaper was just put on, by its UUID, its file there, and the display's
    /// picture files before it, which macOS can still name for a second or so, though they may have been
    /// taken away: until it names the new one, for a few seconds at most
    private var justPut: [String: (wallpaper: URL, before: Set<URL>, until: Date)] = [:]
    /// The files macOS has downloaded that it's showing, as the desktop or the screen saver
    @Published private var downloadsInUse: Set<URL> = []
    /// Those of the files macOS downloads System Settings' wallpapers into that are on the Mac, nil
    /// until they've been looked for (`lookForDownloads()`)
    @Published private var downloadsOnMac: Set<URL>?
    /// Where they're looked for and taken away, away from the main thread, as Tahoe's are in another
    /// app's container, which macOS asks the user about the first time
    private let downloadsQueue = DispatchQueue(label: "Safelight.Downloads", qos: .userInitiated)

    /// Where each wallpaper is made, in a folder of its own, so the file on the desktop is never
    /// written over, and the one before can be taken away
    private let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Safelight", isDirectory: true)
        .appendingPathComponent("Wallpapers", isDirectory: true)

    /// The metadata in which macOS's wallpapers say which picture is for Light and which for Dark: a
    /// property list of their indexes, binary and in base 64. A dynamic wallpaper says so in the
    /// metadata it changes through the day by, for when it's set to Light (Still) or Dark (Still).
    private static let metadataNamespace = "http://ns.apple.com/namespace/1.0/" as CFString
    private static let metadataPrefix = "apple_desktop" as CFString
    private static let appearanceMetadataPath = "apple_desktop:apr" as CFString
    private static let solarMetadataPath = "apple_desktop:solar" as CFString
    private static let dynamicMetadataPaths = [solarMetadataPath, "apple_desktop:h24" as CFString]

    /// The name of the file a wallpaper made here has beside each of its own while Light has Sequoia set
    /// to Automatic, with Sequoia's looks through the day (`makeSunWallpaper`), which the desktop has in
    /// Light in place of the wallpaper's own (`followAppearance`)
    private static let sunFileName = "Sun.heic"

    /// AppKit's option for putting a picture on every Space a display has, as System Settings ›
    /// Wallpaper does with Show on all Spaces on. It's exported, but not in the public headers; without
    /// it, a picture only goes on the Space each display is showing.
    private static let allSpacesOption = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "NSWorkspaceDesktopImageAllSpacesKey") // RTLD_DEFAULT
        .map { NSWorkspace.DesktopImageOptionKey(rawValue: $0.load(as: NSString.self) as String) }

    /// Looks at the wallpaper of the display shown again, as it can be changed in System Settings ›
    /// Wallpaper, and has each display that has one of Safelight's show its file for the appearance
    func refresh() {
        let downloadsInUse = Self.downloadsInUse()
        if downloadsInUse != self.downloadsInUse {
            self.downloadsInUse = downloadsInUse
        }
        let screen = screen(for: place(for: nil))
        for other in NSScreen.screens where other != screen {
            let read = read(other)
            if !read.isBefore, let file = read.file, isMadeHere(file) {
                followAppearance(showing: file, on: other)
            }
        }
        guard let screen else { return show(nil, on: nil) }
        let read = read(screen)
        // Still one from before, which may have been taken away
        guard !read.isBefore else { return }
        let desktop = desktop(showing: read.file, on: screen)
        if let wallpaper = read.file, isMadeHere(wallpaper) {
            systemSettings = nil
            followAppearance(showing: wallpaper, on: screen)
        } else {
            followSystemSettings(showing: desktop)
        }
        show(desktop, on: screen)
    }

    /// The file a display's desktop has, as macOS names it, and whether that's still one from before the
    /// wallpaper just put on the display (`justPut`). Once it names another, that one isn't waited for.
    private func read(_ screen: NSScreen) -> (file: URL?, isBefore: Bool) {
        let file = NSWorkspace.shared.desktopImageURL(for: screen)
        guard let display = Self.uuid(of: screen) else { return (file, false) }
        if let justPut = justPut[display], Date() < justPut.until, let read = file?.standardizedFileURL, read != justPut.wallpaper,
           justPut.before.contains(read) || isMadeHere(read) {
            return (file, true)
        }
        justPut[display] = nil
        lastRead[display] = file
        return (file, false)
    }

    /// What a display's desktop has, which shows `file`: a wallpaper Safelight made, as its own file, with
    /// its pictures for Light and for Dark, whichever is on the desktop, or one Safelight didn't make,
    /// when it can tell its pictures, with a picture file placed as the display's options say
    private func desktop(showing file: URL?, on screen: NSScreen) -> Desktop? {
        let placement = Self.placement(on: screen)
        if let file, isMadeHere(file) {
            return .file(Self.ownFile(beside: file), placement: placement)
        }
        var desktop = Self.desktop(showing: file, on: Self.uuid(of: screen))
        if case .file(let file, _)? = desktop {
            desktop = .file(file, placement: placement)
        }
        return desktop
    }

    /// Where a change for `display`, by its UUID, goes, by the UUID of the display it goes on: with Show
    /// on all Spaces on, on every display, which have the main display's wallpaper (nil); otherwise on
    /// `display` alone, or with none, on the one chosen (`selectedDisplay`)
    func place(for display: String?) -> String? {
        guard !showsOnAllSpaces else { return nil }
        if let display {
            return display
        }
        let connected = NSScreen.screens.compactMap(Self.uuid(of:))
        return selectedDisplay.flatMap { connected.contains($0) ? $0 : nil } ?? connected.first
    }

    /// The display whose desktop a change goes by, where it goes (`place(for:)`): the main display for
    /// every display, nil for one that isn't connected
    private func screen(for place: String?) -> NSScreen? {
        guard let place else { return NSScreen.screens.first }
        return NSScreen.screens.first { Self.uuid(of: $0) == place }
    }

    /// The displays a change goes on, where it goes (`place(for:)`)
    private func screens(for place: String?) -> [NSScreen] {
        place == nil ? NSScreen.screens : screen(for: place).map { [$0] } ?? []
    }

    /// What the desktop has where a change goes (`place(for:)`): the desktop shown, or another display's
    private func desktop(at place: String?) -> Desktop? {
        guard let screen = screen(for: place) else { return nil }
        if screen == self.screen(for: self.place(for: nil)) {
            return shown
        }
        let read = read(screen)
        guard let display = Self.uuid(of: screen), read.isBefore, let wallpaper = justPut[display]?.wallpaper else {
            return desktop(showing: read.file, on: screen)
        }
        return desktop(showing: wallpaper, on: screen)
    }

    /// Shows the wallpaper of a display, by its UUID, while Show on all Spaces is off, and chooses for
    /// it, as System Settings' pop-up under its picture of the desktop does
    func selectDisplay(_ display: String?) {
        guard display != selectedDisplay else { return }
        selectedDisplay = display
        refresh()
    }

    /// The file of the wallpaper on each display just put on in place of another for the appearance, by
    /// the display's UUID, and until when it isn't put on again, as macOS still names the other for a
    /// second or so
    private var followed: [String: (file: URL, until: Date)] = [:]

    /// Puts on the file of the wallpaper made here, of which `file` is on a display's desktop, that the
    /// desktop has in the appearance the Mac has now, when it's another (`setDesktop(_:isDark:on:)`). Only
    /// one with Sequoia's looks through the day for Light has another: in Light, macOS shows the look of
    /// the time of day from that file itself, as it does with Sequoia set to Automatic, but it does in
    /// Dark as well, for a file an app puts on, where Sequoia shows its Dark look. Only System Settings
    /// can have it keep to one look in Dark. So in Dark the desktop has the wallpaper's own file, with its
    /// picture for Dark.
    private func followAppearance(showing file: URL, on screen: NSScreen) {
        guard !isChanging, let display = Self.uuid(of: screen) else { return }
        let own = Self.ownFile(beside: file)
        let wanted = Self.shownFile(of: own, for: screen, isDark: Self.isDark).standardizedFileURL
        guard wanted != file.standardizedFileURL else { return }
        if let followed = followed[display], followed.file == wanted, Date() < followed.until {
            return
        }
        followed[display] = (wanted, Date().addingTimeInterval(5))
        setDesktop(own, on: [screen])
    }

    /// Puts the wallpaper's own file back on each display in place of the one with Sequoia's looks
    /// through the day, as Safelight quits, so the desktop has its picture for Dark in Dark while it isn't
    /// running to put it on. In Light it has its own picture for Light, until Safelight puts the other on
    /// again.
    func putOwnFileBack() {
        for screen in NSScreen.screens {
            guard let file = NSWorkspace.shared.desktopImageURL(for: screen), isMadeHere(file), file.lastPathComponent == Self.sunFileName else { continue }
            if let display = Self.uuid(of: screen) {
                followed[display] = nil
            }
            setDesktop(Self.ownFile(beside: file), isDark: true, on: [screen])
        }
    }

    /// The wallpaper of System Settings' the desktop had when Show on all Spaces was last set as System
    /// Settings has it, and how that was, nil since the desktop has had one of Safelight's
    private var systemSettings: (desktop: Desktop?, showsOnAllSpaces: Bool)?

    /// Sets Show on all Spaces as System Settings has its own, when the desktop has a wallpaper of
    /// System Settings' again, or another, or System Settings has changed its Show on all Spaces since,
    /// so the next wallpaper made here goes where System Settings would put its next. System Settings has it on while its wallpaper is
    /// the one for every Space and display, which only it can put there: once Safelight has put one on
    /// the desktop, on every Space or not, it reads off, so Safelight's own is kept for those.
    private func followSystemSettings(showing desktop: Desktop?) {
        guard let isOnAllSpaces = Self.systemShowsOnAllSpaces else { return }
        if let systemSettings, systemSettings.desktop == desktop, systemSettings.showsOnAllSpaces == isOnAllSpaces {
            return
        }
        systemSettings = (desktop, isOnAllSpaces)
        if showsOnAllSpaces != isOnAllSpaces {
            showsOnAllSpaces = isOnAllSpaces
        }
    }

    /// Whether System Settings › Wallpaper has Show on all Spaces on: while macOS's wallpaper service
    /// keeps a desktop for every Space and display, nil when its store can't be read
    private static var systemShowsOnAllSpaces: Bool? {
        guard let data = try? Data(contentsOf: store),
              let index = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return (index["AllSpacesAndDisplays"] as? [String: Any])?["Desktop"] != nil
    }

    /// How the desktop's picture is placed on a display, with the colour around it that macOS fills in
    /// when none is set
    private static func placement(on screen: NSScreen) -> Placement {
        var placement = Placement(NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:])
        if placement.color == nil {
            placement.color = defaultFillColor(on: uuid(of: screen))
        }
        return placement
    }

    /// Shows the pictures `wallpaper` has for Light and for Dark, or none
    func showPictures(of wallpaper: URL?) {
        show(wallpaper.map { .file($0) }, on: NSScreen.screens.first)
    }

    /// Shows the pictures a display's desktop has for Light and for Dark, or none, drawn the shape of the
    /// display where they're drawn here. They're loaded in the background, and the ones shown before stay
    /// until they are, as do the previews of changes that are on the desktop now.
    private func show(_ desktop: Desktop?, on screen: NSScreen?) {
        let screenSize = screen.map(Self.pixelSize(of:)) ?? Self.screenSize
        guard desktop != shown || screenSize != shownSize else { return }
        shown = desktop
        shownSize = screenSize
        guard let desktop else {
            desktopThumbnails = nil
            previews = previews.filter { isAskedFor($0.value.change) }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let thumbnails = Self.thumbnails(of: desktop, screenSize: screenSize)
            DispatchQueue.main.async {
                guard let self, self.shown == desktop, self.shownSize == screenSize else { return }
                self.desktopThumbnails = thumbnails
                self.previews = self.previews.filter { self.isAskedFor($0.value.change) }
            }
        }
    }

    /// Shows what an appearance will have once a change just asked for is made, as soon as `preview` has
    /// drawn it, while it's still the latest asked for there. With none, the appearance keeps showing
    /// what the desktop has until the change is on it.
    private func showPreview(_ preview: Preview?, of change: Change) {
        guard let preview else { return }
        let screenSize = shownSize
        Task.detached(priority: .userInitiated) {
            let thumbnail = await preview(screenSize)
            await MainActor.run {
                guard let thumbnail, self.latestChange(isDark: change.isDark, at: change.place)?.id == change.id else { return }
                self.previews[change.isDark] = (change.id, change.place, thumbnail)
            }
        }
    }

    /// The last change asked for an appearance where changes go (`place(for:)`) that isn't on the desktop
    /// yet: one waiting, or the one being made
    private func latestChange(isDark: Bool, at place: String?) -> Change? {
        waiting.last(where: { $0.change.isDark == isDark && $0.change.place == place })?.change
            ?? changing.flatMap { $0.isDark == isDark && $0.place == place ? $0 : nil }
    }

    /// The last change asked for an appearance on the desktop shown that isn't on it yet. None waits
    /// while none is being made.
    private func shownChange(isDark: Bool) -> Change? {
        isChanging ? latestChange(isDark: isDark, at: place(for: nil)) : nil
    }

    /// Whether a change is still to be made, or being made
    private func isAskedFor(_ id: UUID) -> Bool {
        changing?.id == id || waiting.contains { $0.change.id == id }
    }

    /// The wallpaper of System Settings' whose picture the desktop shown has for an appearance, or the
    /// shuffle it's from, or a picture or a colour of the user's own: the one chosen here while the
    /// wallpaper is one Safelight made, or the one System Settings has on the desktop. One chosen since
    /// is the choice as soon as it's asked for, as System Settings has a wallpaper chosen as soon as it's
    /// clicked, while it's made.
    func choice(isDark: Bool) -> String? {
        if let change = shownChange(isDark: isDark) {
            return change.choice
        }
        return choice(isDark: isDark, of: shown)
    }

    /// The choice an appearance has, as `choice(isDark:)` says, where a change for a display, by its UUID,
    /// goes (`place(for:)`), while the desktop there has a wallpaper Safelight made, the only kind its
    /// shuffles change, or is to have one: a shuffle is the choice as soon as it's asked for
    func ownChoice(isDark: Bool, on display: String?) -> String? {
        let place = place(for: display)
        if let change = latestChange(isDark: isDark, at: place) {
            return change.choice
        }
        return ownWallpaper(at: place).flatMap { choices(of: $0).choice(isDark: isDark) }
    }

    /// The wallpaper Safelight made the desktop has where a change goes (`place(for:)`), nil while it has
    /// another
    private func ownWallpaper(at place: String?) -> URL? {
        guard let screen = screen(for: place) else { return nil }
        if screen == self.screen(for: self.place(for: nil)) {
            guard case .file(let wallpaper, _)? = shown, isMadeHere(wallpaper) else { return nil }
            return wallpaper
        }
        let read = read(screen)
        let file = read.isBefore ? Self.uuid(of: screen).flatMap { justPut[$0]?.wallpaper } : read.file
        return file.flatMap { isMadeHere($0) ? Self.ownFile(beside: $0) : nil }
    }

    private func choice(isDark: Bool, of desktop: Desktop?) -> String? {
        switch desktop {
        case .file(let wallpaper, _)? where isMadeHere(wallpaper):
            return choices(of: wallpaper).choice(isDark: isDark)
        case .item(let item, _, _)?:
            return item.id
        case .shuffle(let shuffle, _)?:
            return shuffle.id
        case .drawn(let drawn, _, _, _)?:
            return drawn.rawValue
        case .color?, .gradient(_, isCustom: true)?:
            return WallpaperItem.customColor
        default:
            return nil
        }
    }

    /// The options an appearance's choice is shown with: as they were chosen here, while the wallpaper
    /// is one Safelight made, or as System Settings has them for its own, or those of a change asked for
    /// since, as soon as it's asked for (`choice(isDark:)`)
    func options(isDark: Bool) -> PictureOptions {
        if let change = shownChange(isDark: isDark) {
            return change.options
        }
        return options(isDark: isDark, of: shown)
    }

    private func options(isDark: Bool, of desktop: Desktop?) -> PictureOptions {
        switch desktop {
        case .file(let wallpaper, _)? where isMadeHere(wallpaper):
            return choices(of: wallpaper).options(isDark: isDark)
        case .item(_, let lightShowsDark, let darkShowsDark)?:
            return PictureOptions(appearance: AppearanceOption(lightShowsDark: lightShowsDark, darkShowsDark: darkShowsDark))
        case .drawn(_, let lightShowsDark, let darkShowsDark, let colors)?:
            return PictureOptions(appearance: AppearanceOption(lightShowsDark: lightShowsDark, darkShowsDark: darkShowsDark), macintoshColors: colors)
        case .gradient?:
            return PictureOptions(isGradient: true)
        default:
            return PictureOptions()
        }
    }

    /// The options a picture chosen for an appearance takes where a change goes (`place(for:)`): those it
    /// has now, as System Settings keeps its options from one choice to the next, while the wallpaper is
    /// one Safelight made, or is to be. One of System Settings' own keeps its options to itself.
    private func keptOptions(isDark: Bool, at place: String?) -> PictureOptions {
        if let change = latestChange(isDark: isDark, at: place) {
            return change.options
        }
        let desktop = desktop(at: place)
        guard case .file(let wallpaper, _)? = desktop, isMadeHere(wallpaper) else { return PictureOptions() }
        return options(isDark: isDark, of: desktop)
    }

    /// Shows an appearance's choice with other options, making the wallpaper again with them, as
    /// System Settings shows its wallpaper again when one of its options changes. A shuffle's picture
    /// is made again with them, and its next ones have them too. While the appearance's choice is still
    /// being made, they show at once, and it's made again with them once it's on the desktop.
    func setOptions(_ options: PictureOptions, isDark: Bool) {
        let place = place(for: nil)
        if let change = latestChange(isDark: isDark, at: place) {
            wait(Change(isDark: isDark, place: place, choice: change.choice, options: options), isChoice: false) { [weak self] in
                guard let self, self.place(for: nil) == place else { return }
                self.setOptions(options, isDark: isDark)
            } drop: {}
            return
        }
        guard let choice = choice(isDark: isDark) else { return }
        let library = WallpaperLibrary.shared
        if WallpaperItem.isOwnPicture(choice) {
            guard case .file(let wallpaper, _)? = shown, isMadeHere(wallpaper),
                  let original = Self.original(in: Self.wallpaperFolder(of: wallpaper), isDark: isDark) else { return }
            setPicture(original, isDark: isDark, choice: choice, options: options)
        } else if let item = library.item(choice) ?? YourPhotos.shared.items.first(where: { $0.id == choice }) {
            choose(item, isDark: isDark, options: options)
        } else if let current = WallpaperShuffler.shared.current(isDark: isDark),
                  let item = library.pictures(of: choice).first(where: { $0.id == current }) {
            choose(item, isDark: isDark, options: options, from: choice)
        }
    }

    /// Puts the wallpaper made here on every Space of every display, or from now on only on the Space
    /// the display chosen is showing, as System Settings' Show on all Spaces does: turned on, they all
    /// have the wallpaper the display shown has now, while it's one of Safelight's, and its shuffles;
    /// turned off, each display keeps what it has, and shuffles by itself
    func setShowsOnAllSpaces(_ showsOnAllSpaces: Bool) {
        refresh()
        let (display, desktop) = (place(for: nil), shown)
        self.showsOnAllSpaces = showsOnAllSpaces
        if showsOnAllSpaces, Self.allSpacesOption != nil, case .file(let wallpaper, _)? = desktop, isMadeHere(wallpaper) {
            putOnDesktop(wallpaper, on: NSScreen.screens)
            removeWallpapers(except: wallpaper)
            if let display {
                WallpaperShuffler.shared.join(from: display)
            }
        } else if !showsOnAllSpaces {
            WallpaperShuffler.shared.split()
        }
        refresh()
        WallpaperShuffler.shared.schedule()
    }

    /// Whether the picture of the user's own an appearance has can be placed another way: the wallpaper
    /// kept it as it was before it was placed, as one made before Safelight kept them didn't
    func canPlaceAgain(isDark: Bool) -> Bool {
        guard case .file(let wallpaper, _)? = shown, isMadeHere(wallpaper) else { return false }
        return Self.original(in: Self.wallpaperFolder(of: wallpaper), isDark: isDark) != nil
    }

    /// Looks for the files macOS has downloaded System Settings' wallpapers into, as the Wallpaper
    /// window shows which it has
    func lookForDownloads() {
        downloadsQueue.async {
            let onMac = WallpaperLibrary.shared.downloadFiles.filter { FileManager.default.fileExists(atPath: $0.path) }
            DispatchQueue.main.async {
                if onMac != self.downloadsOnMac {
                    self.downloadsOnMac = onMac
                }
            }
        }
    }

    /// Whether macOS has downloaded one of System Settings' wallpapers, as System Settings has it for
    /// its download badge: always for one it doesn't download, or while that hasn't been looked for
    func isDownloaded(_ item: WallpaperItem) -> Bool {
        guard let download = item.download, let downloadsOnMac else { return true }
        return download.isDownloaded(onMac: downloadsOnMac)
    }

    /// Whether one of System Settings' wallpapers can be taken off the Mac, as System Settings' Remove
    /// Download offers, while macOS isn't showing it
    func canRemoveDownloads(of item: WallpaperItem) -> Bool {
        guard let download = item.download, let downloadsOnMac else { return false }
        return download.isRemovable(onMac: downloadsOnMac) && downloadsInUse.isDisjoint(with: download.files)
    }

    /// Takes the files macOS downloaded one of System Settings' wallpapers into off the Mac, without
    /// asking, as System Settings' Remove Download does, so it's downloaded again when it's next chosen.
    /// It shows as taken away at once, as a large video can take a moment.
    func removeDownloads(of item: WallpaperItem) {
        refresh()
        guard canRemoveDownloads(of: item), let files = item.download?.files, let downloadsOnMac else { return }
        self.downloadsOnMac = downloadsOnMac.subtracting(files)
        downloadsQueue.async {
            for file in files where FileManager.default.fileExists(atPath: file.path) {
                do {
                    try FileManager.default.removeItem(at: file)
                } catch {
                    NSLog("Safelight: couldn't remove \(file.path): \(error)")
                }
            }
            self.lookForDownloads()
        }
    }

    /// Makes a wallpaper with `item`'s picture for one appearance, as `setPicture(_:isDark:)` does,
    /// fetching it first: downloading it, taking it from its video, or drawing it in its colour. It's
    /// shown with `options`, or else those the appearance has. When it's a shuffle's picture, the
    /// shuffle is what's remembered as the appearance's choice. `completion` is told whether the
    /// wallpaper was made. `isQuiet` for a change nobody asked for just then, which doesn't beep when it
    /// fails. It goes on `display`, by its UUID, or on the display chosen, or with Show on all Spaces on,
    /// on every display (`place(for:)`).
    func choose(_ item: WallpaperItem, isDark: Bool, options: PictureOptions? = nil, from shuffle: WallpaperShuffle.ID? = nil, isQuiet: Bool = false,
                on display: String? = nil, then completion: ((_ isMade: Bool) -> Void)? = nil) {
        let place = place(for: display)
        let options = options ?? keptOptions(isDark: isDark, at: place)
        let macintoshColors = options.macintoshColors ?? Self.macintoshColors(on: screen(for: place).flatMap(Self.uuid(of:)))
        let isGradient = options.isGradient == true
        // Only a picture is placed, as System Settings' image options place one
        let placement = item.isPicture ? options.placement : nil
        let chosenIsDark = isDark
        setPicture(isDark: isDark, choice: shuffle ?? item.id, item: item.id, options: options, placement: placement, hasPictureForEach: item.light != item.dark,
                   isDrawn: Self.isDrawn(item.light, isGradient: isGradient), isQuiet: isQuiet,
                   preview: Self.preview(of: item, isDark: isDark, options: options, placement: placement, macintoshColors: macintoshColors),
                   at: place, completion: completion) { [weak self] isDark, size, pictures in
            guard let self else { throw CancellationError() }
            // Its picture for the appearance chosen for as its options say, and its own for the other
            let showsDark = isDark == chosenIsDark && item.badge == .dynamic ? options.showsDark(isDark: isDark) : isDark
            return (try await self.file(for: showsDark ? item.dark : item.light, in: pictures, screenSize: size, inDarkAppearance: isDark,
                                        macintoshColors: macintoshColors, isGradient: isGradient), showsDark)
        }
    }

    /// What the desktop shows in an appearance once a wallpaper with `item`'s picture for it is made,
    /// shown with `options` and placed as `placement` says: its picture for the appearance its options
    /// pick, drawn, in its colour or that colour's gradient, or an aerial's first frame, from the picture
    /// the wallpaper's made with, not from System Settings' thumbnail of it, which is cropped otherwise.
    /// None for a picture that's still to be fetched, which can't be shown any sooner than the wallpaper.
    private static func preview(of item: WallpaperItem, isDark: Bool, options: PictureOptions, placement: Placement?, macintoshColors: String?) -> Preview? {
        let showsDark = item.badge == .dynamic ? options.showsDark(isDark: isDark) : isDark
        switch showsDark ? item.dark : item.light {
        case .drawn(let drawn, _):
            return preview(of: .drawn(drawn, lightShowsDark: showsDark, darkShowsDark: showsDark, colors: macintoshColors), isDark: isDark)
        case .color(let swatch):
            return swatchColor(swatch).map { preview(of: options.isGradient == true ? .gradient($0, isCustom: false) : .color($0), isDark: isDark) }
        case .file(let file):
            return preview(of: (file, showsDark), placement: placement)
        case .download(_, let file):
            return FileManager.default.isReadableFile(atPath: file.path) ? preview(of: (file, showsDark), placement: placement) : nil
        case .aerial(let id, _):
            // From its video on the Mac, as Apple's would take as long as the wallpaper
            guard let video = WallpaperLibrary.videoOnMac(ofAerial: id) else { return nil }
            return { _ in (try? await firstFrame(of: video, maxPixelSize: 400)).map { .picture($0) } }
        case .asset:
            return nil
        }
    }

    /// What `desktop` shows in an appearance, as `thumbnails(of:screenSize:)` draws it
    private static func preview(of desktop: Desktop, isDark: Bool) -> Preview {
        { screenSize in thumbnails(of: desktop, screenSize: screenSize).map { isDark ? $0.dark : $0.light } }
    }

    /// What a file's picture for Light or for Dark shows once a wallpaper is made with it, placed as
    /// `placement` says, as `thumbnails(of:placement:screenSize:)` draws it
    private static func preview(of picture: (file: URL, isDark: Bool), placement: Placement?) -> Preview {
        { screenSize in
            CGImageSourceCreateWithURL(picture.file as CFURL, nil)
                .flatMap { thumbnail(in: $0, isDark: picture.isDark, placement: placement ?? Placement(), screenSize: screenSize) }
                .map { .picture($0) }
        }
    }

    /// Whether a wallpaper's picture is one macOS draws itself on each display, for the display's size:
    /// Macintosh, Sequoia, or a colour as its gradient
    private static func isDrawn(_ picture: WallpaperItem.Picture, isGradient: Bool) -> Bool {
        switch picture {
        case .drawn: true
        case .color: isGradient
        case .file, .download, .aerial, .asset: false
        }
    }

    /// Makes a wallpaper all in one colour for one appearance, as `setPicture(_:isDark:)` does
    func setColor(_ color: NSColor, isDark: Bool) {
        let screenSize = Self.screenSize
        let place = place(for: nil)
        let color = color.usingColorSpace(.displayP3)?.cgColor ?? color.cgColor
        setPicture(isDark: isDark, choice: WallpaperItem.customColor, item: nil, options: keptOptions(isDark: isDark, at: place), placement: nil, hasPictureForEach: false,
                   preview: Self.preview(of: .color(color), isDark: isDark), at: place) { isDark, _, folder in
            (try Self.colorPicture(color, size: screenSize, named: "Colour", into: folder), isDark)
        }
    }

    /// The size, in pixels, of the largest display, which a colour is drawn at
    private static var screenSize: CGSize {
        NSScreen.screens.reduce(CGSize.zero) { size, screen in
            let pixels = pixelSize(of: screen)
            return CGSize(width: max(size.width, pixels.width), height: max(size.height, pixels.height))
        }
    }

    /// The size of a display, in pixels, which a picture in the middle of it has one of its own pixels to each of
    private static func pixelSize(of screen: NSScreen) -> CGSize {
        CGSize(width: screen.frame.width * screen.backingScaleFactor, height: screen.frame.height * screen.backingScaleFactor)
    }

    /// The sizes, in pixels, of the displays, each once, the main display's first, which a picture placed
    /// otherwise than filling the display is drawn at, for each
    private static var displaySizes: [CGSize] {
        NSScreen.screens.map(pixelSize(of:)).reduce(into: []) { sizes, size in
            if !sizes.contains(size) {
                sizes.append(size)
            }
        }
    }

    /// Makes a wallpaper with a photo from Photos for one appearance, as `setPicture(_:isDark:)` does
    func choose(_ photo: PhotosPickerItem, isDark: Bool) {
        let place = place(for: nil)
        let options = keptOptions(isDark: isDark, at: place)
        setPicture(isDark: isDark, choice: WallpaperItem.ownPicture(named: nil), item: nil, options: options, placement: options.placement, hasPictureForEach: false,
                   at: place) { isDark, _, pictures in
            guard let data = try await photo.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadUnknown) }
            let file = pictures.appendingPathComponent("Photo").appendingPathExtension(photo.supportedContentTypes.first?.preferredFilenameExtension ?? "heic")
            try data.write(to: file)
            try Self.keepOriginal(file, isDark: isDark, beside: pictures)
            return (file, isDark)
        }
    }

    /// Makes a wallpaper with `file`'s picture for one appearance (its only picture, or for a file
    /// with a picture for each, like Sonoma's, its picture for that appearance), keeping the desktop's
    /// picture for the other, and puts it on the display chosen, or with Show on all Spaces on, on every
    /// display. While the desktop has a wallpaper whose pictures Safelight can't tell, the other
    /// appearance takes `file`'s picture for it too.
    func setPicture(_ file: URL, isDark: Bool) {
        setPicture(file, isDark: isDark, choice: WallpaperItem.ownPicture(named: file.deletingPathExtension().lastPathComponent), options: keptOptions(isDark: isDark, at: place(for: nil)))
    }

    /// Makes a wallpaper with a picture of the user's own for one appearance, as `setPicture(_:isDark:)`
    /// does, placed as `options` say, remembered as `choice`. The picture is kept beside the wallpaper
    /// as it was, so it can be placed another way.
    private func setPicture(_ file: URL, isDark: Bool, choice: WallpaperItem.ID, options: PictureOptions) {
        setPicture(isDark: isDark, choice: choice, item: nil, options: options, placement: options.placement, hasPictureForEach: false,
                   preview: Self.preview(of: (file, isDark), placement: options.placement), at: place(for: nil)) { isDark, _, pictures in
            try Self.keepOriginal(file, isDark: isDark, beside: pictures)
            return (file, isDark)
        }
    }

    /// Keeps a picture of the user's own as it was before it was placed, beside the wallpaper being
    /// made, whose folder has `pictures` in it, named for its appearance: a copy of a file of the user's,
    /// which they may change or take away, or another wallpaper's own
    private static func keepOriginal(_ file: URL, isDark: Bool, beside pictures: URL) throws {
        let kept = pictures.deletingLastPathComponent().appendingPathComponent("\(isDark ? "Dark" : "Light") Original").appendingPathExtension(file.pathExtension)
        try? FileManager.default.removeItem(at: kept)
        if file.path.hasPrefix(pictures.deletingLastPathComponent().deletingLastPathComponent().path + "/") {
            try FileManager.default.linkItem(at: file, to: kept)
        } else {
            try FileManager.default.copyItem(at: file, to: kept)
        }
    }

    /// The picture of the user's own a wallpaper made here, in `folder`, has for an appearance, as it was
    /// before it was placed
    private static func original(in folder: URL, isDark: Bool) -> URL? {
        let name = "\(isDark ? "Dark" : "Light") Original"
        return (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?.first { $0.deletingPathExtension().lastPathComponent == name }
    }

    /// Makes a wallpaper with the picture `picture` gives for one appearance, as `setPicture(_:isDark:)`
    /// does. The other appearance keeps the picture the desktop shows in it, fetched as one of System
    /// Settings' own is when it's one of those. While the desktop has one of System Settings' shuffles,
    /// it takes one of the shuffle's pictures instead, and Safelight's own shuffle of them carries on
    /// for it. While the desktop has one macOS draws, like Sequoia, it takes it drawn as macOS draws it
    /// (`drawing(of:shows:)`). While it has a wallpaper whose pictures Safelight can't tell,
    /// it takes the one `picture` gives for it, when there's `hasPictureForEach`, or the same one. `picture`
    /// fetches it, for a display of the size it's given, in pixels, into the folder it's given, which is
    /// taken away once the wallpaper is made, and says whether it's the file's picture for Dark, for one
    /// with a picture for each, and it's placed on the display as `placement` says. `choice` is
    /// remembered as the appearance's choice, with the `options` it's shown with, and `item` is the
    /// wallpaper of System Settings' the picture is from. It beeps when it can't be made, unless `isQuiet`.
    /// The appearance shows it as chosen at once, and `preview` as what it has as soon as that's drawn,
    /// as System Settings shows a wallpaper as soon as it's clicked.
    ///
    /// While another is being made, it's made once that one is on the desktop, as only one can be made
    /// at a time, in place of any other asked for the appearance and display meanwhile (`wait`). One
    /// that's `isQuiet`, a shuffle's on time, isn't made: its shuffle tries again later.
    ///
    /// While a picture is placed otherwise than filling the display, in either appearance, each size of
    /// display has a wallpaper of its own, with the pictures placed for its size, as macOS places a
    /// picture on each display (`file(of:for:)`). So it has while either appearance has one macOS draws
    /// itself, drawn for its size, as macOS draws one on each display: the desktop's, or `picture`'s, when
    /// `isDrawn`. Otherwise one fills them all. They're made for every display even when it goes on one
    /// (`place`, or the display chosen, `place(for:)`), as Show on all Spaces may put it on them all.
    private func setPicture(isDark: Bool, choice: String?, item: WallpaperItem.ID?, options: PictureOptions, placement: Placement?, hasPictureForEach: Bool,
                            isDrawn: Bool = false, isQuiet: Bool = false, preview: Preview? = nil, at place: String?, as asked: Change? = nil,
                            completion: ((_ isMade: Bool) -> Void)? = nil,
                            picture: @escaping (_ isDark: Bool, _ size: CGSize, _ folder: URL) async throws -> (file: URL, isDark: Bool)) {
        // Nor to a display that's been disconnected since
        guard let folder, place == nil || screen(for: place) != nil, !(isQuiet && isChanging) else {
            completion?(false)
            return
        }
        let change = asked ?? Change(isDark: isDark, place: place, choice: choice, options: options)
        if asked == nil {
            showPreview(preview, of: change)
        }
        guard !isChanging else {
            wait(change, isChoice: true) { [weak self] in
                self?.setPicture(isDark: isDark, choice: choice, item: item, options: options, placement: placement, hasPictureForEach: hasPictureForEach,
                                 isDrawn: isDrawn, isQuiet: isQuiet, at: place, as: change, completion: completion, picture: picture)
            } drop: {
                completion?(false)
            }
            return
        }
        refresh()
        let current = desktop(at: place)
        let followsSun = lightFollowsSun(isDark: isDark, choice: choice, options: options, replacing: current)
        let screenSize = Self.screenSize
        // Never none, as it's made all the same while there's no display to put it on
        let displaySizes = Self.displaySizes.isEmpty ? [.zero] : Self.displaySizes
        let wallpaper = folder.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent("Safelight.heic")
        let pictures = wallpaper.deletingLastPathComponent().appendingPathComponent("Pictures", isDirectory: true)
        changing = change
        let id = change.id
        // Away from the main thread, as fetching the picture, and writing two the size of a screen, takes a while
        Task.detached(priority: .userInitiated) {
            let isMade: Bool
            // The shuffle's picture the other appearance takes, picked as the shuffle picks its next one
            var shuffled: WallpaperItem?
            do {
                try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
                // A picture fetched for the main display, and while it's drawn for a display's size, drawn
                // again for each other size of display, into a folder of its own, as each display has it
                func onEachSize(isDrawn: Bool, _ fetch: (_ size: CGSize, _ folder: URL) async throws -> (file: URL, isDark: Bool)) async throws -> (CGSize) -> (file: URL, isDark: Bool) {
                    let main = try await fetch(displaySizes[0], pictures)
                    var drawn: [String: (file: URL, isDark: Bool)] = [:]
                    for size in isDrawn ? displaySizes.dropFirst() : [] {
                        let folder = pictures.appendingPathComponent(Self.folderName(of: size), isDirectory: true)
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        drawn[Self.folderName(of: size)] = try await fetch(size, folder)
                    }
                    return { drawn[Self.folderName(of: $0)] ?? main }
                }
                let chosen = try await onEachSize(isDrawn: isDrawn) { try await picture(isDark, $0, $1) }
                // Each appearance's picture as the wallpaper for a display of a size, in pixels, has it
                let chosenOn = { (size: CGSize) in DisplayPicture(chosen(size), placement: placement, screenSize: size) }
                let otherOn: (CGSize) -> DisplayPicture
                if case .shuffle(let shuffle, _)? = current {
                    shuffled = WallpaperLibrary.shared.pictures(of: shuffle.id).randomElement()
                }
                if let shuffled {
                    let other = (try await self.file(for: isDark ? shuffled.light : shuffled.dark, in: pictures, screenSize: screenSize, inDarkAppearance: !isDark), !isDark)
                    otherOn = { _ in DisplayPicture(other) }
                } else if let current, let drawing = Self.drawing(of: current, shows: !isDark) {
                    // Drawn for each size of display, as macOS draws it on each
                    let other = try await onEachSize(isDrawn: true, drawing)
                    otherOn = { DisplayPicture(other($0)) }
                } else if let current, let other = try await self.picture(current, shows: !isDark, in: pictures, screenSize: screenSize) {
                    // As each display shows it: placed for it, or from a wallpaper Safelight made, the
                    // wallpaper's own for it while it's placed for it there (another size of picture)
                    let isMadeHere = self.isMadeHere(other.file)
                    let main = Self.file(of: other.file, forPixelSize: displaySizes[0])
                    otherOn = { size in
                        let own = isMadeHere ? Self.file(of: other.file, forPixelSize: size) : other.file
                        let isOwn = !isMadeHere || own != main && Self.pixelSize(of: (own, other.isDark)) != Self.pixelSize(of: (main, other.isDark))
                        return DisplayPicture((isOwn ? own : main, other.isDark), placement: other.placement, screenSize: size)
                    }
                } else if hasPictureForEach {
                    let other = try await onEachSize(isDrawn: isDrawn) { try await picture(!isDark, $0, $1) }
                    otherOn = { DisplayPicture(other($0)) }
                } else {
                    otherOn = { size in DisplayPicture((chosen(size).file, !isDark), placement: placement, screenSize: size) }
                }
                func picturesOn(_ size: CGSize) -> (light: DisplayPicture, dark: DisplayPicture) {
                    isDark ? (otherOn(size), chosenOn(size)) : (chosenOn(size), otherOn(size))
                }
                // The main display's, and each other size's whose pictures are others, placed for it
                let main = displaySizes[0]
                let sizes = [main] + displaySizes.dropFirst().filter { picturesOn($0) != picturesOn(main) }
                isMade = try sizes.indices.allSatisfy { index in
                    let (light, dark) = picturesOn(sizes[index])
                    let name = Self.folderName(of: sizes[index])
                    return Self.makeWallpaper(at: index == 0 ? wallpaper : Self.file(in: wallpaper.deletingLastPathComponent(), forPixelSize: sizes[index]),
                                              light: try light.picture(named: "Light \(name)", into: pictures), dark: try dark.picture(named: "Dark \(name)", into: pictures))
                }
                // A picture of the user's own the other appearance kept stays as it was before it was
                // placed, to be placed again
                if isMade, case .file(let made, _)? = current, self.isMadeHere(made),
                   let original = Self.original(in: Self.wallpaperFolder(of: made), isDark: !isDark) {
                    try? Self.keepOriginal(original, isDark: !isDark, beside: pictures)
                }
                // With Sequoia set to Automatic in Light, its looks through the day beside each file, for
                // Light, which macOS changes between as the sun moves: those of the wallpaper before
                // for the same size of display, which only depend on that, or else drawn. The wallpaper
                // does without, should they fail, as it would on a macOS whose Sequoia can't be drawn.
                if isMade, followsSun {
                    let before: URL? = if case .file(let made, _)? = current, self.isMadeHere(made) { made } else { nil }
                    for (index, size) in sizes.enumerated() where size.width > 0 && size.height > 0 {
                        let own = index == 0 ? wallpaper : Self.file(in: wallpaper.deletingLastPathComponent(), forPixelSize: size)
                        let sun = own.deletingLastPathComponent().appendingPathComponent(Self.sunFileName)
                        let kept = before.map { Self.file(of: $0, forPixelSize: size).deletingLastPathComponent().appendingPathComponent(Self.sunFileName) }
                        if let kept, Self.pixelSize(of: (kept, false)) == size, (try? FileManager.default.linkItem(at: kept, to: sun)) != nil {
                            continue
                        }
                        if !Self.makeSunWallpaper(at: sun, size: size) {
                            NSLog("Safelight: couldn't make Sequoia's looks through the day for \(Self.folderName(of: size))")
                            try? FileManager.default.removeItem(at: sun)
                        }
                    }
                }
            } catch {
                NSLog("Safelight: couldn't fetch the wallpaper's picture: \(error)")
                isMade = false
            }
            try? FileManager.default.removeItem(at: pictures)
            let shuffledID = shuffled?.id
            await MainActor.run {
                self.changing = nil
                self.downloadProgress = nil
                if isMade {
                    self.put(wallpaper, isDark: isDark, choice: choice, item: item, options: options, replacing: current, at: place, shuffled: shuffledID)
                } else {
                    NSLog("Safelight: couldn't make a wallpaper")
                    try? FileManager.default.removeItem(at: wallpaper.deletingLastPathComponent())
                    // The appearance shows what the desktop has again
                    if self.previews[isDark]?.change == id {
                        self.previews[isDark] = nil
                    }
                    if !isQuiet {
                        NSSound.beep()
                    }
                }
                completion?(isMade)
                self.makeWaiting()
            }
        }
    }

    /// Keeps a change asked for while another is being made, to be made once that one is on the desktop
    /// (`makeWaiting`), in place of those waiting that it's asked for again: for the same appearance and
    /// place, a choice takes the place of every change waiting, and a change of options takes the place
    /// of an earlier change of options, which comes after the choice it's for
    private func wait(_ change: Change, isChoice: Bool, make: @escaping () -> Void, drop: @escaping () -> Void) {
        let isAskedAgain = { (waiting: Waiting) in
            waiting.change.isDark == change.isDark && waiting.change.place == change.place && (isChoice || !waiting.isChoice)
        }
        let dropped = waiting.filter(isAskedAgain)
        waiting.removeAll(where: isAskedAgain)
        waiting.append(Waiting(change: change, isChoice: isChoice, make: make, drop: drop))
        dropped.forEach { $0.drop() }
    }

    /// Makes the changes waiting, one after the other, now that none is being made
    private func makeWaiting() {
        while changing == nil, !waiting.isEmpty {
            waiting.removeFirst().make()
        }
    }

    /// Whether a wallpaper made with `choice` for an appearance, shown with `options`, in place of
    /// `current`, has Sequoia set to Automatic in Light: chosen for Light, or kept for it from `current`
    /// (`put`), which then has its looks through the day for Light, as the extension shows them
    private func lightFollowsSun(isDark: Bool, choice: String?, options: PictureOptions, replacing current: Desktop?) -> Bool {
        let light: (choice: String?, options: PictureOptions)
        switch (isDark, current) {
        case (false, _):
            light = (choice, options)
        case (true, .file(let made, _)?) where isMadeHere(made):
            let choices = self.choices(of: made)
            light = (choices.light, choices.options(isDark: false))
        case (true, .drawn(let drawn, let lightShowsDark, let darkShowsDark, _)?):
            light = (drawn.rawValue, PictureOptions(appearance: AppearanceOption(lightShowsDark: lightShowsDark, darkShowsDark: darkShowsDark)))
        default:
            return false
        }
        return light.choice == DrawnWallpaper.sequoia.rawValue && (light.options.appearance ?? .automatic) == .automatic
    }

    /// Writes Sequoia's looks through the day (`SequoiaWallpaper.looks`), drawn for a display of `size`,
    /// in pixels, into a HEIC at `file`, each with where the sun is when the extension shows it, in the
    /// metadata macOS's dynamic wallpapers have, and Sequoia's Light and Dark looks as its own. So
    /// macOS shows the look of the time of day from it itself, as the sun moves, from the same location,
    /// as it does with Sequoia set to Automatic. Like the pictures drawn here, without loss.
    private static func makeSunWallpaper(at file: URL, size: CGSize) -> Bool {
        let looks = SequoiaWallpaper.looks
        let solar: [String: Any] = ["si": looks.enumerated().map { ["a": $0.element.altitude, "z": $0.element.azimuth, "i": $0.offset] },
                                    "ap": ["l": SequoiaWallpaper.lightLook, "d": SequoiaWallpaper.darkLook]]
        let metadata = CGImageMetadataCreateMutable()
        guard let plist = try? PropertyListSerialization.data(fromPropertyList: solar, format: .binary, options: 0),
              CGImageMetadataRegisterNamespaceForPrefix(metadata, metadataNamespace, metadataPrefix, nil),
              CGImageMetadataSetValueWithPath(metadata, nil, solarMetadataPath, plist.base64EncodedString() as CFString),
              let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.heic.identifier as CFString, looks.count, nil) else { return false }
        // All of them kept until they're written: at 5120 by 2880, a second and 0.7 GB more for that long
        let options = [kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary
        for look in looks.indices {
            guard let picture = SequoiaWallpaper.picture(look: look, size: size) else { return false }
            if look == 0 {
                CGImageDestinationAddImageAndMetadata(destination, picture, metadata, options)
            } else {
                CGImageDestinationAddImage(destination, picture, options)
            }
        }
        return CGImageDestinationFinalize(destination)
    }

    /// Puts a wallpaper just made on every display, or on one (`place`, as `place(for:)` gives it), on
    /// every Space or the one it's showing, in place of `current`, and remembers which of System
    /// Settings' wallpapers, or which shuffle, it has the picture for an appearance from, and with which
    /// options. `shuffled` is the picture the other appearance took from `current`, when that's a shuffle.
    private func put(_ wallpaper: URL, isDark: Bool, choice: String?, item: WallpaperItem.ID?, options: PictureOptions, replacing current: Desktop?, at place: String?,
                     shuffled: WallpaperItem.ID? = nil) {
        // The other appearance kept the desktop's picture, which from a wallpaper of System Settings'
        // is that wallpaper's, as its options show it, from one of its shuffles, the shuffle's, which
        // carries on here, and from a colour of the user's own, that colour. From one Safelight can't
        // tell, or a shuffle with no pictures, it took its picture from the same wallpaper, with the same
        // options but its own appearance's picture, but doesn't shuffle.
        var choices: Choices
        switch current {
        case .file(let made, _)? where isMadeHere(made):
            choices = self.choices(of: made)
            // The choices kept from before are its own, which another Space may still show
            self.choices[Self.wallpaperFolder(of: made).lastPathComponent] = choices
        case .item(let current, let lightShowsDark, let darkShowsDark)?:
            let options = PictureOptions(appearance: AppearanceOption(lightShowsDark: lightShowsDark, darkShowsDark: darkShowsDark))
            choices = Choices(light: current.id, dark: current.id, lightOptions: options, darkOptions: options)
        case .shuffle(let shuffle, let interval)? where shuffled != nil:
            choices = Choices(light: shuffle.id, dark: shuffle.id)
            WallpaperShuffler.shared.carryOn(shuffle.id, interval: interval, from: shuffled, isDark: !isDark, on: place)
        case .drawn(let drawn, let lightShowsDark, let darkShowsDark, let colors)?:
            let options = PictureOptions(appearance: AppearanceOption(lightShowsDark: lightShowsDark, darkShowsDark: darkShowsDark), macintoshColors: colors)
            choices = Choices(light: drawn.rawValue, dark: drawn.rawValue, lightOptions: options, darkOptions: options)
        case .color?, .gradient(_, isCustom: true)?:
            choices = Choices(light: WallpaperItem.customColor, dark: WallpaperItem.customColor)
        case nil, .shuffle?:
            var other = options
            other.appearance = nil
            choices = Choices(light: item, dark: item, lightOptions: other, darkOptions: other)
        default:
            choices = Choices()
        }
        choices.set(choice, options: options, isDark: isDark)
        self.choices[Self.wallpaperFolder(of: wallpaper).lastPathComponent] = choices
        let screens = screens(for: place)
        putOnDesktop(wallpaper, on: screens)
        // Only once every Space has the new one: another Space, or another display, may still show one
        // from before
        if place == nil && showsOnAllSpaces && Self.allSpacesOption != nil {
            removeWallpapers(except: wallpaper)
        } else {
            removeWallpapers(except: wallpaper, keepingThoseShown: true)
        }
        earlierChoices = nil
        UserDefaults.standard.removeObject(forKey: Self.earlierChoicesKey)
        if let screen = screen(for: self.place(for: nil)), screens.contains(screen) {
            show(.file(Self.file(of: wallpaper, for: screen)), on: screen)
        }
        YourPhotos.shared.reloadAfterSettingWallpaper()
        // A shuffle stops once the appearance has another choice
        WallpaperShuffler.shared.schedule()
    }

    /// Puts one of Safelight's wallpapers on displays (`setDesktop(_:isDark:on:)`), and until macOS
    /// names it on each, for a few seconds at most, takes the files it had before for ones from before
    /// (`read`)
    private func putOnDesktop(_ wallpaper: URL, on screens: [NSScreen]) {
        let isDark = Self.isDark
        for screen in screens {
            guard let display = Self.uuid(of: screen) else { continue }
            var before = Set([lastRead[display], NSWorkspace.shared.desktopImageURL(for: screen)].compactMap { $0?.standardizedFileURL })
            if let justPut = justPut[display], Date() < justPut.until {
                before.formUnion(justPut.before.union([justPut.wallpaper]))
            }
            justPut[display] = (Self.shownFile(of: wallpaper, for: screen, isDark: isDark).standardizedFileURL, before, Date().addingTimeInterval(5))
        }
        setDesktop(wallpaper, isDark: isDark, on: screens)
        // Once macOS surely names it, or another Space's, as Spaces may have been switched meanwhile
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.1) { [weak self] in
            self?.refresh()
        }
    }

    /// Puts one of Safelight's wallpapers on displays, its own file for each (`file(of:for:)`), on every
    /// Space or only on the one each display is showing, as `showsOnAllSpaces` says, filling it, as each
    /// of its pictures is placed in it. Only on the one, the other Spaces keep theirs, even System
    /// Settings' wallpaper for every Space, which macOS's wallpaper service then gives each Space as its
    /// own, as System Settings does with its Show on all Spaces turned off. In Light, while it has
    /// Sequoia's looks through the day for Light, it's that file that's put on (`followAppearance`).
    private func setDesktop(_ wallpaper: URL, isDark: Bool? = nil, on screens: [NSScreen]) {
        let isDark = isDark ?? Self.isDark
        for screen in screens {
            var options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
            options[.imageScaling] = NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue)
            options[.allowClipping] = NSNumber(value: true)
            if let allSpacesOption = Self.allSpacesOption {
                options[allSpacesOption] = showsOnAllSpaces
            }
            let file = Self.shownFile(of: wallpaper, for: screen, isDark: isDark)
            do {
                try NSWorkspace.shared.setDesktopImageURL(file, for: screen, options: options)
            } catch {
                NSLog("Safelight: couldn't set the wallpaper of \(screen.localizedName): \(error)")
            }
        }
    }

    /// The file of a wallpaper Safelight made, by any of its files, that a display shows: one made for
    /// a display of its size, while a picture in it is placed otherwise than filling the display, or else
    /// the wallpaper's own, which the main display has
    private static func file(of wallpaper: URL, for screen: NSScreen) -> URL {
        file(of: wallpaper, forPixelSize: pixelSize(of: screen))
    }

    /// The file of a wallpaper Safelight made, by any of its files, that a display has in an appearance:
    /// in Light, the one beside its own with Sequoia's looks through the day, when it has one
    private static func shownFile(of wallpaper: URL, for screen: NSScreen, isDark: Bool) -> URL {
        let own = file(of: wallpaper, for: screen)
        let sun = own.deletingLastPathComponent().appendingPathComponent(sunFileName)
        return !isDark && FileManager.default.fileExists(atPath: sun.path) ? sun : own
    }

    /// The wallpaper's own file beside one of its files, which is that file unless it's the one with
    /// Sequoia's looks through the day
    private static func ownFile(beside file: URL) -> URL {
        file.lastPathComponent == sunFileName ? file.deletingLastPathComponent().appendingPathComponent("Safelight.heic") : file
    }

    /// The file of a wallpaper Safelight made, by any of its files, for a display of a size, in pixels
    private static func file(of wallpaper: URL, forPixelSize size: CGSize) -> URL {
        let folder = wallpaperFolder(of: wallpaper)
        let own = file(in: folder, forPixelSize: size)
        return FileManager.default.fileExists(atPath: own.path) ? own : folder.appendingPathComponent("Safelight.heic")
    }

    /// Where the wallpaper made in `folder` has its file for a display of a size, in pixels, when it has
    /// one: in a folder named for the size, by the same name as its own, as macOS shows its name
    private static func file(in folder: URL, forPixelSize size: CGSize) -> URL {
        folder.appendingPathComponent(folderName(of: size), isDirectory: true).appendingPathComponent("Safelight.heic")
    }

    /// The name of the folder a wallpaper has its file for a display of a size in, like "1920x1080"
    private static func folderName(of size: CGSize) -> String {
        "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }

    /// The folder of the wallpaper Safelight made that `file` is one of, its own or one for a display of
    /// a size, or for any other file, the folder it's in
    private static func wallpaperFolder(of file: URL) -> URL {
        let folder = file.deletingLastPathComponent()
        let size = folder.lastPathComponent.split(separator: "x")
        return size.count == 2 && size.allSatisfy({ Int($0) != nil }) ? folder.deletingLastPathComponent() : folder
    }

    /// The file with a wallpaper's picture in it, fetched into `folder` when it isn't one already.
    /// `screenSize`, in pixels, is the size a colour, Macintosh or Sequoia is drawn at, Macintosh in the
    /// colours of `macintoshColors` as they are in Dark or in Light (`inDarkAppearance`), and a colour as
    /// its gradient when `isGradient`.
    private func file(for picture: WallpaperItem.Picture, in folder: URL, screenSize: CGSize, inDarkAppearance: Bool, macintoshColors: String? = nil, isGradient: Bool = false) async throws -> URL {
        switch picture {
        case .file(let file):
            return file
        case .download(let id, let file):
            return FileManager.default.isReadableFile(atPath: file.path) ? file : try await download(id, into: folder)
        case .aerial(let id, let video):
            return try await Self.frame(ofAerial: id, video: video, into: folder)
        case .color(let swatch):
            guard isGradient else { return try Self.colorPicture(swatch, size: screenSize, into: folder) }
            guard let color = Self.color(ofSwatch: swatch) else { throw CocoaError(.fileReadCorruptFile) }
            return try Self.gradientPicture(color, size: screenSize, named: swatch.deletingPathExtension().lastPathComponent, into: folder)
        case .drawn(let drawn, let isDark):
            return try Self.drawnPicture(drawn, showsDark: isDark, inDarkAppearance: inDarkAppearance, colors: macintoshColors, size: screenSize, into: folder)
        case .asset(let id):
            return try await photo(id, into: folder)
        }
    }

    /// A photo in the Photos library, as it looks there, with its edits, at its full size, downloaded
    /// from iCloud when the Mac doesn't have it, as System Settings' photo sets' photos are
    private func photo(_ id: String, into folder: URL) async throws -> URL {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { throw CocoaError(.fileNoSuchFile) }
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.progressHandler = { [weak self] progress, _, _, _ in
            // In whole percents, so the window isn't redrawn for every few bytes
            let fraction = (progress * 100).rounded(.down) / 100
            DispatchQueue.main.async {
                if self?.downloadProgress != fraction {
                    self?.downloadProgress = fraction
                }
            }
        }
        let (data, type) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, String?), Error>) in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, type, _, info in
                if let data {
                    continuation.resume(returning: (data, type))
                } else {
                    continuation.resume(throwing: info?[PHImageErrorKey] as? Error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
        let file = folder.appendingPathComponent("Photo").appendingPathExtension(type.flatMap { UTType($0)?.preferredFilenameExtension } ?? "heic")
        try data.write(to: file)
        return file
    }

    /// One of the pictures macOS downloads from Apple once it's chosen in System Settings, downloaded
    /// from where macOS's list of them says it is. It comes zipped, with the picture inside.
    private func download(_ id: String, into folder: URL) async throws -> URL {
        guard let url = WallpaperLibrary.shared.downloadURL(of: id) else { throw URLError(.fileDoesNotExist) }
        let zip = folder.appendingPathComponent("\(id).zip")
        let unzipped = folder.appendingPathComponent(id, isDirectory: true)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var progress: NSKeyValueObservation?
            let task = URLSession.shared.downloadTask(with: url) { location, response, error in
                progress?.invalidate()
                do {
                    guard let location, (response as? HTTPURLResponse)?.statusCode == 200 else { throw error ?? URLError(.badServerResponse) }
                    try FileManager.default.moveItem(at: location, to: zip)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            progress = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                // In whole percents, so the window isn't redrawn for every few bytes
                let fraction = (progress.fractionCompleted * 100).rounded(.down) / 100
                DispatchQueue.main.async {
                    if self?.downloadProgress != fraction {
                        self?.downloadProgress = fraction
                    }
                }
            }
            task.resume()
        }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, unzipped.path]
        try ditto.run()
        ditto.waitUntilExit()
        let files = FileManager.default.enumerator(at: unzipped, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        guard ditto.terminationStatus == 0, let picture = files.first(where: { $0.pathExtension.lowercased() == "heic" }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return picture
    }

    /// The first frame of an aerial's video, as the desktop shows it: from the copy macOS keeps once
    /// it's downloaded, or the one it comes with, or else from Apple's, which AVFoundation reads only
    /// as much of as it needs
    private static func frame(ofAerial id: String, video: URL, into folder: URL) async throws -> URL {
        let videos = (WallpaperLibrary.videoOnMac(ofAerial: id).map { [$0] } ?? []) + [video]
        var frame: CGImage?
        var failure: Error?
        for video in videos where frame == nil {
            do {
                frame = try await firstFrame(of: video)
            } catch {
                failure = error
            }
        }
        guard let frame else { throw failure ?? CocoaError(.fileReadUnknown) }
        let file = folder.appendingPathComponent("\(id).heic")
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.heic.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, frame, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return file
    }

    /// The first frame of a video the right way up, at its full size, or scaled down to fit
    /// `maxPixelSize` each way
    private static func firstFrame(of video: URL, maxPixelSize: Int? = nil) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        if let maxPixelSize {
            generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        }
        return try await generator.image(at: .zero).image
    }

    /// One of System Settings' colours, as a picture the size of the screen, in the colour of its swatch
    private static func colorPicture(_ swatch: URL, size: CGSize, into folder: URL) throws -> URL {
        guard let color = color(ofSwatch: swatch) else { throw CocoaError(.fileReadCorruptFile) }
        return try colorPicture(color, size: size, named: swatch.deletingPathExtension().lastPathComponent, into: folder)
    }

    /// A colour's swatch's colour, as `color(ofSwatch:)` reads it, read once: the Wallpaper window fills
    /// its circle with it, as System Settings fills its with the colour
    static func swatchColor(_ swatch: URL) -> CGColor? {
        if let color = swatchColors.object(forKey: swatch as NSURL) {
            return color
        }
        let color = color(ofSwatch: swatch)
        color.map { swatchColors.setObject($0, forKey: swatch as NSURL) }
        return color
    }

    private static let swatchColors = NSCache<NSURL, CGColor>()

    /// The colour of one of System Settings' colours: its swatch's middle pixel
    private static func color(ofSwatch swatch: URL) -> CGColor? {
        guard let source = CGImageSourceCreateWithURL(swatch as CFURL, nil),
              let swatchImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let colorSpace = swatchImage.colorSpace.flatMap({ $0.model == .rgb ? $0 : nil }) ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let middle = CGRect(x: swatchImage.width / 2, y: swatchImage.height / 2, width: 1, height: 1)
        guard let pixel = swatchImage.cropping(to: middle) else { return nil }
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return CGColor(colorSpace: colorSpace, components: [CGFloat(bytes[0]) / 255, CGFloat(bytes[1]) / 255, CGFloat(bytes[2]) / 255, 1])
    }

    /// A picture the size of the screen, all in one colour
    private static func colorPicture(_ color: CGColor, size: CGSize, named name: String, into folder: URL) throws -> URL {
        guard let colorSpace = color.colorSpace.flatMap({ $0.model == .rgb ? $0 : nil }) ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: max(Int(size.width), 1), height: max(Int(size.height), 1), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CocoaError(.fileReadCorruptFile) }
        context.setFillColor(color)
        context.fill(CGRect(origin: .zero, size: CGSize(width: context.width, height: context.height)))
        let file = folder.appendingPathComponent(name).appendingPathExtension("tiff")
        guard let picture = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        try writeLossless(picture, to: file)
        return file
    }

    /// Whether `wallpaper` is one Safelight made, or a display's file of one
    private func isMadeHere(_ wallpaper: URL) -> Bool {
        guard let folder else { return false }
        return Self.wallpaperFolder(of: wallpaper.standardizedFileURL).deletingLastPathComponent().path == folder.standardizedFileURL.path
    }

    /// Where macOS's wallpaper service keeps what each display and Space has on its desktop
    private static let store = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")

    /// The ID macOS's wallpaper service knows a display by, its `Display.key`
    static func uuid(of screen: NSScreen) -> String? {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// One of the desktops macOS's wallpaper service keeps: the one choice it shows, by the provider
    /// that shows it and the configuration it has there, and the options it's shown with, each under the
    /// kind of control that sets it
    private struct StoredDesktop {
        let provider: String
        let configuration: [String: Any]
        let options: [String: Any]
        /// Whether it shuffles its choices, as macOS's wallpaper service did with shuffles before they
        /// were choices of their own (it moves old ones over)
        let isShuffled: Bool

        /// Nil for a desktop of more than one choice that doesn't shuffle them
        init?(_ desktop: [String: Any]) {
            func plist(_ value: Any?) -> [String: Any] {
                (value as? Data).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
            }
            guard let content = desktop["Content"] as? [String: Any],
                  let choices = content["Choices"] as? [[String: Any]],
                  let provider = choices.first?["Provider"] as? String else { return nil }
            isShuffled = content["Shuffle"].map { $0 as? String != "$null" } ?? false
            guard choices.count == 1 || isShuffled else { return nil }
            self.provider = provider
            configuration = plist(choices[0]["Configuration"])
            options = plist(content["EncodedOptionValues"])["values"] as? [String: Any] ?? [:]
        }

        var url: URL? {
            ((configuration["url"] as? [String: Any])?["relative"] as? String).flatMap(URL.init(string:))
        }

        func option(_ name: String, _ control: String) -> [String: Any]? {
            ((options[name] as? [String: Any])?[control] as? [String: Any])?["_0"] as? [String: Any]
        }
    }

    /// What a display's desktop has, a wallpaper Safelight didn't make, when Safelight can tell its
    /// pictures, from what macOS's wallpaper service keeps: a desktop for every display, and for each
    /// Space and display on it, or one for all of them. `desktopImageURL(for:)` names a file whatever the
    /// desktop has (its default picture for a colour), so it only says which of them it is when one has
    /// that file. Otherwise it's the one chosen last, which is the Space's own unless Spaces have been
    /// given wallpapers of their own since.
    private static func desktop(showing wallpaper: URL?, on display: String?) -> Desktop? {
        let desktops = storedDesktops(on: display)
        func lastSet(_ desktop: [String: Any]) -> Date {
            desktop["LastSet"] as? Date ?? .distantPast
        }
        let named = wallpaper.flatMap { wallpaper in
            desktops.first { StoredDesktop($0)?.url?.standardizedFileURL.path == wallpaper.standardizedFileURL.path }
        }
        return (named ?? desktops.max { lastSet($0) < lastSet($1) }).flatMap(StoredDesktop.init).flatMap(desktop(of:))
    }

    /// The desktops macOS's wallpaper service keeps for a display: the one for all of them, its own, and
    /// each Space's
    private static func storedDesktops(on display: String?) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: store),
              let index = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
        var desktops: [[String: Any]] = []
        func add(_ owner: Any?, ofDisplay: Bool = false) {
            var owner = owner as? [String: Any]
            if ofDisplay {
                owner = display.flatMap { (owner?["Displays"] as? [String: Any])?[$0] as? [String: Any] }
            }
            if let desktop = owner?["Desktop"] as? [String: Any] {
                desktops.append(desktop)
            }
        }
        add(index["AllSpacesAndDisplays"])
        add(index["SystemDefault"])
        add(index, ofDisplay: true)
        for space in (index["Spaces"] as? [String: Any] ?? [:]).values {
            add((space as? [String: Any])?["Default"])
            add(space, ofDisplay: true)
        }
        return desktops
    }

    /// The files macOS has downloaded that it's showing, as the desktop or the screen saver, of any
    /// display or Space: the videos of the aerials chosen in macOS's wallpaper service, which System
    /// Settings never takes off the Mac. An aerials' shuffle has none, as for System Settings.
    private static func downloadsInUse() -> Set<URL> {
        guard let data = try? Data(contentsOf: store),
              let index = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
        var files: Set<URL> = []
        func add(_ owner: Any?) {
            let owner = owner as? [String: Any]
            for content in ["Desktop", "Idle"] {
                guard let stored = (owner?[content] as? [String: Any]).flatMap(StoredDesktop.init),
                      stored.provider == "com.apple.wallpaper.choice.aerials", let id = stored.configuration["assetID"] as? String else { continue }
                // An aerial's own ID, or for macOS's own, with a video for each appearance, its subcategory's.
                // A shuffle has its category's, or "shuffle-all-aerials", which isn't any aerial's.
                files.formUnion(WallpaperLibrary.shared.item(ofAerial: id)?.download?.files ?? [])
            }
        }
        add(index["AllSpacesAndDisplays"])
        add(index["SystemDefault"])
        for display in (index["Displays"] as? [String: Any] ?? [:]).values {
            add(display)
        }
        for space in (index["Spaces"] as? [String: Any] ?? [:]).values {
            let space = space as? [String: Any]
            add(space?["Default"])
            for display in (space?["Displays"] as? [String: Any] ?? [:]).values {
                add(display)
            }
        }
        return files
    }

    /// Macintosh's colours as System Settings would show it chosen now for the display shown
    var macintoshColors: String? {
        Self.macintoshColors(on: screen(for: place(for: nil)).flatMap(Self.uuid(of:)))
    }

    /// Macintosh's colours as System Settings would show it chosen now for a display, by its UUID: its
    /// colorScheme option as the display's desktop chosen last has it, which keeps options from one
    /// choice to the next
    private static func macintoshColors(on display: String?) -> String? {
        let desktops = storedDesktops(on: display)
        let last = desktops.max { ($0["LastSet"] as? Date ?? .distantPast) < ($1["LastSet"] as? Date ?? .distantPast) }
        return last.flatMap(StoredDesktop.init)?.option("colorScheme", "picker")?["id"] as? String
    }

    /// What one of the wallpaper service's desktops shows, when Safelight can tell its pictures
    private static func desktop(of stored: StoredDesktop) -> Desktop? {
        let library = WallpaperLibrary.shared
        let pictureID = stored.url.map { "picture:\($0.deletingPathExtension().lastPathComponent)" }
        let appearance = stored.option("appearance", "picker")?["id"] as? String
        // A wallpaper with a picture for each appearance, set to Light or to Dark, shows that one in both
        func item(_ id: WallpaperItem.ID?, appearance: String?) -> Desktop? {
            guard let item = id.flatMap({ library.item($0) }) else { return nil }
            return .item(item, lightShowsDark: appearance == "dark", darkShowsDark: appearance != "light")
        }
        func drawn(_ drawn: DrawnWallpaper, appearance: String?) -> Desktop {
            .drawn(drawn, lightShowsDark: appearance == "dark", darkShowsDark: appearance != "light", colors: stored.option("colorScheme", "picker")?["id"] as? String)
        }
        // A shuffle changes as often as its option says (the aerials' have one of their own), which is
        // only there once it's been set
        func shuffle(_ id: WallpaperShuffle.ID, frequency option: String) -> Desktop? {
            guard let shuffle = library.shuffle(id) else { return nil }
            return .shuffle(shuffle, interval: WallpaperShuffle.interval(ofSystemFrequency: stored.option(option, "picker")?["id"] as? String, for: id))
        }
        if stored.isShuffled {
            switch stored.provider {
            case "com.apple.wallpaper.choice.image": return shuffle(WallpaperShuffle.photos, frequency: "shuffleFrequency")
            case "com.apple.wallpaper.choice.color": return shuffle(WallpaperShuffle.colors, frequency: "shuffleFrequency")
            default: return nil
            }
        }
        switch (stored.provider, stored.configuration["type"] as? String) {
        case ("com.apple.wallpaper.choice.image", "imageFile"):
            return stored.url.flatMap { isShownAsRead($0) ? .file($0) : nil }
        case ("com.apple.wallpaper.choice.image", "systemDesktopPicture"):
            return item(pictureID, appearance: nil)
        case ("com.apple.wallpaper.choice.image", "userAddedPhotoShuffle"):
            return shuffle(WallpaperShuffle.photos, frequency: "shuffleFrequency")
        case ("com.apple.wallpaper.choice.dynamic", _):
            // macOS's older dynamic wallpapers have a style instead, whose Dynamic changes through the
            // day, from the Light picture to the Dark one
            return item(pictureID, appearance: stored.option("style", "picker")?["id"] as? String)
        case ("com.apple.wallpaper.choice.sonoma", _):
            return item("picture:Sonoma", appearance: appearance)
        case ("com.apple.NeptuneOneExtension", _):
            return item("picture:Tahoe", appearance: appearance)
        case ("com.apple.wallpaper.choice.sequoia", _):
            return drawn(.sequoia, appearance: appearance)
        case ("com.apple.wallpaper.choice.macintosh", _):
            // Its appearance has an option of its own
            return drawn(.macintosh, appearance: stored.option("appearanceMode", "picker")?["id"] as? String)
        case ("default", _):
            // macOS's default wallpaper, an aerial (Golden Gate Sunset) with a still of it in its default file
            return .file(defaultWallpaper)
        case ("com.apple.wallpaper.choice.aerials", _):
            // An aerial's ID, or for macOS's own, with one for each appearance, its subcategory's. A
            // shuffle has its category's, or "shuffle-all-aerials", which isn't any aerial's.
            let id = stored.configuration["assetID"] as? String
            if let aerial = id.flatMap(library.item(ofAerial:)) {
                return item(aerial.id, appearance: appearance)
            }
            return id.flatMap { shuffle($0 == "shuffle-all-aerials" ? WallpaperShuffle.aerials : "shuffle:\($0)", frequency: "aerialShuffleFrequency") }
        case ("com.apple.wallpaper.choice.color", "shuffle"):
            return shuffle(WallpaperShuffle.colors, frequency: "shuffleFrequency")
        case ("com.apple.wallpaper.choice.color", let type):
            let isGradient = stored.option("shouldGenerateGradient", "toggle")?["isOn"] as? Bool == true
            let color: CGColor?
            if type == "systemColor", let name = (stored.configuration["systemColor"] as? [String: Any])?.keys.first,
               let swatch = library.color(named: name) {
                // As itself, unless it's shown as a gradient
                guard isGradient else { return item(swatch.id, appearance: nil) }
                guard case .color(let file) = swatch.light else { return nil }
                color = Self.color(ofSwatch: file)
            } else if type == "customColor" {
                color = (stored.option("customColor", "color")?["color"] as? [String: Any]).flatMap(Self.color)
            } else {
                color = nil
            }
            return color.map { isGradient ? .gradient($0, isCustom: type == "customColor") : .color($0) }
        default:
            return nil
        }
    }

    /// The file with macOS's default wallpaper's picture, as `desktopImageURL(for:)` names it
    private static let defaultWallpaper = URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic")

    /// A colour as the wallpaper service keeps it: its components, and its colour space, by name, or for
    /// Display P3, which the Colours panel gives, by the number 7 (the desktop shows those components
    /// unchanged on a Display P3 screen)
    private static func color(_ stored: [String: Any]) -> CGColor? {
        guard let components = stored["components"] as? [Double], components.count == 4,
              let data = stored["colorSpace"] as? Data,
              let space = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let name = space as? String ?? (space as? Int == 7 ? CGColorSpace.displayP3 as String : nil),
              let colorSpace = CGColorSpace(name: name as CFString) else { return nil }
        return CGColor(colorSpace: colorSpace, components: components.map { CGFloat($0) })
    }

    /// The file with the picture `desktop` shows in an appearance, fetched into `folder` when it isn't
    /// one already, whether it's that file's picture for Dark, for one with a picture for each, and how
    /// it's placed on the display, for a picture file macOS places (`placedPicture`). Nil for a shuffle,
    /// which hasn't one picture, and for a wallpaper macOS draws, which is drawn for each display
    /// (`drawing(of:shows:)`).
    private func picture(_ desktop: Desktop, shows isDark: Bool, in folder: URL, screenSize: CGSize) async throws -> (file: URL, isDark: Bool, placement: Placement?)? {
        switch desktop {
        case .file(let file, let placement):
            return (file, isDark, placement)
        case .item(let item, let lightShowsDark, let darkShowsDark):
            let showsDark = isDark ? darkShowsDark : lightShowsDark
            return (try await file(for: showsDark ? item.dark : item.light, in: folder, screenSize: screenSize, inDarkAppearance: isDark), showsDark, nil)
        case .color(let color):
            // Named apart from a colour chosen for the other appearance, which is fetched into the same folder
            return (try Self.colorPicture(color, size: screenSize, named: "Desktop Colour", into: folder), isDark, nil)
        case .gradient, .drawn, .shuffle:
            return nil
        }
    }

    /// How the picture a wallpaper macOS draws itself shows in an appearance is drawn here, for a display
    /// of a size, in pixels, into a folder, as macOS draws it on each display: a colour's gradient, or
    /// Macintosh or Sequoia as macOS draws it, or where it can't be, System Settings' thumbnail of it,
    /// stretched to fill the screen. Nil for any other wallpaper.
    private static func drawing(of desktop: Desktop, shows isDark: Bool) -> ((_ size: CGSize, _ folder: URL) throws -> (file: URL, isDark: Bool))? {
        switch desktop {
        case .gradient(let color, _):
            return { size, folder in (try gradientPicture(color, size: size, into: folder), isDark) }
        case .drawn(let drawn, let lightShowsDark, let darkShowsDark, let colors):
            return { size, folder in (try drawnPicture(drawn, showsDark: isDark ? darkShowsDark : lightShowsDark, inDarkAppearance: isDark, colors: colors, size: size, into: folder), isDark) }
        case .file, .item, .color, .shuffle:
            return nil
        }
    }

    /// The colours of the gradient macOS shows a colour wallpaper as with Gradient on, from the bottom to
    /// the top, as System Settings' colours extension makes them: the colour in sRGB, and another from its
    /// components, which are a fifth further from its luma (Rec. 709's), then taken towards white by an
    /// amount that depends on that luma, or for a light colour, towards black, which is then at the bottom
    private static func gradientColors(of color: CGColor) -> [CGColor]? {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let base = color.converted(to: sRGB, intent: .defaultIntent, options: nil),
              let components = base.components, components.count >= 3 else { return nil }
        let luma = 0.2126 * components[0] + 0.7152 * components[1] + 0.0722 * components[2]
        let amount: CGFloat = luma <= 0.25 ? 0.2 : luma <= 0.5 ? 0.25 : luma <= 0.75 ? 0.3 : -0.1
        let shifted = components.prefix(3).map { component in
            let saturated = component - (luma - component) * 0.2
            return saturated + amount * (amount < 0 ? saturated : 1 - saturated)
        }
        // In generic RGB (`CGColorCreateGenericRGB`), as the extension makes it, though its components are sRGB's
        let other = CGColor(red: shifted[0], green: shifted[1], blue: shifted[2], alpha: base.alpha)
        return amount < 0 ? [other, base] : [base, other]
    }

    /// A colour's gradient (`gradientColors(of:)`) as a picture of `size`, in pixels
    private static func gradientImage(_ color: CGColor, size: CGSize) -> CGImage? {
        guard let colors = gradientColors(of: color),
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: nil),
              let context = CGContext(data: nil, width: max(Int(size.width), 1), height: max(Int(size.height), 1), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        // From the bottom, where a context starts
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: context.height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        return context.makeImage()
    }

    /// A colour's gradient as a picture the size of the screen
    private static func gradientPicture(_ color: CGColor, size: CGSize, named name: String = "Desktop", into folder: URL) throws -> URL {
        let file = folder.appendingPathComponent("\(name) Gradient.tiff")
        guard let picture = gradientImage(color, size: size) else { throw CocoaError(.fileWriteUnknown) }
        try writeLossless(picture, to: file)
        return file
    }

    /// Whether macOS shows a picture file as `thumbnails(of:)` reads it: its only picture in Light and in
    /// Dark, or one for each, said as Safelight says it, which macOS changes between with the appearance.
    /// Apple's own files with one for each it shows otherwise: Sonoma's, as a picture file, stays on its
    /// Light picture, and a dynamic wallpaper's follow settings its file doesn't have.
    private static func isShownAsRead(_ file: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return false }
        guard CGImageSourceGetCount(source) > 1 else { return true }
        guard !file.standardizedFileURL.path.hasPrefix("/System/"),
              let metadata = CGImageSourceCopyMetadataAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil) else { return false }
        return CGImageMetadataCopyTagWithPath(metadata, nil, appearanceMetadataPath) != nil
            && dynamicMetadataPaths.allSatisfy { CGImageMetadataCopyTagWithPath(metadata, nil, $0) == nil }
    }

    /// Takes away the wallpapers made before `wallpaper`, now it's on every desktop instead, or with
    /// `keepingThoseShown`, those no display or Space has any more, as with Show on all Spaces off, the
    /// others may still have one. Their choices go with them.
    private func removeWallpapers(except wallpaper: URL, keepingThoseShown: Bool = false) {
        guard let folder, let made = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        var kept: Set<String> = [Self.wallpaperFolder(of: wallpaper).lastPathComponent]
        if keepingThoseShown {
            // When it can't be told which are, none is taken away. Those just put on another display may
            // not be in the wallpaper service's store yet.
            guard let shown = Self.filesShown() else { return }
            let onDisplays = NSScreen.screens.compactMap(NSWorkspace.shared.desktopImageURL(for:)) + justPut.values.map(\.wallpaper)
            kept.formUnion((shown + onDisplays).filter(isMadeHere).map { Self.wallpaperFolder(of: $0).lastPathComponent })
        }
        for old in made where !kept.contains(old.lastPathComponent) {
            try? FileManager.default.removeItem(at: old)
        }
        choices = choices.filter { kept.contains($0.key) }
    }

    /// The picture files macOS's wallpaper service shows on any display or Space, nil when it can't be told
    private static func filesShown() -> [URL]? {
        guard let data = try? Data(contentsOf: store),
              let index = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        var files: [URL] = []
        func add(_ owner: Any?) {
            if let file = ((owner as? [String: Any])?["Desktop"] as? [String: Any]).flatMap(StoredDesktop.init)?.url {
                files.append(file)
            }
        }
        add(index["AllSpacesAndDisplays"])
        add(index["SystemDefault"])
        for display in (index["Displays"] as? [String: Any] ?? [:]).values {
            add(display)
        }
        for space in (index["Spaces"] as? [String: Any] ?? [:]).values {
            let space = space as? [String: Any]
            add(space?["Default"])
            for display in (space?["Displays"] as? [String: Any] ?? [:]).values {
                add(display)
            }
        }
        return files
    }

    /// Writes a picture drawn here, or placed from one that's lost nothing, for a wallpaper to be made
    /// with: uncompressed, so it's written and read again in a few milliseconds, where a PNG the size of
    /// a 5K display took a quarter of a second, and with nothing lost, so the wallpaper keeps it without
    /// loss (`hasLostNothing`)
    private static func writeLossless(_ picture: CGImage, to file: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.tiff.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, picture, [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 1]] as CFDictionary) // none
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Whether a file's picture has lost nothing yet: a PNG, or an uncompressed TIFF, as the pictures
    /// drawn here are written (`writeLossless`). One placed from a picture that had is LZW-compressed.
    private static func hasLostNothing(_ source: CGImageSource) -> Bool {
        switch CGImageSourceGetType(source) as String? {
        case UTType.png.identifier?:
            return true
        case UTType.tiff.identifier?:
            let properties = CGImageSourceCopyPropertiesAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil) as? [CFString: Any]
            return (properties?[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFCompression] as? Int == 1
        default:
            return false
        }
    }

    /// Writes a wallpaper with `light`'s picture for Light and `dark`'s for Dark, or when that's the same
    /// picture, a plain one of it. Each is a file's picture for Light or for Dark, for a file with one for
    /// each, or its only one.
    private static func makeWallpaper(at wallpaper: URL, light: (file: URL, isDark: Bool), dark: (file: URL, isDark: Bool)) -> Bool {
        guard let lightSource = CGImageSourceCreateWithURL(light.file as CFURL, nil),
              let darkSource = light.file == dark.file ? lightSource : CGImageSourceCreateWithURL(dark.file as CFURL, nil) else { return false }
        let lightIndex = index(in: lightSource, isDark: light.isDark)
        let darkIndex = index(in: darkSource, isDark: dark.isDark)
        let isOnePicture = lightSource === darkSource && lightIndex == darkIndex
        guard let lightPicture = picture(in: lightSource, at: lightIndex),
              let darkPicture = isOnePicture ? lightPicture : picture(in: darkSource, at: darkIndex),
              (try? FileManager.default.createDirectory(at: wallpaper.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil,
              let destination = CGImageDestinationCreateWithURL(wallpaper as CFURL, UTType.heic.identifier as CFString, isOnePicture ? 1 : 2, nil)
        else { return false }

        // About the size of macOS's own wallpapers for their pictures' size. A picture that's lost nothing
        // yet, as one drawn here is, loses nothing: lossy, Sequoia's gradients and Macintosh's blocks
        // came out several levels off. Nor does one kept from a wallpaper made before, as the other
        // appearance's is: made again lossy, a picture that had lost nothing lost as much as it would
        // the first time (a fitted grid's lines, up to 189 levels), though again and again no more.
        let made = wallpaperFolder(of: wallpaper).deletingLastPathComponent()
        func options(_ source: CGImageSource, _ file: URL) -> CFDictionary {
            let isKept = wallpaperFolder(of: file).deletingLastPathComponent().standardizedFileURL == made.standardizedFileURL
            return [kCGImageDestinationLossyCompressionQuality: isKept || hasLostNothing(source) ? 1 : 0.95] as CFDictionary
        }
        if isOnePicture {
            CGImageDestinationAddImage(destination, lightPicture, options(lightSource, light.file))
        } else {
            let metadata = CGImageMetadataCreateMutable()
            let indexes = ["l": 0, "d": 1]
            guard CGImageMetadataRegisterNamespaceForPrefix(metadata, metadataNamespace, metadataPrefix, nil),
                  let plist = try? PropertyListSerialization.data(fromPropertyList: indexes, format: .binary, options: 0),
                  CGImageMetadataSetValueWithPath(metadata, nil, appearanceMetadataPath, plist.base64EncodedString() as CFString)
            else { return false }
            CGImageDestinationAddImageAndMetadata(destination, lightPicture, metadata, options(lightSource, light.file))
            CGImageDestinationAddImage(destination, darkPicture, options(darkSource, dark.file))
        }
        return CGImageDestinationFinalize(destination)
    }

    /// The pictures in `wallpaper` for Light and for Dark, scaled down to a few hundred pixels, which is
    /// enough to fill a thumbnail at twice its size, even from a picture much wider than the screen
    /// Placed otherwise than filling the display, each is drawn the shape of a display of `screenSize`,
    /// in pixels, placed on it as macOS places it (`placed(_:size:placement:screenSize:)`).
    private static func thumbnails(of wallpaper: URL, placement: Placement = Placement(), screenSize: CGSize = .zero) -> Thumbnails? {
        guard let source = CGImageSourceCreateWithURL(wallpaper as CFURL, nil),
              let light = thumbnail(in: source, isDark: false, placement: placement, screenSize: screenSize),
              let dark = thumbnail(in: source, isDark: true, placement: placement, screenSize: screenSize) else { return nil }
        return Thumbnails(light: .picture(light), dark: .picture(dark))
    }

    /// `source`'s picture for Light or for Dark, as `thumbnails(of:placement:screenSize:)` draws it
    private static func thumbnail(in source: CGImageSource, isDark: Bool, placement: Placement, screenSize: CGSize) -> CGImage? {
        let index = index(in: source, isDark: isDark)
        guard let picture = picture(in: source, at: index, maxPixelSize: 400) else { return nil }
        guard placement.kind != .fill, screenSize.width > 0, screenSize.height > 0 else { return picture }
        let canvas = CGSize(width: 400, height: max((400 * screenSize.height / screenSize.width).rounded(), 1))
        return placed(picture, size: pixelSize(in: source, at: index), placement: placement, screenSize: screenSize, canvas: canvas)
    }

    /// One of a file's pictures as macOS places it on a display of `screenSize`, in pixels, as
    /// `placement` says, on a picture of the display's shape that a wallpaper with it then fills.
    /// Fitted or stretched, that's at the picture's own size, only as much larger as the display's shape
    /// needs, so macOS scales it to the display as it scales a picture it places itself, with its own
    /// filter, though never larger than the display. In the middle, it's the display's size. It's
    /// written into `folder`, named after `name`, without loss until the wallpaper is made, or the
    /// picture as it is when it fills the display
    private static func placedPicture(_ picture: (file: URL, isDark: Bool), placement: Placement?, screenSize: CGSize, named name: String, into folder: URL) throws -> (file: URL, isDark: Bool) {
        guard let placement, placement.kind != .fill else { return picture }
        guard let source = CGImageSourceCreateWithURL(picture.file as CFURL, nil) else { throw CocoaError(.fileReadCorruptFile) }
        let index = index(in: source, isDark: picture.isDark)
        let size = pixelSize(in: source, at: index)
        guard let image = Self.picture(in: source, at: index),
              let placed = placed(image, size: size, placement: placement, screenSize: screenSize, canvas: canvas(for: size, placement: placement, screenSize: screenSize))
        else { throw CocoaError(.fileReadCorruptFile) }
        // One that's lost nothing as one (which the wallpaper keeps without loss), others with nothing
        // more lost
        let file = folder.appendingPathComponent("\(name) Placed").appendingPathExtension("tiff")
        if hasLostNothing(source) {
            try writeLossless(placed, to: file)
            return (file, false)
        }
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.tiff.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, placed, [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]] as CFDictionary) // LZW
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return (file, false)
    }

    /// The size, in pixels, of the picture `placedPicture` draws a picture of `size`, in pixels, on for a
    /// display of `screenSize`: the display's shape at the picture's own size, while that's no larger
    /// than the display, or else the display's size. A picture larger than the display is scaled down
    /// here, as macOS scaling down a wallpaper that fills the display came out further from its own Fit
    /// to Screen: on a 1920 by 1080 display, 72% of pixels within 2 levels of it, against 78% this way.
    private static func canvas(for size: CGSize, placement: Placement, screenSize: CGSize) -> CGSize {
        var canvas = screenSize
        if placement.kind != .center, size.width > 0, size.height > 0, screenSize.height > 0 {
            let aspect = screenSize.width / screenSize.height
            let own = CGSize(width: max(size.width, (size.height * aspect).rounded()), height: max(size.height, (size.width / aspect).rounded()))
            if own.width <= screenSize.width {
                // As much each side, so a fitted picture is on whole pixels
                canvas = CGSize(width: own.width + (own.width - size.width).truncatingRemainder(dividingBy: 2),
                                height: own.height + (own.height - size.height).truncatingRemainder(dividingBy: 2))
            }
        }
        return canvas
    }

    /// One of a file's pictures as the wallpaper for a display of a size has it: as it is, the same for
    /// every display, or placed on the display as macOS places it (`placedPicture`), when it's placed
    /// otherwise than filling it, the same for each display it's drawn on the same size of picture for
    private struct DisplayPicture: Equatable {
        let file: URL
        let isDark: Bool
        /// How it's placed, on a display of what size, in pixels, and the size of the picture it's drawn
        /// on then, which is all that tells it from one placed for another display
        let placing: (placement: Placement, screenSize: CGSize, canvas: CGSize)?

        init(_ picture: (file: URL, isDark: Bool), placement: Placement? = nil, screenSize: CGSize = .zero) {
            (file, isDark) = picture
            placing = placement.flatMap { placement in
                guard placement.kind != .fill else { return nil }
                // One that can't be read can't be placed for any display
                let size = CGImageSourceCreateWithURL(picture.file as CFURL, nil).map { pixelSize(in: $0, at: index(in: $0, isDark: picture.isDark)) } ?? .zero
                return (placement, screenSize, canvas(for: size, placement: placement, screenSize: screenSize))
            }
        }

        static func == (a: DisplayPicture, b: DisplayPicture) -> Bool {
            a.file == b.file && a.isDark == b.isDark && a.placing?.placement == b.placing?.placement && a.placing?.canvas == b.placing?.canvas
        }

        /// The file with it as the wallpaper has it: placed, written into `folder`, named after `name`,
        /// or the file it's in
        func picture(named name: String, into folder: URL) throws -> (file: URL, isDark: Bool) {
            guard let placing else { return (file, isDark) }
            return try placedPicture((file, isDark), placement: placing.placement, screenSize: placing.screenSize, named: name, into: folder)
        }
    }

    /// The size, in pixels, of one of a file's pictures, nil when it can't be read
    private static func pixelSize(of picture: (file: URL, isDark: Bool)) -> CGSize? {
        CGImageSourceCreateWithURL(picture.file as CFURL, nil).map { pixelSize(in: $0, at: index(in: $0, isDark: picture.isDark)) }
    }

    /// The size of one of `source`'s pictures the right way up, in pixels
    private static func pixelSize(in source: CGImageSource, at index: Int) -> CGSize {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? CGFloat ?? 0, height = properties?[kCGImagePropertyPixelHeight] as? CGFloat ?? 0
        // Turned a quarter, by the orientations that turn it
        return (5...8).contains(properties?[kCGImagePropertyOrientation] as? Int ?? 1) ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// A picture whose own size is `size`, in pixels, as macOS places it on a display of `screenSize`,
    /// in pixels, drawn on a `canvas` of the display's shape: all of it on the display, stretched to its
    /// shape, or in the middle a pixel to each of the display's pixels, whatever its resolution, with the
    /// fill colour around it (or as it fills the display, which macOS does with a wallpaper itself)
    private static func placed(_ picture: CGImage, size: CGSize, placement: Placement, screenSize: CGSize, canvas: CGSize) -> CGImage? {
        let width = Int(canvas.width), height = Int(canvas.height)
        guard width > 0, height > 0, screenSize.width > 0, screenSize.height > 0, size.width > 0, size.height > 0 else { return nil }
        // In the picture's colours, or sRGB's where a context can't have them
        let context = [picture.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }, CGColorSpace(name: CGColorSpace.sRGB)].lazy.compactMap { $0 }.compactMap {
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: $0, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        }.first
        guard let context else { return nil }
        let display = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(placement.color ?? .black)
        context.fill(display)
        let scale: CGFloat = switch placement.kind {
        case .fill: max(display.width / size.width, display.height / size.height)
        case .fit: min(display.width / size.width, display.height / size.height)
        case .stretch, .center: display.width / screenSize.width
        }
        var frame = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
        if placement.kind == .stretch {
            frame = display
        }
        frame.origin = CGPoint(x: ((display.width - frame.width) / 2).rounded(.down), y: ((display.height - frame.height) / 2).rounded(.down))
        context.interpolationQuality = .high
        context.draw(picture, in: frame)
        return context.makeImage()
    }

    /// The colour around a picture that doesn't fill the display shown, until one is chosen
    var defaultFillColor: CGColor {
        Self.defaultFillColor(on: screen(for: place(for: nil)).flatMap(Self.uuid(of:)))
    }

    /// The colour around a picture that doesn't fill a display, by its UUID, until one is chosen: the one
    /// System Settings has for it, which it keeps from one choice to the next, or else black
    private static func defaultFillColor(on display: String?) -> CGColor {
        let desktops = storedDesktops(on: display)
        let last = desktops.max { ($0["LastSet"] as? Date ?? .distantPast) < ($1["LastSet"] as? Date ?? .distantPast) }
        return (last.flatMap(StoredDesktop.init)?.option("color", "color")?["color"] as? [String: Any]).flatMap { color($0) } ?? .black
    }

    /// The pictures the desktop shows in Light and in Dark, scaled down as `thumbnails(of:)` scales them.
    /// A wallpaper of System Settings' shows its thumbnails, which are the ones the Wallpaper window
    /// shows, a shuffle its thumbnail, a colour is just the colour, or its gradient, and Macintosh is
    /// drawn the shape of a display of `screenSize`, as is a picture placed otherwise than filling it.
    private static func thumbnails(of desktop: Desktop, screenSize: CGSize) -> Thumbnails? {
        func both(_ thumbnail: CGImage?) -> Thumbnails? {
            thumbnail.map { Thumbnails(light: .picture($0), dark: .picture($0)) }
        }
        switch desktop {
        case .file(let wallpaper, let placement):
            return thumbnails(of: wallpaper, placement: placement, screenSize: screenSize)
        case .item(let item, let lightShowsDark, let darkShowsDark):
            func thumbnail(showsDark: Bool) -> CGImage? {
                guard let file = showsDark ? item.darkThumbnail : item.lightThumbnail,
                      let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
                return picture(in: source, at: index(in: source, isDark: showsDark), maxPixelSize: 400)
            }
            guard let light = thumbnail(showsDark: lightShowsDark), let dark = thumbnail(showsDark: darkShowsDark) else { return nil }
            return Thumbnails(light: .picture(light), dark: .picture(dark))
        case .color(let color):
            guard let colorSpace = color.colorSpace.flatMap({ $0.model == .rgb ? $0 : nil }) ?? CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            return both(context.makeImage())
        case .gradient(let color, _):
            // The shape of a screen, so filling a thumbnail shows all of it
            return both(gradientImage(color, size: CGSize(width: 160, height: 100)))
        case .shuffle(let shuffle, _):
            return Thumbnails(light: .shuffle(shuffle.thumbnails), dark: .shuffle(shuffle.thumbnails))
        case .drawn(let drawn, let lightShowsDark, let darkShowsDark, let colors):
            // As it's drawn here, the shape of the screen, at about a thumbnail's size
            let size = CGSize(width: 400, height: (400 * screenSize.height / max(screenSize.width, 1)).rounded())
            func look(showsDark: Bool, isDark: Bool) -> CGImage? {
                drawnImage(drawn, showsDark: showsDark, inDarkAppearance: isDark, colors: colors, size: size) ?? thumbnail(of: drawn, isDark: showsDark)
            }
            guard let light = look(showsDark: lightShowsDark, isDark: false), let dark = look(showsDark: darkShowsDark, isDark: true) else { return nil }
            return Thumbnails(light: .picture(light), dark: .picture(dark))
        }
    }

    /// System Settings' thumbnail of a wallpaper macOS draws, as it looks in an appearance: Sequoia's
    /// has one for each, and Macintosh's one of both, Light on its left half and Dark on its right
    private static func thumbnail(of drawn: DrawnWallpaper, isDark: Bool) -> CGImage? {
        switch drawn {
        case .sequoia:
            let file = URL(fileURLWithPath: WallpaperLibrary.sequoiaExtension).appendingPathComponent("Contents/Resources/thumbnail \(isDark ? "dark" : "light").heic")
            return CGImageSourceCreateWithURL(file as CFURL, nil).flatMap { picture(in: $0, at: 0) }
        case .macintosh:
            guard let source = CGImageSourceCreateWithURL(WallpaperLibrary.macintoshThumbnail as CFURL, nil),
                  let both = picture(in: source, at: 0) else { return nil }
            let half = both.width / 2
            return both.cropping(to: CGRect(x: isDark ? both.width - half : 0, y: 0, width: half, height: both.height))
        }
    }

    /// A wallpaper macOS draws as it's drawn here, in its Dark look or its Light one, the size of a picture
    /// of `size`, in pixels: Macintosh in an appearance's colours of `colors`, and Sequoia. Nil on a macOS
    /// whose wallpaper isn't drawn as worked out here.
    private static func drawnImage(_ drawn: DrawnWallpaper, showsDark: Bool, inDarkAppearance isDark: Bool, colors: String?, size: CGSize) -> CGImage? {
        switch drawn {
        case .macintosh: MacintoshWallpaper.picture(showsDark: showsDark, inDarkAppearance: isDark, scheme: colors, size: size)
        case .sequoia: SequoiaWallpaper.picture(showsDark: showsDark, size: size)
        }
    }

    /// A wallpaper macOS draws as a picture of `size`, in pixels, in its Dark look or its Light one: as
    /// it's drawn here, or where it can't be, System Settings' thumbnail of it in that look, stretched to
    /// fill the picture, which is all there is of it on the Mac to put in a wallpaper
    private static func drawnPicture(_ drawn: DrawnWallpaper, showsDark: Bool, inDarkAppearance isDark: Bool, colors: String?, size: CGSize, into folder: URL) throws -> URL {
        // Named for its appearance, apart from the other appearance's, which is drawn into the same folder
        // when both have it
        let file = folder.appendingPathComponent("\(drawn.name) in \(isDark ? "Dark" : "Light").tiff")
        if let picture = drawnImage(drawn, showsDark: showsDark, inDarkAppearance: isDark, colors: colors, size: size) {
            try writeLossless(picture, to: file)
            return file
        }
        guard let thumbnail = thumbnail(of: drawn, isDark: showsDark),
              let colorSpace = thumbnail.colorSpace.flatMap({ $0.model == .rgb ? $0 : nil }) ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: max(Int(size.width), 1), height: max(Int(size.height), 1), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CocoaError(.fileReadCorruptFile) }
        let scale = max(CGFloat(context.width) / CGFloat(thumbnail.width), CGFloat(context.height) / CGFloat(thumbnail.height))
        let filled = CGSize(width: CGFloat(thumbnail.width) * scale, height: CGFloat(thumbnail.height) * scale)
        context.interpolationQuality = .high
        context.draw(thumbnail, in: CGRect(x: (CGFloat(context.width) - filled.width) / 2, y: (CGFloat(context.height) - filled.height) / 2, width: filled.width, height: filled.height))
        guard let picture = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        try writeLossless(picture, to: file)
        return file
    }

    /// Which of `source`'s pictures is for an appearance: as its metadata says, or with none, its main one
    private static func index(in source: CGImageSource, isDark: Bool) -> Int {
        let main = CGImageSourceGetPrimaryImageIndex(source)
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, main, nil) else { return main }
        for path in [appearanceMetadataPath] + dynamicMetadataPaths {
            guard let value = CGImageMetadataCopyStringValueWithPath(metadata, nil, path) as String?,
                  let plist = Data(base64Encoded: value),
                  let dictionary = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any] else { continue }
            // A dynamic wallpaper's are under "ap", among the pictures it shows through the day
            let indexes = dictionary["ap"] as? [String: Int] ?? dictionary as? [String: Int]
            if let index = indexes?[isDark ? "d" : "l"], (0..<CGImageSourceGetCount(source)).contains(index) {
                return index
            }
        }
        return main
    }

    /// One of `source`'s pictures the right way up, at its full size unless it's to be scaled down. At
    /// its full size it's decoded as it is, as a thumbnail of a HEIC's picture is never larger than its
    /// main one, which in a wallpaper of two pictures may be the smaller. A picture that has to be turned
    /// the right way up, like a photo, is the only one in its file, so it's turned as a thumbnail.
    private static func picture(in source: CGImageSource, at index: Int, maxPixelSize: Int? = nil) -> CGImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        if maxPixelSize == nil, properties?[kCGImagePropertyOrientation] as? Int ?? 1 == 1 {
            return CGImageSourceCreateImageAtIndex(source, index, nil)
        }
        var options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true]
        options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize ?? [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight].compactMap { properties?[$0] as? Int }.max()
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }
}

/// Shuffles the wallpaper's picture for Light, for Dark, or for each, as System Settings › Wallpaper's
/// shuffles do. macOS's own shuffles are run by its wallpaper service, which only Apple's apps may ask,
/// so Safelight makes a wallpaper with the next picture itself, every so often, at login or on waking,
/// while it's running and the wallpaper is still one it made. An appearance's shuffle runs while it's
/// that appearance's choice; choosing anything else for it stops it. With Show on all Spaces on, it
/// changes every display's wallpaper, and with it off, each display has shuffles of its own, as macOS's
/// wallpaper service keeps a desktop for each.
final class WallpaperShuffler: ObservableObject {
    static let shared = WallpaperShuffler()

    /// A shuffle for one appearance: how often it changes, and when it last did, to which picture
    struct Shuffle: Codable, Equatable {
        let id: WallpaperShuffle.ID
        var interval: WallpaperShuffle.Interval
        var lastChange: Date?
        var current: WallpaperItem.ID?
    }

    private struct Shuffles: Codable {
        var light: Shuffle?
        var dark: Shuffle?

        subscript(isDark: Bool) -> Shuffle? {
            get { isDark ? dark : light }
            set {
                if isDark {
                    dark = newValue
                } else {
                    light = newValue
                }
            }
        }
    }

    /// Where a shuffle changes the wallpaper, as `WallpaperManager.place(for:)` gives it: on every display
    /// (nil), or on one, by its UUID, and for which appearance
    private struct Slot: Hashable {
        let display: String?
        let isDark: Bool
    }

    /// Every display's (`allDisplays`), for while Show on all Spaces is on, and each display's, by its
    /// UUID, for while it's off. Kept between launches, and after another choice, so a shuffle chosen
    /// again changes as often as before.
    @Published private var shuffles: [String: Shuffles] {
        didSet { UserDefaults.standard.set(try? PropertyListEncoder().encode(shuffles), forKey: Self.shufflesKey) }
    }

    private static let shufflesKey = "WallpaperShufflesByDisplay"
    /// Where they were kept while there were only every display's
    private static let earlierShufflesKey = "WallpaperShuffles"
    private static let allDisplays = "AllDisplays"
    private var timer: Timer?
    /// The shuffles that are to change, one after the other, as one wallpaper is made at a time
    private var queue: [Slot] = []
    /// When a shuffle whose picture couldn't be made tries again, with another: a minute later, as when
    /// the Mac has just woken and isn't online yet, then twice as long each time it fails, up to an hour
    private var retries: [Slot: (date: Date, delay: TimeInterval)] = [:]

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.shufflesKey) {
            shuffles = (try? PropertyListDecoder().decode([String: Shuffles].self, from: data)) ?? [:]
        } else {
            shuffles = defaults.data(forKey: Self.earlierShufflesKey).flatMap { try? PropertyListDecoder().decode(Shuffles.self, from: $0) }
                .map { [Self.allDisplays: $0] } ?? [:]
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.change(at: .wake)
        }
    }

    private subscript(slot: Slot) -> Shuffle? {
        get { shuffles[slot.display ?? Self.allDisplays]?[slot.isDark] }
        set { shuffles[slot.display ?? Self.allDisplays, default: Shuffles()][slot.isDark] = newValue }
    }

    /// Where an appearance's shuffle changes the wallpaper shown (`WallpaperManager.place(for:)`)
    private func shownSlot(isDark: Bool) -> Slot {
        Slot(display: WallpaperManager.shared.place(for: nil), isDark: isDark)
    }

    /// Where shuffles change the wallpaper now: every display, or each display
    private var slots: [Slot] {
        let displays: [String?] = WallpaperManager.shared.showsOnAllSpaces ? [nil] : NSScreen.screens.compactMap(WallpaperManager.uuid(of:))
        return displays.flatMap { display in [false, true].map { Slot(display: display, isDark: $0) } }
    }

    /// The shuffle an appearance has on the display shown, or every display, while it's the appearance's
    /// choice in a wallpaper Safelight made. System Settings' own shuffles are run by macOS.
    func shuffle(isDark: Bool) -> Shuffle? {
        shuffle(at: shownSlot(isDark: isDark))
    }

    /// The shuffle a slot has, while it's where changes go now and the appearance's choice there
    private func shuffle(at slot: Slot) -> Shuffle? {
        let wallpaper = WallpaperManager.shared
        guard wallpaper.place(for: slot.display) == slot.display, let shuffle = self[slot],
              wallpaper.ownChoice(isDark: slot.isDark, on: slot.display) == shuffle.id else { return nil }
        return shuffle
    }

    /// The picture an appearance's shuffle has on the desktop shown now
    func current(isDark: Bool) -> WallpaperItem.ID? {
        shuffle(isDark: isDark)?.current
    }

    /// Makes a shuffle the appearance's choice on the display shown, or every display, with a picture
    /// from it now
    func start(_ shuffle: WallpaperShuffle, isDark: Bool) {
        let slot = shownSlot(isDark: isDark)
        let interval = self[slot].flatMap { $0.id == shuffle.id ? $0.interval : nil } ?? WallpaperShuffle.defaultInterval(for: shuffle.id)
        retries[slot] = nil
        change(Shuffle(id: shuffle.id, interval: interval), at: slot, isQuiet: false)
    }

    /// Carries on one of System Settings' shuffles for an appearance, as often as it changed, from the
    /// picture of it the appearance has just been given, as a wallpaper of Safelight's took the
    /// shuffle's place, on a display, by its UUID, or on every display (nil). Its timer is set once the
    /// wallpaper is the desktop's.
    func carryOn(_ id: WallpaperShuffle.ID, interval: WallpaperShuffle.Interval, from current: WallpaperItem.ID?, isDark: Bool, on display: String?) {
        let slot = Slot(display: display, isDark: isDark)
        retries[slot] = nil
        self[slot] = Shuffle(id: id, interval: interval, lastChange: Date(), current: current)
    }

    func setInterval(_ interval: WallpaperShuffle.Interval, isDark: Bool) {
        let slot = shownSlot(isDark: isDark)
        guard shuffle(at: slot) != nil else { return }
        self[slot]?.interval = interval
        schedule()
    }

    /// Gives each display every display's shuffles that it shows, as Show on all Spaces is turned off,
    /// so each carries on by itself, as macOS's wallpaper service gives each display and Space the
    /// wallpaper it had for all of them. A display keeps a shuffle of its own of the same that has
    /// changed since.
    func split() {
        guard let all = shuffles[Self.allDisplays] else { return }
        for display in NSScreen.screens.compactMap(WallpaperManager.uuid(of:)) {
            for isDark in [false, true] {
                let slot = Slot(display: display, isDark: isDark)
                guard let shuffle = all[isDark], WallpaperManager.shared.ownChoice(isDark: isDark, on: display) == shuffle.id else { continue }
                if let own = self[slot], own.id == shuffle.id, (own.lastChange ?? .distantPast) > (shuffle.lastChange ?? .distantPast) {
                    continue
                }
                self[slot] = shuffle
            }
        }
    }

    /// Gives every display the shuffles of the display, by its UUID, whose wallpaper they've all just been
    /// given, as Show on all Spaces is turned on
    func join(from display: String) {
        for isDark in [false, true] {
            if let shuffle = self[Slot(display: display, isDark: isDark)] {
                self[Slot(display: nil, isDark: isDark)] = shuffle
            }
        }
    }

    /// At launch: the shuffles that change at login do, and the others carry on where they were, or
    /// change now if they were due while Safelight wasn't running. Those kept for every display carry on
    /// on each, with Show on all Spaces off, as they did before each display had its own.
    func resume() {
        if !WallpaperManager.shared.showsOnAllSpaces {
            split()
        }
        change(at: .login)
    }

    /// Changes the shuffles that change at login or on waking, and sets the timer for the others again,
    /// as it doesn't run while the Mac sleeps
    private func change(at interval: WallpaperShuffle.Interval) {
        // The wallpaper may have been changed in System Settings since
        WallpaperManager.shared.refresh()
        for slot in slots where shuffle(at: slot)?.interval == interval {
            enqueue(slot)
        }
        schedule()
    }

    /// Sets the timer for the shuffle to change next, in place of the one before
    func schedule() {
        timer?.invalidate()
        timer = nil
        let next = slots.compactMap { slot -> (slot: Slot, date: Date)? in
            guard let shuffle = shuffle(at: slot) else { return nil }
            // Once it's due, or when it tries again after failing, even one that changes at login or on waking
            let due = shuffle.interval.next(after: shuffle.lastChange ?? .distantPast)
            guard let date = [due, retries[slot]?.date].compactMap({ $0 }).max() else { return nil }
            return (slot, date)
        }.min { $0.date < $1.date }
        guard let next else { return }
        let timer = Timer(fire: max(next.date, Date()), interval: 0, repeats: false) { [weak self] _ in
            WallpaperManager.shared.refresh()
            self?.enqueue(next.slot)
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func enqueue(_ slot: Slot) {
        guard !queue.contains(slot) else { return }
        queue.append(slot)
        if queue.count == 1 {
            changeNext()
        }
    }

    private func changeNext() {
        guard let slot = queue.first else { return }
        guard let shuffle = shuffle(at: slot) else {
            queue.removeFirst()
            changeNext()
            return
        }
        change(shuffle, at: slot, isQuiet: true) { [weak self] in
            self?.queue.removeFirst()
            self?.changeNext()
        }
    }

    /// Makes a wallpaper with another of the shuffle's pictures for the appearance, where the slot says.
    /// `isQuiet` when it's on time, not chosen just now, so it doesn't beep when the picture can't be made.
    private func change(_ shuffle: Shuffle, at slot: Slot, isQuiet: Bool, then completion: (() -> Void)? = nil) {
        // While a picture chosen in the Wallpaper window is being made, or another display's, a little
        // later, as it is then, unless another choice has stopped it meanwhile. One chosen just now is
        // made as soon as that one's on the desktop, as any choice is (`WallpaperManager.choose`).
        guard !isQuiet || !WallpaperManager.shared.isChanging else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { return }
                guard let latest = self.shuffle(at: slot) else {
                    completion?()
                    return
                }
                self.change(latest, at: slot, isQuiet: isQuiet, then: completion)
            }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            // Any picture but the one it has now
            let pictures = WallpaperLibrary.shared.pictures(of: shuffle.id)
            let next = pictures.filter { $0.id != shuffle.current }.randomElement() ?? pictures.randomElement()
            DispatchQueue.main.async {
                // As for a folder with no pictures in it
                guard let next else {
                    if !isQuiet {
                        NSSound.beep()
                    }
                    completion?()
                    return
                }
                // Before it's made, as making it sets the timer again
                var changed = shuffle
                changed.current = next.id
                changed.lastChange = Date()
                self[slot] = changed
                WallpaperManager.shared.choose(next, isDark: slot.isDark, from: shuffle.id, isQuiet: isQuiet, on: slot.display) { [weak self] isMade in
                    guard let self else { return }
                    if isMade {
                        self.retries[slot] = nil
                    } else if self[slot] == changed {
                        // As it was, with the picture still on the desktop, until it tries again
                        self[slot] = shuffle
                        let delay = min(2 * (self.retries[slot]?.delay ?? 30), 60 * 60)
                        self.retries[slot] = (Date().addingTimeInterval(delay), delay)
                    }
                    self.schedule()
                    completion?()
                }
            }
        }
    }
}

// MARK: - Macintosh (As macOS Draws It)
/// System Settings' Macintosh wallpaper as a still picture, drawn as its extension draws it when it shows
/// its still scene, Icon Garden: an emulated Mac screen of 512 by 342 pixels, each black pixel a block
/// standing up from a background of two colours, with a soft shadow under it, seen from an angle. It's
/// drawn with the extension's own shaders from the extension's own files, with what the extension gives
/// the shaders worked out from its code. Drawn so, it's within a level of each colour of what the
/// extension draws on a 5K and a 1080p display.
enum MacintoshWallpaper {
    private static let resources = URL(fileURLWithPath: WallpaperLibrary.macintoshExtension).appendingPathComponent("Contents/Resources", isDirectory: true)

    /// What the extension gives its shaders for a frame, laid out as they take it
    private struct Uniforms {
        var viewProjectionMatrix: float4x4
        /// The emulated screen's size, and half of it
        var bitmapSize: SIMD4<Float>
        var bitmapSizeInt: SIMD4<Int32>
        /// The screen's pixels it draws: from where, and how many a row
        var pixelsRectInt: SIMD4<Int32>
        var translate: SIMD4<Float>
        var rampDirection: SIMD4<Float>
        /// How far the blocks stand up, and over what the ramp raises them
        var animation: SIMD4<Float>
        var backgroundColorTop: SIMD4<Float>
        var backgroundColorBottom: SIMD4<Float>
        var color: SIMD4<Float>
    }

    /// The shaders' uniforms by name and where each is, which is checked before drawing, so a macOS whose
    /// shaders take something else gets no picture from here rather than a wrong one
    private static let uniformsLayout = [("viewProjectionMatrix", 0), ("bitmapSize", 64), ("bitmapSizeInt", 80), ("pixelsRectInt", 96), ("translate", 112),
                                         ("rampDirection", 128), ("animation", 144), ("backgroundColorTop", 160), ("backgroundColorBottom", 176), ("color", 192)]

    /// The still scene, from the extension's program for it, in the extension's own little language
    private struct Scene {
        var image = ""
        var camera = SIMD2<Float>(0, 0)
        var scroll = SIMD2<Float>(0, 0)
        var icons: [(x: Int, y: Int, name: String)] = []
        var cursors: [(x: Int, y: Int, name: String)] = []
        var carets: [(x: Int, y: Int, width: Int, height: Int)] = []

        init?() {
            guard let program = try? String(contentsOf: resources.appendingPathComponent("IconGardenWallpaper.program"), encoding: .utf8) else { return nil }
            for line in program.components(separatedBy: .newlines) {
                let words = line.trimmingCharacters(in: .whitespaces)
                let quoted = words.components(separatedBy: "\"")
                let name = quoted.count > 2 ? quoted[1] : ""
                let numbers = quoted[0].split { !"-0123456789.".contains($0) }.compactMap { Float($0) }
                if words.hasPrefix("let image =") {
                    image = name
                } else if words.hasPrefix("camera to"), numbers.count >= 2 {
                    camera = SIMD2(numbers[0], numbers[1])
                } else if words.hasPrefix("scroll to"), numbers.count >= 2 {
                    scroll = SIMD2(numbers[0], numbers[1])
                } else if words.hasPrefix("add icon at"), numbers.count >= 2 {
                    icons.append((Int(numbers[0]), Int(numbers[1]), name))
                } else if words.hasPrefix("add cursor at"), numbers.count >= 2 {
                    cursors.append((Int(numbers[0]), Int(numbers[1]), name))
                } else if words.hasPrefix("add caret at"), numbers.count >= 4 {
                    carets.append((Int(numbers[0]), Int(numbers[1]), Int(numbers[2]), Int(numbers[3])))
                } else if words == "exit" {
                    break
                }
            }
            guard !image.isEmpty else { return nil }
        }
    }

    /// The cursors the still scene has, by the resources of the Mac's own they were: the watch, and the
    /// spinning ball's first frame. Others are left out, as the scene's only other one is off the screen.
    private static let cursorResources = ["Watch": "CURS_4", "Ball": "acur_128"]

    /// A picture's pixels, each whether it's black, and whether it's there at all
    private static func pixels(_ name: String) -> (width: Int, height: Int, black: [Bool], opaque: [Bool])? {
        guard let source = CGImageSourceCreateWithURL(resources.appendingPathComponent(name).appendingPathExtension("png") as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let count = image.width * image.height
        let opaque = (0..<count).map { bytes[$0 * 4 + 3] > 127 }
        let black = (0..<count).map { opaque[$0] && (Int(bytes[$0 * 4]) + Int(bytes[$0 * 4 + 1]) + Int(bytes[$0 * 4 + 2])) / 3 < 128 }
        return (image.width, image.height, black, opaque)
    }

    /// The emulated screen as the still scene has it, row by row from the top: its picture, the first
    /// frame of each icon over it with its bottom left corner where it's put, each cursor with its hot
    /// spot there (black where its mask and picture are, white where only its mask is, and the screen
    /// turned over where only its picture is), and each caret turned over, standing on where it's put
    private static func screen(of scene: Scene) -> [Bool]? {
        guard let picture = pixels(scene.image), picture.width == 512, picture.height == 342 else { return nil }
        var screen = picture.black
        func set(_ x: Int, _ y: Int, _ change: (inout Bool) -> Void) {
            guard (0..<512).contains(x), (0..<342).contains(y) else { return }
            change(&screen[y * 512 + x])
        }
        for icon in scene.icons {
            guard let sheet = pixels(icon.name), sheet.height == 32 else { return nil }
            for row in 0..<32 {
                for column in 0..<32 where sheet.opaque[row * sheet.width + column] {
                    set(icon.x + column, icon.y - 31 + row) { $0 = sheet.black[row * sheet.width + column] }
                }
            }
        }
        for cursor in scene.cursors {
            guard var resource = cursorResources[cursor.name] else { continue }
            // An animated cursor lists its frames' resources, after how many there are
            if resource.hasPrefix("acur_") {
                guard let list = try? Data(contentsOf: resources.appendingPathComponent(resource).appendingPathExtension("bin")), list.count >= 6 else { return nil }
                resource = "CURS_\(Int16(bitPattern: UInt16(list[4]) << 8 | UInt16(list[5])))"
            }
            guard let data = try? Data(contentsOf: resources.appendingPathComponent(resource).appendingPathExtension("bin")), data.count >= 68 else { return nil }
            let word = { (offset: Int) in UInt16(data[offset]) << 8 | UInt16(data[offset + 1]) }
            let hotSpot = (v: Int(Int16(bitPattern: word(64))), h: Int(Int16(bitPattern: word(66))))
            for row in 0..<16 {
                for column in 0..<16 {
                    let bit = UInt16(1) << (15 - column)
                    let isBlack = word(row * 2) & bit != 0, isMasked = word(32 + row * 2) & bit != 0
                    set(cursor.x - hotSpot.h + column, cursor.y - hotSpot.v + row) { pixel in
                        if isMasked {
                            pixel = isBlack
                        } else if isBlack {
                            pixel.toggle()
                        }
                    }
                }
            }
        }
        for caret in scene.carets {
            for row in 0..<caret.height {
                for column in 0..<caret.width {
                    set(caret.x + column, caret.y - row) { $0.toggle() }
                }
            }
        }
        return screen
    }

    /// The camera the extension sees the screen with: from 1000 away, turned by the scene's two angles,
    /// with an orthographic projection 140 pixels across (180 on a display more than twice as wide as
    /// high or the other way round), scaled so the screen's blocks reach past each of the display's
    /// corners. All of it in Float, as the extension works it out.
    private static func matrix(size: CGSize, camera: SIMD2<Float>) -> float4x4 {
        let aspect = Float(size.width / size.height)
        let across: Float = aspect < 0.5 || aspect > 2 ? 180 : 140
        var orthographic = float4x4(0)
        orthographic[0][0] = 2 / across
        orthographic[1][1] = 2 / (across / aspect)
        orthographic[2][2] = -0.0005001250538043678
        orthographic[3][2] = -1.0005000829696655
        orthographic[3][3] = 1
        // From OpenGL's depth to Metal's
        let depth = float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, -0.5, 0), SIMD4(0, 0, 0.5, 1))
        let turn = camera.x / 180 * .pi * 0.5, tilt = camera.y / -180 * .pi * 0.5
        let turned = simd_quatf(vector: SIMD4(0, 0, sin(turn), cos(turn)))
        let axis = turned.conjugate.act(SIMD3(1, 0, 0))
        let rotation = float4x4(turned * simd_quatf(vector: SIMD4(axis * sin(tilt), cos(tilt))))
        let eye = SIMD3<Float>(0, 0, -1000)
        let back = normalize(eye), side = normalize(cross(SIMD3(0, 1, 0), back)), up = cross(back, side)
        let look = float4x4(SIMD4(side.x, up.x, back.x, 0), SIMD4(side.y, up.y, back.y, 0), SIMD4(side.z, up.z, back.z, 0),
                            SIMD4(-dot(side, eye), -dot(up, eye), -dot(back, eye), 1))
        let view = look * rotation
        // Where the display's diagonals cross the edges of a pixel's square as the camera sees it
        let x = SIMD2(view[0].x, view[0].y), y = SIMD2(view[1].x, view[1].y), origin = SIMD2(view[3].x, view[3].y)
        let corners = [origin + x - y, origin + x + y, origin + y - x]
        func crossing(_ from: SIMD2<Float>, _ to: SIMD2<Float>, _ diagonal: SIMD2<Float>) -> SIMD2<Float> {
            let edge = to - from
            return abs(from + edge * ((-from.y * diagonal.x + from.x * diagonal.y) / (edge.y * diagonal.x - edge.x * diagonal.y)))
        }
        let crossings = [SIMD2(aspect, 1), SIMD2(aspect, -1)].flatMap { [crossing(corners[0], corners[1], $0), crossing(corners[1], corners[2], $0)] }
        let margin = across / (across - 2)
        let scale = max(margin / (crossings.map(\.x).min() ?? 1), margin / (crossings.map(\.y).min() ?? 1) / aspect)
        return depth * orthographic * view * float4x4(diagonal: SIMD4(scale, scale, scale, 1))
    }

    /// Its colour schemes, by their IDs (its colorScheme option's), in its extension's order, and the one
    /// it has until another is chosen
    static let colors = ["random", "spectrum", "accent", "gray", "darkGray", "green", "yellow", "orange", "red", "purple", "blue"]
    static let defaultColors = "spectrum"

    /// The colour a colour scheme gives, as the extension takes it: one of macOS's colours as it is in an
    /// appearance, in linear sRGB. Spectrum (the default) and Accent with a multicolour accent start with
    /// green, which is what the still scene keeps; Random has any of the colours.
    private static func color(of scheme: String?, isDark: Bool) -> SIMD4<Float> {
        let colors: [String: NSColor] = ["green": .systemGreen, "yellow": .systemYellow, "orange": .systemOrange, "red": .systemRed, "purple": .systemPurple, "blue": .systemBlue]
        let color: NSColor
        switch scheme {
        case "gray":
            return SIMD4(0.7, 0.7, 0.77, 1)
        case "darkGray":
            return SIMD4(0.165, 0.15, 0.15, 1)
        case "accent" where UserDefaults.standard.object(forKey: "AppleAccentColor") != nil:
            color = .controlAccentColor
        case "random":
            color = colors.values.randomElement() ?? .systemGreen
        case let scheme?:
            color = colors[scheme] ?? .systemGreen
        case nil:
            color = .systemGreen
        }
        var cgColor: CGColor?
        NSAppearance(named: isDark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            cgColor = color.cgColor
        }
        guard let linear = CGColorSpace(name: CGColorSpace.linearSRGB),
              let components = cgColor?.converted(to: linear, intent: .defaultIntent, options: nil)?.components, components.count == 4 else { return SIMD4(0, 0, 0, 1) }
        return SIMD4(components.map { Float($0) })
    }

    /// The extension's shaders and what they draw with, set up once
    private struct Renderer {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let background: MTLRenderPipelineState
        let shadows: MTLRenderPipelineState
        let blocks: MTLRenderPipelineState
        /// The squares drawn for each of the screen's pixels: the background's across the whole display,
        /// a shadow's under each, and a block's, which stands up as far as the pixel is black
        let backgroundSquare: MTLBuffer
        let shadowSquare: MTLBuffer
        let blockSquare: MTLBuffer

        init?() {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
                  let library = try? device.makeLibrary(URL: MacintoshWallpaper.resources.appendingPathComponent("default.metallib")) else { return nil }
            func pipeline(_ vertex: String, _ fragment: String, blends: Bool) -> (MTLRenderPipelineState, MTLRenderPipelineReflection?)? {
                guard let vertexFunction = library.makeFunction(name: vertex), let fragmentFunction = library.makeFunction(name: fragment) else { return nil }
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertexFunction
                descriptor.fragmentFunction = fragmentFunction
                descriptor.rasterSampleCount = 4
                let attachment = descriptor.colorAttachments[0]!
                attachment.pixelFormat = .rgba16Float
                // A shadow over what's under it
                if blends {
                    attachment.isBlendingEnabled = true
                    attachment.sourceRGBBlendFactor = .sourceAlpha
                    attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    attachment.sourceAlphaBlendFactor = .one
                    attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
                var reflection: MTLRenderPipelineReflection?
                guard let state = try? device.makeRenderPipelineState(descriptor: descriptor, options: .bindingInfo, reflection: &reflection) else { return nil }
                return (state, reflection)
            }
            guard let background = pipeline("backgroundVertex", "backgroundFragment", blends: false),
                  let shadows = pipeline("pixelVertex", "shadowFragment", blends: true),
                  let blocks = pipeline("pixelVertex", "pixelFragment", blends: false),
                  let uniforms = blocks.1?.vertexBindings.first(where: { $0.name == "uniforms" }) as? MTLBufferBinding,
                  uniforms.index == 0, uniforms.bufferDataSize == MemoryLayout<Uniforms>.size,
                  let members = uniforms.bufferStructType?.members, members.map({ ($0.name, $0.offset) }).elementsEqual(MacintoshWallpaper.uniformsLayout, by: ==),
                  blocks.1?.vertexBindings.contains(where: { $0.name == "vertices" && $0.index == 1 }) == true else { return nil }
            func square(_ corners: [SIMD4<Float>]) -> MTLBuffer? {
                device.makeBuffer(bytes: corners, length: MemoryLayout<SIMD4<Float>>.stride * corners.count)
            }
            guard let backgroundSquare = square([SIMD4(-1, -1, 0, 1), SIMD4(1, -1, 0, 1), SIMD4(-1, 1, 0, 1), SIMD4(1, 1, 0, 1)]),
                  let shadowSquare = square([SIMD4(-1.125, -1.125, -0.45, 1), SIMD4(1.125, -1.125, -0.45, 1), SIMD4(-1.125, 1.125, -0.45, 1), SIMD4(1.125, 1.125, -0.45, 1)]),
                  let blockSquare = square([SIMD4(-0.45, -0.45, 0, 1), SIMD4(0.45, -0.45, 0, 1), SIMD4(-0.45, 0.45, 0, 1), SIMD4(0.45, 0.45, 0, 1)]) else { return nil }
            (self.device, self.queue, self.background, self.shadows, self.blocks) = (device, queue, background.0, shadows.0, blocks.0)
            (self.backgroundSquare, self.shadowSquare, self.blockSquare) = (backgroundSquare, shadowSquare, blockSquare)
        }
    }

    private static let renderer = Renderer()

    /// Macintosh as the still scene shows it on a display of `size`, in pixels: in its Dark look or its
    /// Light one, in the colours of `scheme` (its colorScheme option) as they are in an appearance. Nil
    /// on a macOS whose Macintosh isn't drawn as worked out here.
    static func picture(showsDark: Bool, inDarkAppearance isDark: Bool, scheme: String?, size: CGSize) -> CGImage? {
        let width = max(Int(size.width), 1), height = max(Int(size.height), 1)
        guard let renderer, let scene = Scene(), let screen = screen(of: scene) else { return nil }
        let device = renderer.device
        let screenDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 512, height: 342, mipmapped: false)
        guard let screenTexture = device.makeTexture(descriptor: screenDescriptor) else { return nil }
        let bytes = screen.flatMap { $0 ? [UInt8](repeating: 0, count: 3) + [255] : [UInt8](repeating: 255, count: 4) }
        screenTexture.replace(region: MTLRegionMake2D(0, 0, 512, 342), mipmapLevel: 0, withBytes: bytes, bytesPerRow: 512 * 4)
        // Drawn four samples a pixel, which only the GPU keeps where it can
        let samples = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        samples.textureType = .type2DMultisample
        samples.sampleCount = 4
        samples.usage = .renderTarget
        samples.storageMode = device.supportsFamily(.apple1) ? .memoryless : .private
        let resolved = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        resolved.usage = .renderTarget
        resolved.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let sampleTexture = device.makeTexture(descriptor: samples), let output = device.makeTexture(descriptor: resolved) else { return nil }

        // The bottom of the background in the scheme's colour, a third as bright in the Dark look; its top
        // lighter, towards white in gamma 2.2; the blocks two thirds as bright as the bottom, as they are
        // in the still scene
        let base = color(of: scheme, isDark: isDark)
        let bottom = showsDark ? SIMD4(base.x * 0.3, base.y * 0.3, base.z * 0.3, base.w) : base
        let gamma = SIMD4<Float>(pow(bottom.x, 1 / 2.2), pow(bottom.y, 1 / 2.2), pow(bottom.z, 1 / 2.2), pow(bottom.w, 1 / 2.2))
        let lighter = gamma + (SIMD4(repeating: 1) - gamma) * (showsDark ? 0.09 : 0.26)
        let top = SIMD4<Float>(pow(lighter.x, 2.2), pow(lighter.y, 2.2), pow(lighter.z, 2.2), pow(lighter.w, 2.2))
        let blocks = SIMD4(bottom.x * 0.666, bottom.y * 0.666, bottom.z * 0.666, 1)
        // The 140 by 140 of the screen's pixels around where it's scrolled to, from its middle
        let corner = SIMD2<Int32>(Int32(scene.scroll.x) - 70, Int32(scene.scroll.y) - 70)
        var uniforms = Uniforms(viewProjectionMatrix: matrix(size: CGSize(width: width, height: height), camera: scene.camera),
                                bitmapSize: SIMD4(512, 342, 256, 171), bitmapSizeInt: SIMD4(512, 342, 0, 0), pixelsRectInt: SIMD4(corner.x, corner.y, 140, 0),
                                translate: SIMD4(scene.scroll.x - 256, scene.scroll.y - 171, 0, 0), rampDirection: .zero, animation: SIMD4(1, 0.5, 0.75, 0),
                                backgroundColorTop: top, backgroundColorBottom: bottom, color: blocks)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = sampleTexture
        pass.colorAttachments[0].resolveTexture = output
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .multisampleResolve
        guard let commands = renderer.queue.makeCommandBuffer(), let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 0)
        encoder.setVertexTexture(screenTexture, index: 0)
        let count = 140 * 140
        for (pipeline, square, instances) in [(renderer.background, renderer.backgroundSquare, 1), (renderer.shadows, renderer.shadowSquare, count), (renderer.blocks, renderer.blockSquare, count)] {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(square, offset: 0, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances)
        }
        encoder.endEncoding()
        if output.storageMode == .managed, let blit = commands.makeBlitCommandEncoder() {
            blit.synchronize(resource: output)
            blit.endEncoding()
        }
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else { return nil }

        // In 16-bit floats, as the extension draws it, then in 8-bit sRGB as other pictures are
        let rowBytes = width * 8
        var halves = Data(count: rowBytes * height)
        halves.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        guard let linear = CGColorSpace(name: CGColorSpace.linearSRGB), let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: halves as CFData),
              let drawn = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: rowBytes, space: linear,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(drawn, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

// MARK: - Sequoia (As macOS Draws It)
/// System Settings' Sequoia wallpaper as a still picture, drawn as its extension draws it before it starts
/// to move: a field of streaks, each one of three 3D meshes stood on the ground, turned and scaled, seen
/// from low down and coloured by height from a gradient of the time of day (`looks`), solar noon's in the
/// Light look and solar midnight's in the Dark one. It's drawn with the extension's own shaders, meshes and
/// gradients, and the streaks stand where the extension's own tables put them. As in the extension, the
/// streaks without a turn of their own get a random one, so no two times Safelight (or macOS) starts
/// drawing it are quite the same, though while it runs they keep theirs, as the extension's keep theirs
/// while its colours change, so its looks differ only in colour. Drawn so, with the extension's streaks
/// turned as it had turned them, it's within a level of each colour of what the extension draws.
enum SequoiaWallpaper {
    private static let resources = URL(fileURLWithPath: WallpaperLibrary.sequoiaExtension).appendingPathComponent("Contents/Resources", isDirectory: true)
    private static let executable = URL(fileURLWithPath: WallpaperLibrary.sequoiaExtension).appendingPathComponent("Contents/MacOS/WallpaperSequoiaExtension")

    /// One of Sequoia's looks through the day: its gradient, where the sun is when Sequoia set to
    /// Automatic shows it in Light (its altitude and azimuth, in degrees), and how far its colours are
    /// dimmed, which the shaders take as `dimmingGradientAmount`
    struct Look {
        let gradient: String
        let altitude: Double
        let azimuth: Double
        let dimming: Float
    }

    /// Its looks in the extension's order, with the values in the extension's code. Set to Automatic,
    /// the extension shows the one of the time of day in Light, picked by where the sun is
    /// (`WallpaperManager.makeSunWallpaper`), and solar midnight's in Dark. Set to Light it shows solar
    /// noon's, and set to Dark solar midnight's. Live on 2026-11-01, sunset's was 96% within 2 levels of
    /// the extension's (mean 0.87), against none at all drawn as dimmed as solar noon's.
    static let looks = [Look(gradient: "solar midnight", altitude: -45, azimuth: 0, dimming: 1),
                        Look(gradient: "dawn", altitude: -16, azimuth: 65, dimming: 0.5),
                        Look(gradient: "sunrise", altitude: 0, azimuth: 75, dimming: 0),
                        Look(gradient: "mid morning", altitude: 18, azimuth: 95, dimming: 0),
                        Look(gradient: "solar noon", altitude: 45, azimuth: 180, dimming: 1),
                        Look(gradient: "late afternoon", altitude: 18, azimuth: 265, dimming: 0),
                        Look(gradient: "sunset", altitude: 0, azimuth: 285, dimming: 0),
                        Look(gradient: "dusk", altitude: -16, azimuth: 290, dimming: 0.5)]
    /// Which of `looks` is its Light look, and which its Dark one
    static let lightLook = 4, darkLook = 0

    /// Where a streak stands, how it's turned, in radians, and how wide and how tall it is, each as a
    /// share of 0.35 to 1.4 in 16 bits, as the shaders take it
    private struct Streak {
        var x: Float
        var z: Float
        var rotation: Float
        var scaleRadial: UInt16
        var scaleVertical: UInt16
    }

    /// The streaks as the extension lays them out: two heroes with meshes of their own, then 13 with a
    /// turn and scale of their own, then the rest. Their places, and the 13's turns and scales, are
    /// tables in the extension's code, found by their first values; nil where they aren't there.
    private static let layout: (places: [SIMD2<Float>], shaped: [SIMD3<Float>])? = {
        guard let code = try? Data(contentsOf: executable, options: .mappedIfSafe) else { return nil }
        func floats(after key: [Float], count: Int, back: Int = 0) -> [Float]? {
            let bytes = key.flatMap { withUnsafeBytes(of: $0.bitPattern.littleEndian, Array.init) }
            guard let found = code.range(of: Data(bytes)) else { return nil }
            let start = found.lowerBound - back * MemoryLayout<Float>.size
            guard start >= code.startIndex, start + count * 4 <= code.endIndex else { return nil }
            return (0..<count).map { Float(bitPattern: UInt32(littleEndian: code[(start + $0 * 4)..<(start + $0 * 4 + 4)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })) }
        }
        guard let places = floats(after: [-0.39026403427124023, 2.568509101867676], count: 274 * 2),
              let shaped = floats(after: [-17.06, 1.0, 0.48], count: 13 * 3, back: 7 * 3),
              places.allSatisfy({ abs($0) < 50 }), shaped.enumerated().allSatisfy({ $0.offset % 3 == 0 ? abs($0.element) < 30 : (0.2...1.5).contains($0.element) }) else { return nil }
        return (stride(from: 0, to: places.count, by: 2).map { SIMD2(places[$0], places[$0 + 1]) },
                stride(from: 0, to: shaped.count, by: 3).map { SIMD3(shaped[$0], shaped[$0 + 1], shaped[$0 + 2]) })
    }()

    /// A scale as the shaders take it: its share of 0.35 to 1.4, in 16 bits
    private static func normalized(_ scale: Float) -> UInt16 {
        UInt16(min((scale + -0.35) / 1.05 * 65535, 65535))
    }

    /// The camera as the extension sets it up before Sequoia moves: a field of view of 39.7°, narrower
    /// as the display is wider, standing at (0, 0, 2) tilted 177.12° less half the field of view, and
    /// a projection with infinite depth, the near plane 0.01 away, depth reversed
    private static func camera(aspect: Float) -> (view: float4x4, projection: float4x4) {
        let fieldOfView = Float(39.7 * Double.pi / 180)
        let focal = 1 / tan(fieldOfView * 0.5)
        let projection = float4x4(SIMD4(aspect <= 1 ? focal / aspect : focal, 0, 0, 0), SIMD4(0, aspect <= 1 ? focal : aspect * focal, 0, 0),
                                  SIMD4(0, 0, 2.5033950805664062e-05, -1), SIMD4(0, 0, 0.010000250302255154, 0))
        var half = fieldOfView * 0.5
        if aspect > 1 {
            half = tan(atan(half) / aspect)
        }
        let tilt = Float(Double(Float(177.12 * Double.pi / 180)) - Double(half)) + Float.pi / 2
        let tilted = float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, cos(tilt), sin(tilt), 0), SIMD4(0, -sin(tilt), cos(tilt), 0), SIMD4(0, 0, 0, 1))
        // Turned half round about z, which turns x and y over
        var placed = float4x4(SIMD4(-1, 0, 0, 0), SIMD4(0, -1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)) * tilted
        placed[3] = SIMD4(0, 0, 2, 1)
        return (placed.inverse, projection)
    }

    /// The streaks drawn on a display of `aspect`: the heroes, then the others in front of the camera,
    /// nearest first. Where they stand on the ground wraps round from 4 behind to 16 ahead; past 10 ahead
    /// they're left out, as is any whose post, 30 high and 0.7 round, is out of the camera's view (the
    /// heroes, which always are in it, are always drawn).
    private static func streaks(aspect: Float, rotation: (SIMD2<Float>) -> Float) -> (heroes: [Streak], others: [Streak])? {
        guard let layout else { return nil }
        let (view, projection) = camera(aspect: aspect)
        let viewProjection = (projection * view).transpose
        let rows = (0..<4).map { viewProjection[$0] }
        let planes = [rows[3] + rows[0], rows[3] - rows[0], rows[3] + rows[1], rows[3] - rows[1]].map { $0 / length(SIMD3($0.x, $0.y, $0.z)) }
        func isShown(_ streak: Streak) -> Bool {
            guard streak.z <= 10 else { return false }
            return planes.allSatisfy { plane in
                let normal = SIMD3(plane.x, plane.y, plane.z)
                return max(dot(normal, SIMD3(-streak.x, 0, streak.z)), dot(normal, SIMD3(-streak.x, 30, streak.z))) + plane.w + 0.7 >= 0
            }
        }
        var heroes: [Streak] = [], others: [Streak] = []
        let unscaled = normalized(1)
        for (index, place) in layout.places.enumerated() {
            let z = fmodf(place.y + 24, 20) + -4
            var streak = Streak(x: place.x, z: z, rotation: 0, scaleRadial: unscaled, scaleVertical: unscaled)
            if index >= 2, index < 2 + layout.shaped.count {
                let shape = layout.shaped[index - 2]
                (streak.rotation, streak.scaleRadial, streak.scaleVertical) = (shape.x, normalized(shape.y), normalized(shape.z))
            } else if index >= 2 {
                streak.rotation = rotation(place)
            }
            if index < 2 {
                heroes.append(streak)
            } else if isShown(streak) {
                others.append(streak)
            }
        }
        others.sort { $0.z < $1.z }
        return (heroes, others)
    }

    /// The extension's shaders, meshes and gradients, set up once
    private struct Renderer {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let streaks: MTLRenderPipelineState
        let background: MTLRenderPipelineState
        let depth: MTLDepthStencilState
        /// The two heroes' meshes, then the other streaks'
        let meshes: [MTKMesh]
        /// Each of `looks`' gradients
        let gradients: [MTLTexture]

        init?() {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
                  let library = try? device.makeLibrary(URL: SequoiaWallpaper.resources.appendingPathComponent("default.metallib")) else { return nil }
            // Without a second gradient to blend towards, as before it moves
            let constants = MTLFunctionConstantValues()
            var hasSecondGradient = false
            constants.setConstantValue(&hasSecondGradient, type: .bool, index: 0)
            func pipeline(_ vertex: String, _ fragment: String) -> (MTLRenderPipelineState, MTLRenderPipelineReflection?)? {
                guard let vertexFunction = try? library.makeFunction(name: vertex, constantValues: constants),
                      let fragmentFunction = try? library.makeFunction(name: fragment, constantValues: constants) else { return nil }
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertexFunction
                descriptor.fragmentFunction = fragmentFunction
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
                descriptor.depthAttachmentPixelFormat = .depth16Unorm
                descriptor.rasterSampleCount = 4
                var reflection: MTLRenderPipelineReflection?
                guard let state = try? device.makeRenderPipelineState(descriptor: descriptor, options: .bindingInfo, reflection: &reflection) else { return nil }
                return (state, reflection)
            }
            // What the shaders take, checked by name, size and place, so a macOS whose shaders take something else gets no picture from here
            guard let streaks = pipeline("drawVertex", "drawFragment"), let background = pipeline("screenTriangleVertex", "backgroundFragment"),
                  let uniforms = streaks.1?.vertexBindings.first(where: { $0.name == "uniforms" }) as? MTLBufferBinding, uniforms.index == 0, uniforms.bufferDataSize == 128,
                  uniforms.bufferStructType?.members.map({ "\($0.name) \($0.offset)" }) == ["viewTransform 0", "projectionTransform 64"],
                  let instances = streaks.1?.vertexBindings.first(where: { $0.name == "instances" }) as? MTLBufferBinding, instances.index == 2,
                  instances.bufferStructType?.members.map({ "\($0.name) \($0.offset)" }) == ["x 0", "z 4", "rotation 8", "normalizedScaleRadial 12", "normalizedScaleVertical 14"],
                  streaks.1?.vertexBindings.contains(where: { $0.name == "vertices" && $0.index == 1 }) == true,
                  streaks.1?.fragmentBindings.contains(where: { $0.name == "dimmingGradientAmount" && $0.index == 1 }) == true,
                  streaks.1?.fragmentBindings.contains(where: { $0.name == "gradientTexture" && $0.index == 0 }) == true else { return nil }
            let depthDescriptor = MTLDepthStencilDescriptor()
            depthDescriptor.depthCompareFunction = .greaterEqual
            depthDescriptor.isDepthWriteEnabled = true
            guard let depth = device.makeDepthStencilState(descriptor: depthDescriptor) else { return nil }

            // Each mesh with its position and where on its gradient it is, 16 bytes a vertex
            let vertices = MDLVertexDescriptor()
            vertices.attributes = NSMutableArray(array: [MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0),
                                                         MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate, format: .half2, offset: 12, bufferIndex: 0)])
            vertices.layouts = NSMutableArray(array: [MDLVertexBufferLayout(stride: 16)])
            let meshes = ["mesh hero 1", "mesh hero 2", "mesh"].compactMap { name -> MTKMesh? in
                let asset = MDLAsset(url: SequoiaWallpaper.resources.appendingPathComponent(name).appendingPathExtension("usdc"), vertexDescriptor: vertices,
                                     bufferAllocator: MTKMeshBufferAllocator(device: device))
                guard let mesh = asset.childObjects(of: MDLMesh.self).first as? MDLMesh, let drawn = try? MTKMesh(mesh: mesh, device: device),
                      drawn.vertexBuffers.count == 1, drawn.submeshes.count == 1 else { return nil }
                return drawn
            }
            // Each gradient as the extension reads it: drawn in Generic RGB linear, in 16-bit floats
            func gradient(_ name: String) -> MTLTexture? {
                guard let source = CGImageSourceCreateWithURL(SequoiaWallpaper.resources.appendingPathComponent(name).appendingPathExtension("exr") as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let linear = CGColorSpace(name: CGColorSpace.genericRGBLinear),
                      let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 16, bytesPerRow: image.width * 8, space: linear,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                      let data = context.data else { return nil }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: image.width, height: image.height, mipmapped: false)
                guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
                texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0, withBytes: data, bytesPerRow: image.width * 8)
                return texture
            }
            let gradients = looks.compactMap { gradient($0.gradient) }
            guard meshes.count == 3, gradients.count == looks.count else { return nil }
            (self.device, self.queue, self.streaks, self.background, self.depth) = (device, queue, streaks.0, background.0, depth)
            (self.meshes, self.gradients) = (meshes, gradients)
        }
    }

    private static let renderer = Renderer()

    /// The random turn of the streak standing at each place, the same for every picture drawn while
    /// Safelight runs
    private static let turns = Dictionary((layout?.places ?? []).map { ($0, Float.random(in: 0..<(2 * .pi))) }) { first, _ in first }

    /// Sequoia as it is before it moves, on a display of `size`, in pixels, in its Dark look or its
    /// Light one (`picture(look:size:rotation:)`). Nil on a macOS whose Sequoia isn't drawn as worked out here.
    static func picture(showsDark: Bool, size: CGSize, rotation: (SIMD2<Float>) -> Float = { turns[$0] ?? 0 }) -> CGImage? {
        picture(look: showsDark ? darkLook : lightLook, size: size, rotation: rotation)
    }

    /// Sequoia as it is before it moves, on a display of `size`, in pixels, in one of its `looks`, with
    /// each streak that has no turn of its own turned as `rotation` says for where it stands, at random
    /// unless a test says otherwise. Nil on a macOS whose Sequoia isn't drawn as worked out here.
    static func picture(look: Int, size: CGSize, rotation: (SIMD2<Float>) -> Float = { turns[$0] ?? 0 }) -> CGImage? {
        let width = max(Int(size.width), 1), height = max(Int(size.height), 1)
        guard let renderer, looks.indices.contains(look), let streaks = streaks(aspect: Float(width) / Float(height), rotation: rotation) else { return nil }
        let device = renderer.device
        let laidOut = streaks.heroes + streaks.others
        guard streaks.heroes.count == 2, let instances = device.makeBuffer(bytes: laidOut, length: MemoryLayout<Streak>.stride * laidOut.count) else { return nil }
        // Drawn four samples a pixel, which only the GPU keeps where it can, with depth as the extension has it
        func target(_ format: MTLPixelFormat) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.textureType = .type2DMultisample
            descriptor.sampleCount = 4
            descriptor.usage = .renderTarget
            descriptor.storageMode = device.supportsFamily(.apple1) ? .memoryless : .private
            return device.makeTexture(descriptor: descriptor)
        }
        let resolved = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        resolved.usage = .renderTarget
        resolved.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let colors = target(.bgra8Unorm_srgb), let depths = target(.depth16Unorm), let output = device.makeTexture(descriptor: resolved) else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colors
        pass.colorAttachments[0].resolveTexture = output
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.depthAttachment.texture = depths
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 0
        pass.depthAttachment.storeAction = .dontCare
        guard let commands = renderer.queue.makeCommandBuffer(), let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        let (view, projection) = camera(aspect: Float(width) / Float(height))
        var uniforms = [view, projection]
        var dimming = looks[look].dimming
        encoder.setCullMode(.front)
        encoder.setRenderPipelineState(renderer.streaks)
        encoder.setDepthStencilState(renderer.depth)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<float4x4>.stride * 2, index: 0)
        encoder.setVertexBuffer(instances, offset: 0, index: 2)
        encoder.setFragmentBytes(&dimming, length: MemoryLayout<Float>.size, index: 1)
        encoder.setFragmentTexture(renderer.gradients[look], index: 0)
        // Each hero with its own mesh, then the other streaks with theirs
        for (mesh, count, first) in [(renderer.meshes[0], 1, 0), (renderer.meshes[1], 1, 1), (renderer.meshes[2], streaks.others.count, 2)] where count > 0 {
            let submesh = mesh.submeshes[0]
            encoder.setVertexBuffer(mesh.vertexBuffers[0].buffer, offset: mesh.vertexBuffers[0].offset, index: 1)
            encoder.drawIndexedPrimitives(type: submesh.primitiveType, indexCount: submesh.indexCount, indexType: submesh.indexType, indexBuffer: submesh.indexBuffer.buffer,
                                          indexBufferOffset: submesh.indexBuffer.offset, instanceCount: count, baseVertex: 0, baseInstance: first)
        }
        // The sky, behind them all
        encoder.setRenderPipelineState(renderer.background)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        if output.storageMode == .managed, let blit = commands.makeBlitCommandEncoder() {
            blit.synchronize(resource: output)
            blit.endEncoding()
        }
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else { return nil }

        let rowBytes = width * 4
        var pixels = Data(count: rowBytes * height)
        pixels.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB), let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes, space: sRGB,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

// MARK: - 9. Wallpaper Library (System Settings › Wallpaper's Own)
/// One of System Settings › Wallpaper's own wallpapers, as a still picture for Light and one for Dark,
/// which are the same unless it has one of each
struct WallpaperItem: Identifiable, Hashable {
    /// Where one of its pictures comes from
    enum Picture: Hashable {
        /// A file on the Mac, with one picture in it, or one for Light and one for Dark
        case file(URL)
        /// One of the pictures macOS downloads from Apple once it's chosen, by its ID in macOS's list,
        /// and the file macOS keeps it in once it has
        case download(id: String, file: URL)
        /// An aerial, by its ID, as the desktop shows it, from its video on Apple's server
        case aerial(id: String, video: URL)
        /// A colour, as its swatch
        case color(URL)
        /// One of the wallpapers macOS draws, in its Dark look or its Light one
        case drawn(WallpaperManager.DrawnWallpaper, isDark: Bool)
        /// A photo in the Photos library, by its ID there, as it looks in Photos
        case asset(String)
    }

    /// What System Settings badges a thumbnail with: a dynamic wallpaper, which has a picture for Light
    /// and one for Dark, or an aerial, which is a video
    enum Badge {
        case dynamic, video
    }

    /// What macOS downloads once it's chosen in System Settings, into files System Settings' Remove
    /// Download takes off the Mac again, and how each of its extensions tells whether it has
    enum Download: Hashable {
        /// Aerials' videos, by their IDs: an aerial's own, or one for each appearance and each way up a
        /// display can be, for macOS's own Light and Dark one
        case aerials([String])
        /// One of macOS's pictures, in the file it keeps it in
        case picture(URL)
        /// Tahoe's videos, in its extension's container, for Light and Dark: those for landscape
        /// displays, and those for portrait ones
        case tahoe(landscape: [URL], portrait: [URL])

        /// The files Remove Download takes away
        var files: [URL] {
            switch self {
            case .aerials(let ids): ids.map(WallpaperLibrary.downloadedVideo(ofAerial:))
            case .picture(let file): [file]
            case .tahoe(let landscape, let portrait): landscape + portrait
            }
        }

        /// Whether System Settings has it as downloaded, with no download badge, from `onMac`, the files
        /// of those that are on the Mac: aerials once any of their videos is, and Golden Gate Sunset
        /// always, as macOS comes with its video, but Tahoe only once both its landscape videos are
        func isDownloaded(onMac: Set<URL>) -> Bool {
            switch self {
            case .aerials(let ids):
                return ids.contains { onMac.contains(WallpaperLibrary.downloadedVideo(ofAerial: $0)) || WallpaperLibrary.shippedVideo(ofAerial: $0) != nil }
            case .picture(let file):
                return onMac.contains(file)
            case .tahoe(let landscape, _):
                return landscape.allSatisfy(onMac.contains)
            }
        }

        /// Whether System Settings offers to remove it: once any of its files is on the Mac, but Tahoe
        /// always
        func isRemovable(onMac: Set<URL>) -> Bool {
            if case .tahoe = self {
                return true
            }
            return files.contains(where: onMac.contains)
        }
    }

    let id: String
    let name: String
    let light: Picture
    let dark: Picture
    let lightThumbnail: URL?
    let darkThumbnail: URL?
    /// The thumbnail System Settings › Wallpaper shows for it, in Light and in Dark alike, which its
    /// extension gives: one with a picture for each appearance has one of both
    let thumbnail: URL?
    var badge: Badge?
    /// What macOS downloads once it's chosen in System Settings, for those it downloads
    var download: Download?

    /// Whether it's a picture macOS places on the display as System Settings' options for a picture say:
    /// one of macOS's Pictures, or a photo of the user's, but not one with a picture for each
    /// appearance, an aerial, a colour, or one macOS draws
    var isPicture: Bool {
        guard badge == nil else { return false }
        switch light {
        case .file, .download, .asset: return true
        case .aerial, .color, .drawn: return false
        }
    }

    /// The choice a picture of the user's own, from a file or from Photos, is remembered as, which no
    /// wallpaper in the Wallpaper window is: by its name, when it has one
    static func ownPicture(named name: String?) -> ID {
        ownPicturePrefix + (name ?? "")
    }

    static func isOwnPicture(_ id: ID) -> Bool {
        id.hasPrefix(ownPicturePrefix)
    }

    /// The name of a picture of the user's own, or what System Settings calls one with none
    static func nameOfOwnPicture(_ id: ID) -> String? {
        guard isOwnPicture(id) else { return nil }
        let name = String(id.dropFirst(ownPicturePrefix.count))
        return name.isEmpty ? SystemStrings.picture : name
    }

    private static let ownPicturePrefix = "own:"

    /// The choice a colour of the user's own is remembered as, whichever colour it is and whether it's
    /// shown as a gradient, as System Settings' colours extension gives every custom colour one choice,
    /// the Custom Colour button's, keeping the colour and the gradient in its options
    static let customColor = "color:custom"
}

/// One of System Settings › Wallpaper's shuffles: a new picture from a set every so often. Here each
/// shuffles the picture for one appearance, so Light and Dark can each have their own.
struct WallpaperShuffle: Identifiable, Hashable {
    /// How often a shuffle changes its picture
    enum Interval: String, Codable {
        case minute, fiveMinutes, fifteenMinutes, thirtyMinutes, hour, twelveHours, day, twoDays, week, month, login, wake

        var title: String {
            SystemStrings.shuffleInterval(self)
        }

        /// When it changes next after `date`, or nil for one that changes at login or on waking
        func next(after date: Date) -> Date? {
            let minutes = [Self.minute: 1, .fiveMinutes: 5, .fifteenMinutes: 15, .thirtyMinutes: 30, .hour: 60, .twelveHours: 12 * 60]
            let days = [Self.day: 1, .twoDays: 2, .week: 7]
            if let minutes = minutes[self] {
                return date.addingTimeInterval(TimeInterval(minutes * 60))
            } else if let days = days[self] {
                return Calendar.current.date(byAdding: .day, value: days, to: date)
            } else if self == .month {
                return Calendar.current.date(byAdding: .month, value: 1, to: date)
            }
            return nil
        }
    }

    /// Your Photos' shuffle and Colours', and the aerials' of them all, besides those of each category
    /// (`shuffle:` and the category's ID)
    static let photos = "shuffle:photos"
    static let colors = "shuffle:colors"
    static let aerials = "shuffle:aerials"

    let id: String
    let name: String
    /// Four of its pictures, for its thumbnail
    let thumbnails: [URL?]

    var isAerials: Bool {
        Self.isAerials(id)
    }

    /// Whether a shuffle is of aerials: all of System Settings' are but Your Photos', Colours' and the
    /// photo sets' (`PhotoSet`)
    static func isAerials(_ id: ID) -> Bool {
        id != photos && id != colors && !PhotoSet.isSet(id)
    }

    /// How often it can change, as System Settings offers for its kind, but never every few seconds or
    /// continuously, as each change makes a wallpaper
    static func intervals(for id: ID) -> [Interval] {
        isAerials(id) ? [.twelveHours, .day, .twoDays, .week, .month] : [.minute, .fiveMinutes, .fifteenMinutes, .thirtyMinutes, .hour, .day, .login, .wake]
    }

    /// As often as macOS changes one until it's set: every half hour, or for the aerials, every day
    static func defaultInterval(for id: ID) -> Interval {
        isAerials(id) ? .day : .thirtyMinutes
    }

    /// How often one of System Settings' shuffles changes, by the ID of its choice in macOS's wallpaper
    /// service, as one Safelight offers for it: every few seconds or continuously is as often as it can
    /// be, and with none chosen yet, it's as often as macOS changes it then
    static func interval(ofSystemFrequency frequency: String?, for id: ID) -> Interval {
        let known: [String: Interval] = ["shuffle_on_login": .login, "shuffle_on_wakeup": .wake, "shuffle_every_1_minute": .minute,
                                         "shuffle_every_5_minutes": .fiveMinutes, "shuffle_every_15_minutes": .fifteenMinutes,
                                         "shuffle_every_30_minutes": .thirtyMinutes, "shuffle_every_1_hour": .hour, "shuffle_every_12_hours": .twelveHours,
                                         "shuffle_every_1_day": .day, "shuffle_every_2_days": .twoDays, "shuffle_every_1_week": .week, "shuffle_every_1_month": .month]
        let offered = intervals(for: id)
        if frequency == "shuffle_every_5_seconds" || frequency == "shuffle_continuously" {
            return offered[0]
        }
        return frequency.flatMap { known[$0] }.flatMap { offered.contains($0) ? $0 : nil } ?? defaultInterval(for: id)
    }
}

/// System Settings › Wallpaper's own wallpapers, in its sections and its order, gathered as it gathers
/// them from its extensions, as far as each has a still picture to put in a wallpaper of Safelight's:
/// its dynamic wallpapers' pictures for Light and for Dark, its aerials as the desktop shows them
/// before they move, Sequoia and Macintosh as they're drawn here, its pictures and its colours. Its
/// shuffles have no one picture, so they aren't here.
final class WallpaperLibrary {
    static let shared = WallpaperLibrary()

    struct Section: Identifiable {
        /// How System Settings shows a section: wallpapers with their names, shuffles with theirs, the
        /// user's own photos after Add Photo…, or colours as round swatches after a custom colour
        enum Kind {
            case pictures, shuffles, photos, colors
        }

        let id: String
        let title: String
        var kind = Kind.pictures
        /// All its wallpapers, as Show All shows them
        let items: [WallpaperItem]
        /// Those its row shows until then, when that's not all of them: an aerial section's row leaves
        /// out those System Settings shows only after their first in Show All
        var row: [WallpaperItem]?
        /// Its shuffles, before its wallpapers
        var shuffles: [WallpaperShuffle] = []
    }

    /// The ID of Your Photos, whose wallpapers are the user's own, in `YourPhotos`
    static let yourPhotos = "your-photos"

    let sections: [Section]
    private let items: [WallpaperItem.ID: WallpaperItem]
    /// The aerials, by the ID macOS's wallpaper service knows each by: its own, or for one with a video
    /// for each appearance, its subcategory's
    private let aerialItems: [String: WallpaperItem.ID]
    private let downloads: [String: URL]
    /// Every file macOS may have downloaded one of the wallpapers into, which `WallpaperManager` looks for
    let downloadFiles: Set<URL>
    /// The aerials' shuffles' pictures, and the colours, by the shuffle's ID
    private let shufflePictures: [WallpaperShuffle.ID: [WallpaperItem]]

    /// Where macOS keeps its pictures, with the list of them in System Settings' order, their
    /// thumbnails, a descriptor of each it downloads once it's chosen, and its colours' swatches
    private static let desktopPictures = URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true)
    /// macOS's list of the pictures it downloads, with where Apple has each
    private static let downloadList = URL(fileURLWithPath: "/System/Library/AssetsV2/com_apple_MobileAsset_DesktopPicture/com_apple_MobileAsset_DesktopPicture.xml")
    /// Where macOS keeps those pictures once it has downloaded them
    private static let downloadedPictures = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.mobileAssetDesktop", isDirectory: true)
    /// Where macOS keeps its list of aerials, which it updates, with their names, their thumbnails, and
    /// the videos it has downloaded
    static let aerials = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials", isDirectory: true)
    /// Where System Settings has the list of aerials and thumbnails of them it came with
    private static let aerialsExtension = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex/Contents/Resources", isDirectory: true)
    /// The aerials' category with macOS's own, whose Light and Dark videos are one dynamic wallpaper
    private static let dynamicAerials = "dynamic-aerials"
    /// The extensions that give System Settings the dynamic wallpapers it has as a picture for Light and
    /// one for Dark, besides macOS's pictures: Tahoe's, with a file for each, and Sonoma's, with both in one
    static let tahoeExtension = "/System/Library/ExtensionKit/Extensions/NeptuneOneWallpaper.appex"
    static let sonomaExtension = "/System/Library/ExtensionKit/Extensions/WallpaperSonomaExtension.appex"
    /// The extensions of the wallpapers macOS draws as they're shown, which have their thumbnails and
    /// names: Sequoia's has its thumbnails, and Macintosh's is with macOS's wallpapers
    static let sequoiaExtension = "/System/Library/ExtensionKit/Extensions/WallpaperSequoiaExtension.appex"
    static let macintoshExtension = "/System/Library/ExtensionKit/Extensions/WallpaperMacintoshExtension.appex"
    static let macintoshThumbnail = URL(fileURLWithPath: "/System/Library/Wallpapers/.thumbnails/Macintosh.heic")
    /// macOS's colours, in System Settings' order, by their swatches' names
    private static let colors = ["Black", "Blue Violet", "Cyan", "Dusty Rose", "Electric Blue", "Gold 2", "Gold", "Ocher", "Plum", "Red Orange",
                                 "Rose Gold", "Silver", "Soft Pink", "Space Gray Pro", "Space Gray", "Stone", "Teal", "Turquoise Green", "Yellow"]

    /// macOS's list of aerials, as much of it as is used here
    private struct AerialList: Decodable {
        let categories: [Category]
        let assets: [Aerial]

        struct Category: Decodable {
            let id: String
            let localizedNameKey: String
            let preferredOrder: Int?
            let subcategories: [Subcategory]?
        }

        struct Subcategory: Decodable {
            let id: String
            let localizedNameKey: String?
            let preferredOrder: Int?
            /// Whether its aerials are one wallpaper, with a video for Light and one for Dark
            let combineVariants: Bool?
            /// The aerial that stands for it, as Shuffle All's thumbnail has it
            let representativeAssetID: String?
        }

        struct Aerial: Decodable {
            let id: String
            let localizedNameKey: String?
            let accessibilityLabel: String?
            let categories: [String]
            let subcategories: [String]?
            /// Whether its section's row shows it, and not only Show All
            let showInTopLevel: Bool?
            /// Whether the aerials' shuffles have it
            let includeInShuffle: Bool?
            let preferredOrder: Int?
            let video: URL?
            let variant: Variant?

            enum CodingKeys: String, CodingKey {
                case id, localizedNameKey, accessibilityLabel, categories, subcategories, showInTopLevel, includeInShuffle, preferredOrder, variant
                case video = "url-4K-SDR-240FPS"
            }
        }

        struct Variant: Decodable {
            let appearance: String?
            let orientation: String?
        }
    }

    /// A wallpaper in its place in a section: System Settings puts a section's in the order each
    /// extension gives (keeping their order where that's the same), and Show All puts an aerial
    /// section's together by subcategory
    private struct Placed {
        let order: Int
        var subcategory = ""
        var subcategoryOrder = 0
        var isInRow = true
        var isShuffled = false
        let item: WallpaperItem
    }

    private init() {
        let fileManager = FileManager.default
        var downloads: [String: URL] = [:]
        if let list = NSDictionary(contentsOf: Self.downloadList), let assets = list["Assets"] as? [[String: Any]] {
            for asset in assets {
                if let id = asset["DesktopPictureID"] as? String, let base = asset["__BaseURL"] as? String, let path = asset["__RelativePath"] as? String {
                    downloads[id] = URL(string: base + path)
                }
            }
        }

        var dynamic: [Placed] = []
        var aerialItems: [String: WallpaperItem.ID] = [:]
        var aerialSections: [Section] = []
        var aerialShuffles: [(category: String, title: String, items: [WallpaperItem], thumbnails: [URL?], representative: WallpaperItem)] = []
        var pictures: [WallpaperItem] = []

        // The aerials, a section for each category, but macOS's own with the dynamic wallpapers. macOS
        // updates its list; until it has, System Settings has the one it came with.
        let aerialList = [Self.aerials.appendingPathComponent("manifest/entries.json"), Self.aerialsExtension.appendingPathComponent("entries.json")]
            .lazy.compactMap { (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(AerialList.self, from: $0) } }.first
        for category in (aerialList?.categories ?? []).sorted(by: { ($0.preferredOrder ?? 0) < ($1.preferredOrder ?? 0) }) {
            var placed: [Placed] = []
            for subcategory in category.subcategories ?? [] {
                let aerials = (aerialList?.assets ?? []).filter { $0.categories.contains(category.id) && $0.subcategories?.contains(subcategory.id) == true }
                if subcategory.combineVariants == true {
                    // One wallpaper with a video for each appearance, and for each way up a display can be
                    let variant = { (appearance: String) in
                        aerials.first { $0.variant?.appearance == appearance && $0.variant?.orientation != "portrait" }
                    }
                    guard let light = variant("light"), let dark = variant("dark"), let lightVideo = light.video, let darkVideo = dark.video else { continue }
                    let name = subcategory.localizedNameKey.map { SystemStrings.aerialName($0, english: light.accessibilityLabel ?? $0) } ?? light.accessibilityLabel ?? ""
                    // System Settings' thumbnail is the subcategory's preview, of both
                    let item = WallpaperItem(id: "aerial:\(light.id)", name: name,
                                             light: .aerial(id: light.id, video: lightVideo), dark: .aerial(id: dark.id, video: darkVideo),
                                             lightThumbnail: Self.thumbnail(ofAerial: light.id), darkThumbnail: Self.thumbnail(ofAerial: dark.id),
                                             thumbnail: Self.thumbnail(ofAerial: subcategory.id), badge: .dynamic, download: .aerials(aerials.map(\.id)))
                    placed.append(Placed(order: subcategory.preferredOrder ?? 0, subcategory: subcategory.id, item: item))
                    aerialItems[subcategory.id] = item.id
                } else {
                    for aerial in aerials {
                        guard let item = Self.item(ofAerial: aerial) else { continue }
                        placed.append(Placed(order: aerial.preferredOrder ?? 0, subcategory: subcategory.id, subcategoryOrder: subcategory.preferredOrder ?? 0,
                                             isInRow: aerial.showInTopLevel ?? true, isShuffled: aerial.includeInShuffle == true, item: item))
                        aerialItems[aerial.id] = item.id
                    }
                }
            }
            placed = Self.sorted(placed)
            if category.id == Self.dynamicAerials {
                dynamic += placed
                continue
            }
            // Show All has each subcategory's together, in the order of the first of each
            var bySubcategory: [Placed] = []
            var rest = placed
            while let first = rest.first {
                bySubcategory += rest.filter { $0.subcategory == first.subcategory }
                rest.removeAll { $0.subcategory == first.subcategory }
            }
            if !placed.isEmpty {
                let title = SystemStrings.aerialName(category.localizedNameKey, english: category.localizedNameKey)
                aerialSections.append(Section(id: category.id, title: title, items: bySubcategory.map(\.item), row: placed.filter(\.isInRow).map(\.item)))
                let shuffled = placed.filter(\.isShuffled)
                // Its shuffle's thumbnail has its first four in its subcategories' order, and Shuffle All's the
                // aerial that stands for its first subcategory, as System Settings' have
                let inSubcategoryOrder = shuffled.enumerated().sorted { ($0.element.subcategoryOrder, $0.offset) < ($1.element.subcategoryOrder, $1.offset) }.map(\.element)
                let firstSubcategory = (category.subcategories ?? []).sorted { ($0.preferredOrder ?? 0) < ($1.preferredOrder ?? 0) }
                    .first { subcategory in shuffled.contains { $0.subcategory == subcategory.id } }
                let representative = firstSubcategory?.representativeAssetID.flatMap { aerialItems[$0] }.flatMap { id in shuffled.first { $0.item.id == id } }
                if let first = representative ?? inSubcategoryOrder.first {
                    aerialShuffles.append((category.id, title, shuffled.map(\.item), inSubcategoryOrder.prefix(4).map(\.item.thumbnail), first.item))
                }
            }
        }
        // After them, a shuffle of all the aerials that shuffle, and one of each category's
        var shufflePictures: [WallpaperShuffle.ID: [WallpaperItem]] = [:]
        var shuffles: [WallpaperShuffle] = []
        let allShuffled = aerialShuffles.flatMap(\.items)
        if !allShuffled.isEmpty {
            shuffles.append(WallpaperShuffle(id: WallpaperShuffle.aerials, name: SystemStrings.shuffleAll, thumbnails: aerialShuffles.prefix(4).map(\.representative.thumbnail)))
            shufflePictures[WallpaperShuffle.aerials] = allShuffled
        }
        for category in aerialShuffles {
            let id = "shuffle:\(category.category)"
            shuffles.append(WallpaperShuffle(id: id, name: SystemStrings.shuffleCategory(category.title), thumbnails: category.thumbnails))
            shufflePictures[id] = category.items
        }
        if !shuffles.isEmpty {
            aerialSections.append(Section(id: "shuffle-aerials", title: SystemStrings.shuffleAerials, kind: .shuffles, items: [], shuffles: shuffles))
        }

        // Tahoe, Sequoia, Macintosh and Sonoma, from extensions of their own, before macOS's dynamic pictures
        let tahoe = URL(fileURLWithPath: Self.tahoeExtension).appendingPathComponent("Contents/Resources", isDirectory: true)
        let tahoeLight = tahoe.appendingPathComponent("TahoeLight.heic")
        let tahoeDark = tahoe.appendingPathComponent("TahoeDark.heic")
        if fileManager.fileExists(atPath: tahoeLight.path), fileManager.fileExists(atPath: tahoeDark.path) {
            dynamic.append(Placed(order: -400, item: WallpaperItem(id: "picture:Tahoe", name: SystemStrings.tahoe, light: .file(tahoeLight), dark: .file(tahoeDark),
                                                                   lightThumbnail: tahoeLight, darkThumbnail: tahoeDark, thumbnail: tahoe.appendingPathComponent("thumbnail.heic"),
                                                                   badge: .dynamic, download: Self.tahoeDownload)))
        }
        let sequoiaThumbnail = URL(fileURLWithPath: Self.sequoiaExtension).appendingPathComponent("Contents/Resources/thumbnail.heic")
        if fileManager.fileExists(atPath: sequoiaThumbnail.path) {
            let sequoia = WallpaperManager.DrawnWallpaper.sequoia
            dynamic.append(Placed(order: -300, item: WallpaperItem(id: sequoia.rawValue, name: sequoia.name, light: .drawn(sequoia, isDark: false), dark: .drawn(sequoia, isDark: true),
                                                                   lightThumbnail: sequoiaThumbnail, darkThumbnail: sequoiaThumbnail, thumbnail: sequoiaThumbnail, badge: .dynamic)))
        }
        if fileManager.fileExists(atPath: Self.macintoshExtension), fileManager.fileExists(atPath: Self.macintoshThumbnail.path) {
            let macintosh = WallpaperManager.DrawnWallpaper.macintosh
            dynamic.append(Placed(order: -200, item: WallpaperItem(id: macintosh.rawValue, name: macintosh.name, light: .drawn(macintosh, isDark: false), dark: .drawn(macintosh, isDark: true),
                                                                   lightThumbnail: Self.macintoshThumbnail, darkThumbnail: Self.macintoshThumbnail, thumbnail: Self.macintoshThumbnail,
                                                                   badge: .dynamic)))
        }
        let sonoma = Self.desktopPictures.appendingPathComponent("Sonoma.heic")
        if fileManager.fileExists(atPath: Self.sonomaExtension), fileManager.fileExists(atPath: sonoma.path) {
            dynamic.append(Placed(order: -100, item: Self.picture(named: "Sonoma", title: SystemStrings.sonoma, picture: .file(sonoma),
                                                                  thumbnail: Self.thumbnail(ofPicture: sonoma), badge: .dynamic)))
        }

        // macOS's pictures, in System Settings' order and named as it names them: those with a picture
        // for each appearance (or for times of day) with the dynamic wallpapers, the rest as Pictures.
        // Those it downloads once they're chosen are only there as a descriptor until it has. Sonoma's
        // has its place from its extension instead.
        let ordered = NSArray(contentsOf: Self.desktopPictures.appendingPathComponent(".orderedPictures.plist")) as? [String] ?? []
        for fileName in ordered where fileName != sonoma.lastPathComponent {
            let file = Self.desktopPictures.appendingPathComponent(fileName)
            let name = file.deletingPathExtension().lastPathComponent
            let picture: WallpaperItem.Picture
            let isDynamic: Bool
            let thumbnail: URL?
            if file.pathExtension == "madesktop" {
                guard let descriptor = NSDictionary(contentsOf: file) else { continue }
                isDynamic = descriptor["isDynamic"] as? Bool == true
                thumbnail = (descriptor["thumbnailPath"] as? String).map { URL(fileURLWithPath: $0) }
                let downloaded = Self.downloadedPictures.appendingPathComponent("\(name).heic")
                if let id = descriptor["mobileAssetID"] as? String, downloads[id] != nil {
                    picture = .download(id: id, file: downloaded)
                } else {
                    guard fileManager.fileExists(atPath: downloaded.path) else { continue }
                    picture = .file(downloaded)
                }
            } else {
                // The colours are in a folder of their own
                guard fileManager.fileExists(atPath: file.path) else { continue }
                isDynamic = Self.hasPictureForEachAppearance(file)
                picture = .file(file)
                thumbnail = Self.thumbnail(ofPicture: file)
            }
            let item = Self.picture(named: name, title: SystemStrings.desktopPictureName(name), picture: picture, thumbnail: thumbnail, badge: isDynamic ? .dynamic : nil)
            if isDynamic {
                dynamic.append(Placed(order: 0, item: item))
            } else {
                pictures.append(item)
            }
        }

        let colors = Self.colors.compactMap { name -> WallpaperItem? in
            let swatch = Self.desktopPictures.appendingPathComponent("Solid Colors", isDirectory: true).appendingPathComponent("\(name).png")
            guard fileManager.fileExists(atPath: swatch.path) else { return nil }
            let key = name.uppercased().replacingOccurrences(of: " ", with: "_")
            return WallpaperItem(id: "color:\(name)", name: SystemStrings.colorName(key, english: name),
                                 light: .color(swatch), dark: .color(swatch), lightThumbnail: swatch, darkThumbnail: swatch, thumbnail: swatch)
        }

        shufflePictures[WallpaperShuffle.colors] = colors
        // Its tile is a symbol, but System Settings shows it on the desktop as the others are shown, with
        // the second, third, fourth and sixth colours
        let colorShuffle = WallpaperShuffle(id: WallpaperShuffle.colors, name: SystemStrings.shuffle, thumbnails: [1, 2, 3, 5].map { colors.indices.contains($0) ? colors[$0].thumbnail : nil })

        var sections = [Section(id: "dynamic", title: SystemStrings.dynamicWallpapers, items: Self.sorted(dynamic).map(\.item)),
                        Section(id: Self.yourPhotos, title: SystemStrings.yourPhotos, kind: .photos, items: [])]
        sections += aerialSections
        sections += [Section(id: "pictures", title: SystemStrings.pictures, items: pictures),
                     Section(id: "colors", title: SystemStrings.colors, kind: .colors, items: colors, shuffles: [colorShuffle])]
        self.sections = sections.filter { $0.kind == .photos || !$0.items.isEmpty || !$0.shuffles.isEmpty }
        self.items = Dictionary(sections.flatMap(\.items).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.aerialItems = aerialItems
        self.downloads = downloads
        self.downloadFiles = Set(self.items.values.flatMap { $0.download?.files ?? [] })
        self.shufflePictures = shufflePictures
    }

    func item(_ id: WallpaperItem.ID) -> WallpaperItem? {
        items[id]
    }

    /// An aerial by the ID macOS's wallpaper service knows it by
    func item(ofAerial id: String) -> WallpaperItem? {
        aerialItems[id].flatMap { items[$0] }
    }

    /// One of macOS's colours by the name its wallpaper service gives it, "blueViolet" for Blue Violet
    func color(named name: String) -> WallpaperItem? {
        Self.colors.first { $0.replacingOccurrences(of: " ", with: "").lowercased() == name.lowercased() }.flatMap { items["color:\($0)"] }
    }

    /// The name of an appearance's choice: a wallpaper, a shuffle, one of the user's photos, one of the
    /// wallpapers macOS draws, or a picture of the user's own
    func name(of choice: String) -> String? {
        if let item = items[choice] ?? YourPhotos.shared.items.first(where: { $0.id == choice }) {
            return item.name
        }
        return shuffle(choice)?.name ?? PhotoSet.name(of: choice) ?? WallpaperManager.DrawnWallpaper(rawValue: choice)?.name ?? WallpaperItem.nameOfOwnPicture(choice)
    }

    /// One of the shuffles: the aerials', the colours', or Your Photos', with the newest four photos in
    /// its thumbnail once they've been read
    func shuffle(_ id: WallpaperShuffle.ID) -> WallpaperShuffle? {
        if id == WallpaperShuffle.photos {
            return YourPhotos.shared.shuffle ?? WallpaperShuffle(id: id, name: SystemStrings.yourPhotos, thumbnails: [])
        }
        return sections.lazy.flatMap(\.shuffles).first { $0.id == id }
    }

    /// The pictures a shuffle picks from. Your Photos' and a photo set's are read again each time, as
    /// they change, Your Photos' without the wallpapers Safelight made, which are already the desktop's.
    func pictures(of shuffle: WallpaperShuffle.ID) -> [WallpaperItem] {
        if PhotoSet.isSet(shuffle) {
            return PhotoSet.pictures(of: shuffle)
        }
        guard shuffle == WallpaperShuffle.photos else { return shufflePictures[shuffle] ?? [] }
        return YourPhotos.read().filter { $0.lightThumbnail != nil && !$0.id.hasSuffix("/Safelight.heic") }
    }

    /// Where Apple has one of the pictures macOS downloads once it's chosen
    func downloadURL(of id: String) -> URL? {
        downloads[id]
    }

    /// In the order each extension gave, keeping their order where that's the same
    private static func sorted(_ placed: [Placed]) -> [Placed] {
        placed.enumerated().sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }.map(\.element)
    }

    /// An aerial, as the picture of macOS's it's of when there's one, which needs no fetching
    private static func item(ofAerial aerial: AerialList.Aerial) -> WallpaperItem? {
        if let name = aerial.accessibilityLabel, case let file = desktopPictures.appendingPathComponent("\(name).heic"), FileManager.default.fileExists(atPath: file.path) {
            var item = picture(named: name, title: SystemStrings.desktopPictureName(name), picture: .file(file), thumbnail: thumbnail(ofAerial: aerial.id))
            item.badge = .video
            item.download = .aerials([aerial.id])
            return item
        }
        guard let video = aerial.video else { return nil }
        let name = aerial.localizedNameKey.map { SystemStrings.aerialName($0, english: aerial.accessibilityLabel ?? $0) } ?? aerial.accessibilityLabel ?? ""
        return WallpaperItem(id: "aerial:\(aerial.id)", name: name, light: .aerial(id: aerial.id, video: video), dark: .aerial(id: aerial.id, video: video),
                             lightThumbnail: thumbnail(ofAerial: aerial.id), darkThumbnail: thumbnail(ofAerial: aerial.id), thumbnail: thumbnail(ofAerial: aerial.id), badge: .video,
                             download: .aerials([aerial.id]))
    }

    /// One of macOS's pictures, with its thumbnail for Light and its thumbnail for Dark when it has a
    /// picture for each, from the file it's in or to download, and the one System Settings shows,
    /// `systemSettings`, which for one with a picture for each is of both
    private static func picture(named name: String, title: String, picture: WallpaperItem.Picture, thumbnail systemSettings: URL?,
                                badge: WallpaperItem.Badge? = nil) -> WallpaperItem {
        let thumbnails = desktopPictures.appendingPathComponent(".thumbnails", isDirectory: true)
        let thumbnail = { (suffix: String) -> URL? in
            let thumbnail = thumbnails.appendingPathComponent("\(name)\(suffix).heic")
            return FileManager.default.fileExists(atPath: thumbnail.path) ? thumbnail : nil
        }
        let file: URL? = if case .file(let file) = picture { file } else { nil }
        let download: WallpaperItem.Download? = if case .download(_, let file) = picture { .picture(file) } else { nil }
        return WallpaperItem(id: "picture:\(name)", name: title, light: picture, dark: picture,
                             lightThumbnail: thumbnail(" Light") ?? thumbnail("") ?? file, darkThumbnail: thumbnail(" Dark") ?? thumbnail("") ?? file,
                             thumbnail: systemSettings.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? thumbnail("") ?? file,
                             badge: badge, download: download)
    }

    /// System Settings' thumbnail of one of macOS's pictures in a file: the file of the same name with the
    /// pictures' thumbnails
    private static func thumbnail(ofPicture file: URL) -> URL {
        desktopPictures.appendingPathComponent(".thumbnails", isDirectory: true).appendingPathComponent(file.lastPathComponent)
    }

    /// Whether a picture has one for Light and one for Dark, or for times of day, as macOS's dynamic
    /// wallpapers have
    static func hasPictureForEachAppearance(_ file: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let metadata = CGImageSourceCopyMetadataAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil) else { return false }
        return ["apple_desktop:apr", "apple_desktop:solar", "apple_desktop:h24"].contains { CGImageMetadataCopyTagWithPath(metadata, nil, $0 as CFString) != nil }
    }

    /// Where macOS keeps an aerial's video once it has downloaded it
    static func downloadedVideo(ofAerial id: String) -> URL {
        aerials.appendingPathComponent("videos/\(id).mov")
    }

    /// An aerial's video that's on the Mac: the copy macOS keeps once it's downloaded it, or else the
    /// one it comes with
    static func videoOnMac(ofAerial id: String) -> URL? {
        let downloaded = downloadedVideo(ofAerial: id)
        return FileManager.default.isReadableFile(atPath: downloaded.path) ? downloaded : shippedVideo(ofAerial: id)
    }

    /// The video macOS comes with of an aerial: Golden Gate Sunset's, its default wallpaper, which the
    /// aerials' extension plays until it has downloaded its own
    static func shippedVideo(ofAerial id: String) -> URL? {
        id == goldenGateSunset && FileManager.default.fileExists(atPath: goldenGateSunsetVideo.path) ? goldenGateSunsetVideo : nil
    }

    private static let goldenGateSunset = "4207734D-74FE-4F92-B5E1-6EC8DEE24A15"
    private static let goldenGateSunsetVideo = URL(fileURLWithPath: "/System/Library/Wallpapers/.default/Golden Gate.mov")

    /// Tahoe's videos, which its extension downloads into its container, named by its manifest's
    /// identifier, once Tahoe is chosen
    private static let tahoeDownload: WallpaperItem.Download = {
        let videos = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.apple.NeptuneOneExtension/Data/Library/Application Support/Videos", isDirectory: true)
        let manifest = URL(fileURLWithPath: tahoeExtension).appendingPathComponent("Contents/Resources/manifest.json")
        let identifier = (try? Data(contentsOf: manifest)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["identifier"] as? String ?? "Tahoe"
        let video = { (name: String) in videos.appendingPathComponent("\(identifier) \(name).mov") }
        return .tahoe(landscape: [video("Light Landscape"), video("Dark Landscape")], portrait: [video("Light Portrait"), video("Dark Portrait")])
    }()

    /// An aerial's thumbnail, or a subcategory's preview, from macOS's list, or from System Settings for
    /// those it came with
    private static func thumbnail(ofAerial id: String) -> URL? {
        [aerials.appendingPathComponent("thumbnails/\(id).png"), aerialsExtension.appendingPathComponent("\(id).png")]
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// System Settings › Wallpaper's Your Photos: the pictures of the user's own it has been given, from its
/// Add Photo… or as an app's wallpaper, newest first. Its image extension keeps the list, and a copy of
/// each picture, in its container, so reading them is reading another app's data, which macOS asks the
/// user about the first time; it's read when the Wallpaper window opens, where that question makes sense.
final class YourPhotos: ObservableObject {
    static let shared = YourPhotos()
    @Published private(set) var items: [WallpaperItem] = []

    private static let list = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/com.apple.wallpaper.extension.image/Data/Library/Preferences/com.apple.wallpaper.extension.image.plist")

    /// One of the list's pictures, as the extension writes it
    private struct ImageFile: Decodable {
        let dateAdded: Date
        let originalURL: URL
        let originalURLBookmarkData: Data?
        /// The extension's copy, which is there after the picture itself is moved or gone
        let copyURL: URL?
    }

    /// The extension's preferences, which hold the list. System Settings has them from macOS's preferences
    /// service as soon as they change, and their file is written a few seconds later.
    private static let preferences = list.deletingPathExtension().path as CFString
    private static let key = "ChoiceRequests.ImageFiles"

    /// Where the list is read, and watched, one read after another, so the last one shown is the latest
    private let queue = DispatchQueue(label: "Safelight.YourPhotos", qos: .userInitiated)
    private var watcher: DispatchSourceFileSystemObject?
    /// The list as last read, on `queue`; nil until the Wallpaper window has read it
    private var lastRead: [WallpaperItem]?

    /// Reads the list again, and from then on whenever the extension's preferences are written, which is
    /// how a picture added in System Settings shows up here
    func reload() {
        queue.async {
            self.watchList()
            self.update()
        }
    }

    /// Shows the wallpaper Safelight has just set once System Settings has added it, which is a moment
    /// later (a third of a second, with a shuffle's picture): until then the list's newest is the
    /// wallpaper before, which Safelight has taken away. Nothing tells when, so the list is read every
    /// so often until it has changed, for a few seconds at most.
    func reloadAfterSettingWallpaper() {
        queue.async {
            guard let before = self.lastRead else { return }
            self.update(untilChangedFrom: before, attempts: 20)
        }
    }

    private func update(untilChangedFrom before: [WallpaperItem]? = nil, attempts: Int = 1) {
        let items = Self.read()
        lastRead = items
        DispatchQueue.main.async {
            if items != self.items {
                self.items = items
            }
        }
        if let before, items == before, attempts > 1 {
            queue.asyncAfter(deadline: .now() + 0.25) {
                self.update(untilChangedFrom: before, attempts: attempts - 1)
            }
        }
    }

    /// The preferences are written to a new file that takes the old one's place, in their folder, so it's
    /// the folder that's watched
    private func watchList() {
        guard watcher == nil else { return }
        let descriptor = open(Self.list.deletingLastPathComponent().path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: queue)
        watcher.setEventHandler { [weak self] in
            self?.reload()
        }
        watcher.setCancelHandler {
            close(descriptor)
        }
        watcher.resume()
        self.watcher = watcher
    }

    /// Its shuffle of them all, first of them, as System Settings has once there are two to shuffle,
    /// with the newest four in its thumbnail
    var shuffle: WallpaperShuffle? {
        guard items.count >= 2 else { return nil }
        return WallpaperShuffle(id: WallpaperShuffle.photos, name: SystemStrings.yourPhotos, thumbnails: items.prefix(4).map(\.thumbnail))
    }

    /// The list as System Settings has it, from the preferences service, or else from its file
    static func read() -> [WallpaperItem] {
        CFPreferencesAppSynchronize(preferences)
        guard let entries = CFPreferencesCopyAppValue(key as CFString, preferences) as? [Data]
                ?? (try? Data(contentsOf: list)).flatMap({ try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] })?[key] as? [Data]
        else { return [] }
        let files = entries.compactMap { try? PropertyListDecoder().decode(ImageFile.self, from: $0) }
        // Newest first, to the second, and those added in the same second in the list's order
        let newestFirst = files.enumerated().sorted { (-Int($0.element.dateAdded.timeIntervalSinceReferenceDate), $0.offset) < (-Int($1.element.dateAdded.timeIntervalSinceReferenceDate), $1.offset) }.map(\.element)
        return newestFirst.map { file in
            let name = file.originalURL.deletingPathExtension().lastPathComponent
            // Where System Settings loads it from: its copy, or else the picture itself, wherever it's been
            // moved to. With neither, its thumbnail is an iCloud symbol, as System Settings draws it.
            let bookmarked = file.originalURLBookmarkData.flatMap { bookmark in
                var isStale = false
                return try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &isStale)
            }
            guard let picture = [file.copyURL, bookmarked, file.originalURL].lazy.compactMap({ $0 }).first(where: { (try? $0.checkResourceIsReachable()) == true }) else {
                return WallpaperItem(id: "photo:\(file.originalURL.path)", name: name, light: .file(file.originalURL), dark: .file(file.originalURL),
                                     lightThumbnail: nil, darkThumbnail: nil, thumbnail: nil)
            }
            return WallpaperItem(id: "photo:\(file.originalURL.path)", name: name, light: .file(picture), dark: .file(picture),
                                 lightThumbnail: picture, darkThumbnail: picture, thumbnail: picture,
                                 badge: WallpaperLibrary.hasPictureForEachAppearance(picture) ? .dynamic : nil)
        }
    }
}

/// System Settings › Wallpaper's photo sets, which its Add Photo… shuffles: a folder's pictures, or the
/// photos of one of the Photos library's albums (Favourites is one). System Settings has its people
/// too, but Photos only gives people to Apple's own apps. A set's shuffle is known by its ID:
/// `set:folder:` and the folder's path, or `set:album:` and the album's ID in the library.
enum PhotoSet {
    private static let folderPrefix = "set:folder:"
    private static let albumPrefix = "set:album:"

    static func isSet(_ id: WallpaperShuffle.ID) -> Bool {
        id.hasPrefix(folderPrefix) || id.hasPrefix(albumPrefix)
    }

    static func shuffle(ofFolder folder: URL) -> WallpaperShuffle {
        WallpaperShuffle(id: folderPrefix + folder.path, name: FileManager.default.displayName(atPath: folder.path), thumbnails: [])
    }

    static func shuffle(of album: PHAssetCollection) -> WallpaperShuffle {
        WallpaperShuffle(id: albumPrefix + album.localIdentifier, name: name(of: album), thumbnails: [])
    }

    /// A set's name, as Add Photo… lists it, while it's there
    static func name(of id: WallpaperShuffle.ID) -> String? {
        if id.hasPrefix(folderPrefix) {
            return FileManager.default.displayName(atPath: String(id.dropFirst(folderPrefix.count)))
        }
        return album(id).map(name(of:))
    }

    private static func name(of album: PHAssetCollection) -> String {
        album.assetCollectionSubtype == .smartAlbumFavorites ? SystemStrings.favorites : album.localizedTitle ?? ""
    }

    /// The pictures a set's shuffle picks from, read again each time, as they change: those in a folder
    /// itself, not in folders in it, nor hidden, which are pictures by their names' extensions, as
    /// System Settings takes them, or an album's photos, but not its videos
    static func pictures(of id: WallpaperShuffle.ID) -> [WallpaperItem] {
        if id.hasPrefix(folderPrefix) {
            let folder = URL(fileURLWithPath: String(id.dropFirst(folderPrefix.count)), isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
            return files.filter { file in
                UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true && (try? file.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true
            }.map { file in
                WallpaperItem(id: "photo:\(file.path)", name: file.deletingPathExtension().lastPathComponent, light: .file(file), dark: .file(file),
                              lightThumbnail: file, darkThumbnail: file, thumbnail: file)
            }
        }
        guard let album = album(id) else { return [] }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let assets = PHAsset.fetchAssets(in: album, options: options)
        return assets.objects(at: IndexSet(integersIn: 0..<assets.count)).map { asset in
            WallpaperItem(id: "asset:\(asset.localIdentifier)", name: "", light: .asset(asset.localIdentifier), dark: .asset(asset.localIdentifier),
                          lightThumbnail: nil, darkThumbnail: nil, thumbnail: nil)
        }
    }

    private static func album(_ id: WallpaperShuffle.ID) -> PHAssetCollection? {
        guard id.hasPrefix(albumPrefix), PhotoLibrarySets.mayRead else { return nil }
        return PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [String(id.dropFirst(albumPrefix.count))], options: nil).firstObject
    }
}

/// The Photos library's sets, as System Settings › Wallpaper's Add Photo… lists them, read as its
/// Wallpaper extension reads them: Favourites, while it has anything in it, then the shared albums and
/// the others, in the library's order
final class PhotoLibrarySets: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    static let shared = PhotoLibrarySets()

    struct Lists: Equatable {
        var favorites: WallpaperShuffle?
        var sharedAlbums: [WallpaperShuffle] = []
        var albums: [WallpaperShuffle] = []
    }

    @Published private(set) var lists = Lists()
    /// Where they're read, one read after another, so the last one shown is the latest
    private let queue = DispatchQueue(label: "Safelight.PhotoSets", qos: .userInitiated)
    private var isObserving = false

    /// Whether Safelight may read the library, which it asks for only from Add Photo…
    static var mayRead: Bool {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
    }

    /// Asks to read the library, as System Settings does, the first time, then lists its sets, and
    /// from then on whenever it changes
    @MainActor
    func load() async {
        if !Self.mayRead {
            guard await PHPhotoLibrary.requestAuthorization(for: .readWrite) == .authorized else { return }
        }
        if !isObserving {
            isObserving = true
            PHPhotoLibrary.shared().register(self)
        }
        reload()
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        reload()
    }

    private func reload() {
        queue.async {
            let lists = Self.read()
            DispatchQueue.main.async {
                if lists != self.lists {
                    self.lists = lists
                }
            }
        }
    }

    private static func read() -> Lists {
        var lists = Lists()
        if let favorites = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumFavorites, options: nil).firstObject {
            let options = PHFetchOptions()
            options.fetchLimit = 1
            if PHAsset.fetchAssets(in: favorites, options: options).count > 0 {
                lists.favorites = PhotoSet.shuffle(of: favorites)
            }
        }
        func albums(_ subtype: PHAssetCollectionSubtype) -> [WallpaperShuffle] {
            let found = PHAssetCollection.fetchAssetCollections(with: .album, subtype: subtype, options: nil)
            return found.objects(at: IndexSet(integersIn: 0..<found.count)).map(PhotoSet.shuffle(of:))
        }
        lists.sharedAlbums = albums(.albumCloudShared)
        lists.albums = albums(.albumRegular)
        return lists
    }
}

// MARK: - 10. System Strings (System Settings' Translations)
/// Every label in the app, read from the string tables System Settings (or Control Center, the Dock,
/// or an app's menus) loads the same label from, so it comes out in the system language, worded
/// exactly as there.
/// Each keeps its English text as a fallback in case a table ever moves or drops the key.
enum SystemStrings {
    private static let accessibilitySettings = "/System/Library/ExtensionKit/Extensions/AccessibilitySettingsExtension.appex"
    private static let displaysSettings = "/System/Library/ExtensionKit/Extensions/DisplaysExt.appex"
    private static let controlCenterSettings = "/System/Library/ExtensionKit/Extensions/ControlCenterSettings.appex"
    /// Where `AppearancePicker` finds its thumbnails as well.
    static let appearanceSettings = "/System/Library/ExtensionKit/Extensions/Appearance.appex"
    private static let wallpaperSettings = "/System/Library/ExtensionKit/Extensions/Wallpaper.appex"
    private static let dynamicWallpaperSettings = "/System/Library/ExtensionKit/Extensions/WallpaperDynamicExtension.appex"
    private static let imageWallpaperSettings = "/System/Library/ExtensionKit/Extensions/WallpaperImageExtension.appex"
    private static let colorWallpaperSettings = "/System/Library/ExtensionKit/Extensions/WallpaperGradientExtension.appex"
    private static let aerialWallpaperSettings = "/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex"
    private static let desktopPictureNames = "/System/Library/PrivateFrameworks/SystemDesktopAppearance.framework"
    /// The aerials' names come with macOS's list of them, which it updates, and with System Settings
    private static let aerialNames = [WallpaperLibrary.aerials.appendingPathComponent("manifest/TVIdleScreenStrings.bundle").path,
                                      "/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex/Contents/Resources/TVIdleScreenStrings.bundle"]
        .first { FileManager.default.fileExists(atPath: $0) }
    private static let swiftUI = "/System/Library/Frameworks/SwiftUI.framework"
    private static let controlCenter = "/System/Library/CoreServices/ControlCenter.app"
    private static let dock = "/System/Library/CoreServices/Dock.app"
    private static let softwareUpdateSettings = "/System/Library/ExtensionKit/Extensions/SoftwareUpdateSettingsExtension.appex"
    private static let maps = "/System/Applications/Maps.app"
    private static let linkPresentation = "/System/Library/Frameworks/LinkPresentation.framework"
    
    // System Settings › Accessibility › Display › Color Filters
    static let colorFilters = lookup("display.colorFilter.enable", in: accessibilitySettings, english: "Color filters")
    static let intensity = lookup("display.colorFilter.intensity", in: accessibilitySettings, english: "Intensity")
    static let low = lookup("display.colorFilter.intensity.low", in: accessibilitySettings, english: "Low")
    static let high = lookup("display.colorFilter.intensity.high", in: accessibilitySettings, english: "High")
    static let tint = lookup("display.colorFilter.tint", in: accessibilitySettings, english: "Tint")
    
    // System Settings › Accessibility › Hearing Devices' switch for setting each hearing aid by itself,
    // in sentence case, as System Settings labels a switch (Color filters), though its table has it in
    // title case, in English and in the translations that followed it (Indonesian, Malay, Portuguese, Turkish)
    static let adjustIndependently = lookup("mfi.hearingaids.adjust.independently.toggle.title", in: accessibilitySettings, english: "Adjust independently", sentenceCased: true)
    
    // System Settings › Displays (Schedule is Night Shift's)
    static let brightness = lookup("Brightness", in: displaysSettings, english: "Brightness")
    static let schedule = lookup("Schedule", in: displaysSettings, english: "Schedule")
    static let customize = lookup("Customize…", in: displaysSettings, english: "Customize…")

    // System Settings › Appearance
    static let appearance = lookup("Appearance", in: appearanceSettings, english: "Appearance")
    static let light = lookup("Light", in: appearanceSettings, english: "Light")
    static let dark = lookup("Dark", in: appearanceSettings, english: "Dark")

    // System Settings › Wallpaper, its buttons for choosing a picture of your own, its sections' Show
    // All and Show Less, and its menu item for taking a downloaded wallpaper off the Mac
    static let wallpaper = lookup("WALLPAPER", in: wallpaperSettings, english: "Wallpaper")
    static let addPhoto = lookup("ADD_PHOTO", in: wallpaperSettings, english: "Add Photo…")
    static let chooseFromPhotos = lookup("CHOOSE_FROM_PHOTOS", in: wallpaperSettings, english: "Choose from Photos…")
    static let chooseFile = lookup("CHOOSE_FILE", in: wallpaperSettings, english: "Choose File…")
    static let singlePhoto = lookup("SINGLE_PHOTO", in: wallpaperSettings, english: "Single Photo")
    static let photoSets = lookup("PHOTO_SETS", in: wallpaperSettings, english: "Photo Sets")
    static let chooseFolder = lookup("CHOOSE_FOLDER", in: wallpaperSettings, english: "Choose Folder…")
    static let favorites = lookup("FAVORITES", in: wallpaperSettings, english: "Favorites")
    static let showAll = lookup("SHOW_ALL_%@", in: wallpaperSettings, english: "Show All (%@)")
    static let showLess = lookup("SHOW_LESS", in: wallpaperSettings, english: "Show Less")
    static let removeDownload = lookup("REMOVE_DOWNLOAD", in: wallpaperSettings, english: "Remove Download")

    // System Settings › Wallpaper's sections, besides the aerials' (whose names come with them), and
    // the names of its colours and its aerials
    static let dynamicWallpapers = lookup("DYNAMIC_WALLPAPERS", in: dynamicWallpaperSettings, english: "Dynamic Wallpapers")
    static let yourPhotos = lookup("YOUR_PHOTOS", in: imageWallpaperSettings, english: "Your Photos")
    static let pictures = lookup("PICTURES", in: imageWallpaperSettings, english: "Pictures")
    static let colors = lookup("COLORS", in: colorWallpaperSettings, english: "Colors")

    // System Settings › Wallpaper's shuffles, and how often each can change its picture: the aerials'
    // every so many hours or days, the others' every so many minutes, at login or on waking
    static let shuffle = lookup("SHUFFLE_LABEL", in: imageWallpaperSettings, english: "Shuffle")
    static let shuffleAerials = lookup("SHUFFLE_AERIALS", in: aerialWallpaperSettings, english: "Shuffle Aerials")
    static let shuffleAll = lookup("SHUFFLE_ALL", in: aerialWallpaperSettings, english: "Shuffle All")

    static func shuffleCategory(_ category: String) -> String {
        String(format: lookup("SHUFFLE_CATEGORY_PREFIX_(%@)", in: aerialWallpaperSettings, english: "Shuffle %@"), category)
    }

    static func shuffleInterval(_ interval: WallpaperShuffle.Interval) -> String {
        switch interval {
        case .minute: lookup("SHUFFLE_OPTION_1_MINUTE", in: imageWallpaperSettings, english: "Every Minute")
        case .fiveMinutes: lookup("SHUFFLE_OPTION_5_MINUTES", in: imageWallpaperSettings, english: "Every 5 Minutes")
        case .fifteenMinutes: lookup("SHUFFLE_OPTION_15_MINUTES", in: imageWallpaperSettings, english: "Every 15 Minutes")
        case .thirtyMinutes: lookup("SHUFFLE_OPTION_30_MINUTES", in: imageWallpaperSettings, english: "Every 30 Minutes")
        case .hour: lookup("SHUFFLE_OPTION_1_HOUR", in: imageWallpaperSettings, english: "Every Hour")
        case .twelveHours: lookup("SHUFFLE_OPTION_12H", in: aerialWallpaperSettings, english: "Every 12 Hours")
        case .day: lookup("SHUFFLE_OPTION_1_DAY", in: imageWallpaperSettings, english: "Every Day")
        case .twoDays: lookup("SHUFFLE_OPTION_2D", in: aerialWallpaperSettings, english: "Every 2 Days")
        case .week: lookup("SHUFFLE_OPTION_1W", in: aerialWallpaperSettings, english: "Every Week")
        case .month: lookup("SHUFFLE_OPTION_1M", in: aerialWallpaperSettings, english: "Every Month")
        case .login: lookup("SHUFFLE_OPTION_ON_LOGIN", in: imageWallpaperSettings, english: "On Login")
        case .wake: lookup("SHUFFLE_OPTION_ON_WAKEUP", in: imageWallpaperSettings, english: "On Wakeup")
        }
    }
    static let customColor = lookup("CUSTOM_COLOR", in: colorWallpaperSettings, english: "Custom Color")

    // System Settings › Wallpaper's Show on all Spaces, and its options for a wallpaper: how a picture
    // is placed on the display, with the colour around it, which picture one with a picture for each
    // appearance shows, whether a colour is a gradient, and Macintosh's colours
    static let showOnAllSpaces = lookup("SHOW_ON_ALL_SPACES", in: wallpaperSettings, english: "Show on all Spaces")
    // ...and its name for a built-in display, in its pop-up for the display whose wallpaper it shows
    static let builtInDisplay = lookup("BUILT_IN_DISPLAY", in: wallpaperSettings, english: "Built-in Display")
    static let picture = lookup("PICTURE_LABEL", in: imageWallpaperSettings, english: "Picture")
    static let fillColor = lookup("COLOR_LABEL", in: imageWallpaperSettings, english: "Color")
    static let gradient = lookup("GRADIENT", in: colorWallpaperSettings, english: "Gradient")
    static let macintoshColor = lookup("MACINTOSH_COLOR_LABEL", in: WallpaperLibrary.macintoshExtension, english: "Color")

    static func placement(_ kind: WallpaperManager.Placement.Kind) -> String {
        switch kind {
        case .fill: lookup("FILL_SCREEN", in: imageWallpaperSettings, english: "Fill Screen")
        case .fit: lookup("FIT_TO_SCREEN", in: imageWallpaperSettings, english: "Fit to Screen")
        case .stretch: lookup("STRETCH_TO_FILL_SCREEN", in: imageWallpaperSettings, english: "Stretch to Fill Screen")
        case .center: lookup("CENTER", in: imageWallpaperSettings, english: "Center")
        }
    }

    /// A choice of which picture a wallpaper with one for each appearance shows, as the extension that
    /// gives System Settings the wallpaper names it: Sequoia's, Sonoma's, Tahoe's and Macintosh's each
    /// their own way, an aerial's Automatic its own way (and its Light and Dark as the Appearance pane
    /// does), and macOS's pictures' Light and Dark as stills
    static func appearanceOption(_ option: WallpaperManager.AppearanceOption, of item: WallpaperItem.ID) -> String {
        let english = ["automatic": "Automatic", "light": "Light", "dark": "Dark"][option.rawValue] ?? option.rawValue
        let key = option.rawValue.uppercased()
        switch item {
        case WallpaperManager.DrawnWallpaper.sequoia.rawValue:
            return lookup("APPEARANCE_\(key)", in: WallpaperLibrary.sequoiaExtension, english: english)
        case "picture:Sonoma":
            return lookup("DYNAMIC_TYPE_\(key)", in: WallpaperLibrary.sonomaExtension, english: english)
        case "picture:Tahoe":
            return lookup("DYNAMIC_TYPE_\(key)", in: WallpaperLibrary.tahoeExtension, english: english)
        case WallpaperManager.DrawnWallpaper.macintosh.rawValue:
            return lookup("DYNAMIC_TYPE_\(key)", in: WallpaperLibrary.macintoshExtension, english: english)
        case _ where item.hasPrefix("aerial:"):
            switch option {
            case .automatic: return lookup("AERIAL_VARIANT_AUTOMATIC", in: aerialWallpaperSettings, english: english)
            case .light: return light
            case .dark: return dark
            }
        default:
            switch option {
            case .automatic: return lookup("AUTOMATIC", in: dynamicWallpaperSettings, english: english)
            case .light: return lookup("LIGHT_STILL", in: dynamicWallpaperSettings, english: "Light (Still)")
            case .dark: return lookup("DARK_STILL", in: dynamicWallpaperSettings, english: "Dark (Still)")
            }
        }
    }

    /// One of Macintosh's colour schemes, by its ID, whose key is its ID in capitals, a word apart
    static func macintoshColors(_ id: String) -> String {
        let english = ["random": "Random", "spectrum": "Spectrum", "accent": "Accent", "gray": "Gray", "darkGray": "Dark Gray", "green": "Green",
                       "yellow": "Yellow", "orange": "Orange", "red": "Red", "purple": "Purple", "blue": "Blue"][id] ?? id
        return lookup("MACINTOSH_COLOR_" + english.uppercased().replacingOccurrences(of: " ", with: "_"), in: WallpaperLibrary.macintoshExtension, english: english)
    }

    // The names of macOS's pictures, and of Tahoe and Sonoma, whose extensions System Settings has them from
    static let tahoe = lookup("SETTINGS_LABEL_ONE", in: WallpaperLibrary.tahoeExtension, english: "Tahoe")
    static let sonoma = lookup("SONOMA_LABEL", in: WallpaperLibrary.sonomaExtension, english: "Sonoma")
    static let sequoia = lookup("SEQUOIA_LABEL", in: WallpaperLibrary.sequoiaExtension, english: "Sequoia")
    static let macintosh = lookup("MACINTOSH_LABEL", in: WallpaperLibrary.macintoshExtension, english: "Macintosh")

    static func desktopPictureName(_ key: String) -> String {
        lookup(key, table: "Desktop Pictures", in: desktopPictureNames, english: key)
    }

    static func colorName(_ key: String, english: String) -> String {
        lookup(key, in: colorWallpaperSettings, english: english)
    }

    static func aerialName(_ key: String, english: String) -> String {
        aerialNames.map { lookup(key, table: "Localizable.nocache", in: $0, english: english) } ?? english
    }

    // System Settings › Accessibility's buttons for lists, and System Settings › Control Center's Time
    static let add = lookup("global.button.add", in: accessibilitySettings, english: "Add")
    static let delete = lookup("global.button.delete", in: accessibilitySettings, english: "Delete")
    static let restoreDefaults = lookup("keyboard.access.restoreDefaults", in: accessibilitySettings, english: "Restore Defaults")
    static let time = lookup("Time", in: controlCenterSettings, english: "Time")

    // The title of Control Center's Display module, which this popover stands in for
    static let display = lookup("Display", table: "Display", in: controlCenter, english: "Display")
    
    // System Settings › Control Center's Reset button
    static let reset = lookup("Reset", in: controlCenterSettings, english: "Reset")
    
    // The status item's menu, under the name of the Dock's Options menu, which has Open at Login in it;
    // and the app menu's About and Quit items
    static let options = lookup("OPTIONS", table: "DockMenus", in: dock, english: "Options")
    static let openAtLogin = lookup("OPEN_AT_LOGIN", table: "DockMenus", in: dock, english: "Open at Login")
    static let aboutApp = String(format: lookup("About %@", table: "MainMenu", in: swiftUI, english: "About %@"), appName)
    static let quitApp = String(format: lookup("Quit %@", table: "MainMenu", in: swiftUI, english: "Quit %@"), appName)
    // ...and System Settings › General › Software Update's Automatic Updates and Check for Updates,
    // the second with an ellipsis, as it opens a window
    static let automaticUpdates = lookup("Automatic Updates", in: softwareUpdateSettings, english: "Automatic Updates")
    static let checkForUpdates = lookup("Check for Updates", in: softwareUpdateSettings, english: "Check for Updates") + "…"
    
    // The About panel's links: what a link preview calls a source code file, and Maps' Report an Issue
    static let sourceCode = lookup("Source Code (file type)", in: linkPresentation, english: "Source Code")
    static let reportAnIssue = lookup("Report an Issue", in: maps, english: "Report an Issue")
    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Safelight"
    }
    
    /// The user's preferred languages. This app has no translations of its own, so a plain
    /// `localizedString` lookup would follow the app into English; asking with these picks each
    /// table's closest match the way System Settings does (e.g. French (Canada) before French).
    private static let languages = Locale.preferredLanguages.map(Locale.Language.init(identifier:))
    
    private static func lookup(_ key: String, table: String = "Localizable", in bundlePath: String, english: String, sentenceCased: Bool = false) -> String {
        guard let bundle = Bundle(path: bundlePath) else { return english }
        let label = bundle.localizedString(forKey: key, value: english, table: table, localizations: languages)
        guard sentenceCased, label != english,
              let localization = Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: Locale.preferredLanguages).first
        else { return label }
        return sentenceCase(label, in: Locale(identifier: localization))
    }

    /// `label` with each word after the first lowercased, in `locale`'s way (Turkish's dotless ı), as
    /// System Settings capitalizes a switch's label. Acronyms and names like iPhone keep their capitals,
    /// and German, which capitalizes its nouns, keeps Apple's wording as it is.
    private static func sentenceCase(_ label: String, in locale: Locale) -> String {
        guard locale.language.languageCode != .german else { return label }
        let words = label.split(separator: " ", omittingEmptySubsequences: false)
        return ([String(words[0])] + words.dropFirst().map { word in
            guard let first = word.first, first.isUppercase, !word.dropFirst().contains(where: \.isUppercase) else { return String(word) }
            return String(first).lowercased(with: locale) + word.dropFirst()
        }).joined(separator: " ")
    }
}
