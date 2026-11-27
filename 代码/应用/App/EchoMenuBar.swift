// 菜单栏图标：常驻菜单栏，看备份状态；点开有立即备份、打开回响、全局搜索、最近会话、设置、检查更新、退出。
// 设置「通用 → 显示图标」能选只在菜单栏或只在程序坞；只在菜单栏时窗口从菜单栏打开，开着窗口时和普通应用一样有顶部菜单栏、
// 程序坞图标，⌘Tab 能切到（macOS 不给程序坞里没有的应用显示顶部菜单栏），窗口全关后程序坞和 ⌘Tab 里没有回响。
import AppKit
import Combine

@MainActor
final class EchoMenuBar: NSObject, NSMenuDelegate {
    static let shared = EchoMenuBar()
    private var item: NSStatusItem?
    private var watch: AnyCancellable?
    private var spin: Timer?
    private var phase = 0
    private let menu = NSMenu()
    private let status = NSMenuItem()
    private let today = NSMenuItem()
    private let recent = NSMenuItem(title: "最近会话", action: nil, keyEquivalent: "")
    private var backup: NSMenuItem?
    /// 状态行能点时点了去哪：备份失败去设置「通用」改备份位置，Claude Code 会删会话去「存储」
    private var fix: EchoSettingsView.Page?
    private var windowWatch: [NSObjectProtocol] = []

    /// 按设置显示或去掉菜单栏图标、程序坞图标
    func apply() {
        let place = EchoPrefs.iconPlace
        if windowWatch.isEmpty {
            let nc = NotificationCenter.default
            windowWatch = [
                nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { EchoMenuBar.shared.updatePolicy() }
                },
                // 关窗口的通知在窗口消失前发，等它关完再看还有没有窗口
                nc.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
                    DispatchQueue.main.async { MainActor.assumeIsolated { EchoMenuBar.shared.updatePolicy() } }
                },
            ]
        }
        updatePolicy()
        if place == "dock" { remove() } else { install() }
    }

    /// 打开窗口前调：只在菜单栏时先换成普通应用再把回响切到前面，顶部菜单栏才会跟着出来
    func windowWillShow() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    /// 只在菜单栏时，开着窗口（含缩到程序坞的）就是普通应用，窗口全关了再从程序坞、⌘Tab 里去掉
    func updatePolicy() {
        let want: NSApplication.ActivationPolicy = EchoPrefs.iconPlace != "menubar" || Self.hasWindow(NSApp.windows) ? .regular : .accessory
        if NSApp.activationPolicy() != want { NSApp.setActivationPolicy(want) }
    }

    /// 算不算开着回响的窗口：浏览、设置、首次设置这类带标题栏的普通窗口，显示着或缩到了程序坞；提示框、菜单不算
    static func hasWindow(_ windows: [NSWindow]) -> Bool {
        windows.contains { w in
            !(w is NSPanel) && w.styleMask.contains(.titled) && w.level == .normal && (w.isVisible || w.isMiniaturized)
        }
    }

    private func install() {
        guard item == nil else { return }
        if menu.items.isEmpty { build() }
        // 新加的图标默认排在最左边，菜单栏图标多时会被刘海挡住看不到：第一次放到靠右（离屏幕右边 160 点，时间旁边）；
        // 用户按住 ⌘ 拖过之后，系统按同一个名字记住新位置
        let key = "NSStatusItem Preferred Position EchoStatus"
        if UserDefaults.standard.object(forKey: key) == nil { UserDefaults.standard.set(160, forKey: key) }
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        it.autosaveName = "EchoStatus"
        it.button?.toolTip = "回响"
        it.menu = menu
        item = it
        watch = EchoState.shared.objectWillChange.sink { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { EchoMenuBar.shared.refresh() } }
        }
        refresh()
    }

    private func remove() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        watch = nil
        spin?.invalidate()
        spin = nil
    }

    private func build() {
        menu.delegate = self
        menu.autoenablesItems = false
        status.target = self
        status.action = #selector(fixStatus)
        today.isEnabled = false
        menu.addItem(status)
        menu.addItem(today)
        menu.addItem(.separator())
        let b = EchoAction.item("立即备份", "b") { EchoState.shared.backupNow() }
        backup = b
        menu.addItem(b)
        menu.addItem(EchoAction.item("打开回响", "0") { EchoWindows.showBrowser() })
        let f = EchoAction.item("全局搜索…", "f") { EchoWindows.showSearch() }
        f.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(f)
        recent.submenu = NSMenu()
        menu.addItem(recent)
        menu.addItem(.separator())
        menu.addItem(EchoAction.item("设置…", ",") { EchoWindows.showSettings() })
        menu.addItem(EchoAction.item("检查更新…", "") { EchoUpdate.shared.check(manual: true) })
        menu.addItem(.separator())
        menu.addItem(EchoAction.item("退出回响", "q") { NSApp.terminate(nil) })
    }

    /// 图标和打开着的菜单跟着备份状态变
    private func refresh() {
        guard let b = item?.button else { return }
        let s = EchoState.shared
        if s.running, spin == nil {
            spin = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
                MainActor.assumeIsolated { EchoMenuBar.shared.tick() }
            }
        } else if !s.running, spin != nil {
            spin?.invalidate()
            spin = nil
            phase = 0
        }
        b.image = Self.icon(phase: s.running ? phase : nil, dot: !s.running && s.needsAttention)
        updateStatus()
    }

    private func tick() {
        phase += 1
        item?.button?.image = Self.icon(phase: phase, dot: false)
    }

    private func updateStatus() {
        let s = EchoState.shared
        status.title = Self.statusText(running: s.running, done: s.done, total: s.total, error: s.error,
                                       failures: s.failures.count, staleDays: s.staleDays, cleanupDays: s.cleanupDays, last: s.lastSuccess,
                                       indexing: s.indexing, cloud: s.cloudWaiting.count)
        fix = s.running ? nil : s.error != nil ? .general : s.cleanupDays != nil && s.failures.isEmpty && s.staleDays == nil ? .storage : nil
        status.isEnabled = fix != nil
        status.toolTip = s.error ?? (s.failures.isEmpty ? nil : s.failures.joined(separator: "\n"))
        let n = Self.todayCount(s.sessions)
        today.title = "今天新增 \(n) 个会话"
        today.isHidden = n == 0
        backup?.isEnabled = !s.running
    }

    func menuNeedsUpdate(_ m: NSMenu) {
        let s = EchoState.shared
        // 开机自动启动、当天已备份过时会话列表还没读：先读一次，读完状态行跟着更新
        if s.sessions.isEmpty, !s.scanning { s.reloadSessions() }
        updateStatus()
        let sub = recent.submenu ?? NSMenu()
        sub.removeAllItems()
        for x in Self.recent(s.sessions) {
            let i = NSMenuItem(title: Self.title(x), action: #selector(openRecent(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = x.id
            i.toolTip = x.projectPath
            sub.addItem(i)
        }
        recent.isEnabled = !sub.items.isEmpty
    }

    @objc private func fixStatus() {
        if let fix { EchoWindows.showSettings(fix) }
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        EchoWindows.showBrowser()
        EchoState.shared.openSessionID = id
    }

    // MARK: 文字、挑会话（测试也用）

    /// 状态行：和浏览窗口左下角说的是同一件事，备份失败时写出原因
    /// indexing：备份拷完了在更新索引；cloud：在等 iCloud 下载的文件数（见 EchoCloud）
    nonisolated static func statusText(running: Bool, done: Int, total: Int, error: String?, failures: Int,
                                       staleDays: Int?, cleanupDays: Int?, last: Date?, indexing: Bool = false, cloud: Int = 0) -> String {
        if running, indexing { return "正在更新索引…" }
        if running { return total > 0 ? "正在备份 \(done)/\(total)" : "正在备份…" }
        if let error { return "备份失败：" + (error.count > 40 ? String(error.prefix(40)) + "…" : error) }
        if failures > 0 { return "\(failures) 个文件备份失败" }
        if cloud > 0 { return "正在从 iCloud 下载 \(cloud) 个文件" }
        if let n = staleDays { return "已 \(n) 天未备份" }
        if let n = cleanupDays { return "Claude Code 会删除 \(n) 天前的会话" }
        if let last { return "上次备份：" + EchoTime.short(last) }
        return "尚未备份"
    }

    /// 今天开始的会话有几个（各台电脑的都算）
    nonisolated static func todayCount(_ list: [EchoSession], now: Date = Date()) -> Int {
        list.filter { EchoTime.parse($0.meta.start).map { Calendar.current.isDate($0, inSameDayAs: now) } ?? false }.count
    }

    /// 最近用过的 5 个会话
    nonisolated static func recent(_ list: [EchoSession], limit: Int = 5) -> [EchoSession] {
        Array(list.filter { $0.endDate != nil }.sorted { $0.endDate! > $1.endDate! }.prefix(limit))
    }

    nonisolated static func title(_ s: EchoSession) -> String {
        let t = s.meta.title == s.sessionId ? "未命名会话" : s.meta.title
        return t.count > 36 ? String(t.prefix(36)) + "…" : t
    }

    // MARK: 图标

    /// 回响 logo 的三根竖条，单色（跟着菜单栏浅色、深色变）。phase 有值时正在备份，三根轮流亮；dot 时右下角加个小圆点，表示备份出了问题
    static func icon(phase: Int?, dot: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            // 照 AppIcon.svg：宽 100、高 440/300/170、间距 146，缩到最高 14
            let k: CGFloat = 14 / 440, w = 100 * k
            let bars: [(x: CGFloat, h: CGFloat)] = [(326, 440), (472, 300), (618, 170)]
            let base: [CGFloat] = [1, 0.75, 0.5]
            for (i, b) in bars.enumerated() {
                let a: CGFloat = phase.map { $0 % 3 == i ? 1 : 0.35 } ?? base[i]
                let r = NSRect(x: 2.8 + (b.x - 326) * k, y: 9 - b.h * k / 2, width: w, height: b.h * k)
                NSColor.black.withAlphaComponent(a).setFill()
                NSBezierPath(roundedRect: r, xRadius: w / 2, yRadius: w / 2).fill()
            }
            if dot {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 12.5, y: 0.5, width: 5, height: 5)).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}
