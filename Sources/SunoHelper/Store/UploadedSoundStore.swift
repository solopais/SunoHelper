import Foundation
import SwiftUI

/// 已上传到 Suno 的参考音频（持久化）。
/// ⚠️ 重要：Suno 的上传音频是「风格参考素材」，不会出现在歌曲 feed（音乐库）里；
/// 进音乐库的是用它「创作生成」出来的新歌。这里单独存一份，让用户能明确看到自己上传过的歌曲。
struct UploadedSound: Identifiable, Codable {
    let id: String          // Suno 上传 ID（即 audio_condition 引用的素材 ID）
    let name: String        // 原始文件名
    let fileName: String    // 本地保存的文件名（Documents/Uploads/ 下）
    let url: String         // Suno CDN 地址（处理后的音频）
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
    func add(id: String, name: String, url: String, data: Data) {
        let ext = (name as NSString).pathExtension.lowercased().isEmpty ? "mp3" : (name as NSString).pathExtension.lowercased()
        let fname = "\(id).\(ext)"
        let url = dir.appendingPathComponent(fname)
        try? data.write(to: url)
        let item = UploadedSound(id: id, name: name, fileName: fname, url: url, date: Date())
        DispatchQueue.main.async {
            if !self.items.contains(where: { $0.id == id }) {
                self.items.insert(item, at: 0)
                self.save()
            }
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
