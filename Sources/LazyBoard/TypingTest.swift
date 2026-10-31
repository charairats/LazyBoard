import Cocoa

/// A small self-test: type the shown sentences, get an accuracy score per sentence and overall.
final class TypingTest: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    static let shared = TypingTest()

    static let sentences: [String] = [
        "สวัสดีค่ะ วันนี้มาเทสคีย์บอร์ดนะคะ",
        "แก้เรื่องไหนก็รีเทสเรื่องนั้นใน journey ที่เกี่ยวข้อง",
        "ส่ง PR แล้วนะ รอ review ด้วยค่ะ",
        "deploy ขึ้น staging แล้ว ลองกดดูได้เลย",
        "บัคนี้เกิดตอน login ด้วย Google เท่านั้น",
        "เดี๋ยวประชุมกัน 10 โมง ใน Google Meet นะ",
        "The checkout flow ยังพังอยู่ ขอเวลาแก้ครึ่งวัน",
        "ทำไมต้องเทสทั้งหมด ทั้งที่แก้แค่จุดเดียว",
        "อัปเดต README กับ build script เรียบร้อยแล้วค่ะ",
        "ขอบคุณมากนะคะ พรุ่งนี้มาต่อ sprint planning",
    ]

    struct Result {
        let target: String
        let typed: String
        let accuracy: Double
        let layoutFixes: Int
        let llmFixes: Int
        let seconds: TimeInterval
    }

    private var window: NSWindow?
    private let progress = NSTextField(labelWithString: "")
    private let target = NSTextField(wrappingLabelWithString: "")
    private let input = NSTextField(string: "")
    private let hint = NSTextField(labelWithString: "พิมพ์ประโยคด้านบนให้เหมือนที่สุด แล้วกด Enter · ถ้ามี popup ขึ้น กด Tab ใช้ได้ตามปกติ")
    private let report = NSTextView()
    private let reportScroll = NSScrollView()
    private let nextButton = NSButton(title: "ข้าม", target: nil, action: nil)
    private let restartButton = NSButton(title: "เริ่มใหม่", target: nil, action: nil)

    private var index = 0
    private var results: [Result] = []
    private var layoutFixes = 0
    private var llmFixes = 0
    private var started = Date()

    var isRunning: Bool { window?.isVisible == true && index < Self.sentences.count }

    /// Called by the key monitor whenever a fix is applied anywhere; counted only while testing.
    func noteFix(_ s: Suggestion) {
        guard isRunning else { return }
        if s.source == .llm { llmFixes += 1 } else { layoutFixes += 1 }
    }

    // MARK: Window

    func show() {
        if window == nil { build() }
        restart()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(input)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "แบบทดสอบการพิมพ์ · LazyBoard"
        w.delegate = self
        w.isReleasedWhenClosed = false

        progress.font = .systemFont(ofSize: 12)
        progress.textColor = .secondaryLabelColor
        target.font = .systemFont(ofSize: 20, weight: .medium)
        target.maximumNumberOfLines = 3
        input.font = .systemFont(ofSize: 18)
        input.placeholderString = "พิมพ์ตรงนี้…"
        input.delegate = self
        input.target = self
        input.action = #selector(submit)
        (input.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = false
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2

        nextButton.target = self
        nextButton.action = #selector(skip)
        restartButton.target = self
        restartButton.action = #selector(restartClicked)
        let buttons = NSStackView(views: [restartButton, nextButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        report.isEditable = false
        report.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        report.textContainerInset = NSSize(width: 6, height: 6)
        reportScroll.documentView = report
        reportScroll.hasVerticalScroller = true
        reportScroll.borderType = .bezelBorder
        report.autoresizingMask = [.width]
        report.isVerticallyResizable = true
        report.textContainer?.widthTracksTextView = true

        let stack = NSStackView(views: [progress, target, input, hint, buttons, reportScroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        w.contentView?.addSubview(stack)
        guard let content = w.contentView else { return }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            target.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            input.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            reportScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            reportScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
        window = w
    }

    // MARK: Flow

    private func restart() {
        index = 0
        results = []
        report.string = ""
        input.isEnabled = true
        nextButton.isEnabled = true
        showCurrent()
    }

    private func showCurrent() {
        layoutFixes = 0
        llmFixes = 0
        started = Date()
        input.stringValue = ""
        guard index < Self.sentences.count else { finish(); return }
        progress.stringValue = "ประโยคที่ \(index + 1) / \(Self.sentences.count)"
        target.stringValue = Self.sentences[index]
        window?.makeFirstResponder(input)
    }

    @objc private func submit() {
        guard index < Self.sentences.count else { return }
        // An empty Enter right after a sentence appears is a stray key, not an answer.
        if input.stringValue.trimmingCharacters(in: .whitespaces).isEmpty, Date().timeIntervalSince(started) < 1.5 { return }
        record(typed: input.stringValue)
        index += 1
        showCurrent()
    }

    @objc private func skip() {
        guard index < Self.sentences.count else { return }
        record(typed: input.stringValue)
        index += 1
        showCurrent()
    }

    @objc private func restartClicked() { restart() }

    private func record(typed: String) {
        let t = Self.sentences[index]
        let acc = Self.accuracy(typed: typed, target: t)
        results.append(Result(target: t, typed: typed, accuracy: acc, layoutFixes: layoutFixes,
                              llmFixes: llmFixes, seconds: Date().timeIntervalSince(started)))
        appendReportLine(results.count, results.last!)
    }

    private func appendReportLine(_ n: Int, _ r: Result) {
        let mark = r.accuracy >= 0.999 ? "✓" : (r.accuracy >= 0.9 ? "~" : "✗")
        var line = String(format: "%2d %@ %3.0f%%  %4.1fs  fix L%d ✨%d", n, mark, r.accuracy * 100, r.seconds, r.layoutFixes, r.llmFixes)
        if r.accuracy < 0.999 { line += "\n      พิมพ์: \(r.typed)" }
        report.string += line + "\n"
        report.scrollToEndOfDocument(nil)
    }

    private func finish() {
        progress.stringValue = "เสร็จแล้ว"
        target.stringValue = "ผลสรุป"
        input.isEnabled = false
        nextButton.isEnabled = false
        let n = max(results.count, 1)
        let avg = results.map(\.accuracy).reduce(0, +) / Double(n)
        let exact = results.filter { $0.accuracy >= 0.999 }.count
        let fixesL = results.map(\.layoutFixes).reduce(0, +)
        let fixesLLM = results.map(\.llmFixes).reduce(0, +)
        let time = results.map(\.seconds).reduce(0, +)
        report.string += String(format: "\nความถูกต้องเฉลี่ย %.1f%%  ·  ตรงเป๊ะ %d/%d ประโยค  ·  ใช้ fix เลย์เอาต์ %d ครั้ง, ✨ %d ครั้ง  ·  รวม %.0f วินาที\n",
                                avg * 100, exact, results.count, fixesL, fixesLLM, time)
        report.scrollToEndOfDocument(nil)
        Log.write(String(format: "typing test done: avg %.1f%%, exact %d/%d", avg * 100, exact, results.count))
        saveResults(summary: String(format: "avg %.1f%%, exact %d/%d, layout fixes %d, llm fixes %d, %.0fs", avg * 100, exact, results.count, fixesL, fixesLLM, time))
    }

    /// Full per-sentence results (target vs typed) go to a separate file so they can be reviewed later.
    static let resultsURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LazyBoard", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("typing-test-results.txt")
    }()

    private func saveResults(summary: String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var text = "=== \(f.string(from: Date())) · \(summary)\n"
        for (i, r) in results.enumerated() {
            text += String(format: "%2d  %3.0f%%  %4.1fs  L%d ✨%d\n", i + 1, r.accuracy * 100, r.seconds, r.layoutFixes, r.llmFixes)
            text += "    target: \(r.target)\n"
            text += "    typed : \(r.typed)\n"
        }
        text += "\n"
        if let handle = try? FileHandle(forWritingTo: Self.resultsURL) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: Self.resultsURL)
        }
        Log.write("typing test results saved")
    }

    // MARK: Scoring

    /// 1 - normalized Levenshtein distance over unicode scalars (whitespace-trimmed, letter case ignored).
    static func accuracy(typed: String, target: String) -> Double {
        let a = Array(typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().unicodeScalars)
        let b = Array(target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().unicodeScalars)
        if a.isEmpty && b.isEmpty { return 1 }
        let maxLen = max(a.count, b.count)
        guard maxLen > 0 else { return 1 }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...max(a.count, 1) where i <= a.count {
            cur[0] = i
            for j in 1...max(b.count, 1) where j <= b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        let dist = a.isEmpty ? b.count : (b.isEmpty ? a.count : prev[b.count])
        return max(0, 1 - Double(dist) / Double(maxLen))
    }

    func windowWillClose(_ notification: Notification) {
        index = Self.sentences.count
    }
}
