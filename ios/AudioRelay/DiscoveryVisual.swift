import SwiftUI

struct DiscoveryVisual: View {
    var center: UnitPoint = UnitPoint(x: 0.5, y: 0.72)
    var reduceMotion = false
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduced || reduceMotion)) { timeline in
            Canvas { context, size in
                let origin = CGPoint(x: size.width * center.x, y: size.height * center.y)
                let limit = hypot(size.width, size.height)
                let time = reduced || reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                for ring in 1...28 {
                    let radius = CGFloat(ring) * 25
                    let count = max(12, Int(radius / 7))
                    let wave = reduced || reduceMotion ? 0.3 : (sin(time * 3.5 - Double(radius) / 90) + 1) / 2
                    for index in 0..<count {
                        let angle = CGFloat(index) / CGFloat(count) * .pi * 2
                        let point = CGPoint(x: origin.x + cos(angle) * radius, y: origin.y + sin(angle) * radius)
                        let r = 0.65 + wave * 0.55
                        let opacity = max(0, 1 - radius / limit) * (0.08 + wave * 0.48)
                        context.fill(Path(ellipseIn: CGRect(x: point.x-r, y: point.y-r, width: r*2, height: r*2)), with: .color(.white.opacity(opacity)))
                    }
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct ListeningVisual: View {
    let playing: Bool
    let computer: Bool
    var reduceMotion = false
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: computer ? "desktopcomputer" : "headphones").font(.system(size: 48, weight: .light))
            TimelineView(.animation(minimumInterval: 1.0 / 15, paused: reduced || reduceMotion || !playing)) { timeline in
                HStack(spacing: 4) {
                    ForEach(0..<11) { i in
                        Capsule().frame(width: 3, height: playing ? 8 + 16 * abs(sin(timeline.date.timeIntervalSinceReferenceDate * 3 + Double(i) * 0.8)) : 5)
                    }
                }.frame(height: 28)
            }
        }.foregroundStyle(.white).accessibilityHidden(true)
    }
}

struct PhoneBackdrop: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            func ellipse(_ center: CGPoint, _ radii: CGSize, _ stops: [Gradient.Stop]) {
                var layer = context
                layer.translateBy(x: center.x, y: center.y)
                layer.scaleBy(x: radii.width, y: radii.height)
                layer.fill(Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)),
                           with: .radialGradient(Gradient(stops: stops), center: .zero, startRadius: 0, endRadius: 1))
            }
            // Exact approved CSS: ellipse 100% 65% at 90% 75%, #071b64 → transparent 75%.
            ellipse(CGPoint(x: size.width * 0.9, y: size.height * 0.75), CGSize(width: size.width, height: size.height * 0.65),
                    [.init(color: Color(red: 7/255.0, green: 27/255.0, blue: 100/255.0), location: 0), .init(color: .clear, location: 0.75)])
            // Foreground ellipse 110% 68% at 5% 94%, #278ff1 0%, #145ac4 28%, transparent 73%.
            ellipse(CGPoint(x: size.width * 0.05, y: size.height * 0.94), CGSize(width: size.width * 1.1, height: size.height * 0.68),
                    [.init(color: Color(red: 39/255.0, green: 143/255.0, blue: 241/255.0), location: 0),
                     .init(color: Color(red: 20/255.0, green: 90/255.0, blue: 196/255.0), location: 0.28), .init(color: .clear, location: 0.73)])
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}
