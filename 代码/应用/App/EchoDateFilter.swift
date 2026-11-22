// 左栏右上角的日期筛选：一级菜单是全部时间和最近几天，「按月份」悬停出二级的月份选择器（设计稿 设计/日期筛选/）。
// 筛选的值是一个字符串：空是全部时间，「d7」最近 7 天，「m2026-11」某个月；都按会话最后用过的时间算
import SwiftUI

enum EchoDateFilter {
    static let recent = ["", "d1", "d7", "d30", "d90"]

    /// 「今天」从今天 0 点起，「最近 7 天」含今天共 7 天；月份是那个月 1 号 0 点到下个月 1 号
    static func range(_ key: String) -> Range<Date>? {
        let cal = Calendar.current
        if key.hasPrefix("d"), let n = Int(key.dropFirst()), let from = cal.date(byAdding: .day, value: 1 - n, to: cal.startOfDay(for: Date())) {
            return from..<Date.distantFuture
        }
        if let (y, m) = month(key), let from = cal.date(from: DateComponents(year: y, month: m, day: 1)),
           let to = cal.date(byAdding: .month, value: 1, to: from) {
            return from..<to
        }
        return nil
    }

    static func monthKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: d)
        return monthKey(c.year ?? 0, c.month ?? 0)
    }
    static func monthKey(_ y: Int, _ m: Int) -> String { String(format: "m%04d-%02d", y, m) }

    static func month(_ key: String) -> (Int, Int)? {
        guard key.hasPrefix("m") else { return nil }
        let p = key.dropFirst().split(separator: "-").compactMap { Int($0) }
        return p.count == 2 ? (p[0], p[1]) : nil
    }

    /// 今年的月份写「11月」，往年的写「2025年12月」
    static func title(_ key: String) -> String {
        if key.isEmpty { return "全部时间" }
        if key == "d1" { return "今天" }
        if key.hasPrefix("d") { return "最近 \(key.dropFirst()) 天" }
        guard let (y, m) = month(key) else { return key }
        return y == Calendar.current.component(.year, from: Date()) ? "\(m)月" : "\(y)年\(m)月"
    }
}

/// 日期筛选菜单：样式照 EchoPickMenu（白底细框、圆角 10、一项 30 高，选中的文字主色加勾），不画图标栏。
/// 「按月份」悬停或点一下，右边贴着出月份选择器，顶边和这一行对齐；悬停一级的其他项时收起（和系统菜单一样）
struct EchoDateMenu: View {
    let selected: String
    let months: Set<String>                 // 有会话的月份（「m2026-11」）
    let pick: (String) -> Void
    @State private var hover: String?
    @State private var sub = ProcessInfo.processInfo.environment["ECHO_SHOT_SUB"] != nil   // 环境变量只给截图用：打开就展开月份选择器

    private let width: CGFloat = 160
    private let rowH: CGFloat = 30

    var body: some View {
        VStack(spacing: 0) {
            ForEach(EchoDateFilter.recent, id: \.self) { k in
                row(EchoDateFilter.title(k), on: k == selected, hovered: hover == k) {
                    if k == selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(EchoColor.accent) }
                }
                .onHover { if $0 { hover = k; sub = false } else if hover == k { hover = nil } }
                .onTapGesture { pick(k) }
            }
            Color.clear.frame(height: 4)
            let monthOn = selected.hasPrefix("m")
            row("按月份", on: monthOn, hovered: sub) {
                if monthOn { Text(EchoDateFilter.title(selected)).font(.system(size: 12)).foregroundStyle(EchoColor.accentText) }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(EchoColor.fg3)
            }
            .onHover { if $0 { hover = nil; sub = true } }
            .onTapGesture { sub.toggle() }
        }
        .padding(4)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 10).fill(EchoColor.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(EchoColor.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        .overlay(alignment: .topLeading) {
            // 顶边对齐「按月份」那行：菜单内边距 4、五项、空 4，再减去选择器自己的上内边距 4
            if sub { EchoMonthPicker(selected: selected, months: months, pick: pick).offset(x: width - 4, y: 4 + rowH * 5 + 4 - 4) }
        }
    }

    private func row<Trailing: View>(_ title: String, on: Bool, hovered: Bool, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 13, weight: on ? .medium : .regular)).lineLimit(1)
                .foregroundStyle(on ? EchoColor.accentText : EchoColor.fg)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 10).frame(height: rowH)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? EchoColor.onSideHover : .clear))
        .contentShape(Rectangle())
    }
}

/// 月份选择器：照通用的月份选择器（Ant Design、Element 的 month picker，macOS 日历的年视图）。
/// 头部年份居中、两边箭头切换年份；3 列 4 行 12 个月。没有会话和还没到的月份灰掉、点不了；本月主色字；选中的主色实心底
struct EchoMonthPicker: View {
    let selected: String
    let months: Set<String>
    let pick: (String) -> Void
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var hover: Int?

    private var thisYear: Int { Calendar.current.component(.year, from: Date()) }
    private var thisMonth: Int { Calendar.current.component(.month, from: Date()) }
    private var minYear: Int { months.compactMap { EchoDateFilter.month($0)?.0 }.min() ?? thisYear }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                arrow("chevron.left", enabled: year > minYear) { year -= 1 }
                Text("\(String(year)) 年").font(.system(size: 13, weight: .semibold)).foregroundStyle(EchoColor.fg)
                    .frame(maxWidth: .infinity)
                arrow("chevron.right", enabled: year < thisYear) { year += 1 }
            }
            .frame(height: 34)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 2) {
                ForEach(1...12, id: \.self) { m in cell(m) }
            }
        }
        .padding(.top, 4).padding(.horizontal, 6).padding(.bottom, 6)
        .frame(width: 204)
        .background(RoundedRectangle(cornerRadius: 10).fill(EchoColor.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(EchoColor.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        .onAppear { if let (y, _) = EchoDateFilter.month(selected) { year = y } }
    }

    private func cell(_ m: Int) -> some View {
        let key = EchoDateFilter.monthKey(year, m)
        let ok = months.contains(key) && (year < thisYear || m <= thisMonth)
        let on = key == selected
        let now = year == thisYear && m == thisMonth
        return Text("\(m)月").font(.system(size: 13, weight: on || now ? .medium : .regular)).monospacedDigit()
            .foregroundStyle(on ? EchoColor.onAccent : now ? EchoColor.accentText : ok ? EchoColor.fg : EchoColor.fg3)
            .opacity(ok || on ? 1 : 0.5)
            .frame(maxWidth: .infinity).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? EchoColor.accent : hover == m && ok ? EchoColor.onSideHover : .clear))
            .contentShape(Rectangle())
            .onHover { if $0 { hover = m } else if hover == m { hover = nil } }
            .onTapGesture { if ok { pick(key) } }
    }

    private func arrow(_ name: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Image(systemName: name).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(EchoColor.fg2).opacity(enabled ? 1 : 0.35)
            .frame(width: 26, height: 26).contentShape(Rectangle())
            .onTapGesture { if enabled { action() } }
    }
}
