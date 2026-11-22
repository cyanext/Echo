// 备份：~/.claude/projects → 备份目录/<电脑名>/claude/projects，结构不变。~/.claude 只读。
// 流程见立项方案（需求文档/归档/方案.md）第六节：比大小和修改时间，变了才写；先写到本机暂存目录再挪进备份目录；原文件被删时备份保留。
import Foundation

enum EchoBackupRule {
    enum Action: Equatable { case slim, copy, skip }

    /// 图片和 PDF 不备份（tool-results/pdf-*/ 里的页面截图等）
    static let skipExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "pdf"]

    /// rel 是相对 projects 的路径
    static func action(for rel: String) -> Action {
        let name = (rel as NSString).lastPathComponent
        if name.hasPrefix(".") { return .skip }
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "jsonl" { return .slim }
        if skipExtensions.contains(ext) { return .skip }
        return .copy
    }
}

struct EchoFileStamp: Codable, Equatable {
    var size: Int64
    var mtime: Double
}

/// 备份目录/<电脑名>/备份记录.json
struct EchoBackupRecord: Codable {
    var lastSuccess: Date?
    var files: [String: EchoFileStamp] = [:]

    static func load(_ url: URL) -> EchoBackupRecord {
        guard let d = try? Data(contentsOf: url) else { return EchoBackupRecord() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(EchoBackupRecord.self, from: d)) ?? EchoBackupRecord()
    }

    func save(_ url: URL) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try enc.encode(self).write(to: url, options: .atomic)
    }
}

struct EchoBackupResult {
    var copied = 0, skipped = 0, total = 0
    var bytesIn: Int64 = 0, bytesOut: Int64 = 0
    var failures: [(path: String, message: String)] = []
    var seconds: Double = 0
}

/// 备份日志：备份目录/<电脑名>/备份日志.jsonl，每次备份每个应用追加一行，清理、自动删除也各记一行（同一次用同一个时间）。
/// 总览的「备份」卡片按天汇总它。只追加，不改已有的行
enum EchoBackupLog {
    static func url(_ computerDir: URL) -> URL { computerDir.appendingPathComponent("备份日志.jsonl") }

    static func append(_ computerDir: URL, _ entries: [[String: Any]]) {
        guard !entries.isEmpty else { return }
        var data = Data()
        for e in entries {
            guard let d = try? JSONSerialization.data(withJSONObject: e, options: [.sortedKeys, .withoutEscapingSlashes]) else { continue }
            data.append(d); data.append(0x0A)
        }
        let u = url(computerDir)
        try? FileManager.default.createDirectory(at: computerDir, withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: u) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: u)
        }
    }

    static func load(_ computerDir: URL) -> [[String: Any]] {
        var out: [[String: Any]] = []
        try? EchoLines.each(url(computerDir)) { line in
            if let d = (try? JSONSerialization.jsonObject(with: Data(buffer: EchoLines.trim(line)))) as? [String: Any] { out.append(d) }
        }
        return out
    }

    /// 一个应用这次备份的记录
    static func entry(_ t: String, _ app: EchoSource, _ r: EchoBackupResult) -> [String: Any] {
        ["t": t, "app": app.rawValue, "files": r.total, "written": r.copied, "failed": r.failures.count,
         "in": r.bytesIn, "out": r.bytesOut, "sec": (r.seconds * 10).rounded() / 10]
    }
}

enum EchoBackup {
    static var source: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects") }
    static var codexSource: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex") }

    /// 要备份的一个文件：rel 是备份记录里的键（相对源目录），out 是写到备份文件夹里的相对路径
    struct Item { var rel: String; var url: URL; var out: String; var stamp: EchoFileStamp; var action: EchoBackupRule.Action }
    private static let statKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
    private static func stamp(_ url: URL) -> EchoFileStamp? {
        guard let v = try? url.resourceValues(forKeys: Set(statKeys)), v.isRegularFile == true else { return nil }
        return EchoFileStamp(size: Int64(v.fileSize ?? 0), mtime: v.contentModificationDate?.timeIntervalSince1970 ?? 0)
    }

    /// Claude：~/.claude/projects 下的文件照原结构放进 projects/
    static func claudeItems(_ source: URL) throws -> [Item] {
        guard let en = FileManager.default.enumerator(at: source, includingPropertiesForKeys: statKeys) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
        }
        let base = source.standardizedFileURL.path + "/"
        var out: [Item] = []
        for case let url as URL in en {
            guard let st = stamp(url) else { continue }
            let rel = String(url.standardizedFileURL.path.dropFirst(base.count))
            let action = EchoBackupRule.action(for: rel)
            guard action != .skip else { continue }
            out.append(Item(rel: rel, url: url, out: "projects/" + rel, stamp: st, action: action))
        }
        return out
    }

    /// Codex：sessions/年/月/日/ 和 archived_sessions/ 下的 rollout-*.jsonl（或 Codex 压过的 .jsonl.zst），解压后都放进
    /// sessions/年/月/日/rollout-….jsonl（日期取文件名里的），压缩、归档前后写到同一处，不出两份；另外原样复制 session_index.jsonl（会话名）
    static func codexItems(_ source: URL) -> [Item] {
        let fm = FileManager.default
        var out: [Item] = [], seen = Set<String>()
        let base = source.standardizedFileURL.path + "/"
        for dir in ["sessions", "archived_sessions"] {
            let en = fm.enumerator(at: source.appendingPathComponent(dir), includingPropertiesForKeys: statKeys, options: .skipsHiddenFiles)
            for case let url as URL in en?.allObjects ?? [] {
                var name = url.lastPathComponent
                if name.hasSuffix(".zst") { name = String(name.dropLast(4)) }
                guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"), let st = stamp(url) else { continue }
                let d = name.dropFirst("rollout-".count).prefix(10).split(separator: "-")   // 2026-11-02
                guard d.count == 3 else { continue }
                let outRel = "sessions/\(d[0])/\(d[1])/\(d[2])/" + name
                guard seen.insert(outRel).inserted else { continue }   // 归档里和 sessions 里各有一份时只备份一次
                out.append(Item(rel: String(url.standardizedFileURL.path.dropFirst(base.count)), url: url, out: outRel, stamp: st, action: .slim))
            }
        }
        let index = source.appendingPathComponent("session_index.jsonl")
        if let st = stamp(index) { out.append(Item(rel: "session_index.jsonl", url: index, out: "session_index.jsonl", stamp: st, action: .copy)) }
        return out
    }

    /// Claude 的备份（兼容老调用）
    static func run(source: URL, computerDir: URL, policy: EchoPolicy = EchoPolicy(), progress: (Int, Int) -> Void = { _, _ in }) throws -> EchoBackupResult {
        try run(items: claudeItems(source), computerDir: computerDir, policy: policy, progress: progress)
    }

    /// computerDir 是这个应用的备份文件夹（备份/<电脑名>/claude/ 或 codex/）。同步执行，放在后台线程调用。progress(已处理, 总数)
    static func run(items todo: [Item], computerDir: URL, policy: EchoPolicy = EchoPolicy(), progress: (Int, Int) -> Void = { _, _ in }) throws -> EchoBackupResult {
        let t0 = Date()
        let fm = FileManager.default
        let dest = computerDir
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let recordURL = computerDir.appendingPathComponent("备份记录.json")
        var record = EchoBackupRecord.load(recordURL)
        var result = EchoBackupResult()
        result.total = todo.count

        let staging = try makeStaging()
        defer { try? fm.removeItem(at: staging) }

        // 2. 和备份记录比，变了才写。多个文件同时写（大的先排），备份记录、计数、进度用锁护着
        let lock = NSLock()
        var sinceSave = 0, processed = 0
        var cleanEntries: [String: EchoCleanRecord.Entry] = [:]
        let order = todo.indices.sorted { todo[$0].stamp.size > todo[$1].stamp.size }
        DispatchQueue.concurrentPerform(iterations: order.count) { k in
            let f = todo[order[k]]
            let out = dest.appendingPathComponent(f.out)
            defer {
                lock.lock()
                processed += 1
                progress(processed, todo.count)
                lock.unlock()
            }
            lock.lock()
            let same = record.files[f.rel] == f.stamp
            lock.unlock()
            if same, fm.fileExists(atPath: out.path) {
                lock.lock(); result.skipped += 1; lock.unlock()
                return
            }
            do {
                try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                // 先写到本机暂存目录，写完再一步挪进备份目录（place）
                let tmp = staging.appendingPathComponent(UUID().uuidString + ".echo-tmp")
                var bytesIn = f.stamp.size, bytesOut = f.stamp.size
                var stats: EchoSlim.Stats?
                if f.action == .slim {
                    let s = try EchoSlim.slimFile(f.url, to: tmp, policy: policy)
                    bytesIn = Int64(s.bytesIn); bytesOut = Int64(s.bytesOut); stats = s
                } else {
                    try fm.copyItem(at: f.url, to: tmp)
                }
                try place(tmp, at: out)
                let entry = stats.flatMap { EchoCleanRecord.entry(for: out, policy: policy, stats: $0) }
                lock.lock()
                result.bytesIn += bytesIn
                result.bytesOut += bytesOut
                record.files[f.rel] = f.stamp
                if let entry { cleanEntries[out.path] = entry }
                result.copied += 1
                sinceSave += 1
                if sinceSave >= 50 {   // 中途退出也不用全部重来
                    try? record.save(recordURL)
                    sinceSave = 0
                }
                lock.unlock()
            } catch {
                lock.lock(); result.failures.append((f.rel, error.localizedDescription)); lock.unlock()
            }
        }
        EchoCleanRecord.merge(cleanEntries)
        progress(todo.count, todo.count)
        if result.failures.isEmpty { record.lastSuccess = Date() }
        try record.save(recordURL)
        result.seconds = Date().timeIntervalSince(t0)
        return result
    }

    /// 把暂存目录里写好的文件一步挪到 out（覆盖）：iCloud 只看到写好的文件，不会同步到写了一半的，
    /// 也不会给以「.」开头的临时文件打隐藏标记（11-21 几个会话就这样从列表里消失过）
    static func place(_ tmp: URL, at out: URL) throws {
        let fm = FileManager.default
        if rename(tmp.path, out.path) != 0 {
            // 暂存目录和备份目录不在同一块盘上（改名挪不过去）：在备份目录旁边写一份再改名
            let near = out.deletingLastPathComponent().appendingPathComponent(".\(out.lastPathComponent).echo-tmp")
            try? fm.removeItem(at: near)
            defer { try? fm.removeItem(at: tmp) }
            try fm.copyItem(at: tmp, to: near)
            guard rename(near.path, out.path) == 0 else {
                let msg = String(cString: strerror(errno))
                try? fm.removeItem(at: near)
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: msg])
            }
        }
        // 万一还带着隐藏标记（走了上面的退路），清掉
        var visible = URLResourceValues()
        visible.isHidden = false
        var o = out
        try? o.setResourceValues(visible)
    }

    /// 本机暂存目录 ~/Library/Application Support/回响/暂存/<这次>/，只清自己的；中途退出留下的，过一天再清
    static func makeStaging() throws -> URL {
        let fm = FileManager.default
        let stagingRoot = EchoLibrary.supportDir.appendingPathComponent("暂存")
        for old in (try? fm.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let d = try? old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, Date().timeIntervalSince(d) > 86400 { try? fm.removeItem(at: old) }
        }
        let staging = stagingRoot.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    /// Claude Code 会按 cleanupPeriodDays 删旧会话（默认 30 天）。返回 nil 表示已设成很长，不用提醒
    static func cleanupDays() -> Int? {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
        let d = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let days = (d?["cleanupPeriodDays"] as? NSNumber)?.intValue ?? 30
        return days >= 3650 ? nil : days
    }
}
