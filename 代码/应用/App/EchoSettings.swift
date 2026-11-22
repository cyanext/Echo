// 设置窗口：通用（电脑名、备份位置、备份频率、开机自动启动）、存储（来源、备份存储）两页。
// 设计稿 设计/存储设置/，规则见 需求文档/版本需求/v0.7.0-会话备份和自动清理.html。首次设置（EchoOnboarding）复用这里的各块。
import AppKit
import ServiceManagement
import SwiftUI

struct EchoSettingsView: View {
    enum Page: String, CaseIterable { case general = "通用", storage = "存储" }
    @State private var page: Page
    init(start: Page = .general) { _page = State(initialValue: start) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                EchoWindowDrag()
                HStack {
                    Text(page.rawValue).font(.system(size: 15, weight: .semibold)).foregroundStyle(EchoColor.fg)
                    Spacer()
                    Picker("", selection: $page) { ForEach(Page.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 132)
                }
                .padding(.leading, 92).padding(.trailing, 20)
            }
            .frame(height: 52)
            .background(EchoSettingsStyle.chrome)
            Rectangle().fill(EchoColor.line).frame(height: 1)
            // 窗口高度跟着这一页的内容走（NSHostingView 按内容定窗口大小）
            Group {
                switch page {
                case .general: EchoGeneralSettings()
                case .storage: EchoStorageSettings()
                }
            }
            .padding(EdgeInsets(top: 24, leading: 32, bottom: 32, trailing: 32))
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 680)
        .background(EchoColor.surface)
        .ignoresSafeArea()
    }
}

enum EchoSettingsStyle {
    /// Claude Code 的官方图标（LobeHub 图标库的 claudecode-color），放在 Web/ 随应用打包
    private static func webImage(_ name: String) -> NSImage? {
        let dir = ProcessInfo.processInfo.environment["ECHO_WEB"].map { URL(fileURLWithPath: $0) } ?? Bundle.main.resourceURL?.appendingPathComponent("Web")
        return dir.flatMap { NSImage(contentsOf: $0.appendingPathComponent(name)) }
    }
    /// 各应用的小图标：圆角方块（Claude 补了白底），目录树会话行、筛选菜单用（设计稿 设计/多应用/）
    nonisolated(unsafe) private static var appIcons: [EchoSource: NSImage] = [:]
    static func appIcon(_ s: EchoSource) -> NSImage? {
        if let i = appIcons[s] { return i }
        let i = webImage("app-\(s.rawValue).svg")
        appIcons[s] = i
        return i
    }
    static let chrome = EchoColor.chrome
    static let subtle = EchoColor.subtle
    static let accentSoft = EchoColor.accentSoft
    /// 占用条和类型行的颜色：保留的几类主色由深到浅，思考、系统记录灰（默认不备份）
    static func color(_ k: EchoStorage.Kind) -> Color {
        switch k {
        case .message: return EchoColor.q4
        case .toolUse: return EchoColor.q3
        case .toolResult: return EchoColor.q2
        case .thinking: return EchoColor.mute
        case .system: return EchoColor.mute2
        }
    }
}

/// 一行：左边名字加小字说明，右边控件
struct EchoSettingRow<Trailing: View>: View {
    let title: String
    var note: String? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 13)).foregroundStyle(EchoColor.fg)
                if let note { Text(note).font(.system(size: 12)).foregroundStyle(EchoColor.fg3) }
            }
            Spacer(minLength: 0)
            trailing
        }
        .frame(minHeight: 40)
    }
}

/// 块标题：左边名字，右边灰字
struct EchoBlockHeader: View {
    let title: String
    var sum: String = ""
    var sub: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(EchoColor.fg)
                Spacer()
                Text(sum).font(.system(size: 13)).foregroundStyle(EchoColor.fg2)
            }
            if let sub { Text(sub).font(.system(size: 12)).foregroundStyle(EchoColor.fg3).lineLimit(1).truncationMode(.middle) }
        }
    }
}

// MARK: - 通用

struct EchoGeneralSettings: View {
    @State private var name = EchoPrefs.computerName
    @State private var root = EchoPrefs.backupRoot.path
    @State private var hours = EchoPrefs.backupHours
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var cliInstalled = EchoCLIInstall.installed
    @State private var cliError: String?
    @ObservedObject private var state = EchoState.shared

    /// ech 装在哪、Agent 怎么用；~/.local/bin 不在 PATH 里时提示
    private var cliNote: String {
        if let cliError { return cliError }
        guard cliInstalled else { return "Agent 可通过 ech 查询以往会话、按时间列出会话和提交" }
        return EchoCLIInstall.inPath ? "已安装 ech 和配套的 skill" : "已安装到 ~/.local/bin/ech，该目录不在 PATH 中，需写完整路径"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("电脑名", hint: "两台电脑用不同的名字，备份各放一个文件夹") {
                TextField(EchoPrefs.defaultComputerName, text: $name).textFieldStyle(.roundedBorder).onSubmit(saveName)
            }
            field("备份位置", hint: "放在 iCloud 同步的文件夹里，两台电脑都能看到全部会话") {
                HStack {
                    Text(root).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                    Button("选择…", action: pick)
                }
            }
            EchoSettingRow(title: "备份频率", note: state.lastSuccess.map { "上次备份：" + EchoTime.short($0) }) {
                Picker("", selection: $hours) { Text("每小时").tag(1); Text("每 6 小时").tag(6); Text("每天").tag(24) }
                    .labelsHidden().frame(width: 112)
                    .onChange(of: hours) { _, h in EchoPrefs.backupHours = h }
            }
            EchoSettingRow(title: "开机自动启动", note: loginError ?? "在后台备份，不弹窗口") {
                Toggle("", isOn: $login).toggleStyle(.switch).labelsHidden().onChange(of: login) { _, on in setLogin(on) }
            }
            EchoSettingRow(title: "命令行工具", note: cliNote) {
                Button(cliInstalled ? "重新安装" : "安装") {
                    do { try EchoCLIInstall.install(); cliError = nil } catch { cliError = error.localizedDescription }
                    cliInstalled = EchoCLIInstall.installed
                }
            }
        }
        .onDisappear(perform: saveName)
    }

    private func field<C: View>(_ label: String, hint: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(EchoColor.fg)
            c()
            Text(hint).font(.system(size: 12)).foregroundStyle(EchoColor.fg3)
        }
    }

    private func saveName() {
        guard name.trimmed != EchoPrefs.computerName else { return }
        EchoPrefs.computerName = name
        name = EchoPrefs.computerName
        EchoState.shared.lastSuccess = nil   // 换了文件夹，要重新备份一次
        EchoState.shared.backupNow()
    }

    private func pick() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.directoryURL = EchoPrefs.backupRoot
        guard p.runModal() == .OK, let u = p.url else { return }
        EchoPrefs.backupRoot = u
        root = u.path
        EchoState.shared.lastSuccess = nil
        EchoState.shared.backupNow()
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            login = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - 存储

@MainActor
final class EchoStorageModel: ObservableObject {
    @Published var backup: EchoStorage.Backup?
    @Published var claude: (sessions: Int, bytes: Int64)?
    @Published var codex: (sessions: Int, bytes: Int64)?
    @Published var codexLoaded = false                 // Codex 统计完了（nil 表示本机没有 Codex 会话）
    @Published var codexAutoDelete: (count: Int, bytes: Int64)?
    @Published var freeable: Int64?
    @Published var autoDelete: (count: Int, bytes: Int64)?
    @Published var cleaning = false
    @Published var claudeCleanupDays = EchoClaudeSettings.cleanupDays()
    @Published var error: String?
    private var estimating: Task<Void, Never>?

    func refresh() {
        let dir = EchoPrefs.computerDir
        Task.detached(priority: .userInitiated) {
            let b = EchoStorage.backup(dir), c = EchoStorage.claude()
            await MainActor.run { self.backup = b; self.claude = c }
            let x = EchoStorage.codex()
            await MainActor.run { self.codex = x; self.codexLoaded = true }
        }
        estimate()
        countAutoDelete()
        claudeCleanupDays = EchoClaudeSettings.cleanupDays()
    }

    /// 按当前保留期限能释放多少：要按规则过一遍备份，几十秒；期限改了重新算
    func estimate() {
        estimating?.cancel()
        freeable = nil
        let dir = EchoPrefs.computerDir, policy = EchoPrefs.policy
        estimating = Task.detached(priority: .utility) {
            let r = try? EchoClean.run(computerDir: dir, policy: policy, dryRun: true)
            if Task.isCancelled { return }
            await MainActor.run { self.freeable = r?.freed ?? 0 }
        }
    }

    func countAutoDelete() {
        autoDelete = nil
        codexAutoDelete = nil
        let dir = EchoPrefs.claudeDir, days = EchoPrefs.autoDeleteDays, cdir = EchoPrefs.codexDir, cdays = EchoPrefs.autoDeleteCodexDays
        Task.detached(priority: .utility) {
            let list = EchoAutoDelete.candidates(source: EchoBackup.source, computerDir: dir, days: days)
            let cx = EchoAutoDelete.codexCandidates(source: EchoBackup.codexSource, dir: cdir, days: cdays)
            await MainActor.run {
                self.autoDelete = (list.count, list.reduce(0) { $0 + $1.bytes })
                self.codexAutoDelete = (cx.count, cx.reduce(0) { $0 + $1.bytes })
            }
        }
    }

    func cleanNow() {
        guard !cleaning else { return }
        cleaning = true
        let dir = EchoPrefs.computerDir, policy = EchoPrefs.policy
        Task.detached(priority: .userInitiated) {
            let r = Result { try EchoClean.run(computerDir: dir, policy: policy) }
            await MainActor.run {
                self.cleaning = false
                switch r {
                case .success(let res):
                    EchoPrefs.lastClean = Date()
                    self.error = res.failures.isEmpty ? nil : "有 \(res.failures.count) 个文件没清理成"
                case .failure(let e): self.error = e.localizedDescription
                }
                self.refresh()
            }
        }
    }

    func turnOffClaudeCleanup() {
        do {
            try EchoClaudeSettings.setCleanupDays(EchoClaudeSettings.off)
            error = nil
        } catch { self.error = error.localizedDescription }
        claudeCleanupDays = EchoClaudeSettings.cleanupDays()
        EchoState.shared.cleanupDays = EchoBackup.cleanupDays()
    }
}

/// 保留期限的选项：-1 永久，0 不备份
private let keepOptions: [(Int, String)] = [(-1, "永久保留"), (90, "保留 90 天"), (30, "保留 30 天"), (7, "保留 7 天"), (0, "不备份")]

struct EchoStorageSettings: View {
    @StateObject private var model = EchoStorageModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            EchoBackupBlock(model: model)
            EchoSourcesBlock(model: model)
        }
        .onAppear { model.refresh() }
    }
}

/// 来源：一个应用一张卡片（Claude Code、Codex，WorkBuddy 暂无本地会话、灰着），应用自己的清理选项接在卡片里
struct EchoSourcesBlock: View {
    @ObservedObject var model: EchoStorageModel
    @AppStorage("backupClaude") private var on = true
    @AppStorage("autoDelete") private var autoDelete = true
    @AppStorage("autoDeleteDays") private var days = 30
    @AppStorage("backupCodex") private var codexOn = true
    @AppStorage("autoDeleteCodex") private var codexAutoDelete = true
    @AppStorage("autoDeleteCodexDays") private var codexDays = 30
    /// 首次设置里：只画卡片头（第 3 步）或带清理选项（第 4 步），Claude 的自动清理用开关，点「完成」时才改
    var onboarding = false
    var showCleanup = true
    var closeClaude: Binding<Bool>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !onboarding { EchoBlockHeader(title: "来源", sum: "勾选要备份的应用") }
            EchoSourceCard(app: .claude, name: "Claude Code", meta: meta(model.claude, .claude), on: $on) {
                if showCleanup { cleanup }
            }
            if model.codexLoaded && model.codex == nil {
                EchoSourceCard(app: .codex, name: "Codex", meta: "暂无本地会话", on: .constant(false), enabled: false) {}
            } else {
                EchoSourceCard(app: .codex, name: "Codex", meta: meta(model.codex, .codex), on: $codexOn) {
                    if showCleanup { codexCleanup }
                }
            }
            EchoSourceCard(app: .workbuddy, name: "WorkBuddy", meta: "暂无本地会话", on: .constant(false), enabled: false) {}
        }
    }

    private func meta(_ c: (sessions: Int, bytes: Int64)?, _ app: EchoSource) -> String {
        guard let c else { return "正在统计…" }
        let msgs = model.backup.map { "\(($0.messagesBy[app] ?? 0).formatted()) 条消息 · " } ?? ""
        return "\(c.sessions) 个会话 · \(msgs)\(EchoStorage.size(c.bytes))"
    }

    /// 自动清理的开关、期限、会清理几个：Claude、Codex 共用一个样子（「清理」不写「删除」）
    @ViewBuilder private func autoClean(_ on: Binding<Bool>, _ days: Binding<Int>, _ count: (count: Int, bytes: Int64)?) -> some View {
        EchoSettingRow(title: "自动清理非活跃会话", note: "仅清理已完整备份的会话，移到废纸篓；正在使用的会话不受影响") {
            Toggle("", isOn: on).toggleStyle(.switch).labelsHidden()
        }
        EchoSettingRow(title: "非活跃期限") {
            Picker("", selection: days) { ForEach([30, 60, 90, 180], id: \.self) { Text("\($0) 天").tag($0) } }
                .labelsHidden().frame(width: 112)
                .onChange(of: days.wrappedValue) { _, _ in model.countAutoDelete() }
        }
        .disabled(!on.wrappedValue)
        Group {
            if let a = count {
                (Text("按当前设置将清理 ") + Text("\(a.count) 个会话").fontWeight(.semibold) + Text("，释放 \(EchoStorage.size(a.bytes))"))
            } else { Text("正在统计…") }
        }
        .font(.system(size: 12)).foregroundStyle(EchoColor.fg2).padding(.vertical, 4)
        .opacity(on.wrappedValue ? 1 : 0.4)
    }

    /// Codex 自己不删会话，一直攒着：只有回响的自动清理
    @ViewBuilder private var codexCleanup: some View {
        VStack(alignment: .leading, spacing: 0) { autoClean($codexAutoDelete, $codexDays, model.codexAutoDelete) }
    }

    @ViewBuilder private var cleanup: some View {
        VStack(alignment: .leading, spacing: 0) {
            autoClean($autoDelete, $days, model.autoDelete)
            claudeCleanup.padding(.top, 8)
        }
    }

    /// Claude 自己的清理：比回响的期限长算已关闭；不比它长就提示并给按钮
    @ViewBuilder private var claudeCleanup: some View {
        if model.claudeCleanupDays > days {
            if !onboarding {
                EchoSettingRow(title: "Claude 自动清理", note: "cleanupPeriodDays：\(model.claudeCleanupDays) 天") {
                    Text("已关闭").font(.system(size: 13)).foregroundStyle(EchoColor.fg3)
                }
            }
        } else if let closeClaude {
            EchoSettingRow(title: "关闭 Claude 的自动清理（推荐）", note: "Claude 会直接删除 \(model.claudeCleanupDays) 天未使用的会话，不确认是否已备份") {
                Toggle("", isOn: closeClaude).toggleStyle(.switch).labelsHidden()
            }
        } else {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("建议关闭 Claude 的自动清理").font(.system(size: 13)).foregroundStyle(EchoColor.fg)
                    Text("Claude 会直接删除 \(model.claudeCleanupDays) 天未使用的会话，不确认是否已备份").font(.system(size: 12)).foregroundStyle(EchoColor.fg2)
                    Text("关闭后由回响清理：确认备份完整后再移到废纸篓").font(.system(size: 12)).foregroundStyle(EchoColor.fg2)
                }
                Spacer(minLength: 0)
                Button("关闭自动清理") { model.turnOffClaudeCleanup() }
            }
            .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            .background(EchoSettingsStyle.accentSoft, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// 来源卡片：图标、名字、会话数等、勾选；下面接这个应用自己的选项。以后加 Codex 等只多一张卡
struct EchoSourceCard<Content: View>: View {
    let app: EchoSource
    let name: String
    let meta: String
    @Binding var on: Bool
    var enabled = true
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                // 官方 logo 直接画成 32 的圆角方块，不套白框、不画线框
                Group { if let i = EchoSettingsStyle.appIcon(app) { EchoAppLogo(app: app, image: i, size: 32) } }
                    .frame(width: 32, height: 32)
                    .saturation(enabled ? 1 : 0).opacity(enabled ? 1 : 0.45)
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(enabled ? EchoColor.fg : EchoColor.fg3)
                    Text(meta).font(.system(size: 12)).foregroundStyle(enabled ? EchoColor.fg2 : EchoColor.fg3)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: $on).toggleStyle(.checkbox).labelsHidden().disabled(!enabled)
            }
            if on { content.padding(.leading, 44) }
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        .background(EchoSettingsStyle.subtle, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 备份存储：占用条、图例、各类的保留期限、能释放多少和「立即清理」
struct EchoBackupBlock: View {
    @ObservedObject var model: EchoStorageModel
    @State private var keep: [EchoStorage.Kind: Int] = [.toolUse: EchoPrefs.keepToolUse, .toolResult: EchoPrefs.keepToolResult,
                                                        .thinking: EchoPrefs.keepThinking, .system: EchoPrefs.keepSystem]
    var onboarding = false
    /// 期限改了以后（首次设置里重新估算首次备份多大）
    var onChange: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !onboarding {
                EchoBlockHeader(title: "备份存储", sum: model.backup.map { "共 " + EchoStorage.size($0.total) } ?? "",
                                sub: "\(EchoPrefs.computerName) · \(EchoPrefs.backupRoot.lastPathComponent)")
                bar.padding(.top, 12)
                legend.padding(.top, 8)
            }
            HStack {
                Text("类型"); Spacer(); Text("保留期限").frame(width: 112, alignment: .leading)
            }
            .font(.system(size: 12)).foregroundStyle(EchoColor.fg3).padding(.top, onboarding ? 0 : 16)
            ForEach(EchoStorage.Kind.allCases) { k in row(k) }
            if !onboarding { cleanBox.padding(.top, 12) }
        }
    }

    private var bar: some View {
        GeometryReader { g in
            let b = model.backup, total = max(1, Double(b?.total ?? 0))
            HStack(spacing: 2) {
                ForEach(EchoStorage.Kind.allCases) { k in
                    let v = Double(b?.bytes[k] ?? 0)
                    if v > 0 { Rectangle().fill(EchoSettingsStyle.color(k)).frame(width: max(2, (g.size.width - 8) * v / total)) }
                }
                if b == nil { Rectangle().fill(EchoSettingsStyle.subtle) }
            }
        }
        .frame(height: 12)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(EchoStorage.Kind.allCases) { k in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(EchoSettingsStyle.color(k)).frame(width: 8, height: 8)
                    Text(k.rawValue).foregroundStyle(EchoColor.fg)
                    Text(model.backup.map { EchoStorage.size($0.bytes[k] ?? 0) } ?? "…").foregroundStyle(EchoColor.fg2)
                }
                .fixedSize()
            }
        }
        .font(.system(size: 12))
    }

    private func note(_ k: EchoStorage.Kind) -> String? {
        switch k {
        case .message: return "用户消息与 AI 回复正文"
        case .toolUse: return "始终保留 Git 提交与合并命令"
        case .thinking: return "浏览时读取原会话"
        case .system: return "保留标题、重命名、压缩摘要与用量"
        case .toolResult: return nil
        }
    }

    private func row(_ k: EchoStorage.Kind) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(EchoSettingsStyle.color(k)).frame(width: 8, height: 8)
            EchoSettingRow(title: k.rawValue, note: note(k)) {
                if k == .message {
                    Text("永久保留").font(.system(size: 13)).foregroundStyle(EchoColor.fg2).frame(width: 112, alignment: .leading)
                } else {
                    Picker("", selection: Binding(get: { keep[k] ?? 0 }, set: { set(k, $0) })) {
                        ForEach(keepOptions, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .labelsHidden().frame(width: 112)
                }
            }
        }
    }

    private func set(_ k: EchoStorage.Kind, _ v: Int) {
        keep[k] = v
        switch k {
        case .toolUse: EchoPrefs.keepToolUse = v
        case .toolResult: EchoPrefs.keepToolResult = v
        case .thinking: EchoPrefs.keepThinking = v
        case .system: EchoPrefs.keepSystem = v
        case .message: break
        }
        model.estimate()
        onChange?()
    }

    private var cleanBox: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Group {
                    if model.cleaning { Text("正在清理…") }
                    else if let f = model.freeable, f > 0 { Text("按当前设置可释放 ") + Text("约 " + EchoStorage.size(f)).fontWeight(.semibold) }
                    else if model.freeable != nil { Text("暂无可清理的内容") }
                    else { Text("正在计算能释放多少…") }
                }
                .font(.system(size: 13)).foregroundStyle(EchoColor.fg)
                Text(model.error ?? ("每日自动清理 · 上次清理：" + (EchoPrefs.lastClean.map { EchoTime.short($0) } ?? "还没有")))
                    .font(.system(size: 12)).foregroundStyle(model.error == nil ? EchoColor.fg3 : EchoColor.warn)
            }
            Spacer(minLength: 0)
            Button("立即清理") { model.cleanNow() }
                .buttonStyle(.borderedProminent).tint(EchoColor.accent)
                .disabled(model.cleaning || (model.freeable ?? 0) == 0)
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        .background(EchoSettingsStyle.subtle, in: RoundedRectangle(cornerRadius: 8))
    }
}
