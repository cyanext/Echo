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
    static let good = dyn(0x12a150, 0x3ccf7e)
    static let warn = dyn(0xe08a00, 0xf0a63a)
}

/// 左栏右边缘的拖动把手：6 宽，悬停变左右箭头，拖了改左栏宽，220 到 420，记在本机
struct EchoResizeHandle: View {
    @Binding var width: Double
    @State private var start: Double?
    var body: some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { g in
                    if start == nil { start = width }
                    width = min(420, max(220, (start ?? width) + g.translation.width))
                }
                .onEnded { _ in start = nil })
            .offset(x: 3)
    }
}

/// 列表行：悬停浅色圆角底；选中时由调用方给底色
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
                    .fill(fill ?? (hover ? EchoColor.hover : .clear))
                    .shadow(color: .black.opacity(shadow ? 0.06 : 0), radius: 1, y: 1)
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

/// 和对话页（Web/app.js 的 ICON）同一套画法，24 格画、线宽 1.8、圆角端点，规范「图标」。目录树用系统的小三角（chevron.right），不在这里画
struct EchoGlyph: Shape {
    enum Kind { case stack }
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
