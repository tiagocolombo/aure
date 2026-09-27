// The approved SVG is the only artwork source. AppKit rasterizes it offline.
import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fm = FileManager.default
let source = root.appendingPathComponent("docs/assets/aure-logo.svg")
let resources = root.appendingPathComponent("Packages/AureKit/Sources/AureUI/Resources")
let iconset = root.appendingPathComponent("build/branding/AppIcon.iconset")
try fm.createDirectory(at: resources, withIntermediateDirectories: true)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
guard let logo = NSImage(contentsOf: source) else { fatalError("Cannot load \(source.path)") }

func render(_ image: NSImage, pixels: Int, inset: CGFloat = 0, to url: URL) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Cannot allocate \(pixels)px bitmap")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
    NSColor.clear.setFill()
    rect.fill(using: .copy)
    image.draw(in: rect.insetBy(dx: inset, dy: inset), from: .zero,
               operation: .sourceOver, fraction: 1)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Cannot encode \(url.lastPathComponent)")
    }
    try data.write(to: url, options: .atomic)
}

try render(logo, pixels: 1024, to: resources.appendingPathComponent("AureLogo.png"))

// Reuse the exact A/check paths, without the tile or gradients, for a template icon.
// The cropped viewBox gives the strokes breathing room at 22pt in the menu bar.
let document = try XMLDocument(contentsOf: source)
guard let svg = document.rootElement() else { fatalError("Missing SVG root") }
let mark = XMLElement(name: "svg")
mark.addNamespace(XMLNode.namespace(withName: "", stringValue: "http://www.w3.org/2000/svg") as! XMLNode)
for (key, value) in [("width", "44"), ("height", "44"), ("viewBox", "48 48 160 160")] {
    mark.addAttribute(XMLNode.attribute(withName: key, stringValue: value) as! XMLNode)
}
let paths = svg.elements(forName: "path")
guard !paths.isEmpty else { fatalError("SVG must expose its mark as top-level paths") }
for original in paths {
    let path = original.copy() as! XMLElement
    path.attribute(forName: "stroke")?.stringValue = "#000000"
    mark.addChild(path)
}
guard let menu = NSImage(data: XMLDocument(rootElement: mark).xmlData) else {
    fatalError("Cannot render menu-bar mark")
}
try render(menu, pixels: 44, to: resources.appendingPathComponent("AureMenuBar.png"))

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let suffix = scale == 2 ? "@2x" : ""
        // macOS app icons sit inside a transparent margin, unlike in-app artwork.
        try render(logo, pixels: pixels, inset: CGFloat(pixels) * 0.10,
                   to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
print("Generated AureLogo.png, AureMenuBar.png, and AppIcon.iconset from \(source.lastPathComponent)")
