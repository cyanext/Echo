// 设置「存储」页的数：备份里各类内容各占多少、多少条消息；Claude 会话有几个、占多大；按当前设置能释放多少、会自动删几个。
// 都在后台算：按行粗分类只找关键字不解析，几百 MB 的备份几秒；「能释放多少」要按规则过一遍备份，慢一些，单独算。
import Foundation

enum EchoStorage {
    /// 备份里的内容类别，顺序就是占用条和类型行的顺序
    enum Kind: String, CaseIterable, Identifiable {
        case message = "对话消息", toolUse = "工具调用", toolResult = "工具结果", thinking = "思考过程", system = "系统记录"
        var id: String { rawValue }
    }

    struct Backup {
        var bytes: [Kind: Int64] = [:]
        var messages = 0
        var total: Int64 { bytes.values.reduce(0, +) }
    }

    private static let nAssistant = Array("\"type\":\"assistant\"".utf8), nUser = Array("\"type\":\"user\"".utf8)
    private static let nToolUse = Array("\"type\":\"tool_use\"".utf8), nToolResult = Array("\"tool_result\"".utf8)
    private static let nThinking = Array("\"type\":\"thinking\"".utf8), nThinkingCleaned = Array("[已清理：思考过程".utf8)
    private static let nRedacted = Array("\"type\":\"redacted_thinking\"".utf8), nText = Array("\"type\":\"text\"".utf8)
    private static let nMeta = Array("\"isMeta\":true".utf8), nSummary = Array("\"isCompactSummary\":true".utf8)

    /// 一行算哪一类。回复那一行 message 写在顶层 type 前面，所以直接找 "type":"assistant"、"type":"user"
    /// （内容里的同样字样在字符串里，引号带反斜杠，不会误中）
    static func kind(_ b: UnsafeBufferPointer<UInt8>) -> (Kind, isMessage: Bool) {
        if EchoLines.has(b, nAssistant) {
            if EchoLines.has(b, nToolUse) { return (.toolUse, false) }
            if EchoLines.has(b, nThinking) || EchoLines.has(b, nRedacted) || EchoLines.has(b, nThinkingCleaned) { return (.thinking, false) }
            return (.message, EchoLines.has(b, nText))
        }
        if EchoLines.has(b, nUser) {
            if EchoLines.has(b, nToolResult) { return (.toolResult, false) }
            if EchoLines.has(b, nMeta) || EchoLines.has(b, nSummary) { return (.system, false) }
            return (.message, true)
        }
        return (.system, false)
    }

    /// 一台电脑的备份（备份/<电脑名>/projects）各类占多少。多个文件同时读
    static func backup(_ computerDir: URL) -> Backup {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: computerDir.appendingPathComponent("projects"), includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return Backup() }
        let files = en.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
        let parts = EchoParallel.map(files) { u -> Backup in
            var r = Backup()
            try? EchoLines.each(u) { line in
                let (k, m) = kind(EchoLines.trim(line))
                r.bytes[k, default: 0] += Int64(line.count)
                if m { r.messages += 1 }
            }
            return r
        }
        var r = Backup()
        for x in parts {
            for (k, v) in x.bytes { r.bytes[k, default: 0] += v }
            r.messages += x.messages
        }
        return r
    }

    /// Claude 会话：几个会话（projects/<目录>/<会话>.jsonl，不算子代理的记录）、projects 一共多大
    static func claude(_ source: URL = EchoBackup.source) -> (sessions: Int, bytes: Int64) {
        let fm = FileManager.default
        var sessions = 0, bytes: Int64 = 0
        guard let en = fm.enumerator(at: source, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return (0, 0) }
        for case let u as URL in en {
            guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
            bytes += Int64(v.fileSize ?? 0)
            if u.pathExtension == "jsonl", u.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == source.standardizedFileURL { sessions += 1 }
        }
        return (sessions, bytes)
    }

    /// 设置和首次设置里写的大小：按 1024 进位，最多三位有效数字（26 MB、1.2 GB、130 MB）
    static func size(_ n: Int64) -> String {
        if n < 1024 { return "\(n) B" }
        var v = Double(n)
        for u in ["KB", "MB", "GB", "TB"] {
            v /= 1024
            if v < 1000 || u == "TB" { return v < 10 ? String(format: "%.1f %@", v, u) : String(format: "%.0f %@", v, u) }
        }
        return ""
    }
}
