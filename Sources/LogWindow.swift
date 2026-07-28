import SwiftUI

struct LogWindow: View {
    @StateObject private var log = LogManager.shared
    @State private var autoScroll = true
    @State private var filterLevel: LogManager.Level? = nil

    var filteredLines: [LogManager.LogLine] {
        if let lv = filterLevel {
            return log.lines.filter { $0.level == lv }
        }
        return Array(log.lines.suffix(200))
    }

    var body: some View {
        VStack(spacing: 0) {
            // toolbar
            HStack {
                Text("实时日志")
                    .font(.headline)
                Spacer()
                Picker("", selection: $filterLevel) {
                    Text("全部").tag(nil as LogManager.Level?)
                    Text("✅ OK").tag(LogManager.Level.ok as LogManager.Level?)
                    Text("❌ Err").tag(LogManager.Level.err as LogManager.Level?)
                    Text("📦 Data").tag(LogManager.Level.data as LogManager.Level?)
                    Text("📋 Info").tag(LogManager.Level.info as LogManager.Level?)
                }
                .pickerStyle(.menu)
                .frame(width: 90)

                Toggle("自动滚动", isOn: $autoScroll)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                Button("清空") {
                    log.lines.removeAll()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            // log list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if filteredLines.isEmpty {
                            Text("暂无日志，按 F20 开始语音输入")
                                .foregroundColor(.secondary)
                                .padding()
                        }
                        ForEach(filteredLines) { line in
                            HStack(spacing: 6) {
                                Text(line.level.rawValue)
                                Text(formattedTime(line.time))
                                    .foregroundColor(.secondary)
                                Text(line.text)
                                    .foregroundColor(colorForLevel(line.level))
                                Spacer()
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .id(line.id)
                        }
                    }
                }
                .onChange(of: log.lines.count) { _ in
                    if autoScroll, let last = filteredLines.last?.id {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
        }
        .frame(width: 520, height: 380)
    }

    private func formattedTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    private func colorForLevel(_ lv: LogManager.Level) -> Color {
        switch lv {
        case .ok: return .green
        case .err: return .red
        case .data: return .blue
        case .info: return .primary
        }
    }
}
