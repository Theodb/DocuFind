import SwiftUI

/// The tour, in two parts. While the first index runs, the search page explains what is happening; once there is
/// something to find, it shows the quick search bar and its keys, with hints above the bar itself. Each step moves on
/// once you have done it. Shown once after setup; Help → Keyboard Shortcuts Tour brings it back.
enum TourStep: Int, CaseIterable {
    case indexing, anywhere, search, move, look, open

    /// Its own key, so people who took the earlier tour of the results page still get this one.
    static let seenKey = "quickSearchTourSeen"

    /// Steps from here on are hinted inside the quick search bar; the ones before, on the main window.
    var inQuickBar: Bool { rawValue >= TourStep.search.rawValue }

    var title: String {
        switch self {
        case .indexing: "DocuFind is reading your files"
        case .anywhere: "Search from any app"
        case .search: "Describe what you're looking for"
        case .move: "Move between matches"
        case .look: "Look closer"
        case .open: "Open it"
        }
    }

    @MainActor var message: String {
        switch self {
        case .indexing: "It builds a private index on this Mac: your files, the model and the index never leave it. Files become searchable as they finish. When it's done, you'll see how to search from anywhere."
        case .anywhere: GlobalShortcut.shared.isEnabled && GlobalShortcut.shared.isRegistered
            ? "Press the shortcut in any app, even with this window closed, to bring up the search bar."
            : "The search bar's shortcut is off. Turn it on in Settings, or open the bar from here."
        case .search: "A few words are enough. Then press Return."
        case .move: "Step through the matches."
        case .look: "Space shows it large, Space again goes back. On a recording, it plays."
        case .open: "Return opens the file in its app. Esc closes the bar."
        }
    }

    @MainActor var keys: [String] {
        switch self {
        case .indexing: []
        case .anywhere: GlobalShortcut.shared.isEnabled && GlobalShortcut.shared.isRegistered ? [GlobalShortcut.shared.shortcut.display] : []
        case .search: ["↩ Return"]
        case .move: ["←", "→"]
        case .look: ["Space"]
        case .open: ["↩ Return", "esc"]
        }
    }

    var progress: String { "\(rawValue + 1) of \(TourStep.allCases.count)" }
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(step.progress).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("Skip tour") { model.endTour() }.buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            if step == .indexing {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(.green)
                    Text(step.title).font(.system(size: 15, weight: .semibold))
                }
            } else {
                Text(step.title).font(.system(size: 15, weight: .semibold))
            }
            Text(step.message).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                ForEach(step.keys, id: \.self) { TourKeycap(label: $0) }
                Spacer(minLength: 12)
                action(step)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .frame(width: 310)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.16)))
        .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tour, step \(step.progress): \(step.title)")
    }

    /// While indexing runs, the tour waits for it but can go on early; the next step opens the search bar for you.
    @ViewBuilder private func action(_ step: TourStep) -> some View {
        switch step {
        case .indexing where model.indexing && model.indexedCount > 0:
            Button("Try It Now") { model.advanceTour(from: step) }.controlSize(.small)
        case .indexing where model.indexing:
            EmptyView()
        case .anywhere:
            Button("Open Search Bar") { QuickSearchController.shared.show() }.controlSize(.small)
        default:
            Button("Next") { model.advanceTour(from: step) }.controlSize(.small)
        }
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

}

/// The quick search part of the tour: one slim hint above the bar, in the room its glow leaves, so it never covers
/// the results or the preview below.
struct QuickBarTourHint: View {
    @ObservedObject var model: AppModel
    let step: TourStep

    var body: some View {
        HStack(spacing: 12) {
            Text(step.progress).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).monospacedDigit()
            VStack(alignment: .leading, spacing: 1) {
                Text(step.title).font(.system(size: 13, weight: .semibold))
                Text(step.message).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) { ForEach(step.keys, id: \.self) { TourKeycap(label: $0) } }
            Button(step == TourStep.allCases.last ? "Done" : "Skip tour") { model.endTour() }
                .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).frame(width: 600, height: 50)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.accentColor.opacity(0.55)))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
        .id(step)
        .transition(.opacity.combined(with: .offset(y: 6)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tour, step \(step.progress): \(step.title). \(step.message)")
    }
}

/// A key as printed on the keyboard, for the tour's hints.
struct TourKeycap: View {
    let label: String

    var body: some View {
        Text(label).font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, 8).frame(minWidth: 28, minHeight: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.22)))
            .accessibilityLabel(label == "↩ Return" ? "Return" : label == "esc" ? "Escape" : label)
    }
}

