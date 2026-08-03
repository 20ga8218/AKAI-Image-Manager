#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$PROJECT_DIR"

SCREENSHOT_PATH=${1:-/tmp/AKAI-Image-Manager-settings-smoke.png}
SDK_PATH=$(xcrun --show-sdk-path)
BUILD_DIR="$PROJECT_DIR/.build/manual-settings-smoke"
mkdir -p "$BUILD_DIR/ModuleCache"

CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache" swiftc \
  -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 5 \
  -parse-as-library \
  Sources/AKAIImageManager/Models.swift \
  Sources/AKAIImageManager/FileOperations.swift \
  Sources/AKAIImageManager/AppSettings.swift \
  Sources/AKAIImageManager/SettingsView.swift \
  Tests/SettingsVisualRunner.swift \
  -o "$BUILD_DIR/SettingsVisualRunner" \
  -framework AppKit \
  -framework SwiftUI \
  -framework UniformTypeIdentifiers

"$BUILD_DIR/SettingsVisualRunner" "$SCREENSHOT_PATH"
