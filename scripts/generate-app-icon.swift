import AppKit
import Foundation

@main
enum GenerateAppIcon {
    static func main() throws {
        guard (2...4).contains(CommandLine.arguments.count) else {
            throw GeneratorError.missingOutputPath
        }

        let representations: [(type: String, dimension: CGFloat)] = [
            ("icp4", 16),
            ("icp5", 32),
            ("ic11", 32),
            ("ic12", 64),
            ("ic07", 128),
            ("ic08", 256),
            ("ic13", 256),
            ("ic09", 512),
            ("ic14", 512),
            ("ic10", 1024)
        ]

        var payload = Data()
        for representation in representations {
            let png = try renderPNG(dimension: representation.dimension)
            payload.append(contentsOf: representation.type.utf8)
            payload.appendBigEndian(UInt32(png.count + 8))
            payload.append(png)
        }

        var icns = Data("icns".utf8)
        icns.appendBigEndian(UInt32(payload.count + 8))
        icns.append(payload)
        try icns.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

        if CommandLine.arguments.count == 3 {
            let preview = try renderPNG(dimension: 1024)
            try preview.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        } else if CommandLine.arguments.count == 4 {
            let preview = try renderPNG(dimension: 1024)
            try preview.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
            let statusItemPreview = try renderPNG(image: makeStatusItemPreview())
            try statusItemPreview.write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
        }
    }

    private static func renderPNG(dimension: CGFloat) throws -> Data {
        try renderPNG(image: JoyApplicationIcon.build(dimension: dimension))
    }

    private static func renderPNG(image: NSImage) throws -> Data {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw GeneratorError.renderFailed
        }
        return png
    }

    private static func makeStatusItemPreview() -> NSImage {
        let size = NSSize(width: 256, height: 256)
        let preview = NSImage(size: size)
        preview.lockFocus()
        NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        JoyApplicationIcon.makeStatusItemIcon(dimension: 256).draw(
            in: NSRect(origin: .zero, size: size)
        )
        preview.unlockFocus()
        return preview
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        var bigEndianValue = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndianValue) { bytes in
            append(contentsOf: bytes)
        }
    }
}

private enum GeneratorError: Error {
    case missingOutputPath
    case renderFailed
}
