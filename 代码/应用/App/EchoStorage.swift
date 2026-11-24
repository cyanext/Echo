// 设置「存储」页的数：备份里各类内容各占多少、多少条消息；Claude 会话有几个、占多大；按当前设置能释放多少、会自动删几个。
// 都在后台算：按行粗分类只找关键字不解析，几百 MB 的备份几秒；「能释放多少」要按规则过一遍备份，慢一些，单独算。
import Foundation

enum EchoStorage {
    /// 备份里的内容类别，顺序就是占用条和类型行的顺序
    enum Kind: String, CaseIterable, Identifiable {
        case message = "对话消息", toolUse = "工具调用", toolResult = "工具结果", thinking = "思考过程", system = "系统记录", media = "图片和文件"
        var id: String { rawValue }
    }

    struct Backup {
        var bytes: [Kind: Int64] = [:]
        var messages = 0
        var messagesBy: [EchoSource: Int] = [:]   // 各应用的消息数（来源卡片上写）
        var total: Int64 { bytes.values.reduce(0, +) }
    }

    private static let nAssistant = Array("\"type\":\"assistant\"".utf8), nUser = Array("\"type\":\"user\"".utf8)
    private static let nBase64 = Array(";base64,".utf8), nBase64Key = Array("\"base64\"".utf8)
    private static let nToolUse = Array("\"type\":\"tool_use\"".utf8), nToolResult = Array("\"tool_result\"".utf8)
    private static let nThinking = Array("\"type\":\"thinking\"".utf8), nThinkingCleaned = Array("[已清理：思考过程".utf8)
    private static let nRedacted = Array("\"type\":\"redacted_thinking\"".utf8), nText = Array("\"type\":\"text\"".utf8)
    private static let nMeta = Array("\"isMeta\":true".utf8), nSummary = Array("\"isCompactSummary\":true".utf8)

    private static let cxPairs: [(String, Kind)] = [
        ("\"payload\":{\"type\":\"function_call_output\"", .toolResult), ("\"payload\":{\"type\":\"custom_tool_call_output\"", .toolResult),
        ("\"payload\":{\"type\":\"function_call\"", .toolUse), ("\"payload\":{\"type\":\"custom_tool_call\"", .toolUse),
        ("\"payload\":{\"type\":\"web_search_call\"", .toolUse), ("\"payload\":{\"type\":\"reasoning\"", .thinking),
    ]
    private static let cx: [(needle: [UInt8], kind: Kind)] = cxPairs.map { (Array($0.0.utf8), $0.1) }
    private static let cxMessage = Array("\"payload\":{\"type\":\"message\"".utf8), cxUserOrAsst = ["\"role\":\"user\"", "\"role\":\"assistant\""].map { Array($0.utf8) }

    /// Codex 的一行算哪一类：payload 的 type 写在最前面，按它分；对话消息只算 user、assistant（developer 是系统说明）
    static func codexKind(_ b: UnsafeBufferPointer<UInt8>) -> (Kind, isMessage: Bool) {
        for c in cx where EchoLines.has(b, c.needle) { return (c.kind, false) }
        if EchoLines.has(b, cxMessage), cxUserOrAsst.contains(where: { EchoLines.has(b, $0) }) { return (.message, true) }
        return (.system, false)
    }

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

    /// 一台电脑的备份（各应用的会话目录，见 EchoLayout.sessionRoots）各类占多少。多个文件同时读
    static func backup(_ computerDir: URL) -> Backup {
        let fm = FileManager.default
        let files = EchoLayout.sessionRoots(computerDir).flatMap { r -> [(EchoSource, URL)] in
            (fm.enumerator(at: r.root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)?.allObjects ?? []).compactMap { $0 as? URL }
                .filter { $0.pathExtension == "jsonl" || EchoBackupRule.isMedia($0.lastPathComponent) }.map { (r.source, $0) }
        }
        let parts = EchoParallel.map(files) { (src, u) -> Backup in
            var r = Backup()
            if u.pathExtension != "jsonl" {   // 备份下来的图片、PDF 文件
                r.bytes[.media] = Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                return r
            }
            try? EchoLines.each(u) { line in
                let b = EchoLines.trim(line)
                // 留着图片（base64）的行算「图片和文件」：不备份图片时这类内容已换成占位，不会有
                let (k0, m) = src == .codex ? codexKind(b) : kind(b)
                let k = (EchoLines.has(b, nBase64) || EchoLines.has(b, nBase64Key)) && !m ? Kind.media : k0
                r.bytes[k, default: 0] += Int64(line.count)
                if m { r.messages += 1; r.messagesBy[src, default: 0] += 1 }
            }
            return r
        }
        var r = Backup()
        for x in parts {
            for (k, v) in x.bytes { r.bytes[k, default: 0] += v }
            r.messages += x.messages
            for (k, v) in x.messagesBy { r.messagesBy[k, default: 0] += v }
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

    /// Codex 会话：几个主会话（sessions、archived_sessions 下的 rollout-*，子代理的不算：session_meta 的 source 不是字符串）、一共多大（磁盘上，含 Codex 压过的）
    static func codex(_ source: URL = EchoBackup.codexSource) -> (sessions: Int, bytes: Int64)? {
        let items = EchoBackup.codexItems(source).filter { $0.out.hasPrefix("sessions/") }
        guard !items.isEmpty else { return nil }
        let main = EchoParallel.map(items) { it -> Bool in
            var isMain = false
            struct Stop: Error {}
            do {
                try EchoLines.each(it.url) { line in
                    let d = (try? JSONSerialization.jsonObject(with: Data(buffer: EchoLines.trim(line)))) as? [String: Any]
                    isMain = (d?["payload"] as? [String: Any])?["source"] is String
                    throw Stop()
                }
            } catch {}
            return isMain
        }
        return (main.filter { $0 }.count, items.reduce(0) { $0 + $1.stamp.size })
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
