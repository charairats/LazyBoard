import Cocoa
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private let monitor = KeyMonitor()
    private let defaults = UserDefaults.standard
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?

    // Menu items. Titles are set in buildStatusItem / refreshMenuState.
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let claudeLine = NSMenuItem(title: "", action: #selector(fixClaude), keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
    private let excludeItem = NSMenuItem(title: "Disable in This App", action: #selector(toggleExclude), keyEquivalent: "")
    private let autoFixItem = NSMenuItem(title: "Auto-Fix on Space / Enter  (Esc to undo)", action: #selector(toggleAutoFix), keyEquivalent: "")
    private let switchItem = NSMenuItem(title: "Switch Input Source After Fix", action: #selector(toggleSwitch), keyEquivalent: "")
    private let llmItem = NSMenuItem(title: "Use Claude", action: #selector(toggleLLM), keyEquivalent: "")
    private let sendCheckItem = NSMenuItem(title: "Check Before Send", action: nil, keyEquivalent: "")
    private let sendCheckMenu = NSMenu()
    private let quietItem = NSMenuItem(title: "Also Check When I Pause Typing", action: #selector(toggleQuiet), keyEquivalent: "")
    private let rewriteItem = NSMenuItem(title: "Polish on Send", action: nil, keyEquivalent: "")
    private let rewriteMenu = NSMenu()
    private let emojiItem = NSMenuItem(title: "Add 1–2 Emoji at the End", action: #selector(toggleEmoji), keyEquivalent: "")
    private let connectionItem = NSMenuItem(title: "Connection", action: nil, keyEquivalent: "")
    private let connectionMenu = NSMenu()
    private let apiKeyItem = NSMenuItem(title: "Set API Key…", action: #selector(editAPIKey), keyEquivalent: "")
    private let testItem = NSMenuItem(title: "Typing Test…", action: #selector(openTypingTest), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private var backendItems: [NSMenuItem] = []
    private var modelItems: [NSMenuItem] = []
    private var politeItems: [NSMenuItem] = []
    private var fixCount = 0

    /// How Enter and Ctrl+Enter behave. Maps onto holdOnEnter + enterChecks.
    private enum SendCheck: String, CaseIterable {
        case off, ctrlEnter, enter
        var title: String {
            switch self {
            case .off: return "Off  (Enter sends as typed)"
            case .ctrlEnter: return "Ctrl+Enter checks  ·  Enter sends as typed"
            case .enter: return "Enter checks  ·  Ctrl+Enter sends as typed"
            }
        }
        var short: String {
            switch self {
            case .off: return "Off"
            case .ctrlEnter: return "Ctrl+Enter"
            case .enter: return "Enter"
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        migrateOldSettings()
        WordLog.purge()
        defaults.register(defaults: ["enabled": true, "switchLayout": true, "excluded": [String](),
                                     "autoFix": true, "holdOnEnter": true, "enterChecks": false, "checkWhileTyping": false, "emojiMode": false,
                                     "llmEnabled": true, "llmModel": LLMSuggester.Model.haiku.rawValue,
                                     "llmBackend": LLMSuggester.Backend.claudeCLI.rawValue])
        monitor.llm.backend = LLMSuggester.Backend(rawValue: defaults.string(forKey: "llmBackend") ?? "") ?? .claudeCLI
        monitor.isEnabled = defaults.bool(forKey: "enabled")
        monitor.switchLayoutAfterFix = defaults.bool(forKey: "switchLayout")
        monitor.autoFixLayout = defaults.bool(forKey: "autoFix")
        monitor.holdOnEnter = defaults.bool(forKey: "holdOnEnter")
        monitor.enterChecks = defaults.bool(forKey: "enterChecks")
        monitor.checkWhileTyping = defaults.bool(forKey: "checkWhileTyping")
        monitor.llm.emojiMode = defaults.bool(forKey: "emojiMode")
        monitor.llm.polite = LLMSuggester.Polite(rawValue: defaults.string(forKey: "politeMode") ?? "") ?? .off
        monitor.excludedBundleIDs = Set(defaults.stringArray(forKey: "excluded") ?? [])
        monitor.llm.isEnabled = defaults.bool(forKey: "llmEnabled")
        monitor.llm.model = LLMSuggester.Model(rawValue: defaults.string(forKey: "llmModel") ?? "") ?? .haiku
        monitor.llm.apiKey = KeychainStore.read()
        Log.write("llm: backend \(monitor.llm.backend.rawValue), enabled \(monitor.llm.isEnabled), api key \(monitor.llm.apiKey == nil ? "none" : "saved"), claude cli \(LLMSuggester.claudePath == nil ? "missing" : "found")")
        monitor.onFix = { [weak self] s in
            guard let self = self else { return }
            self.fixCount += 1
            TypingTest.shared.noteFix(s)
            self.updateStatusLine()
        }
        buildStatusItem()
        ensureAccessibility()
    }

    /// lazyboard://test opens the typing test; lazyboard://menu is a no-op that just activates the app.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "lazyboard" {
            Log.write("url: \(url.absoluteString)")
            if url.host == "test" { TypingTest.shared.show() }
        }
    }

    /// The app used to be ThaiTab (com.jeen.thaitab): carry its settings over on first launch.
    private func migrateOldSettings() {
        guard !defaults.bool(forKey: "migratedFromThaiTab"), let old = UserDefaults(suiteName: "com.jeen.thaitab") else { return }
        for key in ["enabled", "switchLayout", "excluded", "autoFix", "holdOnEnter", "checkWhileTyping", "emojiMode", "llmEnabled", "llmModel", "llmBackend"] {
            if let value = old.object(forKey: key), defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: "migratedFromThaiTab")
        Log.write("settings migrated from ThaiTab")
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.llm.shutdown()
    }

    // MARK: Status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = Self.okIcon {
            statusItem.button?.image = image
        } else {
            statusItem.button?.title = "LB"
        }
        let menu = NSMenu()
        menu.delegate = self

        // 1. Status: what LazyBoard is doing, and whether Claude works (click it when it shows a problem).
        menu.addItem(statusLine)
        claudeLine.target = self
        menu.addItem(claudeLine)
        menu.addItem(.separator())

        // 2. On/off.
        add([enabledItem, excludeItem], to: menu)
        menu.addItem(.separator())

        // 3. Wrong-layout fixes (works offline, no Claude).
        menu.addItem(Self.header("Wrong Keyboard Fixes (offline)"))
        add([autoFixItem, switchItem], to: menu)
        menu.addItem(.separator())

        // 4. Claude: master switch first, then what it does.
        menu.addItem(Self.header("Claude Spell Check"))
        for mode in SendCheck.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectSendCheck(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            sendCheckMenu.addItem(item)
        }
        sendCheckItem.submenu = sendCheckMenu

        rewriteMenu.addItem(Self.header("Polite Ending (work chats)"))
        for polite in LLMSuggester.Polite.allCases {
            let title: String
            switch polite {
            case .off: title = "None"
            default: title = polite == .khrap ? "Khrap (ครับ)" : "Kha (ค่ะ)"
            }
            let item = NSMenuItem(title: title, action: #selector(selectPolite(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = polite.rawValue
            politeItems.append(item)
            rewriteMenu.addItem(item)
        }
        rewriteMenu.addItem(.separator())
        emojiItem.target = self
        rewriteMenu.addItem(emojiItem)
        rewriteItem.submenu = rewriteMenu

        connectionMenu.addItem(Self.header("Connect via"))
        for backend in LLMSuggester.Backend.allCases {
            let item = NSMenuItem(title: backend == .api ? "Claude API Key" : "Claude Code (your existing login)", action: #selector(selectBackend(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = backend.rawValue
            backendItems.append(item)
            connectionMenu.addItem(item)
        }
        apiKeyItem.target = self
        apiKeyItem.indentationLevel = 1
        connectionMenu.addItem(apiKeyItem)
        connectionMenu.addItem(.separator())
        connectionMenu.addItem(Self.header("Model"))
        for model in LLMSuggester.Model.allCases {
            let item = NSMenuItem(title: model == .haiku ? "Haiku 5.5 (fast, cheap)" : "Opus 5.5 (more accurate)", action: #selector(selectModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = model.rawValue
            modelItems.append(item)
            connectionMenu.addItem(item)
        }
        connectionItem.submenu = connectionMenu

        add([llmItem, sendCheckItem, quietItem, rewriteItem, connectionItem], to: menu)
        menu.addItem(.separator())

        // 5. Other.
        add([testItem, loginItem], to: menu)
        let perm = NSMenuItem(title: "Accessibility Settings…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        perm.target = self
        menu.addItem(perm)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit LazyBoard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        refreshMenuState()
        // Claude errors arrive in the background: keep the icon in step without waiting for the menu to open.
        iconTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.updateIcon() }
    }

    private func add(_ items: [NSMenuItem], to menu: NSMenu) {
        for item in items {
            if item.action != nil { item.target = self }
            menu.addItem(item)
        }
    }

    /// A small grey group title. Real section headers on macOS 14+, a disabled item before that.
    private static func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        item.isEnabled = false
        return item
    }

    /// Greys out what cannot work right now, instead of hiding it.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item === claudeLine { return claudeProblem != nil }
        let needsClaude = item === quietItem || item.menu === sendCheckMenu || item.menu === rewriteMenu
        if needsClaude { return monitor.isEnabled && monitor.llm.isEnabled }
        if item === autoFixItem || item === switchItem || item === llmItem || item === excludeItem { return monitor.isEnabled }
        return true
    }

    private static let okIcon = keyboardIcon(badge: "bolt.fill")
    private static let errorIcon = keyboardIcon(badge: "exclamationmark.triangle.fill")
    private var iconTimer: Timer?

    /// Bolt badge when all is well, warning triangle while Claude has a problem.
    private func updateIcon() {
        guard let button = statusItem?.button, let ok = Self.okIcon, let bad = Self.errorIcon else { return }
        let want = claudeProblem == nil ? ok : bad
        if button.image !== want {
            button.image = want
            button.toolTip = claudeProblem.map { "LazyBoard — Claude: \($0)" } ?? "LazyBoard"
        }
    }

    /// Keyboard with a small badge symbol at the top-right corner, as a template image.
    private static func keyboardIcon(badge: String) -> NSImage? {
        guard let keyboard = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "LazyBoard")?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)),
              let bolt = NSImage(systemSymbolName: badge, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .bold)) else { return nil }
        let size = NSSize(width: 22, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let kb = keyboard.size
            let kbRect = NSRect(x: 0, y: (rect.height - kb.height) / 2, width: kb.width, height: kb.height)
            keyboard.draw(in: kbRect)
            let b = bolt.size
            let boltRect = NSRect(x: rect.width - b.width + 1, y: rect.height - b.height + 1, width: b.width, height: b.height)
            // Punch a small gap around the bolt so it reads clearly over the keyboard outline.
            NSGraphicsContext.current?.cgContext.setBlendMode(.destinationOut)
            NSColor.black.setFill()
            NSBezierPath(ovalIn: boltRect.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
            bolt.draw(in: boltRect)
            return true
        }
        image.isTemplate = true
        return image
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuState()
    }

    private var sendCheck: SendCheck {
        !monitor.holdOnEnter ? .off : (monitor.enterChecks ? .enter : .ctrlEnter)
    }

    private func refreshMenuState() {
        let llm = monitor.llm
        enabledItem.state = monitor.isEnabled ? .on : .off
        switchItem.state = monitor.switchLayoutAfterFix ? .on : .off
        autoFixItem.state = monitor.autoFixLayout ? .on : .off
        quietItem.state = monitor.checkWhileTyping ? .on : .off
        llmItem.state = llm.isEnabled ? .on : .off

        let mode = sendCheck
        for item in sendCheckMenu.items {
            item.state = (item.representedObject as? String) == mode.rawValue ? .on : .off
        }
        sendCheckItem.title = "Check Before Send: \(mode.short)"

        emojiItem.state = llm.emojiMode ? .on : .off
        for item in politeItems {
            item.state = (item.representedObject as? String) == llm.polite.rawValue ? .on : .off
        }
        var rewrites: [String] = []
        if llm.polite != .off { rewrites.append(llm.polite == .khrap ? "Khrap" : "Kha") }
        if llm.emojiMode { rewrites.append("Emoji") }
        rewriteItem.title = "Polish on Send: " + (rewrites.isEmpty ? "Off" : rewrites.joined(separator: " + "))

        for item in backendItems {
            item.state = (item.representedObject as? String) == llm.backend.rawValue ? .on : .off
        }
        for item in modelItems {
            item.state = (item.representedObject as? String) == llm.model.rawValue ? .on : .off
        }
        apiKeyItem.title = llm.apiKey == nil ? "Set API Key…" : "Change API Key…  (saved)"
        connectionItem.title = "Connection: \(backendShort) · \(modelShort)"

        statusItem.button?.appearsDisabled = !monitor.isEnabled
        if let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier {
            excludeItem.title = "Disable in \(app.localizedName ?? id)"
            excludeItem.state = monitor.excludedBundleIDs.contains(id) ? .on : .off
            excludeItem.representedObject = id
            excludeItem.isHidden = false
        } else {
            excludeItem.isHidden = true
        }
        if isBundled {
            loginItem.isHidden = false
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            loginItem.isHidden = true
        }
        updateStatusLine()
    }

    private var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private var backendShort: String { monitor.llm.backend == .api ? "API key" : "Claude Code" }
    private var modelShort: String { monitor.llm.model == .haiku ? "Haiku" : "Opus" }

    /// Full text of what stops Claude from working, or nil when it works (or is switched off on purpose).
    private var claudeProblem: String? {
        let llm = monitor.llm
        guard llm.isEnabled else { return nil }
        if llm.backend == .api && llm.apiKey == nil { return "No API key set" }
        if llm.backend == .claudeCLI && LLMSuggester.claudePath == nil { return "claude command not found (install Claude Code, or use an API key)" }
        return llm.lastError.map(Self.englishError)
    }

    /// LLMSuggester reports errors in Thai; the menu is English.
    private static func englishError(_ err: String) -> String {
        if err.contains("login") || err.contains("authenticate") || err.contains("OAuth") { return "Claude Code login expired" }
        if err.contains("API key") { return "API key rejected" }
        if err.contains("จำกัดอัตรา") { return "Rate limited, pausing 30s" }
        if err.contains("ไม่พบคำสั่ง claude") { return "claude command not found" }
        if err.contains("ตอบช้า") { return "Claude timed out" }
        if err.contains("Keychain") { return "Couldn't save key to Keychain (works until quit)" }
        if err.range(of: "[\u{0E00}-\u{0E7F}]", options: .regularExpression) != nil { return "Request failed" }
        return err
    }

    private func updateStatusLine() {
        if !monitor.isRunning {
            statusLine.title = "LazyBoard: Waiting for Accessibility permission…"
        } else if !monitor.isEnabled {
            statusLine.title = "LazyBoard: Off"
        } else {
            statusLine.title = "LazyBoard: On" + (fixCount == 0 ? "" : " · \(fixCount) fixes")
        }
        let llm = monitor.llm
        if let problem = claudeProblem {
            // Keep the menu narrow: a short line here, the full text on click and in the tooltip.
            var short = problem.components(separatedBy: CharacterSet(charactersIn: ":(\n")).first?
                .trimmingCharacters(in: .whitespaces) ?? problem
            if short.count > 40 { short = String(short.prefix(40)) + "…" }
            claudeLine.title = "⚠️ Claude: \(short) — Fix…"
            claudeLine.toolTip = problem
        } else if !llm.isEnabled {
            claudeLine.title = "Claude: Off"
            claudeLine.toolTip = nil
        } else {
            let latency = llm.lastLatency > 0 ? String(format: " · %.1fs", llm.lastLatency) : ""
            claudeLine.title = "Claude: Ready · \(modelShort) via \(backendShort)\(latency)"
            claudeLine.toolTip = "\(llm.requestCount) requests"
        }
        updateIcon()
    }

    /// Clicked the Claude problem line: say what is wrong in full and offer the fix.
    @objc private func fixClaude() {
        guard let problem = claudeProblem else { return }
        if monitor.llm.backend == .api && monitor.llm.apiKey == nil { editAPIKey(); return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Claude isn't working"
        alert.informativeText = problem + "\n\nTo fix: set a Claude API key (LazyBoard switches to it), or run claude in Terminal, type /login, then press Retry."
        alert.addButton(withTitle: "Set API Key…")
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Close")
        switch alert.runModal() {
        case .alertFirstButtonReturn: editAPIKey()
        case .alertSecondButtonReturn:
            monitor.llm.lastError = nil
            Log.write("llm: error cleared from menu")
            refreshMenuState()
        default: break
        }
    }

    // MARK: Actions

    @objc private func toggleEnabled() {
        monitor.isEnabled.toggle()
        defaults.set(monitor.isEnabled, forKey: "enabled")
        refreshMenuState()
    }

    @objc private func toggleSwitch() {
        monitor.switchLayoutAfterFix.toggle()
        defaults.set(monitor.switchLayoutAfterFix, forKey: "switchLayout")
        refreshMenuState()
    }

    @objc private func toggleAutoFix() {
        monitor.autoFixLayout.toggle()
        defaults.set(monitor.autoFixLayout, forKey: "autoFix")
        refreshMenuState()
    }

    @objc private func toggleEmoji() {
        monitor.llm.emojiMode.toggle()
        defaults.set(monitor.llm.emojiMode, forKey: "emojiMode")
        refreshMenuState()
    }

    @objc private func selectPolite(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let polite = LLMSuggester.Polite(rawValue: raw) else { return }
        monitor.llm.polite = polite
        defaults.set(raw, forKey: "politeMode")
        refreshMenuState()
    }

    @objc private func toggleQuiet() {
        monitor.checkWhileTyping.toggle()
        defaults.set(monitor.checkWhileTyping, forKey: "checkWhileTyping")
        refreshMenuState()
    }

    @objc private func selectSendCheck(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = SendCheck(rawValue: raw) else { return }
        monitor.holdOnEnter = mode != .off
        if mode != .off { monitor.enterChecks = mode == .enter }
        defaults.set(monitor.holdOnEnter, forKey: "holdOnEnter")
        defaults.set(monitor.enterChecks, forKey: "enterChecks")
        Log.write("send check: \(raw)")
        refreshMenuState()
    }

    @objc private func openTypingTest() {
        TypingTest.shared.show()
    }

    @objc private func toggleExclude(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if monitor.excludedBundleIDs.contains(id) { monitor.excludedBundleIDs.remove(id) } else { monitor.excludedBundleIDs.insert(id) }
        defaults.set(Array(monitor.excludedBundleIDs).sorted(), forKey: "excluded")
        refreshMenuState()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            Log.write("login item change failed: \(error)")
        }
        refreshMenuState()
    }

    @objc private func toggleLLM() {
        monitor.llm.isEnabled.toggle()
        defaults.set(monitor.llm.isEnabled, forKey: "llmEnabled")
        refreshMenuState()
    }

    @objc private func selectBackend(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let backend = LLMSuggester.Backend(rawValue: raw) else { return }
        monitor.llm.backend = backend
        defaults.set(raw, forKey: "llmBackend")
        monitor.llm.lastError = nil
        Log.write("llm: backend \(raw)")
        refreshMenuState()
        if backend == .api && monitor.llm.apiKey == nil { editAPIKey() }
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let model = LLMSuggester.Model(rawValue: raw) else { return }
        monitor.llm.model = model
        defaults.set(raw, forKey: "llmModel")
        refreshMenuState()
    }

    @objc private func editAPIKey() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Claude API key"
        alert.informativeText = "Create one at platform.claude.com → API Keys.\nStored only in this Mac's Keychain. Save an empty field to remove the key."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = monitor.llm.apiKey == nil ? "sk-ant-…" : "A key is saved (type to replace it)"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            // Saving an empty field while a key exists removes the key.
            if monitor.llm.apiKey != nil {
                KeychainStore.delete()
                monitor.llm.apiKey = nil
            }
        } else {
            if !value.hasPrefix("sk-ant-") {
                Log.write("api key rejected: not an sk-ant- key (\(value.count) chars)")
                let warn = NSAlert()
                warn.messageText = "That isn't a Claude API key"
                warn.informativeText = "Claude API keys start with sk-ant-. Copy one from platform.claude.com → API Keys and paste it with ⌘V."
                warn.runModal()
                return
            }
            let saved = KeychainStore.write(value)
            monitor.llm.apiKey = value
            monitor.llm.lastError = saved ? nil : "Couldn't save key to Keychain (works until quit)"
            // A key was just given: use it, rather than staying on a CLI login that may have expired.
            if monitor.llm.backend != .api {
                monitor.llm.backend = .api
                defaults.set(LLMSuggester.Backend.api.rawValue, forKey: "llmBackend")
                Log.write("llm: backend api (key saved)")
            }
        }
        refreshMenuState()
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Accessibility permission

    private func ensureAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) {
            Log.write("accessibility already trusted")
            startMonitor()
            return
        }
        Log.write("waiting for accessibility permission")
        updateStatusLine()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            Log.write("accessibility granted")
            self?.startMonitor()
        }
    }

    private func startMonitor() {
        if !monitor.start() {
            Log.write("event tap could not be created")
            statusLine.title = "LazyBoard: Couldn't start (relaunch the app)"
            return
        }
        Log.write("event tap running")
        monitor.llm.prewarm()
        updateStatusLine()
    }
}
