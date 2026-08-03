import AppKit
import Foundation

@main
struct GenerateIcon {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            fputs("usage: GenerateIcon <output.iconset> <output.icns>\n", stderr)
            exit(2)
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let icnsURL = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let variants: [(String, Int)] = [
            ("icon_16x16.png", 16),
            ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32),
            ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128),
            ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256),
            ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512),
            ("icon_512x512@2x.png", 1024)
        ]
        for (name, size) in variants {
            try render(size: size, to: directory.appendingPathComponent(name))
        }
        try writeICNS(from: directory, to: icnsURL)
    }

    private static func render(size: Int, to url: URL) throws {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { throw IconError.bitmap }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let canvas = NSRect(x: 0, y: 0, width: size, height: size)
        NSColor.clear.setFill()
        canvas.fill()

        let inset = CGFloat(size) * 0.055
        let body = NSBezierPath(
            roundedRect: canvas.insetBy(dx: inset, dy: inset),
            xRadius: CGFloat(size) * 0.22,
            yRadius: CGFloat(size) * 0.22
        )
        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.98, green: 0.20, blue: 0.18, alpha: 1),
            NSColor(calibratedRed: 0.57, green: 0.035, blue: 0.045, alpha: 1)
        ])
        gradient?.draw(in: body, angle: -68)

        NSColor.white.withAlphaComponent(0.16).setStroke()
        body.lineWidth = max(1, CGFloat(size) * 0.012)
        body.stroke()

        let panel = NSBezierPath(
            roundedRect: NSRect(
                x: CGFloat(size) * 0.18,
                y: CGFloat(size) * 0.20,
                width: CGFloat(size) * 0.64,
                height: CGFloat(size) * 0.60
            ),
            xRadius: CGFloat(size) * 0.07,
            yRadius: CGFloat(size) * 0.07
        )
        NSColor(calibratedWhite: 0.08, alpha: 0.93).setFill()
        panel.fill()

        let label = NSBezierPath(
            roundedRect: NSRect(
                x: CGFloat(size) * 0.28,
                y: CGFloat(size) * 0.60,
                width: CGFloat(size) * 0.44,
                height: CGFloat(size) * 0.13
            ),
            xRadius: CGFloat(size) * 0.025,
            yRadius: CGFloat(size) * 0.025
        )
        NSColor(calibratedWhite: 0.92, alpha: 1).setFill()
        label.fill()

        let slot = NSBezierPath(
            roundedRect: NSRect(
                x: CGFloat(size) * 0.32,
                y: CGFloat(size) * 0.27,
                width: CGFloat(size) * 0.36,
                height: CGFloat(size) * 0.13
            ),
            xRadius: CGFloat(size) * 0.025,
            yRadius: CGFloat(size) * 0.025
        )
        NSColor(calibratedWhite: 0.78, alpha: 1).setFill()
        slot.fill()

        let waveform = NSBezierPath()
        let midY = CGFloat(size) * 0.535
        let points: [(CGFloat, CGFloat)] = [
            (0.25, 0), (0.31, 0), (0.35, 0.055), (0.39, -0.10),
            (0.44, 0.14), (0.49, -0.18), (0.54, 0.12), (0.59, -0.07),
            (0.64, 0.035), (0.69, 0), (0.75, 0)
        ]
        for (index, point) in points.enumerated() {
            let position = NSPoint(x: CGFloat(size) * point.0, y: midY + CGFloat(size) * point.1)
            if index == 0 { waveform.move(to: position) } else { waveform.line(to: position) }
        }
        NSColor(calibratedRed: 1, green: 0.28, blue: 0.24, alpha: 1).setStroke()
        waveform.lineWidth = max(1.4, CGFloat(size) * 0.025)
        waveform.lineCapStyle = .round
        waveform.lineJoinStyle = .round
        waveform.stroke()

        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw IconError.png
        }
        try data.write(to: url)
    }

    private static func writeICNS(from directory: URL, to destination: URL) throws {
        let entries: [(String, String)] = [
            ("icp4", "icon_16x16.png"),
            ("icp5", "icon_32x32.png"),
            ("icp6", "icon_32x32@2x.png"),
            ("ic07", "icon_128x128.png"),
            ("ic08", "icon_256x256.png"),
            ("ic09", "icon_512x512.png"),
            ("ic10", "icon_512x512@2x.png")
        ]
        var elements = Data()
        for (type, filename) in entries {
            let png = try Data(contentsOf: directory.appendingPathComponent(filename))
            elements.append(contentsOf: type.utf8)
            appendBigEndian(UInt32(png.count + 8), to: &elements)
            elements.append(png)
        }
        var result = Data("icns".utf8)
        appendBigEndian(UInt32(elements.count + 8), to: &result)
        result.append(elements)
        try result.write(to: destination)
    }

    private static func appendBigEndian(_ value: UInt32, to data: inout Data) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }
}

enum IconError: Error {
    case bitmap
    case png
}
