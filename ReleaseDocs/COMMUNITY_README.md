# AKAI Image Manager 1.8.14

AKAI Image Manager is an independent native macOS application for browsing and managing AKAI S950 disk-image files through a Finder-style interface.

The app is an interface for AKAI Util. AKAI Util and USBclean are separate third-party products and are not included in this ZIP.

The sampler-critical workflow through build 20 has been confirmed on physical S950 hardware. Edited and ADG-imported programs, chromatic Spread, keygroup deletion, copied-keygroup program creation, verified in-IMG P9 overwrite and the external-editor S9 audio round trip all survived sampler loading.

Version 1.8.14 build 31 adds previous/next zero-crossing buttons to both S9 loop-point rows. Each snapped position shows whether the waveform crossing is upward or downward; a neutral icon identifies a manually entered position that is not at a crossing. Navigation is bounded so Loop Start cannot pass Loop End and vice versa. An active loop audition restarts immediately at every snapped position. The live loop-length display, labelled WAV markers, explicit marker refresh instruction and editable validated WAV import names are retained.

Hardware testing has only been performed with an AKAI S950 fitted with a GOTEK drive, using a USB stick and IMG disk images. HFE images have not been tested. This release makes no compatibility claim for other hardware or disk-image formats.

## What is included

- `AKAI Image Manager.app` — Universal macOS application for Apple silicon and Intel Macs.
- `README.md` — this installation and usage guide.
- `LICENSE` — MIT licence for AKAI Image Manager.
- `THIRD-PARTY-NOTICES.txt` — official third-party download, source and licensing information.
- `TEST_REPORT.md` — automated and genuine-image validation results.
- `SHA256SUMS.txt` — integrity checksums for the packaged files.

## Requirements

- macOS 14 Sonoma or later.
- AKAI Util 4.6.7 Darwin edition.
- Rosetta on Apple-silicon Macs because the official AKAI Util 4.6.7 Darwin executable is Intel-only.
- A macOS audio editor of your choice is optional and needed only for direct S9 editing.
- USBclean is optional and is used only by the Clean Eject feature.
- Ableton Live 12.4.3 is required only to open the generated Drum Rack; Ableton is not needed for the app’s IMG, S9 or P9 functions.

AKAI Image Manager itself is Universal and runs natively on both Apple silicon and Intel Macs.

## Installation

### 1. Install AKAI Image Manager

1. Unzip the download.
2. Drag `AKAI Image Manager.app` into the Applications folder.
3. Open the app.

This community build is ad-hoc signed, not Developer ID signed or notarized by Apple. If macOS blocks its first launch:

1. Try to open the app once.
2. Open **System Settings → Privacy & Security**.
3. Scroll to Security and choose **Open Anyway** for AKAI Image Manager.
4. Confirm **Open**.

Only override this warning when the ZIP came from a source you trust and its published SHA-256 checksum matches.

### 2. Install AKAI Util

Download the official `akaiutil-4.6.7Darwin.zip`:

https://sourceforge.net/projects/akaiutil/files/akaiutil-4.6.7Darwin.zip/download

Extract the `akaiutil` executable and keep it in a permanent location. `/usr/local/bin/akaiutil` is detected automatically, but any location works:

1. Open **AKAI Image Manager → Settings**.
2. Beside the AKAI Util path, choose the extracted `akaiutil` executable.
3. Select **Validate Again**.

If the executable lost its permission during copying, open Terminal and run:

```sh
chmod +x "/full/path/to/akaiutil"
```

On an Apple-silicon Mac, macOS should offer to install Rosetta when AKAI Util first launches. Accept that installation. Apple’s Rosetta information is available at:

https://support.apple.com/102527

### 3. Optional: choose an audio editor

Direct S9 audio editing works with a macOS application that can open and save PCM WAV files:

1. Open **AKAI Image Manager → Settings**.
2. Under **External Audio Editor**, choose your editor’s `.app`.
3. Save edits over the temporary WAV opened by AKAI Image Manager. Do not use Save As or move the file.

The audio editor is not bundled and is not otherwise required. AKAI Image Manager does not depend on a particular commercial or open-source editor.

### 4. Optional: install USBclean

USBclean is required only for **Clean Eject**. Normal image browsing, import, export, backup and closing do not require it.

Official product page:

https://usbclean.sweetpproductions.com/

Mac App Store:

https://apps.apple.com/gb/app/usbclean/id907406031?mt=12

Install it as `/Applications/USBclean.app`, or choose a different location in AKAI Image Manager Settings.

## Quick start

1. Back up valuable IMG files before enabling write access.
2. Open an IMG or ISO using the Open button, Finder, or drag and drop.
3. Select files in the table.
4. Use Import, Export, Delete, Disk Info or Backup from the toolbar.

Click Name, Type or Size to sort the IMG table. Sorting does not change the underlying AKAI file indexes used for editing, copying or deletion.

Single-volume floppy images open directly with no disk tree. If an S950 hard-disk image has multiple volumes, choose the required volume from the compact folder menu in the header.

Creating or reformatting a 32 MB S950 hard-disk image also creates and opens an initial `VOLUME 001`, so the result is immediately usable.

Native `.S9` and `.P9` files can be:

- dragged into an open writable IMG;
- selected singly or together and copied out by dragging the export handle at the right of any selected row;
- copied as native P9 files with **Export Selected…** when only P9 programs are selected;
- copied in batches with **Copy Original S9/P9 Files…** from the context or Image menu.
- renamed safely from the context or Image menu. S9 rename updates every linked P9 in the current volume; both S9 and P9 rename create a full verified IMG backup and verify the stored native result.

Under **Settings → Safety**, choose whether export opens the selected destination folder. It is off by default. The same settings page can choose a central IMG-backup folder; **Use IMG Folder** returns to storing each backup beside its source image.

Choose **File Information…** for a native S9 to inspect its sample rate, sample count, nominal pitch, loudness, loop/playback mode, direction, type, compression and marker values.

### Edit an S950 sample

This feature is available for one selected sample in a writable S950 IMG:

1. Double-click an S9 sample. The toolbar, Image menu and sample context menu offer the same action. Only the AKAI Image Manager edit dialogue opens.
2. Choose root pitch, forward/reverse direction and playback mode directly. Native sample length and S950 loop length are shown in samples; loop start and end can be typed or changed with the steppers.
3. Use the left/right chevrons beside either loop point to move strictly to the previous or next zero crossing. The diagonal icon indicates an upward or downward crossing; a horizontal icon means the manually entered position is not currently at a zero crossing.
4. Click **Audition Loop** to repeat the current start-to-end region. While it is playing, changing or snapping either position immediately restarts the audition with the new loop. Click **Stop Audition** when finished.
5. If audio editing is required, configure an editor in Settings and click **Open WAV in …** inside the dialogue. Native loop points are present in that WAV as labelled **Loop Start** and **Loop End** markers. Save over the WAV; do not use Save As.
6. After saving marker edits, return to AKAI Image Manager and click **Refresh Loop Points from Saved WAV**. The earlier marker becomes loop start and the later marker becomes loop end, including in One-shot mode. Replacement reads saved markers automatically, but refreshing updates the displayed positions and loop length so they can be verified first.
7. Choose compression and whether to create a verified IMG backup.
8. Click **Back Up and Replace Sample**, or explicitly choose replacement without a backup.
9. Wait for **S9 Sample Replaced and Verified** in the header.

The backup option defaults on and permits automatic rollback. Without it, the S9 is still re-exported and byte-verified, but a failed write cannot be restored automatically.

One-shot mode does not require markers, but exactly two markers are still stored as its native loop boundaries. Loop and Alternating loop require two distinct, in-range boundaries supplied either by the numeric fields or WAV markers; invalid values stop the operation before the IMG is changed. Native loop fields are reconstructed as labelled WAV markers when the edit dialogue opens. The native fractional 1/16-semitone component of nominal pitch is retained when a new root note is selected.

The app converts the edited WAV into native S9 data inside a disposable S950 conversion image. Before touching the real IMG, it checks the native sample name and available space and closes the source cleanly. When selected, it then creates a checksum-verified full IMG backup. The sample is replaced under its original sampler-visible name, re-exported and compared byte-for-byte. Existing P9 sample references therefore remain unchanged.

If conversion fails, the source IMG is never changed. If replacement or verification fails after deletion starts, automatic restoration is available only when the backup checkbox was enabled.

Closing or cancelling the editing sheet removes its temporary WAV. Finish and save the external edit before cancelling or opening another image.

### P9 keygroup editor

Open a standalone P9 from **File → Open S950 P9 Program…**, double-click a P9 in Finder, or double-click its name inside an open image.

The editor supports individual, selected and all-keygroup editing for:

- key and velocity ranges, velocity crossfade and its optional custom midpoint;
- soft and loud sample names;
- loudness, filter, transpose and fine tuning;
- VCF and amplitude envelopes;
- velocity sensitivity, including the note-on/note-off release source;
- MIDI channel and audio output;
- constant pitch and one-shot.

Fine tuning is displayed exactly as the S950 shows it: the nearest semitone plus a signed −8…+7 Fine value in native 1/16-semitone steps. For example, a raw tuning of 380 is shown as Transpose `+24`, Fine `−04`, matching the sampler rather than the mathematically equivalent `+23`, `+12`.

The editor uses a compact two-column parameter layout. Loud Sample controls can be collapsed, and the **Apply** button remains visible in the footer for both individual and multiple-keygroup editing.

The program name in the editor header is intentionally read-only. It is the program’s internal P9 identity, not an ordinary label. Choose the name when creating a program, use **Save Edited Copy…** for a differently named local file, or use **Rename S9/P9…** on a P9 in the IMG browser to change its directory and internal names transactionally.

Soft and Loud sample fields are dropdown menus populated with the S9 samples present in the open volume. **No sample** clears a layer. If an existing P9 references a sample not currently present, that reference remains available in the menu so merely opening the editor cannot lose it. The bulk editor offers the same choices, including **Unchanged**. Choosing a Soft sample updates the selected keygroup’s list name immediately; **Apply** still controls when the complete draft is committed.

Use **Add** below the keygroup list to duplicate the selected keygroup, including all its musical settings. Use **Delete** to remove one or more selected keygroups. The editor always retains at least one keygroup and renumbers the remaining list. Any insertion or deletion clears only the sampler-maintained program/keygroup RAM links affected by structural changes; musical settings, unknown bytes and undocumented flag bits remain intact.

Select two or more keygroups and choose **Spread…** to assign them to consecutive single notes. The dialog accepts a starting note and a shared sample root note. Optional automatic transpose adjusts both Soft and Loud layers by `root note − assigned note`, keeping sliced samples at their original playback speed. It previews the final range and refuses values outside the S950’s note or transpose limits without making partial changes. Fine tuning and unrelated parameters are preserved. Non-zero Fine values are normalized with the Transpose value as one pitch, so the result stays consistent after save/reopen and on the S950 display.

### Import an Ableton Drum Rack

The importer is intended for Drum Rack pads containing Ableton Sampler or Simpler devices with one distinct sample zone per occupied pad:

1. Open the destination P9 directly from a writable S950 IMG.
2. Choose **Import ADG…** in the P9 editor.
3. Select the Ableton `.adg` preset.
4. Choose the first destination note and shared sample root note. Source pad-note gaps are retained when the notes are offset.
5. Choose MIDI channel, S950 output and optional compressed S9 conversion.
6. Review and edit the S950 name for every sample. Each name is uppercase, AKAI-compatible, unique and at most 10 characters.
7. Choose **Import Samples and Add Keygroups**.
8. After conversion and verification, save a P9 copy or use the verified **Overwrite in IMG…** workflow.

The importer reads WAV paths stored by Ableton, converts each source to a native S9 through AKAI Util, and adds one S950 keygroup per pad. For a new program, the first pad replaces the blank full-range keygroup. Ableton’s rack order is retained even when receiving-note values run in the opposite direction. Low and High are set to the offset pad note. Transpose uses `shared root − destination note`; Ableton Detune is converted to the nearest 1/16-semitone Fine value. Velocity-to-volume and velocity-to-filter are mapped from Ableton’s 0–100% values to the S950’s 00–99 sensitivity fields. When the Ableton filter is enabled, its 30–22,000 Hz cutoff is mapped logarithmically to S950 Filter 00–99; a disabled filter becomes Filter 99 with filter velocity sensitivity 0. The chosen MIDI channel and output are applied, while other keygroup parameters use the app’s S950 defaults.

After import, each P9 sample name is resolved from the exact S9 name reported by AKAI Util and the old sample-header RAM address is cleared. These corrections address build 17’s silent imported keygroups and program-only load behavior.

Import is refused before mutation if source audio is missing, a pad has genuine multiple sample zones, a name collides, notes overlap existing sampled keygroups, a mapping exceeds MIDI or S950 transpose limits, the volume lacks file slots, or the P9 would exceed 99 keygroups. If sample import fails part-way through, the app attempts to remove every S9 created by that operation.

### Export an S950 program to an Ableton Drum Rack

1. Open the S950 IMG and select one P9 program.
2. Choose **Image → Export Selected P9 as Ableton Drum Rack…**, or right-click the row and choose **Export P9 as Ableton Drum Rack…**.
3. Choose a destination folder.
4. Open the generated `.adg` in Ableton Live 12.4.3. Keep the ADG beside its generated `Samples` folder when moving or sharing it.

The export is read-only and is available for writable or read-only S950 images. It exports every distinct referenced Soft S9 once as WAV and creates one Sampler pad for each keygroup with a Soft sample. Low note, sample name, root pitch, Fine tuning, base Filter, velocity-to-loudness and velocity-to-filter are translated to the rack. The app then parses the generated ADG and compares those values before reporting success; a failed or cancelled export removes only its newly created output folder.

Drum Rack pads cannot cover key ranges, so a ranged S950 keygroup is placed on its Low note. Loud sample layers and keygroups without a Soft sample are omitted. When any of those cases occur, the generated folder includes `Export Notes.txt` with the exact omissions. Duplicate Low notes, missing referenced S9 files and unsafe root notes are rejected before a rack is written.

### Copy keygroups between programs and IMG files

1. Open the source P9 and select the required keygroups.
2. Choose **Transfer → Copy Selected Keygroups and Samples**.
3. Close the source editor and, if required, open a different IMG.
4. Open the destination P9.
5. Choose **Transfer → Paste … at End**.
6. Wait for the footer to say the pasted keygroups are ready, then click **Apply … Pasted Keygroups**.
7. Choose **Overwrite in IMG…** to back up, replace and byte-verify the expanded destination P9. Use **Save Edited Copy…** instead when a separate local copy is preferred.

If the destination volume has no P9 program:

1. Copy the required keygroups from the source P9 as above.
2. Open the blank writable destination IMG.
3. Choose **New Program from Copied Keygroups…** from the empty-volume screen, Image menu or More menu.
4. Enter the new program name.
5. The editor opens with the copied keygroups already applied.
6. Choose **Create in IMG…**. The app imports the P9, exports it again, and requires an exact byte match.

The zero-keygroup template exists only in memory. It is built from the copied source program’s header settings with the sampler-maintained first-keygroup address cleared. The app does not save an empty P9 to the IMG; the first file it can create contains the applied copied keygroups.

The transfer stages P9 keygroup records and associated native S9 files. It remains available while switching IMG files. If a destination sample name already exists, the copied S9 receives a unique native name and the pasted keygroup is rewritten to reference the exact sampler-visible result. Source files are never modified.

Pasted keygroups added to an existing destination program remain pending until the explicit Apply step, then they are appended at the end. **Save Edited Copy…** is unavailable while such a paste is pending. **New Program from Copied Keygroups…** applies its copied keygroups automatically because creating that program is already an explicit action. Associated samples are imported automatically when the destination P9 was opened from a writable IMG; a standalone destination P9 receives the keygroups only.

The S950 stores sampler-maintained RAM addresses for the first keygroup, both sample headers and the next keygroup. Transfer clears those destination-specific addresses while preserving the musical parameters and other bytes, allowing the sampler to rebuild them when loading the new program.

### Create a new S950 program

1. Open the exact writable IMG volume that should receive the program.
2. Choose **New S950 Program…** from the toolbar, Image menu, More menu or empty-volume screen.
3. Enter a unique program name of up to 10 characters.
4. The editor opens with one blank keygroup. Choose its Soft and optional Loud samples from the volume menus, edit the range and other settings, and click **Apply**.
5. Add, duplicate or delete keygroups as required.
6. Choose **Create in IMG…**.

Creation refuses a colliding P9 name, a different currently open image/volume, insufficient free space or a full file directory. After writing, the app re-exports the P9 and compares every byte with the prepared program. If creation or verification fails, it attempts to remove the incomplete new P9 automatically.

The built-in blank-program template and structural keygroup add/delete path have passed automated byte-layout, AKAI Util image and physical S950 tests.

### Safely overwrite a P9 inside its IMG

When a P9 was opened directly from a writable IMG:

1. Make and Apply the required edits.
2. Choose **Overwrite in IMG…**.
3. Leave the verified-backup checkbox enabled, or explicitly disable it, then confirm the overwrite.
4. Wait for the editor and header to report that the replacement was byte-verified.

When enabled, overwrite creates a complete timestamped IMG backup in the configured backup folder and verifies it before changing the volume. The app then replaces the exact source P9, exports the stored result again and compares every byte with the edited program. A failed write is restored automatically only when that backup was created.

The original program name must be retained during overwrite. Use **Save Edited Copy…** and import the copy when creating a renamed program. A newly created program becomes eligible for the same verified overwrite workflow after its first successful **Create in IMG…** operation.

Unknown P9 bytes and sampler-maintained address fields are preserved unless a documented editor operation intentionally changes them.

## Safety

- Open irreplaceable images read-only first.
- Formatting and deletion modify the open image and cannot be undone without a backup.
- P9 overwrite and external S9 replacement offer a default-on verified-backup checkbox. Disabling it also disables automatic rollback.
- Native S9/P9 rename always creates and verifies its own full IMG backup and automatically restores it after any post-mutation failure.
- The default backup location is beside the IMG; Settings can redirect all IMG backups to one existing folder.
- An IMG already named with one or more trailing backup timestamps receives one clean, current backup timestamp rather than a chained name.
- Every successful AKAI command that changes image content updates the IMG file’s macOS modification date.
- The app never exposes physical-drive formatting.
- New-image, format and sample-conversion choices are limited to the S950 workflows described in this README.
- Commands are serialized so only one AKAI Util operation runs at a time.
- Clean Eject closes AKAI Util, hands the exact mounted volume to USBclean, waits for it to unmount, and then reports **Safe to unplug** in the header without a confirmation dialog.
- Successful operations report through the same non-blocking header style. Errors and confirmations before destructive actions remain dialogs.
- Imported source WAV, S9 and P9 files are staged through temporary copies and are not modified. The temporary WAV intentionally opened for external S9 editing is the only staged file the chosen editor is expected to change.
- Closing a P9 edit that has neither been written to the IMG nor saved as an edited copy requires confirmation.

## Current limitations

- Drum Sampler pads and genuine multi-zone/velocity-layer pads are not imported yet.
- S950-to-Ableton export creates Sampler devices only, exports Soft layers only, and places key ranges on their Low note. Its sanitized template targets Live 12.4.3; corrected pad-note direction and read-only export passed user testing in that Live build.
- Root pitch, playback direction and marker-derived loop mode are editable. Ordinary import, cue reconstruction and genuine-IMG replacement pass automated round trips but need a short physical-S950 acceptance test. Sample-rate editing remains deferred.

## Troubleshooting

### “AKAI Util is not executable” or “not detected”

Choose the executable again in Settings. If needed, apply the `chmod +x` command shown above.

### Apple-silicon Mac asks for Rosetta

Install Rosetta. The GUI is native, but AKAI Util 4.6.7 is an Intel command-line executable.

### The app or AKAI Util is blocked by macOS

Try opening it once, then use **System Settings → Privacy & Security → Open Anyway** only after confirming the download source and checksum.

### Import is disabled

The image is read-only, the current volume is not identified as S950 format, or another operation is still finishing.

### Clean Eject is disabled

USBclean is optional and must be installed or selected in Settings. The IMG must also be located on a mounted volume under `/Volumes`.

### A command fails

Open the Diagnostic Log from the More menu. When reporting a problem, include:

- macOS version and Mac type;
- AKAI Util version;
- image size and density;
- the relevant Diagnostic Log section;
- exact steps that reproduce the problem.

Use a disposable copy of an IMG when sharing a reproduction.

### Edit Sample is disabled

Select exactly one sample in a writable S950 volume.

### The edited WAV is reported as unchanged

Save over the WAV opened by the app, then return to AKAI Image Manager and try **Back Up and Replace Sample** again. Do not use Save As in the external editor.

## Privacy and networking

AKAI Image Manager contains no telemetry, analytics, advertising or updater. It does not make network requests. Network links in this README are for manually obtaining third-party dependencies and support information.

## Third-party and trademark notice

See `THIRD-PARTY-NOTICES.txt` for official sources and terms.

AKAI is a trademark of its respective owner. AKAI Image Manager is an independent community project and is not affiliated with or endorsed by Akai Professional. USBclean is a product of SweetP Productions, Inc.

## Known distribution limitation

This build is ad-hoc signed and is not notarized. A future public release should ideally be signed with an Apple Developer ID certificate and notarized so community users receive the normal verified-developer launch experience.
