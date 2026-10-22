import SwiftUI

/// The DocuFind mark, alive: the painted canvas drifts inside the tile while the
/// magnifier's lens floats over it, magnifying the paint beneath. Used while the app
/// connects and while the search model loads.
struct PaintedLogo: View {
    var size: CGFloat
    var animating = true

    var body: some View {
        TimelineView(.animation(paused: !animating)) { context in
            mark(time: animating ? context.date.timeIntervalSinceReferenceDate : 0)
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("DocuFind")
    }

    private func mark(time t: Double) -> some View {
        let drift = CGSize(width: sin(t * 0.45) * size * 0.2, height: cos(t * 0.37) * size * 0.16)
        let turn = Angle.degrees(sin(t * 0.21) * 10)
        // Proportions follow the app icon (scripts/make-icon.swift): a flat deep-teal magnifier, centred.
        let lens = CGPoint(x: size * (0.4392 + 0.03 * sin(t * 0.8)), y: size * (0.4392 + 0.03 * cos(t * 0.65)))
        let outer = size * 0.2679, inner = size * 0.1908, grip = size * 0.1127
        let ink = Color(red: 6 / 255, green: 64 / 255, blue: 78 / 255)
        let handle = Path { path in
            path.move(to: CGPoint(x: lens.x + outer * 0.62, y: lens.y + outer * 0.62))
            path.addLine(to: CGPoint(x: lens.x + size * 0.3237, y: lens.y + size * 0.3237))
        }
        return ZStack {
            paint(span: 1.8, drift: drift, turn: turn)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).strokeBorder(.white.opacity(0.5), lineWidth: max(1, size * 0.006)))
            // Square where it meets the ring, round at the end, as in the icon.
            handle.stroke(ink, style: StrokeStyle(lineWidth: grip, lineCap: .butt))
            Circle().fill(ink)
                .frame(width: grip, height: grip)
                .position(x: lens.x + size * 0.3237, y: lens.y + size * 0.3237)
            // The lens shows the same canvas, enlarged.
            paint(span: 2.7, drift: CGSize(width: drift.width * 1.5, height: drift.height * 1.5), turn: turn)
                .overlay(RadialGradient(colors: [.white.opacity(0.35), .clear], center: UnitPoint(x: (lens.x - inner * 0.45) / size, y: (lens.y - inner * 0.45) / size),
                                        startRadius: 0, endRadius: inner * 0.9))
                .mask(Circle().frame(width: inner * 2, height: inner * 2).position(lens))
            Circle()
                .strokeBorder(ink, lineWidth: outer - inner)
                .frame(width: outer * 2, height: outer * 2)
                .position(lens)
        }
        .frame(width: size, height: size)
    }

    /// A canvas larger than the tile, so it can move without showing an edge.
    private func paint(span: CGFloat, drift: CGSize, turn: Angle) -> some View {
        // The seed keeps the app's earlier name, so the artwork stays the same.
        PaintedCoverView(key: "magnifind-logo", palette: .aura)
            .frame(width: size * span, height: size * span)
            .rotationEffect(turn)
            .offset(drift)
            .frame(width: size, height: size)
    }
}

/// The README's pixel wordmark, shipped as Resources/Banner.png with a transparent background.
struct DocuFindBanner: View {
    var width: CGFloat

    private static let image = Bundle.main.url(forResource: "Banner", withExtension: "png").flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: width)
        } else {
            Text("DocuFind").font(.system(size: width / 8, weight: .bold, design: .rounded))
        }
    }
}

/// Full-window cover shown at launch while the app connects and loads the search model.
struct ModelLoadingOverlay: View {
    let title: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 22) {
            PaintedLogo(size: 128, animating: !reduceMotion)
                .shadow(color: .black.opacity(0.18), radius: 24, y: 14)
            Text(title).font(.system(size: 22, weight: .semibold)).tracking(-0.4)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: title)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LaunchBackdrop(animating: !reduceMotion))
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
    }
}

/// The launch screen's background: the logo's paint, blown up into a soft glow that
/// drifts behind it, over an opaque base so the page underneath doesn't show through.
struct LaunchBackdrop: View {
    let animating: Bool
    @State private var drift = false

    var body: some View {
        GeometryReader { proxy in
            let side = max(proxy.size.width, proxy.size.height)
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                // Painted at a quarter size and scaled up: it is heavily blurred, and painting it full size cost
                // about 0.3 s of CPU while the app was starting.
                // The seed keeps the app's earlier name, so the artwork stays the same.
                PaintedCoverView(key: "magnifind-launch-glow", palette: .aura)
                    .frame(width: side * 0.225, height: side * 0.225)
                    .scaleEffect(4)
                    .frame(width: side * 0.9, height: side * 0.9)
                    .clipShape(Circle())
                    .scaleEffect(drift ? 1.08 : 0.94)
                    .rotationEffect(.degrees(drift ? 8 : -8))
                    .offset(x: drift ? side * 0.04 : -side * 0.04, y: drift ? -side * 0.02 : side * 0.02)
                    .blur(radius: side * 0.09)
                    .opacity(0.55)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard animating else { return }
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { drift = true }
        }
    }
}
