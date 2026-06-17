import SwiftUI

struct AppTheme {
    let primary: Color = .blue
    let secondary: Color = .teal
    let accent: Color = .indigo

    let surfacePrimary: Color = Color(nsColor: .windowBackgroundColor)
    let surfaceSecondary: Color = Color(nsColor: .underPageBackgroundColor)

    let radiusSmall: CGFloat = 8
    let radiusMedium: CGFloat = 12
    let radiusLarge: CGFloat = 16

    let shadowSmall: CGFloat = 4
    let shadowMedium: CGFloat = 8
    let shadowLarge: CGFloat = 12

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
