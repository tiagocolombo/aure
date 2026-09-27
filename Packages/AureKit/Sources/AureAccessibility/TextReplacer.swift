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
        guard let expected = ReplacementSafety.expectedText(original: field.text, current: el.text,
                                                              range: range, replacement: replacement,
                                                              hasFocus: hasFocus(field)),
              !Task.isCancelled, await select(el, range),
              !Task.isCancelled, hasFocus(field), el.text == field.text else { return nil }

        if el.set(kAXSelectedTextAttribute, replacement as CFString) {
            try? await Task.sleep(for: .milliseconds(80))
            if el.text == expected {
                Log.info("replace: accessibility verified (\(field.bundleId ?? "?"))")
                return .accessibility
            }
            // An accepted write may be delayed or partial. Never duplicate it
            // with a second write/paste when its result is uncertain.
            Log.info("replace: accessibility result unverified; no retry")
            return nil
        }

        // A canvas/proxy editor must never receive an unverified Command-A.
        // Paste only into the same, unchanged field with the exact range still selected.
        guard !Task.isCancelled, hasFocus(field), el.text == field.text,
              el.selectedRange == range else { return nil }
        await paste(replacement)
        try? await Task.sleep(for: .milliseconds(150))
        guard el.text == expected else {
            Log.info("replace: paste result unverified")
            return nil
        }
        Log.info("replace: paste verified (\(field.bundleId ?? "?"))")
        return .paste
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

    /// Puts `text` on the pasteboard, sends ⌘V, then restores the previous contents.
    static func paste(_ text: String) async {
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
            return d
        } ?? []
        pb.clearContents()
        pb.setString(text, forType: .string)
        let ownedChangeCount = pb.changeCount
        postKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        try? await Task.sleep(for: .milliseconds(300))
        // Do not erase a newer copy made by the user or another application.
        guard pb.changeCount == ownedChangeCount else { return }
        pb.clearContents()
        let items = saved.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (t, d) in dict { item.setData(d, forType: t) }
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

    /// Copies the current selection with ⌘C and returns it (clipboard restored).
    public static func copySelection() async -> String? {
        let pb = NSPasteboard.general
        let before = pb.changeCount
        let saved = pb.string(forType: .string)
        postKey(CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(50))
            if pb.changeCount != before { break }
        }
        guard pb.changeCount != before else { return nil }
        let text = pb.string(forType: .string)
        pb.clearContents()
        if let saved { pb.setString(saved, forType: .string) }
        return text
    }
}
