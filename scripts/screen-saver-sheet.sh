#!/bin/zsh
# Draws Safelight's Screen Saver… sheet in Light and in Dark, and compares it with System Settings' own.
#
#   scripts/screen-saver-sheet.sh [choice]            writes build/screen-saver-sheet/light.png and dark.png:
#                                                     the sheet at 2x, with `choice` as both appearances'
#                                                     screen saver (saver:Drift, drawn:sequoia,
#                                                     screen-saver:automatic…), or else the one macOS has
#   scripts/screen-saver-sheet.sh --compare [choice]  captures System Settings › Wallpaper › Screen Saver…
#                                                     (System Settings open on Wallpaper; it's opened with
#                                                     Accessibility if it isn't), draws Safelight's at the
#                                                     same place on the screen, in the appearance the Mac
#                                                     has, and diffs them from the grouped box down
#   scripts/screen-saver-sheet.sh --gallery           the Wallpaper window, with its Screen Saver… button
#
# For --compare, macOS's screen saver must be the one given: set it in System Settings, or replay a store
# with scripts/screen-saver-sheet/tools/safeapply.sh (back the store up first). It builds a copy of
# Safelight.swift into build/screen-saver-sheet/Sheet.app, with its own settings, whose stubs.swift
# stands in for kill(), so it can't restart WallpaperAgent, and scripts/screenshots/NoSystemChanges.swift
# for the colour filter, brightness and appearance. Its windows stay in the background. The tools/ beside
# it, built into build/screen-saver-sheet/tools/, read the wallpaper store (dump.py), System Settings'
# sheet (axdump, axpress), and how the desktop looks as WallpaperAgent restarts (flicker).

set -eu
cd "${0:A:h}/.."

DIR="build/screen-saver-sheet"
APP="$DIR/Sheet.app"
ID="test.safelight.screensaversheet"
mkdir -p "$APP/Contents/MacOS" "$DIR/src" "$DIR/tools"

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
<key>CFBundleExecutable</key><string>Sheet</string>
<key>CFBundleName</key><string>Sheet</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
if ! xcrun swiftc -swift-version 5 -Onone -o "$APP/Contents/MacOS/Sheet" "$DIR/src/Safelight.swift" scripts/screen-saver-sheet/main.swift \
        scripts/screen-saver-sheet/stubs.swift scripts/screenshots/NoSystemChanges.swift >"$DIR/build.log" 2>&1; then
    echo "Build failed (full log: $DIR/build.log):" >&2
    grep -E 'error:' "$DIR/build.log" | sort -u | head -20 >&2
    exit 2
fi
if nm -u "$APP/Contents/MacOS/Sheet" | grep -E '^_kill$|_dlopen$' >&2; then
    echo "The copy could still restart WallpaperAgent or change the system's settings" >&2
    exit 2
fi
codesign --force --sign - "$APP" 2>/dev/null
for tool in axdump axpress flicker; do
    [[ "$DIR/tools/$tool" -nt "scripts/screen-saver-sheet/tools/$tool.swift" ]] || xcrun swiftc -O -o "$DIR/tools/$tool" "scripts/screen-saver-sheet/tools/$tool.swift"
done
cleanup() {
    defaults delete "$ID" >/dev/null 2>&1 || true
    rm -rf "$HOME/Library/Caches/$ID"
}
trap cleanup EXIT

case "${1:-}" in
--gallery)
    for appearance in light dark; do
        GALLERY=1 "$APP/Contents/MacOS/Sheet" $appearance "$PWD/$DIR/gallery-$appearance.png"
    done
    ;;
--compare)
    choice=${2:-}
    pid=$(pgrep -x "System Settings") || { echo "Open System Settings › Wallpaper first" >&2; exit 2; }
    "$DIR/tools/axpress" $pid "Screen Saver…" >/dev/null || true
    sleep 1.5
    # System Settings' window, and the sheet in it, where AppKit has them
    read window x y <<<$(python3 -c "
import Quartz
for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, 0):
    b = w['kCGWindowBounds']
    if w.get('kCGWindowOwnerPID') == $pid and w.get('kCGWindowLayer') == 0 and b['Height'] > 500:
        print(w['kCGWindowNumber'], int(b['X']), int(b['Y'])); break")
    sheet=$("$DIR/tools/axdump" $pid 1 | awk 'NR == 1 { gsub(/[\[\],]/, ""); print $2, $3, $4, $6 }')
    read sx sy sw sh <<<"$sheet"
    screencapture -x -o -l $window "$DIR/system-settings-window.png"
    python3 -c "
from PIL import Image
Image.open('$DIR/system-settings-window.png').crop((int($sx * 2), int($sy * 2), int(($sx + $sw) * 2), int(($sy + $sh) * 2))).save('$DIR/system-settings.png')"
    appearance=$(defaults read -g AppleInterfaceStyle 2>/dev/null | tr 'A-Z' 'a-z' || true)
    [[ "$appearance" == dark ]] || appearance=light
    # The window behind Safelight's sheet put so the sheet lands on System Settings' (AppKit's y is from the bottom)
    screen=$(python3 -c "import AppKit; print(int(AppKit.NSScreen.screens()[0].frame().size.height))")
    ORIGIN="$((x + ${sx%.*} - 4)),$((screen - y - ${sy%.*} + 28 - 752))" "$APP/Contents/MacOS/Sheet" $appearance "$PWD/$DIR/safelight.png" ${choice:+"$choice"}
    python3 scripts/screen-saver-sheet/tools/diff.py "$DIR/system-settings.png" "$DIR/safelight.png" "$DIR/difference.png"
    ;;
*)
    for appearance in light dark; do
        "$APP/Contents/MacOS/Sheet" $appearance "$PWD/$DIR/$appearance.png" ${1:+"$1"}
    done
    ;;
esac
