import AppKit
import SwiftUI

@MainActor
struct AboutLinkRow: View {
    let icon: String
    let title: String
    let url: String

    @State private var hovering = false

    var body: some View {
        Button {
            if let url = URL(string: self.url) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: self.icon)
                Text(self.title)
                    .underline(self.hovering, color: .accentColor)
            }
            .foregroundColor(.accentColor)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .onHover { self.hovering = $0 }
    }
}
