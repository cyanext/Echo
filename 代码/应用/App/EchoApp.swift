// 回响：程序坞应用（照伙伴云NAS应用 v0.5.0 起的做法），关掉窗口在后台照常运行，每天自动备份一次会话。
// 入口、备份状态、主菜单。浏览窗口见 EchoBrowser.swift，设置见 EchoSettings.swift。
import AppKit
import Combine
import ServiceManagement
import SwiftUI

// MARK: - 设置项

enum EchoPrefs {
    private static let d = UserDefaults.standard

    static var defaultComputerName: String {
        (Host.current().localizedName ?? "本机").replacingOccurrences(of: "/", with: "-")
    }

    /// 备份目录下的子文件夹名，两台电脑各用各的
    static var computerName: String {
        get { d.string(forKey: "computerName").flatMap { $0.trimmed.isEmpty ? nil : $0 } ?? defaultComputerName }
        set { d.set(newValue.trimmed.replacingOccurrences(of: "/", with: "-"), forKey: "computerName") }
    }

    /// 默认放代码目录旁边的「回响备份」（桌面在 iCloud 里，两台电脑共用），和代码分开
    static var defaultBackupRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop/项目代码/回响备份")
    }

    /// 以前的默认位置：0.5.0 及以前在代码目录里（项目代码/回响/备份），开发时试过 iCloud 云盘/回响。
    /// 没在设置里改过目录、新位置还没有时，整个挪过去，一次就好
    static func moveOldBackup() {
        guard d.string(forKey: "backupRoot") == nil else { return }
        let fm = FileManager.default, home = URL(fileURLWithPath: NSHomeDirectory())
        guard !fm.fileExists(atPath: defaultBackupRoot.path) else { return }
        let olds = ["Desktop/项目代码/回响/备份", "Library/Mobile Documents/com~apple~CloudDocs/回响"].map { home.appendingPathComponent($0) }
        guard let old = olds.first(where: { fm.fileExists(atPath: $0.path) }) else { return }
        do { try fm.moveItem(at: old, to: defaultBackupRoot) } catch { NSLog("回响：旧备份目录没挪成：%@", error.localizedDescription) }
    }

    static var backupRoot: URL {
        get { d.string(forKey: "backupRoot").map { URL(fileURLWithPath: $0) } ?? defaultBackupRoot }
        set { d.set(newValue.path, forKey: "backupRoot") }
    }

    static var computerDir: URL { backupRoot.appendingPathComponent(computerName) }

    private static func int(_ key: String, _ def: Int) -> Int { d.object(forKey: key) == nil ? def : d.integer(forKey: key) }

    /// 各类内容在备份里留多久（天）：-1 永久，0 不备份。默认：工具调用、工具结果 30 天，思考过程、系统记录不备份
    static var keepToolUse: Int { get { int("keepToolUse", 30) } set { d.set(newValue, forKey: "keepToolUse") } }
    static var keepToolResult: Int { get { int("keepToolResult", 30) } set { d.set(newValue, forKey: "keepToolResult") } }
    static var keepThinking: Int { get { int("keepThinking", 0) } set { d.set(newValue, forKey: "keepThinking") } }
    static var keepSystem: Int { get { int("keepSystem", 0) } set { d.set(newValue, forKey: "keepSystem") } }
    static var policy: EchoPolicy { EchoPolicy(toolUse: keepToolUse, toolResult: keepToolResult, thinking: keepThinking, system: keepSystem) }

    /// 上次清理备份的时间；cleanRules 记清理规则的版本，升级后第一次把已有备份全部过一遍（连密钥打码）
    static var lastClean: Date? { get { d.object(forKey: "lastClean") as? Date } set { d.set(newValue, forKey: "lastClean") } }
    /// 多久备份一次（小时）：1、6、24（默认，每天第一次开机或唤醒后）
    static var backupHours: Int { get { int("backupHours", 24) } set { d.set(newValue, forKey: "backupHours") } }
    /// 来源卡片上的勾：备不备份 Claude Code 的会话
    static var backupClaude: Bool { get { d.object(forKey: "backupClaude") == nil ? true : d.bool(forKey: "backupClaude") } set { d.set(newValue, forKey: "backupClaude") } }

    /// 自动删除 Claude 里不活跃的会话（默认开，30 天）
    static var autoDelete: Bool { get { d.object(forKey: "autoDelete") == nil ? true : d.bool(forKey: "autoDelete") } set { d.set(newValue, forKey: "autoDelete") } }
    static var autoDeleteDays: Int { get { int("autoDeleteDays", 30) } set { d.set(newValue, forKey: "autoDeleteDays") } }

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
    @Published var collections: [EchoCollection] = []
    /// 总览的数据（EchoStats 整理好的 JSON），会话列表变了重新整理
    @Published var overview: Data?
    /// 总览里点了某个会话：浏览窗口打开它
    @Published var openSessionID: String?
    /// 同时给了时间（毫秒）：打开后跳到那个时间的位置（总览里点了版本或提交）
    var openAt: Double?
    private var buildingOverview = false
    private var overviewAgain = false
    /// 上次跑备份的时间（成功失败都算），打开窗口时 5 分钟内跑过就不再跑
    var lastBackupRun: Date?

    private var timer: Timer?

    func start() {
        EchoPrefs.moveOldBackup()
        overview = EchoStats.loadLast()   // 先显示上次整理好的总览，后台再刷新
        lastSuccess = EchoBackupRecord.load(EchoPrefs.computerDir.appendingPathComponent("备份记录.json")).lastSuccess
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
        guard EchoPrefs.backupClaude else { return }
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
        let dir = EchoPrefs.computerDir
        Task.detached(priority: .utility) {
            var last = Date.distantPast
            let r = Result {
                try EchoBackup.run(source: EchoBackup.source, computerDir: dir, policy: EchoPrefs.policy) { n, t in
                    guard n == t || Date().timeIntervalSince(last) > 0.3 else { return }
                    last = Date()
                    Task { @MainActor in EchoState.shared.done = n; EchoState.shared.total = t }
                }
            }
            if case .success(let res) = r, res.failures.isEmpty {
                EchoState.cleanIfDue(dir)
                EchoState.autoDeleteIfOn(dir)
            }
            await MainActor.run {
                let s = EchoState.shared
                s.running = false
                switch r {
                case .success(let res):
                    s.failures = res.failures.map(\.path)
                    s.lastSuccess = EchoBackupRecord.load(dir.appendingPathComponent("备份记录.json")).lastSuccess
                    NSLog("回响备份：共 %d 个文件，写入 %d，跳过 %d，失败 %d，%.1f 秒", res.total, res.copied, res.skipped, res.failures.count, res.seconds)
                    for f in res.failures { NSLog("回响备份失败：%@：%@", f.path, f.message) }
                case .failure(let e):
                    s.error = e.localizedDescription
                }
                s.reloadSessions()
            }
        }
    }

    /// 备份成功后清理备份：每天最多一次；升级后第一次全部过一遍。在后台线程调用
    nonisolated static func cleanIfDue(_ dir: URL, now: Date = Date()) {
        let first = EchoPrefs.cleanRules < EchoPrefs.cleanRulesVersion
        if !first, let d = EchoPrefs.lastClean, Calendar.current.isDate(d, inSameDayAs: now) { return }
        var policy = EchoPrefs.policy
        policy.now = now
        do {
            let r = try EchoClean.run(computerDir: dir, policy: policy, force: first)
            NSLog("回响清理：%d 个文件，重写 %d 个，释放 %.1fMB，失败 %d", r.files, r.rewritten, Double(r.freed) / 1e6, r.failures.count)
            for f in r.failures { NSLog("回响清理失败：%@：%@", f.path, f.message) }
            if r.failures.isEmpty, first { EchoPrefs.cleanRules = EchoPrefs.cleanRulesVersion }
            EchoPrefs.lastClean = now
        } catch {
            NSLog("回响清理没跑起来：%@", error.localizedDescription)
        }
    }

    /// 备份成功后删 Claude 里不活跃、已备份完整的会话（设置里打开时）。在后台线程调用
    nonisolated static func autoDeleteIfOn(_ dir: URL) {
        guard EchoPrefs.autoDelete else { return }
        let list = EchoAutoDelete.candidates(source: EchoBackup.source, computerDir: dir, days: EchoPrefs.autoDeleteDays)
        guard !list.isEmpty else { return }
        let r = EchoAutoDelete.run(list)
        NSLog("回响自动删除：%d 个会话移进废纸篓，腾出 %.1fMB，失败 %d", r.count, Double(r.bytes) / 1e6, r.failures.count)
        for f in r.failures { NSLog("回响自动删除失败：%@：%@", f.path, f.message) }
    }

    func reloadSessions() {
        guard !scanning else { return }
        scanning = true
        let root = EchoPrefs.backupRoot
        Task.detached(priority: .userInitiated) {
            let list = EchoLibrary.scan(backupRoot: root)
            let cols = EchoCollections.load(root)
            await MainActor.run {
                EchoState.shared.sessions = list
                EchoState.shared.collections = cols
                EchoState.shared.scanning = false
                EchoState.shared.rebuildOverview()
            }
        }
    }

    /// 后台整理总览；正在整理时又来一次，整理完再跑一遍
    func rebuildOverview() {
        guard !buildingOverview else { overviewAgain = true; return }
        buildingOverview = true
        let list = sessions, root = EchoPrefs.backupRoot
        Task.detached(priority: .utility) {
            let data = EchoStats.build(list, deleted: EchoDeleted.loadAll(root))
            await MainActor.run {
                let s = EchoState.shared
                s.overview = data
                s.buildingOverview = false
                if s.overviewAgain { s.overviewAgain = false; s.rebuildOverview() }
            }
        }
    }

    // MARK: 改名、合集

    /// 写回原会话后立刻增量备份，列表里马上看到新名字
    func rename(_ s: EchoSession, to title: String) throws {
        guard let u = EchoRename.originalURL(for: s) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: "这个会话在 \(s.computer) 上，到那台电脑上改"])
        }
        try EchoRename.appendTitle(to: u, sessionId: s.sessionId, title: title)
        lastSuccess = nil
        backupNow()
    }

    /// 先把要删的会话按天的数记进「已删除统计」，总览照算；记不下来就不删。再一个个删，出错的跳过，最后报第一个错
    func delete(_ list: [EchoSession]) throws {
        try EchoDeleted.add(list.filter { EchoDelete.paths(for: $0) != nil }.map { try EchoDeleted.make($0) }, EchoPrefs.computerDir)
        var firstError: Error?
        for s in list {
            do {
                guard let p = EchoDelete.paths(for: s) else {
                    throw CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: "「\(s.meta.title)」在 \(s.computer) 上，到那台电脑上删"])
                }
                try EchoDelete.trash(p)
            } catch { firstError = firstError ?? error }
        }
        reloadSessions()
        if let e = firstError { throw e }
    }

    /// 挪到 dir：一个个挪，出错的跳过。挪成的记进移动记录、合集成员换成新路径。返回挪成的和第一个错
    func move(_ list: [EchoSession], to dir: String) -> (done: [EchoSession], error: Error?) {
        let dir = (dir as NSString).standardizingPath, root = EchoPrefs.backupRoot
        var done: [EchoSession] = [], firstError: Error?, moves: [String: String] = [:], keys: [String: String] = [:]
        for s in list {
            do {
                guard let p = EchoMove.paths(for: s, to: dir) else {
                    throw EchoMove.fail("「\(s.meta.title)」在 \(s.computer) 上，到那台电脑上挪")
                }
                try EchoMove.move(p, sessionId: s.sessionId)
                moves[s.sessionId] = dir
                keys[EchoCollections.key(s, root: root)] = String(p.newBackup.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
                done.append(s)
            } catch { firstError = firstError ?? error }
        }
        try? EchoMoved.add(moves, EchoPrefs.computerDir)
        if !keys.isEmpty {
            let cols = EchoCollections.load(root)
            let updated = cols.map { c in EchoCollection(id: c.id, title: c.title, members: c.members.map { keys[$0] ?? $0 }, created: c.created) }
            if updated != cols { try? saveCollections(updated) }
        }
        reloadSessions()
        return (done, firstError)
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
        NSApp.activate(ignoringOtherApps: true)
        browser?.makeKeyAndOrderFront(nil)
    }

    static func showSettings() {
        if settings == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 720),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "回响设置"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: EchoSettingsView())
            w.center()
            settings = w
        }
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
        let e = NSAppleEventManager.shared().currentAppleEvent
        quietLaunch = e?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSApp.mainMenu = Self.mainMenu()
            // 第一次打开时设成开机自动启动，之后以设置里的开关为准
            if !UserDefaults.standard.bool(forKey: "loginItemAsked") {
                UserDefaults.standard.set(true, forKey: "loginItemAsked")
                try? SMAppService.mainApp.register()
            }
            // 备份出问题时程序坞图标加「!」
            badge = EchoState.shared.objectWillChange.sink { _ in
                DispatchQueue.main.async { NSApp.dockTile.badgeLabel = EchoState.shared.needsAttention ? "!" : nil }
            }
            // 第一次打开：先走首次设置，点「完成」才开始备份
            if EchoOnboarding.needed {
                EchoOnboarding.show { EchoState.shared.start(); EchoWindows.showBrowser() }
                return
            }
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

#if !TEST
@main
enum EchoMain {
    static let delegate = EchoAppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
#endif
