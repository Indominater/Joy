import AppKit

enum JoyApplicationIcon {
    private static let sharedImage = build(dimension: 512)

    static func make() -> NSImage {
        sharedImage
    }

    static func makeStatusItemIcon(dimension: CGFloat = 20) -> NSImage {
        let image = NSImage(
            size: NSSize(width: dimension, height: dimension),
            flipped: false
        ) { rect in
            let baseCanvas = NSSize(width: 512, height: 512)
            let baseFontSize: CGFloat = 252
            let mark = "J" as NSString
            let baseFont = roundedFont(ofSize: baseFontSize)
            let baseAttributes: [NSAttributedString.Key: Any] = [.font: baseFont]
            let baseMarkSize = mark.size(withAttributes: baseAttributes)
            let baseMarkRect = NSRect(
                x: (baseCanvas.width - baseMarkSize.width) / 2 - 4,
                y: (baseCanvas.height - baseMarkSize.height) / 2 + 8,
                width: baseMarkSize.width,
                height: baseMarkSize.height
            )
            let baseDotRect = NSRect(x: 358, y: 352, width: 34, height: 34)
            let baseGroupRect = baseMarkRect.union(baseDotRect)
            let inset = dimension / 18
            let scale = min(
                (rect.width - 2 * inset) / baseGroupRect.width,
                (rect.height - 2 * inset) / baseGroupRect.height
            )
            let groupOrigin = NSPoint(
                x: rect.midX - baseGroupRect.width * scale / 2,
                y: rect.midY - baseGroupRect.height * scale / 2
            )
            let markOrigin = NSPoint(
                x: groupOrigin.x + (baseMarkRect.minX - baseGroupRect.minX) * scale,
                y: groupOrigin.y + (baseMarkRect.minY - baseGroupRect.minY) * scale
            )
            let attributes: [NSAttributedString.Key: Any] = [
                .font: roundedFont(ofSize: baseFontSize * scale),
                .foregroundColor: NSColor.black
            ]
            mark.draw(at: markOrigin, withAttributes: attributes)

            let dotRect = NSRect(
                x: groupOrigin.x + (baseDotRect.minX - baseGroupRect.minX) * scale,
                y: groupOrigin.y + (baseDotRect.minY - baseGroupRect.minY) * scale,
                width: baseDotRect.width * scale,
                height: baseDotRect.height * scale
            )
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    static func build(dimension: CGFloat) -> NSImage {
        let scale = dimension / 512
        let canvas = NSSize(width: dimension, height: dimension)
        let image = NSImage(size: canvas)
        image.lockFocus()

        NSGraphicsContext.current?.imageInterpolation = .high

        let tileRect = NSRect(
            x: 30 * scale,
            y: 30 * scale,
            width: 452 * scale,
            height: 452 * scale
        )
        let tile = NSBezierPath(
            roundedRect: tileRect,
            xRadius: 112 * scale,
            yRadius: 112 * scale
        )
        let gradient = NSGradient(colors: [
            NSColor(red: 0.035, green: 0.105, blue: 0.27, alpha: 1),
            NSColor(red: 0.16, green: 0.105, blue: 0.48, alpha: 1)
        ])
        gradient?.draw(in: tile, angle: -42)

        NSColor.white.withAlphaComponent(0.13).setStroke()
        tile.lineWidth = 4 * scale
        tile.stroke()

        let fontSize = 252 * scale
        let font = roundedFont(ofSize: fontSize)
        let mark = "J" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.94)
        ]
        let markSize = mark.size(withAttributes: attributes)
        mark.draw(
            at: NSPoint(
                x: (canvas.width - markSize.width) / 2 - 4 * scale,
                y: (canvas.height - markSize.height) / 2 + 8 * scale
            ),
            withAttributes: attributes
        )

        let accent = NSBezierPath(
            ovalIn: NSRect(
                x: 358 * scale,
                y: 352 * scale,
                width: 34 * scale,
                height: 34 * scale
            )
        )
        NSColor(red: 0.48, green: 0.88, blue: 0.72, alpha: 1).setFill()
        accent.fill()

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func roundedFont(ofSize size: CGFloat) -> NSFont {
        let baseFont = NSFont.systemFont(ofSize: size, weight: .semibold)
        let descriptor = baseFont.fontDescriptor.withDesign(.rounded) ?? baseFont.fontDescriptor
        return NSFont(descriptor: descriptor, size: size) ?? baseFont
    }
}
