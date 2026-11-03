import AppKit

enum Confidence: Int, Comparable {
    case none = 0, weak = 1, strong = 2
    static func < (a: Confidence, b: Confidence) -> Bool { a.rawValue < b.rawValue }
}

struct WordVerdict {
    var direction: Direction?
    var confidence: Confidence
    static let none = WordVerdict(direction: nil, confidence: .none)
}

struct Suggestion: Equatable {
    enum Source: Equatable { case layout, llm }
    /// Number of unicode scalars at the end of the typed buffer to delete.
    let scalarCount: Int
    let replacement: String
    /// Set for layout fixes; nil for LLM typo fixes (no keyboard switch).
    let direction: Direction?
    var source: Source = .layout
    /// Other full replacements the user can cycle to with repeated Tab (LLM only).
    var alternatives: [String] = []
    /// What was typed, for setting a Claude fix against it (LLM only).
    var original: String? = nil
}

/// Decides whether the tail of what was typed is Thai typed on the English layout (or vice versa).
/// Uses only on-device dictionaries: NSSpellChecker (English) and ICU Thai word breaking.
final class Detector {
    static let shared = Detector()

    private var spellCache: [String: Bool] = [:]
    /// Words the user explicitly reverted (Esc after an automatic fix); never flagged again this session.
    var ignoredWords: Set<String> = []
    private let trimSet = CharacterSet(charactersIn: "\"'(),.?!;:[]{}")

    /// Very common short Thai words; lets 1–3 key words like "muj" (ที่) trigger confidently.
    static let commonShortThai: Set<String> = [
        "ที่", "ก็", "ไม่", "ได้", "ให้", "ของ", "มี", "ใน", "เป็น", "ว่า", "จะ", "กับ", "ไป", "มา", "อะ", "ทำ",
        "นะ", "ค่ะ", "คะ", "ครับ", "คับ", "แล้ว", "และ", "จาก", "ถ้า", "แต่", "เอา", "ดู", "ยัง", "อยู่", "ใช้",
        "ต้อง", "เลย", "พี่", "ใคร", "อัน", "ตัว", "คน", "ดี", "ไง", "เค้า", "เขา", "เรา", "ผม", "ฉัน", "มัน",
        "นี้", "นั้น", "ไหน", "ไร", "ก่อน", "หลัง", "บน", "ล่าง", "เข้า", "ออก", "ขึ้น", "ลง", "ลอง", "เช็ค",
        "เทส", "รัน", "แก้", "งาน", "วัน", "ไว้", "ถึง", "ตาม", "ต่อ", "แค่", "แบบ", "อ่ะ", "อ่า", "จ้า", "จ้ะ",
        "ค่า", "โอเค", "เจอ", "รู้", "คิด", "บอก", "เห็น", "หา", "ซื้อ", "กิน", "นอน", "ไหม", "มั้ย", "หรอ",
        "เหรอ", "ป่ะ", "ปะ", "ละ", "ล่ะ", "สิ", "ดิ", "แปป", "เค", "ขอ", "ช่วย", "เพิ่ม", "ลบ", "ส่ง", "รับ",
        "เปิด", "ปิด", "เริ่ม", "จบ", "ใหม่", "เก่า", "เร็ว", "ช้า", "ใหญ่", "เล็ก", "น้อย", "มาก", "สุด", "ทั้ง",
        "หมด", "ทุก", "บาง", "อื่น", "เอง", "กัน", "ด้วย", "เพราะ", "เพื่อ", "โดย", "ซึ่ง", "หรือ", "ถูก", "ผิด",
        "จริง", "ใช่", "แน่", "น่า", "ควร", "อาจ", "คง", "เคย", "เสร็จ", "พัง", "บัค", "โค้ด", "เว็บ", "แอป",
        "หน้า", "ปุ่ม", "จ่าย", "เงิน", "ทีม", "อีก", "เดิม", "เอ่อ", "อืม", "ฮะ", "หละ", "ยัง", "ไหง", "เผื่อ",
        "นะคะ", "นะครับ", "อะไร", "ยังไง", "ทำไม", "ที่ไหน", "เมื่อไหร่", "เท่าไหร่", "แค่ไหน", "ตอน", "ตอนนี้",
        "รอ", "ขอ", "ลอง", "เทส", "รีเทส", "เช็ค", "รัน", "แปะ", "ทัก", "ตอบ", "ถาม", "อ่าน", "เขียน", "ดูก่อน",
        "วันนี้", "พรุ่งนี้", "เมื่อวาน", "เช้า", "เย็น", "คืน", "โมง", "ชั่วโมง", "นาที", "ขอบคุณ", "ขอโทษ",
        // Everyday words of three keys or more: ICU word breaking also keeps gibberish whole, so it cannot vouch for them.
        "เดิน", "เด่น", "โดด", "รีบ", "วิ่ง", "นั่ง", "ยืน", "หยุด", "กลับ", "เล่น", "เรียน", "สอน", "พูด", "คุย", "ฟัง",
        "มอง", "ลืม", "รัก", "ชอบ", "เกลียด", "กลัว", "โกรธ", "เหนื่อย", "ง่วง", "หิว", "อิ่ม", "สบาย", "ป่วย", "เจ็บ",
        "ปวด", "ร้อน", "หนาว", "แดด", "น้ำ", "ข้าว", "กาแฟ", "อาหาร", "ขนม", "ผลไม้", "บ้าน", "ห้อง",
        "ประตู", "โต๊ะ", "เก้าอี้", "ถนน", "เมือง", "ที่นี่", "ที่นั่น", "ตรงนี้", "ตรงนั้น", "เพื่อน", "แฟน", "แม่", "พ่อ", "ลูก",
        "น้อง", "ป้า", "ลุง", "เด็ก", "ผู้ใหญ่", "หัว", "ปาก", "มือ", "เท้า", "แขน", "ความ",
        "การ", "เรื่อง", "ข้อความ", "ภาษา", "ไทย", "อังกฤษ", "ตัวอย่าง", "ปัญหา", "คำถาม", "คำตอบ", "ระบบ", "โปรแกรม", "เกม", "ไฟล์",
        "ข้อมูล", "รูป", "ภาพ", "เสียง", "วิดีโอ", "เพลง", "หนัง", "หนังสือ", "เอกสาร", "ลิงก์", "เมนู", "ตั้งค่า", "เครื่อง", "แป้น",
        "คีย์บอร์ด", "เมาส์", "มือถือ", "โทร", "ประชุม", "ลูกค้า", "บริษัท", "เจ้านาย", "ราคา", "สินค้า", "ของขวัญ", "เวลา", "เดือน", "สัปดาห์",
        "เสาร์", "อาทิตย์", "จันทร์", "อังคาร", "พุธ", "พฤหัส", "ศุกร์", "สวย", "หล่อ", "เก่ง", "แย่", "ยาก", "ง่าย", "หนัก", "เบา",
        "ยาว", "สั้น", "สูง", "ต่ำ", "กว้าง", "แคบ", "ใกล้", "ไกล", "ถูกต้อง", "สำคัญ", "ชัด", "มั่นใจ", "พร้อม", "ว่าง", "ยุ่ง",
        "สนุก", "เบื่อ", "ตลก", "เศร้า", "ดีใจ", "เสียใจ", "เข้าใจ", "รู้สึก", "อยาก", "ต้องการ", "ตัดสินใจ", "เลือก", "เปลี่ยน", "สร้าง", "ทำงาน",
        "แก้ไข", "ตรวจ", "ตรวจสอบ", "ทดสอบ", "แปลง", "พิมพ์", "คลิก", "เลื่อน", "ลาก", "วาง", "เก็บ", "ทิ้ง", "หาย",
        "แชร์", "โพสต์", "อัปเดต", "ติดตั้ง", "ดาวน์โหลด", "เสีย", "ค้าง", "ช้าลง", "เร็วขึ้น", "ดีขึ้น", "แย่ลง", "มากขึ้น", "น้อยลง", "จริงๆ", "เลยนะ",
    ]

    /// Dev and product words macOS's dictionary does not know; never treated as mistyped Thai.
    static let knownEnglish: Set<String> = [
        "google", "github", "gitlab", "bitbucket", "api", "apis", "backend", "frontend", "fullstack", "devops",
        "staging", "prod", "deploy", "redeploy", "rollback", "webhook", "oauth", "jwt", "json", "yaml", "toml",
        "docker", "kubernetes", "k8s", "npm", "pnpm", "yarn", "nodejs", "node", "typescript", "javascript", "js", "ts",
        "swift", "swiftui", "xcode", "figma", "slack", "discord", "notion", "jira", "trello", "asana", "zoom", "meet",
        "gmail", "youtube", "facebook", "instagram", "tiktok", "shopee", "lazada", "grab", "lineman", "ios", "android",
        "macos", "iphone", "ipad", "macbook", "readme", "changelog", "todo", "wip", "lgtm", "pr", "mr", "ci", "cd", "qa",
        "uat", "sit", "dev", "env", "config", "configs", "repo", "repos", "commit", "rebase", "hotfix", "bugfix",
        "refactor", "sprint", "standup", "retro", "backlog", "kanban", "scrum", "login", "logout", "signup", "signin",
        "checkout", "oncall", "localhost", "endpoint", "endpoints", "middleware", "frontend", "ui", "ux", "db", "sql",
        "nosql", "redis", "postgres", "mysql", "mongodb", "firebase", "supabase", "vercel", "netlify", "aws", "gcp",
        "azure", "cloudflare", "nginx", "linux", "ubuntu", "homebrew", "brew", "cli", "sdk", "ide", "vscode", "cursor",
        "copilot", "chatgpt", "openai", "claude", "anthropic", "llm", "ai", "ml", "ok", "okay", "lol", "btw", "fyi",
        "asap", "tbh", "imo", "idk", "wfh", "eta", "nirvania", "lazyboard",
        "html", "css", "http", "https", "url", "xml", "csv", "tsv", "pdf", "png", "jpg", "jpeg", "svg", "gif", "dvd",
        "ssh", "ssl", "tls", "tcp", "udp", "dns", "vpn", "cdn", "mcp", "gpt", "kpi", "crm", "erp", "pm", "hr", "tv", "pc",
        "hmm", "shh", "mr", "mrs", "ms", "dr", "st", "nd", "rd", "th",
    ]

    // MARK: Public

    func suggest(buffer: String) -> Suggestion? {
        let scalars = Array(buffer.unicodeScalars)
        guard !scalars.isEmpty else { return nil }

        // Split into word ranges on spaces.
        var words: [Range<Int>] = []
        var start: Int? = nil
        for (i, sc) in scalars.enumerated() {
            if sc == " " || sc == "\n" {
                if let s = start { words.append(s..<i); start = nil }
            } else if start == nil {
                start = i
            }
        }
        if let s = start { words.append(s..<scalars.count) }
        guard !words.isEmpty else { return nil }

        let lastEndsBuffer = words.last!.upperBound == scalars.count
        var direction: Direction? = nil
        var runStart: Int? = nil
        var hasStrong = false
        var runCount = 0

        for (idx, range) in words.enumerated().reversed() {
            let isLast = lastEndsBuffer && idx == words.count - 1
            let word = String(String.UnicodeScalarView(scalars[range]))
            let v = verdict(word, isLast: isLast)
            guard v.confidence != .none, let d = v.direction else { break }
            if let dir = direction, dir != d { break }
            direction = d
            runStart = range.lowerBound
            if v.confidence == .strong { hasStrong = true }
            runCount += 1
            if runCount >= 12 { break }
        }

        guard hasStrong, let s = runStart, let d = direction else { return nil }
        let tail = scalars[s...]
        return Suggestion(scalarCount: tail.count,
                          replacement: KeyMap.convert(tail, direction: d),
                          direction: d)
    }

    func verdict(_ word: String, isLast: Bool) -> WordVerdict {
        let scalars = Array(word.unicodeScalars)
        guard !scalars.isEmpty, !ignoredWords.contains(word) else { return .none }
        if scalars.allSatisfy(KeyMap.isMappableASCII) {
            return englishToThaiVerdict(word, scalars, isLast: isLast)
        }
        if KeyMap.isThaiLayoutWord(scalars) {
            return thaiToEnglishVerdict(word, scalars, isLast: isLast)
        }
        return .none
    }

    // MARK: English layout → Thai

    private func englishToThaiVerdict(_ word: String, _ scalars: [Unicode.Scalar], isLast: Bool) -> WordVerdict {
        if scalars.allSatisfy({ (0x30...0x39).contains($0.value) }) { return .none }
        // ฝ sits on the / key, so /yj':hkp is ฝั่งซ้าย; only a path with more slashes is surely not Thai.
        if word.contains("://") || word.contains("@") || (word.hasPrefix("/") && word.dropFirst().contains("/")) || word.hasPrefix("~") { return .none }

        let thai = Array(KeyMap.convert(scalars, direction: .englishToThai).unicodeScalars)
        let thaiCount = thai.filter(KeyMap.isThai).count
        guard Double(thaiCount) / Double(thai.count) >= 0.8 else { return .none }
        // Thai has no spaces, so one slipped key inside a long run must not hide the whole run.
        let violations = ThaiOrtho.violations(thai)
        let startsClean = ThaiOrtho.classify(thai[0]) == .consonant || ThaiOrtho.classify(thai[0]) == .leading
        let tolerated = (thai.count >= 8 && startsClean) ? max(1, thai.count / 12) : 0
        guard violations <= tolerated else { return .none }

        let thaiString = String(String.UnicodeScalarView(thai))
        let hasVowel = ThaiOrtho.hasVowelOrTone(thai)
        let englishOK = isEnglishWord(word)
        let lenient = isLast || (scalars.count <= 2 && !englishOK)
        let isCommon = Self.commonShortThai.contains(thaiString)
        // Never turn anything into Thai that is not Thai words: cloudfailre -> แสนีกดฟรสพำ.
        guard isCommon || Self.isRealThai(thaiString) else { return .none }

        // Two-key common Thai words whose keys happen to spell a dictionary entry (iv = รอ, mu = ที).
        if isCommon, scalars.count <= 2, !Self.knownEnglish.contains(word.lowercased()) {
            return WordVerdict(direction: .englishToThai, confidence: .strong)
        }
        if !englishOK && (scalars.count >= 4 || (hasVowel && isCommon)) {
            return WordVerdict(direction: .englishToThai, confidence: .strong)
        }
        // A real English word in the middle of the run ends it, unless it is also a common Thai word.
        if englishOK && !lenient && !isCommon { return .none }
        if hasVowel || !englishOK || lenient || isCommon {
            return WordVerdict(direction: .englishToThai, confidence: .weak)
        }
        return .none
    }

    // MARK: Thai layout → English

    private func thaiToEnglishVerdict(_ word: String, _ scalars: [Unicode.Scalar], isLast: Bool) -> WordVerdict {
        let english = KeyMap.convert(scalars, direction: .thaiToEnglish)
        // Digits typed on the Thai layout: "ๅจ" is 10, "ๅจ.๒" is 10.2 … (two or more keys).
        if scalars.count >= 2, english.range(of: "^[0-9][0-9.,:%/-]*$", options: .regularExpression) != nil {
            return WordVerdict(direction: .thaiToEnglish, confidence: .strong)
        }
        guard english.range(of: "^[A-Za-z]+(?:['-][A-Za-z]+)*[.,!?]?$", options: .regularExpression) != nil else { return .none }
        let core = english.trimmingCharacters(in: trimSet)

        let thaiValid = ThaiOrtho.isValid(scalars)
        let thaiHasVowel = ThaiOrtho.hasVowelOrTone(scalars)
        let englishOK = core.count >= 2 && isEnglishWord(core)
        let englishHasVowel = core.lowercased().contains { "aeiouy".contains($0) }
        let lenient = isLast || (scalars.count <= 2 && !englishOK)

        if englishOK && (!thaiValid || (!thaiHasVowel && core.count >= 4)) {
            return WordVerdict(direction: .thaiToEnglish, confidence: .strong)
        }
        // A dictionary word of 5+ letters spelled by the keys (หแรพยะ = script) is strong evidence on its own:
        // Thai words rarely map to letters only, since ว ง บ ล ม ใ ฝ ข ช sit on symbol keys.
        if englishOK, core.count >= 5, core.allSatisfy({ $0.isLetter }) {
            return WordVerdict(direction: .thaiToEnglish, confidence: .strong)
        }
        // Short acronym typed with Shift on the Thai layout (ญพ = PR): rare consonants, no vowel, a known word.
        if englishOK, !thaiHasVowel, core.count >= 2, scalars.contains(where: { KeyMap.shiftLayerThai.contains($0) }) {
            return WordVerdict(direction: .thaiToEnglish, confidence: .strong)
        }
        // Every key shifted and no Thai reading (์ญฉ = NPC): an acronym typed on the Thai layout.
        if !thaiValid, (2...6).contains(core.count), core.allSatisfy(\.isUppercase),
           scalars.allSatisfy({ KeyMap.shiftLayerThai.contains($0) }) {
            return WordVerdict(direction: .thaiToEnglish, confidence: .strong)
        }
        if !thaiValid && englishHasVowel && core.count >= 3 {
            return WordVerdict(direction: .thaiToEnglish, confidence: .strong)
        }
        // Not in the dictionary but English-shaped (readme, dploy, signup) while the Thai side is not real
        // words either: "พำฟกทำ" -> readme.
        if !englishOK, core.count >= 5, Self.looksEnglish(core), thaiWordScore(word) < 0.34 {
            return WordVerdict(direction: .thaiToEnglish, confidence: .strong)
        }
        // A real Thai word next to a mistyped English one stays Thai: รอ พำรำรไ must not become "iv review".
        if thaiValid && (Self.commonShortThai.contains(word) || Self.isRealThai(word)) { return .none }
        if englishOK || (!thaiValid && (lenient || englishHasVowel)) {
            return WordVerdict(direction: .thaiToEnglish, confidence: .weak)
        }
        return .none
    }

    /// Cheap English-shape test: has vowels, no run of 4+ consonants, mostly letters.
    static func looksEnglish(_ word: String) -> Bool {
        let w = word.lowercased()
        var vowels = 0, run = 0, maxRun = 0
        for ch in w {
            if "aeiouy".contains(ch) { vowels += 1; run = 0 }
            else if ch.isLetter { run += 1; maxRun = max(maxRun, run) }
            else { run = 0 }
        }
        let ratio = Double(vowels) / Double(max(w.count, 1))
        return ratio >= 0.14 && ratio <= 0.7 && maxRun <= 3
    }

    // MARK: Dictionaries

    func isEnglishWord(_ raw: String) -> Bool {
        // Symbols other than a trailing ./,/?/! are Thai keys in disguise ("F,'" = โมง, ".o" = ใน):
        // never English, however the spell checker would split them.
        var bare = Substring(raw)
        while let last = bare.last, ".,?!\")".contains(last) { bare.removeLast() }
        while let first = bare.first, "(\"".contains(first) { bare.removeFirst() }
        guard bare.unicodeScalars.allSatisfy({ ($0.value < 0x80 && CharacterSet.letters.contains($0)) || $0 == "'" || $0 == "-" }) else { return false }
        let w = raw.trimmingCharacters(in: trimSet)
        if w.isEmpty { return false }
        if w.count == 1 { return true }
        if Self.knownEnglish.contains(w.lowercased()) { return true }
        // The spell checker passes vowel-less strings as abbreviations (dvdd, dd-dv), so กอกก would become dvdd.
        let parts = w.lowercased().split(separator: "-").map(String.init)
        let spelled = parts.allSatisfy { part in
            part.count == 1 || Self.knownEnglish.contains(part) || part.contains { "aeiouy".contains($0) }
        }
        if !spelled { return false }
        if let cached = spellCache[w] { return cached }
        let r = NSSpellChecker.shared.checkSpelling(of: w, startingAt: 0, language: "en", wrap: false,
                                                    inSpellDocumentWithTag: 0, wordCount: nil)
        let ok = r.location == NSNotFound
        spellCache[w] = ok
        return ok
    }

    /// libthai's word list (Resources/thai-words.txt) plus the everyday words above. Without the file only those remain.
    static let thaiWords: Set<String> = {
        var words = commonShortThai
        if let url = Bundle.main.url(forResource: "thai-words", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            words.formUnion(text.split(separator: "\n").map(String.init))
        }
        return words
    }()
    private static let longestThaiWord = thaiWords.map { $0.unicodeScalars.count }.max() ?? 0

    /// Every Thai run must be a dictionary word or split into them. Rare two-letter words (พำ+กก, แส+นี) can spell
    /// almost anything, so inside a split two-letter words must be everyday ones (มา+ดู).
    static func isRealThai(_ text: String) -> Bool {
        let letters = text.unicodeScalars.split { !KeyMap.isThai($0) || $0 == "ๆ" || $0 == "ฯ" }.map(Array.init)
        return !letters.isEmpty && letters.allSatisfy { run in
            thaiWords.contains(String(String.UnicodeScalarView(run))) || splitsIntoThaiWords(run)
        }
    }

    private static func splitsIntoThaiWords(_ run: [Unicode.Scalar]) -> Bool {
        var reachable = [Bool](repeating: false, count: run.count + 1)
        reachable[0] = true
        for i in 0..<run.count where reachable[i] {
            for j in (i + 2)..<max(i + 2, min(run.count, i + longestThaiWord) + 1) {
                let piece = String(String.UnicodeScalarView(run[i..<j]))
                if j - i == 2 ? commonShortThai.contains(piece) : thaiWords.contains(piece) { reachable[j] = true }
            }
        }
        return reachable[run.count]
    }

    /// Fraction of Thai letters that fall inside ICU word tokens (≥2 letters, containing a vowel or tone).
    func thaiWordScore(_ text: String) -> Double {
        let total = text.unicodeScalars.filter(KeyMap.isThai).count
        guard total > 0 else { return 0 }
        var covered = 0
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords]) { sub, _, _, _ in
            guard let sub = sub else { return }
            let scs = Array(sub.unicodeScalars)
            guard scs.count >= 2, ThaiOrtho.hasVowelOrTone(scs) else { return }
            covered += scs.filter(KeyMap.isThai).count
        }
        return Double(covered) / Double(total)
    }
}
