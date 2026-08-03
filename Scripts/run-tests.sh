#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$PROJECT_DIR"

SDK_PATH=$(xcrun --show-sdk-path)
BUILD_DIR="$PROJECT_DIR/.build/manual-tests"
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
  Sources/AKAIImageManager/WAVService.swift \
  Sources/AKAIImageManager/AppSettings.swift \
  Tests/TestRunner.swift \
  -o "$BUILD_DIR/AKAIImageManagerTests" \
  -framework AppKit \
  -framework AVFoundation \
  -framework UniformTypeIdentifiers

chmod +x Tests/Fixtures/fake-akaiutil.sh
"$BUILD_DIR/AKAIImageManagerTests"
