@testable import repobarcli
import Testing

struct MarkdownRenderingTests {
    @Test
    func `renders ansi when color enabled`() {
        let markdown = """
        # Heading

        - Item 1
        - Item 2
        """
        let output = renderMarkdown(
            markdown,
            request: MarkdownRenderRequest(width: 40, wrap: true, color: true, plain: false)
        )
        #expect(output.contains("\u{001B}["))
        #expect(output.contains("Heading"))
    }

    @Test
    func `strips ansi when plain`() {
        let markdown = """
        # Heading

        - Item 1
        """
        let output = renderMarkdown(
            markdown,
            request: MarkdownRenderRequest(width: 40, wrap: true, color: true, plain: true)
        )
        #expect(output.contains("\u{001B}[") == false)
        #expect(output.contains("Heading"))
    }

    @Test
    func `renders images as readable text`() {
        let markdown = """
        Before

        ![RepoBar screenshot](docs/screenshot.png)

        ![](docs/logo.png)
        """

        let output = renderMarkdown(
            markdown,
            request: MarkdownRenderRequest(width: 80, wrap: true, color: false, plain: true)
        )

        #expect(output.contains("RepoBar screenshot (docs/screenshot.png)"))
        #expect(output.contains("docs/logo.png"))
        #expect(output.contains("Image(_data:") == false)
    }
}
