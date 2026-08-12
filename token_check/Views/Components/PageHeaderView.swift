import SwiftUI

struct PageHeaderView<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var toolbar: Content

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.largeTitle, weight: .bold))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: true, vertical: false)

            Spacer()

            toolbar
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
