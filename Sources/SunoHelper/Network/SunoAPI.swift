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
    let audio_url: String?       // 处理完成后可能返回真实 CDN URL（部分接口直接给）
    let s3_id: String? = nil    // 处理完成后 Suno 分配的 clip/s3 id（initialize-clip 的上游）
    let image_url: String? = nil // 处理完成后封面图（set_metadata 时用）
    let copyright_muted: Bool?
}

/// Suno 网页内部 API 客户端（cookie 认证，非官方但免费账户可用）
struct SunoAPI {
    static let base = "https://studio-api.prod.suno.com"
    static let shared = SunoAPI()

    // 对齐 SunoTools backend.py browser_token()：{"token": base64({"timestamp": <毫秒>})}
    // 服务端鉴权强依赖此头，缺失会导致上传接口拒收 / 音频不注册（之前 iOS 版一直没带 → 上传"看不见"）。
    static func browserToken() -> String {
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let inner = "{\"timestamp\":\(ts)}".data(using: .utf8) ?? Data()
        let b64 = inner.base64EncodedString()
        return "{\"token\":\"\(b64)\"}"
    }

    // Device-Id（可选，对齐 SunoTools 的 ajs_anonymous_id；clean_device_id 后仅保留字母数字-）
    static func deviceId() -> String? {
        UIDevice.current.identifierForVendor?.uuidString
    }

    private func makeRequest(_ url: URL, method: String = "GET",
                             body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://suno.com/", forHTTPHeaderField: "Referer")
        req.setValue("https://suno.com", forHTTPHeaderField: "Origin")
        // 关键：每个 Suno API 请求都带 Browser-Token
        req.setValue(SunoAPI.browserToken(), forHTTPHeaderField: "Browser-Token")
        if let did = SunoAPI.deviceId(), !did.isEmpty {
            req.setValue(did, forHTTPHeaderField: "Device-Id")
        }
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
            req.setValue(SunoAPI.browserToken(), forHTTPHeaderField: "Browser-Token")
            if let did = SunoAPI.deviceId(), !did.isEmpty {
                req.setValue(did, forHTTPHeaderField: "Device-Id")
            }
            for (k, v) in SunoSession.shared.authHeaders() {
                req.setValue(v, forHTTPHeaderField: k)
            }
            // ⚠️ 关键：必须带 upload_type: studio_file_upload（对齐 SunoTools 真实逻辑）。
            // 缺此字段或写成 file_upload 会导致 Suno 不认该上传，后续 initialize-clip 拿不到 clipId。
            let body = try JSONEncoder().encode([
                "extension": fileExtension,
                "upload_type": "studio_file_upload"
            ])
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

    /// Step 2.5: 报告上传完毕（通知 Suno 服务器 S3 文件已上传完成，开始处理音频）
    /// 对应 SunoTools backend.py：POST /api/uploads/audio/{id}/upload-finish/ {upload_type, upload_filename}
    /// 对齐 SunoTools：单次发送即可（client.api 仅对连接级错误自动重试），
    /// 不臆测「-1005 已处理」去做轮询补发——那会引入重复处理风险。
    func confirmUploadFinish(uploadId: String, fileName: String) async throws {
        try await performUploadFinishOnce(uploadId: uploadId, fileName: fileName)
        DebugLog.shared.success("上传", "upload-finish 成功（Suno 开始处理音频）")
    }

    /// 单次发送 upload-finish（不重试）。失败由 confirmUploadFinish 统一做安全校验。
    private func performUploadFinishOnce(uploadId: String, fileName: String) async throws {
        let url = URL(string: "\(SunoAPI.base)/api/uploads/audio/\(uploadId)/upload-finish")!
        var req = makeRequest(url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = try JSONEncoder().encode([
            "upload_type": "studio_file_upload",
            "upload_filename": fileName
        ])
        req.httpBody = body
        DebugLog.shared.info("上传", "Step2.5 POST /upload-finish id=\(uploadId.prefix(8)) file=\(fileName)")
        let (data, resp) = try await Self.performDataRequest(req, maxAttempts: 1)
        if let http = resp as? HTTPURLResponse {
            DebugLog.shared.info("上传", "upload-finish 响应: \(http.statusCode)")
        }
        try Self.check(resp: resp, data: data)
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

        // 废弃接口：真实可播放地址应通过 uploadAndGetPlayableURL 取得，
        // 此处不拼假地址（cdn1.suno.ai/{id}.mp3 是无效地址，必然静音），返回空字符串
        let audioUrl = ""
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

    // MARK: - 上传后注册为可播放 Clip（关键：拿到真实 audio_url）

    /// 完整上传结果：uploadId（素材引用 ID，用于 AUDIO 生成）、clipId（Suno 歌曲 ID）、
    /// audioUrl（**真实的** Suno CDN 播放地址，由 initialize-clip + feed/v3 取得，绝非手拼）。
    struct UploadedAudioResult {
        let uploadId: String
        let clipId: String
        let audioUrl: String
    }

    /// Step 4：把已处理完成的音频「初始化为 clip」，Suno 会返回 clip_id。
    /// 对应 SunoTools backend.py：POST /api/uploads/audio/{id}/initialize-clip/ {}
    /// 这是拿到可播放歌曲 ID 的唯一入口——不上这步，上传的音频永远只是「素材」，
    /// 既不会出现在音乐库，也取不到真实 audio_url。
    private func initializeClip(uploadId: String) async throws -> String {
        try await run {
            let url = URL(string: "\(SunoAPI.base)/api/uploads/audio/\(uploadId)/initialize-clip/")!
            var req = makeRequest(url, method: "POST")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode([String: String]())
            DebugLog.shared.info("上传", "Step4 POST /initialize-clip id=\(uploadId.prefix(8))")
            let (data, resp) = try await Self.performDataRequest(req)
            try Self.check(resp: resp, data: data)
            // 诊断：打印原始响应，定位真实字段名
            let raw = String(data: data, encoding: .utf8) ?? "<二进制响应>"
            DebugLog.shared.info("上传", "initialize-clip 原始响应: \(raw.prefix(500))")
            // 宽松解析：兼容 clip_id / id / clipId / song_id 多种命名
            struct Flat: Decodable {
                let clip_id: String?
                let id: String?
                let clipId: String?
                let song_id: String?
            }
            let f = try? JSONDecoder().decode(Flat.self, from: data)
            let clipId = f?.clip_id ?? f?.id ?? f?.clipId ?? f?.song_id
            DebugLog.shared.success("上传", "initialize-clip 解析到 clipId=\(clipId?.prefix(8) ?? "<空>")")
            guard let cid = clipId else {
                throw SunoError.uploadFailed("initialize-clip 未返回 clipId（响应: \(raw.prefix(200))）")
            }
            return cid
        }
    }

    /// Step 5：通过 feed/v3 拉取该 clip 的真实可播放地址（audio_url）。
    /// 对应 SunoTools backend.py：POST /api/feed/v3 {filters:{ids:{presence:"True",clipIds:[clipId]}},limit:1}
    /// 优先 audio_url；其次 media_urls[].url（对齐 SunoTools fetch_clip_by_id 的兜底）。
    /// 供「已上传」列表的「刷新地址」按钮复用，故为 internal。
    func fetchClipAudioURL(clipId: String) async throws -> String {
        try await run {
            let url = URL(string: "\(SunoAPI.base)/api/feed/v3")!
            var req = makeRequest(url, method: "POST")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = [
                "filters": ["ids": ["presence": "True", "clipIds": [clipId]]],
                "limit": 1
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            DebugLog.shared.info("上传", "Step5 POST /feed/v3 取 audio_url clipId=\(clipId.prefix(8))")
            let (data, resp) = try await Self.performDataRequest(req)
            try Self.check(resp: resp, data: data)

            // 优先 audio_url；其次 media_urls[].url
            if let loose = try? JSONDecoder().decode(FeedClipLoose.self, from: data),
               let first = loose.clips.first {
                if let u = first.audio_url, !u.isEmpty {
                    DebugLog.shared.success("上传", "feed/v3 取到 audio_url=\(u.prefix(40))")
                    return u
                }
                if let u = first.media_urls?.first?.url, !u.isEmpty {
                    DebugLog.shared.success("上传", "feed/v3 取到 media_urls[0].url=\(u.prefix(40))")
                    return u
                }
            }
            if let wrapped = try? JSONDecoder().decode(SunoFeedResponse.self, from: data),
               let u = wrapped.clips.first?.audio_url, !u.isEmpty {
                DebugLog.shared.success("上传", "feed/v3 取到 audio_url=\(u.prefix(40))")
                return u
            }
            throw SunoError.uploadFailed("feed/v3 未返回 audio_url")
        }
    }

    /// feed/v3 松散解析（仅取播放地址相关字段，兼容 media_urls 兜底）
    private struct FeedClipLoose: Decodable {
        let clips: [ClipAudioLoose]
        struct ClipAudioLoose: Decodable {
            let audio_url: String?
            let media_urls: [MediaURLLoose]?
        }
        struct MediaURLLoose: Decodable {
            let url: String?
        }
    }

    /// 对齐 SunoTools backend.py：initialize-clip 后用 set_metadata 激活 clip
    /// （接受音频上传 TOS is_audio_upload_tos_accepted=true），让 clip 真正可播放、能进「音乐库」。
    /// 失败不影响主流程（仅警告），与 SunoTools「初始化跳过」的容错行为一致。
    private func setClipMetadata(clipId: String, title: String, imageUrl: String?) async {
        let url = URL(string: "\(SunoAPI.base)/api/gen/\(clipId)/set_metadata/")!
        var req = makeRequest(url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "title": title,
            "image_url": imageUrl ?? NSNull(),
            "is_audio_upload_tos_accepted": true
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            _ = try await Self.performDataRequest(req)
            DebugLog.shared.info("上传", "set_metadata 成功 clipId=\(clipId.prefix(8))")
        } catch {
            DebugLog.shared.info("上传", "set_metadata 失败（忽略）：\(error.localizedDescription)")
        }
    }

    // MARK: - 上传流程拆分：beginUpload（阻塞仅几秒）/ resolve（后台解析，可能十几分钟）

    /// Step 1-3：init(studio_file_upload) → S3 → upload-finish。
    /// 成功后 Suno 开始处理音频，返回 uploadId。任何一步失败都会抛出（真实错误：网络/凭证）。
    func beginUpload(fileData: Data, fileName: String) async throws -> String {
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
        return uploadReq.id
    }

    /// Step 4-5（容错、绝不硬抛 404）：轮询 → initialize-clip → set_metadata → feed/v3 取真实 audio_url。
    /// 任意环节失败都返回「部分结果」（url/clipId 可能为空），交由 UI「刷新地址」补救。
    /// 轮询中 Suno 返回 404（记录已清理 = 处理完或彻底失败）视为可跳出，绝不让 404 穿透上层。
    func resolveUploadedAudioURL(uploadId: String, fileName: String) async -> UploadedAudioResult {
        // 轮询处理状态（每 3 秒，最长 ~10 分钟）
        // ⚠️ 对齐 SunoTools backend.py：轮询时 404 / 异常都视为「记录尚未就绪」，继续重试，绝不跳出。
        // 之前 iOS 版把 404 当作「处理完」直接 break → 立刻对未就绪的上传调 initialize-clip → 失败 → clipId 空 → 只能播本地。
        var s3id: String?
        var lastStatus: AudioUploadStatus?
        var reachedComplete = false
        for i in 0..<200 {
            do {
                let st = try await pollUploadStatus(uploadId: uploadId)
                lastStatus = st
                s3id = st.s3_id
                if st.status == "complete", let sid = st.s3_id, !sid.isEmpty {
                    reachedComplete = true
                    break
                }
                if let s = st.status, ["error", "failed", "rejected", "blocked"].contains(s) {
                    DebugLog.shared.error("上传", "音频处理失败(status=\(s))")
                    break
                }
            } catch let SunoError.http(404, _) {
                // SunoTools：404 表示 Suno 还没建好该上传的状态记录 → 继续等
                DebugLog.shared.info("上传", "轮询 404（记录尚未就绪），继续重试 (\(i))")
            } catch {
                DebugLog.shared.info("上传", "轮询瞬时错误，继续重试：\(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        if !reachedComplete {
            DebugLog.shared.info("上传", "轮询未确认 complete（可能 Suno 仍在处理），仍前往 initialize-clip 兜底")
        }

        // Step 4：initialize-clip（容错：失败用 s3_id 兜底，再不行就留空由刷新补救）
        var clipId = ""
        if let cid = try? await initializeClip(uploadId: uploadId) {
            clipId = cid
        } else if let sid = s3id, !sid.isEmpty {
            clipId = sid
        }

        // 对齐 SunoTools：initialize-clip 后调 set_metadata 激活 clip（不阻塞主流程）
        if !clipId.isEmpty {
            await setClipMetadata(clipId: clipId, title: (fileName as NSString).deletingPathExtension, imageUrl: lastStatus?.image_url)
        }

        // Step 5：取真实 audio_url（来自 feed/v3 的 audio_url 字段，即 Suno CDN 直链）
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
        // 兜底：用 clipId(uuid) 拼 Suno CDN 直链（修正此前用 upload_id 短 id 拼的致命错误；
        // feed/v3 取不到时，uuid 直链通常可用）
        if audioUrl.isEmpty, !clipId.isEmpty {
            audioUrl = "https://cdn1.suno.ai/\(clipId).mp3"
            DebugLog.shared.info("上传", "feed 未取到 audio_url，用 clipId 兜底拼 cdn1.suno.ai/\(clipId.prefix(8)).mp3")
        }
        if audioUrl.isEmpty { audioUrl = lastStatus?.audio_url ?? "" }
        DebugLog.shared.info("上传", "resolve 完成：clipId=\(clipId.prefix(8)) url=\(audioUrl.prefix(20))")
        return UploadedAudioResult(uploadId: uploadId, clipId: clipId, audioUrl: audioUrl)
    }

    /// 「已上传」页「刷新地址」复用：优先用已存 clipId 直接查 feed/v3（不重复 initialize-clip，避免重复创建 clip）；
    /// 若 clipId 为空则走完整 resolve（含 poll→initialize→feed）。
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

    /// 完整上传 + 注册流程（兼容入口）：beginUpload → resolveUploadedAudioURL。
    /// 仅 Step 1-3 会抛出真实错误；resolve 阶段永不硬抛 404，返回部分结果。
    func uploadAndGetPlayableURL(fileData: Data, fileName: String,
                                 progress: ((String) -> Void)? = nil) async throws -> UploadedAudioResult {
        progress?("① 申请上传凭证…")
        let uploadId = try await beginUpload(fileData: fileData, fileName: fileName)
        progress?("④ 等待 Suno 处理并注册为可播放歌曲…")
        return await resolveUploadedAudioURL(uploadId: uploadId, fileName: fileName)
    }

    /// 完整上传流程：上传到 S3 → 轮询处理状态直到完成（最长 3 分钟）
    /// 处理完成后返回 AudioUploadStatus（含真实 audio_url 和 title）
    func uploadAndWaitForProcessing(fileData: Data, fileName: String) async throws -> AudioUploadStatus {
        // Step 1+2: 上传到 S3
        let uploadResult = try await uploadAudioOnly(fileData: fileData, fileName: fileName)

        // Step 3: 轮询处理状态（每 3 秒查一次，最长 3 分钟）
        var rounds = 0
        let maxRounds = 200  // 200 × 3s ≈ 10 分钟（免费版负载高时处理可能超过 3 分钟）
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
