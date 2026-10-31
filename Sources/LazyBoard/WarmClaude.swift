import Foundation

/// One long-lived `claude -p --input-format stream-json` process, so each fix skips the CLI
/// start-up cost. Every user message is a new turn in the same conversation, so the process is
/// recycled after a number of turns (and after sitting idle) to keep context small.
final class WarmClaude {
    typealias Completion = (LLMSuggester.Reply?, String?) -> Void

    private var proc: Process?
    private var stdinHandle: FileHandle?
    private var stdoutData = Data()
    private var stderrText = ""
    private var pending: Completion?
    private var turns = 0
    private var runningModel: LLMSuggester.Model?
    private var idleTimer: Timer?
    private var requestStart: Date?

    private let maxTurnsPerProcess = 25
    private let idleTimeout: TimeInterval = 10 * 60
    private let requestTimeout: TimeInterval = 25

    var isBusy: Bool { pending != nil }
    var isRunning: Bool { proc?.isRunning == true }

    // MARK: Lifecycle

    private func start(model: LLMSuggester.Model) -> Bool {
        guard let path = LLMSuggester.claudePath else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = [
            "-p", "--verbose",
            "--model", model == .haiku ? "haiku" : "opus",
            "--effort", "low",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--no-session-persistence", "--strict-mcp-config",
            "--tools", "",
            "--system-prompt", LLMSuggester.systemPrompt,
            "--json-schema", LLMSuggester.jsonSchema,
        ]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lazyboard-cli", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") && !$0.key.hasPrefix("ANTHROPIC") }
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        stdoutData = Data()
        stderrText = ""
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.consume(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(data: handle.availableData, encoding: .utf8) ?? ""
            DispatchQueue.main.async { self?.stderrText += text; if self!.stderrText.count > 4000 { self!.stderrText = String(self!.stderrText.suffix(2000)) } }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.processEnded(proc) }
        }
        do {
            try p.run()
        } catch {
            Log.write("warm claude launch failed: \(error.localizedDescription)")
            return false
        }
        proc = p
        stdinHandle = inPipe.fileHandleForWriting
        runningModel = model
        turns = 0
        Log.write("warm claude started (\(model.rawValue))")
        return true
    }

    func stop() {
        idleTimer?.invalidate()
        idleTimer = nil
        if let p = proc, p.isRunning {
            try? stdinHandle?.close()
            p.terminate()
            Log.write("warm claude stopped")
        }
        proc = nil
        stdinHandle = nil
        if let done = pending {
            pending = nil
            done(nil, "process stopped")
        }
    }

    private func processEnded(_ p: Process) {
        guard p === proc else { return }
        Log.write("warm claude exited (\(p.terminationStatus)) \(stderrText.suffix(200))")
        proc = nil
        stdinHandle = nil
        if let done = pending {
            pending = nil
            done(nil, "claude exited: \(stderrText.suffix(160))")
        }
    }

    private func touchIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleTimeout, repeats: false) { [weak self] _ in
            guard let self = self, !self.isBusy else { return }
            Log.write("warm claude idle, stopping")
            self.stop()
        }
    }

    /// Start the process ahead of the first request so it does not pay the start-up cost.
    func prewarm(model: LLMSuggester.Model) {
        guard proc?.isRunning != true else { return }
        if start(model: model) { touchIdleTimer() }
    }

    // MARK: Requests

    func send(_ text: String, model: LLMSuggester.Model, completion: @escaping Completion) {
        guard pending == nil else { completion(nil, "busy"); return }
        if proc?.isRunning != true || runningModel != model || turns >= maxTurnsPerProcess {
            stop()
            guard start(model: model) else { completion(nil, "ไม่พบคำสั่ง claude ในเครื่อง"); return }
        }
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": text]]
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { completion(nil, "encode"); return }
        data.append(0x0A)
        pending = completion
        requestStart = Date()
        turns += 1
        stdinHandle?.write(data)
        touchIdleTimer()

        let myStart = requestStart
        DispatchQueue.main.asyncAfter(deadline: .now() + requestTimeout) { [weak self] in
            guard let self = self, self.pending != nil, self.requestStart == myStart else { return }
            Log.write("warm claude timeout, restarting")
            self.stop() // fails the pending completion
        }
    }

    private func consume(_ data: Data) {
        stdoutData.append(data)
        while let nl = stdoutData.firstIndex(of: 0x0A) {
            let line = stdoutData.subdata(in: stdoutData.startIndex..<nl)
            stdoutData.removeSubrange(stdoutData.startIndex...nl)
            handle(line: line)
        }
    }

    private func handle(line: Data) {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String else { return }
        guard type == "result" else { return }
        guard let done = pending else { return }
        pending = nil
        if (obj["is_error"] as? Bool) == true {
            let msg = (obj["result"] as? String) ?? "error"
            done(nil, msg)
            return
        }
        if let structured = obj["structured_output"] as? [String: Any], let reply = LLMSuggester.reply(from: structured) {
            done(reply, nil)
            return
        }
        if let result = obj["result"] as? String {
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{"), let o = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any],
               let reply = LLMSuggester.reply(from: o) {
                done(reply, nil)
                return
            }
            if !trimmed.isEmpty { done(LLMSuggester.Reply(fixed: trimmed, alternatives: []), nil); return }
        }
        done(nil, "unreadable result")
    }
}
