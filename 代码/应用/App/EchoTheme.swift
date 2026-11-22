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
    static let side = dyn(0xedf0f0, 0x222627)
    static let sideOn = dyn(0xffffff, 0x34353b)
    static let sideFg = dyn(0x4b5468, 0xb4b9c5)
    static let sideLine = dyn(0xe1e6e6, 0x2d3233)
    static let surface = dyn(0xffffff, 0x1d1e23)
    static let fg = dyn(0x1f2329, 0xe6e8ec)
    static let fg2 = dyn(0x646a73, 0x9aa0ab)
    static let fg3 = dyn(0x8f959e, 0x6f7581)
    static let line = dyn(0xe3e5ec, 0x2c2e35)
    static let accent = dyn(0x008081, 0x3fc0c0)          // 回响主色青绿（11-21 定，和 NAS 的靛蓝分开）
    static let sel = dyn(0x008081, 0x3fc0c0, 0.10, 0.16)
    static let hover = dyn(0x1f2329, 0xffffff, 0.05, 0.06)
    static let sideHover = dyn(0xffffff, 0xffffff, 0.6, 0.06)      // 左栏行悬停：灰底上的半透明白，照 NAS 网站 --bg-side-hover
    static let onSideHover = dyn(0x1f2329, 0xffffff, 0.08, 0.08)   // 左栏里小按钮（目录展开箭头）的悬停，照 NAS 网站 --bg-on-side-hover
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
