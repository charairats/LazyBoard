import Foundation

/// Single words (never whole messages) kept for tuning the local check, at
/// ~/Library/Application Support/LazyBoard/words.tsv: date, kind, why, typed, Claude's version.
/// Lines older than a week are dropped at launch and on every write; `LazyBoard --forget-words` deletes the file.
enum WordLog {
    enum Kind: String {
        case kept    // the local check doubted it, Claude left it alone: likely a real word missing from the dictionaries
        case fixed   // Claude fixed it in a message that waited
        case missed  // Claude would have fixed it in a message that went out unchecked
    }

    struct Pair: Equatable {
        let from: String
        let to: String
    }

    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LazyBoard", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("words.tsv")
    }()
    static let keepFor: TimeInterval = 7 * 24 * 3600
    /// Longer than this is a phrase or a rewrite, not a word.
    static let maxWordLength = 30
    private static let queue = DispatchQueue(label: "lazyboard.words")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func write(_ kind: Kind, why: String, from: String, to: String? = nil) {
        let clean = { (s: String) in s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
        guard !from.isEmpty || !(to ?? "").isEmpty, from.count <= maxWordLength, (to ?? "").count <= maxWordLength else { return }
        let line = [formatter.string(from: Date()), kind.rawValue, why, clean(from), clean(to ?? "")].joined(separator: "\t") + "\n"
        queue.async {
            purgeNow()
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// Drop lines older than a week.
    static func purge() { queue.async { purgeNow() } }

    private static func purgeNow() {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let cutoff = Date().addingTimeInterval(-keepFor)
        let lines = text.split(separator: "\n")
        let fresh = lines.filter { line in
            guard let date = formatter.date(from: String(line.prefix(while: { $0 != "\t" }))) else { return false }
            return date >= cutoff
        }
        guard fresh.count != lines.count else { return }
        if fresh.isEmpty { try? FileManager.default.removeItem(at: url); return }
        try? Data((fresh.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    /// Delete everything kept.
    static func forget() -> Bool {
        queue.sync {
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            try? FileManager.default.removeItem(at: url)
            return true
        }
    }

    // MARK: What changed

    /// The runs of words that differ between what was typed and Claude's version, in order.
    static func changedPairs(from original: String, to fixed: String) -> [Pair] {
        let a = SuggestionPanel.tokens(original), b = SuggestionPanel.tokens(fixed)
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [Pair] = []
        var i = 0, j = 0, from = "", to = ""
        func flush() {
            let f = from.trimmingCharacters(in: .whitespaces), t = to.trimmingCharacters(in: .whitespaces)
            if f != t { pairs.append(Pair(from: f, to: t)) }
            from = ""; to = ""
        }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] { flush(); i += 1; j += 1 }
            else if j >= b.count || (i < a.count && table[i + 1][j] >= table[i][j + 1]) { from += a[i]; i += 1 }
            else { to += b[j]; j += 1 }
        }
        flush()
        return pairs
    }

    /// What kind of change a pair is: spacing (only spaces or punctuation), layout (typed on the other keyboard),
    /// thai-mark (same Thai consonants, other vowels or tone marks), rewrite (a long stretch), or spelling.
    static func shape(_ p: Pair) -> String {
        let core = { (s: String) in String(String.UnicodeScalarView(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })) }
        if core(p.from) == core(p.to) { return "spacing" }
        let scalars = Array(p.from.unicodeScalars)
        if KeyMap.convert(scalars, direction: .englishToThai) == p.to
            || KeyMap.convert(scalars, direction: .thaiToEnglish).lowercased() == p.to.lowercased() { return "layout" }
        let consonants = { (s: String) in s.unicodeScalars.filter { ThaiOrtho.classify($0) == .consonant } }
        if !p.from.isEmpty, p.from.unicodeScalars.allSatisfy(KeyMap.isThai), p.to.unicodeScalars.allSatisfy(KeyMap.isThai),
           Array(consonants(p.from)) == Array(consonants(p.to)) { return "thai-mark" }
        if max(p.from.count, p.to.count) > maxWordLength { return "rewrite" }
        return "spelling"
    }

    /// "spelling 2, thai-mark 1"
    static func shapes(_ pairs: [Pair]) -> String {
        var counts: [String: Int] = [:]
        for p in pairs { counts[shape(p), default: 0] += 1 }
        return counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }
}
