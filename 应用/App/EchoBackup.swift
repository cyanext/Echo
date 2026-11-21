// 备份：~/.claude/projects → 备份目录/<电脑名>/projects，结构不变。~/.claude 只读。
// 流程见方案第六节：比大小和修改时间，变了才写；先写临时文件再改名；原文件被删时备份保留。
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

enum EchoBackup {
    static var source: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects") }

    /// 同步执行，放在后台线程调用。progress(已处理, 总数)
    static func run(source: URL, computerDir: URL, progress: (Int, Int) -> Void = { _, _ in }) throws -> EchoBackupResult {
        let t0 = Date()
        let fm = FileManager.default
        let dest = computerDir.appendingPathComponent("projects")
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let recordURL = computerDir.appendingPathComponent("备份记录.json")
        var record = EchoBackupRecord.load(recordURL)
        var result = EchoBackupResult()

        // 1. 挑出要备份的文件
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let en = fm.enumerator(at: source, includingPropertiesForKeys: keys) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
        }
        let base = source.standardizedFileURL.path + "/"
        var todo: [(rel: String, url: URL, stamp: EchoFileStamp, action: EchoBackupRule.Action)] = []
        for case let url as URL in en {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let rel = String(url.standardizedFileURL.path.dropFirst(base.count))
            let action = EchoBackupRule.action(for: rel)
            guard action != .skip else { continue }
            let stamp = EchoFileStamp(size: Int64(v.fileSize ?? 0), mtime: v.contentModificationDate?.timeIntervalSince1970 ?? 0)
            todo.append((rel, url, stamp, action))
        }
        result.total = todo.count

        // 2. 和备份记录比，变了才写
        var sinceSave = 0
        for (n, f) in todo.enumerated() {
            progress(n, todo.count)
            let out = dest.appendingPathComponent(f.rel)
            if record.files[f.rel] == f.stamp, fm.fileExists(atPath: out.path) {
                result.skipped += 1
                continue
            }
            do {
                try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                let tmp = out.deletingLastPathComponent().appendingPathComponent(".\(out.lastPathComponent).echo-tmp")
                try? fm.removeItem(at: tmp)
                if f.action == .slim {
                    let s = try EchoSlim.slimFile(f.url, to: tmp)
                    result.bytesIn += Int64(s.bytesIn)
                    result.bytesOut += Int64(s.bytesOut)
                } else {
                    try fm.copyItem(at: f.url, to: tmp)
                    result.bytesIn += f.stamp.size
                    result.bytesOut += f.stamp.size
                }
                // 写完再改名覆盖，iCloud 不会同步到写了一半的文件
                guard rename(tmp.path, out.path) == 0 else {
                    let msg = String(cString: strerror(errno))
                    try? fm.removeItem(at: tmp)
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: msg])
                }
                record.files[f.rel] = f.stamp
                result.copied += 1
                sinceSave += 1
                if sinceSave >= 50 {   // 中途退出也不用全部重来
                    try? record.save(recordURL)
                    sinceSave = 0
                }
            } catch {
                result.failures.append((f.rel, error.localizedDescription))
            }
        }
        progress(todo.count, todo.count)
        if result.failures.isEmpty { record.lastSuccess = Date() }
        try record.save(recordURL)
        result.seconds = Date().timeIntervalSince(t0)
        return result
    }

    /// Claude Code 会按 cleanupPeriodDays 删旧会话（默认 30 天）。返回 nil 表示已设成很长，不用提醒
    static func cleanupDays() -> Int? {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
        let d = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let days = (d?["cleanupPeriodDays"] as? NSNumber)?.intValue ?? 30
        return days >= 3650 ? nil : days
    }
}
