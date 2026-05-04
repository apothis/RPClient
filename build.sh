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

codesign --force --sign - "$APP_DIR"

echo "Built $APP_DIR"
