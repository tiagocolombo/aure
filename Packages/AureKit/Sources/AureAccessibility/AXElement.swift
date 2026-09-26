import AppKit
import ApplicationServices
import AureCore
import Foundation

/// Accessibility permission helpers.
public enum AccessibilityPermission {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt (once) that sends the user to System Settings.
    @discardableResult
    public static func request() -> Bool {
        let key = "AXTrustedCheckOptionPrompt" // kAXTrustedCheckOptionPrompt (a mutable C global)
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Thin, typed wrapper over an AXUIElement.
public struct AXElement: @unchecked Sendable, Equatable {
    public let ref: AXUIElement

    public init(_ ref: AXUIElement) { self.ref = ref }

    public static func == (a: AXElement, b: AXElement) -> Bool { CFEqual(a.ref, b.ref) }

    public static var systemWide: AXElement { AXElement(AXUIElementCreateSystemWide()) }

    public static func application(pid: pid_t) -> AXElement { AXElement(AXUIElementCreateApplication(pid)) }

    public func attribute<T>(_ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ref, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    public func element(_ name: String) -> AXElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ref, name as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXElement(value as! AXUIElement)
    }

    public func isSettable(_ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(ref, name as CFString, &settable) == .success && settable.boolValue
    }

    @discardableResult
    public func set(_ name: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(ref, name as CFString, value) == .success
    }

    public func setTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(ref, seconds)
    }

    public var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(ref, &pid) == .success ? pid : nil
    }

    public var role: String? { attribute(kAXRoleAttribute) }
    public var subrole: String? { attribute(kAXSubroleAttribute) }
    public var value: String? { attribute(kAXValueAttribute) }
    public var parent: AXElement? { element(kAXParentAttribute) }

    public var selectedRange: Range<Int>? {
        guard let v: AXValue = attribute(kAXSelectedTextRangeAttribute) else { return nil }
        var r = CFRange()
        guard AXValueGetValue(v, .cfRange, &r) else { return nil }
        return r.location..<(r.location + r.length)
    }

    /// Frame in AppKit screen coordinates (origin bottom-left of the main screen).
    public var frame: CGRect? {
        guard let posV: AXValue = attribute(kAXPositionAttribute),
              let sizeV: AXValue = attribute(kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(posV, .cgPoint, &p), AXValueGetValue(sizeV, .cgSize, &s) else { return nil }
        return Self.flip(CGRect(origin: p, size: s))
    }

    /// Bounds of a character range (for the caret), in AppKit coordinates.
    public func bounds(for range: Range<Int>) -> CGRect? {
        var cf = CFRange(location: range.lowerBound, length: range.count)
        guard let arg = AXValueCreate(.cfRange, &cf) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(ref, kAXBoundsForRangeParameterizedAttribute as CFString, arg, &out) == .success,
              let out, CFGetTypeID(out) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(out as! AXValue, .cgRect, &r), r.width >= 0, r.height > 0 else { return nil }
        return Self.flip(r)
    }

    /// AX uses top-left origin on the primary screen; AppKit uses bottom-left.
    static func flip(_ r: CGRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.origin.x, y: h - r.origin.y - r.height, width: r.width, height: r.height)
    }
}
