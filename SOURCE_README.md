# AKAI Image Manager — Complete Source

This is the complete buildable source project for AKAI Image Manager 1.8.14, build 31.

## Included

- `Sources/AKAIImageManager/` — all application Swift source files and the sanitized Ableton Live 12.4.3 Sampler export template.
- `Tests/` — unit, integration, interaction, genuine-image, Ableton-import, keygroup-transfer and visual regression runners, plus generated-test fixtures.
- `Scripts/` — release, community-package, source-package and regression scripts.
- `Resources/` — the application Info.plist and supplied S950 ICNS artwork.
- `ReleaseDocs/` — community README and third-party notices.
- `Package.swift`, `README.md` and `TEST_REPORT.md`.
- `SOURCE_MANIFEST_SHA256.txt` — generated checksums for every packaged source file.

Compiled `.build/` contents, the `Build/` distribution directory, Finder metadata and private user fixtures are deliberately excluded. They are outputs or test inputs, not application source.

The application does not bundle AKAI Util, USBclean, audio samples or disk images. It includes one sanitized, audio-free Ableton Live 12.4.3 user-preset template used to generate Sampler Drum Racks. Its provenance and the official dependency/source locations are documented in `ReleaseDocs/THIRD-PARTY-NOTICES.txt`.

## Requirements

- macOS 14 or later.
- Apple command-line developer tools with Swift.
- AKAI Util 4.6.7 for integration tests and normal application use.
- Rosetta when using the official Intel AKAI Util binary on Apple silicon.
- USBclean only for the optional Clean Eject feature.
- Ableton Live 12.4.3 or a compatible later Live 12 release only for opening exported Drum Racks; Ableton is not required to build or run the image-management features.

No third-party Swift package is required.

## Build

From this directory:

```sh
./Scripts/run-tests.sh
./Scripts/build-release.sh
```

The Universal arm64/x86_64 application will be created at:

```text
Build/AKAI Image Manager.app
```

The build is ad-hoc signed. Public distribution should ideally use an Apple Developer ID certificate and notarization.

## Extended regression tests

The standard test suite is self-contained. Extended tests accept external test data and always operate on disposable copies:

```sh
./Scripts/run-integration.sh
./Scripts/run-interaction-regression.sh
./Scripts/run-ableton-import-regression.sh /path/to/rack.adg
./Scripts/run-genuine-image-regression.sh /path/to/source.img
./Scripts/run-keygroup-transfer-regression.sh /path/to/source.img
```

Do not add copyrighted samples, other Ableton presets or personal disk images to the source archive unless you have permission to redistribute them. The included sanitized export template is the only intended ADG resource.
