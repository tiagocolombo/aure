import AureCore
import SwiftUI

/// Aure Pad: type or paste text, check or rewrite it, copy the result.
struct PadView: View {
    @Environment(AppState.self) private var app
    @State private var text = ""
    @State private var result: CheckResult?
    @State private var dismissed = Set<UUID>()
    @State private var busy = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var copied = false
    @FocusState private var editorFocused: Bool

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Tone", selection: $app.tone) {
                    ForEach(Tone.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 340)
                Spacer()
                HStack(spacing: 6) {
                    StatusDot(status: app.engine)
                    Text(app.engine.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            TextEditor(text: $text)
                .font(.body)
                .focused($editorFocused)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .frame(minHeight: 140)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Type or paste text to check…")
                            .foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: text) { _, new in
                    if let r = result, r.request.text != new { result = nil; dismissed = [] }
                }

            HStack {
                Button { run(.correct) } label: {
                    Label("Check", systemImage: "checkmark.circle")
                }
                .keyboardShortcut(.return, modifiers: .command)
                Button { run(.rewrite) } label: {
                    Label("Rewrite as \(app.tone.displayName)", systemImage: "wand.and.stars")
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                if busy {
                    ProgressView().controlSize(.small)
                    Button("Stop") { task?.cancel() }.buttonStyle(.link)
                }
                Spacer()
                Button {
                    copy(result.map { _ in corrected } ?? text)
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(text.isEmpty)
            }
            .disabled(!app.engine.isReady && !busy)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            }

            if let result {
                resultView(result)
            } else if !app.engine.isReady {
                Text(app.engine == .noModel
                     ? "Download a model in Settings → Models to start checking."
                     : app.engine.label)
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 420)
        .onAppear { editorFocused = true }
    }

    var visibleIssues: [Issue] { (result?.issues ?? []).filter { !dismissed.contains($0.id) } }

    var corrected: String {
        guard let result else { return text }
        return CorrectionServiceBridge.apply(visibleIssues, to: result.request.text)
    }

    @ViewBuilder
    func resultView(_ r: CheckResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: visibleIssues.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(visibleIssues.isEmpty ? .green : .red)
                Text(visibleIssues.isEmpty ? "Looks good" : "\(visibleIssues.count) suggestion\(visibleIssues.count == 1 ? "" : "s")")
                    .font(.headline)
                Text("\(r.latencyMs) ms").font(.caption).foregroundStyle(.tertiary)
                if r.soundsAIWritten {
                    Label("Sounded AI-written; rewritten in plainer words", systemImage: "person.wave.2")
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                if !visibleIssues.isEmpty {
                    Button("Replace all") {
                        text = corrected
                        result = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("r", modifiers: .command)
                }
            }
            if !visibleIssues.isEmpty {
                GroupBox {
                    DiffText(original: r.request.text, issues: visibleIssues)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(visibleIssues) { issue in
                            IssueRow(issue: issue,
                                     onAccept: { accept(issue, in: r) },
                                     onDismiss: { dismissed.insert(issue.id) })
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
    }

    func accept(_ issue: Issue, in r: CheckResult) {
        // Apply one fix and re-check the rest at their shifted offsets.
        let newText = CorrectionServiceBridge.apply([issue], to: r.request.text)
        let delta = issue.replacement.utf16.count - issue.range.count
        let remaining = r.issues.filter { $0.id != issue.id && !dismissed.contains($0.id) }.map { i -> Issue in
            var i = i
            if i.range.lowerBound >= issue.range.upperBound {
                i.range = (i.range.lowerBound + delta)..<(i.range.upperBound + delta)
            }
            return i
        }
        text = newText
        var updated = r
        updated.request.text = newText
        updated.issues = remaining
        result = updated
    }

    func run(_ mode: CheckMode) {
        let input = text
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        task?.cancel()
        error = nil
        busy = true
        task = Task {
            defer { busy = false }
            do {
                let r = try await app.check(input, mode: mode)
                guard !Task.isCancelled, text == input else { return }
                dismissed = []
                result = r
            } catch AureError.cancelled {
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }
}

enum CorrectionServiceBridge {
    static func apply(_ issues: [Issue], to text: String) -> String {
        DiffEngine.apply(issues.map { .init(range: $0.range, original: $0.original, replacement: $0.replacement) }, to: text)
    }
}
