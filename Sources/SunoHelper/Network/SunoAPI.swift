import Foundation

enum SunoError: LocalizedError {
    case authExpired
    case captcha            // token_validation_failed（需要人机验证）
    case http(Int, String)
    case network(Error)
    case cancelled
    case uploadFailed(String)  // 上传各步骤失败（获取预签名URL / S3上传 / 注册）

    var errorDescription: String? {
        switch self {
        case .authExpired:
            return "登录已过期，请重新登录 Suno 账户"
        case .captcha:
            return "Suno 要求人机验证（hCaptcha），纯接口无法生成。请在「创作」用内置网页方式生成。"
        case .http(let c, let m):
            return "请求失败 (\(c))：\(String(m.prefix(200)))"
        case .network(let e):
            // 加 URLError code 帮助定位（networkConnectionLost=-1005 等）
            if let urlErr = e as? URLError {
                return "网络错误[\(urlErr.errorCode)]：\(e.localizedDescription)"
            }
            return "网络错误：\(e.localizedDescription)"
        case .cancelled:
            return "已取消"
        case .uploadFailed(let reason):
            return "上传失败：\(reason)"
        }
    }
}

// MARK: - 音频上传相关数据结构

/// Step 1 返回：S3 预签名上传信息
struct AudioUploadRequestResponse: Decodable {
    let id: String                 // 上传任务 ID，后续用于关联生成任务
    let url: String                // S3 预签名 POST URL
    let fields: [String: String]   // S3 表单字段（key, policy, signature 等）
}

/// Step 1+2 完成后的结果，供 generate 调用使用
struct AudioUploadResult {
    let uploadId: String           // Suno 上传任务 ID
    let audioUrl: String           // 文件在 Suno CDN/S3 的最终 URL（由 id 拼接）
}

/// GET /api/uploads/audio/{id}/ 的响应（上传后轮询处理状态用）
struct AudioUploadStatus: Decodable {
    let id: String
    let status: String?          // "processing" → "complete" / "error"
    let title: String?
    let audio_url: String?       // 处理完成后可能返回真实 CDN URL
    let copyright_muted: Bool?
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
            DebugLog.shared.error("网络", "\(type(of: error)): \(error.localizedDescription)")
            throw SunoError.network(error)
        }
    }

    
    /// 网络请求重试封装：对"请求未到达服务器"的瞬时连接错误自动重试，
    /// 吞掉偶发 -1005 / 断网抖动，避免一次网络闪断就整条上传/生成失败。
    /// 仅重试连接级错误（连接丢失/无法连接，服务端不可能已处理请求），
    /// 不重试超时(-1001)/取消(-999)/4xx/5xx（避免 POST 重复提交产生重复歌曲）。
    private static func performDataRequest(_ req: URLRequest) async throws -> (Data, URLResponse) {
        let maxAttempts = 3
        let retryable: [URLError.Code] = [
            .networkConnectionLost,   // -1005
            .cannotConnectToHost,     // -1004
            .cannotFindHost,          // -1003
            .notConnectedToInternet,  // -1009
            .cannotLoadFromNetwork    // -1020
        ]
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                return try await URLSession.shared.data(for: req)
            } catch {
                if attempt < maxAttempts,
                   let urlErr = error as? URLError,
                   retryable.contains(urlErr.code) {
                    DebugLog.shared.info("网络", "瞬时连接错误[\(urlErr.errorCode)] 第\(attempt)次，重试...")
                    let backoff = attempt == 1 ? 1_000_000_000 : 2_000_000_000
                    try? await Task.sleep(nanoseconds: backoff)
                    lastError = error
                    continue
                }
                throw error
            }
        }
        throw lastError ?? SunoError.network(NSError(domain: "suno.retry", code: -1))
    }

// MARK: - 音频上传（S3 两步流程）
    //
    // Suno 真实音频上传流程（从网页版逆向确认）：
    //   Step 1: POST /api/uploads/audio { extension: "mp3" } → 获取 S3 预签名 URL + 表单字段
    //   Step 2: POST 文件到 S3（使用预签名 URL + fields，multipart/form-data）
    //   Step 3: 用返回的 uploadId / audioUrl 进行后续生成或翻唱
    //
    // 之前直接 multipart 到 /api/generate/v2/ 是完全错误的协议。

    /// Step 1: 请求 S3 预签名上传 URL
    func requestAudioUpload(fileExtension: String) async throws -> AudioUploadRequestResponse {
        try await run {
            let url = URL(string: "\(SunoAPI.base)/api/uploads/audio/")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("https://suno.com/", forHTTPHeaderField: "Referer")
            req.setValue("https://suno.com", forHTTPHeaderField: "Origin")
            for (k, v) in SunoSession.shared.authHeaders() {
                req.setValue(v, forHTTPHeaderField: k)
            }
            let body = try JSONEncoder().encode(["extension": fileExtension])
            req.httpBody = body
            req.timeoutInterval = 30

            DebugLog.shared.info("上传", "Step1 POST /api/uploads/audio/ ext=\(fileExtension)")
            let (data, resp) = try await Self.performDataRequest(req)
            if let http = resp as? HTTPURLResponse {
                DebugLog.shared.info("上传", "Step1 响应: \(http.statusCode)")
            }
            try Self.check(resp: resp, data: data)
            let decoded = try JSONDecoder().decode(AudioUploadRequestResponse.self, from: data)
            DebugLog.shared.success("上传", "Step1 成功 id=\(decoded.id.prefix(8)) url=\(decoded.url.prefix(40))")
            return decoded
        }
    }

    /// Step 2: 上传文件到 S3（使用预签名 URL + form fields）
    /// 修复 -1005：改用 CFNetwork CFReadStreamCreateForHTTPRequest 强制 HTTP/1.1 直接 POST，
    /// 从根上绕开 iOS URLSession/WKWebView 的 HTTP/2 大文件上传 -1005 bug
    /// 详见 S3Uploader.swift（Python urllib HTTP/1.1 实测能成功上传）
    func uploadFileToS3(presignedURL: String, fields: [String: String],
                        fileData: Data, fileName: String, mimeType: String) async throws {
        try await run {
            let fieldsContentType = fields["Content-Type"] ?? mimeType
            DebugLog.shared.info("S3上传", "fields=\(fields.keys.sorted()) CT=\(fieldsContentType) → CFNetwork HTTP/1.1 POST")

            let (status, body) = try await S3Uploader.shared.upload(
                presignedURL: presignedURL,
                fields: fields,
                fileData: fileData,
                mimeType: fieldsContentType
            )

            DebugLog.shared.info("S3上传", "CFNetwork响应: \(status)")
            if !(200...299).contains(status) {
                DebugLog.shared.error("S3上传", "WebView失败[\(status)]: \(body.prefix(300))")
                throw SunoError.uploadFailed("S3[\(status)]: \(body.prefix(200))")
            }
            DebugLog.shared.success("S3上传", "CFNetwork上传成功 (\(status))")
        }
    }

        /// 音频上传完整流程（Step 1 + Step 2），返回上传结果供后续 generate/cover 使用
    /// 这是新入口：替代旧的直接 multipart 到 generate 的错误方式
    func uploadAudioOnly(fileData: Data, fileName: String) async throws -> AudioUploadResult {
        // 推断文件扩展名
        let ext = (fileName as NSString).pathExtension.lowercased()
        let mimeType = mimeTypeForAudio(fileName)

        // Step 1: 获取 S3 预签名 URL
        let uploadReq = try await requestAudioUpload(fileExtension: ext.isEmpty ? "mp3" : ext)

        // Step 2: 上传文件到 S3
        try await uploadFileToS3(
            presignedURL: uploadReq.url,
            fields: uploadReq.fields,
            fileData: fileData,
            fileName: fileName,
            mimeType: mimeType
        )

        // 构造结果：audioUrl 由 id 拼接（Suno CDN 格式）
        let audioUrl = "https://cdn1.suno.ai/\(uploadReq.id).\(ext.isEmpty ? "mp3" : ext)"
        return AudioUploadResult(uploadId: uploadReq.id, audioUrl: audioUrl)
    }

    /// Step 3: 轮询上传处理状态（S3 上传成功后，Suno 后端需要时间处理音频）
    /// 返回处理完成后的状态信息（status != "processing"）
    func pollUploadStatus(uploadId: String) async throws -> AudioUploadStatus {
        try await run {
            let url = URL(string: "\(SunoAPI.base)/api/uploads/audio/\(uploadId)/")!
            let req = makeRequest(url)
            let (data, resp) = try await Self.performDataRequest(req)
            try Self.check(resp: resp, data: data)
            return try JSONDecoder().decode(AudioUploadStatus.self, from: data)
        }
    }

    /// 完整上传流程：上传到 S3 → 轮询处理状态直到完成（最长 3 分钟）
    /// 处理完成后返回 AudioUploadStatus（含真实 audio_url 和 title）
    func uploadAndWaitForProcessing(fileData: Data, fileName: String) async throws -> AudioUploadStatus {
        // Step 1+2: 上传到 S3
        let uploadResult = try await uploadAudioOnly(fileData: fileData, fileName: fileName)

        // Step 3: 轮询处理状态（每 3 秒查一次，最长 3 分钟）
        var rounds = 0
        let maxRounds = 60  // 60 × 3s = 180s = 3 分钟
        while rounds < maxRounds {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            rounds += 1
            let status = try await pollUploadStatus(uploadId: uploadResult.uploadId)
            if status.status != "processing" {
                return status  // 处理完成（成功或失败）
            }
        }
        // 超时：返回当前状态（可能仍在处理中）
        return AudioUploadStatus(id: uploadResult.uploadId, status: "processing",
                                  title: nil, audio_url: uploadResult.audioUrl, copyright_muted: nil)
    }

    /// 旧接口兼容（内部不再使用，保留避免编译报错）
    /// 实际已改为走 uploadAudioOnly → generate(audioUrl:) 的两步流程
    @available(*, deprecated, message: "Use uploadAudioOnly + generate(payload:withAudioUrl:) instead")
    func generateWithAudioData(fileData: Data, fileName: String, payload: GeneratePayload) async throws -> [SunoClipStub] {
        // 新流程：先上传，再用 audioUrl 生成
        let uploadResult = try await uploadAudioOnly(fileData: fileData, fileName: fileName)

        // 构造带 audioUrl 的 payload 并提交生成
        var audioPayload = payload
        audioPayload.generation_type = "AUDIO"
        audioPayload.prompt = uploadResult.audioUrl  // audio 模式下 prompt 传音频 URL
        return try await generate(payload: audioPayload)
    }

    /// 对文件名做 percent-encoding，确保中文名在 multipart Content-Disposition 中合法
    private func encodedFileName(_ original: String) -> String {
        // 检查是否全是可打印 ASCII（不含控制字符）；否则做 percent-encoding
        if original.allSatisfy({ $0.isASCII && !isControlChar($0) }) {
            return original
        }
        return original.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? original
    }

    /// 兼容 Swift 5.9（Xcode 15.4）的 control character 检查（Character.controlCharacter 是 5.10+ 才有）
    private func isControlChar(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first else { return false }
        return scalar.value < 32 || scalar.value == 127
    }

    /// 音频上传 + 生成一体接口（multipart/form-data）— 从文件 URL 读取（兼容旧调用）
    func generateWithAudio(fileURL: URL, payload: GeneratePayload) async throws -> [SunoClipStub] {
        let fileData = try Data(contentsOf: fileURL)
        return try await generateWithAudioData(fileData: fileData, fileName: fileURL.lastPathComponent, payload: payload)
    }

    /// 根据文件扩展名推断 MIME 类型（公开版本，供外部调用）
    func mimeTypeForAudioPublic(_ fileName: String) -> String {
        return mimeTypeForAudio(fileName)
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
            DebugLog.shared.info("生成", "POST /api/generate/v2/ task=\(payload.task ?? "?") mv=\(payload.mv)")
            let (data, resp) = try await Self.performDataRequest(req)
            if let http = resp as? HTTPURLResponse {
                DebugLog.shared.info("生成", "响应: \(http.statusCode)")
            }
            try Self.check(resp: resp, data: data)
            let decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
            DebugLog.shared.success("生成", "成功 \(decoded.clips.count) clips")
            return decoded.clips
        }
    }

    /// 按 ids 查询（用于轮询生成进度）
    func feed(ids: [String]) async throws -> [SunoClip] {
        try await run {
            var comps = URLComponents(string: "\(SunoAPI.base)/api/feed/v2")!
            comps.queryItems = [URLQueryItem(name: "ids", value: ids.joined(separator: ","))]
            let req = makeRequest(comps.url!)
            let (data, resp) = try await Self.performDataRequest(req)
            try Self.check(resp: resp, data: data)
            return Self.decodeClips(data)
        }
    }

    /// 拉取「我的音乐库」——当前账户所有歌曲（分页）
    /// 关键发现（2026-07-28 用 cookie 实测 API 确认）：
    ///   - 带 page 参数 → API 走缓存路径，返回旧数据（新创作的歌不在里面）
    ///   - 不带 page 参数 → API 返回最新数据（含刚创作的歌），current_page=0
    /// 解决方案：page=1 时不发 page 参数（拿最新），page>1 时带 page 参数（翻历史）
    func library(page: Int) async throws -> SunoFeedResponse {
        try await run {
            let safePage = max(page, 1)
            let cacheBuster = String(Int(Date().timeIntervalSince1970))
            var comps = URLComponents(string: "\(SunoAPI.base)/api/feed/v2")!
            if safePage == 1 {
                // 首页：不带 page 参数，获取最新数据（含刚创作的歌曲）
                comps.queryItems = [
                    URLQueryItem(name: "num_results", value: "50"),
                    URLQueryItem(name: "_t", value: cacheBuster)
                ]
            } else {
                // 后续页：带 page 参数，获取历史库
                comps.queryItems = [
                    URLQueryItem(name: "page", value: String(safePage)),
                    URLQueryItem(name: "num_results", value: "50"),
                    URLQueryItem(name: "_t", value: cacheBuster)
                ]
            }
            let req = makeRequest(comps.url!)
            let urlStr = comps.url!.absoluteString
            let shortUrl = String(urlStr.suffix(80))
            DebugLog.shared.info("音乐库", "GET .../\(shortUrl)")
            let (data, resp) = try await Self.performDataRequest(req)
            if let http = resp as? HTTPURLResponse {
                DebugLog.shared.info("音乐库", "page=\(safePage) 响应: \(http.statusCode) \(data.count)B")
            }
            try Self.check(resp: resp, data: data)
            if let wrapped = try? JSONDecoder().decode(SunoFeedResponse.self, from: data) {
                let titles = wrapped.clips.prefix(3).compactMap { "[\($0.title ?? "?") \($0.created_at ?? "")]" }.joined(separator: ", ")
                DebugLog.shared.info("音乐库", "page=\(safePage) clips=\(wrapped.clips.count) has_more=\(wrapped.has_more ?? false) num_total=\(wrapped.num_total_results ?? -1) top3=\(titles)")
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
            let (data, resp) = try await Self.performDataRequest(req)
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
            let (data, resp) = try await Self.performDataRequest(req)
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
        if http.statusCode == 401 {
            throw SunoError.authExpired
        }
        if http.statusCode == 403 {
            let msg = String(data: data, encoding: .utf8) ?? ""
            DebugLog.shared.error("API", "403: \(msg.prefix(200))")
            // 区分"登录过期"和"模型权限不足"
            if msg.contains("don't have access") || msg.contains("Upgrade your plan") {
                throw SunoError.http(403, msg)  // 模型权限不足，不是登录问题
            }
            throw SunoError.authExpired  // 其他 403 视为登录过期
        }
        if http.statusCode == 422 {
            let msg = String(data: data, encoding: .utf8) ?? ""
            DebugLog.shared.error("API", "422: \(msg.prefix(200))")
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
