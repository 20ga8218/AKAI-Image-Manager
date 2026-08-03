import Foundation

enum AkaiFamily: String, CaseIterable, Codable, Identifiable {
    case s900 = "S950"

    var id: String { rawValue }
}

enum CollisionPolicy: String, CaseIterable, Codable, Identifiable {
    case replace = "Replace"
    case skip = "Skip"
    case rename = "Create Unique Name"

    var id: String { rawValue }
}

struct ImportOptions: Equatable {
    var family: AkaiFamily = .s900
    var compressedS900 = false
    var convertToMono = true
    var preserveSampleRate = true
    var collisionPolicy: CollisionPolicy = .rename
}

struct AkaiFile: Identifiable, Hashable {
    let id: String
    let index: Int
    let name: String
    let type: String
    let byteSize: Int64
    let startBlock: Int?
    let compression: String?

    init(
        id: String? = nil,
        index: Int,
        name: String,
        type: String = "File",
        byteSize: Int64,
        startBlock: Int? = nil,
        compression: String? = nil
    ) {
        self.id = id ?? Self.stableID(index: index, name: name, startBlock: startBlock)
        self.index = index
        self.name = name
        self.type = type
        self.byteSize = byteSize
        self.startBlock = startBlock
        self.compression = compression
    }

    var isSample: Bool {
        let upper = name.uppercased()
        return upper.hasSuffix(".S") || upper.hasSuffix(".S9") || type.localizedCaseInsensitiveContains("sample")
    }

    private static func stableID(index: Int, name: String, startBlock: Int?) -> String {
        "\(index)|\(startBlock ?? -1)|\(name.uppercased())"
    }
}

struct AkaiDisk: Identifiable, Hashable {
    var id: Int { number }
    let number: Int
    let type: String
    let partitionCount: Int
    let blockSize: Int
    let totalBlocks: Int
    let freeBlocks: Int

    var totalBytes: Int64 { Int64(blockSize) * Int64(totalBlocks) }
    var freeBytes: Int64 { Int64(blockSize) * Int64(freeBlocks) }
}

struct AkaiPartition: Identifiable, Hashable {
    var id: String { "\(diskNumber)-\(letter)" }
    let diskNumber: Int
    let letter: String
    let type: String
    let startBlock: Int
    let totalBlocks: Int
    let freeBlocks: Int
}

struct AkaiVolume: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let index: Int?
}

struct DiskSnapshot: Equatable {
    var disks: [AkaiDisk] = []
    var partitions: [AkaiPartition] = []
    var volumes: [AkaiVolume] = []
    var files: [AkaiFile] = []
    var currentPath = "/"
    var fileCount = 0
    var maximumFileCount: Int?
    var rawDF = ""
    var rawDInfo = ""
    var rawDirectory = ""

    var totalBytes: Int64 { disks.reduce(0) { $0 + $1.totalBytes } }
    var freeBytes: Int64 { disks.reduce(0) { $0 + $1.freeBytes } }
    var usedBytes: Int64 { max(0, totalBytes - freeBytes) }
}

struct ImageSession: Equatable {
    let imageURL: URL
    let readOnly: Bool
    let removableVolumeURL: URL?
    let openedAt: Date

    var isRemovable: Bool { removableVolumeURL != nil }
}

struct CommandResult: Equatable {
    let command: String
    let output: String
    let cleanedOutput: String
}

enum ControllerState: Equatable {
    case closed
    case launching
    case ready
    case running(String)
    case quitting
    case failed(String)
}

enum OperationKind: String {
    case opening = "Opening image"
    case refreshing = "Refreshing"
    case importing = "Importing"
    case exporting = "Exporting"
    case deleting = "Deleting"
    case formatting = "Formatting"
    case backingUp = "Creating backup"
    case overwriting = "Overwriting P9"
    case renaming = "Renaming AKAI file"
    case editingSample = "Editing S9 sample"
    case copying = "Copying to USB"
    case ejecting = "Cleaning and ejecting"
}

struct P9OverwriteResult: Equatable {
    let filename: String
    let backupURL: URL?
    let verifiedByteCount: Int
}

struct S9ReplacementResult: Equatable {
    let filename: String
    let backupURL: URL?
    let verifiedByteCount: Int
    let wavInspection: WAVInspection
}

struct OperationProgress: Equatable {
    let kind: OperationKind
    var current: Int
    var total: Int
    var detail: String

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(current) / Double(total)))
    }
}

struct OperationReport: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let lines: [String]
    let isError: Bool
}

struct HeaderNotice: Equatable {
    let title: String
    let detail: String
    let systemImage: String
}

struct AkaiFileInformation: Identifiable, Equatable {
    let id = UUID()
    let filename: String
    let details: String
}

struct P9PendingKeygroupPaste {
    let records: [Data]
    let sampleNameMapping: [String: String]
    let statusLines: [String]

    var count: Int { records.count }
}

struct P9KeygroupTransfer {
    let programHeaderTemplate: Data
    let records: [Data]
    let sampleFiles: [String: URL]
    let sampleNames: [String]
    let missingSampleNames: [String]
    let sourceProgramName: String
    let sourceImageURL: URL?
    let sourceVolumePath: String?
    let createdAt: Date

    var summary: String {
        let keygroupText = records.count == 1 ? "1 keygroup" : "\(records.count) keygroups"
        let sampleText = sampleFiles.count == 1 ? "1 sample" : "\(sampleFiles.count) samples"
        return "\(keygroupText) and \(sampleText) from \(sourceProgramName)"
    }
}

enum FormatPreset: String, CaseIterable, Identifiable {
    case s900Low = "S950 Low-Density Floppy"
    case s900High = "S950 High-Density Floppy"
    case s900Hard32 = "S950 Hard Disk — 32 MB"

    var id: String { rawValue }

    var byteCount: UInt64 {
        switch self {
        case .s900Low: return 800 * 1024
        case .s900High: return 1600 * 1024
        case .s900Hard32: return 32 * 1024 * 1024
        }
    }

    var command: String {
        switch self {
        case .s900Low: return "formatfloppyl9"
        case .s900High: return "formatfloppyh9"
        case .s900Hard32: return "formatharddisk9 32M"
        }
    }

    var isFloppy: Bool {
        byteCount == 800 * 1024 || byteCount == 1600 * 1024
    }

    var requiresInitialVolume: Bool {
        self == .s900Hard32
    }
}

struct WAVInspection: Equatable {
    let url: URL
    let codecDescription: String
    let sampleRate: Double
    let frameCount: Int64
    let cueSampleOffsets: [UInt32]
    let channelCount: Int
    let bitDepth: Int
    let isLinearPCM: Bool
    let needsRepair: Bool
    let repairReasons: [String]
}

enum AppError: LocalizedError {
    case invalidExecutable(String)
    case noImageOpen
    case controllerBusy
    case processFailed(String)
    case promptNotFound(String)
    case unsafeCommand(String)
    case parseFailed(String)
    case readOnly
    case insufficientSpace(required: Int64, available: Int64)
    case unsupportedWAV(String)
    case usbVolumeNotFound
    case usbCleanNotFound
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidExecutable(let path): return "AKAI Util is not executable at \(path)."
        case .noImageOpen: return "Open an AKAI image first."
        case .controllerBusy: return "Another AKAI operation is already running."
        case .processFailed(let detail): return "AKAI Util failed: \(detail)"
        case .promptNotFound(let output): return "AKAI Util did not return to its prompt.\n\n\(output)"
        case .unsafeCommand(let detail): return "The command could not be sent safely: \(detail)"
        case .parseFailed(let detail): return "AKAI Util returned information that could not be interpreted: \(detail)"
        case .readOnly: return "This image is open read-only."
        case .insufficientSpace(let required, let available):
            return "The import needs \(required.formattedByteCount), but only \(available.formattedByteCount) is free."
        case .unsupportedWAV(let detail): return "The WAV file could not be prepared: \(detail)"
        case .usbVolumeNotFound: return "No exact mounted USB destination was found."
        case .usbCleanNotFound: return "USBclean could not be found."
        case .verificationFailed(let detail): return "Verification failed: \(detail)"
        }
    }
}

extension Int64 {
    var formattedByteCount: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
