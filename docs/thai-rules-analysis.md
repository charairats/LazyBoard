# วิเคราะห์กฎ "Thai จริงไหม / แปลงไหม / เขียนทับไหม" (HEAD d806396)

อ่านอย่างเดียว ไม่แก้โค้ด ทุก counter-example ผมรันจริงผ่าน probe build (คอมไพล์ `Sources/LazyBoard/*.swift` ที่ HEAD + `thai-words.txt` 25,497 คำ) ไม่ได้เดาเอาครับ
ผลรวมจากการ scan ทั้ง dictionary:

| scan | ผล |
|---|---|
| คำไทยจริงใน dict ที่พิมพ์เดี่ยวแล้ว space → ถูกเขียนทับเป็น "อังกฤษ" | **139 คำ** (ฟอร์ม→`aviN,`, ทฤษฎี→`mAKEu`, คุม→`86,`, กฎ→`dE`, สกปรก→`ldxid`, โฆษณา→`FSKIk` …) |
| คำไทยจริงใน dict ที่ `ThaiTypos.fix` เขียนทับบน space | **228 คำ** (เดี๋ยว→เดี่ยว, เส้น→เส็น, เข้ม→เข็ม, อ๋อ→อ่อ, แจ๋ว→แจ่ว, กระเป๋า→กระเป่า …) |
| คำอังกฤษจริงที่ถูกแปลงเป็นไทย | **1 คำที่ใช้จริง: `me` → ทำ** (`tell me ` → `tell ทำ `) |

`--test` ของ app ที่ build ไว้ตอนนี้: 1 FAILED (`whole word not doubted: สเตตัส` → doubt `ตัส` nearCommon) ไม่เกี่ยวกับ auto-write แต่แจ้งไว้

---

## 0. Headline case: `gik.shoeg-hk` (14:44:52 วันนี้)

**สิ่งที่เกิด:** Jean พิมพ์ไทย `เราให้นำเข้า` (keys `g i k . s h o e g - h k`) แล้ว LazyBoard เขียนทับเป็น `gik.shoeg-hk` — อ่าน reading แรกของ coordinator ถูกครับ (ไม่ใช่กรณี "ไม่แปลง")

**หลักฐานใน log** (`~/Library/Logs/LazyBoard.log`):
```
14:44:40 switch: keys still on the old layout after Caps Lock
14:44:44 switch: keys still on the old layout after Caps Lock
14:44:45 layout suggestion (4 keys)
14:44:52 auto layout fix after switch (13 keys)      ← intentCandidate()
14:44:52 applied layout fix (13 keys) auto
```
13 keys = 12 ตัวของ `เราให้นำเข้า` + space → path คือ **Caps Lock intent (`intentCandidate` → `Detector.intentConversion(wantThai: false)`)** ไม่ใช่ verdict/suggest, ไม่ใช่ isDevToken, ไม่ใช่ LLM

**probe ยืนยัน:**
```
intentConversion("เราให้นำเข้า", wantThai:false) = "gik.shoeg-hk"
suggest("เราให้นำเข้า ")                        = nil   (path ปกติไม่แตะ)
isRealThai("เราให้นำเข้า") = false ; isRealThai("นำเข้า") = false
```

**root cause 2 ชั้น:**
1. **dictionary ตกหล่น** — `นำเข้า` ไม่มีใน thai-words.txt และ split `นำ|เข้า` ไม่ผ่าน เพราะ `splitsIntoThaiWords` ยอมชิ้น 2 ตัวอักษรเฉพาะที่อยู่ใน `commonShortThai` และ `นำ` ไม่อยู่ในนั้น → source "ไม่ใช่ไทยจริง"
2. **ฝั่ง English target หลวม** — `intentConversion` ฝั่ง toEng ยอม `isEnglishWord(core) || looksEnglish(core)`; `looksEnglish("gik.shoeg-hk")` = true (vowel ratio 0.25, ไม่มี consonant run ≥4) regex `^[A-Za-z0-9][A-Za-z0-9'.-]*$` ก็ยอม `.` `-` ข้างใน → เขียนทับด้วย gibberish
   ฝั่ง toThai ถูกแก้แล้วใน d806396 (ต้อง `isRealThai`), ฝั่ง toEng ยังไม่สมมาตร

ถ้าเป็น reading ที่สอง (พิมพ์บน English layout) ก็ยังพังด้วยเหตุข้อ 1 เหมือนกัน: `suggest("gik.shoeg-hk ")` = nil เพราะ `englishToThaiVerdict` มี guard `isRealThai(thaiString)` → false → `.none` — คือ dict gap ทำให้ทั้ง "ไม่แปลงเมื่อควร" และ "แปลงเมื่อไม่ควร"

**ข้อสรุป:** ฝั่ง Thai→English ต้องมีกฎเดียวกับฝั่ง English→Thai: *target ต้องเป็นอังกฤษจริง (dict lowercase / knownEnglish / acronyms / devToken ที่ทุกชิ้นเป็นคำรู้จัก) AND source ต้องไม่ใช่ไทยจริง* และ dictionary ต้อง split คำประสมทั่วไปได้ (นำ, ส่ง, รับ … เป็น 2-letter word ที่ควรอยู่ใน whitelist)

---

## 1. ทุก path ที่เขียนทับข้อความอัตโนมัติ

trigger ที่ auto-write ได้มี 3 จุดใน `KeyMonitor.handle`:
- **space** (`typed == " "`): `autoFixCandidate()` → `intentCandidate()` → `thaiTypoCandidate()` (ตัวแรกที่ไม่ nil ชนะ)
- **Enter (plain/Ctrl)**: `autoFixCandidate() ?? intentCandidate()` — *ไม่มี* thaiTypo
- **Shift/Cmd/Opt+Enter (`newline`)**: เหมือน Enter
- (LLM: emoji mode อย่างเดียวที่ auto-apply และต้อง `onlyAddsEmoji`; ที่เหลือรอ Tab — ไม่นับเป็น auto-write)

| # | Path | ทิศ | เงื่อนไขหลัก | target จริง? | source ไม่จริง? | ortho |
|---|---|---|---|---|---|---|
| A1 | `suggest` E→T strong: 2-key common (`L227`) | EN→TH | thai ∈ commonShortThai, ≤2 keys, keys ∉ knownEnglish | ✅ common list | ❌ ไม่เช็ค isEnglishWord → `me`→ทำ | ✅ (violations=0) |
| A2 | E→T strong: common/slang ≥4 keys (`L232`) | EN→TH | isCommon, ≥4 keys | ✅ | ❌ ตั้งใจ (ivcxx) แต่ไม่จำกัด | ✅ |
| A3 | E→T strong: `!englishOK && (≥4 \|\| vowel&&common)` (`L235`) | EN→TH | | ✅ isRealThai | ✅ spellchecker | ✅ (≤n/12 ถ้า ≥8) |
| A4 | E→T weak (`L240`) ขี่ run | EN→TH | hasVowel \|\| !englishOK \|\| lenient \|\| common | ✅ | บางส่วน (English กลาง run หยุด run) | ✅ |
| B1 | T→E digits (`L253`) | TH→EN | keys = `^[0-9][0-9.,:%/-]*$`, ≥2 | ✅ เป็นตัวเลข | ❌ → คุม→`86,` จม→`0,` คม→`8,` | ❌ |
| B2 | T→E devToken (`L258`) | TH→EN | isDevToken(english) | ✅ ทุกชิ้นเป็นคำ | ✅ isRealThai | ❌ |
| B3 | T→E `englishOK && (!valid \|\| (!vowel && ≥4))` (`L270`) | TH→EN | | ⚠️ spellchecker (ยอม mixed case) | ❌ → ฟอร์ม→`aviN,` | ใช้ !valid เป็นหลักฐาน |
| B4 | T→E `englishOK, ≥5 letters` (`L275`) | TH→EN | | ⚠️ mixed case ผ่าน | ❌ → ทฤษฎี→`mAKEu`, ทำโทษ→`meFmK` | ❌ |
| B5 | T→E shift-layer acronym (`L279`) | TH→EN | englishOK, no vowel, มี shift char | ⚠️ | ❌ → กฎ→`dE`, ศร→`Li` | ❌ |
| B6 | T→E real EN + not real TH (`L284`) | TH→EN | englishOK, ≥3, !isRealThai | ⚠️ | ✅ | ❌ |
| B7 | T→E all-shift uppercase (`L288`) | TH→EN | !valid, 2–6, all upper | ❌ ไม่เช็ค (์ญฉ→NPC) | ✅ (!valid) | ✅ |
| B8 | T→E `!valid && englishHasVowel && ≥3` (`L292`) | TH→EN | | ❌ ไม่เช็คเลย → `fuu`, `meko`, `reieiw` | ✅ (!valid) | ✅ |
| B9 | T→E looksEnglish + ICU score<0.34 (`L297`) | TH→EN | !englishOK, ≥5 | ❌ shape only | ⚠️ ICU ไม่ใช่ dict → สกปรก, เทรนด์, ปอนด์, สหกรณ์ | ❌ |
| B10 | T→E weak (`L302`) ขี่ run | TH→EN | englishOK \|\| (!valid && (lenient \|\| vowel)) | ❌/⚠️ | หลัง guard L301 ✅ | |
| B11 | mixed head `สogin` (`L180`) | TH→EN | 1–2 Thai head + ≥2 ASCII letters, english ≥4 & isEnglishWord | ✅ | — | — |
| C1 | `intentConversion` wantThai (Caps Lock) | EN→TH | armed intent, !isEnglishWord, vowel, violations ≤max(1,n/6) | ✅ isRealThai (d806396) | ✅ | ✅ |
| C2 | `intentConversion` wantEnglish | TH→EN | armed intent, ∉thaiWords, !(valid && isRealThai) | ❌ `isEnglishWord \|\| looksEnglish` → `gik.shoeg-hk`, `fuu`, `gxo` | ✅ แต่ dict gap | |
| D1 | `ThaiTypos.fix` เเ→แ | TH→TH | มี `เเ` | ❌ | ❌ | (เเ invalid อยู่แล้ว ปลอดภัยจริง) |
| D2 | `fix` ๋→่ | TH→TH | มี ๋ และคำ ∉ maiChattawaWords (16 คำ) | ❌ | ❌ → เดี๋ยว→เดี่ยว | ❌ |
| D3 | `fix` ้→็ (exact + prefix) | TH→TH | ผลลัพธ์ ∈ maitaikhuWords | ✅ list | ❌ → เส้น→เส็น, เข้ม→เข็ม, เข้มแข็ง→เข็มแข็ง | |
| D4 | `fix` นะค่ะ→นะคะ | TH→TH | suffix ใน khaEndings | grammar rule | (ทั้งคู่จริง — ตั้งใจ) | |
| D5 | `ThaiTypos.slipFix` | TH→TH | ≥3, all Thai, 1 slip, unique | ✅ valid+isRealThai | ✅ valid+isRealThai | ✅ |

ไม่ auto-write แต่ใช้ predicate เดียวกัน: `LLMSuggester.layoutHints` (hint ให้ model), `doubts` (ตัดสินว่า Enter ต้องรอ/quiet check)

หมายเหตุเรื่อง run: `suggest` เดินถอยหลังรวมคำทิศเดียวกันได้สูงสุด 12 คำ ต้องมี strong ≥1 แล้ว weak ทุกคำในเส้นทางถูกแปลงไปด้วย — weak ไม่ได้ผ่านกฎ target เดียวกับ strong

---

## 2. Counter-examples ที่หลุดวันนี้ (รันจริง)

### 2.1 English → Thai
| พิมพ์ | ผล | rule |
|---|---|---|
| `tell me ` / `send me ` / `me ` | `ทำ ` | A1: `ทำ` ∈ commonShortThai, 2 keys, `me` ∉ knownEnglish → ไม่ดูว่า `me` เป็นอังกฤษจริง |
| scan keys-of-dict-words ที่เป็นคำอังกฤษ | `-v`→ขอ, `fu`→ดี, `z,`→ผม, `w'`→ไง, `wi`→ไร, `mew,`→ทำไม … | มีแค่ `me` ที่เป็นคำใช้จริง |
| `w,jwfh ok⏎` (ถ้า w,jwfh ไม่ถูกแก้ตอน space เช่นหลัง Esc) | `ไม่ได้ นา` | Enter ใช้ verdict แบบ `isLast=true` → `ok` เป็น weak lenient ขี่ run |
| `gik.shoeg-hk ` (ตั้งใจ เราให้นำเข้า) | **ไม่แปลง** | target `เราให้นำเข้า` ไม่ผ่าน isRealThai (dict gap นำเข้า/นำ) |

abbreviations ที่ผมลอง (pls brb nvm afk lol gg ez sudo chmod grep wget kubectl vite uuid href src btn ctx req msg cfg foo bar baz ngl rn fr ty thx omg wtf tbd dm ig yt aka): **ไม่แปลงเลย** — ฝั่ง EN→TH แข็งแรงเพราะ target ต้องเป็นไทยจริง

### 2.2 Thai → English (ฝั่งที่หลวม)
| พิมพ์ (เดี่ยว + space) | ผล | rule | ทำไม |
|---|---|---|---|
| `ฟอร์ม ` | `aviN, ` | B3 (L270) | NSSpellChecker ไม่ flag คำ mixed-case (`aviN`) → englishOK=true; ฟอร์ม ไม่มีสระ & ≥4 |
| `ทฤษฎี ` `โฆษณา ` `ทัศนะ ` `ทำโทษ ` `กระฉอก ` `ดี๊ด๊า ` | `mAKEu` `FSKIk` `myLot` `meFmK` `ditCvd` `fuUfUk` | B4 (L275) | mixed-case loophole เดียวกัน; rule ไม่เช็ค isRealThai |
| `กฎ ` `ศร ` | `dE` `Li` | B5 (L279) | mixed-case + shift char |
| `คุม ` `จม ` `คม ` `ตม ` `ถม ` | `86,` `0,` `8,` … | B1 (L253) | ไม่เช็คว่า source เป็นไทยจริง |
| `สกปรก ` `เทรนด์ ` `ปอนด์ ` `สหกรณ์ ` | `ldxid` `gmiofN` `xvofN` `lsdiIN` | B9 (L297) | ใช้ ICU `thaiWordScore` ซึ่งนับเฉพาะ token ที่มีสระ → คำไม่มีสระได้ 0; guard real-Thai (L301) อยู่ *หลัง* rule นี้ |
| `ดีี ` `ทำาน ` | `fuu` `meko` | B8 (L292) | typo ไทย (สระซ้ำ) → !valid + keys มี vowel → แปลงเป็น gibberish ก่อนที่ thaiTypo/LLM จะได้ดู |
| `รอ พำรำรไ ` | `รอ reieiw` | B8 | SelfTest ยืนยัน behavior นี้อยู่ (`review?.replacement == "reieiw "`) |
| `กฎ ะำหะ ` | `dE test` | B5 + run | |
| `ืยแ ` (npc) | ไม่แปลง | — | `npc` ไม่มีสระ, ∉ knownEnglish, ไม่ใช่ uppercase → ไม่มี rule ไหนรับ |

ข้อจำกัด: ไทยเขียนติดกัน กรณีข้างบนเกิดเมื่อคำไทยถูกเว้นวรรคเดี่ยว (`กรอก ฟอร์ม นี้`, `ตาม ทฤษฎี`) — ถ้าติดคำอื่น (`ส่งฟอร์ม`, `อ่านทฤษฎี`, `คุมงาน`) ไม่แปลง ผม probe แล้ว

### 2.3 Caps Lock intent (C1/C2)
| คำ | toThai | toEng |
|---|---|---|
| `เราให้นำเข้า` | — | **`gik.shoeg-hk`** (เกิดจริง 14:44:52) |
| `ดีี` / `ทำาน` | — | `fuu` / `meko` |
| `เปน` (สะกดแบบแชต) | — | `gxo` |
| `ืยแ` | — | nil (ไม่มี vowel, ไม่อยู่ list) |
| `.secret` | nil (แก้แล้ว) | — |

### 2.4 ThaiTypos.fix บน space (D2/D3) — 228 คำจริงใน dict ถูกเขียนทับ
- ๋→่: `เดี๋ยว`→เดี่ยว, `เดี๋ยวแก้ให้`→เดี่ยวแก้ให้, `อ๋อ`→อ่อ, `เจ๋ง`→เจ่ง, `แจ๋ว`→แจ่ว, `เก๋า`→เก่า, `กระเป๋า`→กระเป่า, `ปุ๋ย`, `ลูกเต๋า`, `ก๋วยจั๊บ`, `ประเดี๋ยว`, `รถเก๋ง` … (whitelist มีแค่ 16 คำ)
- ้→็: `เส้น`→เส็น (+ เส้นทาง, เส้นตาย …), `เข้ม`→เข็ม, `เข้มแข็ง`→เข็มแข็ง, `เข้มงวด`, `แข้ง`→แข็ง, `เซ้ง`, `เล้ง`, `เป้ง` — เพราะ `เส็น`/`เข็ม`/`แข็ง` อยู่ใน maitaikhuWords และ prefix rule ก็ไม่ดูว่าคำเดิมจริงไหม
- slipFix ปลอดภัย: สแลงที่ไม่อยู่ใน dict (`เปน ชั้ย มั๊ย ม่ายย งับบ จ้าาา`) ไม่ถูกแตะ

---

## 3. ความไม่สอดคล้องระหว่าง path

1. **"ไทยจริง" มี 5 นิยาม**: isRealThai (dict+split), commonShortThai/slang list, ICU `thaiWordScore` (B9, layoutHints), `ThaiOrtho.isValid` เฉย ๆ (B3/B7/B8 ใช้ invalid เป็นหลักฐานว่าไม่ใช่ไทย), และ "ไม่เช็คเลย" (B1, B4, B5, D2, D3)
2. **"อังกฤษจริง" มี 4 นิยาม**: `isEnglishWord` (spellchecker — มีช่องโหว่ mixed-case), `looksEnglish` (shape), `isDevToken`, และ "ไม่เช็คเลย" (B7, B8) — ขณะที่ฝั่งไทย target ต้อง isRealThai เสมอ ⇒ **Thai side strict, English side loose**
3. **source check ไม่สม่ำเสมอ**: EN→TH เช็ค source ด้วย spellchecker เกือบทุก rule (ยกเว้น A1/A2); TH→EN เช็ค isRealThai แค่ B2, B6, และ guard L301 ซึ่งอยู่ *ท้าย* function — rule B1/B3/B4/B5/B9 return ก่อนถึง guard
4. **strong vs weak ไม่มีความหมายเดียว**: strong = "ผ่าน rule ใด rule หนึ่งใน 3 (EN→TH) หรือ 9 (TH→EN)"; weak = "ขี่ run ได้ถ้ามี strong" — weak ฝั่ง TH→EN ไม่เช็ค target เลย (`!valid && lenient`) → gibberish ขี่ run ได้
5. **isLast/lenient**: Enter/newline ใช้ suggestion ที่คำนวณตอนกดปุ่มล่าสุด (คำสุดท้าย lenient) ส่วน space คำนวณหลังใส่ space (ไม่ lenient) → Enter หลวมกว่า space
6. **thaiTypo ทำแค่ตอน space** — Enter/newline ไม่ทำ (คำสุดท้ายก่อนส่งไม่ถูกแก้)
7. **ลำดับบน space**: layout ก่อน typo → `ดีี ` ถูกแปลงเป็น `fuu` ก่อน slipFix/LLM จะเห็น
8. **ortho tolerance 4 ค่า**: suggest (0 หรือ n/12 ถ้า ≥8), intent (max(1,n/6)), layoutHints (max(1,n/10)), readsAsThai (max(1,n/6)) — แต่เมื่อ target ต้อง isRealThai อยู่แล้ว tolerance แทบไม่มีผล
9. **Caps Lock intent ไม่สมมาตร**: toThai ต้อง isRealThai, toEng แค่ looksEnglish (ต้นเหตุ gik.shoeg-hk)
10. **dict split**: ชิ้น 2 ตัวอักษรต้องอยู่ใน commonShortThai → คำประสมพื้นฐาน (นำเข้า, นำส่ง, ผลิตภัณฑ์ ฯลฯ ที่ไม่มีใน libthai) ตกหมด ทั้งทำให้ไม่แปลงเมื่อควร และทำให้ source "ไม่จริง" จนถูกเขียนทับ

---

## 4. กฎชุดเดียวที่เสนอ

**Predicates (ไฟล์เดียว เช่น `Words.swift`; ทุก path ใช้ตัวเดียวกัน)**
- `realThai(s)` = `ThaiOrtho.isValid(s)` && (dict ∪ common ∪ slang ∪ loan contains s || splits) — ขยาย whitelist 2-letter ให้ครอบคำพื้นฐาน (นำ ส่ง รับ ผล ทาง …) แทนการพึ่ง commonShortThai อย่างเดียว
- `realEnglish(s)` = letters (+ `'` `-`), case pattern ต้องเป็น `lower` / `Capitalized` / `ALLCAPS` เท่านั้น (ปิด mixed-case loophole: `mAKEu`, `dE`, `aviN`), spellcheck **รูป lowercase**, หรือ ∈ knownEnglish ∪ acronyms (case-insensitive), roman rule เดิม
- `realNumber(s)` = digit pattern เดิม
- `realDevToken(s)` = isDevToken เดิม (ทุกชิ้นเป็น realEnglish)

**R1 — Overwrite rule (ทุก auto-write path: suggest, intent, typo):**
> เขียนทับได้ก็ต่อเมื่อ **target จริง** (`realThai` / `realEnglish` / `realNumber` / `realDevToken`) **AND source ไม่จริงในสคริปต์ตัวเอง** (TH: `!realThai`; EN: `!realEnglish && !looksLikeCode`)

ข้อยกเว้นเป็น list ชัด ๆ ไม่ใช่ heuristic: `iv`/`ivcxx` (roman rule), pairs ค่ะ/คะ ใน khaEndings
**R2 — Confidence:** strong = R1 ผ่าน และ target เป็นคำใน dict/list ทั้งคำ (ไม่ใช่ split) หรือ ≥3 keys; weak = R1 ผ่านแต่สั้น/split — **ทุกคำใน run ต้องผ่าน R1** (weak ไม่ข้าม target check อีก)
**R3 — Shape-only evidence** (`looksEnglish`, ICU score, `suspiciousThai`, `!valid && vowel`) → ใช้เป็น `layout_hints`/`doubts` ให้ LLM เท่านั้น ห้าม auto-write
**R4 — Caps Lock intent:** R1 ทั้งสองทิศ (ลด evidence threshold ได้: คำเดียว 2 keys พอ) — ตัด `looksEnglish` ฝั่ง toEng
**R5 — ThaiTypos:** generate candidate (เเ→แ, ๋→่, ้→็, slip) แล้ว **filter ด้วย R1** — เดี๋ยว/เส้น/เข้ม/อ๋อ ไม่โดน; เเล้ว/ไม๋/เป้น/เด้ก ยังโดน
**R6 — Triggers เท่ากัน:** space, Enter, newline รัน pipeline เดียว (layout → intent → typo) ด้วย `isLast=false` เสมอ

### Tests ที่จะเปลี่ยน
ต้องเปลี่ยนความคาดหวัง:
- `รอ พำรำรไ ` คาด `reieiw ` → **nil** (ส่งให้ LLM พร้อม hint `review`)
- `์ญฉ` → `NPC` ผ่านต่อเมื่อ `npc` อยู่ใน acronyms (ดู wip patch) ไม่งั้นเป็น nil
- `ส่ง ญพ` → `Pr` ผ่าน (pattern Capitalized, `pr` known) — ถ้าอยากได้ `PR` ต้องใช้ acronyms

ยังผ่านเหมือนเดิม (ผมเช็ค source ไม่ใช่ไทยจริงแล้ว): hello, world, test, hi-fi, script(หแพรยะ), deploy, README, repo/push/pull/api/ctrl/cmd/k8s, feature/build-esim, README.md, levels.maxLevel, login/local, 10/100, sonnet/llm (intent), ThaiTypos เป้น/ก้/เด้ก/เช้ค/ไม๋/เเล้ว, ค่ะ/คะ ทั้งชุด, ทุกเคส EN→TH เดิม

เพิ่มใหม่:
- `me `, `tell me ` → nil
- `ฟอร์ม `, `ทฤษฎี `, `กฎ `, `คุม `, `สกปรก `, `โฆษณา `, `ดีี `, `ทำาน ` → nil
- `fix`: เดี๋ยว, เดี๋ยวแก้ให้, เส้น, เข้ม, เข้มแข็ง, อ๋อ, แจ๋ว, กระเป๋า → nil
- intent toEng: `เราให้นำเข้า`, `ดีี`, `เปน` → nil; toThai `gik.shoeg-hk` → `เราให้นำเข้า` (หลังขยาย split)
- `suggest("gik.shoeg-hk ")` → `เราให้นำเข้า `
- **scan test** แทน "every common Thai word is safe": ทุกคำใน `thaiWords` ต้องได้ `suggest(w+" ") == nil` และ `ThaiTypos.fix(w) == nil` (ยกเว้น khaEndings) — วันนี้ fail 139 + 228
- scan: keys ของทุกคำใน dict ที่เป็น `realEnglish` ต้องไม่ถูกแปลง (วันนี้ fail: `me`)

---

## 5. `wip-acronym.patch` (untracked) สั้น ๆ
- เพิ่ม `KeyMap.acronyms` (llm, api, pr, ui, npc, fps, hp, ok, id, cd, …, ios→iOS) และ `capitalizingAcronyms`
- `thaiToEnglishVerdict`: keys เป็น acronym ตัวเล็ก + `!isRealThai(word)` → strong (แก้ ืยแ→NPC)
- `suggest` TH→EN, `intentConversion` toEng (รับ acronym), `layoutHints`: ใส่ตัวใหญ่ให้ acronym
- สอดคล้องกับ R1 (target ∈ list, source ไม่จริง) ควรรวมเข้า `realEnglish` เลย
- ระวัง: `capitalizingAcronyms` ใช้กับทั้ง run → `cd src` (พิมพ์บน Thai layout) กลายเป็น `CD src`, `ok`→`OK`, `id`→`ID`; คำ 2 ตัวใน list (ok/id/gm) บางคำ keys เป็นไทยจริง (นา, รก, เท) — guard `!isRealThai` กันไว้ได้

---

## 6. Implemented (branch fix/thai-word-check)

ทำครบ R1–R6 แล้วครับ `--test` ผ่านทั้งหมด (รวม scan ทั้ง dictionary)

- **`Words.swift`**: `realThai` (dict ตรง ๆ หรือ valid + split), `realEnglish`, `realNumber`, `realDevToken`, `realEnglishTarget`, `split` (ตัดคำด้วย scalar)
- **`isEnglishWord`**: ยอมเฉพาะ lower / Capitalized / ALLCAPS (ทีละส่วนที่คั่นด้วย `-`) ปิดช่องโหว่ mixed-case; ถ้าเป็น ALLCAPS ให้สะกดเทียบกับรูป lowercase; ยอม acronyms; ตัวเลขโรมันตัวใหญ่ยังนับเป็นอังกฤษ
- **split**: เพิ่ม `shortSplitWords` (นำ ผล รถ ปี ยา ตา หู ชา นม คอ ขา ลม ฝน สี ปู งู ไฟ ใจ ใบ ตก จด ยก สด อก) ทำให้ นำเข้า และ เราให้นำเข้า ผ่าน
- **verdict EN→TH**: ถ้า source เป็นคำอังกฤษจริงจะไม่แปลงเลย (`me` ไม่กลายเป็น ทำ) ส่วน target ต้องผ่าน `realThai`/list และเลิกใช้ ortho tolerance แล้ว
- **verdict TH→EN**: ถ้า source เป็นไทยจริงจะคืน `.none` ตั้งแต่บรรทัดแรก target ต้องเป็นตัวเลข devToken หรือคำอังกฤษจริงเท่านั้น ลบ rule ที่ดูแค่รูปร่างคำออกแล้ว (`!valid && vowel`, `looksEnglish` + ICU) ตอนนี้ใช้เป็น hint อย่างเดียว
- **`isLast`** ไม่ทำให้กฎหลวมลงอีกแล้ว: space, Enter และ newline ตัดสินคำเหมือนกัน
- **intent (Caps Lock)**: ใช้ R1 ทั้งสองทิศ ตัด `looksEnglish` ออก
- **ThaiTypos.fix**: แก้การสะกด (เเ ๋ ้) จะเกิดเฉพาะเมื่อคำที่พิมพ์ไม่ใช่คำจริงและผลลัพธ์เป็นคำจริง ส่วน ค่ะ/คะ ยังเป็นข้อยกเว้นตามเดิม `slipFix` เปลี่ยนมาใช้ `realThai`
- **KeyMonitor**: Enter และ newline ใช้ `autoWriteCandidate()` (layout → intent → typo) เหมือนตอนกด space typo fix ทำงานตอน Enter ได้แล้ว
- **Acronyms** (รวม wip patch): npc→NPC, llm→LLM, api→API, ios→iOS ตัวใหญ่เฉพาะคำที่เป็น acronym เท่านั้น ส่วน ok id cd os http https ssh ยังนับเป็นคำอังกฤษแต่คงตัวเล็กไว้ (`cd src` ไม่กลายเป็น `CD src`)
- **Bug ที่เจอระหว่างทำ**: `" ืยแ"` ช่องว่างตามด้วยสระบน Swift มองเป็น Character เดียวกัน ทำให้ layoutHints/doubts ตัดคำไม่ออก ตอนนี้เปลี่ยนมาใช้ `Words.split`
- **doubts**: เคส nearCommon จะ flag เฉพาะชิ้นที่เป็นคำใน dict เท่านั้น แก้ test สเตตัส ที่เคย fail แล้ว

**Behaviour ที่ Jean จะสังเกตเห็น**
- คำอังกฤษจริงไม่ถูกแปลงเป็นไทยอีก (`me`)
- คำไทยจริงที่พิมพ์แยกเดี่ยวไม่ถูกแปลงเป็นอังกฤษมั่วอีก (ฟอร์ม ทฤษฎี กฎ คุม)
- คำไทยที่สะกดผิดอย่าง `ดีี` หรือ `รอ พำรำรไ` จะไม่ถูกแปลงเป็นอังกฤษมั่วอีกแล้ว ให้ Claude เป็นคนจับแทน
- เดี๋ยว เส้น เข้ม อ๋อ แจ๋ว ไม่ถูกแก้แล้ว และไม่ถูกมองว่าเป็น typo ด้วย
- พิมพ์ `gik.shoeg-hk` แล้วกด space จะกลายเป็น เราให้นำเข้า ส่วนพิมพ์ไทยหลังกด Caps Lock จะไม่ถูกเขียนทับเป็นอังกฤษมั่ว
- ืยแ กลายเป็น NPC และ ฟยร กลายเป็น API (ตัวใหญ่)
- typo fix ทำงานตอนกด Enter ด้วยแล้ว (เช่น `ไม๋` แล้วกด Enter จะกลายเป็น `ไม่` ก่อนส่ง)
