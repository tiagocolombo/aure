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
        let expected = (field.text as NSString).replacingCharacters(
            in: NSRange(location: range.lowerBound, length: range.count), with: replacement)

        if await select(el, range) {
            if el.set(kAXSelectedTextAttribute, replacement as CFString) {
                try? await Task.sleep(for: .milliseconds(80))
                if el.value == expected {
                    Log.info("replace: accessibility ok (\(field.bundleId ?? "?"))")
                    return .accessibility
                }
            }
        }

        // Fallback: select the range and paste. Only paste if the selection is
        // verified, or if we replace the whole field (⌘A selects it).
        let selected = await select(el, range)
        var textToPaste = replacement
        if !selected {
            // Cannot select just this range: select the whole field (⌘A) and
            // paste the whole corrected text instead.
            postKey(CGKeyCode(kVK_ANSI_A), flags: .maskCommand)
            textToPaste = expected
        }
        try? await Task.sleep(for: .milliseconds(80))
        await paste(textToPaste)
        try? await Task.sleep(for: .milliseconds(150))
        Log.info("replace: paste (\(selected ? "range" : "select-all")) in \(field.bundleId ?? "?")")
        return .paste
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
        postKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        try? await Task.sleep(for: .milliseconds(300))
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
