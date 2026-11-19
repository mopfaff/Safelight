#!/bin/zsh
# Makes a demo shot of Safelight's real popover, frame by frame, from a scene file: the UI moving as
# the scene has the pointer move it, and, for a scene on the desktop, videos of the whole screen as the
# display shows it with what Safelight sets on each frame.
#
#   scripts/make-demo.sh <scene>    records scripts/demo/scenes/<scene>.json into build/demo/<scene>/:
#                                   frames/0000.png… (Display P3, at twice the size in points, see-through
#                                   where the popover isn't, unless it's on the desktop) and log.json, frame
#                                   by frame: the pointer, each slider's value and where its knob is drawn,
#                                   and the color filter, brightness and appearance Safelight has set, with
#                                   the calls it made. For a scene with "desktop": true, also desktop.png,
#                                   and scripts/demo/compose.py makes its videos from them: <scene>-16x9.mkv
#                                   and the rest, as its "camera" has them, and stills/
#   scripts/make-demo.sh --camera 16:9 <scene>
#                                   makes only that one of the scene's cameras' videos, when an edit needs
#                                   no other: half the frames to make. With --verify or --draft too.
#   scripts/make-demo.sh --draft <scene>
#                                   makes a small video to look at while working on a scene, in a fraction
#                                   of the time: every fourth frame at half the size, into build/demo/drafts/
#                                   <scene>/ (<scene>-16x9-draft.mp4, stills/), leaving the shot in
#                                   build/demo/<scene>/ as it was
#   scripts/make-demo.sh --verify <scene>
#                                   makes it twice and says whether the two are the same, byte for byte
#   scripts/make-demo.sh --record <scene>
#                                   only records it, without making its videos, into build/demo/recorder/
#                                   recorded/<scene>/, leaving the shot in build/demo/<scene>/ as it was
#   scripts/make-demo.sh --check <scene> [light|dark] [independently]
#                                   compares the recorder's first frame of a scene on the desktop, with the
#                                   window server's shadow added, against the window server's own picture
#                                   of the popover over the same desktop, in the scene's appearance or the
#                                   one given (build/demo/<scene>/check-<appearance>/), and with the displays
#                                   adjusted independently if asked, which makes the popover taller
#                                   (check-<appearance>-independently/). The popover and the desktop round it
#                                   are on the Retina display for a second, behind other windows; the
#                                   displays have to be awake.
#   scripts/make-demo.sh --edit [<edit>...]
#                                   cuts the demo videos from the finished shots' masters, as each
#                                   scripts/demo/edits/<edit>.json has it (all of them if none is named):
#                                   build/demo/edits/<edit>/safelight-<edit>.mp4, with stills/ and sheet.png
#                                   (scripts/demo/edit.py). --edit verify [<edit>...] decodes them as macOS's
#                                   players do and compares them with the frames they were made from
#
# It builds a copy of Safelight.swift into "Safelight Demo Recorder.app" with scripts/demo/recorder/,
# whose RecordedSystem.swift stands in for the functions that change the color filter, brightness and
# appearance, so the Mac is left as it was, and scripts/screenshots/FixedTime.swift. The recorder opens
# the popover invisibly and draws it off screen, so nothing shows and it never becomes the active app;
# it needs a Retina display, as the frames are drawn at its scale. Nothing in a frame depends on the
# time it's recorded at: SwiftUI runs on its clock for tests, from the same time as every shot begins
# (recorder/main.swift, SwiftUITime), and the main thread reads the scene's time from every clock
# (recorder/Interposers.c), so the same scene on the same Mac gives the same frames, byte for byte,
# with the Mac idle or with every core busy; --verify makes a shot twice to check. (Until 2026-11-19
# SwiftUI's time began wherever the real clock had left it as the popover opened, and a slider's knob
# was drawn a little differently from one recording to the next: intensity-drag's from frame 170 on,
# color-filter's from frame 128.) Composing a recording gives the same videos every time. The displays
# in the Brightness section are this Mac's, and the scene's brightness is the one they start at. For a
# scene with "otherDisplays": true, the Mac's other displays are drawn as well, each with its own
# desktop, and compose.py puts them beside the popover's as they're arranged, each dimmed as it's dimmed.
# The window server draws a shadow and rims round the popover's window, which the frames don't have.
# For a scene on the desktop they're taken from the window server once for each appearance and size of
# popover, and over each desktop it's on (each picture of the wallpaper the recording shows under it),
# into build/demo/window-server/, with the popover on the Retina display for a second, which needs the
# displays awake; after that, making a shot shows nothing.

set -eu
cd "${0:A:h}/.."

# The demo itself, cut from the finished shots: scripts/demo/edit.py, after Safelight's icon is drawn for
# its end card, as macOS draws an app's, by an app with the icon (scripts/demo/EditIcon.swift)
if [[ "${1-}" == --edit ]]; then
    shift
    ICON_DIR="build/demo/edits/icon"
    ICON_NAME="Safelight Edit Icon"
    ICON_APP="$ICON_DIR/$ICON_NAME.app"
    rm -rf "$ICON_DIR"
    mkdir -p "$ICON_APP/Contents/MacOS" "$ICON_APP/Contents/Resources"
    PLIST="$ICON_APP/Contents/Info.plist"
    plutil -create xml1 "$PLIST"
    for key value in CFBundleExecutable "$ICON_NAME" CFBundleIconFile AppIcon CFBundleIconName AppIcon \
            CFBundleIdentifier Mo.Safelight.EditIcon CFBundleName "$ICON_NAME" CFBundlePackageType APPL; do
        plutil -insert "$key" -string "$value" "$PLIST"
    done
    plutil -insert LSUIElement -bool YES "$PLIST"
    if ! xcrun actool "$PWD/Safelight/AppIcon.icon" --compile "$PWD/$ICON_APP/Contents/Resources" --platform macosx --minimum-deployment-target 15.5 \
            --app-icon AppIcon --output-partial-info-plist "$PWD/$ICON_DIR/icon.plist" >"$ICON_DIR/actool.log" 2>&1; then
        echo "Couldn't compile the app icon (full log: $ICON_DIR/actool.log)" >&2
        exit 2
    fi
    if ! xcrun swiftc -swift-version 5 -O -o "$ICON_APP/Contents/MacOS/$ICON_NAME" scripts/demo/EditIcon.swift >"$ICON_DIR/build.log" 2>&1; then
        echo "Icon app build failed (full log: $ICON_DIR/build.log)" >&2
        exit 2
    fi
    codesign --force --sign - "$ICON_APP" 2>/dev/null
    # Without this macOS may not have looked at the new app yet, and draws its icon with a no-entry sign
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$ICON_APP"
    "$ICON_APP/Contents/MacOS/$ICON_NAME" "$PWD/$ICON_DIR/icon.png"
    exec python3 scripts/demo/edit.py "$@"
fi

VERIFY=0 CHECK=0 RECORD_ONLY=0 DRAFT=0 CAMERA=""
# What compose.py is told besides the scene: which camera, and whether it's a draft
COMPOSE=()
while [[ "${1-}" == --* ]]; do
    case $1 in
        --verify) VERIFY=1 ;;
        --record) RECORD_ONLY=1 ;;
        --check) CHECK=1 ;;
        --draft) DRAFT=1 COMPOSE+=(--draft) ;;
        --camera)
            CAMERA=${2-}
            COMPOSE+=(--camera "$CAMERA")
            (( $# > 1 )) && shift ;;
        *) break ;;
    esac
    shift
done
if (( VERIFY + CHECK + RECORD_ONLY + DRAFT > 1 )) || (( $# != 1 && !(CHECK && ($# == 2 || $# == 3)) )) || [[ $# == 3 && "${3-}" != independently ]] ||
        { (( ${#COMPOSE} )) && (( CHECK || RECORD_ONLY )) }; then
    echo "Usage: scripts/make-demo.sh [--verify | --draft] [--camera 16:9|9:16] <scene> | --record <scene> | --check <scene> [light|dark] [independently], the scene one of: ${(j:, :)${(@)${(f)$(ls scripts/demo/scenes)}:r}}" >&2
    exit 2
fi
SCENE=$1
SCENE_FILE="scripts/demo/scenes/$SCENE.json"
if [[ ! -f "$SCENE_FILE" ]]; then
    echo "There's no $SCENE_FILE" >&2
    exit 2
fi
# Said now, not after the recording
if (( ${#COMPOSE} )) && ! python3 -c 'import json, sys; sys.exit(sys.argv[2] not in json.load(open(sys.argv[1])).get("camera", {}))' "$SCENE_FILE" "${CAMERA:-16:9}" 2>/dev/null; then
    if [[ -n "$CAMERA" ]]; then
        echo "$SCENE_FILE has no $CAMERA camera" >&2
    else
        echo "$SCENE_FILE has no camera to make a draft's video with" >&2
    fi
    exit 2
fi

BUILD_DIR="build/demo/recorder"
NAME="Safelight Demo Recorder"
APP="$BUILD_DIR/$NAME.app"
OUT="build/demo/$SCENE"

rm -rf "$APP" "$BUILD_DIR/src"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" "$BUILD_DIR/src" "$OUT"

# The recorder has an entry point of its own instead of Safelight's, and draws the desktop with the
# wallpaper's picture for the scene's appearance as Safelight picks it (recorder/Desktop.swift), from a
# wallpaper it makes as Safelight does when the scene has one picture for Light and another for Dark
INDEX='    private static func index(in source: CGImageSource, isDark: Bool) -> Int {'
PICTURE='    private static func picture(in source: CGImageSource, at index: Int, maxPixelSize: Int? = nil) -> CGImage? {'
MAKE='    private static func makeWallpaper(at wallpaper: URL, light: (file: URL, isDark: Bool), dark: (file: URL, isDark: Bool)) -> Bool {'
if [[ $(grep -c '^@main$' Safelight/Safelight.swift) != 1 ]]; then
    echo "Couldn't find Safelight's @main line to leave out" >&2
    exit 2
fi
if [[ $(grep -cxF "$INDEX" Safelight/Safelight.swift) != 1 || $(grep -cxF "$PICTURE" Safelight/Safelight.swift) != 1 || $(grep -cxF "$MAKE" Safelight/Safelight.swift) != 1 ]]; then
    echo "Couldn't find WallpaperManager's index(in:isDark:), picture(in:at:maxPixelSize:) and makeWallpaper(at:light:dark:) for the desktop to use" >&2
    exit 2
fi
sed -e '/^@main$/d' -e "s/^$INDEX\$/${INDEX/private /}/" -e "s/^$PICTURE\$/${PICTURE/private /}/" -e "s/^$MAKE\$/${MAKE/private /}/" Safelight/Safelight.swift >"$BUILD_DIR/src/Safelight.swift"

cp scripts/demo/recorder/Info.plist "$APP/Contents/Info.plist"
# The menu bar icon is a symbol in the asset catalog. With whole paths, as actool hands relative ones to
# Xcode's ibtoold, which takes them from the folder of whoever started it, another project's maybe.
if ! xcrun actool "$PWD/Safelight/Assets.xcassets" --compile "$PWD/$APP/Contents/Resources" --platform macosx \
        --minimum-deployment-target 15.5 --output-partial-info-plist "$PWD/$BUILD_DIR/assets.plist" >"$BUILD_DIR/actool.log" 2>&1; then
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
run() {
    local scene=$1 out=$2 log=$3
    shift 3
    if ! "$APP/Contents/MacOS/$NAME" -scene "$PWD/$scene" -output "$PWD/$out" "$@" \
            -AppleAccentColor "${ACCENT_COLORS[$ACCENT]}" -AppleLanguages "($(setting language en-US))" -AppleLocale "$(setting locale en_GB)" >"$log" 2>&1; then
        echo "Recording $SCENE failed (full log: $log):" >&2
        grep -v '^$' "$log" | tail -20 >&2
        exit 2
    fi
}
ON_DESKTOP=$(setting desktop false)
# What the window server draws round the popover, taken unless it has been for this appearance and size,
# over the desktop as it is in that appearance, or with the wallpaper's picture for the other one given,
# and with the displays adjusted independently or not, as -adjustsDisplaysIndependently YES or NO says,
# which makes the popover taller or not (Safelight reads it as it opens)
windowServer() {
    local scene=$1
    shift
    run "$scene" "$OUT" "$BUILD_DIR/$SCENE-window-server.log" -windowServer "$PWD/build/demo/window-server" "$@"
    grep -E '^(Captured|The window server)' "$BUILD_DIR/$SCENE-window-server.log"
}

if (( CHECK )); then
    if [[ "$ON_DESKTOP" != true ]]; then
        echo "--check compares a scene on the desktop; $SCENE_FILE hasn't \"desktop\": true" >&2
        exit 2
    fi
    APPEARANCE=${2:-$(setting appearance dark)}
    SIZE=() SUFFIX=""
    if [[ "${3-}" == independently ]]; then
        SIZE=(-adjustsDisplaysIndependently YES) SUFFIX="-independently"
    fi
    CHECK_SCENE="$BUILD_DIR/check/$SCENE.json"
    mkdir -p "$BUILD_DIR/check"
    cp "$SCENE_FILE" "$CHECK_SCENE"
    plutil -replace appearance -string "$APPEARANCE" "$CHECK_SCENE"
    windowServer "$CHECK_SCENE" "${SIZE[@]}"
    CHECK_OUT="$OUT/check-$APPEARANCE$SUFFIX"
    run "$CHECK_SCENE" "$CHECK_OUT" "$BUILD_DIR/$SCENE-check.log" -check YES "${SIZE[@]}"
    python3 scripts/demo/compose.py check "$SCENE" --folder "$CHECK_OUT"
    exit 0
fi

# Made in a folder of its own, which takes the place of the shot's once it's done, so a shot made from
# an older recording is never left beside a newer one. On the desktop, the window server's pictures of
# the popover over it are taken first for every appearance of the popover and picture of the wallpaper
# the recording has (compose.py needs).
shoot() {
    local out=$1
    rm -rf "$out.new"
    mkdir -p "$out.new"
    run "$SCENE_FILE" "$out.new" "$BUILD_DIR/$SCENE.log"
    grep -E '^(Recorded|The main queue|AppKit|The scene.s clock)' "$BUILD_DIR/$SCENE.log"
    if [[ "$ON_DESKTOP" == true ]] && (( !RECORD_ONLY )); then
        python3 scripts/demo/compose.py needs "$SCENE" --folder "$out.new" | while read -r appearance wallpaper independently; do
            windowServer "$SCENE_FILE" -appearance "$appearance" -wallpaperAppearance "$wallpaper" -adjustsDisplaysIndependently "$independently"
        done
        python3 scripts/demo/compose.py "$SCENE" --folder "$out.new" "${COMPOSE[@]}"
    fi
    rm -rf "$out"
    mv "$out.new" "$out"
}
if (( RECORD_ONLY )); then
    shoot "$BUILD_DIR/recorded/$SCENE"
    exit 0
fi
if (( DRAFT )); then
    shoot "build/demo/drafts/$SCENE"
    exit 0
fi
shoot "$OUT"

if (( VERIFY )); then
    AGAIN="$BUILD_DIR/again/$SCENE"
    shoot "$AGAIN"
    # All but a wallpaper the recorder made of two pictures, which ImageIO writes with 4 bytes that differ
    # every time; its pictures decode the same, and the desktop drawn from them is compared
    if differing=$(diff -rq -x wallpaper.heic "$OUT" "$AGAIN"); then
        echo "Made again: the same, byte for byte"
    else
        echo "Made again, and these differ:" >&2
        echo "$differing" | awk '{ print $2 }' | xargs -n 1 basename | tr '\n' ' ' >&2
        echo >&2
        exit 1
    fi
fi
