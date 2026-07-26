import Foundation
import Combine

private final class DLDelegate: NSObject, URLSessionDownloadDelegate {
    var onProgress: ((String, Double) -> Void)?
    var onFinish: ((String, URL, URLResponse?) -> Void)?
    var onError: ((String, URLResponse?, Error?) -> Void)?

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let key = downloadTask.originalRequest?.url?.absoluteString ?? ""
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.onProgress?(key, p) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let key = downloadTask.originalRequest?.url?.absoluteString ?? ""
        let tmpSafe = FileManager.default.temporaryDirectory
            .appendingPathComponent("sh_\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: tmpSafe)
            DispatchQueue.main.async { self.onFinish?(key, tmpSafe, downloadTask.response) }
        } catch {
            DispatchQueue.main.async { self.onError?(key, downloadTask.response, error) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return }
        let key = task.originalRequest?.url?.absoluteString ?? ""
        DispatchQueue.main.async { self.onError?(key, task.response, error) }
    }
}

/// 把歌曲音频下载到 App 沙盒 Documents/SunoDownloads，供「分享」使用
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published var status: [String: String] = [:]
    @Published var progress: [String: Double] = [:]
    @Published var isBusy: [String: Bool] = [:]

    private let downloadsDir: URL = {
        let fm = FileManager.default
        return fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SunoDownloads", isDirectory: true)
    }()

    private let delegate = DLDelegate()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    private var activeURLs = Set<String>()
    private var completions: [String: (URL?) -> Void] = [:]

    init() {
        ensureDirectory()
        wireDelegate()
    }

    func isDownloaded(path: String?) -> Bool {
        guard let path = path else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    func isDownloading(_ url: String) -> Bool { activeURLs.contains(url) }

    func download(urlString: String, completion: @escaping (URL?) -> Void) {
        guard !activeURLs.contains(urlString) else { return }
        guard let url = URL(string: urlString) else { completion(nil); return }
        guard ensureDirectory() else { completion(nil); return }

        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 " +
            "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.cachePolicy = .reloadIgnoringLocalCacheData

        activeURLs.insert(urlString)
        completions[urlString] = completion
        status[urlString] = "下载中 0%"
        progress[urlString] = 0
        isBusy[urlString] = true

        session.downloadTask(with: request).resume()
    }

    private func wireDelegate() {
        delegate.onProgress = { [weak self] key, p in
            guard let self = self else { return }
            self.progress[key] = p
            self.status[key] = "下载中 \(Int(p * 100))%"
        }
        delegate.onError = { [weak self] key, response, error in
            guard let self = self else { return }
            self.cleanup(key)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                self.status[key] = "服务器返回 \(http.statusCode)"
            } else if let error = error {
                self.status[key] = "网络错误：\(error.localizedDescription)"
            } else {
                self.status[key] = "下载失败"
            }
            self.completions.removeValue(forKey: key)?(nil)
        }
        delegate.onFinish = { [weak self] key, tmpURL, response in
            guard let self = self else { return }
            self.cleanup(key)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                self.status[key] = "服务器返回 \(http.statusCode)"
                try? FileManager.default.removeItem(at: tmpURL)
                self.completions.removeValue(forKey: key)?(nil)
                return
            }
            let fileExt = (key as NSString).pathExtension.isEmpty ? "mp3" : (key as NSString).pathExtension
            let name = "\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(6)).\(fileExt)"
            let dest = self.downloadsDir.appendingPathComponent(name)
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: tmpURL, to: dest)
                self.status[key] = "已保存"
                self.completions.removeValue(forKey: key)?(dest)
            } catch {
                self.status[key] = "保存失败：\(error.localizedDescription)"
                try? FileManager.default.removeItem(at: tmpURL)
                self.completions.removeValue(forKey: key)?(nil)
            }
        }
    }

    private func cleanup(_ key: String) {
        activeURLs.remove(key)
        progress.removeValue(forKey: key)
        isBusy.removeValue(forKey: key)
    }

    private func ensureDirectory() -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: downloadsDir.path) { return true }
        do {
            try fm.createDirectory(at: downloadsDir, withIntermediateDirectories: true, attributes: nil)
            return true
        } catch {
            print("[DownloadManager] 创建目录失败: \(error)")
            return false
        }
    }

    func clearAllDownloads() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: downloadsDir.path) else { return }
        try? fm.contentsOfDirectory(atPath: downloadsDir.path).forEach {
            try? fm.removeItem(at: downloadsDir.appendingPathComponent($0))
        }
        status.removeAll()
        progress.removeAll()
        isBusy.removeAll()
    }
}
