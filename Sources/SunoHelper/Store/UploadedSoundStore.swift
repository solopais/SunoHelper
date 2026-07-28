import Foundation
import SwiftUI

/// 已上传到 Suno 并注册为可播放 clip 的音频（持久化）。
struct UploadedSound: Identifiable, Codable {
    let id: String          // Suno 上传素材 ID（即 AUDIO 生成时 audio_condition 引用的素材 ID）
    let clipId: String      // Suno 歌曲/clip ID（由 initialize-clip 得到，可用于 feed/v3 取播放地址）
    let name: String        // 原始文件名
    let fileName: String    // 本地保存的文件名（Documents/Uploads/ 下）
    let url: String         // Suno **真实**可播放 CDN 地址（由 initialize-clip + feed/v3 取得）
    let date: Date
}

final class UploadedSoundStore: ObservableObject {
    static let shared = UploadedSoundStore()

    @Published private(set) var items: [UploadedSound] = []

    private let dir: URL
    private let key = "uploadedSounds"

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("Uploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    /// 本地文件路径（用于播放）
    func localURL(for item: UploadedSound) -> URL {
        dir.appendingPathComponent(item.fileName)
    }

    /// 读取本地音频数据（用于播放）
    func localData(for item: UploadedSound) -> Data? {
        try? Data(contentsOf: localURL(for: item))
    }

    /// 保存一次上传：写文件到 Documents/Uploads/ 并追加到列表（按 id 去重）
    func add(id: String, clipId: String, name: String, url: String, data: Data) {
        let ext = (name as NSString).pathExtension.lowercased().isEmpty ? "mp3" : (name as NSString).pathExtension.lowercased()
        let fname = "\(id).\(ext)"
        let fileURL = dir.appendingPathComponent(fname)
        try? data.write(to: fileURL)
        let item = UploadedSound(id: id, clipId: clipId, name: name, fileName: fname, url: url, date: Date())
        DispatchQueue.main.async {
            if !self.items.contains(where: { $0.id == id }) {
                self.items.insert(item, at: 0)
                self.save()
            }
        }
    }

    /// 补全/刷新某条记录的真实播放地址（feed/v3 暂未取到时后续补取）
    func updateURL(id: String, url: String) {
        DispatchQueue.main.async {
            guard let idx = self.items.firstIndex(where: { $0.id == id }) else { return }
            let old = self.items[idx]
            self.items[idx] = UploadedSound(
                id: old.id, clipId: old.clipId, name: old.name,
                fileName: old.fileName, url: url, date: old.date
            )
            self.save()
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let arr = try? JSONDecoder().decode([UploadedSound].self, from: data) else { return }
        items = arr
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
