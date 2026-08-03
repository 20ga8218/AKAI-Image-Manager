import AppKit
import CryptoKit

@main
@MainActor
struct KeygroupTransferRegressionRunner {
    static func main() async {
        guard CommandLine.arguments.count >= 2 else {
            fputs(
                "usage: KeygroupTransferRegressionRunner <source.img> [akaiutil]\n",
                stderr
            )
            exit(2)
        }

        let sourceImage = URL(fileURLWithPath: CommandLine.arguments[1])
        let executable = URL(
            fileURLWithPath: CommandLine.arguments.dropFirst(2).first
                ?? AppSettings.executableDefault
        )
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("akai-keygroup-transfer-\(UUID().uuidString)", isDirectory: true)
        let sourceCopy = workspace.appendingPathComponent(sourceImage.lastPathComponent)
        let destinationImage = workspace.appendingPathComponent("TRANSFER-DEST.img")
        let sourceProgramDirectory = workspace.appendingPathComponent("source-program", isDirectory: true)
        let collisionDirectory = workspace.appendingPathComponent("collision", isDirectory: true)
        let verificationDirectory = workspace.appendingPathComponent("verification", isDirectory: true)
        let seedingController = AkaiCommandController()

        do {
            let sourceChecksum = try checksum(sourceImage)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workspace) }
            for directory in [
                sourceProgramDirectory,
                collisionDirectory,
                verificationDirectory
            ] {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
            }
            try FileManager.default.copyItem(at: sourceImage, to: sourceCopy)
            try ImageFileOperations.createZeroFilledImage(
                at: destinationImage,
                byteCount: FormatPreset.s900High.byteCount
            )

            _ = try await seedingController.open(
                imageURL: destinationImage,
                executableURL: executable,
                readOnly: false
            )
            _ = try await seedingController.send(FormatPreset.s900High.command)
            await seedingController.close()
            print("✓ Created a disposable blank S900 destination IMG")

            guard let defaults = UserDefaults(
                suiteName: "AKAIImageManager.KeygroupTransfer.\(UUID().uuidString)"
            ) else {
                throw TransferRegressionFailure("Could not create isolated settings.")
            }
            let settings = AppSettings(defaults: defaults)
            settings.executablePath = executable.path
            settings.backupBeforeDestructive = false
            let model = AppModel(settings: settings)

            try await model.openImage(sourceCopy, readOnly: false)
            guard let sourceFile = model.snapshot.files.first(where: {
                $0.name.uppercased().hasSuffix(".P9")
            }) else {
                throw TransferRegressionFailure("The source IMG has no P9 program.")
            }
            try await model.exportNativeFiles(
                [sourceFile],
                to: sourceProgramDirectory,
                policy: .rename,
                revealInFinder: false
            )
            model.report = nil
            let sourceProgramURL = sourceProgramDirectory.appendingPathComponent(sourceFile.name)
            let sourceProgram = try P9Program(data: Data(contentsOf: sourceProgramURL))
            guard let sourceIndex = sourceProgram.keygroups.indices.first(where: { index in
                let references = [
                    sourceProgram.keygroups[index].softSampleName,
                    sourceProgram.keygroups[index].loudSampleName
                ]
                return references.contains { reference in
                    model.snapshot.files.contains {
                        $0.isSample
                            && normalizedSampleName(
                                sampleBaseName($0.name)
                            ) == normalizedSampleName(reference)
                    }
                }
            }) else {
                throw TransferRegressionFailure(
                    "No source keygroup referenced a sample present in the IMG."
                )
            }

            try await model.stageKeygroupTransfer(
                from: sourceProgram,
                indexes: [sourceIndex],
                source: .image(
                    filename: sourceFile.name,
                    imageURL: sourceCopy
                )
            )
            guard let transfer = model.keygroupTransfer,
                  let collisionSourceName = transfer.sampleNames.first(where: {
                      transfer.sampleFiles[$0.uppercased()] != nil
                  }),
                  let collisionSourceURL = transfer.sampleFiles[
                    collisionSourceName.uppercased()
                  ]
            else {
                throw TransferRegressionFailure(
                    "The source keygroup did not stage an associated S9 sample."
                )
            }
            let runtimeAddressOffsets = [0x28, 0x3E, 0x44]
            let sourceHadRuntimeAddress = runtimeAddressOffsets.contains(where: { offset in
                transfer.records[0][offset] != 0
                    || transfer.records[0][offset + 1] != 0
            })
            print("✓ Staged one genuine keygroup and its associated native S9 sample")
            print(
                sourceHadRuntimeAddress
                    ? "✓ Source keygroup contained sampler runtime addresses to sanitize"
                    : "✓ Source keygroup already contained transfer-safe zero runtime addresses"
            )

            try await model.openImage(destinationImage, readOnly: false)
            guard model.snapshot.files.isEmpty else {
                throw TransferRegressionFailure(
                    "The disposable destination was not blank before transfer."
                )
            }

            let collisionBase = AkaiFilename.sanitizedBase(
                collisionSourceName,
                family: .s900,
                maximumLength: 10
            )
            let collisionURL = collisionDirectory
                .appendingPathComponent("\(collisionBase).S9")
            try FileManager.default.copyItem(at: collisionSourceURL, to: collisionURL)
            try await model.importNativeFiles([collisionURL], policy: .rename)
            model.report = nil
            print("✓ Seeded the destination with a deliberate sample-name collision")

            let destinationDocument = try await model.prepareP9FromCopiedKeygroups(
                named: "TRANSFER"
            )
            let initialKeygroupCount = destinationDocument.program.keygroups.count
            guard model.report == nil,
                  destinationDocument.pendingKeygroupPaste == nil,
                  initialKeygroupCount == 1,
                  destinationDocument.originalData.count == P9Program.headerSize,
                  destinationDocument.originalData[0x12] == 0,
                  destinationDocument.originalData[0x13] == 0,
                  destinationDocument.originalData[0x17] == 0
            else {
                throw TransferRegressionFailure(
                    "The new program was not a safe in-memory zero-keygroup template."
                )
            }
            print("✓ Created a safe in-memory P9 with its copied keygroup already applied")

            let appended = destinationDocument.program.keygroups[0]
            let original = sourceProgram.keygroups[sourceIndex]
            let renamedReference: String
            if normalizedSampleName(original.softSampleName)
                == normalizedSampleName(collisionSourceName) {
                renamedReference = appended.softSampleName
            } else if normalizedSampleName(original.loudSampleName)
                == normalizedSampleName(collisionSourceName) {
                renamedReference = appended.loudSampleName
            } else {
                throw TransferRegressionFailure("The staged collision sample was not in the copied keygroup.")
            }
            guard normalizedSampleName(renamedReference)
                    != normalizedSampleName(collisionSourceName),
                  model.snapshot.files.contains(where: {
                      $0.isSample
                          && normalizedSampleName(
                              sampleBaseName($0.name)
                          ) == normalizedSampleName(renamedReference)
                  }) else {
                throw TransferRegressionFailure(
                    "The collision was not renamed consistently in the sample and keygroup."
                )
            }
            print("✓ Imported the associated sample under a unique name and rewrote the P9 reference")

            let expandedData = try destinationDocument.program.encoded()
            let appendedBase = P9Program.headerSize
            guard runtimeAddressOffsets.allSatisfy({
                expandedData[appendedBase + $0] == 0
                    && expandedData[appendedBase + $0 + 1] == 0
            }),
            expandedData[0x12] == 0,
            expandedData[0x13] == 0
            else {
                throw TransferRegressionFailure(
                    "A source sampler RAM address survived in the new destination program."
                )
            }
            print("✓ Cleared program, sample-header and next-keygroup runtime addresses")
            let reopened = try P9Program(data: expandedData)
            guard reopened.keygroups.count == initialKeygroupCount else {
                throw TransferRegressionFailure("The expanded P9 did not survive save and reopen.")
            }
            let expandedURL = workspace.appendingPathComponent("TRANSFER.P9")
            try expandedData.write(to: expandedURL, options: .atomic)
            try await model.importNativeFiles([expandedURL], policy: .rename)
            model.report = nil
            guard let importedProgram = model.snapshot.files.first(where: {
                $0.name.caseInsensitiveCompare("TRANSFER.P9") == .orderedSame
            }) else {
                throw TransferRegressionFailure("The expanded P9 was not imported into the destination IMG.")
            }
            try await model.exportNativeFiles(
                [importedProgram],
                to: verificationDirectory,
                policy: .rename,
                revealInFinder: false
            )
            model.report = nil
            let verified = try P9Program(
                data: Data(
                    contentsOf: verificationDirectory
                        .appendingPathComponent(importedProgram.name)
                )
            )
            guard verified.keygroups.count == initialKeygroupCount else {
                throw TransferRegressionFailure(
                    "The destination IMG did not preserve the expanded P9 keygroup count."
                )
            }
            print("✓ Imported and re-exported the expanded P9 through AKAI Util")

            await model.shutdown()
            guard try checksum(sourceImage) == sourceChecksum else {
                throw TransferRegressionFailure("The original source IMG was modified.")
            }
            print("✓ Original source IMG checksum is unchanged")
            print("\nCross-IMG keygroup transfer regression passed")
        } catch {
            await seedingController.close()
            fputs(
                "Cross-IMG keygroup transfer regression failed: \(error.localizedDescription)\n",
                stderr
            )
            exit(1)
        }
    }

    private static func sampleBaseName(_ filename: String) -> String {
        (filename as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespaces)
    }

    private static func normalizedSampleName(_ name: String) -> String {
        name.uppercased()
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
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
}

private struct TransferRegressionFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
