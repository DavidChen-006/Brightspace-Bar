import SwiftUI

struct GlassBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: backgroundStops,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [highlightColor, .clear],
                center: .topTrailing,
                startRadius: 40,
                endRadius: 260
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [accentGlow, .clear],
                center: .bottomLeading,
                startRadius: 40,
                endRadius: 240
            )
            .ignoresSafeArea()
        }
    }

    private var backgroundStops: [Color] {
        if colorScheme == .dark {
            return [
                Color(uiColor: .secondarySystemBackground),
                Color(uiColor: .systemBackground)
            ]
        }
        return [
            Color(uiColor: .systemGroupedBackground),
            Color(uiColor: .secondarySystemGroupedBackground)
        ]
    }

    private var highlightColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.4)
    }

    private var accentGlow: Color {
        colorScheme == .dark ? Color.white.opacity(0.04) : Color(uiColor: .systemGray4).opacity(0.18)
    }
}

struct GlassCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .shadow(color: shadowColor, radius: 14, x: 0, y: 8)
    }

    private var borderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.08)
    }

    private var shadowColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.25) : Color.black.opacity(0.12)
    }
}
