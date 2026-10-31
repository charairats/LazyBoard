import Cocoa
import ApplicationServices

/// Finds where to put the popup: text caret (via Accessibility), else the focused text field,
/// else focused window, else mouse.
enum Caret {
    static func anchorPoint() -> NSPoint {
        guard let app = NSWorkspace.shared.frontmostApplication else { return NSEvent.mouseLocation }
        let (point, source) = locate(in: app)
        let summary = "\(app.bundleIdentifier ?? "app") via \(source)"
        if summary != lastSummary {
            lastSummary = summary
            Log.write("anchor: \(summary)")
        }
        return point
    }

    /// Switch on the accessibility tree of a newly active app, so the first popup there can already find the caret.
    static func prepare(_ app: NSRunningApplication) {
        _ = focusedElement(in: app)
    }

    /// `--caret`: log how the caret is found in every running app (never logs text).
    static func probe() {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let element = focusedElement(in: app)
            let role = element.flatMap { axValue($0, kAXRoleAttribute) as? String } ?? "none"
            let (point, source) = locate(in: app)
            print("\(app.bundleIdentifier ?? "app"): role \(role), via \(source) at \(Int(point.x)),\(Int(point.y))")        }
    }

    private static var lastSummary = ""

    private static func locate(in app: NSRunningApplication) -> (NSPoint, String) {
        if let element = focusedElement(in: app) {
            let field = frame(of: element)
            if let p = caretBottomLeft(element, field: field) { return (p, "caret") }
            if let p = caretFromMarkers(element, field: field) { return (p, "marker") }
            if let f = field, isText(element) {
                // Above a one-line field; inside the bottom edge of a tall one, closer to where typing happens.
                let spot = f.height <= 60 ? f : CGRect(x: f.minX, y: f.maxY, width: f.width, height: 0)
                if let p = toCocoa(spot), onScreen(spot) { return (p, "field") }
            }
        }
        if let p = focusedWindowBottomCenter(in: app) { return (p, "window") }
        return (NSEvent.mouseLocation, "mouse")
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref
    }

    /// Apps already asked to switch their accessibility tree on (Electron/Chromium build it lazily).
    private static var enabledPIDs = Set<pid_t>()

    private static func focusedElement() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return focusedElementOnce(in: nil) }
        return focusedElement(in: app)
    }

    private static func focusedElement(in app: NSRunningApplication) -> AXUIElement? {
        let element = focusedElementOnce(in: app)
        if let e = element, isText(e) { return e }
        // Electron/Chromium apps expose nothing, or only a container such as AXSplitGroup, until a client asks.
        guard !enabledPIDs.contains(app.processIdentifier) else { return element }
        enabledPIDs.insert(app.processIdentifier)
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        // Native apps ignore the attribute above; this one can disturb their windows, so only when nothing is focused.
        if element == nil { AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
        Log.write("ax: asked \(app.bundleIdentifier ?? "app") to enable accessibility")
        return focusedElementOnce(in: app) ?? element
    }

    private static func focusedElementOnce(in app: NSRunningApplication?) -> AXUIElement? {
        if app == nil || app?.isActive == true {
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.15)
            if let ref = axValue(system, kAXFocusedUIElementAttribute), CFGetTypeID(ref) == AXUIElementGetTypeID() {
                let element = ref as! AXUIElement
                AXUIElementSetMessagingTimeout(element, 0.15)
                return element
            }
        }
        // Fall back to the app's own focused element.
        guard let app = app else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.15)
        guard let ref = axValue(appElement, kAXFocusedUIElementAttribute), CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        let element = ref as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.15)
        return element
    }

    private static func isText(_ element: AXUIElement) -> Bool {
        if let ref = axValue(element, kAXSelectedTextRangeAttribute), CFGetTypeID(ref) == AXValueGetTypeID() { return true }
        return axValue(element, "AXSelectedTextMarkerRange") != nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let posRef = axValue(element, kAXPositionAttribute), CFGetTypeID(posRef) == AXValueGetTypeID(),
              let sizeRef = axValue(element, kAXSizeAttribute), CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &pos), AXValueGetValue(sizeRef as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: pos, size: size)
    }

    private static func toCocoa(_ rect: CGRect) -> NSPoint? {
        guard let primary = NSScreen.screens.first else { return nil }
        return NSPoint(x: rect.minX, y: primary.frame.height - rect.minY)
    }

    private static func onScreen(_ rect: CGRect) -> Bool {
        guard let p = toCocoa(rect) else { return false }
        return NSScreen.screens.contains { $0.frame.insetBy(dx: -1, dy: -1).contains(p) }
    }

    /// Some apps answer with a blank rect at the screen corner or the whole field; neither is a caret.
    private static func plausible(_ rect: CGRect, field: CGRect?) -> Bool {
        guard rect.height > 0, rect.height < 120, onScreen(rect) else { return false }
        guard let field = field else { return true }
        return field.insetBy(dx: -8, dy: -8).contains(CGPoint(x: rect.minX, y: rect.midY))
    }

    private static func caretBottomLeft(_ element: AXUIElement, field: CGRect?) -> NSPoint? {
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
            guard AXValueGetValue(ref as! AXValue, .cgRect, &rect), plausible(rect, field: field) else { return nil }
            return rect
        }

        if let r = bounds(CFRange(location: range.location, length: max(range.length, 1))) { return toCocoa(r) }
        if range.length == 0, let r = bounds(CFRange(location: range.location, length: 0)) { return toCocoa(r) }
        // At the very end of the text only the character before the caret has a position: the caret is on its right.
        guard range.location > 0, let r = bounds(CFRange(location: range.location - 1, length: 1)) else { return nil }
        return toCocoa(CGRect(x: r.maxX, y: r.minY, width: 0, height: r.height))
    }

    /// WebKit and Chromium web content can answer through text markers when plain ranges fail.
    private static func caretFromMarkers(_ element: AXUIElement, field: CGRect?) -> NSPoint? {
        guard let marker = axValue(element, "AXSelectedTextMarkerRange") else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, "AXBoundsForTextMarkerRange" as CFString, marker, &ref) == .success,
              let ref = ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(ref as! AXValue, .cgRect, &rect), plausible(rect, field: field) else { return nil }
        return toCocoa(CGRect(x: rect.maxX, y: rect.minY, width: 0, height: rect.height))
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

    private static func focusedWindowBottomCenter(in app: NSRunningApplication) -> NSPoint? {
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
