// 总览的数：每个会话每天的我的消息、AI 干活时长、各模型的 Token；每个项目的 Git 提交。
// 只读：会话读备份，Git 只跑 log。整理成 JSON 交给 Web/overview.js 算周、比较、折合美元（单价在 Web/prices.json）。
// 口径见 设计/总览/说明.md「数怎么算」。
import Foundation

/// 一个会话一天的数
struct EchoDayStat: Codable, Equatable {
    var m = 0                         // 我的消息条数
    var ms = 0.0                      // AI 干活毫秒数（turn_duration 相加）
    var lg = 0.0                      // 最长一轮毫秒数
    var k: [String: [Double]] = [:]   // 模型 → [输入, 输出, 读缓存, 写缓存 5 分钟, 写缓存 1 小时]
}

private struct EchoStatsCache: Codable {
    struct Entry: Codable { var stamp: EchoFileStamp; var days: [String: EchoDayStat] }
    var entries: [String: Entry] = [:]
}

enum EchoStats {
    private static let needleUser = Array("\"type\":\"user\"".utf8)
    private static let needleAsst = Array("\"type\":\"assistant\"".utf8)
    private static let needleUsage = Array("\"usage\"".utf8)
    private static let needleTurn = Array("\"turn_duration\"".utf8)

    /// 本机时区的「年-月-日」
    static func dayKey(_ ts: String) -> String? {
        guard let d = EchoTime.parse(ts) else { return nil }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// 读一个会话文件，按天汇总。同一次回复拆成几行记录，按 requestId 去重
    static func read(_ url: URL) throws -> [String: EchoDayStat] {
        var days: [String: EchoDayStat] = [:], seen = Set<String>()
        try EchoLines.each(url) { line in
            let b = EchoLines.trim(line)
            let isUser = EchoLines.has(b, needleUser)
            let isUsage = !isUser && EchoLines.has(b, needleAsst) && EchoLines.has(b, needleUsage)
            let isTurn = !isUser && !isUsage && EchoLines.has(b, needleTurn)
            guard isUser || isUsage || isTurn,
                  let d = try? JSONSerialization.jsonObject(with: Data(buffer: b)) as? [String: Any],
                  let ts = d["timestamp"] as? String, let day = dayKey(ts) else { return }
            if isUser {
                guard d["type"] as? String == "user", EchoExport.userRole(d)?.role == "user" else { return }
                days[day, default: .init()].m += 1
            } else if isUsage {
                guard d["type"] as? String == "assistant", let msg = d["message"] as? [String: Any],
                      let u = msg["usage"] as? [String: Any] else { return }
                let rid = d["requestId"] as? String ?? msg["id"] as? String ?? UUID().uuidString
                guard seen.insert(rid).inserted else { return }
                let model = msg["model"] as? String ?? "?"
                guard model != "<synthetic>" else { return }
                func n(_ k: String) -> Double { (u[k] as? NSNumber)?.doubleValue ?? 0 }
                let cc = u["cache_creation"] as? [String: Any]
                var w5 = (cc?["ephemeral_5m_input_tokens"] as? NSNumber)?.doubleValue ?? 0
                let w1 = (cc?["ephemeral_1h_input_tokens"] as? NSNumber)?.doubleValue ?? 0
                w5 += max(0, n("cache_creation_input_tokens") - w5 - w1)
                let add = [n("input_tokens"), n("output_tokens"), n("cache_read_input_tokens"), w5, w1]
                var s = days[day, default: .init()]
                s.k[model] = zip(s.k[model] ?? [0, 0, 0, 0, 0], add).map { $0 + $1 }
                days[day] = s
            } else {
                guard d["subtype"] as? String == "turn_duration", let ms = (d["durationMs"] as? NSNumber)?.doubleValue else { return }
                var s = days[day, default: .init()]
                s.ms += ms
                s.lg = max(s.lg, ms)
                days[day] = s
            }
        }
        return days
    }

    /// 会话归到哪个项目：和左栏目录树同一套路径，取大目录下面那一级（~/Desktop/项目代码/NAS/伙伴云NAS应用 → NAS）；
    /// 以「.」开头的目录（.worktrees）算进上一级
    static func project(_ path: String) -> String {
        let home = NSHomeDirectory()
        let under = path == home || path.hasPrefix(home + "/")
        var comps = (under ? String(path.dropFirst(home.count)) : path).split(separator: "/").map(String.init)
        if let dot = comps.firstIndex(where: { $0.hasPrefix(".") }), dot >= 2 { comps = Array(comps[..<dot]) }
        return comps.count >= 3 ? comps[2] : comps.last ?? "~"
    }

    // MARK: Git

    struct Commit: Codable { var p: String; var d: String; var s: String; var a: Int; var r: Int; var f: [String] }

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

    /// 会话所在目录里的 Git 仓库，从 since 起的提交（不含合并提交）；同一个提交在几个工作区只算一次
    static func commits(cwds: Set<String>, since: String) -> [Commit] {
        let fm = FileManager.default
        var repos = Set<String>()
        for c in cwds where fm.fileExists(atPath: c) {
            let top = git(["-C", c, "rev-parse", "--show-toplevel"]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !top.isEmpty { repos.insert(top) }
        }
        var seen = Set<String>(), out: [Commit] = []
        for r in repos.sorted() {
            let log = git(["-C", r, "log", "--all", "--no-merges", "--since=\(since)", "--date=iso-strict",
                           "--pretty=format:%x1e%H%x1f%aI%x1f%s", "--numstat"])
            for rec in log.split(separator: "\u{1e}") {
                let lines = rec.split(separator: "\n", omittingEmptySubsequences: true)
                guard let head = lines.first else { continue }
                let f = head.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
                guard f.count >= 3, seen.insert(f[0]).inserted else { continue }
                var c = Commit(p: project(r), d: f[1], s: f[2], a: 0, r: 0, f: [])
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
    static func build(_ sessions: [EchoSession]) -> Data {
        let cacheURL = EchoLibrary.supportDir.appendingPathComponent("总览缓存.json")
        let cache = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode(EchoStatsCache.self, from: $0) } ?? EchoStatsCache()
        var fresh = EchoStatsCache()
        var list: [[String: Any]] = []
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        for s in sessions {
            guard let v = try? s.url.resourceValues(forKeys: keys) else { continue }
            let stamp = EchoFileStamp(size: Int64(v.fileSize ?? 0), mtime: v.contentModificationDate?.timeIntervalSince1970 ?? 0)
            let days: [String: EchoDayStat]
            if let e = cache.entries[s.url.path], e.stamp == stamp { days = e.days }
            else if let d = try? read(s.url) { days = d }
            else { continue }
            fresh.entries[s.url.path] = .init(stamp: stamp, days: days)
            guard !days.isEmpty else { continue }
            let dict = days.mapValues { d -> [String: Any] in ["m": d.m, "ms": d.ms, "lg": d.lg, "k": d.k] }
            list.append(["id": s.id, "t": s.meta.title == s.sessionId ? "未命名会话" : s.meta.title,
                         "p": project(s.projectPath), "c": s.computer, "days": dict])
        }
        if let d = try? JSONEncoder().encode(fresh) { try? d.write(to: cacheURL, options: .atomic) }

        // Git：只看本机会话的目录，从最早有会话的那天起，最多半年
        let first = list.flatMap { ($0["days"] as? [String: Any])?.keys.map { $0 } ?? [] }.min() ?? ""
        let half = Calendar.current.date(byAdding: .month, value: -6, to: Date())!
        let since = max(first, String(EchoTime.formatted(half, "yyyy-MM-dd")))
        let cwds = Set(sessions.filter { $0.computer == EchoPrefs.computerName }.map(\.meta.cwd).filter { !$0.isEmpty })
        let commits = first.isEmpty ? [] : self.commits(cwds: cwds, since: since)
        let gitList = commits.map { ["p": $0.p, "d": $0.d, "s": $0.s, "a": $0.a, "r": $0.r, "f": $0.f] as [String: Any] }

        let out: [String: Any] = ["today": EchoTime.formatted(Date(), "yyyy-MM-dd"), "sessions": list, "commits": gitList]
        return (try? JSONSerialization.data(withJSONObject: out)) ?? Data("{}".utf8)
    }
}
