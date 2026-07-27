import Foundation

/// 全局调试日志（记录网络请求/响应/错误，用户可在「我的」页查看）
/// 目的：让用户截图发给我，就能看到 HTTP 状态码/响应体/请求 URL，不用连 Xcode
final class DebugLog: ObservableObject {
    static let shared = DebugLog()

    struct Entry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let level: Level
        let category: String
        let message: String
    }

    enum Level: String {
        case info = "INFO"
        case warn = "WARN"
        case error = "ERR"
        case success = "OK"
    }

    @Published var entries: [Entry] = []
    private let maxEntries = 300
    private let queue = DispatchQueue(label: "DebugLog.queue")

    func log(_ level: Level, _ category: String, _ message: String) {
        let entry = Entry(timestamp: Date(), level: level, category: category, message: message)
        DispatchQueue.main.async {
            self.entries.insert(entry, at: 0)
            if self.entries.count > self.maxEntries {
                self.entries.removeLast(self.entries.count - self.maxEntries)
            }
        }
    }

    func info(_ category: String, _ message: String) { log(.info, category, message) }
    func warn(_ category: String, _ message: String) { log(.warn, category, message) }
    func error(_ category: String, _ message: String) { log(.error, category, message) }
    func success(_ category: String, _ message: String) { log(.success, category, message) }

    func clear() {
        DispatchQueue.main.async { self.entries.removeAll() }
    }

    /// 导出为纯文本（方便用户复制）
    func exportText() -> String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return entries.map { e in
            "[\(df.string(from: e.timestamp))] \(e.level.rawValue) [\(e.category)] \(e.message)"
        }.joined(separator: "\n")
    }
}
