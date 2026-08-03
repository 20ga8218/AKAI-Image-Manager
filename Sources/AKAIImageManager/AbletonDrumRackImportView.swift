import SwiftUI

struct AbletonDrumRackImportSheet: View {
    @State private var draft: AbletonDrumRackImportDraft
    let onImport: (AbletonDrumRackImportDraft) -> Void
    @Environment(\.dismiss) private var dismiss

    init(
        draft: AbletonDrumRackImportDraft,
        onImport: @escaping (AbletonDrumRackImportDraft) -> Void
    ) {
        _draft = State(initialValue: draft)
        self.onImport = onImport
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import Ableton Drum Rack")
                        .font(.title2.weight(.semibold))
                    Text(
                        "\(draft.sourceURL.lastPathComponent) — "
                            + "\(draft.rows.count) occupied pad"
                            + "\(draft.rows.count == 1 ? "" : "s")"
                    )
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }

            GroupBox("S950 mapping") {
                HStack(spacing: 18) {
                    noteControl("Start note", value: $draft.startNote)
                    noteControl("Sample root", value: $draft.rootNote)
                    Picker("MIDI channel", selection: $draft.midiChannel) {
                        ForEach(1...16, id: \.self) { channel in
                            Text("\(channel)").tag(channel)
                        }
                    }
                    .frame(width: 145)
                    Picker("Output", selection: $draft.output) {
                        ForEach(P9Output.standardChoices) { output in
                            Text(output.displayName).tag(output)
                        }
                    }
                    .frame(width: 190)
                    Toggle("Compressed S9", isOn: $draft.compressedSamples)
                        .help("Use AKAI Util’s S950 compressed-sample conversion")
                }
                .padding(8)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Sample names")
                    .font(.headline)
                Text(
                    "Edit every S950 name before import. Names are uppercase, "
                        + "limited to 10 AKAI-compatible characters and must be unique."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            sampleHeader
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach($draft.rows) { $row in
                        sampleRow($row)
                        Divider()
                    }
                }
            }
            .frame(minHeight: 210, maxHeight: 340)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )

            if let error = draft.validationError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label(mappingSummary, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }

            HStack {
                Text(
                    "The WAV files are converted to S9 samples now; the appended "
                        + "keygroups remain in memory until you save or overwrite the P9."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import Samples and Append Keygroups") {
                    let finalized = normalizedDraft
                    dismiss()
                    onImport(finalized)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(draft.validationError != nil)
            }
        }
        .controlSize(.small)
        .padding(20)
        .frame(width: 980, height: 650)
    }

    private var sampleHeader: some View {
        HStack(spacing: 10) {
            Text("Pad")
                .frame(width: 78, alignment: .leading)
            Text("S950 key")
                .frame(width: 88, alignment: .leading)
            Text("Source WAV")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("S950 sample name")
                .frame(width: 170, alignment: .leading)
            Text("Tuning")
                .frame(width: 100, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
    }

    private func sampleRow(
        _ row: Binding<AbletonDrumRackImportRow>
    ) -> some View {
        let value = row.wrappedValue
        let target = draft.targetNote(for: value)
        let transpose = rootTranspose(for: value)
        return HStack(spacing: 10) {
            Text(
                "\(P9Keygroup.noteName(value.source.sourceNote)) "
                    + "(\(value.source.sourceNote))"
            )
            .frame(width: 78, alignment: .leading)
            .monospacedDigit()
            Text("\(P9Keygroup.noteName(target)) (\(target))")
                .frame(width: 88, alignment: .leading)
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 1) {
                Text(value.source.sampleURL.lastPathComponent)
                    .lineLimit(1)
                Text(value.source.sampleURL.deletingLastPathComponent().path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TextField(
                "Sample name",
                text: Binding(
                    get: { row.wrappedValue.sampleName },
                    set: { row.wrappedValue.sampleName = cleanedName($0) }
                )
            )
            .monospaced()
            .textFieldStyle(.roundedBorder)
            .frame(width: 170)
            Text(tuningText(transpose: transpose, cents: value.source.detuneCents))
                .frame(width: 100, alignment: .leading)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func noteControl(
        _ title: String,
        value: Binding<Int>
    ) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(P9Keygroup.noteName(value.wrappedValue))
                    .monospacedDigit()
            }
            TextField(
                "",
                value: value,
                format: .number
            )
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: 44)
            Stepper("", value: value, in: 0...127)
                .labelsHidden()
        }
    }

    private var normalizedDraft: AbletonDrumRackImportDraft {
        var value = draft
        for index in value.rows.indices {
            value.rows[index].sampleName = value.cleanedSampleName(
                value.rows[index].sampleName
            )
        }
        return value
    }

    private func cleanedName(_ value: String) -> String {
        draft.editableSampleName(value)
    }

    private func rootTranspose(for row: AbletonDrumRackImportRow) -> Int {
        draft.rootNote - draft.targetNote(for: row)
    }

    private func tuningText(transpose: Int, cents: Int) -> String {
        let fine = Int((Double(cents) * 16.0 / 100.0).rounded())
        let tuning = P9Tuning(transpose: transpose, fine: fine)
        let coarse = tuning.transpose > 0
            ? "+\(tuning.transpose)"
            : "\(tuning.transpose)"
        let fineText = tuning.fine > 0 ? "+\(tuning.fine)" : "\(tuning.fine)"
        return "\(coarse) / \(fineText)"
    }

    private var mappingSummary: String {
        guard let first = draft.rows.first, let last = draft.rows.last else {
            return "No occupied pads found."
        }
        let firstTarget = draft.targetNote(for: first)
        let lastTarget = draft.targetNote(for: last)
        return "\(draft.rows.count) keygroups will be "
            + (draft.replacesBlankKeygroup ? "created" : "appended")
            + " from "
            + "\(P9Keygroup.noteName(firstTarget)) to "
            + "\(P9Keygroup.noteName(lastTarget)); source pad gaps are preserved."
    }
}
