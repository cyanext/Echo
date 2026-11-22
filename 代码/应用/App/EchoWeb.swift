// 右栏的网页：对话（Web/index.html）和总览（Web/overview.html），都走 echo://app/ 取文件和数据。
import AppKit
import SwiftUI
import WebKit

extension WKWebView {
    /// 对话和总览共用：echo://app/ 取文件，网页发 window.webkit.messageHandlers.echo 给 Swift，加载前不闪白
    @MainActor static func echo(scheme: EchoScheme, handler: WKScriptMessageHandler) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(scheme, forURLScheme: "echo")
        cfg.userContentController.add(handler, name: "echo")
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.setValue(false, forKey: "drawsBackground")
        return w
    }
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
            if !s.meta.cwd.isEmpty { meta["cwd"] = s.meta.cwd }   // 挪过文件夹的，恢复命令用新文件夹
            d["meta"] = meta
            return d
        case .collection(let c, let m):
            return try EchoExport.exportCollection(m.map { ($0.url, $0.computer) }, id: c.id, title: c.title)
        }
    }
}

struct EchoConversation: View {
    let target: EchoTarget
    var at: Double?
    @State private var loading = false
    @State private var failed: String?

    var body: some View {
        ZStack {
            EchoWebView(target: target, at: at, loading: $loading, failed: $failed)
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
    var at: Double?
    @Binding var loading: Bool
    @Binding var failed: String?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let w = WKWebView.echo(scheme: context.coordinator.scheme, handler: context.coordinator)
        context.coordinator.web = w
        return w
    }

    func updateNSView(_ w: WKWebView, context: Context) {
        context.coordinator.show(target, at: at, loading: $loading, failed: $failed)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        let scheme = EchoScheme()
        weak var web: WKWebView?
        private var current: String?
        private var currentAt: Double?

        func show(_ t: EchoTarget, at: Double?, loading: Binding<Bool>, failed: Binding<String?>) {
            let key = t.key
            if key == current {
                // 同一个会话已经开着：只换跳转位置
                if let at, at != currentAt { currentAt = at; web?.evaluateJavaScript("window.echoJump && window.echoJump(\(Int(at)))") }
                return
            }
            currentAt = at
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
                        let jump = at.map { "&at=\(Int($0))" } ?? ""
                        self.web?.load(URLRequest(url: URL(string: "echo://app/index.html?s=\(token)\(jump)")!))
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

// MARK: - 总览

/// 总览：网页 Web/overview.html，数据是 EchoState.overview（echo://app/overview.json）；还没整理好时网页自己画灰块占位
struct EchoOverview: View {
    @EnvironmentObject var state: EchoState
    var body: some View {
        EchoOverviewWeb(data: state.overview)
    }
}

struct EchoOverviewWeb: NSViewRepresentable {
    let data: Data?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let w = WKWebView.echo(scheme: context.coordinator.scheme, handler: context.coordinator)
        context.coordinator.web = w
        context.coordinator.scheme.overview = data
        w.load(URLRequest(url: URL(string: "echo://app/overview.html")!))   // 先打开：没数据时网页画占位
        return w
    }

    func updateNSView(_ w: WKWebView, context: Context) {
        guard let data, data != context.coordinator.scheme.overview else { return }
        context.coordinator.scheme.overview = data
        w.evaluateJavaScript("window.echoReload && window.echoReload()")   // 数据到了或更新了：保留当前选的周，重新取数
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        let scheme = EchoScheme()
        weak var web: WKWebView?

        /// 网页里点了会话：{open: 会话 id}
        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let id = body["open"] as? String else { return }
            EchoState.shared.openAt = (body["at"] as? NSNumber)?.doubleValue
            EchoState.shared.openSessionID = id
        }
    }
}

/// echo://app/<文件>：页面文件取自 .app 的 Resources/Web，session.json 是当前会话整理好的数据，overview.json 是总览的数据
final class EchoScheme: NSObject, WKURLSchemeHandler {
    var sessions: [String: Data] = [:]
    var overview: Data?

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let name = url.lastPathComponent
        var body: Data?
        if name == "session.json" {
            let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "s" }?.value ?? ""
            body = sessions[token]
        } else if name == "overview.json" {
            body = overview ?? Data("{}".utf8)   // 还没整理好：空对象，网页画占位
        } else if let res = Bundle.main.resourceURL {
            body = try? Data(contentsOf: res.appendingPathComponent("Web").appendingPathComponent(name))
        }
        guard let body else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let types = ["html": "text/html", "css": "text/css", "js": "text/javascript", "json": "application/json", "svg": "image/svg+xml"]
        let mime = (types[url.pathExtension] ?? "application/octet-stream") + "; charset=utf-8"
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                        headerFields: ["Content-Type": mime, "Cache-Control": "no-store"])!)
        task.didReceive(body)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
