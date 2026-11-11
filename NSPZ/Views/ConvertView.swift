import SwiftUI
import NSZKit

struct ConvertView: View {
    @Environment(ConversionQueue.self) private var queue
    @Environment(LibraryStore.self) private var library
    @State private var showImporter = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    HeroCard(compact: !queue.jobs.isEmpty) { showImporter = true }

                    if !queue.jobs.isEmpty {
                        sectionHeader("Warteschlange", trailing: queue.hasFinishedJobs ? "Erledigte entfernen" : nil) {
                            withAnimation(.smooth) { queue.clearFinished() }
                        }
                        LazyVStack(spacing: 14) {
                            ForEach(queue.jobs) { job in
                                JobCard(job: job)
                                    .transition(.asymmetric(
                                        insertion: .scale(scale: 0.9).combined(with: .opacity),
                                        removal: .opacity.combined(with: .move(edge: .trailing))))
                            }
                        }
                    }

                    let pending = library.storedNSZ.filter { item in
                        !queue.jobs.contains { $0.sourceURL.standardizedFileURL == item.url.standardizedFileURL }
                    }
                    if !pending.isEmpty {
                        sectionHeader("In NSPZ gespeichert", trailing: nil, action: {})
                        VStack(spacing: 10) {
                            ForEach(pending) { item in
                                StoredNSZRow(item: item) {
                                    withAnimation(.bouncy) { queue.add(urls: [item.url], securityScoped: false) }
                                }
                            }
                        }
                    }

                    if queue.jobs.isEmpty {
                        HowItWorksCard()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
                .animation(.bouncy(duration: 0.5), value: queue.jobs.map(\.id))
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .background { AppBackground() }
            .navigationTitle("Konvertieren")
            .toolbar {
                if !queue.readyJobs.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            withAnimation(.bouncy) { queue.startAll() }
                        } label: {
                            Label("Alle starten", systemImage: "play.fill")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showImporter = true
                    } label: {
                        Label("NSZ hinzufügen", systemImage: "plus")
                    }
                    .buttonStyle(.glassProminent)
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.nsz, .data],
                          allowsMultipleSelection: true) { result in
                switch result {
                case let .success(urls):
                    withAnimation(.bouncy) { queue.add(urls: urls) }
                case let .failure(error):
                    importError = error.localizedDescription
                }
            }
            .alert("Import fehlgeschlagen", isPresented: .constant(importError != nil)) {
                Button("OK") { importError = nil }
            } message: {
                Text(importError ?? "")
            }
        }
    }

    private func sectionHeader(_ title: String, trailing: String?, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.title3.weight(.bold))
            Spacer()
            if let trailing {
                Button(trailing, action: action)
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.glass)
            }
        }
        .padding(.top, 4)
        .padding(.horizontal, 4)
    }
}

// MARK: - Hero

private struct HeroCard: View {
    let compact: Bool
    let onImport: () -> Void
    @State private var animate = false

    var body: some View {
        GlassCard(cornerRadius: 34, tint: Theme.violet, padding: compact ? 18 : 26) {
            if compact {
                HStack(spacing: 14) {
                    icon(size: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Weitere Dateien").font(.headline)
                        Text("NSZ aus Dateien, iCloud oder USB-Stick").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button(action: onImport) {
                        Image(systemName: "plus").font(.headline)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                }
            } else {
                VStack(spacing: 18) {
                    icon(size: 92)
                        .padding(.top, 6)
                    VStack(spacing: 6) {
                        Text("NSZ → NSP")
                            .font(.system(size: 34, weight: .heavy, design: .rounded))
                            .foregroundStyle(Theme.accentGradient)
                        Text("Wähle deine komprimierten Dumps. Die Umwandlung läuft komplett auf deinem iPhone – egal wie groß die Dateien sind.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Button(action: onImport) {
                        Label("NSZ-Dateien auswählen", systemImage: "doc.badge.plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { animate = true }
    }

    private func icon(size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(Theme.accentGradient)
                .opacity(0.85)
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: size * 0.44, weight: .bold))
                .foregroundStyle(.white)
                .symbolEffect(.rotate.byLayer, options: .repeat(.periodic(delay: 2.5)), isActive: animate)
        }
        .frame(width: size, height: size)
        .glassEffect(.regular.interactive(), in: .circle)
        .shadow(color: Theme.violet.opacity(0.45), radius: 16, y: 6)
    }
}

// MARK: - Gespeicherte NSZ

private struct StoredNSZRow: View {
    let item: LibraryItem
    let onAdd: () -> Void

    var body: some View {
        GlassCard(cornerRadius: 22, padding: 14) {
            HStack(spacing: 12) {
                KindTile(kind: item.metadata.kind, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.metadata.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(Format.size(item.size)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Hinzufügen", systemImage: "plus", action: onAdd)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
            }
        }
    }
}

// MARK: - Info

private struct HowItWorksCard: View {
    var body: some View {
        GlassCard(cornerRadius: 28) {
            VStack(alignment: .leading, spacing: 14) {
                Label("So funktioniert's", systemImage: "sparkles")
                    .font(.headline)
                step("1", "NSZ-Dateien auswählen – aus der Dateien-App, iCloud Drive, einem USB-Stick oder per „Öffnen in…“.")
                step("2", "NSPZ liest nur die Header, zeigt dir Titel-ID, Version und Zielgröße und wandelt dann direkt von der Quelle um – ohne Zwischenkopie.")
                step("3", "Jede NCA wird dekomprimiert, wieder verschlüsselt und per SHA-256 geprüft. Die fertige NSP landet in der Bibliothek.")
                Divider().opacity(0.4)
                Label {
                    Text("Keine prod.keys nötig: NSZ-Dateien enthalten die Sektionsschlüssel bereits, die Umwandlung ist verlustfrei und bitgenau.")
                } icon: {
                    Image(systemName: "key.slash.fill").foregroundStyle(Theme.mint)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.subheadline.weight(.heavy))
                .frame(width: 28, height: 28)
                .glassEffect(.regular.tint(Theme.azure.opacity(0.35)), in: .circle)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}
