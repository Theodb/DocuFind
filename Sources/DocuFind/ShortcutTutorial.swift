import SwiftUI

/// The keyboard tour: coach marks on the real search page. Each step lights up what to use next, says which key to
/// press, and moves on once you have done it. Shown once after setup; Help → Keyboard Shortcuts Tour brings it back.
enum TourStep: Int, CaseIterable {
    case search, move, look, open, anywhere

    static let seenKey = "shortcutTutorialSeen"

    var title: String {
        switch self {
        case .search: "Describe what you're looking for"
        case .move: "Move between matches"
        case .look: "Look closer"
        case .open: "Open it"
        case .anywhere: "Search from any app"
        }
    }

    var message: String {
        switch self {
        case .search: "A few words are enough, like \u{201C}invoice from the plumber\u{201D}. Then press Return."
        case .move: "Use the arrow keys to step through the results."
        case .look: "Space shows a document or photo large, and Space again goes back. On a recording, Space plays it."
        case .open: "Return (Enter) opens the file in its app."
        case .anywhere: "Press the shortcut in any app to bring up the search bar, even with this window closed."
        }
    }

    @MainActor var keys: [String] {
        switch self {
        case .search, .open: ["↩ Return"]
        case .move: ["←", "→"]
        case .look: ["Space"]
        case .anywhere: [GlobalShortcut.shared.shortcut.display]
        }
    }
}

/// Where each step's target sits on the page.
struct TourAnchorKey: PreferenceKey {
    static let defaultValue: [TourStep: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TourStep: Anchor<CGRect>], nextValue: () -> [TourStep: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Marks the view that the given tour steps light up.
    func tourAnchor(_ steps: TourStep...) -> some View {
        // Added to the anchors inside the view (the best match holds the Open button's), never replacing them.
        transformAnchorPreference(key: TourAnchorKey.self, value: .bounds) { anchors, anchor in
            for step in steps { anchors[step] = anchor }
        }
    }
}

/// The current step over the page: everything else dimmed, the target lit with a soft pulsing ring, and a bubble
/// beside it. Clicks and keys still reach the page, so the step is done by doing it.
struct TourOverlay: View {
    @ObservedObject var model: AppModel
    let anchors: [TourStep: Anchor<CGRect>]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false
    /// The bubble's measured height, to place it above its target or at the bottom.
    @State private var bubbleHeight: CGFloat = 150

    var body: some View {
        GeometryReader { proxy in
            if let step = model.tourStep {
                let target = anchors[step].map { proxy[$0].insetBy(dx: -8, dy: -8) }
                ZStack(alignment: .topLeading) {
                    if let target { spotlight(target) }
                    bubble(step)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { bubbleHeight = $0 }
                        .offset(bubbleOffset(target: target, space: proxy.size))
                        .id(step)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
                .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.86), value: step)
                .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.86), value: target)
            }
        }
        // Measured and drawn in one space, title bar included: the dimming used to ignore the safe area while the
        // target was measured inside it, which drew the ring a title bar's height too high.
        .ignoresSafeArea()
        .onAppear { pulsing = true }
    }

    private func spotlight(_ target: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.4)
                .mask {
                    Rectangle().overlay(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .frame(width: target.width, height: target.height)
                            .offset(x: target.minX, y: target.minY)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                }
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .shadow(color: Color.accentColor.opacity(pulsing && !reduceMotion ? 0.75 : 0.3), radius: pulsing && !reduceMotion ? 16 : 6)
                .frame(width: target.width, height: target.height)
                .offset(x: target.minX, y: target.minY)
                .animation(reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulsing)
        }
        .allowsHitTesting(false)
    }

    private func bubble(_ step: TourStep) -> some View {
        let last = step == TourStep.allCases.last
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(step.rawValue + 1) of \(TourStep.allCases.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if !last {
                    Button("Skip tour") { model.endTour() }.buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            Text(step.title).font(.system(size: 15, weight: .semibold))
            Text(step.message).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                ForEach(step.keys, id: \.self) { keycap($0) }
                Spacer(minLength: 12)
                Button(last ? "Done" : "Next") { model.advanceTour(from: step) }.controlSize(.small)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .frame(width: 310)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.16)))
        .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tour, step \(step.rawValue + 1) of \(TourStep.allCases.count): \(step.title)")
    }

    /// Below the target when there is room, above it otherwise, kept inside the page; without a target (nothing on
    /// the page for that step yet), at the bottom centre, clear of the status bar.
    private func bubbleOffset(target: CGRect?, space: CGSize) -> CGSize {
        let width: CGFloat = 310, margin: CGFloat = 16
        let x = min(max(margin, target?.minX ?? (space.width - width) / 2), max(margin, space.width - width - margin))
        let y: CGFloat
        if let target, target.maxY + 14 + bubbleHeight + 40 < space.height {
            y = target.maxY + 14
        } else if let target {
            y = max(margin, target.minY - 14 - bubbleHeight)
        } else {
            y = space.height - bubbleHeight - 56
        }
        return CGSize(width: x, height: y)
    }

    private func keycap(_ label: String) -> some View {
        Text(label).font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, 8).frame(minWidth: 28, minHeight: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.22)))
            .accessibilityLabel(label == "↩ Return" ? "Return" : label)
    }
}

