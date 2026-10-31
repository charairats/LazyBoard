import Foundation

/// Second layer: after a short pause in typing, asks Claude to fix genuine typos
/// (adjacent-key slips, wrong Thai vowels/tones, misspelled English) in the last sentence.
/// Only runs when the layout detector found nothing.
final class LLMSuggester {
    enum Model: String, CaseIterable {
        case haiku = "claude-haiku-5-5"
        case opus = "claude-opus-5-5"
        var title: String {
            switch self {
            case .haiku: return "Haiku 5.5 (เร็ว ถูก)"
            case .opus: return "Opus 5.5 (แม่นกว่า)"
            }
        }
    }

    enum Backend: String, CaseIterable {
        case claudeCLI   // uses the Claude Code login already on this Mac (no API key)
        case api         // direct Messages API with an API key
        var title: String {
            switch self {
            case .claudeCLI: return "Claude Code CLI (ใช้ login ที่มีอยู่)"
            case .api: return "Claude API key"
            }
        }
    }

    struct Reply: Equatable {
        let fixed: String
        let alternatives: [String]
        var options: [String] { [fixed] + alternatives.filter { $0 != fixed } }
    }

    var isEnabled = true
    var backend: Backend = .claudeCLI
    var model: Model = .haiku
    var apiKey: String?
    private var process: Process?
    private var processID: Int = 0
    private let warm = WarmClaude()
    private var warmRequestID = 0
    /// Segment that arrived while a request was in flight; requested when that one finishes.
    private var queuedSegment: String?
    var debounce: TimeInterval = 0.9
    /// (original segment, reply), only when something changed. Delivered on the main thread.
    var onResult: ((String, Reply) -> Void)?
    /// Every completed request (original, reply), changed or not. Used by the CLI test mode and the Enter hold.
    var onFinished: ((String, Reply) -> Void)?
    /// A request that produced no usable reply (error, timeout, refusal).
    var onFailed: ((String) -> Void)?
    /// A request has just been sent for this segment (to show the loading indicator).
    var onStarted: ((String) -> Void)?
    private(set) var inFlightSegment: String?
    /// Human readable state for the menu.
    private(set) var lastError: String?
    private(set) var requestCount = 0
    private(set) var lastLatency: TimeInterval = 0

    private var pending: DispatchWorkItem?
    private var task: URLSessionDataTask?
    private var cache: [String: Reply] = [:]
    private var backoffUntil = Date.distantPast
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 12
        return URLSession(configuration: c)
    }()

    static let systemPrompt = """
    You are a typo fixer for a Thai developer who types very fast on a Mac and makes many mistakes, \
    in Thai, English, or a mix. The text is a chat message or a note, often informal.

    Your job: return the message as the writer intended to type it.
    - Correct every word that is not a real Thai or English word into the most likely intended word, \
    using the surrounding context. Typical slips: a neighbouring key on the Thai Kedmanee or US QWERTY \
    keyboard, a missing, doubled or swapped character, a wrong Thai vowel or tone mark, a misspelled \
    English word (e.g. "corretion" -> "correction", "sufgges" -> "suggest", "คียืบอด" -> "คีย์บอร์ด", \
    "เดก้" -> "เด็ก", "ขึ้ย" -> "ขึ้น", "นังจ้อง" -> "ยังต้อง").
    - Keep the meaning, word order, slang, Thai particles (ค่ะ ครับ นะ อะ แงๆ), emoji, punctuation, \
    spacing, line breaks and letter case. Do not rewrite style, do not translate, do not add or remove \
    words, never answer or comment on the message. Thai-spelled English dev words (เทส รีเทส ดีพลอย บัค \
    เช็ค รัน คอมมิต) are normal and stay as written; never replace them with formal Thai.
    - Leave real names, product names, code identifiers, URLs and well-known abbreviations as typed, \
    unless the context makes the intended word obvious.
    - "fixed" is your single best full correction of the whole text.
    - When a broken word has more than one plausible intended reading, put up to 2 other complete \
    versions of the whole text in "alternatives" (each differing from "fixed" only in the ambiguous \
    words). Otherwise "alternatives" is an empty array.
    - If there is nothing to fix, return the text unchanged with an empty "alternatives".
    - Each user message is a separate, independent text to fix. Never use earlier messages as context \
    and never refer to them.

    The user message is a JSON object. "text" is the text to fix. "layout_hints" maps garbled words in the \
    text to what the same keys produce on the other keyboard layout (Thai Kedmanee <-> US QWERTY): the \
    writer often forgets to switch layouts, so when a hint, or a small correction of it, is a real word that \
    fits the context, use it in place of the garbled word (hint "กยสนั": "dploy" means the word is "deploy"; \
    hint "พำฟกทำ": "readme" means "README"). When a hint is a real English word and the Thai word is not a \
    real Thai word (หแรพยะ -> script, สนเรื -> login), always use the hint. Your JSON answer is about "text" only.
    """

    var isReady: Bool {
        guard isEnabled else { return false }
        switch backend {
        case .api: return apiKey != nil
        case .claudeCLI: return Self.claudePath != nil
        }
    }

    /// Where the `claude` command lives, if installed.
    static let claudePath: String? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          home + "/.claude/local/claude", home + "/.local/bin/claude",
                          home + "/.npm-global/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    // MARK: Input

    /// Called on every keystroke. Only the debounce timer restarts; a request already in flight
    /// is left to finish (a CLI round trip takes several seconds) and its result is checked for
    /// staleness on arrival.
    func textChanged(_ buffer: String) {
        pending?.cancel()
        pending = nil
        guard isReady, Date() >= backoffUntil else { return }
        let segment = Self.segment(of: buffer)
        guard segment.unicodeScalars.count >= 6 else { queuedSegment = nil; return }
        if let reply = cache[segment] {
            if reply.fixed != segment { onResult?(segment, reply) }
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if self.isBusy {
                self.queuedSegment = segment
                return
            }
            self.start(segment)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private var isBusy: Bool { task != nil || process != nil || warm.isBusy }

    /// Check right now (no debounce), e.g. when Enter is held back. Returns the segment being checked.
    @discardableResult
    func checkNow(_ buffer: String) -> String? {
        pending?.cancel()
        pending = nil
        guard isReady else { return nil }
        let segment = Self.segment(of: buffer)
        guard segment.unicodeScalars.count >= 6 else { return nil }
        if let reply = cache[segment] {
            DispatchQueue.main.async { [weak self] in
                if reply.fixed != segment { self?.onResult?(segment, reply) }
                self?.onFinished?(segment, reply)
            }
            return segment
        }
        if isBusy {
            if inFlightSegment != segment { queuedSegment = segment }
            return segment
        }
        start(segment)
        return segment
    }

    func isChecked(_ segment: String) -> Bool { cache[segment] != nil }

    /// Remember a segment as checked (used after a failed check so Enter is not held again for it).
    func markChecked(_ segment: String) { cache[segment] = Reply(fixed: segment, alternatives: []) }

    // MARK: Layout hints for the model

    /// Words that are not real in their own script, with what the same keys give on the other layout.
    static func layoutHints(for text: String) -> [String: String] {
        let d = Detector.shared
        var hints: [String: String] = [:]
        for raw in text.split(separator: " ") {
            let word = String(raw)
            let scalars = Array(word.unicodeScalars)
            guard scalars.count >= 2 else { continue }
            if scalars.allSatisfy(KeyMap.isMappableASCII) {
                guard scalars.count >= 3 else { continue }
                if scalars.allSatisfy({ (0x30...0x39).contains($0.value) }) { continue }
                guard !d.isEnglishWord(word) else { continue }
                let thai = KeyMap.convert(scalars, direction: .englishToThai)
                let thaiScalars = Array(thai.unicodeScalars)
                let thaiCount = thaiScalars.filter(KeyMap.isThai).count
                // Only a Thai reading that could be Thai is worth showing the model.
                if Double(thaiCount) / Double(scalars.count) >= 0.8, ThaiOrtho.hasVowelOrTone(thaiScalars),
                   ThaiOrtho.violations(thaiScalars) <= max(1, thaiScalars.count / 10) {
                    hints[word] = thai
                }
            } else if KeyMap.isThaiLayoutWord(scalars) {
                let english = KeyMap.convert(scalars, direction: .thaiToEnglish)
                guard english.range(of: "^[A-Za-z0-9][A-Za-z0-9'.-]*$", options: .regularExpression) != nil else { continue }
                let core = english.trimmingCharacters(in: CharacterSet(charactersIn: ".,'-"))
                let valid = ThaiOrtho.isValid(scalars)
                let doubtful = !valid || Self.suspiciousThai(scalars) || d.thaiWordScore(word) < 0.5
                // Garbled Thai gets a hint; so does Thai whose keys spell something English-shaped
                // (พำฟกทำ -> readme): the model decides whether the Thai side is a real word.
                let englishShaped = core.count >= 5 && Detector.looksEnglish(core) && !core.allSatisfy(\.isNumber)
                let shortKnown = core.count >= 2 && d.isEnglishWord(core) && !ThaiOrtho.hasVowelOrTone(scalars)
                    && scalars.contains(where: { KeyMap.shiftLayerThai.contains($0) })
                if scalars.count >= 3 && (doubtful || englishShaped || d.isEnglishWord(core)) || shortKnown {
                    hints[word] = english
                }
            }
        }
        return hints
    }

    /// Thai that is orthographically fine but unlikely: 4+ consonants in a row, or no vowel at all in 4+ letters.
    static func suspiciousThai(_ scalars: [Unicode.Scalar]) -> Bool {
        var run = 0, maxRun = 0
        for sc in scalars {
            if ThaiOrtho.classify(sc) == .consonant { run += 1; maxRun = max(maxRun, run) } else { run = 0 }
        }
        if maxRun >= 4 { return true }
        return scalars.count >= 4 && !ThaiOrtho.hasVowelOrTone(scalars)
    }

    /// The JSON the model receives.
    static func userMessage(for segment: String) -> String {
        var obj: [String: Any] = ["text": segment]
        let hints = layoutHints(for: segment)
        if !hints.isEmpty { obj["layout_hints"] = hints }
        guard let data = try? JSONSerialization.data(withJSONObject: obj), let str = String(data: data, encoding: .utf8) else {
            return segment
        }
        return str
    }

    private func start(_ segment: String) {
        switch backend {
        case .api: request(segment)
        case .claudeCLI: requestViaWarmCLI(segment)
        }
    }

    private func requestViaWarmCLI(_ segment: String) {
        guard Self.claudePath != nil else {
            lastError = "ไม่พบคำสั่ง claude ในเครื่อง"
            return
        }
        warmRequestID += 1
        let myID = warmRequestID
        requestCount += 1
        let started = Date()
        Log.write("llm warm start (\(segment.unicodeScalars.count) keys, \(model.rawValue))")
        inFlightSegment = segment
        onStarted?(segment)
        warm.send(Self.userMessage(for: segment), model: model) { [weak self] reply, error in
            guard let self = self else { return }
            self.inFlightSegment = nil
            defer { self.drainQueue() }
            guard self.warmRequestID == myID else {
                Log.write("llm warm reply ignored (cancelled)")
                return
            }
            guard let reply = reply else {
                let msg = error ?? "error"
                self.lastError = String(msg.prefix(160))
                Log.write("llm warm error: \(msg.prefix(200))")
                self.backoffUntil = Date().addingTimeInterval(msg.contains("logged in") ? 60 : 10)
                self.onFailed?(segment)
                return
            }
            self.lastError = nil
            self.lastLatency = Date().timeIntervalSince(started)
            Log.write(String(format: "llm warm reply in %.1fs, changed=%@, alternatives=%d", self.lastLatency, reply.fixed != segment ? "yes" : "no", reply.alternatives.count))
            self.cache[segment] = reply
            if self.cache.count > 500 { self.cache.removeAll() }
            if reply.fixed != segment { self.onResult?(segment, reply) }
            self.onFinished?(segment, reply)
        }
    }

    /// After a request finishes, run the newest segment that was typed meanwhile (if any).
    private func drainQueue() {
        guard let next = queuedSegment else { return }
        queuedSegment = nil
        if cache[next] == nil, Date() >= backoffUntil { start(next) }
    }

    /// Drops everything: the buffer is gone (Enter, click, app switch, a fix applied).
    func cancel() {
        pending?.cancel()
        pending = nil
        queuedSegment = nil
        task?.cancel()
        task = nil
        if let p = process, p.isRunning {
            Log.write("llm cli cancelled")
            p.terminate()
        }
        process = nil
        processID += 1
        warmRequestID += 1 // a warm reply still in flight will be ignored
    }

    /// Start the background claude process early (CLI backend only).
    func prewarm() {
        guard isReady, backend == .claudeCLI else { return }
        warm.prewarm(model: model)
    }

    /// Stop the background claude process (quit, or backend switched away).
    func shutdown() {
        cancel()
        warm.stop()
    }

    /// Last line of the buffer, without trailing spaces, at most ~160 keystrokes.
    static func segment(of buffer: String) -> String {
        var scalars = Array(buffer.unicodeScalars)
        if let nl = scalars.lastIndex(of: "\n") { scalars = Array(scalars[(nl + 1)...]) }
        while let last = scalars.last, last == " " { scalars.removeLast() }
        if scalars.count > 160 {
            var start = scalars.count - 160
            while start < scalars.count, scalars[start] != " " { start += 1 }
            scalars = Array(scalars[min(start + 1, scalars.count)...])
        }
        return String(String.UnicodeScalarView(scalars))
    }

    // MARK: Request

    private func request(_ segment: String) {
        guard let apiKey = apiKey else { return }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 1024,
            "system": Self.systemPrompt,
            "output_config": [
                "effort": "low",
                "format": [
                    "type": "json_schema",
                    "schema": [
                        "type": "object",
                        "properties": [
                            "fixed": ["type": "string"],
                            "alternatives": ["type": "array", "items": ["type": "string"]],
                        ],
                        "required": ["fixed", "alternatives"],
                        "additionalProperties": false,
                    ],
                ],
            ],
            "messages": [["role": "user", "content": Self.userMessage(for: segment)]],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        requestCount += 1
        let started = Date()

        Log.write("llm api start (\(segment.unicodeScalars.count) keys)")
        inFlightSegment = segment
        onStarted?(segment)
        task = session.dataTask(with: req) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.task = nil
                self.inFlightSegment = nil
                var failed = true
                defer {
                    if failed { self.onFailed?(segment) }
                    self.drainQueue()
                }
                if let error = error as NSError?, error.code == NSURLErrorCancelled { return }
                guard let http = response as? HTTPURLResponse, let data = data else {
                    self.lastError = error?.localizedDescription ?? "network error"
                    return
                }
                switch http.statusCode {
                case 200:
                    break
                case 401, 403:
                    self.lastError = "API key ใช้ไม่ได้ (\(http.statusCode))"
                    self.backoffUntil = Date().addingTimeInterval(60)
                    return
                case 429, 529:
                    self.lastError = "โดนจำกัดอัตรา (\(http.statusCode)) พัก 30 วินาที"
                    self.backoffUntil = Date().addingTimeInterval(30)
                    return
                default:
                    let text = String(data: data, encoding: .utf8) ?? ""
                    self.lastError = "HTTP \(http.statusCode): \(text.prefix(160))"
                    self.backoffUntil = Date().addingTimeInterval(10)
                    return
                }
                guard let reply = Self.parseReply(data) else {
                    self.lastError = "อ่านคำตอบไม่ได้"
                    Log.write("llm api unreadable reply")
                    return
                }
                failed = false
                self.lastError = nil
                self.lastLatency = Date().timeIntervalSince(started)
                Log.write(String(format: "llm api reply in %.1fs, changed=%@, alternatives=%d", self.lastLatency, reply.fixed != segment ? "yes" : "no", reply.alternatives.count))
                self.cache[segment] = reply
                if self.cache.count > 500 { self.cache.removeAll() }
                if reply.fixed != segment { self.onResult?(segment, reply) }
                self.onFinished?(segment, reply)
            }
        }
        task?.resume()
    }

    // MARK: Claude Code CLI backend

    static let jsonSchema = #"{"type":"object","properties":{"fixed":{"type":"string"},"alternatives":{"type":"array","items":{"type":"string"}}},"required":["fixed","alternatives"],"additionalProperties":false}"#

    private func requestViaCLI(_ segment: String) {
        guard let path = Self.claudePath else {
            lastError = "ไม่พบคำสั่ง claude ในเครื่อง"
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = [
            "-p", "--model", model == .haiku ? "haiku" : "opus",
            "--effort", "low",
            "--output-format", "json",
            "--no-session-persistence", "--strict-mcp-config",
            "--tools", "",
            "--system-prompt", Self.systemPrompt,
            "--json-schema", Self.jsonSchema,
            segment,
        ]
        // Run from an empty folder so no project CLAUDE.md or MCP servers are loaded.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("thaitab-cli", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        proc.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") && !$0.key.hasPrefix("ANTHROPIC") }
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        proc.environment = env
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        proc.standardInput = FileHandle.nullDevice

        processID += 1
        let myID = processID
        process = proc
        requestCount += 1
        let started = Date()
        Log.write("llm cli start (\(segment.unicodeScalars.count) keys, \(model.rawValue))")
        proc.terminationHandler = { [weak self] p in
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                guard let self = self, self.processID == myID else { return } // cancelled
                self.process = nil
                defer { self.drainQueue() }
                let text = String(data: data, encoding: .utf8) ?? ""
                guard p.terminationStatus == 0 || !text.isEmpty else {
                    self.lastError = "claude ออกด้วยรหัส \(p.terminationStatus): \(errText.prefix(120))"
                    Log.write("llm cli exit \(p.terminationStatus): \(errText.prefix(200))")
                    self.backoffUntil = Date().addingTimeInterval(15)
                    return
                }
                guard let reply = Self.parseCLIResult(text) else {
                    let msg = Self.cliErrorMessage(text) ?? errText
                    self.lastError = msg.isEmpty ? "อ่านคำตอบจาก claude ไม่ได้" : String(msg.prefix(160))
                    Log.write("llm cli error: \(self.lastError ?? "")")
                    self.backoffUntil = Date().addingTimeInterval(msg.contains("logged in") ? 60 : 15)
                    return
                }
                self.lastError = nil
                self.lastLatency = Date().timeIntervalSince(started)
                Log.write(String(format: "llm cli reply in %.1fs, changed=%@, alternatives=%d", self.lastLatency, reply.fixed != segment ? "yes" : "no", reply.alternatives.count))
                self.cache[segment] = reply
                if self.cache.count > 500 { self.cache.removeAll() }
                if reply.fixed != segment { self.onResult?(segment, reply) }
                self.onFinished?(segment, reply)
            }
        }
        do {
            try proc.run()
        } catch {
            lastError = "เรียก claude ไม่ได้: \(error.localizedDescription)"
            Log.write("llm cli launch failed: \(error.localizedDescription)")
            process = nil
        }
        // Hard timeout.
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            guard let self = self, self.processID == myID, let p = self.process, p.isRunning else { return }
            p.terminate()
            self.lastError = "claude ตอบช้าเกิน 25 วินาที"
            Log.write("llm cli timeout")
        }
    }

    /// The CLI prints one JSON object (possibly after stray log lines).
    static func reply(from obj: [String: Any]) -> Reply? {
        guard let fixed = obj["fixed"] as? String else { return nil }
        let alts = (obj["alternatives"] as? [String] ?? []).filter { !$0.isEmpty }
        return Reply(fixed: fixed, alternatives: Array(alts.prefix(2)))
    }

    static func parseCLIResult(_ raw: String) -> Reply? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}") else { return nil }
        let json = raw[start...end]
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        if (root["is_error"] as? Bool) == true { return nil }
        if let structured = root["structured_output"] as? [String: Any], let r = reply(from: structured) { return r }
        guard let result = root["result"] as? String else { return nil }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any],
           let r = reply(from: obj) { return r }
        return trimmed.isEmpty ? nil : Reply(fixed: trimmed, alternatives: [])
    }

    static func cliErrorMessage(_ raw: String) -> String? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
              let root = try? JSONSerialization.jsonObject(with: Data(raw[start...end].utf8)) as? [String: Any] else { return nil }
        return root["result"] as? String
    }

    static func parseReply(_ data: Data) -> Reply? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let stop = root["stop_reason"] as? String, stop == "refusal" { return nil }
        guard let content = root["content"] as? [[String: Any]] else { return nil }
        let text = content.compactMap { block -> String? in
            (block["type"] as? String) == "text" ? block["text"] as? String : nil
        }.joined()
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        return reply(from: obj)
    }
}
