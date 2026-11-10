import Foundation

/// Second layer: after a short pause in typing, asks Claude to fix genuine typos
/// (adjacent-key slips, wrong Thai vowels/tones, misspelled English) in the whole message.
/// Only runs when the layout detector found nothing.
final class LLMSuggester {
    enum Model: String, CaseIterable {
        case haiku = "claude-haiku-5-5"
        case sonnet = "claude-sonnet-5-5"
        case opus = "claude-opus-5-5"
        var title: String {
            switch self {
            case .haiku: return "Haiku 5.5"
            case .sonnet: return "Sonnet 5.5"
            case .opus: return "Opus 5.5"
            }
        }
        /// The alias the Claude CLI takes for --model.
        var cliName: String {
            switch self {
            case .haiku: return "haiku"
            case .sonnet: return "sonnet"
            case .opus: return "opus"
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
    /// The Ctrl+Enter model in its own process, so the fast one stays warm.
    private let warmStrong = WarmClaude()
    /// The after-send check, always Opus through the CLI, in a process of its own.
    private let warmShadow = WarmClaude()
    static let shadowModel: Model = .opus
    /// Ctrl+Enter asks this model directly, in one call (no fast model first). Sonnet or Opus, from the menu.
    var strongModel: Model = .sonnet
    /// Replies from the Ctrl+Enter model, so a later Ctrl+Enter on the same text does not settle for the fast model's.
    private var strongCache: [String: Reply] = [:]
    /// Reads the whole current line from the text field when it can, so a while-typing check sees the full
    /// sentence and not only what was typed since the last click. Returns the (possibly updated) buffer.
    var currentText: (() -> String)?
    private var warmRequestID = 0
    /// Segment that arrived while a request was in flight; requested when that one finishes.
    private var queuedSegment: String?
    /// Pause before a while-typing check: long enough to skip mid-sentence thinking pauses (each check is a paid call).
    var debounce: TimeInterval = 2.0
    static let maxSegmentKeys = 1500
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
    var lastError: String?
    private(set) var requestCount = 0
    private(set) var lastLatency: TimeInterval = 0

    private var pending: DispatchWorkItem?
    private var task: URLSessionDataTask?
    /// The stronger model's API request, when the fast one was unsure (API backend).
    private var strongTask: URLSessionDataTask?
    /// Which API request is current: a reply to an older one (cancelled or replaced) touches nothing.
    private var apiRequestID = 0
    private var strongAPIID = 0
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
    - "suspects", when present, lists words a local check doubted. Look at each one in its sentence: fix it when \
    it is a slip, including a real word that does not fit the context (หลับ typed for กลับ, เลน for เลย); leave \
    it as typed when it is fine (a name, slang, a real word that fits). Other words can still need fixing too.
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
        guard Self.segment(of: buffer).unicodeScalars.count >= 6 else { queuedSegment = nil; return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // At the pause, not on every key: the whole line from the field when it can be read.
            let segment = Self.segment(of: self.currentText?() ?? buffer)
            guard segment.unicodeScalars.count >= 6 else { self.queuedSegment = nil; return }
            if let reply = self.cache[segment] {
                if reply.fixed != segment { self.onResult?(segment, reply) }
                return
            }
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

    /// Check right now (no debounce), e.g. when Enter is held back. `strong`: Ctrl+Enter, the chosen
    /// Sonnet or Opus in one call, no fast model first. Returns the segment being checked.
    @discardableResult
    func checkNow(_ buffer: String, strong: Bool = false) -> String? {
        pending?.cancel()
        pending = nil
        guard isReady else { return nil }
        let segment = Self.segment(of: buffer)
        guard segment.unicodeScalars.count >= 6 else { return nil }
        if let reply = strong ? strongCache[segment] : cache[segment] {
            DispatchQueue.main.async { [weak self] in
                if reply.fixed != segment { self?.onResult?(segment, reply) }
                self?.onFinished?(segment, reply)
            }
            return segment
        }
        if strong {
            askStrong(segment)
            return segment
        }
        if isBusy {
            if inFlightSegment != segment { queuedSegment = segment }
            return segment
        }
        start(segment)
        return segment
    }

    /// An automatic layout fix changed the line under a check: drop that check (its text is gone) and check
    /// the corrected line at once, so the fix does not cost the check. Returns the segment sent.
    @discardableResult
    func recheck(_ buffer: String) -> String? {
        pending?.cancel()
        pending = nil
        queuedSegment = nil
        task?.cancel()
        task = nil
        apiRequestID += 1
        inFlightSegment = nil
        if warm.isBusy { warmRequestID += 1 } // a warm reply still in flight will be ignored
        guard isReady, Date() >= backoffUntil else { return nil }
        let segment = Self.segment(of: buffer)
        guard segment.unicodeScalars.count >= 6 else { return nil }
        if let reply = cache[segment] {
            if reply.fixed != segment { onResult?(segment, reply) }
            return nil
        }
        if isBusy {
            queuedSegment = segment
            return segment
        }
        start(segment)
        return segment
    }

    /// Stop the debounce only: a request already on its way keeps going.
    func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    /// Something is on its way or waiting (a debounce, a request, a queued line).
    var hasWork: Bool { pending != nil || inFlightSegment != nil || queuedSegment != nil }

    /// Quiet check after an odd word: the fast model only, at once, no cascade. Returns the segment sent.
    @discardableResult
    func checkQuiet(_ buffer: String) -> String? {
        pending?.cancel()
        pending = nil
        guard isReady, Date() >= backoffUntil else { return nil }
        let segment = Self.segment(of: buffer)
        guard segment.unicodeScalars.count >= 6 else { return nil }
        if let reply = cache[segment] {
            if reply.fixed != segment { onResult?(segment, reply) }
            return nil
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
            if looksLikeCode(token) { continue }
            if scalars.count >= 3, scalars.allSatisfy(KeyMap.isMappableASCII), readsAsThai(scalars),
               !token.split(separator: "/").allSatisfy({ d.isEnglishWord(String($0)) }) {
                found.append((token, .layout))
                continue
            }
            if token.hasPrefix("/") { continue }
            let thaiPart = String(String.UnicodeScalarView(token.unicodeScalars.filter { $0 != "ๆ" }))
            if token.unicodeScalars.allSatisfy({ KeyMap.isThai($0) }), isDrawnOut(thaiPart) { continue }
            if let hint = layoutHints(for: token)[token] {
                // Real Thai whose keys spell nothing English (แก้ใน -> cdh.o) is just Thai; หแพรยะ -> script is not.
                let core = hint.trimmingCharacters(in: CharacterSet(charactersIn: ".,'-"))
                // Real Thai that splits into dictionary words (หน่อย, ทำได้ -> mewfh) is Thai even when its keys look
                // English-shaped; only keys that spell a real English word (หแพรยะ -> script) make it a layout slip.
                guard token.unicodeScalars.allSatisfy({ KeyMap.isThai($0) || $0 == "ๆ" }), Detector.isRealThai(token),
                      ThaiOrtho.isValid(token.unicodeScalars), !d.isEnglishWord(core) else {
                    found.append((token, .layout))
                    continue
                }
            }
            // Versions and the like: v1.2.3, k8s.
            let code = token.contains(where: \.isNumber)
            for run in runs(of: token) {
                if KeyMap.isThai(run.unicodeScalars.first!) {
                    if isDrawnOut(run) { continue }
                    if ThaiTypos.fix(run, slips: false) != nil {
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

    /// Numbers, tickers, acronyms, camelCase names and branch or path names: never Thai typed on the wrong layout.
    static func looksLikeCode(_ token: String) -> Bool {
        let scalars = Array(token.unicodeScalars)
        guard scalars.allSatisfy({ $0.value < 0x80 }) else { return false }
        let letters = scalars.filter { CharacterSet.letters.contains($0) }
        // 1:1, 10000, 514.37
        if letters.isEmpty { return true }
        // BTC, ABCD&P500E: a few capitals, maybe digits and &.
        if letters.count >= 2, letters.count <= 6, letters.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) }),
           scalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "&" }) { return true }
        // ekycOnboarded, gRPC, getUserName
        if token.range(of: "^[a-z]{2,}[A-Z][a-z]{2,}([A-Z][a-z0-9]*)*$|^[a-z]+[A-Z]{2,}[a-z0-9]*$", options: .regularExpression) != nil {
            return true
        }
        // feature/change-sim-to-esim: most pieces are English words.
        let parts = token.split(whereSeparator: { $0 == "/" || $0 == "-" || $0 == "_" }).map(String.init)
            .filter { $0.count >= 2 && $0.allSatisfy(\.isLetter) }
        if parts.count >= 3 {
            let english = parts.filter { Detector.shared.isEnglishWord($0) }.count
            if english * 2 >= parts.count { return true }
        }
        return false
    }

    /// Chat stretches the last sound (ง๊าบบบ, เล๊ยยยย, ฮ๊าาา, แงงง): three or more of the same letter at the end.
    static func isDrawnOut(_ run: String) -> Bool {
        let scalars = Array(run.unicodeScalars)
        guard let last = scalars.last, scalars.count >= 3 else { return false }
        return scalars.suffix(3).allSatisfy { $0 == last } || (scalars.suffix(2).allSatisfy { $0 == last } && run.hasSuffix("ๆ") == false && Detector.isRealThai(String(String.UnicodeScalarView(scalars.dropLast()))))
    }

    /// Keys that give mostly Thai letters, with a vowel or tone, on the Thai layout.
    private static func readsAsThai(_ scalars: [Unicode.Scalar]) -> Bool {
        let thai = Array(KeyMap.convert(scalars, direction: .englishToThai).unicodeScalars)
        // A slip or two is fine (แ้ล for แล้ว); camelCase code (useState) breaks Thai spelling all over.
        return Double(thai.filter(KeyMap.isThai).count) / Double(thai.count) >= 0.8 && ThaiOrtho.hasVowelOrTone(thai)
            && ThaiOrtho.violations(thai) <= max(1, thai.count / 6)
    }

    /// After a message went out unchecked, ask the stronger model anyway, only to measure what the local check
    /// lets through. Nothing is shown. Always through the Claude CLI (the subscription), whatever the backend:
    /// never through the API, which would bill every sent message. Skipped quietly when the CLI is not usable.
    func shadowCheck(_ segment: String, completion: @escaping (Reply) -> Void) {
        guard cliUsable, !warmShadow.isBusy, backend == .api || Date() >= backoffUntil else {
            Log.write(cliSignedOut ? "shadow: skipped, cli unavailable" : "shadow: skipped")
            return
        }
        warmShadow.send(Self.userMessage(for: segment), model: Self.shadowModel) { [weak self] reply, error in
            guard let self = self else { return }
            guard let raw = reply else {
                Log.write("shadow: no reply" + (error.map { ": \($0.prefix(120))" } ?? ""))
                self.noteCLIFailure(error)
                return
            }
            self.noteCLISuccess()
            completion(self.guarded(raw, for: segment))
        }
    }

    // MARK: Claude CLI health

    /// The CLI failed to log in, or gave no answer several times in a row: no more CLI requests
    /// (shadow checks above all) until a CLI call works again, the menu's Retry, or a relaunch.
    private(set) var cliSignedOut = false
    private var cliFailures = 0
    static let cliFailureLimit = 3

    /// The CLI is installed, switched on and not known to be signed out.
    var cliUsable: Bool { isEnabled && Self.claudePath != nil && !cliSignedOut }

    static func isLoginError(_ msg: String) -> Bool {
        msg.contains("logged in") || msg.contains("authenticate") || msg.contains("OAuth") || msg.contains("/login")
    }

    private func noteCLIFailure(_ error: String?) {
        guard error != "busy" else { return }
        let login = error.map(Self.isLoginError) ?? false
        cliFailures += 1
        guard !cliSignedOut, login || cliFailures >= Self.cliFailureLimit else { return }
        cliSignedOut = true
        Log.write("cli: marked unavailable (\(login ? "login error" : "\(cliFailures) failures in a row"))")
        warmStrong.stop()
    }

    private func noteCLISuccess() {
        cliFailures = 0
        guard cliSignedOut else { return }
        cliSignedOut = false
        Log.write("cli: available again")
    }

    private var probing = false
    private var lastProbeOK: Bool?

    /// Ask the CLI whether it is signed in (`claude auth status`: no model call, nothing billed) and update the flag.
    /// Run when the menu opens, every minute while the CLI is flagged, and from the menu's warning line.
    func probeCLI(_ done: ((Bool) -> Void)? = nil) {
        guard isEnabled, let path = Self.claudePath, !probing else { done?(false); return }
        probing = true
        DispatchQueue.global(qos: .utility).async {
            let ok = Self.cliSignedIn(path)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.probing = false
                if ok {
                    if self.cliSignedOut { Log.write("cli: probe says signed in") }
                    self.noteCLISuccess()
                    if let e = self.lastError, Self.isLoginError(e) || e.contains("login") { self.lastError = nil }
                } else {
                    if self.lastProbeOK != false { Log.write("cli: probe says signed out") }
                    self.cliSignedOut = true
                }
                self.lastProbeOK = ok
                done?(ok)
            }
        }
    }

    /// `claude auth status` prints JSON with "loggedIn". Same environment as the real requests.
    static func cliSignedIn(_ path: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["auth", "status"]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lazyboard-cli", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") && !$0.key.hasPrefix("ANTHROPIC") }
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard let text = String(data: data, encoding: .utf8), let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let obj = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any] else { return false }
        return obj["loggedIn"] as? Bool ?? false
    }

    /// Menu Retry: try the CLI again.
    func resetCLIHealth() {
        cliFailures = 0
        if cliSignedOut { Log.write("cli: retry from menu") }
        cliSignedOut = false
    }

    private var strongRequestID = 0

    /// Start the Ctrl+Enter model's CLI process early (CLI backend only; the API needs no warming).
    func prewarmStrong() {
        guard isReady, backend == .claudeCLI, !cliSignedOut, !warmStrong.isBusy else { return }
        warmStrong.prewarm(model: strongModel)
    }

    /// Ctrl+Enter: the chosen Sonnet or Opus checks the segment in one call. The reply arrives like any other.
    private func askStrong(_ segment: String) {
        if backend == .api {
            strongTask?.cancel() // an earlier Ctrl+Enter still on its way: this one wins
            strongTask = nil
            request(segment, strong: true)
            return
        }
        strongRequestID += 1
        let myID = strongRequestID
        let started = Date()
        let useModel = strongModel
        requestCount += 1
        if warmStrong.isBusy { warmStrong.stop() } // an earlier Ctrl+Enter still on its way: this one wins
        Log.write("llm strong start (\(segment.unicodeScalars.count) keys, \(useModel.rawValue), cli)")
        warmStrong.send(Self.userMessage(for: segment, emoji: emojiMode, polite: polite), model: useModel) { [weak self] reply, error in
            guard let self = self else { return }
            guard self.strongRequestID == myID else {
                Log.write("llm strong reply ignored (cancelled)")
                return
            }
            guard let raw = reply else {
                let msg = error ?? "error"
                Log.write("llm strong error: \(msg.prefix(200))")
                if Self.isLoginError(msg) {
                    self.lastError = "Claude Code login หมดอายุ: รัน claude ใน Terminal แล้ว /login หรือใช้ API key แทน"
                }
                self.noteCLIFailure(error)
                self.onFailed?(segment)
                return
            }
            self.noteCLISuccess()
            let reply = self.guarded(raw, for: segment)
            Log.write(String(format: "llm strong reply in %.1fs, changed=%@", Date().timeIntervalSince(started), reply.fixed != segment ? "yes" : "no"))
            self.storeStrong(segment, reply)
            if reply.fixed != segment { self.onResult?(segment, reply) }
            self.onFinished?(segment, reply)
        }
    }

    private func storeStrong(_ segment: String, _ reply: Reply) {
        strongCache[segment] = reply
        cache[segment] = reply
        if strongCache.count > 200 { strongCache.removeAll() }
        if cache.count > 500 { cache.removeAll() }
    }

    // MARK: Whole words added or removed

    /// A fix that adds or drops a whole real word (คะ put in, ทำ left out) is not a typo fix: the writer's text
    /// stays as typed. Rewrites (emoji, polite) add words on purpose and are left alone.
    func guarded(_ reply: Reply, for segment: String) -> Reply {
        guard !rewrites else { return reply }
        let options = reply.options.filter { !Self.addsOrDropsWords(from: segment, to: $0) }
        guard options.count != reply.options.count else { return reply }
        Log.write("llm fix dropped: adds or removes words (\(reply.options.count - options.count) of \(reply.options.count))")
        guard let first = options.first else { return Reply(fixed: segment, alternatives: [], unsure: reply.unsure) }
        return Reply(fixed: first, alternatives: Array(options.dropFirst()), unsure: reply.unsure)
    }

    static func addsOrDropsWords(from original: String, to fixed: String) -> Bool {
        guard original != fixed else { return false }
        let d = Detector.shared
        return WordLog.changedPairs(from: original, to: fixed).contains { p in
            guard p.from.isEmpty != p.to.isEmpty else { return false }
            let word = (p.from.isEmpty ? p.to : p.from).trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            guard !word.isEmpty else { return false }
            if word.unicodeScalars.contains(where: KeyMap.isThai) { return Detector.thaiWords.contains(word) }
            return word.count >= 2 && d.isEnglishWord(word)
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
        // What the local check doubted, so the model looks hard at those words in context.
        var suspects: [String] = []
        for d in doubts(in: segment) where !suspects.contains(d.word) && suspects.count < 12 { suspects.append(d.word) }
        if !suspects.isEmpty { obj["suspects"] = suspects }
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
        warm.send(Self.userMessage(for: segment, emoji: emojiMode, polite: polite), model: model) { [weak self] raw, error in
            guard let self = self else { return }
            self.inFlightSegment = nil
            defer { self.drainQueue() }
            guard self.warmRequestID == myID else {
                Log.write("llm warm reply ignored (cancelled)")
                return
            }
            guard let raw = raw else {
                let msg = error ?? "error"
                let loginProblem = Self.isLoginError(msg)
                self.lastError = loginProblem
                    ? "Claude Code login หมดอายุ: รัน claude ใน Terminal แล้ว /login หรือใช้ API key แทน"
                    : String(msg.prefix(160))
                Log.write("llm warm error: \(msg.prefix(200))")
                self.backoffUntil = Date().addingTimeInterval(loginProblem ? 60 : 10)
                self.noteCLIFailure(msg)
                self.onFailed?(segment)
                return
            }
            self.noteCLISuccess()
            let reply = self.guarded(raw, for: segment)
            self.lastError = nil
            self.lastLatency = Date().timeIntervalSince(started)
            Log.write(String(format: "llm warm reply in %.1fs, changed=%@, alternatives=%d, unsure=%@", self.lastLatency,
                             reply.fixed != segment ? "yes" : "no", reply.alternatives.count, reply.unsure ? "yes" : "no"))
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
        strongTask?.cancel()
        strongTask = nil
        apiRequestID += 1
        strongAPIID += 1
        inFlightSegment = nil
        if let p = process, p.isRunning {
            Log.write("llm cli cancelled")
            p.terminate()
        }
        process = nil
        processID += 1
        warmRequestID += 1 // a warm reply still in flight will be ignored
        strongRequestID += 1
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
        warmShadow.stop()
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

    /// One Messages API call. `strong`: the stronger model's second look after the fast one was unsure.
    /// It has its own task, so the fast model's queue keeps moving, and shows no loading dots of its own
    /// (the held message is already glowing).
    private func request(_ segment: String, strong: Bool = false) {
        guard let apiKey = apiKey else { return }
        let useModel = strong ? strongModel : model
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": useModel.rawValue,
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
        let tag = strong ? "llm strong" : "llm api"
        if strong { strongAPIID += 1 } else { apiRequestID += 1 }
        let myID = strong ? strongAPIID : apiRequestID

        if strong {
            Log.write("llm strong start (\(segment.unicodeScalars.count) keys, \(useModel.rawValue), api)")
        } else {
            Log.write("llm api start (\(segment.unicodeScalars.count) keys)")
            inFlightSegment = segment
            onStarted?(segment)
        }
        let t = session.dataTask(with: req) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard myID == (strong ? self.strongAPIID : self.apiRequestID) else { return } // replaced or cancelled
                if strong {
                    self.strongTask = nil
                } else {
                    self.task = nil
                    self.inFlightSegment = nil
                }
                var failed = true
                defer {
                    if failed { self.onFailed?(segment) }
                    self.drainQueue()
                }
                // A Ctrl+Enter replaced by a newer one is not a failed check.
                if let error = error as NSError?, error.code == NSURLErrorCancelled { if strong { failed = false }; return }
                guard let http = response as? HTTPURLResponse, let data = data else {
                    self.lastError = error?.localizedDescription ?? "network error"
                    Log.write("\(tag) error: \(self.lastError ?? "")")
                    return
                }
                if http.statusCode != 200 {
                    // The API's own error message, never the typed text.
                    let apiMessage = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String ?? ""
                    Log.write("\(tag) HTTP \(http.statusCode): \(apiMessage.prefix(200))")
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
                guard let parsed = Self.parseReply(data) else {
                    self.lastError = "อ่านคำตอบไม่ได้"
                    Log.write("\(tag) unreadable reply")
                    return
                }
                failed = false
                let reply = self.guarded(parsed, for: segment)
                self.lastError = nil
                let latency = Date().timeIntervalSince(started)
                if strong {
                    Log.write(String(format: "llm strong reply in %.1fs, changed=%@", latency, reply.fixed != segment ? "yes" : "no"))
                } else {
                    self.lastLatency = latency
                    Log.write(String(format: "llm api reply in %.1fs, changed=%@, alternatives=%d, unsure=%@", latency,
                                     reply.fixed != segment ? "yes" : "no", reply.alternatives.count, reply.unsure ? "yes" : "no"))
                }
                if strong { self.storeStrong(segment, reply) } else {
                    self.cache[segment] = reply
                    if self.cache.count > 500 { self.cache.removeAll() }
                }
                if reply.fixed != segment { self.onResult?(segment, reply) }
                self.onFinished?(segment, reply)
            }
        }
        if strong { strongTask = t } else { task = t }
        t.resume()
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
            "-p", "--model", model.cliName,
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
