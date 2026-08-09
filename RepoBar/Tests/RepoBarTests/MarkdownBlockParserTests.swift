import RepoBarCore
import Testing

struct MarkdownBlockParserTests {
    @Test
    func `Unordered lists preserve nesting depth`() {
        let markdown = """
        - First
          - Child
        - Second
        """

        let blocks = MarkdownBlockParser.parse(markdown: markdown)
        #expect(blocks == [
            .listItem(marker: "•", text: "First", indentLevel: 0),
            .listItem(marker: "•", text: "Child", indentLevel: 1),
            .listItem(marker: "•", text: "Second", indentLevel: 0)
        ])
    }

    @Test
    func `Ordered lists keep numbered markers`() {
        let markdown = """
        1. One
        2. Two
        """

        let blocks = MarkdownBlockParser.parse(markdown: markdown)
        #expect(blocks == [
            .listItem(marker: "1.", text: "One", indentLevel: 0),
            .listItem(marker: "2.", text: "Two", indentLevel: 0)
        ])
    }

    @Test
    func `Inline markdown is preserved for SwiftUI rendering`() {
        let markdown = """
        - **Bold** and `code` [link](https://example.com)
        """

        let blocks = MarkdownBlockParser.parse(markdown: markdown)
        #expect(blocks == [
            .listItem(
                marker: "•",
                text: "**Bold** and `code` [link](https://example.com)",
                indentLevel: 0
            )
        ])
    }

    @Test
    func `Code blocks are preserved`() {
        let markdown = """
        ```swift
        let value = 1
        ```
        """

        let blocks = MarkdownBlockParser.parse(markdown: markdown)
        #expect(blocks == [
            .codeBlock(text: "let value = 1")
        ])
    }

    @Test
    func `Block quotes render as quote blocks`() {
        let markdown = """
        > Quoted text
        """

        let blocks = MarkdownBlockParser.parse(markdown: markdown)
        #expect(blocks == [
            .blockQuote(text: "Quoted text", indentLevel: 0)
        ])
    }
}
