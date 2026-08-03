# AKAI Image Manager

[![macOS Swift CI](https://github.com/richiewarburton/AKAI-Image-Manager/actions/workflows/ci.yml/badge.svg)](https://github.com/richiewarburton/AKAI-Image-Manager/actions/workflows/ci.yml)

AKAI Image Manager is a native SwiftUI application for macOS 14 and later. It provides a Finder-style interface to the installed [AKAI Util](https://github.com/Midi-In/akaiutil) command-line program without requiring users to type AKAI commands.

The app is deliberately image-file focused. It never formats a physical drive.

## Download

Download the current Universal macOS build from the repository’s
[Releases page](https://github.com/richiewarburton/AKAI-Image-Manager/releases).
The release ZIP includes installation guidance, third-party dependency links,
test results and checksums. The app is ad-hoc signed rather than Apple-notarized.

## Requirements

- macOS 14 or later.
- AKAI Util 4.6.7 for Darwin. Fresh installations look for:
  `/usr/local/bin/akaiutil` or `/opt/homebrew/bin/akaiutil`
- Rosetta, because the installed AKAI Util 4.6.7 binary is Intel-only.
- USBclean for Clean Eject. The default location is:
  `/Applications/USBclean.app`

Both paths can be changed and validated in Settings.

## Everyday operation

1. Choose **Open Image** or drag an IMG/ISO/raw image onto the app or Dock icon.
2. Select a volume in the sidebar.
3. Browse and select files in the table.
4. Use the toolbar for Import, Export, Delete, Refresh, Disk Info, Backup, and Clean Eject.

Images can be opened read-only. The status bar always shows the current AKAI path, access mode, and used/free space.
Click the Name, Type or Size column heading to sort the file table. Stable file identities keep selection, double-click, export and deletion attached to the correct file after sorting.

### Import

- Drop one or more WAV files onto the browser or a destination volume.
- WAV files are inspected with AVFoundation. Incompatible audio is repaired into a temporary canonical PCM WAV; the original is never changed.
- A WAV with exactly two standard cue markers writes those positions into the native S9 loop fields while retaining One-shot playback by default. The positions are scaled if audio repair changes the frame count.
- Choose S900/S950 mono handling, compression, sample-rate preservation, and collision behavior.
- Native `.S9` and `.P9` files can also be dropped or selected with Import. They are staged unchanged and transferred with AKAI Util’s native `put` command.
- Native files with colliding names receive a safe unique name by default.
- Select one native S9 or P9 and choose **Rename S9/P9…** from the context or Image menu. Program names are changed in the directory and P9 header together. Sample renames also rewrite every linked P9 reference in the current volume.

### Export and drag out

- Export selected or all samples to WAV with a folder picker.
- With only P9 programs selected, **Export Selected…** copies their original native P9 files. The toolbar, Image menu and row context menu use the same action.
- Select one or more native S9/P9 files, then drag the export handle at the right edge of any selected row directly to Finder. Every selected native file is delivered with its exact single extension. Keeping drag handling on the dedicated handle leaves the rest of the row available for reliable selection.
- Use **Copy Original S9/P9 Files…** in the row context menu or Image menu to copy one or more raw native files with a folder picker.
- Native copies are created on demand with `geti`; they are not simulated data. The exact single `.S9` or `.P9` filename is preserved.
- WAV export collision choices are Replace, Skip, and Create Unique Name.
- Settings can leave Finder closed after export—the default—or open the chosen destination folder itself.
- **File Information…** reports native S9 attributes including sample rate, sample count, nominal pitch, loudness, playback/loop mode, direction, sample type, compression and marker positions.
- Double-click one writable S9 to open its native editor without launching another application. Root pitch, playback direction, playback mode and numeric loop boundaries can be changed directly. Sample and loop lengths are shown in samples. Previous/next controls snap either loop point to a directed zero crossing, and **Audition Loop** follows changes immediately. **Open WAV in …** launches the configured editor only when requested; native boundaries appear there as labelled markers. Replacement retains the sampler-visible name and native fractional pitch, then re-exports and byte-verifies the stored S9.
- Select one P9 and choose **Export Selected P9 as Ableton Drum Rack…** from the Image menu, or **Export P9 as Ableton Drum Rack…** from its row menu. The app exports each referenced Soft S9 once as WAV, creates a Live 12.4.3 Sampler pad for every sampled keygroup, and verifies the generated ADG by parsing it back before reporting success. The new folder contains the ADG and a `Samples` folder; the IMG is not changed.
- S950 keygroup note, Soft-sample name, root pitch, Fine tuning, base filter cutoff, velocity-to-loudness and velocity-to-filter are translated back to the corresponding Sampler pad. A ranged keygroup is placed on its Low note. Loud layers and keygroups without a Soft sample are listed in `Export Notes.txt` and omitted.

### P9 keygroup editor

- Open a standalone P9 with **File > Open P9 Program…**, double-click a P9 in Finder, or double-click its name inside an open image.
- Edit one keygroup directly, command-click several keygroups for bulk editing, or use **Select All**.
- The editor includes key ranges, velocity switching/crossfade and its optional custom midpoint, both sample layers, loudness, filter, transpose, fine tune, VCF, amplitude envelope, velocity sensitivity and release source, MIDI channel, output, constant pitch, and one-shot.
- Fine tuning is shown exactly as the S950 displays it: the nearest semitone plus a signed −8…+7 remainder in native 1/16-semitone steps.
- Bulk edits leave unchecked fields unchanged and can either set an absolute value or adjust every selected keygroup relatively.
- Select two or more keygroups and choose **Spread…** to map them chromatically onto single notes. Enter the first note and the samples’ shared root note; optional automatic transpose compensates both sample layers so every slice plays at its original speed.
- Spread validates the complete note and transpose range before changing anything. Fine tuning and unrelated keygroup parameters remain unchanged.
- Choose **Import ADG…** from a P9 opened in a writable IMG to read occupied Ableton Drum Rack pads containing Sampler or Simpler devices. Set a new start note, shared root note, MIDI channel and output, and edit the unique 10-character name for every S9 sample before import. Rack order and source pad gaps are preserved; WAV sources are converted to S9. Sampler/Simpler velocity-to-volume and velocity-to-filter amounts are mapped from 0–100% to the S950’s 00–99 sensitivities. An enabled filter’s 30–22,000 Hz cutoff is mapped logarithmically to the keygroup’s 00–99 Filter value; a disabled filter imports fully open with no filter velocity sensitivity.
- The ADG importer supports one distinct sample zone per occupied pad. A new program’s blank full-range keygroup is replaced by the first imported pad rather than left behind. It refuses missing audio, genuine multi-zone pads, overlapping destination notes, colliding S9 names and unsafe transpose ranges before changing the IMG.
- Use **Transfer → Copy Selected Keygroups and Samples** to stage keygroup records and their associated native S9 samples. Close the source IMG, open a destination P9 in the same or another writable IMG, then choose **Transfer → Paste … at End**.
- Cross-IMG sample collisions receive unique names. Both the staged S9 internal name and the pasted P9 sample reference are updated to the exact sampler-visible destination name.
- Sampler-maintained Soft sample, Loud sample and next-keygroup RAM addresses are cleared from transferred records so the S950 can rebuild them safely for the destination program.
- After the associated samples transfer, the footer shows that the pasted keygroups are ready. Click **Apply … Pasted Keygroups** to append them to the destination program. **Save Edited Copy…** remains unavailable until that Apply step is complete.
- Save the expanded P9 with **Save Edited Copy…**, then import that copy into the destination IMG.
- Individual and bulk changes use the always-visible **Apply** button in the footer. Typed numeric values update continuously before Apply, and changing the selected sample updates the keygroup list name immediately.
- Parameters use a compact two-column layout. The Loud Sample section is collapsed by default and can be expanded when required.
- The editor offers **Save Edited Copy…**. It does not replace the P9 inside the image.
- Unknown bytes, sampler-maintained address fields, and undocumented flag bits are preserved.
- Closing a P9 editor with changes that have not been written to the IMG or saved as an edited copy requires explicit confirmation.
- P9 overwrite offers a default-on verified IMG backup checkbox. Disabling it also disables automatic rollback; stored P9 bytes are still re-exported and verified.

### Safe S9 and P9 rename

- Renaming a P9 changes its native directory entry and internal ten-byte program name together.
- Renaming an S9 scans every P9 in the current volume, replaces matching Soft and Loud references, and clears only the obsolete sample-header RAM address for each changed layer.
- The complete IMG is closed, copied and checksum-verified before either rename. The renamed native files are then exported again and compared byte-for-byte.
- If mutation or verification fails, the complete IMG is restored and verified automatically from that backup.
- The operation aborts before mutation if a destination name already exists or any P9 needed for a sample-reference scan cannot be parsed.

### Delete, backup, and format

- Selected-file deletion uses stable indexes in descending order.
- Delete All shows the exact file list, requires `DELETE ALL`, and defaults to a timestamped backup.
- Settings can place IMG backups in one central folder instead of beside each source IMG.
- Backing up an IMG whose filename already ends in a backup timestamp replaces that old timestamp instead of chaining another `-backup-…` suffix.
- Successful content-changing commands update the IMG file’s macOS modification date.
- New images use documented exact sizes and AKAI formatting commands.
- Reformatting an existing image requires its full filename and rejects a preset whose exact size does not match the image.

### USB handling

Clean Eject is available only when the active image is underneath an exact `/Volumes/<name>/` mount. The app:

1. finishes the current operation;
2. sends `q` to AKAI Util;
3. waits for complete process termination;
4. hands the exact owning volume to USBclean;
5. waits until that volume is no longer mounted, then shows **Safe to unplug** in the app header without a confirmation dialog.

For local images, **Copy to USB and Eject** appears only when an attached volume contains the same exact filename. The copy uses a temporary destination, verifies file size and SHA-256, then replaces the target.

## Safety

- Only one serialized AKAI command/session is active at a time.
- Mutations are disabled in read-only mode.
- User WAV, S9, and P9 source files are never modified.
- Temporary paths contain no spaces because AKAI Util’s interactive parser does not support quoted path tokens.
- Backups are timestamped and never overwrite unrelated files.
- P9 overwrite and edited-S9 replacement offer an explicit default-on backup checkbox. Without that backup, a failed write cannot be rolled back automatically. Native S9/P9 rename retains its mandatory verified backup.
- No physical-drive formatting is exposed.
- Raw command output remains available in the collapsible diagnostic log if parsing fails.
- Successful imports, exports, copies, backups, repairs, formats and deletions use a non-blocking header notice. Errors and confirmations required before destructive actions remain dialogs.

## Building and testing

No third-party packages are used.

```sh
./Scripts/run-tests.sh
./Scripts/run-integration.sh
./Scripts/run-interaction-regression.sh
./Scripts/run-ableton-import-regression.sh /path/to/rack.adg
./Scripts/run-genuine-image-regression.sh /path/to/read-only-source.img
./Scripts/run-keygroup-transfer-regression.sh /path/to/source.img /path/to/destination-seed.p9
./Scripts/run-settings-smoke.sh
./Scripts/build-release.sh
```

The genuine-image regression always creates its own temporary working copy. It exports native P9 files, deletes and restores one P9 on the copy, verifies byte-for-byte raw round-trip, and checks that the source IMG checksum did not change.

The signed local bundle is produced at:

`Build/AKAI Image Manager.app`

The build script compiles optimized arm64 and x86_64 binaries for macOS 14, combines them into a Universal app, generates the app icon, assembles the bundle, applies an ad-hoc local signature, and verifies the signature and Info.plist.

## Troubleshooting

- **AKAI Util is not detected:** open Settings, choose the executable, and click Validate Again.
- **An image does not open:** enable the diagnostic log and inspect the raw AKAI Util response. Floppy images must be exactly 800 KB or 1600 KB.
- **Import is disabled:** the image is read-only, no volume is open, or another serialized operation is finishing.
- **Clean Eject is disabled:** the active image is local rather than underneath `/Volumes`, or USBclean is not detected.
- **A path contains spaces:** the app handles this through controlled temporary staging. Do not bypass the app and paste a quoted path into AKAI Util; its parser does not understand shell quotes.

## Genuine limitations

- Drum Sampler pads and genuine multi-zone/velocity-layer pads are not imported. S950-to-Ableton export creates Sampler devices only, exports the Soft layer only, and maps a ranged keygroup to its Low note. The generated template targets Ableton Live 12.4.3; corrected pad-note direction and read-only export passed user testing in that Live build.
- Build 31 adds previous/next zero-crossing buttons to both loop-point rows. Each snapped position shows an upward or downward crossing icon; a neutral icon identifies a manually entered position that is not a crossing. Navigation cannot move Loop Start through Loop End or Loop End through Loop Start, and an active loop audition follows each snapped position immediately. This final zero-crossing workflow requires a short user acceptance test. Sample-rate editing remains deferred.
- Keygroup transfer appends at the end of an existing destination P9 after an explicit Apply. **New Program from Copied Keygroups…** opens with its copied keygroups already applied. Associated samples are imported automatically only when the destination P9 was opened from a writable IMG.
- USBclean performs the final cleaning/ejection; AKAI Image Manager confirms that the owning volume is no longer mounted before showing **Safe to unplug**.
- The local build is ad-hoc signed, not Developer ID signed or notarized.
- Physical drives are intentionally unsupported.

## Licence

AKAI Image Manager is released under the [MIT License](LICENSE). AKAI Util,
USBclean and Ableton Live are separate products with their own licences and are
not included in this repository.
