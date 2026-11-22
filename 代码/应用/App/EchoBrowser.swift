// 浏览窗口：左栏多级目录树（合集、目录、会话），右栏总览或对话（网页见 EchoWeb.swift）。
// 照设计稿 设计/浏览窗口/：外框照伙伴云NAS应用（左栏灰底、右边白区、青绿强调色），列表不用系统 List。
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct EchoBrowserView: View {
    @EnvironmentObject var state: EchoState
    @AppStorage("filterComputer") private var computer = ""           // 空表示全部电脑
    @AppStorage("filterApp") private var appFilter = ""               // 空表示全部应用（EchoSource 的 rawValue）
    @State private var pickMenu: String? = ProcessInfo.processInfo.environment["ECHO_SHOT_MENU"]   // 左栏右上角展开的筛选菜单：computer、app（环境变量只给截图用）
    @State private var multiApp = false                               // 有几个应用的会话，才显示应用筛选和会话行图标
    @AppStorage("dirState") private var dirStateRaw = ""               // 用户点过的目录：一行「路径\t1」展开、「路径\t0」收起
    @State private var sessionID: String?
    @State private var collectionID: String?
    @State private var picked: Set<String> = []                        // ⌘ 点选的会话，用来连起来看
    @State private var renaming: EchoTarget?
    @State private var newTitle = ""
    @State private var editError: String?
    @State private var deleting: [EchoSession] = []
    @State private var errorTitle = "没改成"
    @State private var moveDone: String?                               // 挪好后的提示和恢复命令
    @State private var moveCmd: String?
    @AppStorage("sidebarOrder") private var orderRaw = ""              // 拖动排好的顺序（EchoOrder），JSON
    @State private var drag = EchoDragState()                          // 拖动的状态：放在 @State 里不订阅，鼠标移动时左栏的树不重画
    @State private var currentID: String?                              // 当前打开的会话；数据变了算一次，不在每行里找
    @State private var multiComputer = false                           // 有几台电脑的会话，会话行才写电脑名
    @State private var openState: [String: Bool] = [:]                 // dirStateRaw 解析好的展开状态
    @State private var recentLocalDirs: [String] = []                  // 本机最近用过的会话目录（「移动到」用），数据变了算一次
    @State private var baseTree: [EchoDir] = []                        // 按最近用过分好的树，会话数据变了才重建；排序只在它上面套顺序
    @State private var orderMap: [String: [String]] = [:]              // orderRaw 解析好的顺序
    @State private var orderSaving = false                             // 拖完排序时界面已先改好，存顺序那次 onChange 不再重排
    @State private var tree: [EchoDir] = []                            // 会话列表变了才重新分组，不在每次刷新时算
    @State private var showAll: Set<String> = []                       // 点过「再显示」的项目
    @State private var showOverview = true                             // 打开窗口默认停在总览
    @State private var jumpAt: Double?                                 // 从总览点版本或提交进来：打开后跳到这个时间
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
            state.openAt = nil
            showOverview = false
        }
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
            Text(Set(deleting.map(\.app)).count == 1 ? "\(deleting[0].app.title) 里的原会话和回响的备份一起移走" : "原会话和回响的备份一起移走")
        }
        .alert("挪好了", isPresented: Binding(get: { moveDone != nil }, set: { if !$0 { moveDone = nil; moveCmd = nil } })) {
            if let c = moveCmd {
                Button("复制恢复命令") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c, forType: .string) }
            }
            Button("好", role: .cancel) {}
        } message: {
            Text(moveDone ?? "")
        }
        .alert(errorTitle, isPresented: Binding(get: { editError != nil }, set: { if !$0 { editError = nil; errorTitle = "没改成" } })) {
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
                else if let t = target { EchoConversation(target: t, at: jumpAt) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .onChange(of: orderRaw) { _, _ in
            orderMap = decodeOrder()
            if orderSaving { orderSaving = false } else { tree = EchoOrder.arrange(baseTree, orderMap) }   // 别处改了顺序：只套顺序，不重建树
        }
        .onChange(of: sessionID) { _, _ in currentID = session?.id }
        .onChange(of: dirStateRaw) { _, _ in openState = dirState }
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

    /// 挪会话：先算好新位置，挪完当前打开的会话跟过去；有错只报错（带上挪成了几个），全成了提示恢复命令
    private func doMove(_ list: [EchoSession], _ dir: String) {
        let dir = (dir as NSString).standardizingPath
        let newIDs = Dictionary(list.compactMap { s in EchoMove.paths(for: s, to: dir).map { (s.id, $0.newBackup.path) } }, uniquingKeysWith: { a, _ in a })
        let r = state.move(list, to: dir)
        picked = []
        if let cur = sessionID, r.done.contains(where: { $0.id == cur }), let n = newIDs[cur] { sessionID = n }
        if let e = r.error {
            errorTitle = "没挪成"
            editError = (r.done.isEmpty ? "" : "挪成了 \(r.done.count) 个，其余没挪：") + e.localizedDescription
            return
        }
        guard !r.done.isEmpty else { return }
        let shown = (dir as NSString).abbreviatingWithTildeInPath
        if r.done.count == 1, let s = r.done.first {
            moveCmd = "cd '\(dir.replacingOccurrences(of: "'", with: "'\\''"))' && claude --resume \(s.sessionId)"
            moveDone = "已挪到 \(shown)，在终端或 MintPop 里用恢复命令续上"
        } else {
            moveDone = "\(r.done.count) 个会话已挪到 \(shown)"
        }
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
        panel.prompt = "挪到这里"
        panel.message = "选一个文件夹，会话挪过去后在那里续上"
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
            Button("把 \(group.count) 个会话连起来看") { link(group) }
        }
        // 菜单在每次画行时就会构造，这里只按是不是本机的会话判断，不查文件；点下去时改名、删除、挪各自再查
        let local = s.computer == EchoPrefs.computerName
        let targets = group.count > 1 ? group : [s]
        if s.app == .codex, group.count < 2 {
            // Codex 的会话：在 Codex 里改名；按日期存、不按文件夹，不挪
            Button(local ? "复制恢复命令" : "复制恢复命令（会话在 \(s.computer) 上）") {
                let cmd = "cd '\(s.meta.cwd.replacingOccurrences(of: "'", with: "'\\''"))' && codex resume \(s.sessionId)"
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cmd, forType: .string)
            }
            .disabled(!local)
        } else {
            Button(local ? "改名…" : "改名…（会话在 \(s.computer) 上）") { startRename(.session(s)) }
                .disabled(!local)
            let movable = targets.allSatisfy { $0.computer == EchoPrefs.computerName && $0.app == .claude }
            let why = targets.contains { $0.app != .claude } ? "（Codex 的会话不挪）" : "（会话在 \(s.computer) 上）"
            Menu(!movable ? "移动到" + why : group.count > 1 ? "把 \(group.count) 个会话移动到" : "移动到") {
                ForEach(recentDirs(except: targets), id: \.self) { d in
                    Button((d as NSString).abbreviatingWithTildeInPath) { doMove(targets, d) }
                }
                Divider()
                Button("选择文件夹…") { pickFolder(targets) }
            }
            .disabled(!movable)
        }
        Divider()
        if group.count > 1 {
            Button("把 \(group.count) 个会话移到废纸篓…") { deleting = group }
        } else {
            Button(local ? "移到废纸篓…" : "移到废纸篓…（会话在 \(s.computer) 上）") { deleting = [s] }
                .disabled(!local)
        }
        if group.count < 2 {
            Divider()
            Text("⌘ 点选可多选")
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
                    jumpAt = nil
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
        baseTree = EchoLibrary.dirTree(state.sessions.filter { (computer.isEmpty || $0.computer == computer) && (appFilter.isEmpty || $0.app.rawValue == appFilter) })
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
            // 右上角两个筛选：电脑、应用，只放图标，点了出小菜单（设计稿 设计/多应用/）；只有一台电脑、一个应用时不显示
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
                            Image(nsImage: i).resizable().frame(width: 16, height: 16).clipShape(RoundedRectangle(cornerRadius: 3.5))
                        } else {
                            Image(systemName: "square.grid.2x2").font(.system(size: 12.5))
                        }
                    } action: { pickMenu = pickMenu == "app" ? nil : "app" }
                }
            }
            .padding(.leading, 80).padding(.trailing, 10)
            .frame(height: 56)
            .background(EchoWindowDrag())                                     // 红绿灯那一行，按住能拖窗口


            if state.sessions.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        overviewRow
                        collectionSection
                        ForEach(tree) { d in dirSection(d, level: 0, group: "/") }
                    }
                    .padding(.horizontal, 10).padding(.bottom, 12)
                }
                .scrollIndicators(.never)
            }
            footer
        }
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
                    Text(d.name).foregroundStyle(EchoColor.fg)
                        .font(.system(size: 13)).lineLimit(1)
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
            .help((d.path as NSString).abbreviatingWithTildeInPath)

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
                        // 看全部应用时，最前面一个应用小图标（不画边线，左栏灰底上看得出白底）
                        if multiApp, appFilter.isEmpty, let i = EchoSettingsStyle.appIcon(s.app) {
                            Image(nsImage: i).resizable().frame(width: 12, height: 12).clipShape(RoundedRectangle(cornerRadius: 2.5))
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                        }
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
                jumpAt = nil
                showOverview = false
            }
        }
        .contextMenu { sessionMenu(s) }
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

    /// 目录行：同一级的目录拖来是排序（上半行插到前面，下半行插到后面）。会话不能拖，只按最近用过排
    private func dirHover(_ d: EchoDir, group: String, y: CGFloat) {
        guard let it = drag.item, it.dir != d.path else { drag.set(nil); return }
        drag.set(it.group == group
            ? EchoDropHint(key: d.path, mode: y < 17 ? .before : .after, ok: true, text: "")
            : EchoDropHint(key: d.path, mode: .into, ok: false, text: "目录只能在同一级里排序"))
    }

    private func dropOnDir(_ d: EchoDir) -> Bool {
        defer { drag.clear() }
        guard let it = drag.item, let h = drag.hint, h.key == d.path, h.ok else { return false }
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
                         + apps.map { a in (a.rawValue, AnyView(Group { if let i = EchoSettingsStyle.appIcon(a) { Image(nsImage: i).resizable().frame(width: 16, height: 16).clipShape(RoundedRectangle(cornerRadius: 3.5)).overlay(RoundedRectangle(cornerRadius: 3.5).strokeBorder(EchoColor.line, lineWidth: 0.5)) } }), a.title) },
                         selected: appFilter) { appFilter = $0; pickMenu = nil }
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

/// 正在拖的目录。group 是它所在的那一级（见 EchoOrder），只能在同一级里排序
struct EchoDragItem {
    var dir: String
    var group: String
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
