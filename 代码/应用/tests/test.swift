// 回归测试：瘦身、消息显示和原型（代码/原型/slim.py、export.py）的结果一致，备份挑文件的规则。
// 由 tests/run.sh 编译运行：test <会话.jsonl> <原型瘦身结果> <原型 data.js>；test --rules <假会话>
// 手动验收全量备份：test --backup <临时目录>（把本机会话备份到临时目录，跑两遍看耗时）
import Foundation

@main
enum EchoTests {
    static var failed = 0

    static func check(_ ok: Bool, _ what: @autoclosure () -> String) {
        if !ok { failed += 1; print("  ✗ \(what())") }
    }

    static func main() throws {
        let a = CommandLine.arguments
        if a.count == 3, a[1] == "--rules" { rules(); try renameTest(fixture: URL(fileURLWithPath: a[2])) }
        else if a.count == 3, a[1] == "--backup" { try backup(URL(fileURLWithPath: a[2])) }
        else if a.count == 3, a[1] == "--time" { try timeExport(URL(fileURLWithPath: a[2])) }
        else if a.count == 4 { try compare(URL(fileURLWithPath: a[1]), slimmed: URL(fileURLWithPath: a[2]), dataJS: URL(fileURLWithPath: a[3])) }
        else { print("用法：test <会话.jsonl> <原型瘦身结果> <原型 data.js> 或 test --rules"); exit(2) }
        if failed > 0 { print("失败 \(failed) 项"); exit(1) }
    }

    static func lines(_ url: URL) throws -> [Data] {
        var out: [Data] = []
        try EchoLines.each(url) { out.append(Data(buffer: $0)) }
        return out
    }

    static func compare(_ src: URL, slimmed: URL, dataJS: URL) throws {
        let name = src.lastPathComponent
        // 瘦身：行数一样；原型原样写出的行逐字节一样，改写过的行解析后一样
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("echo-test-\(getpid()).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let stats = try EchoSlim.slimFile(src, to: tmp)
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

        // 消息显示：整理结果和原型完全一样
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
        print("  删除 6 项")
    }
}
