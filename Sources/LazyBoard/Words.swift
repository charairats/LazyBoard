import Foundation

/// The one answer to "is this a real word?", shared by every path that may write over typed text.
///
/// The rule every automatic fix follows (docs/thai-rules-analysis.md, R1): the text is written over only when
/// what it becomes is a real word AND what was typed is not a real word in its own script. Anything weaker
/// (English-shaped keys, ICU word breaking, broken Thai spelling) is a hint for Claude, never a reason to overwrite.
enum Words {
    /// Words between spaces and line breaks, split on scalars: a Thai mark typed right after a space (" ืยแ")
    /// joins the space into one Character, so splitting Characters would glue two words together.
    static func split(_ text: String) -> [String] {
        text.unicodeScalars.split(whereSeparator: { $0 == " " || $0 == "\n" }).map { String(String.UnicodeScalarView($0)) }
    }

    /// Real Thai: a dictionary or list entry, or valid Thai that splits into dictionary words.
    static func realThai(_ text: String) -> Bool {
        guard text.unicodeScalars.contains(where: KeyMap.isThai) else { return false }
        if Detector.thaiWords.contains(text) { return true }
        return ThaiOrtho.isValid(text.unicodeScalars) && Detector.isRealThai(text)
    }

    /// Real English: a dictionary word or one we know (dev words, acronyms), in a normal letter case.
    /// Mixed case such as mAKEu (ทฤษฎี) or aviN (ฟอร์ม) is never English: the spell checker lets it through.
    static func realEnglish(_ text: String) -> Bool {
        Detector.shared.isEnglishWord(text)
    }

    /// Digits, maybe with separators: 10, 10.2, 3:45, 50%.
    static func realNumber(_ text: String) -> Bool {
        text.range(of: "^[0-9][0-9.,:%/-]*$", options: .regularExpression) != nil
    }

    /// Branch names, file names, paths whose every part is a word we know (feature/build-esim, README.md, k8s).
    static func realDevToken(_ text: String) -> Bool {
        Detector.shared.isDevToken(text)
    }

    /// The English side of a Thai-layout word is something real to write: a word, a number or a dev token.
    static func realEnglishTarget(_ text: String) -> Bool {
        let core = text.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?'-"))
        if realNumber(text) { return true }
        if realDevToken(text) { return true }
        return core.count >= 2 && realEnglish(core)
    }
}
