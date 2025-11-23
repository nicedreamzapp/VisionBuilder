import SwiftUI

// MARK: - Universal Glass Style (Enhanced with Liquid Glass)

struct UniversalGlassStyle: ViewModifier {
    let variant: Variant
    let isFloating: Bool
    let adaptiveTint: Color?
    @Environment(\.colorScheme) var colorScheme

    enum Variant {
        case regular
        case clear
    }

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    // Base: Adaptive material based on variant and color scheme
                    RoundedRectangle(cornerRadius: isFloating ? 20 : 16)
                        .fill(variant == .regular ? .regularMaterial : .ultraThinMaterial)
                        .opacity(colorScheme == .dark ? 0.8 : 1.0)

                    // Lensing: Gradient for light bending, simulating refraction
                    RoundedRectangle(cornerRadius: isFloating ? 20 : 16)
                        .fill(LinearGradient(colors: [.white.opacity(0.3), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .blendMode(.softLight)

                    // Highlights/Shadows: Dynamic based on size and environment
                    RoundedRectangle(cornerRadius: isFloating ? 20 : 16)
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
                        .shadow(color: .black.opacity(isFloating ? 0.15 : 0.08), radius: 10, y: 5)
                        .blur(radius: 2)

                    // Tint: Adaptive to background and mode
                    if let tint = adaptiveTint {
                        RoundedRectangle(cornerRadius: isFloating ? 20 : 16)
                            .fill(tint.opacity(colorScheme == .dark ? 0.12 : 0.08))
                    }
                }
            }
            .scaleEffect(isFloating ? 1.02 : 1.0)
            .animation(.spring(response: 0.3), value: colorScheme)
    }
}

// Extension with new name
extension View {
    func glassStyle(
        variant: UniversalGlassStyle.Variant = .regular,
        floating: Bool = true,
        tint: Color? = nil
    ) -> some View {
        modifier(UniversalGlassStyle(variant: variant, isFloating: floating, adaptiveTint: tint))
    }
}

// MARK: - Common Button Styles

struct PrimaryButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(color)
                    .shadow(color: color.opacity(0.3), radius: 8, y: 4)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(.primary)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .glassStyle(variant: .clear, floating: false)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Reusable Card Components

struct QuickStatCard: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title2.bold())
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding()
        .glassStyle(variant: .regular, floating: false)
    }
}

struct SimpleCard: View {
    let content: AnyView

    init<Content: View>(@ViewBuilder content: () -> Content) {
        self.content = AnyView(content())
    }

    var body: some View {
        content
            .padding()
            .glassStyle(variant: .regular, floating: false)
    }
}

// MARK: - App Colors (Rich Color Palette)

extension Color {
    // Primary brand colors
    static let appBlue = Color(red: 0.25, green: 0.47, blue: 0.95)
    static let appPurple = Color(red: 0.55, green: 0.35, blue: 0.95)
    static let appGreen = Color(red: 0.2, green: 0.78, blue: 0.55)
    static let appOrange = Color(red: 1.0, green: 0.6, blue: 0.25)
    static let appPink = Color(red: 0.95, green: 0.4, blue: 0.6)
    static let appTeal = Color(red: 0.2, green: 0.75, blue: 0.8)

    // Tab-specific accent colors
    static let labelTabAccent = Color(red: 0.35, green: 0.5, blue: 1.0)
    static let datasetTabAccent = Color(red: 0.2, green: 0.8, blue: 0.6)
    static let inboxTabAccent = Color(red: 1.0, green: 0.55, blue: 0.3)
    static let insightsTabAccent = Color(red: 0.6, green: 0.4, blue: 0.95)

    // Gradient colors for backgrounds
    static let gradientBlueLight = Color(red: 0.85, green: 0.9, blue: 1.0)
    static let gradientBlueMedium = Color(red: 0.7, green: 0.82, blue: 1.0)
    static let gradientPurpleLight = Color(red: 0.92, green: 0.88, blue: 1.0)
    static let gradientGreenLight = Color(red: 0.85, green: 0.98, blue: 0.92)
    static let gradientOrangeLight = Color(red: 1.0, green: 0.92, blue: 0.85)

    // Card background colors
    static let cardBlue = Color(red: 0.93, green: 0.95, blue: 1.0)
    static let cardGreen = Color(red: 0.9, green: 0.98, blue: 0.93)
    static let cardOrange = Color(red: 1.0, green: 0.95, blue: 0.9)
    static let cardPurple = Color(red: 0.96, green: 0.93, blue: 1.0)
}

// MARK: - Tab Theme System

enum TabTheme {
    case label
    case dataset
    case inbox
    case insights

    var gradient: LinearGradient {
        switch self {
        case .label:
            return LinearGradient(
                colors: [Color.gradientBlueLight, Color.gradientPurpleLight.opacity(0.7), Color.white],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .dataset:
            return LinearGradient(
                colors: [Color.gradientGreenLight, Color.gradientBlueLight.opacity(0.5), Color.white],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .inbox:
            return LinearGradient(
                colors: [Color.gradientOrangeLight, Color.gradientPurpleLight.opacity(0.4), Color.white],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .insights:
            return LinearGradient(
                colors: [Color.gradientPurpleLight, Color.gradientBlueLight.opacity(0.6), Color.white],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    var accentColor: Color {
        switch self {
        case .label: return .labelTabAccent
        case .dataset: return .datasetTabAccent
        case .inbox: return .inboxTabAccent
        case .insights: return .insightsTabAccent
        }
    }

    var headerGradient: LinearGradient {
        switch self {
        case .label:
            return LinearGradient(colors: [.appBlue, .appPurple], startPoint: .leading, endPoint: .trailing)
        case .dataset:
            return LinearGradient(colors: [.appGreen, .appTeal], startPoint: .leading, endPoint: .trailing)
        case .inbox:
            return LinearGradient(colors: [.appOrange, .appPink], startPoint: .leading, endPoint: .trailing)
        case .insights:
            return LinearGradient(colors: [.appPurple, .appBlue], startPoint: .leading, endPoint: .trailing)
        }
    }
}

// MARK: - Common Backgrounds

struct AppBackgroundGradient: View {
    var theme: TabTheme = .label

    var body: some View {
        theme.gradient
            .ignoresSafeArea()
    }
}

struct ThemedBackground: View {
    let theme: TabTheme

    var body: some View {
        ZStack {
            theme.gradient

            // Subtle decorative circles
            GeometryReader { geo in
                Circle()
                    .fill(theme.accentColor.opacity(0.08))
                    .frame(width: 300, height: 300)
                    .blur(radius: 60)
                    .offset(x: -50, y: -100)

                Circle()
                    .fill(Color.appPurple.opacity(0.06))
                    .frame(width: 250, height: 250)
                    .blur(radius: 50)
                    .offset(x: geo.size.width - 100, y: geo.size.height - 200)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Empty States (Colorful)

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var accentColor: Color = .appBlue
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 20) {
            // Colorful icon with gradient background
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [accentColor.opacity(0.2), accentColor.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 100)

                Image(systemName: icon)
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [accentColor, accentColor.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            VStack(spacing: 8) {
                Text(title)
                    .font(.title3.bold())
                    .foregroundColor(.primary)

                Text(message)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }

            if let actionTitle = actionTitle, let action = action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(
                            LinearGradient(
                                colors: [accentColor, accentColor.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(12)
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Colorful Action Card

struct ActionCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                // Gradient icon background
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(
                            LinearGradient(
                                colors: [color, color.opacity(0.7)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 56, height: 56)
                        .shadow(color: color.opacity(0.3), radius: 8, y: 4)

                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.primary)

                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.body)
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Gradient Header Card

struct GradientHeaderCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let gradient: LinearGradient

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title2.bold())
                    .foregroundColor(.white)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.85))
            }

            Spacer()

            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundColor(.white.opacity(0.9))
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(gradient)
                .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
        )
    }
}

// MARK: - Stat Card with Accent

struct AccentStatCard: View {
    let icon: String
    let value: String
    let label: String
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [accentColor, accentColor.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Spacer()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title.bold())
                    .foregroundColor(.primary)

                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(accentColor.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(accentColor.opacity(0.1), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
        )
    }
}

// MARK: - App Configuration Constants

extension AppConfig {
    static let defaultBoxSize = CGSize(width: 0.2, height: 0.2)
    static let cropRegionSize: CGFloat = 200.0
    static let edgeOverlayOpacity: Double = 0.6
    static let touchHitSize: CGFloat = 44.0
    static let defaultContrastAdjustment: Float = 1.0
}

// Keep the struct for compatibility
struct AppConfig {
    // Empty - just for namespace
}
