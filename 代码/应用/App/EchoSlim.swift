// 瘦身：会话 jsonl 里的 base64 图片和文件换成占位，去掉三类请求记录，其余原样保留。
// 规则见立项方案（需求文档/归档/方案.md）第五节，行为以 代码/原型/slim.py 为准，tests/run.sh 拿原型现场生成的结果比对。
import Foundation

// MARK: - 按行读文件

enum EchoLines {
    /// 逐行回调，行内容含末尾的换行符（最后一行可能没有）。会话文件大到几百 MB，分块读，不整个读进内存。
    static func each(_ url: URL, _ body: (UnsafeBufferPointer<UInt8>) throws -> Void) throws {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var buf = [UInt8]()
        while let chunk = try fh.read(upToCount: 8 << 20), !chunk.isEmpty {
            buf.append(contentsOf: chunk)
            var start = 0
            try buf.withUnsafeBufferPointer { p in
                let base = p.baseAddress!
                while start < p.count, let nl = memchr(base + start, 0x0A, p.count - start) {
                    let end = base.distance(to: nl.assumingMemoryBound(to: UInt8.self)) + 1
                    try body(UnsafeBufferPointer(rebasing: p[start..<end]))
                    start = end
                }
            }
            buf.removeFirst(start)
        }
        if !buf.isEmpty { try buf.withUnsafeBufferPointer { try body($0) } }
    }

    /// 去掉行尾的换行符
    static func trim(_ line: UnsafeBufferPointer<UInt8>) -> UnsafeBufferPointer<UInt8> {
        var n = line.count
        while n > 0, line[n - 1] == 0x0A || line[n - 1] == 0x0D { n -= 1 }
        return UnsafeBufferPointer(rebasing: line[0..<n])
    }

    static func has(_ line: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        guard let base = line.baseAddress, line.count >= needle.count else { return false }
        return needle.withUnsafeBufferPointer { memmem(base, line.count, $0.baseAddress!, needle.count) != nil }
    }
}

// MARK: - 保留原文的 JSON

/// 键保持原顺序，字符串和数字存原始字节（含引号和转义）。改写一行时，没动的部分逐字节不变。
indirect enum RawJSON {
    case object([(key: [UInt8], value: RawJSON)])
    case array([RawJSON])
    case string([UInt8])
    case scalar([UInt8])

    static func parse(_ b: UnsafeBufferPointer<UInt8>) -> RawJSON? {
        var p = RawParser(b: b)
        guard let v = p.value() else { return nil }
        p.ws()
        return p.i == b.count ? v : nil
    }

    func write(to out: inout [UInt8]) {
        switch self {
        case .string(let s), .scalar(let s): out.append(contentsOf: s)
        case .array(let a):
            out.append(UInt8(ascii: "["))
            for (n, v) in a.enumerated() {
                if n > 0 { out.append(UInt8(ascii: ",")) }
                v.write(to: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let o):
            out.append(UInt8(ascii: "{"))
            for (n, kv) in o.enumerated() {
                if n > 0 { out.append(UInt8(ascii: ",")) }
                out.append(contentsOf: kv.key)
                out.append(UInt8(ascii: ":"))
                kv.value.write(to: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    subscript(key: [UInt8]) -> RawJSON? {
        guard case .object(let o) = self else { return nil }
        return o.last(where: { $0.key == key })?.value   // 键重复时和 Python json.loads 一样取最后一个
    }

    var stringRaw: [UInt8]? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// 带引号的 JSON 字符串原文，只用于不含引号和反斜杠的固定文字
    static func quoted(_ s: String) -> [UInt8] { Array("\"\(s)\"".utf8) }
}

private struct RawParser {
    let b: UnsafeBufferPointer<UInt8>
    var i = 0

    mutating func ws() {
        while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
    }

    mutating func value() -> RawJSON? {
        ws()
        guard i < b.count else { return nil }
        switch b[i] {
        case UInt8(ascii: "{"):
            i += 1
            var items: [(key: [UInt8], value: RawJSON)] = []
            ws()
            if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .object(items) }
            while true {
                ws()
                guard let k = string() else { return nil }
                ws()
                guard i < b.count, b[i] == UInt8(ascii: ":") else { return nil }
                i += 1
                guard let v = value() else { return nil }
                items.append((k, v))
                ws()
                guard i < b.count else { return nil }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "}") { i += 1; return .object(items) }
                return nil
            }
        case UInt8(ascii: "["):
            i += 1
            var items: [RawJSON] = []
            ws()
            if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                guard let v = value() else { return nil }
                items.append(v)
                ws()
                guard i < b.count else { return nil }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                return nil
            }
        case UInt8(ascii: "\""):
            return string().map { .string($0) }
        default:
            let s = i
            while i < b.count {
                let c = b[i]
                if c == UInt8(ascii: ",") || c == UInt8(ascii: "}") || c == UInt8(ascii: "]") || c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 { break }
                i += 1
            }
            return i > s ? .scalar(Array(b[s..<i])) : nil
        }
    }

    mutating func string() -> [UInt8]? {
        guard i < b.count, b[i] == UInt8(ascii: "\"") else { return nil }
        let s = i
        i += 1
        while i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "\\") { i += 2; continue }
            if c == UInt8(ascii: "\"") { i += 1; return Array(b[s..<i]) }
            i += 1
        }
        return nil
    }
}

// MARK: - 瘦身

enum EchoSlim {
    struct Stats: Equatable {
        var bytesIn = 0, bytesOut = 0, removed = 0, droppedLines = 0, changedLines = 0
    }

    private static let kType = RawJSON.quoted("type"), kSource = RawJSON.quoted("source"), kData = RawJSON.quoted("data")
    private static let kBase64 = RawJSON.quoted("base64"), kSlimmed = RawJSON.quoted("slimmed"), kText = RawJSON.quoted("text")
    private static let vImage = RawJSON.quoted("image"), vDocument = RawJSON.quoted("document"), vText = RawJSON.quoted("text")
    /// 请求记录：请求参数、哈希和对话的重复副本，浏览和恢复都用不到
    static let dropTypes: Set<[UInt8]> = Set(["api-request", "api-request-blob", "api-request-shape"].map(RawJSON.quoted))
    private static let needleBase64 = Array("\"base64\"".utf8), needleRequest = Array("\"api-request".utf8)

    /// 递归处理，返回新节点和移除的字节数
    static func slim(_ node: RawJSON) -> (RawJSON, Int) {
        switch node {
        case .object(let items):
            // 规则 1：内容块里的 base64 图片或文档，整块换成文字块
            if let t = node[kType]?.stringRaw, t == vImage || t == vDocument,
               let src = node[kSource], src[kType]?.stringRaw == kBase64 {
                let removed = max(0, (src[kData]?.stringRaw?.count ?? 2) - 2)
                let label = t == vImage ? "[图片已移除]" : "[文件已移除]"
                return (.object([(kType, .string(vText)), (kText, .string(RawJSON.quoted(label)))]), removed)
            }
            var out: [(key: [UInt8], value: RawJSON)] = []
            func set(_ k: [UInt8], _ v: RawJSON) {
                if let n = out.firstIndex(where: { $0.key == k }) { out[n].value = v } else { out.append((k, v)) }
            }
            var removed = 0
            for (k, v) in items {
                // 规则 2：任意位置名为 base64 的长字符串清空，保留文件路径、尺寸等其他字段
                if k == kBase64, let s = v.stringRaw, s.count - 2 > 1000 {
                    removed += s.count - 2
                    set(k, .string(RawJSON.quoted("")))
                    set(kSlimmed, .scalar(Array("true".utf8)))
                    continue
                }
                let (nv, r) = slim(v)
                set(k, nv)
                removed += r
            }
            return (.object(out), removed)
        case .array(let a):
            var removed = 0
            let out = a.map { v -> RawJSON in
                let (nv, r) = slim(v)
                removed += r
                return nv
            }
            return (.array(out), removed)
        default:
            return (node, 0)
        }
    }

    /// 处理一行（含换行符），结果追加到 out
    static func slimLine(_ line: UnsafeBufferPointer<UInt8>, into out: inout [UInt8], stats: inout Stats) {
        stats.bytesIn += line.count
        let body = EchoLines.trim(line)
        if EchoLines.has(body, needleRequest), let j = RawJSON.parse(body), let t = j[kType]?.stringRaw, dropTypes.contains(t) {
            stats.droppedLines += 1
            return
        }
        // 不含 base64 的行、解析失败的行（写到一半的最后一行）原样写出
        guard EchoLines.has(body, needleBase64), let j = RawJSON.parse(body) else {
            out.append(contentsOf: line)
            stats.bytesOut += line.count
            return
        }
        let (n, r) = slim(j)
        let before = out.count
        n.write(to: &out)
        out.append(0x0A)
        stats.bytesOut += out.count - before
        stats.removed += r
        if r > 0 { stats.changedLines += 1 }
    }

    /// 瘦身整个文件，写到 dst（调用方负责先写临时文件再改名）
    @discardableResult
    static func slimFile(_ src: URL, to dst: URL) throws -> Stats {
        guard FileManager.default.createFile(atPath: dst.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: dst.path])
        }
        let fout = try FileHandle(forWritingTo: dst)
        defer { try? fout.close() }
        var stats = Stats()
        var out = [UInt8]()
        out.reserveCapacity(9 << 20)
        try EchoLines.each(src) { line in
            slimLine(line, into: &out, stats: &stats)
            if out.count >= 8 << 20 {
                try fout.write(contentsOf: out)
                out.removeAll(keepingCapacity: true)
            }
        }
        try fout.write(contentsOf: out)
        try fout.synchronize()
        return stats
    }
}
