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
import PhotosUI
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
                // The wallpaper may have been changed in System Settings since
                WallpaperManager.shared.refresh()
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Ensure software dimming is cleared when the app is force-quit
        GammaManager.shared.reset()
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
/// empty frame with a + in it. Disabled, from when a picture is chosen until it's on the desktop, it dims.
struct WallpaperPicker: View {
    @ObservedObject var wallpaper = WallpaperManager.shared
    let choosePicture: (_ isDark: Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            option(SystemStrings.light, picture: wallpaper.thumbnails?.light, isDark: false)
            option(SystemStrings.dark, picture: wallpaper.thumbnails?.dark, isDark: true)
        }
        .disabled(wallpaper.isChanging)
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

    /// Opens the Colours panel for any colour, as System Settings › Wallpaper's custom colour does
    func chooseColor() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.orderFront(nil)
    }

    private var colorChange: DispatchWorkItem?

    /// Makes a wallpaper in the colour once it's been left alone for a moment, as the panel sends every
    /// colour it passes through while one is dragged to, and each wallpaper takes a moment to make
    @objc private func colorChanged(_ panel: NSColorPanel) {
        colorChange?.cancel()
        let color = panel.color
        let isDark = isDark
        let change = DispatchWorkItem { [weak self] in
            if WallpaperManager.shared.isChanging {
                self?.colorChanged(panel)
            } else {
                WallpaperManager.shared.setColor(color, isDark: isDark)
            }
        }
        colorChange = change
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: change)
    }
}

/// The Wallpaper window's contents, laid out the way System Settings › Wallpaper's own code lays out its
/// pane, with its measures. Above, the wallpaper's pictures for Light and for Dark, with a ring around
/// the one being chosen. Under them, scrolling, System Settings' sections: each a row of its wallpapers
/// that scrolls sideways, until Show All shows them all, four to a row (eight colours to a row). Each
/// wallpaper's thumbnail is of its picture for the appearance being chosen, as some have one of each,
/// and the ring is around the one the desktop has.
struct WallpaperGallery: View {
    @ObservedObject var wallpaper = WallpaperManager.shared
    @ObservedObject var window = WallpaperWindow.shared
    @ObservedObject var photos = YourPhotos.shared
    @ObservedObject var shuffler = WallpaperShuffler.shared
    /// The sections showing all their wallpapers, not only a row
    @State private var expandedSections: Set<String> = []
    @State private var isChoosingPhoto = false
    @State private var photo: PhotosPickerItem?

    /// System Settings' pane: its width, its margins, and the room between its sections, and between
    /// a section's title and its thumbnails, and between thumbnails. Its scroll bar is over its sections
    /// even when scroll bars are always shown; here it's beside them, so they're laid out the same.
    private static let width: CGFloat = 508 + (NSScroller.preferredScrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0)
    private static let margin: CGFloat = 20
    private static let sectionSpacing: CGFloat = 20
    private static let spacing: CGFloat = 10
    /// Its thumbnails, four to a row, and its colours, eight to a row
    private static let thumbnailSize = CGSize(width: 107.5, height: 71)
    private static let colorSize: CGFloat = 48.75
    private static let thumbnailCornerRadius: CGFloat = 4
    private static let previewSize = CGSize(width: 160, height: 100)
    private static let previewCornerRadius: CGFloat = 8
    /// Where a preview has room for the ring around it, as the Appearance picker's thumbnails do
    private static let ringPadding: CGFloat = 3.5

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 24) {
                    preview(SystemStrings.light, picture: wallpaper.thumbnails?.light, isDark: false)
                    preview(SystemStrings.dark, picture: wallpaper.thumbnails?.dark, isDark: true)
                }
                shuffleInterval
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                    ForEach(WallpaperLibrary.shared.sections) { section in
                        group(section)
                            // Until a picture chosen is on the desktop, as only one can be made at a time
                            .disabled(wallpaper.isChanging)
                    }
                }
                .padding(Self.margin)
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
    }

    /// The wallpaper's picture for Light or for Dark, the size of System Settings' picture of the
    /// desktop, ringed while it's the one being chosen, as the Appearance picker's thumbnails are.
    /// Clicking it chooses it instead.
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
                    if wallpaper.isChanging && wallpaper.changingIsDark == isDark {
                        ZStack {
                            Rectangle()
                                .fill(.black.opacity(0.35))
                            progress
                        }
                        .colorScheme(.dark)
                    }
                }
                .frame(width: Self.previewSize.width, height: Self.previewSize.height)
                .clipShape(RoundedRectangle(cornerRadius: Self.previewCornerRadius))
                .padding(Self.ringPadding)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: Self.previewCornerRadius + Self.ringPadding)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
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

    /// How often the appearance being chosen changes its picture, while it's a shuffle's, as System
    /// Settings shows beside a shuffle. Its room is kept while there's none, so the window doesn't move.
    private var shuffleInterval: some View {
        let shuffle = shuffler.shuffle(isDark: window.isDark)
        let interval = Binding {
            shuffle?.interval ?? .hour
        } set: {
            shuffler.setInterval($0, isDark: window.isDark)
        }
        return Picker(SystemStrings.shuffle, selection: interval) {
            ForEach(WallpaperShuffle.intervals(for: shuffle?.id ?? WallpaperShuffle.photos), id: \.self) { interval in
                Text(interval.title)
                    .tag(interval)
            }
        }
        .fixedSize()
        .opacity(shuffle == nil ? 0 : 1)
        .disabled(shuffle == nil)
        .accessibilityHidden(shuffle == nil)
    }

    /// A section: its title, with Show All beside it when there's more than a row, and a row of its
    /// wallpapers that scrolls sideways, or all of them
    private func group(_ section: WallpaperLibrary.Section) -> some View {
        let isExpanded = expandedSections.contains(section.id)
        let columns = section.kind == .colors ? 8 : 4
        let items = section.kind == .photos ? photos.items : section.items
        let shuffles = section.kind == .photos ? Array(photos.shuffle.map { [$0] } ?? []) : section.shuffles
        // Add Photo… and the custom colour count as one of the section's
        let count = shuffles.count + items.count + (section.kind == .photos || section.kind == .colors ? 1 : 0)
        return VStack(alignment: .leading, spacing: Self.spacing) {
            HStack(spacing: Self.spacing) {
                Text(section.title)
                    .fontWeight(.medium)
                Spacer()
                if count > columns || section.row.map({ $0.count < items.count }) == true {
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
            .fixedSize(horizontal: false, vertical: true)
            if isExpanded {
                let width = section.kind == .colors ? Self.colorSize : Self.thumbnailSize.width
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: Self.spacing), count: columns), alignment: .leading, spacing: Self.spacing) {
                    self.items(of: section, shuffles, items)
                }
            } else {
                // The width of the window, scrolling under its margins
                ScrollView(.horizontal) {
                    LazyHStack(spacing: Self.spacing) {
                        self.items(of: section, shuffles, section.row ?? items)
                    }
                    .scrollTargetLayout()
                }
                .padding(.horizontal, -Self.margin)
                .contentMargins(.horizontal, Self.margin, for: .automatic)
                .scrollClipDisabled()
                .scrollIndicators(.never)
            }
        }
        // Where the other sections have their wallpapers' names
        .padding(.bottom, section.kind == .pictures || section.kind == .shuffles ? 0 : 10)
    }

    /// A section's tiles, in System Settings' order: Add Photo… and then the photos' shuffle, or the
    /// colours' shuffle and then the custom colour, before the wallpapers
    @ViewBuilder
    private func items(of section: WallpaperLibrary.Section, _ shuffles: [WallpaperShuffle], _ items: [WallpaperItem]) -> some View {
        switch section.kind {
        case .pictures:
            ForEach(items) { item in
                thumbnail(item, showsName: true)
            }
        case .shuffles:
            ForEach(shuffles) { shuffle in
                thumbnail(shuffle, showsName: true)
            }
        case .photos:
            addPhoto
            ForEach(shuffles) { shuffle in
                thumbnail(shuffle, showsName: false)
            }
            ForEach(items) { item in
                thumbnail(item, showsName: false)
            }
        case .colors:
            ForEach(shuffles) { shuffle in
                circleButton("arrow.triangle.2.circlepath", name: shuffle.name, id: shuffle.id) {
                    shuffler.start(shuffle, isDark: window.isDark)
                }
            }
            circleButton("plus", name: SystemStrings.customColor) {
                window.chooseColor()
            }
            ForEach(items) { item in
                swatch(item)
            }
        }
    }

    /// A wallpaper's thumbnail, with its name under it, and badges as System Settings has: at the bottom
    /// left, whether it's dynamic or a video, and at the bottom right, whether it's yet to be downloaded,
    /// or how much of it has been
    private func thumbnail(_ item: WallpaperItem, showsName: Bool) -> some View {
        tile(id: item.id, name: item.name, showsName: showsName, badge: item.badge, isOnMac: item.isOnMac, isMissing: isMissing(item)) {
            wallpaper.choose(item, isDark: window.isDark)
        } thumbnail: {
            if isMissing(item) {
                Rectangle()
                    .fill(.background)
                    .overlay {
                        Image(systemName: "exclamationmark.icloud")
                            .font(.system(size: 20))
                            .foregroundStyle(.tertiary)
                    }
            } else {
                WallpaperThumbnail(file: window.isDark ? item.darkThumbnail : item.lightThumbnail, fadesIn: photos.items.contains(item))
            }
        }
    }

    /// A shuffle's thumbnail: four of its pictures under the symbol for shuffling
    private func thumbnail(_ shuffle: WallpaperShuffle, showsName: Bool) -> some View {
        tile(id: shuffle.id, name: shuffle.name, showsName: showsName, badge: shuffle.isAerials ? .video : nil) {
            shuffler.start(shuffle, isDark: window.isDark)
        } thumbnail: {
            ShuffleThumbnail(files: shuffle.thumbnails, size: Self.thumbnailSize)
        }
    }

    /// A thumbnail as System Settings draws one, with its badges, and its name under it
    private func tile(id: String, name: String, showsName: Bool, badge: WallpaperItem.Badge?, isOnMac: Bool = true, isMissing: Bool = false,
                      action: @escaping () -> Void, @ViewBuilder thumbnail: () -> some View) -> some View {
        let isSelected = wallpaper.choice(isDark: window.isDark) == id
        return Button(action: action) {
            VStack(spacing: 3) {
                thumbnail()
                    .overlay(alignment: .bottomLeading) {
                        if let badge {
                            ThumbnailBadge(image: badge == .dynamic ? ThumbnailBadge.dynamic : Image(systemName: "play.rectangle.fill"))
                                .padding([.bottom, .leading], 5)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Group {
                            if wallpaper.changingChoice == id {
                                progress
                                    .frame(width: 13, height: 13)
                            } else if !isOnMac {
                                ThumbnailBadge(image: Image(systemName: "arrow.down.circle"))
                            }
                        }
                        .padding([.bottom, .trailing], 5)
                    }
                    .modifier(ThumbnailFrame(size: Self.thumbnailSize, cornerRadius: Self.thumbnailCornerRadius, isSelected: isSelected))
                if showsName {
                    Text(name)
                        .font(.caption)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: Self.thumbnailSize.width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isMissing)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Whether a photo of the user's is gone, with no copy of it left: Your Photos' are the only
    /// wallpapers with no thumbnail
    private func isMissing(_ item: WallpaperItem) -> Bool {
        item.lightThumbnail == nil && photos.items.contains(item)
    }

    /// One of System Settings' colours, as a round swatch
    private func swatch(_ item: WallpaperItem) -> some View {
        let isSelected = wallpaper.choice(isDark: window.isDark) == item.id
        return Button {
            wallpaper.choose(item, isDark: window.isDark)
        } label: {
            WallpaperThumbnail(file: item.lightThumbnail)
                .overlay {
                    if wallpaper.changingChoice == item.id {
                        progress
                    }
                }
                .modifier(ThumbnailFrame(size: CGSize(width: Self.colorSize, height: Self.colorSize), cornerRadius: Self.colorSize / 2, isSelected: isSelected))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(item.name)
        .accessibilityLabel(item.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Your Photos' first tile, which, as in System Settings, asks for a photo from Photos or a picture
    /// from a file
    private var addPhoto: some View {
        Menu {
            Button(SystemStrings.chooseFromPhotos) {
                isChoosingPhoto = true
            }
            Button(SystemStrings.chooseFile) {
                window.addPhoto()
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 26))
                    .foregroundStyle(.tertiary)
                Text(SystemStrings.addPhoto)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
            .background(.quinary, in: RoundedRectangle(cornerRadius: Self.thumbnailCornerRadius))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
    }

    /// One of Colours' first two swatches, a symbol in a grey circle, as in System Settings: the colours'
    /// shuffle, ringed while it's chosen, and the custom colour, which opens the Colours panel
    private func circleButton(_ symbol: String, name: String, id: String? = nil, action: @escaping () -> Void) -> some View {
        let isSelected = id != nil && wallpaper.choice(isDark: window.isDark) == id
        return Button(action: action) {
            Circle()
                .fill(.quaternary)
                .overlay {
                    if id != nil && wallpaper.changingChoice == id {
                        progress
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                    }
                }
                .modifier(ThumbnailFrame(size: CGSize(width: Self.colorSize, height: Self.colorSize), cornerRadius: Self.colorSize / 2, isSelected: isSelected))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Over the picture being fetched: how much of it has downloaded, or a spinner until it's known
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

/// System Settings › Wallpaper's Show All and Show Less: plain text, smaller and greyer than the title
struct ShowAllButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}

/// A thumbnail's frame, as System Settings draws one: the picture with its corners rounded and a faint
/// line around its edge, or while it's the one chosen, a little smaller inside a ring in the accent
/// colour, which turns grey while the window isn't the one in front
struct ThumbnailFrame: ViewModifier {
    let size: CGSize
    let cornerRadius: CGFloat
    let isSelected: Bool
    @Environment(\.controlActiveState) private var controlActiveState

    private static let ringWidth: CGFloat = 2

    func body(content: Content) -> some View {
        let inset = isSelected ? Self.ringWidth : 0
        let shape = RoundedRectangle(cornerRadius: cornerRadius - inset)
        content
            .frame(width: size.width - 2 * inset, height: size.height - 2 * inset)
            .clipShape(shape)
            .overlay {
                if !isSelected {
                    shape.stroke(.black.opacity(0.08), lineWidth: 1)
                }
            }
            .frame(width: size.width, height: size.height)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(controlActiveState == .key ? Color.accentColor : Color(nsColor: .unemphasizedSelectedContentBackgroundColor), lineWidth: Self.ringWidth)
                }
            }
    }
}

/// A symbol System Settings draws in a thumbnail's corner, white with a shadow to stand out on any picture
struct ThumbnailBadge: View {
    let image: Image

    /// A dynamic wallpaper's: macOS's symbol for Light and Dark (its name is "Light mode appearance
    /// circle"), which isn't in the public set, so it's looked up the way AppKit looks up its own
    static let dynamic: Image = {
        let lookup = NSSelectorFromString("imageWithPrivateSystemSymbolName:accessibilityDescription:")
        guard NSImage.responds(to: lookup),
              let symbol = NSImage.perform(lookup, with: "appearance.lightmode", with: nil)?.takeUnretainedValue() as? NSImage,
              let sized = symbol.withSymbolConfiguration(.init(pointSize: 11, weight: .medium)) else {
            return Image(systemName: "circle.lefthalf.filled")
        }
        sized.isTemplate = true
        return Image(nsImage: sized)
    }()

    var body: some View {
        image
            .renderingMode(.template)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.primary)
            .shadow(color: .black.opacity(0.65), radius: 2)
            .frame(width: 13, height: 13)
            .colorScheme(.dark)
    }
}

/// A shuffle's thumbnail, as System Settings draws one: four of its pictures, one in each quarter, under
/// the symbol for shuffling
struct ShuffleThumbnail: View {
    let files: [URL?]
    let size: CGSize

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<2) { row in
                HStack(spacing: 0) {
                    ForEach(0..<2) { column in
                        WallpaperThumbnail(file: files.indices.contains(2 * row + column) ? files[2 * row + column] : nil)
                    }
                }
            }
        }
        .overlay {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 0.75 * min(size.width, size.height) / 2, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
        }
    }
}

/// A thumbnail in the Wallpaper window, filling its frame, loaded in the background the first time it's
/// shown and kept for the next
struct WallpaperThumbnail: View {
    let file: URL?
    /// Whether it's empty until its picture has loaded, which then fades in, as Your Photos' photos do in
    /// System Settings, with the same spring
    var fadesIn = false
    @State private var image: CGImage?

    private static let cache = NSCache<NSURL, CGImage>()

    init(file: URL?, fadesIn: Bool = false) {
        self.file = file
        self.fadesIn = fadesIn
        // One loaded before is there from the start
        _image = State(initialValue: Self.cached(file))
    }

    var body: some View {
        // Over its frame, so a picture of another shape, like a square one, doesn't make it larger
        Rectangle()
            .fill(fadesIn ? AnyShapeStyle(.clear) : AnyShapeStyle(.quaternary))
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .clipped()
            .task(id: file) {
                if let image = Self.cached(file) {
                    self.image = image
                    return
                }
                let image = await Self.image(of: file)
                withAnimation(fadesIn ? .smooth(duration: 0.5) : nil) {
                    self.image = image
                }
            }
    }

    private static func cached(_ file: URL?) -> CGImage? {
        file.flatMap { cache.object(forKey: $0 as NSURL) }
    }

    private static func image(of file: URL?) async -> CGImage? {
        guard let file else { return nil }
        let maxPixelSize = 2 * thumbnailMaxSize
        let image = await Task.detached(priority: .userInitiated) {
            CGImageSourceCreateWithURL(file as CFURL, nil).flatMap {
                CGImageSourceCreateThumbnailAtIndex($0, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                ] as CFDictionary)
            }
        }.value
        if let image {
            cache.setObject(image, forKey: file as NSURL)
        }
        return image
    }

    /// Enough for the largest thumbnail, in points
    private static let thumbnailMaxSize = 120
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
/// choosing a picture in System Settings › Wallpaper does with Show on all Spaces on. Each picture can
/// be one of the user's own, or one of System Settings' own wallpapers (`WallpaperLibrary`), fetched
/// first if it has to be.
final class WallpaperManager: ObservableObject, @unchecked Sendable { // Its state only changes on the main thread
    static let shared = WallpaperManager()

    /// The pictures the desktop has in Light and in Dark, scaled down for the popover, while Safelight
    /// can tell them (`Desktop`): for a shuffle, its thumbnail, and for a wallpaper macOS draws as it's
    /// shown, like Sequoia's, System Settings' thumbnails of it. Nil while it can't, as for a kind of
    /// wallpaper it doesn't know.
    @Published private(set) var thumbnails: Thumbnails?
    /// True from when a picture is chosen until the wallpaper with it is on the desktop
    @Published private(set) var isChanging = false
    /// While `isChanging`, whether the picture is for Dark, or for Light
    @Published private(set) var changingIsDark = false
    /// While `isChanging`, the wallpaper of System Settings' whose picture it is, if it is one
    @Published private(set) var changingChoice: WallpaperItem.ID?
    /// How much of the picture has downloaded, while it's one macOS downloads when it's chosen
    @Published private(set) var downloadProgress: Double?
    /// The wallpapers of System Settings' whose pictures the desktop has for Light and for Dark, or the
    /// shuffles they're from, each nil for a picture of the user's own. Kept between launches.
    @Published private var choices: Choices {
        didSet { UserDefaults.standard.set(try? PropertyListEncoder().encode(choices), forKey: Self.choicesKey) }
    }

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
    }

    /// What the desktop has, when Safelight can tell the picture it shows in Light and in Dark
    enum Desktop: Equatable {
        /// A wallpaper Safelight made, or a picture file macOS shows as it is: its picture for each
        /// appearance, or its only one in both
        case file(URL)
        /// One of System Settings' wallpapers, as macOS shows it in each appearance: its own picture for
        /// each, or while it's set to Light or Dark, that one's in both
        case item(WallpaperItem, lightShowsDark: Bool, darkShowsDark: Bool)
        /// A colour of the user's own
        case color(CGColor)
        /// A colour, of the user's own or of System Settings', shown with Gradient on
        case gradient(CGColor)
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

    private static let choicesKey = "WallpaperChoices"

    init() {
        choices = UserDefaults.standard.data(forKey: Self.choicesKey).flatMap { try? PropertyListDecoder().decode(Choices.self, from: $0) } ?? Choices()
    }

    /// What the desktop has, which `thumbnails` are of
    private var shown: Desktop?

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
    private static let dynamicMetadataPaths = ["apple_desktop:solar", "apple_desktop:h24"] as [CFString]

    /// AppKit's option for putting a picture on every Space a display has, as System Settings ›
    /// Wallpaper does with Show on all Spaces on. It's exported, but not in the public headers; without
    /// it, a picture only goes on the Space each display is showing.
    private static let allSpacesOption = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "NSWorkspaceDesktopImageAllSpacesKey") // RTLD_DEFAULT
        .map { NSWorkspace.DesktopImageOptionKey(rawValue: $0.load(as: NSString.self) as String) }

    /// Looks at the desktop's wallpaper again, as it can be changed in System Settings › Wallpaper
    func refresh() {
        guard let screen = NSScreen.screens.first else { return show(nil) }
        let wallpaper = NSWorkspace.shared.desktopImageURL(for: screen)
        if let wallpaper, isMadeHere(wallpaper) {
            show(.file(wallpaper))
        } else {
            show(Self.desktop(showing: wallpaper, on: Self.uuid(of: screen)))
        }
    }

    /// Shows the pictures `wallpaper` has for Light and for Dark, or none
    func showPictures(of wallpaper: URL?) {
        show(wallpaper.map(Desktop.file))
    }

    /// Shows the pictures the desktop has for Light and for Dark, or none. They're loaded in the
    /// background, and the ones shown before stay until they are.
    private func show(_ desktop: Desktop?) {
        guard desktop != shown else { return }
        shown = desktop
        guard let desktop else {
            thumbnails = nil
            return
        }
        let screenSize = Self.screenSize
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let thumbnails = Self.thumbnails(of: desktop, screenSize: screenSize)
            DispatchQueue.main.async {
                guard let self, self.shown == desktop else { return }
                self.thumbnails = thumbnails
            }
        }
    }

    /// The wallpaper of System Settings' whose picture the desktop has for an appearance, or the
    /// shuffle it's from: the one chosen here while the wallpaper is one Safelight made and the picture
    /// isn't one of the user's own, or the one System Settings has on the desktop
    func choice(isDark: Bool) -> String? {
        switch shown {
        case .file(let wallpaper)? where isMadeHere(wallpaper):
            return isDark ? choices.dark : choices.light
        case .item(let item, _, _)?:
            return item.id
        case .shuffle(let shuffle, _)?:
            return shuffle.id
        case .drawn(let drawn, _, _, _)?:
            return drawn.rawValue
        default:
            return nil
        }
    }

    /// Whether the desktop has a wallpaper Safelight made, the only kind its shuffles change
    var hasOwnWallpaper: Bool {
        guard case .file(let wallpaper)? = shown else { return false }
        return isMadeHere(wallpaper)
    }

    /// Makes a wallpaper with `item`'s picture for one appearance, as `setPicture(_:isDark:)` does,
    /// fetching it first: downloading it, taking it from its video, or drawing it in its colour. When
    /// it's a shuffle's picture, the shuffle is what's remembered as the appearance's choice. `completion`
    /// is told whether the wallpaper was made. `isQuiet` for a change nobody asked for just then, which
    /// doesn't beep when it fails.
    func choose(_ item: WallpaperItem, isDark: Bool, from shuffle: WallpaperShuffle.ID? = nil, isQuiet: Bool = false, then completion: ((_ isMade: Bool) -> Void)? = nil) {
        let screenSize = Self.screenSize
        let macintoshColors = Self.macintoshColors
        setPicture(isDark: isDark, choice: shuffle ?? item.id, item: item.id, hasPictureForEach: item.light != item.dark, isQuiet: isQuiet, completion: completion) { [weak self] isDark, folder in
            guard let self else { throw CancellationError() }
            return try await self.file(for: isDark ? item.dark : item.light, in: folder, screenSize: screenSize, macintoshColors: macintoshColors)
        }
    }

    /// Makes a wallpaper all in one colour for one appearance, as `setPicture(_:isDark:)` does
    func setColor(_ color: NSColor, isDark: Bool) {
        let screenSize = Self.screenSize
        setPicture(isDark: isDark, choice: nil, item: nil, hasPictureForEach: false) { _, folder in
            try Self.colorPicture(color.usingColorSpace(.displayP3)?.cgColor ?? color.cgColor, size: screenSize, named: "Colour", into: folder)
        }
    }

    /// The size, in pixels, of the largest display, which a colour is drawn at
    private static var screenSize: CGSize {
        NSScreen.screens.reduce(CGSize.zero) { size, screen in
            CGSize(width: max(size.width, screen.frame.width * screen.backingScaleFactor), height: max(size.height, screen.frame.height * screen.backingScaleFactor))
        }
    }

    /// Makes a wallpaper with a photo from Photos for one appearance, as `setPicture(_:isDark:)` does
    func choose(_ photo: PhotosPickerItem, isDark: Bool) {
        setPicture(isDark: isDark, choice: nil, item: nil, hasPictureForEach: false) { _, folder in
            guard let data = try await photo.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadUnknown) }
            let file = folder.appendingPathComponent("Photo").appendingPathExtension(photo.supportedContentTypes.first?.preferredFilenameExtension ?? "heic")
            try data.write(to: file)
            return file
        }
    }

    /// Makes a wallpaper with `file`'s picture for one appearance (its only picture, or for a file
    /// with a picture for each, like Sonoma's, its picture for that appearance), keeping the desktop's
    /// picture for the other, and puts it on every display. While the desktop has a wallpaper whose
    /// pictures Safelight can't tell, the other appearance takes `file`'s picture for it too.
    func setPicture(_ file: URL, isDark: Bool) {
        setPicture(isDark: isDark, choice: nil, item: nil, hasPictureForEach: false) { _, _ in file }
    }

    /// Makes a wallpaper with the picture `picture` gives for one appearance, as `setPicture(_:isDark:)`
    /// does. The other appearance keeps the picture the desktop shows in it, fetched as one of System
    /// Settings' own is when it's one of those. While the desktop has one of System Settings' shuffles,
    /// it takes one of the shuffle's pictures instead, and Safelight's own shuffle of them carries on
    /// for it. While the desktop has one macOS draws, like Sequoia, it takes System Settings' thumbnail
    /// of it, stretched to fill the screen. While it has a wallpaper whose pictures Safelight can't tell,
    /// it takes the one `picture` gives for it, when there's `hasPictureForEach`, or the same one. `picture`
    /// fetches it into the folder it's given, which is taken away once the wallpaper is made. `choice` is
    /// remembered as the appearance's choice, and `item` is the wallpaper of System Settings' the
    /// picture is from. It beeps when it can't be made, unless `isQuiet`.
    private func setPicture(isDark: Bool, choice: String?, item: WallpaperItem.ID?, hasPictureForEach: Bool, isQuiet: Bool = false, completion: ((_ isMade: Bool) -> Void)? = nil,
                            picture: @escaping (_ isDark: Bool, _ folder: URL) async throws -> URL) {
        guard !isChanging, let folder else {
            completion?(false)
            return
        }
        refresh()
        let current = shown
        let screenSize = Self.screenSize
        let wallpaper = folder.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent("Safelight.heic")
        let pictures = wallpaper.deletingLastPathComponent().appendingPathComponent("Pictures", isDirectory: true)
        isChanging = true
        changingIsDark = isDark
        changingChoice = choice
        // Away from the main thread, as fetching the picture, and writing two the size of a screen, takes a while
        Task.detached(priority: .userInitiated) {
            let isMade: Bool
            // The shuffle's picture the other appearance takes, picked as the shuffle picks its next one
            var shuffled: WallpaperItem?
            do {
                try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
                let chosen = (file: try await picture(isDark, pictures), isDark: isDark)
                let other: (file: URL, isDark: Bool)
                if case .shuffle(let shuffle, _)? = current {
                    shuffled = WallpaperLibrary.shared.pictures(of: shuffle.id).randomElement()
                }
                if let shuffled {
                    other = (try await self.file(for: isDark ? shuffled.light : shuffled.dark, in: pictures, screenSize: screenSize), !isDark)
                } else if let current, let picture = try await self.picture(current, shows: !isDark, in: pictures, screenSize: screenSize) {
                    other = picture
                } else if hasPictureForEach {
                    other = (try await picture(!isDark, pictures), !isDark)
                } else {
                    other = (chosen.file, !isDark)
                }
                isMade = Self.makeWallpaper(at: wallpaper, light: isDark ? other : chosen, dark: isDark ? chosen : other)
            } catch {
                NSLog("Safelight: couldn't fetch the wallpaper's picture: \(error)")
                isMade = false
            }
            try? FileManager.default.removeItem(at: pictures)
            let shuffledID = shuffled?.id
            await MainActor.run {
                self.isChanging = false
                self.changingChoice = nil
                self.downloadProgress = nil
                if isMade {
                    self.put(wallpaper, isDark: isDark, choice: choice, item: item, replacing: current, shuffled: shuffledID)
                } else {
                    NSLog("Safelight: couldn't make a wallpaper")
                    try? FileManager.default.removeItem(at: wallpaper.deletingLastPathComponent())
                    if !isQuiet {
                        NSSound.beep()
                    }
                }
                completion?(isMade)
            }
        }
    }

    /// Puts a wallpaper just made on every Space of every display, in place of `current`, and remembers
    /// which of System Settings' wallpapers, or which shuffle, it has the picture for an appearance from.
    /// `shuffled` is the picture the other appearance took from `current`, when that's a shuffle.
    private func put(_ wallpaper: URL, isDark: Bool, choice: String?, item: WallpaperItem.ID?, replacing current: Desktop?, shuffled: WallpaperItem.ID? = nil) {
        for screen in NSScreen.screens {
            var options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
            if let allSpacesOption = Self.allSpacesOption {
                options[allSpacesOption] = true
            }
            do {
                try NSWorkspace.shared.setDesktopImageURL(wallpaper, for: screen, options: options)
            } catch {
                NSLog("Safelight: couldn't set the wallpaper of \(screen.localizedName): \(error)")
            }
        }
        // Only once every Space has the new one: another Space may still show one from before
        if Self.allSpacesOption != nil {
            removeWallpapers(except: wallpaper)
        }
        show(.file(wallpaper))
        YourPhotos.shared.reloadAfterSettingWallpaper()
        // The other appearance kept the desktop's picture, which from a wallpaper of System Settings'
        // is that wallpaper's, and from one of its shuffles, the shuffle's, which carries on here. From
        // one Safelight can't tell, or a shuffle with no pictures, it took its picture from the same
        // wallpaper, but doesn't shuffle.
        var choices: Choices
        switch current {
        case .file(let made)? where isMadeHere(made):
            choices = self.choices
        case .item(let current, _, _)?:
            choices = Choices(light: current.id, dark: current.id)
        case .shuffle(let shuffle, let interval)? where shuffled != nil:
            choices = Choices(light: shuffle.id, dark: shuffle.id)
            WallpaperShuffler.shared.carryOn(shuffle.id, interval: interval, from: shuffled, isDark: !isDark)
        case .drawn(let drawn, _, _, _)?:
            choices = Choices(light: drawn.rawValue, dark: drawn.rawValue)
        case nil, .shuffle?:
            choices = Choices(light: item, dark: item)
        default:
            choices = Choices()
        }
        if isDark {
            choices.dark = choice
        } else {
            choices.light = choice
        }
        self.choices = choices
        // A shuffle stops once the appearance has another choice
        WallpaperShuffler.shared.schedule()
    }

    /// The file with a wallpaper's picture in it, fetched into `folder` when it isn't one already.
    /// `screenSize`, in pixels, is the size a colour, or Macintosh, is drawn at, and `macintoshColors` the
    /// colours Macintosh is drawn in.
    private func file(for picture: WallpaperItem.Picture, in folder: URL, screenSize: CGSize, macintoshColors: String? = nil) async throws -> URL {
        switch picture {
        case .file(let file):
            return file
        case .download(let id):
            return try await download(id, into: folder)
        case .aerial(let id, let video):
            return try await Self.frame(ofAerial: id, video: video, into: folder)
        case .color(let swatch):
            return try Self.colorPicture(swatch, size: screenSize, into: folder)
        case .drawn(let drawn, let isDark):
            return try Self.drawnPicture(drawn, showsDark: isDark, inDarkAppearance: isDark, colors: macintoshColors, size: screenSize, into: folder)
        }
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
    /// it's downloaded, or else from Apple's, which AVFoundation reads only as much of as it needs
    private static func frame(ofAerial id: String, video: URL, into folder: URL) async throws -> URL {
        let downloaded = WallpaperLibrary.aerials.appendingPathComponent("videos/\(id).mov")
        let videos = FileManager.default.isReadableFile(atPath: downloaded.path) ? [downloaded, video] : [video]
        var frame: CGImage?
        var failure: Error?
        for video in videos where frame == nil {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
            generator.appliesPreferredTrackTransform = true
            do {
                frame = try await generator.image(at: .zero).image
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

    /// One of System Settings' colours, as a picture the size of the screen, in the colour of its swatch
    private static func colorPicture(_ swatch: URL, size: CGSize, into folder: URL) throws -> URL {
        guard let color = color(ofSwatch: swatch) else { throw CocoaError(.fileReadCorruptFile) }
        return try colorPicture(color, size: size, named: swatch.deletingPathExtension().lastPathComponent, into: folder)
    }

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
        let file = folder.appendingPathComponent(name).appendingPathExtension("png")
        guard let picture = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, picture, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return file
    }

    /// Whether `wallpaper` is one Safelight made
    private func isMadeHere(_ wallpaper: URL) -> Bool {
        guard let folder else { return false }
        return wallpaper.standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent().path == folder.standardizedFileURL.path
    }

    /// Where macOS's wallpaper service keeps what each display and Space has on its desktop
    private static let store = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")

    /// The ID macOS's wallpaper service knows a display by
    private static func uuid(of screen: NSScreen) -> String? {
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

    /// Macintosh's colours as System Settings would show it chosen now: its colorScheme option as the
    /// desktop chosen last has it, which keeps options from one choice to the next
    private static var macintoshColors: String? {
        let desktops = storedDesktops(on: NSScreen.screens.first.flatMap(uuid(of:)))
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
            return color.map { isGradient ? .gradient($0) : .color($0) }
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
    /// one already, and whether it's that file's picture for Dark, for one with a picture for each. For
    /// a wallpaper macOS draws, which has no picture to take, it's System Settings' thumbnail of it,
    /// stretched to fill the screen. Nil for a shuffle, which hasn't one picture.
    private func picture(_ desktop: Desktop, shows isDark: Bool, in folder: URL, screenSize: CGSize) async throws -> (file: URL, isDark: Bool)? {
        switch desktop {
        case .file(let file):
            return (file, isDark)
        case .item(let item, let lightShowsDark, let darkShowsDark):
            let showsDark = isDark ? darkShowsDark : lightShowsDark
            return (try await file(for: showsDark ? item.dark : item.light, in: folder, screenSize: screenSize), showsDark)
        case .color(let color):
            // Named apart from a colour chosen for the other appearance, which is fetched into the same folder
            return (try Self.colorPicture(color, size: screenSize, named: "Desktop Colour", into: folder), isDark)
        case .gradient(let color):
            return (try Self.gradientPicture(color, size: screenSize, into: folder), isDark)
        case .drawn(let drawn, let lightShowsDark, let darkShowsDark, let colors):
            return (try Self.drawnPicture(drawn, showsDark: isDark ? darkShowsDark : lightShowsDark, inDarkAppearance: isDark, colors: colors, size: screenSize, into: folder), isDark)
        case .shuffle:
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
    private static func gradientPicture(_ color: CGColor, size: CGSize, into folder: URL) throws -> URL {
        let file = folder.appendingPathComponent("Desktop Gradient.png")
        guard let picture = gradientImage(color, size: size),
              let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, picture, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
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

    /// Takes away the wallpapers made before `wallpaper`, now it's on every desktop instead
    private func removeWallpapers(except wallpaper: URL) {
        guard let folder, let made = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for old in made where old.lastPathComponent != wallpaper.deletingLastPathComponent().lastPathComponent {
            try? FileManager.default.removeItem(at: old)
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
        // came out several levels off.
        func options(_ source: CGImageSource) -> CFDictionary {
            [kCGImageDestinationLossyCompressionQuality: CGImageSourceGetType(source) as String? == UTType.png.identifier ? 1 : 0.95] as CFDictionary
        }
        if isOnePicture {
            CGImageDestinationAddImage(destination, lightPicture, options(lightSource))
        } else {
            let metadata = CGImageMetadataCreateMutable()
            let indexes = ["l": 0, "d": 1]
            guard CGImageMetadataRegisterNamespaceForPrefix(metadata, metadataNamespace, metadataPrefix, nil),
                  let plist = try? PropertyListSerialization.data(fromPropertyList: indexes, format: .binary, options: 0),
                  CGImageMetadataSetValueWithPath(metadata, nil, appearanceMetadataPath, plist.base64EncodedString() as CFString)
            else { return false }
            CGImageDestinationAddImageAndMetadata(destination, lightPicture, metadata, options(lightSource))
            CGImageDestinationAddImage(destination, darkPicture, options(darkSource))
        }
        return CGImageDestinationFinalize(destination)
    }

    /// The pictures in `wallpaper` for Light and for Dark, scaled down to a few hundred pixels, which is
    /// enough to fill a thumbnail at twice its size, even from a picture much wider than the screen
    private static func thumbnails(of wallpaper: URL) -> Thumbnails? {
        guard let source = CGImageSourceCreateWithURL(wallpaper as CFURL, nil),
              let light = picture(in: source, at: index(in: source, isDark: false), maxPixelSize: 400),
              let dark = picture(in: source, at: index(in: source, isDark: true), maxPixelSize: 400) else { return nil }
        return Thumbnails(light: .picture(light), dark: .picture(dark))
    }

    /// The pictures the desktop shows in Light and in Dark, scaled down as `thumbnails(of:)` scales them.
    /// A wallpaper of System Settings' shows its thumbnails, which are the ones the Wallpaper window
    /// shows, a shuffle its thumbnail, a colour is just the colour, or its gradient, and Macintosh is
    /// drawn the shape of a display of `screenSize`.
    private static func thumbnails(of desktop: Desktop, screenSize: CGSize) -> Thumbnails? {
        func both(_ thumbnail: CGImage?) -> Thumbnails? {
            thumbnail.map { Thumbnails(light: .picture($0), dark: .picture($0)) }
        }
        switch desktop {
        case .file(let wallpaper):
            return thumbnails(of: wallpaper)
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
        case .gradient(let color):
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
        let file = folder.appendingPathComponent("Desktop \(drawn.name).png")
        if let picture = drawnImage(drawn, showsDark: showsDark, inDarkAppearance: isDark, colors: colors, size: size) {
            guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(destination, picture, nil)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
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
        guard let picture = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, picture, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
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
/// that appearance's choice; choosing anything else for it stops it.
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

    /// Kept between launches, and after another choice, so a shuffle chosen again changes as often as before
    @Published private var shuffles: Shuffles {
        didSet { UserDefaults.standard.set(try? PropertyListEncoder().encode(shuffles), forKey: Self.shufflesKey) }
    }

    private static let shufflesKey = "WallpaperShuffles"
    private var timer: Timer?
    /// The appearances whose shuffles are to change, one after the other, as one wallpaper is made at a time
    private var queue: [Bool] = []
    /// When a shuffle whose picture couldn't be made tries again, with another: a minute later, as when
    /// the Mac has just woken and isn't online yet, then twice as long each time it fails, up to an hour
    private var retries: [Bool: (date: Date, delay: TimeInterval)] = [:]

    init() {
        shuffles = UserDefaults.standard.data(forKey: Self.shufflesKey).flatMap { try? PropertyListDecoder().decode(Shuffles.self, from: $0) } ?? Shuffles()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.change(at: .wake)
        }
    }

    /// The shuffle an appearance has, while it's the appearance's choice in a wallpaper Safelight made.
    /// System Settings' own shuffles are run by macOS.
    func shuffle(isDark: Bool) -> Shuffle? {
        guard let shuffle = shuffles[isDark], WallpaperManager.shared.hasOwnWallpaper,
              WallpaperManager.shared.choice(isDark: isDark) == shuffle.id else { return nil }
        return shuffle
    }

    /// Makes a shuffle the appearance's choice, with a picture from it now
    func start(_ shuffle: WallpaperShuffle, isDark: Bool) {
        let interval = shuffles[isDark].flatMap { $0.id == shuffle.id ? $0.interval : nil } ?? WallpaperShuffle.defaultInterval(for: shuffle.id)
        retries[isDark] = nil
        change(Shuffle(id: shuffle.id, interval: interval), isDark: isDark, isQuiet: false)
    }

    /// Carries on one of System Settings' shuffles for an appearance, as often as it changed, from the
    /// picture of it the appearance has just been given, as a wallpaper of Safelight's took the
    /// shuffle's place. Its timer is set once the wallpaper is the desktop's.
    func carryOn(_ id: WallpaperShuffle.ID, interval: WallpaperShuffle.Interval, from current: WallpaperItem.ID?, isDark: Bool) {
        retries[isDark] = nil
        shuffles[isDark] = Shuffle(id: id, interval: interval, lastChange: Date(), current: current)
    }

    func setInterval(_ interval: WallpaperShuffle.Interval, isDark: Bool) {
        guard shuffle(isDark: isDark) != nil else { return }
        shuffles[isDark]?.interval = interval
        schedule()
    }

    /// At launch: the shuffles that change at login do, and the others carry on where they were, or
    /// change now if they were due while Safelight wasn't running
    func resume() {
        change(at: .login)
    }

    /// Changes the shuffles that change at login or on waking, and sets the timer for the others again,
    /// as it doesn't run while the Mac sleeps
    private func change(at interval: WallpaperShuffle.Interval) {
        // The wallpaper may have been changed in System Settings since
        WallpaperManager.shared.refresh()
        for isDark in [false, true] where shuffle(isDark: isDark)?.interval == interval {
            enqueue(isDark)
        }
        schedule()
    }

    /// Sets the timer for the shuffle to change next, in place of the one before
    func schedule() {
        timer?.invalidate()
        timer = nil
        let next = [false, true].compactMap { isDark -> (isDark: Bool, date: Date)? in
            guard let shuffle = shuffle(isDark: isDark) else { return nil }
            // Once it's due, or when it tries again after failing, even one that changes at login or on waking
            let due = shuffle.interval.next(after: shuffle.lastChange ?? .distantPast)
            guard let date = [due, retries[isDark]?.date].compactMap({ $0 }).max() else { return nil }
            return (isDark, date)
        }.min { $0.date < $1.date }
        guard let next else { return }
        let timer = Timer(fire: max(next.date, Date()), interval: 0, repeats: false) { [weak self] _ in
            WallpaperManager.shared.refresh()
            self?.enqueue(next.isDark)
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func enqueue(_ isDark: Bool) {
        guard !queue.contains(isDark) else { return }
        queue.append(isDark)
        if queue.count == 1 {
            changeNext()
        }
    }

    private func changeNext() {
        guard let isDark = queue.first else { return }
        guard let shuffle = shuffle(isDark: isDark) else {
            queue.removeFirst()
            changeNext()
            return
        }
        change(shuffle, isDark: isDark, isQuiet: true) { [weak self] in
            self?.queue.removeFirst()
            self?.changeNext()
        }
    }

    /// Makes a wallpaper with another of the shuffle's pictures for the appearance. `isQuiet` when it's
    /// on time, not chosen just now, so it doesn't beep when the picture can't be made.
    private func change(_ shuffle: Shuffle, isDark: Bool, isQuiet: Bool, then completion: (() -> Void)? = nil) {
        // While a picture chosen in the Wallpaper window is being made, a little later
        guard !WallpaperManager.shared.isChanging else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.change(shuffle, isDark: isDark, isQuiet: isQuiet, then: completion)
            }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            // Any picture but the one it has now
            let pictures = WallpaperLibrary.shared.pictures(of: shuffle.id)
            let next = pictures.filter { $0.id != shuffle.current }.randomElement() ?? pictures.randomElement()
            DispatchQueue.main.async {
                guard let next else {
                    completion?()
                    return
                }
                // Before it's made, as making it sets the timer again
                var changed = shuffle
                changed.current = next.id
                changed.lastChange = Date()
                self.shuffles[isDark] = changed
                WallpaperManager.shared.choose(next, isDark: isDark, from: shuffle.id, isQuiet: isQuiet) { [weak self] isMade in
                    guard let self else { return }
                    if isMade {
                        self.retries[isDark] = nil
                    } else if self.shuffles[isDark] == changed {
                        // As it was, with the picture still on the desktop, until it tries again
                        self.shuffles[isDark] = shuffle
                        let delay = min(2 * (self.retries[isDark]?.delay ?? 30), 60 * 60)
                        self.retries[isDark] = (Date().addingTimeInterval(delay), delay)
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
/// from low down and coloured by height from a gradient of the time of day, solar noon's in the Light
/// look and solar midnight's in the Dark one. It's drawn with the extension's own shaders, meshes and
/// gradients, and the streaks stand where the extension's own tables put them. As in the extension, the
/// streaks without a turn of their own get a random one, so no two pictures (and no two times macOS
/// starts drawing it) are quite the same. Drawn so, with the extension's streaks turned as it had turned
/// them, it's within a level of each colour of what the extension draws.
enum SequoiaWallpaper {
    private static let resources = URL(fileURLWithPath: WallpaperLibrary.sequoiaExtension).appendingPathComponent("Contents/Resources", isDirectory: true)
    private static let executable = URL(fileURLWithPath: WallpaperLibrary.sequoiaExtension).appendingPathComponent("Contents/MacOS/WallpaperSequoiaExtension")

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
        /// Solar noon's gradient and solar midnight's
        let gradients: (light: MTLTexture, dark: MTLTexture)

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
            guard meshes.count == 3, let light = gradient("solar noon"), let dark = gradient("solar midnight") else { return nil }
            (self.device, self.queue, self.streaks, self.background, self.depth) = (device, queue, streaks.0, background.0, depth)
            (self.meshes, self.gradients) = (meshes, (light, dark))
        }
    }

    private static let renderer = Renderer()

    /// Sequoia as it is before it moves, on a display of `size`, in pixels, in its Dark look or its
    /// Light one, with each streak that has no turn of its own turned as `rotation` says for where it
    /// stands, at random unless a test says otherwise. Nil on a macOS whose Sequoia isn't drawn as
    /// worked out here.
    static func picture(showsDark: Bool, size: CGSize, rotation: (SIMD2<Float>) -> Float = { _ in Float.random(in: 0..<(2 * .pi)) }) -> CGImage? {
        let width = max(Int(size.width), 1), height = max(Int(size.height), 1)
        guard let renderer, let streaks = streaks(aspect: Float(width) / Float(height), rotation: rotation) else { return nil }
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
        var dimming: Float = 1
        encoder.setCullMode(.front)
        encoder.setRenderPipelineState(renderer.streaks)
        encoder.setDepthStencilState(renderer.depth)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<float4x4>.stride * 2, index: 0)
        encoder.setVertexBuffer(instances, offset: 0, index: 2)
        encoder.setFragmentBytes(&dimming, length: MemoryLayout<Float>.size, index: 1)
        encoder.setFragmentTexture(showsDark ? renderer.gradients.dark : renderer.gradients.light, index: 0)
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
        /// One of the pictures macOS downloads from Apple once it's chosen, by its ID in macOS's list
        case download(String)
        /// An aerial, by its ID, as the desktop shows it, from its video on Apple's server
        case aerial(id: String, video: URL)
        /// A colour, as its swatch
        case color(URL)
        /// One of the wallpapers macOS draws, in its Dark look or its Light one
        case drawn(WallpaperManager.DrawnWallpaper, isDark: Bool)
    }

    /// What System Settings badges a thumbnail with: a dynamic wallpaper, which has a picture for Light
    /// and one for Dark, or an aerial, which is a video
    enum Badge {
        case dynamic, video
    }

    let id: String
    let name: String
    let light: Picture
    let dark: Picture
    let lightThumbnail: URL?
    let darkThumbnail: URL?
    var badge: Badge?

    /// Whether its pictures are on the Mac, or have to be downloaded first. An aerial's is when macOS
    /// has downloaded its video.
    var isOnMac: Bool {
        [light, dark].allSatisfy { picture in
            switch picture {
            case .file, .color, .drawn:
                return true
            case .download:
                return false
            case .aerial(let id, _):
                return FileManager.default.fileExists(atPath: WallpaperLibrary.aerials.appendingPathComponent("videos/\(id).mov").path)
            }
        }
    }
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
        id != Self.photos && id != Self.colors
    }

    /// How often it can change, as System Settings offers for its kind, but never every few seconds or
    /// continuously, as each change makes a wallpaper
    static func intervals(for id: ID) -> [Interval] {
        id == photos || id == colors ? [.minute, .fiveMinutes, .fifteenMinutes, .thirtyMinutes, .hour, .day, .login, .wake] : [.twelveHours, .day, .twoDays, .week, .month]
    }

    /// As often as macOS changes one until it's set: every half hour, or for the aerials, every day
    static func defaultInterval(for id: ID) -> Interval {
        id == photos || id == colors ? .thirtyMinutes : .day
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
                    let item = WallpaperItem(id: "aerial:\(light.id)", name: name,
                                             light: .aerial(id: light.id, video: lightVideo), dark: .aerial(id: dark.id, video: darkVideo),
                                             lightThumbnail: Self.thumbnail(ofAerial: light.id), darkThumbnail: Self.thumbnail(ofAerial: dark.id), badge: .dynamic)
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
                    aerialShuffles.append((category.id, title, shuffled.map(\.item), inSubcategoryOrder.prefix(4).map(\.item.lightThumbnail), first.item))
                }
            }
        }
        // After them, a shuffle of all the aerials that shuffle, and one of each category's
        var shufflePictures: [WallpaperShuffle.ID: [WallpaperItem]] = [:]
        var shuffles: [WallpaperShuffle] = []
        let allShuffled = aerialShuffles.flatMap(\.items)
        if !allShuffled.isEmpty {
            shuffles.append(WallpaperShuffle(id: WallpaperShuffle.aerials, name: SystemStrings.shuffleAll, thumbnails: aerialShuffles.prefix(4).map(\.representative.lightThumbnail)))
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
                                                                   lightThumbnail: tahoeLight, darkThumbnail: tahoeDark, badge: .dynamic)))
        }
        let sequoiaThumbnail = URL(fileURLWithPath: Self.sequoiaExtension).appendingPathComponent("Contents/Resources/thumbnail.heic")
        if fileManager.fileExists(atPath: sequoiaThumbnail.path) {
            let sequoia = WallpaperManager.DrawnWallpaper.sequoia
            dynamic.append(Placed(order: -300, item: WallpaperItem(id: sequoia.rawValue, name: sequoia.name, light: .drawn(sequoia, isDark: false), dark: .drawn(sequoia, isDark: true),
                                                                   lightThumbnail: sequoiaThumbnail, darkThumbnail: sequoiaThumbnail, badge: .dynamic)))
        }
        if fileManager.fileExists(atPath: Self.macintoshExtension), fileManager.fileExists(atPath: Self.macintoshThumbnail.path) {
            let macintosh = WallpaperManager.DrawnWallpaper.macintosh
            dynamic.append(Placed(order: -200, item: WallpaperItem(id: macintosh.rawValue, name: macintosh.name, light: .drawn(macintosh, isDark: false), dark: .drawn(macintosh, isDark: true),
                                                                   lightThumbnail: Self.macintoshThumbnail, darkThumbnail: Self.macintoshThumbnail, badge: .dynamic)))
        }
        let sonoma = Self.desktopPictures.appendingPathComponent("Sonoma.heic")
        if fileManager.fileExists(atPath: Self.sonomaExtension), fileManager.fileExists(atPath: sonoma.path) {
            dynamic.append(Placed(order: -100, item: Self.picture(named: "Sonoma", title: SystemStrings.sonoma, picture: .file(sonoma), badge: .dynamic)))
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
            if file.pathExtension == "madesktop" {
                guard let descriptor = NSDictionary(contentsOf: file) else { continue }
                isDynamic = descriptor["isDynamic"] as? Bool == true
                let downloaded = Self.downloadedPictures.appendingPathComponent("\(name).heic")
                if fileManager.fileExists(atPath: downloaded.path) {
                    picture = .file(downloaded)
                } else {
                    guard let id = descriptor["mobileAssetID"] as? String, downloads[id] != nil else { continue }
                    picture = .download(id)
                }
            } else {
                // The colours are in a folder of their own
                guard fileManager.fileExists(atPath: file.path) else { continue }
                isDynamic = Self.hasPictureForEachAppearance(file)
                picture = .file(file)
            }
            let item = Self.picture(named: name, title: SystemStrings.desktopPictureName(name), picture: picture, badge: isDynamic ? .dynamic : nil)
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
                                 light: .color(swatch), dark: .color(swatch), lightThumbnail: swatch, darkThumbnail: swatch)
        }

        shufflePictures[WallpaperShuffle.colors] = colors
        // Its tile is a symbol, but System Settings shows it on the desktop as the others are shown, with
        // the second, third, fourth and sixth colours
        let colorShuffle = WallpaperShuffle(id: WallpaperShuffle.colors, name: SystemStrings.shuffle, thumbnails: [1, 2, 3, 5].map { colors.indices.contains($0) ? colors[$0].lightThumbnail : nil })

        var sections = [Section(id: "dynamic", title: SystemStrings.dynamicWallpapers, items: Self.sorted(dynamic).map(\.item)),
                        Section(id: Self.yourPhotos, title: SystemStrings.yourPhotos, kind: .photos, items: [])]
        sections += aerialSections
        sections += [Section(id: "pictures", title: SystemStrings.pictures, items: pictures),
                     Section(id: "colors", title: SystemStrings.colors, kind: .colors, items: colors, shuffles: [colorShuffle])]
        self.sections = sections.filter { $0.kind == .photos || !$0.items.isEmpty || !$0.shuffles.isEmpty }
        self.items = Dictionary(sections.flatMap(\.items).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.aerialItems = aerialItems
        self.downloads = downloads
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

    /// The name of an appearance's choice: a wallpaper, a shuffle, one of the user's photos, or one of
    /// the wallpapers macOS draws
    func name(of choice: String) -> String? {
        if let item = items[choice] ?? YourPhotos.shared.items.first(where: { $0.id == choice }) {
            return item.name
        }
        return shuffle(choice)?.name ?? WallpaperManager.DrawnWallpaper(rawValue: choice)?.name
    }

    /// One of the shuffles: the aerials', the colours', or Your Photos', with the newest four photos in
    /// its thumbnail once they've been read
    func shuffle(_ id: WallpaperShuffle.ID) -> WallpaperShuffle? {
        if id == WallpaperShuffle.photos {
            return YourPhotos.shared.shuffle ?? WallpaperShuffle(id: id, name: SystemStrings.yourPhotos, thumbnails: [])
        }
        return sections.lazy.flatMap(\.shuffles).first { $0.id == id }
    }

    /// The pictures a shuffle picks from. Your Photos' are read again each time, as they change, but
    /// without the wallpapers Safelight made, which are already the desktop's.
    func pictures(of shuffle: WallpaperShuffle.ID) -> [WallpaperItem] {
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
            var item = picture(named: name, title: SystemStrings.desktopPictureName(name), picture: .file(file))
            item.badge = .video
            return item
        }
        guard let video = aerial.video else { return nil }
        let name = aerial.localizedNameKey.map { SystemStrings.aerialName($0, english: aerial.accessibilityLabel ?? $0) } ?? aerial.accessibilityLabel ?? ""
        return WallpaperItem(id: "aerial:\(aerial.id)", name: name, light: .aerial(id: aerial.id, video: video), dark: .aerial(id: aerial.id, video: video),
                             lightThumbnail: thumbnail(ofAerial: aerial.id), darkThumbnail: thumbnail(ofAerial: aerial.id), badge: .video)
    }

    /// One of macOS's pictures, with its thumbnail for Light and its thumbnail for Dark when it has a
    /// picture for each, from the file it's in or to download
    private static func picture(named name: String, title: String, picture: WallpaperItem.Picture, badge: WallpaperItem.Badge? = nil) -> WallpaperItem {
        let thumbnails = desktopPictures.appendingPathComponent(".thumbnails", isDirectory: true)
        let thumbnail = { (suffix: String) -> URL? in
            let thumbnail = thumbnails.appendingPathComponent("\(name)\(suffix).heic")
            return FileManager.default.fileExists(atPath: thumbnail.path) ? thumbnail : nil
        }
        let file: URL? = if case .file(let file) = picture { file } else { nil }
        return WallpaperItem(id: "picture:\(name)", name: title, light: picture, dark: picture,
                             lightThumbnail: thumbnail(" Light") ?? thumbnail("") ?? file, darkThumbnail: thumbnail(" Dark") ?? thumbnail("") ?? file, badge: badge)
    }

    /// Whether a picture has one for Light and one for Dark, or for times of day, as macOS's dynamic
    /// wallpapers have
    static func hasPictureForEachAppearance(_ file: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let metadata = CGImageSourceCopyMetadataAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil) else { return false }
        return ["apple_desktop:apr", "apple_desktop:solar", "apple_desktop:h24"].contains { CGImageMetadataCopyTagWithPath(metadata, nil, $0 as CFString) != nil }
    }

    /// An aerial's thumbnail, from macOS's list, or from System Settings for those it came with
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
        return WallpaperShuffle(id: WallpaperShuffle.photos, name: SystemStrings.yourPhotos, thumbnails: items.prefix(4).map(\.lightThumbnail))
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
                                     lightThumbnail: nil, darkThumbnail: nil)
            }
            return WallpaperItem(id: "photo:\(file.originalURL.path)", name: name, light: .file(picture), dark: .file(picture),
                                 lightThumbnail: picture, darkThumbnail: picture,
                                 badge: WallpaperLibrary.hasPictureForEachAppearance(picture) ? .dynamic : nil)
        }
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
    
    // System Settings › Accessibility › Hearing Devices' switch for setting each hearing aid by itself
    static let adjustIndependently = lookup("mfi.hearingaids.adjust.independently.toggle.title", in: accessibilitySettings, english: "Adjust Independently")
    
    // System Settings › Displays (Schedule is Night Shift's)
    static let brightness = lookup("Brightness", in: displaysSettings, english: "Brightness")
    static let schedule = lookup("Schedule", in: displaysSettings, english: "Schedule")
    static let customize = lookup("Customize…", in: displaysSettings, english: "Customize…")

    // System Settings › Appearance
    static let appearance = lookup("Appearance", in: appearanceSettings, english: "Appearance")
    static let light = lookup("Light", in: appearanceSettings, english: "Light")
    static let dark = lookup("Dark", in: appearanceSettings, english: "Dark")

    // System Settings › Wallpaper, its buttons for choosing a picture of your own, and its sections'
    // Show All and Show Less
    static let wallpaper = lookup("WALLPAPER", in: wallpaperSettings, english: "Wallpaper")
    static let addPhoto = lookup("ADD_PHOTO", in: wallpaperSettings, english: "Add Photo…")
    static let chooseFromPhotos = lookup("CHOOSE_FROM_PHOTOS", in: wallpaperSettings, english: "Choose from Photos…")
    static let chooseFile = lookup("CHOOSE_FILE", in: wallpaperSettings, english: "Choose File…")
    static let showAll = lookup("SHOW_ALL_%@", in: wallpaperSettings, english: "Show All (%@)")
    static let showLess = lookup("SHOW_LESS", in: wallpaperSettings, english: "Show Less")

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
    
    private static func lookup(_ key: String, table: String = "Localizable", in bundlePath: String, english: String) -> String {
        guard let bundle = Bundle(path: bundlePath) else { return english }
        return bundle.localizedString(forKey: key, value: english, table: table, localizations: languages)
    }
}
