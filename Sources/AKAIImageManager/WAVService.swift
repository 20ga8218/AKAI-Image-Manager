import AVFoundation
import Foundation

enum WAVZeroCrossingDirection: Equatable {
    case upward
    case downward
}

struct WAVZeroCrossing: Equatable {
    let frame: Int
    let direction: WAVZeroCrossingDirection
}

struct WAVZeroCrossingMap: Equatable {
    let frameCount: Int
    let crossings: [WAVZeroCrossing]

    init(samples: [Float]) {
        frameCount = samples.count
        var result: [WAVZeroCrossing] = []
        result.reserveCapacity(samples.count / 16)
        var previousNonzeroSign: Int?
        var zeroRunStart: Int?

        for (frame, sample) in samples.enumerated() {
            let sign = sample > 0 ? 1 : (sample < 0 ? -1 : 0)
            if sign == 0 {
                if previousNonzeroSign != nil, zeroRunStart == nil {
                    zeroRunStart = frame
                }
                continue
            }
            if let previousNonzeroSign,
               sign != previousNonzeroSign {
                result.append(
                    WAVZeroCrossing(
                        frame: zeroRunStart ?? frame,
                        direction: sign > previousNonzeroSign
                            ? .upward : .downward
                    )
                )
            }
            previousNonzeroSign = sign
            zeroRunStart = nil
        }
        crossings = result
    }

    func previous(before frame: Int) -> WAVZeroCrossing? {
        let index = lowerBound(for: frame)
        guard index > 0 else { return nil }
        return crossings[index - 1]
    }

    func next(after frame: Int) -> WAVZeroCrossing? {
        var index = lowerBound(for: frame)
        while index < crossings.count, crossings[index].frame <= frame {
            index += 1
        }
        guard index < crossings.count else { return nil }
        return crossings[index]
    }

    func direction(at frame: Int) -> WAVZeroCrossingDirection? {
        let index = lowerBound(for: frame)
        guard index < crossings.count,
              crossings[index].frame == frame
        else { return nil }
        return crossings[index].direction
    }

    private func lowerBound(for frame: Int) -> Int {
        var lower = 0
        var upper = crossings.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if crossings[middle].frame < frame {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}

enum WAVService {
    static func zeroCrossings(in url: URL) throws -> WAVZeroCrossingMap {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AppError.unsupportedWAV(
                "\(url.lastPathComponent): \(error.localizedDescription)"
            )
        }
        guard file.processingFormat.commonFormat == .pcmFormatFloat32,
              file.processingFormat.channelCount > 0
        else {
            throw AppError.unsupportedWAV(
                "The temporary WAV could not be decoded for zero-crossing navigation."
            )
        }

        var samples: [Float] = []
        if file.length <= Int64(Int.max) {
            samples.reserveCapacity(Int(file.length))
        }
        let capacity: AVAudioFrameCount = 8_192
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: capacity
        ) else {
            throw AppError.unsupportedWAV(
                "A zero-crossing analysis buffer could not be created."
            )
        }
        while file.framePosition < file.length {
            buffer.frameLength = 0
            let remaining = min(
                Int64(capacity),
                file.length - file.framePosition
            )
            try file.read(
                into: buffer,
                frameCount: AVAudioFrameCount(remaining)
            )
            guard buffer.frameLength > 0,
                  let channels = buffer.floatChannelData
            else { break }
            let channelCount = Int(buffer.format.channelCount)
            for frame in 0..<Int(buffer.frameLength) {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += channels[channel][frame]
                }
                samples.append(sum / Float(channelCount))
            }
        }
        guard samples.count == Int(file.length) else {
            throw AppError.unsupportedWAV(
                "The complete temporary WAV could not be analyzed for zero crossings."
            )
        }
        return WAVZeroCrossingMap(samples: samples)
    }

    static func inspect(_ url: URL, options: ImportOptions) throws -> WAVInspection {
        guard url.pathExtension.caseInsensitiveCompare("wav") == .orderedSame else {
            throw AppError.unsupportedWAV("\(url.lastPathComponent) is not a WAV file.")
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AppError.unsupportedWAV("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        let format = file.fileFormat
        let settings = format.settings
        let formatID = (settings[AVFormatIDKey] as? NSNumber)?.uint32Value ?? 0
        let bitDepth = (settings[AVLinearPCMBitDepthKey] as? NSNumber)?.intValue ?? 0
        let isPCM = formatID == kAudioFormatLinearPCM
        let cueOffsets = (
            try? cueSampleOffsets(in: Data(contentsOf: url))
        ) ?? []
        var reasons: [String] = []
        if !isPCM { reasons.append("converted from a non-PCM codec") }
        if format.channelCount == 0 || format.channelCount > 2 { reasons.append("converted from \(format.channelCount) channels") }
        if options.convertToMono && format.channelCount != 1 { reasons.append("mixed down to mono") }
        if bitDepth != 16 { reasons.append("converted from \(bitDepth == 0 ? "unknown" : "\(bitDepth)-bit") audio to 16-bit PCM") }
        if !format.isStandard { reasons.append("rewritten with a canonical WAV format") }
        if !format.sampleRate.isFinite || format.sampleRate < 4_000 || format.sampleRate > 192_000 {
            reasons.append("replaced an invalid or unsupported sample rate")
        }
        let sanitized = AkaiFilename.sanitizedBase(url.lastPathComponent, family: options.family)
        if sanitized.caseInsensitiveCompare(url.deletingPathExtension().lastPathComponent) != .orderedSame {
            reasons.append("sanitized the filename for AKAI compatibility")
        }
        return WAVInspection(
            url: url,
            codecDescription: isPCM ? "Linear PCM" : "Audio format \(formatID)",
            sampleRate: format.sampleRate,
            frameCount: file.length,
            cueSampleOffsets: cueOffsets,
            channelCount: Int(format.channelCount),
            bitDepth: bitDepth,
            isLinearPCM: isPCM,
            needsRepair: !reasons.isEmpty,
            repairReasons: reasons
        )
    }

    static func canonicalCopy(
        of sourceURL: URL,
        to destinationURL: URL,
        options: ImportOptions
    ) throws {
        let source = try AVAudioFile(forReading: sourceURL)
        let sourceFormat = source.processingFormat
        let sampleRate: Double
        if options.preserveSampleRate, sourceFormat.sampleRate.isFinite,
           sourceFormat.sampleRate >= 4_000, sourceFormat.sampleRate <= 192_000 {
            sampleRate = sourceFormat.sampleRate
        } else {
            sampleRate = 44_100
        }
        let channels: AVAudioChannelCount = options.convertToMono ? 1 : min(max(sourceFormat.channelCount, 1), 2)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: true
        ) else {
            throw AppError.unsupportedWAV("Could not create the canonical PCM format.")
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AppError.unsupportedWAV("Could not create an audio converter.")
        }
        let output = try AVAudioFile(
            forWriting: destinationURL,
            settings: targetFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        let inputCapacity: AVAudioFrameCount = 4096
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: inputCapacity) else {
            throw AppError.unsupportedWAV("Could not allocate an audio input buffer.")
        }
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(ceil(Double(inputCapacity) * ratio)) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            throw AppError.unsupportedWAV("Could not allocate an audio output buffer.")
        }

        var reachedEnd = false
        while true {
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, statusPointer in
                if reachedEnd || source.framePosition >= source.length {
                    reachedEnd = true
                    statusPointer.pointee = .endOfStream
                    return nil
                }
                do {
                    inputBuffer.frameLength = 0
                    try source.read(into: inputBuffer, frameCount: inputCapacity)
                    if inputBuffer.frameLength == 0 {
                        reachedEnd = true
                        statusPointer.pointee = .endOfStream
                        return nil
                    }
                    statusPointer.pointee = .haveData
                    return inputBuffer
                } catch {
                    reachedEnd = true
                    statusPointer.pointee = .endOfStream
                    return nil
                }
            }
            if let conversionError { throw conversionError }
            if outputBuffer.frameLength > 0 {
                try output.write(from: outputBuffer)
                outputBuffer.frameLength = 0
            }
            if status == .endOfStream { break }
            if reachedEnd && outputBuffer.frameLength == 0 { break }
            if status == .error {
                throw AppError.unsupportedWAV("Audio conversion failed.")
            }
        }
    }

    static func prepare(
        _ sourceURL: URL,
        in workspace: URL,
        options: ImportOptions,
        finalBase: String
    ) throws -> (url: URL, inspection: WAVInspection) {
        let inspection = try inspect(sourceURL, options: options)
        let destination = workspace.appendingPathComponent("\(finalBase).wav")
        if inspection.needsRepair
            || sourceURL.pathExtension.caseInsensitiveCompare("wav")
                != .orderedSame {
            try canonicalCopy(of: sourceURL, to: destination, options: options)
        } else {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        }
        return (destination, inspection)
    }

    static func cueSampleOffsets(in url: URL) throws -> [UInt32] {
        try cueSampleOffsets(in: Data(contentsOf: url))
    }

    static func cueSampleOffsets(in data: Data) throws -> [UInt32] {
        var result: [UInt32] = []
        for chunk in try riffChunks(in: data) where chunk.identifier == "cue " {
            guard chunk.payload.count >= 4 else {
                throw AppError.unsupportedWAV(
                    "The WAV cue marker chunk is truncated."
                )
            }
            let count = Int(chunk.payload.littleEndianUInt32(at: 0))
            guard count <= (chunk.payload.count - 4) / 24 else {
                throw AppError.unsupportedWAV(
                    "The WAV cue marker table is truncated."
                )
            }
            for index in 0..<count {
                let recordOffset = 4 + index * 24
                result.append(
                    chunk.payload.littleEndianUInt32(at: recordOffset + 20)
                )
            }
        }
        return result
    }

    static func nativeS9Header(in data: Data) throws -> Data? {
        guard let chunk = try riffChunks(in: data).first(where: {
            $0.identifier == "S9H "
        }) else {
            return nil
        }
        guard chunk.payload.count == S9NativeSample.headerLength else {
            throw AppError.unsupportedWAV(
                "The native S9 attribute chunk in the exported WAV has an unexpected size."
            )
        }
        return chunk.payload
    }

    static func replaceNativeS9Header(
        in url: URL,
        with header: Data
    ) throws {
        guard header.count == S9NativeSample.headerLength else {
            throw AppError.unsupportedWAV(
                "The native S9 attribute header must be exactly \(S9NativeSample.headerLength) bytes."
            )
        }
        var data = try Data(contentsOf: url)
        let chunks = try riffChunks(in: data)
        if let existing = chunks.first(where: { $0.identifier == "S9H " }) {
            guard existing.payloadRange.count == header.count else {
                throw AppError.unsupportedWAV(
                    "The existing S9 attribute chunk has an unexpected size."
                )
            }
            data.replaceSubrange(existing.payloadRange, with: header)
        } else {
            data.append(Data("S9H ".utf8))
            data.appendLittleEndianUInt32(UInt32(header.count))
            data.append(header)
            if !header.count.isMultiple(of: 2) { data.append(0) }
            data.writeLittleEndianUInt32(UInt32(data.count - 8), at: 4)
        }
        try data.write(to: url, options: .atomic)
    }

    @discardableResult
    static func addCueSampleOffsetsIfAbsent(
        _ sampleOffsets: [UInt32],
        to url: URL
    ) throws -> Bool {
        guard sampleOffsets.count == 2,
              sampleOffsets[0] < sampleOffsets[1]
        else {
            throw AppError.unsupportedWAV(
                "Exactly two ordered sample offsets are required to create WAV markers."
            )
        }
        let data = try Data(contentsOf: url)
        guard !(try riffChunks(in: data)).contains(where: {
            $0.identifier == "cue "
        }) else {
            return false
        }

        try replaceCueSampleOffsets(sampleOffsets, in: url)
        return true
    }

    static func replaceCueSampleOffsets(
        _ sampleOffsets: [UInt32],
        labels: [String] = ["Loop Start", "Loop End"],
        in url: URL
    ) throws {
        guard sampleOffsets.count == 2,
              sampleOffsets[0] < sampleOffsets[1],
              labels.count == sampleOffsets.count
        else {
            throw AppError.unsupportedWAV(
                "Exactly two ordered sample offsets and marker labels are required."
            )
        }
        let data = try Data(contentsOf: url)
        let chunks = try riffChunks(in: data)
        var rewritten = Data(data.prefix(12))
        for chunk in chunks {
            let isCueChunk = chunk.identifier == "cue "
            let isAssociatedDataList = chunk.identifier == "LIST"
                && chunk.payload.starts(with: Data("adtl".utf8))
            if !isCueChunk && !isAssociatedDataList {
                rewritten.append(data[chunk.fullRange])
            }
        }

        var cuePayload = Data()
        cuePayload.appendLittleEndianUInt32(UInt32(sampleOffsets.count))
        for (index, sampleOffset) in sampleOffsets.enumerated() {
            cuePayload.appendLittleEndianUInt32(UInt32(index + 1))
            cuePayload.appendLittleEndianUInt32(sampleOffset)
            cuePayload.append(Data("data".utf8))
            cuePayload.appendLittleEndianUInt32(0)
            cuePayload.appendLittleEndianUInt32(0)
            cuePayload.appendLittleEndianUInt32(sampleOffset)
        }
        appendRIFFChunk(identifier: "cue ", payload: cuePayload, to: &rewritten)

        var associatedData = Data("adtl".utf8)
        for (index, label) in labels.enumerated() {
            var labelPayload = Data()
            labelPayload.appendLittleEndianUInt32(UInt32(index + 1))
            labelPayload.append(Data(label.utf8))
            labelPayload.append(0)
            appendRIFFChunk(
                identifier: "labl",
                payload: labelPayload,
                to: &associatedData
            )
        }
        appendRIFFChunk(
            identifier: "LIST",
            payload: associatedData,
            to: &rewritten
        )
        rewritten.writeLittleEndianUInt32(UInt32(rewritten.count - 8), at: 4)
        try rewritten.write(to: url, options: .atomic)
    }

    private static func appendRIFFChunk(
        identifier: String,
        payload: Data,
        to data: inout Data
    ) {
        precondition(identifier.utf8.count == 4)
        data.append(Data(identifier.utf8))
        data.appendLittleEndianUInt32(UInt32(payload.count))
        data.append(payload)
        if !payload.count.isMultiple(of: 2) { data.append(0) }
    }

    private struct RIFFChunk {
        let identifier: String
        let payload: Data
        let payloadRange: Range<Int>
        let fullRange: Range<Int>
    }

    private static func riffChunks(in data: Data) throws -> [RIFFChunk] {
        guard data.count >= 12,
              data[0..<4] == Data("RIFF".utf8)[...],
              data[8..<12] == Data("WAVE".utf8)[...]
        else {
            throw AppError.unsupportedWAV(
                "The file is not a standard RIFF/WAVE file."
            )
        }
        let declaredSize = Int(data.littleEndianUInt32(at: 4)) + 8
        let limit = min(data.count, declaredSize)
        guard limit >= 12 else {
            throw AppError.unsupportedWAV("The RIFF/WAVE header is truncated.")
        }

        var chunks: [RIFFChunk] = []
        var offset = 12
        while offset + 8 <= limit {
            let identifier = String(
                decoding: data[offset..<(offset + 4)],
                as: UTF8.self
            )
            let size = Int(data.littleEndianUInt32(at: offset + 4))
            let payloadStart = offset + 8
            guard size >= 0, payloadStart <= limit, size <= limit - payloadStart else {
                throw AppError.unsupportedWAV(
                    "The RIFF/WAVE file contains a truncated \(identifier) chunk."
                )
            }
            let nextOffset = payloadStart + size
                + (size.isMultiple(of: 2) ? 0 : 1)
            guard nextOffset <= limit else {
                throw AppError.unsupportedWAV(
                    "The RIFF/WAVE file contains a truncated \(identifier) chunk pad."
                )
            }
            chunks.append(
                RIFFChunk(
                    identifier: identifier,
                    payload: Data(data[payloadStart..<(payloadStart + size)]),
                    payloadRange: payloadStart..<(payloadStart + size),
                    fullRange: offset..<nextOffset
                )
            )
            offset = nextOffset
        }
        return chunks
    }
}

private extension Data {
    func littleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    mutating func writeLittleEndianUInt32(_ value: UInt32, at offset: Int) {
        self[offset] = UInt8(value & 0xFF)
        self[offset + 1] = UInt8((value >> 8) & 0xFF)
        self[offset + 2] = UInt8((value >> 16) & 0xFF)
        self[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    mutating func appendLittleEndianUInt32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
