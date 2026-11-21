// 线性图标：和对话页（Web/app.js 的 ICON）同一套画法，24 格画、线宽 1.8、圆角端点。
// 规范 需求文档/设计规范/设计规范.md「图标」：每一级目录收起是合上的文件夹、展开是打开的文件夹；会话是对话气泡。
import SwiftUI

struct EchoGlyph: Shape {
    enum Kind { case folder, folderOpen, chat, stack }
    let kind: Kind

    func path(in rect: CGRect) -> Path {
        let k = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * k, y: rect.minY + y * k) }
        var path = Path()
        switch kind {
        case .folder:
            // 合上的文件夹：左上角的标签加圆角的夹身
            path.move(to: p(5.5, 5.5))
            path.addLine(to: p(9.5, 5.5)); path.addLine(to: p(11.5, 7.5)); path.addLine(to: p(18.5, 7.5))
            path.addQuadCurve(to: p(20.5, 9.5), control: p(20.5, 7.5))
            path.addLine(to: p(20.5, 17.5))
            path.addQuadCurve(to: p(18.5, 19.5), control: p(20.5, 19.5))
            path.addLine(to: p(5.5, 19.5))
            path.addQuadCurve(to: p(3.5, 17.5), control: p(3.5, 19.5))
            path.addLine(to: p(3.5, 7.5))
            path.addQuadCurve(to: p(5.5, 5.5), control: p(3.5, 5.5))
            path.closeSubpath()
        case .folderOpen:
            // 打开的文件夹：后片加往右下斜着打开的前片
            path.move(to: p(3.5, 17.5))
            path.addLine(to: p(3.5, 7.5))
            path.addQuadCurve(to: p(5.5, 5.5), control: p(3.5, 5.5))
            path.addLine(to: p(9.5, 5.5)); path.addLine(to: p(11.5, 7.5)); path.addLine(to: p(17.5, 7.5))
            path.addQuadCurve(to: p(19.5, 9.5), control: p(19.5, 7.5))
            path.addLine(to: p(19.5, 10.5))
            path.move(to: p(3.5, 17.5))
            path.addLine(to: p(6.2, 11.4))
            path.addQuadCurve(to: p(7.6, 10.5), control: p(6.6, 10.5))
            path.addLine(to: p(20, 10.5))
            path.addQuadCurve(to: p(20.9, 11.9), control: p(21.3, 10.6))
            path.addLine(to: p(18.6, 18.3))
            path.addQuadCurve(to: p(16.8, 19.5), control: p(18.2, 19.5))
            path.addLine(to: p(5.4, 19.5))
            path.addQuadCurve(to: p(3.5, 17.5), control: p(3.5, 19.5))
        case .chat:
            // 对话气泡：圆角框，左下角拖一个尾巴
            path.move(to: p(5, 18.5))
            path.addLine(to: p(5, 7))
            path.addQuadCurve(to: p(7.5, 4.5), control: p(5, 4.5))
            path.addLine(to: p(16.5, 4.5))
            path.addQuadCurve(to: p(19, 7), control: p(19, 4.5))
            path.addLine(to: p(19, 13))
            path.addQuadCurve(to: p(16.5, 15.5), control: p(19, 15.5))
            path.addLine(to: p(9, 15.5))
            path.closeSubpath()
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
