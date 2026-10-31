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

    /// A corrected spelling for `word`, or nil when nothing confident applies.
    static func fix(_ word: String) -> String? {
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
        return fixed == word ? nil : fixed
    }
}
