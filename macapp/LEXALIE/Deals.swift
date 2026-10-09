import AppKit
import SwiftUI

/// Deals (owner, 09/10: private equity first). A deal is the folder of one acquisition or investment:
/// every call of it (management, experts, customers, bankers, lenders) is read against the others.
/// Nothing is touched during the call. At the end the deal card: every figure exactly as said with its
/// voice, the words that change what it means, what to verify, the questions left unanswered, what was
/// asked of you, and what doesn't match the earlier calls. Not minutes, never advice.
/// Private by design: a deal and its calls live on this Mac only. Not the text, not the voice, goes to
/// the account; the voice of the lines the card points at stays here, the rest of the sound goes at once.
/// To read the call, the text goes to the server and to Gemini with people's names hidden, and is not kept.
@MainActor
final class Deals: ObservableObject {
    static let shared = Deals()

    static let sources = ["management", "expert", "customer", "banker", "lender", "portfolio", "other"]

    static func sourceLabel(_ s: String) -> String {
        switch s {
        case "management": String(localized: "Management")
        case "expert": String(localized: "Expert or former employee")
        case "customer": String(localized: "Customer")
        case "banker": String(localized: "Banker")
        case "lender": String(localized: "Lender")
        case "portfolio": String(localized: "Portfolio company")
        default: String(localized: "Other")
        }
    }

    // MARK: What the server sends back (api/endcard, mode "deal")

    struct Figure: Codable, Hashable {
        var line: Int
        var sentence: String
        var value: String
        var metric: String
        var status: String
        var qualifier: String
        var topic: String
        var unsure: Bool
    }

    struct Trap: Codable, Hashable { var line: Int; var sentence: String; var kind: String; var note: String }
    struct Claim: Codable, Hashable { var line: Int; var sentence: String; var claim: String; var topic: String }
    struct Dodged: Codable, Hashable { var line: Int; var answer_line: Int; var question: String; var how: String }
    struct Request: Codable, Hashable { var line: Int; var sentence: String; var meaning: String }
    struct Mismatch: Codable, Hashable { var line: Int; var sentence: String; var fact_id: String; var kind: String; var note: String }

    struct Card: Codable, Hashable {
        var numbers: [Figure] = []
        var traps: [Trap] = []
        var claims: [Claim] = []
        var dodged: [Dodged] = []
        var asked_you: [Request] = []
        var contradictions: [Mismatch] = []
    }

    // MARK: The deal and its dossier

    /// One fact of the dossier: a figure or a claim, from one call, with its voice when kept.
    struct Fact: Codable, Identifiable, Hashable {
        var id: String
        var session: UUID
        var source: String
        var date: Date
        var topic: String
        var fact: String
        var sentence: String
        var line: Int
    }

    struct Call: Codable, Identifiable, Hashable {
        var id: UUID
        var title: String
        var date: Date
        var source: String
        var card: Card?
        /// Line → the clip's file name, in the session's folder (Sessions.clipFolder).
        var clips: [Int: String] = [:]
        /// The lines as heard, so the card can quote the answer to a question.
        var lines: [Int: String] = [:]
    }

    struct Deal: Codable, Identifiable, Hashable {
        var id = UUID()
        var name: String
        /// A word of the calendar event's title ("Alfa" for "Project Alfa – management"): those calls join by themselves.
        var keyword: String
        var created = Date()
        var calls: [Call] = []
        var facts: [Fact] = []
    }

    @Published private(set) var deals: [Deal] = []
    /// Calls with no keyword match join this deal, when set (the deal you're working on now).
    @Published var active: UUID? = nil {
        didSet { UserDefaults.standard.set(active?.uuidString, forKey: "activeDeal") }
    }
    @Published private(set) var working = false

    private let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LEXALIE/deals.json")

    init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Deal].self, from: data) { deals = saved }
        active = UserDefaults.standard.string(forKey: "activeDeal").flatMap(UUID.init(uuidString:)).flatMap { id in deals.contains { $0.id == id } ? id : nil }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(deals) { try? data.write(to: file, options: .atomic) }
    }

    @discardableResult
    func create(name: String, keyword: String) -> Deal {
        let d = Deal(name: String(name.trimmingCharacters(in: .whitespaces).prefix(80)),
                     keyword: String(keyword.trimmingCharacters(in: .whitespaces).prefix(40)))
        deals.insert(d, at: 0)
        save()
        return d
    }

    /// The deal and every call of it, forgotten here (their sessions and voices too).
    func delete(_ id: UUID) {
        guard let d = deals.first(where: { $0.id == id }) else { return }
        for c in d.calls { Sessions.shared.forget(c.id) }
        deals.removeAll { $0.id == id }
        if active == id { active = nil }
        save()
    }

    /// The deal a call belongs to: its calendar title names the deal's word, or the deal you set as active.
    func deal(forCall title: String, orActive: Bool = true) -> Deal? {
        let t = title.lowercased()
        if let d = deals.first(where: { !$0.keyword.isEmpty && t.contains($0.keyword.lowercased()) }) { return d }
        return orActive ? active.flatMap { id in deals.first { $0.id == id } } : nil
    }

    func setSource(_ source: String, call: UUID, deal: UUID) {
        guard let k = deals.firstIndex(where: { $0.id == deal }), let c = deals[k].calls.firstIndex(where: { $0.id == call }) else { return }
        deals[k].calls[c].source = source
        for f in deals[k].facts.indices where deals[k].facts[f].session == call { deals[k].facts[f].source = source }
        save()
    }

    /// "Not right": the figure or claim leaves the dossier, so later calls aren't read against it.
    func removeFact(_ id: String, deal: UUID) {
        guard let k = deals.firstIndex(where: { $0.id == deal }) else { return }
        deals[k].facts.removeAll { $0.id == id }
        save()
    }

    /// What to clear up before the next call of the deal: questions left unanswered and what doesn't match.
    func openPoints(_ deal: Deal) -> [String] {
        deal.calls.sorted { $0.date > $1.date }.flatMap { c -> [String] in
            guard let card = c.card else { return [] }
            return card.contradictions.map(\.note) + card.dodged.map(\.question)
        }
    }

    // MARK: After the call

    /// The deal call ended: its card from the server, the voice of the lines it points at, the dossier
    /// grows. The window opens by itself, nothing was touched during the call.
    func finish(_ s: Sessions.Session) async {
        guard let id = s.deal, deals.contains(where: { $0.id == id }) else {
            _ = await Sessions.shared.cutDealClips(s, lines: [])
            return
        }
        working = true
        defer { working = false }
        AppModel.syncRedactor()
        var call = Call(id: s.id, title: s.title.isEmpty ? String(localized: "Call") : s.title, date: s.start,
                        source: "management")
        call.lines = Dictionary(uniqueKeysWithValues: s.lines.map { ($0.i, $0.text) })
        let card = await Self.card(for: s, source: call.source, dossier: deals.first { $0.id == id }?.facts ?? [])
        call.card = card
        var wanted = Set<Int>()
        if let card {
            wanted = Set(card.numbers.map(\.line) + card.contradictions.map(\.line) + card.traps.map(\.line))
        }
        call.clips = await Sessions.shared.cutDealClips(s, lines: wanted)
        guard let k = deals.firstIndex(where: { $0.id == id }) else { return }
        deals[k].calls.insert(call, at: 0)
        if let card { deals[k].facts = Array((deals[k].facts + Self.facts(from: card, call: call)).suffix(400)) }
        save()
        Self.open(dealID: id, callID: call.id)
    }

    /// The card for one call, read against the dossier. Nil when the server can't be reached.
    static func card(for s: Sessions.Session, source: String, dossier: [Fact]) async -> Card? {
        let lines: [[String: Any]] = s.lines.suffix(2500).map {
            ["i": $0.i, "who": $0.mine == true ? "you" : "them", "text": String(Redactor.redact($0.text, keepNumbers: true).prefix(1200))] as [String: Any]
        }
        guard !lines.isEmpty else { return nil }
        let day = DateFormatter()
        day.dateFormat = "dd/MM"
        let facts: [[String: Any]] = dossier.suffix(200).map {
            ["id": $0.id, "source": $0.source, "date": day.string(from: $0.date), "topic": $0.topic, "fact": String($0.fact.prefix(300))] as [String: Any]
        }
        return try? await CoachClient.post("api/endcard", ["mode": "deal", "source": source, "lines": lines, "dossier": facts])
    }

    /// The card's figures and claims, as facts of the dossier.
    static func facts(from card: Card, call: Call) -> [Fact] {
        let figures = card.numbers.enumerated().map { k, n in
            Fact(id: "\(call.id.uuidString.prefix(8))-n\(k)", session: call.id, source: call.source, date: call.date, topic: n.topic,
                 fact: "\(n.metric): \(n.value)" + (n.qualifier.isEmpty ? "" : " (\(n.qualifier))") + " [\(n.status)]",
                 sentence: n.sentence, line: n.line)
        }
        let claims = card.claims.enumerated().map { k, c in
            Fact(id: "\(call.id.uuidString.prefix(8))-c\(k)", session: call.id, source: call.source, date: call.date, topic: c.topic,
                 fact: c.claim, sentence: c.sentence, line: c.line)
        }
        return figures + claims
    }

    func clipURL(_ call: Call, line: Int) -> URL? {
        guard let name = call.clips[line] else { return nil }
        let url = Sessions.shared.clipFolder(call.id).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Windows

    static func open(dealID: UUID? = nil, callID: UUID? = nil) {
        AppWindows.show(id: "deals", title: String(localized: "Deals"), width: 760, height: 720) {
            DealsView(selected: dealID, call: callID).environmentObject(Deals.shared)
        }
    }

    // MARK: For the self-test

    func insertForTest(_ deal: Deal) {
        deals.removeAll { $0.id == deal.id }
        deals.insert(deal, at: 0)
    }

    func removeForTest(_ id: UUID) {
        deals.removeAll { $0.id == id }
        if active == id { active = nil }
        save()
    }
}

// MARK: - The window

struct DealsView: View {
    @EnvironmentObject private var deals: Deals
    @State var selected: UUID?
    @State var call: UUID?
    @State private var newName = ""
    @State private var newKeyword = ""
    @State private var question = ""
    @State private var answer: Ask.Found?
    @State private var asking = false
    @State private var confirmDelete = false

    init(selected: UUID? = nil, call: UUID? = nil) {
        _selected = State(initialValue: selected)
        _call = State(initialValue: call)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            list.frame(width: 220)
            Divider()
            ScrollView {
                if let d = deals.deals.first(where: { $0.id == selected }) {
                    dossier(d).padding(24)
                } else {
                    empty.padding(24)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .background(Brand.onyx)
        .foregroundStyle(Brand.paper)
        .frame(minWidth: 680, minHeight: 560)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(deals.deals) { d in
                Button {
                    selected = d.id
                    call = nil
                    answer = nil
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(d.calls.count == 1 ? String(localized: "1 call") : String(localized: "\(d.calls.count) calls"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(selected == d.id ? Brand.card : .clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            Divider()
            TextField("Deal name", text: $newName).textFieldStyle(.roundedBorder)
            TextField("Word in the calendar title", text: $newKeyword).textFieldStyle(.roundedBorder)
            Button("New deal") {
                let d = deals.create(name: newName, keyword: newKeyword)
                selected = d.id
                newName = ""
                newKeyword = ""
            }
            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            Spacer()
        }
        .padding(16)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("A deal is the folder of one acquisition.").font(.system(size: 20, weight: .semibold))
            Text("Its calls are read against each other: every figure as said, what doesn't match, what wasn't answered. They stay on this Mac.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func dossier(_ d: Deal) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text(d.name).font(.system(size: 24, weight: .semibold))
                Toggle("Calls with no calendar word join this deal", isOn: Binding(
                    get: { deals.active == d.id }, set: { deals.active = $0 ? d.id : nil }))
                    .font(.caption)
                if !d.keyword.isEmpty {
                    Text("Calls with “\(d.keyword)” in the calendar title join by themselves.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let c = d.calls.first(where: { $0.id == call }) {
                DealCardView(deal: d, call: c) { call = nil }
            } else {
                let open = deals.openPoints(d)
                if !open.isEmpty {
                    section(String(localized: "To clear up before the next call")) {
                        ForEach(Array(open.prefix(8).enumerated()), id: \.offset) { _, line in Text(line).font(.callout) }
                    }
                }
                askBox(d)
                let topics = Dictionary(grouping: d.facts, by: { $0.topic.lowercased() })
                if !topics.isEmpty {
                    section(String(localized: "What was said, by topic")) {
                        ForEach(topics.keys.sorted(), id: \.self) { key in
                            let facts = topics[key] ?? []
                            VStack(alignment: .leading, spacing: 4) {
                                Text(facts.first?.topic ?? key).font(.system(size: 14, weight: .semibold))
                                ForEach(facts.sorted { $0.date < $1.date }) { f in
                                    HStack(alignment: .firstTextBaseline) {
                                        Text("\(f.date.formatted(.dateTime.day().month())) · \(Deals.sourceLabel(f.source))")
                                            .font(.caption).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
                                        Text(f.fact).font(.callout)
                                        Spacer()
                                        Button("Not right") { deals.removeFact(f.id, deal: d.id) }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                section(String(localized: "Calls")) {
                    if d.calls.isEmpty {
                        Text("No call yet. Name the deal's word in the calendar event, or set this deal for calls with no word.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(d.calls) { c in
                        Button { call = c.id } label: {
                            HStack {
                                Text(c.title).font(.callout).lineLimit(1)
                                Spacer()
                                Text("\(Deals.sourceLabel(c.source)) · \(c.date.formatted(.dateTime.day().month().hour().minute()))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("Delete this deal and its calls", role: .destructive) { confirmDelete = true }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    .confirmationDialog("Delete \(d.name)?", isPresented: $confirmDelete) {
                        Button("Delete", role: .destructive) { deals.delete(d.id); selected = nil }
                    }
            }
        }
    }

    private func askBox(_ d: Deal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Ask about this deal: what did management say about churn?", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { ask(d) }
                Button("Ask") { ask(d) }.disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || asking)
            }
            if asking { ProgressView().controlSize(.small) }
            if let answer {
                Text(answer.answer).font(.callout)
                ForEach(Array(answer.quotes.enumerated()), id: \.offset) { _, q in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("“\(q.sentence)”").font(.callout).italic()
                        Text(q.place).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func ask(_ d: Deal) {
        let q = question
        asking = true
        Task {
            answer = await Ask.shared.askAll(q, deal: d.id)
            asking = false
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 17, weight: .semibold))
            content()
        }
    }
}

/// One call's deal card: the figures first, with their voice.
struct DealCardView: View {
    @EnvironmentObject private var deals: Deals
    let deal: Deals.Deal
    let call: Deals.Call
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Button("All calls") { back() }.buttonStyle(.plain).foregroundStyle(Brand.line)
                Spacer()
                Picker("Who was it", selection: Binding(get: { call.source }, set: { deals.setSource($0, call: call.id, deal: deal.id) })) {
                    ForEach(Deals.sources, id: \.self) { Text(Deals.sourceLabel($0)).tag($0) }
                }
                .frame(width: 260)
            }
            Text(call.title).font(.system(size: 20, weight: .semibold))
            if let card = call.card {
                if card.numbers.isEmpty && card.traps.isEmpty && card.claims.isEmpty && card.dodged.isEmpty && card.asked_you.isEmpty && card.contradictions.isEmpty {
                    Text("Nothing to flag in this call.").foregroundStyle(.secondary)
                }
                block(String(localized: "Doesn't match earlier calls"), card.contradictions) { m in
                    row(m.note, quote: m.sentence, line: m.line)
                }
                block(String(localized: "Figures"), card.numbers) { n in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(n.value).font(.system(size: 15, weight: .semibold))
                            Text(n.metric).font(.callout)
                            if n.status != "fact" { Text(n.status == "forecast" ? String(localized: "forecast") : String(localized: "estimate")).font(.caption).foregroundStyle(.secondary) }
                            if n.unsure { Text("not sure it was heard right").font(.caption).foregroundStyle(.secondary) }
                        }
                        if !n.qualifier.isEmpty { Text(n.qualifier).font(.caption).foregroundStyle(Brand.line) }
                        quote(n.sentence, line: n.line)
                    }
                }
                block(String(localized: "Read it carefully"), card.traps) { t in row(t.note, quote: t.sentence, line: t.line) }
                block(String(localized: "Not answered"), card.dodged) { q in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(q.question).font(.callout.weight(.medium))
                        Text(q.how).font(.callout).foregroundStyle(.secondary)
                        if let reply = call.lines[q.answer_line] { Text("“\(reply)”").font(.caption).italic().foregroundStyle(.secondary) }
                    }
                }
                block(String(localized: "To verify"), card.claims) { c in row(c.claim, quote: c.sentence, line: c.line) }
                block(String(localized: "They asked you"), card.asked_you) { r in row(r.meaning, quote: r.sentence, line: r.line) }
            } else {
                Text("The card couldn't be made: the server wasn't reachable. The call is kept on this Mac.").foregroundStyle(.secondary)
            }
        }
    }

    private func block<T: Hashable, Content: View>(_ title: String, _ items: [T], @ViewBuilder content: @escaping (T) -> Content) -> some View {
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(title).font(.system(size: 17, weight: .semibold))
                    ForEach(items, id: \.self) { content($0) }
                }
            }
        }
    }

    private func row(_ text: String, quote q: String, line: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(text).font(.callout)
            quote(q, line: line)
        }
    }

    private func quote(_ sentence: String, line: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("“\(sentence)”").font(.caption).italic().foregroundStyle(.secondary)
            if let url = deals.clipURL(call, line: line) {
                Button("Replay") { ToldVoice.shared.play(url) }.buttonStyle(.plain).font(.caption).foregroundStyle(Brand.line)
            }
        }
    }
}
