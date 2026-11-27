// 改名和合集。
// 改名写回原会话：在 ~/.claude 里的会话文件末尾追加一行 custom-title（和 Claude Code 自己 /rename 一样），已有的行一行不动；
// 会话目录里有 custom-title.json 时一并改。只能改本机的会话。
// 删除、移动见文件末尾 EchoDelete、EchoMove。
// 合集：几个会话按时间连起来看，存在备份目录的 合集.json（iCloud 同步，两台电脑都能看到），原文件不动。
import AppKit

enum EchoRename {
    /// 本机会话的原文件（~/.claude 或 ~/.codex 里）；另一台电脑的会话、原文件已被删的返回 nil。
    /// Codex 的可能还在 sessions/年/月/日/，也可能被压成 .zst、挪进 archived_sessions/
    static func originalURL(for s: EchoSession) -> URL? {
        guard s.computer == EchoPrefs.computerName else { return nil }
        let fm = FileManager.default
        if s.app == .codex {
            let name = s.url.lastPathComponent, day = s.url.deletingLastPathComponent().pathComponents.suffix(3).joined(separator: "/")
            let root = EchoBackup.codexSource
            return ["sessions/\(day)/\(name)", "sessions/\(day)/\(name).zst", "archived_sessions/\(name)", "archived_sessions/\(name).zst"]
                .map { root.appendingPathComponent($0) }.first { fm.fileExists(atPath: $0.path) }
        }
        let u = EchoBackup.source.appendingPathComponent(s.url.deletingLastPathComponent().lastPathComponent)
            .appendingPathComponent(s.url.lastPathComponent)
        return fm.fileExists(atPath: u.path) ? u : nil
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

    /// 合集成员的键：相对备份目录的路径。Claude 的会话 0.8 起挪进了 <电脑名>/claude/，键照旧写成 <电脑名>/projects/…，
    /// 以前建的合集不用改，另一台电脑升级前后也对得上
    static func key(_ s: EchoSession, root: URL) -> String {
        let rel = String(s.url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
        var parts = rel.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count > 2, parts[1] == Substring(EchoSource.claude.folder), parts[2] == "projects" { parts.remove(at: 1) }
        return parts.joined(separator: "/")
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

/// Claude 会话的同名目录（子代理、长工具输出），确实是目录才算：Codex 的 x.jsonl.zst 去掉扩展名是 x.jsonl，不能当成目录删
func sameNameDir(_ f: URL) -> URL? {
    var isDir: ObjCBool = false
    let dir = f.deletingPathExtension()
    return FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue ? dir : nil
}

/// 删除：原会话和备份一起移到废纸篓（能放回）。会话文件和同名目录（子代理、长工具输出）一起移，备份记录里去掉。
/// 只删本机的会话；2 分钟内还在写的不删。
enum EchoDelete {
    struct Paths {
        var original: URL?         // ~/.claude/projects/<项目目录>/<会话ID>.jsonl；原会话已不在（清理了、在另一台电脑上）是 nil，只删备份
        var backup: URL            // 备份/<电脑名>/claude/projects/<项目目录>/<会话ID>.jsonl
        var record: URL?           // 这台电脑的备份记录；另一台电脑的会话不改它的备份记录
        var rel: String            // 备份记录里的键：<项目目录>/<会话ID>.jsonl；Codex 是相对 ~/.codex 的原路径（原会话不在时按文件名找）
    }

    static func paths(for s: EchoSession) -> Paths {
        let orig = EchoRename.originalURL(for: s), mine = s.computer == EchoPrefs.computerName
        if s.app == .codex {   // 备份在 codex/sessions/年/月/日/，备份记录在 codex/
            let codexDir = s.url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let rel = orig.map { String($0.standardizedFileURL.path.dropFirst(EchoBackup.codexSource.standardizedFileURL.path.count + 1)) } ?? s.url.lastPathComponent
            return Paths(original: orig, backup: s.url, record: mine ? codexDir.appendingPathComponent("备份记录.json") : nil, rel: rel)
        }
        let rel = s.url.deletingLastPathComponent().lastPathComponent + "/" + s.url.lastPathComponent
        let record = s.url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("备份记录.json")
        return Paths(original: orig, backup: s.url, record: mine ? record : nil, rel: rel)
    }

    /// remove 默认移到废纸篓，测试时换成移到临时目录。原会话在就和备份一起移走，不在就只移备份
    static func trash(_ p: Paths, remove: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws {
        let fm = FileManager.default
        if let o = p.original, EchoRename.isActive(o) {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "会话仍在进行，请结束后再删除"])
        }
        for f in [p.original, p.backup].compactMap({ $0 }) {
            if fm.fileExists(atPath: f.path) { try remove(f) }
            if let dir = sameNameDir(f) { try remove(dir) }
        }
        guard let rp = p.record else { return }
        var r = EchoBackupRecord.load(rp)
        let prefix = (p.rel as NSString).deletingPathExtension + "/"   // 同名目录里的文件（Claude 的子代理记录）
        let name = p.backup.lastPathComponent                           // Codex 原会话不在时，按文件名（去掉 .zst）对
        r.files = r.files.filter { k, _ in
            k != p.rel && !k.hasPrefix(prefix) && !(k.contains("rollout-") && (k as NSString).lastPathComponent.replacingOccurrences(of: ".zst", with: "") == name)
        }
        try? r.save(rp)
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
        guard s.computer == EchoPrefs.computerName, s.app == .claude else { return nil }   // Codex 的会话按日期存，不按文件夹，不挪
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

    /// 正在 Claude 里开着的会话：~/.claude/sessions/<进程号>.json 里记着会话 ID，进程还在运行。
    /// 退出了但父进程没回收的（僵尸进程）不算；进程号被别的进程复用的（启动时间晚于登记的 startedAt）也不算
    static func isOpen(_ sessionId: String, sessionsDir: URL = EchoBackup.source.deletingLastPathComponent().appendingPathComponent("sessions")) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
        return files.contains { f in
            guard f.pathExtension == "json", let d = try? Data(contentsOf: f),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  o["sessionId"] as? String == sessionId, let pid = o["pid"] as? Int32, pid > 1,
                  let started = processStart(pid) else { return false }
            if let ms = o["startedAt"] as? Double, started.timeIntervalSince1970 > ms / 1000 + 60 { return false }
            return true
        }
    }

    /// 进程的启动时间；进程不在或已退出（僵尸进程）时为 nil
    static func processStart(_ pid: Int32) -> Date? {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, Int32(info.kp_proc.p_stat) != SZOMB else { return nil }
        let t = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)
    }

    static func fail(_ text: String) -> Error { CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: text]) }

    /// 先挪原会话（文件、同名目录），再挪备份；原会话挪到一半出错就挪回去。open 测试时替换
    static func move(_ p: Paths, sessionId: String, open: (String) -> Bool = { isOpen($0) }) throws {
        let fm = FileManager.default
        guard p.rel != p.newRel else { return }
        guard p.newOriginal.deletingLastPathComponent().lastPathComponent.count <= 200 else { throw fail("文件夹路径过长，Claude Code 无法识别") }
        if EchoRename.isActive(p.original) { throw fail("会话仍在进行，请结束后再移动") }
        if open(sessionId) { throw fail("会话正在 Claude 中打开，请关闭后再移动") }
        let pairs = [(p.original, p.newOriginal), (p.backup, p.newBackup)]
        for (_, to) in pairs where fm.fileExists(atPath: to.path) || fm.fileExists(atPath: to.deletingPathExtension().path) {
            throw fail("新位置已有此会话")
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

/// 恢复命令：到会话所在的文件夹（挪过的用新文件夹），用 Claude Code 或 Codex 接着这个会话。
/// 右键菜单、移动完的提示框用；网页标题栏的复制按钮在 Web/app.js 里按同样的格式拼
enum EchoResume {
    static func command(_ app: EchoSource, cwd: String, id: String) -> String {
        "cd '\(cwd.replacingOccurrences(of: "'", with: "'\\''"))' && " + (app == .codex ? "codex resume " : "claude --resume ") + id
    }

    static func copy(_ s: EchoSession) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command(s.app, cwd: s.meta.cwd, id: s.sessionId), forType: .string)
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

/// 自动删除 Claude 里不活跃的会话（规则见 CLAUDE.md「数据安全」）：设置里打开时，备份成功后挑出
/// 超过期限没改过、备份完整（备份记录里的大小和时间与原文件一致，同名目录里的文件也是）、没在 Claude 里开着、2 分钟内没写的，
/// 把原会话文件和同名目录移进废纸篓。备份不动，回响里照样能看。
enum EchoAutoDelete {
    struct Candidate { let original: URL; let rel: String; let bytes: Int64 }

    /// source 是 ~/.claude/projects，computerDir 是 Claude 的备份（备份/<电脑名>/claude/）。open 测试时替换
    static func candidates(source: URL, computerDir: URL, days: Int, now: Date = Date(),
                           open: (String) -> Bool = { EchoMove.isOpen($0) }) -> [Candidate] {
        let fm = FileManager.default
        let record = EchoBackupRecord.load(computerDir.appendingPathComponent("备份记录.json"))
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        func stamp(_ u: URL) -> (EchoFileStamp, Date)? {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, let m = v.contentModificationDate else { return nil }
            return (EchoFileStamp(size: Int64(v.fileSize ?? 0), mtime: m.timeIntervalSince1970), m)
        }
        func backedUp(_ u: URL, _ rel: String) -> Bool {
            guard let (s, _) = stamp(u), record.files[rel] == s else { return false }
            return fm.fileExists(atPath: computerDir.appendingPathComponent("projects").appendingPathComponent(rel).path)
        }
        var out: [Candidate] = []
        for p in (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
            for f in (try? fm.contentsOfDirectory(at: p, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? [] where f.pathExtension == "jsonl" {
                let rel = p.lastPathComponent + "/" + f.lastPathComponent
                guard let (s, m) = stamp(f), now.timeIntervalSince(m) > Double(days) * 86400, !EchoRename.isActive(f), backedUp(f, rel) else { continue }
                // 同名目录（子代理记录等）：要备份的文件也得都备份好了，也算没改过
                var bytes = s.size, ok = true
                let dir = f.deletingPathExtension()
                if let en = fm.enumerator(at: dir, includingPropertiesForKeys: keys) {
                    for case let x as URL in en {
                        guard let (xs, xm) = stamp(x) else { continue }
                        bytes += xs.size
                        let xrel = rel.dropLast(6) + "/" + String(x.standardizedFileURL.path.dropFirst(dir.standardizedFileURL.path.count + 1))
                        if now.timeIntervalSince(xm) <= Double(days) * 86400 { ok = false; break }
                        if EchoBackupRule.action(for: String(xrel)) != .skip, !backedUp(x, String(xrel)) { ok = false; break }
                    }
                }
                guard ok, !open(String(f.lastPathComponent.dropLast(6))) else { continue }
                out.append(Candidate(original: f, rel: rel, bytes: bytes))
            }
        }
        return out.sorted { $0.rel < $1.rel }
    }

    /// Codex：超过期限没改过、备份完整（备份记录里的大小和时间与原文件一致、备份文件在）、2 分钟内没写的会话文件。
    /// 只挪会话文件本身（.jsonl 或 .jsonl.zst），Codex 的 session_index、数据库不动。source 是 ~/.codex，dir 是 Codex 的备份（codex/）
    static func codexCandidates(source: URL, dir: URL, days: Int, now: Date = Date()) -> [Candidate] {
        let fm = FileManager.default
        let record = EchoBackupRecord.load(dir.appendingPathComponent("备份记录.json"))
        return EchoBackup.codexItems(source).filter { it in
            guard it.out.hasPrefix("sessions/"), record.files[it.rel] == it.stamp,
                  now.timeIntervalSince1970 - it.stamp.mtime > Double(days) * 86400,
                  fm.fileExists(atPath: dir.appendingPathComponent(it.out).path), !EchoRename.isActive(it.url) else { return false }
            return true
        }.map { Candidate(original: $0.url, rel: $0.rel, bytes: $0.stamp.size) }.sorted { $0.rel < $1.rel }
    }

    /// 移进废纸篓；remove 测试时换成移到临时目录。返回删了几个、腾出多少、哪些没删成
    static func run(_ list: [Candidate], remove: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })
        -> (count: Int, bytes: Int64, failures: [(path: String, message: String)]) {
        let fm = FileManager.default
        var count = 0, bytes: Int64 = 0, failures: [(String, String)] = []
        for c in list {
            do {
                try remove(c.original)
                if let dir = sameNameDir(c.original) { try remove(dir) }
                count += 1
                bytes += c.bytes
            } catch {
                failures.append((c.rel, error.localizedDescription))
            }
        }
        return (count, bytes, failures)
    }
}

/// Claude Code 自己的清理：~/.claude/settings.json 的 cleanupPeriodDays（没写是 30 天），到期直接删、不看回响备份好没有。
/// 「关闭」就是改成 36500：只改这一项的数值（没有就加在开头），其余内容一字不动
enum EchoClaudeSettings {
    static var url: URL { EchoBackup.source.deletingLastPathComponent().appendingPathComponent("settings.json") }
    static let off = 36500

    static func cleanupDays(_ url: URL = url) -> Int {
        let d = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return (d?["cleanupPeriodDays"] as? NSNumber)?.intValue ?? 30
    }

    static func setCleanupDays(_ days: Int, url: URL = url) throws {
        let fm = FileManager.default
        var text = fm.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : ""
        if text.trimmed.isEmpty { text = "{\n  \"cleanupPeriodDays\": \(days)\n}\n" }
        else if let r = text.range(of: #""cleanupPeriodDays"\s*:\s*-?[0-9.]+"#, options: .regularExpression) {
            text.replaceSubrange(r, with: "\"cleanupPeriodDays\": \(days)")
        } else {
            guard let open = text.firstIndex(of: "{") else { throw EchoMove.fail("settings.json 格式不符，未修改") }
            let rest = text[text.index(after: open)...]
            let empty = rest.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("}")
            // 照下一行的缩进写；对象是空的就不加逗号
            let indent = rest.hasPrefix("\n") ? String(rest.dropFirst().prefix { $0 == " " || $0 == "\t" }) : ""
            let item = rest.hasPrefix("\n") ? "\n\(indent.isEmpty ? "  " : indent)\"cleanupPeriodDays\": \(days)" : "\"cleanupPeriodDays\": \(days)"
            text.insert(contentsOf: item + (empty ? "" : (rest.hasPrefix("\n") ? "," : ", ")), at: text.index(after: open))
        }
        // 改完必须还是合法的 JSON、值对了才写
        guard let o = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              (o["cleanupPeriodDays"] as? NSNumber)?.intValue == days else { throw EchoMove.fail("修改后的 settings.json 不是合法的 JSON，未修改") }
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}

extension EchoMove {
    /// 一批会话挪到 dir：一个个挪，出错的跳过；挪成的记进移动记录、合集成员换成新路径。返回挪成的和第一个错。
    /// 应用里的移动、目录移动和改名、ech mv 共用
    static func moveSessions(_ list: [EchoSession], to dir: String) -> (done: [EchoSession], error: Error?) {
        let dir = (dir as NSString).standardizingPath, root = EchoPrefs.backupRoot
        // Codex 的会话另走一套：只改 Codex 记录里的文件夹（EchoCodexMove）
        let cx = EchoCodexMove.move(list.filter { $0.app == .codex }, to: dir)
        var done: [EchoSession] = cx.done, firstError: Error? = cx.error, moves: [String: String] = [:], keys: [String: String] = [:]
        for s in list where s.app == .claude {
            do {
                guard let p = paths(for: s, to: dir) else { throw fail("「\(s.meta.title)」在 \(s.computer) 上，请在该电脑上移动") }
                try move(p, sessionId: s.sessionId)
                moves[s.sessionId] = dir
                keys[EchoCollections.key(s, root: root)] = String(p.newBackup.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
                done.append(s)
            } catch { firstError = firstError ?? error }
        }
        try? EchoMoved.add(moves, EchoPrefs.claudeDir)
        if !keys.isEmpty {
            let cols = EchoCollections.load(root)
            let updated = cols.map { c in EchoCollection(id: c.id, title: c.title, members: c.members.map { keys[$0] ?? $0 }, created: c.created) }
            if updated != cols { try? EchoCollections.save(updated, root) }
        }
        return (done, firstError)
    }
}

/// 移动 Codex 的会话：Codex 的会话文件按日期存，所在文件夹记在 ~/.codex/state_5.sqlite 的 threads.cwd，
/// Codex 的侧栏、codex resume 都按它归文件夹。只改这一列，改前把整个数据库备份到回响的支持目录（留最近 10 份）；
/// 会话文件一行不动，回响按移动记录（codex/移动记录.json）显示新文件夹。2 分钟内还在写的、不在本机的不动
enum EchoCodexMove {
    static var db: URL { EchoBackup.codexSource.appendingPathComponent("state_5.sqlite") }
    static var backups: URL { EchoLibrary.supportDir.appendingPathComponent("Codex 数据库备份") }

    /// db、backups、movedDir、original 测试时换成临时的
    static func move(_ list: [EchoSession], to dir: String, db: URL = db, backups: URL = backups, movedDir: URL = EchoPrefs.codexDir,
                     original: (EchoSession) -> URL? = { EchoRename.originalURL(for: $0) }) -> (done: [EchoSession], error: Error?) {
        guard !list.isEmpty else { return ([], nil) }
        var done: [EchoSession] = [], firstError: Error?
        let ok = list.filter { s in
            guard let o = original(s) else { firstError = firstError ?? EchoMove.fail("「\(s.meta.title)」不在本机，无法移动"); return false }
            if EchoRename.isActive(o) { firstError = firstError ?? EchoMove.fail("「\(s.meta.title)」正在使用，请结束后重试"); return false }
            return true
        }
        guard !ok.isEmpty else { return ([], firstError) }
        do {
            guard FileManager.default.fileExists(atPath: db.path) else { throw EchoMove.fail("找不到 Codex 的会话记录") }
            let conn = try EchoDB(db)
            try backup(conn, to: backups)
            try conn.exec("BEGIN IMMEDIATE")
            var moves: [String: String] = [:]
            do {
                let st = try conn.prepare("UPDATE threads SET cwd = ? WHERE id = ?")
                for s in ok {
                    try st.bind([dir, s.sessionId])
                    _ = try st.step()
                    if conn.changes == 1 { moves[s.sessionId] = dir; done.append(s) }
                    else { firstError = firstError ?? EchoMove.fail("Codex 中没有「\(s.meta.title)」的记录") }
                }
                try conn.exec("COMMIT")
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
            try EchoMoved.add(moves, movedDir)
        } catch {
            done = []
            firstError = error
        }
        return (done, firstError)
    }

    /// 改之前整份备份：VACUUM INTO 得到一致的副本（还在 WAL 里的也在），文件名带时间，留最近 10 份
    static func backup(_ conn: EchoDB, to dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let out = dir.appendingPathComponent("state_5-\(f.string(from: Date())).sqlite")
        try? fm.removeItem(at: out)
        try conn.exec("VACUUM INTO '\(out.path.replacingOccurrences(of: "'", with: "''"))'")
        let all = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "sqlite" }
        for u in all.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(10) { try? fm.removeItem(at: u) }
    }
}

/// 目录改名、挪位置，会话跟过去（需求 需求文档/版本需求/v0.9.0-目录改名后会话跟上.html）。
/// 左栏目录右键「改名」「移动到」「找到新位置」和 ech mv 共用：先出计划（哪些挪、哪些不跟、有没有正在用的会话），再执行
enum EchoDirMove {
    struct Plan {
        var from: String, to: String
        var moveFolder: Bool                          // 同时改名或挪动文件夹本身；false 时只挪会话（文件夹已经在访达里改过了）
        var groups: [String: [EchoSession]] = [:]     // 新路径 → 挪到那里的会话（子文件夹里的对应到新位置的子文件夹）
        var skipped: [EchoSession] = []               // 跟不过去的：只剩备份、在其他电脑上
        var missing: [EchoSession] = []               // 新位置没有对应的子文件夹（只挪会话时）
        var busy: EchoSession?                        // 2 分钟内还在写或正在 Claude 里开着
        var count: Int { groups.values.reduce(0) { $0 + $1.count } }
    }

    /// from、to 是访达里的路径。sessions 是全部会话（不管左栏的筛选）
    static func plan(from: String, to: String, sessions: [EchoSession], moveFolder: Bool) -> Plan {
        let from = EchoPath.real(from), to = (to as NSString).standardizingPath
        var p = Plan(from: from, to: to, moveFolder: moveFolder)
        let fm = FileManager.default, me = EchoPrefs.computerName
        for s in sessions {
            let real = EchoPath.real(s.projectPath)
            guard real == from || real.hasPrefix(from + "/") else { continue }
            let dest = to + real.dropFirst(from.count)
            if (s.projectPath as NSString).standardizingPath == dest { continue }   // 已经在新位置：旧路径是指向新路径的软链时，新路径下原有的会话
            guard s.computer == me, let orig = EchoRename.originalURL(for: s) else { p.skipped.append(s); continue }   // 只剩备份的、在其他电脑上的不跟
            if !moveFolder, !fm.fileExists(atPath: dest) { p.missing.append(s); continue }
            p.groups[dest, default: []].append(s)
            if p.busy == nil, EchoRename.isActive(orig) || EchoMove.isOpen(s.sessionId) { p.busy = s }
        }
        return p
    }

    /// 按计划执行：要挪文件夹的先挪文件夹（有会话正在用、新位置已有同名的整个不动），再把会话挪到新路径下
    static func run(_ p: Plan) throws -> (done: Int, error: Error?) {
        let fm = FileManager.default
        if p.moveFolder {
            if let b = p.busy { throw EchoMove.fail("「\(b.meta.title)」正在使用，请结束后重试") }
            guard !fm.fileExists(atPath: p.to) else { throw EchoMove.fail("「\((p.to as NSString).lastPathComponent)」已存在") }
            try fm.moveItem(atPath: p.from, toPath: p.to)
        }
        var done = 0, firstError: Error?
        for (dest, list) in p.groups.sorted(by: { $0.key < $1.key }) {
            let r = EchoMove.moveSessions(list, to: dest)
            done += r.done.count
            firstError = firstError ?? r.error
        }
        return (done, firstError)
    }

    /// 计划写成一句话：挪几个会话，几个不跟、为什么
    static func describe(_ p: Plan) -> String {
        var out: [String] = []
        if p.count > 0 { out.append("\(p.count) 个会话将移到新位置") }
        let other = p.skipped.filter { $0.computer != EchoPrefs.computerName }.count
        let gone = p.skipped.count - other
        var not: [String] = []
        if gone > 0 { not.append("\(gone) 个仅有备份的会话") }
        if other > 0 { not.append("\(other) 个其他电脑上的会话") }
        if !not.isEmpty { out.append(not.joined(separator: "、") + "不随之移动") }
        if !p.missing.isEmpty { out.append("\(p.missing.count) 个会话在新位置没有对应的子文件夹，不移动") }
        return out.isEmpty ? "此文件夹中没有会话" : out.joined(separator: "；")
    }

    /// 文件夹已不存在时猜它去哪了。moved：同名文件夹在别处（挪走了）；否则是同一位置改了名
    struct Guess: Equatable { var path: String; var moved: Bool }

    /// 先找挪走的：从还在的那一级往下 3 层找同名文件夹，没有再用 Spotlight 在主目录里找，几个同名的取离原位置最近的；
    /// 再找改名的：上一级里名字最像的子文件夹（去掉开头的序号后，中文比共同的字、英文比共同的单词算分，至少 2 分且对上原名的 6 成）。
    /// spotlight 测试时关掉，结果只看临时目录
    static func guess(_ path: String, spotlight: Bool = true) -> Guess? {
        let fm = FileManager.default, name = (path as NSString).lastPathComponent
        func isDir(_ p: String) -> Bool { var d: ObjCBool = false; return fm.fileExists(atPath: p, isDirectory: &d) && d.boolValue }
        // 离原位置多近：共同的上级越多越近
        func near(_ p: String) -> Int { zip(p.split(separator: "/"), path.split(separator: "/")).prefix { $0 == $1 }.count }
        var top = (path as NSString).deletingLastPathComponent
        while !isDir(top), top.count > 1 { top = (top as NSString).deletingLastPathComponent }
        let skip: Set<String> = ["node_modules", "Library", ".git", "build", "dist"]
        var found: [String] = []
        func walk(_ dir: String, _ depth: Int) {
            guard depth > 0, let kids = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for k in kids where !k.hasPrefix(".") && !skip.contains(k) {
                let full = (dir as NSString).appendingPathComponent(k)
                guard isDir(full) else { continue }
                if k == name, full != path { found.append(full) }
                walk(full, depth - 1)
            }
        }
        if top.hasPrefix(NSHomeDirectory() + "/") || !spotlight { walk(top, 3) }
        if found.isEmpty, spotlight { found = spotlightFolders(name).filter { $0 != path && isDir($0) } }
        if let best = found.max(by: { near($0) < near($1) }) { return Guess(path: best, moved: true) }

        let parent = (path as NSString).deletingLastPathComponent
        guard let kids = try? fm.contentsOfDirectory(atPath: parent) else { return nil }
        func core(_ s: String) -> String { s.replacingOccurrences(of: #"^[0-9]+[ .、_-]*"#, with: "", options: .regularExpression).lowercased() }
        func cjk(_ s: String) -> Set<Character> { Set(core(s).filter { $0.unicodeScalars.allSatisfy { $0.value >= 0x3400 && $0.value <= 0x9fff } }) }
        func words(_ s: String) -> Set<String> {
            Set(core(s).split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) }).map(String.init).filter { $0.count >= 3 })
        }
        // 至少对上原名的 6 成（「客户项目」只因都有「客户」被猜成了「客户数据清洗」）
        let wc = cjk(name), ww = words(name), full = wc.count + 2 * ww.count
        var best: (String, Int)?
        for k in kids where !k.hasPrefix(".") {
            let path = (parent as NSString).appendingPathComponent(k)
            guard isDir(path) else { continue }
            let n = cjk(k).intersection(wc).count + 2 * words(k).intersection(ww).count
            if n >= 2, Double(n) >= 0.6 * Double(full), n > (best?.1 ?? 0) { best = (path, n) }
        }
        return best.map { Guess(path: $0.0, moved: false) }
    }

    /// Spotlight 按名字找文件夹（主目录里，跳过废纸篓和资源库），最多等 3 秒
    static func spotlightFolders(_ name: String) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        let q = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        p.arguments = ["-onlyin", NSHomeDirectory(), "kMDItemFSName == \"\(q)\" && kMDItemContentType == \"public.folder\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let end = Date(timeIntervalSinceNow: 3)
        while p.isRunning, Date() < end { usleep(50_000) }
        if p.isRunning { p.terminate(); return [] }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let home = NSHomeDirectory()
        return text.split(separator: "\n").map(String.init).filter { !$0.hasPrefix(home + "/.Trash") && !$0.hasPrefix(home + "/Library/") }
    }
}
