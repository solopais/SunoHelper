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

    func remove(_ song: Song) {
        items.removeAll { $0.id == song.id }
        save()
    }

    func clearAll() {
        items.removeAll()
        save()
    }
}
