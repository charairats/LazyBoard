import Foundation

/// `ThaiTab --test` : runs detector cases from the terminal, no Accessibility permission needed.
enum SelfTest {
    static func run() -> Int32 {
        let d = Detector.shared
        var failures = 0

        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : "   -> " + detail))
            if !ok { failures += 1 }
        }

        func expect(_ buffer: String, _ replacement: String?, _ direction: Direction? = nil) {
            let s = d.suggest(buffer: buffer)
            var ok = (s?.replacement == replacement)
            if ok, let dir = direction, let s = s { ok = s.direction == dir }
            check("suggest(\"\(buffer)\")", ok, "got \(s.map { "\"\($0.replacement)\" (-\($0.scalarCount))" } ?? "nil")")
        }

        print("== roundtrip of key map ==")
        var roundtrip = true
        for (us, th) in KeyMap.usToThai where KeyMap.isThai(th) {
            if KeyMap.thaiToUS[th] != us { roundtrip = false; print("  mismatch \(us) <-> \(th)") }
        }
        check("every Thai letter maps back to one US key", roundtrip)

        print("\n== Jeen's real examples (English layout, meant Thai) ==")
        expect("mujgdujp;-hv'", "ที่เกี่ยวข้อง", .englishToThai)
        expect("0tgmlmyh's,fmew,vt", "จะเทสทั้งหมดทำไมอะ", .englishToThai)
        expect("แก้เรื่องไหนก็รีเทสเรื่องนั้น ใน journey mujgdujp;-hv' 0tgmlmyh's,fmew,vt",
               "ที่เกี่ยวข้อง จะเทสทั้งหมดทำไมอะ", .englishToThai)
        let full = d.suggest(buffer: "แก้เรื่องไหนก็รีเทสเรื่องนั้น ใน journey mujgdujp;-hv' 0tgmlmyh's,fmew,vt")
        check("deletes exactly the 32 wrong keystrokes", full?.scalarCount == 32, "got \(full?.scalarCount ?? -1)")
        expect("muj", "ที่")                     // common short word while still typing
        expect("w,jwfh", "ไม่ได้")
        expect("ok mujgdujp;-hv' ", "ที่เกี่ยวข้อง ") // trailing space kept
        expect("l;ylfu8iy[", "สวัสดีครับ")
        expect("ot8t", "นะคะ")
        expect("vtwi", "อะไร")
        expect("c]h;", "แล้ว")
        expect("F,'", "โมง")
        expect("แล้วนะ iv", "รอ")                                          // iv is a dictionary entry, but รอ wins
        expect(".o", "ใน")   // c]g; in the test run was a typo on top: แลเว, left to the LLM hint
        // one slipped key (eeuj = ำำี่) inside a long run must still be fixed
        expect("สวัสดีค่ะ เออเริ่ด 8jteeuj;yoouhso^de]y'mflv[it[[vp^j8jt", "ค่ะำำี่วันนี้หนูกำลังทดสอบระบบอยู่ค่ะ")
        expect("8jt ;yoouhso^de]y'mflv[it[[vp^j8jt", "ค่ะ วันนี้หนูกำลังทดสอบระบบอยู่ค่ะ")

        print("\n== Thai layout, meant English ==")
        expect("้ำสสน", "hello", .thaiToEnglish)
        expect("้ำสสน ไนพสก", "hello world", .thaiToEnglish)
        expect("ะ้ำ ๆีรแา ิพนไื ดนป", "the quick brown fox", .thaiToEnglish)
        expect("ะำหะ", "test", .thaiToEnglish)
        expect("บัคนี้เกิดตอน สนเรื", "login", .thaiToEnglish)        // ends in ื: never Thai
        expect("อัปเดท ฑฎฤฏ?ฎ", "README", .thaiToEnglish)             // Shift+M gives "?" on the Thai layout
        expect("ส่ง ญพ", "Pr", .thaiToEnglish)                         // shift-layer acronym
        expect("จากนั้นเราจะทำ ้รขดร", "hi-fi", .thaiToEnglish)          // hyphenated word
        expect("กับ build หแพรยะ", "script", .thaiToEnglish)             // valid-looking Thai, but the keys spell a word
        // หแรพยะ = "scirpt" (layout + transposition): left to the LLM, which gets the hint
        check("layout hint for scirpt", LLMSuggester.layoutHints(for: "กับ build หแรพยะ")["หแรพยะ"] == "scirpt")
        expect("กำยสนั", "deploy", .thaiToEnglish)                      // ends in ั
        expect("เดี๋ยวประชุมกัน ๅจ", "10", .thaiToEnglish)   // digits on the Thai layout, at the moment the word ends
        expect("ๅจจ", "100", .thaiToEnglish)
        // "พำฟกทำ" (readme) and "กยสนั" (dploy) are left to the LLM layer with layout hints:
        check("layout hint for พำฟกทำ", LLMSuggester.layoutHints(for: "อัปเดต พำฟกทำ กับ")["พำฟกทำ"] == "readme")
        check("layout hint for กยสนั", LLMSuggester.layoutHints(for: "กยสนั ขึ้น staging")["กยสนั"] == "dploy")
        let noHints = LLMSuggester.layoutHints(for: "ส่ง PR แล้วนะ รอ review ด้วยค่ะ ทำไมต้องเทสทั้งหมด")
        check("no hint for real words", noHints.isEmpty, "\(noHints)")

        print("\n== must stay quiet: correct English ==")
        for s in ["journey", "don't", "retest", "Nirvania", "hello world", "the quick brown fox jumps over the lazy dog",
                  "ok", "lol", "pls fix the bug", "idk", "btw", "asap", "fyi", "tbh", "api", "db", "git push",
                  "merge pr", "ci failed", "login signup checkout cart payment", "deploy to staging and prod",
                  "na ka", "krub", "jaa", "kk", "mak mak", "pai kin khao", "arai na", "mai dai", "chai",
                  "https://example.com/path", "user@example.com", "v1.2.3", "2024", "and", "for", "fix", "can",
                  "I am going to retest the whole journey", "re-test it", "wfh today",
                  "google", "github", "deploy to staging and prod", "google meet", "login with google", "checkout",
                  "sprint planning", "buildscript", "readme", "oncall tonight", "lgtm", "k8s", "api gateway"] {
            expect(s, nil)
        }

        print("\n== must stay quiet: correct Thai ==")
        for s in ["สวัสดีครับ วันนี้อากาศดี", "แก้เรื่องไหนก็รีเทสเรื่องนั้น", "ทน", "สน", "รก", "ดี", "มา", "ไป", "ถนน ขนม",
                  "ทำไมต้องเทสทั้งหมด", "โอเคค่ะ เดี๋ยวแก้ให้", "ขอบคุณมากนะคะ", "พี่จีน", "ไม่เป็นไร", "เสร็จแล้ว",
                  "อยู่ไหน", "กินข้าวยัง", "รันได้แล้ว", "ลองดูก่อน", "จริงๆ แล้ว", "น้ำ", "เพราะว่า", "ผลไม้",
                  "บัคนี้แก้ยาก", "เดี๋ยวประชุมกัน", "ส่ง PR แล้ว", "ดูที่ journey นี้"] {
            expect(s, nil)
        }

        print("\n== every common Thai word is safe on its own ==")
        var unsafeWords: [String] = []
        for w in Detector.commonShortThai where d.suggest(buffer: w) != nil { unsafeWords.append(w) }
        check("no common Thai word triggers thaiToEnglish", unsafeWords.isEmpty, unsafeWords.joined(separator: " "))

        print("\n== orthography ==")
        for good in ["ที่", "น้ำ", "เป็น", "เพราะ", "อยู่", "ทั้งหมด", "ศักดิ์", "เกี่ยวข้อง", "ก็", "ตัวอย่าง"] {
            check("valid: \(good)", ThaiOrtho.isValid(good.unicodeScalars))
        }
        for good2 in ["ก็", "แล้วก็", "ฮึ"] {
            check("valid: \(good2)", ThaiOrtho.isValid(good2.unicodeScalars))
        }
        for bad in ["้ำสสน", "ะ้ำ", "ไ", "กิี", "ก่้", "าก", "เๆ", "ำ", "สนเรื", "กำยสนั", "เก็"] {
            check("invalid: \(bad)", !ThaiOrtho.isValid(bad.unicodeScalars))
        }

        print("\n== multi-line buffers ==")
        expect("บรรทัดแรก journey\nmujgdujp;-hv'", "ที่เกี่ยวข้อง")
        check("LLM segment is the last line only", LLMSuggester.segment(of: "line one here\nsecond line  ") == "second line")

        print("\n== thai typo rules ==")
        for (bad, good) in [("เป้น", "เป็น"), ("เป้นไร", "เป็นไร"), ("ก้", "ก็"), ("เเล้ว", "แล้ว"), ("ไม๋", "ไม่"), ("เด้ก", "เด็ก"), ("เช้ค", "เช็ค")] {
            check("typo \(bad) -> \(good)", ThaiTypos.fix(bad) == good, "got \(ThaiTypos.fix(bad) ?? "nil")")
        }
        for ok in ["แล้ว", "ได้", "ไม่", "จ๋า", "ก๋วยเตี๋ยว", "น้ำ", "ใช้", "เป็น", "hello", "เก้า", "เข้า", "เล้า"] {
            check("untouched \(ok)", ThaiTypos.fix(ok) == nil, "got \(ThaiTypos.fix(ok) ?? "nil")")
        }

        print("\n== popup diff display ==")
        let multi = SuggestionPanel.differingParts(["ส่งงานแล้วนะ ต่อให้ suggest ขึ้นมาแล้ว", "ส่งงานแล้วนะ ต้องให้ suggest ขึ้นมาแล้ว"])
        check("options show only the differing word", multi[0].first(where: \.emphasised)?.text == "ต่อให้" && multi[1].first(where: \.emphasised)?.text == "ต้องให้",
              multi.map { $0.map { ($0.emphasised ? "[" : "") + $0.text + ($0.emphasised ? "]" : "") }.joined() }.joined(separator: " | "))
        let single = SuggestionPanel.changedWords(from: "กำลังทดสอบคียืบอด ต้อให้ suggest", to: "กำลังทดสอบคีย์บอร์ด ต้องให้ suggest")
        check("changed words emphasised", single.filter(\.emphasised).map(\.text).joined() == "กำลังทดสอบคีย์บอร์ด ต้องให้",
              single.map { ($0.emphasised ? "[" : "") + $0.text + ($0.emphasised ? "]" : "") }.joined())

        print("\n== emoji mode helpers ==")
        check("strip trailing emoji", LLMSuggester.strippingTrailingEmoji("เสร็จแล้วค่ะ 🎉✨") == "เสร็จแล้วค่ะ")
        check("strip skin-tone emoji", LLMSuggester.strippingTrailingEmoji("ขอบคุณนะคะ 🙏🏻") == "ขอบคุณนะคะ")
        check("only adds emoji", LLMSuggester.onlyAddsEmoji(original: "ส่ง PR แล้วนะ", fixed: "ส่ง PR แล้วนะ 🚀"))
        check("not only emoji when a word changed", !LLMSuggester.onlyAddsEmoji(original: "ส่ง PR แล้วนะ", fixed: "ส่ง PR แล้วนะคะ 🚀"))
        check("not only emoji when nothing added", !LLMSuggester.onlyAddsEmoji(original: "ส่ง PR แล้วนะ", fixed: "ส่ง PR แล้วนะ"))

        print("\n== typing test scoring ==")
        check("identical = 100%", TypingTest.accuracy(typed: "สวัสดีค่ะ", target: "สวัสดีค่ะ") == 1)
        check("empty typed = 0%", TypingTest.accuracy(typed: "", target: "abc") == 0)
        let one = TypingTest.accuracy(typed: "hello wrold", target: "hello world")
        check("two swapped letters ≈ 82%", abs(one - (1 - 2.0 / 11.0)) < 0.001, String(format: "%.3f", one))
        check("trailing space ignored", TypingTest.accuracy(typed: "ส่ง PR แล้ว ", target: "ส่ง PR แล้ว") == 1)
        check("letter case ignored", TypingTest.accuracy(typed: "ส่ง pr แล้วนะ รอ review", target: "ส่ง PR แล้วนะ รอ review") == 1)

        print("\n\(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")")
        return failures == 0 ? 0 : 1
    }
}
