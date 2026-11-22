// 模型单价：内置 Web/prices.json，每周从 LiteLLM 的公开价格表（GitHub 上的 model_prices_and_context_window.json，不用密钥）拉一次，
// 只留用得到的几家（Claude、GPT、GLM、Kimi、混元），存在本机 ~/Library/Application Support/回响/价格.json；总览取价格时拿它覆盖内置的。
// 拉不到（断网、GitHub 连不上）就接着用上次拉到的或内置的。只发一个 GET 请求，不带任何本机信息。需求见 需求文档/版本需求/v0.8.0-多应用支持.html
import Foundation

enum EchoPrices {
    static let source = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    static var url: URL { EchoLibrary.supportDir.appendingPathComponent("价格.json") }
    /// 留下哪些模型：去掉 provider 前缀（zai/、moonshot/ 等）后以这些开头的
    static let prefixes = ["claude-", "gpt-", "glm-", "kimi-", "hy"]

    /// 内置的加上拉到的（拉到的优先），给网页的 prices.json
    static func merged() -> Data? {
        guard let res = Bundle.main.resourceURL?.appendingPathComponent("Web/prices.json"),
              var base = (try? JSONSerialization.jsonObject(with: Data(contentsOf: res))) as? [String: Any] else { return nil }
        if let fetched = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any],
           let m = fetched["models"] as? [String: Any] {
            var models = base["models"] as? [String: Any] ?? [:]
            models.merge(m) { _, new in new }
            base["models"] = models
            base["date"] = fetched["date"] ?? base["date"]
        }
        return try? JSONSerialization.data(withJSONObject: base)
    }

    /// LiteLLM 的表换成 [输入, 输出, 读缓存]（每百万 Token 美元）。键可能带 provider 前缀，同一个模型几家都有时取第一方的（键里没有 /，或 provider 是厂商自己）
    static func parse(_ data: Data) -> [String: [Double]] {
        guard let all = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        var out: [String: [Double]] = [:], firstParty: Set<String> = []
        let owners = ["anthropic", "openai", "zai", "moonshot", "tencent"]
        for (key, v) in all {
            guard let v = v as? [String: Any], let i = (v["input_cost_per_token"] as? NSNumber)?.doubleValue,
                  let o = (v["output_cost_per_token"] as? NSNumber)?.doubleValue else { continue }
            let parts = key.lowercased().split(separator: "/")
            let name = String(parts.last ?? "")
            guard prefixes.contains(where: { name.hasPrefix($0) }), !name.contains(":") else { continue }
            let first = parts.count == 1 || owners.contains(String(parts[0]))
            if out[name] != nil, !first || firstParty.contains(name) { continue }
            let c = (v["cache_read_input_token_cost"] as? NSNumber)?.doubleValue ?? i * 0.1
            out[name] = [i, o, c].map { ($0 * 1e6 * 1e4).rounded() / 1e4 }
            if first { firstParty.insert(name) }
        }
        return out
    }

    /// 超过 7 天没拉过就拉一次（后台）
    static func refreshIfDue() {
        if let d = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, Date().timeIntervalSince(d) < 7 * 86400 { return }
        var req = URLRequest(url: source, timeoutInterval: 30)
        req.setValue("Echo", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard let data, (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            let models = parse(data)
            guard models.count >= 10 else { return }   // 格式变了、拉到一半：不覆盖
            let out: [String: Any] = ["date": EchoTime.formatted(Date(), "yyyy-MM-dd"), "source": source.absoluteString, "models": models]
            if let d = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]) { try? d.write(to: url, options: .atomic) }
        }.resume()
    }
}
