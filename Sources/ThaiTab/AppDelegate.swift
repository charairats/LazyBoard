import Cocoa
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let monitor = KeyMonitor()
    private let defaults = UserDefaults.standard
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?

    private let statusLine = NSMenuItem(title: "กำลังเริ่ม…", action: nil, keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: "เปิดใช้งาน", action: #selector(toggleEnabled), keyEquivalent: "")
    private let switchItem = NSMenuItem(title: "สลับคีย์บอร์ดให้หลังแก้", action: #selector(toggleSwitch), keyEquivalent: "")
    private let autoFixItem = NSMenuItem(title: "แก้พิมพ์ค้างคีย์บอร์ดให้เองตอนเคาะ space/Enter (Esc ย้อนกลับ)", action: #selector(toggleAutoFix), keyEquivalent: "")
    private let holdItem = NSMenuItem(title: "อม Enter ไว้ให้ Claude ตรวจก่อนส่ง (Ctrl+Enter = ส่งเลย)", action: #selector(toggleHold), keyEquivalent: "")
    private let emojiItem = NSMenuItem(title: "โหมดอีโมจิ: เติมท้ายข้อความ 1–2 ตัวตอนส่ง", action: #selector(toggleEmoji), keyEquivalent: "")
    private let quietItem = NSMenuItem(title: "ให้ Claude ตรวจเงียบๆ ระหว่างหยุดพิมพ์ด้วย", action: #selector(toggleQuiet), keyEquivalent: "")
    private let testItem = NSMenuItem(title: "แบบทดสอบการพิมพ์…", action: #selector(openTypingTest), keyEquivalent: "")
    private let excludeItem = NSMenuItem(title: "ไม่ใช้ในแอปนี้", action: #selector(toggleExclude), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "เปิดอัตโนมัติตอน login", action: #selector(toggleLogin), keyEquivalent: "")
    private let llmItem = NSMenuItem(title: "แก้คำผิดด้วย Claude (หลังหยุดพิมพ์)", action: #selector(toggleLLM), keyEquivalent: "")
    private let apiKeyItem = NSMenuItem(title: "ตั้งค่า Claude API key…", action: #selector(editAPIKey), keyEquivalent: "")
    private let modelMenu = NSMenu()
    private let backendMenu = NSMenu()
    private let llmStatusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var fixCount = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["enabled": true, "switchLayout": true, "excluded": [String](),
                                     "autoFix": true, "holdOnEnter": true, "checkWhileTyping": false, "emojiMode": false,
                                     "llmEnabled": true, "llmModel": LLMSuggester.Model.haiku.rawValue,
                                     "llmBackend": LLMSuggester.Backend.claudeCLI.rawValue])
        monitor.llm.backend = LLMSuggester.Backend(rawValue: defaults.string(forKey: "llmBackend") ?? "") ?? .claudeCLI
        monitor.isEnabled = defaults.bool(forKey: "enabled")
        monitor.switchLayoutAfterFix = defaults.bool(forKey: "switchLayout")
        monitor.autoFixLayout = defaults.bool(forKey: "autoFix")
        monitor.holdOnEnter = defaults.bool(forKey: "holdOnEnter")
        monitor.checkWhileTyping = defaults.bool(forKey: "checkWhileTyping")
        monitor.llm.emojiMode = defaults.bool(forKey: "emojiMode")
        monitor.excludedBundleIDs = Set(defaults.stringArray(forKey: "excluded") ?? [])
        monitor.llm.isEnabled = defaults.bool(forKey: "llmEnabled")
        monitor.llm.model = LLMSuggester.Model(rawValue: defaults.string(forKey: "llmModel") ?? "") ?? .haiku
        monitor.llm.apiKey = KeychainStore.read()
        monitor.onFix = { [weak self] s in
            guard let self = self else { return }
            self.fixCount += 1
            TypingTest.shared.noteFix(s)
            self.updateStatusLine()
        }
        buildStatusItem()
        ensureAccessibility()
    }

    /// thaitab://test opens the typing test; thaitab://menu is a no-op that just activates the app.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "thaitab" {
            Log.write("url: \(url.absoluteString)")
            if url.host == "test" { TypingTest.shared.show() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.llm.shutdown()
    }

    // MARK: Status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = Self.boltKeyboardIcon() {
            statusItem.button?.image = image
        } else {
            statusItem.button?.title = "ไท"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        testItem.target = self
        menu.addItem(testItem)
        menu.addItem(.separator())

        // Everyday switches only; everything else lives under "ตั้งค่าเพิ่มเติม".
        enabledItem.title = "เปิดใช้งาน"
        holdItem.title = "ตรวจด้วย Claude ก่อนส่ง (Ctrl+Enter ข้าม)"
        emojiItem.title = "เติมอีโมจิท้ายข้อความ"
        for item in [enabledItem, holdItem, emojiItem, excludeItem] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let advanced = NSMenu()
        switchItem.title = "สลับคีย์บอร์ดให้หลังแก้"
        autoFixItem.title = "แก้พิมพ์ค้างคีย์บอร์ดให้เองตอนเคาะ space/Enter"
        quietItem.title = "ให้ Claude ตรวจเงียบๆ ระหว่างหยุดพิมพ์ด้วย"
        llmItem.title = "ใช้ Claude แก้คำผิด"
        for item in [switchItem, autoFixItem, quietItem, llmItem, loginItem] {
            item.target = self
            advanced.addItem(item)
        }
        advanced.addItem(.separator())
        llmStatusLine.isEnabled = false
        advanced.addItem(llmStatusLine)
        let backendItem = NSMenuItem(title: "เรียก Claude ผ่าน", action: nil, keyEquivalent: "")
        for backend in LLMSuggester.Backend.allCases {
            let item = NSMenuItem(title: backend.title, action: #selector(selectBackend(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = backend.rawValue
            backendMenu.addItem(item)
        }
        backendItem.submenu = backendMenu
        advanced.addItem(backendItem)
        let modelItem = NSMenuItem(title: "โมเดล", action: nil, keyEquivalent: "")
        for model in LLMSuggester.Model.allCases {
            let item = NSMenuItem(title: model.title, action: #selector(selectModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = model.rawValue
            modelMenu.addItem(item)
        }
        modelItem.submenu = modelMenu
        advanced.addItem(modelItem)
        apiKeyItem.target = self
        advanced.addItem(apiKeyItem)
        advanced.addItem(.separator())
        let perm = NSMenuItem(title: "เปิดหน้าตั้งค่า Accessibility…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        perm.target = self
        advanced.addItem(perm)
        let advancedItem = NSMenuItem(title: "ตั้งค่าเพิ่มเติม", action: nil, keyEquivalent: "")
        advancedItem.submenu = advanced
        menu.addItem(advancedItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "ออกจาก ThaiTab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        refreshMenuState()
    }

    /// Keyboard with a small lightning bolt at the top-right corner, as a template image.
    private static func boltKeyboardIcon() -> NSImage? {
        guard let keyboard = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "ThaiTab")?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)),
              let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
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

    private func refreshMenuState() {
        enabledItem.state = monitor.isEnabled ? .on : .off
        switchItem.state = monitor.switchLayoutAfterFix ? .on : .off
        autoFixItem.state = monitor.autoFixLayout ? .on : .off
        holdItem.state = monitor.holdOnEnter ? .on : .off
        quietItem.state = monitor.checkWhileTyping ? .on : .off
        emojiItem.state = monitor.llm.emojiMode ? .on : .off
        statusItem.button?.appearsDisabled = !monitor.isEnabled
        if let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier {
            excludeItem.title = "ไม่ใช้ใน \(app.localizedName ?? id)"
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
        llmItem.state = monitor.llm.isEnabled ? .on : .off
        for item in modelMenu.items {
            item.state = (item.representedObject as? String) == monitor.llm.model.rawValue ? .on : .off
        }
        for item in backendMenu.items {
            item.state = (item.representedObject as? String) == monitor.llm.backend.rawValue ? .on : .off
        }
        apiKeyItem.isHidden = monitor.llm.backend != .api
        if monitor.llm.backend == .api && monitor.llm.apiKey == nil {
            llmStatusLine.title = "Claude: ยังไม่ได้ใส่ API key"
        } else if monitor.llm.backend == .claudeCLI && LLMSuggester.claudePath == nil {
            llmStatusLine.title = "Claude: ไม่พบคำสั่ง claude (ติดตั้ง Claude Code ก่อน)"
        } else if let err = monitor.llm.lastError {
            llmStatusLine.title = "Claude: \(err)"
        } else if !monitor.llm.isEnabled {
            llmStatusLine.title = "Claude: ปิดอยู่"
        } else {
            let latency = monitor.llm.lastLatency > 0 ? String(format: " · ล่าสุด %.1f วิ", monitor.llm.lastLatency) : ""
            llmStatusLine.title = "Claude: พร้อม · เรียกไปแล้ว \(monitor.llm.requestCount) ครั้ง\(latency)"
        }
        updateStatusLine()
    }

    private var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private func updateStatusLine() {
        if !monitor.isRunning {
            statusLine.title = "รอสิทธิ์ Accessibility…"
        } else if !monitor.isEnabled {
            statusLine.title = "ปิดอยู่"
        } else {
            var parts = [fixCount == 0 ? "ทำงานอยู่" : "แก้ไปแล้ว \(fixCount) ครั้ง"]
            if let err = monitor.llm.lastError { parts.append("Claude: \(err)") }
            else if monitor.llm.isReady, monitor.llm.lastLatency > 0 { parts.append(String(format: "Claude %.1f วิ", monitor.llm.lastLatency)) }
            else if !monitor.llm.isReady { parts.append("Claude ยังไม่พร้อม") }
            statusLine.title = parts.joined(separator: " · ")
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

    @objc private func toggleQuiet() {
        monitor.checkWhileTyping.toggle()
        defaults.set(monitor.checkWhileTyping, forKey: "checkWhileTyping")
        refreshMenuState()
    }

    @objc private func toggleHold() {
        monitor.holdOnEnter.toggle()
        defaults.set(monitor.holdOnEnter, forKey: "holdOnEnter")
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
        refreshMenuState()
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
        alert.informativeText = "สร้างได้ที่ platform.claude.com → API Keys\nคีย์ถูกเก็บใน Keychain ของเครื่องนี้เท่านั้น เว้นว่างแล้วกดบันทึกเพื่อลบคีย์"
        alert.addButton(withTitle: "บันทึก")
        alert.addButton(withTitle: "ยกเลิก")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = monitor.llm.apiKey == nil ? "sk-ant-…" : "มีคีย์บันทึกไว้แล้ว (พิมพ์ทับเพื่อเปลี่ยน)"
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
            KeychainStore.write(value)
            monitor.llm.apiKey = value
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
            statusLine.title = "เปิด event tap ไม่สำเร็จ (ลองเปิดแอปใหม่)"
            return
        }
        Log.write("event tap running")
        monitor.llm.prewarm()
        updateStatusLine()
    }
}
