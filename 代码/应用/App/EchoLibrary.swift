// 会话列表：读备份目录下所有电脑的会话，按会话目录（cwd）排成多级目录树。
// 每个会话的标题、时间、项目路径要扫一遍文件才知道，按「路径 + 大小 + 修改时间」缓存在 ~/Library/Application Support/回响/。
import Foundation

struct EchoSessionMeta: Codable, Hashable {
    var title = "", cwd = "", start = "", end = ""
    var sid: String?       // Codex：session_meta 里的会话 ID（Claude 的会话 ID 就是文件名）
    var sub: Bool?         // Codex：子代理的会话（自动审批 guardian、分派的子任务），照样备份，列表里不显示
}

struct EchoSession: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let sessionId: String
    let computer: String
    let size: Int64
    let meta: EchoSessionMeta
    var app: EchoSource = .claude
    var endDate: Date? { EchoTime.parse(meta.end) }
    var projectPath: String { meta.cwd.isEmpty ? url.deletingLastPathComponent().lastPathComponent : meta.cwd }
}

/// 目录树的一级：名字（合成一行时是「上级 / 下级」）、子目录、直接在这一级开的会话
struct EchoDir: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    let children: [EchoDir]
    let sessions: [EchoSession]
    var count: Int { sessions.count + children.reduce(0) { $0 + $1.count } }
    var last: Date? { ([sessions.first?.endDate] + children.map(\.last)).compactMap { $0 }.max() }
    var all: [EchoSession] { sessions + children.flatMap(\.all) }
    func contains(_ id: String?) -> Bool { id != nil && (sessions.contains { $0.id == id } || children.contains { $0.contains(id) }) }
}

/// 会话目录拆成各级名字：家目录下的去掉家目录；以「.」开头的目录（.worktrees、.claude）和它下面的算进上一级。
/// 左栏目录树、总览的项目归类共用这一套
enum EchoPath {
    static func parts(_ path: String) -> (home: Bool, comps: [String]) {
        let home = NSHomeDirectory()
        let under = path == home || path.hasPrefix(home + "/")
        var comps = (under ? String(path.dropFirst(home.count)) : path).split(separator: "/").map(String.init)
        if let dot = comps.firstIndex(where: { $0.hasPrefix(".") }), dot >= 2 { comps = Array(comps[..<dot]) }
        return (under, comps)
    }
}

/// 多个文件同时处理：并发算每一项，结果按原顺序。f 要线程安全
enum EchoParallel {
    static func map<T, R>(_ items: [T], _ f: (T) -> R) -> [R] {
        var out = [R?](repeating: nil, count: items.count)
        out.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: items.count) { buf[$0] = f(items[$0]) }
        }
        return out.map { $0! }
    }
}

enum EchoTime {
    nonisolated(unsafe) private static let frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()
    /// Claude Code 的时间「2026-11-04T11:41:10.072Z」按位置取数字直接算（fastEpoch），别的格式才用格式器：
    /// 格式器要拿 ICU 的全局锁，几十万行并发处理时线程全卡在锁上（11-22 实测总览冷启动 15 秒，换掉后 1 秒）
    static func parse(_ s: String) -> Date? {
        if s.isEmpty { return nil }
        if let t = fastEpoch(s) { return Date(timeIntervalSince1970: t) }
        return frac.date(from: s) ?? plain.date(from: s)
    }

    /// 只认「YYYY-MM-DDTHH:MM:SS[.小数]Z」，认不出返回 nil
    static func fastEpoch(_ s: String) -> Double? {
        let u = Array(s.utf8)
        func num(_ i: Int, _ n: Int) -> Int? {
            var v = 0
            for k in i..<i + n { let c = u[k]; guard c >= 48, c <= 57 else { return nil }; v = v * 10 + Int(c - 48) }
            return v
        }
        guard u.count >= 20, u[4] == 45, u[7] == 45, u[10] == 84, u[13] == 58, u[16] == 58,
              let y = num(0, 4), let m = num(5, 2), let d = num(8, 2), let H = num(11, 2), let M = num(14, 2), let S = num(17, 2),
              (1...12).contains(m), (1...31).contains(d), H < 24, M < 60, S < 61 else { return nil }
        var i = 19, frac = 0.0
        if u[i] == 46 {
            var scale = 0.1
            i += 1
            while i < u.count, u[i] >= 48, u[i] <= 57 { frac += Double(u[i] - 48) * scale; scale /= 10; i += 1 }
        }
        guard i == u.count - 1, u[i] == 90 else { return nil }
        return Double(daysFromCivil(y, m, d) * 86400 + H * 3600 + M * 60 + S) + frac
    }

    /// 公历日期到 1970-01-01 的天数（Howard Hinnant 的算法）
    static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    static func formatted(_ d: Date, _ fmt: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = fmt
        return f.string(from: d)
    }

    /// 今天 14:05；11月18日 14:05；2025年3月2日
    /// 左栏每行都调，格式器建一次反复用（每次新建很慢，拖动排序后重画会卡）
    nonisolated(unsafe) private static let shortFormats: [DateFormatter] = ["今天 HH:mm", "昨天 HH:mm", "M月d日 HH:mm", "yyyy年M月d日"].map {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = $0; return f
    }

    static func short(_ d: Date?) -> String {
        guard let d else { return "" }
        let cal = Calendar.current
        let i = cal.isDateInToday(d) ? 0 : cal.isDateInYesterday(d) ? 1 : cal.isDate(d, equalTo: Date(), toGranularity: .year) ? 2 : 3
        return shortFormats[i].string(from: d)
    }
}

enum EchoSessionScan {
    private static let needleTs = Array("\"timestamp\":\"".utf8)
    private static let needleCwd = Array("\"cwd\":\"".utf8)
    private static let needleUser = Array("\"type\":\"user\"".utf8)
    private static let needleTitles = ["\"type\":\"custom-title\"", "\"type\":\"ai-title\""].map { Array($0.utf8) }

    private static let needleCodexUser = Array("\"role\":\"user\"".utf8), needleCodexAsst = Array("\"role\":\"assistant\"".utf8)
    private static let needleMeta = Array("\"type\":\"session_meta\"".utf8)

    /// Codex 的会话：项目路径、会话 ID 取 session_meta；起止时间、第一句话和 EchoExport.exportCodex 一致。标题在扫列表时另按 session_index.jsonl 换
    static func readCodex(_ url: URL) throws -> EchoSessionMeta {
        var m = EchoSessionMeta(), firstUser = ""
        try EchoLines.each(url) { line in
            let b = EchoLines.trim(line)
            if m.sid == nil, EchoLines.has(b, needleMeta), let d = json(b), let p = d["payload"] as? [String: Any] {
                m.sid = p["id"] as? String ?? ""
                m.cwd = p["cwd"] as? String ?? ""
                m.sub = !(p["source"] is String)   // 子代理的 source 是 {"subagent": …}
                return
            }
            let isUser = EchoLines.has(b, needleCodexUser)
            guard isUser || EchoLines.has(b, needleCodexAsst), EchoLines.has(b, needleTs) else { return }
            guard let d = json(b), d["type"] as? String == "response_item", let p = d["payload"] as? [String: Any], p["type"] as? String == "message" else { return }
            let ts = d["timestamp"] as? String ?? ""
            if p["role"] as? String == "user" {
                let (human, system) = EchoExport.codexUserParts(p)
                guard !human.isEmpty || !system.isEmpty else { return }
                if m.start.isEmpty { m.start = ts }
                m.end = ts
                if firstUser.isEmpty, !human.isEmpty { firstUser = human.prefix40 }
            } else if !ts.isEmpty, p["role"] as? String == "assistant" { m.end = ts }
        }
        m.title = !firstUser.isEmpty ? firstUser : m.sid ?? ""
        return m
    }

    /// Codex 改过、起过的名字：session_index.jsonl 每行 {id, thread_name}，同一个会话取最后一行
    static func codexTitles(_ codexDir: URL) -> [String: String] {
        var out: [String: String] = [:]
        try? EchoLines.each(codexDir.appendingPathComponent("session_index.jsonl")) { line in
            guard let d = json(EchoLines.trim(line)), let id = d["id"] as? String, let n = d["thread_name"] as? String, !n.isEmpty else { return }
            out[id] = n
        }
        return out
    }

    /// 扫一遍文件取标题、项目路径、起止时间，规则和 EchoExport 一致（标题：用户改的 > AI 起的 > 第一句话）
    static func read(_ url: URL) throws -> EchoSessionMeta {
        var m = EchoSessionMeta(), custom = "", ai = "", firstUser = ""
        try EchoLines.each(url) { line in
            let b = EchoLines.trim(line)
            if needleTitles.contains(where: { EchoLines.has(b, $0) }) {
                if let d = json(b) {
                    if d["type"] as? String == "custom-title" { custom = d["customTitle"] as? String ?? "" }
                    if d["type"] as? String == "ai-title" { ai = d["aiTitle"] as? String ?? "" }
                }
                return
            }
            guard EchoLines.has(b, needleTs) else { return }
            let isUser = EchoLines.has(b, needleUser)
            guard isUser || EchoLines.has(b, Array("\"type\":\"assistant\"".utf8)) else { return }
            if m.cwd.isEmpty || (isUser && firstUser.isEmpty) || m.start.isEmpty, let d = json(b) {
                if m.cwd.isEmpty { m.cwd = d["cwd"] as? String ?? "" }
                if m.start.isEmpty { m.start = d["timestamp"] as? String ?? "" }
                if isUser, firstUser.isEmpty, let (role, text) = EchoExport.userRole(d), role == "user" { firstUser = text.prefix40 }
            }
            if let ts = value(after: needleTs, in: b) { m.end = ts }
        }
        m.title = !custom.isEmpty ? custom : !ai.isEmpty ? ai : !firstUser.isEmpty ? firstUser : String(url.lastPathComponent.dropLast(6))
        return m
    }

    private static func json(_ b: UnsafeBufferPointer<UInt8>) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(buffer: b)) as? [String: Any]
    }

    /// 取 "key":"值" 里的值（时间戳这类不含引号的短字符串）
    private static func value(after needle: [UInt8], in b: UnsafeBufferPointer<UInt8>) -> String? {
        guard let base = b.baseAddress else { return nil }
        let hit = needle.withUnsafeBufferPointer { memmem(base, b.count, $0.baseAddress!, needle.count) }
        guard let hit else { return nil }
        let start = base.distance(to: hit.assumingMemoryBound(to: UInt8.self)) + needle.count
        var end = start
        while end < b.count, b[end] != UInt8(ascii: "\""), end - start < 64 { end += 1 }
        return String(decoding: UnsafeBufferPointer(rebasing: b[start..<end]), as: UTF8.self)
    }
}

/// 列表缓存：路径 → 大小、修改时间、整理出的信息
private struct EchoScanCache: Codable {
    struct Entry: Codable { var stamp: EchoFileStamp; var meta: EchoSessionMeta }
    var entries: [String: Entry] = [:]
}

enum EchoLibrary {
    /// 本机缓存和暂存目录。测试程序（-D TEST）用临时目录，免得把测试数据写进回响真实的缓存和「上次的总览」
    static var supportDir: URL {
        #if TEST
        let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("回响测试")
        #else
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("回响")
        #endif
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// 备份目录下每台电脑的主会话（子代理的会话第一版不显示）。同步执行，放在后台线程调用
    static func scan(backupRoot: URL) -> [EchoSession] {
        let fm = FileManager.default
        let cacheURL = supportDir.appendingPathComponent("会话列表缓存.json")
        var cache = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode(EchoScanCache.self, from: $0) } ?? EchoScanCache()
        var fresh = EchoScanCache()
        var out: [EchoSession] = []
        // 只跳过名字以「.」开头的，不按系统的隐藏标记跳：备份改名后可能还带着临时文件的隐藏标记（11-21 本会话就这样从列表里消失过）
        func list(_ u: URL, _ keys: [URLResourceKey]? = nil) -> [URL] {
            ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: keys)) ?? []).filter { !$0.lastPathComponent.hasPrefix(".") }
        }
        // 先列出所有会话文件，缓存里没有或变了的并发读（第一次打开时一百多个文件）
        struct Item { let f: URL; let c: URL; let stamp: EchoFileStamp; let moved: [String: String]; var app: EchoSource = .claude }
        var items: [Item] = []
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        for c in list(backupRoot, [.isDirectoryKey]) {
            // Claude 的备份在 claude/projects，没升级的电脑还在电脑这一级的 projects；两处都有同一个会话时用 claude/ 里的
            var seen = Set<String>()
            for r in EchoLayout.sessionRoots(c) where r.source == .claude {
                let moved = EchoMoved.load(r.root.deletingLastPathComponent())   // 挪过文件夹的会话按新文件夹显示
                for p in list(r.root) {
                    for f in list(p, Array(keys)) where f.pathExtension == "jsonl" {
                        guard seen.insert(f.lastPathComponent).inserted, let v = try? f.resourceValues(forKeys: keys) else { continue }
                        items.append(Item(f: f, c: c, stamp: EchoFileStamp(size: Int64(v.fileSize ?? 0), mtime: v.contentModificationDate?.timeIntervalSince1970 ?? 0), moved: moved))
                    }
                }
            }
            // Codex：codex/sessions/年/月/日/rollout-….jsonl
            for r in EchoLayout.sessionRoots(c) where r.source == .codex {
                let en = fm.enumerator(at: r.root, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)
                for case let f as URL in en?.allObjects ?? [] where f.pathExtension == "jsonl" {
                    guard let v = try? f.resourceValues(forKeys: keys) else { continue }
                    items.append(Item(f: f, c: c, stamp: EchoFileStamp(size: Int64(v.fileSize ?? 0), mtime: v.contentModificationDate?.timeIntervalSince1970 ?? 0), moved: [:], app: .codex))
                }
            }
        }
        var titles: [String: [String: String]] = [:]   // 电脑 → Codex 的会话名
        for it in items where it.app == .codex && titles[it.c.path] == nil { titles[it.c.path] = EchoSessionScan.codexTitles(EchoLayout.dir(it.c, .codex)) }
        let metas = EchoParallel.map(items) { it -> EchoSessionMeta? in
            if let e = cache.entries[it.f.path], e.stamp == it.stamp { return e.meta }
            return try? (it.app == .codex ? EchoSessionScan.readCodex(it.f) : EchoSessionScan.read(it.f))
        }
        for (it, m) in zip(items, metas) {
            guard var meta = m else { continue }
            fresh.entries[it.f.path] = .init(stamp: it.stamp, meta: meta)
            if meta.start.isEmpty || meta.sub == true { continue }   // 一条对话都没有的空会话、Codex 的子代理会话不列
            let sid = meta.sid ?? String(it.f.lastPathComponent.dropLast(6))
            if let cwd = it.moved[sid] { meta.cwd = cwd }
            if it.app == .codex, let t = titles[it.c.path]?[sid] { meta.title = t }
            out.append(EchoSession(url: it.f, sessionId: sid, computer: it.c.lastPathComponent, size: it.stamp.size, meta: meta, app: it.app))
        }
        cache = fresh
        if let d = try? JSONEncoder().encode(cache) { try? d.write(to: cacheURL, options: .atomic) }
        return out
    }

    /// 多级目录（规范「组件」目录树）：第一级是大目录（~/Desktop/项目代码、~/伙伴云NAS/客户文档 这一级，跳过 Desktop 这类外层），
    /// 下面按真实目录一级级往下；以「.」开头的目录（.worktrees、.claude）算进它的上一级。
    /// 只有一个子目录、自己又没有会话的层级合成一行，名字写成「上级 / 下级」
    static func dirTree(_ sessions: [EchoSession]) -> [EchoDir] {
        final class Node {
            let path: String, name: String
            var kids: [String: Node] = [:], sessions: [EchoSession] = []
            init(_ path: String, _ name: String) { self.path = path; self.name = name }
        }
        var roots: [String: Node] = [:]
        for s in sessions {
            let (under, comps) = EchoPath.parts(s.projectPath)
            let base = under ? NSHomeDirectory() : ""
            let head = comps.count >= 2 ? 2 : comps.count
            let rootPath = base + "/" + comps.prefix(head).joined(separator: "/")
            let root = roots[rootPath] ?? Node(rootPath, comps.prefix(head).last ?? "~")
            roots[rootPath] = root
            var node = root, path = rootPath
            for c in comps.dropFirst(head) {
                path += "/" + c
                let next = node.kids[c] ?? Node(path, c)
                node.kids[c] = next
                node = next
            }
            node.sessions.append(s)
        }
        let byEnd: (EchoSession, EchoSession) -> Bool = { ($0.endDate ?? .distantPast) > ($1.endDate ?? .distantPast) }
        func build(_ n: Node, top: Bool) -> EchoDir {
            var d = EchoDir(path: n.path, name: n.name,
                            children: n.kids.values.map { build($0, top: false) }.sorted { ($0.last ?? .distantPast) > ($1.last ?? .distantPast) },
                            sessions: n.sessions.sorted(by: byEnd))
            if !top, d.sessions.isEmpty, d.children.count == 1 {   // 中间一层只有一个子目录：合成一行
                let c = d.children[0]
                d = EchoDir(path: c.path, name: d.name + " / " + c.name, children: c.children, sessions: c.sessions)
            }
            return d
        }
        return roots.values.map { build($0, top: true) }.sorted { ($0.last ?? .distantPast) > ($1.last ?? .distantPast) }
    }
}

/// 左栏目录的手动顺序：拖动排好的顺序记在本机，每一级一个列表，按目录路径记。组名：顶层目录「/」，子目录用上一级目录的路径。
/// 没排过的（新出现的）按最近用过排在前面，排过的跟在后面按记的顺序。会话不排，只按最近用过
enum EchoOrder {
    static func arrange(_ dirs: [EchoDir], _ order: [String: [String]], group: String = "/") -> [EchoDir] {
        sorted(dirs, order[group], key: \.path).map { d in
            EchoDir(path: d.path, name: d.name, children: arrange(d.children, order, group: d.path), sessions: d.sessions)
        }
    }

    static func sorted<T>(_ items: [T], _ keys: [String]?, key: (T) -> String) -> [T] {
        guard let keys, !keys.isEmpty else { return items }
        let pos = Dictionary(keys.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return items.filter { pos[key($0)] == nil } + items.filter { pos[key($0)] != nil }.sorted { pos[key($0)]! < pos[key($1)]! }
    }

    /// 只重排一级，其余原样：拖完排序时用，不用把整棵树按全部顺序再排一遍。只往这一级所在的那条路径上走
    static func apply(_ dirs: [EchoDir], group: String, keys: [String]) -> [EchoDir] {
        if group == "/" { return sorted(dirs, keys, key: \.path) }
        return dirs.map { d in
            if d.path == group { return EchoDir(path: d.path, name: d.name, children: sorted(d.children, keys, key: \.path), sessions: d.sessions) }
            let base = d.path.hasSuffix("/") ? d.path : d.path + "/"
            guard group.hasPrefix(base) else { return d }
            return EchoDir(path: d.path, name: d.name, children: apply(d.children, group: group, keys: keys), sessions: d.sessions)
        }
    }

    /// 把 moving 这几项挪到 target 前面（after 为真时后面），其余相对顺序不变；返回整组新顺序
    static func move(_ keys: [String], moving: [String], to target: String, after: Bool) -> [String] {
        let set = Set(moving)
        guard !set.contains(target) else { return keys }
        var rest = keys.filter { !set.contains($0) }
        guard let i = rest.firstIndex(of: target) else { return keys }
        rest.insert(contentsOf: keys.filter { set.contains($0) }, at: after ? i + 1 : i)
        return rest
    }
}
