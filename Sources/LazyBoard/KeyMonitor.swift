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
        var original: String?
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
        var bufferAfter: String
    }
    private var lastAuto: AutoFix?
    private static let undoWindow: TimeInterval = 4
    var excludedBundleIDs: Set<String> = []
    var onFix: ((Suggestion) -> Void)?

    /// Hold back Enter until Claude has checked the last sentence; then send, or offer the fix first.
    var holdOnEnter = true
    /// Which key asks for the check: off, Enter sends as typed and Ctrl+Enter checks first;
    /// on, Enter checks first (only when a word looks off) and Ctrl+Enter sends as typed.
    var enterChecks = false
    /// Also ask Claude quietly whenever typing pauses (off: the whole sentence is checked only at Enter).
    var checkWhileTyping = false
    /// A word that looks off (mixed scripts, ภาาษา) just ended: the next space sends the line to the fast model quietly.
    private var quietCheckDue = false
    /// The segment of the quiet check in flight: no loading dots for it.
    private var quietSegment: String?
    /// Claude's fix without the text typed after the checked segment, so it can follow the typing.
    private var llmBase: (original: String, options: [String])?
    private struct Hold {
        let keyCode: Int
        let flags: CGEventFlags
        let segment: String
        var started: Date
        var decided = false
        var decidedAt: Date?
        /// What the local check doubted, to compare with what Claude did.
        var doubts: [(word: String, why: LLMSuggester.Doubt)] = []
        /// The fast model found nothing and the stronger one is checking.
        var escalated = false
    }
    /// Enter pressed right as the fix appears was meant for the waiting state, not for "send as typed".
    private static let decisionGrace: TimeInterval = 1.5
    private var hold: Hold?
    /// Claude usually answers in about 4 seconds but can take 13: past this the writer may send without waiting.
    private static let sendAnywayAfter: TimeInterval = 3
    static func enterSendsWhileChecking(elapsed: TimeInterval) -> Bool { elapsed >= sendAnywayAfter }
    /// Opus usually answers in 5 to 15 seconds.
    private static let strongHintAfter: TimeInterval = 10
    private var lastTabFix = Date.distantPast
    /// A second Tab this soon after a fix is a bounce or a double press, not a choice to swap it for another option.
    private static let tabSettle: TimeInterval = 0.5
    /// A key held down keeps repeating for as long as the swap window stays open, so repeats never count.
    static func tabIsAccidental(sinceFix: TimeInterval, repeated: Bool) -> Bool {
        sinceFix < tabSettle || (repeated && sinceFix < cycleWindow)
    }
    /// A long message takes longer to come back in full, and Opus takes up to 15 seconds where Haiku takes 5.
    private static func holdTimeout(forKeys keys: Int, strong: Bool) -> TimeInterval { (strong ? 30 : 10) + Double(keys) / 50 }
    /// Same floor as LLMSuggester.checkNow: a shorter line is never checked, so holding it would only wait for the timeout.
    private static let holdMinimumKeys = 6

    init() {
        llm.onResult = { [weak self] original, reply in
            guard let self = self else { return }
            // Emoji mode: nothing to fix but the emojis — add them and carry on without asking.
            if self.llm.emojiMode, let h = self.hold, h.segment == original,
               LLMSuggester.onlyAddsEmoji(original: original, fixed: reply.fixed) {
                let trailing = self.trailingBlanks()
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
        llm.onStarted = { [weak self] segment in
            guard let self = self, segment != self.quietSegment, self.suggestion == nil, self.cycle == nil, !self.panel.isLoading else { return }
            self.panel.showLoading(near: Caret.anchorPoint())
        }
        llm.onFinished = { [weak self] original, reply in
            guard let self = self else { return }
            if let h = self.hold, h.segment == original {
                if h.escalated { Log.write(reply.fixed == original ? "cascade: strong agrees" : "cascade: strong fixed it") }
                self.recordCheck(h, reply)
                if reply.fixed == original {
                    Log.write("hold released: nothing to fix")
                    self.releaseHold(send: true, showCheck: true)
                }
                return
            }
            if reply.fixed == original, self.panel.isLoading { self.panel.hide() }
        }
        panel.onPick = { [weak self] index in self?.pick(index) }
        // A key badge clicked works as that key pressed: the event goes through this tap like a real one.
        panel.onKey = { code in
            let source = CGEventSource(stateID: .combinedSessionState)
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down) else { continue }
                e.flags = []
                e.post(tap: .cghidEventTap)
            }
        }
        llm.onEscalated = { [weak self] original in
            guard let self = self, let h = self.hold, h.segment == original else { return }
            self.escalated(h)
        }
        llm.onFailed = { [weak self] original in
            guard let self = self, let h = self.hold, h.segment == original else { return }
            Log.write("hold: check failed")
            self.llm.markChecked(original)
            self.hold = nil
            self.panel.show(options: ["Couldn't check"], selected: 0, hint: "↩ send", near: Caret.anchorPoint())
        }
    }

    /// Tab, or a click on the fix: put it in the text. A held message then waits for Enter.
    private func accept(_ s: Suggestion) {
        lastTabFix = Date()
        guard let h = hold else { apply(s); return }
        // Fix the text in place; the user sends with Enter when they are happy with it.
        apply(s)
        hold = nil
        llm.markChecked(LLMSuggester.segment(of: buffer))
        Log.write(String(format: "hold: fix applied after %.1fs, waiting for Enter", Self.sinceDecided(h)))
        guard cycle == nil else { return }
        panel.show(options: ["Fixed"], selected: 0, hint: "↩ send", near: Caret.anchorPoint())
        let shownBuffer = buffer
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self = self, self.buffer == shownBuffer, self.suggestion == nil, self.cycle == nil else { return }
            self.panel.hide()
        }
    }

    /// A click on one of the offered fixes: that one goes in, the others stay a Tab away.
    private func pick(_ index: Int) {
        guard let s = suggestion else { return }
        var options = [s.replacement] + s.alternatives
        guard options.indices.contains(index) else { return }
        let chosen = options.remove(at: index)
        Log.write("fix clicked (option \(index + 1))")
        accept(Suggestion(scalarCount: s.scalarCount, replacement: chosen, direction: s.direction, source: s.source,
                          alternatives: options, original: s.original))
    }

    /// After a few seconds the writer may send without waiting; much later the check is given up.
    private func scheduleHoldTimers() {
        guard let h = hold else { return }
        let startedAt = h.started
        // Enter sends after 3 seconds either way; while Opus is checking, the hint waits longer so the fix,
        // not the hint, is usually what appears first.
        DispatchQueue.main.asyncAfter(deadline: .now() + (h.escalated ? Self.strongHintAfter : Self.sendAnywayAfter)) { [weak self] in
            guard let self = self, let h = self.hold, h.started == startedAt, !h.decided, self.panel.isLoading else { return }
            self.panel.showLoading(near: Caret.anchorPoint(), hint: "↩ send now · esc", glow: h.escalated)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdTimeout(forKeys: h.segment.unicodeScalars.count, strong: h.escalated)) { [weak self] in
            guard let self = self, let h = self.hold, h.started == startedAt, !h.decided else { return }
            Log.write("hold timeout")
            self.llm.markChecked(h.segment)
            self.hold = nil
            self.panel.show(options: ["No answer in time"], selected: 0, hint: "↩ send", near: Caret.anchorPoint())
        }
    }

    /// The fast model was unsure: keep holding, glowing, while the stronger one has its turn. The timers start over.
    private func escalated(_ h: Hold) {
        var next = h
        next.escalated = true
        next.started = Date()
        hold = next
        panel.showLoading(near: Caret.anchorPoint(), glow: true)
        scheduleHoldTimers()
    }

    /// Seconds the fix has been on screen.
    private static func sinceDecided(_ h: Hold) -> TimeInterval { Date().timeIntervalSince(h.decidedAt ?? Date()) }

    /// What Claude made of a held message: the shape of its fix for the log, and the words for tuning.
    private func recordCheck(_ h: Hold, _ reply: LLMSuggester.Reply) {
        let pairs = WordLog.changedPairs(from: h.segment, to: reply.fixed)
        if !pairs.isEmpty { Log.write("fix shape: \(pairs.count) changes (\(WordLog.shapes(pairs)))") }
        guard !llm.rewrites else { return }
        for p in pairs { WordLog.write(.fixed, why: WordLog.shape(p), from: p.from, to: p.to) }
        for d in h.doubts where !pairs.contains(where: { $0.from.contains(d.word) }) {
            WordLog.write(.kept, why: d.why.rawValue, from: d.word)
        }
    }

    /// Sent unchecked: ask Claude anyway, after the fact, to count what the local check lets through.
    private func shadowCheck(_ segment: String) {
        llm.shadowCheck(segment) { reply in
            let pairs = WordLog.changedPairs(from: segment, to: reply.fixed)
            guard !pairs.isEmpty else { Log.write("shadow: claude agrees"); return }
            Log.write("shadow: claude would change \(pairs.count) (\(WordLog.shapes(pairs)))")
            for p in pairs { WordLog.write(.missed, why: WordLog.shape(p), from: p.from, to: p.to) }
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
            if let app = app { Caret.prepare(app) }
        }
        return true
    }

    func reset() {
        if hold != nil { Log.write("hold dropped: click, shortcut or app switch") }
        showWork?.cancel()
        buffer = ""
        suggestion = nil
        cycle = nil
        lastAuto = nil
        hold = nil
        quietCheckDue = false
        quietSegment = nil
        llmBase = nil
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
        // A click on the popup is a choice made in it, not the writer leaving the text.
        if type != .keyDown, panel.contains(screenPoint: event.location) { return passThrough }
        guard type == .keyDown else { reset(); return passThrough }
        guard isEnabled else { return passThrough }
        if let id = frontBundleID, excludedBundleIDs.contains(id) { return passThrough }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        var flags = event.flags
        var modified = flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate)
        /// This Enter asks Claude to check the message before it goes.
        var review = false
        /// A plain Enter (no modifier) in Ctrl+Enter mode: it always goes out at once, never held.
        var plainEnter = false

        if keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter {
            let ctrlOnly = flags.contains(.maskControl) && !flags.contains(.maskCommand) && !flags.contains(.maskAlternate)
            if ctrlOnly && !enterChecks {
                // Ctrl+Enter asks for the check; what goes out in the end is a plain Enter.
                flags.remove(.maskControl)
                modified = false
                review = true
            } else if !modified && !flags.contains(.maskShift) {
                review = enterChecks
                plainEnter = !enterChecks
            }
            // With Enter checking, Ctrl+Enter sends exactly what was typed, no check, no fix (passwords, links, code).
            if ctrlOnly && enterChecks {
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

        if keyCode == kVK_Tab, !flags.contains(.maskShift) {
            let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if Self.tabIsAccidental(sinceFix: Date().timeIntervalSince(lastTabFix), repeated: repeated) {
                Log.write("tab ignored: right after a fix")
                if repeated { lastTabFix = Date() }
                return nil
            }
        }

        if let c = cycle {
            if Date() > c.expires {
                cycle = nil
                panel.hide()
            } else if keyCode == kVK_Tab && !flags.contains(.maskShift) {
                lastTabFix = Date()
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
                accept(s)
                return nil // swallow the Tab
            }
            if hold != nil { return nil }
            reset()
            return passThrough

        case kVK_Delete:
            // Backspace as the very next key after an automatic fix: most likely a wrong fix.
            if let auto = lastAuto, Date() <= auto.expires, buffer == auto.bufferAfter {
                Log.write("auto fix backspaced right away")
            }
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
                    Log.write(String(format: "hold released by user: sent as typed after %.1fs", Self.sinceDecided(h)))
                    releaseHold(send: true)
                } else if Self.enterSendsWhileChecking(elapsed: Date().timeIntervalSince(h.started)) {
                    Log.write("enter sent while checking")
                    releaseHold(send: true)
                } else {
                    // A double press right after the first Enter still waits. Esc cancels.
                    Log.write("enter ignored: still checking")
                }
                return nil
            }
            if Caret.keysAreNotTyping() {
                reset()
                return passThrough
            }
            var fixedFirst = false
            if let s = autoFixCandidate() {
                Log.write("auto layout fix on enter (\(s.scalarCount) keys)")
                apply(s, automatic: true)
                fixedFirst = true
            }
            // Plain Enter is never held, swallowed or slowed: Ctrl+Enter is the way to ask for a check.
            // Only a confident layout fix (above, done locally and at once) goes in first. A fix Claude
            // already showed stays a suggestion: Enter means the writer chose to send as typed.
            if plainEnter && !review {
                let segment = LLMSuggester.segment(of: buffer)
                if segment.unicodeScalars.count >= Self.holdMinimumKeys {
                    let showing = suggestion?.source == .llm ? ", fix was showing" : ""
                    Log.write("enter sent: plain (\(segment.unicodeScalars.count) keys\(showing))")
                    if llm.isReady, !llm.rewrites, !llm.isChecked(segment) {
                        // Off the key path: the check runs after the Enter is already on its way.
                        DispatchQueue.main.async { [weak self] in self?.shadowCheck(segment) }
                    }
                }
                if fixedFirst {
                    // Deliver the Enter after the replacement, in order.
                    let source = CGEventSource(stateID: .combinedSessionState)
                    postKey(keyCode, source, flags: flags)
                    reset()
                    return nil
                }
                reset()
                return passThrough
            }
            // A fix from the quiet check is on screen: do not send over it. Tab fixes, Enter again sends.
            if let s = suggestion, s.source == .llm, holdOnEnter {
                hold = Hold(keyCode: keyCode, flags: flags, segment: LLMSuggester.segment(of: buffer), started: Date(), decided: true, decidedAt: Date())
                Log.write("enter held: a fix is showing")
                showFix(original: s.original, options: [s.replacement], selected: 0, hint: "⇥ fix · ↩ send as is · esc")
                return nil
            }
            if holdOnEnter, llm.isReady, review || llm.rewrites {
                let enterStart = Date()
                // The buffer forgets text after a mouse click or arrow key; the field itself does not.
                // Only the line the caret is on: the field can hold a whole document or terminal scrollback.
                let bufferLine = LLMSuggester.lastLine(of: buffer)
                if let line = Caret.focusedLineAtEnd() {
                    if line != bufferLine, line.unicodeScalars.count > bufferLine.unicodeScalars.count {
                        Log.write("enter: using field text (\(line.unicodeScalars.count) keys) instead of buffer (\(bufferLine.unicodeScalars.count))")
                        buffer = String(buffer.unicodeScalars.dropLast(bufferLine.unicodeScalars.count)) + line
                    }
                }
                let segment = LLMSuggester.segment(of: buffer)
                var mustCheck = false
                var doubts: [(word: String, why: LLMSuggester.Doubt)] = []
                if segment.unicodeScalars.count < Self.holdMinimumKeys {
                    Log.write("enter sent: too short (\(segment.unicodeScalars.count) keys)")
                } else if llm.isChecked(segment) {
                    Log.write("enter sent: already checked")
                } else if llm.rewrites {
                    Log.write("hold why: mode")
                    mustCheck = true
                } else {
                    doubts = LLMSuggester.doubts(in: segment)
                    if !enterChecks {
                        // Ctrl+Enter: the writer asked, so Claude checks whatever the local check thinks.
                        Log.write("hold why: asked" + (doubts.isEmpty ? "" : ", \(doubts.count) doubted"))
                        mustCheck = true
                    } else if doubts.isEmpty {
                        // Every word is real: send at once, with no dots and no check mark.
                        Log.write("enter sent: looks fine (\(segment.unicodeScalars.count) keys)")
                        shadowCheck(segment)
                    } else {
                        var counts: [String: Int] = [:]
                        for d in doubts { counts[d.why.rawValue, default: 0] += 1 }
                        Log.write("hold why: " + counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
                        mustCheck = true
                    }
                }
                if mustCheck {
                    hold = Hold(keyCode: keyCode, flags: flags, segment: segment, started: Date(), doubts: doubts)
                    llm.prewarmStrong()
                    let fieldRead = Date()
                    panel.showLoading(near: Caret.anchorPoint())
                    let bubbleShown = Date()
                    llm.checkNow(buffer, escalate: review && !enterChecks)
                    Log.write("hold enter (\(segment.unicodeScalars.count) keys)")
                    if Date().timeIntervalSince(enterStart) >= 0.15 {
                        Log.write(String(format: "enter slow: field %.2fs, bubble %.2fs, request %.2fs",
                                         fieldRead.timeIntervalSince(enterStart), bubbleShown.timeIntervalSince(fieldRead), Date().timeIntervalSince(bubbleShown)))
                    }
                    scheduleHoldTimers()
                    return nil
                }
            }
            if !holdOnEnter { Log.write("enter sent: hold off") }
            else if !llm.isReady { Log.write("enter sent: llm not ready") }
            else if !review && !plainEnter {
                // Plain Enter: out it goes. Opus reads it afterwards, to count how often Ctrl+Enter would have helped.
                let segment = LLMSuggester.segment(of: buffer)
                if segment.unicodeScalars.count >= Self.holdMinimumKeys {
                    Log.write("enter sent: plain (\(segment.unicodeScalars.count) keys, \(LLMSuggester.doubts(in: segment).count) doubted)")
                    shadowCheck(segment)
                }
            }
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
            if let h = hold {
                Log.write(h.decided ? String(format: "hold cancelled by user after %.1fs", Self.sinceDecided(h)) : "hold cancelled by user")
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
            // A held key is not typing (walking in a game), and the buffer can no longer match the field.
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                reset()
                return passThrough
            }
            var length = 0
            var chars = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &chars)
            guard length > 0 else { return passThrough }
            let eventText = String(utf16CodeUnits: chars, count: length)
            let typed = InputSource.resolved(eventText: eventText,
                                             layoutText: InputSource.characters(keyCode: keyCode, flags: flags))
            if typed != eventText { Log.write("key: event and layout disagree, using layout") }
            for sc in typed.unicodeScalars where sc.value < 0x20 || (0xF700...0xF8FF).contains(sc.value) {
                reset()
                return passThrough
            }
            buffer.unicodeScalars.append(contentsOf: typed.unicodeScalars)
            trimBuffer()
            // Have Claude running by the time this line reaches Enter.
            if holdOnEnter { llm.prewarm() }
            evaluate()
            if typed == " " {
                if let s = autoFixCandidate() {
                    Log.write("auto layout fix on space (\(s.scalarCount) keys)")
                    apply(s, automatic: true)
                } else if autoFixLayout, let s = thaiTypoCandidate() {
                    Log.write("auto thai typo fix on space (\(s.scalarCount) keys)")
                    apply(s, automatic: true)
                } else {
                    quietCheckOnSpace()
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

    /// Space after a word that looks off (mixed scripts, unknown Thai such as ภาาษา): remember it, and on the
    /// next space (one more word of context) ask the fast model quietly. Its fix waits for Tab; Enter will not send over it.
    private func quietCheckOnSpace() {
        guard llm.isReady, !llm.rewrites, suggestion == nil, cycle == nil, hold == nil else { return }
        if quietCheckDue {
            quietCheckDue = false
            if let segment = llm.checkQuiet(buffer) {
                quietSegment = segment
                Log.write("quiet check on space (\(segment.unicodeScalars.count) keys)")
            }
            return
        }
        let line = String(String.UnicodeScalarView(buffer.unicodeScalars.dropLast()))
        guard !line.hasSuffix(" "), let word = line.split(whereSeparator: { $0 == " " || $0 == "\n" }).last else { return }
        let doubts = LLMSuggester.doubts(in: String(word))
        guard !doubts.isEmpty else { return }
        quietCheckDue = true
        Log.write("odd word on space (" + doubts.map { $0.why.rawValue }.joined(separator: ", ") + ")")
    }

    /// Claude's fix set against the buffer as it is now: the checked segment may be followed by more typing,
    /// which the fix carries along unchanged. Nil when the segment is no longer in the line.
    private func llmSuggestion(original: String, options base: [String]) -> Suggestion? {
        let scalars = Array(buffer.unicodeScalars)
        let orig = Array(original.unicodeScalars)
        guard orig.count <= scalars.count else { return nil }
        var start = scalars.count - orig.count
        while start >= 0, Array(scalars[start..<(start + orig.count)]) != orig { start -= 1 }
        guard start >= 0 else { return nil }
        let extra = String(String.UnicodeScalarView(scalars[(start + orig.count)...]))
        guard !extra.contains("\n") else { return nil }
        let options = base.map { $0 + extra }
        return Suggestion(scalarCount: orig.count + extra.unicodeScalars.count,
                          replacement: options[0], direction: nil, source: .llm,
                          alternatives: Array(options.dropFirst()), original: original + extra)
    }

    /// The word just finished (buffer ends with one space), spelled with a classic Thai slip.
    private func thaiTypoCandidate() -> Suggestion? {
        let scalars = Array(buffer.unicodeScalars)
        guard scalars.last == " ", scalars.count >= 2 else { return nil }
        var start = scalars.count - 1
        while start > 0, scalars[start - 1] != " ", scalars[start - 1] != "\n" { start -= 1 }
        let word = String(String.UnicodeScalarView(scalars[start..<(scalars.count - 1)]))
        guard !word.isEmpty, !detector.ignoredWords.contains(word), let fixed = ThaiTypos.fix(word),
              !Caret.keysAreNotTyping() else { return nil }
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
        let scalars = Array(buffer.unicodeScalars)
        guard scalars.count > LLMSuggester.maxSegmentKeys + 500 else { return }
        let start = LLMSuggester.wordStart(in: scalars, from: scalars.count - LLMSuggester.maxSegmentKeys)
        buffer = String(String.UnicodeScalarView(scalars[start...]))
    }

    /// The spaces and line breaks that end the buffer.
    private func trailingBlanks() -> String {
        let scalars = Array(buffer.unicodeScalars)
        var count = 0
        while count < scalars.count, [" ", "\n"].contains(scalars[scalars.count - 1 - count]) { count += 1 }
        return String(String.UnicodeScalarView(scalars.suffix(count)))
    }

    private func evaluate() {
        let next = detector.suggest(buffer: buffer)
        if next == nil {
            // Nothing layout-related: let the LLM layer look after a pause, if asked to.
            if checkWhileTyping { llm.textChanged(buffer) }
            if suggestion?.source == .llm {
                // A quiet fix follows the typing until Tab, Enter or the line changes under it.
                if let base = llmBase, let s = llmSuggestion(original: base.original, options: base.options) {
                    suggestion = s
                } else { suggestion = nil; llmBase = nil; panel.hide() }
            }
            else if suggestion != nil { suggestion = nil; panel.hide() }
            return
        }
        if Caret.keysAreNotTyping() {
            reset()
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
        if original == quietSegment { quietSegment = nil }
        // A held Enter needs the segment to still end the line; a quiet check may have been typed past.
        let trailing = trailingBlanks()
        let s: Suggestion
        if hold != nil, hold!.segment == original {
            let scalars = Array(buffer.unicodeScalars.dropLast(trailing.unicodeScalars.count))
            let orig = Array(original.unicodeScalars)
            guard orig.count <= scalars.count, Array(scalars[(scalars.count - orig.count)...]) == orig else {
                Log.write("llm result stale, dropped")
                return
            }
            let options = reply.options.map { $0 + trailing }
            s = Suggestion(scalarCount: orig.count + trailing.unicodeScalars.count,
                           replacement: options[0], direction: nil, source: .llm,
                           alternatives: Array(options.dropFirst()), original: original)
            llmBase = nil
        } else {
            guard let fresh = llmSuggestion(original: original, options: reply.options) else {
                Log.write("llm result stale, dropped")
                return
            }
            s = fresh
            llmBase = (original, reply.options)
        }
        let options = [s.replacement] + s.alternatives
        suggestion = s
        Log.write("llm suggestion (\(s.scalarCount) keys, \(options.count) options)")
        if hold != nil, hold!.segment == original {
            hold!.decided = true
            hold!.decidedAt = Date()
            showFix(original: original, options: reply.options, selected: 0,
                    hint: options.count > 1 ? "⇥ fix · ⇥⇥ next · ↩ send as is" : "⇥ fix · ↩ send as is · esc")
            return
        }
        showFix(original: original, options: reply.options, selected: 0, hint: options.count > 1 ? "⇥ fix · ⇥⇥ next" : "⇥ fix")
    }

    /// Claude's fix, set against the text box; a plain list when what was typed is not known.
    private func showFix(original: String?, options: [String], selected: Int, hint: String) {
        let trimmed = options.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let original = original else {
            panel.show(options: trimmed, selected: selected, hint: hint, near: Caret.anchorPoint())
            return
        }
        let field = Caret.focusedFieldFrame()
        Log.write("fix shown at \(field == nil ? "caret" : "field")")
        panel.showFix(original: original, options: trimmed, selected: selected, hint: hint,
                          field: field, near: Caret.anchorPoint())
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
        showFix(original: c.original, options: c.options, selected: next, hint: "⇥ next · ↩ send")
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
                      expires: Date().addingTimeInterval(Self.undoWindow), bufferAfter: buffer)
            : nil

        if switchLayoutAfterFix, let direction = s.direction {
            InputSource.select(thai: direction == .englishToThai)
        }
        if s.source == .llm, !s.alternatives.isEmpty {
            let options = [s.replacement] + s.alternatives
            cycle = Cycle(original: s.original, options: options, index: 0, insertedScalars: s.replacement.unicodeScalars.count,
                          expires: Date().addingTimeInterval(Self.cycleWindow))
            showFix(original: s.original, options: options, selected: 0, hint: "⇥ next · ↩ send")
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

    /// A line break goes out as Shift+Enter, since a plain Return would send the message in a chat app.
    private func postText(_ text: String, _ source: CGEventSource?) {
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            if i > 0 { postKey(kVK_Return, source, flags: .maskShift) }
            postLine(line, source)
        }
    }

    private func postLine(_ text: String, _ source: CGEventSource?) {
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
