#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$PROJECT_DIR"

IMAGE_PATH=${1:-/tmp/akai-manager-disposable.img}
SCREENSHOT_PATH=${2:-/tmp/AKAI-Image-Manager-smoke.png}
AKAIUTIL_PATH=${3:-${AKAIUTIL_PATH:-/usr/local/bin/akaiutil}}
SDK_PATH=$(xcrun --show-sdk-path)
BUILD_DIR="$PROJECT_DIR/.build/manual-visual-smoke"
mkdir -p "$BUILD_DIR/ModuleCache"

CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache" swiftc \
  -sdk "$SDK_PATH" \
  -target arm64-apple-macosx14.0 \
  -swift-version 5 \
  -parse-as-library \
  Sources/AKAIImageManager/Models.swift \
  Sources/AKAIImageManager/AkaiCommandBuilder.swift \
  Sources/AKAIImageManager/AkaiOutputParser.swift \
  Sources/AKAIImageManager/AkaiCommandController.swift \
  Sources/AKAIImageManager/FileOperations.swift \
  Sources/AKAIImageManager/P9Program.swift \
  Sources/AKAIImageManager/AbletonDrumRackImport.swift \
  Sources/AKAIImageManager/AbletonDrumRackExport.swift \
  Sources/AKAIImageManager/AbletonDrumRackImportView.swift \
  Sources/AKAIImageManager/WAVService.swift \
  Sources/AKAIImageManager/AppSettings.swift \
  Sources/AKAIImageManager/P9EditorView.swift \
  Sources/AKAIImageManager/AppModel.swift \
  Sources/AKAIImageManager/MainView.swift \
  Sources/AKAIImageManager/Sheets.swift \
  Sources/AKAIImageManager/SettingsView.swift \
  Tests/VisualSmokeRunner.swift \
  -o "$BUILD_DIR/VisualSmokeRunner" \
  -framework AppKit \
  -framework SwiftUI \
  -framework AVFoundation \
  -framework UniformTypeIdentifiers

"$BUILD_DIR/VisualSmokeRunner" "$IMAGE_PATH" "$SCREENSHOT_PATH" "$AKAIUTIL_PATH"
