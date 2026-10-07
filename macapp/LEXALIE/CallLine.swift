import SwiftUI

/// In a call, one line near the camera (the map of 07/10): at once the sentence you missed, as this Mac
/// heard it, big; a moment later, in the same place, what it means in one line. Under it three ready
/// questions. Nothing else during the call: the rest is in the card at the end. Never a voice in your
/// ears here, it would cover the people talking.
struct CallLineView: View {
    var sentence: String?
    var note: String? = nil
    var moment: Moment? = nil
    @State private var answer: String?
    @State private var asking = false

    init(sentence: String?, note: String? = nil) {
        self.sentence = sentence
        self.note = note
    }

    init(moment: Moment) {
        self.moment = moment
        self.sentence = moment.transcript
    }

    /// The last words only: a line read in two seconds.
    private var shown: String {
        let words = (sentence ?? "").split(separator: " ")
        guard !words.isEmpty else { return "…" }
        return (words.count > 24 ? "… " : "") + words.suffix(24).joined(separator: " ")
    }

    /// What it means, in one line: who asked you what when the card can say so, else "In practice".
    static func line(_ m: Moment) -> String? {
        if CardShape.of(m) == .forYou, let forYou = AppModel.named(m.forYou, with: m.with) { return forYou }
        if let practice = m.inPractice?.trimmingCharacters(in: .whitespacesAndNewlines), !practice.isEmpty { return practice }
        if let piece = m.pieces.first { return "\(piece.text) · \(piece.gloss ?? piece.meaning)" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Text(shown)
                    .font(.system(size: 18, weight: .semibold))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { AppModel.shared.closeCallLine() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Brand.paper.opacity(0.6))
                .help("Close")
            }
            if let moment {
                if let line = Self.line(moment) {
                    Text(line).font(.system(size: 15)).foregroundStyle(Brand.line)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if asking {
                    ProgressView().controlSize(.small)
                } else if let answer {
                    Text(answer).font(.system(size: 13.5)).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    ForEach(Ask.ready(for: .call, song: false)) { ready in
                        Button {
                            asking = true
                            Task { @MainActor in
                                answer = await Ask.shared.answer(ready, context: .call)
                                asking = false
                            }
                        } label: {
                            Text(ready.label).font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .overlay(Capsule().strokeBorder(Brand.paper.opacity(0.25)))
                        }
                        .buttonStyle(.plain)
                    }
                    Button { Ask.shared.open(context: .call) } label: {
                        Text("Write…").font(.system(size: 12, weight: .medium)).foregroundStyle(Brand.paper.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
            } else if let note {
                Text(note).font(.system(size: 12)).foregroundStyle(Brand.paper.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Explaining…").font(.system(size: 12)).foregroundStyle(Brand.paper.opacity(0.6))
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Brand.onyx))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.paper.opacity(0.08)))
        .foregroundStyle(Brand.paper)
    }
}
