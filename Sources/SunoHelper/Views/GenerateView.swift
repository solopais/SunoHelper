import SwiftUI

private enum GenMode: String, CaseIterable {
    case simple = "简单"
    case custom = "自定义"
}

private let MODELS = ["chirp-v3-5", "chirp-v4", "chirp-v4-5", "chirp-v4-5-turbo", "chirp-v4-5-8s"]

struct GenerateView: View {
    @StateObject private var session = SunoSession.shared
    @StateObject private var store = SongStore.shared

    @State private var mode: GenMode = .simple
    @State private var prompt = ""
    @State private var tags = ""
    @State private var title = ""
    @State private var instrumental = false
    @State private var model = "chirp-v3-5"
    @State private var busy = false
    @State private var message = ""

    // 续写模式（从音乐库点「续写」进入）
    private let extendClipID: String?
    @State private var extendNote = ""

    init(extendClipID: String? = nil) {
        self.extendClipID = extendClipID
        _mode = State(initialValue: extendClipID != nil ? .simple : .simple)
    }

    var body: some View {
        AppNav {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let ext = extendClipID {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("续写模式", systemImage: "arrow.forward.to.line")
                                .font(.headline).foregroundColor(AppTheme.accent)
                            Text("基于已选片段继续生成（clip id: \(ext.prefix(8))…）")
                                .font(.caption).foregroundColor(AppTheme.textSecondary)
                        }
                        .padding(.horizontal, 16)
                    } else {
                        Picker("模式", selection: $mode) {
                            ForEach(GenMode.allCases, id: \.self) { m in
                                Text(m.rawValue).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16)
                    }

                    // 主要输入框
                    VStack(alignment: .leading, spacing: 8) {
                        if extendClipID != nil {
                            Text("续写描述（可选）")
                                .font(.subheadline).foregroundColor(AppTheme.textSecondary)
                            TextEditor(text: $extendNote)
                                .frame(minHeight: 90)
                                .padding(8)
                                .background(AppTheme.surface)
                                .foregroundColor(AppTheme.text)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        } else if mode == .simple {
                            Text("描述你想听的歌")
                                .font(.subheadline).foregroundColor(AppTheme.textSecondary)
                            TextEditor(text: $prompt)
                                .frame(minHeight: 110)
                                .padding(8)
                                .background(AppTheme.surface)
                                .foregroundColor(AppTheme.text)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            Text("例：一首欢快的夏日流行歌，关于海边旅行")
                                .font(.caption2).foregroundColor(AppTheme.textSecondary)
                        } else {
                            Text("歌词")
                                .font(.subheadline).foregroundColor(AppTheme.textSecondary)
                            TextEditor(text: $prompt)
                                .frame(minHeight: 130)
                                .padding(8)
                                .background(AppTheme.surface)
                                .foregroundColor(AppTheme.text)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            TextField("风格标签（如 pop, upbeat, 中文）", text: $tags)
                                .padding(10)
                                .background(AppTheme.surface)
                                .foregroundColor(AppTheme.text)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            TextField("歌名（可选）", text: $title)
                                .padding(10)
                                .background(AppTheme.surface)
                                .foregroundColor(AppTheme.text)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .padding(.horizontal, 16)

                    // 纯音乐 & 模型
                    Toggle("纯音乐（无人声）", isOn: $instrumental)
                        .foregroundColor(AppTheme.text)
                        .padding(.horizontal, 16)

                    HStack {
                        Text("模型").foregroundColor(AppTheme.textSecondary).font(.subheadline)
                        Spacer()
                        Picker("模型", selection: $model) {
                            ForEach(MODELS, id: \.self) { m in
                                Text(m).tag(m)
                            }
                        }
                        .pickerStyle(.menu)
                        .accentColor(AppTheme.accent)
                    }
                    .padding(.horizontal, 16)

                    if !message.isEmpty {
                        Text(message)
                            .font(.footnote)
                            .foregroundColor(message.contains("失败") || message.contains("过期") ? AppTheme.error : AppTheme.textSecondary)
                            .padding(.horizontal, 16)
                    }

                    Button(action: runGenerate) {
                        HStack {
                            if busy { ProgressView().tint(.white) }
                            Text(busy ? "生成中…" : "生成歌曲")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(busy ? AppTheme.surface2 : AppTheme.gradient())
                        .foregroundColor(.white)
                        .font(.headline)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(busy || (extendClipID == nil && prompt.trimmingCharacters(in: .whitespaces).isEmpty))
                    .padding(.horizontal, 16)

                    Spacer(minLength: 20)
                }
                .padding(.top, 12)
            }
            .hideScrollContentBackground()
            .background(AppTheme.bg)
            .navigationTitle(extendClipID != nil ? "续写歌曲" : "创作")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    func runGenerate() {
        guard session.isLoggedIn else {
            message = "请先登录 Suno 账户"
            return
        }
        busy = true
        message = "提交生成任务…"

        let payload: GeneratePayload
        if let ext = extendClipID {
            payload = .extend(clipId: ext, at: 0, model: model, note: extendNote)
        } else if mode == .simple {
            payload = .simple(prompt: prompt, model: model, instrumental: instrumental)
        } else {
            payload = .custom(lyrics: prompt, tags: tags, title: title, model: model, instrumental: instrumental)
        }

        Task {
            do {
                let stubs = try await SunoAPI.shared.generate(payload: payload)
                let ids = stubs.map { $0.id }
                await MainActor.run { message = "已提交，Suno 生成中（\(ids.count) 首）…" }

                var finished = false
                var rounds = 0
                while !finished && rounds < 45 {
                    try await Task.sleep(nanoseconds: 4_000_000_000)
                    rounds += 1
                    let clips = try await SunoAPI.shared.feed(ids: ids)
                    for c in clips {
                        await MainActor.run { store.update(Song.from(clip: c)) }
                    }
                    finished = clips.allSatisfy { ($0.status ?? "streaming") == "complete" || ($0.status ?? "") == "error" }
                }

                await MainActor.run {
                    busy = false
                    if finished {
                        message = "✅ 完成！已保存到音乐库"
                        prompt = ""; tags = ""; title = ""; extendNote = ""
                    } else {
                        message = "仍在生成中，可到「音乐库」等待或下拉刷新"
                    }
                }
            } catch {
                await MainActor.run {
                    busy = false
                    message = "❌ \(error.localizedDescription)"
                }
            }
        }
    }
}
