// 交给另一台电脑（接力，规则见 CLAUDE.md「数据安全」）：换电脑接着聊之前，在这台电脑上把会话原样复制成交接副本，放进自己的备份文件夹
// （备份/<电脑名>/claude/接力/<会话ID>.jsonl，同名目录一起），再把本机这份移到废纸篓，这台就没法再接着聊、聊出分叉；
// 另一台「同步到本机」时有交接副本就用它（EchoRestore.from），思考过程、图片、密钥都在。
// 交接副本不精简、不打码，接手的那台备份里有了它的全部对话、或放了 30 天，这台下次备份时移到废纸篓。
import Foundation

enum EchoHandoff {
    struct Fail: LocalizedError { var errorDescription: String? }

    static let keepDays = 30

    /// 一台电脑 Claude 备份（claude/）里放交接副本的文件夹
    static func dir(_ claudeDir: URL) -> URL { claudeDir.appendingPathComponent("接力") }

    /// 这个会话所在电脑的交接副本，没有时 nil
    static func copy(for s: EchoSession, root: URL = EchoPrefs.backupRoot) -> URL? {
        guard s.app == .claude else { return nil }
        let u = dir(EchoLayout.dir(root.appendingPathComponent(s.computer), .claude)).appendingPathComponent(s.sessionId + ".jsonl")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// 另一台电脑上的会话要先在那台交出才能同步到本机，不然两台都能接着聊、聊出分叉。
    /// 那台交出了（有交接副本），或那台 30 天没备份过（当作已经停用）时放行；本机自己的（原会话被清理了）不拦
    static func mustHandOff(_ s: EchoSession, root: URL = EchoPrefs.backupRoot, me: String = EchoPrefs.computerName, now: Date = Date()) -> Bool {
        guard s.app == .claude, s.computer != me, copy(for: s, root: root) == nil else { return false }
        let rec = EchoLayout.dir(root.appendingPathComponent(s.computer), .claude).appendingPathComponent("备份记录.json")
        guard let last = EchoBackupRecord.load(rec).lastSuccess else { return false }
        return now.timeIntervalSince(last) < Double(keepDays) * 86400
    }

    /// 本机交出去的会话 ID（交接副本还在的）
    static func handedOff(_ claudeDir: URL = EchoPrefs.claudeDir) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir(claudeDir).path)) ?? []
        return Set(files.filter { $0.hasSuffix(".jsonl") && !$0.hasPrefix(".") }.map { String($0.dropLast(6)) })
    }

    // MARK: git

    /// 跑一条 git 命令，返回输出；失败（不是仓库、没有上游）返回 nil
    static func git(_ dir: String, _ args: [String]) -> String? {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir] + args
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.environment = (ProcessInfo.processInfo.environment).merging(["GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C"]) { _, n in n }   // 只读：status 不顺手改索引
        do { try p.run() } catch { return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: d, as: UTF8.self) : nil
    }

    /// 会话文件夹所在的仓库和它的各个工作区里，换电脑会丢的改动：没提交的文件（含未跟踪的）、没推送的提交、没推送过的分支。
    /// 不在仓库里、文件夹不在本机时返回空；仓库没有远端时只查没提交的
    static func gitProblems(_ cwd: String) -> [String] {
        let fm = FileManager.default
        guard !cwd.isEmpty, fm.fileExists(atPath: cwd), let top = git(cwd, ["rev-parse", "--show-toplevel"])?.trimmed, !top.isEmpty else { return [] }
        let remote = !(git(top, ["remote"])?.trimmed ?? "").isEmpty
        var trees: [(path: String, branch: String?)] = []
        for block in (git(top, ["worktree", "list", "--porcelain"]) ?? "").components(separatedBy: "\n\n") {
            var path: String?, branch: String?
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
                if line.hasPrefix("branch refs/heads/") { branch = String(line.dropFirst(18)) }
            }
            if let path, fm.fileExists(atPath: path) { trees.append((path, branch)) }   // 另一台电脑建的工作区（路径不在本机）不查
        }
        if trees.isEmpty { trees = [(top, nil)] }
        var out: [String] = []
        for t in trees {
            let name = (t.path as NSString).abbreviatingWithTildeInPath
            let changed = (git(t.path, ["status", "--porcelain"]) ?? "").split(separator: "\n").count
            if changed > 0 { out.append("\(name)：\(changed) 个文件没提交") }
            guard remote, let b = t.branch else { continue }
            if git(t.path, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]) == nil {
                out.append("\(name)：分支「\(b)」没推送到远端")
            } else if let n = Int(git(t.path, ["rev-list", "--count", "@{u}..HEAD"])?.trimmed ?? ""), n > 0 {
                out.append("\(name)：\(n) 个提交没推送")
            }
        }
        return out
    }

    // MARK: 交出

    /// 原样复制成交接副本（同名目录一起），再把本机的会话文件和同名目录移到废纸篓。返回交接副本。
    /// 正在 Claude 里开着、2 分钟内还在写的不交；git 由调用的地方先查（要把问题列给用户看）
    @discardableResult
    static func handOff(original: URL, sessionId: String, claudeDir: URL = EchoPrefs.claudeDir,
                        open: (String) -> Bool = { EchoMove.isOpen($0) },
                        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
                        now: Date = Date()) throws -> URL {
        if open(sessionId) { throw Fail(errorDescription: "此会话正在 Claude 中打开，请先退出再交") }
        if EchoRename.isActive(original) { throw Fail(errorDescription: "此会话 2 分钟内还有写入，请稍后再交") }
        let fm = FileManager.default
        let d = dir(claudeDir)
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        let dest = d.appendingPathComponent(sessionId + ".jsonl"), destSub = d.appendingPathComponent(sessionId)
        let sub = original.deletingPathExtension()
        // 以前交过一次的旧副本先移走
        for u in [dest, destSub] where fm.fileExists(atPath: u.path) { try trash(u) }
        // 先写到临时名字，写完、大小对上再改名：另一台电脑不会拿到写了一半的副本
        let tmp = d.appendingPathComponent(".\(sessionId).jsonl"), tmpSub = d.appendingPathComponent(".\(sessionId)")
        for u in [tmp, tmpSub] { try? fm.removeItem(at: u) }
        do {
            if fm.fileExists(atPath: sub.path) { try fm.copyItem(at: sub, to: tmpSub) }
            try fm.copyItem(at: original, to: tmp)
            let a = try fm.attributesOfItem(atPath: original.path)[.size] as? Int64, b = try fm.attributesOfItem(atPath: tmp.path)[.size] as? Int64
            guard a == b else { throw Fail(errorDescription: "复制会话没有完成，请重试") }
            if fm.fileExists(atPath: tmpSub.path) { try fm.moveItem(at: tmpSub, to: destSub) }
            try fm.moveItem(at: tmp, to: dest)
            try fm.setAttributes([.modificationDate: now], ofItemAtPath: dest.path)   // 修改时间记交出的时间，按它算 30 天
        } catch {
            for u in [tmp, tmpSub, dest, destSub] { try? fm.removeItem(at: u) }
            throw error
        }
        try trash(original)
        if fm.fileExists(atPath: sub.path) { try trash(sub) }
        return dest
    }

    /// 交出前把这个会话照常备份一次（会话文件和同名目录），交出后备份里也是最新的
    static func backupOne(_ original: URL, source: URL = EchoBackup.source, claudeDir: URL = EchoPrefs.claudeDir) throws {
        let rel = original.deletingLastPathComponent().lastPathComponent + "/" + original.lastPathComponent
        let pre = String(rel.dropLast(6)) + "/"
        let items = try EchoBackup.claudeItems(source).filter { $0.rel == rel || $0.rel.hasPrefix(pre) }
        let r = try EchoBackup.run(items: items, computerDir: claudeDir, policy: EchoPrefs.policy)
        if let f = r.failures.first { throw Fail(errorDescription: "备份此会话失败：\(f.message)") }
    }

    // MARK: 接手

    /// 自动接手：另一台电脑交出的会话（它的交接副本），这台备份前自动同步到本机，不用再点「同步到本机」。
    /// 本机有这个会话、交接副本接着它聊了：本机这份移到废纸篓，原位置换成交接副本（EchoRestore.replace）；
    /// 本机没有：写到本机对应的文件夹（EchoRestore.guessFolder），找不到文件夹的留给用户手动同步。
    /// 本机已包含、两边分叉、本机正开着或 2 分钟内还在写的不动。done 记已经看过的交接副本（电脑/会话 ID/修改时间），同一份只看一次：
    /// 用户之后删掉或改动本机这份，不会被同一份交接副本再写回来。还在 iCloud 云端的先叫它下载，下次再看。
    /// 返回接手的会话（标题、来自哪台电脑）和新的 done
    static func receive(root: URL = EchoPrefs.backupRoot, me: String = EchoPrefs.computerName, source: URL = EchoBackup.source,
                        claudeDir: URL = EchoPrefs.claudeDir, done: Set<String>,
                        open: (String) -> Bool = { EchoMove.isOpen($0) },
                        trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
                        guess: (String) -> String? = { EchoRestore.guessFolder($0) }) -> (got: [(title: String, from: String)], done: Set<String>) {
        let fm = FileManager.default
        var done = done, got: [(title: String, from: String)] = []
        let others = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent != me && !$0.lastPathComponent.hasPrefix(".") }
        for c in others {
            let d = dir(EchoLayout.dir(c, .claude))
            let files = ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.pathExtension == "jsonl" && !$0.lastPathComponent.hasPrefix(".") }
            for f in files {
                let sid = String(f.lastPathComponent.dropLast(6)), sub = f.deletingPathExtension()
                let cloud = ([f] + ((fm.enumerator(at: sub, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? [])).map(\.path).filter(EchoCloud.isPlaceholder)
                if !cloud.isEmpty { EchoCloud.download(cloud); continue }
                let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
                let key = "\(c.lastPathComponent)/\(sid)/\(Int(mtime))"
                if done.contains(key) { continue }
                let meta = (try? EchoSessionScan.read(f)) ?? EchoSessionMeta()
                let s = EchoSession(url: f, sessionId: sid, computer: c.lastPathComponent, size: 0, meta: meta)
                let title = meta.title.isEmpty || meta.title == sid ? "未命名会话" : meta.title
                do {
                    switch EchoRestore.state(s, from: f, source: source) {
                    case .upToDate, .diverged:
                        done.insert(key)   // 已包含的不用接；分叉的留给用户在「同步到本机」里选
                    case .newer(let local, _):
                        if open(sid) || EchoRename.isActive(local) { continue }   // 下次再接
                        try EchoRestore.replace(s, from: f, local: local, open: open, trash: trash)
                        done.insert(key); got.append((title, c.lastPathComponent))
                    case .missing:
                        done.insert(key)
                        guard let folder = guess(meta.cwd) else { continue }   // 找不到本机对应的文件夹：留给用户手动同步
                        try EchoRestore.restore(s, from: f, to: folder, source: source, claudeDir: claudeDir)
                        got.append((title, c.lastPathComponent))
                    }
                } catch { NSLog("回响自动接手失败：%@：%@", f.path, error.localizedDescription) }
            }
        }
        return (got, done)
    }

    // MARK: 清理

    /// 这台电脑的交接副本：别的电脑的备份（或本机拿回来的会话）已有它的全部对话，或交出超过 30 天的，移到废纸篓。
    /// root 是备份位置，me 是本机电脑名，source 是本机 ~/.claude/projects。还在 iCloud 云端没下载的备份先不比，下次再看。返回移走了几个
    @discardableResult
    static func cleanup(root: URL = EchoPrefs.backupRoot, me: String = EchoPrefs.computerName, source: URL = EchoBackup.source, now: Date = Date(),
                        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> Int {
        let fm = FileManager.default
        let d = dir(EchoLayout.dir(root.appendingPathComponent(me), .claude))
        let files = ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "jsonl" && !$0.lastPathComponent.hasPrefix(".") }
        guard !files.isEmpty else { return 0 }
        let others = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent != me && !$0.lastPathComponent.hasPrefix(".") }
        func find(_ sid: String, in projects: URL) -> URL? {
            for p in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
                let u = p.appendingPathComponent(sid + ".jsonl")
                if fm.fileExists(atPath: u.path) { return u }
            }
            return nil
        }
        var n = 0
        for f in files {
            let sid = String(f.lastPathComponent.dropLast(6))
            let age = now.timeIntervalSince((try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now)
            var done = age > Double(keepDays) * 86400
            if !done {
                let ids = EchoRestore.messageIDs(f)
                var holders = others.flatMap { c in EchoLayout.sessionRoots(c).filter { $0.source == .claude }.compactMap { find(sid, in: $0.root) } }
                if let mine = EchoRestore.existing(sid, source: source) { holders.append(mine) }
                done = holders.contains { !EchoCloud.isPlaceholder($0.path) && ids.isSubset(of: EchoRestore.messageIDs($0)) }
            }
            guard done else { continue }
            do {
                try trash(f)
                let sub = f.deletingPathExtension()
                if fm.fileExists(atPath: sub.path) { try trash(sub) }
                n += 1
            } catch { NSLog("回响移走交接副本失败：%@：%@", f.path, error.localizedDescription) }
        }
        return n
    }
}
