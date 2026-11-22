// 清理备份：按保留期限把备份里到期的内容换成占位（规则和写备份同一套，见 EchoSlim），只动回响自己的备份，不碰 ~/.claude。
// 规则见 需求文档/版本需求/v0.7.0-会话备份和自动清理.html。
// - 能释放 1 MB 以上或一成以上的文件才重写，免得每天都往废纸篓丢文件；第一次（升级后）全部过一遍，连密钥打码一起。
// - 重写：在暂存目录写好新文件，旧文件移进废纸篓（能放回），新文件挪到原位置；挪不过去就把旧文件从废纸篓放回来。
// - 备份记录不改：它记的是原会话的大小和时间，清理只改备份文件。
import Foundation

enum EchoClean {
    struct Result {
        var files = 0, rewritten = 0
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

    /// computerDir 是 备份/<电脑名>/。dryRun 只算能释放多少；force 不看门槛，有改动就重写（升级后第一次）
    static func run(computerDir: URL, policy: EchoPolicy, dryRun: Bool = false, force: Bool = false,
                    remove: (URL) throws -> URL? = trash) throws -> Result {
        let fm = FileManager.default
        let root = computerDir.appendingPathComponent("projects")
        var result = Result()
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return result }
        let staging = dryRun ? nil : try EchoBackup.makeStaging()
        defer { if let staging { try? fm.removeItem(at: staging) } }
        for case let url as URL in en where url.pathExtension == "jsonl" {
            result.files += 1
            do {
                if dryRun {
                    let s = try EchoSlim.slimFile(url, to: nil, policy: policy)
                    let w = worth(before: s.bytesIn, after: s.bytesOut)
                    result.bytesBefore += Int64(s.bytesIn)
                    result.bytesAfter += Int64(w ? s.bytesOut : s.bytesIn)
                    continue
                }
                let tmp = staging!.appendingPathComponent(UUID().uuidString + ".echo-tmp")
                let s = try EchoSlim.slimFile(url, to: tmp, policy: policy)
                result.bytesBefore += Int64(s.bytesIn)
                guard s.changedLines + s.droppedLines > 0, force || worth(before: s.bytesIn, after: s.bytesOut) else {
                    result.bytesAfter += Int64(s.bytesIn)
                    try? fm.removeItem(at: tmp)
                    continue
                }
                let old = try remove(url)
                do { try EchoBackup.place(tmp, at: url) } catch {
                    if let old, !fm.fileExists(atPath: url.path) { try? fm.moveItem(at: old, to: url) }
                    throw error
                }
                result.bytesAfter += Int64(s.bytesOut)
                result.rewritten += 1
            } catch {
                result.failures.append((String(url.path.dropFirst(root.path.count + 1)), error.localizedDescription))
            }
        }
        return result
    }
}
