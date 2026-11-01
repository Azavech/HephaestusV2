// Draws the app icon and writes it as an .icns file (docs/ci.md › App icon):
//
//   swift scripts/make-icon.swift <output.icns>
//
// A square with rounded corners (radius 22.5 % of the side) filled with a vertical gradient from
// #FF9F0A at the top to #FF3B30 at the bottom, with the SF Symbol `hammer.fill` in white, centred,
// 55 % of the side high; rendered at 16, 32, 128, 256 and 512 points, at 1x and 2x, into a temporary
// AppIcon.iconset, then converted with `iconutil -c icns`.
import AppKit
import Foundation

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("make-icon.swift: \(message)\n".utf8))
    exit(status)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 1 else {
    FileHandle.standardError.write(Data("usage: swift scripts/make-icon.swift <output.icns>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: arguments[0])

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// The icon at `pixels` × `pixels`, as PNG data.
func render(pixels: Int) -> Data {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("cannot create a \(pixels) px bitmap") }
    let side = CGFloat(pixels)
    let square = CGRect(x: 0, y: 0, width: side, height: side)

    // The rounded square and its gradient, #FF9F0A at the top (y = side) to #FF3B30 at the bottom.
    let radius = side * 0.225
    context.addPath(CGPath(roundedRect: square, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.clip()
    guard let gradient = CGGradient(colorsSpace: space, colors: [color(0xFF9F0A), color(0xFF3B30)] as CFArray,
                                    locations: [0, 1])
    else { fail("cannot create the gradient") }
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: side), end: CGPoint(x: 0, y: 0), options: [])

    // The symbol, white, centred, 55 % of the side high.
    let height = side * 0.55
    let configuration = NSImage.SymbolConfiguration(pointSize: height, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    guard let symbol = NSImage(systemSymbolName: "hammer.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration), symbol.size.height > 0
    else { fail("the SF Symbol hammer.fill is not available") }
    let width = symbol.size.width * height / symbol.size.height
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    symbol.draw(in: NSRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()

    guard let image = context.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { fail("cannot encode the \(pixels) px image") }
    return png
}

let manager = FileManager.default
let temporary = manager.temporaryDirectory.appendingPathComponent("make-icon-\(UUID().uuidString)", isDirectory: true)
let iconset = temporary.appendingPathComponent("AppIcon.iconset", isDirectory: true)
do {
    try manager.createDirectory(at: iconset, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        try render(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
        try render(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
    }
} catch {
    fail("writing the iconset failed: \(error.localizedDescription)")
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
do {
    try iconutil.run()
} catch {
    fail("iconutil could not start: \(error.localizedDescription)")
}
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    try? manager.removeItem(at: temporary)
    fail("iconutil failed with status \(iconutil.terminationStatus)")
}
try? manager.removeItem(at: temporary)
print(output.path)
