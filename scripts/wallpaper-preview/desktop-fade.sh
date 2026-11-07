#!/bin/zsh
# Measures WallpaperAgent's own fade on the real desktop, which System Settings › Wallpaper's picture of
# the desktop shows live: puts a picture on the main display's current Space for a few seconds while
# filming WallpaperAgent's window for that display (desktop-fade.swift), then puts everything back. It
# changes the real desktop, so only run it once the user has said yes. The main display must be showing
# a desktop Space, not a full-screen app: on 2026-11-07 it was covered (what's under every window came
# back a flat grey), and the agent took the change ("legacyContentUpdate") but drew nothing new, so
# nothing could be filmed.
#
#   scripts/wallpaper-preview/desktop-fade.sh [picture]   default: Solid Colors/Red Orange.png
#
# Before: backs up the wallpaper store, Safelight's wallpapers and its settings, and logs what
# WallpaperAgent says each Space shows. After: copies the store back and restarts WallpaperAgent (which
# reads it again), checks Safelight's wallpapers and settings are as they were, and logs each Space
# again. Results go to build/wallpaper-preview/desktop-fade/.

set -eu
cd "${0:A:h}/../.."
picture=${1:-"/System/Library/Desktop Pictures/Solid Colors/Red Orange.png"}
DIR="$PWD/build/wallpaper-preview/desktop-fade"
rm -rf "$DIR"
mkdir -p "$DIR/backup"
STORE="$HOME/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
OWN="$HOME/Library/Application Support/Mo.Safelight/Wallpapers"

# The tool, as an .app of its own, which sets the picture, and run from here, which films it
APP="$DIR/DesktopFade.app"
mkdir -p "$APP/Contents/MacOS"
cat >"$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>test.safelight.desktopfade</string>
<key>CFBundleExecutable</key><string>DesktopFade</string>
<key>CFBundleName</key><string>DesktopFade</string>
<key>LSUIElement</key><true/>
</dict></plist>
EOF
xcrun swiftc -O -o "$APP/Contents/MacOS/DesktopFade" scripts/wallpaper-preview/desktop-fade.swift
clang -fobjc-arc -framework Foundation -framework CoreGraphics -framework ColorSync -o "$DIR/spaces" scripts/wallpaper-preview/spaces.m

# Backups, right before
cp "$STORE" "$DIR/backup/Index.plist"
ditto "$OWN" "$DIR/backup/Wallpapers"
defaults export Mo.Safelight "$DIR/backup/Mo.Safelight.plist"
"$DIR/spaces" >"$DIR/spaces-before.txt"

restore() {
    cp "$DIR/backup/Index.plist" "$STORE"
    killall -9 WallpaperAgent || true
    sleep 4
    "$DIR/spaces" >"$DIR/spaces-after.txt"
    if diff -q "$DIR/spaces-before.txt" "$DIR/spaces-after.txt" >/dev/null; then
        echo "every Space shows what it did before"
    else
        echo "Spaces differ from before:"; diff "$DIR/spaces-before.txt" "$DIR/spaces-after.txt" || true
    fi
    if diff -rq "$DIR/backup/Wallpapers" "$OWN" >/dev/null; then
        echo "Safelight's wallpapers are as they were"
    else
        echo "Safelight's wallpapers changed:"; diff -rq "$DIR/backup/Wallpapers" "$OWN" || true
    fi
    defaults export Mo.Safelight "$DIR/Mo.Safelight-after.plist"
    for key in WallpaperChoicesByWallpaper WallpaperShowsOnAllSpaces WallpaperShuffles WallpaperShufflesByDisplay; do
        if [[ "$(/usr/libexec/PlistBuddy -x -c "Print :$key" "$DIR/backup/Mo.Safelight.plist" 2>&1)" != "$(/usr/libexec/PlistBuddy -x -c "Print :$key" "$DIR/Mo.Safelight-after.plist" 2>&1)" ]]; then
            echo "Safelight's $key changed; the backup is $DIR/backup/Mo.Safelight.plist"
        fi
    done
    defaults delete test.safelight.desktopfade >/dev/null 2>&1 || true
}
trap restore EXIT

# Filmed from here, which may record the screen; set from the .app
"$APP/Contents/MacOS/DesktopFade" film "$APP" "$picture" "$DIR/desktop" | tee "$DIR/log.txt"
