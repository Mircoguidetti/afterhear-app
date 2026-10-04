import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct UhsideWidgets: WidgetBundle {
    var body: some Widget {
        ListeningLiveActivity()
    }
}

/// Apricot (§ 19.11).
private let accent = Color(red: 0xf2 / 255, green: 0xc4 / 255, blue: 0xa0 / 255)

/// "Afterhear is listening": always visible while it listens, with the Mark button.
struct ListeningLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ListeningAttributes.self) { context in
            HStack(spacing: 12) {
                Circle().fill(.orange).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Afterhear is listening").font(.headline)
                    Text("\(context.attributes.title) · since \(context.attributes.startedAt, style: .time) · \(context.state.marks) marked")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button(intent: MarkFromActivityIntent()) {
                    Text("Mark").font(.headline)
                }
                .tint(accent)
            }
            .padding(16)
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Listening", systemImage: "waveform").foregroundStyle(.orange)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.marks) marked").font(.caption)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Button(intent: MarkFromActivityIntent()) {
                        Text("Mark what I missed").frame(maxWidth: .infinity)
                    }
                    .tint(accent)
                }
            } compactLeading: {
                Image(systemName: "waveform").foregroundStyle(.orange)
            } compactTrailing: {
                Text("\(context.state.marks)").foregroundStyle(accent)
            } minimal: {
                Image(systemName: "waveform").foregroundStyle(.orange)
            }
        }
    }
}
