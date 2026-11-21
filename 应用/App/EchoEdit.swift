// 改名和合集。
// 改名写回原会话：在 ~/.claude 里的会话文件末尾追加一行 custom-title（和 Claude Code 自己 /rename 一样），已有的行一行不动；
// 会话目录里有 custom-title.json 时一并改。只能改本机的会话。
// 删除见文件末尾 EchoDelete。
// 合集：几个会话按时间连起来看，存在备份目录的 合集.json（iCloud 同步，两台电脑都能看到），原文件不动。
import Foundation

enum EchoRename {
    /// 本机会话在 ~/.claude 里的原文件；另一台电脑的会话、原文件已被删的返回 nil
    static func originalURL(for s: EchoSession) -> URL? {
        guard s.computer == EchoPrefs.computerName else { return nil }
        let u = EchoBackup.source.appendingPathComponent(s.url.deletingLastPathComponent().lastPathComponent)
            .appendingPathComponent(s.url.lastPathComponent)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// 2 分钟内还在写的会话：Claude Code 可能再写一次旧标题，把名字改回去
    static func isActive(_ url: URL) -> Bool {
        let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return m.map { Date().timeIntervalSince($0) < 120 } ?? false
    }

    /// 追加一行 custom-title。文件末尾不是换行（Claude Code 正写到一半）时不写，报错让用户稍后再试
    static func appendTitle(to url: URL, sessionId: String, title: String) throws {
        let t = title.trimmed
        guard !t.isEmpty else { return }
        let fh = try FileHandle(forUpdating: url)
        defer { try? fh.close() }
        let end = try fh.seekToEnd()
        if end > 0 {
            try fh.seek(toOffset: end - 1)
            guard try fh.read(upToCount: 1) == Data([0x0A]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "会话正在写入，稍后再试"])
            }
        }
        let line = "{\"type\":\"custom-title\",\"customTitle\":\(jsonString(t)),\"sessionId\":\(jsonString(sessionId))}\n"
        try fh.seekToEnd()
        try fh.write(contentsOf: Data(line.utf8))
        // 会话目录里的 custom-title.json 是同一个名字的副本，有才改
        let side = url.deletingPathExtension().appendingPathComponent("custom-title.json")
        if FileManager.default.fileExists(atPath: side.path) {
            try Data("{\"customTitle\":\(jsonString(t))}".utf8).write(to: side, options: .atomic)
        }
    }

    static func jsonString(_ s: String) -> String {
        let d = try! JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])
        return String(String(decoding: d, as: UTF8.self).dropFirst().dropLast())
    }
}

struct EchoCollection: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var title: String
    /// 会话相对备份目录的路径：<电脑名>/projects/<项目目录>/<会话ID>.jsonl，两台电脑都认得
    var members: [String]
    var created = Date()
}

enum EchoCollections {
    static func url(_ root: URL) -> URL { root.appendingPathComponent("合集.json") }

    static func load(_ root: URL) -> [EchoCollection] {
        guard let d = try? Data(contentsOf: url(root)) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([EchoCollection].self, from: d)) ?? []
    }

    static func save(_ list: [EchoCollection], _ root: URL) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(list).write(to: url(root), options: .atomic)
    }

    static func key(_ s: EchoSession, root: URL) -> String {
        String(s.url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
    }

    /// 合集里还在的会话，按开始时间排
    static func sessions(_ c: EchoCollection, in all: [EchoSession], root: URL) -> [EchoSession] {
        let byKey = Dictionary(all.map { (key($0, root: root), $0) }, uniquingKeysWith: { a, _ in a })
        return c.members.compactMap { byKey[$0] }.sorted { $0.meta.start < $1.meta.start }
    }
}

extension EchoExport {
    /// 合集：每个会话前加一条「会话」分隔，按开始时间接起来
    static func exportCollection(_ parts: [(url: URL, computer: String)], id: String, title: String) throws -> [String: Any] {
        var exported = try parts.map { p -> [String: Any] in try export(p.url, computer: p.computer) }
        exported.sort { (($0["meta"] as! [String: Any])["start"] as! String) < (($1["meta"] as! [String: Any])["start"] as! String) }
        var turns: [Any] = []
        var computers: [String] = []
        for e in exported {
            let m = e["meta"] as! [String: Any]
            turns.append(["role": "session", "ts": m["start"]!, "text": m["title"]!, "computer": m["computer"]!])
            turns.append(contentsOf: e["turns"] as! [Any])
            if let c = m["computer"] as? String, !computers.contains(c) { computers.append(c) }
        }
        let metas = exported.map { $0["meta"] as! [String: Any] }
        let meta: [String: Any] = [
            "id": id, "title": title, "aiTitle": "", "kind": "collection", "count": exported.count,
            "cwd": metas.first?["cwd"] ?? "", "gitBranch": "",
            "start": metas.compactMap { $0["start"] as? String }.filter { !$0.isEmpty }.min() ?? "",
            "end": metas.compactMap { $0["end"] as? String }.max() ?? "",
            "computer": computers.joined(separator: "、"),
        ]
        return ["meta": meta, "turns": turns]
    }
}

/// 删除：原会话和备份一起移到废纸篓（能放回）。会话文件和同名目录（子代理、长工具输出）一起移，备份记录里去掉。
/// 只删本机的会话；2 分钟内还在写的不删。
enum EchoDelete {
    struct Paths {
        var original: URL          // ~/.claude/projects/<项目目录>/<会话ID>.jsonl
        var backup: URL            // 备份/<电脑名>/projects/<项目目录>/<会话ID>.jsonl
        var record: URL            // 备份/<电脑名>/备份记录.json
        var rel: String            // <项目目录>/<会话ID>.jsonl
    }

    static func paths(for s: EchoSession) -> Paths? {
        guard let orig = EchoRename.originalURL(for: s) else { return nil }
        let rel = s.url.deletingLastPathComponent().lastPathComponent + "/" + s.url.lastPathComponent
        return Paths(original: orig, backup: s.url, record: EchoPrefs.computerDir.appendingPathComponent("备份记录.json"), rel: rel)
    }

    /// remove 默认移到废纸篓，测试时换成移到临时目录
    static func trash(_ p: Paths, remove: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws {
        let fm = FileManager.default
        if EchoRename.isActive(p.original) {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "会话正在进行，结束后再删"])
        }
        for f in [p.original, p.backup] {
            let dir = f.deletingPathExtension()
            if fm.fileExists(atPath: f.path) { try remove(f) }
            if fm.fileExists(atPath: dir.path) { try remove(dir) }
        }
        var r = EchoBackupRecord.load(p.record)
        let prefix = String(p.rel.dropLast(6)) + "/"
        r.files = r.files.filter { $0.key != p.rel && !$0.key.hasPrefix(prefix) }
        try? r.save(p.record)
    }
}
