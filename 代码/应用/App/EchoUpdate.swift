// 检查更新（照 PicBox 的 Updater）：启动 5 秒后查一次，之后每 24 小时一次，读 GitHub 上最新的发版，只发一个 GET，不带本机信息。
// 有新版弹提示：更新、稍后、跳过这个版本。点更新：下载安装包、解压，核对包标识和签名，退出后用脚本换掉程序包再打开。
// 设置里关掉「自动检查更新」后只在手动点「检查更新」时查。测试时 ECHO_UPDATE_URL 指向本地的发版信息（file://）。
import AppKit
import Security

@MainActor
final class EchoUpdate: NSObject {
    static let shared = EchoUpdate()
    static let repo = "cyanext/echo"
    static var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases")! }
    private static let skipKey = "updateSkipVersion"   // 用户点了「跳过这个版本」的版本号

    private var busy = false          // 正在检查、下载或提示框开着，不重复开始
    private var open: [NSAlert] = []  // 正在显示的提示框，显示期间要留着
    private var handlers: [ObjectIdentifier: (Int) -> Void] = [:]
    private var timer: Timer?

    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// 发版标签 app-v0.13.0 → 0.13.0
    nonisolated static func version(fromTag tag: String) -> String {
        var t = Substring(tag)
        if t.hasPrefix("app-") { t = t.dropFirst(4) }
        if t.hasPrefix("v") || t.hasPrefix("V") { t = t.dropFirst() }
        return String(t)
    }

    /// 按点分的数字逐段比，0.13.0 比 0.9.1 新
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    func start() {
        guard Bundle.main.bundlePath.hasSuffix(".app"), timer == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if EchoPrefs.autoUpdate { self.check(manual: false) } }
        let t = Timer(timeInterval: 24 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { if EchoPrefs.autoUpdate { self.check(manual: false) } }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// manual：用户手动点的，没新版、出错都要告诉他，也不管「跳过这个版本」
    func check(manual: Bool) {
        guard !busy else { return }
        busy = true
        let env = ProcessInfo.processInfo.environment["ECHO_UPDATE_URL"]
        var req = URLRequest(url: env.flatMap(URL.init(string:)) ?? URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Echo", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let rel = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async {
                self.busy = false
                self.handle(rel, manual: manual)
            }
        }.resume()
    }

    private func handle(_ rel: [String: Any]?, manual: Bool) {
        guard let tag = rel?["tag_name"] as? String else {
            if manual { alert("检查更新失败", "无法连接 GitHub，请稍后再试。") }
            return
        }
        let ver = Self.version(fromTag: tag)
        guard Self.isNewer(ver, than: Self.current) else {
            if manual { alert("已是最新版本", "回响 v\(Self.current)") }
            return
        }
        let d = UserDefaults.standard
        if !manual && d.string(forKey: Self.skipKey) == ver { return }
        let assets = rel?["assets"] as? [[String: Any]] ?? []
        guard let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true })?["browser_download_url"] as? String,
              let url = URL(string: zip) else {
            if manual { alert("新版本暂无安装包", "请稍后再试。") }
            return
        }
        var notes = rel?["body"] as? String ?? ""
        if notes.count > 600 { notes = String(notes.prefix(600)) + "…" }
        busy = true
        show("回响有新版本 v\(ver)", "当前版本 v\(Self.current)。\n\n\(notes)", ["更新", "稍后", "跳过这个版本"]) { i in
            self.busy = false
            if i == 2 { d.set(ver, forKey: Self.skipKey) } else if i == 0 { self.download(url) }
        }
    }

    /// 下载、解压，核对解出来的程序和本程序是同一个（包标识、签名），再装
    private func download(_ url: URL) {
        busy = true
        URLSession.shared.downloadTask(with: url) { file, _, err in
            var app: URL?
            var reason = "安装包下载或解压失败，请稍后再试。"
            if let file, err == nil {
                let fm = FileManager.default
                let dir = fm.temporaryDirectory.appendingPathComponent("回响更新-" + UUID().uuidString)
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let zip = dir.appendingPathComponent("update.zip")
                try? fm.moveItem(at: file, to: zip)
                let t = Process()
                t.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                t.arguments = ["-x", "-k", zip.path, dir.path]
                try? t.run(); t.waitUntilExit()
                let found = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
                    .first { $0.pathExtension == "app" && Bundle(url: $0)?.bundleIdentifier == Bundle.main.bundleIdentifier }
                if let found {
                    if Self.sameSigner(found) { app = found } else { reason = "安装包的签名与当前版本不一致，未安装。请到 GitHub 下载新版本。" }
                }
            }
            DispatchQueue.main.async {
                self.busy = false
                guard let app else { self.alert("更新失败", reason); return }
                self.install(app)
            }
        }.resume()
    }

    /// 新包要满足当前程序的签名要求（同一个包标识、同一张证书）。自己编译的临时签名没有证书可比，只核对包标识
    nonisolated static func sameSigner(_ new: URL) -> Bool {
        var me: SecCode?, mine: SecStaticCode?, req: SecRequirement?, other: SecStaticCode?, info: CFDictionary?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine else { return false }
        SecCodeCopySigningInformation(mine, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let flags = (info as? [String: Any])?[kSecCodeInfoFlags as String] as? UInt32 ?? 0
        if flags & SecCodeSignatureFlags.adhoc.rawValue != 0 { return true }
        guard SecCodeCopyDesignatedRequirement(mine, [], &req) == errSecSuccess, let req,
              SecStaticCodeCreateWithPath(new as CFURL, [], &other) == errSecSuccess, let other else { return false }
        return SecStaticCodeCheckValidity(other, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), req) == errSecSuccess
    }

    /// 退出回响，等它退干净后用一段脚本换程序包：旧的先挪开，新的拷进去，失败就换回旧的；最后重新打开
    private func install(_ app: URL) {
        let dest = Bundle.main.bundlePath
        guard FileManager.default.isWritableFile(atPath: (dest as NSString).deletingLastPathComponent) else {
            show("无法自动更新", "没有权限替换 \(dest)，请到 GitHub 下载新版本。", ["打开下载页", "取消"]) { i in
                if i == 0 { NSWorkspace.shared.open(Self.releasesPage) }
            }
            return
        }
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "$DEST.old"
        if mv "$DEST" "$DEST.old" && /usr/bin/ditto "$NEW" "$DEST"; then rm -rf "$DEST.old"; else rm -rf "$DEST"; mv "$DEST.old" "$DEST"; fi
        /usr/bin/xattr -cr "$DEST"
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
        open "$DEST"
        """
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/bin/sh")
        t.arguments = ["-c", "nohup /bin/sh -c '\(script.replacingOccurrences(of: "'", with: "'\\''"))' >/dev/null 2>&1 &"]
        t.environment = ["DEST": dest, "NEW": app.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        do { try t.run(); t.waitUntilExit() } catch { alert("更新失败", error.localizedDescription); return }
        NSApp.terminate(nil)
    }

    private func alert(_ title: String, _ text: String) { show(title, text, []) { _ in } }

    /// 提示框不用 runModal：模态时定时备份停下；改成浮在最上层、不卡程序的窗口，点按钮后回调第几个按钮（从 0 开始）
    private func show(_ title: String, _ text: String, _ buttons: [String], done: @escaping (Int) -> Void) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        for b in buttons.isEmpty ? ["好"] : buttons { a.addButton(withTitle: b) }
        for (i, b) in a.buttons.enumerated() { b.tag = i; b.target = self; b.action = #selector(pressed(_:)) }
        a.layout()
        let w = a.window
        w.level = .floating
        w.center()
        open.append(a)
        handlers[ObjectIdentifier(w)] = done
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    @objc private func pressed(_ b: NSButton) {
        guard let w = b.window else { return }
        let done = handlers.removeValue(forKey: ObjectIdentifier(w))
        w.orderOut(nil)
        open.removeAll { $0.window == w }
        done?(b.tag)
    }
}
