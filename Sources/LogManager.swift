import Foundation
import SwiftUI

// MARK: - Global log collector
class LogManager: ObservableObject {
    static let shared = LogManager()
    @Published var lines: [LogLine] = []
    private let maxLines = 500

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
        }
    }
}
