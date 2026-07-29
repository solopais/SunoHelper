import Foundation
import UIKit

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
    let audio_url: String?       // 处理完成后可能返回真实 CDN URL（部分接口直接给）
    let s3_id: String?           // 处理完成后 Suno 分配的 clip/s3 id（initialize-clip 的上游）
    let image_url: String?       // 处理完成后封面图（set_metadata 时用）
    let copyright_muted: Bool?
}

/// 完整上传结果：uploadId（素材引用 ID）、clipId（Suno 歌曲 ID）、
/// audioUrl（真实的 Suno CDN 播放地址，由 initialize-clip + feed/v3 取得）
struct UploadedAudioResult {
    let uploadId: String
    let clipId: String
    let audioUrl: String
}

/// Suno 网页内部 API 客户端（Bearer token 认证，1:1 移植 SunoTools backend.py 的 SunoClient）
struct SunoAPI {
    // ⚠️ 1:1 对齐 SunoTools：API = "https://studio-api-prod.suno.com"
    static let base = "https://studio-api-prod.suno.com"
    static let shared = SunoAPI()

    // 对齐 SunoTools backend.py browser_token()：
    //   inner = json.dumps({"timestamp": <毫秒>})
    //   return json.dumps({"token": base64(inner)})
    // 服务端鉴权强依赖此头，缺失会导致上传接口拒收 / 音频不注册。
    static func browserToken() -> String {
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        // ⚠️ 1:1 对齐 backend.py browser_token()：json.dumps 默认 separators=(", ", ": ")，
        // 内层为 {"timestamp": 123...}（冒号后含空格），外层为 {"token": "xxx"}（含空格）。
        // 之前漏掉空格导致 base64 内容与 PC 版不一致，Upload 接口可能被拒收。
        let inner = "{\"timestamp\": \(ts)}".data(using: .utf8) ?? Data()
        let b64 = inner.base64EncodedString()
        return "{\"token\": \"\(b64)\"}"
    }

    // Device-Id（对齐 SunoTools 的 device_id；clean_device_id 后仅保留字母数字-）
    static func deviceId() -> String? {
        UIDevice.current.identifierForVendor?.uuidString
    }

    // MARK: - 1:1 请求头（对齐 SunoClient.headers()）
    private func makeRequest(_ url: URL, method: String = "GET",
                             body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("https://suno.com", forHTTPHeaderField: "Origin")
        req.setValue("https://suno.com/studio", forHTTPHeaderField: "Referer")
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        // Browser-Token：每个 Suno API 请求都带
        req.setValue(SunoAPI.browserToken(), forHTTPHeaderField: "Browser-Token")
        // Authorization: Bearer <__session>（SunoTools 仅用 Bearer，不发送原始 Cookie）
        if let t = SunoSession.shared.token {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        if let did = SunoAPI.deviceId(), !did.isEmpty {
            req.setValue(did, forHTTPHeaderField: "Device-Id")
        }
        // Chrome UA（SunoTools 用 Windows Chrome/136，缺 UA 会导致接口异常）
        req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36",
                     forHTTPHeaderField: "User-Agent")
        if body != nil {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        req.httpBody = body
        req.timeoutInterval = 90
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

    /// 网络请求重试封装：对"请求未到达服务器"的瞬时连接错误自动重试。
    private static func performDataRequest(_ req: URLRequest, maxAttempts: Int = 3) async throws -> (Data, URLResponse) {
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
                    let backoff: UInt64 = attempt == 1 ? 1_000_000_000 : 2_000_000_000
                    try? await Task.sleep(nanoseconds: backoff)
                    lastError = error
                    continue
                }
                throw error
            }
        }
        throw lastError ?? SunoError.network(NSError(domain: "suno.retry", code: -1))
    }

    // MARK: - 1:1 api()：对齐 SunoClient.api() 语义
    // 非 2xx 直接抛错（轮询调用方自行 catch 重试）；429/5xx 内部重试；
    // 传输层错误重试。返回 [String:Any] / [[String:Any]] / nil。
    private func api(_ method: String, _ path: String, body: [String: Any]? = nil,
                     timeout: TimeInterval = 90, maxAttempts: Int = 10) async throws -> Any? {
        for attempt in 0..<maxAttempts {
            do {
                let url = URL(string: "\(SunoAPI.base)\(path)")!
                var reqBody: Data?
                if let b = body {
                    reqBody = try JSONSerialization.data(withJSONObject: b)
                }
                var req = makeRequest(url, method: method, body: reqBody)
                req.timeoutInterval = timeout
                let (data, resp) = try await Self.performDataRequest(req, maxAttempts: 1)
                guard let http = resp as? HTTPURLResponse else {
                    throw SunoError.network(NSError(domain: "suno.no-http", code: -1))
                }
                if http.statusCode == 429 {
                    let wait = min(45.0, 2.0 + Double(attempt) * 4.0)
                    DebugLog.shared.info("API", "限流 429，等待 \(Int(wait))s 重试")
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    continue
                }
                if http.statusCode >= 500 && attempt < 4 {
                    let wait = min(30.0, 3.0 + Double(attempt) * 3.0)
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    continue
                }
                if !(200...299).contains(http.statusCode) {
                    let msg = String(data: data, encoding: .utf8) ?? ""
                    throw SunoError.http(http.statusCode, msg)
                }
                if data.isEmpty { return nil }
                return try? JSONSerialization.jsonObject(with: data)
            } catch let e as SunoError {
                throw e
            } catch {
                if attempt == maxAttempts - 1 { throw SunoError.network(error) }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        throw SunoError.uploadFailed("API 重试耗尽")
    }

// MARK: - 音频上传（S3 两步流程，1:1 移植 SunoTools upload_one / try_direct_whole_upload）

    /// Step 1: 请求 S3 预签名上传 URL（对齐 init_audio_upload）
    /// POST /api/uploads/audio/ {extension, upload_type: studio_file_upload}
    func requestAudioUpload(fileExtension: String) async throws -> AudioUploadRequestResponse {
        let body: [String: Any] = [
            "extension": fileExtension.isEmpty ? "mp3" : fileExtension,
            "upload_type": "studio_file_upload"
        ]
        let resp = try await api("POST", "/api/uploads/audio/", body: body) as? [String: Any]
        guard let resp,
              let id = resp["id"] as? String,
              let url = resp["url"] as? String else {
            throw SunoError.uploadFailed("init 响应缺少 id/url：\(resp ?? [:])")
        }
        // fields 可能为非字符串值，统一 stringify（对齐 requests 表单序列化）
        let rawFields = resp["fields"] as? [String: Any] ?? [:]
        var fields: [String: String] = [:]
        for (k, v) in rawFields { fields[k] = "\(v)" }
        DebugLog.shared.success("上传", "Step1 init 成功 id=\(id.prefix(8)) fields=\(fields.keys.sorted().joined(separator: ","))")
        return AudioUploadRequestResponse(id: id, url: url, fields: fields)
    }

    /// Step 2: 上传文件到 S3（multipart/form-data，真实文件名；对齐 s3_upload）
    /// 失败重试 4 次（对齐 SunoTools upload_one 的 4 attempts + backoff）
    func uploadFileToS3(presignedURL: String, fields: [String: String],
                        fileData: Data, fileName: String, mimeType: String) async throws {
        var lastErr: Error?
        for attempt in 0..<4 {
            do {
                let (status, bodyStr) = try await S3Uploader.shared.upload(
                    presignedURL: presignedURL,
                    fields: fields,
                    fileData: fileData,
                    fileName: fileName,
                    mimeType: mimeType
                )
                if (200...299).contains(status) {
                    DebugLog.shared.success("S3上传", "成功 (\(status))")
                    return
                }
                lastErr = SunoError.uploadFailed("S3[\(status)]: \(bodyStr.prefix(200))")
            } catch {
                lastErr = error
            }
            if attempt < 3 {
                let wait = min(45.0, 4.0 + Double(attempt) * 6.0)
                DebugLog.shared.info("S3上传", "重试 \(attempt + 1)（\(lastErr?.localizedDescription.prefix(120) ?? "")），等 \(Int(wait))s")
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        throw lastErr ?? SunoError.uploadFailed("S3 上传失败")
    }

    /// Step 2.5: 报告上传完毕（对齐 upload_one 的 upload-finish，单次发送，client.api 仅对连接错误重试）
    func confirmUploadFinish(uploadId: String, fileName: String) async throws {
        // ⚠️ 1:1 对齐 backend.py：upload-finish body 仅 {"upload_type":"studio_file_upload"}，
        // 不带 upload_filename（多余字段可能让 Suno 校验拒绝，使音频永远 processing）
        _ = try await api("POST", "/api/uploads/audio/\(uploadId)/upload-finish/",
                          body: ["upload_type": "studio_file_upload"])
        DebugLog.shared.success("上传", "upload-finish 成功（Suno 开始处理音频）")
    }

    /// Step 3: 轮询上传处理状态（对齐 upload_one 轮询：非 complete 时遇错继续重试，不跳出）
    func pollUploadStatus(uploadId: String) async throws -> AudioUploadStatus {
        let resp = try await api("GET", "/api/uploads/audio/\(uploadId)/") as? [String: Any]
        let id = (resp?["id"] as? String) ?? uploadId
        let status = resp?["status"] as? String
        let s3id = resp?["s3_id"] as? String
        let image = resp?["image_url"] as? String
        let title = resp?["title"] as? String
        return AudioUploadStatus(id: id, status: status, title: title,
                                 audio_url: nil, s3_id: s3id, image_url: image,
                                 copyright_muted: nil)
    }

    /// Step 4: initialize-clip（对齐 upload_one：拿到 clip_id；失败则由调用方用 s3_id 兜底）
    private func initializeClip(uploadId: String) async throws -> String {
        let resp = try await api("POST", "/api/uploads/audio/\(uploadId)/initialize-clip/", body: [:]) as? [String: Any]
        let clipId = resp?["clip_id"] as? String
            ?? resp?["id"] as? String
            ?? resp?["clipId"] as? String
            ?? resp?["song_id"] as? String
        DebugLog.shared.info("上传", "initialize-clip 响应: \(resp ?? [:])")
        guard let cid = clipId, !cid.isEmpty else {
            throw SunoError.uploadFailed("initialize-clip 未返回 clipId：\(resp ?? [:])")
        }
        DebugLog.shared.success("上传", "initialize-clip 解析到 clipId=\(cid.prefix(8))")
        return cid
    }

    /// Step 5: feed/v3 取真实可播放地址（对齐 fetch_clip_by_id：audio_url 优先，media_urls[].url 兜底）
    func fetchClipAudioURL(clipId: String) async throws -> String {
        for _ in 0..<24 {
            do {
                let feed = try await api("POST", "/api/feed/v3",
                    body: ["filters": ["ids": ["presence": "True", "clipIds": [clipId]]], "limit": 1]) as? [String: Any]
                let clips = (feed?["clips"] as? [[String: Any]]) ?? []
                if let clip = clips.first {
                    if let u = clip["audio_url"] as? String, !u.isEmpty {
                        DebugLog.shared.success("上传", "feed/v3 取到 audio_url=\(u.prefix(40))")
                        return u
                    }
                    if let media = clip["media_urls"] as? [[String: Any]],
                       let u = media.first?["url"] as? String, !u.isEmpty {
                        DebugLog.shared.success("上传", "feed/v3 取到 media_urls[0].url=\(u.prefix(40))")
                        return u
                    }
                }
            } catch {
                DebugLog.shared.info("上传", "feed/v3 取直链瞬时错误：\(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw SunoError.uploadFailed("feed/v3 未返回 audio_url")
    }

    /// initialize-clip 后用 set_metadata 激活 clip（对齐 upload_one：best-effort，失败忽略）
    private func setClipMetadata(clipId: String, title: String, imageUrl: String?) async {
        _ = try? await api("POST", "/api/gen/\(clipId)/set_metadata/",
            body: ["title": title, "image_url": imageUrl ?? "", "is_audio_upload_tos_accepted": true])
        DebugLog.shared.info("上传", "set_metadata 完成 clipId=\(clipId.prefix(8))")
    }

    // MARK: - 上传流程拆分：beginUpload（阻塞仅几秒）/ resolve（后台解析）

    /// Step 1-3：init(studio_file_upload) → S3 → upload-finish。返回 uploadId。
    func beginUpload(fileData: Data, fileName: String) async throws -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let mimeType = mimeTypeForAudio(fileName)
        let uploadReq = try await requestAudioUpload(fileExtension: ext)
        try await uploadFileToS3(
            presignedURL: uploadReq.url,
            fields: uploadReq.fields,
            fileData: fileData,
            fileName: fileName,
            mimeType: mimeType
        )
        try await confirmUploadFinish(uploadId: uploadReq.id, fileName: fileName)
        return uploadReq.id
    }

    /// Step 4-5（容错）：轮询 → initialize-clip → set_metadata → feed/v3 取真实 audio_url。
    /// 对齐 SunoTools：轮询遇 404/异常继续重试；clipId 优先 initialize-clip，回退 s3_id；
    /// 直链优先 feed/v3，回退 https://suno.com/song/{clipId} 不由本方法拼（交给 UI 用真实 url）。
    func resolveUploadedAudioURL(uploadId: String, fileName: String) async -> UploadedAudioResult {
        var s3id: String?
        var lastStatus: AudioUploadStatus?
        var reachedComplete = false
        for i in 0..<150 {
            do {
                let st = try await pollUploadStatus(uploadId: uploadId)
                lastStatus = st
                s3id = st.s3_id
                if let sid = st.s3_id, !sid.isEmpty, st.status == "complete" {
                    reachedComplete = true
                    break
                }
                if let s = st.status, ["error", "failed", "rejected", "blocked"].contains(s) {
                    DebugLog.shared.error("上传", "音频处理失败(status=\(s))")
                    break
                }
            } catch {
                DebugLog.shared.info("上传", "轮询瞬时错误，继续重试(\(i))：\(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: 2_400_000_000)
        }
        if !reachedComplete {
            DebugLog.shared.info("上传", "轮询未确认 complete，仍前往 initialize-clip 兜底")
        }

        var clipId = ""
        if let cid = try? await initializeClip(uploadId: uploadId) {
            clipId = cid
        } else if let sid = s3id, !sid.isEmpty {
            clipId = sid
        }

        if !clipId.isEmpty {
            await setClipMetadata(clipId: clipId,
                                  title: (fileName as NSString).deletingPathExtension,
                                  imageUrl: lastStatus?.image_url)
        }

        var audioUrl = ""
        if !clipId.isEmpty {
            for _ in 0..<24 {
                if let u = try? await fetchClipAudioURL(clipId: clipId), !u.isEmpty {
                    audioUrl = u
                    break
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        if audioUrl.isEmpty { audioUrl = lastStatus?.audio_url ?? "" }
        DebugLog.shared.info("上传", "resolve 完成：clipId=\(clipId.prefix(8)) url=\(audioUrl.prefix(20))")
        return UploadedAudioResult(uploadId: uploadId, clipId: clipId, audioUrl: audioUrl)
    }

    /// 「已上传」页「刷新地址」复用：优先用已存 clipId 直接查 feed/v3（不重复 initialize-clip）
    func fetchPlayableURLByUploadId(uploadId: String, clipId existingClipId: String, fileName: String) async -> (clipId: String, audioUrl: String) {
        if !existingClipId.isEmpty {
            var audioUrl = ""
            for _ in 0..<24 {
                if let u = try? await fetchClipAudioURL(clipId: existingClipId), !u.isEmpty {
                    audioUrl = u
                    break
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            if audioUrl.isEmpty { audioUrl = "https://cdn1.suno.ai/\(existingClipId).mp3" }
            return (existingClipId, audioUrl)
        }
        let r = await resolveUploadedAudioURL(uploadId: uploadId, fileName: fileName)
        return (r.clipId, r.audioUrl)
    }

    /// 完整上传 + 注册流程（兼容入口）
    func uploadAndGetPlayableURL(fileData: Data, fileName: String,
                                 progress: ((String) -> Void)? = nil) async throws -> UploadedAudioResult {
        progress?("① 申请上传凭证…")
        let uploadId = try await beginUpload(fileData: fileData, fileName: fileName)
        progress?("④ 等待 Suno 处理并注册为可播放歌曲…")
        return await resolveUploadedAudioURL(uploadId: uploadId, fileName: fileName)
    }

    /// 完整上传流程：上传到 S3 → 轮询处理状态直到完成
    func uploadAndWaitForProcessing(fileData: Data, fileName: String) async throws -> AudioUploadStatus {
        let uploadResult = try await uploadAudioOnly(fileData: fileData, fileName: fileName)
        var rounds = 0
        let maxRounds = 200
        while rounds < maxRounds {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            rounds += 1
            let status = try await pollUploadStatus(uploadId: uploadResult.uploadId)
            if status.status != "processing" {
                return status
            }
        }
        return AudioUploadStatus(id: uploadResult.uploadId, status: "processing",
                                  title: nil, audio_url: uploadResult.audioUrl,
                                  s3_id: nil, image_url: nil, copyright_muted: nil)
    }

    /// 旧接口兼容（内部不再使用）
    @available(*, deprecated, message: "Use uploadAudioOnly + generate(payload:withAudioUrl:) instead")
    func generateWithAudioData(fileData: Data, fileName: String, payload: GeneratePayload) async throws -> [SunoClipStub] {
        let uploadResult = try await uploadAudioOnly(fileData: fileData, fileName: fileName)
        var audioPayload = payload
        audioPayload.generation_type = "AUDIO"
        audioPayload.prompt = uploadResult.audioUrl
        return try await generate(payload: audioPayload)
    }

    func generateWithAudio(fileURL: URL, payload: GeneratePayload) async throws -> [SunoClipStub] {
        let fileData = try Data(contentsOf: fileURL)
        return try await generateWithAudioData(fileData: fileData, fileName: fileURL.lastPathComponent, payload: payload)
    }

    /// 根据文件扩展名推断 MIME 类型
    func mimeTypeForAudioPublic(_ fileName: String) -> String {
        return mimeTypeForAudio(fileName)
    }

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

    /// 旧接口：仅上传到 S3（用于 AUDIO 生成流程），不取可播放直链
    func uploadAudioOnly(fileData: Data, fileName: String) async throws -> AudioUploadResult {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let mimeType = mimeTypeForAudio(fileName)
        let uploadReq = try await requestAudioUpload(fileExtension: ext.isEmpty ? "mp3" : ext)
        try await uploadFileToS3(
            presignedURL: uploadReq.url,
            fields: uploadReq.fields,
            fileData: fileData,
            fileName: fileName,
            mimeType: mimeType
        )
        try await confirmUploadFinish(uploadId: uploadReq.id, fileName: fileName)
        return AudioUploadResult(uploadId: uploadReq.id, audioUrl: "")
    }

    // MARK: - 生成 / 音乐库 / 额度（保持原有可用逻辑，走 1:1 请求头）

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
    func library(page: Int) async throws -> SunoFeedResponse {
        try await run {
            let safePage = max(page, 1)
            let cacheBuster = String(Int(Date().timeIntervalSince1970))
            var comps = URLComponents(string: "\(SunoAPI.base)/api/feed/v2")!
            if safePage == 1 {
                comps.queryItems = [
                    URLQueryItem(name: "num_results", value: "50"),
                    URLQueryItem(name: "_t", value: cacheBuster)
                ]
            } else {
                comps.queryItems = [
                    URLQueryItem(name: "page", value: String(safePage)),
                    URLQueryItem(name: "num_results", value: "50"),
                    URLQueryItem(name: "_t", value: cacheBuster)
                ]
            }
            let req = makeRequest(comps.url!)
            let (data, resp) = try await Self.performDataRequest(req)
            if let http = resp as? HTTPURLResponse {
                DebugLog.shared.info("音乐库", "page=\(safePage) 响应: \(http.statusCode) \(data.count)B")
            }
            try Self.check(resp: resp, data: data)
            if let wrapped = try? JSONDecoder().decode(SunoFeedResponse.self, from: data) {
                let titles = wrapped.clips.prefix(3).compactMap { "[\($0.title ?? "?") \($0.created_at ?? "")]" }.joined(separator: ", ")
                DebugLog.shared.info("音乐库", "page=\(safePage) clips=\(wrapped.clips.count) has_more=\(wrapped.has_more ?? false) top3=\(titles)")
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

    func billing() async throws -> BillingInfo {
        try await run {
            let url = URL(string: "\(SunoAPI.base)/api/billing/info/")!
            let req = makeRequest(url)
            let (data, resp) = try await Self.performDataRequest(req)
            try Self.check(resp: resp, data: data)
            return try JSONDecoder().decode(BillingInfo.self, from: data)
        }
    }

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
            if msg.contains("don't have access") || msg.contains("Upgrade your plan") {
                throw SunoError.http(403, msg)
            }
            throw SunoError.authExpired
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
