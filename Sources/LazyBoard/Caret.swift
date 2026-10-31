import Cocoa
import ApplicationServices

/// Finds where to put the popup: text caret (via Accessibility), else focused window, else mouse.
enum Caret {
    static func anchorPoint() -> NSPoint {
        if let p = caretBottomLeft() { return p }
        if let p = focusedWindowBottomCenter() { return p }
        return NSEvent.mouseLocation
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref
    }

    /// Apps already asked to switch their accessibility tree on (Electron/Chromium build it lazily).
    private static var enabledPIDs = Set<pid_t>()

    private static func focusedElement() -> AXUIElement? {
        if let e = focusedElementOnce() { return e }
        // Electron/Chromium apps expose nothing until a client asks for it; ask once per app, then retry.
        guard let app = NSWorkspace.shared.frontmostApplication, !enabledPIDs.contains(app.processIdentifier) else { return nil }
        enabledPIDs.insert(app.processIdentifier)
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        Log.write("ax: asked \(app.bundleIdentifier ?? "app") to enable accessibility")
        return focusedElementOnce()
    }

    private static func focusedElementOnce() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        if let ref = axValue(system, kAXFocusedUIElementAttribute), CFGetTypeID(ref) == AXUIElementGetTypeID() {
            let element = ref as! AXUIElement
            AXUIElementSetMessagingTimeout(element, 0.15)
            return element
        }
        // Fall back to the frontmost app's own focused element.
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.15)
        guard let ref = axValue(appElement, kAXFocusedUIElementAttribute), CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        let element = ref as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.15)
        return element
    }

    private static func toCocoa(_ rect: CGRect) -> NSPoint? {
        guard let primary = NSScreen.screens.first else { return nil }
        return NSPoint(x: rect.minX, y: primary.frame.height - rect.maxY)
    }

    private static func caretBottomLeft() -> NSPoint? {
        guard let element = focusedElement() else { return nil }
        guard let rangeRef = axValue(element, kAXSelectedTextRangeAttribute), CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return nil }

        func bounds(_ r: CFRange) -> CGRect? {
            var r = r
            guard let param = AXValueCreate(.cfRange, &r) else { return nil }
            var ref: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, param, &ref) == .success,
                  let ref = ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
            var rect = CGRect.zero
            guard AXValueGetValue(ref as! AXValue, .cgRect, &rect), rect.height > 0 else { return nil }
            return rect
        }

        var rect = bounds(CFRange(location: range.location, length: max(range.length, 1)))
        if rect == nil, range.location > 0 { rect = bounds(CFRange(location: range.location - 1, length: 1)) }
        guard let r = rect else { return nil }
        return toCocoa(r)
    }

    /// The text of the focused field up to the caret, when the caret sits at the very end of the text
    /// (so deleting backwards from it is safe). Only the last line is returned. nil when unknown.
    static func focusedLineAtEnd() -> String? {
        guard let element = focusedElement() else { Log.write("ax: no focused element"); return nil }
        guard let valueRef = axValue(element, kAXValueAttribute), let text = valueRef as? String, !text.isEmpty else {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            Log.write("ax: no text value (role \((roleRef as? String) ?? "?"))")
            return nil
        }
        guard let rangeRef = axValue(element, kAXSelectedTextRangeAttribute), CFGetTypeID(rangeRef) == AXValueGetTypeID() else {
            Log.write("ax: no selection range")
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range), range.length == 0 else { Log.write("ax: selection not collapsed"); return nil }
        let utf16 = Array(text.utf16)
        // Some fields report a trailing newline that is not really there; tolerate it.
        var end = utf16.count
        while end > 0, utf16[end - 1] == 0x0A || utf16[end - 1] == 0x0D { end -= 1 }
        guard range.location == end || range.location == utf16.count else {
            Log.write("ax: caret not at end (\(range.location)/\(utf16.count))")
            return nil
        }
        var start = end
        while start > 0, utf16[start - 1] != 0x0A, utf16[start - 1] != 0x0D { start -= 1 }
        return String(utf16CodeUnits: Array(utf16[start..<end]), count: end - start)
    }

    private static func focusedWindowBottomCenter() -> NSPoint? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.15)
        guard let winRef = axValue(appElement, kAXFocusedWindowAttribute), CFGetTypeID(winRef) == AXUIElementGetTypeID() else { return nil }
        let window = winRef as! AXUIElement
        guard let posRef = axValue(window, kAXPositionAttribute), let sizeRef = axValue(window, kAXSizeAttribute) else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &pos), AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        guard let primary = NSScreen.screens.first else { return nil }
        return NSPoint(x: pos.x + size.width / 2 - 150, y: primary.frame.height - (pos.y + size.height) + 80)
    }
}
