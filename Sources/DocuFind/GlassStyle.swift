import AppKit
import SwiftUI

/// A native, behind-window frost for large surfaces such as the sidebar.
/// Small controls use MagniGlassContainer so their content is embedded in glass.
struct MagniGlassSurface: NSViewRepresentable {
    var radius: CGFloat = 16
    var prominent: Bool = false
    var material: NSVisualEffectView.Material = .sidebar
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeNSView(context: Context) -> MagniFrostedView {
        MagniFrostedView(frame: .zero)
    }

    func updateNSView(_ nsView: MagniFrostedView, context: Context) {
        nsView.configure(radius: radius, prominent: prominent, material: material, reduceTransparency: reduceTransparency)
    }
}

/// Hosts content inside the public NSGlassEffectView on macOS 26 and later.
/// Runtime lookup lets the app remain buildable with the macOS 15 SDK.
/// Earlier systems use AppKit vibrancy; Reduce Transparency uses an opaque fill.
struct MagniGlassContainer<Content: View>: NSViewRepresentable {
    var radius: CGFloat
    var prominent: Bool
    var content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(radius: CGFloat = 16, prominent: Bool = false, @ViewBuilder content: () -> Content) {
        self.radius = radius
        self.prominent = prominent
        self.content = content()
    }

    func makeNSView(context: Context) -> MagniGlassContentView {
        MagniGlassContentView(frame: .zero)
    }

    func updateNSView(_ nsView: MagniGlassContentView, context: Context) {
        nsView.update(
            content: AnyView(content.environment(\.self, context.environment)),
            radius: radius,
            prominent: prominent,
            reduceTransparency: reduceTransparency
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MagniGlassContentView, context: Context) -> CGSize? {
        nsView.contentSize(fitting: proposal)
    }
}

/// Makes the window cooperate with the behind-window material without changing
/// other windows. The previous appearance is restored when the view leaves it.
struct MagniWindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> MagniWindowBackdropView {
        MagniWindowBackdropView(frame: .zero)
    }

    func updateNSView(_ nsView: MagniWindowBackdropView, context: Context) {
        nsView.applyToWindow()
    }

    static func dismantleNSView(_ nsView: MagniWindowBackdropView, coordinator: ()) {
        nsView.restoreWindow()
    }
}

@MainActor
final class MagniFrostedView: NSVisualEffectView {
    private var radius: CGFloat = 16
    private var prominent = false
    private var baseMaterial: NSVisualEffectView.Material = .sidebar
    private var environmentReducesTransparency = false
    private var displayOptionsObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)
        displayOptionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshMaterial() }
        }
        refreshMaterial()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let displayOptionsObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(displayOptionsObserver)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshMaterial()
    }

    func configure(radius: CGFloat, prominent: Bool, material: NSVisualEffectView.Material = .sidebar, reduceTransparency: Bool) {
        self.radius = max(0, radius)
        self.prominent = prominent
        baseMaterial = material
        environmentReducesTransparency = reduceTransparency
        refreshMaterial()
    }

    private func refreshMaterial() {
        let reduced = environmentReducesTransparency || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        material = prominent ? .popover : baseMaterial
        blendingMode = reduced ? .withinWindow : .behindWindow
        state = .followsWindowActiveState
        isEmphasized = prominent
        layer?.cornerRadius = radius
        layer?.masksToBounds = radius > 0
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = reduced ? NSColor.windowBackgroundColor.cgColor : nil
        }
    }
}

@MainActor
final class MagniGlassContentView: NSView {
    private let hostingController = NSHostingController(rootView: AnyView(EmptyView()))
    private var effectView: NSView?
    private var environmentReducesTransparency = false
    private var usesOpaqueMaterial: Bool?
    private var radius: CGFloat = 16
    private var prominent = false
    private var displayOptionsObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hostingController.sizingOptions = [.intrinsicContentSize]
        hostingController.safeAreaRegions = []
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = nil
        displayOptionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshMaterial() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let displayOptionsObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(displayOptionsObserver)
        }
    }

    override var intrinsicContentSize: NSSize { hostingController.view.intrinsicContentSize }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshMaterial()
    }

    func update(content: AnyView, radius: CGFloat, prominent: Bool, reduceTransparency: Bool) {
        hostingController.rootView = content
        self.radius = max(0, radius)
        self.prominent = prominent
        environmentReducesTransparency = reduceTransparency
        refreshMaterial()
        invalidateIntrinsicContentSize()
    }

    func contentSize(fitting proposal: ProposedViewSize) -> CGSize {
        let natural = hostingController.view.intrinsicContentSize
        let proposedWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let width = proposedWidth ?? (natural.width > 0 ? natural.width : 320)
        // A parent VStack may offer its entire remaining height to the bridge.
        // The glass should follow its content, including an optional second row,
        // rather than turn that proposal into a flexible empty control surface.
        let fitted = hostingController.sizeThatFits(in: CGSize(width: width, height: 10_000))
        return CGSize(width: proposedWidth ?? fitted.width, height: fitted.height)
    }

    private func refreshMaterial() {
        let reduced = environmentReducesTransparency || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        if effectView == nil || usesOpaqueMaterial != reduced {
            hostingController.view.removeFromSuperview()
            effectView?.removeFromSuperview()
            let next: NSView
            if reduced {
                next = NSView(frame: bounds)
                next.wantsLayer = true
                installHostedContent(in: next)
            } else if let glass = Self.makeGlassView() {
                // These are documented NSGlassEffectView properties. Selectors
                // are checked before KVC because the build SDK predates them.
                glass.setValue(hostingController.view, forKey: "contentView")
                next = glass
            } else {
                let frost = NSVisualEffectView(frame: bounds)
                frost.material = .popover
                frost.blendingMode = .withinWindow
                frost.state = .followsWindowActiveState
                installHostedContent(in: frost)
                next = frost
            }
            next.frame = bounds
            next.autoresizingMask = [.width, .height]
            addSubview(next)
            effectView = next
            usesOpaqueMaterial = reduced
        }
        guard let effectView else { return }
        if effectView.responds(to: NSSelectorFromString("setCornerRadius:")) {
            effectView.setValue(radius, forKey: "cornerRadius")
            if effectView.responds(to: NSSelectorFromString("setTintColor:")) {
                effectView.setValue(prominent ? NSColor.controlAccentColor.withAlphaComponent(0.05) : nil, forKey: "tintColor")
            }
        } else {
            effectView.wantsLayer = true
            effectView.layer?.cornerRadius = radius
            effectView.layer?.masksToBounds = radius > 0
            if let frost = effectView as? NSVisualEffectView {
                frost.isEmphasized = prominent
            }
        }
        if reduced {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                effectView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
        }
    }

    private func installHostedContent(in view: NSView) {
        let hosted = hostingController.view
        hosted.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosted)
        NSLayoutConstraint.activate([
            hosted.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosted.topAnchor.constraint(equalTo: view.topAnchor),
            hosted.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private static func makeGlassView() -> NSView? {
        guard #available(macOS 26, *),
              let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type else { return nil }
        let view = glassClass.init(frame: .zero)
        guard view.responds(to: NSSelectorFromString("setContentView:")),
              view.responds(to: NSSelectorFromString("setCornerRadius:")) else { return nil }
        return view
    }
}

@MainActor
final class MagniWindowBackdropView: NSView {
    private weak var configuredWindow: NSWindow?
    private var previousAppearance: WindowAppearance?

    private struct WindowAppearance {
        let isOpaque: Bool
        let backgroundColor: NSColor
        let transparentTitlebar: Bool
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyToWindow()
    }

    func applyToWindow() {
        guard configuredWindow !== window else { return }
        restoreWindow()
        guard let window else { return }
        previousAppearance = WindowAppearance(
            isOpaque: window.isOpaque,
            backgroundColor: window.backgroundColor,
            transparentTitlebar: window.titlebarAppearsTransparent
        )
        configuredWindow = window
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
    }

    func restoreWindow() {
        if let configuredWindow, let previousAppearance {
            configuredWindow.isOpaque = previousAppearance.isOpaque
            configuredWindow.backgroundColor = previousAppearance.backgroundColor
            configuredWindow.titlebarAppearsTransparent = previousAppearance.transparentTitlebar
        }
        configuredWindow = nil
        previousAppearance = nil
    }
}
