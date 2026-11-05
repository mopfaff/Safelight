#!/bin/zsh
# Draws Safelight's Clock Appearance… popover, and compares it with System Settings' own.
#
#   scripts/clock-appearance.sh                writes build/clock-appearance/light.png and dark.png: the
#                                              popover at 2x, with the clock macOS has (FONT=soft…rail,
#                                              WEIGHT=0…1 for another)
#   scripts/clock-appearance.sh --gallery      the Wallpaper window with the popover open, its pictures
#                                              showing the lock screen, in Light and Dark
#   scripts/clock-appearance.sh --compare      opens System Settings › Wallpaper › Clock Appearance… with
#                                              Accessibility (System Settings open on Wallpaper), captures
#                                              its popover and its picture with the lock screen, closes it,
#                                              and draws Safelight's popover from a button at the same spot,
#                                              over a capture of System Settings' window, so the glass has
#                                              the same colours behind it, in the appearance the Mac has;
#                                              then diffs the two
#
# It builds a copy of Safelight.swift into build/clock-appearance/Clock.app, with its own settings, whose
# stubs.swift stands in for CFPreferencesSetValue and AuthorizationCopyRights, so it can't change the
# clock or ask for a password, and scripts/screenshots/NoSystemChanges.swift for the colour filter,
# brightness and appearance. Its windows stay in the background. It uses scripts/screen-saver-sheet's
# Accessibility tools, and tools/axcancel, which closes System Settings' popover.

set -eu
cd "${0:A:h}/.."

DIR="build/clock-appearance"
APP="$DIR/Clock.app"
ID="test.safelight.clockappearance"
TOOLS="build/screen-saver-sheet/tools"
mkdir -p "$APP/Contents/MacOS" "$DIR/src" "$TOOLS"

if [[ $(grep -c '^@main$' Safelight/Safelight.swift) != 1 ]]; then
    echo "Couldn't find Safelight's @main line to leave out" >&2
    exit 2
fi
sed '/^@main$/d' Safelight/Safelight.swift >"$DIR/src/Safelight.swift"
cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$ID</string>
<key>CFBundleExecutable</key><string>Clock</string>
<key>CFBundleName</key><string>Clock</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
if ! xcrun swiftc -swift-version 5 -Onone -o "$APP/Contents/MacOS/Clock" "$DIR/src/Safelight.swift" scripts/clock-appearance/main.swift \
        scripts/clock-appearance/stubs.swift scripts/screenshots/NoSystemChanges.swift >"$DIR/build.log" 2>&1; then
    echo "Build failed (full log: $DIR/build.log):" >&2
    grep -E 'error:' "$DIR/build.log" | sort -u | head -20 >&2
    exit 2
fi
if nm -u "$APP/Contents/MacOS/Clock" | grep -E '^_kill$|_dlopen$|^_CFPreferencesSetValue$|^_AuthorizationCopyRights$' >&2; then
    echo "The copy could still change the clock or the system's settings" >&2
    exit 2
fi
codesign --force --sign - "$APP" 2>/dev/null
for tool in screen-saver-sheet/tools/axdump screen-saver-sheet/tools/axpress clock-appearance/tools/axcancel; do
    [[ "$TOOLS/${tool:t}" -nt "scripts/$tool.swift" ]] || xcrun swiftc -O -o "$TOOLS/${tool:t}" "scripts/$tool.swift"
done
cleanup() {
    defaults delete "$ID" >/dev/null 2>&1 || true
    rm -rf "$HOME/Library/Caches/$ID"
}
trap cleanup EXIT

case "${1:-}" in
--gallery)
    for appearance in light dark; do
        DELAY=5 "$APP/Contents/MacOS/Clock" gallery $appearance "$PWD/$DIR/gallery-$appearance.png" &
        copy=$!
        sleep 2.5
        "$TOOLS/axpress" $copy "Clock Appearance…" >/dev/null
        wait $copy
    done
    ;;
--compare)
    pid=$(pgrep -x "System Settings") || { echo "Open System Settings › Wallpaper first" >&2; exit 2; }
    window_info() {
        python3 -c "
import Quartz
for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, 0):
    b = w['kCGWindowBounds']
    if w.get('kCGWindowOwnerPID') == $pid and w.get('kCGWindowLayer') == 0 and b['Height'] > 500:
        print(w['kCGWindowNumber'], int(b['X']), int(b['Y']), int(b['Width']), int(b['Height'])); break"
    }
    read window x y w h <<<$(window_info)
    "$TOOLS/axpress" $pid "Clock Appearance…" >/dev/null
    sleep 1.5
    # The popover's frame and the button's, in points from the window's top left
    "$TOOLS/axdump" $pid 40 >"$DIR/system-settings-ax.txt"
    popover=$(awk '/AXPopover/ { gsub(/[\[\],]/, ""); print $2, $3, $4, $6; exit }' "$DIR/system-settings-ax.txt")
    anchor=$(awk '/AXButton "Clock Appearance…"/ { gsub(/[\[\],]/, ""); print $(NF-4) "," $(NF-3) "," $(NF-2) "," $NF; exit }' "$DIR/system-settings-ax.txt")
    screencapture -x -o -l $window "$DIR/system-settings-window.png"
    read px py pw ph <<<"$popover"
    python3 - "$DIR" $px $py $pw $ph <<'PY'
import sys
from PIL import Image
d, px, py, pw, ph = sys.argv[1], *map(float, sys.argv[2:])
im = Image.open(f'{d}/system-settings-window.png')
im.crop((int(px * 2), int(py * 2), int((px + pw) * 2), int((py + ph) * 2))).save(f'{d}/system-settings.png')
# The picture of the desktop with the lock screen over it (System Settings' pane header)
im.crop((265 * 2, 68 * 2, 425 * 2, 168 * 2)).save(f'{d}/system-settings-preview.png')
PY
    # System Settings' window without the popover, which Safelight's popover lies over
    "$TOOLS/axcancel" $pid
    sleep 1
    screencapture -x -o -l $window "$DIR/backdrop.png"
    screen=$(python3 -c "import AppKit; print(int(AppKit.NSScreen.screens()[0].frame().size.height))")
    appearance=$(defaults read -g AppleInterfaceStyle 2>/dev/null | tr 'A-Z' 'a-z' || true)
    [[ "$appearance" == dark ]] || appearance=light
    ORIGIN="$x,$((screen - y - h)),$w,$h" BACKDROP="$PWD/$DIR/backdrop.png" ANCHOR="$anchor" \
        "$APP/Contents/MacOS/Clock" popover $appearance "$PWD/$DIR/safelight.png"
    python3 scripts/clock-appearance/diff.py "$DIR/system-settings.png" "$DIR/safelight.png" "$DIR/difference.png"
    ;;
*)
    for appearance in light dark; do
        "$APP/Contents/MacOS/Clock" popover $appearance "$PWD/$DIR/$appearance.png"
    done
    ;;
esac
