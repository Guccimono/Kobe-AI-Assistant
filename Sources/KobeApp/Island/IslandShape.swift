import SwiftUI

/// Island outline: concave flares at the top corners so it melts into the screen edge like the notch, rounded
/// bottom corners. `width` includes the flares. Width, height, radius and flare all animate, so the island grows
/// out of the notch in one motion. Drawn from the top-left of its frame.
struct IslandShape: Shape {
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat
    var flare: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(width, height), AnimatablePair(radius, flare)) }
        set {
            width = newValue.first.first
            height = newValue.first.second
            radius = newValue.second.first
            flare = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let f = max(0, min(flare, width / 4, height / 2))
        let r = max(0, min(radius, (width - 2 * f) / 2, height / 2))
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        // Left flare: a quarter-curve from the screen edge down into the island's side.
        p.addQuadCurve(to: CGPoint(x: f, y: f), control: CGPoint(x: f, y: 0))
        p.addLine(to: CGPoint(x: f, y: height - r))
        p.addArc(center: CGPoint(x: f + r, y: height - r), radius: r, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        p.addLine(to: CGPoint(x: width - f - r, y: height))
        p.addArc(center: CGPoint(x: width - f - r, y: height - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
        p.addLine(to: CGPoint(x: width - f, y: f))
        p.addQuadCurve(to: CGPoint(x: width, y: 0), control: CGPoint(x: width - f, y: 0))
        p.closeSubpath()
        return p
    }
}
