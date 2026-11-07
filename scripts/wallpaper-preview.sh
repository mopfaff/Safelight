#!/bin/zsh
# Picks wallpapers for Light, as the Wallpaper window's tiles do, and logs what the appearance's picture
# (the Wallpaper window's preview, and the popover's) shows meanwhile: when each picture came, its size,
# when the wallpaper was on the desktop, and how far each picture is from the one before, filled into
# the 160 by 100 pt preview at 2x, in levels. Each picture is written to build/wallpaper-preview/ as a PNG.
#
#   scripts/wallpaper-preview.sh list                     lists what can be picked: its ID, kind, whether
#                                                         it's on the Mac or fetched, and whether it can
#                                                         be placed
#   scripts/wallpaper-preview.sh <id>[@dark|@fit] ...     picks each for Light, one after the other, after
#                                                         a colour to start from; @dark with its Dark
#                                                         picture, @fit fitted on a red fill
#   scripts/wallpaper-preview.sh --against <ref> <id> ... the same first with Safelight.swift as it was at
#                                                         a commit, to compare before and after
#
#   e.g. scripts/wallpaper-preview.sh --against HEAD~1 aerial:4207734D-74FE-4F92-B5E1-6EC8DEE24A15 'picture:Mac Blue@fit'
#
# It builds copies of Safelight.swift whose desktop is a variable: putting a wallpaper on the desktop
# sets it, and reading the desktop reads it, so the Mac's own wallpaper is left as it was. They make
# their wallpapers in their own folder in build/wallpaper-preview/, stand in for the color filter,
# brightness and appearance with scripts/screenshots/NoSystemChanges.swift, and have settings of their
# own (wallpaper-preview-current and -against), emptied after each run. They show no window. A
# wallpaper that isn't on the Mac is fetched from Apple's, as Safelight fetches it.

set -eu
cd "${0:A:h}/.."

DIR="build/wallpaper-preview"
mkdir -p "$DIR"

# Builds a copy of a Safelight.swift into $DIR/<name>/
build() {
    local name=$1 source=$2
    local copy="$DIR/$name"
    rm -rf "$copy"
    mkdir -p "$copy"
    sed -e '/^@main$/d' \
        -e 's|NSScreen.screens.compactMap(NSWorkspace.shared.desktopImageURL(for:))|[fakeDesktop].compactMap { $0 }|' \
        -e 's|NSWorkspace.shared.desktopImageURL(for: screen)|fakeDesktop|g' \
        -e 's|try NSWorkspace.shared.setDesktopImageURL(file, for: screen, options: options)|fakeDesktop = file; fakeSets.append(file)|' \
        -e "s|private let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?|private let folder = Optional(URL(fileURLWithPath: \"$PWD/$copy\", isDirectory: true))?|" \
        "$source" >"$copy/Safelight.swift"
    # Every way it reads or changes the desktop must lead to the variable
    local replaced
    for replaced in 'fakeDesktop = file; fakeSets.append(file)' '[fakeDesktop].compactMap { $0 }' "$PWD/$copy"; do
        if ! grep -qF "$replaced" "$copy/Safelight.swift"; then
            echo "$name's Safelight.swift doesn't read or change the desktop as this script expects; update its seds" >&2
            exit 2
        fi
    done
    if grep -n 'desktopImageURL(for\|setDesktopImageURL' "$copy/Safelight.swift" | grep -v '///' >&2; then
        echo "$name's copy could still read or change the desktop through the lines above" >&2
        exit 2
    fi
    if ! xcrun swiftc -swift-version 5 -Onone -o "$copy/wallpaper-preview-$name" \
            "$copy/Safelight.swift" scripts/wallpaper-preview/main.swift scripts/screenshots/NoSystemChanges.swift >"$copy/build.log" 2>&1; then
        echo "Couldn't build $name's copy (full log: $copy/build.log):" >&2
        grep -E 'error:' "$copy/build.log" | sort -u | head -20 >&2
        exit 2
    fi
    if nm -u "$copy/wallpaper-preview-$name" | grep -E '_dlopen$|_CGSetDisplay|_CGDisplayRestore|_CGConfigure|_SLS|_DisplayServices|_MADisplayFilter' >&2; then
        echo "$name's copy could still change the system's settings through the functions above" >&2
        exit 2
    fi
}

# Runs a copy with the arguments given, from no settings and no wallpapers of its own. Its log keeps
# Safelight's own messages but not the system's.
run() {
    local name=$1
    shift
    local binary="$DIR/$name/wallpaper-preview-$name"
    rm -rf "$DIR/$name/Safelight" "$DIR/$name"/*.png(N)
    defaults delete "${binary:t}" >/dev/null 2>&1 || true
    "$binary" "$DIR/$name" "$@" 2>&1 | awk '!/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] / || /Safelight:/'
    defaults delete "${binary:t}" >/dev/null 2>&1 || true
}

against=""
if [[ "${1:-}" == "--against" ]]; then
    against=${2:?"--against needs a commit"}
    shift 2
fi
if (( $# == 0 )); then
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
fi

if [[ -n "$against" ]]; then
    git show "$against:Safelight/Safelight.swift" >"$DIR/against.swift"
    build against "$DIR/against.swift"
fi
build current Safelight/Safelight.swift
if [[ -n "$against" ]]; then
    echo "=== $against"
    run against "$@"
    echo
    echo "=== working tree"
fi
run current "$@"
