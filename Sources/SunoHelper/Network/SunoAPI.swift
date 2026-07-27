import Foundation

enum SunoError: LocalizedError {
    case authExpired
    case captcha            // token_validation_failed（需要人机验证）
    case http(Int, String)
    case network(Error)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .authExpired:
            return "登录已过期，请重新登录 Suno 账户"
        case .captcha:
            return "Suno 要求人机验证（hCaptcha），纯接口无法生成。请在「创作」用内置网页方式生成。"
        case .http(let c, let m):
            return "请求失败 (\(c))：\(String(m.prefix(200)))"
        case .network(let e):
            return "网络错误：\(e.localizedDescription)"
        case .cancelled:
            return "已取消"
        }
    }
}

/// Suno 网页内部 API 客户端（cookie 认证，非官方但免费账户可用）
struct SunoAPI {
    static let base = "https://studio-api.prod.suno.com"
    static let shared = SunoAPI()

    private func makeRequest(_ url: URL, method: String = "GET",
                             body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://suno.com/", forHTTPHeaderField: "Referer")
        req.setValue("https://suno.com", forHTTPHeaderField: "Origin")
        for (k, v) in SunoSession.shared.authHeaders() {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.httpBody = body
        req.timeoutInterval = 60
        return req
    }

    private func run<T>(_ block: @escaping () async throws -> T) async throws -> T {
        do {
            return try await block()
        } catch let e as SunoError {
            throw e
        } catch is CancellationError {
            throw SunoError.cancelled
        } catch {
            throw SunoError.network(error)
        }
    }

    /// 音频上传 + 生成一体接口（multipart/form-data）— 接受预读取的 Data，避免沙盒权限过期
    func generateWithAudioData(fileData: Data, fileName: String, payload: GeneratePayload) async throws -> [SunoClipStub] {
        try await run {
            let apiURL = URL(string: "\(SunoAPI.base)/api/generate/v2/")!
            let mimeType = mimeTypeForAudio(fileName)

            // 构建 multipart/form-data body
            let boundary = "Boundary-\(UUID().uuidString)"
            var body = Data()

            // 普通文本字段（从 payload 提取）
            let formFields: [(String, String?)] = [
                ("make_instrumental", "\(payload.make_instrumental)"),
                ("mv", payload.mv),
                ("generation_type", "AUDIO_UPLOAD"),
                ("prompt", payload.prompt.isEmpty ? nil : payload.prompt),
                ("gpt_description_prompt", payload.gpt_description_prompt),
                ("tags", payload.tags),
                ("title", payload.title),
                ("negative_tags", payload.negative_tags),
                ("vocal_gender", payload.vocal_gender),
                ("weirdness_constraint", payload.weirdness_constraint.map { "\($0)" }),
                ("style_weight", payload.style_weight.map { "\($0)" }),
                ("audio_weight", payload.audio_weight.map { "\($0)" }),
                ("task", payload.task),
                ("token", payload.token),
            ]

            for (key, value) in formFields {
                if let v = value, !v.isEmpty {
                    body.append(Data("--\(boundary)\r\n".utf8))
                    body.append(Data("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".utf8))
                    body.append(Data("\(v)\r\n".utf8))
                }
            }

            // 文件字段
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"audio_file\"; filename=\"\(fileName)\"\r\n".utf8))
            body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
            body.append(fileData)
            body.append(Data("\r\n".utf8))

            // 结束标记
            body.append(Data("--\(boundary)--\r\n".utf8))

            // 构建请求
            var req = URLRequest(url: apiURL)
            req.httpMethod = "POST"
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            req.setValue("https://suno.com/", forHTTPHeaderField: "Referer")
            req.setValue("https://suno.com", forHTTPHeaderField: "Origin")
            for (k, v) in SunoSession.shared.authHeaders() {
                req.setValue(v, forHTTPHeaderField: k)
            }
            req.httpBody = body
            req.timeoutInterval = 120  // 上传可能需要更长时间

            let (data, resp) = try await URLSession.shared.data(for: req)
            try Self.check(resp: resp, data: data)
            let decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
            return decoded.clips
        }
    }

    /// 音频上传 + 生成一体接口（multipart/form-data）— 从文件 URL 读取（兼容旧调用）
    func generateWithAudio(fileURL: URL, payload: GeneratePayload) async throws -> [SunoClipStub] {
        let fileData = try Data(contentsOf: fileURL)
        return try await generateWithAudioData(fileData: fileData, fileName: fileURL.lastPathComponent, payload: payload)
    }

    /// 根据文件扩展名推断 MIME 类型
    private func mimeTypeForAudio(_ fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        case "ogg": return "audio/ogg"
        case "flac": return "audio/flac"
        case "aac": return "audio/aac"
        default: return "audio/mpeg"
        }
    }

    /// 普通 JSON 生成（文本模式 / 续写 / Cover）
    func generate(payload: GeneratePayload) async throws -> [SunoClipStub] {
        try await run {
            let url = URL(string: "\(SunoAPI.base)/api/generate/v2/")!
            let body = try JSONEncoder().encode(payload)
            let req = makeRequest(url, method: "POST", body: body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            try Self.check(resp: resp, data: data)
            let decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
            return decoded.clips
        }
    }

    /// 按 ids 查询（用于轮询生成进度）
    func feed(ids: [String]) async throws -> [SunoClip] {
        try await run {
            var comps = URLComponents(string: "\(SunoAPI.base)/api/feed/v2")!
            comps.queryItems = [URLQueryItem(name: "ids", value: ids.joined(separator: ","))]
            let req = makeRequest(comps.url!)
            let (data, resp) = try await URLSession.shared.data(for: req)
            try Self.check(resp: resp, data: data)
            return Self.decodeClips(data)
        }
    }

    /// 拉取「我的音乐库」——当前账户所有歌曲（分页）
    /// 注意：Suno feed/v2 的 page 参数从 1 开始（非 0）
    func library(page: Int) async throws -> SunoFeedResponse {
        try await run {
            let safePage = max(page, 1)  // API page 从 1 开始
            var comps = URLComponents(string: "\(SunoAPI.base)/api/feed/v2")!
            comps.queryItems = [
                URLQueryItem(name: "page", value: String(safePage))
            ]
            let req = makeRequest(comps.url!)
            let (data, resp) = try await URLSession.shared.data(for: req)
            try Self.check(resp: resp, data: data)
            if let wrapped = try? JSONDecoder().decode(SunoFeedResponse.self, from: data) {
                return wrapped
            }
            let arr = Self.decodeClips(data)
            return SunoFeedResponse(clips: arr, num_total_results: arr.count,
                                    current_page: safePage, has_more: false)
        }
    }

    func credits() async throws -> Int {
        try await run {
            let url = URL(string: "\(SunoAPI.base)/api/billing/info/")!
            let req = makeRequest(url)
            let (data, resp) = try await URLSession.shared.data(for: req)
            try Self.check(resp: resp, data: data)
            let b = try JSONDecoder().decode(BillingInfo.self, from: data)
            return b.total_credits_left ?? 0
        }
    }

    /// 完整计费信息（含账户类型推断）
    func billing() async throws -> BillingInfo {
        try await run {
            let url = URL(string: "\(SunoAPI.base)/api/billing/info/")!
            let req = makeRequest(url)
            let (data, resp) = try await URLSession.shared.data(for: req)
            try Self.check(resp: resp, data: data)
            return try JSONDecoder().decode(BillingInfo.self, from: data)
        }
    }

    // feed 可能返回 { clips:[...] } 外层，也可能直接是数组 —— 都兼容
    private static func decodeClips(_ data: Data) -> [SunoClip] {
        if let wrapped = try? JSONDecoder().decode(SunoFeedResponse.self, from: data) {
            return wrapped.clips
        }
        if let arr = try? JSONDecoder().decode([SunoClip].self, from: data) {
            return arr
        }
        return []
    }

    private static func check(resp: URLResponse, data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw SunoError.authExpired
        }
        if http.statusCode == 422 {
            let msg = String(data: data, encoding: .utf8) ?? ""
            if msg.contains("token_validation_failed") || msg.contains("verify your request") {
                throw SunoError.captcha
            }
            throw SunoError.http(422, msg)
        }
        if !(200...299).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw SunoError.http(http.statusCode, msg)
        }
    }
}
