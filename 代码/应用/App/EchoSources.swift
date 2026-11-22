// 多应用：会话从哪些应用来，备份里怎么分文件夹。需求见 需求文档/版本需求/待定-多应用支持.html。
// 备份目录/<电脑名>/claude/（projects/、备份记录.json、移动记录.json）、备份目录/<电脑名>/codex/（sessions/…）；
// 已删除统计.json 还在电脑这一级（各应用合在一起）。0.7 及以前 Claude 的东西直接放在电脑这一级，本机第一次用新版时挪进 claude/，
// 另一台电脑没升级时还写在老位置，读的时候两种都认。
import Foundation

enum EchoSource: String, CaseIterable, Codable, Identifiable {
    case claude, codex, workbuddy
    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .workbuddy: "WorkBuddy"
        }
    }

    /// 备份目录/<电脑名>/ 下的子文件夹名
    var folder: String { rawValue }
}

enum EchoLayout {
    /// 这台电脑某个应用的备份文件夹
    static func dir(_ computerDir: URL, _ s: EchoSource) -> URL { computerDir.appendingPathComponent(s.folder) }

    /// 一台电脑的备份里放会话的几个根目录（存在的）：claude/projects、codex/sessions，没升级的电脑还有电脑这一级的 projects
    static func sessionRoots(_ computerDir: URL) -> [(source: EchoSource, root: URL)] {
        let fm = FileManager.default
        let all: [(EchoSource, URL)] = [
            (.claude, dir(computerDir, .claude).appendingPathComponent("projects")),
            (.claude, computerDir.appendingPathComponent("projects")),
            (.codex, dir(computerDir, .codex).appendingPathComponent("sessions")),
        ]
        // 会话目录本身是符号链接时跟到真实位置（列目录不会自己跟进去）；路径上别处的链接不动，合集的键还按备份目录截
        return all.filter { fm.fileExists(atPath: $0.1.path) }.map { s, u in
            (s, (try? fm.destinationOfSymbolicLink(atPath: u.path)).map { URL(fileURLWithPath: $0, relativeTo: u.deletingLastPathComponent()).standardizedFileURL } ?? u)
        }
    }

    /// Claude 那几样（会话目录、备份记录、移动记录）在哪：新位置 claude/ 有就用它，否则（没升级的电脑）是电脑这一级
    static func claudeDirs(_ computerDir: URL) -> [URL] {
        let fm = FileManager.default
        return [dir(computerDir, .claude), computerDir].filter { fm.fileExists(atPath: $0.appendingPathComponent("projects").path) }
    }

    /// 0.7 及以前放在电脑这一级的 Claude 备份挪进 claude/：只在备份文件夹里改名，不碰 ~/.claude。
    /// 一样一样挪（每样一次改名，挪到一半退出，下次接着挪）；新位置已经有同名的就不动，留给人看。返回挪了几样
    @discardableResult
    static func migrate(_ computerDir: URL) throws -> Int {
        let fm = FileManager.default
        let to = dir(computerDir, .claude)
        var moved = 0
        for name in ["projects", "备份记录.json", "移动记录.json"] {
            let old = computerDir.appendingPathComponent(name), new = to.appendingPathComponent(name)
            guard fm.fileExists(atPath: old.path) else { continue }
            if fm.fileExists(atPath: new.path) {
                NSLog("回响：%@ 新旧位置都有，没挪：%@", name, old.path)
                continue
            }
            try fm.createDirectory(at: to, withIntermediateDirectories: true)
            try fm.moveItem(at: old, to: new)
            moved += 1
        }
        if moved > 0 { EchoCleanRecord.rename(prefix: computerDir.appendingPathComponent("projects").path + "/", to: to.appendingPathComponent("projects").path + "/") }
        return moved
    }
}
