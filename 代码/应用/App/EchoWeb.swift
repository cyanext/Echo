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

    /// 哪个会话（合集）：内容变了 key 跟着变，id 不变
    var id: String {
        switch self {
        case .session(let s): return s.id
        case .collection(let c, _): return c.id
        }
    }

    /// 内容变了（会话又写了、合集成员变了、改了名）才重新整理
    var key: String {
        switch self {
        case .session(let s):
            // 读原会话时，原会话又写了也要重新整理
            let o = EchoRename.originalURL(for: s).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? -1
            return "\(s.id)|\(s.size)|\(o)"
        case .collection(let c, let m): return "\(c.id)|\(c.title)|" + m.map { "\($0.id):\($0.size)" }.joined(separator: ",")
        }
    }

    func load() throws -> [String: Any] {
        switch self {
        case .session(let s):
            // 本机会话、原文件还在：从原会话整理，备份里不存的思考过程也看得到；原会话删了才读备份
            var d = try EchoExport.export(EchoRename.originalURL(for: s) ?? s.url, computer: s.computer)
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
    var q: String? = nil          // 从搜索结果进来：在 at 那一处查找这个词
    var ver: String? = nil        // 从总览点版本号进来：先按版本号找要点
    var seq = 0                   // 同一处再点一次也跳
    @State private var loading = false
    @State private var failed: String?

    var body: some View {
        ZStack {
            EchoWebView(target: target, at: at, q: q, ver: ver, seq: seq, loading: $loading, failed: $failed)
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
    var q: String?
    var ver: String?
    var seq: Int
    @Binding var loading: Bool
    @Binding var failed: String?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let w = WKWebView.echo(scheme: context.coordinator.scheme, handler: context.coordinator)
        context.coordinator.web = w
        return w
    }

    func updateNSView(_ w: WKWebView, context: Context) {
        context.coordinator.show(target, at: at, q: q, ver: ver, seq: seq, loading: $loading, failed: $failed)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        let scheme = EchoScheme()
        weak var web: WKWebView?
        private var current: String?
        private var currentID: String?
        private var currentAt: Double?
        private var currentSeq = 0
        private var waiting: String?   // 正在整理、还没打开的会话（key）

        func show(_ t: EchoTarget, at: Double?, q: String?, ver: String?, seq: Int, loading: Binding<Bool>, failed: Binding<String?>) {
            let key = t.key
            if key == current {
                // 同一个会话已经开着：只换跳转位置；搜索结果进来的在那一处查找关键词
                if let q, seq != currentSeq {
                    currentSeq = seq; currentAt = at
                    let arg = (try? JSONSerialization.data(withJSONObject: [q], options: .fragmentsAllowed)).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
                    web?.evaluateJavaScript("window.echoFind && window.echoFind(\(arg)[0], \(at.map { String(Int($0)) } ?? "0"))")
                } else if q == nil, let at, at != currentAt {
                    currentAt = at
                    web?.evaluateJavaScript("window.echoJump && window.echoJump(\(Int(at)), \(Self.js(ver ?? "")))")
                } else if q == nil, at == nil, seq != currentSeq {
                    currentSeq = seq; currentAt = nil
                    web?.evaluateJavaScript("window.echoEnd && window.echoEnd()")
                }
                return
            }
            // 同一个会话又写了（正在进行的会话）：重新整理后停在原来读到的地方、留着页面里的查找词，不再跳回搜索命中或总览点进来的那一处
            let same = t.id == currentID && seq == currentSeq && at == currentAt && web != nil
            currentAt = at
            currentSeq = seq
            current = key
            currentID = t.id
            failed.wrappedValue = nil
            if !same {
                loading.wrappedValue = true
                // 整理超过 0.15 秒（长会话）才先打开灰块占位，短的直接换，不闪一下
                waiting = key
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self, self.waiting == key else { return }
                    self.web?.load(URLRequest(url: URL(string: "echo://app/index.html?skel=1")!))
                }
            }
            load(t, key: key, keep: same, jump: Self.jump(at, q, ver), loading: loading, failed: failed)
        }

        static func jump(_ at: Double?, _ q: String?, _ ver: String?) -> String {
            var jump = at.map { "&at=\(Int($0))" } ?? ""
            if let q, let e = q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { jump += "&q=" + e }
            if let ver, let e = ver.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { jump += "&v=" + e }
            return jump
        }

        private func load(_ t: EchoTarget, key: String, keep: Bool, jump: String, loading: Binding<Bool>, failed: Binding<String?>) {
            Task.detached(priority: .userInitiated) {
                let r = Result { () -> Data in
                    if let d = Self.cached(key) { return d }
                    let d = try JSONSerialization.data(withJSONObject: t.load())
                    Self.remember(key, d)
                    return d
                }
                await MainActor.run {
                    guard self.current == key else { return }   // 整理期间又点了别的会话
                    loading.wrappedValue = false
                    self.waiting = nil
                    switch r {
                    case .success(let data):
                        if keep { self.swapKeeping(data, key: key, fallback: jump) } else { self.open(data, jump) }
                    case .failure(let e):
                        failed.wrappedValue = e.localizedDescription
                        self.web?.loadHTMLString("", baseURL: nil)   // 换掉占位，只留出错说明
                    }
                }
            }
        }

        // 最近打开过的几个会话整理好的数据留在内存里，来回切换时不用再读一遍（key 带着文件状态，会话又写了就换新的）
        nonisolated(unsafe) private static var recent: [(String, Data)] = []
        nonisolated private static let lock = NSLock()
        nonisolated static func cached(_ key: String) -> Data? {
            lock.lock(); defer { lock.unlock() }
            return recent.first { $0.0 == key }?.1
        }
        nonisolated static func remember(_ key: String, _ d: Data) {
            lock.lock(); defer { lock.unlock() }
            recent.removeAll { $0.0 == key }
            recent.insert((key, d), at: 0)
            if recent.count > 6 { recent.removeLast() }
        }

        private func open(_ data: Data, _ jump: String) {
            let token = UUID().uuidString
            scheme.sessions = [token: data]
            web?.load(URLRequest(url: URL(string: "echo://app/index.html?s=\(token)\(jump)")!))
        }

        /// 同一个会话又写了：新内容整理好以后，在换页前一刻问网页读到哪（echoKeep），新页面停回原处。
        /// 用户正在滚动时网页回答 busy，半秒后再问，免得换页时丢掉这期间滚过的距离；网页还没加载好时用原来的跳转
        private func swapKeeping(_ data: Data, key: String, fallback: String) {
            web?.evaluateJavaScript("window.echoKeep ? window.echoKeep() : ''") { r, _ in
                guard self.current == key else { return }
                let keep = r as? String ?? ""
                if keep == "busy" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.swapKeeping(data, key: key, fallback: fallback) }
                    return
                }
                self.open(data, keep.isEmpty ? fallback : keep)
            }
        }

        /// 字符串写成 JS 字面量
        static func js(_ s: String) -> String {
            (try? JSONSerialization.data(withJSONObject: [s])).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
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

        /// 网页里点了会话：{open: 会话 id}；点了已删除会话的「删统计」：{forget: 电脑/会话 ID}
        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if let f = body["forget"] as? String { EchoState.shared.forgetStats(f); return }
            guard let id = body["open"] as? String else { return }
            EchoState.shared.openAt = (body["at"] as? NSNumber)?.doubleValue
            EchoState.shared.openVer = (body["ver"] as? String).flatMap { $0.isEmpty ? nil : $0 }
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
        } else if name == "prices.json" {
            body = EchoPrices.merged()          // 内置的加上每周拉到的
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
