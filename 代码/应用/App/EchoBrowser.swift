// 浏览窗口：左栏多级目录树（合集、目录、会话），右栏总览或对话（网页见 EchoWeb.swift）。
// 照设计稿 设计/浏览窗口/：外框照伙伴云NAS应用（左栏灰底、右边白区、青绿强调色），列表不用系统 List。
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct EchoBrowserView: View {
    @EnvironmentObject var state: EchoState
    @AppStorage("filterComputer") private var computer = ""           // 空表示全部电脑
    @AppStorage("filterApp") private var appFilter = ""               // 空表示全部应用（EchoSource 的 rawValue）
    @State private var dateFilter = ProcessInfo.processInfo.environment["ECHO_SHOT_DATE"] ?? ""                                // 日期筛选：空是全部时间，「d7」最近 7 天，「m2026-11」某个月；不记住，每次打开窗口都是全部（会话少了容易以为丢了）
    @State private var months: Set<String> = []                       // 有会话的月份「m2026-11」（月份选择器用），数据变了算一次
    @State private var pickMenu: String? = ProcessInfo.processInfo.environment["ECHO_SHOT_MENU"]   // 左栏右上角展开的筛选菜单：computer、app、date（环境变量只给截图用）
    @State private var multiApp = false                               // 有几个应用的会话，才显示应用筛选和会话行图标
    @AppStorage("dirState") private var dirStateRaw = ""               // 用户点过的目录：一行「路径\t1」展开、「路径\t0」收起
    @State private var sessionID: String?
    @State private var collectionID: String?
    @State private var picked: Set<String> = []                        // ⌘ 点选的会话，用来连起来看
    @State private var renaming: EchoTarget?
    @State private var newTitle = ""
    @State private var editError: String?
    @State private var errorTitle = "操作未完成"
    @State private var moveDone: String?                               // 挪好后的提示和恢复命令
    @State private var moveCmd: String?
    @AppStorage("sidebarOrder") private var orderRaw = ""              // 拖动排好的顺序（EchoOrder），JSON
    @State private var drag = EchoDragState()                          // 拖动的状态：放在 @State 里不订阅，鼠标移动时左栏的树不重画
    @State private var currentID: String?                              // 当前打开的会话；数据变了算一次，不在每行里找
    @State private var multiComputer = false                           // 有几台电脑的会话，会话行才写电脑名
    @State private var openState: [String: Bool] = [:]                 // dirStateRaw 解析好的展开状态
    @State private var missingDirs: Set<String> = []                   // 访达里已经不存在的目录（改了名、挪走了），左栏标「已不存在」，数据变了算一次
    @State private var recentLocalDirs: [String] = []                  // 本机最近用过的会话目录（「移动到」用），数据变了算一次
    @State private var baseTree: [EchoDir] = []                        // 按最近用过分好的树，会话数据变了才重建；排序只在它上面套顺序
    @State private var orderMap: [String: [String]] = [:]              // orderRaw 解析好的顺序
    @State private var orderSaving = false                             // 拖完排序时界面已先改好，存顺序那次 onChange 不再重排
    @State private var tree: [EchoDir] = []                            // 会话列表变了才重新分组，不在每次刷新时算
    @State private var showAll: Set<String> = []                       // 点过「再显示」的项目
    @State private var showOverview = true                             // 打开窗口默认停在总览
    @State private var jumpAt: Double?                                 // 从总览点版本或提交进来：打开后跳到这个时间
    @State private var jumpQuery: String?                              // 从搜索结果进来：跳到 jumpAt 那一处，页面里查找这个词
    @State private var jumpSeq = 0                                     // 同一处再点一次也要跳回去
    @StateObject private var search = EchoSearchModel()
    @State private var query = ProcessInfo.processInfo.environment["ECHO_SHOT_QUERY"] ?? ""   // 左栏搜索框；有字时目录树换成搜索结果（环境变量只给截图用）
    @FocusState private var searchFocus: Bool
    @State private var shown: [EchoSession] = []                       // 按电脑、应用、日期筛过的会话，搜索只在这些里找
    @State private var searchPick: String?                             // 搜索结果里点过的那一处「文件编号:行号」
    @State private var searchMore: Set<String> = []                    // 点了「还有 N 处」的会话
    @AppStorage("sidebarWidth") private var sideW: Double = 272        // 左栏宽，拖右边缘改，200 到 420（照 NAS 网站）

    private var computers: [String] { Array(Set(state.sessions.map(\.computer))).sorted() }
    private var apps: [EchoSource] { EchoSource.allCases.filter { a in state.sessions.contains { $0.app == a } } }
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
        layout
        .overlay(alignment: .bottom) { EchoDropTip(drag: drag) }
        .overlay(alignment: .topLeading) {
            // 筛选菜单：盖在最上层，左栏右上角按钮下面；点外面任何地方收起
            if pickMenu != nil {
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001).onTapGesture { pickMenu = nil }
                    pickMenuView.frame(width: CGFloat(sideW) - 10, alignment: .trailing).padding(.top, 48)
                }
            }
        }
        .onChange(of: state.openSessionID) { _, id in
            guard let id else { return }
            state.openSessionID = nil
            picked = []
            collectionID = nil
            sessionID = id
            jumpAt = state.openAt
            jumpQuery = nil
            state.openAt = nil
            showOverview = false
        }
        .alert("改名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名字", text: $newTitle)
            Button("取消", role: .cancel) {}
            Button("改名", action: commitRename)
        } message: {
            if case .session(let s) = renaming, let u = EchoRename.originalURL(for: s), EchoRename.isActive(u) {
                Text("会话仍在进行，Claude Code 可能改回原名，建议在会话中用 /rename")
            }
        }
        .alert("已移动", isPresented: Binding(get: { moveDone != nil }, set: { if !$0 { moveDone = nil; moveCmd = nil } })) {
            if let c = moveCmd {
                Button("复制恢复命令") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c, forType: .string) }
            }
            Button("好", role: .cancel) {}
        } message: {
            Text(moveDone ?? "")
        }
        .alert(errorTitle, isPresented: Binding(get: { editError != nil }, set: { if !$0 { editError = nil; errorTitle = "操作未完成" } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(editError ?? "")
        }
    }

    /// 左栏加右边白区；修饰链拆成两段，免得编译器推导类型超时
    private var layout: some View {
        HStack(spacing: 0) {            sidebar
                .frame(width: sideW)
                .overlay(alignment: .trailing) { EchoResizeHandle(width: $sideW).frame(width: 10) }
            // 右边白区：靠左栏的两个角收圆角 12，左栏的灰底从圆角外露出来（照伙伴云NAS应用）
            ZStack {
                if showOverview { EchoOverview() }
                else if let t = target { EchoConversation(target: t, at: jumpAt, q: jumpQuery, seq: jumpSeq) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 网页顶上一条 10 高的透明拖动带（照伙伴云NAS应用 v0.9.3 的 WindowDragArea）：网页把鼠标吃掉，右边顶上也要能拖窗口、双击放大。
            // 对话标题栏的按钮从 12 开始（上内边距 8 加 4），总览的按钮从 17 开始，10 以内没有可点的东西
            .overlay(alignment: .top) { EchoWindowDrag().frame(height: 10) }
            .background(EchoColor.surface)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12))
            .overlay(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12).strokeBorder(EchoColor.sideLine, lineWidth: 1).padding(.trailing, -1))
        }
        .background(EchoColor.side)
        .foregroundStyle(EchoColor.fg)
        .ignoresSafeArea()
        .frame(minWidth: 860, minHeight: 560)
        .onAppear { orderMap = decodeOrder(); regroup() }
        .onChange(of: state.sessions) { _, _ in regroup() }
        .onChange(of: computer) { _, _ in regroup() }
        .onChange(of: appFilter) { _, _ in regroup() }
        .onChange(of: dateFilter) { _, _ in regroup() }
        .onChange(of: orderRaw) { _, _ in
            orderMap = decodeOrder()
            if orderSaving { orderSaving = false } else { tree = EchoOrder.arrange(baseTree, orderMap) }   // 别处改了顺序：只套顺序，不重建树
        }
        .onChange(of: sessionID) { _, _ in currentID = session?.id }
        .onChange(of: dirStateRaw) { _, _ in openState = dirState }
        .onChange(of: query) { _, q in searchPick = nil; searchMore = []; search.run(q, in: shown) }
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

    /// 删除确认：原会话在本机的和备份一起移走，不在的（清理了、在另一台电脑上）只移回响的备份。
    /// 统计数据默认留在总览里，勾选「同时删除统计数据」才删（三个按钮看不懂，改成勾选）。
    /// SwiftUI 的 alert 放不了勾选框，用 NSAlert 的勾选框（suppressionButton）
    /// folder：从目录右键删除时是目录名，确认框写清删的是这个目录下的会话、文件夹本身不删
    private func confirmDelete(_ list: [EchoSession], folder: String? = nil) {
        guard !list.isEmpty else { return }
        let local = list.filter { EchoRename.originalURL(for: $0) != nil }.count
        let a = NSAlert()
        if let folder {
            a.messageText = "将「\(folder)」中的 \(list.count) 个会话移到废纸篓？"
        } else {
            a.messageText = list.count > 1 ? "将 \(list.count) 个会话移到废纸篓？" : "将此会话移到废纸篓？"
        }
        a.informativeText = (folder == nil ? "" : "文件夹本身保留。")
            + (local == list.count ? "原会话和备份将移到废纸篓，可从废纸篓恢复。"
            : local == 0 ? "原会话已不在本机，仅移除备份，可从废纸篓恢复。"
            : "其中 \(local) 个原会话在本机，将与备份一起移到废纸篓，其余仅移除备份。可从废纸篓恢复。")
        a.addButton(withTitle: "移到废纸篓")
        a.addButton(withTitle: "取消")
        a.showsSuppressionButton = true
        a.suppressionButton?.title = "同时删除统计数据"
        a.suppressionButton?.state = .off
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let keepStats = a.suppressionButton?.state != .on
        picked = []
        if list.contains(where: { $0.id == sessionID }) { sessionID = nil }
        do { try state.delete(list, keepStats: keepStats) } catch { editError = error.localizedDescription }
    }

    /// 挪会话：先算好新位置，挪完当前打开的会话跟过去；有错只报错（带上挪成了几个），全成了提示恢复命令
    private func doMove(_ list: [EchoSession], _ dir: String) {
        let dir = (dir as NSString).standardizingPath
        let newIDs = Dictionary(list.compactMap { s in EchoMove.paths(for: s, to: dir).map { (s.id, $0.newBackup.path) } }, uniquingKeysWith: { a, _ in a })
        let r = state.move(list, to: dir)
        picked = []
        if let cur = sessionID, r.done.contains(where: { $0.id == cur }), let n = newIDs[cur] { sessionID = n }
        if let e = r.error {
            errorTitle = "移动失败"
            editError = (r.done.isEmpty ? "" : "已移动 \(r.done.count) 个，其余未移动。") + e.localizedDescription
            return
        }
        guard !r.done.isEmpty else { return }
        let shown = (dir as NSString).abbreviatingWithTildeInPath
        if r.done.count == 1, let s = r.done.first {
            moveCmd = "cd '\(dir.replacingOccurrences(of: "'", with: "'\\''"))' && claude --resume \(s.sessionId)"
            moveDone = "已移动到 \(shown)，可复制恢复命令继续会话"
        } else {
            moveDone = "\(r.done.count) 个会话已移动到 \(shown)"
        }
    }

    /// 目录右键：改名、移动到、在访达中显示、复制路径、移到废纸篓。文件夹已不存在的，第一项是「找到新位置…」。
    /// 删除只删会话（本机的原会话和备份一起进废纸篓，其他电脑的只删备份），文件夹本身不动
    @ViewBuilder
    private func dirMenu(_ d: EchoDir) -> some View {
        let gone = missingDirs.contains(d.path)
        if gone {
            Button("找到新位置…") { findNewPlace(d) }
            Divider()
        }
        let movable = sessionsUnder(d).filter { $0.app == .claude && $0.computer == EchoPrefs.computerName }
        Button("改名…") { renameDir(d) }
            .disabled(gone || EchoPath.isGroup(d.path))
        Menu(movable.isEmpty ? "移动到（无可移动的会话）" : "移动到") {
            ForEach(recentDirs(except: d.all).filter { !$0.hasPrefix(d.path + "/") && $0 != d.path }, id: \.self) { t in
                Button((t as NSString).abbreviatingWithTildeInPath) { confirmDirMove(d, to: t) }
            }
            Divider()
            Button("选择文件夹…") { pickDirTarget(d) }
        }
        .disabled(movable.isEmpty)
        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: d.path)]) }
            .disabled(gone || EchoPath.isGroup(d.path))
        Button("复制路径") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(d.path, forType: .string) }
        Divider()
        Button("移到废纸篓…") { confirmDelete(d.all, folder: d.name) }
    }

    /// 这个目录和子目录下的全部会话，不管左栏的电脑、应用、日期筛选（改名、移动目录要带上看不到的会话）
    private func sessionsUnder(_ d: EchoDir) -> [EchoSession] {
        state.sessions.filter { let p = EchoPath.real($0.projectPath); return p == d.path || p.hasPrefix(d.path + "/") }
    }

    /// 目录改名：改访达里的文件夹名，本机的 Claude Code 会话一起移到新名字下（EchoDirMove，和 ech mv 同一套）
    private func renameDir(_ d: EchoDir) {
        let field = NSTextField(string: d.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        let preview = EchoDirMove.plan(from: d.path, to: d.path + "-", sessions: state.sessions, moveFolder: true)
        let a = NSAlert()
        a.messageText = "将「\(d.name)」改名为："
        var info = "访达中的文件夹同步改名。" + EchoDirMove.describe(preview) + "。"
        if d.path.hasPrefix(NSHomeDirectory() + "/伙伴云NAS/") { info += "\n此文件夹在伙伴云 NAS 上，改名会同步给其他成员。" }
        a.informativeText = info
        a.accessoryView = field
        a.addButton(withTitle: "改名")
        a.addButton(withTitle: "取消")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != d.name else { return }
        guard !name.contains("/"), !name.hasPrefix(".") else { errorTitle = "改名失败"; editError = "名称不能包含「/」，也不能以「.」开头"; return }
        let target = ((d.path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
        runDirMove(EchoDirMove.plan(from: d.path, to: target, sessions: state.sessions, moveFolder: true), title: "改名失败")
    }

    /// 执行目录移动或改名，挪完刷新列表；有错只报错（带上挪成了几个）
    private func runDirMove(_ p: EchoDirMove.Plan, title: String) {
        do {
            let r = try EchoDirMove.run(p)
            picked = []
            if p.groups.values.joined().contains(where: { $0.id == sessionID }) { sessionID = nil }
            state.reloadSessions()
            if let e = r.error {
                errorTitle = title
                editError = "已移动 \(r.done) 个，其余未移动。" + e.localizedDescription
            } else if !p.moveFolder, r.done > 0 {
                moveDone = "\(r.done) 个会话已移动到 \((p.to as NSString).abbreviatingWithTildeInPath)"
            }
        } catch {
            errorTitle = title
            editError = error.localizedDescription
        }
    }

    private func pickDirTarget(_ d: EchoDir) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "移动到此处"
        panel.message = "选择「\(d.name)」的新位置，子文件夹中的会话移到对应的子文件夹"
        var parent = (d.path as NSString).deletingLastPathComponent
        while !parent.isEmpty, parent != "/", !FileManager.default.fileExists(atPath: parent) { parent = (parent as NSString).deletingLastPathComponent }
        panel.directoryURL = URL(fileURLWithPath: parent)
        guard panel.runModal() == .OK, let u = panel.url else { return }
        confirmDirMove(d, to: u.path)
    }

    /// 目录移动：会话挪到「新位置 + 它相对这个目录的子路径」，文件夹本身不动（常见是文件夹在访达里已经改了名、挪了位置）
    private func confirmDirMove(_ d: EchoDir, to target: String) {
        let target = EchoPath.real(target)
        guard target != d.path, !target.hasPrefix(d.path + "/") else { return }
        let p = EchoDirMove.plan(from: d.path, to: target, sessions: state.sessions, moveFolder: false)
        let a = NSAlert()
        a.messageText = "将「\(d.name)」中的 \(p.count) 个会话移动到「\((target as NSString).lastPathComponent)」？"
        a.informativeText = "子文件夹中的会话移到对应的子文件夹，移动后在新位置恢复会话。" + EchoDirMove.describe(p) + "。"
        if p.count > 0 { a.addButton(withTitle: "移动") }
        a.addButton(withTitle: p.count > 0 ? "取消" : "好")
        guard a.runModal() == .alertFirstButtonReturn, p.count > 0 else { return }
        runDirMove(p, title: "移动失败")
    }

    /// 文件夹已不存在：先猜它改成了什么（上一级里名字最像的子文件夹），问一句；猜不到或选「选择其他文件夹…」就打开选择框
    private func findNewPlace(_ d: EchoDir) {
        guard let g = EchoDirMove.guess(d.path) else { pickDirTarget(d); return }
        let name = (g as NSString).lastPathComponent
        let p = EchoDirMove.plan(from: d.path, to: g, sessions: state.sessions, moveFolder: false)
        let a = NSAlert()
        a.messageText = "「\(d.name)」已不存在，是否已改名为「\(name)」？"
        a.informativeText = EchoDirMove.describe(p) + "。移动后在「\(name)」中恢复会话。"
        a.addButton(withTitle: "移动会话")
        a.addButton(withTitle: "选择其他文件夹…")
        a.addButton(withTitle: "取消")
        switch a.runModal() {
        case .alertFirstButtonReturn: runDirMove(p, title: "移动失败")
        case .alertSecondButtonReturn: pickDirTarget(d)
        default: break
        }
    }

    /// 拖到目录上松手后确认一次：拖动容易失手，移动会改 Claude Code 里会话所在的文件夹
    private func confirmMove(_ list: [EchoSession], to d: EchoDir) {
        guard !list.isEmpty else { return }
        let a = NSAlert()
        a.messageText = list.count > 1 ? "将 \(list.count) 个会话移动到「\(d.name)」？" : "将此会话移动到「\(d.name)」？"
        a.informativeText = "移动后在该文件夹中恢复会话，会话内容不变。"
        a.addButton(withTitle: "移动")
        a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        doMove(list, d.path)
    }

    /// 「移动到」里列的文件夹：本机最近用过的会话目录（regroup 时算好），去掉这几个会话现在所在的，最多 8 个
    private func recentDirs(except list: [EchoSession]) -> [String] {
        let skip = Set(list.map(\.projectPath))
        return Array(recentLocalDirs.filter { !skip.contains($0) }.prefix(8))
    }

    private func pickFolder(_ list: [EchoSession]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "移动到此处"
        panel.message = "选择会话的新位置"
        if let p = list.first?.projectPath, FileManager.default.fileExists(atPath: p) { panel.directoryURL = URL(fileURLWithPath: p) }
        guard panel.runModal() == .OK, let u = panel.url else { return }
        doMove(list, u.path)
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
            Button("将 \(group.count) 个会话合并查看") { link(group) }
        }
        // 菜单在每次画行时就会构造，这里只按是不是本机的会话判断，不查文件；点下去时改名、删除、挪各自再查
        let local = s.computer == EchoPrefs.computerName
        let targets = group.count > 1 ? group : [s]
        if s.app == .codex, group.count < 2 {
            // Codex 的会话：在 Codex 里改名；按日期存、不按文件夹，不挪
            Button(local ? "复制恢复命令" : "复制恢复命令（在 \(s.computer) 上）") {
                let cmd = "cd '\(s.meta.cwd.replacingOccurrences(of: "'", with: "'\\''"))' && codex resume \(s.sessionId)"
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cmd, forType: .string)
            }
            .disabled(!local)
        } else {
            Button(local ? "改名…" : "改名…（在 \(s.computer) 上）") { startRename(.session(s)) }
                .disabled(!local)
            let movable = targets.allSatisfy { $0.computer == EchoPrefs.computerName && $0.app == .claude }
            let why = targets.contains { $0.app != .claude } ? "（不支持 Codex 会话）" : "（在 \(s.computer) 上）"
            Menu(!movable ? "移动到" + why : group.count > 1 ? "将 \(group.count) 个会话移动到" : "移动到") {
                ForEach(recentDirs(except: targets), id: \.self) { d in
                    Button((d as NSString).abbreviatingWithTildeInPath) { doMove(targets, d) }
                }
                Divider()
                Button("选择文件夹…") { pickFolder(targets) }
            }
            .disabled(!movable)
        }
        // 在访达中选中回响的备份文件：原会话可能已被清理、在别的电脑上，备份一直在
        Button(group.count > 1 ? "在访达中显示 \(group.count) 个备份" : "在访达中显示备份") {
            NSWorkspace.shared.activateFileViewerSelecting(targets.map(\.url))
        }
        Divider()
        if group.count > 1 {
            Button("将 \(group.count) 个会话移到废纸篓…") { confirmDelete(group) }
        } else {
            Button("移到废纸篓…") { confirmDelete([s]) }   // 原会话不在本机时只删回响的备份
        }
        if group.count < 2 {
            Divider()
            Text("按住 ⌘ 点选可多选")
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
                let on = !showOverview && c.id == collectionID
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
                    jumpAt = nil; jumpQuery = nil
                    showOverview = false
                }
                .contextMenu {
                    Button("改名…") { startRename(.collection(c, members)) }
                    Button("拆开") { unlink(c) }
                }
            }
        }
    }

    /// 左栏顶上一行「总览」（设计稿 设计/总览/）
    private var overviewRow: some View {
        EchoRow(fill: showOverview ? EchoColor.sideOn : nil, shadow: showOverview) {
            HStack(spacing: 6) {
                Image(systemName: "house").font(.system(size: 12, weight: .medium)).frame(width: 12)
                    .foregroundStyle(showOverview ? EchoColor.accent : EchoColor.fg2)
                Text("总览").font(.system(size: 13, weight: showOverview ? .semibold : .regular))
                Spacer()
            }
            .frame(height: 32)
        } action: {
            picked = []
            showOverview = true
        }
        .padding(.bottom, 6)
    }

    private func regroup() {
        let range = EchoDateFilter.range(dateFilter)
        shown = state.sessions.filter {
            (computer.isEmpty || $0.computer == computer) && (appFilter.isEmpty || $0.app.rawValue == appFilter)
                && (range == nil || range!.contains($0.endDate ?? .distantPast))
        }
        baseTree = EchoLibrary.dirTree(shown)
        if !query.trimmed.isEmpty { search.run(query, in: shown) }
        months = Set(state.sessions.compactMap { $0.endDate.map(EchoDateFilter.monthKey) })
        multiApp = Set(state.sessions.map(\.app)).count > 1
        tree = EchoOrder.arrange(baseTree, orderMap)
        multiComputer = Set(state.sessions.map(\.computer)).count > 1
        currentID = session?.id
        openState = dirState
        var seen = Set<String>(), dirs: [String] = []
        for s in state.sessions.filter({ $0.computer == EchoPrefs.computerName }).sorted(by: { ($0.endDate ?? .distantPast) > ($1.endDate ?? .distantPast) }) {
            let p = s.projectPath
            guard p.hasPrefix("/"), seen.insert(p).inserted, FileManager.default.fileExists(atPath: p) else { continue }
            dirs.append(p)
            if dirs.count == 12 { break }
        }
        recentLocalDirs = dirs
        // 本机路径（家目录下）已经不存在的目录；归出来的目录（Codex 后台任务等）不算
        var gone = Set<String>()
        func walk(_ ds: [EchoDir]) { for d in ds { if d.path.hasPrefix(NSHomeDirectory() + "/"), !FileManager.default.fileExists(atPath: d.path) { gone.insert(d.path) }; walk(d.children) } }
        walk(baseTree)
        missingDirs = gone
    }

    /// 目录展开收起：点过的按点的来；没点过的，顶层默认展开，当前会话所在的那几级也展开
    private func isOpen(_ d: EchoDir, level: Int) -> Bool {
        if let v = openState[d.path] { return v }
        return level == 0 || (collectionID == nil && d.contains(currentID))
    }

    private func toggle(_ d: EchoDir, level: Int) {
        var st = openState
        st[d.path] = !isOpen(d, level: level)
        dirStateRaw = st.map { "\($0.key)\t\($0.value ? 1 : 0)" }.sorted().joined(separator: "\n")
    }

    // MARK: 左栏：多级目录和会话

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 右上角筛选：电脑、应用、日期，只放图标，点了出小菜单（设计稿 设计/多应用/）；只有一台电脑、一个应用时不显示那一个，日期一直在
            HStack(spacing: 4) {
                Spacer()
                if computers.count > 1 {
                    EchoPickButton(on: !computer.isEmpty, help: computer.isEmpty ? "全部电脑" : computer) {
                        Image(systemName: "macbook").symbolRenderingMode(.monochrome).font(.system(size: 13))
                    } action: { pickMenu = pickMenu == "computer" ? nil : "computer" }
                }
                if multiApp {
                    EchoPickButton(on: false, help: EchoSource(rawValue: appFilter)?.title ?? "全部应用") {
                        if let a = EchoSource(rawValue: appFilter), let i = EchoSettingsStyle.appIcon(a) {
                            EchoAppLogo(app: a, image: i, size: 16)
                        } else {
                            Image(systemName: "square.grid.2x2").font(.system(size: 12.5))
                        }
                    } action: { pickMenu = pickMenu == "app" ? nil : "app" }
                }
                EchoPickButton(on: !dateFilter.isEmpty, help: EchoDateFilter.title(dateFilter)) {
                    Image(systemName: "clock").font(.system(size: 13))
                } action: { pickMenu = pickMenu == "date" ? nil : "date" }
            }
            .padding(.leading, 80).padding(.trailing, 10)
            .frame(height: 56)
            .background(EchoWindowDrag())                                     // 红绿灯那一行，按住能拖窗口

            if !state.sessions.isEmpty {
                EchoSearchField(text: $query, focused: $searchFocus) { if let g = search.groups.first { openHit(g.session, g.hits[0]) } }
                    .padding(.horizontal, 10).padding(.bottom, 8)
                    .background {   // ⌥⌘F 聚焦搜索框（照「备忘录」在全部备忘录中搜索）
                        Button("") { searchFocus = true }.keyboardShortcut("f", modifiers: [.command, .option]).opacity(0).allowsHitTesting(false)
                    }
            }

            if state.sessions.isEmpty {
                empty
            } else if !query.trimmed.isEmpty {
                ScrollView {
                    searchResults.padding(.horizontal, 10).padding(.bottom, 12)
                }
                .scrollIndicators(.never)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        overviewRow
                        collectionSection
                        ForEach(tree) { d in dirSection(d, level: 0, group: "/") }
                        if tree.isEmpty {
                            Text(dateFilter.isEmpty ? "没有符合筛选条件的会话" : "\(EchoDateFilter.title(dateFilter))没有用过的会话")
                                .font(.system(size: 12)).foregroundStyle(EchoColor.fg3).padding(.leading, 10).padding(.top, 14)
                        }
                    }
                    .padding(.horizontal, 10).padding(.bottom, 12)
                }
                .scrollIndicators(.never)
            }
            footer
        }
    }

    // MARK: 左栏：搜索结果

    /// 搜索结果：顶上一行写找到几处，下面按会话分组，每组先列最近的 3 处
    private var searchResults: some View {
        let q = query.trimmed
        return LazyVStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(searchHead(q))
                if search.groups.isEmpty, search.note == nil, !search.running, let u = search.updated {
                    Text("索引更新于 " + EchoCLI.bj(u, "M月d日 HH:mm") + "，之后的内容要等下一次备份")
                }
            }
            .font(.system(size: 12)).foregroundStyle(EchoColor.fg3)
            .padding(.leading, 10).padding(.top, 2).padding(.bottom, 4)
            ForEach(search.groups) { g in searchGroup(g, q) }
        }
    }

    private func searchHead(_ q: String) -> String {
        if let n = search.note { return n }
        if search.groups.isEmpty { return search.running ? "正在搜索…" : "没有找到「\(q)」" }
        return "\(search.total) 处，\(search.groups.count) 个会话" + (search.capped ? "（只列最近 \(EchoSearchModel.limit) 处）" : "")
    }

    private func searchGroup(_ g: EchoSearchGroup, _ q: String) -> some View {
        let s = g.session, anchor = EchoIndex.anchor(q)
        let list = searchMore.contains(g.id) ? g.hits : Array(g.hits.prefix(3))
        return VStack(alignment: .leading, spacing: 0) {
            EchoRow(fill: nil) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.meta.title == s.sessionId ? "未命名会话" : s.meta.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(EchoColor.fg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        Text((s.projectPath as NSString).lastPathComponent).lineLimit(1)
                        if multiComputer { Text(s.computer).lineLimit(1) }
                        Spacer(minLength: 4)
                        Text(EchoTime.short(s.endDate))
                    }
                    .font(.system(size: 12)).foregroundStyle(EchoColor.fg3).monospacedDigit()
                }
                .padding(.vertical, 6)
            } action: { openHit(s, g.hits[0]) }
            .help(s.projectPath)
            ForEach(list, id: \.line) { h in searchHitRow(h, s, q: q, anchor: anchor) }
            if g.hits.count > list.count {
                Text("还有 \(g.hits.count - list.count) 处").font(.system(size: 12)).foregroundStyle(EchoColor.accentText)
                    .padding(.leading, 22).padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .onTapGesture { searchMore.insert(g.id) }
            }
        }
        .padding(.top, 6)
    }

    /// 一处命中：谁说的（灰）加关键词附近的一截，关键词主色；悬停写时间
    private func searchHitRow(_ h: EchoIndex.Hit, _ s: EchoSession, q: String, anchor: String) -> some View {
        let key = "\(h.fid):\(h.line)", on = key == searchPick && !showOverview
        return EchoRow(fill: on ? EchoColor.sideOn : nil, shadow: on) {
            // 谁说的占一列，摘句折行时第二行和第一行对齐
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(h.role).foregroundStyle(EchoColor.fg3).frame(width: 26, alignment: .leading)
                Text(EchoSearchModel.marked(EchoSearchModel.cut(h.text, around: anchor), q)).foregroundStyle(EchoColor.fg2).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 12))
            .padding(.leading, 12).padding(.vertical, 5)
        } action: { openHit(s, h) }
        .help(EchoCLI.hm(h.ts))
    }

    /// 打开命中的会话，跳到那一处：按那一行的时间找到它所在的一段，页面里查找关键词，停在那一段之后的第一个
    private func openHit(_ s: EchoSession, _ h: EchoIndex.Hit) {
        picked = []
        collectionID = nil
        sessionID = s.id
        jumpAt = EchoTime.fastEpoch(h.ts).map { $0 * 1000 }
        jumpQuery = EchoIndex.anchor(query.trimmed)
        jumpSeq += 1
        searchPick = "\(h.fid):\(h.line)"
        showOverview = false
    }

    /// 树的竖线：每一级祖先的小三角正下方一条 1px 竖线，从上一级展开处一直连到这一级最后一行
    private func guides(_ level: Int) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<max(0, level), id: \.self) { k in
                Rectangle().fill(EchoColor.line).frame(width: 1).offset(x: 10 + CGFloat(k) * indentStep + 5.5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// 顶层目录里重名的名字，regroup 时算
    private var dupRoots: Set<String> {
        var seen = Set<String>(), dup = Set<String>()
        for d in tree where !seen.insert(d.name).inserted { dup.insert(d.name) }
        return dup
    }

    /// 上一级文件夹的名字，系统文件夹写中文（照访达）；在家目录下直接的写「~」
    static func parentName(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        if parent == NSHomeDirectory() { return "~" }
        let n = (parent as NSString).lastPathComponent
        return ["Desktop": "桌面", "Documents": "文稿", "Downloads": "下载"][n] ?? n
    }

    /// 每级缩进 18，正好是小三角加间距的宽度。下一级从上一级的文字起点开始：子目录的三角、会话的标题都和上一级目录名字对齐
    private let indentStep: CGFloat = 18

    /// 一级目录：展开按钮（小三角）、名字、会话数，缩进 18 一级：下一级从上一级的名字起点开始。
    /// 不加文件夹、会话图标（靠留白区隔）；各级字重一样。
    /// 展开后先列子目录，再列直接在这一级开的会话
    private func dirSection(_ d: EchoDir, level: Int, group: String) -> AnyView {
        let open = isOpen(d, level: level)
        return AnyView(Group {
            EchoRow(fill: nil) {
                HStack(spacing: 6) {
                    // 展开按钮：照 NAS 网站目录树，收起朝右、展开朝下，自己有悬停底
                    EchoTwist(open: open) { toggle(d, level: level) }
                    let gone = missingDirs.contains(d.path)
                    // 文件夹已不存在：名字灰掉，后面一个小图标，悬停写原路径和怎么处理（文字标签占地方）
                    Text(d.name).foregroundStyle(gone ? EchoColor.fg3 : EchoColor.fg)
                        .font(.system(size: 13)).lineLimit(1)
                    if gone {
                        Image(systemName: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(EchoColor.fg3)
                    }
                    // 顶层有同名目录（~/伙伴云NAS/客户文档 和 ~/Desktop/客户文档）：名字后面用灰色小字写上一级文件夹
                    if level == 0, dupRoots.contains(d.name) {
                        Text(Self.parentName(d.path)).font(.system(size: 12)).foregroundStyle(EchoColor.fg3).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text("\(d.count)").font(.system(size: 12)).foregroundStyle(EchoColor.fg3).monospacedDigit()
                }
                .padding(.leading, CGFloat(level) * indentStep)
                .frame(height: 34)
            } action: {
                toggle(d, level: level)
            }
            .background(guides(level))
            .overlay(EchoDropMark(drag: drag, key: d.path, dragged: { [p = d.path] in $0.dir == p }))
            .onDrag {
                startDrag(EchoDragItem(dir: d.path, group: group))
                return NSItemProvider(object: d.path as NSString)
            } preview: { dragGhost(d.name) }
            .onDrop(of: [.text], delegate: EchoRowDrop(drag: drag, update: { dirHover(d, group: group, y: $0.y) }, exit: { leave(d.path) }, perform: { dropOnDir(d) }))
            .padding(.top, level == 0 ? 8 : 0)   // 顶层目录之间多空一点，靠留白分组，不加图标
            .help(missingDirs.contains(d.path) ? "文件夹已不存在：\((d.path as NSString).abbreviatingWithTildeInPath)\n右键「找到新位置…」把会话移到改名后的文件夹" : (d.path as NSString).abbreviatingWithTildeInPath)
            .contextMenu { dirMenu(d) }

            if open {
                ForEach(d.children) { c in dirSection(c, level: level + 1, group: d.path) }
                sessionList(d.sessions, key: d.path, level: level + 1)
            }
        })
    }

    /// 会话先显示最近 5 个，下面「再显示 N 个」
    @ViewBuilder
    private func sessionList(_ list: [EchoSession], key: String, level: Int) -> some View {
        let limit = showAll.contains(key) ? list.count : 5
        ForEach(list.prefix(limit)) { s in sessionRow(s, indent: CGFloat(level - 1) * indentStep).background(guides(level)) }
        if list.count > limit {
            EchoRow(fill: nil) {
                Text("再显示 \(list.count - limit) 个").font(.system(size: 12)).foregroundStyle(EchoColor.fg3)
                    .padding(.leading, CGFloat(level - 1) * indentStep + 18).frame(height: 28)   // 和会话标题对齐
            } action: {
                showAll.insert(key)
            }
            .background(guides(level))
        }
    }

    private func sessionRow(_ s: EchoSession, indent: CGFloat) -> some View {
        let on = picked.contains(s.id) || (!showOverview && picked.isEmpty && collectionID == nil && s.id == currentID)
        return EchoRow(fill: on ? EchoColor.sideOn : nil, shadow: on) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.meta.title == s.sessionId ? "未命名会话" : s.meta.title).font(.system(size: 13, weight: on ? .semibold : .regular)).lineLimit(1)
                        .foregroundStyle(EchoColor.fg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        Text(EchoTime.short(s.endDate))
                        if multiComputer { Text(s.computer).lineLimit(1) }
                        Spacer(minLength: 4)
                        Text(ByteCountFormatter.string(fromByteCount: s.size, countStyle: .file))
                    }
                    .font(.system(size: 12)).foregroundStyle(EchoColor.fg3).monospacedDigit()
                }
            }
            .padding(.leading, indent + 18).padding(.vertical, 7)   // 会话标题和上一级目录名字对齐
        } action: {
            // ⌘ 点选：挑几个会话连起来看；普通点击打开
            if NSEvent.modifierFlags.contains(.command) {
                if picked.isEmpty, collectionID == nil, let cur = session { picked.insert(cur.id) }
                if picked.contains(s.id) { picked.remove(s.id) } else { picked.insert(s.id) }
            } else {
                picked = []
                collectionID = nil
                sessionID = s.id
                jumpAt = nil; jumpQuery = nil
                showOverview = false
            }
        }
        .contextMenu { sessionMenu(s) }
        .overlay(EchoDropMark(drag: drag, key: "s:" + s.id, dragged: { $0.sessions.contains { $0.id == s.id } }))
        .onDrag {
            // ⌘ 点选了几个、拖的是其中一个：几个一起拖
            let list = picked.contains(s.id) && picked.count > 1 ? state.sessions.filter { picked.contains($0.id) } : [s]
            startDrag(EchoDragItem(dir: "", group: "", sessions: list))
            return NSItemProvider(object: s.id as NSString)
        } preview: { dragGhost(picked.contains(s.id) && picked.count > 1 ? "\(picked.count) 个会话" : s.meta.title == s.sessionId ? "未命名会话" : s.meta.title) }
    }

    // MARK: 拖动：照 NAS 网站的拖放公共层（lib/dnd.js）。开始拖记下拖的是什么；拖过某行判断能不能放，只重画那一行的标记和底部提示（状态在 EchoDragState，左栏的树不跟着重画）；松开再判断一次、收掉，能放才执行

    private func decodeOrder() -> [String: [String]] {
        (try? JSONDecoder().decode([String: [String]].self, from: Data(orderRaw.utf8))) ?? [:]
    }

    private func startDrag(_ item: EchoDragItem) {
        drag.item = item
        drag.set(nil)
        // 拖到窗口外松手时收不到放下：鼠标松开后稍等一下（让放下先处理）再清掉
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { t in
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            t.invalidate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { drag.clear() }
        }
    }

    private func leave(_ key: String) { if drag.hint?.key == key { drag.set(nil) } }

    /// 目录行：同一级的目录拖来是排序（上半行插到前面，下半行插到后面）；会话拖来是移动到这个文件夹。
    /// 会话不排序，只按最近用过排
    private func dirHover(_ d: EchoDir, group: String, y: CGFloat) {
        guard let it = drag.item else { drag.set(nil); return }
        if !it.sessions.isEmpty { drag.set(moveHint(it.sessions, to: d)); return }
        guard it.dir != d.path else { drag.set(nil); return }
        drag.set(it.group == group
            ? EchoDropHint(key: d.path, mode: y < 17 ? .before : .after, ok: true, text: "")
            : EchoDropHint(key: d.path, mode: .into, ok: false, text: "目录只能在同级之间排序"))
    }

    /// 会话拖到目录上能不能放：只有本机的 Claude 会话能移动，文件夹要在本机，已在这个文件夹里的不算
    private func moveHint(_ list: [EchoSession], to d: EchoDir) -> EchoDropHint {
        let name = "「\(d.name)」"
        func no(_ t: String) -> EchoDropHint { EchoDropHint(key: d.path, mode: .into, ok: false, text: t) }
        if EchoPath.isGroup(d.path) { return no("\(name)是分组，无法移入") }
        if list.contains(where: { $0.app != .claude }) { return no("不支持移动 Codex 会话") }
        if let s = list.first(where: { $0.computer != EchoPrefs.computerName }) { return no("会话在 \(s.computer) 上，无法移动") }
        if list.allSatisfy({ EchoPath.real($0.projectPath) == d.path }) { return no("会话已在\(name)中") }
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: d.path, isDirectory: &isDir) || !isDir.boolValue { return no("\(name)已不存在，无法移入") }
        return EchoDropHint(key: d.path, mode: .into, ok: true, text: list.count > 1 ? "将 \(list.count) 个会话移动到\(name)" : "移动到\(name)")
    }

    private func dropOnDir(_ d: EchoDir) -> Bool {
        defer { drag.clear() }
        guard let it = drag.item, let h = drag.hint, h.key == d.path, h.ok else { return false }
        if !it.sessions.isEmpty {
            // 先让放下结束（拖影收回），再弹确认
            let list = it.sessions.filter { EchoPath.real($0.projectPath) != d.path }
            DispatchQueue.main.async { confirmMove(list, to: d) }
            return true
        }
        return reorder(it.group, [it.dir], to: d.path, after: h.mode == .after)
    }

    /// 按左栏现在的顺序算出整组新顺序，记下来
    private func reorder(_ group: String, _ moving: [String], to target: String, after: Bool) -> Bool {
        func find(_ dirs: [EchoDir], _ path: String) -> EchoDir? {
            for d in dirs { if d.path == path { return d }; if let c = find(d.children, path) { return c } }
            return nil
        }
        let keys: [String]
        if group == "/" { keys = tree.map(\.path) }
        else { keys = find(tree, group)?.children.map(\.path) ?? [] }
        guard !keys.isEmpty else { return false }
        let next = EchoOrder.move(keys, moving: moving, to: target, after: after)
        guard next != keys else { return true }
        // 先改界面：只重排这一组，松手当下就看到新顺序；存顺序放到下一刻，不挡这一帧
        tree = EchoOrder.apply(tree, group: group, keys: next)
        orderMap[group] = next
        let all = orderMap
        DispatchQueue.main.async {
            guard let d = try? JSONEncoder().encode(all) else { return }
            orderSaving = true
            orderRaw = String(decoding: d, as: UTF8.self)
        }
        return true
    }

    /// 拖影：名字小卡片，照 NAS 的 .ui-dnd-ghost
    private func dragGhost(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).lineLimit(1).frame(maxWidth: 260, alignment: .leading)
            .padding(.horizontal, 12).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(EchoColor.surface).shadow(color: .black.opacity(0.18), radius: 6, y: 2))
            .foregroundStyle(EchoColor.fg)
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

    /// 筛选菜单：白底细框，一项一行（图标、名字），选中的文字用主色、右边一个小勾（设计稿 设计/多应用/）。点外面收起
    @ViewBuilder
    private var pickMenuView: some View {
        if pickMenu == "computer" {
            EchoPickMenu(width: 220, items: [("", AnyView(Image(systemName: "macbook").symbolRenderingMode(.monochrome)), "全部电脑")]
                         + computers.map { ($0, AnyView(Image(systemName: "macbook").symbolRenderingMode(.monochrome)), $0) },
                         selected: computer) { computer = $0; pickMenu = nil }
        } else if pickMenu == "app" {
            EchoPickMenu(width: 176, items: [("", AnyView(Image(systemName: "square.grid.2x2")), "全部")]
                         + apps.map { a in (a.rawValue, AnyView(Group { if let i = EchoSettingsStyle.appIcon(a) { EchoAppLogo(app: a, image: i, size: 16) } }), a.title) },
                         selected: appFilter) { appFilter = $0; pickMenu = nil }
        } else if pickMenu == "date" {
            EchoDateMenu(selected: dateFilter, months: months) { dateFilter = $0; pickMenu = nil }
        }
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

/// 正在拖的目录或会话。拖目录时 group 是它所在的那一级（见 EchoOrder），只能在同一级里排序；
/// 拖会话时 sessions 是拖着的会话（⌘ 点选了几个就是那几个），放到目录上是移动
struct EchoDragItem {
    var dir: String
    var group: String
    var sessions: [EchoSession] = []
}

struct EchoDropHint: Equatable {
    enum Mode { case before, after, into }
    var key: String
    var mode: Mode
    var ok: Bool
    var text: String
}

/// 行上的放下：随鼠标位置更新提示（排序时看在上半行还是下半行），松开时交给行处理
/// 照 NAS 网站 dnd.js 的 dragover：每次判断能不能放，能放是「移动」，不能放光标显示禁止（dropEffect none）
struct EchoRowDrop: DropDelegate {
    let drag: EchoDragState
    let update: (CGPoint) -> Void
    let exit: () -> Void
    let perform: () -> Bool
    func dropEntered(info: DropInfo) { update(info.location) }
    func dropUpdated(info: DropInfo) -> DropProposal? { update(info.location); return DropProposal(operation: drag.hint?.ok == true ? .move : .forbidden) }
    func dropExited(info: DropInfo) { exit() }
    func performDrop(info: DropInfo) -> Bool { perform() }
}

/// 拖动的状态单独放一个对象：只有下面几个小视图订阅它，鼠标每动一下只重画插入线、描边、提示条，左栏的树不动
@MainActor final class EchoDragState: ObservableObject {
    @Published var item: EchoDragItem?
    @Published var hint: EchoDropHint?
    func set(_ h: EchoDropHint?) { if hint != h { hint = h } }   // 一样就不发通知
    func clear() { if item != nil { item = nil }; set(nil) }
}

/// 行上的拖动标记（照 NAS 网站的拖放）：能放进的目录浅主色底加主色边，排序处一条主色插入线，拖着的那行盖一层左栏底色变淡
struct EchoDropMark: View {
    @ObservedObject var drag: EchoDragState
    let key: String
    let dragged: (EchoDragItem) -> Bool

    var body: some View {
        ZStack {
            if let it = drag.item, dragged(it) { RoundedRectangle(cornerRadius: 8).fill(EchoColor.side.opacity(0.55)) }
            if let h = drag.hint, h.key == key, h.ok {
                switch h.mode {
                case .into:
                    RoundedRectangle(cornerRadius: 8).fill(EchoColor.sel)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(EchoColor.accent, lineWidth: 1.5))
                case .before: VStack(spacing: 0) { Rectangle().fill(EchoColor.accent).frame(height: 2); Spacer(minLength: 0) }
                case .after: VStack(spacing: 0) { Spacer(minLength: 0); Rectangle().fill(EchoColor.accent).frame(height: 2) }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// 底部居中的提示条：深底浅字，写清松开会怎样、不能放的原因
struct EchoDropTip: View {
    @ObservedObject var drag: EchoDragState

    var body: some View {
        if drag.item != nil, let h = drag.hint, !h.text.isEmpty {   // 排序时不出提示条，只有插入线
            Text(h.text).font(.system(size: 12)).lineLimit(1)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(EchoColor.fg).shadow(color: .black.opacity(0.18), radius: 6, y: 2))
                .foregroundStyle(EchoColor.surface)
                .padding(.bottom, 24)
                .allowsHitTesting(false)
        }
    }
}
