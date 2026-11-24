// 同步到本机：把回响备份里的 Claude Code 会话写回本机 ~/.claude/projects，用 claude --resume 接着聊（规则见 CLAUDE.md「数据安全」）。
// 本机没有这个会话时新写一份；本机有、另一台电脑接着聊了而本机这份之后没动过时，用新版本替换（本机这份先移到废纸篓）；
// 两边各自接着聊过（分叉了）时不自动替换，由用户选。用于另一台电脑上的会话，或本机原会话已被清理的。备份是精简过的：对话全文都在，没有思考过程，到期的工具输出是占位，密钥打码；接着聊不受影响（11-24 实测过）。
// 会话 ID 不变；会话文件里记的工作目录还是原来的，回响用移动记录显示本机的文件夹。
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

    /// 本机这份和备份这份比：按对话消息（你说的话、AI 回的话，备份里永远保留）的 uuid 比，精简不改 uuid
    enum State: Equatable {
        case missing                                  // 本机没有：新写一份
        case newer(local: URL, added: Int)            // 备份接着本机这份聊了 added 条：替换
        case upToDate(local: URL)                     // 本机这份已经包含备份里的全部对话
        case diverged(local: URL, mine: Int, theirs: Int)   // 两边各有对方没有的：mine 条只在本机，theirs 条只在备份
    }

    /// 一个会话文件里对话消息的 uuid（EchoStorage.kind 判断的「对话消息」：不含工具结果、系统记录、思考）
    static func messageIDs(_ url: URL) -> Set<String> {
        var ids = Set<String>()
        try? EchoLines.each(url) { line in
            let b = EchoLines.trim(line)
            guard EchoStorage.kind(b).isMessage, let j = RawJSON.parse(b), let u = j[RawJSON.quoted("uuid")]?.stringRaw, let id = EchoSlim.decode(u) else { return }
            ids.insert(id)
        }
        return ids
    }

    static func state(_ s: EchoSession, source: URL = EchoBackup.source) -> State {
        guard let local = existing(s.sessionId, source: source) else { return .missing }
        let mine = messageIDs(local), theirs = messageIDs(s.url)
        let onlyMine = mine.subtracting(theirs).count, onlyTheirs = theirs.subtracting(mine).count
        if onlyTheirs == 0 { return .upToDate(local: local) }
        if onlyMine == 0 { return .newer(local: local, added: onlyTheirs) }
        return .diverged(local: local, mine: onlyMine, theirs: onlyTheirs)
    }

    /// 用备份替换本机这份：本机的会话文件和同名目录先移到废纸篓（trash 测试时换成直接删），再写备份；位置不变，修改时间改成现在。
    /// 正在 Claude 里开着、2 分钟内还在写的不换
    static func replace(_ s: EchoSession, local: URL, open: (String) -> Bool = { EchoMove.isOpen($0) },
                        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }, now: Date = Date()) throws {
        guard s.app == .claude else { throw Fail(errorDescription: "目前只能同步 Claude Code 的会话") }
        if open(s.sessionId) { throw Fail(errorDescription: "此会话正在 Claude 中打开，请先关闭再同步") }
        if EchoRename.isActive(local) { throw Fail(errorDescription: "此会话 2 分钟内还有写入，请稍后再同步") }
        let fm = FileManager.default
        let sub = local.deletingPathExtension(), from = s.url.deletingPathExtension()
        try trash(local)
        if fm.fileExists(atPath: sub.path) { try trash(sub) }
        if fm.fileExists(atPath: from.path) { try fm.copyItem(at: from, to: sub) }
        try fm.copyItem(at: s.url, to: local)
        try fm.setAttributes([.modificationDate: now], ofItemAtPath: local.path)
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
        guard s.app == .claude else { throw Fail(errorDescription: "目前只能同步 Claude Code 的会话") }
        if let u = existing(s.sessionId, source: source) {
            throw Fail(errorDescription: "本机已有此会话（\(u.deletingLastPathComponent().lastPathComponent)），不再新写一份")
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
