import AppKit
import AureCore
import SwiftUI

/// Aure Pad's plain-text editor. Draws a dotted underline under each annotated
/// span (red for fixes, yellow for optional suggestions) and shows the
/// recommendation in a popover while the mouse rests on one.
struct AnnotatedTextEditor: NSViewRepresentable {
    @Binding var text: String
    var annotations: [PadAnnotation]
    var onAccept: (PadAnnotation) -> Void
    var onDismiss: (PadAnnotation) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1: temporary attributes draw the underlines without touching the text.
        let textView = AnnotatedTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 4, height: 8)
        // Aure draws its own underlines; the system checker's would compete with them.
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        textView.onHover = { [weak coordinator = context.coordinator] span, rect in coordinator?.hover(span, at: rect) }

        let scroll = PadScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.textView?.string != text { coordinator.replaceText(with: text) }
        coordinator.underline(annotations)
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate, NSPopoverDelegate {
        var parent: AnnotatedTextEditor
        weak var textView: AnnotatedTextView?
        private var popover: NSPopover?
        private var shown: UUID?
        private var pendingClose: Task<Void, Never>?

        init(_ parent: AnnotatedTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            closePopover()
            if parent.text != textView.string { parent.text = textView.string }
        }

        /// Programmatic changes (accepting a fix) go through the text view, so Undo reverts them.
        func replaceText(with new: String) {
            guard let textView, let storage = textView.textStorage else { return }
            let edit = TextEdit(from: textView.string, to: new)
            let range = NSRange(location: edit.range.lowerBound, length: edit.range.count)
            let replacement = (new as NSString).substring(with: NSRange(location: edit.range.lowerBound,
                                                                        length: edit.replacementLength))
            guard textView.shouldChangeText(in: range, replacementString: replacement) else {
                textView.string = new
                return
            }
            storage.replaceCharacters(in: range, with: NSAttributedString(string: replacement,
                                                                          attributes: textView.typingAttributes))
            textView.didChangeText()
        }

        func underline(_ annotations: [PadAnnotation]) {
            guard let textView, let layout = textView.layoutManager else { return }
            let text = textView.string
            let spans = annotations.compactMap { a in
                a.issue.underlineRange(in: text).map {
                    AnnotatedTextView.Span(range: NSRange(location: $0.lowerBound, length: $0.count), annotation: a)
                }
            }
            textView.spans = spans
            let all = NSRange(location: 0, length: (text as NSString).length)
            layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: all)
            layout.removeTemporaryAttribute(.underlineColor, forCharacterRange: all)
            for span in spans {
                layout.addTemporaryAttributes([
                    .underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                    .underlineColor: span.annotation.color,
                ], forCharacterRange: span.range)
            }
            if let shown, !spans.contains(where: { $0.annotation.id == shown }) { closePopover() }
        }

        func hover(_ span: AnnotatedTextView.Span?, at rect: NSRect) {
            guard let span else { return scheduleClose() }
            pendingClose?.cancel()
            guard span.annotation.id != shown, let textView else { return }
            popover?.close()
            let annotation = span.annotation
            let card = RecommendationCard(
                annotation: annotation,
                onAccept: { [weak self] in
                    self?.closePopover()
                    self?.parent.onAccept(annotation)
                },
                onDismiss: { [weak self] in
                    self?.closePopover()
                    self?.parent.onDismiss(annotation)
                },
                onHover: { [weak self] inside in
                    if inside { self?.pendingClose?.cancel() } else { self?.scheduleClose() }
                })
            let host = NSHostingController(rootView: card)
            host.sizingOptions = .preferredContentSize
            let p = NSPopover()
            p.contentViewController = host
            p.behavior = .transient
            p.delegate = self
            popover = p
            shown = annotation.id
            p.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
        }

        /// A short grace period lets the mouse travel from the word into the popover.
        private func scheduleClose() {
            pendingClose?.cancel()
            pendingClose = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                self?.closePopover()
            }
        }

        func closePopover() {
            pendingClose?.cancel()
            popover?.close()
            popover = nil
            shown = nil
        }

        func popoverDidClose(_ notification: Notification) {
            guard (notification.object as? NSPopover) === popover else { return }
            popover = nil
            shown = nil
        }
    }
}

/// Keeps the text view at least as tall as the visible area, so a click below
/// the last line still places the caret.
final class PadScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let textView = documentView as? NSTextView else { return }
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.sizeToFit()
    }
}

final class AnnotatedTextView: NSTextView {
    struct Span: Equatable {
        var range: NSRange
        var annotation: PadAnnotation
    }

    var spans: [Span] = []
    /// Called after the mouse rests on a span (with its anchor rect), or with nil when it leaves.
    var onHover: ((Span?, NSRect) -> Void)?
    private var hoverArea: NSTrackingArea?
    private var hovered: UUID?
    private var hoverTask: Task<Void, Never>?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow,
                                                         .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let hit = span(at: convert(event.locationInWindow, from: nil))
        guard hit?.span.annotation.id != hovered else { return }
        hovered = hit?.span.annotation.id
        hoverTask?.cancel()
        guard let hit else { return onHover?(nil, .zero) ?? () }
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.onHover?(hit.span, hit.rect)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard event.trackingArea === hoverArea else { return }
        hovered = nil
        hoverTask?.cancel()
        onHover?(nil, .zero)
    }

    override func mouseDown(with event: NSEvent) {
        hoverTask?.cancel()
        super.mouseDown(with: event)
    }

    /// The span under `point` and the part of it on that line, in view coordinates.
    private func span(at point: NSPoint) -> (span: Span, rect: NSRect)? {
        guard !spans.isEmpty, let layout = layoutManager, let container = textContainer else { return nil }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: p, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < layout.numberOfGlyphs,
              layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(p)
        else { return nil }
        let index = layout.characterIndexForGlyph(at: glyph)
        guard let span = spans.first(where: { NSLocationInRange(index, $0.range) }) else { return nil }
        var line = NSRange()
        layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &line)
        let glyphs = NSIntersectionRange(layout.glyphRange(forCharacterRange: span.range, actualCharacterRange: nil), line)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        return (span, rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y))
    }
}

/// What Aure recommends for one underlined span.
struct RecommendationCard: View {
    let annotation: PadAnnotation
    var onAccept: () -> Void
    var onDismiss: () -> Void
    var onHover: (Bool) -> Void = { _ in }

    var body: some View {
        let issue = annotation.issue
        VStack(alignment: .leading, spacing: 8) {
            Label(annotation.kind == .issue ? issue.category.displayName : "Better writing · Optional",
                  systemImage: annotation.kind == .issue ? "exclamationmark.circle.fill" : "sparkles")
                .font(.subheadline.bold())
                .foregroundStyle(Color(nsColor: annotation.color))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                let original = issue.original.trimmingCharacters(in: .whitespaces)
                if !original.isEmpty {
                    Text(original).strikethrough().foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                }
                let replacement = issue.replacement.trimmingCharacters(in: .whitespaces)
                Text(replacement.isEmpty ? "(remove)" : replacement).fontWeight(.semibold)
            }
            .fixedSize(horizontal: false, vertical: true)
            Text(issue.explanation)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if issue.confidence < 0.9 {
                Text("The model was \(Int((issue.confidence * 100).rounded()))% sure about this change.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Dismiss", action: onDismiss)
                Spacer()
                Button(annotation.kind == .issue ? "Accept" : "Apply", action: onAccept)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .onHover(perform: onHover)
    }
}
