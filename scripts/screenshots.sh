#!/bin/zsh
# Draws the README's screenshots from the current code: the popover, open under its icon in the menu
# bar, and the Schedule window, in Dark and in Light. scripts/release.sh runs it too, so each release's
# screenshots match it.
#
#   scripts/screenshots.sh    writes docs/popover-dark.png, popover-light.png, schedule-dark.png and
#                             schedule-light.png
#   scripts/screenshots.sh --desktop [dark|light]
#                             instead writes, for both appearances or the one given, to
#                             build/screenshots/out/, the popover and the Schedule window over a
#                             desktop: the top right corner of the screen, 540 × 675 and 1128 × 678
#                             points of it, with the wallpapers the demo has, Sonoma Horizon in Light
#                             and Sonoma's Dark picture in Dark, which the popover's Wallpaper picker
#                             shows too. The popover's glass is drawn over the wallpaper, as it can't
#                             be by putting the README's screenshot on one.
#                             scripts/make-reddit-pictures.py makes the Reddit gallery's from them.
#                             With DARK_WALLPAPER=build/wallpapers/Dome.heic, that file's Dark picture
#                             is Dark's wallpaper instead, and they're written to
#                             build/screenshots/out-dome/, named for the file. (Dome is one of macOS's
#                             wallpapers that it downloads when picked, so it isn't on a Mac that
#                             hasn't had it: its catalogue,
#                             /System/Library/AssetsV2/com_apple_MobileAsset_DesktopPicture/, says where
#                             Apple keeps it.)
#   SCHEDULE=scripts/screenshots/my-schedule.json scripts/screenshots.sh [--desktop [dark|light]]
#                             draws the same with that schedule in the Schedule window rather than the
#                             default one, and the popover at that schedule's settings at 21:00. The
#                             file has a schedule as the demo's scenes write one;
#                             scripts/export-schedule.py writes the one Safelight has on this Mac to it.
#                             These go to folders of their own, named for the file, and docs/ is left
#                             alone: build/screenshots/plain-my-schedule/ for the windows by themselves,
#                             and out-my-schedule/ or out-dome-my-schedule/ over a desktop.
#   CLOCK=22:47 scripts/screenshots.sh [--desktop [dark|light]]
#                             draws the same at that time of day rather than 21:00: the menu bar's
#                             clock says it, and the Schedule's line at the current time is there. The
#                             popover's settings are the same, as the default schedule has them all
#                             night. These go to folders of their own as well, named for the time:
#                             build/screenshots/plain-2247/, and out-2247/ or out-dome-2247/ over a
#                             desktop (after the schedule's name, with one).
#
# It builds a copy of Safelight.swift into "Safelight Screenshots.app" with scripts/screenshots/,
# whose NoSystemChanges.swift stands in for the functions that change the color filter, brightness and
# appearance, so the Mac is left as it was. The copy has settings of its own, so the Schedule shows the
# default schedule rather than yours, and FixedTime.swift keeps it at 21:00. Beside its icon, the menu
# bar has stand-ins for Wi-Fi, Spotlight, Control Center and the clock rather than your own items. A
# screenshot that looks the same as the one in docs/ leaves it be, so they only change when the app
# does. Its windows are on screen for a few seconds, on a Retina display: leave them be until it's done.

set -eu
cd "${0:A:h}/.."

BUILD_DIR="build/screenshots"
NAME="Safelight Screenshots"
APP="$BUILD_DIR/$NAME.app"
OUT="$BUILD_DIR/out"
DARK_WALLPAPER="${DARK_WALLPAPER:-/System/Library/Desktop Pictures/Sonoma.heic}"
if [[ "${1:-}" == --desktop && "$DARK_WALLPAPER" != "/System/Library/Desktop Pictures/Sonoma.heic" ]]; then
    if [[ ! -f "$DARK_WALLPAPER" ]]; then
        echo "There's no wallpaper at $DARK_WALLPAPER" >&2
        exit 2
    fi
    OUT="$BUILD_DIR/out-${(L)DARK_WALLPAPER:t:r}"
fi
SCHEDULE="${SCHEDULE:-}"
SCHEDULE_ARGS=()
if [[ -n "$SCHEDULE" ]]; then
    if [[ ! -f "$SCHEDULE" ]]; then
        echo "There's no schedule at $SCHEDULE" >&2
        exit 2
    fi
    if [[ "${1:-}" == --desktop ]]; then OUT="$OUT-${SCHEDULE:t:r}"; else OUT="$BUILD_DIR/plain-${SCHEDULE:t:r}"; fi
    SCHEDULE_ARGS=(-scheduleFile "${SCHEDULE:A}")
fi
CLOCK="${CLOCK:-}"
CLOCK_ARGS=()
if [[ -n "$CLOCK" ]]; then
    if [[ "$CLOCK" != [0-2][0-9]:[0-5][0-9] ]]; then
        echo "The time is like 22:47, not $CLOCK" >&2
        exit 2
    fi
    if [[ "${1:-}" == --desktop || -n "$SCHEDULE" ]]; then OUT="$OUT-${CLOCK/:/}"; else OUT="$BUILD_DIR/plain-${CLOCK/:/}"; fi
    CLOCK_ARGS=(-clock "$CLOCK")
fi
SHOTS=(popover-dark popover-light schedule-dark schedule-light)

rm -rf "$APP" "$OUT" "$BUILD_DIR/src"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT" "$BUILD_DIR/src"

# The screenshot app has an entry point of its own instead of Safelight's
if [[ $(grep -c '^@main$' Safelight/Safelight.swift) != 1 ]]; then
    echo "Couldn't find Safelight's @main line to leave out" >&2
    exit 2
fi
# And, over a desktop, picks its wallpaper's picture for the appearance and makes the wallpaper the
# popover shows as Safelight does, as scripts/make-demo.sh's recorder does
INDEX='    private static func index(in source: CGImageSource, isDark: Bool) -> Int {'
MAKE='    private static func makeWallpaper(at wallpaper: URL, light: (file: URL, isDark: Bool), dark: (file: URL, isDark: Bool)) -> Bool {'
if [[ $(grep -cxF "$INDEX" Safelight/Safelight.swift) != 1 || $(grep -cxF "$MAKE" Safelight/Safelight.swift) != 1 ]]; then
    echo "Couldn't find WallpaperManager's index(in:isDark:) and makeWallpaper(at:light:dark:) for the desktop to use" >&2
    exit 2
fi
sed -e '/^@main$/d' -e "s/^$INDEX\$/${INDEX/private /}/" -e "s/^$MAKE\$/${MAKE/private /}/" Safelight/Safelight.swift >"$BUILD_DIR/src/Safelight.swift"

cp scripts/screenshots/Info.plist "$APP/Contents/Info.plist"
# The menu bar icon is a symbol in the asset catalog
if ! xcrun actool Safelight/Assets.xcassets --compile "$APP/Contents/Resources" --platform macosx \
        --minimum-deployment-target 15.5 --output-partial-info-plist "$BUILD_DIR/assets.plist" >"$BUILD_DIR/actool.log" 2>&1; then
    echo "Couldn't compile the asset catalog (full log: $BUILD_DIR/actool.log)" >&2
    exit 2
fi
if ! xcrun swiftc -swift-version 5 -Onone -o "$APP/Contents/MacOS/$NAME" \
        "$BUILD_DIR/src/Safelight.swift" scripts/screenshots/*.swift >"$BUILD_DIR/build.log" 2>&1; then
    echo "Screenshot app build failed (full log: $BUILD_DIR/build.log):" >&2
    grep -E 'error:' "$BUILD_DIR/build.log" | sort -u | head -20 >&2
    exit 2
fi

# Every way Safelight changes the Mac must lead to NoSystemChanges.swift, not to the system
if nm -u "$APP/Contents/MacOS/$NAME" | grep -E '_dlopen$|_CGSetDisplay|_CGDisplayRestore|_CGConfigure|_SLS|_DisplayServices|_MADisplayFilter' >&2; then
    echo "The screenshot app could still change the system's settings through the functions above" >&2
    exit 2
fi
# Signed with your Apple Development certificate if you have one, so Screen Recording access, once
# granted, stays granted: macOS knows an app signed ad hoc only by a hash of its code, which every build
# changes, so it would ask again each time.
IDENTITY=$(security find-identity -v -p codesigning | awk '/"Apple Development: / { print $2; exit }')
if [[ -z "$IDENTITY" ]] || ! codesign --force --sign "$IDENTITY" --timestamp=none "$APP" 2>/dev/null; then
    codesign --force --sign - "$APP" 2>/dev/null
    echo "Signed ad hoc, so macOS will ask for Screen Recording access again" >&2
fi

# Opened with `open`, as only an app macOS launches that way can be sure of becoming active, and only an
# active app's controls are drawn in the accent colour. Once for each appearance, in American English,
# as the README is, with 24-hour times.
if [[ "${1:-}" == --desktop ]]; then
    CANVASES=540x675,1128x678
    if [[ $# -ge 2 && $2 != dark && $2 != light ]]; then
        echo "The appearance is dark or light, not $2" >&2
        exit 2
    fi
    appearances=(dark light)
    if [[ $# -ge 2 ]]; then appearances=($2); fi
    for appearance in $appearances; do
        LOG="$BUILD_DIR/screenshots-$appearance-desktop.log"
        rm -f "$LOG"
        open -W -n --stdout "$LOG" --stderr "$LOG" "$APP" --args -appearance $appearance \
            -AppleLanguages '(en-US)' -AppleLocale en_GB -output "$PWD/$OUT" \
            -desktopLight "/System/Library/Desktop Pictures/.wallpapers/Sonoma Horizon/Sonoma Horizon.heic" \
            -desktopDark "${DARK_WALLPAPER:A}" -canvases $CANVASES $SCHEDULE_ARGS $CLOCK_ARGS
        for shot in popover-$appearance-desktop-540x675 popover-$appearance-desktop-1128x678 schedule-$appearance-desktop-1128x678; do
            if [[ ! -f "$OUT/$shot.png" ]]; then
                echo "Screenshots failed (full log: $LOG):" >&2
                cat "$LOG" >&2
                exit 2
            fi
        done
    done
    echo "Wrote the pictures over a desktop to $OUT"
    exit 0
fi
for appearance in dark light; do
    LOG="$BUILD_DIR/screenshots-$appearance.log"
    rm -f "$LOG"
    open -W -n --stdout "$LOG" --stderr "$LOG" "$APP" --args -appearance $appearance \
        -AppleLanguages '(en-US)' -AppleLocale en_GB -output "$PWD/$OUT" $SCHEDULE_ARGS $CLOCK_ARGS
    for shot in popover-$appearance schedule-$appearance; do
        if [[ ! -f "$OUT/$shot.png" ]]; then
            echo "Screenshots failed (full log: $LOG):" >&2
            cat "$LOG" >&2
            exit 2
        fi
    done
done
if [[ -n "$SCHEDULE" || -n "$CLOCK" ]]; then
    # The README's are of the default schedule, at 21:00
    echo "Wrote the screenshots${SCHEDULE:+ with the schedule of $SCHEDULE}${CLOCK:+ at $CLOCK} to $OUT"
    exit 0
fi
changed=()
for shot in $SHOTS; do
    if [[ -f "docs/$shot.png" ]] && "$APP/Contents/MacOS/$NAME" -compare "docs/$shot.png" "$OUT/$shot.png"; then
        continue
    fi
    cp "$OUT/$shot.png" docs/
    changed+=("docs/$shot.png")
done
if (( ${#changed} )); then
    echo "Screenshots changed: ${changed[*]}"
else
    echo "Screenshots unchanged."
fi
