// 回响：程序坞应用（照伙伴云NAS应用 v0.5.0 起的做法），关掉窗口在后台照常运行，每天自动备份一次会话；菜单栏也有图标（EchoMenuBar.swift）。
// 入口、备份状态、主菜单。浏览窗口见 EchoBrowser.swift，设置见 EchoSettings.swift。
import AppKit
import Combine
import ServiceManagement
import SwiftUI

// MARK: - 设置项

enum EchoPrefs {
    /// 应用里是自己的设置；ech 从终端调用时没有应用的包身份，显式读回响的设置（备份目录等）
    private static let d: UserDefaults = {
        #if TEST
        return .standard
        #else
        return Bundle.main.bundleIdentifier == "com.cyanext.echo" ? .standard : (UserDefaults(suiteName: "com.cyanext.echo") ?? .standard)
        #endif
    }()

    static var defaultComputerName: String {
        (Host.current().localizedName ?? "本机").replacingOccurrences(of: "/", with: "-")
    }

    /// 备份目录下的子文件夹名，两台电脑各用各的
    static var computerName: String {
        get { d.string(forKey: "computerName").flatMap { $0.trimmed.isEmpty ? nil : $0 } ?? defaultComputerName }
        set { d.set(newValue.trimmed.replacingOccurrences(of: "/", with: "-"), forKey: "computerName") }
    }

    /// 没在设置里选过位置时用的：0.12.0 及以前的默认位置（桌面/项目代码/回响备份）已有备份的接着用，不挪；
    /// 新装的：有 iCloud 云盘放「iCloud 云盘/回响备份」（几台电脑共用），没有放「文稿/回响备份」；系统语言不是中文时文件夹叫「Echo Backup」
    static var defaultBackupRoot: URL { defaultBackupRoot(home: URL(fileURLWithPath: NSHomeDirectory())) }

    static func defaultBackupRoot(home: URL) -> URL {
        let fm = FileManager.default
        let legacy = home.appendingPathComponent("Desktop/项目代码/回响备份")
        if fm.fileExists(atPath: legacy.path) { return legacy }
        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        let name = Locale.preferredLanguages.first?.hasPrefix("zh") == false ? "Echo Backup" : "回响备份"
        return fm.fileExists(atPath: icloud.path) ? icloud.appendingPathComponent(name) : home.appendingPathComponent("Documents/" + name)
    }

    /// 启动时把默认位置记进设置：之后开了 iCloud 云盘、建了旧文件夹，位置也不会变
    static func pinBackupRoot() {
        if d.string(forKey: "backupRoot") == nil { d.set(defaultBackupRoot.path, forKey: "backupRoot") }
    }

    static var backupRoot: URL {
        get { runRoot ?? d.string(forKey: "backupRoot").map { URL(fileURLWithPath: $0) } ?? defaultBackupRoot }
        set { d.set(newValue.path, forKey: "backupRoot") }
    }
    /// 只在这次运行里用的备份位置：ech 发现设置里的位置是一台电脑的备份文件夹时，按上一级读，设置留给应用启动时改
    static var runRoot: URL?

    /// 0.14.1 及以前，设置里能把备份位置选进某台电脑的备份文件夹，之后的备份多套一层电脑名。
    /// 应用启动时改回放各台电脑的那一级，设错那段时间写进多套那层的备份挪回来
    /// trash：测试时换成直接删，不往系统的废纸篓里放
    static func repairBackupRoot(trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        let root = backupRoot.standardizedFileURL, fixed = EchoLayout.sharedRoot(root)
        if fixed.path != root.path {
            NSLog("回响：备份位置是一台电脑的备份文件夹，改用上一级：%@ → %@", root.path, fixed.path)
            backupRoot = fixed
        }
        // 每次启动都看一眼：上次没挪完的接着挪（没有多套那层时只查几个文件在不在）
        let n = EchoLayout.rescueNested(computerDir, name: computerName, trash: trash)
        if n > 0 { NSLog("回响：多套那层的 %d 个文件挪回了 %@", n, computerDir.path) }
    }

    static var computerDir: URL { backupRoot.appendingPathComponent(computerName) }
    /// 这台电脑 Claude 的备份：projects/、备份记录.json、移动记录.json（0.8 起分应用放，见 EchoLayout）
    static var claudeDir: URL { EchoLayout.dir(computerDir, .claude) }
    static var codexDir: URL { EchoLayout.dir(computerDir, .codex) }

    private static func int(_ key: String, _ def: Int) -> Int { d.object(forKey: key) == nil ? def : d.integer(forKey: key) }

    /// 各类内容在备份里留多久（天）：-1 永久，0 不备份。默认：工具调用、工具结果 30 天，思考过程、系统记录不备份
    static var keepToolUse: Int { get { int("keepToolUse", 30) } set { d.set(newValue, forKey: "keepToolUse") } }
    static var keepToolResult: Int { get { int("keepToolResult", 30) } set { d.set(newValue, forKey: "keepToolResult") } }
    static var keepThinking: Int { get { int("keepThinking", 0) } set { d.set(newValue, forKey: "keepThinking") } }
    static var keepSystem: Int { get { int("keepSystem", 0) } set { d.set(newValue, forKey: "keepSystem") } }
    /// 图片和文件：默认 0 不备份
    static var keepMedia: Int { get { int("keepMedia", 0) } set { d.set(newValue, forKey: "keepMedia") } }
    static var policy: EchoPolicy { EchoPolicy(toolUse: keepToolUse, toolResult: keepToolResult, thinking: keepThinking, system: keepSystem, media: keepMedia) }

    /// 上次清理备份的时间；cleanRules 记清理规则的版本，升级后第一次把已有备份全部过一遍（连密钥打码）
    static var lastClean: Date? { get { d.object(forKey: "lastClean") as? Date } set { d.set(newValue, forKey: "lastClean") } }
    /// 多久备份一次（小时）：1、6、24（默认，每天第一次开机或唤醒后）
    static var backupHours: Int { get { int("backupHours", 24) } set { d.set(newValue, forKey: "backupHours") } }
    /// 主题：system 跟随系统、light 浅色、dark 深色。左栏、设置和网页一起变：网页的深色跟着窗口的外观走
    static var theme: String { get { d.string(forKey: "theme") ?? "system" } set { d.set(newValue, forKey: "theme"); applyTheme() } }
    static func applyTheme() {
        NSApp.appearance = theme == "light" ? NSAppearance(named: .aqua) : theme == "dark" ? NSAppearance(named: .darkAqua) : nil
    }
    /// 来源卡片上的勾：备不备份 Claude Code 的会话
    static var backupClaude: Bool { get { d.object(forKey: "backupClaude") == nil ? true : d.bool(forKey: "backupClaude") } set { d.set(newValue, forKey: "backupClaude") } }
    /// 备不备份 Codex 的会话（默认开；本机没有 ~/.codex/sessions 时不起作用）
    static var autoUpdate: Bool { get { d.object(forKey: "autoUpdate") == nil ? true : d.bool(forKey: "autoUpdate") } set { d.set(newValue, forKey: "autoUpdate") } }
    /// 图标显示在哪：both 程序坞和菜单栏（默认）、menubar 只在菜单栏、dock 只在程序坞。改了调 EchoMenuBar.apply()
    static var iconPlace: String { get { d.string(forKey: "iconPlace") ?? "both" } set { d.set(newValue, forKey: "iconPlace") } }
    static var backupCodex: Bool { get { d.object(forKey: "backupCodex") == nil ? true : d.bool(forKey: "backupCodex") } set { d.set(newValue, forKey: "backupCodex") } }
    static var hasCodex: Bool { FileManager.default.fileExists(atPath: EchoBackup.codexSource.appendingPathComponent("sessions").path) }
    /// 这次要备份的应用和各自的备份文件夹
    static var enabledSources: [(EchoSource, URL)] {
        (backupClaude ? [(EchoSource.claude, claudeDir)] : []) + (backupCodex && hasCodex ? [(EchoSource.codex, codexDir)] : [])
    }
    /// 上次备份成功：勾选的应用里最早的那个（都成功过才算这次备份完整）
    static var lastSuccess: Date? {
        let dates = enabledSources.map { EchoBackupRecord.load($0.1.appendingPathComponent("备份记录.json")).lastSuccess }
        return dates.contains(where: { $0 == nil }) ? nil : dates.compactMap { $0 }.min()
    }

    /// 自动删除 Claude 里不活跃的会话（默认开，30 天）
    static var autoDelete: Bool { get { d.object(forKey: "autoDelete") == nil ? true : d.bool(forKey: "autoDelete") } set { d.set(newValue, forKey: "autoDelete") } }
    static var autoDeleteDays: Int { get { int("autoDeleteDays", 30) } set { d.set(newValue, forKey: "autoDeleteDays") } }
    /// Codex 也自动清理（默认开，30 天）：Codex 自己不删会话，一直攒着
    static var autoDeleteCodex: Bool { get { d.object(forKey: "autoDeleteCodex") == nil ? true : d.bool(forKey: "autoDeleteCodex") } set { d.set(newValue, forKey: "autoDeleteCodex") } }
    static var autoDeleteCodexDays: Int { get { int("autoDeleteCodexDays", 30) } set { d.set(newValue, forKey: "autoDeleteCodexDays") } }

    static let cleanRulesVersion = 1
    static var cleanRules: Int { get { d.integer(forKey: "cleanRules") } set { d.set(newValue, forKey: "cleanRules") } }
}

// MARK: - 状态

@MainActor
final class EchoState: ObservableObject {
    static let shared = EchoState()

    @Published var running = false
    @Published var done = 0
    @Published var total = 0
    @Published var lastSuccess: Date?
    /// 整个备份没跑起来的原因（备份目录写不进去等）
    @Published var error: String?
    @Published var failures: [String] = []
    @Published var cleanupDays: Int?
    @Published var sessions: [EchoSession] = []
    @Published var scanning = false
    /// 备份拷完了，正在更新索引
    @Published var indexing = false
    /// 只在 iCloud 云端、列表、索引、总览这次没读的文件（见 EchoCloud），下载完补进来
    @Published var waitList: [String] = []
    @Published var waitIndex: [String] = []
    @Published var waitStats: [String] = []
    var cloudWaiting: Set<String> { Set(waitList + waitIndex + waitStats) }
    private var cloudTimer: Timer?
    private var refreshing = false
    @Published var collections: [EchoCollection] = []
    /// 总览的数据（EchoStats 整理好的 JSON），会话列表变了重新整理
    @Published var overview: Data?
    /// 总览里点了某个会话：浏览窗口打开它
    @Published var openSessionID: String?
    /// 菜单栏点了「全局搜索…」：浏览窗口的搜索框获得焦点（每点一次加 1）
    @Published var focusSearch = 0
    /// 同时给了时间（毫秒）：打开后跳到那个时间的位置（总览里点了版本或提交）
    var openAt: Double?
    var openVer: String?          // 总览点的版本号：对话页先按它找要点，找不到再按 openAt 的时间
    private var buildingOverview = false
    private var overviewAgain = false
    /// 上次跑备份的时间（成功失败都算），打开窗口时 5 分钟内跑过就不再跑
    var lastBackupRun: Date?

    private var timer: Timer?

    func start() {
        EchoPrefs.pinBackupRoot()
        EchoPrefs.repairBackupRoot()
        do { try EchoLayout.migrate(EchoPrefs.computerDir) } catch { NSLog("回响：Claude 的备份没挪进 claude/：%@", error.localizedDescription) }
        overview = EchoStats.loadLast()   // 先显示上次整理好的总览，后台再刷新
        EchoPrices.refreshIfDue()
        lastSuccess = EchoPrefs.lastSuccess
        cleanupDays = EchoBackup.cleanupDays()
        backupIfNeeded()
        // 每小时看一次：电脑每天第一次开机或唤醒后就会备份，不用固定时间点
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in EchoState.shared.backupIfNeeded() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))   // 刚唤醒时 iCloud 和网络还没就绪
                EchoState.shared.backupIfNeeded()
            }
        }
    }

    func backupIfNeeded() {
        guard !EchoPrefs.enabledSources.isEmpty else { return }
        if let d = lastSuccess {
            let h = EchoPrefs.backupHours
            if h >= 24 ? Calendar.current.isDateInToday(d) : Date().timeIntervalSince(d) < Double(h) * 3600 - 60 { return }
        }
        backupNow()
    }

    func backupNow() {
        guard !running else { return }
        running = true
        lastBackupRun = Date()
        error = nil
        done = 0
        total = 0
        cleanupDays = EchoBackup.cleanupDays()
        Task.detached(priority: .utility) {
            var last = Date.distantPast
            let job = EchoBackupJob.run { done, total in
                guard done == total || Date().timeIntervalSince(last) > 0.3 else { return }
                last = Date()
                Task { @MainActor in EchoState.shared.done = done; EchoState.shared.total = total }
            }
            let r = job.result
            // 备份完更新 ech 的索引（只处理变了的备份文件），扫出的列表直接给左栏用，不再扫一遍
            var fresh: (EchoScanResult, [String], [EchoCollection])?
            if case .success = r {
                await MainActor.run { EchoState.shared.indexing = true }
                fresh = EchoState.scanAndIndex(EchoPrefs.backupRoot)
            }
            await MainActor.run {
                let s = EchoState.shared
                s.running = false
                s.indexing = false
                switch r {
                case .success(let res):
                    s.failures = res.failures.map(\.path)
                    s.lastSuccess = EchoPrefs.lastSuccess
                    NSLog("回响备份：共 %d 个文件，写入 %d，跳过 %d，失败 %d，%.1f 秒", res.total, res.copied, res.skipped, res.failures.count, res.seconds)
                    for f in res.failures { NSLog("回响备份失败：%@：%@", f.path, f.message) }
                case .failure(let e):
                    s.error = e.localizedDescription
                }
                if let fresh { s.apply(fresh.0, waitIndex: fresh.1, collections: fresh.2) } else { s.reloadSessions() }
            }
        }
    }

    /// 扫列表、更新索引，在后台线程调用。只在 iCloud 云端的文件先跳过
    nonisolated static func scanAndIndex(_ root: URL) -> (EchoScanResult, [String], [EchoCollection]) {
        let scan = EchoLibrary.scan(backupRoot: root, skipCloud: true)
        var waitIndex: [String] = []
        do { waitIndex = try EchoIndex.update(scan).waiting } catch { NSLog("回响：更新索引失败：%@", error.localizedDescription) }
        return (scan, waitIndex, EchoCollections.load(root))
    }

    /// 用扫好的列表刷新左栏，再整理总览
    private func apply(_ scan: EchoScanResult, waitIndex: [String]? = nil, collections cols: [EchoCollection]) {
        sessions = scan.sessions
        collections = cols
        waitList = scan.waiting
        if let waitIndex { self.waitIndex = waitIndex }
        watchCloud()
        rebuildOverview()
    }

    /// 有文件在等 iCloud 下载时，每 15 秒看一眼；有下完的就重扫列表、更新索引和总览（读过的有缓存，只读新到的）
    private func watchCloud() {
        if cloudWaiting.isEmpty { cloudTimer?.invalidate(); cloudTimer = nil; return }
        guard cloudTimer == nil else { return }
        cloudTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor in EchoState.shared.checkCloud() }
        }
    }

    private func checkCloud() {
        guard !running, !refreshing, !scanning else { return }
        let paths = cloudWaiting, root = EchoPrefs.backupRoot
        refreshing = true
        Task.detached(priority: .utility) {
            let fresh = paths.contains { !EchoCloud.isPlaceholder($0) } ? EchoState.scanAndIndex(root) : nil
            await MainActor.run {
                let s = EchoState.shared
                s.refreshing = false
                if let fresh { s.apply(fresh.0, waitIndex: fresh.1, collections: fresh.2) }
            }
        }
    }

    /// 备份成功后清理备份：每天最多一次；升级后第一次全部过一遍。在后台线程调用。跑了返回结果（记进备份日志）
    @discardableResult
    nonisolated static func cleanIfDue(_ dir: URL, now: Date = Date()) -> EchoClean.Result? {
        let first = EchoPrefs.cleanRules < EchoPrefs.cleanRulesVersion
        if !first, let d = EchoPrefs.lastClean, Calendar.current.isDate(d, inSameDayAs: now) { return nil }
        var policy = EchoPrefs.policy
        policy.now = now
        do {
            let r = try EchoClean.run(computerDir: dir, policy: policy, force: first)
            NSLog("回响清理：%d 个文件，重写 %d 个，释放 %.1fMB，失败 %d", r.files, r.rewritten, Double(r.freed) / 1e6, r.failures.count)
            for f in r.failures { NSLog("回响清理失败：%@：%@", f.path, f.message) }
            if r.failures.isEmpty, first { EchoPrefs.cleanRules = EchoPrefs.cleanRulesVersion }
            EchoPrefs.lastClean = now
            return r
        } catch {
            NSLog("回响清理没跑起来：%@", error.localizedDescription)
            return nil
        }
    }

    /// 备份成功后删 Claude 里不活跃、已备份完整的会话（设置里打开时）。dir 是 Claude 的备份（claude/）。在后台线程调用
    @discardableResult
    nonisolated static func autoDeleteIfOn(_ dir: URL) -> (count: Int, bytes: Int64)? {
        guard EchoPrefs.autoDelete else { return nil }
        let list = EchoAutoDelete.candidates(source: EchoBackup.source, computerDir: dir, days: EchoPrefs.autoDeleteDays)
        guard !list.isEmpty else { return nil }
        let r = EchoAutoDelete.run(list)
        NSLog("回响自动清理：%d 个会话移到废纸篓，释放 %.1fMB，失败 %d", r.count, Double(r.bytes) / 1e6, r.failures.count)
        for f in r.failures { NSLog("回响自动删除失败：%@：%@", f.path, f.message) }
        return r.count > 0 ? (r.count, r.bytes) : nil
    }

    /// Codex 的自动清理（设置里打开时）。dir 是 Codex 的备份（codex/）。在后台线程调用
    @discardableResult
    nonisolated static func autoDeleteCodexIfOn(_ dir: URL) -> (count: Int, bytes: Int64)? {
        guard EchoPrefs.autoDeleteCodex else { return nil }
        let list = EchoAutoDelete.codexCandidates(source: EchoBackup.codexSource, dir: dir, days: EchoPrefs.autoDeleteCodexDays)
        guard !list.isEmpty else { return nil }
        let r = EchoAutoDelete.run(list)
        NSLog("回响自动清理 Codex：%d 个会话移到废纸篓，释放 %.1fMB，失败 %d", r.count, Double(r.bytes) / 1e6, r.failures.count)
        for f in r.failures { NSLog("回响自动清理 Codex 失败：%@：%@", f.path, f.message) }
        return r.count > 0 ? (r.count, r.bytes) : nil
    }

    func reloadSessions() {
        guard !scanning else { return }
        scanning = true
        let root = EchoPrefs.backupRoot
        Task.detached(priority: .userInitiated) {
            let scan = EchoLibrary.scan(backupRoot: root, skipCloud: true)
            let cols = EchoCollections.load(root)
            await MainActor.run {
                EchoState.shared.scanning = false
                EchoState.shared.apply(scan, collections: cols)
            }
        }
    }

    /// 后台整理总览；正在整理时又来一次，整理完再跑一遍
    func rebuildOverview() {
        guard !buildingOverview else { overviewAgain = true; return }
        buildingOverview = true
        let list = sessions, root = EchoPrefs.backupRoot
        Task.detached(priority: .utility) {
            let (data, waiting) = EchoStats.build(list, deleted: EchoDeleted.loadAll(root), skipCloud: true)
            await MainActor.run {
                let s = EchoState.shared
                s.overview = data
                s.waitStats = waiting
                s.watchCloud()
                s.buildingOverview = false
                if s.overviewAgain { s.overviewAgain = false; s.rebuildOverview() }
            }
        }
    }

    // MARK: 改名、合集

    /// 写回原会话后立刻增量备份，列表里马上看到新名字
    func rename(_ s: EchoSession, to title: String) throws {
        guard s.app == .claude else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: "Codex 会话请在 Codex 中改名"]) }
        guard let u = EchoRename.originalURL(for: s) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: "此会话在 \(s.computer) 上，请在该电脑上改名"])
        }
        try EchoRename.appendTitle(to: u, sessionId: s.sessionId, title: title)
        lastSuccess = nil
        backupNow()
    }

    /// 删会话：原会话在就和备份一起移到废纸篓，不在（清理了、在另一台电脑上）就只移备份。
    /// keepStats：先把按天的数记进「已删除统计」，总览照算（记不下来就不删）；不保留时连统计一起删。一个个删，出错的跳过，最后报第一个错
    func delete(_ list: [EchoSession], keepStats: Bool = true) throws {
        if keepStats { try EchoDeleted.add(list.map { try EchoDeleted.make($0) }, EchoPrefs.computerDir) }
        else { EchoDeleted.forget(Set(list.map { $0.computer + "/" + $0.sessionId }), EchoPrefs.backupRoot) }
        var firstError: Error?
        for s in list {
            do { try EchoDelete.trash(EchoDelete.paths(for: s)) } catch { firstError = firstError ?? error }
        }
        reloadSessions()
        if let e = firstError { throw e }
    }

    /// 总览里点了已删除会话的「删除统计」：先确认（网页里的 confirm 在 WKWebView 弹不出来，由这里弹）
    func forgetStats(_ id: String) {
        let a = NSAlert()
        a.messageText = "删除此会话的统计数据？"
        a.informativeText = "删除后，总览将不再计入该会话的消息数、Token 和时长。此操作无法撤销。"
        a.addButton(withTitle: "删除")
        a.addButton(withTitle: "取消")
        a.buttons[0].hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        EchoDeleted.forget([id], EchoPrefs.backupRoot)
        rebuildOverview()
    }

    /// 挪到 dir：一个个挪，出错的跳过。挪成的记进移动记录、合集成员换成新路径。返回挪成的和第一个错
    func move(_ list: [EchoSession], to dir: String) -> (done: [EchoSession], error: Error?) {
        let r = EchoMove.moveSessions(list, to: dir)
        collections = EchoCollections.load(EchoPrefs.backupRoot)
        reloadSessions()
        return r
    }

    func saveCollections(_ list: [EchoCollection]) throws {
        try EchoCollections.save(list, EchoPrefs.backupRoot)
        collections = list
    }

    func addCollection(_ members: [EchoSession]) throws -> EchoCollection {
        let root = EchoPrefs.backupRoot
        let sorted = members.sorted { $0.meta.start < $1.meta.start }
        let c = EchoCollection(title: "\(sorted.first?.meta.title ?? "合集") 等 \(sorted.count) 个会话",
                               members: sorted.map { EchoCollections.key($0, root: root) })
        try saveCollections(EchoCollections.load(root) + [c])
        return c
    }

    /// 超过 3 天没成功备份
    var staleDays: Int? {
        guard let d = lastSuccess else { return nil }
        let n = Calendar.current.dateComponents([.day], from: d, to: Date()).day ?? 0
        return n > 3 ? n : nil
    }

    var needsAttention: Bool { error != nil || !failures.isEmpty || staleDays != nil || cleanupDays != nil }
}

// MARK: - 窗口

@MainActor
enum EchoWindows {
    private static var browser: NSWindow?
    private static var settings: NSWindow?

    static func showBrowser() {
        if browser == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "回响"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: EchoBrowserView().environmentObject(EchoState.shared))
            w.setContentSize(NSSize(width: 1280, height: 820))
            w.center()
            w.setFrameAutosaveName("EchoBrowser")
            browser = w
        }
        // 浏览读的是备份：打开窗口时顺手增量备份一次，今天的会话也能看到（只写变过的文件，一两秒）
        let s = EchoState.shared
        // 列表还没读过时先读已有的备份，不等这次备份做完（备份完会再读一遍）
        if s.sessions.isEmpty { s.reloadSessions() }
        if s.running { } else if let d = s.lastBackupRun, Date().timeIntervalSince(d) < 300 { s.reloadSessions() } else { s.backupNow() }
        EchoMenuBar.shared.windowWillShow()
        NSApp.activate(ignoringOtherApps: true)
        browser?.makeKeyAndOrderFront(nil)
    }

    /// 菜单栏「全局搜索…」：打开浏览窗口，等窗口出来再聚焦搜索框
    static func showSearch() {
        showBrowser()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { EchoState.shared.focusSearch += 1 }
    }

    /// page：打开到哪一页（菜单栏的状态行点进来时用）；不给就停在上次那一页
    static func showSettings(_ page: EchoSettingsView.Page? = nil) {
        if let page, let w = settings { w.contentView = NSHostingView(rootView: EchoSettingsView(start: page)) }
        if settings == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 720),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "回响设置"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: EchoSettingsView(start: page ?? .general))
            w.center()
            settings = w
        }
        EchoMenuBar.shared.windowWillShow()
        NSApp.activate(ignoringOtherApps: true)
        settings?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - 入口

final class EchoAppDelegate: NSObject, NSApplicationDelegate {
    private var badge: AnyCancellable?
    /// 开机自动启动时不弹窗口，在后台备份
    private var quietLaunch = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 只在菜单栏显示时，启动前就设好，程序坞里不闪一下图标
        if EchoPrefs.iconPlace == "menubar" { NSApp.setActivationPolicy(.accessory) }
        let e = NSAppleEventManager.shared().currentAppleEvent
        quietLaunch = e?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        EchoPrefs.applyTheme()
        MainActor.assumeIsolated {
            NSApp.mainMenu = Self.mainMenu()
            EchoMenuBar.shared.apply()
            EchoUpdate.shared.start()
            DispatchQueue.global(qos: .utility).async { _ = EchoCLIInstall.inPath }   // 先在后台问好终端的 PATH，打开设置时不卡
            // 升级上来、走过首次设置的：第一次打开新版时设成开机自动启动，之后以设置里的开关为准。新装的在首次设置里选
            if !EchoOnboarding.needed, !UserDefaults.standard.bool(forKey: "loginItemAsked") {
                UserDefaults.standard.set(true, forKey: "loginItemAsked")
                try? SMAppService.mainApp.register()
            }
            // 备份出问题时程序坞图标加「!」
            badge = EchoState.shared.objectWillChange.sink { _ in
                DispatchQueue.main.async { NSApp.dockTile.badgeLabel = EchoState.shared.needsAttention ? "!" : nil }
            }
            // 第一次打开：先走首次设置，点「完成」才开始备份；首次设置里勾着的开机自动启动、命令行工具 ech 这时执行
            if EchoOnboarding.needed {
                EchoOnboarding.show {
                    EchoOnboarding.finish()
                    EchoState.shared.start(); EchoWindows.showBrowser()
                }
                return
            }
            // 升级到带 ech 的版本后第一次启动：已经走过首次设置的，自动装一次；之后以设置里的为准
            if !UserDefaults.standard.bool(forKey: "cliAsked") {
                UserDefaults.standard.set(true, forKey: "cliAsked")
                if !EchoCLIInstall.installed { try? EchoCLIInstall.install() }
            }
            EchoCLIInstall.refreshIfInstalled()
            EchoState.shared.start()
            if !quietLaunch { EchoWindows.showBrowser() }
        }
    }

    /// 关掉窗口后照常在后台运行，每天备份
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 点程序坞图标、再打开一次时弹出浏览窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { if !EchoOnboarding.bringFront() { EchoWindows.showBrowser() } } }
        return true
    }

    @MainActor static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: "关于回响", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(EchoAction.item("检查更新…", "") { EchoUpdate.shared.check(manual: true) })
        app.addItem(.separator())
        app.addItem(EchoAction.item("设置…", ",") { EchoWindows.showSettings() })
        app.addItem(EchoAction.item("立即备份", "b") { EchoState.shared.backupNow() })
        app.addItem(.separator())
        app.addItem(withTitle: "隐藏回响", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "退出回响", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let window = NSMenu(title: "窗口")
        window.addItem(EchoAction.item("浏览会话", "0") { EchoWindows.showBrowser() })
        window.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        for m in [app, edit, window] {
            let i = NSMenuItem()
            i.submenu = m
            main.addItem(i)
        }
        NSApp.windowsMenu = window
        return main
    }
}

/// 菜单项直接带一个闭包
final class EchoAction: NSObject {
    private static var keep: [EchoAction] = []
    private let run: () -> Void
    private init(_ run: @escaping () -> Void) { self.run = run }
    @objc private func fire() { run() }

    @MainActor static func item(_ title: String, _ key: String, _ run: @escaping @MainActor () -> Void) -> NSMenuItem {
        let a = EchoAction { MainActor.assumeIsolated { run() } }
        keep.append(a)
        let i = NSMenuItem(title: title, action: #selector(fire), keyEquivalent: key)
        i.target = a
        return i
    }
}

/// 回响的备份一次：勾选的应用一个个备份，成功后清理到期内容、自动清理非活跃会话，写备份日志。
/// 应用的「立即备份」和 ech backup 共用；两边同时跑时，后来的等先来的跑完（备份.lock 文件锁）
enum EchoBackupJob {
    static func run(progress: @escaping (Int, Int) -> Void = { _, _ in }) -> (result: Result<EchoBackupResult, Error>, logs: [[String: Any]]) {
        let lock = open(EchoLibrary.supportDir.appendingPathComponent("备份.lock").path, O_CREAT | O_RDWR, 0o644)
        if lock >= 0 { flock(lock, LOCK_EX) }
        defer { if lock >= 0 { flock(lock, LOCK_UN); close(lock) } }
        let dir = EchoPrefs.computerDir, claudeDir = EchoPrefs.claudeDir, sources = EchoPrefs.enabledSources
        let started = ISO8601DateFormatter().string(from: Date())
        var logs: [[String: Any]] = []
        // 另一台电脑交出的会话先自动接到本机，这次备份就带上它，那台下次备份时据此移走交接副本
        if sources.contains(where: { $0.0 == .claude }) {
            let key = "接手过的交接副本"
            let r = EchoHandoff.receive(done: Set(UserDefaults.standard.stringArray(forKey: key) ?? []))
            UserDefaults.standard.set(Array(r.done), forKey: key)
            if !r.got.isEmpty { NSLog("回响自动接手：%@", r.got.map { "\($0.title)（\($0.from)）" }.joined(separator: "、")) }
        }
        let r = Result { () -> EchoBackupResult in
            let lists = try sources.map { s, d -> (EchoSource, [EchoBackup.Item], URL) in
                (s, s == .claude ? try EchoBackup.claudeItems(EchoBackup.source) : EchoBackup.codexItems(EchoBackup.codexSource), d)
            }
            let total = lists.reduce(0) { $0 + $1.1.count }
            var all = EchoBackupResult(), before = 0
            for (src, items, d) in lists {
                let one = try EchoBackup.run(items: items, computerDir: d, policy: EchoPrefs.policy) { n, _ in progress(before + n, total) }
                before += items.count
                logs.append(EchoBackupLog.entry(started, src, one))
                all.copied += one.copied; all.skipped += one.skipped; all.total += one.total
                all.bytesIn += one.bytesIn; all.bytesOut += one.bytesOut; all.failures += one.failures; all.seconds += one.seconds
            }
            return all
        }
        if case .success(let res) = r, res.failures.isEmpty {
            if let c = EchoState.cleanIfDue(dir) { logs.append(["t": started, "app": "", "cleanFiles": c.rewritten, "cleanFreed": c.freed]) }
            if sources.contains(where: { $0.0 == .claude }), let a = EchoState.autoDeleteIfOn(claudeDir) {
                logs.append(["t": started, "app": "claude", "autoDel": a.count, "autoDelBytes": a.bytes])
            }
            if sources.contains(where: { $0.0 == .claude }) {
                let n = EchoHandoff.cleanup()   // 交接副本：另一台接手了、或放了 30 天的移走
                if n > 0 { NSLog("回响移走交接副本：%d 个", n) }
            }
            if let (_, codexDir) = sources.first(where: { $0.0 == .codex }), let a = EchoState.autoDeleteCodexIfOn(codexDir) {
                logs.append(["t": started, "app": "codex", "autoDel": a.count, "autoDelBytes": a.bytes])
            }
        }
        if case .failure(let e) = r { logs.append(["t": started, "app": "", "error": e.localizedDescription]) }
        EchoBackupLog.append(dir, logs)
        return (r, logs)
    }
}

#if !TEST
@main
enum EchoMain {
    static let delegate = EchoAppDelegate()

    static func main() {
        // 用 ech 这个名字调用：命令行模式，不开窗口
        if EchoCLI.isCLI { exit(EchoCLI.main(Array(CommandLine.arguments.dropFirst()))) }
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
#endif
