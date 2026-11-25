#!/bin/zsh
# Builds Safelight (Release) for Apple silicon and Intel, signed with Safelight's own certificate
# rather than an Apple Developer ID, and puts it in a disk image for a GitHub release, with the
# update feed that tells copies already installed about it. Then it draws the README's screenshots
# again with scripts/screenshots.sh, so they show the version released.
#
#   scripts/release.sh        writes build/release/Safelight.app, Safelight-<version>.dmg and
#                             appcast.xml, and any screenshots in docs/ that have changed

set -eu
cd "${0:A:h}/.."

BUILD_DIR="build"
OUT="$BUILD_DIR/release"
LOG="$BUILD_DIR/release-build.log"
APP="$BUILD_DIR/Build/Products/Release/Safelight.app"

mkdir -p "$OUT"

# macOS keeps the Accessibility permission the brightness keys need for as long as the app's signature
# names the same signer. Every version, and every build from Xcode, is signed with the self-signed
# "Safelight" certificate, so the permission carries over. Its key is backed up in
# ~/.config/safelight/code-signing.p12 and kept in safelight-signing.keychain-db, a keychain with
# no password that the scheme's build pre-action unlocks, so codesign never stops to ask for one.
# Without it, the build is signed ad hoc, which names this one build alone: anyone else's copy
# works, but a release signed so would lose the permission at every update.
IDENTITY=-
if security find-identity -v -p codesigning | grep -q '"Safelight"'; then
    IDENTITY=Safelight
else
    echo "No trusted \"Safelight\" signing certificate here, so this build is signed ad hoc." >&2
fi

# The generic destination builds every architecture; without it, xcodebuild builds only this Mac's.
# Xcode would also let debuggers attach (get-task-allow), as it does to any build not signed for the
# App Store or Developer ID; a release keeps that out, as other apps could then act with its permission.
if ! xcodebuild -project Safelight.xcodeproj -scheme Safelight -configuration Release \
        -destination 'generic/platform=macOS' -derivedDataPath "$BUILD_DIR" \
        CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
        CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build >"$LOG" 2>&1; then
    echo "Safelight build failed (full log: $LOG):" >&2
    grep -E 'error:' "$LOG" | sort -u | head -20 >&2
    exit 2
fi
codesign --verify --deep --strict "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="$OUT/Safelight-$VERSION.dmg"
STAGE="$OUT/disk-image"
rm -rf "$OUT/Safelight.app" "$STAGE" "$DMG"
ditto "$APP" "$OUT/Safelight.app"

# The disk image's window: Safelight beside a link to Applications, laid out by
# scripts/dmg/DS_Store (which scripts/make-dmg-layout.py writes).
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Safelight.app"
ln -s /Applications "$STAGE/Applications"
cp scripts/dmg/DS_Store "$STAGE/.DS_Store"
hdiutil create -quiet -volname Safelight -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
rm -rf "$STAGE"
echo "Safelight $VERSION ($(lipo -archs "$OUT/Safelight.app/Contents/MacOS/Safelight")): $DMG"

# The update feed, appcast.xml, goes on the GitHub release beside the disk image. Each copy of
# Safelight reads the latest release's (SUFeedURL in Safelight/Info.plist) and installs the disk image
# it points to, but only if Sparkle's sign_update signed it with the private key that goes with
# SUPublicEDKey. The key is a file outside the repository (SPARKLE_KEY to use another), read from
# there so signing doesn't stop to ask for the keychain's password. Without it, a copy that's already
# installed can't be updated again, so keep a copy somewhere safe.
SPARKLE="$BUILD_DIR/SourcePackages/artifacts/sparkle/Sparkle/bin"
KEY="${SPARKLE_KEY:-$HOME/.config/safelight/sparkle-private-key}"
APPCAST="$OUT/appcast.xml"
rm -f "$APPCAST"
if [[ -f "$KEY" ]] && SIGNATURE=$("$SPARKLE/sign_update" --ed-key-file "$KEY" "$DMG"); then
    INFO="$OUT/Safelight.app/Contents/Info.plist"
    # Sparkle goes by the build number (CURRENT_PROJECT_VERSION), not the version people see, so
    # raise it for every disk image put out, even one that keeps the version, or no copy will update.
    BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$INFO")
    MINIMUM_SYSTEM=$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$INFO")
    RELEASE="https://github.com/mopfaff/Safelight/releases"
    cat >"$APPCAST" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Safelight</title>
        <link>$RELEASE</link>
        <item>
            <title>Safelight $VERSION</title>
            <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
            <sparkle:version>$BUILD_NUMBER</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$MINIMUM_SYSTEM</sparkle:minimumSystemVersion>
            <sparkle:fullReleaseNotesLink>$RELEASE/tag/v$VERSION</sparkle:fullReleaseNotesLink>
            <enclosure url="$RELEASE/download/v$VERSION/Safelight-$VERSION.dmg" $SIGNATURE type="application/octet-stream"/>
        </item>
    </channel>
</rss>
EOF
    # Signed as well (SURequireSignedFeed), so no one else can change what it says about the update
    "$SPARKLE/sign_update" --ed-key-file "$KEY" "$APPCAST" >/dev/null
    echo "Update feed for $VERSION: $APPCAST (attach it to the v$VERSION release with the disk image, then run scripts/update-tap.sh)"
else
    echo "No update feed: couldn't sign the disk image with Sparkle's private key ($KEY)" >&2
fi

scripts/screenshots.sh || echo "The screenshots weren't drawn again; the disk image is ready all the same." >&2
