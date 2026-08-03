#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$PROJECT_DIR"

INFO_PLIST="$PROJECT_DIR/Resources/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")
DIST_DIR="$PROJECT_DIR/Build/Distribution"
PACKAGE_NAME="AKAI Image Manager $VERSION Source"
PACKAGE_DIR="$DIST_DIR/$PACKAGE_NAME"
ZIP_PATH="$DIST_DIR/AKAI-Image-Manager-$VERSION-build-$BUILD_NUMBER-SOURCE.zip"
ARCHIVE_DIR="$PROJECT_DIR/.build/source-archive-history"

mkdir -p "$DIST_DIR" "$ARCHIVE_DIR"

if [ -e "$PACKAGE_DIR" ]; then
  mv "$PACKAGE_DIR" "$ARCHIVE_DIR/$PACKAGE_NAME-$(date +%s)"
fi
if [ -e "$ZIP_PATH" ]; then
  mv "$ZIP_PATH" "$ARCHIVE_DIR/$(basename "$ZIP_PATH").$(date +%s)"
fi

mkdir -p "$PACKAGE_DIR"

for SOURCE_ITEM in \
  .github \
  .gitignore \
  LICENSE \
  Package.swift \
  README.md \
  SOURCE_README.md \
  TEST_REPORT.md \
  Sources \
  Tests \
  Scripts \
  Resources \
  ReleaseDocs
do
  /usr/bin/ditto "$PROJECT_DIR/$SOURCE_ITEM" "$PACKAGE_DIR/$SOURCE_ITEM"
done

(
  cd "$PACKAGE_DIR"
  find . -type f ! -name SOURCE_MANIFEST_SHA256.txt -print \
    | LC_ALL=C sort \
    | while IFS= read -r SOURCE_FILE; do
        /usr/bin/shasum -a 256 "$SOURCE_FILE"
      done \
    > SOURCE_MANIFEST_SHA256.txt
)

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$PACKAGE_DIR" "$ZIP_PATH"
/usr/bin/unzip -t "$ZIP_PATH" >/dev/null

printf 'Version: %s (%s)\n' "$VERSION" "$BUILD_NUMBER"
printf 'Source package: %s\n' "$PACKAGE_DIR"
printf 'Source ZIP: %s\n' "$ZIP_PATH"
/usr/bin/shasum -a 256 "$ZIP_PATH"
