---
summary: "Markdown rendering notes for RepoBar: current SwiftUI approach, cross-platform plan, and options."
read_when:
  - Changing markdown rendering in menus or changelog previews
  - Adding iOS markdown rendering for shared UI
  - Evaluating Swift Markdown / AST-based rendering
---

# Markdown Rendering (RepoBar)

## Goals
- Cross-platform (macOS + iOS).
- Good block layout (headings, lists, code, quotes).
- No AppKit/UIKit-only rendering in core path.

## Current Approach
- SwiftUI block renderer in `ChangelogMenuView`.
- Cross-platform `RepoBarCore.MarkdownBlockParser` (Swift Markdown AST).
- Inline styling via `AttributedString(markdown:)`.

## What Markdownosaur Does (Learnings)
- Uses `swift-markdown` AST + `MarkupVisitor`.
- Builds real block structure and list indentation.
- Adds explicit newlines between blocks.
- Styles inline runs by applying font traits.
- High fidelity, but example outputs `NSAttributedString` for UIKit/AppKit.

## Cross-Platform Options
1) **AST → SwiftUI blocks (recommended)**
   - Parse markdown with `swift-markdown`.
   - Walk AST and emit `MarkdownBlock` (heading/list/paragraph/code/quote).
   - Render blocks in SwiftUI (shared between macOS/iOS).
   - Use `AttributedString(markdown:)` only for inline runs.

2) **NSTextView / UITextView**
   - Best fidelity, but platform-specific.
   - Not cross-platform; avoid for shared renderer.

3) **`NSAttributedString(markdown:)` only**
   - Easy, but block semantics often lost in SwiftUI `Text`.
   - Still not great for list indentation.

## Implementation Details (AST → SwiftUI)
- `swift-markdown` dependency in `Package.swift`.
- `MarkdownBlockParser` walks the AST and emits `MarkdownBlock`:
  - `visitHeading`, `visitParagraph`, `visitUnorderedList`, `visitOrderedList`, `visitListItem`,
    `visitCodeBlock`, `visitBlockQuote`.
  - Track list depth; add explicit block spacing (single/double newline semantics).
- Convert AST nodes into `MarkdownBlock` + inline text.
- Render in SwiftUI (same on macOS + iOS).

## Notes / Gotchas
- SwiftUI `Text` ignores many paragraph styles; block rendering must manage spacing.
- Lists need explicit indentation + markers for correct wrap.
- Inline parsing should stay lightweight; avoid full markdown parsing per line if possible.

## Next Steps
- Expand block coverage (tables, images, nested block quotes).
- Consider a shared UI package for block renderers (macOS + iOS).
