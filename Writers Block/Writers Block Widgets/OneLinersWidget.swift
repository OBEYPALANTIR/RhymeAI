import AppIntents
import SwiftUI
import WidgetKit

struct OneLinersEntry: TimelineEntry {
    let date: Date
    let snapshot: OneLinersSnapshot
}

/// Reads only the snapshot the app writes; the app reloads the timeline when it changes.
struct OneLinersProvider: TimelineProvider {
    /// The gallery and placeholders show lines like the design's, never a real pool.
    static let sample = OneLinersSnapshot(
        count: 41,
        lines: [
            .init(id: "1", text: "Found the Lord in a gas station bathroom", createdAt: .now, hasAudio: true),
            .init(id: "2", text: "Nobody warned me love was a layaway plan", createdAt: .now, hasAudio: false),
            .init(id: "3", text: "Half a heart still beats on time", createdAt: .now, hasAudio: false),
        ],
        appearance: AppAppearanceStyle.ink.rawValue
    )

    func placeholder(in context: Context) -> OneLinersEntry {
        OneLinersEntry(date: .now, snapshot: Self.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (OneLinersEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<OneLinersEntry>) -> Void) {
        completion(Timeline(entries: [current()], policy: .never))
    }

    private func current() -> OneLinersEntry {
        OneLinersEntry(date: .now, snapshot: OneLinersSnapshot.read(from: OneLinersSnapshot.defaultURL) ?? .empty)
    }
}

struct OneLinersWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: OneLinersSnapshot.widgetKind, provider: OneLinersProvider()) { entry in
            OneLinersWidgetView(entry: entry)
        }
        .configurationDisplayName("One Liners")
        .description("Your newest lines, with Record and Type.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct OneLinersWidgetView: View {
    let entry: OneLinersEntry
    @Environment(\.widgetFamily) private var family

    private var appearance: AppAppearanceStyle { .resolve(entry.snapshot.appearance) }
    private var palette: AppAppearancePalette { appearance.palette }
    private static let emptyText = "Catch a line before it slips away."

    var body: some View {
        Group {
            if family == .systemMedium { medium } else { small }
        }
        .foregroundStyle(palette.primaryInk)
        .environment(\.colorScheme, appearance.preferredColorScheme)
        .containerBackground(palette.surface, for: .widget)
        .widgetURL(OneLinerPendingAction.open.url)
    }

    // MARK: - Small

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("ONE LINERS · \(entry.snapshot.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.secondaryInk)
                Spacer(minLength: 8)
                Button(intent: OpenCaptureIntent(mode: .type)) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 34, height: 34)
                        .background(palette.raisedSurface, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Type a one liner")
            }
            Spacer(minLength: 8)
            Text(entry.snapshot.lines.first.map(Self.text(for:)) ?? Self.emptyText)
                .font(.system(size: 13))
                .lineSpacing(2)
                .lineLimit(2)
                .foregroundStyle(palette.secondaryInk)
            Spacer(minLength: 8)
            recordButton(height: 44)
        }
    }

    // MARK: - Medium

    private var medium: some View {
        HStack(spacing: 13) {
            VStack(alignment: .leading, spacing: 0) {
                Text("RECENT ONE LINERS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.secondaryInk)
                Spacer(minLength: 5)
                VStack(alignment: .leading, spacing: 5) {
                    if entry.snapshot.lines.isEmpty {
                        Text(Self.emptyText)
                            .foregroundStyle(palette.secondaryInk)
                    }
                    ForEach(Array(entry.snapshot.lines.enumerated()), id: \.element.id) { index, line in
                        Text(Self.text(for: line))
                            .foregroundStyle(index == 0 ? palette.primaryInk : palette.secondaryInk)
                    }
                }
                .font(.system(size: 13))
                .lineLimit(1)
                Spacer(minLength: 5)
                Text("Open One Liners")
                    .font(.system(size: 12, weight: .semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 8) {
                recordButton(height: 55)
                Button(intent: OpenCaptureIntent(mode: .type)) {
                    pillLabel("Type", systemImage: "keyboard", height: 44)
                        .foregroundStyle(palette.primaryInk)
                        .background(palette.raisedSurface, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Type a one liner")
            }
            .frame(width: 102)
        }
    }

    // MARK: - Parts

    private func recordButton(height: CGFloat) -> some View {
        Button(intent: RecordOneLinerIntent()) {
            pillLabel("Record", systemImage: "mic", height: height)
                .foregroundStyle(palette.onAction)
                .background(palette.action, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Record a one liner")
    }

    private func pillLabel(_ title: String, systemImage: String, height: CGFloat) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }

    /// A line recorded with no words yet still shows up.
    private static func text(for line: OneLinersSnapshot.Line) -> String {
        line.text.isEmpty ? "Recorded line, no words yet" : line.text
    }
}

#Preview(as: .systemSmall) {
    OneLinersWidget()
} timeline: {
    OneLinersEntry(date: .now, snapshot: OneLinersProvider.sample)
}

#Preview(as: .systemMedium) {
    OneLinersWidget()
} timeline: {
    OneLinersEntry(date: .now, snapshot: OneLinersProvider.sample)
}
