// 把一个会话 jsonl 整理成浏览页面用的数据（meta + turns）。
// 规则见立项方案（需求文档/归档/方案.md）第七节「消息显示规则」，行为以 代码/原型/export.py 为准，tests/run.sh 拿原型现场生成的结果比对。
import Foundation

enum EchoExport {
    /// 用户消息里由系统注入、不是人打的字，按前缀识别
    static let systemPrefixes = [
        "<system-reminder>", "<command-name>", "<command-message>", "<local-command-stdout>",
        "<local-command-stderr>", "<task-notification>", "<user-prompt-submit-hook>",
        "[Image:", "Caveat:", "[Request interrupted",
    ]

    private static let needles = ["\"type\":\"user\"", "\"type\":\"assistant\"", "\"type\":\"custom-title\"", "\"type\":\"ai-title\"", "\"compact_boundary\""].map { Array($0.utf8) }

    /// 逐条回调可能相关的记录（user、assistant、标题），其余 20 多种类型连解析都省掉
    static func records(_ url: URL, _ body: ([String: Any]) -> Void) throws {
        try EchoLines.each(url) { line in
            let b = EchoLines.trim(line)
            guard needles.contains(where: { EchoLines.has(b, $0) }) else { return }
            guard let d = try? JSONSerialization.jsonObject(with: Data(buffer: b)) as? [String: Any] else { return }
            body(d)
        }
    }

    /// 备份里思考过程的占位「[已清理：思考过程，原 3.4 KB]」，返回原来多大（见 EchoSlim）
    static func thinkingCleaned(_ s: String) -> String? {
        let head = "[\(EchoSlim.cleanedKey)：思考过程，原 "
        guard s.hasPrefix(head), s.hasSuffix("]"), !s.contains("\n") else { return nil }
        return String(s.dropFirst(head.count).dropLast())
    }

    static func textOf(_ content: Any?) -> String {
        if let s = content as? String { return s }
        let parts = (content as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }.map { $0["text"] as? String ?? "" }
        return parts.joined(separator: "\n")
    }

    static func toolResultText(_ block: [String: Any]) -> String {
        if let s = block["content"] as? String { return s }
        var out: [String] = []
        for b in block["content"] as? [[String: Any]] ?? [] {
            if b["type"] as? String == "text" { out.append(b["text"] as? String ?? "") }
            else if b["type"] as? String == "image" { out.append("[图片]") }
        }
        return out.joined(separator: "\n")
    }

    static func commandLabel(_ text: String) -> String? {
        func grab(_ tag: String) -> String? {
            guard let r = text.range(of: "<\(tag)>"), let e = text.range(of: "</\(tag)>", range: r.upperBound..<text.endIndex) else { return nil }
            return String(text[r.upperBound..<e.lowerBound]).trimmed
        }
        guard let name = grab("command-name") else { return nil }
        return (name + " " + (grab("command-args") ?? "")).trimmed
    }

    /// 用户记录显示成什么：nil 表示挂到工具调用下或不显示
    static func userRole(_ d: [String: Any]) -> (role: String, text: String)? {
        let content = (d["message"] as? [String: Any])?["content"]
        if let list = content as? [[String: Any]], list.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
        let text = textOf(content).trimmed
        if text.isEmpty { return nil }
        if truthy(d["isCompactSummary"]) { return ("summary", text) }
        if let cmd = commandLabel(text) { return ("command", cmd) }
        let human = (d["origin"] as? [String: Any])?["kind"] as? String == "human"
        if truthy(d["isMeta"]) || systemPrefixes.contains(where: text.hasPrefix) || (!human && text.hasPrefix("<")) {
            return ("system", text)
        }
        return ("user", text)
    }

    private final class Block {
        var kind: String, text = "", name = "", input: Any = [String: Any](), result: Any = NSNull(), isError = false
        var cleaned: String?   // 备份里清理掉的思考过程：原来多大
        init(kind: String) { self.kind = kind }
        var dict: [String: Any] {
            if kind == "tool" { return ["kind": kind, "name": name, "input": input, "result": result, "isError": isError] }
            if let cleaned { return ["kind": kind, "text": text, "cleaned": cleaned] }
            return ["kind": kind, "text": text]
        }
    }

    private final class Turn {
        let role: String, ts: String
        var text = "", msgId: String?, blocks: [Block] = [], trigger: String?
        init(role: String, ts: String) { self.role = role; self.ts = ts }
        var dict: [String: Any] {
            if role == "assistant" { return ["role": role, "ts": ts, "blocks": blocks.map(\.dict)] }
            if let trigger { return ["role": role, "ts": ts, "text": text, "trigger": trigger] }
            return ["role": role, "ts": ts, "text": text]
        }
    }

    static func export(_ url: URL, computer: String) throws -> [String: Any] {
        if try isCodexFile(url) { return try exportCodex(url, computer: computer) }
        var meta: [String: Any] = ["id": String(url.lastPathComponent.dropLast(6)), "title": "", "aiTitle": "", "cwd": "",
                                   "gitBranch": "", "start": "", "end": "", "computer": computer]
        var turns: [Turn] = []
        var tools: [String: Block] = [:]
        var seen = Set<String>(), seenNil = false   // 已处理的 uuid，去重（和原型一样，没有 uuid 的只留第一条）
        var trigger = ""                            // 上一条压缩记录的触发方式（auto、manual），记到紧跟着的阶段总结上

        try records(url) { d in
            let t = d["type"] as? String
            if t == "system", d["subtype"] as? String == "compact_boundary" {
                trigger = (d["compactMetadata"] as? [String: Any])?["trigger"] as? String ?? ""
                return
            }
            if t == "custom-title" { meta["title"] = d["customTitle"] as? String ?? "" }
            else if t == "ai-title" { meta["aiTitle"] = d["aiTitle"] as? String ?? "" }
            guard t == "user" || t == "assistant" else { return }
            if let uid = d["uuid"] as? String {
                if seen.contains(uid) { return }
                seen.insert(uid)
            } else {
                if seenNil { return }
                seenNil = true
            }
            let ts = d["timestamp"] as? String ?? ""
            if (meta["start"] as! String).isEmpty { meta["start"] = ts }
            if !ts.isEmpty { meta["end"] = ts }
            if (meta["cwd"] as! String).isEmpty { meta["cwd"] = d["cwd"] as? String ?? "" }
            if (meta["gitBranch"] as! String).isEmpty { meta["gitBranch"] = d["gitBranch"] as? String ?? "" }
            let message = d["message"] as? [String: Any] ?? [:]

            if t == "assistant" {
                // 同一条回复会拆成多行写入，按 message.id 合并
                let msgId = message["id"] as? String
                let turn: Turn
                if let last = turns.last, last.role == "assistant", last.msgId == msgId { turn = last }
                else {
                    turn = Turn(role: "assistant", ts: ts)
                    turn.msgId = msgId
                    turns.append(turn)
                }
                for b in message["content"] as? [[String: Any]] ?? [] {
                    switch b["type"] as? String {
                    case "text":
                        guard let s = b["text"] as? String else { break }
                        if let size = thinkingCleaned(s) { let x = Block(kind: "thinking"); x.cleaned = size; turn.blocks.append(x) }
                        else if !s.trimmed.isEmpty { let x = Block(kind: "text"); x.text = s; turn.blocks.append(x) }
                    case "thinking":
                        if let s = b["thinking"] as? String, !s.trimmed.isEmpty { let x = Block(kind: "thinking"); x.text = s; turn.blocks.append(x) }
                    case "tool_use":
                        let x = Block(kind: "tool")
                        x.name = b["name"] as? String ?? ""
                        x.input = b["input"] ?? [String: Any]()
                        if let id = b["id"] as? String { tools[id] = x }
                        turn.blocks.append(x)
                    default: break
                    }
                }
                return
            }

            // user：工具结果挂到对应的工具调用下面
            if let list = message["content"] as? [[String: Any]], list.contains(where: { $0["type"] as? String == "tool_result" }) {
                for b in list where b["type"] as? String == "tool_result" {
                    if let id = b["tool_use_id"] as? String, let x = tools[id] {
                        x.result = toolResultText(b)
                        x.isError = truthy(b["is_error"])
                    }
                }
                return
            }
            guard let (role, text) = userRole(d) else { return }
            let turn = Turn(role: role, ts: ts)
            turn.text = text
            if role == "summary" { turn.trigger = trigger; trigger = "" }
            turns.append(turn)
        }

        turns.removeAll { $0.role == "assistant" && $0.blocks.isEmpty }
        if (meta["title"] as! String).isEmpty {
            let ai = meta["aiTitle"] as! String
            meta["title"] = !ai.isEmpty ? ai : turns.first(where: { $0.role == "user" }).map { $0.text.prefix40 } ?? meta["id"]!
        }
        return ["meta": meta, "turns": turns.map(\.dict)]
    }

    /// 和 Python 的真值判断一致：nil、false、0、空字符串都算假
    static func truthy(_ v: Any?) -> Bool {
        switch v {
        case nil, is NSNull: return false
        case let b as Bool: return b
        case let n as NSNumber: return n.doubleValue != 0
        case let s as String: return !s.isEmpty
        default: return true
        }
    }
}

// MARK: - Codex（规则以原型 export.py 的 export_codex 为准）

extension EchoExport {
    private struct Stop: Error {}

    /// 第一行是 session_meta 的是 Codex 的会话
    static func isCodexFile(_ url: URL) throws -> Bool {
        var codex = false
        do {
            try EchoLines.each(url) { line in
                codex = ((try? JSONSerialization.jsonObject(with: Data(buffer: EchoLines.trim(line)))) as? [String: Any])?["type"] as? String == "session_meta"
                throw Stop()
            }
        } catch is Stop {}
        return codex
    }

    private static let codexSystemPrefixes = ["<", "# AGENTS.md", "Host notice:"]
    private static let codexRequest = try! NSRegularExpression(pattern: #"\n## My request[^\n]*:\n"#)
    private static let cleanedText = try! NSRegularExpression(pattern: #"^\[已清理：(.+)\]$"#)

    /// 「[已清理：工具参数，原 3.4 KB]」里的「工具参数，原 3.4 KB」
    static func cleanedInner(_ s: String) -> String? {
        let ns = s as NSString
        guard let m = cleanedText.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// 从会话文件往上找 session_index.jsonl，取这个会话最后一次的名字
    static func codexTitle(_ url: URL, _ sid: String) -> String {
        var d = url.standardizedFileURL.deletingLastPathComponent()
        for _ in 0..<5 {
            let f = d.appendingPathComponent("session_index.jsonl")
            if FileManager.default.fileExists(atPath: f.path) {
                var name = ""
                try? EchoLines.each(f) { line in
                    guard let o = (try? JSONSerialization.jsonObject(with: Data(buffer: EchoLines.trim(line)))) as? [String: Any],
                          o["id"] as? String == sid, let n = o["thread_name"] as? String, !n.isEmpty else { return }
                    name = n
                }
                return name
            }
            d = d.deletingLastPathComponent()
        }
        return ""
    }

    private static func lstrip(_ s: String) -> Substring { s.drop(while: { $0.isWhitespace }) }

    /// 一条 user 消息拆成（人打的字，系统注入的段落）
    static func codexUserParts(_ p: [String: Any]) -> (human: String, system: String) {
        let kinds = (p["internal_chat_message_metadata_passthrough"] as? [String: Any])?["content_item_kinds"] as? [Any] ?? []
        var human: [String] = [], system: [String] = []
        for (i, c) in (p["content"] as? [Any] ?? []).enumerated() {
            guard let c = c as? [String: Any], c["type"] as? String == "input_text" else { continue }
            var text = c["text"] as? String ?? ""
            let kind = i < kinds.count ? kinds[i] as? String : nil
            let isUser = (kind?.isEmpty == false) ? kind == "user.text" : !codexSystemPrefixes.contains(where: { lstrip(text).hasPrefix($0) })
            if isUser {
                let ns = text as NSString
                if let m = codexRequest.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                    system.append(ns.substring(to: m.range.location).trimmed)
                    text = ns.substring(from: m.range.location + m.range.length)
                }
            }
            if isUser { human.append(text.trimmed) } else { system.append(text.trimmed) }
        }
        return (human.filter { !$0.isEmpty }.joined(separator: "\n"), system.filter { !$0.isEmpty }.joined(separator: "\n\n"))
    }

    /// 工具参数：JSON 字符串解开；清理掉的写成和 Claude 一样的 {已清理: …}
    static func codexInput(_ v: Any?) -> Any {
        if let s = v as? String {
            if let inner = cleanedInner(s) { return ["已清理": inner] }
            if let o = (try? JSONSerialization.jsonObject(with: Data(s.utf8), options: .fragmentsAllowed)) as? [String: Any] { return o }
            return ["input": s]
        }
        if let d = v as? [String: Any] { return d }
        return ["input": v ?? NSNull()]
    }

    static func codexOutput(_ v: Any?) -> String {
        if let s = v as? String { return s }
        var out: [String] = []
        for b in v as? [Any] ?? [] {
            guard let b = b as? [String: Any] else { continue }
            if let t = b["type"] as? String, t == "input_text" || t == "output_text" { out.append(b["text"] as? String ?? "") }
            else if b["type"] as? String == "input_image" { out.append("[图片]") }
        }
        return out.joined(separator: "\n")
    }

    private final class CBlock {
        let kind: String
        var text = "", name = "", input: Any = [String: Any](), result: Any = NSNull(), cleaned: String?
        init(_ kind: String) { self.kind = kind }
        var dict: [String: Any] {
            if kind == "tool" { return ["kind": kind, "name": name, "input": input, "result": result, "isError": false] }
            if let cleaned { return ["kind": kind, "text": text, "cleaned": cleaned] }
            return ["kind": kind, "text": text]
        }
    }

    static func exportCodex(_ url: URL, computer: String) throws -> [String: Any] {
        var meta: [String: Any] = ["id": "", "title": "", "aiTitle": "", "cwd": "", "gitBranch": "", "start": "", "end": "", "computer": computer, "app": "codex"]
        var turns: [(role: String, ts: String, text: String, blocks: [CBlock], trigger: String?)] = []
        var tools: [String: CBlock] = [:]
        var cur: Int?   // 正在拼的这一轮回复在 turns 里的位置
        func reply(_ ts: String) -> Int {
            if let cur { return cur }
            turns.append(("assistant", ts, "", [], nil))
            cur = turns.count - 1
            return cur!
        }
        func str(_ k: String) -> String { meta[k] as? String ?? "" }
        let needles = ["\"type\":\"response_item\"", "\"type\":\"session_meta\"", "\"type\":\"compacted\""].map { Array($0.utf8) }
        try EchoLines.each(url) { line in
            let b = EchoLines.trim(line)
            guard needles.contains(where: { EchoLines.has(b, $0) }),
                  let d = (try? JSONSerialization.jsonObject(with: Data(buffer: b))) as? [String: Any],
                  let p = d["payload"] as? [String: Any] else { return }
            let t = d["type"] as? String, ts = d["timestamp"] as? String ?? ""
            if t == "session_meta" {
                if str("id").isEmpty { meta["id"] = p["id"] as? String ?? "" }
                if str("cwd").isEmpty { meta["cwd"] = p["cwd"] as? String ?? "" }
                if let g = p["git"] as? [String: Any], str("gitBranch").isEmpty { meta["gitBranch"] = g["branch"] as? String ?? "" }
                return
            }
            if t == "compacted" {
                let m = (p["message"] as? String ?? "").trimmed
                if !m.isEmpty { turns.append(("summary", ts, m, [], "auto")); cur = nil }
                return
            }
            guard t == "response_item" else { return }
            let pt = p["type"] as? String
            if pt == "message", p["role"] as? String == "user" {
                let (human, system) = codexUserParts(p)
                if !system.isEmpty { turns.append(("system", ts, system, [], nil)) }
                if !human.isEmpty { turns.append(("user", ts, human, [], nil)) }
                if !human.isEmpty || !system.isEmpty {
                    if str("start").isEmpty { meta["start"] = ts }
                    meta["end"] = ts
                    cur = nil
                }
                return
            }
            switch pt {
            case "message" where p["role"] as? String == "assistant":
                for c in p["content"] as? [Any] ?? [] {
                    guard let c = c as? [String: Any], c["type"] as? String == "output_text", let x = c["text"] as? String, !x.trimmed.isEmpty else { continue }
                    let blk = CBlock("text"); blk.text = x
                    turns[reply(ts)].blocks.append(blk)
                }
                if !ts.isEmpty { meta["end"] = ts }
            case "reasoning":
                if let enc = p["encrypted_content"] as? String, let inner = cleanedInner(enc), inner.hasPrefix("思考过程，原 ") {
                    let blk = CBlock("thinking"); blk.cleaned = String(inner.dropFirst("思考过程，原 ".count))
                    turns[reply(ts)].blocks.append(blk)
                } else {
                    let text = (p["summary"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).map { $0["text"] as? String ?? "" } }.joined(separator: "\n\n")
                    if !text.trimmed.isEmpty { let blk = CBlock("thinking"); blk.text = text; turns[reply(ts)].blocks.append(blk) }
                }
            case "function_call", "custom_tool_call", "web_search_call", "tool_search_call":
                let blk = CBlock("tool")
                if pt == "function_call" { blk.name = p["name"] as? String ?? ""; blk.input = codexInput(p["arguments"]) }
                else if pt == "custom_tool_call" { blk.name = p["name"] as? String ?? ""; blk.input = codexInput(p["input"]) }
                else {
                    blk.name = String(pt!.dropLast(5))
                    let a = p["action"]
                    blk.input = EchoExport.truthy(a) ? a! : [String: Any]()
                }
                if let id = p["call_id"] as? String, !id.isEmpty { tools[id] = blk }
                turns[reply(ts)].blocks.append(blk)
            case "function_call_output", "custom_tool_call_output":
                if let id = p["call_id"] as? String, let blk = tools[id] { blk.result = codexOutput(p["output"]) }
            default: break
            }
        }
        let kept = turns.filter { $0.role != "assistant" || !$0.blocks.isEmpty }
        let sid = str("id")
        let title = codexTitle(url, sid)
        meta["title"] = !title.isEmpty ? title : kept.first(where: { $0.role == "user" }).map { $0.text.prefix40 } ?? sid
        let out: [[String: Any]] = kept.map { x in
            if x.role == "assistant" { return ["role": x.role, "ts": x.ts, "blocks": x.blocks.map(\.dict)] }
            if let tr = x.trigger { return ["role": x.role, "ts": x.ts, "text": x.text, "trigger": tr] }
            return ["role": x.role, "ts": x.ts, "text": x.text]
        }
        return ["meta": meta, "turns": out]
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    /// 前 40 个字符（按 Unicode 码点数，和 Python 的 [:40] 一致）
    var prefix40: String { String(String.UnicodeScalarView(unicodeScalars.prefix(40))) }
}
