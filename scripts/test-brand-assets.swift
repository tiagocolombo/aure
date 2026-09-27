// Run with scripts/test-brand-assets.sh. No third-party image tools required.
import AppKit
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let resources = root.appendingPathComponent("Packages/AureKit/Sources/AureUI/Resources")
func bitmap(_ name: String, pixels: Int) -> NSBitmapImageRep {
    let url = resources.appendingPathComponent(name)
    require(FileManager.default.fileExists(atPath: url.path), "Missing generated asset: \(name)")
    guard let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data) else {
        fatalError("Cannot decode \(name)")
    }
    require(rep.pixelsWide == pixels && rep.pixelsHigh == pixels, "Wrong pixel size: \(name)")
    require(rep.hasAlpha, "\(name) must retain transparency")
    require(rep.colorAt(x: 0, y: 0)!.alphaComponent == 0, "\(name) corners must be transparent")
    return rep
}

let logo = bitmap("AureLogo.png", pixels: 1024)
require(logo.colorAt(x: 512, y: 512)!.alphaComponent > 0.99, "Logo center must be opaque")
let menu = bitmap("AureMenuBar.png", pixels: 44)
var visiblePixels = 0
for y in 0..<menu.pixelsHigh {
    for x in 0..<menu.pixelsWide {
        guard let color = menu.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0 else { continue }
        visiblePixels += 1
        require(color.redComponent < 0.01 && color.greenComponent < 0.01 && color.blueComponent < 0.01,
                "Menu mark must be monochrome for template rendering")
    }
}
require(visiblePixels > 100 && visiblePixels < 1200, "Menu asset must contain the mark, not a filled tile")
let iconURL = root.appendingPathComponent("Resources/AppIcon.icns")
require(FileManager.default.fileExists(atPath: iconURL.path), "Missing AppIcon.icns")
let icon = NSImage(contentsOf: iconURL)
require(icon != nil, "App icon must decode")
let sizes = Set(icon!.representations.map { $0.pixelsWide })
require(Set([16, 32, 64, 128, 256, 512, 1024]).isSubset(of: sizes), "Incomplete app-icon resolutions: \(sizes)")
print("PASS: logo transparency, 1024px artwork, 44px monochrome menu mark, and app-icon resolutions")
