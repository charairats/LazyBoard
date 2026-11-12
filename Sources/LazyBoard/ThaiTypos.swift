import Foundation

/// Deterministic fixes for the most common Thai slips that need no model:
/// ้ typed for ็ (same key, Shift forgotten) in everyday words, เเ typed for แ, ๋ typed for ่ (Shift held).
enum ThaiTypos {
    /// Everyday words spelled with ็; typing them with ้ instead is the classic slip (เป้น -> เป็น).
    static let maitaikhuWords: Set<String> = [
        "เป็น", "ก็", "เด็ก", "เล็ก", "เห็น", "เก็บ", "เช็ค", "เช็ก", "เย็น", "เจ็ด", "เสร็จ", "เข็ม", "เม็ด", "เก็ง",
        "เต็ม", "เผ็ด", "เข็น", "เล็บ", "เบ็ด", "เค็ม", "เจ็บ", "เซ็น", "เน็ต", "เว็บ", "เซ็ต", "เป็ด", "แข็ง", "แล็บ",
        "แท็บ", "แอ็ป", "แจ็ค", "เส็ง", "เร็ว", "เด็ด", "เข็ด", "เก็ต", "เช็ด", "เม็ง", "เท็จ", "เฟ็ก", "เส็น",
        "แค็ป", "แพ็ค", "แพ็ก", "เป็ง", "เบ็น", "เก็ง", "เล็ง", "เจ็ง", "เซ็ง", "เอ็ม", "เอ็น", "เอ็กซ์", "เอ็ด",
        "ก็ได้", "ก็เลย", "ก็คือ", "ก็ตาม", "เป็นไร", "เป็นต้น", "เป็นไง", "เร็วๆ", "เด็กๆ", "เล็กๆ",
    ]

    /// Words that genuinely carry ๋; anything else with ๋ almost certainly meant ่.
    static let maiChattawaWords: Set<String> = ["จ๋า", "ก๋วยเตี๋ยว", "เตี๋ยว", "ก๋ง", "จุ๋มจิ๋ม", "ตุ๋น", "ป๋า", "ม๋า", "น๋า", "ย๋า", "ป๋อ", "ก๋า", "ตั๋ว", "หยิ๋ว", "จิ๋ว", "ตี๋"]

    /// Endings that always take คะ, never ค่ะ. Not เปล่า or อะไร alone: "เปล่าค่ะ" and "ไม่มีอะไรค่ะ" are correct answers.
    static let khaEndings = ["นะ", "มั้ย", "ไหม", "หรอ", "เหรอ", "หรือ", "หรือเปล่า", "รึเปล่า"]

    /// A corrected spelling for `word`, or nil when nothing confident applies.
    /// `slips`: also try one Shift or swap slip (for the fix on space; the doubt check reports pieces instead).
    static func fix(_ word: String, slips: Bool = true) -> String? {
        guard word.unicodeScalars.contains(where: KeyMap.isThai) else { return nil }
        var fixed = word
        // เเ (two sara e) is always แ.
        fixed = fixed.replacingOccurrences(of: "เเ", with: "แ")
        // ๋ for ่ unless the word is one of the few real ๋ words.
        if fixed.unicodeScalars.contains("\u{0E4B}"), !maiChattawaWords.contains(fixed) {
            fixed = fixed.replacingOccurrences(of: "๋", with: "่")
        }
        // ้ for ็: only when the result is an everyday ็ word (a plain ้ is usually right).
        if fixed.unicodeScalars.contains("\u{0E49}") {
            let candidate = fixed.replacingOccurrences(of: "้", with: "็")
            if maitaikhuWords.contains(candidate) {
                fixed = candidate
            } else {
                // Mixed words such as เป้นไร: fix a leading ็-word prefix.
                for w in maitaikhuWords where fixed.hasPrefix(w.replacingOccurrences(of: "็", with: "้")) && w.count >= 3 {
                    fixed = w + fixed.dropFirst(w.count)
                    break
                }
            }
        }
        // R1: a spelling change is kept only when the word as typed is not real Thai and the change is
        // (เดี๋ยว, เส้น and เข้ม are words: they stay; เป้น and ไม๋ are not).
        if fixed != word, Words.realThai(word) || !Words.realThai(fixed) { fixed = word }
        // นะค่ะ, ไหมค่ะ: the classic wrong tone on the particle. Both spellings are words: an explicit exception.
        if khaEndings.contains(where: { fixed.hasSuffix($0 + "ค่ะ") }) {
            fixed = String(fixed.dropLast("ค่ะ".count)) + "คะ"
        }
        if slips, fixed == word, let slip = slipFix(word) { return slip }
        return fixed == word ? nil : fixed
    }

    /// Each Thai character and the one on the same key with or without Shift (ื and ์ share a key).
    static let shiftPartner: [Unicode.Scalar: Unicode.Scalar] = {
        let plain = Array("`1234567890-=qwertyuiop[]\\asdfghjkl;'zxcvbnm,./".unicodeScalars)
        let shifted = Array("~!@#$%^&*()_+QWERTYUIOP{}|ASDFGHJKL:\"ZXCVBNM<>?".unicodeScalars)
        var map: [Unicode.Scalar: Unicode.Scalar] = [:]
        for (p, s) in zip(plain, shifted) {
            guard let a = KeyMap.usToThai[p], let b = KeyMap.usToThai[s], KeyMap.isThai(a), KeyMap.isThai(b) else { continue }
            map[a] = b
            map[b] = a
        }
        return map
    }()

    /// A Thai word that is not real, one slip away from exactly one real spelling: Shift missed or added on one key
    /// (สัตวื -> สัตว์), or two neighbouring characters swapped (ไมไ่ด้ -> ไม่ได้). Nil when unsure.
    static func slipFix(_ word: String) -> String? {
        let scalars = Array(word.unicodeScalars)
        guard scalars.count >= 3, scalars.allSatisfy(KeyMap.isThai) else { return nil }
        if Words.realThai(word) { return nil }
        var found = Set<String>()
        func consider(_ c: [Unicode.Scalar]) {
            guard ThaiOrtho.isValid(c) else { return }
            let text = String(String.UnicodeScalarView(c))
            if text != word, Words.realThai(text) { found.insert(text) }
        }
        for i in scalars.indices {
            if let other = shiftPartner[scalars[i]] {
                var c = scalars
                c[i] = other
                consider(c)
            }
            if i + 1 < scalars.count, scalars[i] != scalars[i + 1] {
                var c = scalars
                c.swapAt(i, i + 1)
                consider(c)
            }
        }
        return found.count == 1 ? found.first : nil
    }
}
