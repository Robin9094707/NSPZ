import SwiftUI

@main
struct NSPZApp: App {
    @State private var library: LibraryStore
    @State private var queue: ConversionQueue

    init() {
        let library = LibraryStore()
        _library = State(initialValue: library)
        _queue = State(initialValue: ConversionQueue(library: library))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(queue)
        }
    }
}

enum AppTab: Hashable {
    case convert, library, settings
}

struct RootView: View {
    @Environment(ConversionQueue.self) private var queue
    @Environment(LibraryStore.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSplash = true
    @State private var selection: AppTab = .convert

    var body: some View {
        ZStack {
            MainTabView(selection: $selection)
                .scaleEffect(showSplash ? 0.94 : 1)
                .blur(radius: showSplash ? 14 : 0)
                .opacity(showSplash ? 0 : 1)

            if showSplash {
                SplashView {
                    withAnimation(.smooth(duration: 0.75)) { showSplash = false }
                }
                .transition(.asymmetric(insertion: .identity,
                                        removal: .opacity.combined(with: .scale(scale: 1.18))))
                .zIndex(1)
            }
        }
        .onOpenURL { url in
            queue.add(urls: [url])
            selection = .convert
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { library.refresh() }
        }
    }
}

struct MainTabView: View {
    @Binding var selection: AppTab
    @Environment(ConversionQueue.self) private var queue
    @Environment(LibraryStore.self) private var library

    var body: some View {
        TabView(selection: $selection) {
            Tab("Konvertieren", systemImage: "arrow.triangle.2.circlepath", value: AppTab.convert) {
                ConvertView()
            }
            .badge(queue.readyJobs.count)

            Tab("Bibliothek", systemImage: "square.stack.3d.up.fill", value: AppTab.library) {
                LibraryView()
            }

            Tab("Einstellungen", systemImage: "gearshape.fill", value: AppTab.settings) {
                SettingsView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            ActivityAccessory(selection: $selection)
        }
        .sensoryFeedback(.success, trigger: queue.completedCount)
        .sensoryFeedback(.error, trigger: queue.failedCount)
    }
}

/// Liquid-Glass-Zubehör über der Tab-Leiste – zeigt die laufende Konvertierung überall in der App.
struct ActivityAccessory: View {
    @Binding var selection: AppTab
    @Environment(ConversionQueue.self) private var queue
    @Environment(LibraryStore.self) private var library
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        Button {
            selection = queue.activeJob != nil ? .convert : .library
        } label: {
            HStack(spacing: 12) {
                if let job = queue.activeJob {
                    ProgressRing(value: job.fraction, lineWidth: 3.5)
                        .frame(width: 24, height: 24)
                        .overlay {
                            Image(systemName: "bolt.fill").font(.system(size: 9, weight: .bold))
                        }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(job.metadata.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if placement != .inline {
                            Text("\(Int(job.fraction * 100)) % · \(Format.speed(job.bytesPerSecond))")
                                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    Spacer(minLength: 0)
                    Text("\(Int(job.fraction * 100)) %")
                        .font(.subheadline.weight(.bold)).monospacedDigit()
                        .contentTransition(.numericText())
                } else {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Theme.mint)
                        .symbolEffect(.bounce, value: queue.completedCount)
                    Text(library.items.isEmpty ? "Bereit zum Konvertieren" : "\(library.items.count) NSP · \(Format.size(library.totalSize))")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 16)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
