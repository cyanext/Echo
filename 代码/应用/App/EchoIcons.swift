// 线性图标：和对话页（Web/app.js 的 ICON）同一套画法，24 格画、线宽 1.8、圆角端点。
// 规范 需求文档/设计规范/设计规范.md「图标」。目录树用系统的小三角（chevron.right），不在这里画。
import SwiftUI

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
