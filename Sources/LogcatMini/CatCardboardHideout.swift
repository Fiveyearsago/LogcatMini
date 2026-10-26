import SwiftUI

/// The cat and the front of the box are separate layers, so the reveal has real depth.
struct CatCardboardHideout: View {
    let open: Bool
    let mood: DutyCatMood
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            CardboardBoxArt(opening: open ? 1 : 0, front: false)
            if open {
                DutyCatIllustration(petted: false, reduceMotion: reduceMotion, mood: mood, inBox: true)
                    .frame(width: 142, height: 114)
                    .offset(x: 2, y: -13)
                    .transition(reduceMotion ? .opacity : .offset(y: 65).combined(with: .opacity))
            }
            CardboardBoxArt(opening: open ? 1 : 0, front: true)
            if open {
                DutyCatPaws().frame(width: 142, height: 20).offset(x: 2, y: 29)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.65, dampingFraction: 0.76), value: open)
        .accessibilityHidden(true)
    }
}

private struct CardboardBoxArt: View, Animatable {
    var opening: Double
    let front: Bool
    var animatableData: Double {
        get { opening }
        set { opening = newValue }
    }

    var body: some View {
        Canvas { context, size in
            var box = context
            box.scaleBy(x: size.width / 200, y: size.height / 160)
            let edge = Color(red: 0.53, green: 0.36, blue: 0.22)
            let kraft = Color(red: 0.85, green: 0.66, blue: 0.43)
            let light = Color(red: 0.94, green: 0.78, blue: 0.55)
            if front {
                let face = Path(roundedRect: CGRect(x: 45, y: 108, width: 114, height: 48), cornerRadius: 4)
                box.fill(face, with: .linearGradient(Gradient(colors: [light, kraft]), startPoint: CGPoint(x: 45, y: 108), endPoint: CGPoint(x: 159, y: 156)))
                box.stroke(face, with: .color(edge.opacity(0.65)), lineWidth: 1)
                box.fill(Path(CGRect(x: 96, y: 109, width: 13, height: 46)), with: .color(.white.opacity(0.16)))
                let label = Path(roundedRect: CGRect(x: 57, y: 123, width: 33, height: 23), cornerRadius: 2)
                box.fill(label, with: .color(Color(red: 1, green: 0.96, blue: 0.85)))
                box.draw(Text("PAW").font(.system(size: 7, weight: .bold, design: .monospaced)).foregroundColor(edge), at: CGPoint(x: 73.5, y: 131))
                box.draw(Text("POST").font(.system(size: 6, design: .monospaced)).foregroundColor(edge), at: CGPoint(x: 73.5, y: 139))
                for pad in [CGRect(x: 133, y: 134, width: 10, height: 8),
                            CGRect(x: 129, y: 130, width: 4, height: 5),
                            CGRect(x: 134, y: 126, width: 4, height: 6),
                            CGRect(x: 140, y: 127, width: 4, height: 6),
                            CGRect(x: 145, y: 132, width: 4, height: 5)] {
                    box.fill(Path(ellipseIn: pad), with: .color(edge.opacity(0.65)))
                }
                // Fold the two lid flaps out from the rim as the cat rises.
                for right in [false, true] {
                    var lid = box
                    lid.translateBy(x: right ? 159 : 45, y: 108)
                    if right { lid.scaleBy(x: -1, y: 1) }
                    lid.rotate(by: .degrees(-opening * 120))
                    var flap = Path()
                    flap.move(to: .zero)
                    flap.addLine(to: CGPoint(x: 56, y: -1))
                    flap.addLine(to: CGPoint(x: 48, y: -18))
                    flap.addLine(to: CGPoint(x: 5, y: -19))
                    flap.closeSubpath()
                    lid.fill(flap, with: .linearGradient(Gradient(colors: [light, kraft]), startPoint: CGPoint(x: 0, y: -19), endPoint: CGPoint(x: 56, y: 0)))
                    lid.stroke(flap, with: .color(edge.opacity(0.65)), style: StrokeStyle(lineWidth: 0.8, lineJoin: .round))
                }
            } else {
                let inside = Path(roundedRect: CGRect(x: 45, y: 91, width: 114, height: 61), cornerRadius: 5)
                box.fill(inside, with: .color(edge))
                box.stroke(inside, with: .color(kraft), lineWidth: 2)
            }
        }
    }
}
