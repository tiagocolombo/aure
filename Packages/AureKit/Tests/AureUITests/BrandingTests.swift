import AppKit
import AureCore
import SwiftUI
import Testing
@testable import AureUI

@Suite @MainActor struct BrandingTests {
    @Test func menuBrandIsReservedForHealthyReadyState() {
        #expect(MenuBarPresentation(paused: false, engine: .ready("Local"), status: .clean).symbol == nil)
        #expect(MenuBarPresentation(paused: true, engine: .ready("Local"), status: .clean).symbol == "text.badge.xmark")
        #expect(MenuBarPresentation(paused: false, engine: .loading("Local"), status: nil).symbol == "hourglass")
        #expect(MenuBarPresentation(paused: false, engine: .noModel, status: nil).symbol == "text.badge.minus")
        #expect(MenuBarPresentation(paused: false, engine: .failed("Failure"), status: nil).symbol == "text.badge.minus")
        #expect(MenuBarPresentation(paused: false, engine: .ready("Local"), status: .issues(2)).symbol == "exclamationmark.bubble")
        #expect(MenuBarPresentation(paused: false, engine: .ready("Local"), status: .error("Failure")).symbol == "text.badge.minus")
        #expect(MenuBarPresentation(paused: false, engine: .ready("Local"), status: .checking).symbol == "hourglass")
        #expect(MenuBarPresentation(paused: true, engine: .ready("Local"), status: nil).accessibilityLabel == "Aure — Paused")
        #expect(MenuBarPresentation(paused: false, engine: .ready("Local"), status: .issues(2)).accessibilityLabel == "Aure — 2 suggestions")
    }

    @Test func aboutMetadataAndRendering() throws {
        #expect(AboutView.version == AureVersion.string)
        #expect(AboutView.tagline == "Your words. Your Mac. Your call.")
        #expect(AboutView.inferenceStatement.contains("does not send your writing to a cloud inference service"))
        #expect(AboutView.inferenceStatement.contains("Other apps"))
        #expect(AboutView.modelLicenseNotice.contains("separate licenses"))
        #expect(AboutView.links.map(\.title) == ["Repository", "Report an issue", "Contribute", "License", "llama.cpp"])
        #expect(AboutView.links.map { $0.url.absoluteString } == [
            "https://github.com/tiagocolombo/aure",
            "https://github.com/tiagocolombo/aure/issues",
            "https://github.com/tiagocolombo/aure/blob/master/CONTRIBUTING.md",
            "https://github.com/tiagocolombo/aure/blob/master/LICENSE",
            "https://github.com/ggml-org/llama.cpp"
        ])
        _ = NSApplication.shared
        for scheme in [ColorScheme.light, .dark] {
            let content = AboutView().environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: content)
            let image = try #require(renderer.nsImage)
            #expect(image.size.width <= 620)
            #expect(image.size.height > 200 && image.size.height <= 460)
            let host = NSHostingView(rootView: content)
            host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            host.setFrameSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(png.count > 1000)
            if let directory = ProcessInfo.processInfo.environment["AURE_BRAND_PREVIEW_DIR"] {
                let root = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try png.write(to: root.appendingPathComponent("aure-about-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }

    @Test func bundledImagesUseSeparateTemplateMark() throws {
        let logo = try #require(AureBrand.image(named: "AureLogo"))
        #expect(logo.isValid)
        #expect(!logo.isTemplate)
        let mark = try #require(AureBrand.menuBarImage)
        #expect(mark.isValid)
        #expect(mark.isTemplate)
        #expect(mark.size == NSSize(width: 18, height: 18))
        #expect(AureBrand.image(named: "MissingImage") == nil)
    }

    @Test func resolvesPackagedResourcesBeforeFallback() throws {
        let scratch = ProcessInfo.processInfo.environment["AURE_TEST_TEMP_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let root = scratch.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Aure.app/Contents/Resources")
        let bundleURL = resources.appendingPathComponent("AureKit_AureUI.bundle")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        var fallbackCalled = false
        let resolved = AureBrand.resolveBundle(candidates: [nil, resources], fallback: {
            fallbackCalled = true
            return .main
        })
        #expect(resolved.bundleURL.path == bundleURL.path)
        #expect(!fallbackCalled)

        let executableDirectory = root.appendingPathComponent("Aure.app/Contents/MacOS")
        let neighbor = executableDirectory.appendingPathComponent("AureKit_AureUI.bundle")
        try FileManager.default.createDirectory(at: neighbor, withIntermediateDirectories: true)
        let preferred = AureBrand.resolveBundle(candidates: [resources, executableDirectory], fallback: { .main })
        #expect(preferred.bundleURL.path == bundleURL.path)
        let executableBundle = AureBrand.resolveBundle(candidates: [nil, root, executableDirectory], fallback: { .main })
        #expect(executableBundle.bundleURL.path == neighbor.path)
        let fallback = AureBrand.resolveBundle(candidates: [nil, root], fallback: {
            fallbackCalled = true
            return .main
        })
        #expect(fallbackCalled)
        #expect(fallback.bundleURL == Bundle.main.bundleURL)
    }
}
