import SwiftUI

struct StatCardView: View {
    let title: String
    let value: String
    let subtitle: String?
    let icon: String
    let color: Color

    @Environment(\.appTheme) var theme
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(color.gradient)
                )
                .shadow(color: color.opacity(0.3), radius: 4, y: 2)

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
        .frame(minWidth: 110)
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: theme.radiusMedium)
                .fill(.background)
                .shadow(color: color.opacity(isHovering ? 0.2 : 0.1), radius: isHovering ? 8 : 4, y: isHovering ? 4 : 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.radiusMedium)
                .stroke(color.opacity(isHovering ? 0.35 : 0.15), lineWidth: 1.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.radiusMedium)
                .fill(color.opacity(0.03))
        )
        .scaleEffect(isHovering ? 1.03 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
