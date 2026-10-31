import Cocoa
import Carbon.HIToolbox

/// Global key tap: buffers what is typed, asks the Detector, and on Tab replaces the text.
final class KeyMonitor {
    static let magicTag: Int64 = 0x5448_4149 // "THAI": marks events we post ourselves

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var buffer = ""
    private var suggestion: Suggestion?
    private let panel = SuggestionPanel()
    /// The layout popup waits for a pause in typing instead of redrawing on every key.
    private var showWork: DispatchWorkItem?
    private static let showDelay: TimeInterval = 0.5
    private let detector = Detector.shared
    let llm = LLMSuggester()
    private var frontBundleID: String? = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

    /// After an LLM fix with alternatives is applied, repeated Tab swaps the inserted text for the next option.
    private struct Cycle {
        var options: [String]
        var index: Int
        var insertedScalars: Int
        var expires: Date
    }
    private var cycle: Cycle?
    private static let cycleWindow: TimeInterval = 6

    var isEnabled = true { didSet { if !isEnabled { reset() } } }
    var switchLayoutAfterFix = true
    /// Apply a confident wrong-layout fix by itself when a word ends (space) or the line is sent (Enter),
    /// however short the word: this is what lets the user type on one layout and never switch.
    var autoFixLayout = true

    /// The last automatic fix, so Esc can put the original keystrokes back.
    private struct AutoFix {
        var original: String
        var replacementScalars: Int
        var expires: Date
    }
    private var lastAuto: AutoFix?
    private static let undoWindow: TimeInterval = 4
    var excludedBundleIDs: Set<String> = []
    var onFix: ((Suggestion) -> Void)?

    /// Hold back Enter until Claude has checked the last sentence; then send, or offer the fix first.
    var holdOnEnter = true
    /// Also ask Claude quietly whenever typing pauses (off: the whole sentence is checked only at Enter).
    var checkWhileTyping = false
    private struct Hold {
        let keyCode: Int
        let flags: CGEventFlags
        let segment: String
        let started: Date
        var decided = false
        var decidedAt: Date?
    }
    /// Enter pressed right as the fix appears was meant for the waiting state, not for "send as typed".
    private static let decisionGrace: TimeInterval = 1.5
    private var hold: Hold?
    private static let holdTimeout: TimeInterval = 10
    private static let holdMinimumKeys = 4

    init() {
        llm.onResult = { [weak self] original, reply in
            guard let self = self else { return }
            // Emoji mode: nothing to fix but the emojis — add them and carry on without asking.
            if self.llm.emojiMode, let h = self.hold, h.segment == original,
               LLMSuggester.onlyAddsEmoji(original: original, fixed: reply.fixed) {
                let all = Array(self.buffer.unicodeScalars)
                var spaces = 0
                while spaces < all.count, all[all.count - 1 - spaces] == " " { spaces += 1 }
                let trailing = String(repeating: " ", count: spaces)
                let s = Suggestion(scalarCount: original.unicodeScalars.count + trailing.unicodeScalars.count,
                                   replacement: reply.fixed, direction: nil, source: .llm)
                if self.buffer.hasSuffix(original + trailing) {
                    Log.write("emoji added, sending")
                    self.apply(s, automatic: true)
                    self.releaseHold(send: true, showCheck: true)
                    return
                }
            }
            self.showLLMResult(original: original, reply: reply)
        }
        llm.onStarted = { [weak self] _ in
            guard let self = self, self.suggestion == nil, self.cycle == nil else { return }
            self.panel.showLoading(near: Caret.anchorPoint())
        }
        llm.onFinished = { [weak self] original, reply in
            guard let self = self else { return }
            if let h = self.hold, h.segment == original {
                if reply.fixed == original {
                    Log.write("hold released: nothing to fix")
                    self.releaseHold(send: true, showCheck: true)
                }
                return
            }
            if reply.fixed == original, self.panel.isLoading { self.panel.hide() }
        }
        llm.onFailed = { [weak self] original in
            guard let self = self, let h = self.hold, h.segment == original else { return }
            Log.write("hold: check failed")
            self.llm.markChecked(original)
            self.hold = nil
            self.panel.show(options: ["ตรวจไม่สำเร็จ"], selected: 0, hint: "↩ ส่ง", near: Caret.anchorPoint())
        }
    }

    /// End the hold: optionally deliver the Enter that was held back.
    private func releaseHold(send: Bool, showCheck: Bool = false) {
        guard let h = hold else { return }
        hold = nil
        if showCheck {
            panel.showCheck(near: Caret.anchorPoint())
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self = self, self.suggestion == nil, self.hold == nil, !self.panel.isLoading else { return }
                self.panel.hide()
            }
        } else {
            panel.hide()
        }
        if send {
            let source = CGEventSource(stateID: .combinedSessionState)
            postKey(h.keyCode, source, flags: h.flags)
        }
        let keepPanel = showCheck
        if keepPanel {
            // reset() would hide the check mark; clear state by hand.
            showWork?.cancel()
            buffer = ""
            suggestion = nil
            cycle = nil
            lastAuto = nil
            llm.cancel()
        } else {
            reset()
        }
    }

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.frontBundleID = app?.bundleIdentifier
            self?.reset()
        }
        return true
    }

    func reset() {
        showWork?.cancel()
        buffer = ""
        suggestion = nil
        cycle = nil
        lastAuto = nil
        hold = nil
        llm.cancel()
        panel.hide()
    }

    // MARK: Event handling

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return passThrough
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.magicTag { return passThrough }
        guard type == .keyDown else { reset(); return passThrough }
        guard isEnabled else { return passThrough }
        if let id = frontBundleID, excludedBundleIDs.contains(id) { return passThrough }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let modified = flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate)

        if keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter {
            // Ctrl+Enter: send exactly what was typed, no check, no fix (passwords, links, code).
            if flags.contains(.maskControl) && !flags.contains(.maskCommand) && !flags.contains(.maskAlternate) {
                Log.write("enter sent: ctrl bypass")
                hold = nil
                suggestion = nil
                panel.hide()
                let source = CGEventSource(stateID: .combinedSessionState)
                postKey(keyCode, source, flags: flags.subtracting(.maskControl))
                reset()
                return nil
            }
            // Shift/Cmd/Option + Enter is a new line inside the message: no hold, no check,
            // just finish a confident layout fix if one is pending and start a fresh line.
            if modified || flags.contains(.maskShift) {
                return newline(keyCode: keyCode, flags: flags, passThrough: passThrough)
            }
        }
        if modified {
            reset()
            return passThrough
        }

        if hold != nil, ![kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_Escape].contains(keyCode) {
            Log.write("hold dropped: typing continued")
            hold = nil
            panel.hide()
        }

        if let c = cycle {
            if Date() > c.expires {
                cycle = nil
                panel.hide()
            } else if keyCode == kVK_Tab && !flags.contains(.maskShift) {
                cycleNext()
                return nil
            } else {
                cycle = nil
                panel.hide()
            }
        }

        switch keyCode {
        case kVK_Tab:
            if let s = suggestion, !flags.contains(.maskShift) {
                if hold != nil {
                    // Fix the text in place; the user sends with Enter when they are happy with it.
                    apply(s)
                    hold = nil
                    llm.markChecked(LLMSuggester.segment(of: buffer))
                    Log.write("hold: fix applied, waiting for Enter")
                    if cycle == nil {
                        panel.show(options: ["แก้แล้ว"], selected: 0, hint: "↩ ส่ง", near: Caret.anchorPoint())
                        let shownBuffer = buffer
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                            guard let self = self, self.buffer == shownBuffer, self.suggestion == nil, self.cycle == nil else { return }
                            self.panel.hide()
                        }
                    }
                    return nil
                }
                apply(s)
                return nil // swallow the Tab
            }
            if hold != nil { return nil }
            reset()
            return passThrough

        case kVK_Delete:
            if !buffer.unicodeScalars.isEmpty {
                buffer.unicodeScalars.removeLast()
                evaluate()
            }
            return passThrough

        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let h = hold {
                if h.decided {
                    if let at = h.decidedAt, Date().timeIntervalSince(at) < Self.decisionGrace {
                        Log.write("enter ignored: fix just appeared")
                        return nil
                    }
                    // The fix is on screen and the user chose to send as typed.
                    Log.write("hold released by user: sent as typed")
                    releaseHold(send: true)
                } else {
                    // Still checking: extra Enters just wait. Esc cancels.
                    Log.write("enter ignored: still checking")
                }
                return nil
            }
            var fixedFirst = false
            if let s = autoFixCandidate() {
                Log.write("auto layout fix on enter (\(s.scalarCount) keys)")
                apply(s, automatic: true)
                fixedFirst = true
            }
            // A fix from the quiet check is on screen: do not send over it. Tab fixes, Enter again sends.
            if let s = suggestion, s.source == .llm, holdOnEnter {
                hold = Hold(keyCode: keyCode, flags: flags, segment: LLMSuggester.segment(of: buffer), started: Date(), decided: true, decidedAt: Date())
                Log.write("enter held: a fix is showing")
                panel.show(options: [s.replacement.trimmingCharacters(in: .whitespaces)], selected: 0,
                           hint: "⇥ แก้ · ↩ ส่งตามเดิม · esc", near: Caret.anchorPoint())
                return nil
            }
            if holdOnEnter, llm.isReady {
                // The buffer forgets text after a mouse click or arrow key; the field itself does not.
                let bufferLine = LLMSuggester.segment(of: buffer)
                if let line = Caret.focusedLineAtEnd() {
                    let axLine = LLMSuggester.segment(of: line)
                    if axLine != bufferLine, axLine.unicodeScalars.count > bufferLine.unicodeScalars.count {
                        Log.write("enter: using field text (\(axLine.unicodeScalars.count) keys) instead of buffer (\(bufferLine.unicodeScalars.count))")
                        buffer = line
                    }
                }
                let segment = LLMSuggester.segment(of: buffer)
                if segment.unicodeScalars.count < Self.holdMinimumKeys {
                    Log.write("enter sent: too short (\(segment.unicodeScalars.count) keys)")
                } else if llm.isChecked(segment) {
                    Log.write("enter sent: already checked")
                }
                if segment.unicodeScalars.count >= Self.holdMinimumKeys, !llm.isChecked(segment) {
                    hold = Hold(keyCode: keyCode, flags: flags, segment: segment, started: Date())
                    llm.checkNow(buffer)
                    Log.write("hold enter (\(segment.unicodeScalars.count) keys)")
                    panel.showLoading(near: Caret.anchorPoint())
                    let startedAt = hold!.started
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdTimeout) { [weak self] in
                        guard let self = self, let h = self.hold, h.started == startedAt, !h.decided else { return }
                        Log.write("hold timeout")
                        self.llm.markChecked(h.segment)
                        self.hold = nil
                        self.panel.show(options: ["ตรวจไม่ทัน"], selected: 0, hint: "↩ ส่ง", near: Caret.anchorPoint())
                    }
                    return nil
                }
            }
            if !holdOnEnter { Log.write("enter sent: hold off") }
            else if !llm.isReady { Log.write("enter sent: llm not ready") }
            if fixedFirst {
                // Deliver the Enter after the replacement, in order.
                let source = CGEventSource(stateID: .combinedSessionState)
                postKey(keyCode, source, flags: flags)
                reset()
                return nil
            }
            reset()
            return passThrough

        case kVK_Escape:
            if hold != nil {
                Log.write("hold cancelled by user")
                hold = nil
                suggestion = nil
                panel.hide()
                return nil
            }
            if let auto = lastAuto, Date() <= auto.expires {
                undoAutoFix(auto)
                return nil
            }
            reset()
            return passThrough

        case kVK_ForwardDelete,
             kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown:
            reset()
            return passThrough

        default:
            var length = 0
            var chars = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &chars)
            guard length > 0 else { return passThrough }
            let typed = String(utf16CodeUnits: chars, count: length)
            for sc in typed.unicodeScalars where sc.value < 0x20 || (0xF700...0xF8FF).contains(sc.value) {
                reset()
                return passThrough
            }
            buffer.unicodeScalars.append(contentsOf: typed.unicodeScalars)
            trimBuffer()
            evaluate()
            if typed == " " {
                if let s = autoFixCandidate() {
                    Log.write("auto layout fix on space (\(s.scalarCount) keys)")
                    apply(s, automatic: true)
                } else if autoFixLayout, let s = thaiTypoCandidate() {
                    Log.write("auto thai typo fix on space (\(s.scalarCount) keys)")
                    apply(s, automatic: true)
                }
            }
            return passThrough
        }
    }

    private func newline(keyCode: Int, flags: CGEventFlags, passThrough: Unmanaged<CGEvent>) -> Unmanaged<CGEvent>? {
        var fixedFirst = false
        if let s = autoFixCandidate() {
            Log.write("auto layout fix on newline (\(s.scalarCount) keys)")
            apply(s, automatic: true)
            fixedFirst = true
        }
        hold = nil
        suggestion = nil
        cycle = nil
        llm.cancel()
        panel.hide()
        buffer.unicodeScalars.append("\n")
        trimBuffer()
        if fixedFirst {
            let source = CGEventSource(stateID: .combinedSessionState)
            postKey(keyCode, source, flags: flags)
            return nil
        }
        return passThrough
    }

    /// The word just finished (buffer ends with one space), spelled with a classic Thai slip.
    private func thaiTypoCandidate() -> Suggestion? {
        let scalars = Array(buffer.unicodeScalars)
        guard scalars.last == " ", scalars.count >= 2 else { return nil }
        var start = scalars.count - 1
        while start > 0, scalars[start - 1] != " ", scalars[start - 1] != "\n" { start -= 1 }
        let word = String(String.UnicodeScalarView(scalars[start..<(scalars.count - 1)]))
        guard !word.isEmpty, !detector.ignoredWords.contains(word), let fixed = ThaiTypos.fix(word) else { return nil }
        return Suggestion(scalarCount: word.unicodeScalars.count + 1, replacement: fixed + " ", direction: nil, source: .layout)
    }

    /// The current layout suggestion, if it is long enough to be applied without asking.
    private func autoFixCandidate() -> Suggestion? {
        guard autoFixLayout, let s = suggestion, s.source == .layout else { return nil }
        return s
    }

    /// Esc shortly after an automatic fix: put the original keystrokes back and stop flagging those words.
    private func undoAutoFix(_ auto: AutoFix) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<auto.replacementScalars { postKey(kVK_Delete, source) }
        postText(auto.original, source)
        var scalars = Array(buffer.unicodeScalars)
        scalars.removeLast(min(auto.replacementScalars, scalars.count))
        buffer = String(String.UnicodeScalarView(scalars)) + auto.original
        for word in auto.original.split(separator: " ") where !word.isEmpty {
            detector.ignoredWords.insert(String(word))
        }
        lastAuto = nil
        suggestion = nil
        panel.hide()
        Log.write("auto fix undone (\(auto.replacementScalars) keys)")
    }

    private func trimBuffer() {
        let scalars = buffer.unicodeScalars
        guard scalars.count > 300 else { return }
        var idx = scalars.index(scalars.endIndex, offsetBy: -200)
        while idx < scalars.endIndex, scalars[idx] != " ", scalars[idx] != "\n" { idx = scalars.index(after: idx) }
        buffer = String(scalars[idx...])
    }

    private func evaluate() {
        let next = detector.suggest(buffer: buffer)
        if next == nil {
            // Nothing layout-related: let the LLM layer look after a pause.
            llm.textChanged(buffer)
            if suggestion?.source == .llm { suggestion = nil; panel.hide() }
            else if suggestion != nil { suggestion = nil; panel.hide() }
            return
        }
        llm.cancel()
        guard next != suggestion || !panel.isVisible else { return }
        suggestion = next
        if let s = next {
            Log.write("layout suggestion (\(s.scalarCount) keys)")
            panel.show(text: s.replacement, near: Caret.anchorPoint())
        }
    }

    private func showLLMResult(original: String, reply: LLMSuggester.Reply) {
        // The user may have typed on since the request went out: the segment must still end the buffer
        // (ignoring trailing spaces), or the result is stale.
        guard cycle == nil else { return }
        var scalars = Array(buffer.unicodeScalars)
        var trailing = ""
        while let last = scalars.last, last == " " { scalars.removeLast(); trailing.append(" ") }
        let orig = Array(original.unicodeScalars)
        guard orig.count <= scalars.count, Array(scalars[(scalars.count - orig.count)...]) == orig else {
            Log.write("llm result stale, dropped")
            return
        }
        let options = reply.options.map { $0 + trailing }
        let s = Suggestion(scalarCount: orig.count + trailing.unicodeScalars.count,
                           replacement: options[0], direction: nil, source: .llm,
                           alternatives: Array(options.dropFirst()))
        suggestion = s
        Log.write("llm suggestion (\(s.scalarCount) keys, \(options.count) options)")
        if hold != nil, hold!.segment == original {
            hold!.decided = true
            hold!.decidedAt = Date()
            panel.show(options: reply.options, selected: 0,
                       hint: options.count > 1 ? "⇥ แก้ · ⇥⇥ สลับ · ↩ ส่งตามเดิม" : "⇥ แก้ · ↩ ส่งตามเดิม · esc",
                       near: Caret.anchorPoint(), original: original)
            return
        }
        panel.show(options: reply.options, selected: 0,
                   hint: options.count > 1 ? "⇥ แก้ · ⇥⇥ สลับ" : "⇥ แก้", near: Caret.anchorPoint(), original: original)
    }

    private func cycleNext() {
        guard var c = cycle else { return }
        let next = (c.index + 1) % c.options.count
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<c.insertedScalars { postKey(kVK_Delete, source) }
        postText(c.options[next], source)
        var scalars = Array(buffer.unicodeScalars)
        scalars.removeLast(min(c.insertedScalars, scalars.count))
        buffer = String(String.UnicodeScalarView(scalars)) + c.options[next]
        c.index = next
        c.insertedScalars = c.options[next].unicodeScalars.count
        c.expires = Date().addingTimeInterval(Self.cycleWindow)
        cycle = c
        llm.markChecked(LLMSuggester.segment(of: buffer))
        Log.write("llm cycle -> option \(next + 1)")
        panel.show(options: c.options.map { $0.trimmingCharacters(in: .whitespaces) }, selected: next,
                   hint: "⇥ สลับ · ↩ ส่ง", near: Caret.anchorPoint())
        scheduleCycleExpiry()
    }

    private func scheduleCycleExpiry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.cycleWindow + 0.2) { [weak self] in
            guard let self = self, let c = self.cycle, Date() > c.expires else { return }
            self.cycle = nil
            self.panel.hide()
        }
    }

    // MARK: Applying a fix

    private func apply(_ s: Suggestion, automatic: Bool = false) {
        Log.write("applied \(s.source == .llm ? "llm" : "layout") fix (\(s.scalarCount) keys)\(automatic ? " auto" : "")")
        panel.hide()
        suggestion = nil
        llm.cancel()
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<s.scalarCount { postKey(kVK_Delete, source) }
        postText(s.replacement, source)

        var scalars = Array(buffer.unicodeScalars)
        let original = String(String.UnicodeScalarView(scalars.suffix(min(s.scalarCount, scalars.count))))
        scalars.removeLast(min(s.scalarCount, scalars.count))
        buffer = String(String.UnicodeScalarView(scalars)) + s.replacement
        lastAuto = automatic
            ? AutoFix(original: original, replacementScalars: s.replacement.unicodeScalars.count,
                      expires: Date().addingTimeInterval(Self.undoWindow))
            : nil

        if switchLayoutAfterFix, let direction = s.direction {
            InputSource.select(thai: direction == .englishToThai)
        }
        if s.source == .llm, !s.alternatives.isEmpty {
            let options = [s.replacement] + s.alternatives
            cycle = Cycle(options: options, index: 0, insertedScalars: s.replacement.unicodeScalars.count,
                          expires: Date().addingTimeInterval(Self.cycleWindow))
            panel.show(options: options.map { $0.trimmingCharacters(in: .whitespaces) }, selected: 0,
                       hint: "⇥ สลับ · ↩ ส่ง", near: Caret.anchorPoint())
            scheduleCycleExpiry()
        }
        onFix?(s)
    }

    private func tag(_ e: CGEvent) {
        e.flags = []
        e.setIntegerValueField(.eventSourceUserData, value: Self.magicTag)
    }

    private func postKey(_ code: Int, _ source: CGEventSource?, flags: CGEventFlags = []) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: false) else { return }
        tag(down); down.flags = flags; down.post(tap: .cghidEventTap)
        tag(up); up.flags = flags; up.post(tap: .cghidEventTap)
    }

    private func postText(_ text: String, _ source: CGEventSource?) {
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 20, units.count)])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
            for e in [down, up] {
                chunk.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                tag(e)
                e.post(tap: .cghidEventTap)
            }
            i += 20
        }
    }
}
