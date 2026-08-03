#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$PROJECT_DIR"

AKAIUTIL_PATH=${1:-${AKAIUTIL_PATH:-/usr/local/bin/akaiutil}}
SDK_PATH=$(xcrun --show-sdk-path)
BUILD_DIR="$PROJECT_DIR/.build/manual-integration"
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
  Sources/AKAIImageManager/WAVService.swift \
  Tests/IntegrationRunner.swift \
  -o "$BUILD_DIR/AKAIImageManagerIntegrationTests" \
  -framework AppKit \
  -framework AVFoundation

"$BUILD_DIR/AKAIImageManagerIntegrationTests" "$AKAIUTIL_PATH"
