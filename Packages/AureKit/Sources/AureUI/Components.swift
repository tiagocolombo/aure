import AureCore
import SwiftUI

/// Renders the original text with removed parts struck through in red and
/// inserted parts in green.
struct DiffText: View {
    let original: String
    let issues: [Issue]

    var body: some View {
        Text(attributed)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    var attributed: AttributedString {
        var out = AttributedString()
        let ns = original as NSString
        var cursor = 0
        for issue in issues.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            if issue.range.lowerBound > cursor {
                out += AttributedString(ns.substring(with: NSRange(location: cursor, length: issue.range.lowerBound - cursor)))
            }
            if !issue.original.isEmpty {
                var del = AttributedString(issue.original)
                del.strikethroughStyle = .single
                del.foregroundColor = .red
                out += del
            }
            if !issue.replacement.isEmpty {
                var ins = AttributedString(issue.replacement)
                ins.foregroundColor = .green
                ins.backgroundColor = .green.opacity(0.12)
                out += ins
            }
            cursor = max(cursor, issue.range.upperBound)
        }
        if cursor < ns.length {
            out += AttributedString(ns.substring(from: cursor))
        }
        return out
    }
}

struct IssueRow: View {
    let issue: Issue
    var onAccept: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if !issue.original.isEmpty {
                        Text(issue.original.trimmingCharacters(in: .whitespaces)).strikethrough().foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(issue.replacement.isEmpty ? "(remove)" : issue.replacement.trimmingCharacters(in: .whitespaces))
                        .fontWeight(.semibold)
                }
                HStack(spacing: 4) {
                    Text("\(issue.category.displayName) · \(issue.explanation)")
                    if issue.confidence < 0.9 {
                        Text("· \(Int((issue.confidence * 100).rounded()))% sure")
                            .foregroundStyle(.orange)
                            .help("The model was not fully sure about this change.")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let onAccept {
                Button(action: onAccept) { Image(systemName: "checkmark") }
                    .buttonStyle(.borderless).help("Accept")
            }
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Dismiss")
            }
        }
    }

    var color: Color {
        switch issue.category {
        case .spelling: .red
        case .grammar: .orange
        case .punctuation: .yellow
        case .wordChoice: .purple
        case .tone: .blue
        case .clarity: .teal
        }
    }
}

struct StatusDot: View {
    let status: AppState.EngineStatus
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
    var color: Color {
        switch status {
        case .ready: .green
        case .loading: .yellow
        case .noModel: .gray
        case .failed: .red
        }
    }
}
