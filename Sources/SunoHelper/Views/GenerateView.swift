import SwiftUI

// MARK: - 创作模式（对应网页「很简单」/「高级」）
private enum CreateMode: String, CaseIterable {
    case simple = "很简单"
    case advanced = "高级"
}

struct GenerateView: View {
    @StateObject private var session = SunoSession.shared
    @StateObject private var store = SongStore.shared

    // === 模式与核心输入 ===
    @State private var createMode: CreateMode = .simple
    @State private var model = SunoModels.defaultMV
    @State private var prompt = ""              // 简单模式提示词 / 高级模式歌词
    @State private var tags = ""                // 风格标签
    @State private var title = ""               // 歌曲标题
    @State private var instrumental = false     // 纯音乐

    // === 高级选项（对应网页「更多选项」面板）===
    @State private var showAdvancedOptions = false
    @State private var lyricsMode: LyricsMode = .prompt   // 写 / 提示 / 器乐
    @State private var vocalGender: VocalGender? = nil    // 男性 / 女性
    @State private var weirdness: Double = 50             // 怪异 0–100%
    @State private var styleWeight: Double = 50           // 风格影响 0–100%
    @State private var negativeTags = ""                  // 排除标签

    // === 状态 ===
    @State private var busy = false
    @State private var message = ""
    @State private var showWebViewCreate = false
    @State private var captchaBlocked = false
    @State private var showAudioPicker = false       // 音频文件选择器
    @State private var pickedAudioURL: URL?          // 已选音频文件路径（bookmark 用）
    @State private var pickedAudioName: String?      // 已选音频文件名
    @State private var pickedAudioData: Data?        // 已选音频文件数据（选择时立即读取，避免沙盒权限过期）

    // === 续写模式 ===
    private let extendClipID: String?
    private let coverClipID: String?       // Cover 模式：基于已有歌曲翻唱
    @State private var extendNote = ""

    // === 账户信息 ===
    @State private var planType: SunoPlanType = .unknown
    @State private var creditsLeft: Int?

    init(extendClipID: String? = nil, coverClipID: String? = nil) {
        self.extendClipID = extendClipID
        self.coverClipID = coverClipID
    }

    // 根据账户类型过滤可用模型
    var availableModels: [SunoModel] {
        if planType == .free {
            return SunoModels.availableForFree()
        }
        return SunoModels.all
    }

    var body: some View {
        AppNav {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    // MARK: - 续写模式提示
                    if let ext = extendClipID {
                       续写Header(clipId: ext)
                    }

                    // MARK: - Cover 模式提示
                    if let cid = coverClipID {
                        CoverHeader(clipId: cid)
                    }

                    // MARK: - 顶栏：模式切换 + 模型选择
                    HStack(spacing: 12) {
                        // 左侧：模式切换
                        Picker("模式", selection: $createMode) {
                            ForEach(CreateMode.allCases, id: \.self) { m in
                                Text(m.rawValue).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)

                        Spacer()

                        // 右侧：模型选择
                        Picker("模型", selection: $model) {
                            ForEach(availableModels) { m in
                                Text(m.label).tag(m.mv)
                            }
                        }
                        .pickerStyle(.menu)
                        .accentColor(AppTheme.accent)
                    }
                    .padding(.horizontal, 16)

                    // MARK: - 简单模式内容
                    if createMode == .simple && extendClipID == nil {
                        SimpleModeSection(
                            prompt: $prompt,
                            instrumental: $instrumental,
                            model: model
                        )
                    }

                    // MARK: - 高级模式内容
                    if createMode == .advanced && extendClipID == nil {
                        AdvancedModeSection(
                            prompt: $prompt,
                            tags: $tags,
                            title: $title,
                            instrumental: $instrumental,
                            lyricsMode: $lyricsMode,
                            vocalGender: $vocalGender,
                            weirdness: $weirdness,
                            styleWeight: $styleWeight,
                            negativeTags: $negativeTags,
                            showAdvancedOptions: $showAdvancedOptions,
                            planType: planType,
                            onPickAudio: { showAudioPicker = true },
                            onClearAudio: {
                                pickedAudioURL = nil
                                pickedAudioName = nil
                                pickedAudioData = nil
                            },
                            pickedAudioName: pickedAudioName
                        )
                    }

                    // MARK: - 续写模式内容
                    if extendClipID != nil {
                        ExtendSection(note: $extendNote)
                    }

                    // MARK: - 提示消息
                    if !message.isEmpty {
                        Text(message)
                            .font(.footnote)
                            .foregroundColor(message.contains("失败") || message.contains("过期") || message.contains("❌") ? AppTheme.error : AppTheme.textSecondary)
                            .padding(.horizontal, 16)
                    }

                    // MARK: - hCaptcha 回退按钮
                    if captchaBlocked {
                        Button(action: { showWebViewCreate = true }) {
                            Label("去 Suno 网页创作（绕过人机验证）", systemImage: "globe")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.orange.opacity(0.15))
                                .foregroundColor(.orange)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                                )
                        }
                        .padding(.horizontal, 16)
                    }

                    // MARK: - 创作按钮
                    Button(action: runGenerate) {
                        HStack(spacing: 8) {
                            if busy { ProgressView().tint(.white).scaleEffect(0.8) }
                            Image(systemName: "wand.and.stars")
                            Text(busy ? "创作中…" : "创作")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(busy ? AnyShapeStyle(AppTheme.surface2) : AnyShapeStyle(AppTheme.gradient()))
                        .foregroundColor(.white)
                        .font(.headline)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(busy || canSubmit() == false)
                    .padding(.horizontal, 16)

                    // MARK: - 网页创作入口
                    Button(action: { showWebViewCreate = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "globe")
                            Text("在 Suno 网页中创作").underline()
                        }
                        .font(.caption)
                        .foregroundColor(AppTheme.accent.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 8)

                    Spacer(minLength: 20)
                }
                .padding(.top, 12)
            }
            .hideScrollContentBackground()
            .background(AppTheme.bg)
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $showWebViewCreate) {
                CreateWebView()
            }
            .fileImporter(
                isPresented: $showAudioPicker,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        // 立即读取文件数据（security-scoped URL 仅在选择回调期间有效）
                        let accessed = url.startAccessingSecurityScopedResource()
                        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                        if let data = try? Data(contentsOf: url) {
                            pickedAudioData = data
                            pickedAudioURL = url
                            pickedAudioName = url.lastPathComponent
                            createMode = .advanced
                        } else {
                            message = "❌ 无法读取音频文件，请重试"
                        }
                    }
                case .failure(let err):
                    message = "选择文件失败：\(err.localizedDescription)"
                }
            }
            .onAppear { checkPlan() }
        }
    }

    var navTitle: String {
        if coverClipID != nil { return "翻唱" }
        if extendClipID != nil { return "续写歌曲" }
        return "创作"
    }

    /// 是否可以提交
    func canSubmit() -> Bool {
        if busy { return false }
        if extendClipID != nil { return true }  // 续写不需要必填
        if coverClipID != nil { return true }   // Cover 不需要必填
        return !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 检查账户类型
    func checkPlan() {
        Task {
            do {
                let info = try await SunoAPI.shared.billing()
                await MainActor.run {
                    planType = info.inferredPlan
                    creditsLeft = info.credits
                    // 如果当前选中的模型不在可用列表里，切回默认
                    if !availableModels.contains(where: { $0.mv == model }) {
                        model = availableModels.first?.mv ?? SunoModels.defaultMV
                    }
                }
            } catch {
                await MainActor.run { planType = .unknown }
            }
        }
    }

    /// 构建生成载荷（根据当前表单状态）
    func buildPayload() -> GeneratePayload {
        if let cid = coverClipID {
            return .cover(clipId: cid, model: model)
        } else if let ext = extendClipID {
            return .extend(clipId: ext, at: 0, model: model, note: extendNote)
        } else if createMode == .simple {
            var p = GeneratePayload.simple(prompt: prompt, model: model, instrumental: instrumental)
            applyAdvancedParams(&p)
            return p
        } else {
            var gen = vocalGender?.rawValue
            var ww = weirdness / 100.0
            var sw = styleWeight / 100.0
            return .custom(
                lyrics: prompt, tags: tags, title: title,
                model: model, instrumental: instrumental,
                negativeTags: negativeTags.isEmpty ? nil : negativeTags,
                gender: gen, weirdness: ww, styleWeight: sw
            )
        }
    }

    /// 执行生成
    func runGenerate() {
        guard session.isLoggedIn else {
            message = "请先登录 Suno 账户"
            return
        }
        busy = true
        message = pickedAudioData != nil ? "正在上传音频并提交创作任务…" : "提交创作任务…"
        captchaBlocked = false

        Task {
            do {
                let stubs: [SunoClipStub]

                // 如果选择了音频文件，走 multipart 上传路径（用预读取的 Data 避免沙盒权限过期）
                if let audioData = pickedAudioData, let audioURL = pickedAudioURL {
                    message = "正在上传音频并提交创作任务…"
                    var audioPayload = buildPayload()
                    audioPayload.generation_type = "AUDIO_UPLOAD"
                    audioPayload.input = "AUDIO"
                    stubs = try await SunoAPI.shared.generateWithAudioData(fileData: audioData, fileName: audioURL.lastPathComponent, payload: audioPayload)
                } else {
                    stubs = try await SunoAPI.shared.generate(payload: buildPayload())
                }
                let ids = stubs.map { $0.id }
                await MainActor.run { message = "已提交，Suno 创作中（\(ids.count) 首）…" }

                var finished = false
                var rounds = 0
                while !finished && rounds < 60 {
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
                        resetForm()
                    } else {
                        message = "仍在创作中，可到「音乐库」等待或下拉刷新"
                    }
                }
            } catch {
                await MainActor.run {
                    busy = false
                    message = "❌ \(error.localizedDescription)"
                    if let se = error as? SunoError, case .captcha = se {
                        captchaBlocked = true
                    }
                }
            }
        }
    }

    /// 把高级参数应用到任意 payload
    func applyAdvancedParams(_ p: inout GeneratePayload) {
        p.vocal_gender = vocalGender?.rawValue
        p.weirdness_constraint = weirdness / 100.0
        p.style_weight = styleWeight / 100.0
        if !negativeTags.isEmpty { p.negative_tags = negativeTags }
        if !title.isEmpty { p.title = title }
    }

    /// 重置表单
    func resetForm() {
        prompt = ""; tags = ""; title = ""; extendNote = ""
        negativeTags = ""; vocalGender = nil
        weirdness = 50; styleWeight = 50
        pickedAudioURL = nil; pickedAudioName = nil; pickedAudioData = nil
    }
}

// MARK: - 简单模式区域
private struct SimpleModeSection: View {
    @Binding var prompt: String
    @Binding var instrumental: Bool
    let model: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("描述你想创作的歌曲")
                .font(.subheadline).foregroundColor(AppTheme.textSecondary)

            TextEditor(text: $prompt)
                .frame(minHeight: 120)
                .padding(8)
                .background(AppTheme.surface)
                .foregroundColor(AppTheme.text)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            Text("例：一首欢快的夏日流行歌，关于海边旅行，女声")
                .font(.caption2).foregroundColor(AppTheme.textSecondary)
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - 高级模式区域（一比一复刻网页版）
private struct AdvancedModeSection: View {
    @Binding var prompt: String
    @Binding var tags: String
    @Binding var title: String
    @Binding var instrumental: Bool
    @Binding var lyricsMode: LyricsMode
    @Binding var vocalGender: VocalGender?
    @Binding var weirdness: Double
    @Binding var styleWeight: Double
    @Binding var negativeTags: String
    @Binding var showAdvancedOptions: Bool
    var planType: SunoPlanType = .unknown
    var onPickAudio: (() -> Void)? = nil
    var onClearAudio: (() -> Void)? = nil
    var pickedAudioName: String? = nil

    /// 免费版是否锁定高级参数（怪异/风格影响固定 50%）
    private var isFreePlan: Bool { planType == .free }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            // MARK: 功能按钮行（+音频 +配音 +灵感来源）
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    // 音频上传（免费版可用）— 点击弹出文件选择器
                    FeatureChip(icon: "waveform", label: "音频", isNew: false, isLocked: false, action: onPickAudio)
                    // 配音 — Pro 专属（AI 声音克隆/自定义人声，上传声音样本或从已有歌曲提取音色）
                    FeatureChip(icon: "mic.fill", label: "配音", isNew: true, isLocked: isFreePlan, lockHint: "Pro 专属")
                    // 灵感来源 — Pro 专属（AI 推荐提示词/风格组合/热门趋势建议）
                    FeatureChip(icon: "lightbulb", label: "灵感来源", isNew: false, isLocked: isFreePlan, lockHint: "Pro 专属")
                }
            }
            .padding(.horizontal, 16)

            // 已选音频文件名显示
            if let name = pickedAudioName {
                HStack(spacing: 6) {
                    Image(systemName: "doc.fill").font(.caption).foregroundColor(AppTheme.accent)
                    Text(name)
                        .font(.caption).foregroundColor(AppTheme.textSecondary).lineLimit(1)
                    Button(action: { onClearAudio?() }) {
                        Image(systemName: "xmark.circle.fill").font(.caption).foregroundColor(AppTheme.textSecondary)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 4)
            }

            // MARK: 歌词区域
            DisclosureGroup(isExpanded: .constant(true)) {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 110)
                        .padding(8)
                        .background(AppTheme.surface)
                        .foregroundColor(AppTheme.text)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    Text("支持 [Verse] / [Chorus] / [Bridge] 结构标记")
                        .font(.caption2).foregroundColor(AppTheme.textSecondary)
                }
            } label: {
                HStack {
                    Text("歌词").font(.subheadline).fontWeight(.medium).foregroundColor(AppTheme.text)
                    Spacer()
                    Image(systemName: "chevron.down").font(.caption).foregroundColor(AppTheme.textSecondary)
                }
            }
            .padding(.horizontal, 16)
            // InsetDisclosureGroupStyle is iOS 16+; remove for iOS 15 compatibility

            // MARK: 风格区域
            DisclosureGroup(isExpanded: .constant(true)) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("风格标签（如 pop, upbeat, 电子, 女声）", text: $tags)
                        .padding(10)
                        .background(AppTheme.surface)
                        .foregroundColor(AppTheme.text)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    // 快捷风格标签
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(["未来声场", "南方氛围", "你办派对", "春力节拍", "民谣画意", "电子", "摇滚", "R&B", "古典"], id: \.self) { tag in
                                StyleTagChip(tag: tag, selectedTags: $tags)
                            }
                        }
                    }
                }
            } label: {
                HStack {
                    Text("风格").font(.subheadline).fontWeight(.medium).foregroundColor(AppTheme.text)
                    Spacer()
                    Image(systemName: "chevron.down").font(.caption).foregroundColor(AppTheme.textSecondary)
                }
            }
            .padding(.horizontal, 16)
            // InsetDisclosureGroupStyle is iOS 16+; remove for iOS 15 compatibility

            // MARK: 更多选项（折叠面板）
            DisclosureGroup(isExpanded: $showAdvancedOptions) {
                VStack(alignment: .leading, spacing: 14) {

                    // 歌词模式：写 / 提示 / 器乐
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("歌词").font(.subheadline).foregroundColor(AppTheme.textSecondary)
                            Spacer()
                            HStack(spacing: 0) {
                                ForEach(LyricsMode.allCases) { mode in
                                    LyricsModeChip(mode: mode, selected: $lyricsMode)
                                }
                            }
                        }
                        Text(instrumentalModeHint)
                            .font(.caption2).foregroundColor(AppTheme.textSecondary)
                    }

                    // 声音性别
                    HStack {
                        Text("声音性别").font(.subheadline).foregroundColor(AppTheme.textSecondary)
                        Spacer()
                        HStack(spacing: 0) {
                            GenderChip(label: "男性", gender: .male, selected: $vocalGender)
                            GenderChip(label: "女性", gender: .female, selected: $vocalGender)
                        }
                    }

                    // 怪异滑块（免费版锁定 50%）
                    SliderRow(label: "怪异", value: $weirdness, icon: "questionmark.circle", locked: isFreePlan)

                    // 风格影响滑块（免费版锁定 50%）
                    SliderRow(label: "风格影响", value: $styleWeight, icon: "paintbrush", locked: isFreePlan)

                    // Song Title
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "music.note").foregroundColor(AppTheme.accent).font(.caption)
                            Text("Song Title (Optional)")
                                .font(.subheadline).foregroundColor(AppTheme.textSecondary)
                        }
                        TextField("歌曲标题（可选）", text: $title)
                            .padding(10)
                            .background(AppTheme.surface)
                            .foregroundColor(AppTheme.text)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            } label: {
                HStack {
                    Image(systemName: "slider.horizontal.3").font(.subheadline)
                    Text("更多选项").font(.subheadline).fontWeight(.medium).foregroundColor(AppTheme.text)
                    Spacer()
                    Image(systemName: showAdvancedOptions ? "chevron.up" : "chevron.down")
                        .font(.caption).foregroundColor(AppTheme.textSecondary)
                }
            }
            .padding(.horizontal, 16)
            // InsetDisclosureGroupStyle is iOS 16+; remove for iOS 15 compatibility
        }
    }

    var instrumentalModeHint: String {
        switch lyricsMode {
        case .write:        return "填写完整歌词，AI 将按你的词谱曲演唱"
        case .prompt:       return "AI 自动根据风格标签生成歌词和旋律"
        case .instrumental: return "仅生成器乐曲，无人声演唱"
        }
    }
}

// MARK: - 续写区域
private struct ExtendSection: View {
    @Binding var note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("续写描述（可选，留空则自动延续）")
                .font(.subheadline).foregroundColor(AppTheme.textSecondary)
            TextEditor(text: $note)
                .frame(minHeight: 90)
                .padding(8)
                .background(AppTheme.surface)
                .foregroundColor(AppTheme.text)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - 续写头部
private struct 续写Header: View {
    let clipId: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("续写模式", systemImage: "arrow.forward.to.line")
                .font(.headline).foregroundColor(AppTheme.accent)
            Text("基于已选片段继续生成（id: \(clipId.prefix(8))…）")
                .font(.caption).foregroundColor(AppTheme.textSecondary)
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - 翻唱头部
private struct CoverHeader: View {
    let clipId: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("翻唱模式", systemImage: "waveform.badge.mic")
                .font(.headline).foregroundColor(AppTheme.accent)
            Text("基于已选歌曲重新生成（保留原曲结构，可换风格/模型）\nid: \(clipId.prefix(8))…")
                .font(.caption).foregroundColor(AppTheme.textSecondary)
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - 功能按钮 Chip（+音频/+配音/+灵感）
private struct FeatureChip: View {
    let icon: String
    let label: String
    let isNew: Bool
    var isLocked: Bool = false
    var lockHint: String = ""
    var action: (() -> Void)? = nil

    var body: some View {
        Button(action: {
            if !isLocked { action?() }
        }) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption)
                Text(label).font(.caption)
                if isNew && !isLocked {
                    Text("新").font(.system(size: 9)).fontWeight(.bold)
                        .foregroundColor(.white).padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.pink).clipShape(Capsule())
                }
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8)).foregroundColor(AppTheme.textSecondary)
                    if !lockHint.isEmpty {
                        Text(lockHint).font(.system(size: 8)).foregroundColor(AppTheme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(isLocked ? AppTheme.surface2 : AppTheme.surface)
            .foregroundColor(isLocked ? AppTheme.textSecondary : AppTheme.text)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(isLocked ? 0.7 : 1.0)
        }
        .disabled(isLocked)
    }
}

// MARK: - 风格快捷标签
private struct StyleTagChip: View {
    let tag: String
    @Binding var selectedTags: String

    var isSelected: Bool {
        selectedTags.contains(tag)
    }

    var body: some View {
        Button(action: toggleTag) {
            Text(tag)
                .font(.caption2)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(isSelected ? AppTheme.accent.opacity(0.15) : AppTheme.surface)
                .foregroundColor(isSelected ? AppTheme.accent : AppTheme.textSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? AppTheme.accent : Color.clear, lineWidth: 1)
                )
        }
    }

    func toggleTag() {
        var current = selectedTags.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let idx = current.firstIndex(of: tag) {
            current.remove(at: idx)
        } else {
            current.append(tag)
        }
        selectedTags = current.joined(separator: ", ")
    }
}

// MARK: - 歌词模式 Chip
private struct LyricsModeChip: View {
    let mode: LyricsMode
    @Binding var selected: LyricsMode

    var body: some View {
        Button(action: { selected = mode }) {
            Text(mode.displayName)
                .font(.caption)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected == mode ? AppTheme.accent : AppTheme.surface)
                .foregroundColor(selected == mode ? .white : AppTheme.textSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - 性别选择 Chip
private struct GenderChip: View {
    let label: String
    let gender: VocalGender
    @Binding var selected: VocalGender?

    var body: some View {
        Button(action: {
            if selected == gender { selected = nil } else { selected = gender }
        }) {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(selected == gender ? AppTheme.accent : AppTheme.surface)
                .foregroundColor(selected == gender ? .white : AppTheme.textSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - 滑块行
private struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let icon: String
    var locked: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: icon).font(.caption).foregroundColor(AppTheme.textSecondary)
                    Text(label).font(.subheadline).foregroundColor(AppTheme.textSecondary)
                }
                Spacer()
                HStack(spacing: 3) {
                    Text("\(Int(value))%")
                        .font(.caption).monospacedDigit().foregroundColor(AppTheme.accent)
                    if locked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9)).foregroundColor(AppTheme.textSecondary)
                    }
                }
            }
            Slider(value: $value, in: 0...100, step: 1)
                .accentColor(AppTheme.accent)
                .tint(AppTheme.accent)
                .disabled(locked)
                .opacity(locked ? 0.6 : 1.0)
            if locked {
                Text("免费版固定为 50%")
                    .font(.caption2).foregroundColor(AppTheme.textSecondary)
            }
        }
    }
}
