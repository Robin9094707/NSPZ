import SwiftUI

enum Theme {
    static let coral = Color(red: 1.00, green: 0.33, blue: 0.36)
    static let azure = Color(red: 0.16, green: 0.62, blue: 1.00)
    static let violet = Color(red: 0.55, green: 0.36, blue: 1.00)
    static let mint = Color(red: 0.20, green: 0.86, blue: 0.68)

    static let accentGradient = LinearGradient(colors: [azure, violet, coral],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)

    static func tint(for kind: GameMetadata.Kind) -> Color {
        switch kind {
        case .base: azure
        case .update: mint
        case .dlc: violet
        case .unknown: coral
        }
    }
}

/// Lebendiger, langsam fließender Mesh-Gradient als Untergrund für das Glas.
struct AppBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var animated = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !animated || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            MeshGradient(
                width: 3, height: 3,
                points: points(t),
                colors: colors,
                smoothsColors: true
            )
        }
        .ignoresSafeArea()
    }

    private func points(_ t: Double) -> [SIMD2<Float>] {
        let a = Float(sin(t * 0.21)) * 0.12
        let b = Float(cos(t * 0.17)) * 0.10
        let c = Float(sin(t * 0.13 + 1)) * 0.08
        return [
            [0, 0], [0.5 + a, 0], [1, 0],
            [0, 0.5 + b], [0.5 + c, 0.5 - a], [1, 0.5 + c],
            [0, 1], [0.5 - b, 1], [1, 1],
        ]
    }

    private var colors: [Color] {
        if scheme == .dark {
            return [
                Color(red: 0.05, green: 0.06, blue: 0.16), Color(red: 0.10, green: 0.10, blue: 0.30), Color(red: 0.22, green: 0.05, blue: 0.20),
                Color(red: 0.03, green: 0.18, blue: 0.32), Color(red: 0.08, green: 0.07, blue: 0.20), Color(red: 0.30, green: 0.06, blue: 0.14),
                Color(red: 0.02, green: 0.10, blue: 0.20), Color(red: 0.12, green: 0.05, blue: 0.26), Color(red: 0.06, green: 0.04, blue: 0.12),
            ]
        }
        return [
            Color(red: 0.86, green: 0.92, blue: 1.00), Color(red: 0.92, green: 0.88, blue: 1.00), Color(red: 1.00, green: 0.88, blue: 0.90),
            Color(red: 0.78, green: 0.90, blue: 1.00), Color(red: 0.96, green: 0.95, blue: 1.00), Color(red: 1.00, green: 0.84, blue: 0.86),
            Color(red: 0.84, green: 0.96, blue: 0.98), Color(red: 0.90, green: 0.86, blue: 1.00), Color(red: 0.98, green: 0.92, blue: 0.96),
        ]
    }
}

/// Karte aus Liquid Glass.
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 28
    var tint: Color? = nil
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(tint.map { Glass.regular.tint($0.opacity(0.18)) } ?? .regular,
                         in: .rect(cornerRadius: cornerRadius))
    }
}

/// Kleine Glas-Kapsel für Metadaten (Title-ID, Version …).
struct InfoChip: View {
    let text: String
    var symbol: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
    }
}

/// Farbiges Symbol-Kachel-Icon.
struct KindTile: View {
    let kind: GameMetadata.Kind
    var size: CGFloat = 52

    var body: some View {
        let tint = Theme.tint(for: kind)
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(LinearGradient(colors: [tint, tint.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                Image(systemName: kind.symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 0.8)
            }
            .frame(width: size, height: size)
            .shadow(color: tint.opacity(0.35), radius: 10, y: 4)
    }
}

/// Fortschrittsbalken mit Verlauf und Schimmer.
struct GlowProgressBar: View {
    let value: Double
    var height: CGFloat = 10
    @State private var shimmer = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.10))
                Capsule()
                    .fill(Theme.accentGradient)
                    .frame(width: max(height, geo.size.width * value))
                    .overlay {
                        Capsule()
                            .fill(LinearGradient(colors: [.clear, .white.opacity(0.45), .clear],
                                                 startPoint: .leading, endPoint: .trailing))
                            .offset(x: shimmer ? geo.size.width : -geo.size.width)
                            .mask(Capsule())
                    }
                    .clipShape(Capsule())
                    .shadow(color: Theme.violet.opacity(0.5), radius: 6)
                    .animation(.smooth(duration: 0.35), value: value)
            }
        }
        .frame(height: height)
        .onAppear {
            withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) { shimmer = true }
        }
    }
}

/// Runder Fortschrittsring (für die Tab-Leisten-Anzeige).
struct ProgressRing: View {
    let value: Double
    var lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: value)
                .stroke(AngularGradient(colors: [Theme.azure, Theme.violet, Theme.coral, Theme.azure], center: .center),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth, value: value)
        }
    }
}
