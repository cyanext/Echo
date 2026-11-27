// 回归测试：瘦身、消息显示和原型（代码/原型/slim.py、export.py）的结果一致，备份挑文件的规则。
// 由 tests/run.sh 编译运行：test <会话.jsonl> <原型瘦身结果> <原型 data.js>；test --rules <假会话>
// 手动验收全量备份：test --backup <临时目录>（把本机会话备份到临时目录，跑两遍看耗时）
import Foundation
import AppKit
import SwiftUI

@main
enum EchoTests {
    static var failed = 0

    static func check(_ ok: Bool, _ what: @autoclosure () -> String) {
        if !ok { failed += 1; print("  ✗ \(what())") }
    }

    static func main() throws {
        let a = CommandLine.arguments
        // 截图、整理演示数据时把本机当成这台电脑（总览只统计本机会话所在文件夹的提交）
        if let c = ProcessInfo.processInfo.environment["ECHO_SHOT_COMPUTER"] { EchoPrefs.computerName = c }
        if a.count >= 2, a[1] == "--shot", let r = ProcessInfo.processInfo.environment["ECHO_SHOT_ROOT"] { EchoPrefs.backupRoot = URL(fileURLWithPath: r) }   // 设置页截图读这个备份目录
        if a.count >= 2, a[1] == "--ech" {   // 对着 ECHO_SHOT_ROOT 这个备份目录跑 ech 命令（README 里的示例输出），索引在测试用的临时目录
            if let r = ProcessInfo.processInfo.environment["ECHO_SHOT_ROOT"] { EchoPrefs.backupRoot = URL(fileURLWithPath: r) }
            exit(EchoCLI.main(Array(a.dropFirst(2))))
        }
        if a.count == 3, a[1] == "--rules" { rules(); try renameTest(fixture: URL(fileURLWithPath: a[2])); try statsTest(); try commitMatchTest(); timeTest(); try cleanTest(); try layoutTest(); try backupRootTest(); try pathTest(); try mvLinkTest(); try echTest(); try codexMoveTest(); try codexBackupTest(); try autoDeleteTest(); try claudeSettingsTest(); try updateTest(); try emptySessionTest(); menuBarTest(); resumeTest(); try restoreTest(); try handoffTest(); mergeTest(); try mediaTest(); try cloudTest(); try openTest() }
        else if a.count == 4, a[1] == "--overview" {   // 手动排查：按应用的方式整理总览数据，写到文件，看用了多久
            let t0 = Date()
            let list = EchoLibrary.scan(backupRoot: URL(fileURLWithPath: a[2]))
            let t1 = Date()
            let data = EchoStats.build(list, deleted: EchoDeleted.loadAll(URL(fileURLWithPath: a[2])))
            try data.write(to: URL(fileURLWithPath: a[3]))
            print(String(format: "  %d 个会话，扫列表 %.1f 秒，整理总览 %.1f 秒，%d KB", list.count, t1.timeIntervalSince(t0), Date().timeIntervalSince(t1), data.count / 1024))
        }
        else if a.count >= 5, a[1] == "--record-deleted" {   // 补记已删除统计：test --record-deleted <电脑备份目录> <删除时间 ISO> <会话.jsonl…>
            let dir = URL(fileURLWithPath: a[2]), when = EchoTime.parse(a[3]) ?? Date()
            var out: [EchoDeletedSession] = []
            for f in a.dropFirst(4) {
                let u = URL(fileURLWithPath: f), m = try EchoSessionScan.read(u)
                let s = EchoSession(url: u, sessionId: String(u.lastPathComponent.dropLast(6)), computer: dir.lastPathComponent, size: 0, meta: m)
                let r = try EchoDeleted.make(s, at: when)
                print("  \(r.sid.prefix(8))  \(r.t)  \(r.cwd)  \(r.days.count) 天")
                out.append(r)
            }
            try EchoDeleted.add(out, dir)
        }
        else if a.count == 3, a[1] == "--prices" {   // 手动排查：解析一份 LiteLLM 价格表，列出留下的模型
            let m = EchoPrices.parse(try Data(contentsOf: URL(fileURLWithPath: a[2])))
            print("  留下 \(m.count) 个模型")
            for k in m.keys.sorted() where ["gpt-6.1-sol", "gpt-5.5", "claude-opus-5-5", "claude-sonnet-5-5", "glm-5.2", "kimi-k3", "hy3"].contains(k) { print("  \(k)：\(m[k]!)") }
        }
        else if a.count == 3, a[1] == "--cat" {   // 按行读一个文件原样写到标准输出（.zst 边读边解压），和 zstd -dc 比对
            let out = FileHandle.standardOutput
            try EchoLines.each(URL(fileURLWithPath: a[2])) { l in autoreleasepool { out.write(Data(buffer: l)) } }
        }
        else if a.count == 3, a[1] == "--backup" { try backup(URL(fileURLWithPath: a[2])) }
        else if a.count == 3, a[1] == "--backup-codex" {   // 手动验收：本机 Codex 会话全量备份到 <目录>（不是电脑目录，是 codex 这一级），跑两遍
            for n in 1...2 {
                let r = try EchoBackup.run(items: EchoBackup.codexItems(EchoBackup.codexSource), computerDir: URL(fileURLWithPath: a[2]))
                print(String(format: "  第 %d 遍：%d 个文件，写入 %d，跳过 %d，失败 %d，%.0fMB → %.0fMB，%.1f 秒",
                             n, r.total, r.copied, r.skipped, r.failures.count, Double(r.bytesIn) / 1e6, Double(r.bytesOut) / 1e6, r.seconds))
                for f in r.failures.prefix(5) { print("    \(f.path)：\(f.message)") }
            }
        }
        else if a.count == 3, a[1] == "--time" { try timeExport(URL(fileURLWithPath: a[2])) }
        else if a.count == 3, a[1] == "--clean-estimate" {   // 手动排查：按默认保留期限估算一台电脑的备份能释放多少（只算不改）
            let t0 = Date()
            let r = try EchoClean.run(computerDir: URL(fileURLWithPath: a[2]), policy: EchoPolicy(), dryRun: true)
            print(String(format: "  %d 个文件，%.0fMB → %.0fMB，%.1f 秒", r.files, Double(r.bytesBefore) / 1e6, Double(r.bytesAfter) / 1e6, Date().timeIntervalSince(t0)))
        }
        else if a.count == 4, a[1] == "--autodelete-preview" {   // 手动排查：按期限列出会被自动删除的会话（只列不删）：test --autodelete-preview <电脑备份目录> <天数>
            let list = EchoAutoDelete.candidates(source: EchoBackup.source, computerDir: URL(fileURLWithPath: a[2]), days: Int(a[3]) ?? 30)
            for c in list { print(String(format: "  %@  %.1fMB", c.rel, Double(c.bytes) / 1e6)) }
            print(String(format: "  共 %d 个，%.0fMB", list.count, Double(list.reduce(0) { $0 + $1.bytes }) / 1e6))
        }
        else if a.count >= 4, a[1] == "--shot" {   // 离屏截图界面，不弹窗口：test --shot <settings-general|settings-storage|onboarding-N> <输出.png> [dark] [等几秒]
            try MainActor.assumeIsolated { try shot(a[2], to: URL(fileURLWithPath: a[3]), dark: a.contains("dark"), wait: Double(a.last!) ?? 3) }
        }
        else if a.count == 4, a[1] == "--slim" {   // 手动排查：按默认保留期限瘦身一个文件，看用时和改了多少
            let t0 = Date()
            let s = try EchoSlim.slimFile(URL(fileURLWithPath: a[2]), to: URL(fileURLWithPath: a[3]))
            print(String(format: "  %.0fMB → %.0fMB，去掉 %d 行，改写 %d 行，%.1f 秒", Double(s.bytesIn) / 1e6, Double(s.bytesOut) / 1e6, s.droppedLines, s.changedLines, Date().timeIntervalSince(t0)))
        }
        else if a.count == 4, a[1] == "--scan" {   // 手动排查：按应用的方式扫备份目录，看某个会话在不在、归到哪
            let list = EchoLibrary.scan(backupRoot: URL(fileURLWithPath: a[2]))
            print("  扫到 \(list.count) 个会话")
            let fm = FileManager.default
            for c in (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: a[2]), includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
                for p in EchoLayout.sessionRoots(c).flatMap({ (try? fm.contentsOfDirectory(at: $0.root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] }) {
                    for f in (try? fm.contentsOfDirectory(at: p, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles)) ?? [] where f.lastPathComponent.hasPrefix(a[3]) {
                        print("  目录里有：\(f.lastPathComponent)，扩展名 \(f.pathExtension)，属性 \(String(describing: try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]).fileSize))")
                        do { let m = try EchoSessionScan.read(f); print("  读出：标题「\(m.title)」开始 \(m.start)") } catch { print("  读出错：\(error)") }
                    }
                }
            }
            for s in list where s.url.lastPathComponent.hasPrefix(a[3]) { print("  \(s.url.lastPathComponent)：标题「\(s.meta.title)」，项目 \(s.projectPath)，开始 \(s.meta.start)") }
        }
        else if a.count == 4, a[1] == "--slim-compare" { try compare(URL(fileURLWithPath: a[2]), slimmed: URL(fileURLWithPath: a[3]), dataJS: nil) }   // 只比瘦身（Codex 会话等）
        else if a.count == 4, a[1] == "--export" { try compareExport(URL(fileURLWithPath: a[2]), dataJS: URL(fileURLWithPath: a[3])) }
        else if a.count == 4 { try compare(URL(fileURLWithPath: a[1]), slimmed: URL(fileURLWithPath: a[2]), dataJS: URL(fileURLWithPath: a[3])) }
        else { print("用法：test <会话.jsonl> <原型瘦身结果> <原型 data.js> 或 test --rules"); exit(2) }
        if failed > 0 { print("失败 \(failed) 项"); exit(1) }
    }

    /// 总览的数：我的消息只算人打的字；同一次回复拆成几行按 requestId 只算一次；AI 干活取 turn_duration；写缓存分 5 分钟和 1 小时
    /// 空会话（只有一条 /resume 这类命令，没有你的消息也没有 AI 回复）不列出、不备份
    static func emptySessionTest() throws {
        let fm = FileManager.default, t = fm.temporaryDirectory.appendingPathComponent("回响空会话-" + UUID().uuidString)
        defer { try? fm.removeItem(at: t) }
        let src = t.appendingPathComponent("projects/-tmp-p"), comp = t.appendingPathComponent("备份/电脑/claude")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        let cmd = #"{"type":"user","uuid":"u1","timestamp":"2026-11-23T03:11:00.000Z","cwd":"/tmp/p","sessionId":"e","message":{"role":"user","content":"<command-name>/resume</command-name>\n<command-message>resume</command-message>\n<command-args>dc18a693</command-args>"}}"#
        let ask = #"{"type":"user","uuid":"u2","timestamp":"2026-11-23T03:12:00.000Z","cwd":"/tmp/p","sessionId":"n","origin":{"kind":"human"},"message":{"role":"user","content":"你好"}}"#
        try (cmd + "\n").write(to: src.appendingPathComponent("e.jsonl"), atomically: true, encoding: .utf8)
        try (ask + "\n").write(to: src.appendingPathComponent("n.jsonl"), atomically: true, encoding: .utf8)
        check(try EchoSessionScan.read(src.appendingPathComponent("e.jsonl")).empty == true, "只有 /resume 的会话应算空会话")
        check(try EchoSessionScan.read(src.appendingPathComponent("n.jsonl")).empty == nil, "有你的消息的会话不算空会话")
        _ = try EchoBackup.run(source: t.appendingPathComponent("projects"), computerDir: comp)
        check(!fm.fileExists(atPath: comp.appendingPathComponent("projects/-tmp-p/e.jsonl").path), "空会话不该备份")
        check(fm.fileExists(atPath: comp.appendingPathComponent("projects/-tmp-p/n.jsonl").path), "正常会话应备份")
        let listed = EchoLibrary.scan(backupRoot: t.appendingPathComponent("备份")).map(\.sessionId)
        check(listed == ["n"], "列表只该有正常会话，实际 \(listed)")
        print("  空会话 5 项")
    }

    /// 另一台电脑的备份只在 iCloud 云端时：列表、索引、总览都先跳过不读、记进等下载；改过的先照上次的显示，下完再读新的
    static func cloudTest() throws {
        let fm = FileManager.default, t = fm.temporaryDirectory.appendingPathComponent("回响云端-" + UUID().uuidString)
        defer { try? fm.removeItem(at: t); EchoCloud.fake = [] }
        let root = t.appendingPathComponent("备份"), dir = root.appendingPathComponent("另一台/claude/projects/-tmp-p")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        func ask(_ text: String) -> String { #"{"type":"user","uuid":"\#(UUID().uuidString)","timestamp":"2026-11-20T02:59:00Z","cwd":"/tmp/p","origin":{"kind":"human"},"message":{"role":"user","content":"\#(text)"}}"# }
        func reply(_ rid: String) -> String { #"{"type":"assistant","timestamp":"2026-11-20T03:00:00Z","requestId":"\#(rid)","message":{"model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":10}}}"# }
        let a = dir.appendingPathComponent("a.jsonl"), b = dir.appendingPathComponent("b.jsonl"), c = dir.appendingPathComponent("c.jsonl")
        try [ask("第一句"), reply("a1")].joined(separator: "\n").write(to: a, atomically: true, encoding: .utf8)
        try [ask("别的"), reply("b1")].joined(separator: "\n").write(to: b, atomically: true, encoding: .utf8)
        func tokens(_ d: Data) -> [String: Double] {
            let o = try! JSONSerialization.jsonObject(with: d) as! [String: Any]
            return Dictionary(uniqueKeysWithValues: (o["sessions"] as! [[String: Any]]).map { x in
                (x["id"] as! String, ((x["days"] as! [String: Any]).values.first as! [String: Any])["k"].flatMap { ($0 as! [String: [Double]])["claude-opus-5-5"]?[1] } ?? 0)
            })
        }
        var s = EchoLibrary.scan(backupRoot: root, skipCloud: true)
        check(s.sessions.count == 2 && s.waiting.isEmpty, "云端：都下载了时照常列出")
        _ = try EchoIndex.update(s)
        _ = EchoStats.build(s.sessions, skipCloud: true)
        // 另一台电脑接着聊了 a，又新开了 c，两个都还没下载
        try [ask("第一句"), reply("a1"), ask("第二句"), reply("a2")].joined(separator: "\n").write(to: a, atomically: true, encoding: .utf8)
        try [ask("新的"), reply("c1")].joined(separator: "\n").write(to: c, atomically: true, encoding: .utf8)
        let real = s.sessions[0].url.deletingLastPathComponent()   // 扫出来的是 /private/var/… 这样的真实路径
        let pa = real.appendingPathComponent("a.jsonl").path, pc = real.appendingPathComponent("c.jsonl").path
        EchoCloud.fake = [pa, pc]
        s = EchoLibrary.scan(backupRoot: root, skipCloud: true)
        check(Set(s.sessions.map(\.sessionId)) == ["a", "b"], "云端：改过的先照上次的列出，新的等下完，实际 \(s.sessions.map(\.sessionId))")
        check(Set(s.waiting) == [pa, pc], "云端：没下载的记进等下载")
        check(try EchoIndex.update(s).waiting == [pa], "云端：索引先不做改过的")
        var (data, wait) = EchoStats.build(s.sessions, skipCloud: true)
        let ida = s.sessions.first { $0.sessionId == "a" }!.id
        check(wait == [pa] && tokens(data)[ida] == 10, "云端：总览先算上次的，实际 \(wait) \(tokens(data))")
        // 下完了
        EchoCloud.fake = []
        s = EchoLibrary.scan(backupRoot: root, skipCloud: true)
        check(s.sessions.count == 3 && s.waiting.isEmpty, "云端：下完补进列表")
        check(try EchoIndex.update(s).changed == 2, "云端：下完补进索引")
        (data, wait) = EchoStats.build(s.sessions, skipCloud: true)
        check(wait.isEmpty && tokens(data)[ida] == 20, "云端：下完总览算新的，实际 \(tokens(data))")
        print("  iCloud 云端 7 项")
    }

    /// 同步到本机：本机没有时写回 projects/<文件夹编码>/，同名目录一起；修改时间改成现在；记移动记录；本机已有同一个 ID 不再新写；猜本机对应的文件夹；
    /// 本机有时按对话消息的 uuid 比新旧：备份接着聊了就替换（本机这份进废纸篓），本机已包含就不动，分叉了交给用户
    static func restoreTest() throws {
        let fm = FileManager.default
        let t = fm.temporaryDirectory.appendingPathComponent("回响恢复-\(UUID().uuidString)").standardizedFileURL
        defer { try? fm.removeItem(at: t) }
        let backup = t.appendingPathComponent("备份/另一台/claude/projects/-Users-other-p"), source = t.appendingPathComponent("projects"), claudeDir = t.appendingPathComponent("备份/本机/claude")
        try fm.createDirectory(at: backup.appendingPathComponent("s1/subagents"), withIntermediateDirectories: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let line = #"{"type":"user","uuid":"u1","sessionId":"s1","timestamp":"2026-10-01T00:00:00Z","cwd":"/Users/other/p","origin":{"kind":"human"},"message":{"role":"user","content":"旧会话"}}"# + "\n"
        try line.write(to: backup.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
        try line.write(to: backup.appendingPathComponent("s1/subagents/agent-a.jsonl"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86400 * 60)], ofItemAtPath: backup.appendingPathComponent("s1.jsonl").path)
        let s = EchoSession(url: backup.appendingPathComponent("s1.jsonl"), sessionId: "s1", computer: "另一台", size: 1, meta: EchoSessionMeta(title: "旧会话", cwd: "/Users/other/p", start: "", end: ""))
        let dir = t.appendingPathComponent("本机项目").path
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let f = try EchoRestore.restore(s, to: dir, source: source, claudeDir: claudeDir).resolvingSymlinksInPath()
        check(f.path == source.appendingPathComponent(EchoMove.projectDirName(dir) + "/s1.jsonl").path, "恢复：写到新文件夹对应的项目目录，实际 \(f.path)")
        check((try? String(contentsOf: f, encoding: .utf8)) == line, "恢复：会话内容原样写回")
        check(fm.fileExists(atPath: f.deletingPathExtension().appendingPathComponent("subagents/agent-a.jsonl").path), "恢复：同名目录（子代理）一起写回")
        let mtime = (try? fm.attributesOfItem(atPath: f.path)[.modificationDate] as? Date) ?? .distantPast
        check(Date().timeIntervalSince(mtime) < 60, "恢复：修改时间改成现在，免得马上被自动清理")
        check(EchoMoved.load(claudeDir)["s1"] == dir, "恢复：记移动记录，按本机文件夹显示")
        check(EchoRestore.existing("s1", source: source) != nil, "恢复：恢复后本机能找到这个会话")
        do { try EchoRestore.restore(s, to: t.path, source: source, claudeDir: claudeDir); check(false, "恢复：本机已有同一个会话时应拒绝") } catch {}
        // 猜文件夹：原路径在本机就用它；另一台电脑的主目录换成本机的
        let home = t.appendingPathComponent("home").path
        try fm.createDirectory(atPath: home + "/Projects/订单服务", withIntermediateDirectories: true)
        check(EchoRestore.guessFolder(dir, home: home, spotlight: false) == dir, "恢复：原路径在本机就用它")
        check(EchoRestore.guessFolder("/Users/other/Projects/订单服务", home: home, spotlight: false) == home + "/Projects/订单服务", "恢复：换成本机主目录后找到")
        check(EchoRestore.guessFolder("/Users/other/没有的文件夹", home: home, spotlight: false) == nil, "恢复：找不到时让用户选")
        // 比新旧：本机这份（u1）、备份接着聊了（u1 u2）、本机也接着聊了另一句（u1 u3）
        func msg(_ id: String, _ text: String) -> String {
            #"{"type":"user","uuid":"\#(id)","sessionId":"s1","timestamp":"2026-10-01T00:00:00Z","cwd":"/Users/other/p","origin":{"kind":"human"},"message":{"role":"user","content":"\#(text)"}}"# + "\n"
        }
        func st() -> EchoRestore.State {
            switch EchoRestore.state(s, source: source) {   // 临时目录有 /var 和 /private/var 两种写法，比之前统一
            case .missing: return .missing
            case .upToDate(let u): return .upToDate(local: u.resolvingSymlinksInPath())
            case .newer(let u, let n): return .newer(local: u.resolvingSymlinksInPath(), added: n)
            case .diverged(let u, let a, let b): return .diverged(local: u.resolvingSymlinksInPath(), mine: a, theirs: b)
            }
        }
        check(st() == .upToDate(local: f), "同步：刚写回的和备份一样，已是最新")
        try (line + msg("u2", "另一台接着聊")).write(to: s.url, atomically: true, encoding: .utf8)
        check(st() == .newer(local: f, added: 1), "同步：备份多了 1 条，算新版本，实际 \(st())")
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -600)], ofItemAtPath: f.path)   // 2 分钟内写过的不换
        try EchoRestore.replace(s, local: f, open: { _ in false }, trash: { try fm.removeItem(at: $0) }, now: Date())
        check((try? String(contentsOf: f, encoding: .utf8))?.contains("另一台接着聊") == true, "同步：用新版本替换本机这份")
        check(fm.fileExists(atPath: f.deletingPathExtension().appendingPathComponent("subagents/agent-a.jsonl").path), "同步：替换时同名目录也换成备份里的")
        try (line + msg("u3", "本机也聊了")).write(to: f, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -600)], ofItemAtPath: f.path)
        check(st() == .diverged(local: f, mine: 1, theirs: 1), "同步：两边各有新内容算分叉，实际 \(st())")
        do { try EchoRestore.replace(s, local: f, open: { _ in true }, trash: { try fm.removeItem(at: $0) }); check(false, "同步：会话开着时不该替换") } catch {}
        check(fm.fileExists(atPath: f.path), "同步：没替换成时本机这份还在")
        print("  同步到本机 16 项")
    }

    /// 交给另一台电脑：原样复制成交接副本、本机这份移走；另一台同步时用交接副本；接手后、30 天后交接副本移走；git 有没提交没推送的拦下
    static func handoffTest() throws {
        let fm = FileManager.default
        let t = fm.temporaryDirectory.appendingPathComponent("回响接力-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: t) }
        func msg(_ id: String, _ text: String) -> String {
            #"{"type":"user","uuid":"\#(id)","sessionId":"h1","timestamp":"2026-10-01T00:00:00Z","cwd":"/Users/a/p","origin":{"kind":"human"},"message":{"role":"user","content":"\#(text)"},"thinking":"原样的思考"}"# + "\n"
        }
        let root = t.appendingPathComponent("备份"), srcA = t.appendingPathComponent("A/projects"), srcB = t.appendingPathComponent("B/projects")
        let claudeA = root.appendingPathComponent("A/claude"), claudeB = root.appendingPathComponent("B/claude")
        let orig = srcA.appendingPathComponent("-Users-a-p/h1.jsonl")
        try fm.createDirectory(at: orig.deletingPathExtension().appendingPathComponent("subagents"), withIntermediateDirectories: true)
        let body = msg("u1", "第一句") + msg("u2", "第二句")
        try body.write(to: orig, atomically: true, encoding: .utf8)
        try "子代理".write(to: orig.deletingPathExtension().appendingPathComponent("subagents/a.jsonl"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -600)], ofItemAtPath: orig.path)
        // A 的精简备份（只有 u1，模拟备份落后）
        let slimA = claudeA.appendingPathComponent("projects/-Users-a-p/h1.jsonl")
        try fm.createDirectory(at: slimA.deletingLastPathComponent(), withIntermediateDirectories: true)
        try msg("u1", "第一句").write(to: slimA, atomically: true, encoding: .utf8)
        let rm: (URL) throws -> Void = { try fm.removeItem(at: $0) }
        // 没交出的不能在另一台同步：A 最近备份过时拦，A 30 天没备份过时放行，本机自己的不拦
        let sA = EchoSession(url: slimA, sessionId: "h1", computer: "A", size: 1, meta: EchoSessionMeta(title: "", cwd: "/Users/a/p", start: "", end: ""))
        let recA = claudeA.appendingPathComponent("备份记录.json")
        try EchoBackupRecord(lastSuccess: Date(timeIntervalSinceNow: -40 * 86400)).save(recA)
        check(!EchoHandoff.mustHandOff(sA, root: root, me: "B"), "接力：那台 30 天没备份过时能直接同步")
        try EchoBackupRecord(lastSuccess: Date(timeIntervalSinceNow: -3600)).save(recA)
        check(EchoHandoff.mustHandOff(sA, root: root, me: "B"), "接力：A 上的会话没交出时 B 不能同步")
        check(!EchoHandoff.mustHandOff(sA, root: root, me: "A"), "接力：本机自己的会话不拦")
        do { try EchoHandoff.handOff(original: orig, sessionId: "h1", claudeDir: claudeA, open: { _ in true }, trash: rm); check(false, "接力：开着的会话不该交出") } catch {}
        check(fm.fileExists(atPath: orig.path), "接力：没交出时本机这份还在")
        let copy = try EchoHandoff.handOff(original: orig, sessionId: "h1", claudeDir: claudeA, open: { _ in false }, trash: rm)
        check(copy.path == claudeA.appendingPathComponent("接力/h1.jsonl").path, "接力：交接副本放在 claude/接力/，实际 \(copy.path)")
        check((try? String(contentsOf: copy, encoding: .utf8)) == body, "接力：交接副本和原文件一样")
        check(fm.fileExists(atPath: copy.deletingPathExtension().appendingPathComponent("subagents/a.jsonl").path), "接力：同名目录一起复制")
        check(!fm.fileExists(atPath: orig.path) && !fm.fileExists(atPath: orig.deletingPathExtension().path), "接力：本机这份和同名目录移走")
        check(EchoHandoff.handedOff(claudeA) == ["h1"], "接力：记得本机交出了哪些")
        check(!EchoHandoff.mustHandOff(sA, root: root, me: "B"), "接力：交出后 B 能同步")
        // B 同步：有交接副本时用它，原样写入
        let s = EchoSession(url: slimA, sessionId: "h1", computer: "A", size: 1, meta: EchoSessionMeta(title: "", cwd: "/Users/a/p", start: "", end: ""))
        check(EchoRestore.from(s, root: root).path == copy.path, "接力：同步时用交接副本")
        let dir = t.appendingPathComponent("B 的项目").path
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let got = try EchoRestore.restore(s, from: EchoRestore.from(s, root: root), to: dir, source: srcB, claudeDir: claudeB)
        check((try? String(contentsOf: got, encoding: .utf8)) == body, "接力：B 写入的是原样的交接副本")
        check(fm.fileExists(atPath: got.deletingPathExtension().appendingPathComponent("subagents/a.jsonl").path), "接力：B 写入时同名目录一起")
        // 自动接手：B 已包含时不动；B 是旧的时换成交接副本；B 没有时写到猜到的文件夹，猜不到不写；同一份只接一次
        func recv(_ done: Set<String> = [], guess: String? = nil) -> (got: [(title: String, from: String)], done: Set<String>) {
            EchoHandoff.receive(root: root, me: "B", source: srcB, claudeDir: claudeB, done: done, open: { _ in false }, trash: rm, guess: { _ in guess })
        }
        var r = recv()
        check(r.got.isEmpty && r.done.count == 1, "自动接手：本机已包含时不动，实际 \(r.got.count) 个")
        try msg("u1", "第一句").write(to: got, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -600)], ofItemAtPath: got.path)
        r = recv()
        check(r.got.count == 1 && r.got[0].from == "A" && (try? String(contentsOf: got, encoding: .utf8)) == body, "自动接手：本机是旧的时换成交接副本")
        try msg("u1", "第一句").write(to: got, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -600)], ofItemAtPath: got.path)
        check(recv(r.done).got.isEmpty && (try? String(contentsOf: got, encoding: .utf8)) == msg("u1", "第一句"), "自动接手：同一份交接副本只接一次")
        try fm.removeItem(at: got); try? fm.removeItem(at: got.deletingPathExtension())
        check(recv().got.isEmpty && EchoRestore.existing("h1", source: srcB) == nil, "自动接手：本机没有、找不到文件夹时不写")
        r = recv(guess: dir)
        check(r.got.count == 1 && (EchoRestore.existing("h1", source: srcB).flatMap { try? String(contentsOf: $0, encoding: .utf8) }) == body, "自动接手：本机没有时写到本机对应的文件夹")
        // 清理：B 的备份还没有它时不动；有了全部对话后移走
        check(EchoHandoff.cleanup(root: root, me: "A", source: srcA, trash: rm) == 0 && fm.fileExists(atPath: copy.path), "接力：没人接手时交接副本留着")
        let slimB = claudeB.appendingPathComponent("projects/-x/h1.jsonl")
        try fm.createDirectory(at: slimB.deletingLastPathComponent(), withIntermediateDirectories: true)
        try msg("u1", "第一句").write(to: slimB, atomically: true, encoding: .utf8)
        check(EchoHandoff.cleanup(root: root, me: "A", source: srcA, trash: rm) == 0, "接力：B 的备份少了对话时不移走")
        try (body + msg("u3", "B 接着聊")).write(to: slimB, atomically: true, encoding: .utf8)
        check(EchoHandoff.cleanup(root: root, me: "A", source: srcA, trash: rm) == 1 && !fm.fileExists(atPath: copy.path), "接力：B 接手后交接副本移走")
        check(!fm.fileExists(atPath: copy.deletingPathExtension().path), "接力：交接副本的同名目录一起移走")
        check(EchoRestore.from(s, root: root) == slimA, "接力：没有交接副本时用备份")
        // 30 天没人接
        try body.write(to: orig, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -600)], ofItemAtPath: orig.path)
        let c2 = try EchoHandoff.handOff(original: orig, sessionId: "h1", claudeDir: claudeA, open: { _ in false }, trash: rm, now: Date(timeIntervalSinceNow: -86400 * 31))
        try fm.removeItem(at: slimB)
        check(EchoHandoff.cleanup(root: root, me: "A", source: srcA, trash: rm) == 1 && !fm.fileExists(atPath: c2.path), "接力：30 天没人接的交接副本移走")
        // git：没提交的、没推送的拦下；干净的不拦；不是仓库的不查
        let repo = t.appendingPathComponent("仓库").path, remote = t.appendingPathComponent("远端.git").path
        func git(_ dir: String, _ a: String...) { _ = EchoHandoff.git(dir, a) }
        try fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
        git(t.path, "init", "-q", "--bare", remote)
        git(repo, "init", "-q", "-b", "main"); git(repo, "config", "user.email", "t@t"); git(repo, "config", "user.name", "t")
        try "a".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        check(EchoHandoff.gitProblems(repo).contains { $0.contains("1 个文件没提交") }, "接力：没提交的文件拦下，实际 \(EchoHandoff.gitProblems(repo))")
        git(repo, "add", "."); git(repo, "commit", "-q", "-m", "a")
        check(EchoHandoff.gitProblems(repo).isEmpty, "接力：没有远端的仓库只查没提交的")
        git(repo, "remote", "add", "origin", remote)
        check(EchoHandoff.gitProblems(repo).contains { $0.contains("没推送到远端") }, "接力：分支没推送过拦下")
        git(repo, "push", "-q", "-u", "origin", "main")
        check(EchoHandoff.gitProblems(repo).isEmpty, "接力：推送完不拦，实际 \(EchoHandoff.gitProblems(repo))")
        try "b".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        git(repo, "commit", "-q", "-am", "b")
        check(EchoHandoff.gitProblems(repo).contains { $0.contains("1 个提交没推送") }, "接力：没推送的提交拦下")
        git(repo, "push", "-q")
        git(repo, "worktree", "add", "-q", "-b", "主题", repo + "/.worktrees/主题")
        try "c".write(toFile: repo + "/.worktrees/主题/c.txt", atomically: true, encoding: .utf8)
        let p = EchoHandoff.gitProblems(repo)
        check(p.contains { $0.contains("主题：1 个文件没提交") } && p.contains { $0.contains("「主题」没推送到远端") }, "接力：工作区一起查，实际 \(p)")
        check(EchoHandoff.gitProblems(t.path).isEmpty, "接力：不在仓库里的文件夹不查")
        print("  交给另一台电脑 25 项")
    }

    /// 几台电脑上的同一个会话：一份包含另一份只留多的，一样多留本机的；分叉都留并标注；只有一台的不动
    static func mergeTest() {
        func ses(_ sid: String, _ c: String, _ end: String = "2026-11-20T00:00:00Z") -> EchoSession {
            EchoSession(url: URL(fileURLWithPath: "/备份/\(c)/claude/projects/p/\(sid).jsonl"), sessionId: sid, computer: c, size: 1, meta: EchoSessionMeta(title: sid, cwd: "/p", start: "", end: end))
        }
        let ids: [String: Set<String>] = ["/备份/A/claude/projects/p/s1.jsonl": ["1", "2"], "/备份/B/claude/projects/p/s1.jsonl": ["1", "2", "3"],
                                          "/备份/A/claude/projects/p/s2.jsonl": ["1", "2"], "/备份/B/claude/projects/p/s2.jsonl": ["1", "3"],
                                          "/备份/A/claude/projects/p/s3.jsonl": ["1"], "/备份/B/claude/projects/p/s3.jsonl": ["1"],
                                          "/备份/A/claude/projects/p/s4.jsonl": ["1"]]
        let out = EchoMerge.apply([ses("s1", "A"), ses("s1", "B"), ses("s2", "A"), ses("s2", "B"), ses("s3", "A"), ses("s3", "B", "2026-11-25T00:00:00Z"), ses("s4", "A")],
                                  me: "A", ids: { ids[$0.path] ?? [] })
        let got = out.map { "\($0.sessionId)@\($0.computer):\($0.merged ?? "")" }
        check(got.contains("s1@B:在 B 上接着聊过") && !got.contains { $0.hasPrefix("s1@A") }, "归组：包含时只留多的，标在哪台接着聊过，实际 \(got)")
        check(got.contains("s2@A:分叉") && got.contains("s2@B:分叉"), "归组：分叉都留，都标分叉")
        check(got.contains("s3@A:") && !got.contains { $0.hasPrefix("s3@B") }, "归组：一样多时留本机的")
        check(got.contains("s4@A:"), "归组：只有一台的不动")
        check(out.count == 5, "归组：7 个里留 5 个，实际 \(out.count)")
        print("  几台电脑上的同一个会话 5 项")
    }

    /// 图片和文件：默认不备份（换成占位、图片文件跳过）；设了期限时没到期的原样留着，到期的换成占位，备份下来的图片文件到期移走
    static func mediaTest() throws {
        let fm = FileManager.default
        let t = fm.temporaryDirectory.appendingPathComponent("回响图片-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: t) }
        try fm.createDirectory(at: t, withIntermediateDirectories: true)
        let img = String(repeating: "QUJD", count: 600)
        func line(_ ts: String) -> String {
            #"{"type":"user","uuid":"u","timestamp":"\#(ts)","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(img)"}},{"type":"text","text":"看这张图"}]}}"# + "\n"
        }
        let now = EchoTime.parse("2026-11-24T00:00:00Z")!
        func slim(_ l: String, _ media: Int) throws -> String {
            let src = t.appendingPathComponent("s.jsonl"), dst = t.appendingPathComponent("o.jsonl")
            try l.write(to: src, atomically: true, encoding: .utf8)
            var p = EchoPolicy(); p.media = media; p.now = now
            _ = try EchoSlim.slimFile(src, to: dst, policy: p)
            return try String(contentsOf: dst, encoding: .utf8)
        }
        check(try !slim(line("2026-11-23T00:00:00Z"), 0).contains(img), "图片：默认不备份，换成占位")
        check(try slim(line("2026-11-23T00:00:00Z"), 7).contains(img), "图片：保留 7 天时，昨天的原样留着")
        check(try !slim(line("2026-11-10T00:00:00Z"), 7).contains(img), "图片：保留 7 天时，两周前的换成占位")
        check(try slim(line("2026-01-01T00:00:00Z"), -1).contains(img), "图片：永久保留时一直留着")
        let d = UserDefaults.standard, saved = d.object(forKey: "keepMedia")
        defer { if let saved { d.set(saved, forKey: "keepMedia") } else { d.removeObject(forKey: "keepMedia") } }
        EchoPrefs.keepMedia = 0
        check(EchoBackupRule.action(for: "-p/s1/tool-results/a.png") == .skip, "图片文件：不备份时跳过")
        EchoPrefs.keepMedia = 7
        check(EchoBackupRule.action(for: "-p/s1/tool-results/a.png") == .copy, "图片文件：设了期限时照原样复制")
        // 清理：备份里的图片文件按修改时间到期移走
        let comp = t.appendingPathComponent("电脑"), dir = comp.appendingPathComponent("claude/projects/-p/s1/tool-results")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: dir.appendingPathComponent("old.png"))
        try Data([1, 2, 3]).write(to: dir.appendingPathComponent("new.png"))
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-86400 * 10)], ofItemAtPath: dir.appendingPathComponent("old.png").path)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-86400)], ofItemAtPath: dir.appendingPathComponent("new.png").path)
        var p = EchoPolicy(); p.media = 7; p.now = now
        _ = try EchoClean.run(computerDir: comp, policy: p, remove: { try fm.removeItem(at: $0); return nil })
        check(!fm.fileExists(atPath: dir.appendingPathComponent("old.png").path) && fm.fileExists(atPath: dir.appendingPathComponent("new.png").path), "清理：过期的图片文件移走，没到期的留着")
        p.media = 0
        _ = try EchoClean.run(computerDir: comp, policy: p, remove: { try fm.removeItem(at: $0); return nil })
        check(!fm.fileExists(atPath: dir.appendingPathComponent("new.png").path), "清理：改回不备份后，备份里的图片文件也移走")
        print("  图片和文件 8 项")
    }

    /// 复制恢复命令：到会话的文件夹，路径里的单引号要转义
    static func resumeTest() {
        check(EchoResume.command(.claude, cwd: "/Users/a/项目 A", id: "s1") == "cd '/Users/a/项目 A' && claude --resume s1", "恢复命令：Claude 用 claude --resume")
        check(EchoResume.command(.codex, cwd: "/tmp/x", id: "019d") == "cd '/tmp/x' && codex resume 019d", "恢复命令：Codex 用 codex resume")
        check(EchoResume.command(.claude, cwd: "/tmp/it's", id: "s2") == #"cd '/tmp/it'\''s' && claude --resume s2"#, "恢复命令：路径里的单引号转义")
        print("  恢复命令 3 项")
    }

    /// 菜单栏：状态行的文字、今天新增几个会话、最近会话
    static func menuBarTest() {
        func st(running: Bool = false, done: Int = 0, total: Int = 0, error: String? = nil, failures: Int = 0, stale: Int? = nil, cleanup: Int? = nil, last: Date? = nil,
                indexing: Bool = false, cloud: Int = 0) -> String {
            EchoMenuBar.statusText(running: running, done: done, total: total, error: error, failures: failures, staleDays: stale, cleanupDays: cleanup, last: last,
                                   indexing: indexing, cloud: cloud)
        }
        check(st(running: true, done: 48, total: 48, indexing: true) == "正在更新索引…", "备份拷完在更新索引时说更新索引")
        // 只在菜单栏时开着窗口才算普通应用：显示着的、缩到程序坞的普通窗口算，没显示的、提示框不算
        MainActor.assumeIsolated {
            _ = NSApplication.shared
            func win(_ panel: Bool = false) -> NSWindow {
                let r = NSRect(x: -4000, y: -4000, width: 100, height: 100)
                return panel ? NSPanel(contentRect: r, styleMask: [.titled], backing: .buffered, defer: false) : NSWindow(contentRect: r, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            }
            let shown = win(), hidden = win(), panel = win(true)
            shown.orderFront(nil); panel.orderFront(nil)
            check(EchoMenuBar.hasWindow([shown, hidden]) && !EchoMenuBar.hasWindow([hidden, panel]), "开着窗口的判断不对：显示着的应算，没显示的、提示框不算")
            shown.orderOut(nil); panel.orderOut(nil)
        }
        check(st(stale: 5, cloud: 12) == "正在从 iCloud 下载 12 个文件", "等 iCloud 下载时说下载几个文件")
        check(st(failures: 3, cloud: 12) == "3 个文件备份失败", "备份失败排在等 iCloud 下载前面")
        check(st(running: true, done: 12, total: 48, error: "x") == "正在备份 12/48", "正在备份时先说进度")
        check(st(running: true) == "正在备份…", "还没数出总数时只说正在备份")
        check(st(error: "备份文件夹无法写入", failures: 3) == "备份失败：备份文件夹无法写入", "备份失败写原因，排在文件失败前面")
        check(st(error: String(repeating: "长", count: 50)).count == "备份失败：".count + 41, "原因太长截到 40 个字")
        check(st(failures: 3, stale: 5) == "3 个文件备份失败", "有文件备份失败")
        check(st(stale: 5, cleanup: 30) == "已 5 天未备份", "多天没备份")
        check(st(cleanup: 30) == "Claude Code 会删除 30 天前的会话", "Claude Code 会删会话")
        check(st() == "尚未备份", "从没备份过")
        func s(_ id: String, start: String, end: String) -> EchoSession {
            var m = EchoSessionMeta(); m.title = id == "c" ? "c" : "会话 " + id; m.start = start; m.end = end
            return EchoSession(url: URL(fileURLWithPath: "/tmp/\(id).jsonl"), sessionId: id, computer: "电脑", size: 1, meta: m)
        }
        let list = [s("a", start: "2026-11-22T12:00:00.000Z", end: "2026-11-23T12:30:00.000Z"),
                    s("b", start: "2026-11-23T11:00:00.000Z", end: "2026-11-23T11:10:00.000Z"),
                    s("c", start: "2026-11-23T12:00:00.000Z", end: "2026-11-23T13:00:00.000Z")]
        check(EchoMenuBar.todayCount(list, now: EchoTime.parse("2026-11-23T12:00:00.000Z")!) == 2, "今天新增按开始时间算")
        check(EchoMenuBar.recent(list, limit: 2).map(\.sessionId) == ["c", "a"], "最近会话按最后使用时间排")
        check(EchoMenuBar.title(list[2]) == "未命名会话", "没有标题的写未命名会话")
        print("  菜单栏 15 项")
    }

    /// 检查更新的版本号比较，默认备份位置
    static func updateTest() throws {
        check(EchoUpdate.version(fromTag: "app-v0.13.0") == "0.13.0", "发版标签去掉 app-v")
        check(EchoUpdate.isNewer("0.13.0", than: "0.9.1"), "0.13.0 应比 0.9.1 新")
        check(!EchoUpdate.isNewer("0.12.0", than: "0.12.0"), "同一版本不算新")
        check(EchoUpdate.isNewer("1.0", than: "0.99.9") && !EchoUpdate.isNewer("0.12", than: "0.12.1"), "段数不同时补 0 比")
        let fm = FileManager.default, home = fm.temporaryDirectory.appendingPathComponent("回响默认位置-" + UUID().uuidString)
        defer { try? fm.removeItem(at: home) }
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let name = Locale.preferredLanguages.first?.hasPrefix("zh") == false ? "Echo Backup" : "回响备份"
        check(EchoPrefs.defaultBackupRoot(home: home).path == home.path + "/Documents/" + name, "没有 iCloud 云盘时放文稿里")
        try fm.createDirectory(at: home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"), withIntermediateDirectories: true)
        check(EchoPrefs.defaultBackupRoot(home: home).path == home.path + "/Library/Mobile Documents/com~apple~CloudDocs/" + name, "有 iCloud 云盘时放 iCloud 云盘里")
        try fm.createDirectory(at: home.appendingPathComponent("Desktop/项目代码/回响备份"), withIntermediateDirectories: true)
        check(EchoPrefs.defaultBackupRoot(home: home).path == home.path + "/Desktop/项目代码/回响备份", "旧的默认位置已有备份时接着用")
    }

    static func statsTest() throws {
        let rows = [
            #"{"type":"user","timestamp":"2026-11-20T02:00:00Z","message":{"role":"user","content":"做总览"},"origin":{"kind":"human"}}"#,
            #"{"type":"user","timestamp":"2026-11-20T02:00:01Z","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#,
            #"{"type":"user","timestamp":"2026-11-20T02:00:02Z","isMeta":true,"message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
            #"{"type":"assistant","timestamp":"2026-11-20T02:00:03Z","requestId":"r1","message":{"model":"claude-opus-5-5","usage":{"input_tokens":2,"output_tokens":100,"cache_read_input_tokens":1000,"cache_creation_input_tokens":50,"cache_creation":{"ephemeral_5m_input_tokens":10,"ephemeral_1h_input_tokens":40}}}}"#,
            #"{"type":"assistant","timestamp":"2026-11-20T02:00:04Z","requestId":"r1","message":{"model":"claude-opus-5-5","usage":{"input_tokens":2,"output_tokens":100,"cache_read_input_tokens":1000,"cache_creation_input_tokens":50}}}"#,
            #"{"type":"assistant","timestamp":"2026-11-20T02:00:05Z","requestId":"r2","message":{"model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}"#,
            #"{"type":"system","subtype":"turn_duration","timestamp":"2026-11-20T02:01:00Z","durationMs":60000}"#,
            #"{"type":"system","subtype":"turn_duration","timestamp":"2026-11-20T02:05:00Z","durationMs":30000}"#,
        ]
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("回响统计测试.jsonl")
        try rows.joined(separator: "\n").write(to: u, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: u) }
        let days = try EchoStats.read(u)
        let day = EchoStats.dayKey("2026-11-20T02:00:00Z")!
        let d = days[day]
        check(days.count == 1, "统计：应只有一天，实际 \(days.keys.sorted())")
        check(d?.m == 1, "统计：我的消息应 1 条（工具结果、命令不算），实际 \(d?.m ?? -1)")
        check(d?.k["claude-opus-5-5"] == [2, 100, 1000, 10, 40], "统计：同一 requestId 只算一次、写缓存分开，实际 \(d?.k ?? [:])")
        check(d?.k["<synthetic>"] == nil, "统计：<synthetic> 不算")
        check(d?.ms == 90000 && d?.lg == 60000, "统计：AI 干活 90 秒、最长 60 秒，实际 \(d?.ms ?? 0) \(d?.lg ?? 0)")
        check(EchoStats.project(NSHomeDirectory() + "/Desktop/项目代码/NAS/伙伴云NAS应用") == "NAS", "统计：项目取大目录下一级")
        check(EchoStats.project(NSHomeDirectory() + "/Desktop/项目代码/回响/.worktrees/主页") == "回响", "统计：.worktrees 算进上一级")
        // 已删除统计：删了照算，放回来不算两遍，同一个会话再删只留一条
        let cdir = FileManager.default.temporaryDirectory.appendingPathComponent("回响删除统计测试-\(UUID().uuidString)/机")
        defer { try? FileManager.default.removeItem(at: cdir.deletingLastPathComponent()) }
        let sess = EchoSession(url: u, sessionId: "s9", computer: "机", size: 0, meta: EchoSessionMeta(title: "删掉的", cwd: "/x/y", start: "2026-11-20T02:00:00Z", end: ""))
        try EchoDeleted.add([try EchoDeleted.make(sess)], cdir)
        try EchoDeleted.add([try EchoDeleted.make(sess)], cdir)
        let gone = EchoDeleted.loadAll(cdir.deletingLastPathComponent())
        check(gone.count == 1 && gone[0].days[day]?.m == 1 && gone[0].t == "删掉的", "已删除统计：应留一条、数不变，实际 \(gone.count) 条")
        func sessCount(_ live: [EchoSession]) -> (Int, Int) {
            let o = try! JSONSerialization.jsonObject(with: EchoStats.build(live, deleted: gone)) as! [String: Any]
            let ss = o["sessions"] as! [[String: Any]]
            return (ss.count, ss.filter { $0["x"] != nil }.count)
        }
        check(sessCount([]) == (1, 1), "已删除统计：删了以后总览应照算，实际 \(sessCount([]))")
        check(sessCount([sess]) == (1, 0), "已删除统计：放回来以后不应算两遍，实际 \(sessCount([sess]))")
        // 子代理的 Token 算进主会话；同一次请求在几个会话里只算一次，算给最早开始的
        let tdir = FileManager.default.temporaryDirectory.appendingPathComponent("回响跨会话统计-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tdir) }
        try FileManager.default.createDirectory(at: tdir.appendingPathComponent("a/subagents"), withIntermediateDirectories: true)
        func reply(_ rid: String, _ out: Int, _ ts: String = "2026-11-20T03:00:00Z") -> String {
            #"{"type":"assistant","timestamp":"\#(ts)","requestId":"\#(rid)","message":{"model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":\#(out)}}}"#
        }
        let ask = #"{"type":"user","timestamp":"2026-11-20T02:59:00Z","uuid":"u1","message":{"role":"user","content":"开始"},"origin":{"kind":"human"}}"#
        let ask2 = #"{"type":"user","timestamp":"2026-11-20T03:59:00Z","uuid":"u2","message":{"role":"user","content":"接着"},"origin":{"kind":"human"}}"#
        func took(_ uuid: String, _ ms: Int, _ ts: String) -> String {
            #"{"type":"system","subtype":"turn_duration","durationMs":\#(ms),"timestamp":"\#(ts)","uuid":"\#(uuid)"}"#
        }
        let tool = #"{"type":"user","timestamp":"2026-11-20T03:00:30Z","uuid":"x1","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#
        try [ask, reply("r1", 100), tool, took("t1", 60000, "2026-11-20T03:01:00Z")].joined(separator: "\n").write(to: tdir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        try reply("r9", 7).write(to: tdir.appendingPathComponent("a/subagents/agent-1.jsonl"), atomically: true, encoding: .utf8)
        try reply("r9", 7).write(to: tdir.appendingPathComponent("a/subagents/agent-2.jsonl"), atomically: true, encoding: .utf8)
        try [ask, reply("r1", 100), tool, took("t1", 60000, "2026-11-20T03:01:00Z"), ask2, reply("r3", 20, "2026-11-20T04:00:00Z"), took("t2", 30000, "2026-11-20T04:01:00Z")].joined(separator: "\n").write(to: tdir.appendingPathComponent("b.jsonl"), atomically: true, encoding: .utf8)
        check(try EchoStats.read(tdir.appendingPathComponent("a.jsonl"))[day]?.k["claude-opus-5-5"] == [2, 107, 0, 0, 0], "统计：子代理的 Token 算进主会话，两个子代理记录里同一次请求只算一次")
        let sa = EchoSession(url: tdir.appendingPathComponent("a.jsonl"), sessionId: "a", computer: "机", size: 0, meta: EchoSessionMeta(title: "原会话", cwd: "/x/y", start: "2026-11-20T02:59:00Z", end: ""))
        let sb = EchoSession(url: tdir.appendingPathComponent("b.jsonl"), sessionId: "b", computer: "机", size: 0, meta: EchoSessionMeta(title: "分叉出来的", cwd: "/x/y", start: "2026-11-20T03:30:00Z", end: ""))
        for _ in 0..<2 {   // 第二遍走缓存，结果要一样
            let o = try JSONSerialization.jsonObject(with: EchoStats.build([sb, sa])) as! [String: Any]
            let ds = Dictionary(uniqueKeysWithValues: (o["sessions"] as! [[String: Any]]).map { x in (x["t"] as! String, (x["days"] as! [String: Any])[day] as! [String: Any]) })
            let out = ds.mapValues { ($0["k"] as! [String: [Double]])["claude-opus-5-5"]! }
            check(out["原会话"] == [2, 107, 0, 0, 0] && out["分叉出来的"] == [1, 20, 0, 0, 0], "统计：分叉出来的会话不再算原会话的请求，实际 \(out)")
            let mm = ds.mapValues { [($0["m"] as! NSNumber).intValue, ($0["ms"] as! NSNumber).intValue] }
            check(mm["原会话"] == [1, 60000] && mm["分叉出来的"] == [1, 30000], "统计：分叉出来的会话不再算原会话的消息和 AI 干活时长，实际 \(mm)")
            let a = (ds["分叉出来的"]?["a"] as? NSNumber)?.doubleValue ?? 0
            check(a == ISO8601DateFormatter().date(from: "2026-11-20T03:59:00Z")!.timeIntervalSince1970, "统计：分叉出来的会话从自己的第一条算起止时间，实际 \(a)")
        }
        // Git：上级目录往下找两层里的仓库，.开头的不进；删掉的分支工作区换成主目录
        let fm = FileManager.default
        let top = fm.temporaryDirectory.appendingPathComponent("回响仓库测试-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: top) }
        for d in ["甲/.git", "乙/丙/.git", "乙/丙/丁/.git", "乙/.隐藏/.git", "戊/己/庚/.git"] {
            try fm.createDirectory(atPath: top + "/" + d, withIntermediateDirectories: true)
        }
        check(EchoStats.reposBelow(top).sorted() == [top + "/乙/丙", top + "/甲"], "统计：上级目录应找到两层内的仓库，实际 \(EchoStats.reposBelow(top))")
        check(EchoStats.reposBelow(NSHomeDirectory()).isEmpty, "统计：家目录不往下找")
        check(EchoStats.liveDir(top + "/甲/.worktrees/已删") == top + "/甲", "统计：删掉的分支工作区换成主目录")
        check(EchoStats.liveDir(top + "/没有") == nil, "统计：不存在的目录跳过")
        print("  总览统计：\(failed == 0 ? "通过" : "有失败")")
    }

    /// 清理备份：到期的换成占位、行数不变；旧文件进废纸篓（这里换成临时目录）；再跑一遍不动；没到门槛不重写，第一次（force）照样重写；估算不改文件
    /// 手写的时间解析和本地日期，要和系统格式器、Calendar 算的一样
    static func timeTest() {
        // 时间筛选「昨天」：昨天 0 点到今天 0 点，跨月、跨年的第一天也对
        let cal = Calendar.current
        for (now, from) in [("2026-11-26 09:30", "2026-11-25"), ("2026-12-01 00:00", "2026-11-30"), ("2027-01-01 23:59", "2026-12-31")] {
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"; let n = df.date(from: now)!
            df.dateFormat = "yyyy-MM-dd"
            let r = EchoDateFilter.range("y1", now: n)
            check(r?.lowerBound == df.date(from: from) && r?.upperBound == cal.startOfDay(for: n), "昨天的范围不对：\(now) → \(String(describing: r))")
        }
        check(EchoDateFilter.title("y1") == "昨天" && EchoDateFilter.short("y1") == "昨天", "昨天的名字不对")
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let g = ISO8601DateFormatter()
        for s in ["2026-11-04T11:41:10.072Z", "2026-02-28T23:59:59.999Z", "2024-02-29T16:00:00Z", "2000-01-01T00:00:00.5Z", "2026-12-31T15:59:60Z"] {
            let want = (f.date(from: s) ?? g.date(from: s))?.timeIntervalSince1970
            let got = EchoTime.fastEpoch(s)
            check(want == nil || abs((got ?? -1) - want!) < 0.001, "时间解析 \(s)：\(String(describing: got))，格式器 \(String(describing: want))")
            if let t = got {
                var o: [Int: Int] = [:]
                let c = Calendar.current.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: t))
                check(EchoStats.localDay(t, &o) == String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!), "本地日期 \(s) 不对")
            }
        }
        check(EchoTime.fastEpoch("2026-11-04 11:41:10") == nil && EchoTime.parse("2026-11-04T11:41:10+08:00") != nil, "认不出的格式应退回格式器")
        print("  时间解析 11 项")
    }

    /// 总览把提交挂到会话：从会话里的 git commit 命令取说明（-m、-qm、单引号、heredoc），从输出取提交号
    static func commitMatchTest() throws {
        let fm = FileManager.default
        let f = fm.temporaryDirectory.appendingPathComponent("echo-commit-\(getpid()).jsonl")
        defer { try? fm.removeItem(at: f) }
        func bash(_ cmd: String) -> String {
            let o: [String: Any] = ["type": "assistant", "timestamp": "2026-11-20T00:00:00Z", "message": ["id": "m", "content": [["type": "tool_use", "id": "t", "name": "Bash", "input": ["command": cmd]]]]]
            return String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)! + "\n"
        }
        let result: [String: Any] = ["type": "user", "timestamp": "2026-11-20T00:00:00Z", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t", "content": "[main 9affe6e] 改了点东西\n 2 files changed, 3 insertions(+)"]]]]
        let text = bash("cd /x && git add -A && git commit -qm \"总览：合计行不铺底，「合计」两个字用主色\n\nCo-Authored-By: x\"")
            + bash("git -C /y commit -m 'v0.7.1 整体提速'")
            + bash("git commit -m \"$(cat <<'EOF'\n修复 \\\"引号\\\" 的说明\n\n正文\nEOF\n)\"")
            + bash("echo git commit 不算")
            + String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)! + "\n"
        try text.write(to: f, atomically: true, encoding: .utf8)
        let g = try EchoStats.readAll(f).g
        let want: Set<String> = ["m:总览：合计行不铺底，「合计」两个字用主色", "m:v0.7.1 整体提速", "m:修复 \\\"引号\\\" 的说明", "9affe6e"]
        check(g == want, "提交挂会话：应取出 \(want.sorted())，实际 \(g.sorted())")
        check(EchoStats.commitKey("  一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十多出来\n正文") == "一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十", "提交说明取第一行前 30 字")
        print("  提交挂会话 2 项")
    }

    static func cleanTest() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("echo-clean-\(getpid())")
        defer { try? fm.removeItem(at: dir) }
        let proj = dir.appendingPathComponent("projects/-p")
        let bin = dir.appendingPathComponent("废纸篓")
        try fm.createDirectory(at: proj, withIntermediateDirectories: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        func line(_ o: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), encoding: .utf8)! + "\n" }
        let big = String(repeating: "旧参数", count: 2000)
        let a = line(["type": "assistant", "uuid": "a", "timestamp": "2026-09-01T00:00:00Z", "message": ["id": "m", "content": [["type": "tool_use", "id": "t", "name": "Read", "input": ["x": big]]]]])
            + line(["type": "user", "uuid": "b", "timestamp": "2026-11-20T00:00:00Z", "message": ["role": "user", "content": "新消息"]])
            + line(["type": "assistant", "uuid": "e", "timestamp": "2026-11-20T00:00:00Z", "message": ["id": "m3", "content": [["type": "tool_use", "id": "t3", "name": "Read", "input": ["x": "新参数，12-20 到期"]]]]])
        let f = proj.appendingPathComponent("a.jsonl")
        try a.write(to: f, atomically: true, encoding: .utf8)
        // 门槛：大文件里只有一小块能清，不重写；force 时重写
        let small = line(["type": "assistant", "uuid": "c", "timestamp": "2026-09-01T00:00:00Z", "message": ["id": "m2", "content": [["type": "tool_use", "id": "t2", "name": "Read", "input": ["x": "小"]]]]])
            + String(repeating: line(["type": "user", "uuid": "d", "timestamp": "2026-11-20T00:00:00Z", "message": ["role": "user", "content": String(repeating: "很多消息", count: 50)]]), count: 400)
        let g = proj.appendingPathComponent("b.jsonl")
        try small.write(to: g, atomically: true, encoding: .utf8)
        let gBefore = try Data(contentsOf: g)
        var policy = EchoPolicy()
        policy.now = EchoTime.parse("2026-11-21T00:00:00Z")!
        var n = 0
        let move: (URL) throws -> URL? = { u in n += 1; let t = bin.appendingPathComponent("\(n)-" + u.lastPathComponent); try fm.moveItem(at: u, to: t); return t }

        let est = try EchoClean.run(computerDir: dir, policy: policy, dryRun: true, remove: move)
        let fNow = try Data(contentsOf: f)
        check(est.freed > 0 && n == 0 && fNow == Data(a.utf8), "清理：估算应算出能释放、不动文件，实际释放 \(est.freed)，移走 \(n)")
        let r1 = try EchoClean.run(computerDir: dir, policy: policy, remove: move)
        let after = try String(contentsOf: f, encoding: .utf8)
        check(r1.rewritten == 1 && after.contains("已清理") && !after.contains("旧参数") && after.components(separatedBy: "\n").count == a.components(separatedBy: "\n").count,
              "清理：到期的工具参数应换成占位、行数不变，实际重写 \(r1.rewritten)")
        check(n == 1 && (try? Data(contentsOf: bin.appendingPathComponent("1-a.jsonl"))) == Data(a.utf8), "清理：旧文件应原样进废纸篓")
        let gNow = try Data(contentsOf: g)
        check(gNow == gBefore, "清理：没到门槛的文件不应重写")
        let r2 = try EchoClean.run(computerDir: dir, policy: policy, remove: move)
        check(r2.rewritten == 0 && n == 1, "清理：再跑一遍不应再动，实际重写 \(r2.rewritten)")
        let r3 = try EchoClean.run(computerDir: dir, policy: policy, force: true, remove: move)
        let gText = try String(contentsOf: g, encoding: .utf8)
        check(r3.rewritten == 1 && gText.contains("已清理"), "清理：第一次全部过一遍时没到门槛的也重写，实际 \(r3.rewritten)")
        // 记了清理记录：没到期的文件下次直接跳过
        let r4 = try EchoClean.run(computerDir: dir, policy: policy, remove: move)
        check(r4.skipped == 2 && r4.rewritten == 0, "清理：清理记录在、还没到期的应跳过，实际跳过 \(r4.skipped)")
        var later = policy
        later.now = EchoTime.parse("2026-12-31T00:00:00Z")!
        let r5 = try EchoClean.run(computerDir: dir, policy: later, dryRun: true, remove: move)
        check(r5.skipped < 2, "清理：到了最早到期的那天应重新看，实际跳过 \(r5.skipped)")
        check(EchoSlim.sizeText(512) == "512 B" && EchoSlim.sizeText(3482) == "3.4 KB" && EchoSlim.sizeText(130 << 20) == "130 MB" && EchoSlim.sizeText(1288490189) == "1.2 GB", "大小写法不对")
        print("  清理 9 项")
    }

    /// 备份分应用放（0.8）：老布局挪进 claude/、挪一次就好、清理记录跟着改；没升级的电脑照样读；同一个会话两处都有只算一次；合集的键不变
    /// 左栏的目录：替身换成真实路径（~/Desktop/客户文档 → ~/伙伴云NAS/客户文档）、查不到的部分原样接上，抽象的文件夹归组
    static func pathTest() throws {
        let fm = FileManager.default
        let t = EchoPath.real(fm.temporaryDirectory.path) + "/echo-path-\(getpid())"
        defer { try? fm.removeItem(atPath: t) }
        try fm.createDirectory(atPath: t + "/NAS/客户文档/甲", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: t + "/桌面", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: t + "/桌面/客户文档", withDestinationPath: "../NAS/客户文档")
        check(EchoPath.real(t + "/桌面/客户文档/甲") == t + "/NAS/客户文档/甲", "替身没换成真实路径：\(EchoPath.real(t + "/桌面/客户文档/甲"))")
        check(EchoPath.real(t + "/桌面/客户文档/已删/乙") == t + "/NAS/客户文档/已删/乙", "查不到的部分应原样接上")
        check(EchoPath.real(t + "/没有/丙") == t + "/没有/丙", "不存在的路径应原样返回")
        let home = NSHomeDirectory()
        check(EchoPath.parts(home + "/.claude/jobs/d219103f/tmp/codex-x").comps == ["Codex 后台任务"], "Codex 后台任务没归组")
        check(EchoPath.parts(home + "/Documents/Codex/2026-09-25/ni-k").comps == ["Codex 临时对话"], "Codex 临时对话没归组")
        check(EchoPath.parts("/private/tmp/claude-501/x/scratchpad").comps == ["临时文件夹"], "临时文件夹没归组")
        check(EchoStats.project(home + "/Documents/New project") == "Codex 默认项目", "New project 没换名字")
        print("  目录路径 7 项")
    }

    /// ech mv：旧路径是指向新路径的软链时只挪会话、软链留在原处（新路径写软链路径或真实路径都认），普通文件夹照旧改名
    static func mvLinkTest() throws {
        let fm = FileManager.default
        let t = fm.temporaryDirectory.path + "/echo-mv-\(getpid())"   // 不解析软链：/var 本身是软链，下面拿真实路径再比一次
        defer { try? fm.removeItem(atPath: t) }
        try fm.createDirectory(atPath: t + "/code/NAS", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: t + "/桌面/旧", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: t + "/桌面/NAS", withDestinationPath: t + "/code/NAS")
        let a = t + "/桌面/NAS", b = t + "/code/NAS"
        let r = EchoCLI.mvTarget(from: a, to: b)
        check(r.to == b && !r.moveFolder && r.link, "指向新路径的软链应只挪会话：\(r)")
        let r2 = EchoCLI.mvTarget(from: a, to: EchoPath.real(b))
        check(r2.to == EchoPath.real(b) && !r2.moveFolder && r2.link, "新路径写真实路径也应认出软链：\(r2)")
        check(EchoCLI.mvTarget(from: t + "/桌面/旧", to: t + "/code") == (t + "/code/旧", true, false, false), "普通文件夹挪进已有的文件夹不对")
        check(EchoCLI.mvTarget(from: t + "/桌面/旧", to: t + "/桌面/新") == (t + "/桌面/新", true, false, false), "普通文件夹改名不对")
        // 新路径下原有的会话不算要挪的；执行后软链还在，新路径里没多出软链
        let other = { (id: String, cwd: String) in EchoSession(url: URL(fileURLWithPath: "/x/\(id).jsonl"), sessionId: id, computer: "别的电脑", size: 1, meta: EchoSessionMeta(title: id, cwd: cwd, start: "", end: "")) }
        let p = EchoDirMove.plan(from: a, to: b, sessions: [other("l1", a + "/子"), other("l2", b), other("l3", b + "/子")], moveFolder: r.moveFolder)
        check(p.skipped.map(\.sessionId) == ["l1"] && p.count == 0, "新路径下原有的会话被算进来了：\(p.skipped.map(\.sessionId))")
        _ = try EchoDirMove.run(p)
        check((try? fm.destinationOfSymbolicLink(atPath: a)) == b && !fm.fileExists(atPath: b + "/NAS"), "软链被挪走了")
        print("  ech mv 软链 6 项")
    }

    /// ech：分段（开头、版本提交后、跨天、压缩）、版本号只认说明开头、引用的写法
    /// 移动 Codex 会话：只改假数据库里这一行的 cwd，改前有整份备份，记进移动记录；2 分钟内还在写的不动
    static func codexMoveTest() throws {
        let fm = FileManager.default
        let t = fm.temporaryDirectory.appendingPathComponent("回响Codex移动-\(getpid())")
        try? fm.removeItem(at: t)
        try fm.createDirectory(at: t, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: t) }
        let dbURL = t.appendingPathComponent("state_5.sqlite")
        do {
            let db = try EchoDB(dbURL)
            try db.exec("CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT NOT NULL, title TEXT NOT NULL DEFAULT '')")
            try db.exec("INSERT INTO threads(id, cwd) VALUES ('c1', '/旧/项目'), ('c2', '/旧/项目'), ('c3', '/别处')")
        }
        let old = t.appendingPathComponent("old.jsonl"), fresh = t.appendingPathComponent("fresh.jsonl")
        try Data("{}".utf8).write(to: old); try Data("{}".utf8).write(to: fresh)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.path)
        func sess(_ id: String) -> EchoSession {
            EchoSession(url: t.appendingPathComponent(id + ".jsonl"), sessionId: id, computer: EchoPrefs.computerName, size: 1,
                        meta: EchoSessionMeta(title: id, cwd: "/旧/项目", start: "x", end: "x"), app: .codex)
        }
        let backups = t.appendingPathComponent("备份"), movedDir = t.appendingPathComponent("codex")
        try fm.createDirectory(at: movedDir, withIntermediateDirectories: true)
        let r = EchoCodexMove.move([sess("c1"), sess("c2")], to: "/新/项目", db: dbURL, backups: backups, movedDir: movedDir,
                                   original: { $0.sessionId == "c1" ? old : fresh })
        var cwd: [String: String] = [:]
        try EchoDB(dbURL, readonly: true).rows("SELECT id, cwd FROM threads") { cwd[$0.text(0)] = $0.text(1) }
        check(r.done.map(\.sessionId) == ["c1"] && r.error != nil, "应只移动 c1，c2 正在写应报错：\(r.done.map(\.sessionId))")
        check(cwd == ["c1": "/新/项目", "c2": "/旧/项目", "c3": "/别处"], "只该改 c1 那一行：\(cwd)")
        check(EchoMoved.load(movedDir) == ["c1": "/新/项目"], "应记进移动记录")
        let baks = (try? fm.contentsOfDirectory(atPath: backups.path)) ?? []
        var before = ""
        if let b = baks.first { try EchoDB(backups.appendingPathComponent(b), readonly: true).rows("SELECT cwd FROM threads WHERE id='c1'") { before = $0.text(0) } }
        check(baks.count == 1 && before == "/旧/项目", "改前应整份备份：\(baks)")
        let none = EchoCodexMove.move([sess("c9")], to: "/新/项目", db: dbURL, backups: backups, movedDir: movedDir, original: { _ in old })
        check(none.done.isEmpty && none.error != nil, "Codex 里没有的会话应报错")
        print("  移动 Codex 会话 5 项")
    }

    static func echTest() throws {
        let rows = [
            #"{"type":"user","timestamp":"2026-11-20T02:00:00Z","uuid":"u1","message":{"role":"user","content":"开始做"},"origin":{"kind":"human"}}"#,
            #"{"type":"assistant","timestamp":"2026-11-20T02:01:00Z","uuid":"a1","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"git commit -m \"v0.1.0 第一版\""}}]}}"#,
            #"{"type":"user","timestamp":"2026-11-20T02:01:01Z","uuid":"r1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#,
            #"{"type":"assistant","timestamp":"2026-11-20T02:02:00Z","uuid":"a2","message":{"id":"m2","role":"assistant","content":[{"type":"text","text":"提交好了。"}]}}"#,
            #"{"type":"user","timestamp":"2026-11-21T02:00:00Z","uuid":"u2","message":{"role":"user","content":"第二天接着做"},"origin":{"kind":"human"}}"#,
            #"{"type":"system","subtype":"compact_boundary","timestamp":"2026-11-21T03:00:00Z","uuid":"s1","compactMetadata":{"trigger":"manual"}}"#,
            #"{"type":"user","timestamp":"2026-11-21T03:00:01Z","uuid":"u3","isCompactSummary":true,"message":{"role":"user","content":"压缩后的总结。"}}"#,
            #"{"type":"user","timestamp":"2026-11-21T03:01:00Z","uuid":"u4","message":{"role":"user","content":"继续"},"origin":{"kind":"human"}}"#,
        ]
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("回响分段测试.jsonl")
        try rows.joined(separator: "\n").write(to: u, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: u) }
        let turns = try EchoExport.export(u, computer: "x", withLines: true)["turns"] as! [[String: Any]]
        let segs = EchoIndex.segments(turns)
        check(segs.map(\.kind) == ["开头", "版本后", "跨天", "压缩"], "分段不对：\(segs.map(\.kind))")
        check(segs.first?.vers == ["0.1.0"] && segs.first?.l1 == 2, "第 1 段应在第 2 行的版本提交结束：\(segs.first.map { "\($0.vers) \($0.l1)" } ?? "")")
        check(segs.last?.head == "压缩后的总结。" && segs.last?.l0 == 7, "压缩段应从阶段总结开始：\(segs.last.map { "\($0.l0) \($0.head)" } ?? "")")
        check(EchoIndex.rows(turns).map(\.role) == ["我", "工具", "AI", "我", "总结", "我"], "进索引的行不对：\(EchoIndex.rows(turns).map(\.role))")
        check(EchoIndex.versionKey("后台接口 v0.14.2：会议改名撞名") == "后台接口 0.14.2", "模块版本号没认出")
        check(EchoIndex.versionKey("v0.8.1 左栏日期筛选") == "0.8.1", "开头的版本号没认出")
        check(EchoIndex.versionKey("合并「目录筛选」分支：v0.8.2") == nil, "合并提交不算版本")
        check(EchoIndex.versionKey("总览：提交按会话挂") == nil, "没有版本号的说明不该认出版本")
        check(EchoCLI.short("019d52b6-7616-72e1-9780-037355606bcd") == "019d52b6-7616" && EchoCLI.short("ce57ce36-7e31-45fd-b076-5262412dae73") == "ce57ce36", "引用的短写法不对")
        check(EchoCLI.splitRef("ce57ce36#L10-20") == ("ce57ce36", "L10-20") && EchoCLI.splitRef("ce57ce36").1 == nil, "引用拆不开")
        // 猜新位置：去掉序号后比共同的字，取最像的
        let fm = FileManager.default
        let t = EchoPath.real(fm.temporaryDirectory.path) + "/echo-guess-\(getpid())"
        defer { try? fm.removeItem(atPath: t) }
        for n in ["02 二期项目", "01 一期项目", "会议", "客户数据清洗", "team-doc-style", "服务器 cyanext/html-to-md-api", "a/b/c/d/深处"] { try fm.createDirectory(atPath: t + "/" + n, withIntermediateDirectories: true) }
        func g(_ n: String) -> EchoDirMove.Guess? { EchoDirMove.guess(t + "/" + n, spotlight: false) }
        check(g("项目二期") == .init(path: t + "/02 二期项目", moved: false), "没猜出改名为「02 二期项目」：\(String(describing: g("项目二期")))")
        check(g("客户资料") == nil, "不像的不该猜")
        check(g("html-to-md-api") == .init(path: t + "/服务器 cyanext/html-to-md-api", moved: true), "没猜出挪进了「服务器 cyanext」：\(String(describing: g("html-to-md-api")))")
        check(g("notes-api") == nil, "英文名按单词比，没有共同的单词不该猜（原来按字母比，html-to-md-api 猜成了 team-doc-style）")
        check(g("doc-style")?.path == t + "/team-doc-style", "英文名的单词都对上应猜出")
        check(g("old-style-guide") == nil, "只对上一个单词（不到 6 成）不该猜")
        check(g("客户项目") == nil, "只对上「客户」两个字（不到 6 成）不该猜成「客户数据清洗」")
        check(g("深处") == nil, "超过 3 层的同名文件夹不找")
        // 左栏搜索：拆词、摘句围着长词、整句出现时标整句，单个字不单独标
        check(EchoIndex.terms("主色定　B  靛蓝") == ["主色定", "B", "靛蓝"], "拆词不对：\(EchoIndex.terms("主色定　B  靛蓝"))")
        check(EchoIndex.anchor("B 主色定") == "主色定" && EchoIndex.anchor("靛蓝") == "靛蓝", "摘句应围着 3 个字以上的词")
        let cut = EchoSearchModel.cut(String(repeating: "前", count: 40) + "\n关键词" + String(repeating: "后", count: 200), around: "关键词")
        check(cut.hasPrefix("…" + String(repeating: "前", count: 11) + " 关键词") && cut.hasSuffix("…"), "摘句应在关键词前留 12 个字：\(cut.prefix(20))")
        func lit(_ a: AttributedString) -> [String] { a.runs.filter { $0.foregroundColor != nil }.map { String(a[$0.range].characters) } }
        check(lit(EchoSearchModel.marked("by 主色定 B（#00898A）", "主色定 B")) == ["主色定 B"], "整句出现时应只标整句")
        check(lit(EchoSearchModel.marked("Bash 里主色定了", "主色定 B")) == ["主色定"], "单个字不该单独标")
        check(EchoSearchModel.matches("回响 日期筛选", "筛选 回响") && !EchoSearchModel.matches("回响 日期筛选", "回响 搜索"), "会话名应几个词都有才算")
        print("  ech 分段、引用、猜新位置、搜索 24 项")
    }

    /// 备份位置选进了某台电脑的备份文件夹（0.14.1 及以前能选）：选的时候改用上一级；已经设错的，启动时改回来，多套那层的备份挪回来
    static func backupRootTest() throws {
        let fm = FileManager.default
        let r = fm.temporaryDirectory.appendingPathComponent("回响备份位置-\(UUID().uuidString)").standardizedFileURL
        defer { try? fm.removeItem(at: r) }
        let mac = r.appendingPathComponent("本机"), nested = mac.appendingPathComponent("本机")
        func put(_ rel: String, _ text: String, at base: URL, age: Double = 0) throws {
            let u = base.appendingPathComponent(rel)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
            if age > 0 { try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: u.path) }
        }
        func line(_ id: String, _ text: String) -> String {
            #"{"type":"user","uuid":"u-\#(id)","sessionId":"\#(id)","timestamp":"2026-11-20T00:00:00Z","cwd":"/tmp/p","origin":{"kind":"human"},"message":{"role":"user","content":"\#(text)"}}"# + "\n"
        }
        // 设错之前：本机的备份；设错之后写进多套的那层：s1 更新了，s3 是新会话（原会话之后被自动清理，只在这层有）
        try put("备份日志.jsonl", "{\"a\":1}\n", at: mac)
        try put("claude/备份记录.json", "{}", at: mac)
        try put("claude/projects/-p/s1.jsonl", line("s1", "旧"), at: mac, age: 3600)
        try put("claude/projects/-p/s2.jsonl", line("s2", "只在本机"), at: mac)
        try EchoMoved.add(["s1": "/x"], mac.appendingPathComponent("claude"))
        try EchoDeleted.add([EchoDeletedSession(sid: "a", t: "删掉的 a", cwd: "/p", c: "本机", deleted: "2026-11-01T00:00:00Z", days: [:])], mac)
        try put("备份日志.jsonl", "{\"b\":2}\n", at: nested)
        try put("claude/备份记录.json", "{}", at: nested)
        try put("claude/projects/-p/s1.jsonl", line("s1", "新"), at: nested)
        try put("claude/projects/-p/s3.jsonl", line("s3", "只在多套的那层"), at: nested)
        try EchoMoved.add(["s3": "/y"], nested.appendingPathComponent("claude"))
        try EchoDeleted.add([EchoDeletedSession(sid: "b", t: "删掉的 b", cwd: "/p", c: "本机", deleted: "2026-11-21T00:00:00Z", days: [:])], nested)

        check(EchoLayout.sharedRoot(r).path == r.path, "备份位置：放各台电脑的那一级原样用")
        check(EchoLayout.sharedRoot(mac).path == r.path, "备份位置：选了电脑的备份文件夹改用上一级")
        check(EchoLayout.sharedRoot(mac.appendingPathComponent("claude")).path == r.path, "备份位置：选了电脑里的 claude/ 改用放各台电脑的那一级")
        check(EchoLayout.sharedRoot(nested).path == r.path, "备份位置：多套了一层的也找回放各台电脑的那一级")
        let fresh = r.appendingPathComponent("新文件夹")
        try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
        check(EchoLayout.sharedRoot(fresh).path == fresh.path, "备份位置：新建的空文件夹原样用")
        try put("备份记录.json", "{}", at: r.appendingPathComponent("老电脑"))
        try fm.createDirectory(at: r.appendingPathComponent("老电脑/projects"), withIntermediateDirectories: true)
        check(EchoLayout.sharedRoot(r.appendingPathComponent("老电脑")).path == r.path, "备份位置：0.7 及以前的老布局也认得是电脑文件夹")
        try fm.removeItem(at: r.appendingPathComponent("老电脑"))
        try fm.removeItem(at: fresh)

        // 设错时：本机的 claude/ 被当成一台叫 claude 的电脑，ech 的索引也这么记
        check(Set(EchoLibrary.scan(backupRoot: mac).map(\.computer)).contains("claude"), "备份位置：复现设错时多出的「claude」电脑")
        try EchoIndex.update(backupRoot: mac)

        let d = UserDefaults.standard, savedRoot = d.string(forKey: "backupRoot"), savedName = d.string(forKey: "computerName")
        defer {
            if let savedRoot { d.set(savedRoot, forKey: "backupRoot") } else { d.removeObject(forKey: "backupRoot") }
            if let savedName { d.set(savedName, forKey: "computerName") } else { d.removeObject(forKey: "computerName") }
        }
        EchoPrefs.backupRoot = mac
        EchoPrefs.computerName = "本机"
        EchoPrefs.repairBackupRoot(trash: { try fm.removeItem(at: $0) })
        check(EchoPrefs.backupRoot.path == r.path, "备份位置：启动时改回上一级，实际 \(EchoPrefs.backupRoot.path)")
        let p = mac.appendingPathComponent("claude/projects/-p")
        check(fm.fileExists(atPath: p.appendingPathComponent("s3.jsonl").path), "备份位置：只在多套那层的会话挪回来")
        check((try? String(contentsOf: p.appendingPathComponent("s1.jsonl"), encoding: .utf8))?.contains("新") == true, "备份位置：两边都有的会话留新的")
        check(fm.fileExists(atPath: p.appendingPathComponent("s2.jsonl").path), "备份位置：只在本机的会话不动")
        check(!fm.fileExists(atPath: nested.path), "备份位置：都挪回来后多套的那层移到废纸篓")
        check(Set(EchoDeleted.load(mac).map(\.sid)) == ["a", "b"], "备份位置：已删除统计合到一起")
        check(EchoMoved.load(mac.appendingPathComponent("claude")) == ["s1": "/x", "s3": "/y"], "备份位置：移动记录合到一起")
        check((try? String(contentsOf: mac.appendingPathComponent("备份日志.jsonl"), encoding: .utf8)) == "{\"a\":1}\n{\"b\":2}\n", "备份位置：备份日志接在后面")
        let list = EchoLibrary.scan(backupRoot: r)
        check(list.map(\.computer) == ["本机", "本机", "本机"] && Set(list.map(\.sessionId)) == ["s1", "s2", "s3"], "备份位置：改对后三个会话都在「本机」下，实际 \(list.map { $0.computer + "/" + $0.sessionId })")
        try EchoIndex.update(backupRoot: r)
        var labels = Set<String>()
        try EchoIndex.open().rows("SELECT computer FROM files") { labels.insert($0.text(0)) }
        check(labels == ["本机"], "备份位置：ech 的索引改归「本机」，实际 \(labels)")
        EchoPrefs.repairBackupRoot(trash: { try fm.removeItem(at: $0) })
        check(EchoPrefs.backupRoot.path == r.path && fm.fileExists(atPath: p.appendingPathComponent("s3.jsonl").path), "备份位置：改对的再启动不再动")
        print("  备份位置 18 项")
    }

    static func layoutTest() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("echo-layout-\(getpid())")
        defer { try? fm.removeItem(at: root) }
        let me = root.appendingPathComponent("本机"), other = root.appendingPathComponent("另一台")
        func line(_ o: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), encoding: .utf8)! + "\n" }
        func session(_ dir: URL, _ sid: String, _ text: String) throws {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try line(["type": "user", "uuid": sid, "timestamp": "2026-11-20T00:00:00Z", "cwd": "/tmp/p", "message": ["role": "user", "content": text]])
                .write(to: dir.appendingPathComponent(sid + ".jsonl"), atomically: true, encoding: .utf8)
        }
        try session(me.appendingPathComponent("projects/-p"), "s1", "本机的会话")
        try Data("{}".utf8).write(to: me.appendingPathComponent("备份记录.json"))
        try Data(#"{"s1":"/tmp/挪过"}"#.utf8).write(to: me.appendingPathComponent("移动记录.json"))
        try session(other.appendingPathComponent("projects/-p"), "s2", "另一台没升级")
        let oldPath = me.appendingPathComponent("projects/-p/s1.jsonl").path
        EchoCleanRecord.merge([oldPath: .init(stamp: EchoFileStamp(size: 1, mtime: 1), policy: "k", next: 9)])
        let key0 = EchoCollections.key(EchoSession(url: URL(fileURLWithPath: oldPath), sessionId: "s1", computer: "本机", size: 0, meta: .init()), root: root)

        let n = try EchoLayout.migrate(me)
        let claude = me.appendingPathComponent("claude")
        check(n == 3 && !fm.fileExists(atPath: me.appendingPathComponent("projects").path)
              && ["projects/-p/s1.jsonl", "备份记录.json", "移动记录.json"].allSatisfy { fm.fileExists(atPath: claude.appendingPathComponent($0).path) },
              "分应用：老布局应整个挪进 claude/，实际挪了 \(n) 样")
        let rec = EchoCleanRecord.load()
        check(rec[oldPath] == nil && rec[claude.appendingPathComponent("projects/-p/s1.jsonl").path]?.next == 9, "分应用：清理记录的路径应跟着换")
        check((try? EchoLayout.migrate(me)) == 0, "分应用：挪过的再跑不应再动")

        try session(other.appendingPathComponent("claude/projects/-p"), "s2", "两处都有")   // 另一台挪到一半：两处都有 s2
        let list = EchoLibrary.scan(backupRoot: root)
        let s1 = list.first { $0.sessionId == "s1" }
        check(list.count == 2 && s1?.projectPath == "/tmp/挪过" && list.filter { $0.sessionId == "s2" }.count == 1
              && list.first { $0.sessionId == "s2" }?.url.path.contains("/claude/") == true,
              "分应用：新旧布局都应读到、同一个会话只算一次（用 claude/ 里的）、移动记录照用，实际 \(list.map { $0.computer + "/" + $0.sessionId })")
        check(s1.map { EchoCollections.key($0, root: root) } == key0, "分应用：合集的键应不变，实际 \(s1.map { EchoCollections.key($0, root: root) } ?? "")")
        let est = try EchoClean.run(computerDir: me, policy: EchoPolicy(), dryRun: true)
        check(est.files == 1, "分应用：清理应找到 claude/ 里的会话，实际 \(est.files) 个")
        print("  分应用 6 项")
    }

    /// Codex：sessions 和 archived_sessions（含 .zst）解压后按日期放进 sessions/年/月/日/，复制 session_index；
    /// 自动清理只挑到期、备份完整的会话文件，不动 session_index；x.jsonl.zst 不会把同名的 x.jsonl 当目录删
    static func codexBackupTest() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("echo-codex-\(getpid())")
        defer { try? fm.removeItem(at: root) }
        let src = root.appendingPathComponent("codex源"), dir = root.appendingPathComponent("备份/机/codex"), bin = root.appendingPathComponent("废纸篓")
        let a = src.appendingPathComponent("sessions/2026/09/01/rollout-2026-09-01T10-00-00-aaa.jsonl")
        let z = src.appendingPathComponent("archived_sessions/rollout-2026-10-02T10-00-00-bbb.jsonl.zst")
        for d in [a.deletingLastPathComponent(), z.deletingLastPathComponent(), bin] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let line = #"{"timestamp":"2026-09-01T02:00:00.000Z","type":"session_meta","payload":{"id":"aaa","cwd":"/tmp","source":"vscode"}}"# + "\n"
            + #"{"timestamp":"2026-09-01T02:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"装一下补丁"}]}}"# + "\n"
        try line.write(to: a, atomically: true, encoding: .utf8)
        let plain = z.deletingPathExtension()   // 临时写一份未压缩的，用 zstd 压成 .zst
        try line.replacingOccurrences(of: "aaa", with: "bbb").write(to: plain, atomically: true, encoding: .utf8)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/zstd"); p.arguments = ["-q", "--rm", plain.path]
        try p.run(); p.waitUntilExit()
        try "{\"id\":\"aaa\",\"thread_name\":\"改过的名字\"}\n".write(to: src.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)
        let old = Date(timeIntervalSinceNow: -40 * 86400)
        for f in [a, z] { try fm.setAttributes([.modificationDate: old], ofItemAtPath: f.path) }

        let items = EchoBackup.codexItems(src)
        let r = try EchoBackup.run(items: items, computerDir: dir)
        let outA = dir.appendingPathComponent("sessions/2026/09/01/rollout-2026-09-01T10-00-00-aaa.jsonl")
        let outZ = dir.appendingPathComponent("sessions/2026/10/02/rollout-2026-10-02T10-00-00-bbb.jsonl")
        check(r.copied == 3 && fm.fileExists(atPath: outA.path) && (try? String(contentsOf: outZ, encoding: .utf8))?.contains("bbb") == true
              && fm.fileExists(atPath: dir.appendingPathComponent("session_index.jsonl").path),
              "Codex 备份：两个会话应解压到 sessions/年/月/日/、复制 session_index，实际写了 \(r.copied)")
        // 备份后又改过的不清理
        try line.appending(line).write(to: a, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: a.path)
        let c = EchoAutoDelete.codexCandidates(source: src, dir: dir, days: 30)
        check(c.map(\.original.lastPathComponent) == ["rollout-2026-10-02T10-00-00-bbb.jsonl.zst"], "Codex 自动清理：只挑备份完整、到期的，实际 \(c.map(\.rel))")
        try line.write(to: z.deletingPathExtension(), atomically: true, encoding: .utf8)   // 同名的 x.jsonl 文件
        var moved: [String] = []
        let res = EchoAutoDelete.run(c) { u in moved.append(u.lastPathComponent); try fm.moveItem(at: u, to: bin.appendingPathComponent(u.lastPathComponent)) }
        check(res.count == 1 && moved == [z.lastPathComponent] && fm.fileExists(atPath: z.deletingPathExtension().path)
              && fm.fileExists(atPath: src.appendingPathComponent("session_index.jsonl").path),
              "Codex 自动清理：只挪会话文件，不动同名的 .jsonl 和 session_index，实际挪了 \(moved)")
        let list = EchoLibrary.scan(backupRoot: root.appendingPathComponent("备份"))
        check(list.count == 2 && list.first { $0.sessionId == "aaa" }?.meta.title == "改过的名字" && list.allSatisfy { $0.app == .codex },
              "Codex 列表：两个会话都在、标题取 session_index，实际 \(list.map { $0.sessionId + "「" + $0.meta.title + "」" })")
        print("  Codex 备份 4 项")
    }

    /// 自动删除：只挑超过期限、备份完整（连同名目录）、没开着的；只删原会话，备份不动
    static func autoDeleteTest() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("echo-autodel-\(getpid())")
        defer { try? fm.removeItem(at: root) }
        let src = root.appendingPathComponent("claude/projects"), comp = root.appendingPathComponent("备份/机")
        let bin = root.appendingPathComponent("废纸篓")
        for d in [src.appendingPathComponent("-p/s4/subagents"), comp.appendingPathComponent("projects/-p"), bin] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let old = Date(timeIntervalSinceNow: -40 * 86400)
        var record = EchoBackupRecord()
        func make(_ rel: String, backed: Bool = true, at: Date = old) throws {
            let f = src.appendingPathComponent(rel)
            try Data("x\n".utf8).write(to: f)
            try fm.setAttributes([.modificationDate: at], ofItemAtPath: f.path)
            if backed {
                let b = comp.appendingPathComponent("projects").appendingPathComponent(rel)
                try fm.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("x\n".utf8).write(to: b)
                let v = try f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                record.files[rel] = EchoFileStamp(size: Int64(v.fileSize!), mtime: v.contentModificationDate!.timeIntervalSince1970)
            }
        }
        try make("-p/s1.jsonl")                                  // 该删
        try make("-p/s2.jsonl", backed: false)                   // 没备份
        try make("-p/s3.jsonl", at: Date(timeIntervalSinceNow: -5 * 86400))   // 最近用过
        try make("-p/s4.jsonl"); try make("-p/s4/subagents/a.jsonl", backed: false)   // 子代理记录没备份
        try make("-p/s5.jsonl")                                  // 正开着
        try record.save(comp.appendingPathComponent("备份记录.json"))
        let list = EchoAutoDelete.candidates(source: src, computerDir: comp, days: 30, open: { $0 == "s5" })
        check(list.map(\.rel) == ["-p/s1.jsonl"], "自动删除：只该挑 s1，实际 \(list.map(\.rel))")
        let r = EchoAutoDelete.run(list, remove: { try fm.moveItem(at: $0, to: bin.appendingPathComponent($0.lastPathComponent)) })
        check(r.count == 1 && !fm.fileExists(atPath: src.appendingPathComponent("-p/s1.jsonl").path), "自动删除：s1 应移走")
        check(fm.fileExists(atPath: comp.appendingPathComponent("projects/-p/s1.jsonl").path), "自动删除：备份不应动")
        print("  自动删除 3 项")
    }

    /// 关闭 Claude 的自动清理：只改 cleanupPeriodDays，其余一字不动；没有就加上；坏文件不改
    static func claudeSettingsTest() throws {
        let fm = FileManager.default
        let f = fm.temporaryDirectory.appendingPathComponent("echo-settings-\(getpid()).json")
        defer { try? fm.removeItem(at: f) }
        let cases: [(String, String)] = [
            ("{\n  \"model\": \"opus\",\n  \"cleanupPeriodDays\": 30,\n  \"x\": [1, 2]\n}\n", "{\n  \"model\": \"opus\",\n  \"cleanupPeriodDays\": 36500,\n  \"x\": [1, 2]\n}\n"),
            ("{\n    \"model\": \"opus\"\n}\n", "{\n    \"cleanupPeriodDays\": 36500,\n    \"model\": \"opus\"\n}\n"),
            ("{\"model\":\"opus\"}", "{\"cleanupPeriodDays\": 36500, \"model\":\"opus\"}"),
            ("{}", "{\"cleanupPeriodDays\": 36500}"),
        ]
        for (before, want) in cases {
            try before.write(to: f, atomically: true, encoding: .utf8)
            try EchoClaudeSettings.setCleanupDays(36500, url: f)
            let got = try String(contentsOf: f, encoding: .utf8)
            check(got == want, "改 settings.json 不对：\(before.debugDescription) → \(got.debugDescription)")
        }
        try? fm.removeItem(at: f)
        try EchoClaudeSettings.setCleanupDays(36500, url: f)
        check(EchoClaudeSettings.cleanupDays(f) == 36500, "没有 settings.json 时应新建")
        try "{ 坏的".write(to: f, atomically: true, encoding: .utf8)
        let failed = (try? EchoClaudeSettings.setCleanupDays(36500, url: f)) == nil
        let still = try String(contentsOf: f, encoding: .utf8)
        check(failed && still == "{ 坏的", "坏文件不应改")
        print("  改 Claude 设置 6 项")
    }

    /// 用不显示的窗口画界面再存图：不切屏幕、不装应用就能看设置页、首次设置
    @MainActor static func shot(_ what: String, to out: URL, dark: Bool, wait: Double) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let view: AnyView
        switch what {
        case "settings-general": view = AnyView(EchoSettingsView(start: .general))
        case "browser":   // 浏览窗口：读 ECHO_SHOT_ROOT 这个备份目录；ECHO_SHOT_MENU=computer、app 时展开那个筛选菜单
            UserDefaults.standard.set(ProcessInfo.processInfo.environment["ECHO_SHOT_APP"] ?? "", forKey: "filterApp")   // 先选好的应用筛选
            EchoState.shared.sessions = EchoLibrary.scan(backupRoot: URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_SHOT_ROOT"] ?? "/tmp"))
            EchoState.shared.collections = EchoCollections.load(URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_SHOT_ROOT"] ?? "/tmp"))
            EchoState.shared.lastSuccess = Date(timeIntervalSinceNow: -600)   // 底部写「10 分钟前备份」
            if let id = ProcessInfo.processInfo.environment["ECHO_SHOT_OPEN"] {   // 打开这个会话（左栏显示选中）
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { EchoState.shared.openSessionID = id }
            }
            let env = ProcessInfo.processInfo.environment   // 窗口大小，默认 1100×720
            view = AnyView(EchoBrowserView().environmentObject(EchoState.shared).frame(width: Double(env["ECHO_SHOT_W"] ?? "") ?? 1100, height: Double(env["ECHO_SHOT_H"] ?? "") ?? 720))
        case "menubar-icon":   // 菜单栏图标的三种样子：平常、正在备份、出了问题，放大 4 倍，浅色菜单栏上一排、深色一排
            view = AnyView(VStack(spacing: 0) {
                ForEach([false, true], id: \.self) { dark in
                    HStack(spacing: 24) {
                        ForEach(0..<3) { i in
                            Image(nsImage: EchoMenuBar.icon(phase: i == 1 ? 1 : nil, dot: i == 2)).renderingMode(.template)
                                .resizable().interpolation(.high).frame(width: 72, height: 72).foregroundStyle(dark ? .white : .black)
                        }
                    }
                    .padding(24).background(dark ? Color(white: 0.16) : Color(white: 0.93))
                }
            })
        case let x where x.hasPrefix("onboarding-"): view = AnyView(EchoOnboardingView(start: Int(x.dropFirst(11)) ?? 0) {})
        default: view = AnyView(EchoSettingsView(start: .storage))
        }
        let host = NSHostingView(rootView: view)
        let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 680, height: 760), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.appearance = NSApp.appearance
        w.contentView = host
        let end = Date(timeIntervalSinceNow: wait)
        while Date() < end { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1)) }
        host.setFrameSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: out)
        print("  截图 \(out.lastPathComponent)")
    }

    static func lines(_ url: URL) throws -> [Data] {
        var out: [Data] = []
        try EchoLines.each(url) { out.append(Data(buffer: $0)) }
        return out
    }

    static func compare(_ src: URL, slimmed: URL, dataJS: URL?) throws {
        let name = src.lastPathComponent
        // 瘦身：行数一样；原型原样写出的行逐字节一样，改写过的行解析后一样
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("echo-test-\(getpid()).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var policy = EchoPolicy()
        if let n = ProcessInfo.processInfo.environment["ECHO_NOW"], let d = EchoTime.parse(n) { policy.now = d }
        let stats = try EchoSlim.slimFile(src, to: tmp, policy: policy)
        let mine = try lines(tmp), theirs = try lines(slimmed), orig = try lines(src)
        check(mine.count == theirs.count, "\(name) 瘦身后行数 \(mine.count)，原型 \(theirs.count)")
        for (n, (m, t)) in zip(mine, theirs).enumerated() where m != t {
            let pm = try? JSONSerialization.jsonObject(with: m) as? NSDictionary
            let pt = try? JSONSerialization.jsonObject(with: t) as? NSDictionary
            check(pm != nil && pm == pt, "\(name) 瘦身第 \(n + 1) 行和原型不一致")
        }
        let origSet = Set(orig)
        let kept = mine.filter { origSet.contains($0) }.count
        let raw = theirs.filter { origSet.contains($0) }.count
        check(kept >= raw, "\(name) 原样保留的行 \(kept)，原型 \(raw)")
        print("  瘦身 \(name)：\(orig.count) 行 → \(mine.count) 行，去掉请求记录 \(stats.droppedLines) 行，改写 \(stats.changedLines) 行")

        if let dataJS { try compareExport(src, dataJS: dataJS) }
    }

    /// 消息显示：整理结果和原型完全一样
    static func compareExport(_ src: URL, dataJS: URL) throws {
        let name = src.lastPathComponent
        var js = try String(contentsOf: dataJS, encoding: .utf8)
        js = String(js.dropFirst("window.SESSION = ".count))
        js = String(js.dropLast(2))
        let expect = try JSONSerialization.jsonObject(with: Data(js.utf8)) as! NSDictionary
        let got = try EchoExport.export(src, computer: "测试机") as NSDictionary
        if got != expect {
            let gt = (got["turns"] as! [NSDictionary]), et = (expect["turns"] as! [NSDictionary])
            check(false, "\(name) 整理结果和原型不一致：meta 一致 \(got["meta"] as! NSDictionary == expect["meta"] as! NSDictionary)，消息 \(gt.count) / \(et.count)")
            for (n, (g, e)) in zip(gt, et).enumerated() where g != e { print("    第 \(n + 1) 条：\(g)\n    原型：\(e)"); break }
        }
        print("  显示 \(name)：\((got["turns"] as! [Any]).count) 条消息，标题「\((got["meta"] as! NSDictionary)["title"]!)」")
    }

    static func backup(_ dir: URL) throws {
        for n in 1...2 {
            let r = try EchoBackup.run(source: EchoBackup.source, computerDir: dir)
            print(String(format: "  第 %d 遍：%d 个文件，写入 %d，跳过 %d，失败 %d，%.0fMB → %.0fMB，%.1f 秒",
                         n, r.total, r.copied, r.skipped, r.failures.count, Double(r.bytesIn) / 1e6, Double(r.bytesOut) / 1e6, r.seconds))
            for f in r.failures.prefix(5) { print("    \(f.path)：\(f.message)") }
        }
    }

    /// 量打开一个会话的耗时：整理、转 JSON、会话列表扫描
    static func timeExport(_ url: URL) throws {
        var t = Date()
        let d = try EchoExport.export(url, computer: "测试机")
        let a = Date().timeIntervalSince(t); t = Date()
        let data = try JSONSerialization.data(withJSONObject: d)
        let b = Date().timeIntervalSince(t); t = Date()
        _ = try EchoSessionScan.read(url)
        let c = Date().timeIntervalSince(t)
        print(String(format: "  整理 %.2f 秒，转 JSON %.2f 秒（%.1fMB，%d 条），扫描标题 %.2f 秒", a, b, Double(data.count) / 1e6, (d["turns"] as! [Any]).count, c))
    }

    static func rules() {
        let cases: [(String, EchoBackupRule.Action)] = [
            ("-Users-me-x/a1.jsonl", .slim),
            ("-Users-me-x/a1/subagents/agent-1.jsonl", .slim),
            ("-Users-me-x/a1/subagents/agent-1.meta.json", .copy),
            ("-Users-me-x/memory/MEMORY.md", .copy),
            ("-Users-me-x/a1/tool-results/b85a7fvd9.txt", .copy),
            ("-Users-me-x/a1/custom-title.json", .copy),
            ("-Users-me-x/a1/tool-results/pdf-1c1a/page-01.jpg", .skip),
            ("-Users-me-x/a1/tool-results/pdf-1c1a/page-01.PNG", .skip),
            ("-Users-me-x/a1/tool-results/a.pdf", .skip),
            ("-Users-me-x/.DS_Store", .skip),
        ]
        for (rel, want) in cases { check(EchoBackupRule.action(for: rel) == want, "备份规则 \(rel) 应为 \(want)") }
        print("  备份规则 \(cases.count) 条")
    }

    /// 改名：只在末尾追加一行，已有内容逐字节不变；custom-title.json 有才改；写到一半时不写
    static func renameTest(fixture: URL) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("echo-rename-\(getpid())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("s1"), withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("s1.jsonl")
        let body = Data("{\"type\":\"user\",\"uuid\":\"u1\",\"timestamp\":\"2026-11-20T01:00:00.000Z\",\"origin\":{\"kind\":\"human\"},\"message\":{\"content\":\"你好\"}}\n".utf8)
        try body.write(to: f)
        try Data("{\"customTitle\":\"旧名\"}".utf8).write(to: dir.appendingPathComponent("s1/custom-title.json"))
        try EchoRename.appendTitle(to: f, sessionId: "s1", title: " 新名 \"引号\" / 斜杠 ")
        let after = try Data(contentsOf: f)
        check(after.prefix(body.count) == body, "改名后原有内容变了")
        let last = String(decoding: after.dropFirst(body.count), as: UTF8.self)
        let obj = try? JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: String]
        check(obj == ["type": "custom-title", "customTitle": "新名 \"引号\" / 斜杠", "sessionId": "s1"] && last.hasSuffix("\n"), "改名追加的行不对：\(last)")
        check(try EchoSessionScan.read(f).title == "新名 \"引号\" / 斜杠", "改名后列表标题没变")
        check((try EchoExport.export(f, computer: "x")["meta"] as! [String: Any])["title"] as? String == "新名 \"引号\" / 斜杠", "改名后对话标题没变")
        let side = try String(contentsOf: dir.appendingPathComponent("s1/custom-title.json"), encoding: .utf8)
        check(side.contains("新名"), "custom-title.json 没改")
        // 最后一行写到一半：不写，报错
        let fh = try FileHandle(forWritingTo: f); try fh.seekToEnd(); try fh.write(contentsOf: Data("{\"type\":\"assi".utf8)); try fh.close()
        let before = try Data(contentsOf: f)
        check((try? EchoRename.appendTitle(to: f, sessionId: "s1", title: "再改")) == nil, "写到一半时应该报错")
        check(try Data(contentsOf: f) == before, "写到一半时不应该动文件")
        print("  改名 5 项")

        // 合集：按开始时间排，每个会话前一条分隔，消息数相加
        let g = dir.appendingPathComponent("s2.jsonl")
        try Data(String(decoding: body, as: UTF8.self).replacingOccurrences(of: "2026-11-20", with: "2026-11-21").utf8).write(to: g)
        let a = try EchoExport.export(fixture, computer: "甲"), b = try EchoExport.export(g, computer: "乙")
        let c = try EchoExport.exportCollection([(fixture, "甲"), (g, "乙")], id: "c1", title: "合集")
        let turns = c["turns"] as! [[String: Any]]
        let parts = turns.filter { $0["role"] as? String == "session" }
        check(turns.count == (a["turns"] as! [Any]).count + (b["turns"] as! [Any]).count + 2, "合集消息数不对")
        check(parts.map { $0["computer"] as! String } == ["甲", "乙"], "合集没按开始时间排")
        check((c["meta"] as! [String: Any])["kind"] as? String == "collection", "合集 meta 不对")
        print("  合集 3 项")

        // 删除：原会话和备份连同目录移走，备份记录去掉；还在写的不删
        let home = dir.appendingPathComponent("claude/-p"), bak = dir.appendingPathComponent("备份/机/projects/-p"), bin = dir.appendingPathComponent("废纸篓")
        for d in [home.appendingPathComponent("x1/subagents"), bak.appendingPathComponent("x1/subagents"), bin] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        for d in [home, bak] {
            try body.write(to: d.appendingPathComponent("x1.jsonl"))
            try body.write(to: d.appendingPathComponent("x1/subagents/a.jsonl"))
            try body.write(to: d.appendingPathComponent("x2.jsonl"))
        }
        let old = Date(timeIntervalSinceNow: -3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: home.appendingPathComponent("x1.jsonl").path)
        let rec = dir.appendingPathComponent("备份/机/备份记录.json")
        let stamp = EchoFileStamp(size: 1, mtime: 1)
        try EchoBackupRecord(lastSuccess: nil, files: ["-p/x1.jsonl": stamp, "-p/x1/subagents/a.jsonl": stamp, "-p/x2.jsonl": stamp]).save(rec)
        var n = 0
        let mv: (URL) throws -> Void = { u in n += 1; try FileManager.default.moveItem(at: u, to: bin.appendingPathComponent("\(n)-\(u.lastPathComponent)")) }
        try EchoDelete.trash(.init(original: home.appendingPathComponent("x1.jsonl"), backup: bak.appendingPathComponent("x1.jsonl"), record: rec, rel: "-p/x1.jsonl"), remove: mv)
        let fm = FileManager.default
        check(!fm.fileExists(atPath: home.appendingPathComponent("x1.jsonl").path) && !fm.fileExists(atPath: home.appendingPathComponent("x1").path), "原会话和目录没移走")
        check(!fm.fileExists(atPath: bak.appendingPathComponent("x1.jsonl").path) && !fm.fileExists(atPath: bak.appendingPathComponent("x1").path), "备份和目录没移走")
        check(fm.fileExists(atPath: home.appendingPathComponent("x2.jsonl").path) && fm.fileExists(atPath: bak.appendingPathComponent("x2.jsonl").path), "别的会话被误删")
        check(n == 4, "移走的项数 \(n)，应为 4")
        check(EchoBackupRecord.load(rec).files.keys.sorted() == ["-p/x2.jsonl"], "备份记录没去掉")
        check((try? EchoDelete.trash(.init(original: home.appendingPathComponent("x2.jsonl"), backup: bak.appendingPathComponent("x2.jsonl"), record: rec, rel: "-p/x2.jsonl"), remove: mv)) == nil
              && fm.fileExists(atPath: home.appendingPathComponent("x2.jsonl").path), "还在写的会话不应该删")
        // 原会话已不在（清理了、在另一台电脑上）：只移备份；另一台电脑的（record 为 nil）不改备份记录
        try fm.removeItem(at: home.appendingPathComponent("x2.jsonl"))
        let movedBefore = n
        try EchoDelete.trash(.init(original: nil, backup: bak.appendingPathComponent("x2.jsonl"), record: nil, rel: "-p/x2.jsonl"), remove: mv)
        check(n == movedBefore + 1 && !fm.fileExists(atPath: bak.appendingPathComponent("x2.jsonl").path) && EchoBackupRecord.load(rec).files.keys.sorted() == ["-p/x2.jsonl"],
              "原会话不在时应只移备份、不改另一台电脑的备份记录")
        print("  删除 7 项")

        // 移动：目录编码；原会话和备份连同目录挪到新项目目录，备份记录改键；开着的、还在写的、新位置已有的不挪；移动记录改显示的目录
        check(EchoMove.projectDirName("/Users/x/项目代码/回响") == "-Users-x--------", "中文目录编码不对")
        check(EchoMove.projectDirName("/a b/c.d_e/😀") == "-a-b-c-d-e---", "符号和表情编码不对")
        let mvSrc = dir.appendingPathComponent("mv/claude"), mvBak = dir.appendingPathComponent("mv/备份/\(EchoPrefs.computerName)/projects")
        for d in [mvSrc.appendingPathComponent("-old/y1/subagents"), mvBak.appendingPathComponent("-old/y1/subagents")] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        for d in [mvSrc.appendingPathComponent("-old"), mvBak.appendingPathComponent("-old")] {
            try body.write(to: d.appendingPathComponent("y1.jsonl"))
            try body.write(to: d.appendingPathComponent("y1/subagents/a.jsonl"))
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: d.appendingPathComponent("y1.jsonl").path)
        }
        let mvRec = mvBak.deletingLastPathComponent().appendingPathComponent("备份记录.json")
        try EchoBackupRecord(lastSuccess: nil, files: ["-old/y1.jsonl": stamp, "-old/y1/subagents/a.jsonl": stamp, "-old/z.jsonl": stamp]).save(mvRec)
        let mvSess = EchoSession(url: mvBak.appendingPathComponent("-old/y1.jsonl"), sessionId: "y1", computer: EchoPrefs.computerName, size: 1, meta: EchoSessionMeta(title: "t", cwd: "/old", start: "x", end: "x"))
        let target = "/Users/x/新 目录"
        let mp = EchoMove.paths(for: mvSess, to: target, source: mvSrc)!
        check((try? EchoMove.move(mp, sessionId: "y1", open: { _ in true })) == nil && fm.fileExists(atPath: mp.original.path), "开着的会话不应该挪")
        try EchoMove.move(mp, sessionId: "y1", open: { _ in false })
        let nd = EchoMove.projectDirName(target)
        check(fm.fileExists(atPath: mvSrc.appendingPathComponent("\(nd)/y1.jsonl").path) && fm.fileExists(atPath: mvSrc.appendingPathComponent("\(nd)/y1/subagents/a.jsonl").path)
              && !fm.fileExists(atPath: mvSrc.appendingPathComponent("-old/y1.jsonl").path) && !fm.fileExists(atPath: mvSrc.appendingPathComponent("-old/y1").path), "原会话和目录没挪过去")
        check(fm.fileExists(atPath: mvBak.appendingPathComponent("\(nd)/y1.jsonl").path) && fm.fileExists(atPath: mvBak.appendingPathComponent("\(nd)/y1/subagents/a.jsonl").path)
              && !fm.fileExists(atPath: mvBak.appendingPathComponent("-old/y1.jsonl").path), "备份和目录没挪过去")
        check(Set(EchoBackupRecord.load(mvRec).files.keys) == ["-old/z.jsonl", "\(nd)/y1.jsonl", "\(nd)/y1/subagents/a.jsonl"], "备份记录没改键：\(EchoBackupRecord.load(mvRec).files.keys.sorted())")
        // 挪回去时旧位置又有了同一个会话：不挪
        try body.write(to: mvSrc.appendingPathComponent("-old/y1.jsonl"))
        let back = EchoMove.paths(for: EchoSession(url: mvBak.appendingPathComponent("\(nd)/y1.jsonl"), sessionId: "y1", computer: EchoPrefs.computerName, size: 1, meta: mvSess.meta), to: "/old", source: mvSrc)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: mvSrc.appendingPathComponent("\(nd)/y1.jsonl").path)
        check(back.map { (try? EchoMove.move($0, sessionId: "y1", open: { _ in false })) == nil } == true && fm.fileExists(atPath: mvSrc.appendingPathComponent("\(nd)/y1.jsonl").path), "新位置已有同一个会话时不应该挪")
        // 还在写的不挪；别的电脑的不给挪
        try body.write(to: mvSrc.appendingPathComponent("\(nd)/y1.jsonl"))
        let busy = EchoMove.paths(for: EchoSession(url: mvBak.appendingPathComponent("\(nd)/y1.jsonl"), sessionId: "y1", computer: EchoPrefs.computerName, size: 1, meta: mvSess.meta), to: "/other", source: mvSrc)!
        check((try? EchoMove.move(busy, sessionId: "y1", open: { _ in false })) == nil, "还在写的会话不应该挪")
        check(EchoMove.paths(for: EchoSession(url: mvSess.url, sessionId: "y1", computer: "别的电脑", size: 1, meta: mvSess.meta), to: "/x", source: mvSrc) == nil, "别的电脑的会话不应该能挪")
        // 移动记录：左栏按新文件夹显示
        try EchoMoved.add(["y1": target], mvBak.deletingLastPathComponent())
        let listed = EchoLibrary.scan(backupRoot: dir.appendingPathComponent("mv/备份")).first { $0.sessionId == "y1" }
        check(listed?.projectPath == target, "挪过的会话没按新文件夹显示：\(listed?.projectPath ?? "无")")
        print("  移动 9 项")

        // 手动顺序：新出现的在前，排过的按记的顺序；挪到前、后；拖的是自己不动
        check(EchoOrder.move(["a", "b", "c", "d"], moving: ["d"], to: "b", after: false) == ["a", "d", "b", "c"], "插到前面不对")
        check(EchoOrder.move(["a", "b", "c", "d"], moving: ["a", "c"], to: "d", after: true) == ["b", "d", "a", "c"], "几项一起插到后面不对")
        check(EchoOrder.move(["a", "b"], moving: ["a"], to: "a", after: true) == ["a", "b"], "拖到自己身上不该变")
        check(EchoOrder.sorted(["new", "b", "a"], ["a", "b"], key: { $0 }) == ["new", "a", "b"], "新出现的应该排在前面")
        let od = EchoDir(path: "/p", name: "p", children: [EchoDir(path: "/p/x", name: "x", children: [], sessions: []), EchoDir(path: "/p/y", name: "y", children: [], sessions: [])],
                         sessions: [mvSess, EchoSession(url: mvSess.url, sessionId: "y2", computer: "机", size: 1, meta: mvSess.meta)])
        let arranged = EchoOrder.arrange([od], ["/p": ["/p/y", "/p/x"], "s:/p": ["y2", "y1"]])
        check(arranged[0].children.map(\.name) == ["y", "x"] && arranged[0].sessions.map(\.sessionId) == ["y1", "y2"], "子目录没按记的顺序，或会话被排了（会话只按时间）")
        let deep = EchoOrder.apply([od, EchoDir(path: "/q", name: "q", children: [], sessions: [])], group: "/p", keys: ["/p/y", "/p/x"])
        check(deep[0].children.map(\.name) == ["y", "x"] && deep[1].path == "/q", "只重排一级时别的动了")
        check(EchoOrder.apply([od, EchoDir(path: "/q", name: "q", children: [], sessions: [])], group: "/", keys: ["/q", "/p"]).map(\.path) == ["/q", "/p"], "顶层没重排")
        print("  顺序 7 项")

        // 带隐藏标记的会话文件也要列出来；名字以「.」开头的临时文件不列
        let lib = dir.appendingPathComponent("库/机/projects/-p")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        var hid = lib.appendingPathComponent("h1.jsonl")
        try body.write(to: hid)
        var rv = URLResourceValues(); rv.isHidden = true; try hid.setResourceValues(rv)
        try body.write(to: lib.appendingPathComponent(".h2.jsonl.echo-tmp"))
        let found = EchoLibrary.scan(backupRoot: dir.appendingPathComponent("库")).map(\.url.lastPathComponent)
        check(found == ["h1.jsonl"], "带隐藏标记的会话没列出来，或临时文件被列出来：\(found)")
        print("  隐藏标记 1 项")
    }

    /// 「正在 Claude 里开着」：进程在运行才算；僵尸进程、进程号被复用的不算
    static func openTest() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func reg(_ pid: Int32, _ id: String, startedAt: Double?) throws {
            var o: [String: Any] = ["pid": pid, "sessionId": id]
            if let t = startedAt { o["startedAt"] = t }
            try JSONSerialization.data(withJSONObject: o).write(to: dir.appendingPathComponent("\(pid).json"))
        }
        let me = getpid(), now = Date().timeIntervalSince1970 * 1000
        try reg(me, "live", startedAt: now)
        check(EchoMove.isOpen("live", sessionsDir: dir), "进程在运行的会话应该算开着")
        check(!EchoMove.isOpen("other", sessionsDir: dir), "没登记的会话不应该算开着")
        try reg(me, "reused", startedAt: 1_000)
        check(!EchoMove.isOpen("reused", sessionsDir: dir), "进程号被复用（进程晚于登记启动）不应该算开着")
        try reg(me, "nostamp", startedAt: nil)
        check(EchoMove.isOpen("nostamp", sessionsDir: dir), "登记里没有 startedAt 时按进程在不在判断")
        // 起一个子进程，退出后不回收，留成僵尸进程
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        defer { argv.forEach { free($0) } }
        guard posix_spawn(&pid, "/usr/bin/true", nil, nil, argv, environ) == 0 else { check(false, "起子进程失败"); return }
        var si = siginfo_t()
        _ = waitid(P_PID, id_t(pid), &si, WEXITED | WNOWAIT)
        try reg(pid, "zombie", startedAt: now)
        check(EchoMove.processStart(pid) == nil, "僵尸进程不应该有启动时间")
        check(!EchoMove.isOpen("zombie", sessionsDir: dir), "僵尸进程登记的会话不应该算开着")
        var st: Int32 = 0
        waitpid(pid, &st, 0)
        check(!EchoMove.isOpen("zombie", sessionsDir: dir), "进程不在了的会话不应该算开着")
    }

}
