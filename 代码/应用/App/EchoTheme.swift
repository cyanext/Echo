// 原生外框的公共部分：颜色、左栏的行、图标按钮、拖动把手、窗口拖动区、自绘图标。
// 颜色和网页的 base.css、设计规范「颜色」一致。
import AppKit
import SwiftUI

/// 颜色照伙伴云NAS应用的 RailColor，和设计稿 设计/浏览窗口/设计稿.css 一致
enum EchoColor {
    static func dyn(_ light: UInt32, _ dark: UInt32, _ la: CGFloat = 1, _ da: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            let isDark = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let v = isDark ? dark : light
            return NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: isDark ? da : la)
        })
    }
    // 颜色令牌：界面里只引用这些名字，不写色值；和网页的 Web/base.css、overview.css 同名同值
    static let side = dyn(0xf2f5f5, 0x222627)           // 左栏：纯色，浅色从 #edf0f0 提亮、压一点灰（渐变太丑，不要）
    static let sideOn = dyn(0xffffff, 0x34353b)
    static let sideFg = dyn(0x4b5468, 0xb4b9c5)
    static let sideLine = dyn(0xe1e6e6, 0x2d3233)
    static let surface = dyn(0xffffff, 0x1d1e23)
    static let fg = dyn(0x1f2329, 0xe6e8ec)
    static let fg2 = dyn(0x646a73, 0x9aa0ab)
    static let fg3 = dyn(0x8f959e, 0x6f7581)
    static let line = dyn(0xe3e5ec, 0x2c2e35)
    static let accent = dyn(0x00898a, 0x4ccaca)          // 回响主色青绿（11-21 定，和 NAS 的靛蓝分开；11-22 调亮一档，选 B）
    static let accentText = dyn(0x008081, 0x3fc0c0)      // 主色写字：深一档，浅色对白底 4.8:1（主色本身 3.8:1 偏淡），深色也收一点亮度
    static let sel = dyn(0x00898a, 0x4ccaca, 0.10, 0.16)
    static let hover = dyn(0x1f2329, 0xffffff, 0.05, 0.06)
    static let sideHover = dyn(0xffffff, 0xffffff, 0.6, 0.06)      // 左栏行悬停：灰底上的半透明白，照 NAS 网站 --bg-side-hover
    static let onSideHover = dyn(0x1f2329, 0xffffff, 0.08, 0.08)   // 左栏里小按钮（目录展开箭头）的悬停，照 NAS 网站 --bg-on-side-hover
    static let accentSoft = dyn(0x00898a, 0x4ccaca, 0.08, 0.14)
    static let onAccent = dyn(0xffffff, 0x10292a)                  // 主色实心底上的字：浅色白字，深色深字（和网页 --on-dark、--on-light 一样）
    static let chrome = dyn(0xf6f7f7, 0x232529)
    static let subtle = dyn(0xf2f4f4, 0x292e2f)
    // 主色由浅到深的色阶（深色模式反过来，q4 最亮），和网页 overview.css 的 --q1…--q4 一致；mute 两档灰
    static let q2 = dyn(0x64c3c3, 0x006d6d)
    static let q3 = dyn(0x009fa0, 0x009a9b)
    static let q4 = dyn(0x007677, 0x5ecbcb)
    static let mute = dyn(0xd3dbdb, 0x364042)
    static let mute2 = dyn(0xe6ebeb, 0x2c3536)
    static let good = dyn(0x12a150, 0x3ccf7e)
    static let warn = dyn(0xe08a00, 0xf0a63a)
}

/// 左栏右边缘的拖动条，照 NAS 网站 .ui-split：平时看不见，悬停或拖动时在右边缘显示 2 宽的竖线（上下各缩 20）；
/// 用 AppKit 视图做：左栏的滚动列表和对话网页都是原生视图，叠在上面的 SwiftUI 收不到悬停；光标用光标区域，不会被网页改掉。
/// 点按区是左栏最右边 10 宽。左栏宽 200 到 420，记在本机
struct EchoResizeHandle: NSViewRepresentable {
    @Binding var width: Double

    final class V: NSView {
        var width: Binding<Double>?
        private var start: (x: CGFloat, w: Double)?
        private var hover = false { didSet { needsDisplay = true } }
        static let line = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x3e / 255, green: 0x41 / 255, blue: 0x4a / 255, alpha: 1)
            : NSColor(srgbRed: 0xd5 / 255, green: 0xd8 / 255, blue: 0xde / 255, alpha: 1) }

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }   // 窗口不在前台时第一下就能拖
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
        override func mouseEntered(with e: NSEvent) { hover = true }
        override func mouseExited(with e: NSEvent) { hover = false }
        override func mouseDown(with e: NSEvent) { start = (e.locationInWindow.x, width?.wrappedValue ?? 0); needsDisplay = true }
        override func mouseDragged(with e: NSEvent) {
            guard let s = start else { return }
            width?.wrappedValue = min(420, max(200, s.w + Double(e.locationInWindow.x - s.x)))
        }
        override func mouseUp(with e: NSEvent) { start = nil; needsDisplay = true }
        override func draw(_ dirtyRect: NSRect) {
            guard hover || start != nil, bounds.height > 40 else { return }
            Self.line.setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.maxX - 2, y: 20, width: 2, height: bounds.height - 40), xRadius: 1, yRadius: 1).fill()
        }
    }

    func makeNSView(context: Context) -> V { V() }
    func updateNSView(_ v: V, context: Context) { v.width = $width }
}

/// 左栏的行：悬停半透明白圆角底（0.12 秒渐变），选中时由调用方给白底
struct EchoRow<Content: View>: View {
    var fill: Color?
    var shadow = false
    @ViewBuilder let content: Content
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        content
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(fill ?? (hover ? EchoColor.sideHover : .clear))
                    .shadow(color: .black.opacity(shadow ? 0.06 : 0), radius: 1, y: 1)
                    .animation(.easeOut(duration: 0.12), value: hover)
            )
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture(perform: action)
    }
}

struct EchoIconButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }
    private struct Styled: View {
        let configuration: Configuration
        @State private var hover = false
        var body: some View {
            configuration.label
                .foregroundStyle(hover ? EchoColor.fg : EchoColor.fg2)
                .background(RoundedRectangle(cornerRadius: 6).fill(hover || configuration.isPressed ? EchoColor.hover : .clear))
                .onHover { hover = $0 }
        }
    }
}

/// 目录展开按钮：照 NAS 网站目录树的 .tw，14 的箭头放在 22 见方的按钮里，悬停深色 8% 圆角底，展开时转 90° 朝下。
/// 排版上只占 12 宽（左右各收 5），不挤动后面的名字
struct EchoTwist: View {
    let open: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            EchoGlyph(kind: .chevron)
                .stroke(style: StrokeStyle(lineWidth: 2.2 * 14 / 24, lineCap: .round, lineJoin: .round))
                .frame(width: 14, height: 14)
                .rotationEffect(.degrees(open ? 90 : 0))
                .foregroundStyle(EchoColor.fg)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(hover ? EchoColor.onSideHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .animation(.easeOut(duration: 0.12), value: open)
        .padding(.horizontal, -5)
        .help(open ? "收起" : "展开")
    }
}

/// 拖窗口的区域：窗口没有标题栏，红绿灯那一行按住能拖，双击放大或还原（照伙伴云NAS应用 WindowDragArea）
struct EchoWindowDrag: NSViewRepresentable {
    final class V: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with e: NSEvent) {
            if e.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: e) }
        }
    }
    func makeNSView(context: Context) -> NSView { V() }
    func updateNSView(_ v: NSView, context: Context) {}
}

// MARK: - 线性图标

/// 和对话页（Web/app.js 的 ICON）同一套画法，24 格画、线宽 1.8、圆角端点，规范「图标」。目录展开箭头也在这里画（线宽 2.2，照 NAS 网站）
struct EchoGlyph: Shape {
    enum Kind { case stack, chevron }
    let kind: Kind

    func path(in rect: CGRect) -> Path {
        let k = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * k, y: rect.minY + y * k) }
        var path = Path()
        switch kind {
        case .stack:
            // 合集：两张叠着的卡片
            path.addRoundedRect(in: CGRect(origin: p(4.5, 8.5), size: CGSize(width: 13 * k, height: 11 * k)), cornerSize: CGSize(width: 2 * k, height: 2 * k))
            path.move(to: p(7.5, 5.5)); path.addLine(to: p(17.5, 5.5))
            path.addQuadCurve(to: p(19.5, 7.5), control: p(19.5, 5.5))
            path.addLine(to: p(19.5, 16.5))
        case .chevron:
            // 展开箭头：朝右，和 NAS 网站的 i-tri 一样（m10 8 4 4-4 4）
            path.move(to: p(10, 8)); path.addLine(to: p(14, 12)); path.addLine(to: p(10, 16))
        }
        return path
    }
}

/// 图标视图：按规范的大小和线宽画，颜色跟着前景色
struct EchoIcon: View {
    let kind: EchoGlyph.Kind
    var size: CGFloat = 16

    var body: some View {
        EchoGlyph(kind: kind)
            .stroke(style: StrokeStyle(lineWidth: 1.8 * size / 24 * 1.33, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

/// 左栏右上角的筛选按钮：一个图标加小箭头，悬停有底；筛着的时候图标用主色（设计稿 设计/多应用/）
struct EchoPickButton<Icon: View>: View {
    let on: Bool
    let help: String
    @ViewBuilder let icon: () -> Icon
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                icon()
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(on ? EchoColor.accent : EchoColor.fg2)
            .padding(.horizontal, 6).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(hover ? EchoColor.sideHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// 筛选菜单：白底细框、圆角 10、轻阴影；一项一行（图标栏 24 宽、名字），选中的文字用主色、右边一个小勾；没有分隔线
struct EchoPickMenu: View {
    let width: CGFloat
    let items: [(id: String, icon: AnyView, title: String)]
    let selected: String
    let pick: (String) -> Void
    @State private var hover: String?
    var body: some View {
        VStack(spacing: 0) {
            ForEach(items, id: \.id) { it in
                let on = it.id == selected
                HStack(spacing: 4) {
                    it.icon.font(.system(size: 13)).foregroundStyle(on ? EchoColor.accent : EchoColor.fg3).frame(width: 24, alignment: .leading)
                    Text(it.title).font(.system(size: 13, weight: on ? .medium : .regular)).lineLimit(1)
                        .foregroundStyle(on ? EchoColor.accentText : EchoColor.fg)
                    Spacer(minLength: 8)
                    if on { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(EchoColor.accent) }
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(hover == it.id ? EchoColor.onSideHover : .clear))
                .contentShape(Rectangle())
                .onHover { hover = $0 ? it.id : (hover == it.id ? nil : hover) }
                .onTapGesture { pick(it.id) }
            }
        }
        .padding(4)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 10).fill(EchoColor.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(EchoColor.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }
}

/// 应用的官方 logo：圆角方块，不画线框；WorkBuddy 整块绿底，缩到 86% 和另两家视觉一样大（设计规范「应用图标」）
struct EchoAppLogo: View {
    let app: EchoSource
    let image: NSImage
    let size: CGFloat
    var body: some View {
        Image(nsImage: image).resizable().frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            .scaleEffect(app == .workbuddy ? 0.86 : 1)
    }
}
