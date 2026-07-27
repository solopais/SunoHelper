import Foundation

/// 一首已生成的歌（历史记录，持久化到 UserDefaults）
struct Song: Codable, Identifiable {
    var id: String
    var title: String
    var audioURL: String?
    var videoURL: String?
    var imageURL: String?
    var lyric: String
    var tags: String
    var prompt: String
    var model: String
    var createdAt: TimeInterval      // 1970 秒
    var downloadedLocalPath: String?
    var pending: Bool = false        // 生成中（音频尚未就绪）

    var createdAtDate: Date { Date(timeIntervalSince1970: createdAt) }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if !prompt.isEmpty { return prompt }
        return "未命名歌曲"
    }

    static func from(clip: SunoClip) -> Song {
        let meta = clip.metadata
        let title = (clip.title?.isEmpty == true ? (meta?.gpt_description_prompt ?? "") : (clip.title ?? meta?.gpt_description_prompt ?? ""))
        return Song(
            id: clip.id,
            title: title,
            audioURL: clip.audio_url,
            videoURL: clip.video_url,
            imageURL: clip.image_url,
            lyric: meta?.prompt ?? "",
            tags: meta?.tags ?? "",
            prompt: meta?.gpt_description_prompt ?? "",
            model: clip.model_name ?? "",
            createdAt: parseSunoDate(clip.created_at) ?? Date().timeIntervalSince1970,
            downloadedLocalPath: nil,
            pending: (clip.status ?? "streaming") != "complete"
        )
    }
}

private func parseSunoDate(_ raw: String?) -> TimeInterval? {
    guard let raw = raw else { return nil }
    if let d = Double(raw) { return d }
    let fmt = ISO8601DateFormatter()
    if let d = fmt.date(from: raw) { return d.timeIntervalSince1970 }
    let f2 = DateFormatter()
    f2.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
    if let d = f2.date(from: raw) { return d.timeIntervalSince1970 }
    return nil
}
