import AppKit
import PDFKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// The Search page: a calm home with one glowing search field, then a
/// best-match-first results page. Documents and recordings get painted covers;
/// photos show their own thumbnail.
struct SearchExperience: View {
    @ObservedObject var model: AppModel
    var focus: FocusState<Bool>.Binding
    let onSetUpLibrary: () -> Void
    @Namespace private var namespace
    @State private var preview: SearchItem?
    @State private var previewSpace: CGFloat = 900
    @Environment(\.colorScheme) private var colorScheme
    /// The match shown in the spotlight card; nil means the best match.
    @State private var focusedID: SearchItem.ID?
    @State private var scrollRequest = 0
    @State private var keyMonitor: Any?

    private var showingResults: Bool { model.hasSearched }
    /// The words of the search that produced the results, not whatever the field holds now.
    private var terms: [String] { SearchTerms.parse(model.searchedQuery) }
    private var visible: [SearchItem] { model.filter == "all" ? model.results : model.results.filter { $0.kind == model.filter } }
    private var bestScore: Double { model.results.map(\.score).max() ?? 0 }
    private var canSearch: Bool {
        model.connected && model.dependenciesReady && !model.searching && !model.installing
            && (!model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.reference != nil)
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollViewReader { proxy in
                ScrollView {
                    Color.clear.frame(height: 0).id(Self.top)
                    Group {
                        if showingResults { resultsPage } else { homePage }
                    }
                    .frame(maxWidth: 1180)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 48)
                }
                // Start at the top; recent files arrive after launch and must not shift the view.
                .defaultScrollAnchor(.top)
                .onChange(of: model.results.map(\.id)) { _, _ in
                    proxy.scrollTo(Self.top, anchor: .top)
                    PassagePlayer.shared.stop()
                    focusedID = nil
                    // A preview of the old results would show stale data.
                    preview = nil
                    // Hand the arrow keys to the results once they arrive.
                    if !model.results.isEmpty { focus.wrappedValue = false }
                }
                .onChange(of: model.filter) { _, _ in focusedID = nil; PassagePlayer.shared.stop() }
                .onChange(of: scrollRequest) { _, _ in
                    withAnimation(.smooth(duration: 0.45)) { proxy.scrollTo(Self.top, anchor: .top) }
                }
                .onChange(of: showingResults) { _, _ in proxy.scrollTo(Self.top, anchor: .top) }
            }
            if showingResults {
                // Content scrolls under the floating search field. This band hides it from the window's top edge
                // (under the transparent title bar too) to just below the field, then fades out.
                LinearGradient(
                    stops: [.init(color: Color(nsColor: .windowBackgroundColor), location: 0),
                            .init(color: Color(nsColor: .windowBackgroundColor), location: 0.8),
                            .init(color: Color(nsColor: .windowBackgroundColor).opacity(0), location: 1)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 124)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
                searchField(compact: true)
                    .frame(maxWidth: 520)
                    .padding(.top, 14)
                    .padding(.horizontal, 28)
            }
        }
        .animation(.smooth(duration: 0.5), value: showingResults)
        .overlay {
            // The preview floats over a dimmed page; clicking outside it, Esc or Done goes back.
            if let item = preview {
                ZStack {
                    Color.black.opacity(colorScheme == .dark ? 0.5 : 0.32)
                        .ignoresSafeArea()
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { previewSpace = $0 }
                        .contentShape(Rectangle())
                        .onTapGesture { closePreview() }
                        .accessibilityLabel("Close preview")
                        .accessibilityAddTraits(.isButton)
                    FilePreviewSheet(
                        item: item, terms: terms, strength: MatchStrength(score: item.score, best: bestScore),
                        reason: reason(for: item),
                        onOpen: { open(item); closePreview() }, onReveal: { reveal(item) },
                        onSimilar: { closePreview(); findSimilar(item) },
                        onClose: closePreview,
                        position: previewPosition,
                        onPrevious: { step(-1) }, onNext: { step(1) },
                        availableHeight: previewSpace - 48
                    )
                    .id(item.id)
                    .transition(.opacity)
                    .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.regularMaterial))
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.14)))
                    .shadow(color: .black.opacity(0.35), radius: 40, y: 20)
                    .padding(24)
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
                }
                .onExitCommand { closePreview() }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: preview?.id)
        // The keyboard tour over the real page; hidden while a preview covers it.
        .overlayPreferenceValue(TourAnchorKey.self) { anchors in
            if preview == nil, model.tourStep != nil { TourOverlay(model: model, anchors: anchors) }
        }
        .onChange(of: model.searching) { _, searching in if !searching && model.hasSearched { model.tourDid(.search) } }
        .onChange(of: preview?.id) { old, id in
            if id != nil { focus.wrappedValue = false }
            // Space opened the preview and Space closed it again.
            if old != nil && id == nil { model.tourDid(.look) }
        }
        // Typing into the field (Cmd-F) closes the preview, so its arrows and Space don't take the keys.
        .onChange(of: focus.wrappedValue) { _, focused in if focused { preview = nil } }
        .onAppear(perform: installKeys)
        .onDisappear {
            PassagePlayer.shared.stop()
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    /// ← → Space and Return for the results and the preview, read from the key events themselves. As button
    /// shortcuts, SwiftUI kept running an earlier render's action after the selection changed: Space previewed the
    /// previous match, and the arrows stopped working once a preview had closed.
    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in handleKey(event) ? nil : event }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        // Only the main window, with no modifier, and not while typing in a field or recording a search.
        guard let window = event.window, window.isKeyWindow, window.identifier?.rawValue.hasPrefix("main") == true,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              !(window.firstResponder is NSText), !QueryRecorder.shared.isRecording else { return false }
        if let item = preview {
            switch event.keyCode {
            case 123: step(-1)
            case 124: step(1)
            case 49: if item.kind == "audio" { PassagePlayer.shared.toggle(item) } else { closePreview() }
            case 36, 76: open(item); closePreview()
            default: return false
            }
            return true
        }
        guard showingResults, !model.searching, visible.indices.contains(focusedIndex) else { return false }
        let item = visible[focusedIndex]
        switch event.keyCode {
        case 123: moveFocus(-1)
        case 124: moveFocus(1)
        case 49: if item.kind == "audio" { PassagePlayer.shared.toggle(item) } else { preview = item }
        case 36, 76: open(item)
        default: return false
        }
        return true
    }

    private func closePreview() {
        preview = nil
        // When the preview goes, macOS hands the keyboard to the search field, which would turn off the arrows and
        // Space for the results. They keep it: clicking the field is what returns to typing.
        focus.wrappedValue = false
        DispatchQueue.main.async { focus.wrappedValue = false }
    }

    private var focusedIndex: Int { visible.firstIndex { $0.id == focusedID } ?? 0 }

    private func moveFocus(_ delta: Int) {
        let next = focusedIndex + delta
        guard visible.indices.contains(next) else { return }
        PassagePlayer.shared.stop()
        focusedID = visible[next].id
        model.tourDid(.move)
    }

    private func focus(on item: SearchItem) {
        if item.id != visible[focusedIndex].id { PassagePlayer.shared.stop() }
        focusedID = item.id
        scrollRequest += 1
    }

    /// The list the preview steps through: the filtered results, or the recent files on Home.
    private var previewList: [SearchItem] {
        guard let id = preview?.id else { return [] }
        return visible.contains { $0.id == id } ? visible : jumpBackIn
    }

    private var previewPosition: (index: Int, count: Int)? {
        guard let id = preview?.id, let index = previewList.firstIndex(where: { $0.id == id }) else { return nil }
        return (index, previewList.count)
    }

    private func step(_ delta: Int) {
        guard let position = previewPosition else { return }
        let next = position.index + delta
        guard previewList.indices.contains(next) else { return }
        PassagePlayer.shared.stop()
        preview = previewList[next]
        if visible.contains(where: { $0.id == previewList[next].id }) { focusedID = previewList[next].id }
    }

    // MARK: Home

    /// Recent files people care about: machine-made ones (lock files, requirements, configs) left out.
    private var jumpBackIn: [SearchItem] {
        let machine = ["requirements", ".lock", "package.json", ".yaml", ".yml", ".toml", ".cfg", ".ini", "license", "notices"]
        return Array(model.recent.filter { item in !machine.contains { item.title.lowercased().contains($0) } }.prefix(8))
    }

    /// The field first, with where to look under it, then what was opened lately. No headline: the window is the app,
    /// and the sidebar already says what is indexed.
    private var homePage: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 14) {
                searchField(compact: false)
                    .frame(maxWidth: 600)
                if model.indexedCount > 0 && model.dependenciesReady {
                    ScopeBar(model: model) { focus.wrappedValue = true }
                }
            }
            .padding(.top, 64).padding(.bottom, 44)
            .frame(maxWidth: .infinity)
            // The launch screen's painted glow, faint, behind the field only.
            .background(alignment: .top) {
                // Painted at a quarter size and scaled up: it is blurred anyway, and painting is costly.
                // The seed keeps the app's earlier name, so the artwork stays the same.
                PaintedCoverView(key: "magnifind-home-glow", palette: .aura)
                    .frame(width: 225, height: 105)
                    .scaleEffect(4)
                    .frame(width: 900, height: 300)
                    .clipShape(Ellipse())
                    .blur(radius: 90)
                    .opacity(0.2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if model.indexedCount == 0 || !model.dependenciesReady {
                setupCard
            } else if !jumpBackIn.isEmpty {
                Text("Recent").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.bottom, 12)
                // As many per row as fit; narrow windows wrap instead of squeezing.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 16, alignment: .top)], alignment: .leading, spacing: 20) {
                    ForEach(jumpBackIn) { item in
                        RecentTile(item: item, onOpen: { preview = item })
                    }
                }
            }
        }
    }

    private var setupCard: some View {
        VStack(spacing: 10) {
            Text(model.dependenciesReady ? "Your library is empty" : "Finish setting up").font(.system(size: 19, weight: .semibold))
            Text(model.dependenciesReady
                 ? "Choose the folders DocuFind should read, then start indexing. Files become searchable as they finish."
                 : "Install the local model runtime, then choose the folders DocuFind should read.")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Set Up Library", action: onSetUpLibrary).buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 6)
        }
        .padding(36).frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    // MARK: Results

    private var resultsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The filter sits beside the title when both fit, otherwise under it.
            WidthSwitch(threshold: 900) {
                HStack(alignment: .bottom, spacing: 20) {
                    resultsHeading.layoutPriority(1)
                    Spacer(minLength: 12)
                    filterBar
                }
            } narrow: {
                VStack(alignment: .leading, spacing: 18) {
                    resultsHeading
                    filterBar
                }
            }
            .padding(.top, 88).padding(.bottom, 24)
            if model.searching {
                ResultsPlaceholder(columns: Self.gridColumns)
            } else if !visible.isEmpty {
                let spotlight = visible[focusedIndex]
                SpotlightCard(
                    item: spotlight, terms: terms, strength: MatchStrength(score: spotlight.score, best: bestScore),
                    reason: reason(for: spotlight),
                    position: (focusedIndex, visible.count),
                    shortcutsEnabled: preview == nil && !focus.wrappedValue,
                    onPrevious: { moveFocus(-1) }, onNext: { moveFocus(1) },
                    onPreview: { preview = spotlight }, onOpen: { open(spotlight) },
                    onReveal: { reveal(spotlight) }, onSimilar: { findSimilar(spotlight) }
                )
                .tourAnchor(.move, .look)
                if visible.count > 1 {
                    sectionHeader("All matches", detail: "\(visible.count) files").padding(.top, 56)
                    LazyVGrid(columns: Self.gridColumns, alignment: .leading, spacing: 28) {
                        ForEach(visible) { item in
                            // Clicking a card brings it into the spotlight; double-click opens the file.
                            ResultCard(item: item, terms: terms, strength: MatchStrength(score: item.score, best: bestScore),
                                       focused: item.id == visible[focusedIndex].id,
                                       onPreview: { focus(on: item) }, onOpen: { open(item) },
                                       onReveal: { reveal(item) }, onSimilar: { findSimilar(item) })
                        }
                    }
                }
            } else {
                emptyResults
            }
        }
    }

    private var resultsHeading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 36, weight: .semibold)).tracking(-1).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(summary).font(.system(size: 14)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let notice = model.searchNotice, !model.searching {
                Label(notice, systemImage: "quote.opening").font(.system(size: 12.5)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var emptyResults: some View {
        VStack(spacing: 8) {
            Text(model.results.isEmpty ? "Nothing close to this yet" : "No \(KindFilter.name(model.filter).lowercased()) match this")
                .font(.system(size: 19, weight: .semibold))
            Text(model.results.isEmpty
                 ? (model.indexedCount == 0 ? "Index a folder first, then search again." : "Try describing it another way, or search with a file that looks or sounds like it.")
                 : "Switch back to All to see all \(model.results.count) matches.")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(44).frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    private var title: String {
        let text = model.searchedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [text.isEmpty ? nil : "“\(text)”", model.reference.map { SearchTerms.isRecording($0) ? "sounds like your recording" : "like \($0.lastPathComponent)" }].compactMap { $0 }
        guard !parts.isEmpty else { return "Search" }
        let joined = parts.joined(separator: " ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    /// The kind filter, only once there are results to filter (all zeros while searching looks broken).
    @ViewBuilder private var filterBar: some View {
        if !model.searching && !model.results.isEmpty {
            KindFilter(selection: $model.filter, counts: kindCounts)
        }
    }

    private var kindCounts: [String: Int] {
        var counts = ["all": model.results.count]
        for item in model.results { counts[item.kind, default: 0] += 1 }
        return counts
    }

    private var summary: String {
        if model.searching { return "Finding the closest files on this Mac…" }
        let n = model.results.count
        guard n > 0 else { return "No close matches." }
        let parts = [("text", "document"), ("image", "photo"), ("audio", "recording")].compactMap { kind, noun -> String? in
            guard let count = kindCounts[kind], count > 0 else { return nil }
            return "\(count) \(noun)\(count == 1 ? "" : "s")"
        }
        return "\(n) \(n == 1 ? "match" : "matches") · " + parts.joined(separator: ", ")
    }

    private func reason(for item: SearchItem) -> AttributedString {
        SearchTerms.reason(for: item, terms: terms, reference: model.reference)
    }

    // MARK: Search field

    private func searchField(compact: Bool) -> some View {
        SearchField(model: model, focus: focus, compact: compact, canSearch: canSearch,
                    onSubmit: runSearch, onClear: { model.clearSearch(); focus.wrappedValue = true })
            .matchedGeometryEffect(id: "search", in: namespace)
            .tourAnchor(.search)
    }

    private func sectionHeader(_ title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 20, weight: .semibold)).tracking(-0.4)
            Spacer()
            if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.tertiary) }
        }.padding(.bottom, 16)
    }

    private func runSearch() { if canSearch { Task { await model.search() } } }
    private func open(_ item: SearchItem) {
        FileOpener.open(item, query: model.searchedQuery)
        model.tourDid(.open)
    }
    private func reveal(_ item: SearchItem) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
    private func findSimilar(_ item: SearchItem) {
        model.reference = URL(fileURLWithPath: item.path)
        model.query = ""
        model.filter = "all"
        runSearch()
    }

    private static let top = "search-top"
    // Two columns fit in the narrowest window.
    private static let gridColumns = [GridItem(.adaptive(minimum: 200), spacing: 20, alignment: .top)]
}

// MARK: - Search field

private struct SearchField: View {
    @ObservedObject var model: AppModel
    var focus: FocusState<Bool>.Binding
    let compact: Bool
    let canSearch: Bool
    let onSubmit: () -> Void
    let onClear: () -> Void
    @ObservedObject private var recorder = QueryRecorder.shared
    @State private var dropTargeted = false
    /// The field's width, measured outside the glass.
    @State private var width: CGFloat = 0

    var body: some View {
        MagniGlassContainer(radius: compact ? 21 : 26, prominent: true) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: compact ? 14 : 18, weight: .medium)).foregroundStyle(.secondary)
                if recorder.isRecording {
                    RecordingStrip(recorder: recorder, compact: compact)
                    Button { recorder.cancel() } label: { Image(systemName: "xmark").font(.system(size: compact ? 11 : 13, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Discard the recording").accessibilityLabel("Discard recording")
                    Button { recorder.stop() } label: {
                        RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: compact ? 10 : 13, height: compact ? 10 : 13)
                            .frame(width: compact ? 30 : 44, height: compact ? 30 : 44)
                            .background(Circle().fill(Color.red))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                    .help("Stop and search (Return)").accessibilityLabel("Stop recording and search")
                } else {
                    inputRow
                }
            }
            .padding(.leading, compact ? 14 : 18).padding(.trailing, compact ? 5 : 8)
            // The glass hosts its content separately and would grow to the text's full width,
            // so the content takes the width measured outside it.
            .frame(width: width > 0 ? width : nil, height: compact ? 40 : 52)
        }
        .frame(height: compact ? 40 : 52)
        .animation(.smooth(duration: 0.2), value: canSearch)
        .background(GeometryReader { geometry in
            Color.clear
                .onAppear { width = geometry.size.width }
                .onChange(of: geometry.size.width) { _, value in width = value }
        })
        // Keep the glow around the edge; the field itself stays calm and readable.
        .background(RoundedRectangle(cornerRadius: compact ? 21 : 26, style: .continuous).fill(Color(nsColor: .windowBackgroundColor).opacity(0.86)))
        .background { SearchAura(busy: model.searching || recorder.isRecording, compact: compact) }
        .overlay {
            RoundedRectangle(cornerRadius: compact ? 21 : 26, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(dropTargeted ? 0.8 : 0), lineWidth: 2)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in model.reference = url } }
            }
            return true
        }
    }

    @ViewBuilder private var inputRow: some View {
                if let reference = model.reference {
                    ReferenceChip(url: reference, compact: compact) { model.reference = nil }
                }
                TextField(model.reference == nil ? "Describe a document, photo or sound…" : "Add words to narrow it down…", text: $model.query)
                    .textFieldStyle(.plain).font(.system(size: compact ? 14 : 16))
                    .focused(focus).onSubmit(onSubmit)
                    .accessibilityLabel("Search description")
                Button {
                    Task { recorder.startedByQuickBar = false; await recorder.start { url in model.reference = url; onSubmit() } }
                } label: {
                    Image(systemName: "mic").font(.system(size: compact ? 13 : 16, weight: .medium))
                        .frame(width: compact ? 26 : 32, height: compact ? 26 : 32)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(!model.connected || !model.dependenciesReady)
                .help("Record a sound or a song to search with (up to 30 seconds)")
                .accessibilityLabel("Record to search")
                Button { model.chooseReference() } label: {
                    Image(systemName: "paperclip").font(.system(size: compact ? 13 : 16, weight: .medium))
                        .frame(width: compact ? 26 : 32, height: compact ? 26 : 32)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Search with a file: an image, recording, text file or PDF. You can also drop one here.")
                .accessibilityLabel("Search with a file")
                if model.hasSearched || !model.query.isEmpty || model.reference != nil {
                    Button(action: onClear) { Image(systemName: "xmark").font(.system(size: compact ? 11 : 13, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Clear search").accessibilityLabel("Clear search")
                }
                // Return searches; the button only appears once there is something to search, for the mouse.
                if canSearch {
                    Button(action: onSubmit) {
                        Image(systemName: "arrow.up").font(.system(size: compact ? 12 : 13, weight: .semibold))
                            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                            .frame(width: compact ? 30 : 34, height: compact ? 30 : 34)
                            .background(Circle().fill(Color.primary))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(focus.wrappedValue ? .defaultAction : nil)
                    .help("Search (Return)").accessibilityLabel("Search library")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
    }
}

/// The painted glow behind the search field. It drifts slowly and brightens while searching.
struct SearchAura: View {
    private func animate(_ busy: Bool) {
        guard !reduceMotion else { return }
        if busy {
            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) { drift = true }
        } else {
            withAnimation(.easeInOut(duration: 0.6)) { drift = false }
        }
    }

    let busy: Bool
    let compact: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var drift = false
    private var blurRadius: CGFloat { compact ? 14 : 24 }

    var body: some View {
        if !reduceTransparency {
            // The seed keeps the app's earlier name, so the artwork stays the same.
            PaintedCoverView(key: "magnifind-search-aura", palette: .aura)
                .scaleEffect(1.3)
                .offset(x: drift ? 28 : -28)
                .rotationEffect(.degrees(drift ? 3 : -3))
                .padding(.horizontal, compact ? -14 : -26)
                .padding(.vertical, compact ? -8 : -18)
                .clipShape(Capsule())
                // A transparent margin lets the blur fade all the way out instead of stopping at an edge.
                .padding(blurRadius * 2)
                .blur(radius: blurRadius)
                .padding(-blurRadius * 2)
                .opacity(busy ? 1 : (compact ? 0.45 : 0.5))
                .animation(.easeInOut(duration: 0.4), value: busy)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                // Drifts only while busy (searching, recording); at rest it stays still and costs nothing.
                .onAppear { animate(busy) }
                .onChange(of: busy) { _, value in animate(value) }
        }
    }
}

private struct ReferenceChip: View {
    let url: URL
    let compact: Bool
    let onRemove: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            FileDot(path: url.path, kind: SearchTerms.kind(of: url)).frame(width: compact ? 18 : 22, height: compact ? 18 : 22)
            Text(SearchTerms.isRecording(url) ? "Your recording" : url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: compact ? 110 : 180, alignment: .leading)
            Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("Stop searching like \(SearchTerms.referenceName(url))")
        }
        .padding(.leading, 4).padding(.trailing, 8).frame(height: compact ? 26 : 30)
        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor).opacity(0.9)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
    }
}

// MARK: - Match navigation

/// Previous / next arrows over a cover, with ← and → as shortcuts, and the position in the list.
struct MatchNavigator: View {
    let position: (index: Int, count: Int)
    let shortcutsEnabled: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        if position.count > 1 {
            HStack {
                arrow("chevron.left", enabled: position.index > 0, key: .leftArrow, label: "Previous match", action: onPrevious)
                Spacer()
                arrow("chevron.right", enabled: position.index < position.count - 1, key: .rightArrow, label: "Next match", action: onNext)
            }
            .padding(.horizontal, 14)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                // "Match", so it isn't read as a page number next to a PDF's page label.
                Text("Match \(position.index + 1) of \(position.count)")
                    .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 10)
            }
        }
    }

    private func arrow(_ symbol: String, enabled: Bool, key: KeyEquivalent, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .bold))
                .frame(width: 40, height: 40)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.2)))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }
}

// MARK: - Loading

/// Shown in place of results while a search runs: the page's own layout, painted
/// softly and catching a slow sheen, so results arrive without a jump.
private struct ResultsPlaceholder: View {
    let columns: [GridItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The same two layouts as the spotlight card.
            WidthSwitch(threshold: 380 + 28 + 320) {
                HStack(alignment: .top, spacing: 28) {
                    painted(.aura, key: "placeholder-best").frame(minWidth: 380, maxWidth: .infinity).frame(height: 340)
                    lines.frame(width: 320, alignment: .leading).padding(.top, 10)
                }
            } narrow: {
                VStack(alignment: .leading, spacing: 18) {
                    painted(.aura, key: "placeholder-best").frame(height: 240)
                    lines.padding(.bottom, 10)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Color.primary.opacity(0.045)))
            line(width: 120, height: 16).padding(.top, 56).padding(.bottom, 18)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                ForEach(Array([CoverPalette.documents, .photos, .recordings].enumerated()), id: \.offset) { index, palette in
                    VStack(alignment: .leading, spacing: 12) {
                        painted(palette, key: "placeholder-\(index)").aspectRatio(16 / 10, contentMode: .fit)
                        line(width: 150, height: 12)
                        line(width: 100, height: 10)
                    }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Finding the closest files")
        .transition(.opacity)
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: 14) {
            line(width: 150, height: 10)
            line(width: 260, height: 26)
            line(width: 200, height: 10)
            line(width: 110, height: 20).padding(.top, 6)
            line(width: 280, height: 12).padding(.top, 10)
            line(width: 240, height: 12)
        }
    }

    private func painted(_ palette: CoverPalette, key: String) -> some View {
        PaintedCoverView(key: key, palette: palette)
            .opacity(0.32)
            .modifier(Sheen())
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func line(width: CGFloat, height: CGFloat) -> some View {
        Capsule().fill(Color.primary.opacity(0.08)).frame(width: width, height: height).modifier(Sheen())
    }
}

/// A slow diagonal sheen; still under Reduce Motion.
private struct Sheen: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -0.7

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geometry in
                    LinearGradient(colors: [.clear, .white.opacity(0.18), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: max(40, geometry.size.width * 0.5))
                        .offset(x: phase * geometry.size.width)
                }
                .allowsHitTesting(false)
            }
            .clipped()
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1.2 }
            }
    }
}

// MARK: - Filter

private struct KindFilter: View {
    @Binding var selection: String
    let counts: [String: Int]
    @Namespace private var namespace
    static let kinds = [("all", "All", "square.grid.2x2"), ("text", "Documents", "doc.text"), ("image", "Photos", "photo"), ("audio", "Recordings", "waveform")]
    static func name(_ kind: String) -> String { kinds.first { $0.0 == kind }?.1 ?? "Files" }

    var body: some View {
        // Each variant has its own glass: the glass hosts its content separately, so it needs a fixed size.
        WidthSwitch(threshold: 470, alignment: .leading) {
            bar(labelled: true)
        } narrow: {
            bar(labelled: false)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func bar(labelled: Bool) -> some View {
        MagniGlassContainer(radius: 19) {
            HStack(spacing: 2) {
                ForEach(Self.kinds, id: \.0) { kind, label, symbol in
                    Button { withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { selection = kind } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: symbol).font(.system(size: 11))
                            if labelled {
                                Text(label).font(.system(size: 12.5, weight: selection == kind ? .semibold : .regular))
                            }
                            Text("\(counts[kind] ?? 0)").font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
                        }
                        .fixedSize()
                        .foregroundStyle(selection == kind ? Color.primary : Color.secondary)
                        .padding(.horizontal, 12).frame(height: 30)
                        .background {
                            if selection == kind {
                                Capsule().fill(Color(nsColor: .controlBackgroundColor))
                                    .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(labelled ? "" : label)
                    .accessibilityLabel("\(label), \(counts[kind] ?? 0)")
                    .accessibilityAddTraits(selection == kind ? .isSelected : [])
                }
            }.padding(4)
        }
        .fixedSize()
    }
}

// MARK: - Cards

enum MatchStrength {
    case strong, close, related
    /// BidirLM cosine scores are not calibrated percentages, so strength is relative to the best match.
    init(score: Double, best: Double) {
        let gap = best - score
        self = gap <= 0.03 ? .strong : gap <= 0.08 ? .close : .related
    }
    var label: String { switch self { case .strong: "Top match"; case .close: "Close"; case .related: "Related" } }
}

struct StrengthPill: View {
    let strength: MatchStrength
    var body: some View {
        Text(strength.label).font(.system(size: 10.5, weight: .semibold))
            .fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 2.5)
            .foregroundStyle(strength == .strong ? Color(nsColor: .windowBackgroundColor) : Color.secondary)
            .background(Capsule().fill(strength == .strong ? Color.primary : Color.primary.opacity(0.07)))
    }
}

/// A recent file on the home page, the way Finder's Recents shows it: the photo itself, the document's first page,
/// or a recording's painted waveform; then its name, its folder and when it changed. No badges: the picture says it.
private struct RecentTile: View {
    let item: SearchItem
    let onOpen: () -> Void
    @State private var hovering = false
    /// When the file changed, read once off the main thread rather than on every redraw.
    @State private var modified = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cover
                .frame(height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(hovering ? 0.18 : 0.06), radius: hovering ? 12 : 6, y: hovering ? 6 : 3)
                .scaleEffect(hovering ? 1.02 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text([SearchTerms.folder(of: item), modified].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { value in withAnimation(.smooth(duration: 0.2)) { hovering = value } }
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .task(id: item.path) {
            let path = item.path
            let date = await Task.detached(priority: .utility) {
                (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            }.value
            modified = date?.formatted(.relative(presentation: .named)) ?? ""
        }
    }

    @ViewBuilder private var cover: some View {
        switch item.kind {
        case "image": FileCover(item: item, minimal: true)
        case "audio":
            PaintedCoverView(key: item.path, palette: .forKind(item.kind))
                .overlay { WaveformBars(seed: item.path).frame(height: 40).padding(.horizontal, 22) }
        default:
            // Text and Markdown drawn by the app, styled; Quick Look would show their raw source.
            if DocumentExcerpt.plainExtensions.contains(URL(fileURLWithPath: item.path).pathExtension.lowercased()) {
                DocumentPage(item: item, terms: [], lines: 7, size: 8.5, plain: true)
            } else if item.isPDF {
                PDFTopThumbnail(path: item.path)
            } else {
                PageThumbnail(path: item.path)
            }
        }
    }
}

/// The top of a PDF's first page, large enough to read its title: a whole page at tile size is mostly margin and
/// unreadable type.
private struct PDFTopThumbnail: View {
    let path: String
    @State private var image: NSImage?

    var body: some View {
        // In an overlay, so the picture fills the tile without widening its column.
        Color.white
            .overlay(alignment: .topLeading) {
                if let image { Image(nsImage: image).resizable().scaledToFill().transition(.opacity) }
            }
            .clipped()
        .task(id: path) {
            let path = path
            let rendered = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let document = PDFDocument(url: URL(fileURLWithPath: path)), !document.isLocked,
                      let page = document.page(at: 0) else { return nil }
                // The top-left three quarters of the page's width, in the tile's 4:3 shape.
                let bounds = page.bounds(for: .cropBox)
                let width = bounds.width * 0.78, height = width * 0.75
                let band = CGRect(x: bounds.minX + bounds.width * 0.03, y: bounds.maxY - height - bounds.height * 0.015, width: width, height: height)
                let scale = 640 / band.width
                guard let context = CGContext(data: nil, width: Int(band.width * scale), height: Int(band.height * scale), bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
                else { return nil }
                context.setFillColor(.white); context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
                context.scaleBy(x: scale, y: scale); context.translateBy(x: -band.minX, y: -band.minY)
                page.draw(with: .cropBox, to: context)
                return context.makeImage()
            }.value
            if let rendered { withAnimation(.easeOut(duration: 0.2)) { image = NSImage(cgImage: rendered, size: NSSize(width: rendered.width, height: rendered.height)) } }
        }
    }
}

/// A document's first page as Finder draws it (Quick Look), the top of the page filling the tile.
private struct PageThumbnail: View {
    let path: String
    @Environment(\.displayScale) private var scale
    @State private var image: NSImage?

    var body: some View {
        // In an overlay, so the page fills the tile without widening its column.
        Color.primary.opacity(0.05)
            .overlay(alignment: .top) {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                        .padding(.top, 12).padding(.horizontal, 14)
                        .transition(.opacity)
                }
            }
            .clipped()
        .task(id: path) {
            let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: 240, height: 320),
                                                       scale: scale, representationTypes: .thumbnail)
            if let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                withAnimation(.easeOut(duration: 0.2)) { image = thumbnail.nsImage }
            }
        }
    }
}

/// Where the next search looks: everything or one kind, with how many of each are indexed. It carries into the
/// results, where the same filter stays.
private struct ScopeBar: View {
    @ObservedObject var model: AppModel
    let onPick: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            chip("all", "All", "square.grid.2x2", model.indexedCount)
            chip("text", "Documents", "doc.text", model.kindCounts["text"] ?? 0)
            chip("image", "Photos", "photo", model.kindCounts["image"] ?? 0)
            chip("audio", "Recordings", "waveform", model.kindCounts["audio"] ?? 0)
        }
    }

    @ViewBuilder private func chip(_ kind: String, _ title: String, _ symbol: String, _ count: Int) -> some View {
        if kind == "all" || count > 0 {
            let selected = model.filter == kind
            Button { model.filter = kind; onPick() } label: {
                HStack(spacing: 5) {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                    Text(title).font(.system(size: 12, weight: .medium))
                    Text(count.formatted()).font(.system(size: 12)).monospacedDigit().foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 11).frame(height: 28)
                .background(Capsule().fill(Color.primary.opacity(selected ? 0.12 : 0.04)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(selected ? 0.16 : 0.07)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .accessibilityLabel("\(title), \(count)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(kind == "all" ? "Search everything" : "Search only \(title.lowercased())")
        }
    }
}

private struct ResultCard: View {
    let item: SearchItem
    let terms: [String]
    let strength: MatchStrength?
    var focused = false
    let onPreview: () -> Void
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onSimilar: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FileCover(item: item, terms: terms, paperLines: 3)
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
                .overlay {
                    if focused {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.85), lineWidth: 2.5)
                            .padding(-5)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Button(action: onSimilar) {
                        Text("Find similar").font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10).frame(height: 26)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain).padding(10)
                    .opacity(hovering ? 1 : 0)
                    .accessibilityLabel("Find files similar to \(item.title)")
                }
                .shadow(color: .black.opacity(hovering ? 0.16 : 0), radius: 18, y: 12)
                .offset(y: hovering ? -3 : 0)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                // The pills keep their size; the location truncates when the card is narrow.
                HStack(spacing: 7) {
                    pills.fixedSize()
                    detail.layoutPriority(-1)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { value in withAnimation(.smooth(duration: 0.3)) { hovering = value } }
        .onTapGesture(perform: onPreview)
        // Single clicks act at once; a double click also opens the file.
        .simultaneousGesture(TapGesture(count: 2).onEnded(onOpen))
        .contextMenu {
            Button("Open", action: onOpen)
            Button("Show in Finder", action: onReveal)
            Divider()
            Button("Find Similar Files", action: onSimilar)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title)\(strength.map { ", \($0.label)" } ?? "")")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open", onOpen)
        .accessibilityAction(named: "Find similar", onSimilar)
    }

    @ViewBuilder private var pills: some View {
        if let strength { StrengthPill(strength: strength) }
        ExactPill(item: item)
    }

    private var detail: some View {
        Text([SearchTerms.detail(for: item), SearchTerms.copiesNote(item)].compactMap { $0 }.joined(separator: " · "))
            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
    }
}

struct SpotlightCard: View {
    let item: SearchItem
    let terms: [String]
    let strength: MatchStrength
    let reason: AttributedString
    let position: (index: Int, count: Int)
    let shortcutsEnabled: Bool
    var showsExpand = true
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onPreview: () -> Void
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onSimilar: () -> Void

    var body: some View {
        WidthSwitch(threshold: 380 + 28 + 320) {
            HStack(alignment: .top, spacing: 28) {
                cover.frame(minWidth: 380, maxWidth: .infinity).frame(height: 340)
                details.frame(width: 320)
            }
        } narrow: {
            VStack(alignment: .leading, spacing: 18) {
                cover.frame(height: 240)
                details
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
        .shadow(color: .black.opacity(0.06), radius: 24, y: 16)
    }

    private var cover: some View {
        let base = FileCover(item: item, terms: terms, paperLines: 5, paperSize: 14, playable: true, onTap: onPreview, onDoubleTap: onOpen, scrollable: true)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay { MatchNavigator(position: position, shortcutsEnabled: shortcutsEnabled, onPrevious: onPrevious, onNext: onNext) }
            .overlay(alignment: .topTrailing) {
                if showsExpand { Button(action: onPreview) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 12, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(.regularMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.2)))
                }
                .buttonStyle(.plain).padding(10)
                .help(item.kind == "audio" ? "Preview" : "Preview (Space)").accessibilityLabel("Open preview") }
            }
        // A recording's cover is its player, so it takes no tap gestures that could catch waveform clicks.
        return Group {
            if item.kind == "audio" {
                base
            } else {
                base.contentShape(Rectangle())
                    .onTapGesture(perform: onPreview)
                    // Single clicks act at once; a double click also opens the file.
                    .simultaneousGesture(TapGesture(count: 2).onEnded(onOpen))
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(position.index == 0 ? "Best match" : "Match \(position.index + 1)") · \(SearchTerms.folder(of: item))")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 6) {
                FileTitle(name: item.title, size: 26)
                FolderLine(path: item.path)
                CopiesMenu(item: item)
            }
            HStack(spacing: 7) {
                StrengthPill(strength: strength)
                ExactPill(item: item)
            }
            Text(reason).font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Button("Open", action: onOpen).buttonStyle(.borderedProminent)
                    .tourAnchor(.open)
                Button("Show in Finder", action: onReveal)
                Button("Find Similar", action: onSimilar)
            }.controlSize(.large)
        }
        .padding(.vertical, 10).padding(.trailing, 6)
    }
}

struct FilePreviewSheet: View {
    let item: SearchItem
    let terms: [String]
    let strength: MatchStrength
    let reason: AttributedString
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onSimilar: () -> Void
    let onClose: () -> Void
    let position: (index: Int, count: Int)?
    let onPrevious: () -> Void
    let onNext: () -> Void

    /// The height the preview may use, measured by the page behind it.
    var availableHeight: CGFloat = 900

    var body: some View {
        if item.kind == "text" || item.kind == "image" {
            fileSheet
        } else {
            // The cover gets shorter in short windows, so the details and buttons stay visible. Chosen from the space
            // on offer rather than with ViewThatFits, which would build (and load) all three covers.
            sheet(coverHeight: availableHeight >= 760 ? 340 : availableHeight >= 620 ? 220 : 140)
                .frame(maxWidth: 660)
        }
    }

    /// A document or photo shows as itself, the way Quick Look shows it: it fills the preview, with only its name
    /// and the buttons to open or close it above. Space closes it again, as it opened it.
    private var fileSheet: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 12)
                Button("Open", action: onOpen).buttonStyle(.borderedProminent)
                Button("Done", action: onClose).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18).frame(height: 50)
            FileCover(item: item, terms: terms, paperLines: 7, paperSize: 15, scrollable: true, bare: true)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay { if let position { MatchNavigator(position: position, shortcutsEnabled: true, onPrevious: onPrevious, onNext: onNext) } }
                .padding([.horizontal, .bottom], 10)
        }
        .frame(maxWidth: 900)
        .frame(height: max(320, availableHeight))
    }

    private func sheet(coverHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FileCover(item: item, terms: terms, paperLines: coverHeight < 200 ? 3 : 7, paperSize: 15, playable: true, scrollable: true)
                .frame(height: coverHeight)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay { if let position { MatchNavigator(position: position, shortcutsEnabled: true, onPrevious: onPrevious, onNext: onNext) } }
                .padding(14)
            VStack(alignment: .leading, spacing: 12) {
                Text("\(SearchTerms.folder(of: item)) · \(SearchTerms.kindName(item.kind))").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
                FileTitle(name: item.title, size: 24)
                FolderLine(path: item.path)
                CopiesMenu(item: item)
                if item.score > 0 {
                    HStack(spacing: 10) {
                        StrengthPill(strength: strength)
                        ExactPill(item: item)
                        Text(String(format: "%.3f similarity", item.score)).font(.system(size: 11.5)).foregroundStyle(.tertiary).monospacedDigit()
                            .help("Cosine similarity between embeddings. This is not a confidence percentage.")
                    }
                    Text(reason).font(.system(size: 13.5)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(item.snippet).font(.system(size: 13.5)).foregroundStyle(.secondary).lineLimit(4)
                }
                // Regular-size buttons when the large ones don't fit across.
                ViewThatFits(in: .horizontal) {
                    actions.controlSize(.large)
                    actions
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 26).padding(.bottom, 24).padding(.top, 4)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Open", action: onOpen).buttonStyle(.borderedProminent)
            Button("Show in Finder", action: onReveal)
            Button("Find Similar", action: onSimilar)
            Spacer(minLength: 8)
            Button("Done", action: onClose).keyboardShortcut(.cancelAction)
        }
    }
}

/// "Also in 3 other places": the identical copies a result stands for, each one revealable in Finder.
struct CopiesMenu: View {
    let item: SearchItem
    var body: some View {
        if let copies = item.copies, !copies.isEmpty {
            Menu {
                Section("Same file, also in") {
                    ForEach(copies, id: \.self) { path in
                        Button(SearchTerms.displayPath(path)) {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                    }
                }
            } label: {
                Label("Also in \(copies.count) other \(copies.count == 1 ? "place" : "places")", systemImage: "doc.on.doc")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Identical copies of this file, whatever their names. Choose one to show it in Finder.")
        }
    }
}

// MARK: - Covers

/// A card's artwork: a photo's own thumbnail, or a painted cover with the
/// matching passage (documents) or a waveform (recordings) on top.
struct FileCover: View {
    let item: SearchItem
    var terms: [String] = []
    var paperLines = 3
    var paperSize: CGFloat = 12.5
    /// Recordings get a real player for their matched passage instead of decorative bars.
    var playable = false
    /// Clicks for covers that take mouse events themselves (the PDF reader).
    var onTap: (() -> Void)? = nil
    var onDoubleTap: (() -> Void)? = nil
    /// Documents open as a whole, scrollable file (the best match and the preview); NestedScrolling hands the
    /// wheel back to the page at the file's ends.
    var scrollable = false
    /// Artwork only (no labels, passage or waveform), with photos cropped to fill: for narrow slivers.
    var minimal = false
    /// A document as itself, with no paint around it: for the preview.
    var bare = false
    @State private var thumbnail: NSImage?
    /// The page in view of a whole PDF and its page count, as it scrolls.
    @State private var pdfPosition: (page: Int, count: Int)?
    @State private var returnRequest = 0

    private var palette: CoverPalette { .forKind(item.kind) }

    var body: some View {
        // Documents float on their painted cover, the way a recording's player sits on its paint, so moving
        // between matches keeps one continuous background and only the page changes.
        if item.isPDF, scrollable, !minimal, let page = item.page {
            // The whole document, open at the matching page with the words marked.
            onPaint {
                PDFReader(path: item.path, page: page, terms: item.matched.map { [$0] } ?? terms, onClick: onTap, onDoubleClick: onDoubleTap,
                          onPage: { pdfPosition = ($0, $1) }, returnRequest: returnRequest)
                    // Top left, clear of the match counter at the bottom and the expand button at the top right.
                    .overlay(alignment: .topLeading) { if let pdfPosition { pageLabel(pdfPosition, match: page) } }
            }
            .onChange(of: item.id) { _, _ in pdfPosition = nil }
        } else if item.kind == "text", scrollable, !minimal, FullDocument.readableExtensions.contains(URL(fileURLWithPath: item.path).pathExtension.lowercased()) {
            // The whole file, opened at the matched passage, like a recording playing from its match.
            onPaint {
                DocumentReader(item: item, terms: terms, size: paperSize, selectable: bare)
            }
        } else {
            standardCover
        }
    }

    /// Which page is in view, and when it isn't the matching one, a way back to it.
    private func pageLabel(_ position: (page: Int, count: Int), match: Int) -> some View {
        HStack(spacing: 8) {
            Text("Page \(position.page) of \(position.count)").monospacedDigit()
            if position.page != match {
                Button("Back to page \(match)") { returnRequest += 1 }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 10).frame(height: 24)
        .background(.regularMaterial, in: Capsule())
        .padding(10)
    }

    @ViewBuilder private func onPaint<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if bare { content() } else { PaintedInset(key: item.path, kind: item.kind, inset: 6, content: content) }
    }

    private var kindLabel: some View {
        Label(SearchTerms.kindName(item.kind), systemImage: SearchTerms.symbol(item.kind))
            .font(.system(size: 11, weight: .semibold)).labelStyle(.titleAndIcon)
            .padding(.horizontal, 10).frame(height: 24)
            .background(.regularMaterial, in: Capsule())
            .padding(10)
    }

    private var standardCover: some View {
        Color.clear
            .overlay {
                if item.kind == "image", let thumbnail, minimal {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                } else if item.kind == "image", let thumbnail {
                    // The whole photo, fitted; a blurred copy of itself fills the rest of the box.
                    // Each layer is sized to the box separately, so the fill cannot enlarge the fit.
                    Color.clear
                        .overlay {
                            Image(nsImage: thumbnail).resizable().scaledToFill()
                                .blur(radius: 28, opaque: true)
                                .overlay(Color.black.opacity(0.12))
                        }
                        .clipped()
                        .overlay {
                            Image(nsImage: thumbnail).resizable().scaledToFit()
                                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                        }
                } else if item.kind == "text" && !minimal && bare {
                    if item.isPDF, let page = item.page {
                        PDFPassageCover(item: item, page: page, terms: terms)
                    } else {
                        DocumentPage(item: item, terms: terms, lines: paperLines + 1, size: paperSize)
                    }
                } else if item.kind == "text" && !minimal {
                    DocumentOnPaint(item: item, terms: terms, lines: paperLines + 1, size: paperSize)
                } else {
                    PaintedCoverView(key: item.path, palette: palette)
                }
            }
            .overlay(alignment: .bottom) {
                if minimal || item.kind == "text" {
                    EmptyView()
                } else if item.kind == "audio" && playable {
                    RecordingPlayer(item: item)
                } else if item.kind == "audio" {
                    WaveformBars(seed: item.path).frame(height: 56).padding(18)
                } else if item.kind != "image" {
                    Text(SearchTerms.highlighted(item.snippet, terms: terms))
                        .font(.system(size: paperSize)).lineSpacing(2).lineLimit(paperLines)
                        .foregroundStyle(Color(white: 0.09))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.93)))
                        .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
                        .padding(14)
                }
            }
            .overlay(alignment: .topLeading) { if !minimal && !bare && item.kind != "text" { kindLabel } }
            .clipped()
            .task(id: item.path) {
                guard item.kind == "image" else { return }
                // The preview shows the photo large, so it needs a sharper copy than the cards.
                let image = await ThumbnailCache.shared.image(path: item.path, maxPixels: bare ? 2400 : 900).map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                if !Task.isCancelled { thumbnail = image }
            }
    }
}

/// A document shown as a page: its type and title, then the matching passage as readable prose with the
/// query's words marked, fading out at the bottom like text that continues.
struct DocumentPage: View {
    let item: SearchItem
    let terms: [String]
    var lines = 5
    var size: CGFloat = 12.5
    /// Just the text, like a page: no type badge or passage mark (the home page's recent files).
    var plain = false
    @State private var excerpt: DocumentExcerpt?

    var body: some View {
        // On a large cover the page reads like a page: the type grows with the space available.
        GeometryReader { geometry in
            let scale = min(1.3, max(1, geometry.size.height / 220))
            page(size: size * scale, scale: scale, lines: max(lines, fitting(geometry.size.height, size: size * scale, scale: scale)))
        }
        .background(Color(red: 0.995, green: 0.993, blue: 0.985))
        // One element for VoiceOver: what the page is and the passage that matched.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([SearchTerms.fileType(item.path).name, SearchTerms.readableLocation(item), "matching passage: \(SearchTerms.readable(item.snippet))"]
            .compactMap { $0 }.joined(separator: ", "))
        .task(id: "\(item.path)|\(item.location ?? "")|\(item.snippet.prefix(60))") {
            // Already read (a card scrolling back into view): shown at once. Otherwise a soft cross-fade when the
            // file's own lines replace the indexed text.
            if let known = DocumentExcerpt.cached(path: item.path, location: item.location, snippet: item.snippet) {
                excerpt = known
                return
            }
            let loaded = await DocumentExcerpt.load(path: item.path, location: item.location, snippet: item.snippet)
            withAnimation(.easeOut(duration: 0.18)) { excerpt = loaded }
        }
    }

    /// How many passage lines fit under the header, so a bigger page shows more of the text.
    private func fitting(_ height: CGFloat, size: CGFloat, scale: CGFloat) -> Int {
        let header = 60 * scale
        return Int((height - header) / (size * 1.25 + 3 * scale))
    }

    private func page(size: CGFloat, scale: CGFloat, lines: Int) -> some View {
        let type = SearchTerms.fileType(item.path)
        return VStack(alignment: .leading, spacing: 0) {
            if !plain {
            HStack(spacing: 8) {
                Text(type.name).font(.system(size: 10.5 * scale, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 7 * scale).frame(height: 18 * scale)
                    .background(type.color, in: RoundedRectangle(cornerRadius: 5 * scale, style: .continuous))
                if let location = SearchTerms.readableLocation(item) {
                    Text(location).font(.system(size: 11 * scale, weight: .medium)).foregroundStyle(Color(white: 0.45))
                }
                Spacer(minLength: 0)
            }
            .frame(height: 20 * scale)
            }
            // No title here: every card shows the file's name beside or below the page.
            HStack(alignment: .top, spacing: 10 * scale) {
                if !plain {
                    Capsule().fill(LinearGradient(colors: [Color(red: 0.6, green: 0.85, blue: 0.35), Color(red: 1, green: 0.84, blue: 0.3)],
                                                  startPoint: .top, endPoint: .bottom))
                        .frame(width: 3 * scale)
                }
                passage(size: size, scale: scale, lines: lines)
                    .foregroundStyle(Color(white: 0.22))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, plain ? 0 : 8 * scale)
            Spacer(minLength: 0)
        }
        .padding((plain ? 12 : 16) * scale)
        // Large covers carry previous and next buttons at their sides; keep the text clear of them.
        .padding(.horizontal, scale > 1.2 ? 36 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .mask(LinearGradient(stops: [.init(color: .black, location: 0.82), .init(color: .black.opacity(0.3), location: 1)], startPoint: .top, endPoint: .bottom))
    }

    /// The passage as laid out in the file when it can be read back (line breaks, indentation, headings),
    /// otherwise the indexed text as prose.
    @ViewBuilder private func passage(size: CGFloat, scale: CGFloat, lines: Int) -> some View {
        if let excerpt, excerpt.monospaced {
            // Code and data keep their columns: one line each, cut at the edge rather than wrapped.
            VStack(alignment: .leading, spacing: 2 * scale) {
                ForEach(Array(excerpt.lines.prefix(lines + 2).enumerated()), id: \.offset) { _, line in
                    Text(SearchTerms.highlighted(line.isEmpty ? " " : line, terms: terms))
                        .font(.system(size: size * 0.9, design: .monospaced)).lineLimit(1).truncationMode(.tail)
                }
            }
        } else if let excerpt {
            Text(prose(excerpt, size: size)).font(.system(size: size)).lineSpacing(3 * scale).lineLimit(lines)
        } else {
            Text(SearchTerms.highlighted(SearchTerms.readable(item.snippet), terms: terms))
                .font(.system(size: size)).lineSpacing(3 * scale).lineLimit(lines)
        }
    }

    private func prose(_ excerpt: DocumentExcerpt, size: CGFloat) -> AttributedString {
        var text = AttributedString()
        // A first heading that repeats the title above it is left out, with the blank line after it.
        let normalized = { (value: String) in value.lowercased().filter { $0.isLetter || $0.isNumber } }
        var skip = Set<Int>()
        if excerpt.headings.contains(0), normalized(excerpt.lines[0]) == normalized(title) {
            skip.insert(0)
            if excerpt.lines.count > 1, excerpt.lines[1].trimmingCharacters(in: .whitespaces).isEmpty { skip.insert(1) }
        }
        for (index, line) in excerpt.lines.enumerated() where !skip.contains(index) {
            if !text.characters.isEmpty { text += AttributedString("\n") }
            var part = excerpt.markdown && !excerpt.code.contains(index) ? MarkdownText.inline(line, terms: terms) : SearchTerms.highlighted(line, terms: terms)
            if excerpt.code.contains(index) { part.font = .system(size: size * 0.9, design: .monospaced) }
            if excerpt.headings.contains(index) {
                part.font = .system(size: size, weight: .semibold)
                part.foregroundColor = Color(white: 0.1)
            }
            text += part
        }
        return text
    }

    /// The file name as a title: no extension, separators read as spaces.
    private var title: String {
        let name = URL(fileURLWithPath: item.title).deletingPathExtension().lastPathComponent
        return name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
    }
}

/// A painted cover with content floating on it as a rounded, softly shadowed card.
struct PaintedInset<Content: View>: View {
    let key: String
    let kind: String
    /// A thin band of paint, so the page inside gets most of the card.
    var inset: CGFloat = 6
    @ViewBuilder let content: Content

    var body: some View {
        PaintedCoverView(key: key, palette: .forKind(kind))
            .overlay {
                content
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                    .padding(inset)
            }
    }
}

/// A document as a page floating on its painted cover: the real PDF page around the match, or the passage.
struct DocumentOnPaint: View {
    let item: SearchItem
    let terms: [String]
    var lines = 4
    var size: CGFloat = 11
    var inset: CGFloat = 6

    var body: some View {
        PaintedInset(key: item.path, kind: item.kind, inset: inset) {
            if item.isPDF, let page = item.page {
                PDFPassageCover(item: item, page: page, terms: terms)
            } else {
                DocumentPage(item: item, terms: terms, lines: lines, size: size)
            }
        }
        // Flattened into one layer, so scrolling a page of results moves these cards instead of redrawing
        // their paint, page and shadow on every frame.
        .drawingGroup()
    }
}

/// One of two layouts by the width on offer, decided only when that width changes. ViewThatFits measures
/// every candidate on each layout pass, which inside a scrolling page means on every frame.
struct WidthSwitch<Wide: View, Narrow: View>: View {
    let threshold: CGFloat
    var alignment: Alignment = .leading
    @ViewBuilder let wide: Wide
    @ViewBuilder let narrow: Narrow
    @State private var isWide = true

    var body: some View {
        // The width on offer is read from a zero-height, full-width probe, so the chosen layout never sets it.
        Group {
            if isWide { wide } else { narrow }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: alignment)
        .background(alignment: .top) {
            Color.clear.frame(maxWidth: .infinity).frame(height: 0)
                .onGeometryChange(for: Bool.self, of: { $0.size.width >= threshold }) { value in isWide = value }
        }
    }
}

/// A file name as a heading: it wraps only at spaces, hyphens and underscores, shrinks a little before
/// wrapping, and shows its extension lighter so the name reads first.
struct FileTitle: View {
    let name: String
    var size: CGFloat = 24

    var body: some View {
        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        // Lines may break at spaces, hyphens and underscores (a zero-width space marks the latter), never inside a
        // word, a number like 15.32.15, or before the extension (word joiners hold those together).
        let joined = base.replacingOccurrences(of: "_", with: "_\u{200B}").replacingOccurrences(of: ".", with: "\u{2060}.\u{2060}")
        (Text(joined) + Text(ext.isEmpty ? "" : "\u{2060}.\(ext)").foregroundColor(.secondary))
            .font(.system(size: size, weight: .semibold)).tracking(-size * 0.022)
            .lineLimit(2).minimumScaleFactor(0.75).allowsTightening(true)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .accessibilityLabel(name)
    }
}

/// The folder a file is in, on one line, shortened in the middle when long: "~/Documents/…/Safety".
struct FolderLine: View {
    let path: String

    var body: some View {
        Label {
            Text(SearchTerms.displayPath(URL(fileURLWithPath: path).deletingLastPathComponent().path))
                .lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: "folder").font(.system(size: 10.5))
        }
        .font(.system(size: 11.5)).foregroundStyle(.tertiary)
        .help(SearchTerms.displayPath(path))
        .textSelection(.enabled)
    }
}

/// Says when a match contains the words as typed.
struct ExactPill: View {
    let item: SearchItem
    var body: some View {
        if let label {
            Label(label, systemImage: "textformat")
                .font(.system(size: 10.5, weight: .semibold)).labelStyle(.titleAndIcon)
                .fixedSize()
                .padding(.horizontal, 8).padding(.vertical, 2.5)
                .foregroundStyle(Color(nsColor: NSColor(name: nil) { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        ? NSColor(red: 1, green: 0.84, blue: 0.4, alpha: 1) : NSColor(red: 0.55, green: 0.38, blue: 0, alpha: 1)
                }))
                .background(Capsule().fill(Color(red: 1, green: 0.85, blue: 0.3).opacity(0.45)))
        }
    }
    private var label: String? {
        switch item.exact { case "name": return "In the name"; case "text": return "Exact words"; default: return nil }
    }
}

/// Small round artwork used in chips.
private struct FileDot: View {
    let path: String
    let kind: String
    @State private var thumbnail: NSImage?
    var body: some View {
        Group {
            if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFill() }
            else { PaintedCoverView(key: path, palette: .forKind(kind)) }
        }
        .clipShape(Circle())
        .task(id: path) {
            guard kind == "image" else { return }
            let image = await ThumbnailCache.shared.image(path: path, maxPixels: 80).map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            if !Task.isCancelled { thumbnail = image }
        }
    }
}

/// Decorative bars. Recordings are not decoded for display; the location text says where the match is.
struct WaveformBars: View {
    let seed: String
    var body: some View {
        Canvas { context, size in
            var state = UInt64(truncatingIfNeeded: seed.hashValue == 0 ? 1 : SearchTerms.stableHash(seed))
            let count = max(12, Int(size.width / 9))
            let step = size.width / CGFloat(count)
            for index in 0..<count {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let noise = CGFloat(state >> 33) / CGFloat(UInt32.max)
                let t = CGFloat(index) / CGFloat(count)
                let amplitude = 0.15 + 0.8 * abs(sin(t * 7 + noise * 2)) * (0.45 + noise * 0.55)
                let height = max(step * 0.55, amplitude * size.height)
                let rect = CGRect(x: CGFloat(index) * step, y: (size.height - height) / 2, width: step * 0.55, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: step * 0.275), with: .color(.white.opacity(0.92)))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Helpers

enum SearchTerms {
    static let highlight = Color(red: 1, green: 0.85, blue: 0.3).opacity(0.6)
    private static let stop: Set<String> = ["the", "a", "an", "of", "in", "on", "at", "to", "for", "from", "with", "and", "or", "my", "me", "it", "its", "that", "this", "these", "those", "some", "something", "thing", "things", "file", "files", "about", "like", "one", "any", "find", "show", "where", "was", "were", "is", "are", "be", "been", "have", "has", "had", "our", "your", "their", "photo", "picture"]

    static func words(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
    static func stem(_ word: String) -> String {
        word.count > 3 && word.hasSuffix("s") && !word.hasSuffix("ss") ? String(word.dropLast()) : word
    }
    static func parse(_ query: String) -> [String] {
        var seen = Set<String>()
        return words(query).filter { $0.count > 2 && !stop.contains($0) }.map(stem).filter { seen.insert($0).inserted }
    }
    static func matches(_ term: String, _ word: String) -> Bool {
        word == term || (term.count >= 4 && word.count >= 3 && (term.hasPrefix(word) || word.hasPrefix(term)))
    }
    private static func matchesAny(_ word: String, _ terms: [String]) -> Bool {
        let key = stem(words(word).first ?? "")
        return !key.isEmpty && terms.contains { matches($0, key) }
    }
    /// The snippet with the query's words marked, as the reader sees them.
    static func highlighted(_ text: String, terms: [String]) -> AttributedString {
        var result = AttributedString(text)
        mark(&result, terms: terms)
        return result
    }
    /// Marks the search words in text that may already carry styles (Markdown's bold or code).
    static func mark(_ result: inout AttributedString, terms: [String]) {
        guard !terms.isEmpty else { return }
        let text = String(result.characters)
        var found: [Range<String.Index>] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, range, _, _ in
            if let word, matchesAny(word, terms) { found.append(range) }
        }
        for range in found {
            guard let target = Range(range, in: result) else { continue }
            result[target].backgroundColor = highlight
            result[target].foregroundColor = Color(white: 0.1)
        }
    }
    /// The words in the text that matched, in reading order.
    static func found(in text: String, terms: [String]) -> [String] {
        var seen = Set<String>(), found: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, _, _, _ in
            guard let word, matchesAny(word, terms), seen.insert(word.lowercased()).inserted else { return }
            found.append(word.lowercased())
        }
        return Array(found.prefix(4))
    }
    static func kind(of url: URL) -> String {
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .image) == true { return "image" }
        if type?.conforms(to: .audio) == true { return "audio" }
        return "text"
    }
    static func kindName(_ kind: String) -> String { kind == "image" ? "Photo" : kind == "audio" ? "Recording" : "Document" }
    static func symbol(_ kind: String) -> String { kind == "image" ? "photo" : kind == "audio" ? "waveform" : "doc.text" }
    /// Why a match was returned, in plain words, with the query's words marked.
    @MainActor static func reason(for item: SearchItem, terms: [String], reference: URL?) -> AttributedString {
        let similar = reference.map { " It is also close to \(referenceName($0))." } ?? ""
        if let matched = item.matched, item.exact == "name" {
            var text = AttributedString("The file name contains ")
            text += marked(matched)
            text += AttributedString(".\(similar)")
            return text
        }
        if let matched = item.matched, item.exact == "text" {
            if item.kind == "image" {
                var text = AttributedString("The picture shows the words ")
                text += marked(matched)
                if let words = item.recognizedText { text += AttributedString(": “\(words)”") }
                text += AttributedString(".\(similar)")
                return text
            }
            var text = AttributedString("\(readableLocation(item) ?? "The passage") contains ")
            text += marked(matched)
            text += AttributedString(" exactly as you typed it.\(similar)")
            return text
        }
        switch item.kind {
        case "image":
            return AttributedString("DocuFind compared the picture itself with your description. No caption or file name was needed.\(similar)")
        case "audio":
            let place = readableLocation(item).map { "The closest stretch of the recording is \($0)." } ?? "The recording is close in meaning."
            return AttributedString("\(place) DocuFind listens in 30-second windows.\(similar)")
        default:
            let place = readableLocation(item) ?? "The passage"
            let found = found(in: item.snippet, terms: terms)
            guard !found.isEmpty else { return AttributedString("\(place) is close in meaning, even though it uses different words.\(similar)") }
            var text = AttributedString("\(place) talks about ")
            for (index, word) in found.enumerated() {
                if index > 0 { text += AttributedString(index == found.count - 1 ? " and " : ", ") }
                var mark = AttributedString(word)
                mark.backgroundColor = highlight
                text += mark
            }
            text += AttributedString(", and the rest of the passage is close in meaning.\(similar)")
            return text
        }
    }

    private static func marked(_ words: String) -> AttributedString {
        var mark = AttributedString(words)
        mark.backgroundColor = highlight
        return mark
    }

    /// Clips recorded from the search bar live in the private recordings folder.
    @MainActor static func isRecording(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL == AppModel.shared.dataDirectory.appendingPathComponent("recordings").standardizedFileURL
    }
    @MainActor static func referenceName(_ url: URL) -> String { isRecording(url) ? "your recording" : url.lastPathComponent }
    static func folder(of item: SearchItem) -> String { URL(fileURLWithPath: item.path).deletingLastPathComponent().lastPathComponent }
    static func displayPath(_ path: String) -> String { path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
    /// "3 copies" when a result stands for several identical files.
    static func copiesNote(_ item: SearchItem) -> String? {
        item.copyCount > 0 ? "\(item.copyCount + 1) copies" : nil
    }

    static func detail(for item: SearchItem) -> String {
        if item.kind == "image" { return folder(of: item) }
        return [readableLocation(item), folder(of: item)].compactMap { $0 }.joined(separator: " · ")
    }

    /// "Page 3" or "at 1:30"; the character offsets used internally ("Character 2296") are left out.
    static func readableLocation(_ item: SearchItem) -> String? {
        guard var location = item.location else { return nil }
        if let range = location.range(of: #",? ?[Cc]haracter \d+"#, options: .regularExpression) { location.removeSubrange(range) }
        // "50.0–80.0 seconds" (as the worker stores it) reads as "0:50–1:20", like the player.
        let parts = location.replacingOccurrences(of: " seconds", with: "").split(separator: "–").compactMap { Double($0) }
        if location.hasSuffix(" seconds"), parts.count == 2 {
            func clock(_ value: Double) -> String { let total = Int(value.rounded()); return "\(total / 60):" + String(format: "%02d", total % 60) }
            return "\(clock(parts[0]))–\(clock(parts[1]))"
        }
        location = location.trimmingCharacters(in: .whitespaces)
        return location.isEmpty ? nil : location
    }

    /// The passage as prose: Markdown headings, list marks, emphasis and link targets removed.
    static func readable(_ text: String) -> String {
        var result = text
        for (pattern, template) in [(#"\[([^\]]*)\]\([^)]*\)"#, "$1"), (#"(^|\s)#{1,6}\s+"#, "$1"), (#"\*\*|__|`"#, ""), (#"(^|\s)[-*•]\s+"#, "$1")] {
            result = result.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// The file type as people know it: PDF, Word, Markdown…
    static func fileType(_ path: String) -> (name: String, color: Color) {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "pdf": return ("PDF", Color(red: 0.86, green: 0.25, blue: 0.24))
        case "doc", "docx", "rtf", "odt", "pages": return ("Word", Color(red: 0.2, green: 0.42, blue: 0.85))
        case "md", "markdown": return ("Markdown", Color(red: 0.45, green: 0.36, blue: 0.85))
        case "html", "htm": return ("Web page", Color(red: 0.92, green: 0.5, blue: 0.16))
        case "csv", "xlsx", "xls", "numbers": return ("Sheet", Color(red: 0.16, green: 0.62, blue: 0.38))
        case "key", "pptx", "ppt": return ("Slides", Color(red: 0.93, green: 0.6, blue: 0.1))
        default: return ("Text", Color(white: 0.45))
        }
    }
    static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return hash
    }
}
