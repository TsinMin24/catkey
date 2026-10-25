import Foundation
import SwiftUI

// MARK: - Global log collector
class LogManager: ObservableObject {
    static let shared = LogManager()
    @Published var lines: [LogLine] = []
    private let maxLines = 500
    private let logFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/MagicKey.log")

    struct LogLine: Identifiable {
        let id = UUID()
        let time: Date
        let text: String
        let level: Level
    }
    enum Level: String {
        case info = "📋"
        case ok = "✅"
        case err = "❌"
        case data = "📦"
    }

    func append(_ text: String, level: Level = .info) {
        let line = LogLine(time: Date(), text: text, level: level)
        DispatchQueue.main.async {
            self.lines.append(line)
            // 日志文件超过 1MB 就重建，避免无限增长
            if let attrs = try? FileManager.default.attributesOfItem(atPath: self.logFileURL.path),
               let size = attrs[.size] as? NSNumber,
               size.intValue > 1_000_000 {
                try? FileManager.default.removeItem(at: self.logFileURL)
            }
            let content = "\(Self.dateFormatter.string(from: line.time)) \(level.rawValue) \(text)\n"
            if let handle = try? FileHandle(forWritingTo: self.logFileURL) {
                handle.seekToEndOfFile()
                handle.write(content.data(using: .utf8) ?? Data())
                try? handle.close()
            } else {
                try? content.data(using: .utf8)?.write(to: self.logFileURL)
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
