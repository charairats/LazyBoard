import Foundation

/// Second layer: after a short pause in typing, asks Claude to fix genuine typos
/// (adjacent-key slips, wrong Thai vowels/tones, misspelled English) in the whole message.
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

    /// Workplace tone: which ending particle to use, or off. Asked per message, so the writer's own voice is never guessed.
    enum Polite: String, CaseIterable {
        case off
        case khrap = "ครับ"
        case kha = "ค่ะ"
        var title: String {
            switch self {
            case .off: return "ปิด"
            case .khrap: return "เปิด (ลงท้าย ครับ)"
            case .kha: return "เปิด (ลงท้าย ค่ะ)"
            }
        }
    }

    struct Reply: Equatable {
        let fixed: String
        let alternatives: [String]
        /// The model is not confident in "fixed", so a stronger one should look again.
        var unsure = false
        var options: [String] { [fixed] + alternatives.filter { $0 != fixed } }
    }

    var isEnabled = true
    /// Append one or two fitting emojis to the end of each checked line.
    var emojiMode = false { didSet { if emojiMode != oldValue { cache.removeAll() } } }
    /// Rewrite each checked line in a polite workplace tone; shown as a fix to accept with Tab, never sent by itself.
    var polite: Polite = .off { didSet { if polite != oldValue { cache.removeAll() } } }
    var backend: Backend = .claudeCLI
    var model: Model = .haiku
    var apiKey: String?
    private var process: Process?
    private var processID: Int = 0
    private let warm = WarmClaude()
    /// The stronger model in its own process, so the fast one stays warm: it re-checks a message the fast one
    /// passed although the local check doubted it, and does the after-send check.
    private let warmStrong = WarmClaude()
    static let strongModel: Model = .opus
    private var warmRequestID = 0
    /// Segment that arrived while a request was in flight; requested when that one finishes.
    private var queuedSegment: String?
    var debounce: TimeInterval = 0.9
    static let maxSegmentKeys = 1500
    /// (original segment, reply), only when something changed. Delivered on the main thread.
    var onResult: ((String, Reply) -> Void)?
    /// Every completed request (original, reply), changed or not. Used by the CLI test mode and the Enter hold.
    var onFinished: ((String, Reply) -> Void)?
    /// A request that produced no usable reply (error, timeout, refusal).
    var onFailed: ((String) -> Void)?
    /// The fast model was unsure about a held segment and the stronger one is now checking it.
    var onEscalated: ((String) -> Void)?
    /// Segments checked at Enter: if the fast model is unsure about one, the stronger one gets it.
    private var escalateIfUnsure = Set<String>()
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
        c.timeoutIntervalForRequest = 60
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
    - After นะ and question words the particle is คะ, never ค่ะ: fix "นะค่ะ" -> "นะคะ", "ไหมค่ะ" -> "ไหมคะ", \
    "มั้ยค่ะ" -> "มั้ยคะ", "หรอค่ะ" -> "หรอคะ". Statements such as "ได้ค่ะ" and "เปล่าค่ะ" stay as they are.
    - Keep the meaning, word order, slang, Thai particles (ค่ะ ครับ นะ อะ แงๆ), emoji, punctuation, \
    spacing, line breaks and letter case. Do not rewrite style, do not translate, do not add or remove \
    words, never answer or comment on the message. Thai-spelled English dev words (เทส รีเทส ดีพลอย บัค \
    เช็ค รัน คอมมิต) are normal and stay as written; never replace them with formal Thai. So is chat slang and \
    its casual spelling (เริ่ด ปัง จึ้ง ฉ่ำ ตึง รอแปป ผิดบาน ป่าว ค้าบ งับ): it is meant, never a typo.
    - Leave real names, product names, code identifiers, URLs and well-known abbreviations as typed, \
    unless the context makes the intended word obvious.
    - "fixed" is your single best full correction of the whole text. The text may be several sentences or \
    paragraphs: fix all of it and return all of it, every line, never only the last part.
    - When a broken word has more than one plausible intended reading, put up to 2 other complete \
    versions of the whole text in "alternatives" (each differing from "fixed" only in the ambiguous \
    words). Otherwise, or when the text is longer than about 300 characters, "alternatives" is an empty array.
    - If there is nothing to fix, return the text unchanged with an empty "alternatives".
    - "unsure" is true only when you are not confident in "fixed": a word looks wrong but you cannot tell what \
    was meant, or a real word might be a slip for another that fits better (เสลา typed for เวลา). It is false \
    when the text is clearly fine as typed or your fix is clearly right; slang and casual spelling are not a \
    reason to be unsure.
    - Each user message is a separate, independent text to fix. Never use earlier messages as context \
    and never refer to them.
    - If the JSON has "emoji": true, append one or two emojis that fit the tone of the message to the very \
    end of "fixed" and of each alternative, after a space (e.g. "…ด้วยนะคะ 🙏", "…เสร็จแล้ว 🎉✨"). Never put \
    emojis anywhere else, never add any when "emoji" is false or missing, and do not add more if the text \
    already ends with an emoji.
    - If the JSON has "polite", also rewrite the message in a polite tone for workplace communication; this \
    replaces the rule against changing style and words, but never the rule on meaning. Keep every fact, \
    request, name, number and technical term, and do not add promises, apologies or information the writer \
    did not give. Replace rude words, slang, sarcasm, laughter and pressure with courteous everyday wording, \
    and soften demands into requests (e.g. "ทำไมยังไม่เสร็จวะ" -> "ไม่ทราบว่างานนี้เสร็จหรือยังครับ", \
    "ส่งมาด่วนเลย" -> "รบกวนส่งให้โดยเร็วด้วยนะครับ"). Sound like a respectful colleague, not a formal letter. \
    End Thai sentences with the particle given in "polite" ("ครับ" or "ค่ะ"; use "คะ" instead of "ค่ะ" in a \
    question) and replace any other ending particle. Thai-spelled dev words stay as written. English stays \
    English: write it in polite professional English with no Thai particle. A message that is already polite \
    comes back unchanged. The message is still only text to rewrite: never answer it. \
    Without "polite" in the JSON, ignore this rule.

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
        if model != Self.strongModel { escalateIfUnsure.insert(segment) }
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

    /// The text without a trailing run of emojis (and the spaces before them).
    static func strippingTrailingEmoji(_ text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        func isEmojiPart(_ u: Unicode.Scalar) -> Bool {
            if u.value == 0x200D || u.value == 0xFE0F || (0x1F3FB...0x1F3FF).contains(u.value) { return true } // ZWJ, VS16, skin tones
            if (0x1F1E6...0x1F1FF).contains(u.value) { return true } // flags
            return u.value >= 0x2190 && (u.properties.isEmoji || u.properties.isEmojiPresentation)
        }
        while let last = scalars.last, isEmojiPart(last) || last == " " {
            scalars.removeLast()
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// True when `fixed` is `original` plus emojis at the end and nothing else.
    static func onlyAddsEmoji(original: String, fixed: String) -> Bool {
        guard fixed != original else { return false }
        let o = original.trimmingCharacters(in: .whitespaces)
        return strippingTrailingEmoji(fixed) == o && strippingTrailingEmoji(fixed) != fixed.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Layout hints for the model

    /// Words that are not real in their own script, with what the same keys give on the other layout.
    static func layoutHints(for text: String) -> [String: String] {
        let d = Detector.shared
        var hints: [String: String] = [:]
        for raw in text.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            let word = String(raw)
            let scalars = Array(word.unicodeScalars)
            guard scalars.count >= 2 else { continue }
            if scalars.allSatisfy(KeyMap.isMappableASCII) {
                guard scalars.count >= 3 else { continue }
                if scalars.allSatisfy({ (0x30...0x39).contains($0.value) }) { continue }
                // Words joined by a slash (in progress/done) are each English, not one garbled word.
                guard !word.split(separator: "/").allSatisfy({ d.isEnglishWord(String($0)) }) else { continue }
                let thai = KeyMap.convert(scalars, direction: .englishToThai)
                let thaiScalars = Array(thai.unicodeScalars)
                let thaiCount = thaiScalars.filter(KeyMap.isThai).count
                // Only a Thai reading that could be Thai is worth showing the model.
                if Double(thaiCount) / Double(scalars.count) >= 0.8, ThaiOrtho.hasVowelOrTone(thaiScalars),
                   ThaiOrtho.violations(thaiScalars) <= max(1, thaiScalars.count / 10) {
                    hints[word] = thai
                }
            } else if KeyMap.isThaiLayoutWord(scalars) {
                if Detector.commonShortThai.contains(word) || Detector.slangThai.contains(word) { continue }
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

    /// Emoji and polite modes rewrite the message, so Enter always waits for Claude in them.
    var rewrites: Bool { emojiMode || polite != .off }

    /// Why the local check doubts a word.
    enum Doubt: String {
        case english = "english-unknown"
        case thai = "thai-unknown"
        case typo = "thai-typo"
        case layout
        /// A real but uncommon word one slipped key from an everyday one (เสลา for เวลา).
        case nearCommon = "near-common"
    }

    /// An everyday Thai word the same length as `word`, one neighbouring key away from it.
    static func commonNeighbour(of word: String) -> String? {
        guard !Detector.commonShortThai.contains(word), !Detector.slangThai.contains(word) else { return nil }
        let scalars = Array(word.unicodeScalars)
        guard scalars.count >= 3 else { return nil }
        for (i, sc) in scalars.enumerated() {
            for other in KeyMap.thaiNeighbours[sc] ?? [] {
                var variant = scalars
                variant[i] = other
                let candidate = String(String.UnicodeScalarView(variant))
                if Detector.commonShortThai.contains(candidate) { return candidate }
            }
        }
        return nil
    }

    /// True when every word is already a real Thai or English word, or a link, number or bit of code.
    /// Anything in doubt is false, and Claude checks it as before.
    static func looksFine(_ text: String) -> Bool { doubts(in: text).isEmpty }

    /// The words that do not look right, and why. For a Thai run without spaces, the pieces that are not words.
    static func doubts(in text: String) -> [(word: String, why: Doubt)] {
        let d = Detector.shared
        var found: [(word: String, why: Doubt)] = []
        for raw in text.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            let token = String(raw)
            if token.contains("://") || token.contains("@") || token.hasPrefix("~") || token.hasPrefix("#") { continue }
            // File names and identifiers: KeyMonitor.swift, snake_case.
            if token.range(of: "^[A-Za-z0-9_-]{3,}\\.[a-z]{2,5}$|^[A-Za-z]+_[A-Za-z0-9_]+$", options: .regularExpression) != nil { continue }
            // Thai typed on the English layout uses the digit and / keys too (gliH0ch]loj8tjt, /yj':hkp = ฝั่งซ้าย),
            // so those are only code or paths when the keys do not read as Thai.
            let scalars = Array(token.unicodeScalars)
            if scalars.count >= 3, scalars.allSatisfy(KeyMap.isMappableASCII), readsAsThai(scalars),
               !token.split(separator: "/").allSatisfy({ d.isEnglishWord(String($0)) }) {
                found.append((token, .layout))
                continue
            }
            if token.hasPrefix("/") { continue }
            if let hint = layoutHints(for: token)[token] {
                // Real Thai whose keys spell nothing English (แก้ใน -> cdh.o) is just Thai; หแพรยะ -> script is not.
                let core = hint.trimmingCharacters(in: CharacterSet(charactersIn: ".,'-"))
                guard token.unicodeScalars.allSatisfy(KeyMap.isThai), Detector.isRealThai(token), !d.isEnglishWord(core),
                      !(core.count >= 5 && core.allSatisfy(\.isLetter) && Detector.looksEnglish(core)) else {
                    found.append((token, .layout))
                    continue
                }
            }
            // Versions and the like: v1.2.3, k8s.
            let code = token.contains(where: \.isNumber)
            for run in runs(of: token) {
                if KeyMap.isThai(run.unicodeScalars.first!) {
                    if ThaiTypos.fix(run) != nil {
                        found.append((run, .typo))
                    } else if !ThaiOrtho.isValid(run.unicodeScalars) || !Detector.isRealThai(run) {
                        let unknown = SuggestionPanel.tokens(run).filter { !Detector.isRealThai($0) }
                        found += (unknown.isEmpty ? [run] : unknown).map { ($0, .thai) }
                    } else if !Detector.slangThai.contains(run) {
                        // Word breaking does not know slang (ค้าบ -> ค้า + บ): a piece of a slang word in the run is fine.
                        let slangHere = Detector.slangThai.filter { run.contains($0) }
                        found += SuggestionPanel.tokens(run)
                            .filter { t in commonNeighbour(of: t) != nil && !slangHere.contains { $0.count > t.count && $0.contains(t) } }
                            .map { ($0, .nearCommon) }
                    }
                } else if !code {
                    let rest = run.dropFirst()
                    // camelCase, LazyBoard, iPhone and acronyms are names, not misspellings.
                    if rest.contains(where: \.isUppercase) && (rest.contains(where: \.isLowercase) || run.count <= 6) { continue }
                    if !d.isEnglishWord(run) { found.append((run, .english)) }
                }
            }
        }
        return found
    }

    /// Keys that give mostly Thai letters, with a vowel or tone, on the Thai layout.
    private static func readsAsThai(_ scalars: [Unicode.Scalar]) -> Bool {
        let thai = Array(KeyMap.convert(scalars, direction: .englishToThai).unicodeScalars)
        // A slip or two is fine (แ้ล for แล้ว); camelCase code (useState) breaks Thai spelling all over.
        return Double(thai.filter(KeyMap.isThai).count) / Double(thai.count) >= 0.8 && ThaiOrtho.hasVowelOrTone(thai)
            && ThaiOrtho.violations(thai) <= max(1, thai.count / 6)
    }

    /// After a message went out unchecked, ask the stronger model anyway, only to measure what the local check
    /// lets through. Nothing is shown. Skipped while it is busy, and on the API backend.
    func shadowCheck(_ segment: String, completion: @escaping (Reply) -> Void) {
        guard isReady, backend == .claudeCLI, !warmStrong.isBusy, Date() >= backoffUntil else {
            Log.write("shadow: skipped")
            return
        }
        warmStrong.send(Self.userMessage(for: segment), model: Self.strongModel) { reply, _ in
            guard let reply = reply else { Log.write("shadow: no reply"); return }
            completion(reply)
        }
    }

    /// Whether a message the fast model passed can go to the stronger one right now.
    var canEscalate: Bool { isReady && backend == .claudeCLI && model != Self.strongModel && !warmStrong.isBusy }

    func prewarmStrong() {
        guard canEscalate else { return }
        warmStrong.prewarm(model: Self.strongModel)
    }

    /// Ask the stronger model about a segment the fast one left unchanged. The reply arrives like any other.
    func escalate(_ segment: String) {
        warmRequestID += 1
        let myID = warmRequestID
        let started = Date()
        Log.write("llm strong start (\(segment.unicodeScalars.count) keys, \(Self.strongModel.rawValue))")
        warmStrong.send(Self.userMessage(for: segment, emoji: emojiMode, polite: polite), model: Self.strongModel) { [weak self] reply, error in
            guard let self = self else { return }
            guard self.warmRequestID == myID else {
                Log.write("llm strong reply ignored (cancelled)")
                return
            }
            guard let reply = reply else {
                Log.write("llm strong error: \((error ?? "error").prefix(200))")
                self.onFailed?(segment)
                return
            }
            Log.write(String(format: "llm strong reply in %.1fs, changed=%@", Date().timeIntervalSince(started), reply.fixed != segment ? "yes" : "no"))
            self.cache[segment] = reply
            if reply.fixed != segment { self.onResult?(segment, reply) }
            self.onFinished?(segment, reply)
        }
    }

    /// The Thai and the English letter runs in one space-separated token ("ส่งPRแล้ว" -> ส่ง, PR, แล้ว).
    private static func runs(of token: String) -> [String] {
        var result: [String] = []
        var current = String.UnicodeScalarView()
        var currentThai = false
        func flush() {
            var run = String(current)
            while let last = run.last, "'-".contains(last) { run.removeLast() }
            if !run.isEmpty { result.append(run) }
            current = String.UnicodeScalarView()
        }
        for sc in token.unicodeScalars {
            let thai = KeyMap.isThai(sc) && !(0x0E50...0x0E59).contains(sc.value) && sc != "ๆ" && sc != "ฯ"
            let latin = sc.value < 0x80 && (CharacterSet.letters.contains(sc) || (!current.isEmpty && !currentThai && "'-".unicodeScalars.contains(sc)))
            if (thai || latin), current.isEmpty || thai == currentThai {
                current.append(sc)
                currentThai = thai
            } else {
                flush()
                if thai || latin { current.append(sc); currentThai = thai }
            }
        }
        flush()
        return result
    }

    /// The JSON the model receives.
    static func userMessage(for segment: String, emoji: Bool = false, polite: Polite = .off) -> String {
        var obj: [String: Any] = ["text": segment]
        if emoji { obj["emoji"] = true }
        if polite != .off { obj["polite"] = polite.rawValue }
        let hints = layoutHints(for: segment)
        if !hints.isEmpty { obj["layout_hints"] = hints }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: .withoutEscapingSlashes), let str = String(data: data, encoding: .utf8) else {
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
        warm.send(Self.userMessage(for: segment, emoji: emojiMode, polite: polite), model: model) { [weak self] reply, error in
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
            Log.write(String(format: "llm warm reply in %.1fs, changed=%@, alternatives=%d, unsure=%@", self.lastLatency,
                             reply.fixed != segment ? "yes" : "no", reply.alternatives.count, reply.unsure ? "yes" : "no"))
            if self.escalateIfUnsure.remove(segment) != nil, reply.unsure {
                if self.canEscalate {
                    Log.write("cascade: fast model unsure, asking the strong one")
                    self.onEscalated?(segment)
                    self.escalate(segment)
                    return
                }
                Log.write("cascade: skipped, strong model busy")
            }
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
        escalateIfUnsure.removeAll()
        inFlightSegment = nil // so the same line asked again is queued, not assumed to be on its way
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
        warmStrong.stop()
    }

    /// The whole message: every line, without trailing blanks, at most maxSegmentKeys keystrokes.
    static func segment(of buffer: String) -> String {
        var scalars = Array(buffer.unicodeScalars)
        while let last = scalars.last, last == " " || last == "\n" { scalars.removeLast() }
        if scalars.count > maxSegmentKeys {
            scalars = Array(scalars[wordStart(in: scalars, from: scalars.count - maxSegmentKeys)...])
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Where to cut a long text at or just after `from`. Thai can go a long way without a space,
    /// so give up on finding one soon rather than throw most of the text away.
    static func wordStart(in scalars: [Unicode.Scalar], from: Int) -> Int {
        let window = scalars[from..<min(from + 60, scalars.count)]
        return window.firstIndex { $0 == " " || $0 == "\n" }.map { $0 + 1 } ?? from
    }

    /// The text after the last line break.
    static func lastLine(of text: String) -> String {
        guard let nl = text.unicodeScalars.lastIndex(of: "\n") else { return text }
        return String(text.unicodeScalars[text.unicodeScalars.index(after: nl)...])
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
            "max_tokens": 4096,
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
                            "unsure": ["type": "boolean"],
                        ],
                        "required": ["fixed", "alternatives", "unsure"],
                        "additionalProperties": false,
                    ],
                ],
            ],
            "messages": [["role": "user", "content": Self.userMessage(for: segment, emoji: emojiMode, polite: polite)]],
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

    static let jsonSchema = #"{"type":"object","properties":{"fixed":{"type":"string"},"alternatives":{"type":"array","items":{"type":"string"}},"unsure":{"type":"boolean"}},"required":["fixed","alternatives","unsure"],"additionalProperties":false}"#

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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lazyboard-cli", isDirectory: true)
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
        return Reply(fixed: fixed, alternatives: Array(alts.prefix(2)), unsure: obj["unsure"] as? Bool ?? false)
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
