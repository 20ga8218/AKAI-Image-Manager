#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$PROJECT_DIR"

AKAIUTIL_PATH=${1:-${AKAIUTIL_PATH:-/usr/local/bin/akaiutil}}
RETAINED_IMAGE_PATH=${2:-}
SDK_PATH=$(xcrun --show-sdk-path)
BUILD_DIR="$PROJECT_DIR/.build/manual-interaction-regression"
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
  Tests/InteractionRegressionRunner.swift \
  -o "$BUILD_DIR/InteractionRegressionRunner" \
  -framework AppKit \
  -framework SwiftUI \
  -framework AVFoundation \
  -framework UniformTypeIdentifiers

if [ -n "$RETAINED_IMAGE_PATH" ]; then
  "$BUILD_DIR/InteractionRegressionRunner" "$AKAIUTIL_PATH" "$RETAINED_IMAGE_PATH"
else
  "$BUILD_DIR/InteractionRegressionRunner" "$AKAIUTIL_PATH"
fi
