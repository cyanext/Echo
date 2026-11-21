// 浏览窗口：左栏项目、中栏会话、右栏对话（WKWebView 加载 Web/ 里的页面）。
// 列表照伙伴云NAS应用的设计规范：不用系统 List，用间距加悬停浅色圆角底。
import AppKit
import SwiftUI
import WebKit

struct EchoBrowserView: View {
    @EnvironmentObject var state: EchoState
    @State private var computer = ""          // 空表示全部电脑
    @State private var projectID: String?
    @State private var sessionID: String?

    private var computers: [String] { Array(Set(state.sessions.map(\.computer))).sorted() }
    private var projects: [EchoProject] {
        EchoLibrary.group(computer.isEmpty ? state.sessions : state.sessions.filter { $0.computer == computer })
    }
    private var project: EchoProject? { projects.first { $0.id == projectID } ?? projects.first }
    private var session: EchoSession? { project?.sessions.first { $0.id == sessionID } }

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } content: {
            sessionList.navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        } detail: {
            if let s = session {
                EchoConversation(session: s)
            } else {
                Text(state.sessions.isEmpty ? "" : "选择一个会话").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(project?.name ?? "回响")
        .frame(minWidth: 900, minHeight: 560)
    }

    // MARK: 左栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if computers.count > 1 {
                Picker("", selection: $computer) {
                    Text("全部").tag("")
                    ForEach(computers, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 10)
            }
            if state.sessions.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(projects) { p in
                            EchoRow(selected: p.id == project?.id) {
                                HStack(spacing: 8) {
                                    Image(systemName: "folder").frame(width: 16).foregroundStyle(.secondary)
                                    Text(p.name).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text("\(p.sessions.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                            } action: {
                                projectID = p.id
                                sessionID = p.sessions.first?.id
                            }
                            .help(p.path)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
        }
        .padding(.top, 6)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            if state.scanning || state.running {
                ProgressView().controlSize(.small)
                Text(state.running ? "正在备份" : "正在读取").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("还没有备份").font(.callout).foregroundStyle(.secondary)
                Button("立即备份") { state.backupNow() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 中栏

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(project?.sessions ?? []) { s in
                    EchoRow(selected: s.id == sessionID) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.meta.title).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 6) {
                                Text(EchoTime.short(s.endDate))
                                if computers.count > 1 { Text(s.computer) }
                                Spacer(minLength: 4)
                                Text(ByteCountFormatter.string(fromByteCount: s.size, countStyle: .file)).monospacedDigit()
                            }
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.vertical, 3)
                    } action: {
                        sessionID = s.id
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
    }
}

/// 列表行：悬停浅色圆角底，选中用强调色浅底
struct EchoRow<Content: View>: View {
    let selected: Bool
    @ViewBuilder let content: Content
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor.opacity(0.18) : hover ? Color.primary.opacity(0.06) : .clear)
            )
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture(perform: action)
    }
}

// MARK: - 右栏：对话

struct EchoConversation: View {
    let session: EchoSession
    @State private var loading = false
    @State private var failed: String?

    var body: some View {
        ZStack {
            EchoWebView(session: session, loading: $loading, failed: $failed)
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
    let session: EchoSession
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
        context.coordinator.show(session, loading: $loading, failed: $failed)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        let scheme = EchoScheme()
        weak var web: WKWebView?
        private var current: String?

        func show(_ s: EchoSession, loading: Binding<Bool>, failed: Binding<String?>) {
            let key = "\(s.id)|\(s.size)"
            guard key != current else { return }
            current = key
            loading.wrappedValue = true
            failed.wrappedValue = nil
            let local = s.computer == EchoPrefs.computerName
            Task.detached(priority: .userInitiated) {
                let r = Result { () -> Data in
                    var d = try EchoExport.export(s.url, computer: s.computer)
                    var meta = d["meta"] as! [String: Any]
                    meta["local"] = local
                    d["meta"] = meta
                    return try JSONSerialization.data(withJSONObject: d)
                }
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
