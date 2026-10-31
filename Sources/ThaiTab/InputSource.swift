import Carbon

enum InputSource {
    /// Switch the active keyboard layout to Thai or to an English layout (ABC/US).
    static func select(thai: Bool) {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
        guard let unmanaged = TISCreateInputSourceList(filter, false) else { return }
        let array = unmanaged.takeRetainedValue() as NSArray
        var fallback: TISInputSource?
        for item in array {
            let source = item as! TISInputSource
            guard let id = property(source, kTISPropertyInputSourceID) as? String else { continue }
            guard (property(source, kTISPropertyInputSourceIsSelectCapable) as? Bool) == true else { continue }
            if thai {
                if id.hasPrefix("com.apple.keylayout.Thai") { TISSelectInputSource(source); return }
            } else {
                if id == "com.apple.keylayout.ABC" || id == "com.apple.keylayout.US" { TISSelectInputSource(source); return }
                if fallback == nil, let langs = property(source, kTISPropertyInputSourceLanguages) as? [String], langs.contains("en") {
                    fallback = source
                }
            }
        }
        if let fallback = fallback { TISSelectInputSource(fallback) }
    }

    private static func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue()
    }
}
