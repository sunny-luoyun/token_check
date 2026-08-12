import SwiftUI

struct CardStyle: ViewModifier {
    @Environment(\.appTheme) var theme

    func body(content: Content) -> some View {
        content
            .padding()
            .background(
                RoundedRectangle(cornerRadius: theme.radiusMedium)
                    .fill(.background)
                    .shadow(color: .black.opacity(0.08), radius: theme.shadowSmall, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.radiusMedium)
                    .stroke(.separator.opacity(0.3), lineWidth: 1)
            )
    }
}

struct MainContentCard: ViewModifier {
    @Environment(\.appTheme) var theme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: theme.radiusMedium)
                    .fill(theme.surfaceCard)
                    .shadow(color: .black.opacity(0.05), radius: theme.shadowSmall, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.radiusMedium)
                    .stroke(.separator.opacity(0.3), lineWidth: 1)
            )
    }
}

struct CardHoverEffect: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovering ? 1.02 : 1.0)
            .shadow(color: .black.opacity(isHovering ? 0.12 : 0.04), radius: isHovering ? 8 : 4, y: isHovering ? 4 : 2)
            .animation(.easeInOut(duration: 0.2), value: isHovering)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}

struct MetricValue: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(.title2, design: .monospaced, weight: .bold))
            .monospacedDigit()
    }
}

struct SectionTitle: ViewModifier {
    @Environment(\.appTheme) var theme

    func body(content: Content) -> some View {
        content
            .font(.headline)
            .foregroundStyle(.primary)
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(CardStyle())
    }

    func cardHoverEffect() -> some View {
        modifier(CardHoverEffect())
    }

    func mainContentCard() -> some View {
        modifier(MainContentCard())
    }

    func metricValue() -> some View {
        modifier(MetricValue())
    }

    func sectionTitle() -> some View {
        modifier(SectionTitle())
    }

    func shimmering() -> some View {
        modifier(ShimmerEffect())
    }
}

struct ShimmerEffect: ViewModifier {
    @State private var isAnimating = false

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [
                            .clear,
                            .white.opacity(0.4),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .offset(x: isAnimating ? geo.size.width : -geo.size.width)
                    .animation(
                        .easeInOut(duration: 1.5).repeatForever(autoreverses: false),
                        value: isAnimating
                    )
                }
            )
            .onAppear {
                isAnimating = true
            }
    }
}
