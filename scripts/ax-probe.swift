// Privacy-preserving AX capability probe: no titles, descriptions, URLs, or text.
// swift scripts/ax-probe.swift com.google.Chrome --wait 8 [--enable-tree] [--measure-text]
// --measure-text reads only the focused editable target to report UTF-16 lengths;
// use it ONLY on a disposable test document. No clipboard or keyboard events.
import AppKit
import ApplicationServices

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}
func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
    guard let v = attr(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
}
func names(_ el: AXUIElement, parameterized: Bool = false) -> [String] {
    var n: CFArray?
    if parameterized { AXUIElementCopyParameterizedAttributeNames(el, &n) }
    else { AXUIElementCopyAttributeNames(el, &n) }
    return (n as? [String]) ?? []
}
func describe(_ el: AXUIElement, measure: Bool = false) {
    let role = attr(el, kAXRoleAttribute) as? String ?? "?"
    let secure = (attr(el, kAXSubroleAttribute) as? String) == kAXSecureTextFieldSubrole
    print("role=\(role) secure=\(secure)")
    guard !secure else { return }
    let attrs = names(el), params = names(el, parameterized: true)
    print("attributes: \(attrs.joined(separator: ", "))")
    print("parameterized: \(params.joined(separator: ", "))")
    for name in [kAXValueAttribute, kAXSelectedTextRangeAttribute, kAXSelectedTextAttribute] {
        var settable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(el, name as CFString, &settable)
        print("\(name): supported=\(attrs.contains(name)) settable=\(settable.boolValue) status=\(result.rawValue)")
    }
    if let v = attr(el, kAXSelectedTextRangeAttribute), CFGetTypeID(v) == AXValueGetTypeID() {
        var range = CFRange()
        if AXValueGetValue(v as! AXValue, .cfRange, &range) {
            print("selection=\(range.location)+\(range.length)")
        }
    }
    let count = attr(el, kAXNumberOfCharactersAttribute) as? Int
    print("characterCount=\(count.map(String.init) ?? "unavailable") editableAncestor=\(element(el, "AXEditableAncestor") != nil)")
    guard measure else { return }
    if let value = attr(el, kAXValueAttribute) as? String { print("valueUTF16=\((value as NSString).length)") }
    if let count, count > 0, count <= 100_000, params.contains(kAXStringForRangeParameterizedAttribute) {
        var range = CFRange(location: 0, length: count)
        if let arg = AXValueCreate(.cfRange, &range) {
            var result: CFTypeRef?
            let status = AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, arg, &result)
            print("stringForRangeStatus=\(status.rawValue) UTF16=\((result as? String).map { String(($0 as NSString).length) } ?? "unavailable")")
        }
    }
}

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--help") {
    print("swift scripts/ax-probe.swift [bundle-id] [--wait seconds] [--enable-tree] [--measure-text]")
    print("Metadata only by default. --measure-text is for disposable test documents only; outputs lengths, never text.")
    exit(0)
}
guard AXIsProcessTrusted() else {
    print("NOT TRUSTED: this runner lacks macOS Accessibility permission. No app inspected.")
    print("If you choose, enable your terminal in System Settings > Privacy & Security > Accessibility, then rerun there. Aure's grant is separate.")
    exit(1)
}
if let i = args.firstIndex(of: "--wait"), i + 1 < args.count, let seconds = Double(args[i + 1]), seconds >= 0, seconds <= 60 {
    print("Waiting \(seconds)s: focus a disposable test editor.")
    Thread.sleep(forTimeInterval: seconds)
}
let bundle = args.first { !$0.hasPrefix("--") && Double($0) == nil }
let app: NSRunningApplication?
if let bundle { app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first }
else { app = NSWorkspace.shared.frontmostApplication }
guard let app else { print("Requested app not running; not inspecting another app."); exit(2) }
print("bundle=\(app.bundleIdentifier ?? "unknown") pid=\(app.processIdentifier)")
let appEl = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(appEl, 0.25)
if args.contains("--enable-tree") {
    for name in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
        print("\(name) status=\(AXUIElementSetAttributeValue(appEl, name as CFString, kCFBooleanTrue).rawValue)")
    }
    Thread.sleep(forTimeInterval: 0.5)
}
guard let focused = element(appEl, kAXFocusedUIElementAttribute) else { print("No focused element"); exit(0) }
print("focused:")
describe(focused)
guard (attr(focused, kAXSubroleAttribute) as? String) != kAXSecureTextFieldSubrole else { exit(0) }
let target = element(focused, "AXEditableAncestor") ?? focused
print("editable target:")
let role = attr(target, kAXRoleAttribute) as? String ?? ""
let editable = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"].contains(role)
describe(target, measure: args.contains("--measure-text") && editable)
// Ancestor roles/capabilities only. Never traverse or read sibling page content.
var current = element(focused, kAXParentAttribute)
for depth in 1...10 {
    guard let parent = current else { break }
    print("ancestor \(depth):")
    describe(parent)
    current = element(parent, kAXParentAttribute)
}
