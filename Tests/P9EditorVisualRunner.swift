import AppKit
import SwiftUI

@main
@MainActor
struct P9EditorVisualRunner {
    static func main() {
        guard (3...4).contains(CommandLine.arguments.count) else {
            fputs("usage: P9EditorVisualRunner <program.p9> <screenshot.png> [--all|--spread|--overwrite]\n", stderr)
            exit(2)
        }
        let programURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let screenshotURL = URL(fileURLWithPath: CommandLine.arguments[2])

        do {
            let sourceData = try Data(contentsOf: programURL)
            let mode = CommandLine.arguments.count == 4 ? CommandLine.arguments[3] : ""
            let document = try P9EditorDocument(
                data: sourceData,
                source: mode == "--overwrite"
                    ? .image(
                        filename: programURL.lastPathComponent,
                        imageURL: URL(fileURLWithPath: "/tmp/VISUAL.img")
                    )
                    : .local(programURL)
            )
            guard try document.program.encoded() == sourceData, !document.hasChanges else {
                throw P9EditorVisualFailure.roundTrip
            }
            if mode == "--overwrite", !document.program.keygroups.isEmpty {
                var program = document.program
                program.keygroups[0].softLoudness += 1
                document.program = program
            }
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
            NSApplication.shared.finishLaunching()
            let contentSize: NSSize
            let root: AnyView
            if mode == "--spread" {
                contentSize = NSSize(width: 1240, height: 800)
                root = AnyView(
                    P9EditorSheet(
                        document: document,
                        initialSelection: Set(document.program.keygroups.indices),
                        showSpreadInitially: true
                    )
                    .frame(width: contentSize.width, height: contentSize.height)
                )
            } else {
                contentSize = NSSize(width: 1240, height: 800)
                let initialSelection = mode == "--all"
                    ? Set(document.program.keygroups.indices)
                    : nil
                root = AnyView(
                    P9EditorSheet(
                        document: document,
                        initialSelection: initialSelection,
                        showOverwriteConfirmationInitially: mode == "--overwrite",
                        onOverwriteP9: mode == "--overwrite" ? { _, _ in } : nil
                    )
                        .frame(width: contentSize.width, height: contentSize.height)
                )
            }
            let hostingView = NSHostingView(rootView: root)
            let window = NSWindow(
                contentRect: NSRect(
                    x: 0,
                    y: 0,
                    width: contentSize.width,
                    height: contentSize.height
                ),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.appearance = NSAppearance(named: .darkAqua)
            window.title = "P9 Keygroup Editor — Visual Smoke Test"
            window.contentView = hostingView
            window.makeKeyAndOrderFront(nil)
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            hostingView.layoutSubtreeIfNeeded()
            window.attachedSheet?.appearance = NSAppearance(named: .darkAqua)
            window.attachedSheet?.contentView?.appearance = NSAppearance(named: .darkAqua)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

            let captureWindow = mode == "--spread" || mode == "--overwrite"
                ? window.attachedSheet ?? window
                : window
            guard let capturedImage = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                CGWindowID(captureWindow.windowNumber),
                [.boundsIgnoreFraming]
            ) else {
                throw P9EditorVisualFailure.capture
            }
            let bitmap = NSBitmapImageRep(cgImage: capturedImage)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw P9EditorVisualFailure.capture
            }
            try data.write(to: screenshotURL)
            print("P9 editor smoke screenshot: \(screenshotURL.path)")
            window.orderOut(nil)
        } catch {
            fputs("P9 editor visual smoke test failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

private enum P9EditorVisualFailure: Error {
    case capture
    case roundTrip
}
