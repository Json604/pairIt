import SwiftUI
import WidgetKit

struct RelayShortcutEntry: TimelineEntry { let date: Date }
struct RelayShortcutProvider: TimelineProvider {
    func placeholder(in context: Context) -> RelayShortcutEntry { RelayShortcutEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (RelayShortcutEntry) -> Void) { completion(RelayShortcutEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<RelayShortcutEntry>) -> Void) {
        completion(Timeline(entries: [RelayShortcutEntry(date: .now)], policy: .never))
    }
}

struct RelayShortcutView: View {
    @Environment(\.widgetFamily) private var family
    let blue = Color(red: 0.72, green: 0.23, blue: 0.08)
    let ink = Color(red: 0.098, green: 0.098, blue: 0.098)
    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                Image(systemName: "headphones").font(.title2).accessibilityLabel("Open PairIt and listen to computer")
            case .accessoryRectangular:
                HStack(spacing: 8) {
                    Image(systemName: "headphones").font(.title2)
                    VStack(alignment: .leading) { Text("PairIt").font(.headline); Text("Listen to computer").font(.caption) }
                }
            case .systemMedium:
                VStack(alignment: .leading, spacing: 14) {
                    Label("PairIt", systemImage: "headphones").font(.subheadline.weight(.semibold)).foregroundStyle(ink)
                    HStack(spacing: 10) {
                        shortcut("Computer", icon: "desktopcomputer", url: "audiorelay://listen", primary: true)
                        shortcut("iPhone", icon: "iphone", url: "audiorelay://phone", primary: false)
                    }
                }
            default:
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Image(systemName: "headphones").font(.title2).foregroundStyle(blue); Spacer() }
                    Spacer(minLength: 0)
                    Text("PairIt").font(.subheadline.weight(.medium)).foregroundStyle(ink)
                    HStack { Text("Listen to computer").font(.headline); Spacer(minLength: 0); Image(systemName: "arrow.up.right").font(.caption) }.foregroundStyle(blue)
                }
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(colors: [.white, Color(red: 1, green: 0.82, blue: 0.68)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .widgetURL(URL(string: "audiorelay://listen")!)
    }
    private func shortcut(_ title: String, icon: String, url: String, primary: Bool) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 8) { Image(systemName: icon); Text(title).fontWeight(.medium) }
                .font(.subheadline).frame(maxWidth: .infinity).padding(.vertical, 16)
                .foregroundStyle(primary ? .white : ink)
                .background(primary ? ink : .white.opacity(0.8), in: RoundedRectangle(cornerRadius: 14))
        }.accessibilityLabel("Open PairIt for \(title) audio")
    }
}

@main
struct RelayShortcuts: Widget {
    let kind = "AudioRelayShortcuts"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RelayShortcutProvider()) { _ in RelayShortcutView() }
            .configurationDisplayName("PairIt")
            .description("Open the receiver to listen to your computer, or return to iPhone audio.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}
