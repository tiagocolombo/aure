/// Resolve only the browser's explicit editing relationship, never search
/// arbitrary parents/children (which could expose unrelated page content).
enum EditableTarget {
    static func read<Element, Result>(_ focused: Element, isSecure: (Element) -> Bool,
                                      ancestor: (Element) -> Element?, read: (Element) -> Result?) -> Result? {
        guard !isSecure(focused) else { return nil }
        let target = ancestor(focused) ?? focused
        guard !isSecure(target) else { return nil }
        return read(target)
    }
}
