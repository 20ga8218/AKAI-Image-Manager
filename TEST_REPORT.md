# AKAI Image Manager — Test Report

Date: 3 August 2026  
Host: Apple silicon macOS, target macOS 14+  
Compiler: Apple Swift 6.3.3  
AKAI Util: 4.6.7, Intel executable under Rosetta
Application: 1.8.14 (build 31), Universal arm64 + x86_64

## Automated tests

Command:

```sh
./Scripts/run-tests.sh
```

Result: **51 passed, 0 failed**

Coverage:

- safe AKAI command construction and path-token handling;
- native S9/P9 `put`, `geti`, and stable path deletion commands;
- classification of content-changing AKAI commands used for IMG modification-date updates;
- terminal prompt detection;
- representative `df`, `dir`, and recursive volume parsing;
- stable file identities across repeated directory parsing;
- native drag-name normalization that prevents doubled `.p9`/`.s9` extensions and preserves exact exported filename case;
- application selection uses the real macOS application-bundle UTI and validates a runnable bundle executable;
- P9 header/keygroup parsing with byte-identical no-edit serialization;
- S950 byte-layout validation for loudness, attack, filter, and signed release velocity sensitivity;
- VCF amount validation at keygroup byte `0x17`, with the unrelated byte `0x27` protected from writes;
- S950-canonical 1/16-semitone tuning display, including the hardware-confirmed raw `380` → Transpose `+24`, Fine `−04` case;
- non-zero Fine preservation and pitch-exact Spread save/reopen behavior;
- Ableton Drum Rack XML parsing, unique per-sample S950 naming, source-pad gap preservation, root-note transpose, Detune-to-Fine conversion, MIDI channel and output mapping;
- logarithmic 30–22,000 Hz Ableton cutoff mapping to S950 Filter 00–99, plus independent 0–100% mappings for velocity-to-loudness and velocity-to-filter;
- Ableton rack document-order preservation when receiving notes descend;
- generation of a two-pad Live 12.4.3 Sampler Drum Rack from the sanitized bundled template, including unique branch IDs, relative and absolute WAV references, root note, Detune, base filter and both velocity mappings;
- explicit conversion between ordinary MIDI pad notes and Live’s reversed Drum Rack receiving-note storage (`128 − MIDI note`), including C1/C#1 stored as 92/91;
- generated-ADG decompression and parser round trip with confirmation that no personal source path or template placeholder remains;
- read-only controller permission for native/WAV export commands, while a native import remains rejected;
- Simpler component-based relative sample-path resolution;
- replacement of a new program’s blank full-range keygroup during ADG import;
- stale editor-draft rejection so an externally imported first keygroup cannot be replaced by the pre-import blank draft;
- exact sampler-visible space handling across S9 internal names and P9 references;
- clearing stale sample-header addresses when a P9 layer changes sample;
- linked Soft/Loud P9 reference rewrites for a native S9 rename, without changing next-keygroup addresses;
- release-velocity source and custom crossfade-midpoint flag validation;
- chromatic keygroup Spread ordering from an unordered selection;
- shared-root automatic transpose on both Soft and Loud sample layers;
- no-transpose mode, preservation of Fine tuning, and atomic rejection of unsafe note/transpose ranges;
- byte-level Spread save/reopen validation limited to key mapping and tuning fields;
- appended keygroup record sizing, destination count updates, sample-reference renaming, and the 99-keygroup limit;
- clearing of copied Soft sample-header, Loud sample-header and next-keygroup runtime addresses without changing other keygroup bytes;
- creation of a zero-keygroup in-memory destination header with the first-keygroup runtime address cleared, followed by a valid applied keygroup and save/reopen;
- native S9 collision renaming limited to the staged copy’s ten-byte internal name;
- parsing of standard RIFF/WAVE `cue ` records independently from the native `S9H ` header chunk, including the supplied marker layout;
- replacement of WAV cue tables with two labelled `LIST/adtl` Loop Start/Loop End records while preserving audio and native `S9H ` data;
- strict previous/next zero-crossing navigation, including exact-zero plateaus and upward/downward direction classification;
- byte-limited S9 root-pitch, playback-mode, direction, loop-end and loop-length writes with every unrelated header byte preserved;
- direct typed loop-start/end validation and native-header writes without requiring WAV markers;
- scaling two marker positions to a changed native frame count, with the earlier marker mapped to `end − loop length` and the later marker mapped to `end`;
- retention of marker-derived loop fields while playback mode remains One-shot;
- replacement or insertion of the native `S9H ` WAV chunk without changing the audio or existing cue records;
- preservation of unknown P9 bytes and undocumented flag bits;
- documented-field byte-diff validation and selected/all-keygroup bulk editing;
- individual and bulk sample-reference assignment using the S950 name constraints;
- a one-keygroup blank-program template with safe header defaults and save/reopen validation;
- keygroup duplication/deletion with stable renumbering and preservation of unrelated record bytes;
- structural-edit clearing of only the known program/keygroup runtime-address fields;
- typed negative bulk loudness through Apply, encoded save, and reopen across 40 keygroups;
- rejection of truncated or size-inconsistent P9 files;
- descending multiple-deletion ordering;
- AKAI filename sanitization, typed-name normalization, validation and unique naming;
- exact USB-volume ownership and copy-destination selection;
- S950-only format-preset exposure, plus initial-volume creation for 32 MB S950 hard-disk images;
- clamped UI progress values;
- float/stereo WAV incompatibility detection and mono PCM16 repair;
- atomic image replacement with byte-size and SHA-256 verification;
- timestamped destructive backups as byte-exact verified image copies;
- verified backups written to a configured folder outside the source IMG directory;
- normalization of repeated backup timestamps, including same-second `-2` collision handling;
- explicit IMG modification-date updates after successful mutations;
- exact source-IMG identity checks before P9 overwrite;
- genuine P9 overwrite, re-export and byte-for-byte comparison;
- forced post-write verification failure with complete checksum-verified IMG rollback;
- edited WAV conversion to native S9 in a disposable S950 volume;
- preservation and validation of the replacement S9 internal sample name;
- genuine S9 replacement, re-export and byte-for-byte comparison;
- forced S9 post-write verification failure with complete checksum-verified IMG rollback;
- clean-eject completion waits for the exact mounted volume to disappear;
- serialized controller transitions through open, ready, command, quit, and closed.

## Disposable integration test

Command:

```sh
./Scripts/run-integration.sh
```

Result: **passed**

The test used a newly generated temporary 800 KB image and temporary audio only. It:

1. opened the disposable image with the installed AKAI Util;
2. formatted it as an S950 low-density floppy;
3. parsed its disk geometry;
4. imported a generated canonical WAV;
5. browsed the resulting AKAI file;
6. exported the file as native S9/P9 data;
7. deleted and re-imported that native file;
8. exported the restored sample back to WAV;
9. inspected the WAV with AVFoundation;
10. sent `q` and verified the controller reached its closed state.

No user IMG, WAV, S9/P9 file, or physical USB drive was modified.

## Ableton import regressions

Command:

```sh
./Scripts/run-ableton-import-regression.sh /path/to/rack.adg
```

Result: **passed**

The regression creates a fresh disposable 32 MB S950 image, imports the real audio referenced by an ADG, creates the P9, re-exports every S9/P9 file and verifies:

1. rack/pad order is retained;
2. the blank full-range keygroup is replaced rather than retained;
3. each P9 sample reference exactly matches a stored S9 internal name;
4. imported sample-header runtime addresses are zero;
5. base Filter and both velocity-sensitivity values survive P9 creation and native re-export;
6. the complete native set survives creation and re-export;
7. the source ADG checksum is unchanged.

It passed with the supplied three-pad `S950 RACK filter gain velocity.adg`, including the expected Filter `99/99/99`, velocity-loudness `0/50/0` and velocity-filter `0/50/50` values. Earlier regressions passed with the seven-pad `VIRTUAL S950 AKAI.adg` Sampler rack and a separate 19-pad `Fairlight Effects 1.adg` Simpler rack.

## Rendered interaction regression

Command:

```sh
./Scripts/run-interaction-regression.sh
```

Result: **passed**

This regression creates and formats a fresh disposable IMG, imports generated audio, creates S9 and P9-labelled native entries, and renders the real SwiftUI file table. It verified:

1. a full data-cell selection updates the SwiftUI binding, selects the matching native row, focuses the table and enables P9 Export Selected;
2. Name, Type and Size sorting preserves stable file identity and the correct selected native row;
3. the supplied float WAV exposes strict previous/next zero crossings with upward/downward directions; its loop region is auditioned through the app audio engine, updated live after a loop-point change and stopped cleanly;
4. that WAV is repaired, imported under an explicitly typed valid S950 name and re-exported with scaled native loop boundaries while remaining One-shot;
5. a genuine native looping S9 reconstructs its native boundaries as labelled Loop Start/Loop End WAV markers;
6. sample double-click routing reconstructs imported boundaries as labelled WAV cues, renders root/direction/mode, numeric loop controls and their derived loop length, and does not launch the configured audio editor;
7. native S9 information reports sample rate, nominal pitch, playback mode and loop length;
8. the P9 drag provider resolves an actual native P9 representation with one extension;
9. a two-file S9/P9 drag preparation preserves both selected stable identities and exports both exact native filenames;
10. copying the selected P9 through AKAI Util creates exactly `DELETEP9.P9`, with no second extension;
11. successful deletion reports through a non-blocking header notice rather than an interactive completion dialog;
12. deleting that selected P9 while the table remains rendered completes without the detached `EnvironmentObject` crash;
13. a stale pre-import editor draft cannot replace an externally imported first keygroup;
14. the editor’s sample-choice list exposes the S9 files in the current volume;
15. a blank program starts with one keygroup, survives keygroup duplication/deletion, is created in the IMG, exported and matched byte-for-byte;
16. a real P9 and its referenced S9 export to a generated Live 12.4.3 Sampler rack, parse back with matching note/name/root values, and leave the source IMG byte-identical;
17. an S9 rename rewrites and byte-verifies its linked P9;
18. a P9 rename updates and byte-verifies its internal program name;
19. the IMG reopens read-only, exports its renamed P9/S9 as a valid rack, and remains byte-identical;
20. S950 32 MB hard-disk formatting creates and opens `VOLUME 001`;
21. the AKAI Util child process closes cleanly.

The initial P9 entry is synthetic test data used to exercise the native filename, table, `geti`, drag-provider and deletion paths. The reverse export uses the later valid P9 created and byte-verified through the application model. Genuine P9/S9 behavior is covered separately with the supplied build-18 hardware fixture images.

## Ableton export regression

Result: **passed automatically and in Live 12.4.3**

Build 24 uses the user-supplied one-pad Ableton Live 12.4.3 Sampler rack as the schema reference. Its bundled derivative was sanitized to remove personal paths, sample names, browser identifiers and audio references. Automated tests verified the template and generated racks contain no original personal path, export every distinct S9 once, retain pad note/root/Fine/filter/velocity values through the existing ADG parser, and do not modify the source IMG.

Build 24 user testing confirmed WAV export, Sampler loading, filter/velocity mapping and movable relative sample references. It also exposed that Live stores Drum Rack receiving notes in reverse numeric order and that the controller had classified its two export commands as unavailable read-only. Build 25 corrects both issues. The supplied `ALWAYS.img` then passed a genuine 14-pad regression: P9 notes 36–49 were written as Live values 92–79 in the same keygroup order, parsed back to 36–49, matched every sample name, and left the source checksum unchanged.

User testing confirmed the corrected pad order/notes and a read-only UI export in Ableton Live 12.4.3.

## Cross-IMG keygroup transfer regression

Command:

```sh
./Scripts/run-keygroup-transfer-regression.sh /path/to/APACHE.img
```

Result: **passed**

The regression created a source copy and a separately formatted blank destination IMG, then:

1. staged one genuine APACHE keygroup and its associated native S9 sample;
2. closed the source and opened the destination through the same application model;
3. created a deliberate destination sample-name collision;
4. created a safe zero-keygroup P9 in memory from the copied source header, with the first-keygroup runtime address cleared;
5. imported the associated S9 with a unique internal and directory name;
6. applied the copied keygroup automatically before presenting the new program editor, without saving an empty P9 or presenting a modal completion report;
7. required no second Apply action for the explicit New Program from Copied Keygroups workflow;
8. rewrote the pasted P9 sample reference to the exact name reported by AKAI Util;
9. proved that the genuine source record contained sampler RAM addresses, then verified the program and all three keygroup runtime addresses were cleared;
10. saved and reopened the new P9;
11. imported and re-exported that P9 through AKAI Util with the new keygroup count intact;
12. verified that the original source IMG checksum was unchanged.

## Physical S950 hardware confirmation — through build 20

Result: **passed**

Confirmed on 28 July 2026 using a physical AKAI S950:

1. edited P9 programs survived save, IMG import and sampler loading;
2. chromatic keygroup Spread survived save/reopen and played correctly on the sampler;
3. copied keygroups and associated samples could be used to create a new P9 on a blank destination image;
4. the new program loaded without the sampler freeze caused by copied runtime addresses;
5. the transferred keygroup and sample loaded successfully from the destination media;
6. an edited P9 overwritten in place through the verified backup/replace path loaded successfully;
7. an S9 exported to an external audio editor, saved, converted back, replaced and byte-verified loaded successfully through its existing P9 reference.
8. the supplied seven-pad ADG imported as seven correctly ordered keygroups with no blank keygroup, and **LOAD PROGRAM and SAMPLES** loaded both the program and samples;
9. the first and last imported keygroups played correctly;
10. deletion of a selected middle keygroup remained correct after save and reopen;
11. P9 deletion from a disposable IMG completed without a crash;
12. a new program made from copied keygroups required no additional Apply and loaded normally after creation and reopen.

Hardware testing has only been performed with an AKAI S950 fitted with a GOTEK drive, using a USB stick and IMG disk images. HFE images have not been tested. Later macOS table/export and Ableton changes passed their user acceptance tests. Builds 28–30 user testing confirmed native labelled markers, validated import names, marker/typed loop replacement, loop length and live audition. Build 31’s zero-crossing controls remain the final short UI acceptance check.

## Genuine P9 image regression

Command:

```sh
./Scripts/run-genuine-image-regression.sh /path/to/AKAI-Disk.img
```

Result: **passed**

The tests recorded each source checksum, created a matching temporary local copy, and performed every mutation on that copy. Build 28 used the supplied `looping.wav` to verify float-audio repair, typed import naming, One-shot marker storage and labelled temporary-WAV marker reconstruction, plus a genuine native looping `RHODES01.s9` to verify labelled marker generation. It used `ALWAYS.img` for a real S9 external-edit round trip with changed root pitch, reverse playback and two-marker boundaries retained in One-shot mode. Build 25 used the same image to verify all 14 sampled keygroups against corrected Ableton pad-note encoding. Every source checksum remained unchanged.

The regression verified:

1. rendered native-table selection of a genuine P9;
2. double-click routing into the genuine P9 keygroup editor;
3. genuine P9-to-Ableton export with keygroup order, sample names, decoded MIDI notes and raw Live receiving-note values checked independently;
4. a genuine keygroup edit followed by a complete checksum-matched IMG backup in the configured external backup folder;
5. destructive P9 replacement followed by re-export and byte-for-byte verification;
6. non-blocking success reporting and a clean editor baseline after overwrite;
7. a deliberately forced P9 post-write verification failure followed by automatic restoration of the complete pre-overwrite IMG checksum;
8. raw export of every program with one exact `.P9` extension;
9. deletion of each selected genuine P9 from its rendered copy without a crash;
10. re-import under the original exact name;
11. byte-for-byte equality before and after the P9 raw round-trip;
12. a verified P9 overwrite with the backup checkbox disabled and no backup created;
13. an updated macOS IMG modification date after content mutation;
14. selection of a genuine S9 that is referenced by a P9 program;
15. conversion of a changed exported WAV into native S9 data in a disposable S950 image;
16. replacement under the original internal sample name, preserving the P9 reference;
17. re-export and byte-for-byte verification of the stored native S9;
18. a deliberately forced S9 verification failure followed by automatic restoration of the complete pre-replacement IMG checksum;
19. a verified edited-S9 replacement with the backup checkbox disabled and no backup created;
20. root pitch, reverse direction and marker scaling surviving native S9 export/import/export byte verification while playback remains One-shot;
21. an unchanged source checksum after testing.

## Release and visual checks

- Optimized Release compilation: passed.
- Info.plist and IMG/ISO document association validation: passed.
- Universal arm64 and x86_64 Mach-O bundle structure: passed.
- Forced x86_64 runtime launch through Rosetta and normal Quit: passed.
- Ad-hoc code-sign verification with strict/deep checks: passed.
- Supplied S950 ICNS copy and bundle-hash inspection: passed.
- SwiftUI render smoke test with a disposable, read-only AKAI image: passed.
- Single-volume render uses the full window and contains no permanent disk/partition sidebar: passed.
- A disposable two-volume S950 hard-disk image exposed both volumes through the conditional compact header menu: passed.
- Attached-sheet render check for the Spread preview and controls: passed.
- P9 editor render check for a read-only program header, sample dropdown and compact Add/Delete controls: passed.
- P9 overwrite confirmation render check for its default-on backup checkbox and rollback explanation: passed.
- Settings Safety-tab render check for the backup destination and export-folder controls: passed.
- Live packaged app launch: passed; no application crash was observed.
- Normal Quit with an open disposable image: passed; both AKAI Image Manager and its AKAI Util child process exited.

The physical USBclean eject path was not exercised against a real drive to avoid risking user media. Exact volume resolution, controller shutdown, verified copy logic, and USBclean handoff construction were tested non-destructively.
