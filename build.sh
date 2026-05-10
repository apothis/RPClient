#!/bin/bash
set -e

APP_NAME="RPClient"
APP_DIR="$APP_NAME.app"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

swift build -c release --product "$APP_NAME"

BIN_DIR=$(swift build -c release --product "$APP_NAME" --show-bin-path)
cp "$BIN_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp Info.plist "$APP_DIR/Contents/Info.plist"

# SwiftPM generates per-target resource bundles (e.g. RPClient_RPClientCore.bundle)
# next to the binary. Bundle.module looks for these adjacent to the executable
# OR inside Contents/Resources of the host app. Copy them in so the help
# system's markdown pages load when running RPClient.app via Finder.
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
    cp -R "$bundle" "$APP_DIR/Contents/Resources/"
done
shopt -u nullglob

codesign --force --sign - "$APP_DIR"

echo "Built $APP_DIR"
