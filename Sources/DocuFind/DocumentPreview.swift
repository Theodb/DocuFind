import AppKit
import PDFKit
import SwiftUI

/// The matching passage of a text file as it is laid out in the file: its own line breaks and indentation.
/// The index keeps passages with whitespace collapsed, so the lines are read back from the file itself.
struct DocumentExcerpt: Sendable, Equatable {
    let lines: [String]
    /// Code and data keep their columns, so they are set in a monospaced font.
    let monospaced: Bool
    /// Markdown headings, shown in bold.
    let headings: Set<Int>
    /// Lines inside a Markdown code block, set in a monospaced font.
    var code: Set<Int> = []
    /// Markdown's inline styles (bold, italics, code, links) are drawn rather than shown as marks.
    var markdown = false

    static let codeExtensions: Set<String> = ["py", "swift", "js", "ts", "jsx", "tsx", "css", "c", "h", "cpp", "hpp", "java", "go", "rs", "sh", "sql",
                                              "yaml", "yml", "toml", "xml", "json", "csv", "tsv", "log", "tex"]
    /// Files read as they are on disk; HTML, RTF and PDF go through a converter, so their offsets don't match the file.
    static let plainExtensions: Set<String> = codeExtensions.union(["txt", "md", "markdown", "rst"])

    /// Reads up to `maxLines` lines starting at the line that holds the passage. Nil when the passage can't be found.
    static func load(path: String, location: String?, snippet: String, maxLines: Int = 14) async -> DocumentExcerpt? {
        let suffix = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard plainExtensions.contains(suffix) else { return nil }
        if let cached = cache.object(forKey: "\(path)|\(location ?? "")|\(snippet.prefix(60))" as NSString) { return cached.value }
        let result = await Task.detached(priority: .utility) { () -> DocumentExcerpt? in
            let offset = location.flatMap(characterOffset) ?? 0
            // Read only as far as the passage needs: offsets count characters, a character is at most 4 bytes.
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: (offset + 6000) * 4)) ?? Data()
            let text = String(decoding: data, as: UTF8.self)
            guard let start = passageStart(in: text, near: offset, snippet: snippet) else { return nil }
            // Back up to the start of the line, so the first line keeps its indentation.
            var lineStart = text[..<start].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
            // A passage at the very end of the file leaves the card nearly empty: start up to two lines earlier, so the
            // card shows what leads to the passage, which still comes within its first lines.
            if data.count < (offset + 6000) * 4 {
                func filled(_ part: Substring) -> Int { part.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count }
                var context = 0
                while filled(text[lineStart...]) < 3, context < 2, lineStart > text.startIndex {
                    let previousEnd = text.index(before: lineStart)
                    lineStart = text[..<previousEnd].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
                    if !text[lineStart..<previousEnd].trimmingCharacters(in: .whitespaces).isEmpty { context += 1 }
                }
            }
            var lines = text[lineStart...].split(separator: "\n", maxSplits: maxLines + 1, omittingEmptySubsequences: false)
                .prefix(maxLines).map { $0.replacingOccurrences(of: "\t", with: "    ").replacingOccurrences(of: "\r", with: "") }
            // Drop blank lines at the end, and collapse runs of blank lines to one.
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            lines = lines.enumerated().filter { index, line in
                !(line.trimmingCharacters(in: .whitespaces).isEmpty && index > 0 && lines[index - 1].trimmingCharacters(in: .whitespaces).isEmpty)
            }.map(\.element)
            guard !lines.isEmpty else { return nil }
            let monospaced = codeExtensions.contains(suffix)
            if MarkdownLines.extensions.contains(suffix) {
                // The text before the excerpt tells whether it opens inside a code block.
                let parsed = MarkdownLines.parse(lines, startsInCode: MarkdownLines.endsInCode(text[..<lineStart]))
                return DocumentExcerpt(lines: parsed.lines, monospaced: false, headings: Set(parsed.headings.keys), code: parsed.code, markdown: true)
            }
            return DocumentExcerpt(lines: lines, monospaced: monospaced, headings: [])
        }.value
        if let result { cache.setObject(Box(result), forKey: "\(path)|\(location ?? "")|\(snippet.prefix(60))" as NSString) }
        return result
    }

    /// The excerpt if it has already been read, without waiting.
    static func cached(path: String, location: String?, snippet: String) -> DocumentExcerpt? {
        cache.object(forKey: "\(path)|\(location ?? "")|\(snippet.prefix(60))" as NSString)?.value
    }

    /// "Character 2296" or "Page 2, character 40" → 2295 (zero-based).
    fileprivate static func characterOffset(_ location: String) -> Int? {
        guard let range = location.range(of: #"[Cc]haracter (\d+)"#, options: .regularExpression) else { return nil }
        return Int(location[range].filter(\.isNumber)).map { max(0, $0 - 1) }
    }

    /// Where the snippet's opening words appear, searched near the stored offset first, then from the top.
    fileprivate static func passageStart(in text: String, near offset: Int, snippet: String) -> String.Index? {
        let words = snippet.replacingOccurrences(of: "…", with: " ").split(whereSeparator: \.isWhitespace).prefix(6)
        guard words.count >= 2 else { return nil }
        let pattern = words.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s+"#)
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let whole = NSRange(text.startIndex..., in: text)
        let hint = (text.index(text.startIndex, offsetBy: max(0, offset - 400), limitedBy: text.endIndex) ?? text.endIndex)
        let near = NSRange(hint..., in: text)
        let match = expression.firstMatch(in: text, range: near) ?? expression.firstMatch(in: text, range: whole)
        return match.flatMap { Range($0.range, in: text)?.lowerBound }
    }

    private final class Box: NSObject {
        let value: DocumentExcerpt
        init(_ value: DocumentExcerpt) { self.value = value }
    }
    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = { let cache = NSCache<NSString, Box>(); cache.countLimit = 200; return cache }()
}

/// A PDF match shown as its real page, cropped around the matching passage, with the query's words marked.
struct PDFPassageCover: View {
    let item: SearchItem
    let page: Int
    let terms: [String]
    @State private var image: NSImage?
    @State private var failed = false

    /// How much of the page's width the crop shows: tight on small cards so text stays legible, wider on large ones.
    /// Measured before the first render, so a large cover isn't drawn once at the small crop and again.
    @State private var widthFraction: CGFloat?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            GeometryReader { proxy in
                Color.clear.onAppear { widthFraction = proxy.size.width > 480 ? 0.85 : 0.55 }
                    .onChange(of: proxy.size.width > 480) { _, large in widthFraction = large ? 0.85 : 0.55 }
            }
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .clipped()
            } else if failed {
                DocumentPage(item: item, terms: terms)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if image != nil {
                HStack(spacing: 6) {
                    Text("PDF").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 7).frame(height: 18)
                        .background(SearchTerms.fileType(item.path).color, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Text("Page \(page)").font(.system(size: 11, weight: .semibold))
                }
                .padding(.leading, 6).padding(.trailing, 9).frame(height: 26)
                .background(.regularMaterial, in: Capsule())
                .padding(10)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("PDF, page \(page), matching passage: \(SearchTerms.readable(item.snippet))")
        .task(id: "\(item.path):\(page):\(terms):\(item.snippet.prefix(40)):\(widthFraction ?? 0)") {
            guard let widthFraction else { return }
            image = await Self.render(path: item.path, page: page, terms: terms, snippet: item.snippet, widthFraction: widthFraction)
            failed = image == nil
        }
    }

    /// The page at card resolution, cropped to a 16:10 band centred on the marked words, or on the passage's
    /// opening words when no query word is printed on the page.
    private static func render(path: String, page number: Int, terms: [String], snippet: String, widthFraction: CGFloat) async -> NSImage? {
        let key = "\(path)|\(number)|\(terms)|\(snippet.prefix(40))|\(widthFraction)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let document = PDFDocument(url: URL(fileURLWithPath: path)), !document.isLocked,
                  let page = document.page(at: number - 1) else { return nil }
            let bounds = page.bounds(for: .cropBox)
            var marks = PDFHighlights.selections(on: page, in: document, terms: terms).map { $0.bounds(for: page) }
            var focus = marks.first
            if focus == nil {
                // Only this page's text is searched: searching the whole document took seconds on long PDFs.
                let opening = snippet.replacingOccurrences(of: "…", with: "").split(whereSeparator: \.isWhitespace).prefix(5).joined(separator: " ")
                if opening.count > 8, let text = page.string as NSString? {
                    let range = text.range(of: opening, options: [.caseInsensitive, .diacriticInsensitive])
                    if range.location != NSNotFound { focus = page.selection(for: range)?.bounds(for: page) }
                }
            }
            marks = Array(marks.prefix(40))
            // A band about half the page wide, 10:16 of it tall, so body text stays legible on a card: the focus
            // sits a quarter in from its left, centred vertically.
            let width = bounds.width * widthFraction
            let height = width * 10 / 16
            let left = min(bounds.maxX - width, max(bounds.minX, (focus?.minX ?? bounds.minX + bounds.width * 0.1) - width * 0.25))
            var top = focus.map { $0.midY + height / 2 } ?? (bounds.maxY - bounds.height * 0.04)
            top = min(bounds.maxY, max(bounds.minY + height, top))
            let band = CGRect(x: left, y: top - height, width: width, height: height)
            let scale = 900 / band.width
            let pixelWidth = Int(band.width * scale), pixelHeight = Int(band.height * scale)
            guard pixelWidth > 0, pixelHeight > 0,
                  let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return nil }
            context.setFillColor(.white)
            context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -band.minX, y: -band.minY)
            page.draw(with: .cropBox, to: context)
            context.setBlendMode(.multiply)
            context.setFillColor(CGColor(red: 1, green: 0.85, blue: 0.3, alpha: 0.75))
            for rect in marks { context.fill(rect.insetBy(dx: -1.5, dy: -1)) }
            return context.makeImage()
        }.value
        guard let image else { return nil }
        let result = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        cache.setObject(result, forKey: key, cost: image.width * image.height * 4)
        return result
    }

    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = { let cache = NSCache<NSString, NSImage>(); cache.totalCostLimit = 48 * 1024 * 1024; return cache }()
}

// MARK: Reading the whole document

/// A whole text file split into lines, with where the matched passage starts and how many lines it spans.
struct FullDocument: Sendable {
    let lines: [String]
    let passage: Range<Int>
    let monospaced: Bool
    /// Markdown heading lines and their level.
    let headings: [Int: Int]
    /// Lines inside a Markdown code block.
    var code: Set<Int> = []
    var markdown = false

    /// Read as they are on disk, or converted to plain text by macOS first (HTML and RTF).
    static let convertedExtensions: Set<String> = ["html", "htm", "rtf"]
    static let readableExtensions = DocumentExcerpt.plainExtensions.union(convertedExtensions)

    /// Files beyond this are shown as an excerpt only; a card scrolling through a huge log helps nobody.
    static let maxBytes = 2_000_000

    private final class Box: NSObject {
        let value: FullDocument
        init(_ value: FullDocument) { self.value = value }
    }
    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = { let cache = NSCache<NSString, Box>(); cache.countLimit = 24; cache.totalCostLimit = 32 * 1024 * 1024; return cache }()

    static func load(path: String, location: String?, snippet: String) async -> FullDocument? {
        let key = "\(path)|\(location ?? "")|\(snippet.prefix(60))" as NSString
        if let cached = cache.object(forKey: key) { return cached.value }
        let document = await read(path: path, location: location, snippet: snippet)
        if let document { cache.setObject(Box(document), forKey: key, cost: document.lines.reduce(0) { $0 + $1.utf8.count }) }
        return document
    }

    private static func read(path: String, location: String?, snippet: String) async -> FullDocument? {
        let suffix = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard readableExtensions.contains(suffix) else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> FullDocument? in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? Int, size <= maxBytes,
                  let data = convertedExtensions.contains(suffix) ? plainText(of: path) : FileManager.default.contents(atPath: path)
            else { return nil }
            let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
            let offset = location.flatMap(DocumentExcerpt.characterOffset) ?? 0
            let start = DocumentExcerpt.passageStart(in: text, near: offset, snippet: snippet) ?? text.startIndex
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.replacingOccurrences(of: "\t", with: "    ") }
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            guard !lines.isEmpty else { return nil }
            // The passage's first line, then as many lines as its text covers.
            let first = text[..<start].reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
            var covered = 0, last = first
            let length = min(max(snippet.count, 120), 400)
            while last < lines.count, covered < length {
                covered += lines[last].count + 1
                last += 1
            }
            let monospaced = DocumentExcerpt.codeExtensions.contains(suffix)
            let passage = min(first, lines.count - 1)..<max(min(last, lines.count), min(first, lines.count - 1) + 1)
            if monospaced { return FullDocument(lines: lines, passage: passage, monospaced: true, headings: [:]) }
            guard MarkdownLines.extensions.contains(suffix) else { return reflowed(lines, passage: passage, headings: [:]) }
            let parsed = MarkdownLines.parse(lines)
            var document = reflowed(parsed.lines, passage: passage, headings: parsed.headings, kept: parsed.code)
            document.markdown = true
            return document
        }.value
    }

    /// HTML or RTF as the plain text macOS reads from it, through textutil: no WebKit, so it runs off the main thread.
    private static func plainText(of path: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "txt", "-encoding", "UTF-8", "-stdout", path]
        // HTML that doesn't name its charset is read as Latin-1 by textutil; today such files are almost always UTF-8.
        if ["html", "htm"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()),
           let head = FileHandle(forReadingAtPath: path).flatMap({ try? $0.read(upToCount: 4096) }),
           String(decoding: head, as: UTF8.self).range(of: "charset", options: .caseInsensitive) == nil {
            process.arguments = ["-inputencoding", "UTF-8"] + process.arguments!
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 && !data.isEmpty ? data : nil
    }

    /// Prose wrapped by hand at a fixed width (licenses, plain-text notes) is joined back into paragraphs, so it
    /// flows to the reader's width instead of leaving a word or two on a line of its own wherever the reader is
    /// narrower than the file. Each run of lines is judged on its own, since one file can mix wrapped prose with
    /// long lines: a run is joined when its lines stop near the same width (40 to 100 characters) and mostly end
    /// mid-sentence, the way a wrap cuts prose. A short line ends a run (a label, a paragraph's last line), and
    /// lines that each end a sentence or a statement, such as a transcript or code, stay apart. Headings, list items, indented lines,
    /// quotes and `kept` lines (code) stay as written.
    static func reflowed(_ lines: [String], passage: Range<Int>, headings: [Int: Int], kept: Set<Int> = []) -> FullDocument {
        let special = #"^(\s{2,}|\s*([-*+•>]|\d+[.)])\s)"#
        func plain(_ index: Int) -> Bool {
            !lines[index].trimmingCharacters(in: .whitespaces).isEmpty && headings[index] == nil && !kept.contains(index)
                && lines[index].range(of: special, options: .regularExpression) == nil
        }
        func wrapped(_ run: Range<Int>) -> Bool {
            let longest = lines[run].map(\.count).max() ?? 0
            let sentences = lines[run].dropLast().filter { line in
                line.trimmingCharacters(in: .whitespaces).last.map { ".!?;{}".contains($0) } ?? false
            }.count
            return run.count >= 2 && (40...100).contains(longest) && sentences * 2 <= run.count - 1
        }
        var joined: [String] = [], from: [Int] = [], newHeadings: [Int: Int] = [:], newCode = Set<Int>()
        func keep(_ run: Range<Int>) {
            for line in run {
                if let level = headings[line] { newHeadings[joined.count] = level }
                if kept.contains(line) { newCode.insert(joined.count) }
                joined.append(lines[line])
                from.append(joined.count - 1)
            }
        }
        var index = 0
        while index < lines.count {
            var end = index
            while end < lines.count, plain(end) { end += 1 }
            guard end > index else { keep(index..<index + 1); index += 1; continue }
            // Split the paragraph after each line that falls well short of its longest line.
            let longest = lines[index..<end].map(\.count).max() ?? 0
            var run = index
            for line in index..<end where line == end - 1 || lines[line].count < longest * 3 / 5 {
                if wrapped(run..<line + 1) {
                    joined.append(lines[run...line].map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " "))
                    from += Array(repeating: joined.count - 1, count: line + 1 - run)
                } else {
                    keep(run..<line + 1)
                }
                run = line + 1
            }
            index = end
        }
        let start = from[passage.lowerBound], end = from[passage.upperBound - 1] + 1
        return FullDocument(lines: joined, passage: start..<end, monospaced: false, headings: newHeadings, code: newCode)
    }
}

/// A text file shown whole, like a page you can scroll: it opens at the matched passage, which is marked,
/// and the rest of the file is a scroll away. Falls back to the excerpt page when the file can't be read.
struct DocumentReader: View {
    let item: SearchItem
    let terms: [String]
    var size: CGFloat = 14
    /// Text can be selected and copied: in the preview, where a click does nothing else.
    var selectable = false
    @State private var document: FullDocument?
    @State private var unreadable = false
    /// The reader stays hidden on the blank page until it has scrolled to the passage, then fades in. Nothing
    /// else is drawn meanwhile: an excerpt in its own layout would visibly jump when the reader replaced it.
    @State private var positioned = false

    private var key: String { "\(item.path)|\(item.location ?? "")|\(item.snippet.prefix(60))" }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.995, green: 0.993, blue: 0.985)
            if unreadable {
                DocumentPage(item: item, terms: terms, lines: 9, size: size)
            } else if let document {
                reader(document)
                    .opacity(positioned ? 1 : 0)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.title)
        .task(id: key) {
            // Cleared first, so the next document's reader appears fresh: it scrolls to its passage, then fades in.
            positioned = false
            document = nil
            unreadable = false
            let loaded = await FullDocument.load(path: item.path, location: item.location, snippet: item.snippet)
            document = loaded
            unreadable = loaded == nil
        }
    }

    private func reader(_ document: FullDocument) -> some View {
        ScrollViewReader { proxy in
            // Code and data scroll sideways instead of cutting their lines; prose wraps.
            ScrollView(document.monospaced ? [.vertical, .horizontal] : .vertical) {
                // Only the file's text: its name and type are shown around the reader.
                LazyVStack(alignment: .leading, spacing: document.monospaced ? 2 : 4) {
                    // The passage is one row, so its mark runs unbroken down all its lines.
                    ForEach(rows(document), id: \.self) { row in
                        if row >= 0 {
                            line(document, row).id(row)
                        } else {
                            passage(document).id(document.passage.lowerBound)
                        }
                    }
                }
                // Prose keeps to about 75 characters a line, however wide the reader.
                .frame(maxWidth: document.monospaced ? nil : size * 44, alignment: .leading)
                .padding(.horizontal, 52).padding(.vertical, 18)
                .frame(maxWidth: document.monospaced ? nil : .infinity)
                .modifier(Selectable(enabled: selectable))
            }
            .scrollIndicators(.visible)
            // Lines fade at the edges instead of being sliced.
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.07),
                                         .init(color: .black, location: 0.93), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .onAppear {
                // The passage in the middle of the view, with the file around it, then the reader fades in.
                proxy.scrollTo(document.passage.lowerBound, anchor: UnitPoint(x: 0, y: 0.5))
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.22)) { positioned = true }
                }
            }
        }
    }

    /// Each line outside the passage, with -1 standing for the passage as a whole.
    private func rows(_ document: FullDocument) -> [Int] {
        Array(0..<document.passage.lowerBound) + [-1] + Array(document.passage.upperBound..<document.lines.count)
    }

    private func passage(_ document: FullDocument) -> some View {
        VStack(alignment: .leading, spacing: document.monospaced ? 2 : 4) {
            ForEach(Array(document.passage), id: \.self) { line(document, $0) }
        }
        // The same green-to-yellow mark as the cards, once for the whole passage.
        .overlay(alignment: .leading) {
            Rectangle().fill(LinearGradient(colors: [Color(red: 0.6, green: 0.85, blue: 0.35), Color(red: 1, green: 0.84, blue: 0.3)],
                                            startPoint: .top, endPoint: .bottom))
                .frame(width: 3)
        }
    }

    private func line(_ document: FullDocument, _ index: Int) -> some View {
        let text = document.lines[index].isEmpty ? " " : document.lines[index]
        let inPassage = document.passage.contains(index)
        let code = document.monospaced || document.code.contains(index)
        let level = document.headings[index]
        var content = document.markdown && !code ? MarkdownText.inline(text, terms: inPassage ? terms : [])
            : SearchTerms.highlighted(text, terms: inPassage ? terms : [])
        if let level { content.font = .system(size: size * MarkdownText.headingScale(level), weight: .semibold) }
        return Text(content)
            .font(code ? .system(size: size * 0.88, design: .monospaced) : .system(size: size))
            // A code or data file keeps each line whole, scrolling sideways.
            .lineLimit(document.monospaced ? 1 : nil)
            .fixedSize(horizontal: document.monospaced, vertical: false)
            .lineSpacing(code ? 0 : size * 0.3)
            .padding(.top, level != nil && index > 0 ? size * 0.6 : 0)
            .foregroundStyle(Color(white: inPassage ? 0.1 : 0.32))
            .frame(maxWidth: document.monospaced ? nil : .infinity, alignment: .leading)
            .padding(.leading, 12)
            .accessibilityAddTraits(level != nil ? .isHeader : [])
            // The mark is only colour, so VoiceOver says where the match begins.
            .accessibilityLabel(index == document.passage.lowerBound ? Text("Matching passage: ") + Text(content) : Text(content))
    }
}

/// Text selection only where it's wanted: elsewhere a click on a card opens it.
private struct Selectable: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.textSelection(.enabled) } else { content }
    }
}

/// A Markdown line's inline styles drawn as styles, with the search words marked on top.
enum MarkdownText {
    static func inline(_ text: String, terms: [String]) -> AttributedString {
        guard var styled = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return SearchTerms.highlighted(text, terms: terms)
        }
        SearchTerms.mark(&styled, terms: terms)
        return styled
    }

    /// Larger type for the top heading levels, so a document's structure shows at a glance.
    static func headingScale(_ level: Int) -> CGFloat {
        switch level { case 1: 1.45; case 2: 1.25; case 3: 1.1; default: 1 }
    }
}

/// A PDF shown whole in the card, open at the matching page with the words marked; scrolls through every page.
struct PDFReader: NSViewRepresentable {
    let path: String
    let page: Int
    let terms: [String]
    /// The card's click and double click; PDFView takes mouse events before any SwiftUI gesture above it.
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    /// The page in view and the page count, as the reader scrolls.
    var onPage: ((Int, Int) -> Void)?
    /// Changing it scrolls back to the match, after the reader was scrolled away from it.
    var returnRequest = 0

    func makeNSView(context: Context) -> ClickablePDFView {
        let view = ClickablePDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = NSColor(white: 0.93, alpha: 1)
        view.alphaValue = 0
        view.pageObserver = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak view] _ in
            MainActor.assumeIsolated { view?.reportPage() }
        }
        update(view)
        return view
    }

    func updateNSView(_ view: ClickablePDFView, context: Context) {
        update(view)
    }

    private func update(_ view: ClickablePDFView) {
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.onPage = onPage
        if view.returnRequest != returnRequest {
            view.returnRequest = returnRequest
            view.showMatch()
        }
        let key = "\(path)|\(page)|\(terms)"
        guard view.loadedKey != key else { return }
        view.loadedKey = key
        view.alphaValue = 0
        let path = path, number = page, terms = terms
        // Parsing a PDF and searching its page can take a while on a long file: done off the main thread.
        Task.detached(priority: .userInitiated) {
            let opened = PDFDocument(url: URL(fileURLWithPath: path))
            let document = opened.flatMap { $0.isLocked ? nil : $0 }
            let target = document?.page(at: number - 1)
            let marks = (document != nil && target != nil) ? PDFHighlights.selections(on: target!, in: document!, terms: terms) : []
            let loaded = UncheckedBox((document, target, marks))
            await MainActor.run {
                guard view.loadedKey == key else { return }
                let (document, target, marks) = loaded.value
                guard let document else { view.alphaValue = 1; return }
                view.document = document
                guard let target else { view.alphaValue = 1; return }
                marks.forEach { $0.color = NSColor(red: 1, green: 0.85, blue: 0.3, alpha: 0.75) }
                view.highlightedSelections = marks
                view.match = (target, marks.first?.bounds(for: target))
                // After layout, so the page is in place: the first marked word, or the page, is centred in the view.
                DispatchQueue.main.async {
                    view.go(to: target)
                    view.reportPage()
                    DispatchQueue.main.async {
                        view.showMatch()
                        // Shown only once it sits at the match, so it never visibly jumps there.
                        NSAnimationContext.runAnimationGroup { context in
                            context.duration = 0.22
                            view.animator().alphaValue = 1
                        }
                    }
                }
            }
        }
    }
}

/// A PDFView that hands single and double clicks to the card it sits in, when the card wants them.
final class ClickablePDFView: PDFView {
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onPage: ((Int, Int) -> Void)?
    var loadedKey: String?
    var pageObserver: NSObjectProtocol?
    var returnRequest = 0
    /// The matching page, and the first marked word on it if any.
    var match: (page: PDFPage, rect: CGRect?)?

    /// Scrolls so the match sits in the middle of the visible area: the first marked word, or the page's middle.
    /// Through go(to:) first, since PDFKit doesn't update its current page for a scroll it didn't make.
    func showMatch() {
        guard let (page, rect) = match, let documentView, let clip = documentView.enclosingScrollView?.contentView else { return }
        go(to: page)
        let bounds = page.bounds(for: displayBox)
        let visible = clip.bounds
        let y: CGFloat
        if let rect {
            // A marked word sits in the middle of the view.
            y = documentView.convert(convert(rect, from: page), from: self).midY - visible.height / 2
        } else {
            // Found by meaning, with nothing marked: the page opens at its top, where its heading and opening lines are.
            let top = documentView.convert(convert(CGRect(x: bounds.minX, y: bounds.maxY, width: 1, height: 1), from: page), from: self)
            y = (documentView.isFlipped ? top.minY : top.maxY - visible.height) - 8
        }
        let limit = max(0, documentView.bounds.height - visible.height)
        clip.scroll(to: NSPoint(x: visible.minX, y: min(max(0, y), limit)))
        documentView.enclosingScrollView?.reflectScrolledClipView(clip)
        reportPage()
    }

    deinit {
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
    }

    func reportPage() {
        guard let document, let page = currentPage else { return }
        onPage?(document.index(for: page) + 1, document.pageCount)
    }

    override func mouseDown(with event: NSEvent) {
        guard onClick != nil || onDoubleClick != nil else { return super.mouseDown(with: event) }
        if event.clickCount == 2 { onDoubleClick?() } else if event.clickCount == 1 { onClick?() }
    }
}

/// Carries values the compiler can't prove are thread-safe from a background task to the main thread,
/// for objects (like a freshly opened PDFDocument) that only one side uses at a time.
struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
