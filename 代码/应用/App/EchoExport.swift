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
        init(kind: String) { self.kind = kind }
        var dict: [String: Any] {
            kind == "tool" ? ["kind": kind, "name": name, "input": input, "result": result, "isError": isError] : ["kind": kind, "text": text]
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
                        if let s = b["text"] as? String, !s.trimmed.isEmpty { let x = Block(kind: "text"); x.text = s; turn.blocks.append(x) }
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

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    /// 前 40 个字符（按 Unicode 码点数，和 Python 的 [:40] 一致）
    var prefix40: String { String(String.UnicodeScalarView(unicodeScalars.prefix(40))) }
}
