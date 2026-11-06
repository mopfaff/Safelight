#!/bin/zsh
# Measures how fast each display's light really changes, which no software reading shows: the Studio
# Display camera watches the room and whoever's in front, lit by the displays. With one display covered
# white and the other black, each in turn has its picture blacked out and back at once (the reference,
# as fast as the camera and the panel go), then its brightness set from full to the lowest and back, and
# to half and back, in one go, as a click on a slider does: the Dell over DDC (one write, again 50 ms
# later, as Safelight writes), the Studio Display through DisplayServices. For each step it prints when
# the light got 10, 50 and 90% of the way, and the curve.
#
#   scripts/display-light.sh                  measures, flashing both screens for about 36 seconds
#   scripts/display-light.sh --attachments    only shows what the camera sends with a frame
#
# The camera sets its exposure itself, whatever it's asked, so the light is measured where the display
# lights the room most over where it lights it least (see scripts/display-light/main.swift). Only those
# measurements are kept, never a frame.
#
# It runs as an app of its own, Display Light (build/display-light/), signed with the Safelight
# certificate, as macOS only asks for camera access for an app opened normally (not for one started
# from Claude Code's shell); the first run asks once. Both displays' brightness is put back after.
#
# On 2026-11-06 the Studio Display's light got there within two frames of starting to change; the Dell
# SE2216H's moved about 30 of its 100 steps a second, taking 1.4 to 1.9 s for half its range.

set -eu
cd "${0:A:h}/.."

DIR="build/display-light"
APP="$DIR/Display Light.app"
mkdir -p "$APP/Contents/MacOS"
cp scripts/display-light/Info.plist "$APP/Contents/Info.plist"
if ! xcrun swiftc -O -o "$APP/Contents/MacOS/display-light" scripts/display-light/main.swift >"$DIR/build.log" 2>&1; then
    echo "Build failed (full log: $DIR/build.log):" >&2
    grep -E 'error:' "$DIR/build.log" | sort -u | head -20 >&2
    exit 2
fi
# Signed as Safelight is, so camera access, once given, stays given when it's rebuilt
if ! codesign --force --sign Safelight "$APP" 2>"$DIR/codesign.log"; then
    echo "Couldn't sign with the Safelight certificate, so signing ad hoc (macOS asks again after each build)" >&2
    codesign --force --sign - "$APP"
fi

rm -f "$DIR/result.txt"
open -g -W -n --stdout "$DIR/result.txt" --stderr "$DIR/result.txt" "$APP" --args "$@"
cat "$DIR/result.txt"
