import SwiftUI

struct SettingsView: View {
    @Environment(LibraryStore.self) private var library
    @AppStorage(SettingsKey.verifyHashes) private var verifyHashes = true
    @AppStorage(SettingsKey.keepAwake) private var keepAwake = true
    @AppStorage(SettingsKey.deleteSource) private var deleteSource = false
    @AppStorage(SettingsKey.autoStart) private var autoStart = false
    @AppStorage(SettingsKey.threads) private var threads = 0
    @AppStorage(SettingsKey.watchFolder) private var watchFolder = true

    private let cores = ProcessInfo.processInfo.activeProcessorCount

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $verifyHashes) {
                        Label {
                            VStack(alignment: .leading) {
                                Text("Integrität prüfen")
                                Text("SHA-256 jeder NCA mit dem Dateinamen abgleichen").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "checkmark.shield.fill").foregroundStyle(Theme.mint) }
                    }
                    Toggle(isOn: $watchFolder) {
                        Label {
                            VStack(alignment: .leading) {
                                Text("App-Ordner überwachen")
                                Text("NSZ in „Auf meinem iPhone › NSPZ“ automatisch übernehmen").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "folder.fill.badge.plus").foregroundStyle(Theme.violet) }
                    }
                    Toggle(isOn: $autoStart) {
                        Label {
                            VStack(alignment: .leading) {
                                Text("Automatisch starten")
                                Text("Direkt nach dem Hinzufügen konvertieren").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "bolt.fill").foregroundStyle(Theme.azure) }
                    }
                    Picker(selection: $threads) {
                        Text("Automatisch (\(cores))").tag(0)
                        ForEach([1, 2, 4, 6, 8].filter { $0 <= max(cores, 2) }, id: \.self) { n in
                            Text("\(n)").tag(n)
                        }
                    } label: {
                        Label("Threads (Block-NCZ)", systemImage: "cpu.fill")
                    }
                } header: {
                    Text("Konvertierung")
                }

                Section {
                    Toggle(isOn: $keepAwake) {
                        Label("Display wach halten", systemImage: "sun.max.fill")
                    }
                    Toggle(isOn: $deleteSource) {
                        Label {
                            VStack(alignment: .leading) {
                                Text("NSZ nach Erfolg löschen")
                                Text("Spart Speicher – die Quelle wird nur nach erfolgreicher Prüfung entfernt").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "trash.fill").foregroundStyle(Theme.coral) }
                    }
                } header: {
                    Text("Verhalten")
                } footer: {
                    Text("Wechselst du während der Umwandlung die App, läuft sie als Hintergrundaufgabe mit Fortschritt in der Dynamic Island / auf dem Sperrbildschirm weiter.")
                }

                Section("Speicher") {
                    LabeledContent("Ort", value: "Auf meinem iPhone › NSPZ")
                    LabeledContent("Bibliothek", value: Format.size(library.totalSize))
                    LabeledContent("Frei", value: Format.size(library.freeSpace))
                    Button {
                        FilesApp.reveal(library.documents)
                    } label: {
                        Label("In Dateien-App öffnen", systemImage: "folder.fill")
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Wie die Umwandlung funktioniert", systemImage: "info.circle.fill")
                            .font(.headline)
                        Text("Eine NSZ ist eine NSP, deren NCA-Dateien mit Zstandard komprimiert wurden (NCZ). NSPZ dekomprimiert jede NCZ – Block-NCZs parallel auf allen CPU-Kernen –, verschlüsselt die Sektionen mit hardwarebeschleunigtem AES-CTR wieder und schreibt eine bitgenaue NSP. Die benötigten Sektionsschlüssel sind bereits in der NSZ enthalten, du brauchst also keine prod.keys oder title.keys.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("Nur für eigene, legal erstellte Sicherungskopien.")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                } header: {
                    Text("Über NSPZ")
                }
            }
            .scrollContentBackground(.hidden)
            .background { AppBackground(animated: false) }
            .navigationTitle("Einstellungen")
            .onAppear { library.refresh() }
        }
    }
}
