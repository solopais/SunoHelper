import Foundation
import Combine

/// 我的音乐库（历史记录），Codable 持久化到 UserDefaults
final class SongStore: ObservableObject {
    static let shared = SongStore()

    @Published var items: [Song] = []
    private let key = "suno_songs_v1"

    init() { load() }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let arr = try? JSONDecoder().decode([Song].self, from: data) else { return }
        items = arr
    }

    func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func add(_ song: Song) {
        if !items.contains(where: { $0.id == song.id }) {
            items.insert(song, at: 0)
            save()
        }
    }

    func update(_ song: Song) {
        if let idx = items.firstIndex(where: { $0.id == song.id }) {
            items[idx] = song
        } else {
            items.insert(song, at: 0)
        }
        save()
    }

    func markDownloaded(id: String, path: String) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].downloadedLocalPath = path
            save()
        }
    }

    /// 替换本地音乐库（fullReload 用：先清空再写入服务端数据）
    func replaceRemote(_ remote: [Song]) {
        items = remote
        save()
    }

    /// 合并从 Suno 拉回的音乐库（保留本地已下载路径），按创建时间倒序
    func mergeRemote(_ remote: [Song]) {
        for r in remote {
            if let idx = items.firstIndex(where: { $0.id == r.id }) {
                var merged = r
                merged.downloadedLocalPath = items[idx].downloadedLocalPath
                items[idx] = merged
            } else {
                items.append(r)
            }
        }
        items.sort { $0.createdAt > $1.createdAt }
        save()
    }

    /// 增量追加远程歌曲（用于无限滚动分页加载，保留本地下载路径）
    func appendRemote(_ newSongs: [Song]) {
        for r in newSongs {
            if let idx = items.firstIndex(where: { $0.id == r.id }) {
                var merged = r
                merged.downloadedLocalPath = items[idx].downloadedLocalPath
                items[idx] = merged
            } else {
                items.append(r)
            }
        }
        // 去重后保持倒序（最新的在前）
        var seen = Set<String>()
        items = items.filter { s in
            guard !seen.contains(s.id) else { return false }
            seen.insert(s.id); return true
        }
        items.sort { $0.createdAt > $1.createdAt }
        save()
    }

    func remove(_ song: Song) {
        items.removeAll { $0.id == song.id }
        save()
    }

    func clearAll() {
        items.removeAll()
        save()
    }
}
