import AVFoundation
import Combine
import CoreMedia

/// 全局单例音频播放器（后台播放 + 进度）
final class AudioPlayer: ObservableObject {
    static let shared = AudioPlayer()

    private var player: AVPlayer?
    private var timeObserver: Any?

    @Published var isPlaying = false
    @Published var currentURL: String?
    @Published var progress: Double = 0
    @Published var duration: Double = 0
    @Published var isReady = false

    func toggle(url: String) {
        if currentURL == url {
            isPlaying ? pause() : resume()
        } else {
            loadAndPlay(url)
        }
    }

    /// 从内存中的 Data 直接播放（用于上传后试听原始音频，不依赖 CDN URL）
    func playFromData(_ data: Data, fileName: String = "audio.mp3") {
        player?.pause()
        removeObserver()

        // 写入临时文件（AVPlayer 需要 file:// URL）
        let tmpDir = FileManager.default.temporaryDirectory
        let ext = (fileName as NSString).pathExtension.isEmpty ? "mp3" : (fileName as NSString).pathExtension
        let tmpName = "suno_preview_\(Int(Date().timeIntervalSince1970 * 1000)).\(ext)"
        let tmpURL = tmpDir.appendingPathComponent(tmpName)

        do {
            try data.write(to: tmpURL, options: .atomic)
            loadAndPlay(tmpURL.absoluteString)
        } catch {
            // 写入失败时 fallback：尝试用无文件 URL 的方式（不会成功但避免崩溃）
            DebugLog.shared.error("播放", "写入临时文件失败: \(error.localizedDescription)")
        }
    }

    private func loadAndPlay(_ url: String) {
        player?.pause()
        removeObserver()
        guard let u = URL(string: url) else { return }
        let item = AVPlayerItem(url: u)
        player = AVPlayer(playerItem: item)
        currentURL = url
        isReady = false
        player?.play()
        isPlaying = true
        addObserver()
    }

    func pause() { player?.pause(); isPlaying = false }
    func resume() { player?.play(); isPlaying = true }

    func stop() {
        player?.pause()
        removeObserver()
        player = nil
        currentURL = nil
        isPlaying = false
        progress = 0
        duration = 0
        isReady = false
    }

    private func addObserver() {
        guard let player = player else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] t in
            guard let self = self else { return }
            let cur = t.seconds
            let dur = player.currentItem?.duration.seconds ?? 0
            self.duration = dur.isFinite ? dur : 0
            self.isReady = self.duration > 0
            self.progress = (self.duration > 0) ? min(1, max(0, cur / self.duration)) : 0
        }
    }

    private func removeObserver() {
        if let timeObserver = timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }
}
