import Foundation

/// `LazyBoard --stats` : one block per day, counted from the diagnostic log (which never contains typed text).
enum Stats {
    private static let metrics: [(title: String, match: String)] = [
        ("Enter เข้าตรวจ", "hold enter"),
        ("Ctrl+Enter ข้ามตรวจ", "enter sent: ctrl bypass"),
        ("Enter ยังตรวจอยู่", "enter ignored: still checking"),
        ("ตรวจไม่ทัน", "hold timeout"),
        ("Claude เสนอคำแก้", "llm suggestion"),
        ("กดรับคำแก้ Claude", "applied llm fix"),
        ("ไม่มีอะไรต้องแก้", "hold released: nothing to fix"),
        ("popup ผิดภาษา", "layout suggestion"),
        ("แก้ผิดภาษาเอง", "layout fix (auto)"),
        ("แก้ผิดภาษาด้วย Tab", "layout fix (tab)"),
        ("แก้เองแล้วกด Esc", "auto fix undone"),
        ("แก้เองแล้วลบทันที", "auto fix backspaced right away"),
    ]

    static func run() -> Int32 {
        guard let text = try? String(contentsOf: Log.url, encoding: .utf8) else {
            print("no log at \(Log.url.path)")
            return 1
        }
        var counts: [String: [String: Int]] = [:]
        var latencies: [String: [Double]] = [:]
        for line in text.split(separator: "\n") where line.count > 20 {
            let day = String(line.prefix(10))
            var message = String(line.dropFirst(20))
            if message.hasPrefix("applied layout fix") {
                message = message.hasSuffix(" auto") ? "layout fix (auto)" : "layout fix (tab)"
            }
            if let m = metrics.first(where: { message.hasPrefix($0.match) }) {
                counts[day, default: [:]][m.match, default: 0] += 1
            }
            if let r = message.range(of: #"reply in [0-9.]+s"#, options: .regularExpression),
               let seconds = Double(message[r].dropFirst(9).dropLast()) {
                latencies[day, default: []].append(seconds)
            }
        }
        for day in Set(counts.keys).union(latencies.keys).sorted().suffix(7) {
            print("== \(day) ==")
            for m in metrics { print("  \(m.title): \(counts[day]?[m.match] ?? 0)") }
            if let all = latencies[day]?.sorted(), !all.isEmpty {
                print(String(format: "  Claude ตอบ: กลาง %.1f วิ, ช้าสุด %.1f วิ", all[all.count / 2], all[all.count - 1]))
            }
        }
        return 0
    }
}
