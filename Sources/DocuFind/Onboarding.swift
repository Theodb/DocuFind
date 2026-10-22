import AppKit
import SwiftUI

/// Detects Full Disk Access without triggering a permission prompt.
enum DiskAccess {
    static func hasFullDiskAccess() -> Bool {
        let home = NSHomeDirectory()
        // The TCC database is readable only with Full Disk Access.
        if let handle = FileHandle(forReadingAtPath: home + "/Library/Application Support/com.apple.TCC/TCC.db") {
            try? handle.close()
            return true
        }
        if let handle = FileHandle(forReadingAtPath: home + "/Library/Safari/Bookmarks.plist") {
            try? handle.close()
            return true
        }
        return (try? FileManager.default.contentsOfDirectory(atPath: home + "/Library/Mail")) != nil
    }
}

/// First-launch walkthrough: choose folders, grant access once, then index.
struct OnboardingView: View {
    @ObservedObject var model: AppModel
    let onFinish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Int
    @State private var hasAccess = DiskAccess.hasFullDiskAccess()
    @State private var openAtLogin = LoginItem.isEnabled
    @ObservedObject private var shortcut = GlobalShortcut.shared

    init(model: AppModel, step: Int = 0, onFinish: @escaping () -> Void) {
        self.model = model
        self.onFinish = onFinish
        _step = State(initialValue: step)
    }

    private static let stepCount = 4
    /// The last step, where setup finishes before the first index.
    static let setupStep = stepCount - 1

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: folders
                case 2: access
                default: ready
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 40).padding(.top, 36)
            .id(step)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)), removal: .opacity))
            footer
        }
        // Tall enough for the setup step (three progress bars and the two choices) with a margin above the footer.
        .frame(width: 640, height: 620)
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: step)
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 18) {
            PaintedLogo(size: 132, animating: !reduceMotion).padding(.top, 34)
            Text("Search your Mac by meaning")
                .font(.system(size: 32, weight: .semibold)).tracking(-0.9)
                .multilineTextAlignment(.center)
            Text("Describe a document, a photo or a sound in your own words. DocuFind reads your files on this Mac and nothing leaves it.")
                .font(.system(size: 14)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineSpacing(3).frame(maxWidth: 440)
            Text(setupNeeded ? "Get Started also downloads the search model (about 3.5 GB, once), so it is ready by the time you finish." : "Setup takes about a minute.")
                .font(.system(size: 12)).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 440).padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    private var folders: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Choose what to search", detail: "DocuFind indexes the documents, photos and recordings in these folders.")
            VStack(spacing: 0) {
                if model.roots.isEmpty {
                    Text("Add a folder to get started.").font(.system(size: 13)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
                ForEach(Array(model.roots.enumerated()), id: \.element) { index, root in
                    if index > 0 { Divider().padding(.leading, SettingsLayout.dividerInset(symbol: true)) }
                    HStack(spacing: 12) {
                        Image(systemName: root == NSHomeDirectory() ? "house.fill" : "folder.fill")
                            .font(.system(size: 18)).foregroundStyle(.blue).frame(width: 26)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(root == NSHomeDirectory() ? "Home Folder" : URL(fileURLWithPath: root).lastPathComponent)
                                .font(.system(size: 13, weight: .medium))
                            Text(root.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button { Task { await model.removeRoot(root) } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.indexing)
                            .accessibilityLabel("Remove \(root)").help("Remove this folder")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
            }
            .background(card)
            HStack {
                Button("Add Folder…") { model.addFolder() }.disabled(model.indexing)
                Spacer()
            }
            Text("External drives are not included in your Home Folder. Add each drive you want to search.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Allow access once", detail: "macOS asks separately for Desktop, Documents, Downloads and other folders. Turn on Full Disk Access for DocuFind once and those prompts stop.")
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield.fill").font(.system(size: 18)).foregroundStyle(.green)
                Text("Everything runs on this Mac. DocuFind reads your files only to index them here: nothing is uploaded, and there is no account or cloud.")
                    .font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.green.opacity(0.1)))
            .accessibilityElement(children: .combine)
            HStack(alignment: .center, spacing: 18) {
                // The icon itself is what to drag: no box of its own inside the card.
                VStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                        .resizable().frame(width: 72, height: 72)
                        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                    Text("Drag me").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
                .onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider() }
                .help("Drag into the Full Disk Access list")
                .accessibilityLabel("DocuFind app. Drag into the Full Disk Access list.")
                VStack(alignment: .leading, spacing: 8) {
                    instruction(1, "Open Privacy Settings.")
                    instruction(2, "Drag DocuFind into the list, then turn it on.")
                    instruction(3, "Come back here. This page updates by itself.")
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(card)
            HStack(spacing: 10) {
                Image(systemName: hasAccess ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.system(size: 18)).foregroundStyle(hasAccess ? Color.green : Color.secondary)
                Text(hasAccess ? "Full Disk Access is on" : "Waiting for Full Disk Access…")
                    .font(.system(size: 13, weight: .medium))
                if !hasAccess { ProgressView().controlSize(.small) }
            }
            .accessibilityElement(children: .combine)
            Text("If DocuFind still can’t read a folder after an update, switch this permission off and on again.")
                .font(.system(size: 11.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .task {
            while !Task.isCancelled {
                hasAccess = DiskAccess.hasFullDiskAccess()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !setupNeeded {
                header("Ready to index", detail: "DocuFind will read \(model.roots.count == 1 ? "your folder" : "your \(model.roots.count) folders") and build a private index on this Mac.")
                HStack(spacing: 14) {
                    PaintedLogo(size: 56, animating: !reduceMotion && model.indexing)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.indexing ? "Indexing started" : "Start when you are ready").font(.system(size: 14, weight: .semibold))
                        Text("The first index can take a while. Files become searchable as they finish, and you can stop at any time.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading).background(card)
            } else {
                header("Install the search model", detail: "DocuFind runs the model on this Mac's Neural Engine. Setup downloads it once with its runtime (about 3.5 GB). After that, search works offline.")
                VStack(alignment: .leading, spacing: 12) {
                    if settingUp {
                        SetupProgressView(model: model)
                    } else {
                        if let error = model.error {
                            Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        }
                        Button(model.error == nil ? "Install" : "Try Again") { Task { await model.setUp() } }
                            .buttonStyle(.borderedProminent).disabled(model.indexing)
                    }
                    Text("You can keep using your Mac meanwhile.").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading).background(card)
            }
            // Both on by default; either can be changed here or later in Settings.
            VStack(alignment: .leading, spacing: 12) {
                choice("Quick search shortcut",
                       detail: !shortcut.isEnabled ? "Off. Turn it on to search from any app with a keyboard shortcut."
                           : shortcut.isRegistered ? "Press it in any app to open a search bar over what you're doing. Click the shortcut to pick another one."
                           : "Another app already uses this shortcut. Click it and press a different one.",
                       warning: shortcut.isEnabled && !shortcut.isRegistered,
                       isOn: Binding(get: { shortcut.isEnabled }, set: { shortcut.setEnabled($0) })) {
                    if shortcut.isEnabled { ShortcutRecorder().frame(width: 150, height: 28) }
                }
                Divider()
                choice("Open DocuFind at login", detail: "Keeps the search model loaded, so results are instant.",
                       isOn: Binding(get: { openAtLogin }, set: { value in
                           try? LoginItem.set(value)
                           openAtLogin = LoginItem.isEnabled
                       }))
            }
            // The same width and inner margins as the card above it.
            .padding(18).frame(maxWidth: .infinity, alignment: .leading).background(card)
        }
    }

    /// Text on the left; the switch (and any control for the choice) on the right, centred on the text.
    private func choice(_ title: String, detail: String, warning: Bool = false, isOn: Binding<Bool>,
                        @ViewBuilder control: () -> some View = { EmptyView() }) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(warning ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                ForEach(0..<Self.stepCount, id: \.self) { index in
                    Capsule().fill(index == step ? Color.primary : Color.primary.opacity(0.18))
                        .frame(width: index == step ? 18 : 7, height: 7)
                }
            }
            .accessibilityElement().accessibilityLabel("Step \(step + 1) of \(Self.stepCount)")
            if settingUp && step < Self.stepCount - 1 { setupBadge }
            Spacer()
            if step > 0 { Button("Back") { step -= 1 } }
            switch step {
            case 2:
                if !hasAccess { Button("Skip, allow folders one at a time") { step += 1 } }
                Button("Continue") { step += 1 }.keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).disabled(!hasAccess)
            case 3:
                // Setup can't be put off: without the model there is nothing to search with.
                if !setupNeeded { Button("Not now", action: onFinish) }
                Button("Start Indexing") {
                    Task { await model.index() }
                    onFinish()
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                .disabled(setupNeeded || !model.connected || model.indexing || model.roots.isEmpty)
            default:
                Button(step == 0 ? "Get Started" : "Continue") {
                    // Setup runs while the remaining steps are filled in.
                    if step == 0 && setupNeeded && !settingUp { Task { await model.setUp() } }
                    step += 1
                }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(step == 1 && model.roots.isEmpty)
            }
        }
        .controlSize(.large)
        // No band of its own: the buttons line up with the content above, on the same glow.
        .padding(.horizontal, 40).padding(.top, 12).padding(.bottom, 28)
    }

    // MARK: Helpers

    private var setupNeeded: Bool { model.setupNeeded }
    private var settingUp: Bool { model.installing || model.downloadingModel }

    /// Setup's progress while the other steps are on screen.
    private var setupBadge: some View {
        // The packages are about 5% of the bytes; the model is the rest.
        let runtime = model.dependenciesReady ? 1 : model.runtimeProgress ?? 0
        let weights = model.modelDownloaded ? 1 : model.modelDownload?.fraction ?? 0
        let fraction = 0.05 * runtime + 0.95 * weights
        return HStack(spacing: 6) {
            ProgressView(value: fraction).progressViewStyle(.circular).controlSize(.small)
            Text("Setting up… \(Int(fraction * 100))%").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.leading, 12)
        .accessibilityElement(children: .combine)
    }

    /// A light, see-through card, so it sits on the frosted glow instead of cutting a dark block out of it.
    private var card: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.primary.opacity(0.05))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))
    }

    private func header(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 28, weight: .semibold)).tracking(-0.8)
            Text(detail).font(.system(size: 13.5)).foregroundStyle(.secondary).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                .frame(width: 18, height: 18).background(Circle().fill(Color.primary.opacity(0.08)))
            Text(text).font(.system(size: 13))
        }
    }
}

/// The guide filling the window, on the launch screen's painted glow, while setup isn't finished.
struct OnboardingScreen: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The window is the only box: the guide sits on one frosted layer over the glow, with no panel of its own.
        OnboardingView(model: model, step: model.onboardingStep, onFinish: { model.finishOnboarding() })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
            .background(LaunchBackdrop(animating: !reduceMotion))
            .ignoresSafeArea()
    }
}
