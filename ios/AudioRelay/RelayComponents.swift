import SwiftUI

/// Shared presentation; callers own the real or simulated actions.
struct RelayNearbyDevice: View {
    let name: String
    let detail: String
    var phone = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Group {
                    if phone { Image(systemName: "iphone").font(.title) }
                    else { LaptopGlyph().stroke(Color(white: 0.15), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)).frame(width: 26, height: 26) }
                }.frame(width: 88, height: 88).background(NearbyPresence()).foregroundStyle(.black)
                Text(name).font(.caption.bold()).fixedSize(horizontal: false, vertical: true)
                if !detail.isEmpty { Text(detail).font(.caption2).foregroundStyle(.white.opacity(0.7)) }
            }
        }.buttonStyle(RelayControlButtonStyle())
    }
}
struct RelayShortcut: View {
    let title: String
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 19)).frame(height: 22)
                Text(title).font(.caption).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, minHeight: 48).padding(.vertical, 8).padding(.horizontal, 3)
                .background(Color(white: 0.92), in: RoundedRectangle(cornerRadius: 13))
        }.buttonStyle(RelayControlButtonStyle()).foregroundStyle(RelayPalette.ink)
    }
}
struct RelayOutputChoice: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.subheadline).frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(selected ? Color.white : Color(white: 0.4))
                .background(selected ? Color(white: 0.06) : .clear, in: RoundedRectangle(cornerRadius: 13))
        }.buttonStyle(RelayControlButtonStyle(scales: false)).animation(reduced ? nil : .easeOut(duration: 0.18), value: selected)
    }
}

/// Shared measured arc arrangement for the live discovery screen and tutorial.
struct RelayPhoneOrbit: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        return CGSize(width: width, height: positions(width: width, subviews: subviews).height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = positions(width: bounds.width, subviews: subviews)
        for (index, point) in layout.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), anchor: .top, proposal: ProposedViewSize(width: bounds.width / 2 - 8, height: nil))
        }
    }
    private func positions(width: CGFloat, subviews: Subviews) -> (points: [CGPoint], height: CGFloat) {
        var points: [CGPoint] = []
        var y: CGFloat = 0
        let proposal = ProposedViewSize(width: width / 2 - 8, height: nil)
        for start in stride(from: 0, to: subviews.count, by: 3) {
            points.append(CGPoint(x: width / 2, y: y))
            y += subviews[start].sizeThatFits(proposal).height
            let end = min(start + 3, subviews.count)
            if start + 1 < end {
                y += 12
                var height: CGFloat = 0
                for index in (start + 1)..<end {
                    points.append(CGPoint(x: end - start == 2 ? width / 4 : (index == start + 1 ? width / 4 : width * 3 / 4), y: y))
                    height = max(height, subviews[index].sizeThatFits(proposal).height)
                }
                y += height + 8
            }
        }
        return (points, y)
    }
}
