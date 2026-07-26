import Foundation

// MARK: - Suno 内部 API 响应结构（基于 gcui-art/suno-api 参考实现）

/// /api/feed/v2 返回的 clip 对象（已扁平化）
struct SunoClip: Codable, Identifiable {
    let id: String
    let title: String
    let image_url: String?
    let audio_url: String?
    let video_url: String?
    let created_at: String?
    let model_name: String?
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

/// GET /api/billing/info/ 的响应
struct BillingInfo: Codable {
    let total_credits_left: Int?
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
    var token: String? = nil

    static func simple(prompt: String, model: String, instrumental: Bool) -> GeneratePayload {
        GeneratePayload(make_instrumental: instrumental, mv: model, gpt_description_prompt: prompt)
    }

    static func custom(lyrics: String, tags: String, title: String, model: String, instrumental: Bool) -> GeneratePayload {
        GeneratePayload(make_instrumental: instrumental, mv: model, prompt: lyrics, tags: tags, title: title)
    }

    static func extend(clipId: String, at: Double, model: String, note: String) -> GeneratePayload {
        var p = GeneratePayload(make_instrumental: false, mv: model, prompt: note,
                                 continue_clip_id: clipId, continue_at: at, task: "extend")
        return p
    }
}
