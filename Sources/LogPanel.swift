import SwiftUI

/// 停靠在设置页底部的运行日志。风格与设置页同一套令牌：
/// 发丝线分隔、无卡片无阴影、马蒂斯字、红色只留给错误。
struct MKLogPanel: View {
    @ObservedObject private var log = LogManager.shared
    @Environment(\.mk) private var mk
    @State private var autoScroll = true
    @State private var expanded: Bool =
        UserDefaults.standard.object(forKey: "LogPanelExpanded") as? Bool ?? true

    private var visibleLines: [LogManager.LogLine] {
        Array(log.lines.suffix(200))
    }

    private func toggleExpanded() {
        expanded.toggle()
        UserDefaults.standard.set(expanded, forKey: "LogPanelExpanded")
    }

    var body: some View {
        VStack(spacing: 0) {
            MKRule()
            header

            if expanded {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            if visibleLines.isEmpty {
                                mkText("暂无日志 · 按住 \(PTTSettings.label) 说句话试试", size: 10, weight: .light)
                                    .foregroundColor(mk.muted)
                                    .padding(.top, 8)
                            }
                            ForEach(visibleLines) { line in
                                row(line).id(line.id)
                            }
                        }
                        .padding(.horizontal, 32)
                        .padding(.top, 8)
                        .padding(.bottom, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onAppear {
                        if let last = visibleLines.last?.id {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                    .onChange(of: log.lines.count) { _ in
                        guard autoScroll, let last = visibleLines.last?.id else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
                .frame(height: 150)
            }
        }
        .background(mk.paper)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Button(action: toggleExpanded) {
                HStack(spacing: 7) {
                    mkText("运行日志", size: 13, weight: .medium)
                        .foregroundColor(mk.ink)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .regular))
                        .foregroundColor(mk.muted)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            if expanded {
                Button {
                    autoScroll.toggle()
                } label: {
                    mkText(autoScroll ? "自动滚动 开" : "自动滚动 关", size: 10, weight: .light)
                        .foregroundColor(autoScroll ? mk.ink : mk.muted)
                }
                .buttonStyle(.plain)

                Button {
                    log.lines.removeAll()
                } label: {
                    mkText("清空", size: 10, weight: .light)
                        .foregroundColor(mk.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 9)
    }

    private func row(_ line: LogManager.LogLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Self.timeFormatter.string(from: line.time))
                .font(.matisse(9.5, .light))
                .foregroundColor(mk.muted.opacity(0.8))
                .frame(width: 50, alignment: .leading)

            mkText(line.text, size: 10, weight: line.level == .err ? .medium : .regular)
                .foregroundColor(color(for: line.level))
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func color(for level: LogManager.Level) -> Color {
        switch level {
        case .err: return mk.accent
        case .data: return mk.muted
        default: return mk.ink
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
