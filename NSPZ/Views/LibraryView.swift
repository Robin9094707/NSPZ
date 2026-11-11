import SwiftUI
import UIKit
import NSZKit

struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @State private var search = ""
    @State private var pendingDelete: LibraryItem?

    private var filtered: [LibraryItem] {
        guard !search.isEmpty else { return library.items }
        return library.items.filter {
            $0.name.localizedCaseInsensitiveContains(search) || ($0.metadata.titleID?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    var body: some View {
        @Bindable var library = library
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    StorageCard()
                    if library.items.isEmpty {
                        ContentUnavailableView {
                            Label("Noch keine NSPs", systemImage: "square.stack.3d.up.slash")
                        } description: {
                            Text("Konvertierte Dateien erscheinen hier und in der Dateien-App unter „Auf meinem iPhone › NSPZ“.")
                        }
                        .padding(.top, 40)
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(filtered) { item in
                                NavigationLink(value: item) {
                                    LibraryRow(item: item)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    ShareLink(item: item.url) { Label("Teilen", systemImage: "square.and.arrow.up") }
                                    Button("In Dateien zeigen", systemImage: "folder") { FilesApp.reveal(item.url) }
                                    Button("Löschen", systemImage: "trash", role: .destructive) { pendingDelete = item }
                                }
                                .transition(.scale(scale: 0.92).combined(with: .opacity))
                            }
                        }
                        .animation(.bouncy, value: filtered.map(\.id))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .background { AppBackground() }
            .navigationTitle("Bibliothek")
            .navigationDestination(for: LibraryItem.self) { item in
                LibraryDetailView(item: item)
            }
            .searchable(text: $search, prompt: "Titel oder Title-ID")
            .refreshable { library.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sortierung", selection: $library.sort) {
                            ForEach(LibraryStore.Sort.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: {
                        Label("Sortieren", systemImage: "arrow.up.arrow.down")
                    }
                }
            }
            .confirmationDialog("„\(pendingDelete?.metadata.title ?? "")“ löschen?",
                                isPresented: .constant(pendingDelete != nil), titleVisibility: .visible) {
                Button("Löschen", role: .destructive) {
                    if let item = pendingDelete { withAnimation { library.delete(item) } }
                    pendingDelete = nil
                }
                Button("Abbrechen", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("Die NSP-Datei wird dauerhaft entfernt.")
            }
        }
    }
}

enum FilesApp {
    /// Öffnet die Dateien-App direkt im Ordner der Datei.
    @MainActor
    static func reveal(_ url: URL) {
        let folder = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        if let target = URL(string: "shareddocuments://" + folder.path(percentEncoded: true)) {
            UIApplication.shared.open(target)
        }
    }
}

private struct StorageCard: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        GlassCard(cornerRadius: 30, tint: Theme.azure) {
            HStack(spacing: 0) {
                stat(value: "\(library.items.count)", label: "NSPs", symbol: "shippingbox.fill", tint: Theme.azure)
                Divider().frame(height: 44).opacity(0.4)
                stat(value: Format.size(library.totalSize), label: "Belegt", symbol: "internaldrive.fill", tint: Theme.violet)
                Divider().frame(height: 44).opacity(0.4)
                stat(value: Format.size(library.freeSpace), label: "Frei", symbol: "sparkles", tint: Theme.mint)
            }
        }
    }

    private func stat(value: String, label: String, symbol: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(value).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct LibraryRow: View {
    let item: LibraryItem

    var body: some View {
        GlassCard(cornerRadius: 24, padding: 14) {
            HStack(spacing: 14) {
                KindTile(kind: item.metadata.kind, size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.metadata.title).font(.headline).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(Format.size(item.size))
                        Text("·")
                        Text(item.date, format: .relative(presentation: .named))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let id = item.metadata.titleID {
                        Text(id).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .contentShape(.rect(cornerRadius: 24))
    }
}

struct LibraryDetailView: View {
    let item: LibraryItem
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var analysis: NSZAnalysis?
    @State private var loadError: String?
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                GlassCard(cornerRadius: 34, tint: Theme.tint(for: item.metadata.kind), padding: 24) {
                    VStack(spacing: 14) {
                        KindTile(kind: item.metadata.kind, size: 84)
                        Text(item.metadata.title)
                            .font(.title2.weight(.bold))
                            .multilineTextAlignment(.center)
                        HStack(spacing: 6) {
                            InfoChip(text: item.metadata.kind.rawValue, tint: Theme.tint(for: item.metadata.kind))
                            if let id = item.metadata.titleID { InfoChip(text: id, symbol: "number").monospaced() }
                            if let v = item.metadata.versionLabel { InfoChip(text: v, symbol: "tag.fill") }
                        }
                        GlassEffectContainer(spacing: 12) {
                            HStack(spacing: 12) {
                                ShareLink(item: item.url) {
                                    Label("Teilen", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.glassProminent)
                                Button {
                                    FilesApp.reveal(item.url)
                                } label: {
                                    Label("Dateien", systemImage: "folder").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.glass)
                            }
                            .controlSize(.large)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }

                GlassCard(cornerRadius: 26) {
                    VStack(spacing: 10) {
                        row("Dateiname", item.name)
                        row("Größe", Format.size(item.size))
                        row("Erstellt", item.date.formatted(date: .abbreviated, time: .shortened))
                    }
                }

                GlassCard(cornerRadius: 26) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Inhalt").font(.headline)
                        if let analysis {
                            ForEach(analysis.entries) { entry in
                                EntryRow(entry: entry)
                            }
                        } else if let loadError {
                            Text(loadError).font(.footnote).foregroundStyle(Theme.coral)
                        } else {
                            ProgressView().frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .padding(16)
        }
        .background { AppBackground() }
        .navigationTitle(item.metadata.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Umbenennen", systemImage: "pencil") {
                        newName = (item.name as NSString).deletingPathExtension
                        renaming = true
                    }
                    Button("Löschen", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .alert("Umbenennen", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Sichern") {
                if library.rename(item, to: newName) { dismiss() }
            }
            Button("Abbrechen", role: .cancel) {}
        }
        .confirmationDialog("NSP löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                library.delete(item)
                dismiss()
            }
        }
        .task {
            let url = item.url
            let result = await Task.detached { Result { try NSZConverter.analyze(url: url) } }.value
            switch result {
            case let .success(a): analysis = a
            case let .failure(e): loadError = e.localizedDescription
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing).lineLimit(3)
        }
        .font(.subheadline)
    }
}
