// 浏览窗口：左栏按目录二级分类的会话（大目录 > 项目 > 会话），右栏对话（WKWebView 加载 Web/ 里的页面）。
// 照设计稿 设计/浏览窗口/：外框照伙伴云NAS应用（图标栏灰底、白色内容区、靛蓝强调色），列表不用系统 List。
import AppKit
import SwiftUI
import WebKit

/// 颜色照伙伴云NAS应用的 RailColor，和设计稿 设计/浏览窗口/设计稿.css 一致
enum EchoColor {
    static func dyn(_ light: UInt32, _ dark: UInt32, _ la: CGFloat = 1, _ da: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            let isDark = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let v = isDark ? dark : light
            return NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: isDark ? da : la)
        })
    }
    static let side = dyn(0xecedf3, 0x232428)
    static let sideOn = dyn(0xffffff, 0x34353b)
    static let sideFg = dyn(0x4b5468, 0xb4b9c5)
    static let sideLine = dyn(0xe3e5ec, 0x2f3036)
    static let surface = dyn(0xffffff, 0x1d1e23)
    static let fg = dyn(0x1f2329, 0xe6e8ec)
    static let fg2 = dyn(0x646a73, 0x9aa0ab)
    static let fg3 = dyn(0x8f959e, 0x6f7581)
    static let line = dyn(0xe3e5ec, 0x2c2e35)
    static let accent = dyn(0x4e5bd8, 0x7c87f0)
    static let sel = dyn(0x4e5bd8, 0x7c87f0, 0.10, 0.16)
    static let hover = dyn(0x1f2329, 0xffffff, 0.05, 0.06)
    static let good = dyn(0x12a150, 0x3ccf7e)
    static let warn = dyn(0xe08a00, 0xf0a63a)
}

struct EchoBrowserView: View {
    @EnvironmentObject var state: EchoState
    @AppStorage("filterComputer") private var computer = ""           // 空表示全部电脑
    @AppStorage("dirState") private var dirStateRaw = ""               // 用户点过的目录：一行「路径\t1」展开、「路径\t0」收起
    @State private var sessionID: String?
    @State private var collectionID: String?
    @State private var picked: Set<String> = []                        // ⌘ 点选的会话，用来连起来看
    @State private var renaming: EchoTarget?
    @State private var newTitle = ""
    @State private var editError: String?
    @State private var deleting: [EchoSession] = []
    @State private var tree: [EchoDir] = []                            // 会话列表变了才重新分组，不在每次刷新时算
    @State private var showAll: Set<String> = []                       // 点过「再显示」的项目

    private var computers: [String] { Array(Set(state.sessions.map(\.computer))).sorted() }
    private var dirState: [String: Bool] {
        Dictionary(dirStateRaw.split(separator: "\n").compactMap { l -> (String, Bool)? in
            let f = l.split(separator: "\t"); return f.count == 2 ? (String(f[0]), f[1] == "1") : nil
        }, uniquingKeysWith: { _, b in b })
    }
    /// 没选过会话时打开最近的一个，右栏不空着
    private var session: EchoSession? {
        tree.lazy.flatMap(\.all).first { $0.id == sessionID } ?? tree.lazy.flatMap(\.all).max { ($0.endDate ?? .distantPast) < ($1.endDate ?? .distantPast) }
    }
    private var target: EchoTarget? {
        if let id = collectionID, let c = state.collections.first(where: { $0.id == id }) {
            return .collection(c, EchoCollections.sessions(c, in: state.sessions, root: EchoPrefs.backupRoot))
        }
        return session.map { .session($0) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 272)
                .background(EchoColor.side)
                .overlay(alignment: .trailing) { Rectangle().fill(EchoColor.sideLine).frame(width: 1) }
            ZStack {
                if let t = target { EchoConversation(target: t) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(EchoColor.surface)
        .foregroundStyle(EchoColor.fg)
        .ignoresSafeArea()
        .frame(minWidth: 860, minHeight: 560)
        .onAppear(perform: regroup)
        .onChange(of: state.sessions) { _, _ in regroup() }
        .onChange(of: computer) { _, _ in regroup() }
        .alert("改名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名字", text: $newTitle)
            Button("取消", role: .cancel) {}
            Button("改名", action: commitRename)
        } message: {
            if case .session(let s) = renaming, let u = EchoRename.originalURL(for: s), EchoRename.isActive(u) {
                Text("会话正在进行，Claude Code 可能把名字改回去，在会话里用 /rename 更稳")
            }
        }
        .alert(deleting.count > 1 ? "把 \(deleting.count) 个会话移到废纸篓？" : "把这个会话移到废纸篓？",
               isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } })) {
            Button("取消", role: .cancel) {}
            Button("移到废纸篓", role: .destructive, action: commitDelete)
        } message: {
            Text("Claude Code 里的原会话和回响的备份一起移走")
        }
        .alert("没改成", isPresented: Binding(get: { editError != nil }, set: { if !$0 { editError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(editError ?? "")
        }
    }

    private func startRename(_ t: EchoTarget) {
        newTitle = t.title
        renaming = t
    }

    private func commitRename() {
        guard let t = renaming else { return }
        renaming = nil
        do {
            switch t {
            case .session(let s): try state.rename(s, to: newTitle)
            case .collection(let c, _):
                guard !newTitle.trimmed.isEmpty else { return }
                try state.saveCollections(state.collections.map { $0.id == c.id ? EchoCollection(id: c.id, title: newTitle.trimmed, members: c.members, created: c.created) : $0 })
            }
        } catch { editError = error.localizedDescription }
    }

    private func commitDelete() {
        let list = deleting
        deleting = []
        picked = []
        if list.contains(where: { $0.id == sessionID }) { sessionID = nil }
        do { try state.delete(list) } catch { editError = error.localizedDescription }
    }

    private func link(_ list: [EchoSession]) {
        do {
            let c = try state.addCollection(list)
            picked = []
            collectionID = c.id
        } catch { editError = error.localizedDescription }
    }

    private func unlink(_ c: EchoCollection) {
        do {
            try state.saveCollections(state.collections.filter { $0.id != c.id })
            if collectionID == c.id { collectionID = nil }
        } catch { editError = error.localizedDescription }
    }

    /// 右键菜单：选了几个时连起来看，单个时改名
    @ViewBuilder
    private func sessionMenu(_ s: EchoSession) -> some View {
        let group = picked.contains(s.id) && picked.count > 1
            ? state.sessions.filter { picked.contains($0.id) } : []
        if group.count > 1 {
            Button("把 \(group.count) 个会话连起来看") { link(group) }
        }
        Button(EchoRename.originalURL(for: s) == nil ? "改名…（会话在 \(s.computer) 上）" : "改名…") { startRename(.session(s)) }
            .disabled(EchoRename.originalURL(for: s) == nil)
        Divider()
        if group.count > 1 {
            Button("把 \(group.count) 个会话移到废纸篓…") { deleting = group }
        } else {
            Button(EchoDelete.paths(for: s) == nil ? "移到废纸篓…（会话在 \(s.computer) 上）" : "移到废纸篓…") { deleting = [s] }
                .disabled(EchoDelete.paths(for: s) == nil)
        }
        if group.count < 2 {
            Divider()
            Text("⌘ 点选几个会话，可以连起来看或一起删")
        }
    }

    // MARK: 合集

    @ViewBuilder
    private var collectionSection: some View {
        let list = state.collections.sorted { $0.created > $1.created }
        if !list.isEmpty {
            HStack(spacing: 8) {
                EchoIcon(kind: .stack).foregroundStyle(EchoColor.fg2)
                Text("合集").font(.system(size: 13, weight: .semibold)).foregroundStyle(EchoColor.fg)
            }
            .padding(.horizontal, 10).frame(height: 30)
            ForEach(list) { c in
                let members = EchoCollections.sessions(c, in: state.sessions, root: EchoPrefs.backupRoot)
                let on = c.id == collectionID
                EchoRow(fill: on ? EchoColor.sideOn : nil, shadow: on) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.title).font(.system(size: 13, weight: on ? .semibold : .regular)).lineLimit(1)
                            .foregroundStyle(EchoColor.fg)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 6) {
                            Text("\(members.count) 个会话")
                            Spacer(minLength: 4)
                            Text(EchoTime.short(members.compactMap(\.endDate).max()))
                        }
                        .font(.system(size: 12)).foregroundStyle(EchoColor.fg3).monospacedDigit()
                    }
                    .padding(.leading, 24).padding(.vertical, 5)
                } action: {
                    collectionID = c.id
                    picked = []
                }
                .contextMenu {
                    Button("改名…") { startRename(.collection(c, members)) }
                    Button("拆开") { unlink(c) }
                }
            }
        }
    }

    private func regroup() {
        tree = EchoLibrary.dirTree(computer.isEmpty ? state.sessions : state.sessions.filter { $0.computer == computer })
    }

    /// 目录展开收起：点过的按点的来；没点过的，顶层默认展开，当前会话所在的那几级也展开
    private func isOpen(_ d: EchoDir, level: Int) -> Bool {
        if let v = dirState[d.path] { return v }
        return level == 0 || (collectionID == nil && d.contains(session?.id))
    }

    private func toggle(_ d: EchoDir, level: Int) {
        var st = dirState
        st[d.path] = !isOpen(d, level: level)
        dirStateRaw = st.map { "\($0.key)\t\($0.value ? 1 : 0)" }.sorted().joined(separator: "\n")
    }

    // MARK: 左栏：多级目录和会话

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                if computers.count > 1 {
                    Menu {
                        Button("全部电脑") { computer = "" }
                        ForEach(computers, id: \.self) { c in Button(c) { computer = c } }
                    } label: {
                        Text(computer.isEmpty ? "全部电脑" : computer).font(.system(size: 12))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .foregroundStyle(EchoColor.fg2)
                }
            }
            .padding(.leading, 80).padding(.trailing, 14)
            .frame(height: 56)
            .background(EchoWindowDrag())                                     // 红绿灯那一行，按住能拖窗口

            if state.sessions.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        collectionSection
                        ForEach(tree) { d in dirSection(d, level: 0) }
                    }
                    .padding(.horizontal, 10).padding(.bottom, 12)
                }
                .scrollIndicators(.never)
            }
            footer
        }
    }

    /// 一级目录：文件夹图标（收起合上、展开打开）、名字、会话数，缩进 16 一级；顶层名字加粗。
    /// 展开后先列子目录，再列直接在这一级开的会话
    private func dirSection(_ d: EchoDir, level: Int) -> AnyView {
        let open = isOpen(d, level: level)
        let parts = d.name.components(separatedBy: " / ")
        return AnyView(Group {
            EchoRow(fill: nil) {
                HStack(spacing: 8) {
                    EchoIcon(kind: open ? .folderOpen : .folder)
                        .foregroundStyle(open ? EchoColor.accent : EchoColor.fg2)
                    (Text(parts[0]).foregroundColor(EchoColor.fg)
                        + Text(parts.count > 1 ? " / " + parts.dropFirst().joined(separator: " / ") : "").foregroundColor(EchoColor.fg3))
                        .font(.system(size: 13, weight: level == 0 ? .semibold : .regular)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(d.count)").font(.system(size: 12)).foregroundStyle(EchoColor.fg3).monospacedDigit()
                }
                .padding(.leading, CGFloat(level) * 16)
                .frame(height: 30)
            } action: {
                toggle(d, level: level)
            }
            .padding(.top, level == 0 ? 10 : 0)
            .help((d.path as NSString).abbreviatingWithTildeInPath)

            if open {
                ForEach(d.children) { c in dirSection(c, level: level + 1) }
                sessionList(d.sessions, key: d.path, level: level + 1)
            }
        })
    }

    /// 会话先显示最近 5 个，下面「再显示 N 个」
    @ViewBuilder
    private func sessionList(_ list: [EchoSession], key: String, level: Int) -> some View {
        let limit = showAll.contains(key) ? list.count : 5
        ForEach(list.prefix(limit)) { s in sessionRow(s, indent: CGFloat(level) * 16) }
        if list.count > limit {
            EchoRow(fill: nil) {
                Text("再显示 \(list.count - limit) 个").font(.system(size: 12)).foregroundStyle(EchoColor.fg3)
                    .padding(.leading, CGFloat(level) * 16 + 24).frame(height: 26)
            } action: {
                showAll.insert(key)
            }
        }
    }

    private func sessionRow(_ s: EchoSession, indent: CGFloat) -> some View {
        let on = picked.contains(s.id) || (picked.isEmpty && collectionID == nil && s.id == session?.id)
        return EchoRow(fill: on ? EchoColor.sideOn : nil, shadow: on) {
          HStack(alignment: .top, spacing: 8) {
            EchoIcon(kind: .chat, size: 14).foregroundStyle(on ? EchoColor.accent : EchoColor.fg3).padding(.top, 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.meta.title == s.sessionId ? "未命名会话" : s.meta.title).font(.system(size: 13, weight: on ? .semibold : .regular)).lineLimit(1)
                    .foregroundStyle(EchoColor.fg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Text(EchoTime.short(s.endDate))
                    if computers.count > 1 { Text(s.computer).lineLimit(1) }
                    Spacer(minLength: 4)
                    Text(ByteCountFormatter.string(fromByteCount: s.size, countStyle: .file))
                }
                .font(.system(size: 12)).foregroundStyle(EchoColor.fg3).monospacedDigit()
            }
          }
          .padding(.leading, indent).padding(.vertical, 5)
        } action: {
            // ⌘ 点选：挑几个会话连起来看；普通点击打开
            if NSEvent.modifierFlags.contains(.command) {
                if picked.isEmpty, collectionID == nil, let cur = session { picked.insert(cur.id) }
                if picked.contains(s.id) { picked.remove(s.id) } else { picked.insert(s.id) }
            } else {
                picked = []
                collectionID = nil
                sessionID = s.id
            }
        }
        .contextMenu { sessionMenu(s) }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            if state.scanning || state.running {
                ProgressView().controlSize(.small)
            } else {
                Text("还没有备份").font(.system(size: 13)).foregroundStyle(EchoColor.fg2)
                Button("立即备份") { state.backupNow() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 左下角：备份状态和立即备份
    private var footer: some View {
        HStack(spacing: 8) {
            if state.running {
                ProgressView().controlSize(.mini).frame(width: 6, height: 6)
            } else {
                Image(systemName: state.needsAttention ? "exclamationmark.icloud" : "checkmark.icloud")
                    .font(.system(size: 13)).foregroundStyle(state.needsAttention ? EchoColor.warn : EchoColor.good)
            }
            Text(statusText).font(.system(size: 12)).foregroundStyle(EchoColor.fg3).lineLimit(1)
                .help(state.cleanupDays != nil ? "在 ~/.claude/settings.json 把 cleanupPeriodDays 设成 36500 可永久保留" : state.failures.joined(separator: "\n"))
            Spacer()
            Button { state.backupNow() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium)).frame(width: 26, height: 26)
            }
            .buttonStyle(EchoIconButton())
            .disabled(state.running)
            .help("立即备份")
        }
        .padding(.leading, 20).padding(.trailing, 12)
        .frame(height: 44)
    }

    private var statusText: String {
        if state.running { return state.total > 0 ? "正在备份 \(state.done)/\(state.total)" : "正在备份" }
        if state.error != nil { return "备份失败，点右边重试" }
        if !state.failures.isEmpty { return "\(state.failures.count) 个文件没备份上" }
        if let n = state.staleDays { return "已经 \(n) 天没备份" }
        if let n = state.cleanupDays { return "Claude Code 会删 \(n) 天前的会话" }
        if let d = state.lastSuccess { return "上次备份 \(EchoTime.short(d))" }
        return "还没有备份过"
    }
}

/// 列表行：悬停浅色圆角底；选中时由调用方给底色
struct EchoRow<Content: View>: View {
    var fill: Color?
    var shadow = false
    @ViewBuilder let content: Content
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        content
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(fill ?? (hover ? EchoColor.hover : .clear))
                    .shadow(color: .black.opacity(shadow ? 0.06 : 0), radius: 1, y: 1)
            )
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture(perform: action)
    }
}

struct EchoIconButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }
    private struct Styled: View {
        let configuration: Configuration
        @State private var hover = false
        var body: some View {
            configuration.label
                .foregroundStyle(hover ? EchoColor.fg : EchoColor.fg2)
                .background(RoundedRectangle(cornerRadius: 6).fill(hover || configuration.isPressed ? EchoColor.hover : .clear))
                .onHover { hover = $0 }
        }
    }
}

/// 拖窗口的区域：窗口没有标题栏，红绿灯那一行按住能拖，双击放大或还原（照伙伴云NAS应用 WindowDragArea）
struct EchoWindowDrag: NSViewRepresentable {
    final class V: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with e: NSEvent) {
            if e.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: e) }
        }
    }
    func makeNSView(context: Context) -> NSView { V() }
    func updateNSView(_ v: NSView, context: Context) {}
}

// MARK: - 右栏：对话

/// 右栏显示的东西：一个会话，或一个合集（几个会话连起来）
enum EchoTarget: Hashable {
    case session(EchoSession)
    case collection(EchoCollection, [EchoSession])

    var title: String {
        switch self {
        case .session(let s): return s.meta.title
        case .collection(let c, _): return c.title
        }
    }

    /// 内容变了（会话又写了、合集成员变了、改了名）才重新整理
    var key: String {
        switch self {
        case .session(let s): return "\(s.id)|\(s.size)"
        case .collection(let c, let m): return "\(c.id)|\(c.title)|" + m.map { "\($0.id):\($0.size)" }.joined(separator: ",")
        }
    }

    func load() throws -> [String: Any] {
        switch self {
        case .session(let s):
            var d = try EchoExport.export(s.url, computer: s.computer)
            var meta = d["meta"] as! [String: Any]
            meta["local"] = s.computer == EchoPrefs.computerName
            d["meta"] = meta
            return d
        case .collection(let c, let m):
            return try EchoExport.exportCollection(m.map { ($0.url, $0.computer) }, id: c.id, title: c.title)
        }
    }
}

struct EchoConversation: View {
    let target: EchoTarget
    @State private var loading = false
    @State private var failed: String?

    var body: some View {
        ZStack {
            EchoWebView(target: target, loading: $loading, failed: $failed)
            if loading { ProgressView().controlSize(.small) }
            if let f = failed {
                VStack(spacing: 6) {
                    Text("会话打不开").font(.headline)
                    Text(f).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct EchoWebView: NSViewRepresentable {
    let target: EchoTarget
    @Binding var loading: Bool
    @Binding var failed: String?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(context.coordinator.scheme, forURLScheme: "echo")
        cfg.userContentController.add(context.coordinator, name: "echo")
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.setValue(false, forKey: "drawsBackground")   // 加载前不闪白
        context.coordinator.web = w
        return w
    }

    func updateNSView(_ w: WKWebView, context: Context) {
        context.coordinator.show(target, loading: $loading, failed: $failed)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        let scheme = EchoScheme()
        weak var web: WKWebView?
        private var current: String?

        func show(_ t: EchoTarget, loading: Binding<Bool>, failed: Binding<String?>) {
            let key = t.key
            guard key != current else { return }
            current = key
            loading.wrappedValue = true
            failed.wrappedValue = nil
            Task.detached(priority: .userInitiated) {
                let r = Result { () -> Data in try JSONSerialization.data(withJSONObject: t.load()) }
                await MainActor.run {
                    guard self.current == key else { return }   // 整理期间又点了别的会话
                    loading.wrappedValue = false
                    switch r {
                    case .success(let data):
                        let token = UUID().uuidString
                        self.scheme.sessions = [token: data]
                        self.web?.load(URLRequest(url: URL(string: "echo://app/index.html?s=\(token)")!))
                    case .failure(let e):
                        failed.wrappedValue = e.localizedDescription
                    }
                }
            }
        }

        /// 网页里点「复制恢复命令」
        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let cmd = body["copy"] as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
        }
    }
}

/// echo://app/<文件>：页面文件取自 .app 的 Resources/Web，session.json 是当前会话整理好的数据
final class EchoScheme: NSObject, WKURLSchemeHandler {
    var sessions: [String: Data] = [:]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let name = url.lastPathComponent
        var body: Data?
        if name == "session.json" {
            let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "s" }?.value ?? ""
            body = sessions[token]
        } else if let res = Bundle.main.resourceURL {
            body = try? Data(contentsOf: res.appendingPathComponent("Web").appendingPathComponent(name))
        }
        guard let body else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let types = ["html": "text/html", "css": "text/css", "js": "text/javascript", "json": "application/json"]
        let mime = (types[url.pathExtension] ?? "application/octet-stream") + "; charset=utf-8"
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                        headerFields: ["Content-Type": mime, "Cache-Control": "no-store"])!)
        task.didReceive(body)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
