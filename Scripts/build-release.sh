#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$PROJECT_DIR"

SDK_PATH=$(xcrun --show-sdk-path)
BUILD_DIR="$PROJECT_DIR/.build/release-manual"
APP_DIR="$PROJECT_DIR/Build/AKAI Image Manager.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
CUSTOM_ICON="$PROJECT_DIR/Resources/AKAI_S950.icns"

mkdir -p "$BUILD_DIR/ModuleCache" "$PROJECT_DIR/Build"

for APP_ARCH in arm64 x86_64; do
  CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache-$APP_ARCH" swiftc \
    -sdk "$SDK_PATH" \
    -target "$APP_ARCH-apple-macosx14.0" \
    -swift-version 5 \
    -parse-as-library \
    -O \
    -whole-module-optimization \
    Sources/AKAIImageManager/*.swift \
    -o "$BUILD_DIR/AKAIImageManager-$APP_ARCH" \
    -framework AppKit \
    -framework SwiftUI \
    -framework AVFoundation \
    -framework UniformTypeIdentifiers
done

/usr/bin/lipo -create \
  "$BUILD_DIR/AKAIImageManager-arm64" \
  "$BUILD_DIR/AKAIImageManager-x86_64" \
  -output "$BUILD_DIR/AKAIImageManager"

if [ -d "$APP_DIR" ]; then
  mv "$APP_DIR" "$BUILD_DIR/previous-app-$(date +%s)"
fi
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
if [ -f "$CUSTOM_ICON" ]; then
  cp "$CUSTOM_ICON" "$RESOURCES_DIR/AppIcon.icns"
else
  CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache" swiftc \
    -sdk "$SDK_PATH" \
    -target arm64-apple-macosx14.0 \
    -swift-version 5 \
    -parse-as-library \
    Scripts/GenerateIcon.swift \
    -o "$BUILD_DIR/GenerateIcon" \
    -framework AppKit
  mkdir -p "$ICONSET_DIR"
  "$BUILD_DIR/GenerateIcon" "$ICONSET_DIR" "$RESOURCES_DIR/AppIcon.icns"
fi

cp "$BUILD_DIR/AKAIImageManager" "$MACOS_DIR/AKAIImageManager"
cp Resources/Info.plist "$CONTENTS_DIR/Info.plist"
cp Sources/AKAIImageManager/Resources/AKAI-S950-Sampler-Template.adg \
  "$RESOURCES_DIR/AKAI-S950-Sampler-Template.adg"
chmod 755 "$MACOS_DIR/AKAIImageManager"

codesign --force --deep --sign - "$APP_DIR"
plutil -lint "$CONTENTS_DIR/Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "$APP_DIR"
