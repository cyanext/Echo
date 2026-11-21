// 回响：菜单栏常驻，每天自动备份一次会话，浏览窗口按项目看会话。
// 入口、备份状态、菜单栏菜单。浏览窗口见 EchoBrowser.swift，设置见 EchoSettings.swift。
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

    static var defaultBackupRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop/项目代码/回响/备份")
    }

    static var backupRoot: URL {
        get { d.string(forKey: "backupRoot").map { URL(fileURLWithPath: $0) } ?? defaultBackupRoot }
        set { d.set(newValue.path, forKey: "backupRoot") }
    }

    static var computerDir: URL { backupRoot.appendingPathComponent(computerName) }
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

    private var timer: Timer?

    func start() {
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
        if let d = lastSuccess, Calendar.current.isDateInToday(d) { return }
        backupNow()
    }

    func backupNow() {
        guard !running else { return }
        running = true
        error = nil
        done = 0
        total = 0
        cleanupDays = EchoBackup.cleanupDays()
        let dir = EchoPrefs.computerDir
        Task.detached(priority: .utility) {
            var last = Date.distantPast
            let r = Result {
                try EchoBackup.run(source: EchoBackup.source, computerDir: dir) { n, t in
                    guard n == t || Date().timeIntervalSince(last) > 0.3 else { return }
                    last = Date()
                    Task { @MainActor in EchoState.shared.done = n; EchoState.shared.total = t }
                }
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

    func reloadSessions() {
        guard !scanning else { return }
        scanning = true
        let root = EchoPrefs.backupRoot
        Task.detached(priority: .userInitiated) {
            let list = EchoLibrary.scan(backupRoot: root)
            await MainActor.run {
                EchoState.shared.sessions = list
                EchoState.shared.scanning = false
            }
        }
    }

    /// 超过 3 天没成功备份
    var staleDays: Int? {
        guard let d = lastSuccess else { return nil }
        let n = Calendar.current.dateComponents([.day], from: d, to: Date()).day ?? 0
        return n > 3 ? n : nil
    }

    var needsAttention: Bool { error != nil || !failures.isEmpty || staleDays != nil }
}

// MARK: - 菜单栏

@MainActor
final class EchoMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var bag: AnyCancellable?
    private var open = false

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        updateIcon()
        bag = EchoState.shared.objectWillChange.sink { [weak self] _ in
            // 菜单展开时也刷新进度：放进 common 模式，菜单跟踪期间照样执行
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    self?.updateIcon()
                    if self?.open == true { self?.rebuild() }
                }
            }
        }
    }

    private func updateIcon() {
        let s = EchoState.shared
        let name = s.needsAttention ? "exclamationmark.bubble" : "bubble.left.and.text.bubble.right"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "回响")
        img?.isTemplate = true
        item.button?.image = img
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }
    func menuWillOpen(_ menu: NSMenu) { open = true }
    func menuDidClose(_ menu: NSMenu) { open = false }

    private func rebuild() {
        let s = EchoState.shared
        menu.removeAllItems()
        func info(_ t: String) {
            let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
            i.isEnabled = false
            menu.addItem(i)
        }
        if s.running { info(s.total > 0 ? "正在备份 \(s.done) / \(s.total)" : "正在备份…") }
        else if let e = s.error { info("备份失败：\(e)") }
        else if let d = s.lastSuccess { info("上次备份 \(EchoTime.short(d))") }
        else { info("还没有备份过") }
        if !s.running {
            if !s.failures.isEmpty { info("\(s.failures.count) 个文件没备份上，下次自动重试") }
            if let n = s.staleDays { info("已经 \(n) 天没有备份成功") }
        }
        if let n = s.cleanupDays {
            info("Claude Code 会自动删除 \(n) 天前的会话")
            info("在 ~/.claude/settings.json 把 cleanupPeriodDays 设成 36500")
        }
        menu.addItem(.separator())
        add("浏览会话…", #selector(browse), "o")
        add("立即备份", #selector(backup), "b").isEnabled = !s.running
        menu.addItem(.separator())
        add("设置…", #selector(settings), ",")
        add("退出回响", #selector(quit), "q")
    }

    @discardableResult
    private func add(_ title: String, _ sel: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        menu.addItem(i)
        return i
    }

    @objc private func browse() { EchoWindows.showBrowser() }
    @objc private func backup() { EchoState.shared.backupNow() }
    @objc private func settings() { EchoWindows.showSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
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
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: EchoBrowserView().environmentObject(EchoState.shared))
            w.setContentSize(NSSize(width: 1280, height: 820))
            w.center()
            w.setFrameAutosaveName("EchoBrowser")
            browser = w
        }
        EchoState.shared.reloadSessions()
        NSApp.activate(ignoringOtherApps: true)
        browser?.makeKeyAndOrderFront(nil)
    }

    static func showSettings() {
        if settings == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 260),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "回响设置"
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
    var menu: EchoMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSApp.mainMenu = Self.mainMenu()
            menu = EchoMenu()
            // 第一次打开时设成开机自动启动，之后以设置里的开关为准
            if !UserDefaults.standard.bool(forKey: "loginItemAsked") {
                UserDefaults.standard.set(true, forKey: "loginItemAsked")
                try? SMAppService.mainApp.register()
            }
            EchoState.shared.start()
        }
    }

    /// 菜单栏应用不显示主菜单，但拷贝、粘贴、全选、关窗口的快捷键要靠它
    static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        app.addItem(withTitle: "退出回响", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        for m in [app, edit] {
            let i = NSMenuItem()
            i.submenu = m
            main.addItem(i)
        }
        return main
    }
}

#if !TEST
@main
enum EchoMain {
    static let delegate = EchoAppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
#endif
