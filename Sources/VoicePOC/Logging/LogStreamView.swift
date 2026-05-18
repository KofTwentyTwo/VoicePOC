import SwiftUI

/// SwiftUI viewer for the LogStream ring buffer. Polls every 100 ms and only
/// re-renders when LogStream's version bumps. Pattern matches VisionPOC's
/// LogStreamView so the UX is consistent across sibling POCs.
public struct LogStreamView: View {
    @State private var entries: [LogStream.Entry] = []
    @State private var lastVersion: UInt64 = 0
    @State private var levelFilter: Set<LogStream.Level> = Set(LogStream.Level.allCases)
    @State private var sourceFilter: Set<LogStream.Source> = Set(LogStream.Source.allCases)
    @State private var autoScroll: Bool = true
    @State private var paused: Bool = false

    private let pollTimer = Timer.publish(every: 0.10, on: .main, in: .common).autoconnect()

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            logList
        }
        .frame(minWidth: 720, idealWidth: 960, minHeight: 360, idealHeight: 600)
        .background(Color(white: 0.07))
        .onReceive(pollTimer) { _ in
            guard !paused else { return }
            let v = LogStream.shared.version
            guard v != lastVersion else { return }
            entries = LogStream.shared.snapshot()
            lastVersion = v
        }
    }

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 12) {
            Menu("Level") {
                ForEach(LogStream.Level.allCases) { lvl in
                    Toggle(lvl.rawValue, isOn: Binding(
                        get: { levelFilter.contains(lvl) },
                        set: { isOn in
                            if isOn { levelFilter.insert(lvl) } else { levelFilter.remove(lvl) }
                        }
                    ))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Menu("Source") {
                ForEach(LogStream.Source.allCases) { src in
                    Toggle(src.rawValue, isOn: Binding(
                        get: { sourceFilter.contains(src) },
                        set: { isOn in
                            if isOn { sourceFilter.insert(src) } else { sourceFilter.remove(src) }
                        }
                    ))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Toggle("Auto-scroll", isOn: $autoScroll)
                .toggleStyle(.checkbox)
                .controlSize(.small)

            Toggle("Pause", isOn: $paused)
                .toggleStyle(.checkbox)
                .controlSize(.small)

            Spacer()

            Text("\(filteredEntries.count) / \(entries.count)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            Button("Clear") { LogStream.shared.clear() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(white: 0.10))
    }

    private var filteredEntries: [LogStream.Entry] {
        entries.filter { levelFilter.contains($0.level) && sourceFilter.contains($0.source) }
    }

    @ViewBuilder
    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredEntries) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(Self.timeFormatter.string(from: entry.timestamp))
                                .foregroundStyle(.secondary)
                            Text(entry.level.rawValue)
                                .foregroundStyle(color(for: entry.level))
                                .frame(width: 32, alignment: .leading)
                            Text(entry.source.rawValue)
                                .foregroundStyle(Color(red: 0.20, green: 0.85, blue: 0.95))
                                .frame(width: 60, alignment: .leading)
                            Text(entry.message)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 2)
                        .id(entry.id)
                    }
                }
            }
            .onChange(of: filteredEntries.last?.id) { _, newValue in
                guard autoScroll, let last = newValue else { return }
                withAnimation(.linear(duration: 0.06)) {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    private func color(for level: LogStream.Level) -> Color {
        switch level {
        case .debug: return .gray
        case .info:  return Color(white: 0.85)
        case .warn:  return .yellow
        case .error: return .red
        }
    }
}
