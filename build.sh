#!/usr/bin/env bash
# Build Quill.app and install it to ~/Applications.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Quill"
# Single source of truth: the app, the menu and the release tag all read this.
VERSION="$(cat VERSION 2>/dev/null || echo 0.0.0)"
BUNDLE_ID="com.freeze.quill"
BUILD="build"
APP="$BUILD/$APP_NAME.app"
DEST="$HOME/Applications/$APP_NAME.app"

echo "→ compiling"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal: Apple Silicon AND Intel. Building arm64-only means every Intel Mac
# gets an app that refuses to launch, with no useful error.
# Asked for by name: a bare `--show-sdk-path` can resolve to a Command Line
# Tools SDK that no longer exists after an Xcode update, and the build dies there.
SDK="$(xcrun --sdk macosx --show-sdk-path)"
for ARCH in arm64 x86_64; do
  swiftc \
    -swift-version 5 \
    -O \
    -target "$ARCH-apple-macos12.0" \
    -sdk "$SDK" \
    -framework Cocoa -framework AVFoundation -framework QuartzCore \
    -framework CoreAudio -framework AudioToolbox -framework NaturalLanguage \
    Sources/*.swift \
    -o "$BUILD/$APP_NAME-$ARCH"
done
lipo -create -output "$APP/Contents/MacOS/$APP_NAME" \
  "$BUILD/$APP_NAME-arm64" "$BUILD/$APP_NAME-x86_64"
rm -f "$BUILD/$APP_NAME-arm64" "$BUILD/$APP_NAME-x86_64"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Quill records your voice and streams it to Grok speech-to-text, using your Grok Build session.</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>Live translation listens to what your Mac is playing — a call, a video — and streams it to Grok to transcribe and translate.</string>
  <key>NSHumanReadableCopyright</key><string>freeze</string>
</dict>
</plist>
PLIST

# A STABLE code identity is the whole point here. Ad-hoc signing derives the
# designated requirement from the binary hash, so every rebuild looks like a
# brand-new app to macOS: Accessibility and Microphone grants silently stop
# applying and the old rows linger in System Settings looking enabled.
# Signing with a fixed self-signed cert pins the requirement to the certificate.
# The identity lives in a DEDICATED keychain whose password is known to this
# script, and codesign is pre-authorised for it via set-key-partition-list.
# In the login keychain it would prompt for the password on every single build.
SIGN_ID="Quill Local Signing"
SIGN_KEYCHAIN="$HOME/Library/Keychains/quill-signing.keychain-db"
if [ -f "$SIGN_KEYCHAIN" ]; then
  echo "→ signing as '$SIGN_ID' (stable identity, no password prompt)"
  security unlock-keychain -p quill "$SIGN_KEYCHAIN" 2>/dev/null || true
  # Re-assert codesign's access every build. If this lapses — or a stray copy of
  # the identity ends up in the login keychain — macOS blocks the build on a
  # password dialog instead of failing, and the build appears to hang forever.
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k quill \
    "$SIGN_KEYCHAIN" >/dev/null 2>&1 || true
  codesign --force --keychain "$SIGN_KEYCHAIN" --sign "$SIGN_ID" \
           --identifier "$BUNDLE_ID" "$APP" >/dev/null
else
  echo "→ WARNING: '$SIGN_ID' not in the keychain; falling back to ad-hoc."
  echo "  Permissions will need re-granting after every build."
  echo "  Recreate it with: ./signing/install-identity.sh"
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1
fi

echo "→ installing to $DEST"
osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || true
sleep 0.4
rm -rf "$DEST"
mkdir -p "$HOME/Applications"
cp -R "$APP" "$DEST"

echo "✓ built $DEST (v$VERSION)"
codesign -d -r- "$DEST" 2>&1 | grep designated | sed 's/^/  /' 
