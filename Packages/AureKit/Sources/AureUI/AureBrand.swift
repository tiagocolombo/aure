import AppKit
import SwiftUI

/// Shared resource lookup for both SwiftPM executables and packaged apps.
enum AureBrand {
    static var resourceBundle: Bundle {
        resolveBundle(candidates: [Bundle.main.resourceURL, Bundle.main.bundleURL,
                                   Bundle.main.executableURL?.deletingLastPathComponent()],
                      fallback: { Bundle.module })
    }

    @MainActor static func image(named: String) -> NSImage? {
        let bundle = resourceBundle
        guard let url = bundle.url(forResource: named, withExtension: "png", subdirectory: "Resources")
            ?? bundle.url(forResource: named, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }

    @MainActor static var menuBarImage: NSImage? {
        guard let image = image(named: "AureMenuBar") else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }

    static func resolveBundle(candidates: [URL?], fallback: () -> Bundle) -> Bundle {
        for base in candidates {
            if let url = base?.appendingPathComponent("AureKit_AureUI.bundle"),
               let bundle = Bundle(url: url) { return bundle }
        }
        return fallback()
    }
}

/// Full-color artwork for in-app identity; never used as the menu-bar template.
struct AureLogo: View {
    var size: CGFloat = 64

    var body: some View {
        Group {
            if let image = AureBrand.image(named: "AureLogo") {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "text.badge.checkmark").resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Aure logo")
    }
}
