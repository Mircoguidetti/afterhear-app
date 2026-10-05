import SwiftUI

/// First launch (docs/BRAIN.md § 19.10): how the tap works on the Mac, one card at a time,
/// with Skip. Again from Settings → "Show me the gestures again".
enum MacGuide {
    static let seenKey = "macGestureGuideSeen"

    @MainActor static func showIfNew() {
        guard !UserDefaults.standard.bool(forKey: seenKey) else { return }
        show()
    }

    @MainActor static func show() {
        AppWindows.show(id: "guide", title: String(localized: "How the tap works"), width: 460, height: 420) {
            MacGuideView { UserDefaults.standard.set(true, forKey: seenKey) }
        }
    }
}

struct MacGuideView: View {
    let done: () -> Void
    @State private var page = 0

    private var pages: [(icon: String, title: String, text: String)] {
        [
            ("keyboard", String(localized: "\(DoubleTapOption.label): mark it. \(DoubleTapOption.nowLabel): help me now."),
             String(localized: "Something slips past you: tap \(DoubleTapOption.label) (or \(HotKey.label)) and carry on, nothing stops; it's waiting for you tonight. Need it now? \(DoubleTapOption.nowLabel) (or \(HotKey.nowLabel)): the video pauses and the sentence you just heard comes up, explained; in a call, one line.")),
            ("chevron.left.forwardslash.chevron.right", String(localized: "‹ ›: not that one?"),
             String(localized: "Wrong sentence? The arrows move to the one before or after. Replay plays the real voice, Slow plays it slower.")),
            ("person.2.wave.2", String(localized: "Before each call: how should I help?"),
             String(localized: "15 minutes before, a notice: how the last call with those people went, and the mode for this one. Just mark (nothing on screen), Suggestions (a hard word now and then) or With me (every help). One tap to change, also from the menu bar.")),
            ("iphone.gen3", String(localized: "Out there: iPhone and Watch"),
             String(localized: "One tap marks, two taps explain it now, hold for two seconds to start or stop listening. Tonight LEXALIE finds what you marked.")),
        ]
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer()
                Button("Skip") { finish() }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Image(systemName: pages[page].icon).font(.system(size: 44)).foregroundStyle(Brand.accent)
            Text(pages[page].title).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
            Text(pages[page].text).multilineTextAlignment(.center).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                ForEach(pages.indices, id: \.self) { i in
                    Circle().fill(i == page ? Brand.signal : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                }
            }
            Button(page == pages.count - 1 ? String(localized: "Got it") : String(localized: "Next")) {
                if page == pages.count - 1 { finish() } else { page += 1 }
            }
            .buttonStyle(.borderedProminent).tint(Brand.accent).foregroundStyle(Brand.onyx)
            .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 460, height: 420)
    }

    private func finish() {
        done()
        NSApp.keyWindow?.close()
    }
}
