import AppKit
import SwiftUI

/// Pictures of the real cards, drawn by the app itself on GitHub's Mac after every build, in the Mac's
/// light and dark look (owner, 07/10: he's at a fair and wants to see them without his Mac). Example
/// content, no call to our server. They go up with the test release; a picture that can't be drawn
/// never stops the release.
@MainActor
enum SelfTestShots {
    static func cards() -> [(String, Moment)] {
        func moment(_ sentence: String, _ piece: Piece, context: String = "video", trigger: String = "tap") -> Moment {
            var m = Moment(date: Date(), transcript: sentence, sent: sentence, translation: "", pieces: [piece],
                           clipFile: nil, provider: "selftest", latencyMs: 900)
            m.trigger = trigger
            m.context = context
            return m
        }
        var heard = moment("We've got nine months of runway at this burn rate.",
                           Piece(text: "nine months of runway", heardAs: nil, gloss: nil, meaning: "said fast, the words run together",
                                 note: "", cause: "connected_speech", level: "B2"), context: "call")
        heard.pieces.append(Piece(text: "runway", heardAs: nil, gloss: "autonomia", meaning: "quanti mesi un'azienda può andare avanti con i soldi che ha",
                                  note: "", cause: "unknown_word", level: "C1"))
        heard.soundsLike = "nine-munsa-runway"
        heard.inPractice = "se spendiamo così, finiamo i soldi in nove mesi."
        var idiom = moment("He's basically moving the goalposts.",
                           Piece(text: "moving the goalposts", heardAs: nil, gloss: "spostare i pali", meaning: "cambiare le regole quando stai per perdere",
                                 note: "", cause: "idiom", level: "C1"))
        idiom.equivalent = "cambiare le carte in tavola"
        idiom.translation = "Sta praticamente spostando i pali della porta."
        idiom.inPractice = "lo accusa di cambiare criterio pur di non ammettere di avere torto."
        var forYou = moment("Marco, could you give us a ballpark figure for March by Friday?",
                            Piece(text: "ballpark figure", heardAs: nil, gloss: "cifra indicativa", meaning: "un numero a occhio, non quello esatto",
                                  note: "", cause: "idiom", level: "B2"), context: "call")
        forYou.forYou = "[nome] ti chiede una stima dei numeri di marzo, entro venerdì."
        forYou.with = "Sarah"
        var who = moment("That was peak Pets.com territory.",
                         Piece(text: "Pets.com", heardAs: nil, gloss: nil, meaning: "negozio online di cibo per animali, 1998–2000, fallito poco dopo la quotazione",
                               note: "", cause: "cultural", level: "C1"), trigger: "airpods")
        who.inPractice = "è il simbolo della bolla delle dot-com."
        var tone = moment("Well, that's quite brave.",
                          Piece(text: "quite brave", heardAs: nil, gloss: nil, meaning: "\"quite\" abbassa, non alza",
                                note: "", cause: "subtext", level: "B2"))
        tone.toneLabel = "ironico"
        tone.inPractice = "non è un complimento: vuol dire \"è una pessima idea\". La risata viene da lì."
        var plain = moment("Honestly, it's the Overton window all over again.",
                           Piece(text: "the Overton window", heardAs: nil, gloss: "finestra di Overton", meaning: "le idee che in un certo momento sembrano accettabili nel dibattito pubblico",
                                 note: "", cause: "speed_accent", level: "C1"))
        plain.translation = "Onestamente, è di nuovo la finestra di Overton."
        plain.inPractice = "dice che un'idea assurda sta diventando normale."
        return [("1-non-hai-sentito", heard), ("2-modo-di-dire", idiom), ("3-era-per-te", forYou),
                ("4-chi-e", who), ("5-tono", tone), ("6-normale", plain)]
    }

    static func run() async {
        guard let dir = ProcessInfo.processInfo.environment["SELFTEST_SHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, moment) in cards() {
            for (look, appearance) in [("giorno", NSAppearance.Name.aqua), ("notte", .darkAqua)] {
                let ok = await snapshot(AnyView(PanelView(phase: .result(moment))), width: 420, appearance: appearance, to: "\(dir)/\(name)-\(look).png")
                print((ok ? "SHOT " : "NO SHOT ") + "\(name)-\(look)")
            }
        }
        let end = EndCard(title: "Dopo la call con Sarah, Raj e Tom", items: [
            .init(kind: .open, label: String(localized: "Still open for you"), quote: "Marco, what's your take on the October budget?", detail: nil, moment: nil),
            .init(kind: .laughed, label: String(localized: "Why they laughed"), quote: "That's what she said.",
                  detail: "La battuta fissa di Michael Scott in The Office.\nHai visto The Office giovedì.", moment: nil),
        ])
        for (look, appearance) in [("giorno", NSAppearance.Name.aqua), ("notte", .darkAqua)] {
            let ok = await snapshot(AnyView(EndCardView(card: end)), width: 420, appearance: appearance, to: "\(dir)/7-fine-call-\(look).png")
            print((ok ? "SHOT " : "NO SHOT ") + "7-fine-call-\(look)")
        }
        // 07/10: the line near the camera in a call, the question window, the card while the ear plays,
        // and the evening's "now you get it".
        let all = cards()
        var call = all[2].1
        call.inPractice = "vuole una stima dei numeri di marzo, entro venerdì."
        let extra: [(String, AnyView, CGFloat)] = [
            ("8-call-riga", AnyView(CallLineView(moment: call)), 520),
            ("9-chiedi", AnyView(AskView(context: .video, song: false)), 460),
            ("10-orecchio", AnyView(PanelView(phase: .video(all[1].1, paused: true))), 420),
            ("11-ormai-la-capisci", AnyView(GotItLine(got: Memory.SmoothEncounter(at: Date(), text: "moving the goalposts"))), 420),
        ]
        for (name, view, width) in extra {
            for (look, appearance) in [("giorno", NSAppearance.Name.aqua), ("notte", .darkAqua)] {
                let ok = await snapshot(view, width: width, appearance: appearance, to: "\(dir)/\(name)-\(look).png")
                print((ok ? "SHOT " : "NO SHOT ") + "\(name)-\(look)")
            }
        }
    }

    /// The view in an off-screen window with the Mac's light or dark look, drawn to a PNG.
    private static func snapshot(_ view: AnyView, width: CGFloat, appearance: NSAppearance.Name, to path: String) async -> Bool {
        let ground = appearance == .darkAqua ? Color(white: 0.11) : Color(white: 0.87)
        let host = NSHostingView(rootView: view.frame(width: width).padding(24).background(ground))
        host.appearance = NSAppearance(named: appearance)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: width + 48, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 600_000_000)
        let size = host.fittingSize
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 300_000_000)
        defer { window.orderOut(nil) }
        guard size.width > 10, size.height > 10, let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}
