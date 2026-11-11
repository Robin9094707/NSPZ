import SwiftUI
import NSZKit

struct JobCard: View {
    let job: ConversionJob
    @Environment(ConversionQueue.self) private var queue
    @State private var showDetails = false

    var body: some View {
        GlassCard(cornerRadius: 30, tint: tint) {
            VStack(alignment: .leading, spacing: 14) {
                header
                sizes
                stateView
            }
        }
        .contextMenu {
            if job.state == .converting {
                Button("Abbrechen", systemImage: "stop.fill", role: .destructive) { queue.cancel(job) }
            } else {
                Button("Entfernen", systemImage: "trash", role: .destructive) { withAnimation { queue.remove(job) } }
            }
        }
        .sheet(isPresented: $showDetails) {
            JobDetailSheet(job: job)
                .presentationDetents([.medium, .large])
        }
    }

    private var tint: Color? {
        switch job.state {
        case .done: Theme.mint
        case .failed: Theme.coral
        case .converting: Theme.azure
        default: nil
        }
    }

    // MARK: Kopf

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            KindTile(kind: job.metadata.kind)
            VStack(alignment: .leading, spacing: 6) {
                Text(job.metadata.title)
                    .font(.headline)
                    .lineLimit(2)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        InfoChip(text: job.metadata.kind.rawValue, tint: Theme.tint(for: job.metadata.kind))
                        if let id = job.metadata.titleID {
                            InfoChip(text: id, symbol: "number").monospaced()
                        }
                        if let version = job.metadata.versionLabel {
                            InfoChip(text: version, symbol: "tag.fill")
                        }
                    }
                }
                .scrollClipDisabled()
            }
            Spacer(minLength: 0)
            Button {
                showDetails = true
            } label: {
                Image(systemName: "info").font(.subheadline.weight(.bold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .disabled(job.analysis == nil)
        }
    }

    @ViewBuilder
    private var sizes: some View {
        if let analysis = job.analysis {
            HStack(spacing: 8) {
                Label(Format.size(analysis.inputSize), systemImage: "archivebox")
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                Label(Format.size(analysis.outputSize), systemImage: "shippingbox")
                Spacer()
                Text("\(analysis.entries.count) Dateien")
                    .foregroundStyle(.secondary)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
    }

    // MARK: Zustand

    @ViewBuilder
    private var stateView: some View {
        switch job.state {
        case .analyzing:
            HStack(spacing: 10) {
                ProgressView()
                Text("Analysiere Header …").font(.subheadline).foregroundStyle(.secondary)
            }

        case .ready:
            HStack(spacing: 10) {
                Button {
                    withAnimation(.bouncy) { queue.start(job) }
                } label: {
                    Label("Konvertieren", systemImage: "bolt.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                removeButton
            }

        case .queued:
            HStack(spacing: 10) {
                Image(systemName: "clock.fill").foregroundStyle(Theme.violet)
                    .symbolEffect(.pulse)
                Text("Wartet auf freien Slot …").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button("Zurückstellen") { withAnimation { queue.cancel(job) } }
                    .buttonStyle(.glass)
            }

        case .converting:
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Int(job.fraction * 100)) %")
                        .font(.system(.title, design: .rounded, weight: .heavy))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: job.fraction))
                        .animation(.snappy, value: Int(job.fraction * 100))
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Format.speed(job.bytesPerSecond))
                            .font(.subheadline.weight(.semibold)).monospacedDigit()
                        if let remaining = job.remainingTime {
                            Text("noch \(Format.duration(remaining))")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                GlowProgressBar(value: job.fraction)
                HStack {
                    Text(job.currentFile)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(role: .destructive) {
                        queue.cancel(job)
                    } label: {
                        Label("Abbrechen", systemImage: "stop.fill").font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.glass)
                    .tint(Theme.coral)
                }
            }

        case .done:
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title2)
                        .foregroundStyle(Theme.mint)
                        .symbolEffect(.bounce, value: job.state == .done)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fertig in \(Format.duration(job.elapsed ?? 0))").font(.subheadline.weight(.semibold))
                        if let report = job.report {
                            Text(report.verifiedCount > 0
                                 ? "\(report.verifiedCount) NCA per SHA-256 verifiziert · Ø \(Format.speed(Double(report.outputSize) / max(report.duration, 0.001)))"
                                 : "Ø \(Format.speed(Double(report.outputSize) / max(report.duration, 0.001)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(spacing: 10) {
                    if let url = job.outputURL {
                        ShareLink(item: url) {
                            Label("Teilen", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                    }
                    removeButton
                }
            }

        case let .failed(message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Theme.coral)
                HStack(spacing: 10) {
                    Button {
                        withAnimation(.bouncy) { queue.start(job) }
                    } label: {
                        Label("Erneut versuchen", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    removeButton
                }
            }

        case .cancelled:
            HStack(spacing: 10) {
                Label("Abgebrochen", systemImage: "stop.circle").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button("Neu starten", systemImage: "arrow.clockwise") { withAnimation(.bouncy) { queue.start(job) } }
                    .buttonStyle(.glass)
                removeButton
            }
        }
    }

    private var removeButton: some View {
        Button {
            withAnimation(.smooth) { queue.remove(job) }
        } label: {
            Image(systemName: "xmark").font(.subheadline.weight(.bold)).frame(width: 22, height: 22)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .accessibilityLabel("Entfernen")
    }
}

// MARK: - Detailblatt

struct JobDetailSheet: View {
    let job: ConversionJob

    var body: some View {
        NavigationStack {
            List {
                Section("Quelle") {
                    LabeledContent("Datei", value: job.fileName)
                    if let id = job.metadata.titleID { LabeledContent("Title-ID", value: id).monospaced() }
                    if let v = job.metadata.versionLabel { LabeledContent("Version", value: v) }
                    if let a = job.analysis {
                        LabeledContent("NSZ-Größe", value: Format.size(a.inputSize))
                        LabeledContent("NSP-Größe", value: Format.size(a.outputSize))
                        LabeledContent("Ersparnis", value: "\(Int((1 - Double(a.inputSize) / Double(max(a.outputSize, 1))) * 100)) %")
                    }
                }
                if let analysis = job.analysis {
                    Section("Inhalt (\(analysis.entries.count))") {
                        ForEach(analysis.entries) { entry in
                            EntryRow(entry: entry, verified: job.report?.files.contains {
                                $0.name == entry.outputName && $0.status == .verified
                            } ?? false)
                        }
                    }
                }
            }
            .navigationTitle(job.metadata.title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct EntryRow: View {
    let entry: NSZEntryInfo
    var verified = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(entry.kind == .plain ? Color.secondary : Theme.violet)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.outputName).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if verified {
                Image(systemName: "checkmark.shield.fill").foregroundStyle(Theme.mint)
            }
        }
    }

    private var symbol: String {
        switch entry.kind {
        case .nczSolid: "cube.fill"
        case .nczBlock: "square.grid.3x3.fill"
        case .plain: "doc.fill"
        }
    }

    private var detail: String {
        switch entry.kind {
        case .nczSolid: "NCZ (solid) · \(Format.size(entry.inputSize)) → \(Format.size(entry.outputSize))"
        case .nczBlock: "NCZ (Block, parallel) · \(Format.size(entry.inputSize)) → \(Format.size(entry.outputSize))"
        case .plain: Format.size(entry.outputSize)
        }
    }
}
