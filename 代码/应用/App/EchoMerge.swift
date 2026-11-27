// 同一个会话在几台电脑上（同步到本机、交给另一台电脑之后两台的备份里都有）：按对话消息的 uuid 判关系，只显示一份。
// 一份包含另一份：只留多的那份（一样多时留本机的，再看谁最后用过），左栏写「在 <电脑> 上接着聊过」；
// 各有对方没有的（分叉）：都留，都写「分叉」。只在 iCloud 云端、还没下载的不比，先都显示。
// 扫列表（EchoLibrary.scan）最后做一遍，左栏、搜索、ech、总览拿到的都是归好组的
import Foundation

enum EchoMerge {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (EchoFileStamp, Set<String>)] = [:]

    /// 一个备份文件里对话消息的 uuid，按大小和修改时间缓存
    static func ids(_ url: URL) -> Set<String> {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let st = EchoFileStamp(size: Int64(v?.fileSize ?? 0), mtime: v?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        lock.lock(); let hit = cache[url.path]; lock.unlock()
        if let hit, hit.0 == st { return hit.1 }
        let s = EchoRestore.messageIDs(url)
        lock.lock(); cache[url.path] = (st, s); lock.unlock()
        return s
    }

    /// 归组：返回要显示的会话，几台电脑上都有的带上说明（merged）
    static func apply(_ sessions: [EchoSession], me: String = EchoPrefs.computerName, ids: (URL) -> Set<String> = { EchoMerge.ids($0) }) -> [EchoSession] {
        let groups = Dictionary(grouping: sessions.indices.filter { sessions[$0].app == .claude }) { sessions[$0].sessionId }
            .filter { Set($0.value.map { sessions[$0].computer }).count > 1 }
        guard !groups.isEmpty else { return sessions }
        var hide = Set<Int>(), note: [Int: String] = [:]
        for (_, idx) in groups {
            let known = idx.filter { !EchoCloud.isPlaceholder(sessions[$0].url.path) }
            guard known.count > 1 else { continue }
            // 先排好：对话多的在前；一样多时本机的在前，再按最后用过
            let sets = Dictionary(uniqueKeysWithValues: known.map { ($0, ids(sessions[$0].url)) })
            let order = known.sorted { a, b in
                if sets[a]!.count != sets[b]!.count { return sets[a]!.count > sets[b]!.count }
                let la = sessions[a].computer == me, lb = sessions[b].computer == me
                if la != lb { return la }
                return (sessions[a].endDate ?? .distantPast) > (sessions[b].endDate ?? .distantPast)
            }
            var kept: [Int] = []
            for i in order {
                if kept.contains(where: { sets[i]!.isSubset(of: sets[$0]!) }) { hide.insert(i) } else { kept.append(i) }
            }
            if kept.count > 1 {
                for i in kept { note[i] = "分叉" }
            } else if let k = kept.first, sessions[k].computer != me, known.contains(where: { sessions[$0].computer == me }) {
                note[k] = "在 \(sessions[k].computer) 上接着聊过"
            }
        }
        return sessions.indices.filter { !hide.contains($0) }.map { i in
            var s = sessions[i]
            s.merged = note[i]
            return s
        }
    }
}
