#!/usr/bin/env bash
#
# Build a signed, notarised, stapled DMG of PRReview, refresh Casks/prreview.rb
# with the new version + sha256, and print the follow-up git/gh commands.
#
# One-time setup:
#
#   1. Apple Developer account, with a "Developer ID Application" certificate
#      installed in your login keychain.
#
#   2. Store an App Store Connect API key (or app-specific password) under a
#      keychain profile so notarytool can pick it up non-interactively:
#
#        xcrun notarytool store-credentials prreview-notary \
#          --apple-id "<your-apple-id>" \
#          --team-id "<your-team-id>" \
#          --password "<app-specific-password>"
#
#   3. Install create-dmg:
#
#        brew install create-dmg
#
#   4. Export the three env vars (e.g. in ~/.zshrc):
#
#        export DEVELOPMENT_TEAM="ABCDE12345"
#        export SIGNING_IDENTITY="Developer ID Application: Your Name (ABCDE12345)"
#        export NOTARY_PROFILE="prreview-notary"
#
# Usage:
#
#   scripts/release.sh 0.1.0
#

set -euo pipefail

: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your 10-char Apple team ID}"
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Developer ID Application identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to the keychain profile name created via xcrun notarytool store-credentials}"

VERSION="${1:?Usage: scripts/release.sh <version> (e.g. 0.1.0)}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

BUILD_DIR="build/release"
ARCHIVE="$BUILD_DIR/PRReview-$VERSION.xcarchive"
EXPORT_DIR="$BUILD_DIR/export-$VERSION"
APP_PATH="$EXPORT_DIR/PRReview.app"
ZIP_PATH="$BUILD_DIR/PRReview-$VERSION.zip"
DMG_PATH="$BUILD_DIR/PRReview-$VERSION.dmg"
EXPORT_OPTS="$BUILD_DIR/ExportOptions.plist"
CASK="Casks/prreview.rb"

if ! command -v create-dmg >/dev/null; then
    echo "create-dmg is not installed. Run: brew install create-dmg" >&2
    exit 1
fi

mkdir -p "$BUILD_DIR"
rm -rf "$ARCHIVE" "$EXPORT_DIR" "$ZIP_PATH" "$DMG_PATH"

if command -v xcodegen >/dev/null; then
    xcodegen generate
fi

echo "==> Archiving Release build for $VERSION"
xcodebuild \
    -project PRReview.xcodeproj \
    -scheme PRReview \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    MARKETING_VERSION="$VERSION" \
    archive

cat >"$EXPORT_OPTS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$DEVELOPMENT_TEAM</string>
    <key>signingStyle</key><string>manual</string>
</dict>
</plist>
EOF

echo "==> Exporting signed .app"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTS"

if [ ! -d "$APP_PATH" ]; then
    echo "Expected $APP_PATH not found after export" >&2
    exit 1
fi

echo "==> Zipping for notarytool"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Submitting to Apple notary service (this can take several minutes)"
xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

echo "==> Stapling notarisation ticket"
xcrun stapler staple "$APP_PATH"

echo "==> Building DMG"
create-dmg \
    --volname "PR Review $VERSION" \
    --window-size 540 380 \
    --icon-size 96 \
    --icon "PRReview.app" 140 190 \
    --app-drop-link 400 190 \
    "$DMG_PATH" \
    "$APP_PATH"

SHA=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')

echo "==> Updating $CASK"
python3 - "$CASK" "$VERSION" "$SHA" <<'PY'
import sys, re, pathlib
path, version, sha = sys.argv[1], sys.argv[2], sys.argv[3]
text = pathlib.Path(path).read_text()
text = re.sub(r'^( *version )".*"', rf'\1"{version}"', text, count=1, flags=re.MULTILINE)
text = re.sub(r'^( *sha256 )(:no_check|".*")', rf'\1"{sha}"', text, count=1, flags=re.MULTILINE)
pathlib.Path(path).write_text(text)
PY

echo ""
echo "Release artifacts:"
echo "  DMG:    $DMG_PATH"
echo "  sha256: $SHA"
echo "  cask:   $CASK (updated)"
echo ""
echo "Next steps:"
echo "  git add $CASK"
echo "  git commit -m \"release: v$VERSION\" --no-verify"
echo "  git tag v$VERSION"
echo "  git push origin main v$VERSION"
echo "  gh release create v$VERSION $DMG_PATH --title \"v$VERSION\" --notes \"Release v$VERSION\""
echo ""
echo "Then users can install via:"
echo "  brew tap ordishs/code-reviewer https://github.com/ordishs/code-reviewer"
echo "  brew install --cask prreview"
