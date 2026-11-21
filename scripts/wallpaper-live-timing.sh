#!/bin/zsh
# Times how long a wallpaper picked in Safelight takes to reach the real desktop: picks seven, as the
# Wallpaper window's tiles do, with Show on all Spaces on, three one at a time and three in a row, and
# sets when each was picked against WallpaperAgent's own log of when it had its picture for each display.
#
#   scripts/wallpaper-live-timing.sh             times Safelight.swift as it is
#   scripts/wallpaper-live-timing.sh <commit>    times it as it was at a commit
#
# IT CHANGES THE REAL WALLPAPER of every display and Space for about a minute, so ask before running
# it. Then it puts the desktop back as it was: macOS's wallpaper store from a copy made at the start,
# and WallpaperAgent restarted to read it, which turns the displays grey for a third of a second. It
# says whether every Space shows what it showed before. Safelight is quit meanwhile, as it would take
# the test's wallpaper for one of System Settings' and turn its own Show on all Spaces off, and
# launched again afterwards.
#
# It builds a copy of Safelight.swift with its own bundle ID (test.safelight.livetiming), so its
# wallpapers and settings are its own, taken away at the end, with scripts/screenshots/NoSystemChanges.swift
# standing in for the color filter, brightness and appearance. Everything is kept in
# build/wallpaper-live-timing/: the store's copy (Index.plist), what each Space showed before and after,
# the app's log (app.txt), WallpaperAgent's (agent.txt) and the times (printed, and in times.txt).

set -eu
cd "${0:A:h}/.."

DIR="$PWD/build/wallpaper-live-timing"
SRC="scripts/wallpaper-live-timing"
ID="test.safelight.livetiming"
APP="$DIR/LiveTiming.app"
STORE="$HOME/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
mkdir -p "$DIR"

source="Safelight/Safelight.swift"
if [[ -n "${1:-}" ]]; then
    git show "$1:Safelight/Safelight.swift" >"$DIR/Safelight-ref.swift"
    source="$DIR/Safelight-ref.swift"
fi

# The copy: its requests to macOS logged, and nothing read from other apps' containers, which macOS
# would ask the user about
rm -rf "$APP" "$DIR/src"
mkdir -p "$APP/Contents/MacOS" "$DIR/src"
sed -e '/^@main$/d' \
    -e 's|try NSWorkspace.shared.setDesktopImageURL(file, for: screen, options: options)|liveSet(file, screen, options); try NSWorkspace.shared.setDesktopImageURL(file, for: screen, options: options)|' \
    -e 's|        YourPhotos.shared.reloadAfterSettingWallpaper()|        _ = 0|' \
    "$source" >"$DIR/src/Safelight.swift"
for replaced in 'liveSet(file, screen, options); try' '        _ = 0'; do
    if ! grep -qF "$replaced" "$DIR/src/Safelight.swift"; then
        echo "Safelight.swift doesn't put wallpapers on the desktop as this script expects; update its seds" >&2
        exit 2
    fi
done
cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$ID</string>
<key>CFBundleExecutable</key><string>livetiming</string>
<key>CFBundleName</key><string>LiveTiming</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
if ! xcrun swiftc -swift-version 5 -Onone -o "$APP/Contents/MacOS/livetiming" \
        "$DIR/src/Safelight.swift" "$SRC/main.swift" scripts/screenshots/NoSystemChanges.swift >"$DIR/build.log" 2>&1; then
    echo "Couldn't build the copy (full log: $DIR/build.log):" >&2
    grep -E 'error:' "$DIR/build.log" | sort -u | head -20 >&2
    exit 2
fi
if nm -u "$APP/Contents/MacOS/livetiming" | grep -E '_dlopen$|_CGSetDisplay|_CGDisplayRestore|_CGConfigure|_SLS|_DisplayServices|_MADisplayFilter' >&2; then
    echo "The copy could still change the system's settings through the functions above" >&2
    exit 2
fi
codesign --force --sign - "$APP" 2>/dev/null
xcrun clang -fobjc-arc -framework Foundation -framework CoreGraphics -framework ColorSync -o "$DIR/spaces" "$SRC/spaces.m"

# Safelight quit, and what it puts on the desktop as it quits there, before the copy of the store
safelight=$(ps -axo comm= | grep '/Safelight.app/Contents/MacOS/Safelight$' | head -1 || true)
if [[ -n "$safelight" ]]; then
    killall Safelight 2>/dev/null || true
    for _ in {1..50}; do pgrep -xq Safelight || break; sleep 0.1; done
    sleep 4
fi
cp "$STORE" "$DIR/Index.plist"
"$DIR/spaces" >"$DIR/spaces-before.txt"
echo "Before: $(wc -l <"$DIR/spaces-before.txt" | tr -d ' ') Spaces and displays, showing $(awk '{print $NF}' "$DIR/spaces-before.txt" | sort -u | wc -l | tr -d ' ') different files"

restore() {
    pkill -f "$APP/Contents/MacOS/livetiming" 2>/dev/null || true
    cp "$DIR/Index.plist" "$STORE"
    killall -9 WallpaperAgent 2>/dev/null || true
    sleep 5
    "$DIR/spaces" >"$DIR/spaces-after.txt"
    if cmp -s "$DIR/spaces-before.txt" "$DIR/spaces-after.txt" && [[ -s "$DIR/spaces-after.txt" ]]; then
        echo "Put back: every Space shows what it showed before"
    else
        echo "NOT AS BEFORE: what the Spaces show differs (before, after):" >&2
        diff "$DIR/spaces-before.txt" "$DIR/spaces-after.txt" >&2 || true
    fi
    python3 "$SRC/storediff.py" "$DIR/Index.plist" "$STORE" --ignore-dates
    rm -rf "$HOME/Library/Application Support/$ID"
    defaults delete "$ID" >/dev/null 2>&1 || true
    if [[ -n "$safelight" ]]; then
        open "${safelight%/Contents/MacOS/Safelight}" || echo "Couldn't launch Safelight again: ${safelight%/Contents/MacOS/Safelight}" >&2
    fi
}

defaults delete "$ID" >/dev/null 2>&1 || true
rm -rf "$HOME/Library/Application Support/$ID"
# `open` adds to the files it's given
rm -f "$DIR/app.txt" "$DIR/app-errors.txt"
start=$(date '+%Y-%m-%d %H:%M:%S')
{
    open -W -n --stdout "$DIR/app.txt" --stderr "$DIR/app-errors.txt" "$APP"
    sleep 1
    /usr/bin/log show --start "$start" --style compact --info --debug --predicate 'process == "WallpaperAgent"' >"$DIR/agent.txt" 2>/dev/null
} always {
    restore
}
python3 "$SRC/times.py" "$DIR/app.txt" "$DIR/agent.txt" | tee "$DIR/times.txt"
