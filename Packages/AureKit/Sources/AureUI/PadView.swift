import AureCore
import SwiftUI

/// Aure Pad: type or paste text, check or rewrite it, copy the result.
/// Fixes are underlined with red dots, optional suggestions with yellow ones;
/// resting the mouse on an underline shows Aure's recommendation.
struct PadView: View {
    @Environment(AppState.self) private var app
    @State private var text = ""
    @State private var review: PadReview?
    @State private var busy = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var writingTask: Task<Void, Never>?
    @State private var suggestingWriting = false
    @State private var copied = false

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
                if let r = review?.result {
                    Text(r.request.dialect.displayName)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(app.dialect == .automatic ? "Detected from your text" : "Settings → General → Writing language")
                }
                HStack(spacing: 6) {
                    StatusDot(status: app.engine)
                    Text(app.engine.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            AnnotatedTextEditor(text: $text, annotations: review?.annotations ?? [],
                                onAccept: { accept($0.id) }, onDismiss: { review?.dismiss($0.id) })
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .frame(minHeight: 140)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Type or paste text to check…")
                            .foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: text) { _, new in
                    review?.textChanged(to: new)
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
                    copy(review?.corrected ?? text)
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

            if let review {
                resultView(review)
            } else if !app.engine.isReady {
                Text(app.engine == .noModel
                     ? "Download a model in Settings → Models to start checking."
                     : app.engine.label)
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 420)
    }

    @ViewBuilder
    func resultView(_ r: PadReview) -> some View {
        let annotations = r.annotations
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                summary(r)
                Text("\(r.result.latencyMs) ms").font(.caption).foregroundStyle(.tertiary)
                if r.result.soundsAIWritten || (!r.visibleWriting.isEmpty && r.writingSoundsAIWritten) {
                    Label("Sounded AI-written; plainer words suggested", systemImage: "person.wave.2")
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                if suggestingWriting {
                    ProgressView().controlSize(.small)
                    Text("Looking for an optional improvement…").font(.caption).foregroundStyle(.secondary)
                }
                if !annotations.isEmpty {
                    Button("Replace all") { replaceAll() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("r", modifiers: .command)
                }
            }
            if !annotations.isEmpty {
                Text("Rest the mouse on an underline to see the recommendation.")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(annotations) { a in
                            IssueRow(issue: a.issue,
                                     onAccept: { accept(a.id) },
                                     onDismiss: { review?.dismiss(a.id) },
                                     tint: Color(nsColor: a.color))
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
    }

    @ViewBuilder
    func summary(_ r: PadReview) -> some View {
        let fixes = r.annotations.filter { $0.kind == .issue }.count
        let suggestions = r.annotations.count - fixes
        if fixes > 0 {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color(nsColor: PadAnnotation.issueColor))
            Text("\(fixes) issue\(fixes == 1 ? "" : "s")").font(.headline)
        } else if suggestions > 0 {
            Image(systemName: "sparkles").foregroundStyle(Color(nsColor: PadAnnotation.suggestionColor))
            Text("\(suggestions) optional suggestion\(suggestions == 1 ? "" : "s")").font(.headline)
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Looks good").font(.headline)
        }
    }

    func accept(_ id: UUID) {
        guard var r = review else { return }
        let new = r.apply(id)
        review = r
        text = new
        suggestWritingIfNeeded()
    }

    func replaceAll() {
        guard let r = review else { return }
        review = nil
        text = CorrectionServiceBridge.apply(r.annotations.map(\.issue), to: r.text)
    }

    func run(_ mode: CheckMode) {
        let input = text
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        task?.cancel()
        cancelWritingSuggestion()
        error = nil
        busy = true
        task = Task {
            defer { busy = false }
            do {
                let r = try await app.check(input, mode: mode)
                guard !Task.isCancelled, text == input else { return }
                review = PadReview(result: r)
                suggestWritingIfNeeded()
            } catch AureError.cancelled {
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Once no fixes remain, ask the model for an optional better-writing
    /// alternative and underline its changes in yellow.
    func suggestWritingIfNeeded() {
        guard let r = review, r.wantsWritingSuggestion, app.writingSuggestionsEnabled else { return }
        let input = r.text
        review?.writingRequested = true
        cancelWritingSuggestion()
        suggestingWriting = true
        writingTask = Task {
            let suggestion = try? await app.suggestWriting(input)
            guard !Task.isCancelled else { return }
            suggestingWriting = false
            if let suggestion { review?.setWriting(suggestion) }
        }
    }

    func cancelWritingSuggestion() {
        writingTask?.cancel()
        writingTask = nil
        suggestingWriting = false
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
