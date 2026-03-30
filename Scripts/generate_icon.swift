#!/usr/bin/env swift

import AppKit

let size = CGSize(width: 1024, height: 1024)
let cornerRadius: CGFloat = 228 // macOS icon corner radius at 1024px

let image = NSImage(size: size, flipped: false) { rect in
    guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

    // Rounded rect clip path
    let clipPath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(clipPath)
    ctx.clip()

    // Dark background: #1C1C1E
    ctx.setFillColor(CGColor(red: 0x1C / 255.0, green: 0x1C / 255.0, blue: 0x1E / 255.0, alpha: 1.0))
    ctx.fill(rect)

    // Subtle border
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.08))
    ctx.setLineWidth(4)
    ctx.addPath(clipPath)
    ctx.strokePath()

    // Brain SF Symbol — render as white using palette configuration
    let symbolSize: CGFloat = 600
    let config = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .thin)
        .applying(.init(paletteColors: [.white]))

    guard let brainImage = NSImage(systemSymbolName: "brain", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else {
        fputs("Failed to create brain symbol\n", stderr)
        return false
    }

    let brainSize = brainImage.size
    let x = (rect.width - brainSize.width) / 2
    let y = (rect.height - brainSize.height) / 2
    let drawRect = NSRect(x: x, y: y, width: brainSize.width, height: brainSize.height)

    // Draw with isTemplate = false so palette color is respected
    let tinted = brainImage.copy() as! NSImage
    tinted.isTemplate = false
    tinted.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)

    return true
}

// Save as PNG
guard let tiffData = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData),
      let pngData = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Failed to create PNG data\n", stderr)
    exit(1)
}

let outputPath = "Scripts/AppIcon-1024.png"
let url = URL(fileURLWithPath: outputPath)
do {
    try pngData.write(to: url)
    print("Icon saved to \(outputPath)")
} catch {
    fputs("Failed to write PNG: \(error)\n", stderr)
    exit(1)
}
