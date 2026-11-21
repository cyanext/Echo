// 会话列表：读备份目录下所有电脑的会话，按项目（cwd）归组。
// 每个会话的标题、时间、项目路径要扫一遍文件才知道，按「路径 + 大小 + 修改时间」缓存在 ~/Library/Application Support/回响/。
import Foundation

struct EchoSessionMeta: Codable, Hashable {
    var title = "", cwd = "", start = "", end = ""
}

struct EchoSession: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let sessionId: String
    let computer: String
    let size: Int64
    let meta: EchoSessionMeta
    var endDate: Date? { EchoTime.parse(meta.end) }
    var projectPath: String { meta.cwd.isEmpty ? url.deletingLastPathComponent().lastPathComponent : meta.cwd }
}

struct EchoProject: Identifiable, Hashable {
    var id: String { path }
    let path: String
    var name: String { (path as NSString).lastPathComponent }
    let sessions: [EchoSession]
    var last: Date? { sessions.first?.endDate }
}

/// 第一级目录：大目录里直接开的会话，加它下面的项目
struct EchoCategory: Identifiable, Hashable {
    var id: String { path }
    let path: String
    var name: String { (path as NSString).lastPathComponent }
    let root: [EchoSession]
    let projects: [EchoProject]
    var count: Int { root.count + projects.reduce(0) { $0 + $1.sessions.count } }
    var last: Date? { ([root.first?.endDate] + projects.map(\.last)).compactMap { $0 }.max() }
    var all: [EchoSession] { root + projects.flatMap(\.sessions) }
}

enum EchoTime {
    nonisolated(unsafe) private static let frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()
    static func parse(_ s: String) -> Date? { s.isEmpty ? nil : frac.date(from: s) ?? plain.date(from: s) }

    static func formatted(_ d: Date, _ fmt: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = fmt
        return f.string(from: d)
    }

    /// 今天 14:05；11月18日 14:05；2025年3月2日
    static func short(_ d: Date?) -> String {
        guard let d else { return "" }
        let cal = Calendar.current, f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        if cal.isDateInToday(d) { f.dateFormat = "今天 HH:mm" }
        else if cal.isDateInYesterday(d) { f.dateFormat = "昨天 HH:mm" }
        else if cal.isDate(d, equalTo: Date(), toGranularity: .year) { f.dateFormat = "M月d日 HH:mm" }
        else { f.dateFormat = "yyyy年M月d日" }
        return f.string(from: d)
    }
}

enum EchoSessionScan {
    private static let needleTs = Array("\"timestamp\":\"".utf8)
    private static let needleCwd = Array("\"cwd\":\"".utf8)
    private static let needleUser = Array("\"type\":\"user\"".utf8)
    private static let needleTitles = ["\"type\":\"custom-title\"", "\"type\":\"ai-title\""].map { Array($0.utf8) }

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
    static var supportDir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("回响")
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
        let computers = (try? fm.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        for c in computers {
            let projects = c.appendingPathComponent("projects")
            for p in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
                let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
                for f in (try? fm.contentsOfDirectory(at: p, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)) ?? [] where f.pathExtension == "jsonl" {
                    guard let v = try? f.resourceValues(forKeys: keys) else { continue }
                    let stamp = EchoFileStamp(size: Int64(v.fileSize ?? 0), mtime: v.contentModificationDate?.timeIntervalSince1970 ?? 0)
                    var meta: EchoSessionMeta
                    if let e = cache.entries[f.path], e.stamp == stamp { meta = e.meta }
                    else if let m = try? EchoSessionScan.read(f) { meta = m }
                    else { continue }
                    fresh.entries[f.path] = .init(stamp: stamp, meta: meta)
                    if meta.start.isEmpty { continue }   // 一条对话都没有的空会话不列
                    out.append(EchoSession(url: f, sessionId: String(f.lastPathComponent.dropLast(6)), computer: c.lastPathComponent, size: stamp.size, meta: meta))
                }
            }
        }
        cache = fresh
        if let d = try? JSONEncoder().encode(cache) { try? d.write(to: cacheURL, options: .atomic) }
        return out
    }

    /// 二级分类：第一级是大目录（~/Desktop/项目代码、~/伙伴云NAS/客户文档），第二级是它下面的项目文件夹；
    /// 更深的子目录归到所在项目（NAS/NAS网站 算 NAS，回响/.worktrees/v0.1.0 算回响）。直接在大目录里开的会话不进项目
    static func place(_ cwd: String) -> (category: String, project: String?) {
        let home = NSHomeDirectory()
        let under = cwd == home || cwd.hasPrefix(home + "/")
        let rest = under ? String(cwd.dropFirst(home.count)) : cwd
        let comps = rest.split(separator: "/").map(String.init)
        let base = under ? home : ""
        func join(_ n: Int) -> String { base + "/" + comps.prefix(n).joined(separator: "/") }
        if comps.count < 2 { return (comps.isEmpty ? (under ? home : "/") : join(comps.count), nil) }
        return (join(2), comps.count >= 3 ? join(3) : nil)
    }

    static func tree(_ sessions: [EchoSession]) -> [EchoCategory] {
        let byEnd: (EchoSession, EchoSession) -> Bool = { ($0.endDate ?? .distantPast) > ($1.endDate ?? .distantPast) }
        var cats: [String: (root: [EchoSession], projects: [String: [EchoSession]])] = [:]
        for s in sessions {
            let (c, p) = place(s.projectPath)
            if let p { cats[c, default: ([], [:])].projects[p, default: []].append(s) }
            else { cats[c, default: ([], [:])].root.append(s) }
        }
        return cats.map { c, v in
            EchoCategory(path: c, root: v.root.sorted(by: byEnd),
                         projects: v.projects.map { EchoProject(path: $0.key, sessions: $0.value.sorted(by: byEnd)) }
                            .sorted { ($0.last ?? .distantPast) > ($1.last ?? .distantPast) })
        }
        .sorted { ($0.last ?? .distantPast) > ($1.last ?? .distantPast) }
    }

    /// 按项目归组；项目按最近使用排序，会话按最后时间倒序
    static func group(_ sessions: [EchoSession]) -> [EchoProject] {
        Dictionary(grouping: sessions, by: \.projectPath)
            .map { EchoProject(path: $0.key, sessions: $0.value.sorted { ($0.endDate ?? .distantPast) > ($1.endDate ?? .distantPast) }) }
            .sorted { ($0.last ?? .distantPast) > ($1.last ?? .distantPast) }
    }
}
