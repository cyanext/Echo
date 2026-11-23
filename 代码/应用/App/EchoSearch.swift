// 左栏的搜索：会话名和对话都找。对话用 ech 的同一份索引（EchoIndex.search），只找我说的、阶段总结、AI 回的。
// 先后：会话名 > 我说的 > 总结 > AI。会话名命中的排最前；其余会话按它最靠前的那处排，同一类按时间从近到远。
// 结果按会话分组，每个会话先列 3 处，点一处打开会话、跳到那里并高亮关键词。
import SwiftUI

struct EchoSearchGroup: Identifiable {
    let session: EchoSession
    var hits: [EchoIndex.Hit]
    var titleHit = false               // 会话名里有关键词
    var id: String { session.id }
}

@MainActor final class EchoSearchModel: ObservableObject {
    @Published var groups: [EchoSearchGroup] = []
    @Published var total = 0
    @Published var capped = false          // 命中数到了上限，只列了最近的这些
    @Published var running = false
    @Published var note: String?           // 没法搜时的说明：字太少、还没建索引
    @Published var updated: Date?          // 索引更新时间：今天刚聊的要等下一次备份
    private var task: Task<Void, Never>?
    nonisolated static let limit = 300
    nonisolated static let roles = ["我", "总结", "AI"]   // 先后：我说的 > 总结 > AI

    /// 输入停 0.25 秒再查；sessions 是左栏按电脑、应用、日期筛过的会话，结果只列这些
    func run(_ query: String, in sessions: [EchoSession]) {
        task?.cancel()
        let q = query.trimmed
        guard q.count >= 2 else {
            groups = []; total = 0; capped = false; running = false
            note = q.isEmpty ? nil : "至少输入 2 个字"
            return
        }
        running = true
        let byPath = Dictionary(sessions.map { ($0.url.standardizedFileURL.path, $0) }, uniquingKeysWith: { a, _ in a })
        let titled = sessions.filter { $0.meta.title != $0.sessionId && Self.matches($0.meta.title, q) }
            .sorted { ($0.endDate ?? .distantPast) > ($1.endDate ?? .distantPast) }
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            let r = await Task.detached(priority: .userInitiated) { () -> Result<([EchoIndex.Hit], Date?), Error> in
                Result {
                    guard FileManager.default.fileExists(atPath: EchoIndex.url.path) else { throw EchoSearchError.noIndex }
                    let db = try EchoIndex.open(readonly: true)
                    return (try EchoIndex.search(db, q, limit: EchoSearchModel.limit, roles: EchoSearchModel.roles, byRole: true), EchoIndex.updated(db))
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.running = false
            switch r {
            case .success(let (hits, updated)):
                self.groups = Self.rank(titled: titled, hits: hits, byPath: byPath)
                self.total = self.groups.reduce(0) { $0 + $1.hits.count }
                self.capped = hits.count == EchoSearchModel.limit
                self.updated = updated
                self.note = nil
            case .failure(let e):
                // 对话搜不了时会话名照样能搜
                self.groups = Self.rank(titled: titled, hits: [], byPath: byPath); self.total = 0
                self.note = (e as? EchoSearchError) == .noIndex ? "索引还没建好，备份完成后就能搜对话" : "搜索对话失败：\(e.localizedDescription)"
            }
        }
    }

    /// 会话名里几个词都有
    nonisolated static func matches(_ title: String, _ q: String) -> Bool {
        let t = EchoIndex.terms(q)
        return !t.isEmpty && t.allSatisfy { title.range(of: $0, options: .caseInsensitive) != nil }
    }

    /// 分组排先后：会话名命中的在前（按最后使用时间）；其余按它第一处命中出现的先后，hits 已经按「我 > 总结 > AI、同类从近到远」排好
    nonisolated static func rank(titled: [EchoSession], hits: [EchoIndex.Hit], byPath: [String: EchoSession]) -> [EchoSearchGroup] {
        var order: [String] = [], map: [String: EchoSearchGroup] = [:]
        for s in titled { order.append(s.id); map[s.id] = EchoSearchGroup(session: s, hits: [], titleHit: true) }
        for h in hits {
            guard let s = byPath[URL(fileURLWithPath: h.path).standardizedFileURL.path] else { continue }
            if map[s.id] == nil { order.append(s.id); map[s.id] = EchoSearchGroup(session: s, hits: []) }
            map[s.id]!.hits.append(h)
        }
        return order.map { map[$0]! }
    }

    /// 关键词附近的一截：前面留 12 个字，后面接着写，左栏两行放得下关键词
    nonisolated static func cut(_ text: String, around q: String) -> String {
        // 去掉 Markdown 的加粗、代码符号、表格竖线和标题井号，空白合成一个
        let plain = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "|", with: " ").replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "#{1,6} ", with: "", options: .regularExpression)
        let flat = plain.split(whereSeparator: { $0 == "\n" || $0 == " " || $0 == "\t" }).joined(separator: " ")
        guard let r = flat.range(of: q, options: .caseInsensitive) else { return String(flat.prefix(90)) }
        let s = flat.index(r.lowerBound, offsetBy: -12, limitedBy: flat.startIndex) ?? flat.startIndex
        let e = flat.index(r.upperBound, offsetBy: 80, limitedBy: flat.endIndex) ?? flat.endIndex
        return (s > flat.startIndex ? "…" : "") + flat[s..<e] + (e < flat.endIndex ? "…" : "")
    }

    /// 几个词都用主色文字标出来（会话名 13 号，摘句 12 号）
    nonisolated static func marked(_ text: String, _ q: String, size: CGFloat = 12) -> AttributedString {
        var a = AttributedString(text)
        // 整句出现时标整句；否则逐个词标，单个字不标（「B」会标出一堆不相干的字母）
        let whole = text.range(of: q, options: .caseInsensitive) != nil
        for t in whole ? [q] : EchoIndex.terms(q).filter({ $0.count >= 2 }) {
            var from = a.startIndex
            while from < a.endIndex, let r = a[from...].range(of: t, options: .caseInsensitive) {
                a[r].foregroundColor = EchoColor.accentText
                a[r].font = .system(size: size, weight: .semibold)
                from = r.upperBound
            }
        }
        return a
    }
}

enum EchoSearchError: Error { case noIndex }

/// 左栏顶上的搜索框：高 30，淡底无边框，聚焦时一圈主色（设计规范「搜索框」）
struct EchoSearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var submit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(EchoColor.fg3)
            TextField("", text: $text, prompt: Text("搜索全部会话").foregroundColor(EchoColor.fg3))
                .textFieldStyle(.plain).font(.system(size: 13))
                .focused(focused)
                .onSubmit(submit)
                .onExitCommand { if text.isEmpty { focused.wrappedValue = false } else { text = "" } }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(EchoColor.fg3)
                }
                .buttonStyle(.plain).help("清空")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(EchoColor.hover))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(EchoColor.accent, lineWidth: focused.wrappedValue ? 1.5 : 0))
        .help("搜索全部会话（⌥⌘F）")
    }
}
