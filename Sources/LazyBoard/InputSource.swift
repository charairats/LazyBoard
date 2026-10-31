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

    /// What a key produces on a layout (the current one by default), asked of the layout itself.
    static func characters(keyCode: Int, flags: CGEventFlags, on layout: TISInputSource? = nil) -> String? {
        guard let source = layout ?? TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let data = property(source, kTISPropertyUnicodeKeyLayoutData),
              let bytes = CFDataGetBytePtr((data as! CFData)) else { return nil }
        var modifiers = 0
        if flags.contains(.maskShift) { modifiers |= shiftKey }
        if flags.contains(.maskAlphaShift) { modifiers |= alphaLock }
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self),
                                    UInt16(keyCode), UInt16(kUCKeyActionDown), UInt32(modifiers >> 8), UInt32(LMGetKbdType()),
                                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys, chars.count, &length, &chars)
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }

    /// Right after a layout switch a key event can still carry the old layout's character while the app
    /// inserts the new layout's. Trust the layout when the two disagree on Thai vs. not.
    static func resolved(eventText: String, layoutText: String?) -> String {
        guard let layoutText = layoutText else { return eventText }
        let eventThai = eventText.unicodeScalars.contains(where: KeyMap.isThai)
        let layoutThai = layoutText.unicodeScalars.contains(where: KeyMap.isThai)
        return eventThai == layoutThai ? eventText : layoutText
    }

    /// An installed keyboard layout by id, enabled or not.
    static func layout(id: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] else { return nil }
        return list.first
    }

    private static func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue()
    }
}
