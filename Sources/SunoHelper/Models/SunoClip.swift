import Foundation

// MARK: - Suno 内部 API 响应结构（基于对 studio-api.prod.suno.com 的真实抓取）

/// /api/feed/v2 返回的 clip 对象
struct SunoClip: Codable, Identifiable {
    let id: String
    let title: String
    let image_url: String?
    let audio_url: String?
    let video_url: String?
    let created_at: String?
    let model_name: String?      // chirp-fenix / chirp-crow / chirp-auk ...
    let status: String?          // streaming / complete / error
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

/// GET /api/billing/info/ 的响应（真实字段）
struct BillingInfo: Codable {
    let credits: Int?
    let monthly_limit: Int?
    let monthly_usage: Int?
    let is_active: Bool?
    var total_credits_left: Int? { credits }
}

// MARK: - 模型（与 suno.com 网页下拉一致，mv 为真实接口代号）
struct SunoModel: Identifiable, Hashable {
    var id: String { mv }
    let label: String   // 网页显示名
    let mv: String      // 接口 mv 代号
    let maxSeconds: Int
}

enum SunoModels {
    static let all: [SunoModel] = [
        SunoModel(label: "v5.5 Pro", mv: "chirp-fenix",      maxSeconds: 480),
        SunoModel(label: "v5 Pro",   mv: "chirp-crow",       maxSeconds: 480),
        SunoModel(label: "v4.5+ Pro", mv: "chirp-bluejay",   maxSeconds: 480),
        SunoModel(label: "v4.5-all", mv: "chirp-auk-turbo",  maxSeconds: 240),
        SunoModel(label: "v4.5 Pro", mv: "chirp-auk",        maxSeconds: 240),
        SunoModel(label: "v4 Pro",   mv: "chirp-v4",         maxSeconds: 150),
    ]
    static let defaultMV = "chirp-crow"

    static func label(for mv: String) -> String {
        all.first { $0.mv == mv }?.label ?? mv
    }
}

// MARK: - 生成请求体
struct GeneratePayload: Encodable {
    var make_instrumental: Bool
    var mv: String
    var prompt: String = ""
    var generation_type: String = "TEXT"
    var gpt_description_prompt: String? = nil
    var tags: String? = nil
    var title: String? = nil
    var negative_tags: String? = nil
    var continue_at: Double? = nil
    var continue_clip_id: String? = nil
    var task: String? = nil
    var token: String? = nil          // hCaptcha token（由 WebView 注入）

    static func simple(prompt: String, model: String, instrumental: Bool) -> GeneratePayload {
        GeneratePayload(make_instrumental: instrumental, mv: model, gpt_description_prompt: prompt)
    }

    static func custom(lyrics: String, tags: String, title: String, model: String, instrumental: Bool) -> GeneratePayload {
        GeneratePayload(make_instrumental: instrumental, mv: model, prompt: lyrics, tags: tags, title: title)
    }

    static func extend(clipId: String, at: Double, model: String, note: String) -> GeneratePayload {
        GeneratePayload(make_instrumental: false, mv: model, prompt: note,
                        continue_at: at, continue_clip_id: clipId, task: "extend")
    }
}
