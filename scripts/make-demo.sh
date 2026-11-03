#!/bin/zsh
# Records a demo shot of Safelight's real popover, frame by frame, from a scene file: the UI moving as
# the scene has the pointer move it, and what Safelight would apply to the Mac on each frame.
#
#   scripts/make-demo.sh <scene>    records scripts/demo/scenes/<scene>.json into build/demo/<scene>/:
#                                   frames/0000.png… (Display P3, at twice the size in points, see-through
#                                   where the popover isn't) and log.json, frame by frame: the pointer,
#                                   each slider's value and where its knob is drawn, and the color filter,
#                                   brightness and appearance Safelight has set, with the calls it made
#   scripts/make-demo.sh --verify <scene>
#                                   records it twice and says whether the two are the same, byte for byte
#
# It builds a copy of Safelight.swift into "Safelight Demo Recorder.app" with scripts/demo/recorder/,
# whose RecordedSystem.swift stands in for the functions that change the color filter, brightness and
# appearance, so the Mac is left as it was, and scripts/screenshots/FixedTime.swift. The recorder opens
# the popover invisibly and draws it off screen, so nothing shows and it never becomes the active app;
# it needs a Retina display, as the frames are drawn at its scale. Nothing in a frame depends on the
# time it's recorded at: SwiftUI runs on its clock for tests, and the main thread reads the scene's
# time from every clock (recorder/Interposers.c), so the same scene on the same Mac gives the same
# frames, byte for byte. Run at a background priority (taskpolicy -b), the knob's settling after a
# drag came out a tenth of a point off; --verify finds that. The displays in the Brightness section are
# this Mac's, and the scene's brightness is the one they start at.
# For now it only records: the color filter and brightness are applied to the frames afterwards
# (scripts/demo/pipeline.py).

set -eu
cd "${0:A:h}/.."

VERIFY=0
if [[ "${1-}" == --verify ]]; then
    VERIFY=1
    shift
fi
if (( $# != 1 )); then
    echo "Usage: scripts/make-demo.sh [--verify] <scene>, one of: ${(j:, :)${(@)${(f)$(ls scripts/demo/scenes)}:r}}" >&2
    exit 2
fi
SCENE=$1
SCENE_FILE="scripts/demo/scenes/$SCENE.json"
if [[ ! -f "$SCENE_FILE" ]]; then
    echo "There's no $SCENE_FILE" >&2
    exit 2
fi

BUILD_DIR="build/demo/recorder"
NAME="Safelight Demo Recorder"
APP="$BUILD_DIR/$NAME.app"
OUT="build/demo/$SCENE"

rm -rf "$APP" "$BUILD_DIR/src"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" "$BUILD_DIR/src" "$OUT"

# The recorder has an entry point of its own instead of Safelight's
if [[ $(grep -c '^@main$' Safelight/Safelight.swift) != 1 ]]; then
    echo "Couldn't find Safelight's @main line to leave out" >&2
    exit 2
fi
sed '/^@main$/d' Safelight/Safelight.swift >"$BUILD_DIR/src/Safelight.swift"

cp scripts/demo/recorder/Info.plist "$APP/Contents/Info.plist"
# The menu bar icon is a symbol in the asset catalog
if ! xcrun actool Safelight/Assets.xcassets --compile "$APP/Contents/Resources" --platform macosx \
        --minimum-deployment-target 15.5 --output-partial-info-plist "$BUILD_DIR/assets.plist" >"$BUILD_DIR/actool.log" 2>&1; then
    echo "Couldn't compile the asset catalog (full log: $BUILD_DIR/actool.log)" >&2
    exit 2
fi
# Interposers.c, a dylib of its own, as only another image can interpose: the scene's clock on the main
# thread, and the popover's key appearance kept from the window server
if ! xcrun clang -dynamiclib -O2 -undefined dynamic_lookup -install_name @rpath/libInterposers.dylib \
        -o "$APP/Contents/Frameworks/libInterposers.dylib" scripts/demo/recorder/Interposers.c >"$BUILD_DIR/build.log" 2>&1 ||
   ! xcrun swiftc -swift-version 5 -Onone -o "$APP/Contents/MacOS/$NAME" -import-objc-header scripts/demo/recorder/Interposers.h \
        -L"$APP/Contents/Frameworks" -lInterposers -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
        "$BUILD_DIR/src/Safelight.swift" scripts/demo/recorder/*.swift scripts/screenshots/FixedTime.swift >>"$BUILD_DIR/build.log" 2>&1; then
    echo "Recorder build failed (full log: $BUILD_DIR/build.log):" >&2
    grep -E 'error:' "$BUILD_DIR/build.log" | sort -u | head -20 >&2
    exit 2
fi

# Every way Safelight changes the Mac must lead to RecordedSystem.swift, not to the system. The real
# dlsym is still there, but only for the compiler's own `#available` checks, which look up
# _availability_version_check with it; the recorder checks on opening that the app gets the stand-ins.
if nm -u "$APP/Contents/MacOS/$NAME" | grep -E '_dlopen$|_CGSetDisplay|_CGDisplayRestore|_CGConfigure|_SLS|_DisplayServices|_MADisplayFilter|_AXIsProcessTrusted' >&2; then
    echo "The recorder could still change the system's settings through the functions above" >&2
    exit 2
fi
codesign --force --sign - "$APP/Contents/Frameworks/libInterposers.dylib" "$APP" 2>/dev/null

# AppKit reads the accent colour, language and region as the app opens
setting() { plutil -extract "$1" raw -o - "$SCENE_FILE" 2>/dev/null || echo "$2" }
typeset -A ACCENT_COLORS=(graphite -1 red 0 orange 1 yellow 2 green 3 blue 4 purple 5 pink 6)
ACCENT=$(setting accentColor blue)
if [[ -z "${ACCENT_COLORS[$ACCENT]-}" ]]; then
    echo "$SCENE_FILE's accentColor is $ACCENT, not one of ${(kj:, :)ACCENT_COLORS}" >&2
    exit 2
fi

# Run directly rather than with `open`, as it never needs to be the active app
record() {
    local out=$1 log=$2
    if ! "$APP/Contents/MacOS/$NAME" -scene "$PWD/$SCENE_FILE" -output "$PWD/$out" \
            -AppleAccentColor "${ACCENT_COLORS[$ACCENT]}" -AppleLanguages "($(setting language en-US))" -AppleLocale "$(setting locale en_GB)" >"$log" 2>&1; then
        echo "Recording $SCENE failed (full log: $log):" >&2
        grep -v '^$' "$log" | tail -20 >&2
        exit 2
    fi
}
record "$OUT" "$BUILD_DIR/$SCENE.log"
grep '^Recorded' "$BUILD_DIR/$SCENE.log"

if (( VERIFY )); then
    AGAIN="$BUILD_DIR/again/$SCENE"
    rm -rf "$AGAIN"
    mkdir -p "$AGAIN"
    record "$AGAIN" "$BUILD_DIR/$SCENE-again.log"
    if differing=$(diff -rq "$OUT" "$AGAIN"); then
        echo "Recorded again: the same, byte for byte"
    else
        echo "Recorded again, and these differ:" >&2
        echo "$differing" | awk '{ print $2 }' | xargs -n 1 basename | tr '\n' ' ' >&2
        echo >&2
        exit 1
    fi
fi
