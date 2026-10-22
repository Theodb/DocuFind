import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// How results appear under the floating bar.
enum QuickSearchLayout: String, CaseIterable {
    case carousel, list
    static let storageKey = "quickSearchLayout"
    var title: String { self == .carousel ? "Carousel" : "List" }
}

/// A borderless, transparent panel that floats above every app and Space.
/// Only its glass bar and cards are visible; clicks elsewhere pass through and hide it.
final class QuickSearchPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 860, height: 660),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { QuickSearchController.shared.hide() }
    override func resignKey() {
        super.resignKey()
        QuickSearchController.shared.panelLostFocus()
    }
}

/// Shows and hides the floating search bar from the global shortcut or the menu bar.
@MainActor
final class QuickSearchController {
    static let shared = QuickSearchController()
    private var panel: QuickSearchPanel?
    private var monitor: Any?
    /// Opening from a link activates the app, which briefly takes focus from the panel.
    private var openedAt = Date.distantPast
    /// The visible view's handler for arrow keys, which a text field would otherwise keep for its cursor.
    var keyHandler: ((UInt16) -> Bool)?
    /// Keeps the bar open while a file chooser or a permission prompt has the focus.
    private var holdOpen = false
    /// Set when a search is entered: the keys then go to the results until the field is clicked.
    private var keysToResults = false
    /// The app that was in front when the bar opened; it gets the keyboard back when the bar closes.
    private var previousApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?

    /// The front window of another app, to keep DocuFind's main window behind it.
    private static func frontWindowNumber(of pid: pid_t) -> Int? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.first { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }?[kCGWindowNumber as String] as? Int
    }

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show(query: String = "") {
        let panel = panel ?? QuickSearchPanel()
        self.panel = panel
        // A fresh view each time, so it opens empty and focused.
        panel.contentView = NSHostingView(rootView: QuickSearchView(model: .shared, initialQuery: query, onClose: { [weak self] in self?.hide() },
                                                                     onLeave: { [weak self] in self?.hide(restoringFocus: false) }))
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            let size = panel.frame.size
            // The bar sits 84 points into the panel, leaving room for its glow to fade out.
            panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.maxY - area.height * 0.14 - size.height + 56))
        }
        installKeyMonitor()
        keysToResults = false
        openedAt = Date()
        // macOS only gives the keyboard to the active app, so DocuFind activates for the bar, like
        // Spotlight, and hands the focus back when it closes. Only the bar is brought forward.
        panel.makeKeyAndOrderFront(nil)
        if !NSApp.isActive {
            let front = NSWorkspace.shared.frontmostApplication
            previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
            let behind = previousApp.flatMap { Self.frontWindowNumber(of: $0.processIdentifier) }
            activationObserver.map(NotificationCenter.default.removeObserver)
            activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let panel = self.panel, panel.isVisible else { return }
                    self.activationObserver.map(NotificationCenter.default.removeObserver)
                    self.activationObserver = nil
                    // Activation brings the main window forward too; put it back behind the app you were in.
                    if let behind {
                        for window in NSApp.windows where window !== panel && window.isVisible && window.level == .normal {
                            window.order(.below, relativeTo: behind)
                        }
                    }
                    panel.makeKeyAndOrderFront(nil)
                    self.focusField()
                }
            }
            NSApp.activate(ignoringOtherApps: true)
        }
        focusField()
    }

    /// Puts the cursor in the search field, so typing works without a click. SwiftUI's own focus
    /// request arrives before the panel is key and is dropped, so this goes through AppKit, twice
    /// in case the view is still being laid out.
    func focusField() {
        keysToResults = false
        for delay in [0.0, 0.12, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let panel = self?.panel, panel.isVisible, let content = panel.contentView else { return }
                let field = Self.textField(in: content)
                guard let field, panel.firstResponder !== field.currentEditor() else { return }
                panel.makeFirstResponder(field)
            }
        }
    }

    /// Takes the cursor out of the search field, so the keys move through the results instead.
    func leaveField() {
        keysToResults = true
        panel?.makeFirstResponder(nil)
    }

    /// Whether the keys go to the results: after a search is entered, until the field is clicked again.
    func keysGoToResults() -> Bool {
        if keysToResults, let panel, let content = panel.contentView, let editor = Self.textField(in: content)?.currentEditor(),
           panel.firstResponder === editor {
            keysToResults = false
        }
        return keysToResults
    }

    private static func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews { if let field = textField(in: subview) { return field } }
        return nil
    }

    /// Runs something that takes the focus away (a file chooser, a permission prompt) without hiding the bar.
    func keepOpen<T>(_ work: () async -> T) async -> T {
        holdOpen = true
        defer {
            holdOpen = false
            panel?.makeKeyAndOrderFront(nil)
            focusField()
        }
        return await work()
    }

    func chooseFile() async -> URL? {
        await keepOpen {
            let chooser = NSOpenPanel()
            chooser.message = "Choose a photo, recording or document to find files like it."
            chooser.allowsMultipleSelection = false
            chooser.level = .modalPanel
            NSApp.activate(ignoringOtherApps: true)
            return chooser.runModal() == .OK ? chooser.url : nil
        }
    }

    func panelLostFocus() {
        guard !holdOpen, Date().timeIntervalSince(openedAt) > 0.6 else { return }
        hide()
    }

    /// Closes the bar. `restoringFocus` returns to the app that was in front, which is right for Esc or a click
    /// elsewhere, but not after opening a file: the window just opened must stay in front.
    func hide(restoringFocus: Bool = true) {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        PassagePlayer.shared.stop()
        if QueryRecorder.shared.isRecording, QueryRecorder.shared.startedByQuickBar { QueryRecorder.shared.cancel() }
        // Back to the app that was in front, unless the user moved to another one meanwhile.
        if restoringFocus, let previous = previousApp, NSApp.isActive, !previous.isTerminated {
            previous.activate()
        }
        previousApp = nil
    }

    private func installKeyMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.window is QuickSearchPanel,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  let handled = self?.keyHandler?(event.keyCode), handled else { return event }
            return nil
        }
    }
}

/// The floating bar with the app's glow. Results show as a Cover Flow carousel
/// (with the recording player) or as a list of separate glass cards, per Settings.
struct QuickSearchView: View {
    @ObservedObject var model: AppModel
    var initialQuery = ""
    let onClose: () -> Void
    /// Closes the bar after opening or revealing something, leaving that in front.
    let onLeave: () -> Void
    @AppStorage(QuickSearchLayout.storageKey) private var layout = QuickSearchLayout.carousel.rawValue
    @State private var query = ""
    @State private var results: [SearchItem] = []
    @State private var selection = 0
    @State private var refining: Task<Void, Never>?
    /// Bumped by each new set of results (not by refined passages), to cross-fade the carousel.
    @State private var resultSet = 0
    @State private var lastPointer = NSPoint.zero
    @State private var searching = false
    @State private var searchedQuery = ""
    @State private var reference: URL?
    @State private var failure: String?
    @State private var pending: Task<Void, Never>?
    @State private var dropTargeted = false
    /// After moving through results with the arrow keys, Space plays the selected recording;
    /// typing any other key returns to the search text.
    @State private var browsing = false
    /// Space's large view of the selected result, as in the main window; Space again goes back.
    @State private var previewing = false
    @ObservedObject private var recorder = QueryRecorder.shared
    @FocusState private var focused: Bool

    private var isCarousel: Bool { layout != QuickSearchLayout.list.rawValue }
    private var shown: [SearchItem] { Array(results.prefix(12)) }
    private var bestScore: Double { results.map(\.score).max() ?? 0 }
    private var terms: [String] { SearchTerms.parse(searchedQuery) }

    var body: some View {
        VStack(spacing: isCarousel ? 18 : 8) {
            bar
            if previewing, shown.indices.contains(selection) { previewPane(shown[selection]) }
            else if isCarousel { carousel } else { list }
            if let failure {
                Text(failure).font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .frame(maxWidth: 600)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else if !searching && (!searchedQuery.isEmpty || reference != nil) && results.isEmpty {
                Text(reference == nil ? "Nothing close to “\(searchedQuery)”." : "Nothing close to this file.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .padding(.horizontal, 18).frame(height: 44)
                    .background(.regularMaterial, in: Capsule())
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: results.map(\.id))
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: previewing)
        .padding(.horizontal, 30).padding(.top, 84)
        .frame(width: 860, height: 660, alignment: .top)
        // Observed here, not inside the glass container: that renders in its own AppKit host.
        .onChange(of: query) { _, _ in schedule() }
        .onAppear {
            focused = true
            QuickSearchController.shared.keyHandler = { handleKey($0) }
            if !initialQuery.isEmpty {
                query = initialQuery
                schedule()
            }
        }
    }

    // MARK: Bar

    private var bar: some View {
        MagniGlassContainer(radius: 26, prominent: true) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary)
                if recorder.isRecording {
                    RecordingStrip(recorder: recorder, compact: false)
                    barButton("xmark", "Discard the recording") { recorder.cancel() }
                    Button { recorder.stop() } label: {
                        RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: 11, height: 11)
                            .frame(width: 34, height: 34).background(Circle().fill(Color.red))
                    }
                    .buttonStyle(.plain).help("Stop and search (Return)").accessibilityLabel("Stop recording and search")
                } else {
                    if let reference {
                        HStack(spacing: 5) {
                            Image(systemName: SearchTerms.symbol(SearchTerms.kind(of: reference))).font(.system(size: 11, weight: .semibold))
                            Text(SearchTerms.isRecording(reference) ? "Your recording" : reference.lastPathComponent)
                                .font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 150)
                            Button { clearReference() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Stop searching with this file")
                        }
                        .padding(.horizontal, 9).frame(height: 28)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                    TextField(reference == nil ? "Search your Mac by meaning…" : "Files like this", text: $query)
                        .textFieldStyle(.plain).font(.system(size: 18))
                        .focused($focused)
                        .onSubmit(submit)
                    if searching { ProgressView().controlSize(.small) }
                    barButton("mic", "Record a sound or a song to search with (up to 30 seconds)") { record() }
                        .disabled(!model.connected || !model.dependenciesReady)
                    barButton("paperclip", "Search with a file: a photo, recording or document. You can also drop one here.") { upload() }
                }
            }
            .padding(.leading, 20).padding(.trailing, 10)
            .frame(width: 600, height: 52)
        }
        .frame(width: 600, height: 52)
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.accentColor.opacity(dropTargeted ? 0.8 : 0), lineWidth: 2))
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in searchLike(url) } }
            }
            return true
        }
        // Shadows come from rounded shapes; an AppKit glass view would cast a square one.
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.86))
            .shadow(color: .black.opacity(0.28), radius: 24, y: 12))
        .background { SearchAura(busy: searching, compact: false) }
    }

    private func barButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                .frame(width: 30, height: 30).contentShape(Circle())
        }
        .buttonStyle(.plain).foregroundStyle(.secondary).help(label).accessibilityLabel(label)
    }

    private func record() {
        Task {
            // The first time, macOS asks for the microphone; the bar stays open meanwhile.
            await QuickSearchController.shared.keepOpen {
                recorder.startedByQuickBar = true
                await recorder.start { url in searchLike(url) }
            }
        }
    }

    private func upload() {
        Task {
            if let url = await QuickSearchController.shared.chooseFile() { searchLike(url) }
        }
    }

    private func clearReference() {
        pending?.cancel()
        reference = nil
        results = []
        searchedQuery = ""
        searching = false
        QuickSearchController.shared.focusField()
    }

    // MARK: Carousel

    @ViewBuilder private var carousel: some View {
        if shown.indices.contains(selection) {
            CoverFlow(items: shown, selection: selection, terms: terms,
                      onSelect: { select($0) }, onOpen: { open($0) })
                // A new set of results cross-fades as a whole instead of shuffling the old cards around.
                .id(resultSet)
                .transition(.opacity)
            HStack(spacing: 12) {
                arrow("chevron.left", enabled: selection > 0, label: "Previous match") { move(-1) }
                details(shown[selection])
                arrow("chevron.right", enabled: selection < shown.count - 1, label: "Next match") { move(1) }
            }
        }
    }

    /// Title, strength and actions for the centred cover, in a compact glass pill.
    private func details(_ item: SearchItem) -> some View {
        MagniGlassContainer(radius: 22) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 7) {
                        StrengthPill(strength: MatchStrength(score: item.score, best: bestScore))
                        ExactPill(item: item)
                        Text(String(format: "%.3f similarity", item.score))
                            .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
                            .help("Cosine similarity between your search and this file. Higher is closer; it is not a percentage.")
                        Text([SearchTerms.detail(for: item), SearchTerms.copiesNote(item)].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 11.5)).foregroundStyle(.tertiary).lineLimit(1)
                        Text("\(selection + 1) of \(shown.count)").font(.system(size: 11.5)).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(-1)
                pillButton("arrow.up.forward.app", "Open (Return)") { open(item) }
                pillButton("folder", "Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                    onLeave()
                }
                pillButton("sparkle.magnifyingglass", "Find similar") { findSimilar(item) }
            }
            .padding(.leading, 18).padding(.trailing, 10)
            // The glass hosts its content separately, so the width must be fixed here too,
            // or a long name is measured at full length and runs past the pill.
            // With the arrows on each side, the row is as wide as the search bar (600).
            .frame(width: 504, height: 58)
        }
        .frame(width: 504, height: 58)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.5)))
    }

    private func arrow(_ symbol: String, enabled: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .bold))
                .frame(width: 36, height: 36)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.2)))
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.35).accessibilityLabel(label)
    }

    private func pillButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }

    // MARK: List

    /// Scrolls within the panel; the selected row is kept in view as the arrows move it.
    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 10) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                        QuickResultCard(item: item, terms: terms, strength: MatchStrength(score: item.score, best: bestScore),
                                        selected: index == selection, onOpen: { open(item) })
                            .frame(width: 600)
                            .id(item.id)
                            // Only a moving pointer selects: rows scrolling under a still one (keyboard) leave it alone.
                            .onContinuousHover { phase in
                                guard case .active = phase, NSEvent.mouseLocation != lastPointer else { return }
                                lastPointer = NSEvent.mouseLocation
                                browsing = false
                                select(index)
                            }
                            .transition(.opacity)
                    }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            // Fades the rows out at the edges instead of cutting them.
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.02),
                                         .init(color: .black, location: 0.95), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: 640)
            .frame(maxHeight: 500)
            .onChange(of: selection) { _, next in
                guard shown.indices.contains(next) else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(shown[next].id) }
            }
        }
    }

    // MARK: Behaviour

    /// ↑ ↓ always move; ← → move the carousel once there are results.
    /// Whether the results on screen answer exactly what is typed (or the file searched with).
    private var showsResultsForField: Bool {
        reference != nil || query.trimmingCharacters(in: .whitespacesAndNewlines) == searchedQuery
    }

    private func handleKey(_ code: UInt16) -> Bool {
        // After Return the field lets go, as in the main window: arrows move, Space shows a document or photo large
        // (Space again goes back) or plays a recording, Return opens and Esc steps back. Other keys do nothing
        // until the field is clicked.
        if QuickSearchController.shared.keysGoToResults() {
            switch code {
            case 123: move(-1)
            case 124: move(1)
            case 126 where !previewing: move(-1)
            case 125 where !previewing: move(1)
            case 49: act()
            case 36, 76: if shown.indices.contains(selection) { open(shown[selection]) }
            case 53: if previewing { previewing = false } else { onClose() }
            case 48: return false
            default: break
            }
            return true
        }
        guard !shown.isEmpty else { return false }
        switch code {
        case 125: move(1)
        case 126: move(-1)
        // ← → move through the carousel whenever its results are for the text in the field (or after ↓ ↑). While
        // the text differs (a search on the way), they move the cursor; ⌥/⌘ arrows always edit the text.
        case 124 where isCarousel && (browsing || showsResultsForField): move(1)
        case 123 where isCarousel && (browsing || showsResultsForField): move(-1)
        case 49 where browsing && shown.indices.contains(selection) && shown[selection].kind == "audio":
            // Plays the selected recording; on other results Space types a space as usual.
            PassagePlayer.shared.toggle(shown[selection])
        case 36, 76, 53, 48:  // Return, Enter, Escape and Tab keep their usual meaning.
            return false
        default:
            browsing = false
            return false
        }
        if code != 49 { browsing = true }
        return true
    }

    /// Searches shortly after typing pauses; the model stays loaded, so this feels live.
    private func schedule() {
        pending?.cancel()
        refining?.cancel()
        previewing = false
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            if reference == nil { results = []; searchedQuery = ""; searching = false; failure = nil }
            return
        }
        reference = nil
        pending = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await run(text)
        }
    }

    private func run(_ text: String) async {
        searching = true
        failure = nil
        do {
            let found = try await model.quickSearch(text: text)
            guard text == query.trimmingCharacters(in: .whitespacesAndNewlines), reference == nil else { return }
            show(found, for: text)
        } catch {
            guard text == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            searching = false
            failure = error.localizedDescription
        }
    }

    private func findSimilar(_ item: SearchItem) {
        searchLike(URL(fileURLWithPath: item.path))
    }

    /// Files like a photo, recording or document: a result, a dropped or chosen file, or a recording.
    private func searchLike(_ url: URL) {
        pending?.cancel()
        refining?.cancel()
        reference = url
        query = ""
        searching = true
        failure = nil
        Task {
            do {
                let found = try await model.quickSearch(similarTo: url.path)
                guard reference == url else { return }
                show(found.filter { $0.path != url.path }, for: "")
            } catch {
                guard reference == url else { return }
                searching = false
                failure = error.localizedDescription
            }
        }
    }

    private func show(_ found: [SearchItem], for text: String) {
        PassagePlayer.shared.stop()
        previewing = false
        if found.map(\.id) != results.map(\.id) { resultSet += 1 }
        results = found
        refining?.cancel()
        if !text.isEmpty {
            refining = Task {
                let better = await model.refinedSnippets(for: found, query: text)
                // Only for the search that asked: an older one's passages must not land on newer results.
                guard !Task.isCancelled, searchedQuery == text, results.map(\.id) == found.map(\.id) else { return }
                results = results.map { item in better[item.id].map { var copy = item; copy.snippet = $0.snippet; copy.location = $0.location; return copy } ?? item }
            }
        }
        searchedQuery = text
        selection = 0
        searching = false
    }

    /// Return searches now if the search hasn't run yet, then hands the keys to the results.
    private func submit() {
        if recorder.isRecording { recorder.stop(); return }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty && text != searchedQuery { pending?.cancel(); Task { await run(text) } }
        if !text.isEmpty || !shown.isEmpty { QuickSearchController.shared.leaveField() }
    }

    /// Space on a result: plays or pauses a recording; shows anything else large, or goes back.
    private func act() {
        guard shown.indices.contains(selection) else { return }
        let item = shown[selection]
        if item.kind == "audio" { PassagePlayer.shared.toggle(item) } else { previewing.toggle() }
    }

    /// The selected result large, like the main window's preview: the whole document or photo, with the arrows and
    /// details below.
    private func previewPane(_ item: SearchItem) -> some View {
        VStack(spacing: 14) {
            FileCover(item: item, terms: terms, paperLines: 7, paperSize: 15, playable: true, scrollable: true, bare: true)
                .frame(width: 600, height: 400)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.2)))
                .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
                .id(item.id)
                .transition(.opacity)
            HStack(spacing: 12) {
                arrow("chevron.left", enabled: selection > 0, label: "Previous match") { move(-1) }
                details(item)
                arrow("chevron.right", enabled: selection < shown.count - 1, label: "Next match") { move(1) }
            }
        }
        .transition(.scale(scale: 0.94).combined(with: .opacity))
    }

    private func move(_ delta: Int) {
        guard !shown.isEmpty else { return }
        // Stops at the ends, like the chevrons and dragging.
        select(max(0, min(shown.count - 1, selection + delta)))
    }

    private func select(_ index: Int) {
        guard index != selection else { return }
        PassagePlayer.shared.stop()
        selection = index
    }

    private func open(_ item: SearchItem) {
        FileOpener.open(item, query: searchedQuery)
        onLeave()
    }
}

/// Cover Flow in the flat style: the current match as a large rounded card in the
/// centre, its neighbours as narrow rounded slivers that thin out towards the edges.
/// No reflections or shadows. Click a sliver, swipe, or use the arrows to move.
private struct CoverFlow: View {
    let items: [SearchItem]
    let selection: Int
    let terms: [String]
    let onSelect: (Int) -> Void
    let onOpen: (SearchItem) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragSteps = 0

    private let centre = CGSize(width: 340, height: 212)
    /// Sliver sizes by distance from the centre.
    private let slivers: [CGSize] = [CGSize(width: 58, height: 186), CGSize(width: 36, height: 156), CGSize(width: 14, height: 112)]
    private let gap: CGFloat = 12

    var body: some View {
        ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let offset = index - selection
                let size = self.size(offset)
                card(item, centred: offset == 0)
                    // The artwork keeps the centre size; this frame is a window onto it, so a sliver
                    // widening into the centre reveals more of the same image instead of rescaling it.
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: min(26, size.width / 2), style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: min(26, size.width / 2), style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: min(26, size.width / 2), style: .continuous)
                        .strokeBorder(.white.opacity(offset == 0 ? 0.35 : 0.2), lineWidth: 1))
                    .offset(x: position(offset))
                    .opacity(abs(offset) > slivers.count ? 0 : 1)
                    .zIndex(Double(10 - abs(offset)))
                    .onTapGesture { offset == 0 ? (item.kind == "audio" ? () : onOpen(item)) : onSelect(index) }
                    .allowsHitTesting(abs(offset) <= slivers.count)
                    .accessibilityHidden(abs(offset) > slivers.count)
                    .accessibilityLabel(item.title)
                    .accessibilityAddTraits(offset == 0 ? [.isButton, .isSelected] : .isButton)
            }
        }
        .frame(width: 780, height: centre.height)
        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.9), value: selection)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 12).onChanged { value in
            // Swipe or drag sideways to move, one match per 70 points.
            let steps = Int((-value.translation.width / 70).rounded())
            if steps != dragSteps {
                let target = max(0, min(items.count - 1, selection + steps - dragSteps))
                dragSteps = steps
                onSelect(target)
            }
        }.onEnded { _ in dragSteps = 0 })
    }

    /// A cropped artwork layer that is always there, and the full card (whole photo, label,
    /// passage or player) cross-fading in as the card reaches the centre.
    private func card(_ item: SearchItem, centred: Bool) -> some View {
        ZStack {
            FileCover(item: item, minimal: true)
                .frame(width: centre.width, height: centre.height)
            Group {
                if item.kind == "text" {
                    // Like a recording: the same paint as the sliver, with the page floating on it, so opening the card
                    // only reveals more paint and the page fades in on top.
                    DocumentOnPaint(item: item, terms: terms)
                } else {
                    FileCover(item: item, terms: terms, paperLines: 3, paperSize: 11, playable: centred)
                }
            }
            .frame(width: centre.width, height: centre.height)
            .opacity(centred ? 1 : 0)
            .allowsHitTesting(centred)
        }
    }

    private func size(_ offset: Int) -> CGSize {
        if offset == 0 { return centre }
        let level = min(abs(offset), slivers.count) - 1
        return abs(offset) > slivers.count ? CGSize(width: 4, height: 60) : slivers[level]
    }

    /// Centre of each card: the centre card, then slivers packed outwards with even gaps.
    private func position(_ offset: Int) -> CGFloat {
        guard offset != 0 else { return 0 }
        var x = centre.width / 2
        for level in 1...abs(offset) {
            let width = size(level).width
            x += gap + (level == abs(offset) ? width / 2 : width)
        }
        return offset < 0 ? -x : x
    }
}

/// One result as its own glass box: cover, name, strength and similarity, where it
/// matched, and for recordings a player for the matched passage on a painted strip.
private struct QuickResultCard: View {
    let item: SearchItem
    let terms: [String]
    let strength: MatchStrength
    let selected: Bool
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                FileCover(item: item, minimal: true)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: SearchTerms.symbol(item.kind)).font(.system(size: 10, weight: .bold))
                            .frame(width: 22, height: 22).background(.regularMaterial, in: Circle()).padding(4)
                    }
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    if item.kind == "text" {
                        Text(SearchTerms.highlighted(item.snippet, terms: terms))
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    HStack(spacing: 7) {
                        StrengthPill(strength: strength)
                        ExactPill(item: item)
                        Text(String(format: "%.3f similarity", item.score))
                            .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
                        Text([SearchTerms.detail(for: item), SearchTerms.copiesNote(item)].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 11.5)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(-1)
                Button(action: onOpen) {
                    Image(systemName: selected ? "return" : "arrow.up.forward.app").font(.system(size: 12, weight: .semibold))
                        .frame(width: 32, height: 32).background(Circle().fill(Color.primary.opacity(selected ? 0.12 : 0.06)))
                }
                .buttonStyle(.plain).help("Open (Return)").accessibilityLabel("Open")
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            if item.kind == "audio" {
                PaintedCoverView(key: item.path, palette: .forKind(item.kind))
                    .overlay(RecordingPlayer(item: item, compact: true))
                    .frame(height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(selected ? Color.primary.opacity(0.5) : Color.white.opacity(0.14), lineWidth: selected ? 2 : 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
