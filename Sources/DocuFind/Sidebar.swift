import AppKit
import SwiftUI

/// The sidebar as a floating Liquid Glass panel: glass navigation capsules with
/// painted icons, a library summary coloured like the result covers, and a privacy pill.
struct MagniSidebar: View {
    @ObservedObject var model: AppModel
    @Binding var destination: Destination?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var namespace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 4) {
                ForEach(Destination.allCases) { page in row(page) }
            }
            .padding(.top, 10)
            Spacer(minLength: 16)
            libraryCard
            privacyPill.padding(.top, 10)
        }
        .padding(12)
        .background {
            // The panel floats inside the window, like macOS 26 sidebars, with no outline or shadow.
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.clear)
                .background(MagniGlassSurface(radius: 24, material: .sidebar))
                .padding(8)
                // Reach up behind the window buttons, like macOS 26 sidebars.
                .ignoresSafeArea(.container, edges: .top)
        }
    }

    private func row(_ page: Destination) -> some View {
        let selected = destination == page
        return Button {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { destination = page }
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    if selected {
                        PaintedCoverView(key: "sidebar-\(page.rawValue)", palette: Self.palette(for: page))
                            .clipShape(Circle())
                            .transition(.opacity)
                    } else {
                        Circle().fill(Color.primary.opacity(0.06))
                    }
                    // On the paint, the glyph uses the app icon's deep-teal ink.
                    Image(systemName: page.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? Color(red: 6 / 255, green: 64 / 255, blue: 78 / 255) : Color.secondary)
                }
                .frame(width: 28, height: 28)
                Text(page.rawValue)
                    .font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                Spacer(minLength: 4)
                if page == .library && model.indexing {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 42)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(reduceTransparency ? 0.1 : 0.07))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.16)))
                        .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
                        .matchedGeometryEffect(id: "selection", in: namespace)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(SidebarRowStyle())
        .accessibilityLabel(page.rawValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Library card

    private var libraryCard: some View {
        let kinds = [("text", "Documents", CoverPalette.documents), ("image", "Photos", CoverPalette.photos), ("audio", "Recordings", CoverPalette.recordings)]
        let total = max(1, kinds.reduce(0) { $0 + (model.kindCounts[$1.0] ?? 0) })
        return Button { destination = .library } label: {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Your library").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(model.indexedCount.formatted()).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                // One bar, split by kind, in the same colours as the result covers.
                GeometryReader { geometry in
                    HStack(spacing: 3) {
                        ForEach(kinds, id: \.0) { kind, _, palette in
                            let share = CGFloat(model.kindCounts[kind] ?? 0) / CGFloat(total)
                            if share > 0 {
                                Capsule().fill(Self.gradient(palette))
                                    .frame(width: max(6, share * (geometry.size.width - 6)))
                            }
                        }
                        if model.indexedCount == 0 { Capsule().fill(Color.primary.opacity(0.08)) }
                    }
                }
                .frame(height: 7)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(kinds, id: \.0) { kind, label, palette in
                        HStack(spacing: 7) {
                            Circle().fill(Self.gradient(palette)).frame(width: 7, height: 7)
                            Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            Spacer()
                            Text((model.kindCounts[kind] ?? 0).formatted()).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.tertiary)
                        }
                    }
                }
                if model.indexing {
                    VStack(alignment: .leading, spacing: 6) {
                        if let fraction = model.indexingFraction {
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.08))
                                    Capsule().fill(Self.gradient(.aura)).frame(width: max(4, geometry.size.width * fraction))
                                }
                            }
                            .frame(height: 4)
                            .animation(.easeOut(duration: 0.4), value: fraction)
                        }
                        HStack(alignment: .top, spacing: 7) {
                            ProgressView().controlSize(.mini)
                            Text(model.indexingSummary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                }
            }
            // No box of its own: the text lines up with the navigation rows above.
            .padding(.horizontal, 8).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens Library")
    }

    private var privacyPill: some View {
        HStack(spacing: 7) {
            Image(systemName: "lock.fill").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
            Text("Private · on this Mac").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11).frame(height: 26)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: Colour

    static func palette(for page: Destination) -> CoverPalette {
        switch page {
        case .search: .aura
        case .library: .documents
        case .settings: .recordings
        case .about: .photos
        }
    }

    static func gradient(_ palette: CoverPalette) -> LinearGradient {
        LinearGradient(colors: palette.colors.prefix(3).map { Color(red: Double($0.x), green: Double($0.y), blue: Double($0.z)) },
                       startPoint: .leading, endPoint: .trailing)
    }
}

/// Soft hover and press feedback for sidebar rows.
private struct SidebarRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SidebarRowBody(configuration: configuration)
    }

    private struct SidebarRowBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(hovering ? 0.04 : 0)))
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}
