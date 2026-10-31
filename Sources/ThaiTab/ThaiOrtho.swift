import Foundation

enum ThaiClass: Equatable {
    case consonant, leading, following, above, below, tone, killer, mark, digit, other
}

/// Lightweight Thai orthography check: rejects sequences no Thai typist would produce
/// (tone mark at word start, two tone marks in a row, leading vowel with no consonant...).
enum ThaiOrtho {
    static func classify(_ s: Unicode.Scalar) -> ThaiClass {
        switch s.value {
        case 0x0E01...0x0E2E: return .consonant
        case 0x0E40...0x0E44: return .leading              // เ แ โ ใ ไ
        case 0x0E30, 0x0E32, 0x0E33, 0x0E45: return .following // ะ า ำ ๅ
        case 0x0E31, 0x0E34...0x0E37, 0x0E47, 0x0E4D: return .above // ั ิ ี ึ ื ็ ํ
        case 0x0E38...0x0E3A: return .below                // ุ ู ฺ
        case 0x0E48...0x0E4B: return .tone                 // ่ ้ ๊ ๋
        case 0x0E4C, 0x0E4E: return .killer                // ์ ๎
        case 0x0E2F, 0x0E46: return .mark                  // ฯ ๆ
        case 0x0E50...0x0E59: return .digit
        default: return .other
        }
    }

    static func isVowelOrTone(_ c: ThaiClass) -> Bool {
        switch c {
        case .leading, .following, .above, .below, .tone: return true
        default: return false
        }
    }

    static func hasVowelOrTone<S: Sequence>(_ scalars: S) -> Bool where S.Element == Unicode.Scalar {
        scalars.contains { isVowelOrTone(classify($0)) }
    }

    static func isValid<S: Sequence>(_ scalars: S) -> Bool where S.Element == Unicode.Scalar {
        violations(scalars) == 0
    }

    /// Number of orthographic rule breaks. After a break the state resets, so one slipped key
    /// inside a long run counts once instead of poisoning the whole word.
    static func violations<S: Sequence>(_ scalars: S) -> Int where S.Element == Unicode.Scalar {
        let all = Array(scalars)
        var prev: ThaiClass = .other
        var prevScalar: Unicode.Scalar? = nil
        var count = 0
        var bad = 0
        var inError = false
        for s in all {
            let c = classify(s)
            count += 1
            // A run of stray marks after a slip counts as one slip; a consonant ends the run.
            if inError {
                if c == .consonant || c == .leading || c == .digit || c == .other {
                    inError = false
                    prev = .other
                } else {
                    prevScalar = s
                    continue
                }
            }
            var ok = true
            if prev == .leading && c != .consonant { ok = false }
            switch c {
            case .consonant, .digit, .leading, .other:
                break
            case .following:
                switch s.value {
                case 0x0E30: // ะ : after consonant, tone, or า (เพราะ)
                    if !(prev == .consonant || prev == .tone || prevScalar?.value == 0x0E32) { ok = false }
                case 0x0E32, 0x0E33: // า ำ : after consonant or tone (น้ำ, ว่า)
                    if !(prev == .consonant || prev == .tone) { ok = false }
                default: // ๅ
                    if prev != .consonant { ok = false }
                }
            case .above, .below:
                if prev != .consonant { ok = false }
            case .tone:
                if !(prev == .consonant || prev == .above || prev == .below) { ok = false }
                if prevScalar?.value == 0x0E47 { ok = false } // no tone after ็
            case .killer:
                if !(prev == .consonant || prev == .above || prev == .below) { ok = false }
            case .mark:
                if prev == .other || prev == .leading { ok = false }
            }
            if ok {
                prev = c
            } else {
                bad += 1
                inError = true
                prev = .other
            }
            prevScalar = s
        }
        if prev == .leading { bad += 1 }
        if count == 0 { bad += 1 }
        // ั and ื always need a following consonant; ็ does too, except in the word ก็.
        if let last = all.last {
            if last.value == 0x0E31 || last.value == 0x0E37 { bad += 1 }
            if last.value == 0x0E47 {
                let n = all.count
                let isKoKai = n >= 2 && all[n - 2].value == 0x0E01
                let beforeIsLeading = n >= 3 && classify(all[n - 3]) == .leading
                if !(isKoKai && !beforeIsLeading) { bad += 1 }
            }
        }
        return bad
    }
}
