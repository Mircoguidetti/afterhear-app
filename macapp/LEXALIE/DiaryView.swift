import SwiftUI

/// The evening: each moment of the day, why it slipped past, and "I know it / again".
struct DiaryView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: Store
    @State private var confirmDelete = false
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.moments.isEmpty {
                VStack(spacing: 8) {
                    Text("No moments yet").font(.title3.weight(.semibold))
                    Text("Something slips past you: \(DoubleTapOption.label) to mark it, \(DoubleTapOption.nowLabel) for help now.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(days, id: \.self) { day in
                        Section(day.formatted(date: .complete, time: .omitted)) {
                            ForEach(store.moments.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }) { moment in
                                MomentRow(moment: moment)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 520, minHeight: 480)
    }

    private var days: [Date] {
        var seen = Set<Date>()
        return store.moments.map { Calendar.current.startOfDay(for: $0.date) }.filter { seen.insert($0).inserted }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Diary").font(.title2.weight(.semibold))
                let labelled = store.moments.filter { $0.label != nil }.count
                Text("\(store.moments.count) moments · \(labelled) labelled")
                    .font(.callout).foregroundStyle(.secondary)
                if let line = ModelWatch.eveningLine() {
                    Text(line).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(copied ? String(localized: "Copied") : String(localized: "Copy report")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(store.report(), forType: .string)
                copied = true
            }
            Button("Delete everything", role: .destructive) { confirmDelete = true }
                .confirmationDialog("Delete every moment and clip? If you're signed in, they're deleted from your account too.", isPresented: $confirmDelete) {
                    Button("Delete everything", role: .destructive) { store.deleteAll() }
                }
        }
        .padding(16)
    }
}

private struct MomentRow: View {
    @EnvironmentObject private var store: Store
    let moment: Moment
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(moment.date, style: .time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if let with = moment.with {
                    Text("with \(with)").font(.caption).foregroundStyle(.secondary)
                }
                if moment.trigger == "sorry" {
                    Text("✨ you said \"sorry?\"").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if moment.turns != nil {
                    Button("Pick the piece") { AppModel.shared.showChooser(moment.id) }
                }
                if store.clipURL(moment) != nil {
                    Button("▶︎") { AppModel.shared.play(moment, slow: false) }
                    Button("0.7×") { AppModel.shared.play(moment, slow: true) }
                }
            }
            .controlSize(.small)

            Text(moment.transcript).font(.system(size: 15))
            Text("«\(moment.translation)»").font(.callout).foregroundStyle(.secondary)

            ForEach(Array(moment.pieces.enumerated()), id: \.offset) { _, piece in
                VStack(alignment: .leading, spacing: 2) {
                    Text(piece.text).font(.headline)
                    Text(piece.meaning)
                    if !piece.note.isEmpty { Text(piece.note).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Brand.paper).frame(width: 3) }
            }

            HStack {
                if let diagnosis = moment.diagnosis {
                    Text(diagnosis.label).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Again") { store.setReview(.again, for: moment.id) }
                    .tint(moment.review == .again ? .orange : nil)
                Button("I know it") { store.setReview(.known, for: moment.id) }
                    .tint(moment.review == .known ? .green : nil)
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                    .help(String(localized: "Delete this moment"))
                    .confirmationDialog("Delete this moment?", isPresented: $confirmDelete) {
                        Button("Delete", role: .destructive) { store.delete(moment.id) }
                    } message: {
                        Text("The sentence, its clip and its explanation go, from this Mac and from your account.")
                    }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 8)
    }
}
