#!/bin/zsh
# Presses the brightness keys and drags a slider for the first external monitor Safelight sets over
# DDC, as with Adjust Independently on and the pointer over it, and logs each brightness written to the
# monitor and when: a key press writes its step once, a slider its latest value at most every 50 ms.
# How fast the monitor's light then follows, scripts/display-light.sh measures.
#
#   scripts/ddc-writes.sh
#
# It builds a copy of Safelight.swift (build/ddc-writes/) whose pointer is over the monitor, which can't
# catch the real keys, and which loads only IOKit and CoreDisplay, so the Studio Display, the color
# filter and the appearance are left as they are. The monitor's brightness really changes for a few
# seconds and is put back where it was. The copy has settings of its own (ddc-writes), emptied after.
# A Safelight that's running reads the monitor once a second and may move its slider meanwhile.

set -eu
cd "${0:A:h}/.."

DIR="build/ddc-writes"
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

if ! xcrun swiftc -swift-version 5 -Onone -o "$DIR/ddc-writes" "$DIR/Safelight.swift" scripts/ddc-writes/main.swift >"$DIR/build.log" 2>&1; then
    echo "Build failed (full log: $DIR/build.log):" >&2
    grep -E 'error:' "$DIR/build.log" | sort -u | head -20 >&2
    exit 2
fi
# Nothing but the monitor's own brightness may change
if nm -u "$DIR/ddc-writes" | grep -E '_CGSetDisplay|_CGDisplayRestore|_CGConfigure|_SLS|_DisplayServices|_MADisplayFilter|_AXIsProcessTrusted' >&2; then
    echo "The copy could still change the system's settings through the functions above" >&2
    exit 2
fi

"$DIR/ddc-writes" || STATUS=$?
defaults delete ddc-writes 2>/dev/null || true
exit ${STATUS:-0}
