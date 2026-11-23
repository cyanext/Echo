// 左栏右上角的日期筛选：快捷选项一项一行，下面「选择月份」（设计稿 设计/日期筛选/）。
// 筛选的值是一个字符串（键见 EchoDateFilter.range），空是全部时间；都按会话最后用过的时间算
import SwiftUI

enum EchoDateFilter {
    /// 快捷选项，一项一行
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

    static func title(_ key: String) -> String {
        if key.isEmpty { return "全部时间" }
        if key == "d1" { return "今天" }
        if key.hasPrefix("d") { return "最近 \(key.dropFirst()) 天" }
        if let (y, m) = month(key) { return "\(y)年\(m)月" }
        return key
    }

    /// 筛选按钮上写的：近 30 天、今天、全部时间、2026年10月（把近 30 天的文字显示出来）
    static func short(_ key: String) -> String {
        key.hasPrefix("d") && key != "d1" ? "近 \(key.dropFirst()) 天" : title(key)
    }

    /// 打开窗口时默认的：近 30 天
    static let initial = "d30"
}

/// 日期筛选面板：上面快捷选项竖着一项一行（和其他筛选菜单一样），下面「选择月份」输入框，点开在下面出月份选择器（输入框照伙伴云的日期筛选）。
/// 不要分隔线
struct EchoDateMenu: View {
    let selected: String
    let months: Set<String>                 // 有会话的月份（「m2026-11」）
    let pick: (String) -> Void
    @State private var hover: String?
    @State private var picker = ProcessInfo.processInfo.environment["ECHO_SHOT_SUB"] != nil   // 环境变量只给截图用：打开就展开月份选择器

    private let width: CGFloat = 200

    var body: some View {
        VStack(spacing: 0) {
            ForEach(EchoDateFilter.recent, id: \.self) { cell($0) }
            field.padding(.top, 4).padding(.horizontal, 4).padding(.bottom, 4)
            // 月份选择器挂在输入框下面 4，和输入框左对齐、一样宽：挂在输入框下沿一个 0 高的视图上，往下长
            Color.clear.frame(height: 0).overlay(alignment: .top) {
                if picker {
                    EchoMonthPicker(selected: selected, months: months, width: width - 16, pick: pick)
                        .fixedSize(horizontal: false, vertical: true).offset(y: 2)
                }
            }
        }
        .padding(4)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 10).fill(EchoColor.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(EchoColor.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }

    /// 一项一行，照其他筛选菜单（EchoPickMenu）：30 高，选中的文字主色、右边一个小勾
    private func cell(_ k: String) -> some View {
        let on = k == selected
        return HStack(spacing: 6) {
            Text(EchoDateFilter.title(k)).font(.system(size: 13, weight: on ? .medium : .regular)).lineLimit(1)
                .foregroundStyle(on ? EchoColor.accentText : EchoColor.fg)
            Spacer(minLength: 8)
            if on { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(EchoColor.accent) }
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover == k ? EchoColor.onSideHover : .clear))
        .contentShape(Rectangle())
        .onHover { if $0 { hover = k } else if hover == k { hover = nil } }
        .onTapGesture { pick(k) }
    }

    /// 选了月份时写「2026年10月」，没选时灰字「选择月份」；右边日历图标。点一下展开、收起月份选择器
    private var field: some View {
        let on = selected.hasPrefix("m")
        return HStack(spacing: 6) {
            Text(on ? EchoDateFilter.title(selected) : "选择月份").font(.system(size: 13, weight: on ? .medium : .regular))
                .foregroundStyle(on ? EchoColor.accentText : EchoColor.fg3)
            Spacer(minLength: 4)
            Image(systemName: "calendar").font(.system(size: 13)).foregroundStyle(on ? EchoColor.accent : EchoColor.fg2)
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(picker ? EchoColor.accent : EchoColor.line, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { picker.toggle() }
    }
}

/// 月份选择器：照通用的月份选择器（Ant Design、Element 的 month picker，macOS 日历的年视图）。
/// 头部年份居中、两边箭头切换年份；3 列 4 行 12 个月。没有会话和还没到的月份灰掉、点不了；本月主色字；选中的主色实心底
struct EchoMonthPicker: View {
    let selected: String
    let months: Set<String>
    var width: CGFloat = 204
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
        .frame(width: width)
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
