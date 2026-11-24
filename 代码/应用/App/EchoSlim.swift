// 瘦身：会话 jsonl 写进备份前怎么改（base64、请求记录、按保留期限换成占位、密钥打码），其余原样保留。
// 规则见 需求文档/版本需求/v0.7.0-会话备份和自动清理.html，行为以 代码/原型/slim.py 为准，tests/run.sh 拿原型现场生成的结果比对。
import Foundation
import CZstd

// MARK: - 按行读文件

/// zstd 流式解压：喂一块压缩数据，每解出一小段（ZSTD_DStreamOutSize，约 128 KB）就交给 sink，不攒成一整块
final class EchoZstd {
    private let ctx: OpaquePointer
    private var out = [UInt8](repeating: 0, count: ZSTD_DStreamOutSize())
    /// 最后一帧解完了（ZSTD_decompressStream 返回 0）；文件读完还没解完说明文件不完整
    private(set) var finished = true

    init() throws {
        guard let c = ZSTD_createDCtx() else { throw CocoaError(.fileReadUnknown) }
        ctx = c
    }
    deinit { ZSTD_freeDCtx(ctx) }

    func decompress(_ data: Data, _ sink: (UnsafeBufferPointer<UInt8>) throws -> Void) throws {
        try data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            var input = ZSTD_inBuffer(src: src.baseAddress, size: src.count, pos: 0)
            while true {
                var full = false
                try out.withUnsafeMutableBytes { dst in
                    var output = ZSTD_outBuffer(dst: dst.baseAddress, size: dst.count, pos: 0)
                    let r = ZSTD_decompressStream(ctx, &output, &input)
                    if ZSTD_isError(r) != 0 {
                        throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "解压出错：" + String(cString: ZSTD_getErrorName(r))])
                    }
                    finished = r == 0
                    full = output.pos == output.size   // 输出满了，解压器里可能还有，接着要
                    try sink(UnsafeBufferPointer(start: dst.baseAddress!.assumingMemoryBound(to: UInt8.self), count: output.pos))
                }
                if input.pos == input.size && !full { break }
            }
        }
    }
}

enum EchoLines {
    /// 逐行回调，行内容含末尾的换行符（最后一行可能没有）。会话文件大到几百 MB，分块读，不整个读进内存。
    /// .zst（Codex 压过的旧会话）边读边解压，调用方不用管
    static func each(_ url: URL, _ body: (UnsafeBufferPointer<UInt8>) throws -> Void) throws {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let zst = url.pathExtension == "zst" ? try EchoZstd() : nil
        var buf = [UInt8]()
        // 新读到的一段接在上次没处理完的半行后面，切出完整的行回调，剩下的半行留着
        func feed(_ chunk: UnsafeBufferPointer<UInt8>) throws {
            buf.append(contentsOf: chunk)
            var start = 0
            try buf.withUnsafeBufferPointer { p in
                let base = p.baseAddress!
                while start < p.count, let nl = memchr(base + start, 0x0A, p.count - start) {
                    let end = base.distance(to: nl.assumingMemoryBound(to: UInt8.self)) + 1
                    try body(UnsafeBufferPointer(rebasing: p[start..<end]))
                    start = end
                }
            }
            buf.removeFirst(start)
        }
        // 每读一块放进 autoreleasepool：读出的 Data 是自动释放的，不包的话整个文件读完才放，大文件能涨到几百 MB
        while try autoreleasepool(invoking: {
            guard let raw = try fh.read(upToCount: zst == nil ? 8 << 20 : 1 << 20), !raw.isEmpty else { return false }
            if let zst { try zst.decompress(raw, feed) }
            else { try raw.withUnsafeBytes { try feed($0.bindMemory(to: UInt8.self)) } }
            return true
        }) {}
        if let zst, !zst.finished { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path, NSLocalizedDescriptionKey: "压缩文件不完整"]) }
        if !buf.isEmpty { try buf.withUnsafeBufferPointer { try body($0) } }
    }

    /// 去掉行尾的换行符
    static func trim(_ line: UnsafeBufferPointer<UInt8>) -> UnsafeBufferPointer<UInt8> {
        var n = line.count
        while n > 0, line[n - 1] == 0x0A || line[n - 1] == 0x0D { n -= 1 }
        return UnsafeBufferPointer(rebasing: line[0..<n])
    }

    static func has(_ line: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        guard let base = line.baseAddress, line.count >= needle.count else { return false }
        return needle.withUnsafeBufferPointer { memmem(base, line.count, $0.baseAddress!, needle.count) != nil }
    }
}

// MARK: - 保留原文的 JSON

/// 键保持原顺序，字符串和数字存原始字节（含引号和转义）。改写一行时，没动的部分逐字节不变。
indirect enum RawJSON {
    case object([(key: [UInt8], value: RawJSON)])
    case array([RawJSON])
    case string([UInt8])
    case scalar([UInt8])

    static func parse(_ b: UnsafeBufferPointer<UInt8>) -> RawJSON? {
        var p = RawParser(b: b)
        guard let v = p.value() else { return nil }
        p.ws()
        return p.i == b.count ? v : nil
    }

    func write(to out: inout [UInt8]) {
        switch self {
        case .string(let s), .scalar(let s): out.append(contentsOf: s)
        case .array(let a):
            out.append(UInt8(ascii: "["))
            for (n, v) in a.enumerated() {
                if n > 0 { out.append(UInt8(ascii: ",")) }
                v.write(to: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let o):
            out.append(UInt8(ascii: "{"))
            for (n, kv) in o.enumerated() {
                if n > 0 { out.append(UInt8(ascii: ",")) }
                out.append(contentsOf: kv.key)
                out.append(UInt8(ascii: ":"))
                kv.value.write(to: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    subscript(key: [UInt8]) -> RawJSON? {
        guard case .object(let o) = self else { return nil }
        return o.last(where: { $0.key == key })?.value   // 键重复时和 Python json.loads 一样取最后一个
    }

    var stringRaw: [UInt8]? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// 带引号的 JSON 字符串原文，只用于不含引号和反斜杠的固定文字
    static func quoted(_ s: String) -> [UInt8] { Array("\"\(s)\"".utf8) }
}

private struct RawParser {
    let b: UnsafeBufferPointer<UInt8>
    var i = 0

    mutating func ws() {
        while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
    }

    mutating func value() -> RawJSON? {
        ws()
        guard i < b.count else { return nil }
        switch b[i] {
        case UInt8(ascii: "{"):
            i += 1
            var items: [(key: [UInt8], value: RawJSON)] = []
            ws()
            if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .object(items) }
            while true {
                ws()
                guard let k = string() else { return nil }
                ws()
                guard i < b.count, b[i] == UInt8(ascii: ":") else { return nil }
                i += 1
                guard let v = value() else { return nil }
                items.append((k, v))
                ws()
                guard i < b.count else { return nil }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "}") { i += 1; return .object(items) }
                return nil
            }
        case UInt8(ascii: "["):
            i += 1
            var items: [RawJSON] = []
            ws()
            if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                guard let v = value() else { return nil }
                items.append(v)
                ws()
                guard i < b.count else { return nil }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                return nil
            }
        case UInt8(ascii: "\""):
            return string().map { .string($0) }
        default:
            let s = i
            while i < b.count {
                let c = b[i]
                if c == UInt8(ascii: ",") || c == UInt8(ascii: "}") || c == UInt8(ascii: "]") || c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 { break }
                i += 1
            }
            return i > s ? .scalar(Array(b[s..<i])) : nil
        }
    }

    mutating func string() -> [UInt8]? {
        guard i < b.count, b[i] == UInt8(ascii: "\"") else { return nil }
        let s = i
        i += 1
        while i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "\\") { i += 2; continue }
            if c == UInt8(ascii: "\"") { i += 1; return Array(b[s..<i]) }
            i += 1
        }
        return nil
    }
}

// MARK: - 瘦身

/// 各类内容在备份里留多久（天）：-1 永久，0 不备份，其余按那一行的时间算。now 是「现在」，测试时给固定值
struct EchoPolicy {
    var toolUse = 30, toolResult = 30, thinking = 0, system = 0
    /// 图片和文件（会话里贴的截图、读的 PDF，Codex 生成的图片，会话目录里的图片和 PDF 文件）：默认 0 不备份，换成占位
    var media = 0
    var now = Date()

    func expired(_ days: Int, _ ts: Date?) -> Bool {
        if days < 0 { return false }
        if days == 0 { return true }
        guard let ts else { return false }
        return now.timeIntervalSince(ts) > Double(days) * 86400
    }

    /// 没到期、留着的内容哪天到期（记进 Stats.nextExpiry）
    func expiry(_ days: Int, _ ts: Date?) -> Double {
        guard days > 0, let ts else { return .infinity }
        return ts.timeIntervalSince1970 + Double(days) * 86400
    }

    /// 期限的写法，清理记录里比对用（期限改了要重新看）
    var key: String { "\(toolUse),\(toolResult),\(thinking),\(system)" + (media == 0 ? "" : ",m\(media)") }   // 不备份图片时和旧版一样，清理记录不用重算
}

/// 一个文件从头处理到尾时要记住的：git 提交、合并命令的调用编号（它的结果也一直留着）
final class EchoSlimState {
    var gitIds = Set<[UInt8]>()
    /// Codex 自动审批的子会话（session_meta 的 source.subagent.other == "guardian"）：用户消息也算系统记录
    var guardian = false
}

enum EchoSlim {
    struct Stats: Equatable {
        var bytesIn = 0, bytesOut = 0, droppedLines = 0, changedLines = 0
        /// 留着的内容里最早什么时候有到期的（秒数）；没有会到期的是无穷大。清理按它跳过还不用看的文件
        var nextExpiry = Double.infinity
    }

    static let cleanedKey = "已清理"
    private static let kType = RawJSON.quoted("type"), kSource = RawJSON.quoted("source"), kData = RawJSON.quoted("data")
    private static let kBase64 = RawJSON.quoted("base64"), kSlimmed = RawJSON.quoted("slimmed"), kText = RawJSON.quoted("text")
    private static let kMessage = RawJSON.quoted("message"), kContent = RawJSON.quoted("content"), kInput = RawJSON.quoted("input")
    private static let kId = RawJSON.quoted("id"), kName = RawJSON.quoted("name"), kToolUseId = RawJSON.quoted("tool_use_id")
    private static let kTimestamp = RawJSON.quoted("timestamp"), kToolUseResult = RawJSON.quoted("toolUseResult")
    private static let kAttachment = RawJSON.quoted("attachment"), kCleaned = RawJSON.quoted(cleanedKey)
    private static let vImage = RawJSON.quoted("image"), vDocument = RawJSON.quoted("document"), vText = RawJSON.quoted("text")
    private static let vThinking = RawJSON.quoted("thinking"), vRedacted = RawJSON.quoted("redacted_thinking")
    private static let vToolUse = RawJSON.quoted("tool_use"), vToolResult = RawJSON.quoted("tool_result"), vBash = RawJSON.quoted("Bash")
    private static let vAssistant = RawJSON.quoted("assistant"), vUser = RawJSON.quoted("user"), vAttachment = RawJSON.quoted("attachment")
    private static let kOrigin = RawJSON.quoted("origin"), kKind = RawJSON.quoted("kind"), vHuman = RawJSON.quoted("human"), vQueued = RawJSON.quoted("queued_command")
    /// 请求记录：请求参数、哈希和对话的重复副本，浏览和恢复都用不到
    static let dropTypes: Set<[UInt8]> = Set(["api-request", "api-request-blob", "api-request-shape"].map(RawJSON.quoted))
    private static let needleRequest = Array("\"api-request".utf8)
    /// 有这些才可能要改，才解析
    private static let needlesParse = ["\"base64\"", "\"thinking\"", "\"redacted_thinking\"", "\"type\":\"attachment\"", "\"tool_use\"", "\"tool_result\""].map { Array($0.utf8) }

    /// 按 1024 进位，不到 100 留一位小数（和原型 size_text 一致）
    static func sizeText(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        var v = Double(n)
        for u in ["KB", "MB", "GB"] {
            v /= 1024
            if v < 1024 || u == "GB" { return v < 100 ? String(format: "%.1f %@", v, u) : String(format: "%.0f %@", v, u) }
        }
        return ""
    }

    static func placeholder(_ kind: String, _ n: Int) -> String { "[\(cleanedKey)：\(kind)，原 \(sizeText(n))]" }

    /// 普通文字写成 JSON 字符串（加引号、转义）
    static func jsonString(_ s: String) -> [UInt8] {
        let d = try! JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])
        return Array(d.dropFirst().dropLast())
    }

    /// JSON 字符串原文解出文字
    static func decode(_ raw: [UInt8]) -> String? {
        (try? JSONSerialization.jsonObject(with: Data(raw), options: .fragmentsAllowed)) as? String
    }

    private static func rawLen(_ v: RawJSON) -> Int {
        var out = [UInt8]()
        v.write(to: &out)
        return out.count
    }

    private static func isCleaned(_ v: RawJSON) -> Bool {
        if let s = v.stringRaw { return s.starts(with: Array("\"[\(cleanedKey)：".utf8)) }
        return v[kCleaned] != nil
    }

    private static func cleanedObject(_ text: String, type: RawJSON? = nil) -> RawJSON {
        var items: [(key: [UInt8], value: RawJSON)] = []
        if let type { items.append((kType, type)) }
        items.append((kCleaned, .string(jsonString(text))))
        return .object(items)
    }

    private static func textBlock(_ text: String) -> RawJSON {
        .object([(kType, .string(vText)), (kText, .string(jsonString(text)))])
    }

    /// 图片、文档块换成占位；名为 base64 的长字符串清空。返回新节点和改没改
    static func stripBase64(_ node: RawJSON) -> (RawJSON, Bool) {
        switch node {
        case .object(let items):
            if let t = node[kType]?.stringRaw, t == vImage || t == vDocument,
               let src = node[kSource], src[kType]?.stringRaw == kBase64 {
                let len = max(0, (src[kData]?.stringRaw?.count ?? 2) - 2)
                return (textBlock(placeholder(t == vImage ? "图片" : "文件", len * 3 / 4)), true)
            }
            var out: [(key: [UInt8], value: RawJSON)] = []
            func set(_ k: [UInt8], _ v: RawJSON) {
                if let n = out.firstIndex(where: { $0.key == k }) { out[n].value = v } else { out.append((k, v)) }
            }
            var changed = false
            for (k, v) in items {
                if k == kBase64, let s = v.stringRaw, s.count - 2 > 1000 {
                    set(k, .string(RawJSON.quoted("")))
                    set(kSlimmed, .scalar(Array("true".utf8)))
                    changed = true
                    continue
                }
                let (nv, c) = stripBase64(v)
                set(k, nv)
                changed = changed || c
            }
            return (.object(out), changed)
        case .array(let a):
            var changed = false
            let out = a.map { v -> RawJSON in
                let (nv, c) = stripBase64(v)
                changed = changed || c
                return nv
            }
            return (.array(out), changed)
        default:
            return (node, false)
        }
    }

    /// 真的 git 提交、合并命令：在开头，或跟在 && || ; 换行后面（和原型 GIT_RE 一致）
    private static let gitRe = try! NSRegularExpression(pattern: #"(?:^|&&|\|\||;|\n)\s*git\b(?:\s+-c\s+\S+)*\s+(?:commit|merge)\b"#)

    private static func keepsGit(_ b: RawJSON) -> Bool {
        guard b[kName]?.stringRaw == vBash, let raw = b[kInput]?[RawJSON.quoted("command")]?.stringRaw, let cmd = decode(raw) else { return false }
        return gitRe.firstMatch(in: cmd, range: NSRange(cmd.startIndex..., in: cmd)) != nil
    }

    /// 按保留期限换思考、工具数据、附件。返回新节点和改没改
    static func applyPolicy(_ obj: RawJSON, _ policy: EchoPolicy, _ state: EchoSlimState, next: inout Double) -> (RawJSON, Bool) {
        guard case .object(var items) = obj, let t = obj[kType]?.stringRaw else { return (obj, false) }
        let ts = obj[kTimestamp]?.stringRaw.flatMap { EchoTime.parse(String(decoding: $0.dropFirst().dropLast(), as: UTF8.self)) }
        func index(_ k: [UInt8]) -> Int? { items.lastIndex(where: { $0.key == k }) }
        var changed = false

        if t == vAssistant || t == vUser, let mi = index(kMessage), case .object(var msg) = items[mi].value,
           let ci = msg.lastIndex(where: { $0.key == kContent }), case .array(var content) = msg[ci].value {
            var hitResult = false
            let resultExpired = t == vUser && policy.expired(policy.toolResult, ts)
            for (n, b) in content.enumerated() {
                guard case .object(var bi) = b, let bt = b[kType]?.stringRaw else { continue }
                if t == vAssistant, bt == vThinking || bt == vRedacted {
                    if policy.expired(policy.thinking, ts) {
                        content[n] = textBlock(placeholder("思考过程", rawLen(b)))
                        changed = true
                    } else { next = min(next, policy.expiry(policy.thinking, ts)) }
                } else if t == vAssistant, bt == vToolUse {
                    if keepsGit(b) { if let id = b[kId]?.stringRaw { state.gitIds.insert(id) } }
                    else if let ii = bi.lastIndex(where: { $0.key == kInput }), !isCleaned(bi[ii].value) {
                        if policy.expired(policy.toolUse, ts) {
                            bi[ii].value = cleanedObject("工具参数，原 \(sizeText(rawLen(bi[ii].value)))")
                            content[n] = .object(bi)
                            changed = true
                        } else { next = min(next, policy.expiry(policy.toolUse, ts)) }
                    }
                } else if t == vUser, bt == vToolResult, !(b[kToolUseId]?.stringRaw.map { state.gitIds.contains($0) } ?? false) {
                    guard resultExpired else {
                        if let c = b[kContent], !isCleaned(c) { next = min(next, policy.expiry(policy.toolResult, ts)) }
                        continue
                    }
                    hitResult = true
                    if let ii = bi.lastIndex(where: { $0.key == kContent }), !isCleaned(bi[ii].value) {
                        bi[ii].value = .string(jsonString(placeholder("工具结果", rawLen(bi[ii].value))))
                        content[n] = .object(bi)
                        changed = true
                    }
                }
            }
            if changed {
                msg[ci].value = .array(content)
                items[mi].value = .object(msg)
            }
            if hitResult, let ri = index(kToolUseResult), !isCleaned(items[ri].value) {
                items[ri].value = .string(jsonString(placeholder("工具结果", rawLen(items[ri].value))))
                changed = true
            }
        } else if t == vAttachment, obj[kAttachment]?[kType]?.stringRaw == vQueued, obj[kAttachment]?[kOrigin]?[kKind]?.stringRaw == vHuman {
            // 你在 AI 干活时插进来的消息：算对话消息，永久保留，不按系统记录清理（和原型 slim.py 的 human_queued 一样）
        } else if t == vAttachment, !policy.expired(policy.system, ts), obj[kAttachment]?[kCleaned] == nil {
            next = min(next, policy.expiry(policy.system, ts))
        } else if t == vAttachment, policy.expired(policy.system, ts), let ai = index(kAttachment),
                  case .object = items[ai].value, items[ai].value[kCleaned] == nil {
            let a = items[ai].value
            items[ai].value = cleanedObject("系统记录，原 \(sizeText(rawLen(a)))", type: a[kType] ?? .scalar(Array("null".utf8)))
            changed = true
        }
        return (changed ? .object(items) : obj, changed)
    }

    // MARK: Codex（规则见原型 slim.py 的 apply_codex，两边逐行比对）

    private static let kPayload = RawJSON.quoted("payload"), kRole = RawJSON.quoted("role"), kCallId = RawJSON.quoted("call_id")
    private static let needlePayload = Array("\"payload\"".utf8)
    private static let codexTypes: Set<[UInt8]> = Set(["session_meta", "response_item", "event_msg", "turn_context", "world_state", "compacted",
                                                        "token_usage_record", "inter_agent_communication_metadata"].map(RawJSON.quoted))
    /// 系统记录：「type|payload.type」→ 换成占位的字段
    private static let codexSystem: [String: [String]] = [
        "session_meta|": ["base_instructions"],
        "turn_context|": ["permission_profile", "file_system_sandbox_policy", "collaboration_mode"],
        "world_state|": ["state"],
        "compacted|": ["replacement_history", "guardian_history", "retained_context", "replacement_history_metadata"],
        "event_msg|item_completed": ["item"],
        "event_msg|thread_settings_applied": ["thread_settings"],
        "response_item|additional_tools": ["tools"],
        "response_item|compaction": ["encrypted_content"],
    ]
    private static let codexGitRe = try! NSRegularExpression(pattern: #"(?:^|&&|\|\||;|\n|\\n|["'`])\s*git\b(?:\s+-c\s+\S+)*\s+(?:commit|merge)\b"#)

    static func isCodex(_ j: RawJSON) -> Bool {
        guard let t = j[kType]?.stringRaw, codexTypes.contains(t), case .object? = j[kPayload] else { return false }
        return true
    }

    /// 和 Python 的真值一致：null、false、0、空字符串、空数组、空对象都算没有
    private static func truthy(_ v: RawJSON?) -> Bool {
        switch v {
        case nil: return false
        case .string(let r)?: return r.count > 2
        case .array(let a)?: return !a.isEmpty
        case .object(let o)?: return !o.isEmpty
        case .scalar(let b)?: let s = String(decoding: b, as: UTF8.self); return !["null", "false", "0", "0.0"].contains(s)
        }
    }

    private static func isNull(_ v: RawJSON?) -> Bool {
        if case .scalar(let b)? = v { return b == Array("null".utf8) }
        return v == nil
    }

    /// 有这个键就换值（位置不变），没有就加在最后（和 Python 字典赋值一样）
    private static func set(_ items: inout [(key: [UInt8], value: RawJSON)], _ k: [UInt8], _ v: RawJSON) {
        if let i = items.lastIndex(where: { $0.key == k }) { items[i].value = v } else { items.append((k, v)) }
    }

    /// data:…;base64, 开头的长字符串换成占位
    static func stripDataURLs(_ node: RawJSON) -> (RawJSON, Bool) {
        switch node {
        case .string(let raw):
            let head = Array("\"data:".utf8), marker = Array(";base64,".utf8)
            guard raw.count - 2 > 1000, raw.starts(with: head) else { return (node, false) }
            let window = Array(raw[1..<min(raw.count - 1, 101)])
            guard let mi = (0...(window.count - marker.count)).first(where: { Array(window[$0..<$0 + marker.count]) == marker }) else { return (node, false) }
            let comma = mi + marker.count - 1   // 逗号在字符串里的位置
            let kind = raw.starts(with: Array("\"data:image/".utf8)) ? "图片" : "文件"
            return (.string(jsonString(placeholder(kind, (raw.count - 2 - comma - 1) * 3 / 4))), true)
        case .object(var items):
            var changed = false
            for i in items.indices {
                let (nv, c) = stripDataURLs(items[i].value)
                if c { items[i].value = nv; changed = true }
            }
            return (changed ? .object(items) : node, changed)
        case .array(var a):
            var changed = false
            for i in a.indices {
                let (nv, c) = stripDataURLs(a[i])
                if c { a[i] = nv; changed = true }
            }
            return (changed ? .array(a) : node, changed)
        default:
            return (node, false)
        }
    }

    /// Codex 的一行按保留期限换思考、工具数据、系统记录。返回新节点和改没改
    static func applyCodex(_ obj: RawJSON, _ policy: EchoPolicy, _ state: EchoSlimState, next: inout Double) -> (RawJSON, Bool) {
        guard case .object(var items) = obj, let pi = items.lastIndex(where: { $0.key == kPayload }), case .object(var p) = items[pi].value,
              let tRaw = obj[kType]?.stringRaw, let t = decode(tRaw) else { return (obj, false) }
        let payload = items[pi].value
        let pt = (t == "event_msg" || t == "response_item") ? payload[kType]?.stringRaw.flatMap(decode) : nil
        let ts = obj[kTimestamp]?.stringRaw.flatMap { EchoTime.parse(String(decoding: $0.dropFirst().dropLast(), as: UTF8.self)) }
        var changed = false
        if t == "session_meta", payload[RawJSON.quoted("source")]?[RawJSON.quoted("subagent")]?[RawJSON.quoted("other")]?.stringRaw == RawJSON.quoted("guardian") {
            state.guardian = true
        }
        var fields = codexSystem[t + "|" + (pt ?? "")] ?? []
        let role = payload[kRole]?.stringRaw.flatMap(decode)
        if t == "response_item", pt == "message", !["user", "assistant"].contains(role ?? "") || (role == "user" && state.guardian) { fields = ["content"] }
        for f in fields {
            let k = RawJSON.quoted(f)
            guard let i = p.lastIndex(where: { $0.key == k }), !isNull(p[i].value), !isCleaned(p[i].value) else { continue }
            if policy.expired(policy.system, ts) {
                p[i].value = .string(jsonString(placeholder("系统记录", rawLen(p[i].value))))
                changed = true
            } else { next = min(next, policy.expiry(policy.system, ts)) }
        }
        if t == "response_item" {
            let cur = RawJSON.object(p)
            switch pt {
            case "reasoning":
                let enc = RawJSON.quoted("encrypted_content")
                let keys = ["summary", "content", "encrypted_content"].map(RawJSON.quoted).filter { truthy(cur[$0]) }
                if !keys.isEmpty, !(cur[enc].map(isCleaned) ?? false) {
                    if policy.expired(policy.thinking, ts) {
                        let n = keys.reduce(0) { $0 + rawLen(cur[$1]!) }
                        for k in keys where k != enc { set(&p, k, .array([])) }
                        set(&p, enc, .string(jsonString(placeholder("思考过程", n))))
                        changed = true
                    } else { next = min(next, policy.expiry(policy.thinking, ts)) }
                }
            case "function_call", "custom_tool_call":
                let k = RawJSON.quoted(pt == "function_call" ? "arguments" : "input")
                let v = cur[k]
                if case .string(let raw)? = v, let str = decode(raw), codexGitRe.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)) != nil {
                    state.gitIds.insert(cur[kCallId]?.stringRaw ?? Array("null".utf8))
                } else if let v, !isNull(v), !isCleaned(v) {
                    if policy.expired(policy.toolUse, ts) {
                        set(&p, k, .string(jsonString(placeholder("工具参数", rawLen(v)))))
                        changed = true
                    } else { next = min(next, policy.expiry(policy.toolUse, ts)) }
                }
            case "function_call_output", "custom_tool_call_output":
                let k = RawJSON.quoted("output")
                if !state.gitIds.contains(cur[kCallId]?.stringRaw ?? Array("null".utf8)), let v = cur[k], !isNull(v), !isCleaned(v) {
                    if policy.expired(policy.toolResult, ts) {
                        set(&p, k, .string(jsonString(placeholder("工具结果", rawLen(v)))))
                        changed = true
                    } else { next = min(next, policy.expiry(policy.toolResult, ts)) }
                }
            case "image_generation_call":
                let k = RawJSON.quoted("result")
                if case .string(let raw)? = cur[k], raw.count - 2 > 1000 {
                    if policy.expired(policy.media, ts) {
                        set(&p, k, .string(jsonString(placeholder("图片", (raw.count - 2) * 3 / 4))))
                        changed = true
                    } else { next = min(next, policy.expiry(policy.media, ts)) }
                }
            default: break
            }
        }
        guard changed else { return (obj, false) }
        items[pi].value = .object(p)
        return (.object(items), true)
    }

    /// 处理一行（含换行符），结果追加到 out
    static func slimLine(_ line: UnsafeBufferPointer<UInt8>, into out: inout [UInt8], stats: inout Stats, policy: EchoPolicy, state: EchoSlimState) {
        stats.bytesIn += line.count
        let body = EchoLines.trim(line)
        if EchoLines.has(body, needleRequest), let j = RawJSON.parse(body), let t = j[kType]?.stringRaw, dropTypes.contains(t) {
            stats.droppedLines += 1
            return
        }
        var bytes: [UInt8]? = nil   // 改写过的这一行（不含换行），nil 表示原样
        let codexJ = EchoLines.has(body, needlePayload) ? RawJSON.parse(body) : nil
        // 图片和文件按这一行的时间看到没到期：到期（默认 0 天，一律）换成占位，没到期原样留着、记下哪天到期
        func media(_ j: RawJSON, _ strip: (RawJSON) -> (RawJSON, Bool)) -> (RawJSON, Bool) {
            let (s, c) = strip(j)
            guard c else { return (j, false) }
            let ts = j[kTimestamp]?.stringRaw.flatMap { EchoTime.parse(String(decoding: $0.dropFirst().dropLast(), as: UTF8.self)) }
            if policy.expired(policy.media, ts) { return (s, true) }
            stats.nextExpiry = min(stats.nextExpiry, policy.expiry(policy.media, ts))
            return (j, false)
        }
        if let j = codexJ, isCodex(j) {
            let (a, c0) = media(j, stripDataURLs)
            let (b, c1) = media(a, stripBase64)
            let (c, c2) = applyCodex(b, policy, state, next: &stats.nextExpiry)
            if c0 || c1 || c2 {
                var o = [UInt8]()
                c.write(to: &o)
                bytes = o
            }
        } else if needlesParse.contains(where: { EchoLines.has(body, $0) }), let j = codexJ ?? RawJSON.parse(body) {
            let (a, c1) = media(j, stripBase64)
            let (b, c2) = applyPolicy(a, policy, state, next: &stats.nextExpiry)
            if c1 || c2 {
                var o = [UInt8]()
                b.write(to: &o)
                bytes = o
            }
        }
        let masked = EchoSecrets.mask(bytes ?? Array(body))
        let before = out.count
        if bytes == nil, masked == nil {
            out.append(contentsOf: line)   // 原样写出，连行尾一起
        } else {
            out.append(contentsOf: masked ?? bytes!)
            out.append(0x0A)
            stats.changedLines += 1
        }
        stats.bytesOut += out.count - before
    }

    /// 瘦身整个文件，写到 dst（调用方负责先写临时文件再改名）；dst 为 nil 时只算不写（估算能释放多少）
    @discardableResult
    static func slimFile(_ src: URL, to dst: URL?, policy: EchoPolicy = EchoPolicy()) throws -> Stats {
        var fout: FileHandle?
        if let dst {
            guard FileManager.default.createFile(atPath: dst.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: dst.path])
            }
            fout = try FileHandle(forWritingTo: dst)
        }
        defer { try? fout?.close() }
        var stats = Stats()
        let state = EchoSlimState()
        var out = [UInt8]()
        out.reserveCapacity(9 << 20)
        try EchoLines.each(src) { line in
            slimLine(line, into: &out, stats: &stats, policy: policy, state: state)
            if out.count >= 8 << 20 {
                try fout?.write(contentsOf: out)
                out.removeAll(keepingCapacity: true)
            }
        }
        try fout?.write(contentsOf: out)
        try fout?.synchronize()
        return stats
    }
}

// MARK: - 密钥打码

/// 留前 4 位和后 4 位，中间换成 8 个「•」；不到 12 位的只留前 2 位；私钥只留首尾两行标记。规则和原型 mask_secrets 一致。
/// 几乎每行都有 token（用量里的 output_tokens），所以「password=…」这类赋值在字节上逐个找关键字（等价于原型的 ASSIGN 正则），
/// Bearer、sk- 这些少见的先在字节里找到再跑正则；没有可疑内容的行不转字符串
enum EchoSecrets {
    static let dots = String(repeating: "•", count: 8)
    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    private static let privateKey = re(#"(-----BEGIN [A-Z ]*PRIVATE KEY-----)(.{40,}?)(-----END [A-Z ]*PRIVATE KEY-----)"#)
    private static let bearer = re(#"(Bearer\s+)([A-Za-z0-9._~+/=-]{16,})"#)
    private static let prefixed = re(#"()(?<![A-Za-z0-9])(sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|AKIA[0-9A-Z]{16})"#)
    private static let rareNeedles = ["Bearer", "sk-", "hp_", "ho_", "hu_", "hs_", "hr_", "github_pat_", "AKIA", "PRIVATE KEY"].map { Array($0.utf8) }
    /// 赋值的关键字（小写），顺序同原型正则里的分支
    private static let keys = ["password", "passwd", "secret", "token", "api_key", "apikey", "access_key", "accesskey"].map { Array($0.utf8) }
    private static let keyFirst = Set(keys.map { $0[0] })
    private static let exampleWords = ["xxx", "your", "example", "placeholder", "dummy", "changeme", "test", "redacted", "***"]

    static func maskValue(_ v: String) -> String {
        let u = Array(v.unicodeScalars)
        func s(_ x: ArraySlice<Unicode.Scalar>) -> String { String(String.UnicodeScalarView(x)) }
        return u.count >= 12 ? s(u.prefix(4)) + dots + s(u.suffix(4)) : s(u.prefix(2)) + dots
    }

    static func looksReal(_ v: String) -> Bool {
        let low = v.lowercased()
        if exampleWords.contains(where: low.contains) || v.contains(where: { "${}•".contains($0) }) { return false }
        return v.unicodeScalars.contains(where: { ("a"..."z").contains($0) || ("A"..."Z").contains($0) })
            && v.unicodeScalars.contains(where: { ("0"..."9").contains($0) })
    }

    private static func sub(_ s: String, _ r: NSRegularExpression, _ f: (NSTextCheckingResult, NSString) -> String) -> String {
        let ns = s as NSString
        var out = s as NSString
        for m in r.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            out = out.replacingCharacters(in: m.range, with: f(m, ns)) as NSString
        }
        return out as String
    }

    /// 从 i 起解一个 Unicode 字符，返回字符和占几个字节；坏字节当一个字节
    private static func scalar(_ b: [UInt8], _ i: Int) -> (Unicode.Scalar?, Int) {
        if b[i] < 0x80 { return (Unicode.Scalar(b[i]), 1) }
        var it = b[i...].makeIterator()
        var d = UTF8()
        if case .scalarValue(let u) = d.decode(&it) { return (u, UTF8.width(u)) }
        return (nil, 1)
    }

    /// 和 Python 的 \s 一样：ASCII 空白和 Unicode 空白
    private static func isSpace(_ u: Unicode.Scalar?) -> Bool {
        guard let u else { return false }
        return u.properties.isWhitespace || (0x1C...0x1F).contains(u.value)
    }

    /// 等价于原型的 ASSIGN：关键字 \\?["']? \s* [:=] \s* \\?["']? 值（不含 "'\ 空白 ,;&<>，至少 8 个字符）
    private static func assign(_ b: [UInt8]) -> [UInt8]? {
        let n = b.count
        var out: [UInt8] = [], last = 0, i = 0, changed = false
        // 先在小写副本里用 memmem 找出所有关键字的位置，按位置排好；同一位置取原型正则里靠前的分支
        let low = b.map { (65...90).contains($0) ? $0 + 32 : $0 }
        var hits: [(pos: Int, len: Int)] = []
        low.withUnsafeBufferPointer { lp in
            guard let base = lp.baseAddress else { return }
            for (order, k) in keys.enumerated() {
                var from = 0
                while from < n, let p = k.withUnsafeBufferPointer({ memmem(base + from, n - from, $0.baseAddress!, k.count) }) {
                    let pos = base.distance(to: p.assumingMemoryBound(to: UInt8.self))
                    hits.append((pos * 16 + order, k.count))
                    from = pos + 1
                }
            }
        }
        guard !hits.isEmpty else { return nil }
        hits.sort { $0.pos < $1.pos }
        for h in hits {
            let start = h.pos / 16
            guard start >= i else { continue }
            i = start
            let k = keys[h.pos % 16]
            var j = i + k.count
            if j < n, b[j] == 0x5C { j += 1 }
            if j < n, b[j] == 0x22 || b[j] == 0x27 { j += 1 }
            while j < n { let (u, w) = scalar(b, j); if isSpace(u) { j += w } else { break } }
            guard j < n, b[j] == 0x3A || b[j] == 0x3D else { continue }
            j += 1
            while j < n { let (u, w) = scalar(b, j); if isSpace(u) { j += w } else { break } }
            if j < n, b[j] == 0x5C { j += 1 }
            if j < n, b[j] == 0x22 || b[j] == 0x27 { j += 1 }
            var e = j, count = 0
            while e < n {
                let c = b[e]
                if c == 0x22 || c == 0x27 || c == 0x5C || c == 0x2C || c == 0x3B || c == 0x26 || c == 0x3C || c == 0x3E { break }
                let (u, w) = scalar(b, e)
                if isSpace(u) { break }
                e += w; count += 1
            }
            guard count >= 8 else { continue }
            let v = String(decoding: b[j..<e], as: UTF8.self)
            if looksReal(v) {
                out.append(contentsOf: b[last..<j])
                out.append(contentsOf: Array(maskValue(v).utf8))
                last = e
                changed = true
            }
            i = e
        }
        guard changed else { return nil }
        out.append(contentsOf: b[last...])
        return out
    }

    /// 有密钥就返回打码后的一行，没有返回 nil
    static func mask(_ line: [UInt8]) -> [UInt8]? {
        var b = line, changed = false
        if rareNeedles.contains(where: { nd in line.withUnsafeBufferPointer { EchoLines.has($0, nd) } }) {
            let s0 = String(decoding: line, as: UTF8.self)
            var s = sub(s0, privateKey) { m, ns in ns.substring(with: m.range(at: 1)) + dots + ns.substring(with: m.range(at: 3)) }
            s = sub(s, bearer) { m, ns in ns.substring(with: m.range(at: 1)) + maskValue(ns.substring(with: m.range(at: 2))) }
            s = sub(s, prefixed) { m, ns in maskValue(ns.substring(with: m.range(at: 2))) }
            if s != s0 { b = Array(s.utf8); changed = true }
        }
        if let a = assign(b) { b = a; changed = true }
        return changed ? b : nil
    }
}
