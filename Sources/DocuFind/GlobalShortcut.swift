import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// A system-wide key combination. Stored with Carbon modifier flags because the
/// hot-key API needs them; RegisterEventHotKey needs no Accessibility permission.
struct KeyShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var key: String

    static let standard = KeyShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), key: "Space")

    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + " " + key
    }

    /// Builds a shortcut from a key press; needs ⌘, ⌥ or ⌃ so ordinary typing never triggers it.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        guard carbon & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        let names: [Int: String] = [kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Escape: "Esc",
                                    kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓"]
        let name = names[Int(event.keyCode)] ?? (event.charactersIgnoringModifiers ?? "").uppercased()
        guard !name.isEmpty else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: carbon, key: name)
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }
}

/// Owns the one global hot key that shows the floating search bar.
@MainActor
final class GlobalShortcut: ObservableObject {
    static let shared = GlobalShortcut()
    private static let storageKey = "quickSearchShortcut"
    private static let enabledKey = "quickSearchShortcutEnabled"
    @Published private(set) var shortcut: KeyShortcut
    /// False when another app already owns the combination, or when the shortcut is off.
    @Published private(set) var isRegistered = false
    /// On unless turned off in setup or Settings.
    @Published private(set) var isEnabled: Bool
    var onPress: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    private init() {
        LegacySettings.migrate()
        shortcut = UserDefaults.standard.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(KeyShortcut.self, from: $0) } ?? .standard
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func register() {
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { GlobalShortcut.shared.onPress?() }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        guard isEnabled else { isRegistered = false; return }
        let id = EventHotKeyID(signature: OSType(0x4F4D_4E46), id: 1) // 'OMNF'
        isRegistered = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &hotKey) == noErr
    }

    /// Frees the combination while a new one is being recorded, so it can be pressed again.
    func suspend() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    func setEnabled(_ on: Bool) {
        isEnabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        register()
    }

    func update(_ next: KeyShortcut) {
        shortcut = next
        if let data = try? JSONEncoder().encode(next) { UserDefaults.standard.set(data, forKey: Self.storageKey) }
        register()
    }
}

/// Click, then press the new combination. Esc or clicking away cancels.
/// The field becomes first responder and receives the keys itself, including ⌘ combinations.
struct ShortcutRecorder: NSViewRepresentable {
    func makeNSView(context: Context) -> ShortcutRecorderView { ShortcutRecorderView() }
    func updateNSView(_ view: ShortcutRecorderView, context: Context) { view.refresh() }
}

final class ShortcutRecorderView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var recording = false { didSet { refresh() } }
    private var liveModifiers: NSEvent.ModifierFlags = []
    private var hint: String?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 150, height: 28))
        wantsLayer = true
        layer?.cornerRadius = 8
        label.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 150), heightAnchor.constraint(equalToConstant: 28),
        ])
        setAccessibilityRole(.button)
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 28) }

    override func mouseDown(with event: NSEvent) {
        if recording { finish() } else { begin() }
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        capture(event)
    }

    /// ⌘ combinations arrive as key equivalents rather than key-downs.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        capture(event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard recording else { return super.flagsChanged(with: event) }
        liveModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        hint = nil
        refresh()
    }

    override func resignFirstResponder() -> Bool {
        if recording { finish() }
        return super.resignFirstResponder()
    }

    private func begin() {
        Task { @MainActor in GlobalShortcut.shared.suspend() }
        recording = true
        liveModifiers = []
        hint = nil
        window?.makeFirstResponder(self)
    }

    private func capture(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { return finish() }
        if let next = KeyShortcut(event: event) {
            Task { @MainActor in GlobalShortcut.shared.update(next) }
            finish(keeping: next)
        } else {
            hint = "Add ⌘, ⌥ or ⌃"
            NSSound.beep()
            refresh()
        }
    }

    private func finish(keeping next: KeyShortcut? = nil) {
        recording = false
        if next == nil { Task { @MainActor in GlobalShortcut.shared.register() } }
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        DispatchQueue.main.async { self.refresh() }
    }

    func refresh() {
        let current = MainActor.assumeIsolated { GlobalShortcut.shared.shortcut.display }
        if recording {
            var held = ""
            if liveModifiers.contains(.control) { held += "⌃" }
            if liveModifiers.contains(.option) { held += "⌥" }
            if liveModifiers.contains(.shift) { held += "⇧" }
            if liveModifiers.contains(.command) { held += "⌘" }
            label.stringValue = hint ?? (held.isEmpty ? "Press keys…" : held + " …")
            label.textColor = hint == nil ? .controlAccentColor : .systemOrange
        } else {
            label.stringValue = current
            label.textColor = .labelColor
        }
        // Layer colours are fixed values, so resolve them in this view's light or dark appearance.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderWidth = recording ? 2 : 1
            layer?.borderColor = (recording ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
        setAccessibilityLabel(recording ? "Recording shortcut. Press the new keys, or Escape to cancel." : "Quick search shortcut, \(current). Click to change.")
    }
}

/// Opening DocuFind at login, so the shortcut and the loaded model are always ready.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Turns it on once, on first launch; afterwards the user's choice in Settings stands.
    static func enableOnFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: "loginItemConfigured") else { return }
        UserDefaults.standard.set(true, forKey: "loginItemConfigured")
        try? SMAppService.mainApp.register()
    }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
