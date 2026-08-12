import SwiftUI

struct StatCardView: View {
    let title: String
    let value: String
    let subtitle: String?
    let icon: String
    let color: Color
    var emphasized: Bool = false

    @Environment(\.appTheme) var theme
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(color.gradient)
                    )
                    .shadow(color: color.opacity(0.35), radius: isHovering ? 8 : 4, y: isHovering ? 4 : 2)

                Spacer()

                if emphasized {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(color.opacity(0.8))
                }
            }

            Text(value)
                .font(.system(.largeTitle, design: .monospaced, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .monospacedDigit()

            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: theme.radiusMedium)
                .fill(theme.surfaceCard)
                .shadow(color: color.opacity(isHovering ? 0.18 : 0.08), radius: isHovering ? 8 : 4, y: isHovering ? 4 : 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.radiusMedium)
                .stroke(color.opacity(isHovering ? 0.35 : 0.15), lineWidth: 1.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.radiusMedium)
                .fill(color.opacity(0.03))
        )
        .scaleEffect(isHovering ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
