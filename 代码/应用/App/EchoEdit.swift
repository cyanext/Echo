// 改名和合集。
// 改名写回原会话：在 ~/.claude 里的会话文件末尾追加一行 custom-title（和 Claude Code 自己 /rename 一样），已有的行一行不动；
// 会话目录里有 custom-title.json 时一并改。只能改本机的会话。
// 删除、移动见文件末尾 EchoDelete、EchoMove。
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

/// 移动：把本机会话挪到另一个文件夹，规则见 CLAUDE.md「数据安全」。
/// Claude Code 按工作目录把会话放在 ~/.claude/projects/<目录编码>/ 下，/resume 只找当前文件夹的，所以要挪文件：
/// 原会话和同名目录挪到新文件夹的项目目录，备份跟着挪、备份记录改键；文件内容一行不动。
/// 会话文件里记的工作目录还是旧的，回响用「移动记录」显示新文件夹（EchoMoved）。
/// 只挪本机的；2 分钟内还在写、正在 Claude 里开着、新位置已有同一个会话的不挪。
enum EchoMove {
    struct Paths {
        var original: URL, backup: URL          // 现在的位置
        var newOriginal: URL, newBackup: URL    // 挪到的位置
        var record: URL                         // 备份/<电脑名>/备份记录.json
        var rel: String, newRel: String         // <项目目录>/<会话ID>.jsonl
    }

    /// Claude Code 的项目目录名：路径里字母、数字以外的字符都换成「-」，按 UTF-16 算（中文一个字一个）
    static func projectDirName(_ path: String) -> String {
        String(path.utf16.map { c -> Character in
            (48...57).contains(c) || (65...90).contains(c) || (97...122).contains(c) ? Character(UnicodeScalar(UInt8(c))) : "-"
        })
    }

    static func paths(for s: EchoSession, to dir: String, source: URL = EchoBackup.source) -> Paths? {
        guard s.computer == EchoPrefs.computerName else { return nil }
        let oldDir = s.url.deletingLastPathComponent().lastPathComponent, name = s.url.lastPathComponent
        let original = source.appendingPathComponent(oldDir).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: original.path) else { return nil }
        let newDir = projectDirName(dir)
        let backupProjects = s.url.deletingLastPathComponent().deletingLastPathComponent()
        return Paths(original: original, backup: s.url,
                     newOriginal: source.appendingPathComponent(newDir).appendingPathComponent(name),
                     newBackup: backupProjects.appendingPathComponent(newDir).appendingPathComponent(name),
                     record: backupProjects.deletingLastPathComponent().appendingPathComponent("备份记录.json"),
                     rel: oldDir + "/" + name, newRel: newDir + "/" + name)
    }

    /// 正在 Claude 里开着的会话：~/.claude/sessions/<进程号>.json 里记着会话 ID，进程还在
    static func isOpen(_ sessionId: String, sessionsDir: URL = EchoBackup.source.deletingLastPathComponent().appendingPathComponent("sessions")) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
        return files.contains { f in
            guard f.pathExtension == "json", let d = try? Data(contentsOf: f),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  o["sessionId"] as? String == sessionId, let pid = o["pid"] as? Int32, pid > 1 else { return false }
            return kill(pid, 0) == 0 || errno == EPERM
        }
    }

    static func fail(_ text: String) -> Error { CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: text]) }

    /// 先挪原会话（文件、同名目录），再挪备份；原会话挪到一半出错就挪回去。open 测试时替换
    static func move(_ p: Paths, sessionId: String, open: (String) -> Bool = { isOpen($0) }) throws {
        let fm = FileManager.default
        guard p.rel != p.newRel else { return }
        guard p.newOriginal.deletingLastPathComponent().lastPathComponent.count <= 200 else { throw fail("文件夹路径太长，Claude Code 认不出") }
        if EchoRename.isActive(p.original) { throw fail("会话正在进行（2 分钟内还在写），结束后再挪") }
        if open(sessionId) { throw fail("会话正在 Claude 里开着，先关掉（MintPop 里归档那个会话，或在终端里退出 Claude）再挪") }
        let pairs = [(p.original, p.newOriginal), (p.backup, p.newBackup)]
        for (_, to) in pairs where fm.fileExists(atPath: to.path) || fm.fileExists(atPath: to.deletingPathExtension().path) {
            throw fail("新文件夹里已经有这个会话")
        }
        var done: [(URL, URL)] = []
        do {
            for (from, to) in pairs {
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                for (f, t) in [(from, to), (from.deletingPathExtension(), to.deletingPathExtension())] where fm.fileExists(atPath: f.path) {
                    try fm.moveItem(at: f, to: t)
                    done.append((f, t))
                }
            }
        } catch {
            for (f, t) in done.reversed() { try? fm.moveItem(at: t, to: f) }
            throw error
        }
        // 备份记录改键，下次备份不会再拷一遍
        var r = EchoBackupRecord.load(p.record)
        let oldPrefix = String(p.rel.dropLast(6)) + "/", newPrefix = String(p.newRel.dropLast(6)) + "/"
        var files: [String: EchoFileStamp] = [:]
        for (k, v) in r.files {
            if k == p.rel { files[p.newRel] = v }
            else if k.hasPrefix(oldPrefix) { files[newPrefix + k.dropFirst(oldPrefix.count)] = v }
            else { files[k] = v }
        }
        r.files = files
        try? r.save(p.record)
    }
}

/// 移动记录：备份/<电脑名>/移动记录.json，会话 ID → 挪到的文件夹。会话文件里的工作目录不改，左栏、总览、恢复命令按这里的显示
enum EchoMoved {
    static func url(_ computerDir: URL) -> URL { computerDir.appendingPathComponent("移动记录.json") }

    static func load(_ computerDir: URL) -> [String: String] {
        (try? Data(contentsOf: url(computerDir))).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    static func add(_ moves: [String: String], _ computerDir: URL) throws {
        guard !moves.isEmpty else { return }
        let all = load(computerDir).merging(moves) { _, new in new }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(all).write(to: url(computerDir), options: .atomic)
    }
}
