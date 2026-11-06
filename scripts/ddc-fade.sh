#!/bin/zsh
# Presses the brightness keys and drags a slider for the first external monitor Safelight sets over
# DDC, as with Adjust Independently on and the pointer over it, and logs each brightness written to the
# monitor and when: a key press fades it as macOS fades an Apple display (macOS's own curve is printed
# under each write to compare), and a slider sets it once a frame.
#
#   scripts/ddc-fade.sh
#
# It builds a copy of Safelight.swift (build/ddc-fade/) whose pointer is over the monitor, which can't
# catch the real keys, and which loads only IOKit and CoreDisplay, so the Studio Display, the color
# filter and the appearance are left as they are. The monitor's brightness really changes for a few
# seconds and is put back where it was. The copy has settings of its own (ddc-fade), emptied after.
# A Safelight that's running reads the monitor once a second and may move its slider meanwhile.

set -eu
cd "${0:A:h}/.."

DIR="build/ddc-fade"
mkdir -p "$DIR"

if [[ $(grep -c '^@main$' Safelight/Safelight.swift) != 1 ]]; then
    echo "Couldn't find Safelight's @main line to leave out" >&2
    exit 2
fi
# The pointer the brightness keys look under
POINTER='NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }),'
if [[ $(grep -cF "$POINTER" Safelight/Safelight.swift) != 1 ]]; then
    echo "Couldn't find where the brightness keys look for the pointer" >&2
    exit 2
fi
sed -e '/^@main$/d' -e "s/NSMouseInRect(NSEvent.mouseLocation, \\\$0.frame, false) }),\$/NSMouseInRect(fakePointer, \$0.frame, false) }),/" \
    Safelight/Safelight.swift >"$DIR/Safelight.swift"

if ! xcrun swiftc -swift-version 5 -Onone -o "$DIR/ddc-fade" "$DIR/Safelight.swift" scripts/ddc-fade/main.swift >"$DIR/build.log" 2>&1; then
    echo "Build failed (full log: $DIR/build.log):" >&2
    grep -E 'error:' "$DIR/build.log" | sort -u | head -20 >&2
    exit 2
fi
# Nothing but the monitor's own brightness may change
if nm -u "$DIR/ddc-fade" | grep -E '_CGSetDisplay|_CGDisplayRestore|_CGConfigure|_SLS|_DisplayServices|_MADisplayFilter|_AXIsProcessTrusted' >&2; then
    echo "The copy could still change the system's settings through the functions above" >&2
    exit 2
fi

"$DIR/ddc-fade" || STATUS=$?
defaults delete ddc-fade 2>/dev/null || true
exit ${STATUS:-0}
