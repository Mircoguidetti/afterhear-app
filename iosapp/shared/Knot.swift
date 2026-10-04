import SwiftUI

/// The knot (docs/BRAIN.md § 19.12): our logo. A thread that rises, ties one loop and comes down.
/// Filled = you marked it; dashed = your model caught it; it draws itself when something is tied.
struct KnotShape: Shape {
    func path(in rect: CGRect) -> Path {
        // The logo: the thread rises, ties one open loop and comes down, no tails. Drawn in a 23 × 22 box.
        let sx = rect.width / 23, sy = rect.height / 22
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + (x - 16) * sx, y: rect.minY + y * sy) }
        var path = Path()
        path.move(to: p(18.6, 19.4))
        // A straight rise, bending only at the top (owner, 02/10: two soft curves read as a wobble).
        path.addLine(to: p(22.6, 6.8))
        path.addCurve(to: p(28, 2), control1: p(23.6, 3.65), control2: p(25.3, 2))
        path.addCurve(to: p(31.2, 15.8), control1: p(34.5, 2), control2: p(35.8, 13))
        path.addCurve(to: p(24.6, 12.8), control1: p(27, 18.3), control2: p(23.2, 15.8))
        path.addCurve(to: p(35, 15), control1: p(26, 10), control2: p(31.5, 10.6))
        path.addCurve(to: p(36.8, 18.6), control1: p(35.8, 16.2), control2: p(36.4, 17.4))
        return path
    }
}

/// The knot as a mark. `tied` animates the thread drawing itself into the knot.
struct KnotMark: View {
    var color: Color
    var model = false
    var tied: CGFloat = 1
    var lineWidth: CGFloat = 1.6

    var body: some View {
        KnotShape()
            .trim(from: 0, to: tied)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round,
                                              dash: model ? [2.4, 2.2] : []))
            .aspectRatio(23.0 / 22.0, contentMode: .fit)
    }
}

/// "Marked": the thread ties itself, holds, then fades. Plays every time `trigger` changes.
struct KnotTie: View {
    var color: Color
    var trigger: Int
    @State private var tied: CGFloat = 0
    @State private var shown = false

    var body: some View {
        KnotMark(color: color, tied: tied, lineWidth: 2.0)
            .shadow(color: color.opacity(0.8), radius: shown ? 6 : 0)
            .opacity(shown ? 1 : 0)
            .onChange(of: trigger) { _ in
                tied = 0
                shown = true
                withAnimation(.easeOut(duration: 0.35)) { tied = 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                    withAnimation(.easeIn(duration: 0.4)) { shown = false }
                }
            }
    }
}
