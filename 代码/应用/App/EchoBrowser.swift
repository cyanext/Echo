// 浏览窗口：左栏多级目录树（合集、目录、会话），右栏总览或对话（网页见 EchoWeb.swift）。
// 照设计稿 设计/浏览窗口/：外框照伙伴云NAS应用（左栏灰底、右边白区、青绿强调色），列表不用系统 List。
import AppKit
import SwiftUI

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
    @State private var errorTitle = "没改成"
    @State private var moveList: [EchoSession] = []                    // 拖到目录上、等确认要挪的会话
    @State private var moveDir = ""
    @State private var moveDone: String?                               // 挪好后的提示和恢复命令
    @State private var moveCmd: String?
    @State private var dropTarget: String?                             // 拖着会话经过的目录，标白底
    @State private var tree: [EchoDir] = []                            // 会话列表变了才重新分组，不在每次刷新时算
    @State private var showAll: Set<String> = []                       // 点过「再显示」的项目
    @State private var showOverview = true                             // 打开窗口默认停在总览
    @State private var jumpAt: Double?                                 // 从总览点版本或提交进来：打开后跳到这个时间
    @AppStorage("sidebarWidth") private var sideW: Double = 272        // 左栏宽，拖右边缘改，200 到 420（照 NAS 网站）

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
        .onAppear(perform: regroup)
        .onChange(of: state.sessions) { _, _ in regroup() }
        .onChange(of: computer) { _, _ in regroup() }
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
            Text("Claude Code 里的原会话和回响的备份一起移走")
        }
        .alert(moveList.count > 1 ? "把 \(moveList.count) 个会话挪到这个文件夹？" : "把「\(moveList.first?.meta.title ?? "")」挪到这个文件夹？",
               isPresented: Binding(get: { !moveList.isEmpty }, set: { if !$0 { moveList = [] } })) {
            Button("取消", role: .cancel) {}
            Button("挪过去") { let l = moveList, d = moveDir; doMove(l, d) }
        } message: {
            Text("\((moveDir as NSString).abbreviatingWithTildeInPath)\nClaude Code 里的原会话和回响的备份一起挪，挪完在这个文件夹续上")
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

    /// 「移动到」里列的文件夹：本机最近用过的会话目录，去掉这几个会话现在所在的，最多 8 个
    private func recentDirs(except list: [EchoSession]) -> [String] {
        let skip = Set(list.map(\.projectPath))
        var seen = Set<String>(), out: [String] = []
        let local = state.sessions.filter { $0.computer == EchoPrefs.computerName }
            .sorted { ($0.endDate ?? .distantPast) > ($1.endDate ?? .distantPast) }
        for s in local {
            let p = s.projectPath
            guard !skip.contains(p), p.hasPrefix("/"), seen.insert(p).inserted, FileManager.default.fileExists(atPath: p) else { continue }
            out.append(p)
            if out.count == 8 { break }
        }
        return out
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
        Button(EchoRename.originalURL(for: s) == nil ? "改名…（会话在 \(s.computer) 上）" : "改名…") { startRename(.session(s)) }
            .disabled(EchoRename.originalURL(for: s) == nil)
        let targets = group.count > 1 ? group : [s]
        let movable = targets.allSatisfy { EchoRename.originalURL(for: $0) != nil }
        Menu(!movable ? "移动到（会话在 \(s.computer) 上）" : group.count > 1 ? "把 \(group.count) 个会话移动到" : "移动到") {
            ForEach(recentDirs(except: targets), id: \.self) { d in
                Button((d as NSString).abbreviatingWithTildeInPath) { doMove(targets, d) }
            }
            Divider()
            Button("选择文件夹…") { pickFolder(targets) }
        }
        .disabled(!movable)
        Divider()
        if group.count > 1 {
            Button("把 \(group.count) 个会话移到废纸篓…") { deleting = group }
        } else {
            Button(EchoDelete.paths(for: s) == nil ? "移到废纸篓…（会话在 \(s.computer) 上）" : "移到废纸篓…") { deleting = [s] }
                .disabled(EchoDelete.paths(for: s) == nil)
        }
        if group.count < 2 {
            Divider()
            Text("⌘ 点选几个会话，可以连起来看、一起挪或一起删；把会话拖到目录上也能挪")
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
                    LazyVStack(alignment: .leading, spacing: 0) {
                        overviewRow
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
    private func dirSection(_ d: EchoDir, level: Int) -> AnyView {
        let open = isOpen(d, level: level)
        let parts = d.name.components(separatedBy: " / ")
        return AnyView(Group {
            EchoRow(fill: dropTarget == d.path ? EchoColor.sideOn : nil, shadow: dropTarget == d.path) {
                HStack(spacing: 6) {
                    // 展开按钮：照 NAS 网站目录树，收起朝右、展开朝下，自己有悬停底
                    EchoTwist(open: open) { toggle(d, level: level) }
                    (Text(parts[0]).foregroundColor(EchoColor.fg)
                        + Text(parts.count > 1 ? " / " + parts.dropFirst().joined(separator: " / ") : "").foregroundColor(EchoColor.fg3))
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
            .dropDestination(for: String.self) { items, _ in
                // 拖来的是会话的 id（几个选中的用换行连起来）；已经在这个目录的不算
                let ids = Set(items.flatMap { $0.split(separator: "\n").map(String.init) })
                let list = state.sessions.filter { ids.contains($0.id) && $0.projectPath != d.path }
                dropTarget = nil
                guard !list.isEmpty else { return false }
                moveDir = d.path
                moveList = list
                return true
            } isTargeted: { on in
                if on { dropTarget = d.path } else if dropTarget == d.path { dropTarget = nil }
            }
            .padding(.top, level == 0 ? 8 : 0)   // 顶层目录之间多空一点，靠留白分组，不加图标
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
        let on = picked.contains(s.id) || (!showOverview && picked.isEmpty && collectionID == nil && s.id == session?.id)
        return EchoRow(fill: on ? EchoColor.sideOn : nil, shadow: on) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
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
        .draggable(picked.contains(s.id) && picked.count > 1 ? picked.sorted().joined(separator: "\n") : s.id)
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
