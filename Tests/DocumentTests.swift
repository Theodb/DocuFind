import Foundation

@main
struct DocumentTests {
    static func main() {
        // Code inside a fence is shown exactly as written: no headings, bullets or stripped stars.
        let parsed = MarkdownLines.parse(["# Setup", "Run **this**:", "```bash", "# install", "- x", "echo $((2**8))", "```", "* item", "### Notes"])
        precondition(parsed.lines == ["Setup", "Run **this**:", "", "# install", "- x", "echo $((2**8))", "", "• item", "Notes"])
        precondition(parsed.headings == [0: 1, 8: 3])
        precondition(parsed.code == [3, 4, 5])

        // An excerpt that starts inside a code block opened earlier keeps it as code until the closing fence.
        precondition(MarkdownLines.endsInCode("intro\n```python\nx = 1\n"))
        precondition(!MarkdownLines.endsInCode("```\ncode\n```\nprose\n"))
        let excerpt = MarkdownLines.parse(["# not a heading", "```", "## Heading"], startsInCode: true)
        precondition(excerpt.code == [0] && excerpt.headings == [2: 2] && excerpt.lines == ["# not a heading", "", "Heading"])
        print("Document checks passed.")
    }
}
