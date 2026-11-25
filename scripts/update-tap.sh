#!/bin/zsh
# Updates Casks/safelight.rb in mopfaff/homebrew-tap to match the build in build/release/
# (or the live v1.0 release on GitHub if --from-release is passed). Run right after uploading
# a new Safelight-<version>.dmg to the GitHub release so the cask's version and sha256 stay in sync.
#
#   scripts/update-tap.sh                 read version/build/sha256 from build/release/
#   scripts/update-tap.sh --from-release  read version/build/sha256 from the live GitHub release

set -eu
cd "${0:A:h}/.."

TAP_REPO="mopfaff/homebrew-tap"
CASK_PATH="Casks/safelight.rb"

if [[ "${1:-}" == "--from-release" ]]; then
    APPCAST=$(curl -fsSL "https://github.com/mopfaff/Safelight/releases/latest/download/appcast.xml")
    VERSION=$(echo "$APPCAST" | sed -n 's/.*<sparkle:shortVersionString>\([^<]*\)<\/sparkle:shortVersionString>.*/\1/p' | head -1)
    BUILD_NUMBER=$(echo "$APPCAST" | sed -n 's/.*<sparkle:version>\([^<]*\)<\/sparkle:version>.*/\1/p' | head -1)
    SHA256=$(gh release view "v$VERSION" --repo mopfaff/Safelight --json assets \
        --jq ".assets[] | select(.name == \"Safelight-$VERSION.dmg\") | .digest" | sed 's/^sha256://')
else
    INFO="build/release/Safelight.app/Contents/Info.plist"
    if [[ ! -f "$INFO" ]]; then
        echo "Missing $INFO — run scripts/release.sh first, or pass --from-release." >&2
        exit 1
    fi
    VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$INFO")
    BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$INFO")
    DMG="build/release/Safelight-$VERSION.dmg"
    if [[ ! -f "$DMG" ]]; then
        echo "Missing $DMG — run scripts/release.sh first." >&2
        exit 1
    fi
    SHA256=$(shasum -a 256 "$DMG" | awk '{print $1}')

    # Make sure the uploaded GitHub release asset already matches before updating the tap.
    REMOTE_SHA=$(gh release view "v$VERSION" --repo mopfaff/Safelight --json assets \
        --jq ".assets[] | select(.name == \"Safelight-$VERSION.dmg\") | .digest" | sed 's/^sha256://')
    if [[ -n "$REMOTE_SHA" && "$REMOTE_SHA" != "$SHA256" ]]; then
        echo "GitHub release v$VERSION has sha256 $REMOTE_SHA, but local $DMG has $SHA256." >&2
        echo "Upload $DMG to v$VERSION before updating $TAP_REPO." >&2
        exit 1
    fi
fi

if [[ -z "$VERSION" || -z "$BUILD_NUMBER" || -z "$SHA256" ]]; then
    echo "Could not resolve version ($VERSION), build ($BUILD_NUMBER), or sha256 ($SHA256)." >&2
    exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

gh repo clone "$TAP_REPO" "$TMP/tap" -- --quiet
cd "$TMP/tap"
git config user.name "mopfaff"
git config user.email "179018332+mopfaff@users.noreply.github.com"

sed -i '' -E \
    -e "s/^  version \".*\"/  version \"$VERSION,$BUILD_NUMBER\"/" \
    -e "s/^  sha256 \".*\"/  sha256 \"$SHA256\"/" \
    "$CASK_PATH"

if git diff --quiet -- "$CASK_PATH"; then
    echo "$TAP_REPO is already at $VERSION,$BUILD_NUMBER ($SHA256)."
    exit 0
fi

git add "$CASK_PATH"
git commit -m "Update Safelight to $VERSION,$BUILD_NUMBER"
git push origin main
echo "Updated $TAP_REPO to $VERSION,$BUILD_NUMBER ($SHA256)."
