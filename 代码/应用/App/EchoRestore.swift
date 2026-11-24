// 恢复到本机：把回响备份里的 Claude Code 会话写回本机 ~/.claude/projects，用 claude --resume 接着聊（规则见 CLAUDE.md「数据安全」）。
// 用于另一台电脑上的会话，或本机原会话已被清理的。备份是精简过的：对话全文都在，没有思考过程，到期的工具输出是占位，密钥打码；接着聊不受影响（11-24 实测过）。
// 只新建，不覆盖：本机任何文件夹里已有同一个会话 ID 就不恢复。会话 ID 不变；会话文件里记的工作目录还是原来的，回响用移动记录显示本机的文件夹。
import Foundation

enum EchoRestore {
    struct Fail: LocalizedError { var errorDescription: String? }

    /// 本机 projects 下有没有这个会话（在哪个文件夹都算）
    static func existing(_ id: String, source: URL = EchoBackup.source) -> URL? {
        let fm = FileManager.default
        for d in (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? [] {
            let u = d.appendingPathComponent(id + ".jsonl")
            if fm.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    /// 本机对应的文件夹：原路径在本机就用它；把另一台电脑的主目录换成本机的再找；再按文件夹名找（EchoDirMove.guess）。都没有返回 nil，让用户选
    static func guessFolder(_ cwd: String, home: String = NSHomeDirectory(), spotlight: Bool = true) -> String? {
        let fm = FileManager.default
        func isDir(_ p: String) -> Bool { var d: ObjCBool = false; return fm.fileExists(atPath: p, isDirectory: &d) && d.boolValue }
        guard cwd.hasPrefix("/") else { return nil }
        if isDir(cwd) { return cwd }
        var mapped = cwd
        let parts = cwd.split(separator: "/")
        if parts.count >= 2, parts[0] == "Users" { mapped = ([home] + parts.dropFirst(2).map(String.init)).joined(separator: "/") }
        if isDir(mapped) { return mapped }
        return EchoDirMove.guess(mapped, spotlight: spotlight)?.path
    }

    /// 写回本机：<source>/<文件夹编码>/<会话ID>.jsonl，同名目录（子代理、工具结果）一起；修改时间改成现在，免得被当成很久没用、又被自动清理；
    /// 记一条移动记录（claudeDir 是这台电脑 Claude 的备份），回响显示本机的文件夹。返回写好的会话文件
    @discardableResult
    static func restore(_ s: EchoSession, to dir: String, source: URL = EchoBackup.source, claudeDir: URL = EchoPrefs.claudeDir, now: Date = Date()) throws -> URL {
        guard s.app == .claude else { throw Fail(errorDescription: "目前只能恢复 Claude Code 的会话") }
        if let u = existing(s.sessionId, source: source) {
            throw Fail(errorDescription: "本机已有此会话（\(u.deletingLastPathComponent().lastPathComponent)），不再恢复")
        }
        let fm = FileManager.default
        let dest = source.appendingPathComponent(EchoMove.projectDirName(dir))
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let file = dest.appendingPathComponent(s.sessionId + ".jsonl")
        let sub = s.url.deletingPathExtension(), subDest = dest.appendingPathComponent(s.sessionId)
        if fm.fileExists(atPath: sub.path), !fm.fileExists(atPath: subDest.path) { try fm.copyItem(at: sub, to: subDest) }
        try fm.copyItem(at: s.url, to: file)
        try fm.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)   // 新电脑还没备份过时没有这个文件夹
        try EchoMoved.add([s.sessionId: dir], claudeDir)
        return file
    }
}
