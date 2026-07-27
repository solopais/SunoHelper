import Foundation

// MARK: - Suno 内部 API 响应结构（基于对 studio-api.prod.suno.com 的真实抓取）

/// /api/feed/v2 返回的 clip 对象
struct SunoClip: Codable, Identifiable {
    let id: String
    let title: String?
    let image_url: String?
    let audio_url: String?
    let video_url: String?
    let created_at: String?
    let model_name: String?      // chirp-fenix / chirp-crow / chirp-auk ...
    let status: String?          // streaming / complete / error
    let play_count: Int?
    let upvote_count: Int?
    let metadata: SunoMetadata?
}

struct SunoMetadata: Codable {
    let prompt: String?
    let gpt_description_prompt: String?
    let type: String?
    let tags: String?
    let negative_tags: String?
    let duration: Double?
    let error_message: String?
    let vocal_gender: String?
    let weirdness: Double?
    let style_weight: Double?
    let mv: String?
    let title: String?
    let make_instrumental: Bool?
}

/// /api/feed/v2 的真实外层结构：{ clips:[...], num_total_results, current_page, has_more }
struct SunoFeedResponse: Codable {
    let clips: [SunoClip]
    let num_total_results: Int?
    let current_page: Int?
    let has_more: Bool?
}

/// POST /api/generate/v2/ 的响应
struct GenerateResponse: Codable {
    let clips: [SunoClipStub]
    let metadata: SunoGenerateMeta?
}

struct SunoClipStub: Codable, Identifiable {
    let id: String
    let status: String?
}

struct SunoGenerateMeta: Codable {
    let prompt: String?
    let tags: String?
    let title: String?
    let gpt_description_prompt: String?
    let make_instrumental: Bool?
    let mv: String?
}

// MARK: - 账户类型与计费

enum SunoPlanType: String, CaseIterable, Codable {
    case free = "free"
    case pro = "pro"
    case premier = "premier"
    case unknown = "unknown"

    var displayName: String {
        switch self {
        case .free:     return "免费版"
        case .pro:      return "Pro 版"
        case .premier:  return "Premier 版"
        case .unknown:  return "未知"
        }
    }

    var badgeColor: String {
        switch self {
        case .free:     return "gray"
        case .pro:      return "blue"
        case .premier:  return "purple"
        case .unknown:  return "gray"
        }
    }
}

/// GET /api/billing/info/ 的响应（真实字段）
struct BillingInfo: Codable {
    let credits: Int?
    let monthly_limit: Int?
    let monthly_usage: Int?
    let is_active: Bool?
    /// 订阅计划类型（可能为 nil，需用 credits/monthly_limit 推断）
    let plan_type: String?

    var total_credits_left: Int? { credits }

    /// 根据额度推断账户类型
    /// Suno 计费规则：免费版 monthly_limit=50或100，Pro=500，Premier=10000+
    var inferredPlan: SunoPlanType {
        if let limit = monthly_limit {
            if limit >= 10000 { return .premier }
            if limit >= 500  { return .pro }
            // <= 100 即免费版（含 legacy 免费 50 和当前免费 100）
            return .free
        }
        // 无 monthly_limit 字段时兜底：看 plan_type
        if let type = plan_type, !type.isEmpty {
            let t = type.lowercased()
            if t.contains("premier") { return .premier }
            if t.contains("pro")      { return .pro }
            return .free
        }
        // 最后兜底
        if let c = credits, c <= 100 { return .free }
        return .unknown
    }
}

// MARK: - 模型（与 suno.com 网页下拉一致，mv 为真实接口代号）
struct SunoModel: Identifiable, Hashable {
    var id: String { mv }
    let label: String       // 网页显示名
    let mv: String          // 接口 mv 代号
    let maxSeconds: Int
    /// 该模型是否需要 Pro 及以上账户
    let requiresPro: Bool
}

enum SunoModels {
    /// 官方模型列表（与 suno.com/create 下拉完全一致，共 6 个）
    static let all: [SunoModel] = [
        SunoModel(label: "v5.5 Pro",    mv: "chirp-fenix",      maxSeconds: 480, requiresPro: true),
        SunoModel(label: "v5 Pro",      mv: "chirp-crow",       maxSeconds: 480, requiresPro: true),
        SunoModel(label: "v4.5+ Pro",   mv: "chirp-bluejay",    maxSeconds: 480, requiresPro: true),
        SunoModel(label: "v4.5 Pro",    mv: "chirp-auk",        maxSeconds: 240, requiresPro: true),
        SunoModel(label: "v4.5-all",    mv: "chirp-auk-turbo",  maxSeconds: 240, requiresPro: false),
        SunoModel(label: "v4 Pro",      mv: "chirp-v4",         maxSeconds: 150, requiresPro: false),
    ]
    static let defaultMV = "chirp-auk-turbo"   // 默认选中 v4.5-all（最佳免费模型）

    static func label(for mv: String) -> String {
        all.first { $0.mv == mv }?.label ?? mv
    }

    /// 免费版可用的模型列表
    static func availableForFree() -> [SunoModel] {
        all.filter { !$0.requiresPro }
    }
}

// MARK: - 歌词模式（对应网页「写/提示/器乐」）
enum LyricsMode: String, CaseIterable, Identifiable {
    case write = "write"         // 写 — 自定义歌词
    case prompt = "prompt"       // 提示 — AI 根据描述生成歌词
    case instrumental = "instrumental" // 器乐 — 纯音乐

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .write:        return "写"
        case .prompt:       return "提示"
        case .instrumental: return "器乐"
        }
    }
}

// MARK: - 声音性别
enum VocalGender: String, CaseIterable, Identifiable {
    case male = "m"
    case female = "f"

    var id: String { rawValue }
    var displayName: String {
        self == .male ? "男性" : "女性"
    }
}

// MARK: - 生成请求体（完整参数，一比一复刻网页版）
struct GeneratePayload: Encodable {
    // === 核心参数 ===
    var make_instrumental: Bool = false
    var mv: String = SunoModels.defaultMV
    var prompt: String = ""                    // 自定义模式：歌词文本
    var generation_type: String = "TEXT"        // TEXT / AUDIO_UPLOAD / SIMPLE_REMIX 等（API 枚举校验）
    var gpt_description_prompt: String? = nil   // 简单/灵感模式提示词（≤200字）
    var tags: String? = nil                     // 风格标签（逗号分隔）
    var title: String? = nil                    // 歌曲标题

    // === 高级参数（网页版「更多选项」面板）===
    var negative_tags: String? = nil           // 排除的风格标签
    var vocal_gender: String? = nil             // 声音性别："m" / "f"
    var weirdness_constraint: Double? = nil     // 怪异度 0.0–1.0（网页滑块 0–100%）
    var style_weight: Double? = nil             // 风格影响 0.0–1.0（网页滑块 0–100%）
    var audio_weight: Double? = nil             // 音频保真度 0.0–1.0
    var auto_lyrics: Bool? = nil               // 是否自动生成歌词

    // === 续写参数 ===
    var continue_at: Double? = nil
    var continue_clip_id: String? = nil
    var cover_clip_id: String? = nil            // 翻唱(Cover) 基于的源歌曲 id（API 真实字段名）
    var task: String? = nil                     // "extend" / "whole" / "cover" 等

    // === 音频上传参数 ===
    var audio_url: String? = nil                // 音频上传后的 CDN URL（S3 两步上传流程用）

    // === 验证相关 ===
    var token: String? = nil                   // hCaptcha token（由 WebView 注入）

    // === 便捷构造器 ===

    /// 简单模式（灵感提示词 + 模型）
    static func simple(prompt: String, model: String, instrumental: Bool) -> GeneratePayload {
        var p = GeneratePayload(make_instrumental: instrumental, mv: model)
        p.gpt_description_prompt = prompt
        return p
    }

    /// 自定义模式（完整歌词 + 风格 + 标题 + 高级选项）
    static func custom(
        lyrics: String,
        tags: String,
        title: String,
        model: String,
        instrumental: Bool,
        negativeTags: String? = nil,
        gender: String? = nil,
        weirdness: Double? = nil,
        styleWeight: Double? = nil
    ) -> GeneratePayload {
        var p = GeneratePayload(
            make_instrumental: instrumental, mv: model,
            prompt: lyrics, tags: tags, title: title,
            negative_tags: negativeTags, vocal_gender: gender,
            weirdness_constraint: weirdness, style_weight: styleWeight
        )
        return p
    }

    /// 续写
    static func extend(clipId: String, at: Double, model: String, note: String) -> GeneratePayload {
        var p = GeneratePayload(make_instrumental: false, mv: model, prompt: note)
        p.continue_at = at
        p.continue_clip_id = clipId
        p.task = "extend"
        return p
    }

    /// Cover 翻唱：基于已有歌曲重新生成（保留旋律/结构，换风格/人声）
    /// 真实请求体（已用 cookie 实测 200 确认）：
    ///   task="cover" + cover_clip_id=<源歌曲id> + generation_type="TEXT" + prompt=""(必填!) + mv="chirp-auk-turbo"
    /// 注意：cover 仅 chirp-auk-turbo（免费）和 chirp-fenix/crow/bluejay/auk（Pro）支持，
    ///   chirp-v4 不支持 cover。免费账户强制用 chirp-auk-turbo。
    static func cover(clipId: String, model: String) -> GeneratePayload {
        var p = GeneratePayload(make_instrumental: false, mv: "chirp-auk-turbo")
        p.prompt = ""                    // API 必填字段！空字符串即可（422 实测确认）
        p.task = "cover"
        p.cover_clip_id = clipId
        p.generation_type = "TEXT"
        return p
    }
}
