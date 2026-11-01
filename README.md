<p align="center">
  <img src="docs/icon.png" width="128" alt="Safelight's icon: a 24-hour dial, white through the day and red through the night">
</p>

# Safelight

Safelight puts your Mac's color filter, brightness and Light/Dark appearance on one schedule. Choose how the screen should look at a few times of day, and Safelight fades from one to the next: plain white through the afternoon, warmer and dimmer after sunset, deep red late at night, and back again in the morning.

It lives in the menu bar.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/popover-dark.png">
    <img src="docs/popover-light.png" width="418" alt="Safelight's icon in the menu bar, beside Wi-Fi, Spotlight, Control Center and the clock, with its controls open below it: Schedule, Color filters, Intensity, Tint, Brightness, Adjust Independently, Appearance and Wallpaper">
  </picture>
</p>

## What it does

- **A red that goes all the way.** Safelight drives the Color Tint filter built into macOS (System Settings › Accessibility › Display › Color Filters), so the screen can go fully red, which Night Shift can't. The filter applies to everything on screen.
- **Brightness for every display.** Set them all as one, or turn on Adjust Independently to give each display its own brightness, in the schedule too. Displays that let the Mac set their brightness are set directly. The rest, like most external monitors, are dimmed in software, and an iPad used with Sidecar under a dark layer.
- **Brightness keys for every display.** With Adjust Independently on, the brightness keys set the display under the pointer, whichever it is. Catching the keys takes Accessibility permission, which macOS asks for when you turn it on.
- **Light and Dark too.** Each time of day can switch the system between Light and Dark appearance.
- **A wallpaper for each.** Choose a picture for Light and another for Dark, and the desktop fades over between them as the appearance switches, whatever switches it: Safelight, System Settings, Control Center or Auto. Pick from macOS's own wallpapers, in System Settings' sections (Dynamic Wallpapers, the aerials' Landscape, Cityscape, Underwater, Earth and Mac, Pictures and Colours), from Photos, or from a file, or shuffle them: System Settings' shuffles, or a set from its Add Photo… menu, a folder, or Favourites, a person or an album in Photos. A dynamic wallpaper gives its Light or Dark picture, and an aerial the picture the desktop shows before it moves. Safelight makes them one wallpaper, the way macOS's own Light and Dark wallpapers are made, so macOS does the changing itself, on every Space. Aerials don't move, as macOS only lets System Settings set moving ones.
- **One schedule for all of it.** Add as many times of day as you like. Each sets the color filter, intensity, tint, brightness and appearance, and the filter and brightness fade smoothly between them. The strip along the top previews the whole day.
- **Looks and speaks like macOS.** The controls are the ones System Settings uses, and every label comes from System Settings' own translations, so Safelight appears in your Mac's language.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/schedule-dark.png">
    <img src="docs/schedule-light.png" width="800" alt="The Schedule window: a preview of the day above five times of day, each with its own color filter, intensity, tint, brightness and appearance">
  </picture>
</p>

Click the menu bar icon for the controls, the gear next to Schedule to edit the schedule, and the Light or Dark wallpaper to choose its picture in the Wallpaper window. Right-click (or Control-click) the icon for Open at Login, Automatic Updates, Check for Updates… and Quit. Reset and Quit turn the schedule and color filter off and set brightness back to full.

## Install

Safelight needs macOS 15.5 or later, on Apple silicon or Intel.

1. Download the Safelight disk image (`.dmg`) from the [latest release](https://github.com/mopfaff/Safelight/releases/latest), open it, and drag Safelight onto the Applications folder beside it.
2. Open Safelight. It isn't notarized by Apple, so macOS says it can't check it for malware. Click **Done**.
3. Open **System Settings › Privacy & Security**, scroll down, and click **Open Anyway** next to the message about Safelight. Confirm with your password.

You only need to do this once. If you'd rather read the code first, all of Safelight's own code is in [`Safelight/Safelight.swift`](Safelight/Safelight.swift), and you can build it yourself.

### Updates

Safelight keeps itself up to date. Once a day it looks for a new release here, downloads it, and installs it the next time it quits, or when you log out or restart, so the screen never changes while you're using it. An update opens without the warning above, and Safelight only installs one signed with its own key. If you'd rather decide yourself, turn off Automatic Updates in the icon's right-click menu and choose Check for Updates… when you like. The updating is done by [Sparkle](https://sparkle-project.org), the open-source updater many Mac apps use.

## Build it yourself

You need Xcode 26 or later.

```bash
git clone https://github.com/mopfaff/Safelight.git
cd Safelight
scripts/release.sh
```

Xcode fetches Sparkle the first time. The app ends up in `build/release`. A copy you build yourself opens without the warning above, and updates itself to each new release like a downloaded one; turn off Automatic Updates to keep your own build. You can also open `Safelight.xcodeproj` in Xcode, choose your own team (or Sign to Run Locally) under Signing & Capabilities, and run it from there.

## How it works

Safelight doesn't draw anything over your screen. It changes the same settings System Settings does, through the functions System Settings itself calls. Those functions aren't part of Apple's public developer APIs, which is also why Safelight isn't on the Mac App Store, and a macOS update could change them. If something stops working after an update, please [open an issue](https://github.com/mopfaff/Safelight/issues).

## Support

Safelight is free and open source. If it's useful to you, you can support its development through [GitHub Sponsors](https://github.com/sponsors/mopfaff).

## License

Copyright © 2025–2026 mopfaff. Safelight is licensed under the [GNU General Public License v3.0](LICENSE).
