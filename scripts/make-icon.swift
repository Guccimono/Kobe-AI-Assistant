// Renders Resources/AppIcon.icns. Preferred source: Resources/AppIcon-composed.png, the Icon Composer export
// (already shaped, shaded and shadowed, with its transparent margin: drawn as-is). Fallback: Resources/AppIcon.svg
// (the flat mark), clipped to the macOS icon body (80 % of the canvas, rounded corners).
// Usage: swift scripts/make-icon.swift   (writes Resources/AppIcon.icns via iconutil)
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let composed = root.appendingPathComponent("Resources/AppIcon-composed.png")
let svg = root.appendingPathComponent("Resources/AppIcon.svg")
let useComposed = FileManager.default.fileExists(atPath: composed.path)
guard let art = NSImage(contentsOf: useComposed ? composed : svg) else { fatalError("missing \(svg.path)") }

func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size)
    // macOS icon grid: the body is ~80% of the canvas, corner radius ~22.5% of the body.
    let body = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    if !useComposed { NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225).addClip() }
    art.draw(in: useComposed ? NSRect(x: 0, y: 0, width: s, height: s) : body, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "wrote \(out.path)" : "iconutil failed")
