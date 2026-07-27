import SwiftUI

struct SongCard: View {
    let song: Song
    var onExtend: () -> Void = {}
    var onCover: () -> Void = {}

    @StateObject private var player = AudioPlayer.shared
    @StateObject private var dl = DownloadManager.shared
    @State private var copied = false
    @State private var showLyrics = false

    private var audioKey: String { song.audioURL ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                // 封面
                Group {
                    if let img = song.imageURL, let u = URL(string: img) {
                        AsyncImage(url: u) { img in
                            img.resizable().scaledToFill()
                        } placeholder: {
                            Rectangle().fill(AppTheme.surface2)
                        }
                    } else {
                        Rectangle().fill(AppTheme.surface2)
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 4) {
                    Text(song.displayTitle)
                        .font(.headline).foregroundColor(AppTheme.text)
                        .lineLimit(2)
                    if !song.tags.isEmpty {
                        Text(song.tags)
                            .font(.caption).foregroundColor(AppTheme.textSecondary)
                            .lineLimit(1)
                    }
                    Text(song.pending ? "生成中…" : (song.createdAtDate as NSDate).description(with: Locale.current))
                        .font(.caption2).foregroundColor(song.pending ? AppTheme.accent : AppTheme.textSecondary)
                }

                Spacer()

                // 播放 / 暂停
                Button(action: togglePlay) {
                    Image(systemName: playIcon)
                        .font(.title2)
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(AppTheme.accent)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .disabled(song.audioURL == nil || song.pending)
            }

            if song.pending {
                ProgressView("Suno 生成中…")
                    .progressViewStyle(.linear)
                    .tint(AppTheme.accent)
            } else if player.currentURL == audioKey, player.duration > 0 {
                ProgressView(value: player.progress)
                    .progressViewStyle(.linear)
                    .tint(AppTheme.accent)
            }

            // 操作行
            HStack(spacing: 18) {
                compactAction(icon: dl.isDownloading(audioKey) ? "arrow.down.circle" : (dl.isDownloaded(path: song.downloadedLocalPath) ? "checkmark.circle.fill" : "arrow.down.circle"),
                              label: dlStatusLabel) {
                    download()
                }
                .disabled(song.audioURL == nil || dl.isDownloading(audioKey))

                compactAction(icon: "square.and.arrow.up", label: "分享") {
                    if let u = song.audioURL { ShareSheet.present(items: [u]) }
                }
                .disabled(song.audioURL == nil)

                compactAction(icon: copied ? "checkmark" : "doc.on.doc", label: copied ? "已复制" : "复制") {
                    if let u = song.audioURL {
                        UIPasteboard.general.string = u
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                }
                .disabled(song.audioURL == nil)

                compactAction(icon: "arrow.forward.to.line", label: "续写") {
                    onExtend()
                }
                .disabled(song.audioURL == nil)

                compactAction(icon: "waveform.badge.mic", label: "Cover") {
                    onCover()
                }
                .disabled(song.audioURL == nil)

                if !song.lyric.isEmpty {
                    compactAction(icon: "text.alignleft", label: "歌词") {
                        showLyrics = true
                    }
                }

                Spacer()
            }
        }
        .padding(14)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .sheet(isPresented: $showLyrics) {
            NavigationView {
                ScrollView {
                    Text(song.lyric)
                        .font(.body).foregroundColor(AppTheme.text)
                        .padding(16)
                }
                .navigationTitle("歌词")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("完成") { showLyrics = false }
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private var playIcon: String {
        if song.audioURL == nil || song.pending { return "play.circle" }
        if player.currentURL == audioKey && player.isPlaying { return "pause.circle.fill" }
        return "play.circle.fill"
    }

    private var dlStatusLabel: String {
        if dl.isDownloaded(path: song.downloadedLocalPath) { return "已保存" }
        if dl.isDownloading(audioKey) { return dl.status[audioKey] ?? "下载中" }
        return "下载"
    }

    private func togglePlay() {
        guard let url = song.audioURL, !song.pending else { return }
        player.toggle(url: url)
    }

    private func download() {
        guard let url = song.audioURL else { return }
        dl.download(urlString: url) { local in
            if let local = local {
                SongStore.shared.markDownloaded(id: song.id, path: local.path)
            }
        }
    }

    @ViewBuilder
    private func compactAction(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundColor(AppTheme.text)
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}
