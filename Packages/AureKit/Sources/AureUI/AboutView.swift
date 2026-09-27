import AureCore
import SwiftUI

struct AboutView: View {
    struct ProjectLink: Sendable {
        let title: String
        let url: URL
    }
    static let version = AureVersion.string
    static let tagline = "Your words. Your Mac. Your call."
    static let inferenceStatement = "Aure runs grammar and tone inference on your Mac with llama.cpp. It does not send your writing to a cloud inference service. Model downloads require internet access. Other apps you write in may transmit or store your text."
    static let modelLicenseNotice = "Models have separate licenses and usage terms; review the license for each model you download or import."
    static let links: [ProjectLink] = [
        .init(title: "Repository", url: URL(string: "https://github.com/tiagocolombo/aure")!),
        .init(title: "Report an issue", url: URL(string: "https://github.com/tiagocolombo/aure/issues")!),
        .init(title: "Contribute", url: URL(string: "https://github.com/tiagocolombo/aure/blob/main/CONTRIBUTING.md")!),
        .init(title: "License", url: URL(string: "https://github.com/tiagocolombo/aure/blob/main/LICENSE")!),
        .init(title: "llama.cpp", url: URL(string: "https://github.com/ggml-org/llama.cpp")!)
    ]

    var body: some View {
        VStack(spacing: 12) {
            AureLogo(size: 76)
            VStack(spacing: 3) {
                Text("Aure").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                Text("Version \(Self.version)").font(.caption).foregroundStyle(.secondary)
            }
            Text(Self.tagline).font(.headline)
            Text(Self.inferenceStatement)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                ForEach(Self.links.prefix(4), id: \.title) { link in
                    Link(link.title, destination: link.url)
                }
            }
            Divider()
            HStack(spacing: 4) {
                Text("Local inference powered by")
                Link("llama.cpp", destination: Self.links[4].url)
            }
            .font(.caption)
            Text(Self.modelLicenseNotice)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(width: 560)
        .background(.background)
    }
}
