import Foundation

enum Direction: Equatable {
    case englishToThai   // typed on US layout, meant Thai
    case thaiToEnglish   // typed on Thai layout, meant English
}

/// Physical-key mapping between US QWERTY and Thai Kedmanee (macOS "Thai" layout).
enum KeyMap {
    static let usToThai: [Unicode.Scalar: Unicode.Scalar] = {
        let pairs: [(String, String)] = [
            // number row
            ("`", "_"), ("1", "ๅ"), ("2", "/"), ("3", "-"), ("4", "ภ"), ("5", "ถ"), ("6", "ุ"), ("7", "ึ"),
            ("8", "ค"), ("9", "ต"), ("0", "จ"), ("-", "ข"), ("=", "ช"),
            ("~", "%"), ("!", "+"), ("@", "๑"), ("#", "๒"), ("$", "๓"), ("%", "๔"), ("^", "ู"), ("&", "฿"),
            ("*", "๕"), ("(", "๖"), (")", "๗"), ("_", "๘"), ("+", "๙"),
            // top row
            ("q", "ๆ"), ("w", "ไ"), ("e", "ำ"), ("r", "พ"), ("t", "ะ"), ("y", "ั"), ("u", "ี"), ("i", "ร"),
            ("o", "น"), ("p", "ย"), ("[", "บ"), ("]", "ล"), ("\\", "ฃ"),
            ("Q", "๐"), ("W", "\""), ("E", "ฎ"), ("R", "ฑ"), ("T", "ธ"), ("Y", "ํ"), ("U", "๊"), ("I", "ณ"),
            ("O", "ฯ"), ("P", "ญ"), ("{", "ฐ"), ("}", ","), ("|", "ฅ"),
            // home row
            ("a", "ฟ"), ("s", "ห"), ("d", "ก"), ("f", "ด"), ("g", "เ"), ("h", "้"), ("j", "่"), ("k", "า"),
            ("l", "ส"), (";", "ว"), ("'", "ง"),
            ("A", "ฤ"), ("S", "ฆ"), ("D", "ฏ"), ("F", "โ"), ("G", "ฌ"), ("H", "็"), ("J", "๋"), ("K", "ษ"),
            ("L", "ศ"), (":", "ซ"), ("\"", "."),
            // bottom row
            ("z", "ผ"), ("x", "ป"), ("c", "แ"), ("v", "อ"), ("b", "ิ"), ("n", "ื"), ("m", "ท"), (",", "ม"),
            (".", "ใ"), ("/", "ฝ"),
            ("Z", "("), ("X", ")"), ("C", "ฉ"), ("V", "ฮ"), ("B", "ฺ"), ("N", "์"), ("M", "?"), ("<", "ฒ"),
            (">", "ฬ"), ("?", "ฦ"),
        ]
        var map: [Unicode.Scalar: Unicode.Scalar] = [:]
        for (us, th) in pairs {
            map[us.unicodeScalars.first!] = th.unicodeScalars.first!
        }
        return map
    }()

    static let thaiToUS: [Unicode.Scalar: Unicode.Scalar] = {
        var map: [Unicode.Scalar: Unicode.Scalar] = [:]
        for (us, th) in usToThai where isThai(th) {
            map[th] = us
        }
        // ASCII the Thai layout produces (Shift+M = ?, Shift+Z = ( …): map back too, so a word
        // like ฑฎฤฏ?ฎ (README) converts whole.
        for (us, th) in usToThai where !isThai(th) && map[th] == nil {
            map[th] = us
        }
        return map
    }()

    /// Everything the Thai layout can type: Thai script plus a few ASCII marks.
    static let thaiLayoutOutputs: Set<Unicode.Scalar> = Set(usToThai.values)

    /// Thai characters that need the Shift key on the Kedmanee layout (rare consonants, digits).
    static let shiftLayerThai: Set<Unicode.Scalar> = {
        var set = Set<Unicode.Scalar>()
        for (us, th) in usToThai where isThai(th) {
            let c = Character(us)
            if c.isUppercase || "~!@#$%^&*()_+{}|:\"<>?".unicodeScalars.contains(us) { set.insert(th) }
        }
        return set
    }()

    /// A word typed on the Thai layout: Thai script, allowing the layout's own ASCII marks inside.
    static func isThaiLayoutWord(_ scalars: [Unicode.Scalar]) -> Bool {
        guard scalars.contains(where: isThai) else { return false }
        return scalars.allSatisfy { thaiLayoutOutputs.contains($0) }
    }

    static func isThai(_ s: Unicode.Scalar) -> Bool {
        (0x0E00...0x0E7F).contains(s.value)
    }

    static func isMappableASCII(_ s: Unicode.Scalar) -> Bool {
        usToThai[s] != nil
    }

    static func convert<S: Sequence>(_ scalars: S, direction: Direction) -> String where S.Element == Unicode.Scalar {
        var out = String.UnicodeScalarView()
        for sc in scalars {
            switch direction {
            case .englishToThai: out.append(usToThai[sc] ?? sc)
            case .thaiToEnglish: out.append(thaiToUS[sc] ?? sc)
            }
        }
        return String(out)
    }
}
