import SwiftUI

/// The last minutes around a tap, as a chat. Afterhear highlights its guess;
/// you confirm it or tap the piece you really missed.
struct ChooseView: View {
    let momentID: UUID
    @EnvironmentObject private var store: Store
    @State private var working: Int?
    @State private var confirmed = false

    private var moment: Moment? { store.moments.first { $0.id == momentID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let moment, let turns = moment.turns, !turns.isEmpty {
                Text("Tap the piece you didn't catch")
                    .font(.title3.weight(.semibold))
                Text("Highlighted: Afterhear's guess. Them on the left, you on the right.")
                    .font(.callout).foregroundStyle(.secondary)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(Array(turns.enumerated()), id: \.offset) { index, turn in
                                bubble(turn, index: index, moment: moment).id(index)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onAppear { proxy.scrollTo(moment.chosen ?? turns.count - 1, anchor: .center) }
                }
                explanation(moment)
            } else {
                Text("There's no conversation for this moment: it was saved before this version, or without transcription on the Mac.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 560)
    }

    private func bubble(_ turn: Turn, index: Int, moment: Moment) -> some View {
        let isChosen = moment.chosen == index
        return HStack {
            if turn.isMine { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 4) {
                Text(turn.isMine ? "you" : "them").font(.caption2).foregroundStyle(.secondary)
                Text(turn.text).font(.system(size: 14))
                    .foregroundStyle(isChosen ? Brand.onyx : .primary)
                HStack(spacing: 10) {
                    Button { AppModel.shared.play(moment, turn: turn, slow: false) } label: { Image(systemName: "play.fill") }
                    Button { AppModel.shared.play(moment, turn: turn, slow: true) } label: { Image(systemName: "tortoise.fill") }
                    if working == index { ProgressView().controlSize(.small) }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(isChosen ? Brand.onyx.opacity(0.7) : .secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(isChosen ? Brand.accent : Color.secondary.opacity(turn.isMine ? 0.18 : 0.1)))
            .contentShape(Rectangle())
            .onTapGesture {
                guard !turn.isMine, !isChosen, working == nil else { return }
                working = index
                confirmed = false
                Task {
                    await AppModel.shared.choose(turn: index, in: momentID)
                    working = nil
                }
            }
            if !turn.isMine { Spacer(minLength: 60) }
        }
    }

    /// Not in the list? Maybe something you knew before, heard again in these minutes.
    @ViewBuilder private func knownBefore(_ moment: Moment) -> some View {
        let heard = (moment.turns ?? []).filter { !$0.isMine }.map(\.text).joined(separator: " ")
        let found = Array(Memory.shared.knownBefore(in: heard).prefix(4))
        if !found.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Not in the list? Maybe one you knew before:").font(.caption).foregroundStyle(.secondary)
                HStack {
                    ForEach(found, id: \.key) { item in
                        Button(item.text) { AppModel.shared.relapse(item, in: momentID) }
                            .help(item.gloss ?? item.meaning ?? "")
                    }
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder private func explanation(_ moment: Moment) -> some View {
        knownBefore(moment)
        Divider()
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(moment.pieces.enumerated()), id: \.offset) { _, piece in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(piece.text).font(.headline)
                    Text("→ \(piece.gloss ?? piece.meaning)")
                }
            }
            if moment.pieces.isEmpty {
                Text("No hard words in this piece.").foregroundStyle(.secondary)
            }
            Text("«\(moment.translation)»").font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(confirmed || moment.delay != nil ? String(localized: "Thanks, Afterhear is learning your timing") : String(localized: "Yes, that's the one")) {
                    AppModel.shared.confirm(momentID)
                    confirmed = true
                }
                .disabled(confirmed || moment.delay != nil)
            }
        }
    }
}
