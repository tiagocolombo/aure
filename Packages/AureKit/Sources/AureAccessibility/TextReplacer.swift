import AppKit
import ApplicationServices
import AureCore
import Carbon.HIToolbox
import Foundation

/// Replaces text inside another app's field.
@MainActor
public enum TextReplacer {
    public enum Method: String { case accessibility, paste }

    /// Replaces `range` (UTF-16) in the field with `replacement`.
    /// Tries AX first (select range + set selected text), verifies, then falls
    /// back to selecting the range and pasting with ⌘V (clipboard restored).
    @discardableResult
    public static func replace(in field: FocusedField, range: Range<Int>, with replacement: String) async -> Method? {
        let el = field.element
        let app = field.bundleId ?? "?"
        guard let expected = ReplacementSafety.expectedText(original: field.text, current: el.text,
                                                              range: range, replacement: replacement,
                                                              hasFocus: hasFocus(field)),
              !Task.isCancelled, await select(el, range),
              !Task.isCancelled, hasFocus(field), el.text == field.text else { return nil }

        if el.set(kAXSelectedTextAttribute, replacement as CFString) {
            switch await settledWrite(el, original: field.text, expected: expected) {
            case .applied:
                Log.info("replace: accessibility verified (\(app))")
                return .accessibility
            case .uncertain:
                // An accepted write may be delayed or partial. Never duplicate it
                // with a second write/paste when its result is uncertain.
                Log.info("replace: accessibility result unverified; no retry (\(app))")
                return nil
            case .ignored:
                // The app reported success but left the field untouched, so a
                // paste cannot duplicate anything. Reselect: the write may have
                // collapsed the selection.
                Log.info("replace: accessibility write ignored; trying paste (\(app))")
                guard !Task.isCancelled, await select(el, range) else { return nil }
            }
        }

        // A canvas/proxy editor must never receive an unverified Command-A.
        // Paste only into the same, unchanged field with the exact range still selected.
        guard !Task.isCancelled, hasFocus(field), el.text == field.text,
              el.selectedRange == range else {
            Log.info("replace: paste preconditions failed (\(app))")
            return nil
        }
        await paste(replacement, into: field.pid)
        try? await Task.sleep(for: .milliseconds(150))
        guard el.text == expected else {
            Log.info("replace: paste result unverified (\(app))")
            return nil
        }
        Log.info("replace: paste verified (\(app))")
        return .paste
    }

    /// Waits up to ~500 ms for an accepted AX write to land, returning early
    /// once the field shows the expected text or changes in some other way.
    private static func settledWrite(_ el: AXElement, original: String,
                                     expected: String) async -> ReplacementSafety.WriteOutcome {
        var outcome = ReplacementSafety.WriteOutcome.ignored
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(50))
            outcome = ReplacementSafety.writeOutcome(original: original, expected: expected, current: el.text)
            if outcome != .ignored { break }
        }
        return outcome
    }

    private static func hasFocus(_ field: FocusedField) -> Bool {
        guard AccessibilityPermission.isTrusted,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == field.pid,
              let focused = AXElement.application(pid: field.pid).element(kAXFocusedUIElementAttribute)
        else { return false }
        return focused == field.element || focused.element("AXEditableAncestor") == field.element
    }

    /// Replaces the whole field value.
    @discardableResult
    public static func replaceAll(in field: FocusedField, with text: String) async -> Method? {
        await replace(in: field, range: 0..<(field.text as NSString).length, with: text)
    }

    /// Sets the selection and reads it back: Chrome and Electron sometimes
    /// report success without moving the selection.
    static func select(_ el: AXElement, _ range: Range<Int>) async -> Bool {
        var cf = CFRange(location: range.lowerBound, length: range.count)
        guard let v = AXValueCreate(.cfRange, &cf), el.set(kAXSelectedTextRangeAttribute, v) else { return false }
        try? await Task.sleep(for: .milliseconds(40))
        return el.selectedRange == range
    }

    /// Marks from nspasteboard.org that clipboard managers honour: do not record
    /// (transient), do not show (concealed), written by a program (auto-generated).
    static let privateMarkers: [NSPasteboard.PasteboardType] = [
        .init("org.nspasteboard.TransientType"), .init("org.nspasteboard.ConcealedType"),
        .init("org.nspasteboard.AutoGeneratedType"),
    ]
    static let transientMarker = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let concealedMarker = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Puts `text` on the pasteboard, sends ⌘V to `pid`'s app, then restores the
    /// previous contents. Both writes stay on this Mac (no Universal Clipboard) and
    /// are marked so clipboard managers skip them. A concealed item (a password a
    /// password manager copied) is not put back: that would restart its lifetime and
    /// defeat the manager's clear-after-a-delay.
    static func paste(_ text: String, into pid: pid_t) async {
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
            return d
        } ?? []
        let savedIsSecret = saved.contains { $0[concealedMarker] != nil }

        pb.prepareForNewContents(with: .currentHostOnly)
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        for marker in privateMarkers { item.setData(Data(), forType: marker) }
        pb.writeObjects([item])
        let ownedChangeCount = pb.changeCount
        // The key goes to whichever app is frontmost when it is posted.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
            postKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
            try? await Task.sleep(for: .milliseconds(300))
        }
        // Do not erase a newer copy made by the user or another application.
        guard pb.changeCount == ownedChangeCount else { return }
        pb.prepareForNewContents(with: .currentHostOnly)
        guard !savedIsSecret else { return }
        let items = saved.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (t, d) in dict { item.setData(d, forType: t) }
            // Restoring is not a new copy: clipboard history already has it.
            if dict[transientMarker] == nil { item.setData(Data(), forType: transientMarker) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }

    static func postKey(_ key: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
