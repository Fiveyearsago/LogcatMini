import SwiftUI

enum DutyCatMood { case curious, detective, tangled, sleepy }

/// Resolution-independent artwork. The timeline only exists while the cat is visible.
struct DutyCatIllustration: View {
    let petted: Bool
    let reduceMotion: Bool
    var mood: DutyCatMood = .curious
    var inBox = false
    @State private var started = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSince(started)
            Canvas { context, size in
                var drawing = context
                drawing.scaleBy(x: size.width / 200, y: size.height / 160)
                CatArtwork.draw(in: drawing, time: time, happy: petted, mood: mood, inBox: inBox)
            }
        }
        .accessibilityHidden(true)
    }
}

struct DutyCatPaws: View {
    var body: some View {
        Canvas { context, size in
            // Same 200-point canvas and shoulder positions as the illustration above.
            var paws = context
            paws.scaleBy(x: size.width / 200, y: size.width / 200)
            for left in [true, false] {
                let origin = left ? 62.0 : 116.0
                let paw = Path(roundedRect: CGRect(x: origin, y: 1, width: 31, height: 24), cornerRadius: 12)
                paws.fill(paw, with: .linearGradient(Gradient(colors: [CatArtwork.cream, CatArtwork.honey]), startPoint: .zero, endPoint: CGPoint(x: 0, y: 30)))
                paws.stroke(paw, with: .color(CatArtwork.outline.opacity(0.36)), lineWidth: 0.8)
                for x in [origin + 11, origin + 21] {
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 16))
                    line.addQuadCurve(to: CGPoint(x: x + 0.5, y: 22), control: CGPoint(x: x - 1, y: 19))
                    paws.stroke(line, with: .color(CatArtwork.outline.opacity(0.45)), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
                }
            }
        }
    }
}

private enum CatArtwork {
    static let cream = Color(red: 1, green: 0.94, blue: 0.80)
    static let honey = Color(red: 0.90, green: 0.73, blue: 0.50)
    static let outline = Color(red: 0.49, green: 0.34, blue: 0.23)
    static let ginger = Color(red: 0.76, green: 0.49, blue: 0.27)
    static let pink = Color(red: 0.91, green: 0.61, blue: 0.56)
    static let ink = Color(red: 0.22, green: 0.21, blue: 0.20)
    static let teal = Color(red: 0.27, green: 0.53, blue: 0.48)

    static func draw(in context: GraphicsContext, time: Double, happy: Bool, mood: DutyCatMood, inBox: Bool) {
        let breathing = sin(time * 1.8) * 1.2
        // The tail and ears use different slow rhythms so the pose never feels mechanical.
        var tail = Path()
        tail.move(to: CGPoint(x: 142, y: 151))
        tail.addCurve(to: CGPoint(x: 179, y: 107 + sin(time * 1.6) * 7),
                      control1: CGPoint(x: 194, y: 156), control2: CGPoint(x: 196, y: 119))
        context.stroke(tail, with: .color(outline.opacity(0.3)), style: StrokeStyle(lineWidth: 15, lineCap: .round))
        context.stroke(tail, with: .linearGradient(Gradient(colors: [honey, cream]), startPoint: CGPoint(x: 145, y: 150), endPoint: CGPoint(x: 182, y: 100)), style: StrokeStyle(lineWidth: 13, lineCap: .round))
        var tailTip = Path()
        tailTip.move(to: CGPoint(x: 185, y: 119 + sin(time * 1.6) * 4))
        tailTip.addQuadCurve(to: CGPoint(x: 179, y: 107 + sin(time * 1.6) * 7), control: CGPoint(x: 191, y: 112))
        context.stroke(tailTip, with: .color(ginger.opacity(0.7)), style: StrokeStyle(lineWidth: 12, lineCap: .round))

        let body = Path(ellipseIn: CGRect(x: 63, y: 105 + breathing, width: 88, height: 75))
        context.fill(body, with: .linearGradient(Gradient(colors: [cream, honey]), startPoint: CGPoint(x: 78, y: 105), endPoint: CGPoint(x: 144, y: 181)))
        context.stroke(body, with: .color(outline.opacity(0.32)), lineWidth: 1)
        ellipse(in: context, rect: CGRect(x: 81, y: 128 + breathing, width: 51, height: 47), color: cream.opacity(0.75))
        for x in [64.0, 118.0] {
            let leg = Path(roundedRect: CGRect(x: x, y: 134, width: 27, height: 38), cornerRadius: 13)
            context.fill(leg, with: .linearGradient(Gradient(colors: [cream, honey]), startPoint: CGPoint(x: x, y: 134), endPoint: CGPoint(x: x + 20, y: 176)))
            context.stroke(leg, with: .color(outline.opacity(0.18)), lineWidth: 0.8)
        }

        var head = context
        head.translateBy(x: 104, y: 116 + breathing)
        head.rotate(by: .degrees(happy ? -5 : mood == .sleepy ? 3 : sin(time * 0.85) * 2))
        head.translateBy(x: -104, y: -116)
        ears(in: head, time: time)
        face(in: head, time: time, happy: happy, sleepy: mood == .sleepy)
        scarf(in: head)
        var accessoryContext = context
        // Keep the ball above the opened flap instead of losing it behind the box.
        if inBox && mood == .tangled { accessoryContext.translateBy(x: -2, y: -35) }
        accessory(in: accessoryContext, time: time, mood: mood)

        if happy {
            var heart = Path()
            heart.move(to: CGPoint(x: 174, y: 53))
            heart.addCurve(to: CGPoint(x: 166, y: 40), control1: CGPoint(x: 160, y: 46), control2: CGPoint(x: 161, y: 39))
            heart.addQuadCurve(to: CGPoint(x: 174, y: 43), control: CGPoint(x: 171, y: 37))
            heart.addCurve(to: CGPoint(x: 182, y: 40), control1: CGPoint(x: 177, y: 37), control2: CGPoint(x: 182, y: 38))
            heart.addQuadCurve(to: CGPoint(x: 174, y: 53), control: CGPoint(x: 190, y: 45))
            context.fill(heart, with: .color(pink))
        }
    }

    private static func ears(in context: GraphicsContext, time: Double) {
        for right in [false, true] {
            var earContext = context
            if right {
                earContext.translateBy(x: 208, y: 0)
                earContext.scaleBy(x: -1, y: 1)
            }
            earContext.translateBy(x: 66, y: 53)
            let twitch = pow(max(0, sin(time * 1.1 + (right ? 1.4 : 0))), 14) * 5
            earContext.rotate(by: .degrees(-twitch))
            earContext.translateBy(x: -66, y: -53)
            var ear = Path()
            ear.move(to: CGPoint(x: 43, y: 65))
            ear.addCurve(to: CGPoint(x: 43, y: 10), control1: CGPoint(x: 40, y: 43), control2: CGPoint(x: 34, y: 7))
            ear.addCurve(to: CGPoint(x: 83, y: 41), control1: CGPoint(x: 49, y: 8), control2: CGPoint(x: 71, y: 25))
            ear.closeSubpath()
            earContext.fill(ear, with: .linearGradient(Gradient(colors: [honey, cream]), startPoint: CGPoint(x: 40, y: 8), endPoint: CGPoint(x: 65, y: 65)))
            earContext.stroke(ear, with: .color(outline.opacity(0.5)), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            var inner = Path()
            inner.move(to: CGPoint(x: 48, y: 47))
            inner.addQuadCurve(to: CGPoint(x: 47, y: 20), control: CGPoint(x: 42, y: 18))
            inner.addQuadCurve(to: CGPoint(x: 69, y: 40), control: CGPoint(x: 58, y: 25))
            inner.closeSubpath()
            earContext.fill(inner, with: .linearGradient(Gradient(colors: [pink, pink.opacity(0.38)]), startPoint: CGPoint(x: 47, y: 20), endPoint: CGPoint(x: 59, y: 50)))
        }
    }

    private static func face(in context: GraphicsContext, time: Double, happy: Bool, sleepy: Bool) {
        var silhouette = Path()
        silhouette.move(to: CGPoint(x: 45, y: 63))
        silhouette.addCurve(to: CGPoint(x: 87, y: 34), control1: CGPoint(x: 49, y: 42), control2: CGPoint(x: 69, y: 35))
        silhouette.addQuadCurve(to: CGPoint(x: 94, y: 25), control: CGPoint(x: 91, y: 31))
        silhouette.addQuadCurve(to: CGPoint(x: 100, y: 32), control: CGPoint(x: 99, y: 25))
        silhouette.addQuadCurve(to: CGPoint(x: 110, y: 27), control: CGPoint(x: 104, y: 27))
        silhouette.addQuadCurve(to: CGPoint(x: 115, y: 34), control: CGPoint(x: 111, y: 31))
        silhouette.addCurve(to: CGPoint(x: 163, y: 66), control1: CGPoint(x: 138, y: 32), control2: CGPoint(x: 158, y: 45))
        silhouette.addQuadCurve(to: CGPoint(x: 170, y: 92), control: CGPoint(x: 167, y: 78))
        silhouette.addLine(to: CGPoint(x: 165, y: 93))
        silhouette.addLine(to: CGPoint(x: 169, y: 100))
        silhouette.addCurve(to: CGPoint(x: 105, y: 130), control1: CGPoint(x: 161, y: 121), control2: CGPoint(x: 131, y: 131))
        silhouette.addCurve(to: CGPoint(x: 38, y: 100), control1: CGPoint(x: 78, y: 131), control2: CGPoint(x: 48, y: 123))
        silhouette.addLine(to: CGPoint(x: 42, y: 93))
        silhouette.addLine(to: CGPoint(x: 37, y: 92))
        silhouette.addQuadCurve(to: CGPoint(x: 45, y: 63), control: CGPoint(x: 40, y: 75))
        silhouette.closeSubpath()
        context.fill(silhouette, with: .linearGradient(Gradient(colors: [cream, Color(red: 0.99, green: 0.88, blue: 0.67), honey]), startPoint: CGPoint(x: 86, y: 43), endPoint: CGPoint(x: 128, y: 172)))
        context.stroke(silhouette, with: .color(outline.opacity(0.48)), style: StrokeStyle(lineWidth: 1.1, lineJoin: .round))

        // Three tiny tabby stripes and a pale, heart-shaped muzzle.
        for (x, y, angle) in [(90.0, 43.0, -15.0), (103.0, 40.0, 0.0), (116.0, 43.0, 15.0)] {
            var stripe = context
            stripe.translateBy(x: x, y: y)
            stripe.rotate(by: .degrees(angle))
            stripe.fill(Path(roundedRect: CGRect(x: -2.4, y: 0, width: 4.8, height: 13), cornerRadius: 3), with: .color(ginger.opacity(0.48)))
        }
        ellipse(in: context, rect: CGRect(x: 72, y: 93, width: 39, height: 28), color: cream.opacity(0.9))
        ellipse(in: context, rect: CGRect(x: 98, y: 93, width: 39, height: 28), color: cream.opacity(0.9))
        ellipse(in: context, rect: CGRect(x: 50, y: 91, width: 22, height: 11), color: pink.opacity(0.37))
        ellipse(in: context, rect: CGRect(x: 137, y: 91, width: 22, height: 11), color: pink.opacity(0.37))

        let blinkPhase = time.truncatingRemainder(dividingBy: 4.7)
        let blinkAmount = blinkPhase > 3.9 && blinkPhase < 4.14
            ? sin((blinkPhase - 3.9) / 0.24 * .pi) : 0
        for x in [77.0, 131.0] {
            if happy || sleepy {
                var eye = Path()
                eye.move(to: CGPoint(x: x - 9, y: 83))
                eye.addQuadCurve(to: CGPoint(x: x + 9, y: 83), control: CGPoint(x: x, y: sleepy && !happy ? 90 : 70))
                context.stroke(eye, with: .color(ink), style: StrokeStyle(lineWidth: 2.7, lineCap: .round))
            } else {
                let glance = sin(time * 0.6) * 0.8
                var eye = context
                eye.translateBy(x: x + glance, y: 82)
                eye.scaleBy(x: 1, y: max(0.06, 1 - blinkAmount))
                let iris = Path(ellipseIn: CGRect(x: -10, y: -12, width: 20, height: 24))
                eye.fill(iris, with: .linearGradient(Gradient(colors: [ink, Color(red: 0.39, green: 0.29, blue: 0.19)]), startPoint: CGPoint(x: 0, y: -10), endPoint: CGPoint(x: 0, y: 12)))
                ellipse(in: eye, rect: CGRect(x: -6.5, y: 4, width: 13, height: 6), color: honey.opacity(0.6))
                ellipse(in: eye, rect: CGRect(x: -6, y: -10, width: 12, height: 18), color: ink)
                ellipse(in: eye, rect: CGRect(x: -6, y: -9, width: 5, height: 6), color: .white.opacity(0.97))
                ellipse(in: eye, rect: CGRect(x: 3, y: 3, width: 3, height: 3), color: cream.opacity(0.95))
            }
            var brow = Path()
            brow.move(to: CGPoint(x: x - 4, y: 66))
            brow.addQuadCurve(to: CGPoint(x: x + 3, y: 65), control: CGPoint(x: x, y: 63))
            context.stroke(brow, with: .color(ginger.opacity(0.65)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
        var nose = Path()
        nose.move(to: CGPoint(x: 99, y: 95))
        nose.addQuadCurve(to: CGPoint(x: 109, y: 95), control: CGPoint(x: 104, y: 93))
        nose.addQuadCurve(to: CGPoint(x: 104, y: 101), control: CGPoint(x: 111, y: 97))
        nose.addQuadCurve(to: CGPoint(x: 99, y: 95), control: CGPoint(x: 98, y: 98))
        context.fill(nose, with: .color(Color(red: 0.72, green: 0.44, blue: 0.39)))
        var mouth = Path()
        mouth.move(to: CGPoint(x: 104, y: 100))
        mouth.addLine(to: CGPoint(x: 104, y: 105))
        mouth.addCurve(to: CGPoint(x: 96, y: 107), control1: CGPoint(x: 102, y: 110), control2: CGPoint(x: 98, y: 110))
        mouth.move(to: CGPoint(x: 104, y: 105))
        mouth.addCurve(to: CGPoint(x: 112, y: 107), control1: CGPoint(x: 106, y: 110), control2: CGPoint(x: 110, y: 110))
        context.stroke(mouth, with: .color(outline), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))

        for right in [false, true] {
            for index in 0..<2 {
                var whisker = Path()
                let x = right ? 146.0 : 61.0
                let end = right ? 176.0 : 31.0
                whisker.move(to: CGPoint(x: x, y: 102 + Double(index * 5)))
                whisker.addQuadCurve(to: CGPoint(x: end, y: 99 + Double(index * 12)), control: CGPoint(x: (x + end) / 2, y: 101 + Double(index * 7)))
                context.stroke(whisker, with: .color(outline.opacity(0.65)), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
            }
        }
    }

    private static func accessory(in context: GraphicsContext, time: Double, mood: DutyCatMood) {
        switch mood {
        case .curious: break
        case .sleepy:
            for index in 0..<3 {
                let rise = sin(time * 1.1 + Double(index)) * 2
                let z = Text(index == 0 ? "z" : "Z")
                    .font(.system(size: CGFloat(9 + index * 2), weight: .semibold, design: .rounded))
                    .foregroundColor(teal.opacity(0.8 - Double(index) * 0.15))
                context.draw(z, at: CGPoint(x: 164 + Double(index * 10), y: 58 - Double(index * 16) + rise))
            }
        case .detective:
            var glass = context
            glass.translateBy(x: 36, y: 113)
            glass.rotate(by: .degrees(sin(time * 1.2) * 5))
            var handle = Path()
            handle.move(to: CGPoint(x: -9, y: 12))
            handle.addLine(to: CGPoint(x: -21, y: 29))
            glass.stroke(handle, with: .color(outline.opacity(0.9)), style: StrokeStyle(lineWidth: 7, lineCap: .round))
            let lens = Path(ellipseIn: CGRect(x: -16, y: -16, width: 32, height: 32))
            glass.fill(lens, with: .linearGradient(Gradient(colors: [.white.opacity(0.6), Color.cyan.opacity(0.14)]), startPoint: CGPoint(x: -10, y: -12), endPoint: CGPoint(x: 12, y: 14)))
            glass.stroke(lens, with: .color(teal), lineWidth: 3.5)
            var shine = Path()
            shine.move(to: CGPoint(x: -9, y: -2))
            shine.addQuadCurve(to: CGPoint(x: -2, y: -10), control: CGPoint(x: -10, y: -9))
            glass.stroke(shine, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        case .tangled:
            let yarn = Color(red: 0.79, green: 0.48, blue: 0.48)
            var thread = Path()
            thread.move(to: CGPoint(x: 173, y: 149))
            thread.addCurve(to: CGPoint(x: 148, y: 155), control1: CGPoint(x: 141, y: 134), control2: CGPoint(x: 137, y: 158))
            thread.addCurve(to: CGPoint(x: 163, y: 151), control1: CGPoint(x: 162, y: 156), control2: CGPoint(x: 154, y: 139))
            context.stroke(thread, with: .color(yarn), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            var ball = context
            ball.translateBy(x: 181 + sin(time) * 2, y: 139)
            ball.rotate(by: .degrees(sin(time) * 8))
            let circle = Path(ellipseIn: CGRect(x: -14, y: -14, width: 28, height: 28))
            ball.fill(circle, with: .linearGradient(Gradient(colors: [pink, yarn]), startPoint: CGPoint(x: -10, y: -10), endPoint: CGPoint(x: 10, y: 14)))
            ball.clip(to: circle)
            for index in -2...2 {
                let x = Double(index * 6)
                var strand = Path()
                strand.move(to: CGPoint(x: x - 12, y: -18))
                strand.addQuadCurve(to: CGPoint(x: x + 12, y: 18), control: CGPoint(x: x + 19, y: -5))
                ball.stroke(strand, with: .color(cream.opacity(0.4)), lineWidth: 1.1)
            }
        }
    }

    private static func scarf(in context: GraphicsContext) {
        var ribbon = Path()
        ribbon.move(to: CGPoint(x: 72, y: 124))
        ribbon.addQuadCurve(to: CGPoint(x: 138, y: 123), control: CGPoint(x: 104, y: 137))
        ribbon.addLine(to: CGPoint(x: 136, y: 134))
        ribbon.addQuadCurve(to: CGPoint(x: 75, y: 135), control: CGPoint(x: 105, y: 147))
        ribbon.closeSubpath()
        context.fill(ribbon, with: .linearGradient(Gradient(colors: [teal, Color(red: 0.19, green: 0.40, blue: 0.37)]), startPoint: CGPoint(x: 72, y: 124), endPoint: CGPoint(x: 134, y: 143)))
        var end = Path()
        end.move(to: CGPoint(x: 127, y: 133))
        end.addQuadCurve(to: CGPoint(x: 143, y: 158), control: CGPoint(x: 141, y: 141))
        end.addLine(to: CGPoint(x: 132, y: 155))
        end.addLine(to: CGPoint(x: 127, y: 160))
        end.addQuadCurve(to: CGPoint(x: 120, y: 137), control: CGPoint(x: 124, y: 147))
        context.fill(end, with: .color(teal))
        ellipse(in: context, rect: CGRect(x: 98, y: 137, width: 14, height: 14), color: Color(red: 0.94, green: 0.73, blue: 0.33))
        ellipse(in: context, rect: CGRect(x: 101, y: 139, width: 4, height: 3), color: cream.opacity(0.9))
        var bell = Path()
        bell.move(to: CGPoint(x: 101, y: 147))
        bell.addLine(to: CGPoint(x: 109, y: 147))
        context.stroke(bell, with: .color(outline.opacity(0.8)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        ellipse(in: context, rect: CGRect(x: 104, y: 145, width: 2, height: 4), color: outline.opacity(0.8))
    }

    private static func ellipse(in context: GraphicsContext, rect: CGRect, color: Color) {
        context.fill(Path(ellipseIn: rect), with: .color(color))
    }
}
