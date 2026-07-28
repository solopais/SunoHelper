import SwiftUI

/// 「已上传」标签页：展示用户上传到 Suno 的参考音频。
/// 这些音频本身不会进入歌曲 feed（音乐库），这里单独列出，让用户明确看到自己传过的歌、
/// 可播放本地原文件、并拿到 Suno 上传 ID（即创作时的风格参考引用）。
struct UploadedView: View {
    @StateObject private var store = UploadedSoundStore.shared
    @State private var playMsg: [String: String] = [:]

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

            Button(action: {
                if let data = store.localData(for: item) {
                    AudioPlayer.shared.playFromData(data, fileName: item.name)
                    playMsg[item.id] = "▶ 正在播放（本地原文件）"
                } else {
                    playMsg[item.id] = "⚠ 本地文件已丢失，请重新上传"
                }
            }) {
                Label("播放", systemImage: "play.circle")
                    .font(.subheadline)
            }
            if let msg = playMsg[item.id], !msg.isEmpty {
                Text(msg).font(.caption2).foregroundColor(AppTheme.accent)
            }

            Divider().background(AppTheme.surface2)

            VStack(alignment: .leading, spacing: 4) {
                Text("Suno 上传 ID（创作时的风格参考引用）")
                    .font(.caption2).foregroundColor(AppTheme.textSecondary)
                Text(item.id)
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
}
