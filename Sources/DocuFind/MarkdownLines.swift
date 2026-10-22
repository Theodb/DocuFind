import Foundation

/// Markdown read line by line for the document readers: headings with their level, list items as bullets, and
/// fenced code kept exactly as written. Inline styles (bold, italics, code, links) stay in the text and are
/// drawn when the line is shown.
enum MarkdownLines {
    static let extensions: Set<String> = ["md", "markdown"]

    struct Parsed: Equatable {
        var lines: [String]
        /// Heading lines and their level, 1 to 6.
        var headings: [Int: Int]
        /// Lines inside a code block.
        var code: Set<Int>
    }

    /// `startsInCode` is for an excerpt that begins inside a code block opened earlier in the file.
    /// Fence lines become blank, so a code block keeps a gap around it without showing its ``` marks.
    static func parse(_ source: [String], startsInCode: Bool = false) -> Parsed {
        var lines = source, headings: [Int: Int] = [:], code = Set<Int>(), fenced = startsInCode
        for index in lines.indices {
            if isFence(lines[index]) {
                fenced.toggle()
                lines[index] = ""
            } else if fenced {
                code.insert(index)
            } else if let range = lines[index].range(of: #"^\s{0,3}#{1,6}\s+"#, options: .regularExpression) {
                headings[index] = lines[index][range].filter { $0 == "#" }.count
                lines[index] = String(lines[index][range.upperBound...])
            } else {
                lines[index] = lines[index].replacingOccurrences(of: #"^(\s*)[-*+]\s+"#, with: "$1• ", options: .regularExpression)
            }
        }
        return Parsed(lines: lines, headings: headings, code: code)
    }

    /// Whether text ends inside an open code block: an odd number of fences.
    static func endsInCode(_ text: Substring) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).filter { isFence(String($0)) }.count % 2 == 1
    }

    private static func isFence(_ line: String) -> Bool {
        line.range(of: #"^\s{0,3}(```|~~~)"#, options: .regularExpression) != nil
    }
}
