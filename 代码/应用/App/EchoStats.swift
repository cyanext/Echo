// 总览的数：每个会话每天的我的消息、AI 干活时长、各模型的 Token；每个项目的 Git 提交；删掉的会话留下的统计。
// 只读：会话读备份，Git 只跑 log。整理成 JSON 交给 Web/overview.js 算周、比较、折合美元（单价在 Web/prices.json）。
// 口径见 设计/总览/说明.md「数怎么算」。
import Foundation

/// 一个会话一天的数
struct EchoDayStat: Codable, Equatable {
    var m = 0                         // 我的消息条数
    var ms = 0.0                      // AI 干活毫秒数（turn_duration 相加）
    var lg = 0.0                      // 最长一轮毫秒数
    var k: [String: [Double]] = [:]   // 模型 → [输入, 输出, 读缓存, 写缓存 5 分钟, 写缓存 1 小时]
    var a = 0.0                       // 这天第一条、最后一条记录的时间（秒），用来把提交归到会话
    var b = 0.0
}

/// 删掉的会话留下的统计：只有按天的数和几项会话信息，没有对话内容。删会话前记下，总览照算
struct EchoDeletedSession: Codable, Equatable {
    var sid: String                   // 会话 ID
    var t: String                     // 标题
    var cwd: String                   // 会话目录
    var c: String                     // 电脑
    var deleted: String               // 删除时间（ISO 8601）
    var days: [String: EchoDayStat]
    var g: [String]? = nil            // 会话里 git commit 输出的提交号（前 7 位），总览按它把提交挂到会话上
}

/// 已删除统计：每台电脑一个文件 <备份目录>/<电脑名>/已删除统计.json，只有这台电脑写（只能删本机的会话），读的时候各台合起来
enum EchoDeleted {
    private struct File: Codable { var sessions: [EchoDeletedSession] = [] }

    static func url(_ computerDir: URL) -> URL { computerDir.appendingPathComponent("已删除统计.json") }

    static func load(_ computerDir: URL) -> [EchoDeletedSession] {
        (try? Data(contentsOf: url(computerDir))).flatMap { try? JSONDecoder().decode(File.self, from: $0) }?.sessions ?? []
    }

    static func loadAll(_ backupRoot: URL) -> [EchoDeletedSession] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return dirs.flatMap(load)
    }

    /// 加进这台电脑的记录，同一个会话（删了、放回、又删）只留最新一条。先写临时文件再改名，写到一半不会坏
    static func add(_ list: [EchoDeletedSession], _ computerDir: URL) throws {
        guard !list.isEmpty else { return }
        let ids = Set(list.map(\.sid))
        let all = load(computerDir).filter { !ids.contains($0.sid) } + list
        try FileManager.default.createDirectory(at: computerDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try enc.encode(File(sessions: all)).write(to: url(computerDir), options: .atomic)
    }

    /// 删掉某些会话的统计（总览里就不算了）：每台电脑的已删除统计里都找，id 是「电脑/会话 ID」
    static func forget(_ ids: Set<String>, _ backupRoot: URL) {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        for d in dirs {
            let all = load(d)
            let kept = all.filter { !ids.contains($0.c + "/" + $0.sid) }
            guard kept.count != all.count else { continue }
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            try? enc.encode(File(sessions: kept)).write(to: url(d), options: .atomic)
        }
    }

    /// 从备份读出这个会话按天的数
    static func make(_ s: EchoSession, at date: Date = Date()) throws -> EchoDeletedSession {
        let (days, g) = try EchoStats.readAll(s.url)
        return EchoDeletedSession(sid: s.sessionId, t: s.meta.title == s.sessionId ? "未命名会话" : s.meta.title, cwd: s.projectPath,
                                  c: s.computer, deleted: ISO8601DateFormatter().string(from: date), days: days, g: g.isEmpty ? nil : g.sorted())
    }
}

/// 一个仓库上次的 git log 结果：key 是起始日期加各分支指向的提交
struct GitLogCache: Codable { var key: String; var log: String }

private struct EchoStatsCache: Codable {
    struct Entry: Codable { var stamp: EchoFileStamp; var days: [String: EchoDayStat]; var g: [String]? }
    var entries: [String: Entry] = [:]
}

enum EchoStats {
    private static let needleUser = Array("\"type\":\"user\"".utf8)
    private static let needleAsst = Array("\"type\":\"assistant\"".utf8)
    private static let needleUsage = Array("\"usage\"".utf8)
    private static let needleTurn = Array("\"turn_duration\"".utf8)

    /// 本机时区的「年-月-日」
    static func dayKey(_ ts: String) -> String? {
        guard let t = epoch(ts) else { return nil }
        var offsets: [Int: Int] = [:]
        return localDay(t, &offsets)
    }

    static func epoch(_ s: String) -> Double? { EchoTime.parse(s)?.timeIntervalSince1970 }

    /// 秒数对应的本地「年-月-日」：时区偏移按小时缓存在调用方（夏令时也对），日期自己算
    static func localDay(_ t: Double, _ offsets: inout [Int: Int]) -> String {
        let hour = Int((t / 3600).rounded(.down))
        let off: Int
        if let o = offsets[hour] { off = o } else {
            off = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: t))
            offsets[hour] = off
        }
        let z = Int(((t + Double(off)) / 86400).rounded(.down)) + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    private static let needleToolResult = Array("\"tool_result\"".utf8)
    private static let kType = RawJSON.quoted("type"), kTs = RawJSON.quoted("timestamp"), kMessage = RawJSON.quoted("message")
    private static let kUsage = RawJSON.quoted("usage"), kModel = RawJSON.quoted("model"), kRequestId = RawJSON.quoted("requestId")
    private static let kId = RawJSON.quoted("id"), kSubtype = RawJSON.quoted("subtype"), kDuration = RawJSON.quoted("durationMs")
    private static let kCacheCreation = RawJSON.quoted("cache_creation")

    static func read(_ url: URL) throws -> [String: EchoDayStat] { try readAll(url).days }

    private static let needleChanged = [" file changed", " files changed"].map { Array($0.utf8) }
    /// git commit 的输出第一行「[分支 提交号] 说明」
    private static let commitOut = try! NSRegularExpression(pattern: #"\[[^\]\\]{1,120} ([0-9a-f]{7,40})\]"#)

    /// 会话里 git commit 跑出的提交号（前 7 位）：只看带工具结果、又有「file(s) changed」的行
    static func commitHashes(_ b: UnsafeBufferPointer<UInt8>, into g: inout Set<String>) {
        guard needleChanged.contains(where: { EchoLines.has(b, $0) }) else { return }
        let s = String(decoding: b, as: UTF8.self), ns = s as NSString
        for m in commitOut.matches(in: s, range: NSRange(location: 0, length: ns.length)) { g.insert(String(ns.substring(with: m.range(at: 1)).prefix(7))) }
    }

    private static let needleBash = Array("\"name\":\"Bash\"".utf8), needleCommit = Array("commit".utf8)
    /// git commit -m "说明"、-qm '说明'、-m "$(cat <<'EOF' 说明 …"：取说明
    private static let commitMsg = try! NSRegularExpression(pattern: #"git\b[^\n]*?\scommit\b[^\n]*?\s-[a-zA-Z]*m\s*(?:"\$\(cat <<'?(\w+)'?\n([^\n]*)|"((?:[^"\\]|\\.)*)"|'([^']*)')"#)

    /// 提交说明的第一行、去掉首尾空白后的前 30 个字：会话里的 git commit 命令和 git log 的说明都按这个对
    static func commitKey(_ msg: String) -> String {
        String((msg.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? "").trimmed.prefix(30))
    }

    /// 会话里跑过的 git commit 命令的说明（commitKey）。用 -q 提交时没有「[分支 提交号]」输出，只能按说明对
    static func commitMessages(_ b: UnsafeBufferPointer<UInt8>, into g: inout Set<String>) {
        guard EchoLines.has(b, needleBash), EchoLines.has(b, needleCommit),
              let d = try? JSONSerialization.jsonObject(with: Data(buffer: b)) as? [String: Any],
              let content = (d["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return }
        for c in content where c["type"] as? String == "tool_use" && c["name"] as? String == "Bash" {
            guard let cmd = (c["input"] as? [String: Any])?["command"] as? String else { continue }
            commitMessages(in: cmd, into: &g)
        }
    }

    /// 一条命令里 git commit 的说明（commitKey），记成「m:说明」
    static func commitMessages(in cmd: String, into g: inout Set<String>) {
        for msg in commitTexts(in: cmd) {
            let k = commitKey(msg)
            if !k.isEmpty { g.insert("m:" + k) }
        }
    }

    /// 一条命令里 git commit 的说明原文（-m "…"、-m '…'、heredoc 的第一行）
    static func commitTexts(in cmd: String) -> [String] {
        guard cmd.contains("commit") else { return [] }
        let ns = cmd as NSString
        return commitMsg.matches(in: cmd, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard let r = (2...4).map({ m.range(at: $0) }).first(where: { $0.location != NSNotFound }) else { return nil }
            var msg = ns.substring(with: r)
            if m.range(at: 3).location != NSNotFound { msg = msg.replacingOccurrences(of: "\\\"", with: "\"") }
            return msg
        }
    }

    /// 读一个会话文件，按天汇总；顺带收 git commit 跑出的提交号。同一次回复拆成几行记录，按 requestId 去重。
    /// 只取要用的几个字段：用保留原文的解析器（RawJSON，不建字典），只有不带工具结果的用户消息才完整解析，判断是不是人打的字
    static func readAll(_ url: URL) throws -> (days: [String: EchoDayStat], g: Set<String>) {
        if try EchoExport.isCodexFile(url) { return try readCodex(url) }
        var days: [String: EchoDayStat] = [:], seen = Set<String>(), offsets: [Int: Int] = [:], g = Set<String>()
        func str(_ v: RawJSON?) -> String? { v?.stringRaw.flatMap { EchoSlim.decode($0) } }
        func num(_ v: RawJSON?) -> Double {
            guard case .scalar(let b)? = v else { return 0 }
            return Double(String(decoding: b, as: UTF8.self)) ?? 0
        }
        try EchoLines.each(url) { line in
            let b = EchoLines.trim(line)
            let isUser = EchoLines.has(b, needleUser)
            let isUsage = !isUser && EchoLines.has(b, needleAsst) && EchoLines.has(b, needleUsage)
            let isTurn = !isUser && !isUsage && EchoLines.has(b, needleTurn)
            if isUser, EchoLines.has(b, needleToolResult) { commitHashes(b, into: &g) }
            else if !isUser, EchoLines.has(b, needleAsst) { commitMessages(b, into: &g) }
            guard isUser || isUsage || isTurn, let j = RawJSON.parse(b),
                  let ts = str(j[kTs]), let t = epoch(ts) else { return }
            let day = localDay(t, &offsets)
            var span = days[day, default: .init()]
            span.a = span.a == 0 ? t : min(span.a, t)
            span.b = max(span.b, t)
            days[day] = span
            let type = str(j[kType])
            if isUser {
                // 带工具结果的是工具输出，不是人打的字，不用解析内容
                guard type == "user", !EchoLines.has(b, needleToolResult),
                      let d = try? JSONSerialization.jsonObject(with: Data(buffer: b)) as? [String: Any],
                      EchoExport.userRole(d)?.role == "user" else { return }
                days[day, default: .init()].m += 1
            } else if isUsage {
                guard type == "assistant", let msg = j[kMessage], let u = msg[kUsage], case .object = u else { return }
                let rid = str(j[kRequestId]) ?? str(msg[kId]) ?? UUID().uuidString
                guard seen.insert(rid).inserted else { return }
                let model = str(msg[kModel]) ?? "?"
                guard model != "<synthetic>" else { return }
                func n(_ k: String) -> Double { num(u[RawJSON.quoted(k)]) }
                let cc = u[kCacheCreation]
                var w5 = num(cc?[RawJSON.quoted("ephemeral_5m_input_tokens")])
                let w1 = num(cc?[RawJSON.quoted("ephemeral_1h_input_tokens")])
                w5 += max(0, n("cache_creation_input_tokens") - w5 - w1)
                let add = [n("input_tokens"), n("output_tokens"), n("cache_read_input_tokens"), w5, w1]
                var s = days[day, default: .init()]
                s.k[model] = zip(s.k[model] ?? [0, 0, 0, 0, 0], add).map { $0 + $1 }
                days[day] = s
            } else {
                guard str(j[kSubtype]) == "turn_duration" else { return }
                let ms = num(j[kDuration])
                var s = days[day, default: .init()]
                s.ms += ms
                s.lg = max(s.lg, ms)
                days[day] = s
            }
        }
        return (days, g)
    }

    /// Codex 的会话按天汇总：我的消息数人打的字（EchoExport.codexUserParts）；Token 取 token_usage_record（按 response_id 去重，
    /// 模型取最近一条 turn_context）：缓存读取含在输入里，思考含在输出里，所以 [输入 − 读缓存, 输出, 读缓存, 0, 0]；
    /// AI 干活取 task_complete 的 duration_ms；提交取 git commit 命令里的说明和输出里的提交号
    static func readCodex(_ url: URL) throws -> (days: [String: EchoDayStat], g: Set<String>) {
        var days: [String: EchoDayStat] = [:], seen = Set<String>(), offsets: [Int: Int] = [:], g = Set<String>(), model = "?"
        let wanted = ["\"type\":\"turn_context\"", "\"type\":\"token_usage_record\"", "\"task_complete\"", "\"role\":\"user\"", "commit"].map { Array($0.utf8) }
        func touch(_ ts: String?) -> String? {
            guard let ts, let t = epoch(ts) else { return nil }
            let day = localDay(t, &offsets)
            var s = days[day, default: .init()]
            s.a = s.a == 0 ? t : min(s.a, t)
            s.b = max(s.b, t)
            days[day] = s
            return day
        }
        try EchoLines.each(url) { line in
            let b = EchoLines.trim(line)
            guard wanted.contains(where: { EchoLines.has(b, $0) }),
                  let d = (try? JSONSerialization.jsonObject(with: Data(buffer: b))) as? [String: Any], let p = d["payload"] as? [String: Any] else { return }
            let t = d["type"] as? String, pt = p["type"] as? String, ts = d["timestamp"] as? String
            switch (t, pt) {
            case ("turn_context", _):
                if let m = p["model"] as? String, !m.isEmpty { model = m }
            case ("token_usage_record", _):
                guard let u = p["usage"] as? [String: Any] else { return }
                let rid = p["response_id"] as? String ?? UUID().uuidString
                guard seen.insert(rid).inserted, let day = touch(ts) else { return }
                func n(_ k: String) -> Double { (u[k] as? NSNumber)?.doubleValue ?? 0 }
                let cached = n("cached_input_tokens")
                let add = [max(0, n("input_tokens") - cached), n("output_tokens"), cached, 0, 0]
                days[day]!.k[model] = zip(days[day]!.k[model] ?? [0, 0, 0, 0, 0], add).map { $0 + $1 }
            case ("event_msg", "task_complete"):
                guard let ms = (p["duration_ms"] as? NSNumber)?.doubleValue, let day = touch(ts) else { return }
                days[day]!.ms += ms
                days[day]!.lg = max(days[day]!.lg, ms)
            case ("response_item", "message") where p["role"] as? String == "user":
                guard !EchoExport.codexUserParts(p).human.isEmpty, let day = touch(ts) else { return }
                days[day]!.m += 1
            case ("response_item", "function_call"), ("response_item", "custom_tool_call"):
                let v = (p["arguments"] ?? p["input"]) as? String ?? ""
                // function_call 的参数是 JSON（{"cmd": …}），解开再找；custom_tool_call 是一段脚本，直接找
                let cmd = ((try? JSONSerialization.jsonObject(with: Data(v.utf8))) as? [String: Any]).flatMap { ($0["cmd"] ?? $0["command"]).map { "\($0)" } } ?? v
                commitMessages(in: cmd, into: &g)
            case ("response_item", "function_call_output"), ("response_item", "custom_tool_call_output"):
                commitHashes(b, into: &g)
            default: break
            }
        }
        return (days, g)
    }

    /// 会话归到哪个项目：和左栏目录树同一套路径，取大目录下面那一级（~/Desktop/项目代码/NAS/伙伴云NAS应用 → NAS）；
    /// 以「.」开头的目录（.worktrees）算进上一级
    static func project(_ path: String) -> String {
        if let a = EchoPath.alias[EchoPath.real(path)] { return a }
        let comps = EchoPath.parts(path).comps
        return comps.count >= 3 ? comps[2] : comps.last ?? "~"
    }

    /// 总览卡片上写的路径：大目录加项目（~/Desktop/项目代码/NAS/伙伴云NAS应用 → 项目代码/NAS）
    static func projectPath(_ path: String) -> String {
        if let a = EchoPath.alias[EchoPath.real(path)] { return a }
        let comps = EchoPath.parts(path).comps
        return comps.count >= 3 ? comps[1] + "/" + comps[2] : comps.last ?? "~"
    }

    // MARK: Git

    struct Commit: Codable { var h: String; var p: String; var d: String; var s: String; var a: Int; var r: Int; var f: [String] }

    /// 跑一条 git 命令（只读），出错返回空
    private static func git(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : ""
    }

    /// 会话目录对应的仓库目录：分支工作区合完删掉了，换成它所在的主目录（…/回响/.worktrees/整理 → …/回响）
    static func liveDir(_ cwd: String) -> String? {
        let fm = FileManager.default
        if fm.fileExists(atPath: cwd) { return cwd }
        if let r = cwd.range(of: "/.worktrees/") {
            let main = String(cwd[..<r.lowerBound])
            if fm.fileExists(atPath: main) { return main }
        }
        return nil
    }

    /// 目录本身不在仓库里（在「项目代码」这种上级目录开的会话）：往下找两层里的仓库，以「.」开头的目录不进。家目录和根目录不找
    static func reposBelow(_ dir: String) -> [String] {
        let fm = FileManager.default
        guard dir != NSHomeDirectory(), dir != "/" else { return [] }
        func kids(_ d: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: d)) ?? []).filter { !$0.hasPrefix(".") }.map { d + "/" + $0 }
                .filter { var isDir: ObjCBool = false; return fm.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue }
        }
        let isRepo = { (d: String) in fm.fileExists(atPath: d + "/.git") }
        var out: [String] = []
        for k in kids(dir) {
            if isRepo(k) { out.append(k); continue }
            out += kids(k).filter(isRepo)
        }
        return out
    }

    /// 会话所在目录里的 Git 仓库，从 since 起的提交（不含合并提交）；同一个提交在几个工作区只算一次。
    /// 会话目录不在仓库里时，算它下面两层里的仓库（规则见 设计/总览/说明.md「数怎么算」）
    static func commits(cwds: Set<String>, since: String) -> [Commit] {
        // 几十个目录、十几个仓库，一个个跑要几秒：并行跑
        let dirs = Set(cwds.compactMap(liveDir)).sorted()
        var tops = [[String]](repeating: [], count: dirs.count)
        tops.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: dirs.count) { i in
                let top = git(["-C", dirs[i], "rev-parse", "--show-toplevel"]).trimmingCharacters(in: .whitespacesAndNewlines)
                buf[i] = top.isEmpty ? reposBelow(dirs[i]) : [top]
            }
        }
        let repos = Set(tops.joined()).sorted()
        // git log --numstat 在大仓库上要好几秒：每个仓库先用 rev-parse --all（很快）取各分支指向的提交当指纹，
        // 指纹和起始日期都没变就用上次的结果，只重跑变了的仓库
        let cacheURL = EchoLibrary.supportDir.appendingPathComponent("总览git缓存.json")
        let cache = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode([String: GitLogCache].self, from: $0) } ?? [:]
        var logs = [String](repeating: "", count: repos.count), keys = [String](repeating: "", count: repos.count)
        logs.withUnsafeMutableBufferPointer { buf in
            keys.withUnsafeMutableBufferPointer { kb in
                DispatchQueue.concurrentPerform(iterations: repos.count) { i in
                    let key = since + "\n" + git(["-C", repos[i], "rev-parse", "--all"])
                    kb[i] = key
                    if let c = cache[repos[i]], c.key == key { buf[i] = c.log; return }
                    buf[i] = git(["-C", repos[i], "log", "--all", "--no-merges", "--since=\(since)", "--date=iso-strict",
                                  "--pretty=format:%x1e%H%x1f%aI%x1f%s", "--numstat"])
                }
            }
        }
        var fresh: [String: GitLogCache] = [:]
        for (i, r) in repos.enumerated() { fresh[r] = GitLogCache(key: keys[i], log: logs[i]) }
        if let d = try? JSONEncoder().encode(fresh) { try? d.write(to: cacheURL, options: .atomic) }
        var seen = Set<String>(), out: [Commit] = []
        for (r, log) in zip(repos, logs) {
            for rec in log.split(separator: "\u{1e}") {
                let lines = rec.split(separator: "\n", omittingEmptySubsequences: true)
                guard let head = lines.first else { continue }
                let f = head.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
                guard f.count >= 3, seen.insert(f[0]).inserted else { continue }
                var c = Commit(h: f[0], p: project(r), d: f[1], s: f[2], a: 0, r: 0, f: [])
                for l in lines.dropFirst() {
                    let n = l.split(separator: "\t", maxSplits: 2).map(String.init)
                    guard n.count == 3 else { continue }
                    c.a += Int(n[0]) ?? 0
                    c.r += Int(n[1]) ?? 0
                    c.f.append(r + "/" + n[2])
                }
                out.append(c)
            }
        }
        return out
    }

    // MARK: 汇总

    /// 整理成 overview.js 要的 JSON。同步执行，放在后台线程调用
    static func build(_ sessions: [EchoSession], deleted: [EchoDeletedSession] = []) -> Data {
        let cacheURL = EchoLibrary.supportDir.appendingPathComponent("总览缓存3.json")   // 2：加了每天的起止时间；3：加了提交号
        let cache = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode(EchoStatsCache.self, from: $0) } ?? EchoStatsCache()
        var fresh = EchoStatsCache()
        var list: [[String: Any]] = []
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        // 缓存里没有、或文件变了的，并发读（第一次打开时一百多个文件，一个个读要十几秒）
        let stamps = sessions.map { s -> EchoFileStamp? in
            guard let v = try? s.url.resourceValues(forKeys: keys) else { return nil }
            return EchoFileStamp(size: Int64(v.fileSize ?? 0), mtime: v.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        var read = [(days: [String: EchoDayStat], g: Set<String>)?](repeating: nil, count: sessions.count)
        let todo = sessions.indices.filter { i in stamps[i] != nil && cache.entries[sessions[i].url.path]?.stamp != stamps[i] }
        read.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: todo.count) { n in buf[todo[n]] = try? self.readAll(sessions[todo[n]].url) }
        }
        for (i, s) in sessions.enumerated() {
            guard let stamp = stamps[i] else { continue }
            let days: [String: EchoDayStat], g: [String]
            if let e = cache.entries[s.url.path], e.stamp == stamp { days = e.days; g = e.g ?? [] }
            else if let d = read[i] { days = d.days; g = d.g.sorted() }
            else { continue }
            fresh.entries[s.url.path] = .init(stamp: stamp, days: days, g: g.isEmpty ? nil : g)
            guard !days.isEmpty else { continue }
            let dict = days.mapValues { d -> [String: Any] in ["m": d.m, "ms": d.ms, "lg": d.lg, "k": d.k, "a": d.a, "b": d.b] }
            var one: [String: Any] = ["id": s.id, "t": s.meta.title == s.sessionId ? "未命名会话" : s.meta.title,
                                      "p": project(s.projectPath), "d": projectPath(s.projectPath), "c": s.computer, "days": dict]
            if !g.isEmpty { one["g"] = g }
            if s.app != .claude { one["a"] = s.app.rawValue }
            one["z"] = s.size   // 备份文件多大：备份页的「备份趋势」按会话开始那周累加
            list.append(one)
        }
        if let d = try? JSONEncoder().encode(fresh) { try? d.write(to: cacheURL, options: .atomic) }
        // 删掉的会话照算；从废纸篓放回来的（同一台电脑、同一个会话 ID 又读到了）用读到的，不算两遍
        let live = Set(sessions.map { $0.computer + "/" + $0.sessionId })
        let gone = deleted.filter { !live.contains($0.c + "/" + $0.sid) && !$0.days.isEmpty }
        for g in gone {
            let dict = g.days.mapValues { d -> [String: Any] in ["m": d.m, "ms": d.ms, "lg": d.lg, "k": d.k, "a": d.a, "b": d.b] }
            var one: [String: Any] = ["id": "deleted:" + g.c + "/" + g.sid, "x": 1, "t": g.t, "p": project(g.cwd), "d": projectPath(g.cwd), "c": g.c, "days": dict]
            if let h = g.g, !h.isEmpty { one["g"] = h }
            list.append(one)
        }

        // Git：只看本机会话的目录，从最早有会话的那天起，最多半年
        let first = list.flatMap { ($0["days"] as? [String: Any])?.keys.map { $0 } ?? [] }.min() ?? ""
        let half = Calendar.current.date(byAdding: .month, value: -6, to: Date())!
        let since = max(first, String(EchoTime.formatted(half, "yyyy-MM-dd")))
        let cwds = Set(sessions.filter { $0.computer == EchoPrefs.computerName }.map(\.meta.cwd).filter { !$0.isEmpty }
                       + gone.filter { $0.c == EchoPrefs.computerName }.map(\.cwd))
        let commits = first.isEmpty ? [] : self.commits(cwds: cwds, since: since)
        let owners = owner(commits, list)
        let gitList = commits.enumerated().map { i, c -> [String: Any] in
            var x: [String: Any] = ["h": c.h, "p": c.p, "d": c.d, "s": c.s, "a": c.a, "r": c.r, "f": c.f]
            if let o = owners[i] { x["o"] = o }
            return x
        }

        let out: [String: Any] = ["today": EchoTime.formatted(Date(), "yyyy-MM-dd"), "sessions": list, "commits": gitList, "backup": backupSummary(sessions)]
        let data = (try? JSONSerialization.data(withJSONObject: out)) ?? Data("{}".utf8)
        try? data.write(to: lastURL, options: .atomic)
        return data
    }

    /// 提交归到哪个会话（总览和 ech 用同一个结果）：先看哪个会话里做了这次提交（会话的 g：git commit 输出里的提交号前 7 位，
    /// 和「m:」加说明第一行前 30 字），在别的文件夹里提交的也对得上；没有的，同一项目、提交时间落在会话这天的起止之间
    /// （前后各放宽 10 分钟），几个都对得上取这天 Token 多的；都对不上的不归任何会话，只算进当天的提交次数
    static func owner(_ commits: [Commit], _ sessions: [[String: Any]]) -> [String?] {
        var byKey: [String: String] = [:]
        for s in sessions { for h in s["g"] as? [String] ?? [] { byKey[h.hasPrefix("m:") ? h : String(h.prefix(7))] = s["id"] as? String } }
        return commits.map { c in
            if let o = byKey[String(c.h.prefix(7))] ?? byKey["m:" + commitKey(c.s)] { return o }
            guard let t = EchoTime.parse(c.d)?.timeIntervalSince1970 else { return nil }
            let day = EchoTime.formatted(Date(timeIntervalSince1970: t), "yyyy-MM-dd")
            var best: (String, Double)?
            for s in sessions where s["p"] as? String == c.p {
                guard let d = (s["days"] as? [String: [String: Any]])?[day], let a = d["a"] as? Double, let b = d["b"] as? Double,
                      t >= a - 600, t <= b + 600 else { continue }
                let tok = (d["k"] as? [String: [Double]] ?? [:]).values.reduce(0) { $0 + $1.reduce(0, +) }
                if best == nil || tok > best!.1 { best = (s["id"] as? String ?? "", tok) }
            }
            return best?.0
        }
    }

    /// 总览「备份」页的数：这台电脑各应用备份了几个会话、原会话多大（备份记录里记的大小）、备份多大（备份文件夹里的文件）、
    /// 几个会话的原文件已经不在了（Claude 清理、自动清理后只在备份里），加上上次备份时间和备份日志
    static func backupSummary(_ sessions: [EchoSession]) -> [String: Any] {
        let fm = FileManager.default, comp = EchoPrefs.computerDir, me = EchoPrefs.computerName
        var apps: [[String: Any]] = []
        let dirs: [(EchoSource, URL, URL)] = [(.claude, EchoLayout.claudeDirs(comp).first ?? EchoPrefs.claudeDir, EchoBackup.source),
                                              (.codex, EchoPrefs.codexDir, EchoBackup.codexSource)]
        for (src, dir, origin) in dirs {
            let rec = EchoBackupRecord.load(dir.appendingPathComponent("备份记录.json"))
            guard !rec.files.isEmpty else { continue }
            let srcBytes = rec.files.values.reduce(Int64(0)) { $0 + $1.size }
            var bak: Int64 = 0
            for case let u as URL in fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: .skipsHiddenFiles)?.allObjects ?? [] {
                if let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true { bak += Int64(v.fileSize ?? 0) }
            }
            // 原文件不在了的会话：Claude 看 <项目目录>/<会话>.jsonl；Codex 同一个会话可能在 sessions 和 archived_sessions 都记过，按文件名算
            var gone = 0
            if src == .claude {
                gone = rec.files.keys.filter { $0.hasSuffix(".jsonl") && $0.split(separator: "/").count == 2 && !fm.fileExists(atPath: origin.appendingPathComponent($0).path) }.count
            } else {
                var alive: [String: Bool] = [:]
                for k in rec.files.keys where k.contains("rollout-") {
                    let name = (k as NSString).lastPathComponent.replacingOccurrences(of: ".zst", with: "")
                    alive[name] = (alive[name] ?? false) || fm.fileExists(atPath: origin.appendingPathComponent(k).path)
                }
                gone = alive.values.filter { !$0 }.count
            }
            apps.append(["app": src.rawValue, "sessions": sessions.filter { $0.computer == me && $0.app == src }.count,
                         "src": srcBytes, "bak": bak, "gone": gone])
        }
        // 备份里各类内容各占多少（要把备份读一遍，几秒；总览在后台整理）
        let b = EchoStorage.backup(comp)
        let kinds = EchoStorage.Kind.allCases.map { ["k": $0.rawValue, "b": b.bytes[$0] ?? 0] as [String: Any] }
        var out: [String: Any] = ["apps": apps, "log": EchoBackupLog.load(comp), "kinds": kinds]
        if let d = EchoPrefs.lastSuccess { out["last"] = ISO8601DateFormatter().string(from: d) }
        return out
    }

    /// 上次整理好的总览：应用打开时先显示它，后台整理完再换
    private static var lastURL: URL { EchoLibrary.supportDir.appendingPathComponent("总览数据.json") }
    static func loadLast() -> Data? { try? Data(contentsOf: lastURL) }
}
