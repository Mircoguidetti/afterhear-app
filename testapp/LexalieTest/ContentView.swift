import Combine
import SwiftUI

struct ContentView: View {
    @ObservedObject var engine = Engine.shared
    @State private var tick = Date()
    private let clock = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Microfono", selection: $engine.micMode) {
                        ForEach(MicMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .disabled(engine.listening)
                    Picker("Lingua intorno a te", selection: $engine.language) {
                        ForEach(HeardLanguage.allCases) { Text($0.label).tag($0) }
                    }
                    .disabled(engine.listening)
                    Button(engine.listening ? "Ferma l'ascolto" : "Avvia l'ascolto") {
                        Task {
                            if engine.listening { engine.stop() } else { await engine.start() }
                        }
                    }
                    .font(.headline)
                    Button("Prova: cosa ha detto? (tasto a schermo)") {
                        Task { await engine.trigger(source: "Schermo") }
                    }
                    .disabled(!engine.listening)
                } footer: {
                    Text(engine.status + "\n" + engine.routeName)
                }

                Section("Risultati") {
                    row("Minuti di ascolto", String(format: "%.0f", engine.minutesListening))
                    row("Interruzioni", "\(engine.interruptions)")
                    row("Batteria all'ora", engine.batteryPerHour.map { String(format: "%.1f%%", $0) } ?? "dopo 5 min")
                    row("Gesti AirPods", "\(engine.count(prefix: "AirPods"))")
                    row("Gesti tasto Azione", "\(engine.count(prefix: "Tasto Azione"))")
                    row("Latenza media", engine.averageLatency.map { "\($0) ms" } ?? "—")
                    row("Momenti etichettati", "\(engine.labelled.count) / \(engine.measured.count)")
                    ShareLink("Esporta i risultati", item: engine.report())
                }

                Section("Momenti · ▶ per riascoltare (ad ascolto fermo) · la sera etichetta ognuno") {
                    if engine.events.isEmpty {
                        Text("Ancora niente. Avvia l'ascolto e fai un gesto.").foregroundStyle(.secondary)
                    }
                    ForEach(engine.events) { e in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(e.source).font(.caption.bold())
                                Spacer()
                                if let ms = e.latencyMs { Text("\(ms) ms").font(.caption.monospacedDigit()) }
                                if e.audioFile != nil {
                                    Button { engine.play(e) } label: { Image(systemName: "play.circle") }
                                        .buttonStyle(.borderless)
                                        .disabled(engine.listening)
                                }
                                Text(e.date, style: .time).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(e.text).font(.body)
                            if e.latencyMs != nil {
                                Menu {
                                    ForEach(MomentLabel.allCases) { l in
                                        Button(l.rawValue) { engine.setLabel(l, for: e.id) }
                                    }
                                    if e.label != nil {
                                        Button("Togli etichetta", role: .destructive) { engine.setLabel(nil, for: e.id) }
                                    }
                                } label: {
                                    Label(e.label?.rawValue ?? "Perché ti è sfuggito?", systemImage: e.label == nil ? "tag" : "tag.fill")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
            .navigationTitle("LEXALIE · test")
            .toolbar {
                Menu {
                    Button("Cancella tutti i momenti", role: .destructive) { engine.deleteAll() }
                        .disabled(engine.listening)
                } label: { Image(systemName: "ellipsis.circle") }
            }
            .onReceive(clock) { tick = $0 }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
        .id(tick)
    }
}
