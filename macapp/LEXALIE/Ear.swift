import Foundation
import SwiftUI

/// Your ear (docs/PIANO.md, block I): why something slips past you, measured on this Mac.
/// Nothing here leaves the device: no voice, no voiceprint, no names.

/// Measured at every tap from the missed sentence (I1).
struct Signals: Codable, Hashable {
    /// Syllables per second of the missed sentence, from the recogniser's timings.
    var syllablesPerSecond: Double?
    /// Someone else spoke over it.
    var overlap = false
    /// Voice over background, in dB (the sentence against the quietest moments of the clip).
    var snrDb: Double?
    /// Reduced forms in the sentence ("gonna", "d'you", "kinda"…).
    var reduced: [String] = []
    /// Minutes since the call started, when it was a call.
    var minutesIntoCall: Double?
    /// Hour of the day.
    var hour: Int
    /// The accent you gave the person, never guessed from the voice.
    var accent: String?
}

/// The evening's step test (I3): the first step where you understand is the diagnosis.
enum Diagnosis: String, Codable, CaseIterable {
    /// Understood on a normal replay: you weren't listening at that moment.
    case attention
    /// Understood slowed down: too fast for you.
    case speed
    /// Understood when the missed words play alone: words run together.
    case connected
    /// Understood only written: a word you know on paper, not by ear.
    case spokenForm = "spoken_form"
    /// Not even written: vocabulary, an idiom, a reference, what they meant.
    case meaning

    var label: String {
        switch self {
        case .attention: String(localized: "Attention")
        case .speed: String(localized: "Speed")
        case .connected: String(localized: "Words run together")
        case .spokenForm: String(localized: "Known written, not by ear")
        case .meaning: String(localized: "Meaning")
        }
    }
}

enum EarSignals {
    static func measure(turn: Turn?, samples: [Float], rate: Double, overlap: Bool, language: HeardLanguage,
                        call: Call?, at date: Date, accent: String?) -> Signals {
        var signals = Signals(overlap: overlap, hour: Calendar.current.component(.hour, from: date), accent: accent)
        if let call { signals.minutesIntoCall = max(0, date.timeIntervalSince(call.start) / 60) }
        guard let turn else { return signals }
        let seconds = turn.end - turn.start
        if seconds >= 0.6 {
            signals.syllablesPerSecond = (Double(syllables(turn.text)) / seconds * 10).rounded() / 10
        }
        signals.reduced = reducedForms(turn.text, language: language)
        signals.snrDb = snr(samples: samples, rate: rate, from: turn.start, to: turn.end)
        return signals
    }

    /// Vowel groups: close enough to syllables for a speed, in every language we hear.
    static func syllables(_ text: String) -> Int {
        let vowels = Set("aeiouyàáâãäåèéêëìíîïòóôõöùúûüýæœаеёиоуыэюя")
        var count = 0
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }) {
            var inVowel = false
            var groups = 0
            for c in word {
                let v = vowels.contains(c)
                if v && !inVowel { groups += 1 }
                inVowel = v
            }
            // English silent final e ("make", "time"), but not "the", "be".
            if word.count > 3, word.hasSuffix("e"), !word.hasSuffix("le"), groups > 1 { groups -= 1 }
            count += max(groups, 1)
        }
        return count
    }

    private static let reducedLists: [String: [String]] = [
        "en": ["gonna", "wanna", "gotta", "kinda", "sorta", "dunno", "lemme", "gimme", "y'know", "ya", "d'you", "didja", "whatcha",
               "gotcha", "innit", "ain't", "y'all", "outta", "lotta", "cuppa", "'cause", "cos", "'em", "c'mon", "s'pose", "hafta", "oughta"],
        "it": ["'sto", "'sta", "'na", "'n", "c'ho", "mo'", "po'", "vabbè", "boh"],
        "es": ["pa'", "pa", "na'", "to'", "'ta", "'tá", "q", "pos", "pue"],
        "fr": ["j'sais", "chais", "y'a", "t'as", "t'es", "j'suis", "chuis", "p'tit", "p'tite", "m'sieur", "ouais", "faut"],
        "de": ["hab", "nich", "nix", "is", "'n", "'ne", "gibt's", "geht's", "haste", "willste", "kannste", "weißte", "mal"],
        "pt": ["tá", "tô", "pra", "pro", "cê", "né", "tava", "num"],
        "ru": ["щас", "чё", "чо", "грю", "тыща", "здрасте", "ваще", "токо", "када"],
    ]

    static func reducedForms(_ text: String, language: HeardLanguage) -> [String] {
        guard let list = reducedLists[String(language.rawValue.prefix(2))] else { return [] }
        let words = text.lowercased().replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        return Array(Set(words.filter { list.contains($0) })).sorted()
    }

    /// The sentence's loudness against the quietest tenth of the clip, in 20 ms frames.
    static func snr(samples: [Float], rate: Double, from start: Double, to end: Double) -> Double? {
        let frame = Int(rate * 0.02)
        guard frame > 0, samples.count > frame * 10 else { return nil }
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / frame)
        var i = 0
        while i + frame <= samples.count {
            var sum: Float = 0
            for j in i..<(i + frame) { sum += samples[j] * samples[j] }
            levels.append((sum / Float(frame)).squareRoot())
            i += frame
        }
        let first = max(0, Int(start / 0.02)), last = min(levels.count, Int(end / 0.02))
        guard last - first >= 5 else { return nil }
        let speech = levels[first..<last].sorted()[(last - first) / 2]
        let floor = max(levels.sorted()[levels.count / 10], 1e-5)
        guard speech > 0 else { return nil }
        return (20 * log10(Double(speech / floor))).rounded()
    }
}

/// From the diagnosed moments (I4): always with how many moments it rests on.
struct EarProfile {
    let diagnosed: Int
    let byCause: [(Diagnosis, Int)]
    /// Your speed limit: below most of the sentences that were too fast for you.
    let speedLimit: Double?
    /// Taps in the first five minutes of calls against the rest, per minute.
    let earlyTapsPerMinute: Double?
    let laterTapsPerMinute: Double?

    static let enough = 30

    init(moments: [Moment]) {
        let done = moments.filter { $0.diagnosis != nil && !$0.isModel }
        diagnosed = done.count
        var counts: [Diagnosis: Int] = [:]
        for m in done { counts[m.diagnosis!, default: 0] += 1 }
        byCause = Diagnosis.allCases.compactMap { d in counts[d].map { (d, $0) } }.sorted { $0.1 > $1.1 }
        let fast = done.filter { $0.diagnosis == .speed }.compactMap(\.signals?.syllablesPerSecond).sorted()
        speedLimit = fast.count >= 5 ? fast[fast.count / 4] : nil
        let inCalls = moments.filter { !$0.isModel }.compactMap(\.signals?.minutesIntoCall)
        if inCalls.count >= 10 {
            let early = inCalls.filter { $0 < 5 }.count
            let longest = max(inCalls.max() ?? 5, 6)
            earlyTapsPerMinute = Double(early) / 5
            laterTapsPerMinute = Double(inCalls.count - early) / (longest - 5)
        } else {
            earlyTapsPerMinute = nil
            laterTapsPerMinute = nil
        }
    }

    /// One or two sentences for the model that explains (numbers only, no names).
    var forModel: String {
        guard diagnosed >= 10 else { return "" }
        let top = byCause.prefix(3).map { "\($0.0.rawValue) \($0.1 * 100 / diagnosed)%" }.joined(separator: ", ")
        var text = "Tested by ear on \(diagnosed) moments: \(top)."
        if let speedLimit { text += " Sentences above about \(speedLimit) syllables per second are hard for them." }
        return text
    }
}

/// In the Progress window: your ear, with the number of moments behind it.
struct EarProfileView: View {
    let profile: EarProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your ear").font(.title3.weight(.semibold))
            if profile.diagnosed < EarProfile.enough {
                Text("After \(EarProfile.enough) moments tested in the evening review, here you'll see why things slip past you. So far: \(profile.diagnosed).")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(profile.byCause.enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(row.0.label)
                        Spacer()
                        Text(verbatim: "\(row.1 * 100 / profile.diagnosed)%").monospacedDigit()
                    }
                }
                if let limit = profile.speedLimit {
                    Text("Above about \(String(format: "%.1f", limit)) syllables a second it gets hard.")
                }
                Text("Based on \(profile.diagnosed) moments.").font(.footnote).foregroundStyle(.secondary)
            }
            if let early = profile.earlyTapsPerMinute, let later = profile.laterTapsPerMinute, early > later * 1.5 {
                Text("In the first five minutes of a call you tap more: your ear needs a moment to tune in.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// "Who said it?" after a group call, only on the moments you marked (I2): one tap, never during the call.
struct WhoSaidIt: View {
    let moment: Moment
    @EnvironmentObject private var store: Store

    var body: some View {
        let current = store.moments.first { $0.id == moment.id } ?? moment
        if let guests = current.callGuests, guests.count >= 2, current.with == nil {
            VStack(alignment: .leading, spacing: 6) {
                Text("Who said it?").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(guests, id: \.self) { name in
                        Button(name) { store.setWith(name, for: moment.id) }.controlSize(.small)
                    }
                }
            }
        }
    }
}

/// The step test in the evening review, on three moments a night (I3).
struct EarLadder: View {
    let moment: Moment
    /// The test is over: show the explanation.
    let done: () -> Void
    @EnvironmentObject private var store: Store
    @State private var step = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(prompt).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            if step == 3 {
                Text(moment.transcript).font(.system(size: 20))
            } else {
                Button { replay() } label: { Label("Play", systemImage: "play.fill") }.controlSize(.large)
            }
            HStack {
                Button(step == 3 ? String(localized: "Now I get it") : String(localized: "I got it")) { understood() }
                    .buttonStyle(.borderedProminent).tint(Brand.accent)
                Button(step == 3 ? String(localized: "Not even written") : String(localized: "Not yet")) { next() }
            }
            .controlSize(.large)
        }
        .onAppear { replay() }
    }

    private var prompt: String {
        switch step {
        case 0: String(localized: "Listen again. Do you get it now?")
        case 1: String(localized: "Slower. And now?")
        case 2: String(localized: "Only the part you missed. And now?")
        default: String(localized: "Written down. Do you get it?")
        }
    }

    private func replay() {
        switch step {
        case 0: AppModel.shared.play(moment, slow: false)
        case 1: AppModel.shared.play(moment, slow: true)
        case 2: AppModel.shared.playMissedPart(moment)
        default: break
        }
    }

    private func understood() {
        let found: [Diagnosis] = [.attention, .speed, .connected, .spokenForm]
        store.setDiagnosis(found[min(step, 3)], for: moment.id)
        done()
    }

    private func next() {
        if step >= 3 {
            store.setDiagnosis(.meaning, for: moment.id)
            done()
            return
        }
        step += 1
        replay()
    }

    /// Three a night, on moments that have their sound and their sentence, never tested before.
    static func picks(_ queue: [Moment], store: Store) -> Set<UUID> {
        Set(queue.filter { $0.diagnosis == nil && $0.chosen != nil && $0.turns != nil && store.clipURL($0) != nil && !$0.isModel }
            .prefix(3).map(\.id))
    }
}
