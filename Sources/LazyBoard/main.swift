import Cocoa

if CommandLine.arguments.contains("--test") {
    exit(SelfTest.run())
}
if CommandLine.arguments.contains("--caret") {
    Caret.probe()
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--try"), i + 1 < CommandLine.arguments.count {
    let text = CommandLine.arguments[(i + 1)...].joined(separator: " ")
    if let s = Detector.shared.suggest(buffer: text) {
        print("fix \(s.scalarCount) keys -> \(s.replacement)")
    } else {
        print("no suggestion")
    }
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--verdict"), i + 1 < CommandLine.arguments.count {
    let d = Detector.shared
    for word in CommandLine.arguments[(i + 1)...] {
        let v = d.verdict(word, isLast: true)
        let scalars = Array(word.unicodeScalars)
        let thai = KeyMap.convert(scalars, direction: .englishToThai)
        let eng = KeyMap.convert(scalars, direction: .thaiToEnglish)
        print("\(word): \(v.confidence) \(String(describing: v.direction)) | toThai=\(thai) valid=\(ThaiOrtho.isValid(thai.unicodeScalars)) common=\(Detector.commonShortThai.contains(thai)) score=\(String(format: "%.2f", d.thaiWordScore(thai))) | toEng=\(eng) englishOK=\(d.isEnglishWord(word)) looksEnglish=\(Detector.looksEnglish(word))")
    }
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--llm"), i + 1 < CommandLine.arguments.count {
    // Each remaining argument is one text; they run one after another through the same backend.
    let texts = Array(CommandLine.arguments[(i + 1)...])
    let llm = LLMSuggester()
    llm.apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? KeychainStore.read()
    if let m = ProcessInfo.processInfo.environment["LAZYBOARD_MODEL"], let model = LLMSuggester.Model(rawValue: m) { llm.model = model }
    llm.backend = ProcessInfo.processInfo.environment["LAZYBOARD_BACKEND"] == "api" ? .api : .claudeCLI
    llm.emojiMode = ProcessInfo.processInfo.environment["LAZYBOARD_EMOJI"] == "1"
    llm.polite = LLMSuggester.Polite(rawValue: ProcessInfo.processInfo.environment["LAZYBOARD_POLITE"] ?? "") ?? .off
    guard llm.isReady else {
        print(llm.backend == .api ? "no API key: set ANTHROPIC_API_KEY or save one from the LazyBoard menu"
                                  : "claude CLI not found (install Claude Code)")
        exit(2)
    }
    llm.debounce = 0
    var done = false
    var lastStart = Date()
    llm.onFinished = { original, reply in
        print(reply.fixed == original ? "no change" : "fix -> \(reply.fixed)")
        for (i, alt) in reply.alternatives.enumerated() { print("alt \(i + 1) -> \(alt)") }
        print(String(format: "  %.1fs", Date().timeIntervalSince(lastStart)))
        done = true
    }
    for text in texts {
        print("> \(text)")
        done = false
        lastStart = Date()
        llm.textChanged(text)
        while !done && Date().timeIntervalSince(lastStart) < 30 {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            if let err = llm.lastError { print("error: \(err)"); llm.shutdown(); exit(1) }
        }
        if !done { print("timeout") }
    }
    print("model \(llm.model.rawValue), backend \(llm.backend.rawValue)")
    llm.shutdown()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
