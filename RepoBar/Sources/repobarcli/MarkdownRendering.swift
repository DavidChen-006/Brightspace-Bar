import Foundation
import Swiftdansi

struct MarkdownRenderRequest {
    var width: Int?
    var wrap: Bool?
    var color: Bool?
    var plain: Bool
}

func renderMarkdown(_ markdown: String, request: MarkdownRenderRequest) -> String {
    let options = RenderOptions(
        wrap: request.wrap,
        width: request.width,
        color: request.color
    )
    let markdown = markdown.replacingMarkdownImagesForTerminal()

    if request.plain {
        return strip(markdown, options: options)
    }

    return render(markdown, options: options)
}

private extension String {
    func replacingMarkdownImagesForTerminal() -> String {
        let pattern = #"\!\[([^\]]*)\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return self }

        let range = NSRange(self.startIndex ..< self.endIndex, in: self)
        let matches = regex.matches(in: self, range: range)
        guard matches.isEmpty == false else { return self }

        var output = self
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: output),
                  let altRange = Range(match.range(at: 1), in: output),
                  let targetRange = Range(match.range(at: 2), in: output)
            else { continue }

            let alt = String(output[altRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let target = String(output[targetRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = alt.isEmpty ? target : "\(alt) (\(target))"
            output.replaceSubrange(fullRange, with: replacement)
        }
        return output
    }
}
