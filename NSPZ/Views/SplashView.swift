import SwiftUI

/// Öffnungsanimation: Eine „NSZ"-Glaskapsel teilt sich, ein Pfeil fließt hindurch,
/// und sie verschmilzt (Liquid-Glass-Morphing) zu „NSP" – dann öffnet sich die App.
struct SplashView: View {
    var onFinish: () -> Void

    @Namespace private var glass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0
    @State private var arrowProgress: CGFloat = 0
    @State private var titleVisible = false
    @State private var glow = false

    var body: some View {
        ZStack {
            AppBackground()

            Circle()
                .fill(RadialGradient(colors: [Theme.violet.opacity(0.55), .clear], center: .center,
                                     startRadius: 10, endRadius: 260))
                .frame(width: 520, height: 520)
                .scaleEffect(glow ? 1.15 : 0.6)
                .opacity(glow ? 1 : 0)
                .blur(radius: 30)

            VStack(spacing: 34) {
                GlassEffectContainer(spacing: 26) {
                    HStack(spacing: phase == 1 ? 24 : 0) {
                        if phase <= 1 {
                            pill("NSZ", tint: Theme.coral)
                                .glassEffectID("source", in: glass)
                        }
                        if phase == 1 {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundStyle(.primary)
                                .frame(width: 56, height: 56)
                                .glassEffect(.regular.interactive(), in: .circle)
                                .glassEffectID("arrow", in: glass)
                                .rotationEffect(.degrees(arrowProgress * 360))
                        }
                        if phase >= 1 {
                            pill("NSP", tint: Theme.azure)
                                .glassEffectID("target", in: glass)
                                .scaleEffect(phase >= 2 ? 1.25 : 1)
                        }
                    }
                }

                VStack(spacing: 8) {
                    Text("NSPZ")
                        .font(.system(size: 52, weight: .black, design: .rounded))
                        .foregroundStyle(Theme.accentGradient)
                    Text("NSZ zu NSP – nativ, schnell, privat.")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .opacity(titleVisible ? 1 : 0)
                .offset(y: titleVisible ? 0 : 18)
                .blur(radius: titleVisible ? 0 : 8)
            }
        }
        .task { await play() }
        .onTapGesture { onFinish() }
    }

    private func pill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 36, weight: .heavy, design: .rounded))
            .tracking(1.5)
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .glassEffect(.regular.tint(tint.opacity(0.45)).interactive(), in: .capsule)
    }

    private func play() async {
        if reduceMotion {
            phase = 2; titleVisible = true
            try? await Task.sleep(for: .milliseconds(700))
            onFinish()
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        withAnimation(.bouncy(duration: 0.7, extraBounce: 0.1)) { glow = true }
        try? await Task.sleep(for: .milliseconds(300))
        withAnimation(.bouncy(duration: 0.75, extraBounce: 0.12)) { phase = 1 }
        withAnimation(.smooth(duration: 0.9)) { arrowProgress = 1 }
        try? await Task.sleep(for: .milliseconds(850))
        withAnimation(.bouncy(duration: 0.7, extraBounce: 0.18)) { phase = 2 }
        try? await Task.sleep(for: .milliseconds(200))
        withAnimation(.smooth(duration: 0.6)) { titleVisible = true }
        try? await Task.sleep(for: .milliseconds(900))
        onFinish()
    }
}
