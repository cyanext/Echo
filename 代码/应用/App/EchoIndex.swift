// ech 用的本机索引（需求 需求文档/版本需求/v0.9.0-ech命令和skill.html）：每个会话按压缩点、版本提交、北京时间跨天分段，
// 我的消息、回复文字、阶段总结、工具调用的命令进全文索引（SQLite FTS5，trigram 分词，中文按字串匹配）。
// 索引放本机 ~/Library/Application Support/回响/索引.sqlite，不放 iCloud；只读备份，回响或 ech backup 备份完增量更新。
import Foundation
import SQLite3

/// 很薄的一层 SQLite：开库、执行、预编译语句
final class EchoDB {
    let db: OpaquePointer
    init(_ url: URL, readonly: Bool = false) throws {
        var p: OpaquePointer?
        let flags = readonly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(url.path, &p, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let p else {
            throw EchoDB.fail(p.map { String(cString: sqlite3_errmsg($0)) } ?? "打不开索引")
        }
        db = p
        sqlite3_busy_timeout(db, 5000)
    }
    deinit { sqlite3_close_v2(db) }

    static func fail(_ s: String) -> Error { CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: s]) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? "SQL 出错"
            sqlite3_free(err)
            throw EchoDB.fail(m)
        }
    }

    func prepare(_ sql: String) throws -> EchoStmt {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { throw EchoDB.fail(String(cString: sqlite3_errmsg(db))) }
        return EchoStmt(s)
    }

    /// 查询：每行回调一次
    func rows(_ sql: String, _ args: [Any?] = [], _ body: (EchoStmt) throws -> Void) throws {
        let st = try prepare(sql)
        try st.bind(args)
        while try st.step() { try body(st) }
    }

    var lastID: Int64 { sqlite3_last_insert_rowid(db) }
    var changes: Int { Int(sqlite3_changes(db)) }   // 上一条 UPDATE、DELETE 改了几行
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class EchoStmt {
    let s: OpaquePointer
    init(_ s: OpaquePointer) { self.s = s }
    deinit { sqlite3_finalize(s) }

    func bind(_ args: [Any?]) throws {
        sqlite3_reset(s)
        sqlite3_clear_bindings(s)
        for (i, a) in args.enumerated() {
            let k = Int32(i + 1)
            switch a {
            case nil: sqlite3_bind_null(s, k)
            case let v as Int: sqlite3_bind_int64(s, k, Int64(v))
            case let v as Int64: sqlite3_bind_int64(s, k, v)
            case let v as Double: sqlite3_bind_double(s, k, v)
            case let v as String: sqlite3_bind_text(s, k, v, -1, SQLITE_TRANSIENT)
            default: sqlite3_bind_text(s, k, "\(a!)", -1, SQLITE_TRANSIENT)
            }
        }
    }

    @discardableResult
    func step() throws -> Bool {
        let r = sqlite3_step(s)
        if r == SQLITE_ROW { return true }
        if r == SQLITE_DONE { return false }
        throw EchoDB.fail(String(cString: sqlite3_errmsg(sqlite3_db_handle(s))))
    }

    func run(_ args: [Any?]) throws { try bind(args); try step() }
    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(s, i)) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(s, i) }
    func text(_ i: Int32) -> String { sqlite3_column_text(s, i).map { String(cString: $0) } ?? "" }
}

enum EchoIndex {
    static var url: URL { EchoLibrary.supportDir.appendingPathComponent("索引.sqlite") }
    /// 表结构改了就加一，旧索引整个重建
    static let schemaVersion = "4"   // 4：回顾（recap）进索引，分段第一句优先用回顾
    /// 一行进索引的字最多多长：贴进来的长文按前面这些字搜
    static let maxText = 8000

    struct Row { var line: Int; var role: String; var ts: String; var text: String }
    struct Seg { var n: Int; var l0: Int; var l1: Int; var t0: String; var t1: String; var vers: [String]; var head: String; var kind: String
        var recap = ""   // 这一段最后一条回顾：段的第一句优先用它（Claude 写的阶段小结，比我说的第一句更能说明这段做了什么）
    }

    // MARK: 从整理好的会话取行

    /// 整理结果（EchoExport.export withLines）里要进索引的行：我的消息、阶段总结、斜杠命令、回复文字、工具调用一行概述。
    /// 系统注入的消息、思考过程、工具输出不进
    static func rows(_ turns: [[String: Any]]) -> [Row] {
        var out: [Row] = []
        func add(_ line: Int, _ role: String, _ ts: String, _ text: String) {
            let t = text.trimmed
            guard !t.isEmpty else { return }
            out.append(Row(line: line, role: role, ts: ts, text: String(t.prefix(maxText))))
        }
        for t in turns {
            let role = t["role"] as? String ?? "", ts = t["ts"] as? String ?? "", line = t["line"] as? Int ?? 0
            switch role {
            case "user": add(line, "我", ts, t["text"] as? String ?? "")
            case "summary": add(line, "总结", ts, t["text"] as? String ?? "")
            case "recap": add(line, "回顾", ts, t["text"] as? String ?? "")
            case "command": add(line, "命令", ts, t["text"] as? String ?? "")
            case "assistant":
                for b in t["blocks"] as? [[String: Any]] ?? [] {
                    let bl = b["line"] as? Int ?? line
                    switch b["kind"] as? String {
                    case "text": add(bl, "AI", ts, b["text"] as? String ?? "")
                    case "tool": add(bl, "工具", ts, toolLine(b["name"] as? String ?? "", b["input"]))
                    default: break
                    }
                }
            default: break
            }
        }
        return out.sorted { $0.line < $1.line }
    }

    /// 工具调用写成一行：工具名加最能说明在干什么的那个参数（命令、说明、文件、搜索词）
    static func toolLine(_ name: String, _ input: Any?) -> String {
        let cmd = command(input)
        if !cmd.isEmpty { return name + " " + cmd }
        let d = input as? [String: Any] ?? [:]
        for k in ["description", "file_path", "path", "pattern", "query", "url", "prompt", "skill"] {
            if let v = d[k] as? String, !v.isEmpty { return name + " " + String(v.prefix(400)) }
        }
        return name
    }

    /// 工具调用里的终端命令：Claude 的 Bash 是 command，Codex 的是 cmd 或 command（字符串或数组）
    static func command(_ input: Any?) -> String {
        let d = input as? [String: Any] ?? [:]
        for k in ["command", "cmd"] {
            if let s = d[k] as? String { return s }
            if let a = d[k] as? [String] { return a.joined(separator: " ") }
        }
        return ""
    }

    /// 版本号：和要点栏（Web/app.js versionKey 的第一种）同一套，只认说明开头的「模块 v1.2.3」「v1.2.3」；说明中间顺带提到的版本号不算
    private static let headVer = try! NSRegularExpression(pattern: #"^\s*(?:(?!v?\d)[^\s:：]{1,6}[:：]\s*)?([\p{L}\p{N}_ -]{0,12}?)\s*(?:v?(\d+\.\d+\.\d+)|v(\d+\.\d+))(?![\d.])"#, options: [.caseInsensitive])

    static func versionKey(_ label: String) -> String? {
        if label.hasPrefix("Merge") || label.hasPrefix("合并") { return nil }
        let ns = label as NSString, r = NSRange(location: 0, length: ns.length)
        guard let m = headVer.firstMatch(in: label, range: r) else { return nil }
        func g(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
        var mod = g(1) ?? ""
        while let last = mod.last, " _-".contains(last) { mod.removeLast() }
        if mod.lowercased().hasSuffix("v") { mod.removeLast() }
        return (mod.trimmed + " " + (g(2) ?? g(3) ?? "")).trimmed
    }

    /// 一行工具调用里提交的版本
    static func versions(_ r: Row) -> [String] {
        r.role == "工具" ? EchoStats.commitTexts(in: r.text).compactMap(versionKey) : []
    }

    /// 北京时间的日期（2026-11-22），分段按它跨天
    static func bjDay(_ ts: String) -> String {
        guard let t = EchoTime.fastEpoch(ts) else { return "" }
        let days = Int((t + 8 * 3600) / 86400)
        let d = Date(timeIntervalSince1970: Double(days) * 86400)
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        let x = c.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", x.year ?? 0, x.month ?? 0, x.day ?? 0)
    }

    /// 分段：阶段总结开始新的一段（压缩点）；一个版本最后一次提交结束这一段，下一行开始新的一段（和要点栏一样，提交是这一版的终点）；
    /// 北京时间跨天后我的第一句话开始新的一段。每段记起止行、起止时间、这一段里提交的版本、第一句话（有阶段总结时取它）
    static func segments(_ turns: [[String: Any]]) -> [Seg] {
        let rs = rows(turns)
        // 每个版本最后一次提交在哪一行
        var lastOf: [String: Int] = [:]
        for r in rs { for v in versions(r) { lastOf[v] = r.line } }
        let ends = Set(lastOf.values)
        var segs: [Seg] = []
        var cur: Seg?
        var closeNext = false
        func close(_ c: Seg) -> Seg {
            var c = c
            if !c.recap.isEmpty { c.head = firstSentence(c.recap) }
            return c
        }
        func start(_ r: Row, _ kind: String) {
            if let c = cur { segs.append(close(c)) }
            cur = Seg(n: segs.count + 1, l0: r.line, l1: r.line, t0: r.ts, t1: r.ts, vers: [], head: "", kind: kind)
        }
        for r in rs {
            if cur == nil { start(r, "开头") }
            else if r.role == "总结" { start(r, "压缩") }
            else if closeNext { start(r, "版本后") }
            else if r.role == "我", !r.ts.isEmpty, !cur!.t1.isEmpty, bjDay(r.ts) != bjDay(cur!.t1) { start(r, "跨天") }
            closeNext = false
            cur!.l1 = r.line
            if !r.ts.isEmpty { cur!.t1 = r.ts; if cur!.t0.isEmpty { cur!.t0 = r.ts } }
            // 第一句：我说的第一句；Codex 的阶段总结是正文，可以用；Claude Code 的压缩摘要开头是固定的一句套话，跳过
            if cur!.head.isEmpty, r.role == "我" || (r.role == "总结" && !r.text.hasPrefix("This session is being continued")) { cur!.head = firstSentence(r.text) }
            if r.role == "回顾" { cur!.recap = r.text }
            for v in versions(r) where !cur!.vers.contains(v) { cur!.vers.append(v) }
            if ends.contains(r.line) { closeNext = true }
        }
        if let c = cur { segs.append(close(c)) }
        return segs
    }

    static func firstSentence(_ s: String) -> String {
        let line = s.split(separator: "\n").first.map(String.init) ?? s
        var out = ""
        for ch in line {
            out.append(ch)
            if "。！？!?".contains(ch) || out.count >= 60 { break }
        }
        return out.trimmed
    }

    // MARK: 建、更新

    static func open(readonly: Bool = false) throws -> EchoDB {
        let db = try EchoDB(url, readonly: readonly)
        if readonly { return db }
        try db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        try db.exec("CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT)")
        var ver = ""
        try db.rows("SELECT v FROM meta WHERE k='schema'") { ver = $0.text(0) }
        if ver != schemaVersion {
            try db.exec("""
            DROP TABLE IF EXISTS files; DROP TABLE IF EXISTS segs; DROP TABLE IF EXISTS lines; DROP TABLE IF EXISTS fts;
            DROP TRIGGER IF EXISTS lines_ai; DROP TRIGGER IF EXISTS lines_ad;
            CREATE TABLE files(id INTEGER PRIMARY KEY, path TEXT UNIQUE, size INTEGER, mtime REAL, sid TEXT, app TEXT, computer TEXT,
                               title TEXT, cwd TEXT, start TEXT, end TEXT);
            CREATE TABLE segs(fid INTEGER, n INTEGER, l0 INTEGER, l1 INTEGER, t0 TEXT, t1 TEXT, vers TEXT, head TEXT, kind TEXT);
            CREATE INDEX segs_fid ON segs(fid, n);
            CREATE TABLE lines(id INTEGER PRIMARY KEY, fid INTEGER, line INTEGER, role TEXT, ts TEXT, text TEXT);
            CREATE INDEX lines_fid ON lines(fid, line);
            CREATE VIRTUAL TABLE fts USING fts5(text, content='lines', content_rowid='id', tokenize='trigram');
            CREATE TRIGGER lines_ai AFTER INSERT ON lines BEGIN INSERT INTO fts(rowid, text) VALUES (new.id, new.text); END;
            CREATE TRIGGER lines_ad AFTER DELETE ON lines BEGIN INSERT INTO fts(fts, rowid, text) VALUES('delete', old.id, old.text); END;
            INSERT OR REPLACE INTO meta VALUES('schema', '\(schemaVersion)');
            """)
        }
        return db
    }

    struct UpdateResult { var changed = 0; var removed = 0; var total = 0; var seconds = 0.0 }

    /// 增量更新：大小、修改时间或所在电脑变了的备份文件整个重做（备份位置改到上一级后，同一个文件归到的电脑会变），备份里没有了的删掉。
    /// 整理会话多个文件同时做，写库在一个事务里
    @discardableResult
    static func update(backupRoot: URL, sessions given: [EchoSession]? = nil) throws -> UpdateResult {
        let t0 = Date()
        let sessions = given ?? EchoLibrary.scan(backupRoot: backupRoot)
        let db = try open()
        var old: [String: (id: Int, size: Int, mtime: Double, computer: String)] = [:]
        try db.rows("SELECT id, path, size, mtime, computer FROM files") { old[$0.text(1)] = ($0.int(0), $0.int(2), $0.double(3), $0.text(4)) }
        let fm = FileManager.default
        var todo: [(EchoSession, Int, Double)] = []
        var keep = Set<String>()
        for s in sessions {
            let a = try? fm.attributesOfItem(atPath: s.url.path)
            let size = (a?[.size] as? NSNumber)?.intValue ?? 0
            let mtime = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            keep.insert(s.url.path)
            if let o = old[s.url.path], o.size == size, o.mtime == mtime, o.computer == s.computer { continue }
            todo.append((s, size, mtime))
        }
        let built: [(EchoSession, Int, Double, [Row], [Seg])?] = EchoParallel.map(todo) { s, size, mtime in
            guard let d = try? EchoExport.export(s.url, computer: s.computer, withLines: true),
                  let turns = d["turns"] as? [[String: Any]] else { return nil }
            return (s, size, mtime, rows(turns), segments(turns))
        }
        var r = UpdateResult(total: sessions.count)
        try db.exec("BEGIN")
        do {
            let delLines = try db.prepare("DELETE FROM lines WHERE fid=?"), delSegs = try db.prepare("DELETE FROM segs WHERE fid=?")
            let delFile = try db.prepare("DELETE FROM files WHERE id=?")
            func drop(_ id: Int) throws { try delLines.run([id]); try delSegs.run([id]); try delFile.run([id]) }
            for (path, o) in old where !keep.contains(path) { try drop(o.id); r.removed += 1 }
            let insFile = try db.prepare("INSERT INTO files(path, size, mtime, sid, app, computer, title, cwd, start, end) VALUES(?,?,?,?,?,?,?,?,?,?)")
            let insLine = try db.prepare("INSERT INTO lines(fid, line, role, ts, text) VALUES(?,?,?,?,?)")
            let insSeg = try db.prepare("INSERT INTO segs(fid, n, l0, l1, t0, t1, vers, head, kind) VALUES(?,?,?,?,?,?,?,?,?)")
            for b in built {
                guard let (s, size, mtime, rs, sg) = b else { continue }
                if let o = old[s.url.path] { try drop(o.id) }
                let title = s.meta.title == s.sessionId ? "未命名会话" : s.meta.title
                try insFile.run([s.url.path, size, mtime, s.sessionId, s.app.rawValue, s.computer, title, s.projectPath,
                                 sg.first?.t0 ?? "", sg.last?.t1 ?? ""])
                let fid = Int(db.lastID)
                for x in rs { try insLine.run([fid, x.line, x.role, x.ts, x.text]) }
                for x in sg { try insSeg.run([fid, x.n, x.l0, x.l1, x.t0, x.t1, x.vers.joined(separator: "、"), x.head, x.kind]) }
                r.changed += 1
            }
            try db.exec("INSERT OR REPLACE INTO meta VALUES('updated', '\(Date().timeIntervalSince1970)')")
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
        r.seconds = Date().timeIntervalSince(t0)
        return r
    }

    /// 上次更新索引的时间
    static func updated(_ db: EchoDB) -> Date? {
        var v: Double?
        try? db.rows("SELECT v FROM meta WHERE k='updated'") { v = Double($0.text(0)) }
        return v.map { Date(timeIntervalSince1970: $0) }
    }
}

// MARK: 按关键词找（ech find 和左栏的搜索共用）

extension EchoIndex {
    struct Hit {
        var fid: Int, line: Int
        var role: String, ts: String, text: String
        var title: String, computer: String, app: String, sid: String, path: String
    }

    /// 关键词拆成几个词（空格、全角空格分开，几个都要有）
    static func terms(_ q: String) -> [String] {
        q.split(whereSeparator: { $0 == " " || $0 == "　" }).map(String.init)
    }

    /// 摘句时围着哪个词：先取 3 个字以上的（走全文索引的），没有就取第一个
    static func anchor(_ q: String) -> String {
        let t = terms(q)
        return t.first { $0.count >= 3 } ?? t.first ?? q
    }

    /// 找含这几个词的行，按时间从近到远。3 个字以上的词走全文索引（trigram 至少 3 个字），短的逐行比对（全表扫，约 1 秒）
    /// roles 只找这几种行（我、AI、总结…），nil 是全部；byRole 时按 roles 的先后排，同一种再按时间从近到远
    static func search(_ db: EchoDB, _ q: String, limit: Int, app: String? = nil, project: String? = nil, since: String? = nil, roles: [String]? = nil, byRole: Bool = false) throws -> [Hit] {
        let ts = terms(q)
        let long = ts.filter { $0.count >= 3 }, short = ts.filter { $0.count < 3 }
        guard !ts.isEmpty else { return [] }
        var sql = "SELECT l.fid, l.line, l.role, l.ts, l.text, f.title, f.computer, f.app, f.sid, f.path FROM "
        var args: [Any?] = []
        if long.isEmpty {
            sql += "lines l JOIN files f ON f.id = l.fid WHERE 1"
        } else {
            sql += "fts JOIN lines l ON l.id = fts.rowid JOIN files f ON f.id = l.fid WHERE fts MATCH ?"
            args.append(long.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " "))
        }
        for t in short { sql += " AND l.text LIKE ?"; args.append("%" + t + "%") }
        if let app { sql += " AND f.app = ?"; args.append(app) }
        if let project { sql += " AND f.cwd LIKE ?"; args.append("%" + project + "%") }
        if let since { sql += " AND l.ts >= ?"; args.append(since) }
        if let roles, !roles.isEmpty { sql += " AND l.role IN (" + roles.map { _ in "?" }.joined(separator: ",") + ")"; args += roles.map { $0 } }
        sql += " ORDER BY "
        if byRole, let roles, !roles.isEmpty {
            sql += "CASE l.role " + roles.indices.map { "WHEN ? THEN \($0) " }.joined() + "END, "
            args += roles.map { $0 }
        }
        sql += "l.ts DESC LIMIT ?"
        args.append(limit)
        var hits: [Hit] = []
        try db.rows(sql, args) { s in
            hits.append(Hit(fid: s.int(0), line: s.int(1), role: s.text(2), ts: s.text(3), text: s.text(4),
                            title: s.text(5), computer: s.text(6), app: s.text(7), sid: s.text(8), path: s.text(9)))
        }
        return hits
    }
}
