import Foundation

struct AbletonSamplerExportPad: Equatable {
    let keygroupIndex: Int
    let receivingNote: Int
    let sampleName: String
    let wavURL: URL
    let sampleFrames: Int64
    let sampleRate: Double
    let rootNote: Int
    let detuneCents: Int
    let s950Filter: Int
    let s950VelocityLoudness: Int
    let s950VelocityFilter: Int
}

struct AbletonDrumRackExportResult: Equatable {
    let packageURL: URL
    let adgURL: URL
    let sampleURLs: [URL]
    let warnings: [String]
}

enum AbletonDrumRackExportError: LocalizedError, Equatable {
    case missingTemplate
    case invalidTemplate(String)
    case invalidPad(String)
    case gzipFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingTemplate:
            return "The bundled Ableton Live 12.4.3 Sampler template is missing."
        case .invalidTemplate(let detail):
            return "The Ableton Sampler template is invalid: \(detail)"
        case .invalidPad(let detail):
            return "The S950 keygroup cannot be exported to Ableton: \(detail)"
        case .gzipFailed(let detail):
            return "The Ableton ADG could not be compressed: \(detail)"
        }
    }
}

enum AbletonDrumRackExporter {
    static let templateName = "AKAI-S950-Sampler-Template"

    static var bundledTemplateURL: URL? {
#if SWIFT_PACKAGE
        Bundle.module.url(forResource: templateName, withExtension: "adg")
#else
        Bundle.main.url(forResource: templateName, withExtension: "adg")
#endif
    }

    static func generate(
        templateURL: URL,
        rackName: String,
        pads: [AbletonSamplerExportPad]
    ) throws -> Data {
        guard !pads.isEmpty else {
            throw AbletonDrumRackExportError.invalidPad(
                "the program has no Soft samples to place on pads."
            )
        }
        var seenNotes = Set<Int>()
        for pad in pads {
            guard (0...127).contains(pad.receivingNote) else {
                throw AbletonDrumRackExportError.invalidPad(
                    "keygroup \(pad.keygroupIndex + 1) uses MIDI note \(pad.receivingNote)."
                )
            }
            guard seenNotes.insert(pad.receivingNote).inserted else {
                throw AbletonDrumRackExportError.invalidPad(
                    "more than one keygroup starts on \(P9Keygroup.noteName(pad.receivingNote))."
                )
            }
            guard (0...127).contains(pad.rootNote) else {
                throw AbletonDrumRackExportError.invalidPad(
                    "keygroup \(pad.keygroupIndex + 1) requires root note \(pad.rootNote), outside 0–127."
                )
            }
            guard pad.sampleFrames > 0,
                  pad.sampleRate.isFinite,
                  pad.sampleRate > 0
            else {
                throw AbletonDrumRackExportError.invalidPad(
                    "\(pad.sampleName) has invalid WAV duration or sample rate."
                )
            }
        }

        let templateXML = try decompressedADG(at: templateURL)
        let document: XMLDocument
        do {
            document = try XMLDocument(data: templateXML)
        } catch {
            throw AbletonDrumRackExportError.invalidTemplate(
                error.localizedDescription
            )
        }
        guard let branchContainer = try elements(
            in: document,
            xpath: "/Ableton/GroupDevicePreset/BranchPresets"
        ).first else {
            throw AbletonDrumRackExportError.invalidTemplate(
                "BranchPresets is missing."
            )
        }
        let templateBranches = try elements(
            in: branchContainer,
            xpath: "DrumBranchPreset"
        )
        guard templateBranches.count == 1 else {
            throw AbletonDrumRackExportError.invalidTemplate(
                "exactly one DrumBranchPreset is required."
            )
        }
        let templateBranch = templateBranches[0]
        while branchContainer.childCount > 0 {
            branchContainer.removeChild(at: 0)
        }

        if let userName = try elements(
            in: document,
            xpath: "/Ableton/GroupDevicePreset/Device/DrumGroupDevice/UserName"
        ).first {
            setValue(rackName, on: userName)
        }

        for (branchIndex, pad) in pads.enumerated() {
            guard let branch = templateBranch.copy() as? XMLElement else {
                throw AbletonDrumRackExportError.invalidTemplate(
                    "the pad branch could not be cloned."
                )
            }
            branch.attribute(forName: "Id")?.stringValue = String(branchIndex)
            try configure(branch: branch, for: pad)
            branchContainer.addChild(branch)
        }

        let generatedBranches = try elements(
            in: document,
            xpath: "/Ableton/GroupDevicePreset/BranchPresets/DrumBranchPreset"
        )
        guard generatedBranches.count == pads.count else {
            throw AbletonDrumRackExportError.invalidTemplate(
                "the generated branch count is incorrect."
            )
        }
        return try compressedADG(document.xmlData(options: []))
    }

    static func decompressedADG(_ data: Data) throws -> Data {
        try gzip(arguments: ["-dc"], input: data)
    }

    static func filterFrequency(forS950Value value: Int) -> Double {
        let clamped = min(99, max(0, value))
        let minimum = 30.0
        let maximum = 22_000.0
        return minimum * pow(maximum / minimum, Double(clamped) / 99.0)
    }

    private static func configure(
        branch: XMLElement,
        for pad: AbletonSamplerExportPad
    ) throws {
        try setValue(pad.sampleName, in: branch, xpath: "Name")
        try setValue(
            pad.sampleName,
            in: branch,
            xpath: ".//MultiSampler/UserName"
        )
        let parts = try elements(in: branch, xpath: ".//MultiSamplePart")
        guard parts.count == 1 else {
            throw AbletonDrumRackExportError.invalidTemplate(
                "each Sampler branch must contain one MultiSamplePart."
            )
        }
        let part = parts[0]
        part.attribute(forName: "Id")?.stringValue = "0"
        try setValue(pad.sampleName, in: part, xpath: "Name")
        try setValue(pad.rootNote, in: part, xpath: "RootKey")
        try setValue(pad.detuneCents, in: part, xpath: "Detune")

        let lastFrame = max(0, pad.sampleFrames - 1)
        try setValue(0, in: part, xpath: "SampleStart")
        try setValue(lastFrame, in: part, xpath: "SampleEnd")
        try setValue(0, in: part, xpath: "SustainLoop/Start")
        try setValue(lastFrame, in: part, xpath: "SustainLoop/End")
        try setValue(0, in: part, xpath: "ReleaseLoop/Start")
        try setValue(lastFrame, in: part, xpath: "ReleaseLoop/End")

        let relativePath = "Samples/\(pad.wavURL.lastPathComponent)"
        let fileValues = try? pad.wavURL.resourceValues(
            forKeys: [.fileSizeKey]
        )
        let size = fileValues?.fileSize ?? 0
        let dateValues = try? pad.wavURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        )
        let modified = dateValues?.contentModificationDate ?? Date()
        let fileRefs = try elements(in: part, xpath: ".//SampleRef//FileRef")
        guard !fileRefs.isEmpty else {
            throw AbletonDrumRackExportError.invalidTemplate(
                "the sample FileRef is missing."
            )
        }
        for fileRef in fileRefs {
            // Live uses type 1 for paths relative to the ADG. Keeping the WAVs
            // in a sibling Samples folder makes the whole export movable.
            try setValue(1, in: fileRef, xpath: "RelativePathType")
            try setValue(relativePath, in: fileRef, xpath: "RelativePath")
            try setValue(pad.wavURL.path, in: fileRef, xpath: "Path")
            try setValue(size, in: fileRef, xpath: "OriginalFileSize")
            try setValue(0, in: fileRef, xpath: "OriginalCrc")
            try setValue("", in: fileRef, xpath: "SourceHint")
        }
        try setValue(
            Int(modified.timeIntervalSince1970),
            in: part,
            xpath: ".//SampleRef/LastModDate"
        )
        try setValue(
            pad.sampleFrames,
            in: part,
            xpath: ".//SampleRef/DefaultDuration"
        )
        try setValue(
            numberString(pad.sampleRate),
            in: part,
            xpath: ".//SampleRef/DefaultSampleRate"
        )
        for browserPath in try elements(
            in: part,
            xpath: ".//SampleRef//BrowserContentPath"
        ) {
            setValue("", on: browserPath)
        }

        let filterEnabled = pad.s950Filter < 99
            || pad.s950VelocityFilter > 0
        try setValue(
            filterEnabled ? "true" : "false",
            in: branch,
            xpath: ".//MultiSampler/Filter/IsOn/Manual"
        )
        try setValue(
            numberString(filterFrequency(forS950Value: pad.s950Filter)),
            in: branch,
            xpath: ".//MultiSampler/Filter//SimplerFilter/Freq/Manual"
        )
        try setValue(
            sensitivity(pad.s950VelocityFilter),
            in: branch,
            xpath: ".//MultiSampler/Filter//SimplerFilter/ModByVelocity/Manual"
        )
        try setValue(
            sensitivity(pad.s950VelocityLoudness),
            in: branch,
            xpath: ".//MultiSampler/VolumeAndPan/VolumeVelScale/Manual"
        )
        try setValue(
            AbletonDrumRackNote.receivingValue(
                forMIDINote: pad.receivingNote
            ),
            in: branch,
            xpath: "ZoneSettings/ReceivingNote"
        )
        try setValue(60, in: branch, xpath: "ZoneSettings/SendingNote")
        try setValue(0, in: branch, xpath: "ZoneSettings/ChokeGroup")
    }

    private static func sensitivity(_ value: Int) -> String {
        numberString(Double(min(99, max(0, value))) / 99.0)
    }

    private static func numberString(_ value: Double) -> String {
        String(format: "%.10g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func setValue<T>(
        _ value: T,
        in node: XMLNode,
        xpath: String
    ) throws {
        let matches = try elements(in: node, xpath: xpath)
        guard matches.count == 1 else {
            throw AbletonDrumRackExportError.invalidTemplate(
                "\(xpath) matched \(matches.count) nodes instead of one."
            )
        }
        setValue(String(describing: value), on: matches[0])
    }

    private static func setValue(_ value: String, on element: XMLElement) {
        guard let attribute = element.attribute(forName: "Value") else {
            element.addAttribute(XMLNode.attribute(withName: "Value", stringValue: value) as! XMLNode)
            return
        }
        attribute.stringValue = value
    }

    private static func elements(
        in node: XMLNode,
        xpath: String
    ) throws -> [XMLElement] {
        try node.nodes(forXPath: xpath).compactMap { $0 as? XMLElement }
    }

    private static func decompressedADG(at url: URL) throws -> Data {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AbletonDrumRackExportError.invalidTemplate(
                error.localizedDescription
            )
        }
        return try decompressedADG(data)
    }

    private static func compressedADG(_ xml: Data) throws -> Data {
        try gzip(arguments: ["-cn"], input: xml)
    }

    private static func gzip(arguments: [String], input: Data) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = arguments
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw AbletonDrumRackExportError.gzipFailed(
                error.localizedDescription
            )
        }
        inputPipe.fileHandleForWriting.write(input)
        try? inputPipe.fileHandleForWriting.close()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !output.isEmpty else {
            let detail = String(decoding: error, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AbletonDrumRackExportError.gzipFailed(
                detail.isEmpty ? "gzip exited with status \(process.terminationStatus)." : detail
            )
        }
        return output
    }
}
