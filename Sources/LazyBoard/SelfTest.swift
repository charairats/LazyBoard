import Foundation

/// `LazyBoard --test` : runs detector cases from the terminal, no Accessibility permission needed.
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
        // one slipped key (eeuj = ำำี่) leaves something that is not Thai words: left to the LLM check, never converted
        expect("สวัสดีค่ะ เออเริ่ด 8jteeuj;yoouhso^de]y'mflv[it[[vp^j8jt", nil)
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
        check("LLM segment keeps every line", LLMSuggester.segment(of: "line one here\nsecond line \n ") == "line one here\nsecond line")
        let thaiParagraph = String(repeating: "ก", count: 400) + " ท้าย"
        check("LLM segment keeps a long Thai paragraph", LLMSuggester.segment(of: thaiParagraph) == thaiParagraph)
        let endless = String(repeating: "ก", count: 2000)
        check("LLM segment over the limit keeps the limit", LLMSuggester.segment(of: endless).unicodeScalars.count == LLMSuggester.maxSegmentKeys)
        check("last line", LLMSuggester.lastLine(of: "one\ntwo three") == "two three")
        check("layout hints cross lines", LLMSuggester.layoutHints(for: "hello\nหแรพยะ")["หแรพยะ"] != nil)

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
        check("changed words emphasised", single.filter(\.emphasised).map(\.text).joined() == "คีย์บอร์ดต้อง",
              single.map { ($0.emphasised ? "[" : "") + $0.text + ($0.emphasised ? "]" : "") }.joined())

        print("\n== key events after a layout switch ==")
        expect("จีนเทาได้เลยปะ deploy s,fpy'", "หมดยัง", .englishToThai)
        check("stale Thai event on ABC uses the layout", InputSource.resolved(eventText: "ง", layoutText: "'") == "'")
        check("stale English event on Thai uses the layout", InputSource.resolved(eventText: "'", layoutText: "ง") == "ง")
        check("same script keeps the event", InputSource.resolved(eventText: "A", layoutText: "a") == "A")
        check("no layout data keeps the event", InputSource.resolved(eventText: "ง", layoutText: nil) == "ง")
        let abc = InputSource.layout(id: "com.apple.keylayout.ABC"), thai = InputSource.layout(id: "com.apple.keylayout.Thai")
        check("ABC layout: s", InputSource.characters(keyCode: 1, flags: [], on: abc) == "s")
        check("ABC layout: shift+s", InputSource.characters(keyCode: 1, flags: .maskShift, on: abc) == "S")
        check("Thai layout: s = ห", InputSource.characters(keyCode: 1, flags: [], on: thai) == "ห")
        check("Thai layout: ' = ง", InputSource.characters(keyCode: 39, flags: [], on: thai) == "ง")

        print("\n== emoji mode helpers ==")
        check("strip trailing emoji", LLMSuggester.strippingTrailingEmoji("เสร็จแล้วค่ะ 🎉✨") == "เสร็จแล้วค่ะ")
        check("strip skin-tone emoji", LLMSuggester.strippingTrailingEmoji("ขอบคุณนะคะ 🙏🏻") == "ขอบคุณนะคะ")
        check("only adds emoji", LLMSuggester.onlyAddsEmoji(original: "ส่ง PR แล้วนะ", fixed: "ส่ง PR แล้วนะ 🚀"))
        check("not only emoji when a word changed", !LLMSuggester.onlyAddsEmoji(original: "ส่ง PR แล้วนะ", fixed: "ส่ง PR แล้วนะคะ 🚀"))
        check("not only emoji when nothing added", !LLMSuggester.onlyAddsEmoji(original: "ส่ง PR แล้วนะ", fixed: "ส่ง PR แล้วนะ"))

        print("\n== ค่ะ / คะ ==")
        for (bad, good) in [("นะค่ะ", "นะคะ"), ("สวัสดีนะค่ะ", "สวัสดีนะคะ"), ("มั้ยค่ะ", "มั้ยคะ"), ("สวยไหมค่ะ", "สวยไหมคะ"),
                            ("จริงหรอค่ะ", "จริงหรอคะ"), ("ใช่หรือเปล่าค่ะ", "ใช่หรือเปล่าคะ")] {
            check("typo \(bad) -> \(good)", ThaiTypos.fix(bad) == good, "got \(ThaiTypos.fix(bad) ?? "nil")")
        }
        for ok in ["ค่ะ", "ได้ค่ะ", "เปล่าค่ะ", "ไม่มีอะไรค่ะ", "ขอบคุณค่ะ", "นะคะ", "ไหมคะ"] {
            check("untouched \(ok)", ThaiTypos.fix(ok) == nil, "got \(ThaiTypos.fix(ok) ?? "nil")")
        }

        print("\n== polite mode ==")
        check("off adds nothing to the request", !LLMSuggester.userMessage(for: "ส่งงานด้วย").contains("polite"))
        check("on names the particle", LLMSuggester.userMessage(for: "ส่งงานด้วย", polite: .kha).contains("\"polite\":\"ค่ะ\""))

        print("\n== request JSON ==")
        let slashes = LLMSuggester.userMessage(for: "to do / in progress/done")
        check("slashes reach the model unescaped", slashes.contains("to do / in progress/done") && !slashes.contains("\\/"), slashes)

        print("\n== enter sends at once when every word is real ==")
        for s in ["ส่ง PR แล้วนะ รอ review ด้วยค่ะ", "วันนี้หนูกำลังทดสอบระบบอยู่ค่ะ", "to do / in progress/done",
                  "ดูที่ https://example.com/path ได้เลย", "deploy ขึ้น staging แล้ว v1.2.3", "แก้ใน KeyMonitor.swift แล้วนะ",
                  "เปิด LazyBoard บน iPhone", "ส่งPRแล้ว", "ok 555 👍", "ขอบคุณมากนะคะ"] {
            check("looks fine: \(s)", LLMSuggester.looksFine(s))
        }
        for s in ["fix the corretion please", "ส่งงานแล้วนะค่ะ", "เป้นอะไรมากมั้ย", "กำลังทดสอบคียืบอด", "อัปเดต พำฟกทำ กับ",
                  "ok mujgdujp;-hv'", "เเล้วเจอกัน"] {
            check("goes to Claude: \(s)", !LLMSuggester.looksFine(s))
        }

        print("\n== why Enter waits, and what Claude changed ==")
        let english = LLMSuggester.doubts(in: "fix the corretion please")
        check("doubt: unknown English word", english.count == 1 && english[0].word == "corretion" && english[0].why == .english, "\(english)")
        check("doubt: Thai typo rule", LLMSuggester.doubts(in: "ส่งงานแล้วนะค่ะ").first?.why == .typo)
        let thaiDoubts = LLMSuggester.doubts(in: "วันนี้กำลังทดสอบคียืบอด")
        check("doubt: only the unknown Thai pieces", !thaiDoubts.isEmpty && thaiDoubts.allSatisfy { $0.why == .thai && !$0.word.contains("กำลัง") },
              thaiDoubts.map(\.word).joined(separator: "|"))
        check("doubt: wrong layout", LLMSuggester.doubts(in: "อัปเดต พำฟกทำ กับ").first?.why == .layout)
        check("ส sits next to ว", KeyMap.thaiNeighbours["ส"]?.contains("ว") == true)
        check("เสลา is one key from เวลา", LLMSuggester.commonNeighbour(of: "เสลา") == "เวลา")
        let slip = LLMSuggester.doubts(in: "ขอความแม่นเพิ่ม แลกกับเสลานิดหน่อยเราว่าคุ้มนะ")
        check("doubt: real word one key from a common one", slip.contains { $0.word == "เสลา" && $0.why == .nearCommon }, "\(slip)")
        check("common words are not near-common", LLMSuggester.commonNeighbour(of: "เวลา") == nil)
        // Found while testing in chat on 2026-11-03.
        let review = d.suggest(buffer: "ส่ง PR แล้วนะ รอ พำรำรไ ")
        check("รอ stays Thai beside a mistyped English word", review?.replacement == "reieiw " && review?.scalarCount == 7,
              "got \(review.map { "\"\($0.replacement)\" (-\($0.scalarCount))" } ?? "nil")")
        expect("/yj':hkp", "ฝั่งซ้าย", .englishToThai)
        expect("์ญฉ", "NPC", .thaiToEnglish)
        check("doubt: Thai keys with digits are not code", LLMSuggester.doubts(in: "gliH0ch]loj8tjt").first?.why == .layout)
        check("doubt: Thai keys starting with /", LLMSuggester.doubts(in: "/yj':hkp ฝั่งขวาตัวเราค่ะ").first?.why == .layout)
        for s in ["useState กับ useEffect", "ดูที่ https://example.com/a/b ได้เลย", "/clear แล้วเริ่มใหม่", "deploy v1.2.3 แล้ว"] {
            check("no layout doubt: \(s)", !LLMSuggester.doubts(in: s).contains { $0.why == .layout }, "\(LLMSuggester.doubts(in: s))")
        }
        check("reply reads unsure", LLMSuggester.reply(from: ["fixed": "x", "alternatives": [String](), "unsure": true])?.unsure == true)
        check("reply without unsure is sure", LLMSuggester.reply(from: ["fixed": "x"])?.unsure == false)
        let pairs = WordLog.changedPairs(from: "ส่ง PR แล้วนะค่ะ fix the corretion", to: "ส่ง PR แล้วนะคะ fix the correction")
        check("changed pairs", pairs.count == 2 && pairs[1] == WordLog.Pair(from: "corretion", to: "correction"), "\(pairs)")
        check("shape: thai-mark", WordLog.shape(pairs[0]) == "thai-mark", WordLog.shape(pairs[0]))
        check("shape: spelling", WordLog.shape(pairs[1]) == "spelling")
        check("shape: layout", WordLog.shape(WordLog.Pair(from: "w,jwfh", to: "ไม่ได้")) == "layout")
        check("shape: spacing", WordLog.shape(WordLog.Pair(from: "ok,", to: "ok")) == "spacing")
        check("no pairs when nothing changed", WordLog.changedPairs(from: "เหมือนเดิม ok", to: "เหมือนเดิม ok").isEmpty)

        print("\n== fix set against what was typed ==")
        check("tokens join back to the text", SuggestionPanel.tokens("ส่งงานแล้วนะ ต่อให้ suggest!").joined() == "ส่งงานแล้วนะ ต่อให้ suggest!")
        let thaiDiff = SuggestionPanel.changedWords(from: "วันนี้หนูกำลังทดสอบคียืบอดอยู่ค่ะ", to: "วันนี้หนูกำลังทดสอบคีย์บอร์ดอยู่ค่ะ")
        check("only the changed Thai word is emphasised", !thaiDiff.first!.emphasised && thaiDiff.filter(\.emphasised).map(\.text).joined().hasPrefix("คีย์"),
              thaiDiff.map { ($0.emphasised ? "[" : "") + $0.text + ($0.emphasised ? "]" : "") }.joined())
        let long = String(repeating: "ข้อความยาวมาก ", count: 30)
        let squeezed = SuggestionPanel.condensed(SuggestionPanel.changedWords(from: long + "ต่อให้", to: long + "ต้องให้"))
        check("long unchanged text is shortened", squeezed.reduce(0) { $0 + $1.text.count } < 80 && squeezed.contains { $0.emphasised && $0.text.hasPrefix("ต้อง") },
              squeezed.map(\.text).joined())

        print("\n== typing test scoring ==")
        check("identical = 100%", TypingTest.accuracy(typed: "สวัสดีค่ะ", target: "สวัสดีค่ะ") == 1)
        check("empty typed = 0%", TypingTest.accuracy(typed: "", target: "abc") == 0)
        let one = TypingTest.accuracy(typed: "hello wrold", target: "hello world")
        check("two swapped letters ≈ 82%", abs(one - (1 - 2.0 / 11.0)) < 0.001, String(format: "%.3f", one))
        check("trailing space ignored", TypingTest.accuracy(typed: "ส่ง PR แล้ว ", target: "ส่ง PR แล้ว") == 1)
        check("letter case ignored", TypingTest.accuracy(typed: "ส่ง pr แล้วนะ รอ review", target: "ส่ง PR แล้วนะ รอ review") == 1)

        print("\n== enter while checking ==")
        check("double press still waits", !KeyMonitor.enterSendsWhileChecking(elapsed: 0.5))
        check("later enter sends without waiting", KeyMonitor.enterSendsWhileChecking(elapsed: 4))

        print("\n== tab after a fix ==")
        check("double press ignored", KeyMonitor.tabIsAccidental(sinceFix: 0.2, repeated: false))
        check("held key ignored", KeyMonitor.tabIsAccidental(sinceFix: 1.0, repeated: true))
        check("deliberate second tab swaps", !KeyMonitor.tabIsAccidental(sinceFix: 1.0, repeated: false))
        check("tab long after a fix is a normal tab", !KeyMonitor.tabIsAccidental(sinceFix: 3600, repeated: true))

        print("\n== word check on both sides ==")
        expect("gfjo", "เด่น", .englishToThai)
        expect("gfbo", "เดิน", .englishToThai)
        expect("Fff", "โดด", .englishToThai)
        expect("iu[", "รีบ", .englishToThai)
        expect("Fff gfjo gfbo ", "โดด เด่น เดิน ", .englishToThai)
        expect("cloudfailre ", nil)
        expect("cloudflare ", nil)
        expect("relocator ", nil)
        expect("cosmetic: ", nil)
        expect("cosmetic; ", nil)
        expect("description: ", nil)
        expect("key:value ", nil)
        expect("name=value ", nil)
        expect("[cosmetic] ", nil)
        expect("input/output ", nil)
        expect("and/or ", nil)
        expect("lazyboard ", nil)
        expect("กอกก", nil)
        expect("กอขกก", nil)
        expect("กกขกอ", nil)
        expect("html", nil)
        expect("hello", nil)
        expect("df ", nil)
        expect("django ", nil)
        expect("canva ", nil)

        print("\n\(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")")
        return failures == 0 ? 0 : 1
    }
}
