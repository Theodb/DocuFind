import SwiftUI

/// Shared measurements for the Library and Settings pages, so every option lines up the same way.
enum SettingsLayout {
    /// Space between a row's edge and its content.
    static let rowPadding: CGFloat = 16
    static let rowVerticalPadding: CGFloat = 12
    /// Width of a row's leading symbol, and the gap after it.
    static let symbolWidth: CGFloat = 26
    static let symbolSpacing: CGFloat = 12
    /// Width of every picker at the trailing edge of a row.
    static let pickerWidth: CGFloat = 200
    /// Where a divider starts: under the title, past the symbol when there is one.
    static func dividerInset(symbol: Bool) -> CGFloat { rowPadding + (symbol ? symbolWidth + symbolSpacing : 0) }
}

/// A titled group of options: a header with an optional trailing button, then its surfaces and notes.
struct SettingsSection<Content: View, Accessory: View>: View {
    private let title: String
    private let accessory: Accessory
    private let content: Content

    init(_ title: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 12)
                accessory
            }
            .padding(.horizontal, 4)
            .frame(minHeight: 24)
            content
        }
    }
}

extension SettingsSection where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
    }
}

/// The rounded card that holds a list of rows.
struct SettingsSurface<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(reduceTransparency ? 1 : 0.6), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color(nsColor: .separatorColor).opacity(0.25)))
    }
}

/// One option: an optional symbol, a title with a description under it, and a control at the
/// trailing edge. Descriptions wrap; the control keeps its size. `extra` sits under the description,
/// for progress or secondary buttons.
struct SettingsRow<Control: View, Extra: View>: View {
    private let title: String
    private let detail: String?
    private let symbol: String?
    private let symbolColor: Color
    private let detailColor: Color
    private let truncatesDetail: Bool
    private let alignment: VerticalAlignment
    private let control: Control
    private let extra: Extra

    /// - Parameters:
    ///   - truncatesDetail: keep the description on one line, shortened in the middle (for paths).
    ///   - alignment: `.top` keeps the symbol and control level with the title when `extra` makes the row tall.
    init(_ title: String, detail: String? = nil, symbol: String? = nil, symbolColor: Color = .secondary,
         detailColor: Color = .secondary, truncatesDetail: Bool = false, alignment: VerticalAlignment = .center,
         @ViewBuilder control: () -> Control, @ViewBuilder extra: () -> Extra) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.symbolColor = symbolColor
        self.detailColor = detailColor
        self.truncatesDetail = truncatesDetail
        self.alignment = alignment
        self.control = control()
        self.extra = extra()
    }

    var body: some View {
        HStack(alignment: alignment, spacing: SettingsLayout.symbolSpacing) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(symbolColor)
                    .frame(width: SettingsLayout.symbolWidth)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                if let detail {
                    if truncatesDetail {
                        Text(detail).font(.system(size: 11)).foregroundStyle(detailColor)
                            .lineLimit(1).truncationMode(.middle)
                    } else {
                        Text(detail).font(.system(size: 11)).foregroundStyle(detailColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                extra
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control.fixedSize()
        }
        .padding(.horizontal, SettingsLayout.rowPadding)
        .padding(.vertical, SettingsLayout.rowVerticalPadding)
        .frame(minHeight: 52)
    }
}

extension SettingsRow where Extra == EmptyView {
    init(_ title: String, detail: String? = nil, symbol: String? = nil, symbolColor: Color = .secondary,
         detailColor: Color = .secondary, truncatesDetail: Bool = false, @ViewBuilder control: () -> Control) {
        self.init(title, detail: detail, symbol: symbol, symbolColor: symbolColor, detailColor: detailColor,
                  truncatesDetail: truncatesDetail, control: control, extra: { EmptyView() })
    }
}

extension SettingsRow where Control == SettingsSwitch, Extra == EmptyView {
    /// A row with a switch; the title doubles as the switch's accessibility label.
    init(_ title: String, detail: String? = nil, symbol: String? = nil, isOn: Binding<Bool>) {
        self.init(title, detail: detail, symbol: symbol, control: { SettingsSwitch(title: title, isOn: isOn) })
    }
}

/// The switch used at the trailing edge of a row.
struct SettingsSwitch: View {
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch)
    }
}

/// A divider between rows, starting under the titles.
struct SettingsDivider: View {
    var symbol = false
    var body: some View { Divider().padding(.leading, SettingsLayout.dividerInset(symbol: symbol)) }
}

/// A note under a section's surface.
struct SettingsNote: View {
    private let text: String
    private let color: Color
    init(_ text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

/// A Library or Settings page: a title, a subtitle, then sections, centred with a readable width.
struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 26, weight: .semibold))
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 4)
                content
            }
            .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 36)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}
