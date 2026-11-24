// 清理备份：按保留期限把备份里到期的内容换成占位（规则和写备份同一套，见 EchoSlim），只动回响自己的备份，不碰 ~/.claude。
// 规则见 需求文档/版本需求/v0.7.0-会话备份和自动清理.html。
// - 能释放 1 MB 以上或一成以上的文件才重写，免得每天都往废纸篓丢文件；第一次（升级后）全部过一遍，连密钥打码一起。
// - 重写：在暂存目录写好新文件，旧文件移进废纸篓（能放回），新文件挪到原位置；挪不过去就把旧文件从废纸篓放回来。
// - 备份记录不改：它记的是原会话的大小和时间，清理只改备份文件。
// - 省步骤：清理记录（本机）记着每个备份文件「最早什么时候有内容到期」，文件没变、期限没改、还没到那天的直接跳过；
//   写备份时也记一笔，刚写好的文件当天不用再看。多个文件同时处理。
import Foundation

/// 清理记录：本机 ~/Library/Application Support/回响/清理记录.json，备份文件路径 → 大小、修改时间、期限、最早到期
enum EchoCleanRecord {
    struct Entry: Codable, Equatable { var stamp: EchoFileStamp; var policy: String; var next: Double }
    private static let lock = NSLock()
    private static var url: URL { EchoLibrary.supportDir.appendingPathComponent("清理记录.json") }
    /// 没有会到期内容的文件，最早到期是无穷大：JSON 里写成字符串 "inf"（默认编码遇到无穷大会报错，整份记录就写不出来）
    private static func decode(_ d: Data) -> [String: Entry]? {
        let dec = JSONDecoder()
        dec.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try? dec.decode([String: Entry].self, from: d)
    }
    private static func encode(_ r: [String: Entry]) -> Data? {
        let enc = JSONEncoder()
        enc.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try? enc.encode(r)
    }

    static func load() -> [String: Entry] {
        lock.lock(); defer { lock.unlock() }
        return (try? Data(contentsOf: url)).flatMap(decode) ?? [:]
    }

    /// 合并进去（备份和清理各写各的那几项）
    static func merge(_ add: [String: Entry]) {
        guard !add.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var all = (try? Data(contentsOf: url)).flatMap(decode) ?? [:]
        all.merge(add) { _, new in new }
        if let d = encode(all) { try? d.write(to: url, options: .atomic) }
    }

    static func stamp(_ u: URL) -> EchoFileStamp? {
        guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        return EchoFileStamp(size: Int64(v.fileSize ?? 0), mtime: v.contentModificationDate?.timeIntervalSince1970 ?? 0)
    }

    /// 备份文件挪了位置（0.8 起 Claude 的备份挪进 claude/）：记录里这一段路径开头的都换成新的
    static func rename(prefix: String, to new: String) {
        lock.lock(); defer { lock.unlock() }
        guard let all = (try? Data(contentsOf: url)).flatMap(decode) else { return }
        var out: [String: Entry] = [:]
        for (k, v) in all { out[k.hasPrefix(prefix) ? new + k.dropFirst(prefix.count) : k] = v }
        if let d = encode(out) { try? d.write(to: url, options: .atomic) }
    }

    /// 写好一个备份文件后记一笔：stats 是写它时瘦身的结果
    static func entry(for u: URL, policy: EchoPolicy, stats: EchoSlim.Stats) -> Entry? {
        stamp(u).map { Entry(stamp: $0, policy: policy.key, next: stats.nextExpiry) }
    }
}

enum EchoClean {
    struct Result {
        var files = 0, rewritten = 0, skipped = 0
        var bytesBefore: Int64 = 0, bytesAfter: Int64 = 0
        var failures: [(path: String, message: String)] = []
        var freed: Int64 { bytesBefore - bytesAfter }
    }

    /// 值不值得重写：能释放 1 MB 以上，或一成以上
    static func worth(before: Int, after: Int) -> Bool {
        let saved = before - after
        return saved > 0 && (saved >= 1 << 20 || saved * 10 >= before)
    }

    /// 默认移到废纸篓，返回它在废纸篓里的位置；测试时换成移到临时目录
    static func trash(_ u: URL) throws -> URL? {
        var r: NSURL?
        try FileManager.default.trashItem(at: u, resultingItemURL: &r)
        return r as URL?
    }

    /// 没到门槛、先不重写的文件：过几天再看（到期的内容会越攒越多）
    static let recheck: Double = 3 * 86400

    /// computerDir 是 备份/<电脑名>/，各应用的会话都清（EchoLayout.sessionRoots）。dryRun 只算能释放多少；force 不看门槛、不看清理记录，有改动就重写（升级后第一次）
    static func run(computerDir: URL, policy: EchoPolicy, dryRun: Bool = false, force: Bool = false,
                    remove: @escaping (URL) throws -> URL? = trash) throws -> Result {
        let fm = FileManager.default
        let root = computerDir
        // 大文件先排，几个线程的活儿分得匀
        let files = EchoLayout.sessionRoots(computerDir).flatMap { r -> [URL] in
            let en = fm.enumerator(at: r.root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles])
            return (en?.allObjects ?? []).compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
        }
            .sorted { (EchoCleanRecord.stamp($0)?.size ?? 0) > (EchoCleanRecord.stamp($1)?.size ?? 0) }
        let record = force ? [:] : EchoCleanRecord.load()
        let staging = dryRun ? nil : try EchoBackup.makeStaging()
        defer { if let staging { try? fm.removeItem(at: staging) } }
        let now = policy.now.timeIntervalSince1970
        let removeLock = NSLock()   // 移到废纸篓一个个来

        struct One { var before: Int64 = 0, after: Int64 = 0, rewritten = false, skipped = false, failure: String?, entry: EchoCleanRecord.Entry? }
        let parts = EchoParallel.map(files) { url -> One in
            var o = One()
            guard let stamp = EchoCleanRecord.stamp(url) else { return o }
            o.before = stamp.size
            o.after = stamp.size
            // 文件没变、期限没改、还没到最早到期那天：不用看
            if let e = record[url.path], e.stamp == stamp, e.policy == policy.key, now < e.next { o.skipped = true; return o }
            do {
                if dryRun {
                    let s = try EchoSlim.slimFile(url, to: nil, policy: policy)
                    if worth(before: s.bytesIn, after: s.bytesOut) { o.after = Int64(s.bytesOut) }
                    return o
                }
                let tmp = staging!.appendingPathComponent(UUID().uuidString + ".echo-tmp")
                let s = try EchoSlim.slimFile(url, to: tmp, policy: policy)
                guard s.changedLines + s.droppedLines > 0, force || worth(before: s.bytesIn, after: s.bytesOut) else {
                    try? fm.removeItem(at: tmp)
                    let next = s.changedLines + s.droppedLines > 0 ? min(s.nextExpiry, now + recheck) : s.nextExpiry
                    o.entry = .init(stamp: stamp, policy: policy.key, next: next)
                    return o
                }
                removeLock.lock()
                let old = Swift.Result { try remove(url) }
                removeLock.unlock()
                let oldURL = try old.get()
                do { try EchoBackup.place(tmp, at: url) } catch {
                    if let oldURL, !fm.fileExists(atPath: url.path) { try? fm.moveItem(at: oldURL, to: url) }
                    throw error
                }
                o.after = Int64(s.bytesOut)
                o.rewritten = true
                o.entry = EchoCleanRecord.entry(for: url, policy: policy, stats: s)
            } catch {
                o.failure = error.localizedDescription
            }
            return o
        }
        var result = Result(), entries: [String: EchoCleanRecord.Entry] = [:]
        // 图片和文件（会话目录里的图片、PDF，设置里打开了才会备份）：按文件修改时间到期（不备份时一律）就移到废纸篓
        let media = EchoLayout.sessionRoots(computerDir).flatMap { r -> [URL] in
            (fm.enumerator(at: r.root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])?.allObjects ?? [])
                .compactMap { $0 as? URL }.filter { EchoBackupRule.isMedia($0.lastPathComponent) }
        }
        for u in media {
            guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  policy.expired(policy.media, v.contentModificationDate) else { continue }
            let size = Int64(v.fileSize ?? 0)
            result.files += 1
            result.bytesBefore += size
            if dryRun { continue }
            do { _ = try remove(u); result.rewritten += 1 }
            catch { result.bytesAfter += size; result.failures.append((String(u.path.dropFirst(root.path.count + 1)), error.localizedDescription)) }
        }
        for (url, o) in zip(files, parts) {
            result.files += 1
            result.bytesBefore += o.before
            result.bytesAfter += o.after
            if o.rewritten { result.rewritten += 1 }
            if o.skipped { result.skipped += 1 }
            if let f = o.failure { result.failures.append((String(url.path.dropFirst(root.path.count + 1)), f)) }
            if let e = o.entry { entries[url.path] = e }
        }
        if !dryRun { EchoCleanRecord.merge(entries) }
        return result
    }
}
