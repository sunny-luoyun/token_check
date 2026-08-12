import SwiftUI

struct AppTheme {
    // 导航 / 强调
    let primary: Color = .blue
    let secondary: Color = .teal
    let accent: Color = .indigo

    // 指标专属色（全局统一，深浅色自动适配）
    let cost: Color = .red
    let inputMiss: Color = .orange
    let cacheHit: Color = .green
    let output: Color = .blue
    let reasoning: Color = .purple
    let rollback: Color = .red

    // 表面
    let surfacePrimary: Color = Color(nsColor: .windowBackgroundColor)
    let surfaceSecondary: Color = Color(nsColor: .underPageBackgroundColor)
    let surfaceCard: Color = Color(nsColor: .controlBackgroundColor)
    let sidebarMaterial: Material = .ultraThinMaterial
    let sidebarSelection: Color = .blue

    // 圆角
    let radiusSmall: CGFloat = 8
    let radiusMedium: CGFloat = 12
    let radiusLarge: CGFloat = 16

    // 阴影
    let shadowSmall: CGFloat = 4
    let shadowMedium: CGFloat = 8
    let shadowLarge: CGFloat = 12

    // 间距
    let spacingSmall: CGFloat = 4
    let spacingMedium: CGFloat = 8
    let spacingLarge: CGFloat = 16
    let spacingXLarge: CGFloat = 24
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme()
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}
