// 命令行工具 ech（需求 需求文档/版本需求/v0.9.0-ech命令和skill.html）：和应用同一个程序，用 ech 这个名字调用时走这里，不开窗口。
// 查询命令只读备份、本机索引和总览数据；backup 和回响的「立即备份」同一套；mv 和左栏目录右键「改名」同一套。输出纯文本，给各家 AI 读，--json 给脚本用。
import Foundation

enum EchoCLI {
    /// 用 ech 这个名字调用（~/.local/bin/ech 指向应用里的程序）
    static var isCLI: Bool { (CommandLine.arguments.first.map { ($0 as NSString).lastPathComponent } ?? "") == "ech" }

    /// 一次输出最多多少字，超出分页
    static let pageChars = 8000

    struct Args {
        var cmd = ""
        var pos: [String] = []
        var opt: [String: String] = [:]
        var flags = Set<String>()
        init(_ a: [String]) {
            var i = 0
            while i < a.count {
                let x = a[i]
                if x.hasPrefix("--") {
                    let k = String(x.dropFirst(2))
                    if let eq = k.firstIndex(of: "=") { opt[String(k[..<eq])] = String(k[k.index(after: eq)...]) }
                    else if ["json", "tools", "dry-run", "help"].contains(k) { flags.insert(k) }
                    else if i + 1 < a.count { opt[k] = a[i + 1]; i += 1 }
                } else if x == "-h" { flags.insert("help") }
                else if cmd.isEmpty { cmd = x } else { pos.append(x) }
                i += 1
            }
        }
        var page: Int { max(1, Int(opt["page"] ?? "1") ?? 1) }
    }

    struct Fail: Error { let text: String }

    /// 返回退出码；输出写到标准输出，出错写到标准错误
    static func main(_ argv: [String]) -> Int32 {
        let a = Args(argv)
        // 设置里的备份位置是一台电脑的备份文件夹（应用还没启动改过来）：这次按上一级读，设置不动
        let stored = EchoPrefs.backupRoot.standardizedFileURL, fixed = EchoLayout.sharedRoot(stored)
        if fixed.path != stored.path { EchoPrefs.runRoot = fixed }
        do {
            var out: String
            switch a.cmd {
            case "", "help": out = help
            case "version", "-v": out = "ech \(appVersion ?? "开发版")"
            case "find": out = try find(a)
            case "list": out = try list(a)
            case "segs": out = try segs(a)
            case "read": out = try read(a)
            case "context": out = try context(a)
            case "resume": out = try resume(a)
            case "mv": out = try mv(a)
            case "backup": out = try backup(a)
            case "index": out = try index()
            case "schema": out = try schema(a)
            case "install-skill": out = try installSkill()
            default: throw Fail(text: "没有「\(a.cmd)」这个命令，运行 ech help 查看用法")
            }
            if a.flags.contains("help") { out = help }
            if !a.flags.contains("json"), let n = skillNotice() { out += "\n\n" + n }
            print(out)
            return 0
        } catch let e as Fail {
            FileHandle.standardError.write((e.text + "\n").data(using: .utf8)!)
            return 1
        } catch {
            FileHandle.standardError.write((error.localizedDescription + "\n").data(using: .utf8)!)
            return 1
        }
    }

    static let help = """
    ech：查回响备份里的会话（只读），和备份
      ech find <关键词> [--app claude|codex] [--since 日期] [--project 词] [--limit 20] [--tools]   按关键词找会话和段（默认只找对话，--tools 连工具调用一起找）
      ech list [--since 日期] [--until 日期] [--project 词] [--app 名]                  按时间列会话、消息、Token、提交（默认最近 7 天）
      ech segs <会话>                                列一个会话的分段（每段一个引用，如 ce57ce36#3）
      ech read <引用> [--tools]                       把一段读成对话文字：ce57ce36#3 第 3 段，ce57ce36#L1200-1500 这几行，只写会话读最后一段
      ech context <会话> [--tools]                    续上一个会话：最近一次压缩的阶段总结和之后的对话
      ech resume <会话>                              恢复命令：在终端或 MintPop 主页里打开原会话接着聊
      ech mv <旧路径> <新路径> [--dry-run]              改名或移动文件夹，本机的会话（Claude Code、Codex）随之移动；旧路径已不存在时，或是指向新路径的软链时，只移动会话
      ech backup                                     备份并更新索引（和回响的「立即备份」一样）
      ech index                                      只更新索引和总览数据，不备份
      ech schema [命令]                              各命令的参数（JSON）
      ech install-skill                              装 ech skill：~/.claude/skills/ech，有 Codex 时也装到 ~/.codex/skills/ech
    日期写 2026-11-16、2026/11/16、11-16（今年），或 7d（最近 7 天，含今天），按北京时间、含两头。
    <会话> 写会话 ID（前 8 位就够）或备份文件路径；find、segs、list 的每一条都带引用，复制给 read 就行。输出超过 \(pageChars) 字时分页，加 --page 2 看下一页；加 --json 输出 JSON。
    """

    // MARK: 公共

    /// 应用的包：ech 是指向应用里程序的替身，顺着找回去
    static var appBundle: URL? {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }

    static var appVersion: String? {
        guard let app = appBundle, let d = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return d["CFBundleShortVersionString"] as? String
    }

    static func openIndex() throws -> EchoDB {
        guard FileManager.default.fileExists(atPath: EchoIndex.url.path) else {
            throw Fail(text: "还没有索引：先运行 ech backup（或打开回响备份一次）")
        }
        return try EchoIndex.open(readonly: true)
    }

    /// 11-22 14:03（北京时间）
    static func hm(_ ts: String) -> String {
        guard let t = EchoTime.fastEpoch(ts) else { return "" }
        return bj(Date(timeIntervalSince1970: t), "MM-dd HH:mm")
    }

    static func bj(_ d: Date, _ fmt: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN"); f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = fmt
        return f.string(from: d)
    }

    static func indexHead(_ db: EchoDB) -> String {
        EchoIndex.updated(db).map { "索引更新于 " + bj($0, "M月d日 HH:mm") } ?? "索引还没建好"
    }

    /// 超过一页的切开：按行切，最后一行写还剩多少、下一页怎么看
    static func paged(_ text: String, _ a: Args, _ again: String) -> String {
        var pages: [String] = [], cur = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if cur.count + line.count + 1 > pageChars, !cur.isEmpty { pages.append(cur); cur = "" }
            cur += (cur.isEmpty ? "" : "\n") + line
        }
        pages.append(cur)
        let p = min(a.page, pages.count)
        var out = pages[p - 1]
        if p < pages.count {
            let rest = pages[p...].reduce(0) { $0 + $1.count }
            out += "\n\n（第 \(p)/\(pages.count) 页，还有 \(rest) 字：\(again) --page \(p + 1)）"
        }
        return out
    }

    static func json(_ v: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    static func shell(_ args: [String]) -> String {
        args.map { $0.contains(where: { " \"'".contains($0) }) ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }

    /// 截一句：命中处前后各留一些字，换行换成空格
    static func snippet(_ text: String, around q: String, width: Int = 60) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let r = flat.range(of: q, options: .caseInsensitive) else { return String(flat.prefix(width * 2)) }
        let s = flat.index(r.lowerBound, offsetBy: -width, limitedBy: flat.startIndex) ?? flat.startIndex
        let e = flat.index(r.upperBound, offsetBy: width, limitedBy: flat.endIndex) ?? flat.endIndex
        return (s > flat.startIndex ? "…" : "") + flat[s..<e] + (e < flat.endIndex ? "…" : "")
    }

    // MARK: 日期参数

    /// --since、--until → 北京时间的日期范围（含两头）。日期写 2026-11-16、2026/11/16、11-16（今年），
    /// 相对时间写 7d（最近 7 天，含今天）；不写 --since 时是最近 7 天，不写 --until 时到今天
    static func dayRange(_ since: String?, _ until: String?) throws -> (String, String) {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let today = cal.startOfDay(for: Date())
        func key(_ d: Date) -> String { bj(d, "yyyy-MM-dd") }
        func day(_ s: String, _ name: String) throws -> Date {
            if s.hasSuffix("d"), let n = Int(s.dropLast()), n > 0 { return cal.date(byAdding: .day, value: 1 - n, to: today)! }
            if let d = parseDay(s, cal) { return d }
            throw Fail(text: "\(name) 看不懂「\(s)」：写 2026-11-16、2026/11/16、11-16，或 7d（最近 7 天）")
        }
        let from = try since.map { try day($0, "--since") } ?? cal.date(byAdding: .day, value: -6, to: today)!
        let to = try until.map { try day($0, "--until") } ?? today
        guard from <= to else { throw Fail(text: "--since 晚于 --until") }
        return (key(from), key(to))
    }

    /// 2026-11-16、2026/11/16、20261116、11-16（今年）
    static func parseDay(_ s: String, _ cal: Calendar) -> Date? {
        var p = s.split(whereSeparator: { $0 == "-" || $0 == "/" || $0 == "." }).compactMap { Int($0) }
        if p.count == 1, s.count == 8, let n = Int(s) { p = [n / 10000, n / 100 % 100, n % 100] }
        if p.count == 2 { p.insert(cal.component(.year, from: Date()), at: 0) }
        guard p.count == 3, (1...12).contains(p[1]), (1...31).contains(p[2]) else { return nil }
        return cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    // MARK: find

    static func find(_ a: Args) throws -> String {
        let q = a.pos.joined(separator: " ").trimmed
        guard !q.isEmpty else { throw Fail(text: "用法：ech find <关键词>") }
        let db = try openIndex()
        let limit = Int(a.opt["limit"] ?? "20") ?? 20
        let since = try a.opt["since"].map { try dayRange($0, nil).0 }
        // 默认只找对话（我说的、回顾、阶段总结、AI 回的）；--tools 连工具调用和命令一起找
        let hits = try EchoIndex.search(db, q, limit: limit, app: a.opt["app"], project: a.opt["project"], since: since,
                                        roles: a.flags.contains("tools") ? nil : ["我", "回顾", "总结", "AI"])
        let anchor = EchoIndex.anchor(q)
        typealias Hit = EchoIndex.Hit
        let segQ = try db.prepare("SELECT n, vers FROM segs WHERE fid=? AND l0<=? ORDER BY n DESC LIMIT 1")
        let near = try db.prepare("SELECT role, text FROM lines WHERE fid=? AND line<? ORDER BY line DESC LIMIT 1")
        let after = try db.prepare("SELECT role, text FROM lines WHERE fid=? AND line>? ORDER BY line LIMIT 1")
        func seg(_ h: Hit) throws -> (Int, String) {
            try segQ.bind([h.fid, h.line]); return try segQ.step() ? (segQ.int(0), segQ.text(1)) : (1, "")
        }
        func around(_ st: EchoStmt, _ h: Hit) throws -> String? {
            try st.bind([h.fid, h.line]); return try st.step() ? "\(st.text(0))：" + snippet(st.text(1), around: "", width: 30) : nil
        }
        if a.flags.contains("json") {
            return json(try hits.map { h -> [String: Any] in
                let (n, v) = try seg(h)
                return ["ref": "\(short(h.sid))#\(n)", "session": h.sid, "title": h.title, "computer": h.computer, "app": h.app, "seg": n, "versions": v, "line": h.line, "role": h.role, "ts": h.ts, "text": snippet(h.text, around: anchor)]
            })
        }
        guard !hits.isEmpty else { return indexHead(db) + "\n没有找到「\(q)」。今天刚聊的内容要先运行 ech backup。" }
        var out = [indexHead(db) + "，找到 \(hits.count) 处" + (hits.count == limit ? "（只列最近 \(limit) 处，加 --limit 看更多）" : "")]
        var order: [Int] = [], groups: [Int: [Hit]] = [:]
        for h in hits { if groups[h.fid] == nil { order.append(h.fid) }; groups[h.fid, default: []].append(h) }
        for fid in order {
            let g = groups[fid]!, f = g[0]
            out.append("\n■ \(f.title) · \(f.computer) · \(f.app == "codex" ? "Codex" : "Claude Code") · \(short(f.sid))")
            for h in g {
                let (n, v) = try seg(h)
                out.append("  \(short(h.sid))#\(n)\(v.isEmpty ? "" : "（\(v)）") \(hm(h.ts)) 第 \(h.line) 行")
                if let b = try around(near, h) { out.append("    · " + b) }
                out.append("    ▶ \(h.role)：" + snippet(h.text, around: anchor))
                if let b = try around(after, h) { out.append("    · " + b) }
            }
        }
        out.append("\n读某一段：ech read <会话>#<段号>，比如 ech read \(short(hits[0].sid))#\(try seg(hits[0]).0)")
        return paged(out.joined(separator: "\n"), a, shell(["ech", "find"] + a.pos))
    }

    // MARK: 会话

    /// 引用：「会话 ID 前 8 位」「会话#段号」「会话#L起-止」，会话也可以写备份文件路径。拆成会话和后半截
    static func splitRef(_ ref: String) -> (String, String?) {
        guard let i = ref.lastIndex(of: "#") else { return (ref, nil) }
        return (String(ref[..<i]), String(ref[ref.index(after: i)...]))
    }

    /// 会话 ID 前缀或备份文件路径 → 索引里的文件
    static func resolve(_ db: EchoDB, _ key: String) throws -> (fid: Int, path: String, title: String, sid: String, computer: String) {
        var found: [(Int, String, String, String, String)] = []
        var k = splitRef(key).0, computer: String?
        // 会话@电脑名：同一个会话在两台电脑上分叉了，指定用哪台的（一份包含另一份时扫列表已只留一份，见 EchoMerge）
        if !k.hasPrefix("/"), !k.hasPrefix("~"), let at = k.lastIndex(of: "@") { computer = String(k[k.index(after: at)...]); k = String(k[..<at]) }
        try db.rows("SELECT id, path, title, sid, computer FROM files WHERE sid LIKE ? OR path = ? LIMIT 10", [k + "%", (k as NSString).expandingTildeInPath]) {
            found.append(($0.int(0), $0.text(1), $0.text(2), $0.text(3), $0.text(4)))
        }
        if let computer { found = found.filter { $0.4 == computer } }
        if found.isEmpty { throw Fail(text: "没找到会话「\(key)」：写会话 ID（前 8 位就够）或备份文件路径；今天新开的会话要先 ech backup") }
        if found.count > 1, Set(found.map(\.3)).count == 1 {
            throw Fail(text: "「\(key)」在几台电脑上各有新内容（分叉了），写成 会话@电脑名：\n" + found.map { "  \(short($0.3))@\($0.4)  \($0.2)" }.joined(separator: "\n"))
        }
        if found.count > 1 { throw Fail(text: "「\(key)」对上了几个会话，写长一点：\n" + found.map { "  \($0.3)  \($0.2)" }.joined(separator: "\n")) }
        return found[0]
    }

    static func segs(_ a: Args) throws -> String {
        guard let key = a.pos.first else { throw Fail(text: "用法：ech segs <会话>") }
        let db = try openIndex()
        let f = try resolve(db, key)
        var list: [[String: Any]] = []
        try db.rows("SELECT n, l0, l1, t0, t1, vers, head, kind FROM segs WHERE fid=? ORDER BY n", [f.fid]) { s in
            list.append(["n": s.int(0), "l0": s.int(1), "l1": s.int(2), "t0": s.text(3), "t1": s.text(4), "versions": s.text(5), "head": s.text(6), "kind": s.text(7)])
        }
        if a.flags.contains("json") { return json(["session": f.sid, "title": f.title, "segs": list]) }
        var out = ["\(f.title) · \(f.computer) · \(short(f.sid))，\(list.count) 段（\(indexHead(db))）"]
        for s in list {
            let v = s["versions"] as! String
            out.append("  \(short(f.sid))#\(s["n"]!)  第 \(s["l0"]!)–\(s["l1"]!) 行  \(hm(s["t0"] as! String)) 至 \(hm(s["t1"] as! String))  \(s["kind"]!)\(v.isEmpty ? "" : "  版本 " + v)")
            if let h = s["head"] as? String, !h.isEmpty { out.append("    " + h) }
        }
        out.append("\n读某一段：ech read \(short(f.sid))#<段号>")
        return paged(out.joined(separator: "\n"), a, shell(["ech", "segs", key]))
    }

    // MARK: resume

    /// 恢复命令：和回响右键「复制恢复命令」一样。原会话在另一台电脑上、或本机已被清理时说清楚，提示先在回响里「同步到本机」
    static func resume(_ a: Args) throws -> String {
        guard let key = a.pos.first else { throw Fail(text: "用法：ech resume <会话>") }
        let db = try openIndex()
        let f = try resolve(db, key)
        var app = EchoSource.claude, cwd = ""
        try db.rows("SELECT app, cwd FROM files WHERE id=?", [f.fid]) { app = EchoSource(rawValue: $0.text(0)) ?? .claude; cwd = $0.text(1) }
        let cmd = EchoResume.command(app, cwd: cwd, id: f.sid)
        let local = f.computer == EchoPrefs.computerName
        let gone = local && app == .claude && EchoRestore.existing(f.sid) == nil
        let note = !local ? "这个会话在 \(f.computer) 上：在那台电脑上运行，或在回响左栏右键这个会话「同步到本机…」"
            : gone ? "原会话已被清理，本机只剩回响的备份：先在回响左栏右键这个会话「同步到本机…」" : ""
        if a.flags.contains("json") { return json(["session": f.sid, "title": f.title, "computer": f.computer, "cwd": cwd, "command": cmd, "ready": note.isEmpty, "note": note]) }
        return ["\(f.title) · \(f.computer) · \(short(f.sid))", cmd, note].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: read

    static func read(_ a: Args) throws -> String {
        guard let key = a.pos.first else { throw Fail(text: "用法：ech read <会话>[#段号 | #L起-止]") }
        let db = try openIndex()
        let f = try resolve(db, key)
        var lo = 0, hi = Int.max, label = ""
        // 段号、行号可以写在引用里（ce57ce36#21、ce57ce36#L1200-1500），也可以写成第二个参数
        var which = splitRef(key).1 ?? (a.pos.count > 1 ? a.pos[1] : nil)
        if let w = which, w.hasPrefix("L") { which = String(w.dropFirst()) }
        if let w = which, w.contains("-") {
            let p = w.split(separator: "-").compactMap { Int($0) }
            guard p.count == 2 else { throw Fail(text: "行号写成 起-止，比如 1200-1500") }
            (lo, hi, label) = (p[0], p[1], "第 \(p[0])–\(p[1]) 行")
        } else {
            let st = try db.prepare(which == nil ? "SELECT n, l0, l1 FROM segs WHERE fid=? ORDER BY n DESC LIMIT 1" : "SELECT n, l0, l1 FROM segs WHERE fid=? AND n=?")
            try st.bind(which == nil ? [f.fid] : [f.fid, Int(which!) ?? -1])
            guard try st.step() else { throw Fail(text: "没有第 \(which ?? "") 段：ech segs \(short(f.sid)) 看有几段") }
            lo = st.int(1)
            label = "第 \(st.int(0)) 段"
            // 段的终点延到下一段开始前，段尾的工具输出、回复都带上
            let nx = try db.prepare("SELECT l0 FROM segs WHERE fid=? AND n=?")
            try nx.bind([f.fid, st.int(0) + 1])
            hi = try nx.step() ? nx.int(0) - 1 : Int.max
        }
        return try render(f, lo, hi, label, a, again: ["ech", "read"] + a.pos)
    }

    /// 续上一个会话：最近一次压缩的阶段总结和之后的全部对话，和 Claude Code 续这个会话时读进去的一样；没压缩过的从头读
    static func context(_ a: Args) throws -> String {
        guard let key = a.pos.first else { throw Fail(text: "用法：ech context <会话>") }
        let db = try openIndex()
        let f = try resolve(db, key)
        var lo = 0, label = "从头"
        try db.rows("SELECT n, l0 FROM segs WHERE fid=? AND kind='压缩' ORDER BY n DESC LIMIT 1", [f.fid]) { lo = $0.int(1); label = "第 \($0.int(0)) 段起（最近一次压缩之后）" }
        // 先给最近一条回顾：Claude 写的做到哪、下一步，最快接上
        var recap = ""
        try db.rows("SELECT ts, text FROM lines WHERE fid=? AND role='回顾' ORDER BY line DESC LIMIT 1", [f.fid]) { recap = "最近一次回顾（\(hm($0.text(0)))）：" + $0.text(1) }
        let body = try render(f, lo, Int.max, label, a, again: ["ech", "context"] + a.pos)
        if recap.isEmpty || a.flags.contains("json") || a.page > 1 { return body }
        let lines = body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        return lines[0] + "\n" + recap + "\n" + (lines.count > 1 ? lines[1] : "")
    }

    /// 把会话文件里 lo 到 hi 行的对话写成文字：我的消息、回复、阶段总结，工具调用一行概述（--tools 带输出）
    static func render(_ f: (fid: Int, path: String, title: String, sid: String, computer: String), _ lo: Int, _ hi: Int, _ label: String, _ a: Args, again: [String]) throws -> String {
        let d = try EchoExport.export(URL(fileURLWithPath: f.path), computer: f.computer, withLines: true)
        let tools = a.flags.contains("tools")
        var out = ["\(f.title) · \(f.computer) · \(short(f.sid)) · \(label)" + (lo > 0 ? "（第 \(lo) 行起）" : "")]
        var items: [[String: Any]] = []
        func inRange(_ l: Int) -> Bool { l >= lo && l <= hi }
        for t in d["turns"] as? [[String: Any]] ?? [] {
            let role = t["role"] as? String ?? "", ts = t["ts"] as? String ?? "", line = t["line"] as? Int ?? 0
            if role == "assistant" {
                for b in t["blocks"] as? [[String: Any]] ?? [] {
                    let bl = b["line"] as? Int ?? line
                    guard inRange(bl) else { continue }
                    switch b["kind"] as? String {
                    case "text":
                        out.append("\n[\(hm(ts))] AI：" + (b["text"] as? String ?? "").trimmed)
                        items.append(["line": bl, "ts": ts, "role": "AI", "text": b["text"] ?? ""])
                    case "tool":
                        let one = EchoIndex.toolLine(b["name"] as? String ?? "", b["input"])
                        out.append("  · 工具 " + String(one.replacingOccurrences(of: "\n", with: " ").prefix(300)))
                        var it: [String: Any] = ["line": bl, "ts": ts, "role": "工具", "text": one]
                        if tools, let r = b["result"] as? String, !r.isEmpty {
                            let cut = String(r.prefix(2000))
                            out.append(cut.split(separator: "\n", omittingEmptySubsequences: false).map { "    │ " + $0 }.joined(separator: "\n") + (r.count > 2000 ? "\n    │ …（共 \(r.count) 字）" : ""))
                            it["result"] = cut
                        }
                        items.append(it)
                    default: break
                    }
                }
                continue
            }
            guard inRange(line) else { continue }
            let text = (t["text"] as? String ?? "").trimmed
            switch role {
            case "user": out.append("\n[\(hm(ts))] 我：" + text); items.append(["line": line, "ts": ts, "role": "我", "text": text])
            case "summary": out.append("\n[\(hm(ts))] 阶段总结：" + text); items.append(["line": line, "ts": ts, "role": "总结", "text": text])
            case "recap": out.append("\n[\(hm(ts))] 回顾：" + text); items.append(["line": line, "ts": ts, "role": "回顾", "text": text])
            case "command": out.append("\n[\(hm(ts))] 命令：" + text)
            default: break
            }
        }
        if a.flags.contains("json") { return json(["session": f.sid, "title": f.title, "range": label, "items": items]) }
        if out.count == 1 { out.append("（这一段没有对话）") }
        return paged(out.joined(separator: "\n"), a, shell(again + (tools ? ["--tools"] : [])))
    }

    // MARK: list

    static func list(_ a: Args) throws -> String {
        guard let data = EchoStats.loadLast(), let d = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Fail(text: "还没有总览数据：先运行 ech backup（或打开回响看一次总览）")
        }
        let (from, to) = try dayRange(a.opt["since"], a.opt["until"])
        let sessions = d["sessions"] as? [[String: Any]] ?? [], commits = d["commits"] as? [[String: Any]] ?? []
        // 提交归到哪个会话：生成总览数据时算好的 o（EchoStats.owner），和总览一致
        var byS: [String: [[String: Any]]] = [:]
        for c in commits {
            let day = String((c["d"] as? String ?? "").prefix(10))
            guard day >= from, day <= to, let o = c["o"] as? String else { continue }
            byS[o, default: []].append(c)
        }
        struct Row { var last: String; var proj: String; var title: String; var m: Int; var tok: Double; var commits: [[String: Any]]; var sid: String; var app: String; var computer: String }
        var rows: [Row] = []
        for s in sessions {
            let days = (s["days"] as? [String: [String: Any]] ?? [:]).filter { $0.key >= from && $0.key <= to }
            guard !days.isEmpty else { continue }
            if let app = a.opt["app"], (s["a"] as? String ?? "claude") != app { continue }
            if let p = a.opt["project"], !(s["d"] as? String ?? "").contains(p), !(s["p"] as? String ?? "").contains(p) { continue }
            let id = s["id"] as? String ?? ""
            let m = days.values.reduce(0) { $0 + ($1["m"] as? Int ?? 0) }
            if m == 0, tok(s, from, to) == 0, byS[id] == nil { continue }   // 空会话不列
            // AI 一次都没回复的 Claude 会话（测试、开了就关）不列；Claude 每次回复都记 Token，Codex 的旧会话不记，不按这条筛
            if (s["a"] as? String ?? "claude") == "claude", tok(s, "", "9") == 0, byS[id] == nil { continue }
            rows.append(Row(last: days.keys.max()!, proj: s["d"] as? String ?? "", title: s["t"] as? String ?? "", m: m, tok: tok(s, from, to),
                            commits: byS[id] ?? [], sid: sessionID(id), app: s["a"] as? String ?? "claude", computer: s["c"] as? String ?? ""))
        }
        rows.sort { $0.last != $1.last ? $0.last > $1.last : $0.tok > $1.tok }
        func vers(_ cs: [[String: Any]]) -> [String] {
            var v: [String] = []
            for c in cs.sorted(by: { ($0["d"] as? String ?? "") < ($1["d"] as? String ?? "") }) {
                if let k = EchoIndex.versionKey(c["s"] as? String ?? ""), !v.contains(k) { v.append(k) }
            }
            return v
        }
        if a.flags.contains("json") {
            return json(["from": from, "to": to, "sessions": rows.map { r -> [String: Any] in
                ["last": r.last, "project": r.proj, "title": r.title, "messages": r.m, "tokens": Int(r.tok), "session": r.sid, "app": r.app, "computer": r.computer,
                 "versions": vers(r.commits), "commits": r.commits.map { ["hash": String(($0["h"] as? String ?? "").prefix(7)), "time": $0["d"] ?? "", "subject": $0["s"] ?? ""] }]
            }])
        }
        let tm = rows.reduce(0) { $0 + $1.m }, tt = rows.reduce(0.0) { $0 + $1.tok }, tc = rows.reduce(0) { $0 + $1.commits.count }
        var out = ["\(from) 至 \(to)：\(rows.count) 个会话，我的消息 \(tm) 条，Token \(fmtTok(tt))，提交 \(tc) 次（总览数据）"]
        for r in rows {
            let v = vers(r.commits)
            var line = "\(r.last.dropFirst(5)) \(r.proj) · \(r.title) · \(r.m) 条 · \(fmtTok(r.tok))"
            if !r.commits.isEmpty { line += " · 提交 \(r.commits.count)" + (v.isEmpty ? "" : "（\(versText(v))）") }
            line += " · \(short(r.sid))"
            out.append(line)
        }
        if rows.isEmpty { out.append("这段时间没有会话") }
        return paged(out.joined(separator: "\n"), a, shell(["ech", "list"] + a.opt.filter { $0.key != "page" }.flatMap { ["--" + $0.key, $0.value] }))
    }

    /// 会话 ID 的短写法，用在引用里：Claude Code 的取前 8 位；Codex 的是按时间排的 UUIDv7，前 8 位约一分钟才变，取前 13 位
    static func short(_ sid: String) -> String {
        let c = Array(sid)
        return c.count >= 36 && c[14] == "7" ? String(c.prefix(13)) : String(c.prefix(8))
    }

    /// 备份文件路径 → 会话 ID（Codex 的文件名是 rollout-时间-会话ID）
    static func sessionID(_ path: String) -> String {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return name.hasPrefix("rollout-") ? String(name.suffix(36)) : name
    }

    /// 版本号多了只写头尾：0.1.0 至 0.8.2 共 14 个版本
    static func versText(_ v: [String]) -> String {
        v.count <= 4 ? v.joined(separator: "、") : "\(v.first!) 至 \(v.last!) 共 \(v.count) 个版本"
    }

    /// 一个会话在日期范围里的 Token 合计（各模型的输入、输出、读缓存、写缓存加起来）
    static func tok(_ s: [String: Any], _ from: String, _ to: String) -> Double {
        var t = 0.0
        for (k, v) in s["days"] as? [String: [String: Any]] ?? [:] where k >= from && k <= to {
            for (_, arr) in v["k"] as? [String: [Double]] ?? [:] { t += arr.reduce(0, +) }
        }
        return t
    }

    static func fmtTok(_ t: Double) -> String { t >= 1e6 ? String(format: "%.1fM", t / 1e6) : String(format: "%.0fK", t / 1e3) }

    // MARK: backup

    static func backup(_ a: Args) throws -> String {
        let r = EchoBackupJob.run()
        var out: [String] = []
        switch r.result {
        case .success(let res):
            out.append(String(format: "备份完成：%d 个文件，写入 %d，失败 %d，%.1f 秒", res.total, res.copied, res.failures.count, res.seconds))
            for f in res.failures.prefix(5) { out.append("  备份失败：\(f.path)：\(f.message)") }
        case .failure(let e):
            throw Fail(text: "备份失败：" + e.localizedDescription)
        }
        let root = EchoPrefs.backupRoot
        let sessions = EchoLibrary.scan(backupRoot: root)
        let ix = try EchoIndex.update(backupRoot: root, sessions: sessions)
        out.append(String(format: "索引：%d 个会话，更新 %d 个，%.1f 秒", ix.total, ix.changed, ix.seconds))
        _ = EchoStats.build(sessions, deleted: EchoDeleted.loadAll(root))
        out.append("总览数据已更新")
        return out.joined(separator: "\n")
    }

    /// 只更新索引和总览数据，不备份（索引坏了、刚升级时用）
    static func index() throws -> String {
        let root = EchoPrefs.backupRoot, sessions = EchoLibrary.scan(backupRoot: root)
        let ix = try EchoIndex.update(backupRoot: root, sessions: sessions)
        _ = EchoStats.build(sessions, deleted: EchoDeleted.loadAll(root))
        return String(format: "索引：%d 个会话，更新 %d 个，删掉 %d 个，%.1f 秒；总览数据已更新", ix.total, ix.changed, ix.removed, ix.seconds)
    }

    // MARK: mv

    /// 改文件夹名或挪位置，本机的会话（Claude Code、Codex）随之移动（和左栏目录右键「改名」同一套）。
    /// 旧路径已经不在了（在访达里改过了），或是指向新路径的软链（另一台电脑经 iCloud 同步来的），只挪会话；--dry-run 只说会做什么
    static func mv(_ a: Args) throws -> String {
        guard a.pos.count == 2 else { throw Fail(text: "用法：ech mv <旧路径> <新路径> [--dry-run]") }
        let cwd = FileManager.default.currentDirectoryPath
        func abs(_ s: String) -> String {
            let e = (s as NSString).expandingTildeInPath
            return ((e.hasPrefix("/") ? e : (cwd as NSString).appendingPathComponent(e)) as NSString).standardizingPath
        }
        let from = abs(a.pos[0])
        let t = mvTarget(from: from, to: abs(a.pos[1]))
        let to = t.to, fromExists = t.moveFolder
        if t.gone { throw Fail(text: "\(from) 和 \(to) 都不存在") }
        let root = EchoPrefs.backupRoot
        let p = EchoDirMove.plan(from: from, to: to, sessions: EchoLibrary.scan(backupRoot: root), moveFolder: fromExists)
        let what = fromExists ? "把 \(from) 改成 \(to)" : t.link ? "\(from) 是指向 \(to) 的软链，只把会话移到 \(to)" : "\(from) 已不存在，只把会话移到 \(to)"
        if a.flags.contains("json") && a.flags.contains("dry-run") {
            return json(["from": from, "to": to, "moveFolder": fromExists, "sessions": p.count, "skipped": p.skipped.count, "missing": p.missing.count, "busy": p.busy?.meta.title ?? ""])
        }
        if a.flags.contains("dry-run") {
            var out = "预览：\(what)；\(EchoDirMove.describe(p))。"
            if let b = p.busy { out += "\n「\(b.meta.title)」正在使用，现在执行" + (fromExists ? "会整个不动。" : "会跳过它。") }
            return out + "\n去掉 --dry-run 执行。"
        }
        let r = try EchoDirMove.run(p)
        _ = try? EchoIndex.update(backupRoot: root)
        var out = (fromExists ? "已把 \(from) 改成 \(to)" : "已把会话移到 \(to)") + "；移动了 \(r.done) 个会话。"
        if p.count > r.done, let e = r.error { out += "\n其余未移动：" + e.localizedDescription }
        let rest = EchoDirMove.describe(Plan(skipped: p.skipped, missing: p.missing))
        if !p.skipped.isEmpty || !p.missing.isEmpty { out += "\n" + rest + "。" }
        return out
    }

    /// ech mv 实际做什么：新路径是已有的文件夹时挪进去（和 mv 一样）；旧路径已不存在、或是指向新路径的软链时只挪会话（moveFolder 为 false），
    /// 软链留在原处。比对时两边都解析软链，新路径写软链路径或真实路径都认。gone：两边都不存在
    static func mvTarget(from: String, to: String) -> (to: String, moveFolder: Bool, link: Bool, gone: Bool) {
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: from)) != nil, EchoPath.real(from) == EchoPath.real(to) { return (to, false, true, false) }
        var isDir: ObjCBool = false
        let fromExists = fm.fileExists(atPath: from, isDirectory: &isDir) && isDir.boolValue
        if fromExists, fm.fileExists(atPath: to, isDirectory: &isDir), isDir.boolValue { return ((to as NSString).appendingPathComponent((from as NSString).lastPathComponent), true, false, false) }
        return (to, fromExists, false, !fromExists && !fm.fileExists(atPath: to))
    }

    private static func Plan(skipped: [EchoSession], missing: [EchoSession]) -> EchoDirMove.Plan {
        var x = EchoDirMove.Plan(from: "", to: "", moveFolder: false)
        x.skipped = skipped; x.missing = missing
        return x
    }

    // MARK: schema、skill

    static let commands: [[String: Any]] = [
        ["command": "find", "summary": "按关键词找会话和段（只读）。默认只找对话：我说的、回顾、阶段总结、AI 回的", "args": [["name": "关键词", "required": true, "desc": "空格分开的几个词都要有；3 个字以上走全文索引"]],
         "options": [["name": "--app", "values": "claude | codex"], ["name": "--since", "values": "2026-11-16 | 2026/11/16 | 11-16 | 7d"], ["name": "--project", "desc": "项目路径里的词"], ["name": "--tools", "desc": "连工具调用和命令一起找"], ["name": "--limit", "default": 20], ["name": "--page"], ["name": "--json"]]],
        ["command": "list", "summary": "按时间列会话、我的消息、Token、提交和版本（只读，取总览数据）",
         "options": [["name": "--since", "default": "7d", "values": "2026-11-16 | 2026/11/16 | 11-16 | 7d"], ["name": "--until", "default": "今天", "values": "2026-11-22 | 11-22"], ["name": "--project"], ["name": "--app"], ["name": "--page"], ["name": "--json"]]],
        ["command": "segs", "summary": "列一个会话的分段：段号、起止行、时间、版本、第一句（只读）", "args": [["name": "会话", "required": true, "desc": "会话 ID 前 8 位或备份文件路径"]], "options": [["name": "--json"]]],
        ["command": "read", "summary": "把一段读成对话文字（只读）", "args": [["name": "引用", "required": true, "desc": "会话#段号（ce57ce36#3）、会话#L起-止（ce57ce36#L1200-1500），只写会话读最后一段"]],
         "options": [["name": "--tools", "desc": "带上工具输出，每条前 2000 字"], ["name": "--page"], ["name": "--json"]]],
        ["command": "context", "summary": "续上一个会话：最近一次压缩的阶段总结和之后的全部对话，新会话开头读它就能接着做（只读）",
         "args": [["name": "会话", "required": true]], "options": [["name": "--tools"], ["name": "--page"], ["name": "--json"]]],
        ["command": "resume", "summary": "会话的恢复命令（cd <文件夹> && claude --resume <ID>，Codex 是 codex resume），贴到终端或 MintPop 主页接着聊原会话；挪过文件夹的用新文件夹（只读）",
         "args": [["name": "会话", "required": true]], "options": [["name": "--json"]]],
        ["command": "mv", "summary": "改名或移动文件夹，本机的会话随之移动（会写：访达里的文件夹、~/.claude 的会话位置、~/.codex/state_5.sqlite 的会话文件夹、备份）；旧路径已不存在时，或是指向新路径的软链时，只移动会话",
         "args": [["name": "旧路径", "required": true], ["name": "新路径", "required": true, "desc": "是已有的文件夹时移入其中，和 mv 一样"]],
         "options": [["name": "--dry-run", "desc": "只说会做什么，不动文件"], ["name": "--json"]]],
        ["command": "backup", "summary": "备份、更新索引和总览数据（和回响的「立即备份」一样，会写备份目录）"],
        ["command": "index", "summary": "只更新索引和总览数据，不备份"],
        ["command": "schema", "summary": "各命令的参数", "args": [["name": "命令", "required": false]]],
        ["command": "install-skill", "summary": "装 ech skill 到 ~/.claude/skills/ech，本机有 Codex 时也装到 ~/.codex/skills/ech（同名的先删再装）"],
    ]

    static func schema(_ a: Args) throws -> String {
        if let c = a.pos.first {
            guard let one = commands.first(where: { $0["command"] as? String == c }) else { throw Fail(text: "没有「\(c)」这个命令") }
            return json(one)
        }
        return json(["version": appVersion ?? "", "commands": commands])
    }

    static var skillDir: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/skills/ech") }
    /// Codex 的 skill 目录：本机装了 Codex（有 ~/.codex）时也装一份，哪家 AI 都能用
    static var codexSkillDir: URL? {
        let codex = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
        return FileManager.default.fileExists(atPath: codex.path) ? codex.appendingPathComponent("skills/ech") : nil
    }

    /// 应用里带的 skill：Contents/Resources/skills/ech
    static var bundledSkill: URL? {
        let u = (appBundle ?? Bundle.main.bundleURL).appendingPathComponent("Contents/Resources/skills/ech")
        return FileManager.default.fileExists(atPath: u.appendingPathComponent("SKILL.md").path) ? u : nil
    }

    static func skillVersion(_ dir: URL) -> String? {
        guard let s = try? String(contentsOf: dir.appendingPathComponent("SKILL.md"), encoding: .utf8) else { return nil }
        for line in s.split(separator: "\n").prefix(20) where line.hasPrefix("version:") {
            return line.dropFirst(8).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }
        return nil
    }

    static func installSkill() throws -> String {
        guard let src = bundledSkill else { throw Fail(text: "应用里没有带 skill，请从装好的回响里运行 ech") }
        let fm = FileManager.default
        let dirs = [skillDir] + (codexSkillDir.map { [$0] } ?? [])
        for d in dirs {
            try fm.createDirectory(at: d.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: d.path) { try fm.removeItem(at: d) }
            try fm.copyItem(at: src, to: d)
        }
        return "已安装 ech skill \(skillVersion(skillDir) ?? "")：" + dirs.map { ($0.path as NSString).abbreviatingWithTildeInPath }.joined(separator: "、")
    }

    /// 装的 skill 比应用旧时提醒一句（照 hac 的版本提示）
    static func skillNotice() -> String? {
        guard let app = appVersion, let bundled = bundledSkill.flatMap(skillVersion) else { return nil }
        let installed = skillVersion(skillDir)
        guard installed != bundled else { return nil }
        return installed == nil ? "（还没装 ech skill：运行 ech install-skill）" : "（ech skill 是 \(installed!)，回响是 \(app)：运行 ech install-skill 更新）"
    }
}

/// 装命令行工具：~/.local/bin/ech 指向应用里的程序，再装 skill。首次设置完成时装一次，设置「通用」里能手动装；
/// 装过的每次启动时检查一遍（应用挪了位置、升级了），替身和 skill 跟上
enum EchoCLIInstall {
    static var link: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin/ech") }
    static var target: String? { Bundle.main.executablePath }

    /// 已经装过：~/.local/bin/ech 是个替身（指向哪都算，启动时会修正）
    static var installed: Bool { (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil }

    /// ~/.local/bin 在不在终端的 PATH 里（Claude Code 的终端也是从登录 shell 继承的）。
    /// 从访达打开的回响自己的 PATH 很短，不准：问一次登录 shell（读 .zprofile、.zshrc），3 秒没回就按不在算
    static let inPath: Bool = {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        p.arguments = ["-ilc", "echo \"$PATH\""]
        p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning, Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return false }
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let dir = link.deletingLastPathComponent().path
        return path.split(whereSeparator: { $0 == ":" || $0 == "\n" }).contains { $0 == dir || $0 == "$HOME/.local/bin" }
    }()

    static func install() throws {
        guard let target else { throw EchoCLI.Fail(text: "找不到回响的程序") }
        let fm = FileManager.default
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if installed || fm.fileExists(atPath: link.path) {
            guard installed else { throw EchoCLI.Fail(text: "\(link.path) 已有别的文件，没有覆盖") }
            try fm.removeItem(at: link)
        }
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        _ = try EchoCLI.installSkill()
    }

    /// 启动时：装过的，替身不指向当前程序就重建，skill 和应用版本不一致就重装
    static func refreshIfInstalled() {
        guard installed, let target else { return }
        let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        let want = EchoCLI.bundledSkill.flatMap(EchoCLI.skillVersion)
        let staleSkill = want != EchoCLI.skillVersion(EchoCLI.skillDir) || EchoCLI.codexSkillDir.map { want != EchoCLI.skillVersion($0) } == true
        if dest != target || staleSkill {
            do { try install() } catch { NSLog("回响：更新命令行工具失败：%@", error.localizedDescription) }
        }
    }
}
