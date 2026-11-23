import SwiftUI

/// Штрих галочки. Координаты — доли размера относительно центра: короткое плечо слева,
/// вершина ниже центра, длинное плечо уходит вправо вверх.
struct CheckStroke: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let c = CGPoint(x: rect.midX, y: rect.midY)
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x + x * side, y: c.y + y * side) }
        var p = Path()
        p.move(to: pt(-0.21, 0.01))
        p.addLine(to: pt(-0.06, 0.16))
        p.addLine(to: pt(0.23, -0.14))
        return p
    }
}

/// Зубчатая «печать» со скруглёнными зубцами. Зубцов немного, выемки глубокие — форма читается сразу.
/// Путь начинается в верхней точке и идёт по часовой стрелке — trim прорисовывает контур по часовой.
struct SealShape: Shape {
    var points = 8
    var depth: CGFloat = 0.18   // глубина выемок относительно радиуса

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * (1 - depth)
        let n = points * 2
        func vertex(_ i: Int) -> CGPoint {
            // В координатах экрана (ось y вниз) рост угла — это движение по часовой стрелке
            let a = -Double.pi / 2 + Double(i) * 2 * .pi / Double(n)
            let r = i.isMultiple(of: 2) ? outer : inner
            return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
        }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }

        // Скругление: от середины ребра к середине следующего, вершина — контрольная точка кривой
        var p = Path()
        p.move(to: vertex(0))
        p.addQuadCurve(to: mid(vertex(0), vertex(1)), control: vertex(0))
        for i in 1...n {
            p.addQuadCurve(to: mid(vertex(i % n), vertex((i + 1) % n)), control: vertex(i % n))
        }
        p.addQuadCurve(to: vertex(0), control: vertex(0))
        return p
    }
}

/// Сектор от верхней точки по часовой стрелке на долю `progress` полного оборота — маска заливки.
struct SweepShape: Shape {
    var progress: Double

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = max(rect.width, rect.height)   // с запасом, чтобы сектор покрывал углы формы
        var p = Path()
        guard progress > 0 else { return p }
        p.move(to: c)
        p.addArc(center: c, radius: r, startAngle: .degrees(-90),
                 endAngle: .degrees(-90 + 360 * progress), clockwise: false)   // false — по часовой на экране
        p.closeSubpath()
        return p
    }
}

/// Галочка-«печать» в момент `t` (0…1) общей шкалы. Этапы перекрываются, поэтому переходы без пауз;
/// любой кадр можно отрисовать отдельно для проверки.
struct CheckmarkGraphic: View, Animatable {
    var size: CGFloat
    var t: Double

    var animatableData: Double {
        get { t }
        set { t = newValue }
    }

    /// Доля этапа [a, b] на шкале t, 0…1.
    private func phase(_ a: Double, _ b: Double) -> Double { min(1, max(0, (t - a) / (b - a))) }
    /// Smootherstep: плавный разгон и плавное торможение, без рывков на стыках этапов.
    private func smooth(_ x: Double) -> Double { x * x * x * (x * (x * 6 - 15) + 10) }

    var body: some View {
        let outline = smooth(phase(0.00, 0.45))   // 1. контур по часовой
        // 2. заливка по часовой, чуть позади контура. ×1.04 — замыкается до медленного хвоста кривой,
        //    иначе на последних градусах виден шов сверху и точка в центре
        let sweep = min(1, smooth(phase(0.12, 0.62)) * 1.04)
        let check = smooth(phase(0.55, 0.88))     // 3. прорисовка галочки
        let settle = phase(0.82, 1.00)            // 4. посадка: 1 → 1.04 → 1
        let pulse = 1 + 0.04 * sin(.pi * smooth(settle))
        let appear = smooth(phase(0.00, 0.20))    // мягкий вход всего знака
        let line = size * 0.055

        ZStack {
            SealShape()
                .fill(Color.green.gradient)
                .mask { if sweep < 1 { SweepShape(progress: sweep) } else { Rectangle() } }
            SealShape()
                .trim(from: 0, to: outline)
                .stroke(Color.green, style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
            CheckStroke()
                .trim(from: 0, to: check)
                .stroke(.white, style: StrokeStyle(lineWidth: size * 2.5 / 24, lineCap: .round, lineJoin: .round))
                .scaleEffect(0.85 + 0.15 * check)
                .opacity(min(1, check * 4))
        }
        .padding(line / 2)
        .scaleEffect((0.9 + 0.1 * appear) * pulse)
        .opacity(appear)
        .frame(width: size, height: size)
    }
}

/// Зелёная галочка успеха в зубчатой «печати»: контур по часовой, заливка по часовой, галочка, посадка.
struct AnimatedCheckmark: View {
    var size: CGFloat = 44
    static let duration = 1.2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start: Date?
    @State private var done = false

    var body: some View {
        // Свой таймер кадров вместо withAnimation: анимационная транзакция при появлении
        // цепляла и само окно-лист, и оно выезжало не так, как системное
        TimelineView(.animation(paused: reduceMotion || done)) { context in
            CheckmarkGraphic(size: size, t: progress(at: context.date))
        }
        .accessibilityLabel("Готово")
        .onAppear { if start == nil { start = Date() } }
        .task {
            // Останавливаем таймер кадров, когда анимация закончилась (последний кадр — t = 1)
            try? await Task.sleep(for: .seconds(Self.duration + 0.05))
            done = true
        }
    }

    /// Положение на общей шкале 0…1: время идёт равномерно, плавность задают кривые внутри фаз.
    private func progress(at date: Date) -> Double {
        if reduceMotion { return 1 }
        guard let start else { return 0 }
        return min(1, max(0, date.timeIntervalSince(start) / Self.duration))
    }
}
