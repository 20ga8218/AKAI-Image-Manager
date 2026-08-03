import AppKit
import CryptoKit
import SwiftUI

@main
@MainActor
struct GenuineImageRegressionRunner {
    static func main() async {
        guard CommandLine.arguments.count >= 2 else {
            fputs("usage: GenuineImageRegressionRunner <source.img> [akaiutil]\n", stderr)
            exit(2)
        }

        let sourceImage = URL(fileURLWithPath: CommandLine.arguments[1])
        let executable = URL(
            fileURLWithPath: CommandLine.arguments.dropFirst(2).first
                ?? AppSettings.executableDefault
        )
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("akai-genuine-\(UUID().uuidString)", isDirectory: true)
        let workingImage = workspace.appendingPathComponent(sourceImage.lastPathComponent)
        let firstExportDirectory = workspace.appendingPathComponent("first-export", isDirectory: true)
        let secondExportDirectory = workspace.appendingPathComponent("second-export", isDirectory: true)
        let originalSampleDirectory = workspace.appendingPathComponent("original-sample", isDirectory: true)
        let editedSampleDirectory = workspace.appendingPathComponent("edited-sample", isDirectory: true)
        let backupDirectory = workspace.appendingPathComponent("backups", isDirectory: true)

        do {
            let originalChecksum = try checksum(sourceImage)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workspace) }
            try FileManager.default.createDirectory(
                at: firstExportDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: secondExportDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: originalSampleDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: editedSampleDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: backupDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: sourceImage, to: workingImage)
            let oldModificationDate = Date(timeIntervalSince1970: 946_684_800)
            try FileManager.default.setAttributes(
                [.modificationDate: oldModificationDate],
                ofItemAtPath: workingImage.path
            )
            guard try checksum(workingImage) == originalChecksum else {
                throw GenuineRegressionFailure("The disposable IMG copy did not match its source.")
            }
            print("✓ Created a checksum-matched disposable IMG copy")

            guard let defaults = UserDefaults(
                suiteName: "AKAIImageManager.GenuineRegression.\(UUID().uuidString)"
            ) else {
                throw GenuineRegressionFailure("Could not create isolated test settings.")
            }
            let settings = AppSettings(defaults: defaults)
            settings.executablePath = executable.path
            settings.backupBeforeDestructive = false
            settings.backupFolderPath = backupDirectory.path
            let model = AppModel(settings: settings)

            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.finishLaunching()
            let root = MainView()
                .environmentObject(model)
                .environmentObject(settings)
                .frame(width: 1180, height: 760)
            let hostingView = NSHostingView(rootView: root)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentView = hostingView
            window.makeKeyAndOrderFront(nil)

            try await model.openImage(workingImage, readOnly: false)
            try await Task.sleep(nanoseconds: 400_000_000)
            hostingView.layoutSubtreeIfNeeded()

            let originalFileCount = model.snapshot.files.count
            var programs = model.snapshot.files.filter {
                $0.name.uppercased().hasSuffix(".P9")
            }
            guard !programs.isEmpty else {
                throw GenuineRegressionFailure("The supplied IMG does not contain a P9 file.")
            }
            print("✓ Rendered \(originalFileCount) genuine files, including \(programs.count) P9 programs")

            guard let table = findFileTable(
                in: hostingView,
                expectedRowCount: originalFileCount
            ), let target = programs.first,
                  let targetRow = model.snapshot.files.firstIndex(where: { $0.id == target.id })
            else {
                throw GenuineRegressionFailure("Could not locate the rendered genuine file table.")
            }
            table.selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
            try await Task.sleep(nanoseconds: 120_000_000)
            guard model.selection.contains(target.id) else {
                throw GenuineRegressionFailure("Native table selection did not reach the P9 binding.")
            }
            print("✓ Selected \(target.name) through the rendered native table")

            model.openEditor(for: target)
            var editorWaitAttempts = 0
            while model.operationActive && editorWaitAttempts < 100 {
                try await Task.sleep(nanoseconds: 50_000_000)
                editorWaitAttempts += 1
            }
            guard let editor = model.p9EditorDocument,
                  editor.source.filename.caseInsensitiveCompare(target.name) == .orderedSame,
                  !editor.program.keygroups.isEmpty
            else {
                throw GenuineRegressionFailure("Double-click editor routing did not open the genuine P9.")
            }
            let sampledKeygroups = editor.program.keygroups.filter {
                !$0.softSampleName.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
            }
            let imageBeforeAbletonExport = try checksum(workingImage)
            let templateURL = URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath
            ).appendingPathComponent(
                "Sources/AKAIImageManager/Resources/AKAI-S950-Sampler-Template.adg"
            )
            let abletonExport = try await model.performAbletonDrumRackExport(
                target,
                to: workspace,
                templateURL: templateURL
            )
            let exportedPreset = try AbletonDrumRackParser.parse(
                url: abletonExport.adgURL
            )
            let generatedXML = try AbletonDrumRackExporter.decompressedADG(
                Data(contentsOf: abletonExport.adgURL)
            )
            let generatedDocument = try XMLDocument(data: generatedXML)
            let storedReceivingNotes = try generatedDocument.nodes(
                forXPath: "/Ableton/GroupDevicePreset/BranchPresets/DrumBranchPreset/ZoneSettings/ReceivingNote/@Value"
            ).compactMap { Int($0.stringValue ?? "") }
            let expectedReceivingNotes = sampledKeygroups.map {
                AbletonDrumRackNote.receivingValue(forMIDINote: $0.lowKey)
            }
            guard exportedPreset.samples.count == sampledKeygroups.count,
                  exportedPreset.samples.map(\.sourceNote)
                    == sampledKeygroups.map(\.lowKey),
                  exportedPreset.samples.map(\.sourceName)
                    == sampledKeygroups.map(\.softSampleName),
                  storedReceivingNotes == expectedReceivingNotes,
                  try checksum(workingImage) == imageBeforeAbletonExport
            else {
                throw GenuineRegressionFailure(
                    "The genuine P9-to-Ableton export changed pad order, MIDI notes, sample names or the source IMG."
                )
            }
            print(
                "✓ Exported \(sampledKeygroups.count) genuine keygroups to correctly encoded Ableton pad notes"
            )
            let imageBeforeOverwrite = try checksum(workingImage)
            var editedProgram = editor.program
            let originalLoudness = editedProgram.keygroups[0].softLoudness
            editedProgram.keygroups[0].softLoudness =
                originalLoudness >= 50 ? originalLoudness - 1 : originalLoudness + 1
            editor.program = editedProgram
            let intendedEditedData = try editedProgram.encoded()
            let overwriteResult = try await model.performP9Overwrite(editor)
            guard let overwriteBackupURL = overwriteResult.backupURL,
                  overwriteBackupURL.deletingLastPathComponent().standardizedFileURL
                    == backupDirectory.standardizedFileURL,
                  try checksum(overwriteBackupURL) == imageBeforeOverwrite
            else {
                throw GenuineRegressionFailure(
                    "The automatic overwrite backup did not match the pre-edit IMG."
                )
            }
            guard overwriteResult.verifiedByteCount == intendedEditedData.count,
                  !editor.hasChanges,
                  model.report == nil,
                  model.headerNotice?.title == "P9 Overwritten and Verified"
            else {
                throw GenuineRegressionFailure(
                    "The successful overwrite was not verified or reported non-modally."
                )
            }
            let modifiedAfterOverwrite = try workingImage.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            guard let modifiedAfterOverwrite,
                  modifiedAfterOverwrite > oldModificationDate
            else {
                throw GenuineRegressionFailure(
                    "The IMG modification date was not updated after overwrite."
                )
            }
            let imageBeforeForcedFailure = try checksum(workingImage)
            var secondEdit = editor.program
            let originalFilter = secondEdit.keygroups[0].softFilter
            secondEdit.keygroups[0].softFilter =
                originalFilter >= 99 ? originalFilter - 1 : originalFilter + 1
            editor.program = secondEdit
            model.overwriteVerificationMutator = { exportedData in
                var corrupted = exportedData
                if !corrupted.isEmpty {
                    corrupted[corrupted.count - 1] ^= 0x01
                }
                return corrupted
            }
            var forcedVerificationFailed = false
            do {
                _ = try await model.performP9Overwrite(editor)
            } catch {
                forcedVerificationFailed = true
            }
            model.overwriteVerificationMutator = nil
            guard forcedVerificationFailed,
                  try checksum(workingImage) == imageBeforeForcedFailure,
                  editor.hasChanges,
                  model.snapshot.files.contains(where: {
                      $0.name.caseInsensitiveCompare(target.name) == .orderedSame
                  })
            else {
                throw GenuineRegressionFailure(
                    "A forced overwrite failure did not restore the complete IMG."
                )
            }
            editor.program = try P9Program(data: intendedEditedData)
            programs = model.snapshot.files.filter {
                $0.name.uppercased().hasSuffix(".P9")
            }
            model.p9EditorDocument = nil
            print("✓ Double-click routing opened and edited the genuine P9 keygroup editor")
            print("✓ Backed up, overwrote and byte-verified the genuine P9 in its IMG copy")
            print("✓ Forced verification failure restored the complete pre-overwrite IMG")

            try await model.exportNativeFiles(
                programs,
                to: firstExportDirectory,
                policy: .rename,
                revealInFinder: false
            )
            model.report = nil
            let expectedProgramNames = programs.map(\.name).sorted()
            let firstExportNames = try FileManager.default.contentsOfDirectory(
                atPath: firstExportDirectory.path
            ).sorted()
            guard firstExportNames == expectedProgramNames else {
                throw GenuineRegressionFailure(
                    "Raw P9 export names differed: \(firstExportNames.joined(separator: ", "))."
                )
            }
            print("✓ Exported every genuine P9 with one exact extension")

            let firstExport = firstExportDirectory.appendingPathComponent(target.name)
            guard try Data(contentsOf: firstExport) == intendedEditedData else {
                throw GenuineRegressionFailure(
                    "The overwritten P9 in the IMG did not match the intended edited bytes."
                )
            }
            let firstExportChecksum = try checksum(firstExport)
            guard let currentTarget = model.snapshot.files.first(where: {
                $0.name.caseInsensitiveCompare(target.name) == .orderedSame
            }) else {
                throw GenuineRegressionFailure(
                    "The genuine P9 disappeared before deletion testing."
                )
            }
            try await model.delete(files: [currentTarget])
            model.report = nil
            try await Task.sleep(nanoseconds: 200_000_000)
            hostingView.layoutSubtreeIfNeeded()
            guard model.snapshot.files.count == originalFileCount - 1,
                  !model.snapshot.files.contains(where: {
                      $0.name.caseInsensitiveCompare(target.name) == .orderedSame
                  }) else {
                throw GenuineRegressionFailure("The genuine P9 was not removed from the copy.")
            }
            print("✓ Deleted \(target.name) from the rendered disposable copy without crashing")

            try await model.importNativeFiles([firstExport], policy: .rename)
            model.report = nil
            guard let restored = model.snapshot.files.first(where: {
                $0.name.caseInsensitiveCompare(target.name) == .orderedSame
            }), model.snapshot.files.count == originalFileCount else {
                throw GenuineRegressionFailure("The exported P9 did not restore to its original name.")
            }
            print("✓ Re-imported \(target.name) into the disposable copy")

            try await model.exportNativeFiles(
                [restored],
                to: secondExportDirectory,
                policy: .rename,
                revealInFinder: false
            )
            model.report = nil
            let secondExport = secondExportDirectory.appendingPathComponent(target.name)
            guard try checksum(secondExport) == firstExportChecksum else {
                throw GenuineRegressionFailure("The genuine P9 changed during raw round-trip.")
            }
            print("✓ Verified byte-for-byte genuine P9 raw round-trip")

            let noBackupEditor = try P9EditorDocument(
                data: Data(contentsOf: secondExport),
                source: .image(
                    filename: target.name,
                    imageURL: workingImage
                )
            )
            var noBackupProgram = noBackupEditor.program
            noBackupProgram.keygroups[0].softFilter =
                noBackupProgram.keygroups[0].softFilter >= 99
                    ? noBackupProgram.keygroups[0].softFilter - 1
                    : noBackupProgram.keygroups[0].softFilter + 1
            noBackupEditor.program = noBackupProgram
            let noBackupResult = try await model.performP9Overwrite(
                noBackupEditor,
                createBackup: false
            )
            guard noBackupResult.backupURL == nil else {
                throw GenuineRegressionFailure(
                    "P9 overwrite created a backup after the option was disabled."
                )
            }
            print("✓ Optional P9 overwrite completed and verified without creating a backup")

            let referencedSampleNames = Set(
                try P9Program(data: intendedEditedData).keygroups.flatMap {
                    [$0.softSampleName, $0.loudSampleName]
                }.filter { !$0.isEmpty }.map {
                    sampleBaseName($0).uppercased()
                        .replacingOccurrences(of: "_", with: " ")
                }
            )
            guard let sourceSample = model.snapshot.files.first(where: {
                $0.isSample
                    && referencedSampleNames.contains(
                        sampleBaseName($0.name).uppercased()
                            .replacingOccurrences(of: "_", with: " ")
                    )
            }) else {
                throw GenuineRegressionFailure(
                    "The genuine IMG did not contain a P9-referenced S900/S950 sample for external editing."
                )
            }
            try await model.exportNativeFiles(
                [sourceSample],
                to: originalSampleDirectory,
                policy: .rename,
                revealInFinder: false
            )
            model.report = nil
            guard let originalNativeURL = try FileManager.default.contentsOfDirectory(
                at: originalSampleDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).first(where: {
                $0.pathExtension.caseInsensitiveCompare("s9") == .orderedSame
            }) else {
                throw GenuineRegressionFailure("The original native S9 did not export.")
            }
            let originalNativeData = try Data(contentsOf: originalNativeURL)

            try await model.prepareExternalSampleEdit(
                file: sourceSample,
                editorURL: URL(fileURLWithPath: "/Applications/Test Audio Editor.app"),
                launchEditor: false
            )
            guard let sampleEdit = model.externalSampleEditSession else {
                throw GenuineRegressionFailure(
                    "The external sample edit session was not created."
                )
            }
            try replaceFirstPCMSample(in: sampleEdit.wavURL, value: 16_384)
            let editedFrameCount = sampleEdit.originalInspection.frameCount
            guard editedFrameCount >= 8 else {
                throw GenuineRegressionFailure(
                    "The genuine S9 sample is too short for a marker-loop regression."
                )
            }
            let cueStart = UInt32(editedFrameCount / 4)
            let cueEnd = UInt32(editedFrameCount * 3 / 4)
            try appendCueMarkers(
                [cueStart, cueEnd],
                to: sampleEdit.wavURL
            )
            let editedAttributes = S9SampleEditSettings(
                rootNote: min(127, sampleEdit.originalAttributes.rootNote + 1),
                playbackMode: .oneShot,
                playbackDirection: .reverse
            )
            let imageBeforeSampleReplacement = try checksum(workingImage)
            let sampleResult = try await model.performEditedS9Replacement(
                sampleEdit,
                compressed: false,
                attributes: editedAttributes
            )
            guard let sampleBackupURL = sampleResult.backupURL,
                  sampleBackupURL.deletingLastPathComponent().standardizedFileURL
                    == backupDirectory.standardizedFileURL,
                  try checksum(sampleBackupURL) == imageBeforeSampleReplacement,
                  model.report == nil,
                  model.headerNotice?.title == "S9 Sample Replaced and Verified"
            else {
                throw GenuineRegressionFailure(
                    "The edited S9 replacement backup or non-modal report was invalid."
                )
            }
            guard let replacedSample = model.snapshot.files.first(where: {
                $0.isSample
                    && sampleBaseName($0.name)
                        .caseInsensitiveCompare(sampleBaseName(sourceSample.name))
                        == .orderedSame
            }) else {
                throw GenuineRegressionFailure(
                    "The edited S9 did not retain its original sampler-visible name."
                )
            }
            guard referencedSampleNames.contains(
                sampleBaseName(replacedSample.name).uppercased()
                    .replacingOccurrences(of: "_", with: " ")
            ) else {
                throw GenuineRegressionFailure(
                    "The replaced sample no longer matched its P9 program reference."
                )
            }
            try await model.exportNativeFiles(
                [replacedSample],
                to: editedSampleDirectory,
                policy: .rename,
                revealInFinder: false
            )
            model.report = nil
            guard let editedNativeURL = try FileManager.default.contentsOfDirectory(
                at: editedSampleDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).first(where: {
                $0.pathExtension.caseInsensitiveCompare("s9") == .orderedSame
            }), try Data(contentsOf: editedNativeURL) != originalNativeData else {
                throw GenuineRegressionFailure(
                    "The externally edited audio did not produce a changed native S9."
                )
            }
            let storedAttributes = try S9NativeSample.attributes(
                in: Data(contentsOf: editedNativeURL)
            )
            let expectedLoopStart = UInt32(
                (Double(cueStart) * Double(storedAttributes.sampleLength)
                    / Double(editedFrameCount)).rounded()
            )
            let expectedLoopEnd = UInt32(
                (Double(cueEnd) * Double(storedAttributes.sampleLength)
                    / Double(editedFrameCount)).rounded()
            )
            guard storedAttributes.rootNote == editedAttributes.rootNote,
                  storedAttributes.playbackMode == .oneShot,
                  storedAttributes.playbackDirection == .reverse,
                  storedAttributes.playbackEnd == expectedLoopEnd,
                  storedAttributes.loopStart == expectedLoopStart
            else {
                throw GenuineRegressionFailure(
                    "The edited root pitch, direction or marker-derived loop did not survive the native S9 round trip."
                )
            }
            print("✓ Converted an edited WAV and replaced its S9 under the original sample name")
            print("✓ Backed up and byte-verified the edited native S9 inside the IMG copy")
            print("✓ Preserved root, reverse direction and two-marker boundaries in one-shot mode")

            let imageBeforeSampleFailure = try checksum(workingImage)
            try replaceFirstPCMSample(in: sampleEdit.wavURL, value: -16_384)
            model.s9ReplacementVerificationMutator = { exportedData in
                var corrupted = exportedData
                if !corrupted.isEmpty {
                    corrupted[corrupted.count - 1] ^= 0x01
                }
                return corrupted
            }
            var forcedSampleVerificationFailed = false
            do {
                _ = try await model.performEditedS9Replacement(
                    sampleEdit,
                    compressed: false,
                    attributes: editedAttributes
                )
            } catch {
                forcedSampleVerificationFailed = true
            }
            model.s9ReplacementVerificationMutator = nil
            guard forcedSampleVerificationFailed,
                  try checksum(workingImage) == imageBeforeSampleFailure,
                  model.snapshot.files.contains(where: {
                      $0.isSample
                          && sampleBaseName($0.name)
                              .caseInsensitiveCompare(sampleBaseName(sourceSample.name))
                              == .orderedSame
                  })
            else {
                throw GenuineRegressionFailure(
                    "A forced S9 verification failure did not restore the complete IMG."
                )
            }
            let noBackupSampleResult = try await model.performEditedS9Replacement(
                sampleEdit,
                compressed: false,
                createBackup: false,
                attributes: editedAttributes
            )
            guard noBackupSampleResult.backupURL == nil else {
                throw GenuineRegressionFailure(
                    "Edited-S9 replacement created a backup after the option was disabled."
                )
            }
            sampleEdit.removeWorkspace()
            model.externalSampleEditSession = nil
            print("✓ Forced S9 verification failure restored the complete pre-replacement IMG")
            print("✓ Optional edited-S9 replacement completed and verified without a backup")

            await model.shutdown()
            window.orderOut(nil)
            guard try checksum(sourceImage) == originalChecksum else {
                throw GenuineRegressionFailure("The original supplied IMG changed during testing.")
            }
            print("✓ Original source IMG checksum is unchanged")
            print("\nGenuine IMG regression passed")
        } catch {
            fputs("Genuine IMG regression failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func findFileTable(in view: NSView, expectedRowCount: Int) -> NSTableView? {
        if let table = view as? NSTableView,
           table.numberOfColumns >= 6,
           table.numberOfRows == expectedRowCount {
            return table
        }
        for subview in view.subviews {
            if let table = findFileTable(in: subview, expectedRowCount: expectedRowCount) {
                return table
            }
        }
        return nil
    }

    private static func checksum(_ url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize()
    }

    private static func replaceFirstPCMSample(
        in wavURL: URL,
        value: Int16
    ) throws {
        var data = try Data(contentsOf: wavURL)
        let marker = Data("data".utf8)
        guard let markerRange = data.range(of: marker),
              markerRange.upperBound + 6 <= data.count
        else {
            throw GenuineRegressionFailure("The exported WAV has no readable PCM data chunk.")
        }
        let sampleOffset = markerRange.upperBound + 4
        data[sampleOffset] = UInt8(truncatingIfNeeded: value)
        data[sampleOffset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        try data.write(to: wavURL, options: .atomic)
    }

    private static func appendCueMarkers(
        _ sampleOffsets: [UInt32],
        to wavURL: URL
    ) throws {
        var data = try Data(contentsOf: wavURL)
        guard data.count >= 12,
              Data(data[0..<4]) == Data("RIFF".utf8),
              Data(data[8..<12]) == Data("WAVE".utf8)
        else {
            throw GenuineRegressionFailure(
                "The exported sample is not a standard RIFF/WAVE file."
            )
        }
        var payload = Data()
        appendLittleEndian(UInt32(sampleOffsets.count), to: &payload)
        for (index, sampleOffset) in sampleOffsets.enumerated() {
            appendLittleEndian(UInt32(index + 1), to: &payload)
            appendLittleEndian(sampleOffset, to: &payload)
            payload.append(Data("data".utf8))
            appendLittleEndian(UInt32(0), to: &payload)
            appendLittleEndian(UInt32(0), to: &payload)
            appendLittleEndian(sampleOffset, to: &payload)
        }
        data.append(Data("cue ".utf8))
        appendLittleEndian(UInt32(payload.count), to: &data)
        data.append(payload)
        if !payload.count.isMultiple(of: 2) { data.append(0) }
        let riffSize = UInt32(data.count - 8)
        data[4] = UInt8(riffSize & 0xFF)
        data[5] = UInt8((riffSize >> 8) & 0xFF)
        data[6] = UInt8((riffSize >> 16) & 0xFF)
        data[7] = UInt8((riffSize >> 24) & 0xFF)
        try data.write(to: wavURL, options: .atomic)
    }

    private static func appendLittleEndian(
        _ value: UInt32,
        to data: inout Data
    ) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private static func sampleBaseName(_ filename: String) -> String {
        (filename as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespaces)
    }
}

private struct GenuineRegressionFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
