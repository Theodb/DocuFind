import AppKit
import PDFKit
import SwiftUI

/// Opens a result where it matched: a PDF at its page, anything else in its usual app.
@MainActor
enum FileOpener {
    static func open(_ item: SearchItem, query: String = "") {
        let url = URL(fileURLWithPath: item.path)
        if item.isPDF, let page = item.page {
            PDFViewerWindow.show(url: url, page: page, highlights: PDFHighlights.terms(for: query, item: item))
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - PDF pages

enum PDFHighlights {
    /// What to mark on the page: the words typed exactly, or else the query's words.
    @MainActor static func terms(for query: String, item: SearchItem) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "\"([^\"]+)\"|“([^”]+)”")
        let quoted = pattern.matches(in: query, range: NSRange(query.startIndex..., in: query)).compactMap { match in
            [1, 2].compactMap { Range(match.range(at: $0), in: query).map { String(query[$0]) } }.first
        }
        if !quoted.isEmpty { return quoted }
        if let matched = item.matched, item.exact == "text" { return [matched] }
        return SearchTerms.parse(query)
    }

    /// Where the terms appear on one page. Only that page's text is searched, not the whole document.
    static func selections(on page: PDFPage, in document: PDFDocument, terms: [String]) -> [PDFSelection] {
        guard let text = page.string as NSString? else { return [] }
        var found: [PDFSelection] = []
        for term in terms where !term.isEmpty {
            var range = NSRange(location: 0, length: text.length)
            while found.count < 200 {
                let match = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: range)
                guard match.location != NSNotFound, let selection = page.selection(for: match) else { break }
                found.append(selection)
                let next = match.location + max(match.length, 1)
                range = NSRange(location: next, length: text.length - next)
            }
        }
        return found
    }
}

/// A PDF page drawn as a picture, with the matching words marked. Used as the cover of a PDF match.
struct PDFPageCover: View {
    let path: String
    let page: Int
    let terms: [String]
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color(white: 0.93)
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
                    .padding(.vertical, 16).padding(.horizontal, 24)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Text("Page \(page)").font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10).frame(height: 24)
                .background(.regularMaterial, in: Capsule()).padding(10)
        }
        .task(id: "\(path):\(page):\(terms)") {
            image = await Self.render(path: path, page: page, terms: terms)
        }
    }

    private static func render(path: String, page number: Int, terms: [String]) async -> NSImage? {
        let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let document = PDFDocument(url: URL(fileURLWithPath: path)), !document.isLocked,
                  let page = document.page(at: number - 1) else { return nil }
            let bounds = page.bounds(for: .cropBox)
            let scale = 1100 / max(bounds.width, bounds.height, 1)
            let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
            let marks = PDFHighlights.selections(on: page, in: document, terms: terms).map { $0.bounds(for: page) }
            guard width > 0, height > 0,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return nil }
            context.setFillColor(.white)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            page.draw(with: .cropBox, to: context)
            // Multiplied over the text, like a highlighter pen.
            context.setBlendMode(.multiply)
            context.setFillColor(CGColor(red: 1, green: 0.85, blue: 0.3, alpha: 0.75))
            for rect in marks { context.fill(rect.insetBy(dx: -1.5, dy: -1)) }
            return context.makeImage()
        }.value
        return image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }
}

/// A window that shows a PDF at the matching page, with the words marked.
@MainActor
final class PDFViewerWindow: NSWindowController, NSWindowDelegate {
    private static var open: [PDFViewerWindow] = []
    private let url: URL

    static func show(url: URL, page: Int, highlights: [String]) {
        guard let document = PDFDocument(url: url), !document.isLocked else {
            NSWorkspace.shared.open(url)
            return
        }
        let controller = PDFViewerWindow(url: url, document: document, page: page, highlights: highlights)
        open.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(url: URL, document: PDFDocument, page: Int, highlights: [String]) {
        self.url = url
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .windowBackgroundColor
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = url.lastPathComponent
        window.representedURL = url
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("DocuFind PDF Viewer")
        let host = NSHostingView(rootView: PDFViewerBar(page: page, count: document.pageCount,
                                                        onPreview: { NSWorkspace.shared.open(url) },
                                                        onReveal: { NSWorkspace.shared.activateFileViewerSelecting([url]) }))
        let stack = NSStackView(views: [host, view])
        stack.orientation = .vertical
        stack.spacing = 0
        window.contentView = stack
        super.init(window: window)
        window.delegate = self
        window.center()
        if let target = document.page(at: page - 1) {
            let marks = PDFHighlights.selections(on: target, in: document, terms: highlights)
            marks.forEach { $0.color = NSColor(red: 1, green: 0.85, blue: 0.3, alpha: 0.75) }
            view.highlightedSelections = marks
            // After layout, so the page lands at the top of the window.
            DispatchQueue.main.async {
                view.go(to: target)
                if let first = marks.first { view.go(to: first) }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }
}

private struct PDFViewerBar: View {
    let page: Int
    let count: Int
    let onPreview: () -> Void
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Label("Matched on page \(page) of \(count)", systemImage: "text.magnifyingglass")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            Button("Show in Finder", action: onReveal)
            Button("Open in Preview", action: onPreview).keyboardShortcut("o", modifiers: .command)
        }
        .controlSize(.small)
        .padding(.horizontal, 14).frame(height: 38)
    }
}
