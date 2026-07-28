import SwiftUI

/// 「已上传」标签页：展示用户上传到 Suno 的参考音频。
/// 这些音频本身不会进入歌曲 feed（音乐库），这里单独列出，让用户明确看到自己传过的歌、
/// 可播放本地原文件、并拿到 Suno 上传 ID（即创作时的风格参考引用）。
struct UploadedView: View {
    @StateObject private var store = UploadedSoundStore.shared
    @State private var playMsg: [String: String] = [:]
    @State private var refreshingIDs: Set<String> = []

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    var body: some View {
        AppNav {
            Group {
                if store.items.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "waveform.circle")
                            .font(.system(size: 46))
                            .foregroundColor(AppTheme.textSecondary)
                        Text("还没有上传过音频")
                            .font(.headline)
                            .foregroundColor(AppTheme.textSecondary)
                        Text("在「创作」页选择音频文件即可上传，上传成功后会显示在这里。")
                            .font(.caption)
                            .foregroundColor(AppTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(store.items) { item in
                                uploadedRow(item)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .background(AppTheme.bg)
            .navigationTitle("已上传 (\(store.items.count))")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func uploadedRow(_ item: UploadedSound) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "music.note")
                    .font(.title3)
                    .foregroundColor(AppTheme.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.subheadline).bold()
                        .foregroundColor(AppTheme.text)
                        .lineLimit(2)
                    Text(UploadedView.fmt.string(from: item.date))
                        .font(.caption2)
                        .foregroundColor(AppTheme.textSecondary)
                }
                Spacer(minLength: 0)
            }

            if !item.url.isEmpty {
                Button(action: {
                    AudioPlayer.shared.toggle(url: item.url)
                    playMsg[item.id] = "▶ 正在播放（Suno 已处理版）"
                }) {
                    Label("播放", systemImage: "play.circle")
                        .font(.subheadline)
                }
            } else if refreshingIDs.contains(item.id) {
                ProgressView().tint(AppTheme.accent)
            } else {
                Button(action: { Task { await refreshURL(item) } }) {
                    Label("刷新播放地址", systemImage: "arrow.clockwise")
                        .font(.subheadline)
                }
                .foregroundColor(AppTheme.accent)
            }
            if let msg = playMsg[item.id], !msg.isEmpty {
                Text(msg).font(.caption2).foregroundColor(AppTheme.accent)
            }

            Divider().background(AppTheme.surface2)

            VStack(alignment: .leading, spacing: 4) {
                Text("Suno 上传素材 ID（创作时 audio_condition 引用）")
                    .font(.caption2).foregroundColor(AppTheme.textSecondary)
                Text(item.id)
                    .font(.caption2.monospaced())
                    .foregroundColor(AppTheme.textSecondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Suno 歌曲 ID（clipId，可在音乐库搜到这首上传曲）")
                    .font(.caption2).foregroundColor(AppTheme.textSecondary)
                Text(item.clipId)
                    .font(.caption2.monospaced())
                    .foregroundColor(AppTheme.textSecondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
            }
            Text("提示：用此音频翻唱生成的新歌会进入「音乐库」。")
                .font(.caption2)
                .foregroundColor(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surface2)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    /// 用 clipId 通过 feed/v3 重新取真实播放地址（上传时 feed 暂未就绪导致 url 为空时补救）
    private func refreshURL(_ item: UploadedSound) async {
        refreshingIDs.insert(item.id)
        playMsg[item.id] = nil
        defer { refreshingIDs.remove(item.id) }
        do {
            let url = try await SunoAPI.shared.fetchClipAudioURL(clipId: item.clipId)
            UploadedSoundStore.shared.updateURL(id: item.id, url: url)
            playMsg[item.id] = "✅ 已取到播放地址"
        } catch {
            playMsg[item.id] = "⚠️ 仍未取到：\(error.localizedDescription)"
        }
    }
}
