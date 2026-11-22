// 首次设置：第一次打开回响（没完成过引导、本机也还没有备份记录）时出现，四步：欢迎、备份放在哪、备份什么、怎么清理。
// 设计稿 设计/首次设置/。第 2～4 步直接用设置窗口的各块（EchoSettings），改的就是设置。点「完成，开始备份」后才开始备份。
import AppKit
import SwiftUI

enum EchoOnboarding {
    private static var window: NSWindow?
    /// 引导还开着：点程序坞图标时把它提到前面，不开浏览窗口
    static func bringFront() -> Bool {
        guard let window else { return false }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// 已经有备份记录的（老用户）直接算完成过
    static var needed: Bool {
        let d = UserDefaults.standard
        if d.bool(forKey: "onboarded") { return false }
        let dir = EchoPrefs.computerDir   // 备份记录在 claude/ 里，还没挪的在电脑这一级
        if [EchoPrefs.claudeDir, dir].contains(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("备份记录.json").path) }) {
            d.set(true, forKey: "onboarded")
            return false
        }
        return true
    }

    static func show(done: @escaping () -> Void) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 720),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: EchoOnboardingView {
            UserDefaults.standard.set(true, forKey: "onboarded")
            window?.close()
            window = nil
            done()
        })
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// 第 2 步点「继续」：先读一次 ~/.claude、~/.codex，写一次备份文件夹，让系统的授权弹窗在这一步弹完
    static func askAccess() {
        _ = try? FileManager.default.contentsOfDirectory(atPath: EchoBackup.source.path)
        _ = try? FileManager.default.contentsOfDirectory(atPath: EchoBackup.codexSource.appendingPathComponent("sessions").path)
        let dir = EchoPrefs.computerDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let probe = dir.appendingPathComponent("回响-写入测试.tmp")
        try? Data().write(to: probe)
        try? FileManager.default.removeItem(at: probe)
    }

    /// 首次备份大约多大：按当前保留期限把勾选的应用的会话过一遍（只算不写），图片等不备份的文件不算
    static func estimate(policy: EchoPolicy) -> Int64 {
        let codex = EchoPrefs.backupCodex && EchoPrefs.hasCodex
            ? EchoParallel.map(EchoBackup.codexItems(EchoBackup.codexSource)) { it -> Int64 in
                it.action == .copy ? it.stamp.size : Int64((try? EchoSlim.slimFile(it.url, to: nil, policy: policy).bytesOut) ?? 0)
            }.reduce(0, +) : 0
        return codex + (EchoPrefs.backupClaude ? claudeEstimate(policy: policy) : 0)
    }

    private static func claudeEstimate(policy: EchoPolicy) -> Int64 {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: EchoBackup.source, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
        let base = EchoBackup.source.standardizedFileURL.path + "/"
        let files = en.compactMap { $0 as? URL }
        // 多个文件同时算
        return EchoParallel.map(files) { u -> Int64 in
            guard let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true else { return 0 }
            switch EchoBackupRule.action(for: String(u.standardizedFileURL.path.dropFirst(base.count))) {
            case .slim: return Int64((try? EchoSlim.slimFile(u, to: nil, policy: policy).bytesOut) ?? 0)
            case .copy: return Int64(v.fileSize ?? 0)
            case .skip: return 0
            }
        }.reduce(0, +)
    }
}

struct EchoOnboardingView: View {
    let done: () -> Void
    @State var step: Int
    @StateObject private var model = EchoStorageModel()
    @AppStorage("backupClaude") private var backupClaude = true
    @AppStorage("backupCodex") private var backupCodex = true
    @State private var closeClaude = true
    @State private var firstBackup: Int64?

    init(start: Int = 0, done: @escaping () -> Void) {
        self.done = done
        _step = State(initialValue: start)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: page("备份放在哪", "以后可以在「设置 → 通用」里改。") {
                    VStack(alignment: .leading, spacing: 24) {
                        EchoGeneralSettings()
                        note("点「继续」后，macOS 会询问能否访问会话和备份文件夹", "请点「允许」，否则回响读不到会话")
                    }
                }
                case 2: page("备份什么", "勾选要备份的应用，各类内容按下面的期限备份。") {
                    VStack(alignment: .leading, spacing: 16) {
                        EchoSourcesBlock(model: model, onboarding: true, showCleanup: false)
                            .onChange(of: backupClaude) { _, _ in estimateFirst() }
                            .onChange(of: backupCodex) { _, _ in estimateFirst() }
                        EchoBackupBlock(model: model, onboarding: true, onChange: { estimateFirst() })
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                if let f = firstBackup { Text("首次备份约 ") + Text(EchoStorage.size(f)).fontWeight(.semibold) }
                                else { Text("正在估算首次备份大小…") }
                                Text("完成后开始备份，进度显示在左栏底部").font(.system(size: 12)).foregroundStyle(EchoColor.fg3)
                            }
                            .font(.system(size: 13)).foregroundStyle(EchoColor.fg)
                            Spacer()
                        }
                        .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                        .background(EchoSettingsStyle.subtle, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                default: page("怎么清理", "以后可以在「设置 → 存储」里改。") {
                    EchoSourcesBlock(model: model, onboarding: true, closeClaude: $closeClaude)
                }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            footer
        }
        .frame(width: 680, height: 720)
        .background(EchoColor.surface)
        .ignoresSafeArea()
        .onAppear { model.refresh(); estimateFirst() }
    }

    private func estimateFirst() {
        firstBackup = nil
        let policy = EchoPrefs.policy
        Task.detached(priority: .utility) {
            let n = EchoOnboarding.estimate(policy: policy)
            await MainActor.run { firstBackup = n }
        }
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 104, height: 104)
            Text("帮你记住和 AI 的每次对话").font(.system(size: 24, weight: .semibold)).foregroundStyle(EchoColor.fg).padding(.top, 16)
            // 副标语：去掉全角逗号（占一整个字宽，读着像断开），两半之间空半个字；字距收到 1，「回响」只换颜色、字重中等，不和主标语抢
            (Text("念念不忘 必有") + Text("回响").fontWeight(.medium).foregroundColor(EchoColor.accent))
                .font(.system(size: 17)).tracking(1).foregroundStyle(EchoColor.fg2).padding(.top, 8)
            VStack(alignment: .leading, spacing: 12) {
                feat("checkmark.icloud", "备份", "Claude Code、Codex 的会话自动备份，换台电脑也看得到")
                // 精简：本机实测 Claude 7.9 GB 备份后 846 MB，Codex 3.6 GB 约 240 MB（11-22）
                feat("rectangle.compress.vertical", "精简", "图片和过程数据按期限清理，备份只有原会话的十分之一，密钥自动打码")
                feat("clock.arrow.circlepath", "回看", "按目录找会话，按版本、压缩点跳到当时做了什么")
                feat("chart.bar", "总览", "每周用了多少 Token、做了哪些提交")
            }
            .padding(.top, 32)
        }
        .padding(.top, 72)
    }

    private func feat(_ icon: String, _ name: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(EchoColor.accent)
                .frame(width: 36, height: 36).background(EchoSettingsStyle.accentSoft, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(EchoColor.fg)
                Text(text).font(.system(size: 12)).foregroundStyle(EchoColor.fg2)
            }
        }
    }

    private func page<C: View>(_ title: String, _ desc: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(EchoColor.fg)
            Text(desc).font(.system(size: 13)).foregroundStyle(EchoColor.fg2).padding(.top, 4).padding(.bottom, 20)
            c()
        }
        .padding(EdgeInsets(top: 52, leading: 32, bottom: 0, trailing: 32))
    }

    private func note(_ a: String, _ b: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(a).font(.system(size: 13)).foregroundStyle(EchoColor.fg)
            Text(b).font(.system(size: 12)).foregroundStyle(EchoColor.fg2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        .background(EchoSettingsStyle.accentSoft, in: RoundedRectangle(cornerRadius: 8))
    }

    /// 底部：左边步骤点（不能继续时换成原因），右边上一步、继续
    private var footer: some View {
        HStack {
            if step == 2 && !backupClaude && !backupCodex {
                Text("至少勾选一个应用").font(.system(size: 12)).foregroundStyle(EchoColor.fg2)
            } else {
                HStack(spacing: 8) {
                    ForEach(0..<4) { i in
                        Capsule().fill(i == step ? EchoColor.accent : EchoColor.line).frame(width: i == step ? 18 : 6, height: 6)
                    }
                }
            }
            Spacer()
            if step > 0 { Button("上一步") { step -= 1 }.controlSize(.large) }
            Button(step == 0 ? "开始设置" : step == 3 ? "完成，开始备份" : "继续") { next() }
                .buttonStyle(.borderedProminent).tint(EchoColor.accent).controlSize(.large)
                .disabled(step == 2 && !backupClaude && !backupCodex)
        }
        .padding(.horizontal, 32)
        .frame(height: 72)
    }

    private func next() {
        if step == 1 { EchoOnboarding.askAccess() }
        if step < 3 { step += 1; return }
        if closeClaude, EchoClaudeSettings.cleanupDays() <= EchoPrefs.autoDeleteDays {
            try? EchoClaudeSettings.setCleanupDays(EchoClaudeSettings.off)
        }
        done()
    }
}
