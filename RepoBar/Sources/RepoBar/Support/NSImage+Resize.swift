import AppKit

extension NSImage {
    func resized(to targetSize: NSSize) -> NSImage {
        let image = NSImage(size: targetSize)
        image.lockFocus()

        let aspectWidth = targetSize.width / self.size.width
        let aspectHeight = targetSize.height / self.size.height
        let aspectRatio = min(aspectWidth, aspectHeight)

        let scaledWidth = self.size.width * aspectRatio
        let scaledHeight = self.size.height * aspectRatio
        let drawingRect = NSRect(
            x: (targetSize.width - scaledWidth) / 2,
            y: (targetSize.height - scaledHeight) / 2,
            width: scaledWidth,
            height: scaledHeight
        )

        NSGraphicsContext.current?.imageInterpolation = .high

        self.draw(
            in: drawingRect,
            from: NSRect(origin: .zero, size: self.size),
            operation: .copy,
            fraction: 1.0
        )

        image.unlockFocus()
        return image
    }
}
