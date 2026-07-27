import Foundation
import CFNetwork

/// S3 文件上传 — 使用 CFNetwork HTTP/1.1 直接 POST
///
/// 为什么不用 URLSession / WKWebView：
/// - URLSession 在 iOS 上强制走 HTTP/2，向 S3 上传大文件（> 几 MB）时会偶发
///   NSURLErrorNetworkConnectionLost（-1005），所有 session 配置（default/ephemeral/
///   shared）和 data/upload 两种方式均失败（v7 实测）。
/// - WKWebView.load(URLRequest) POST 的底层 NetworkProcess 同样走 HTTP/2，v12 实测也 -1005
///   （didFailProvisionalNavigation: The network connection was lost）。
/// - Python urllib（HTTP/1.1）实测可成功上传到同一 S3 预签名 URL（204）。
///
/// 因此本实现直接用 CFNetwork 的 CFReadStreamCreateForHTTPRequest 发起 HTTP/1.1 请求。
/// CFNetwork 的 CFHTTP 层只支持 HTTP/1.0 / 1.1，绝不会协商 HTTP/2，从根上绕开该 bug。
/// 同步阻塞在后台线程读取响应，简单可靠，且不依赖 JS / base64。
final class S3Uploader {
    static let shared = S3Uploader()
    private init() {}

    @discardableResult
    func upload(presignedURL: String, fields: [String: String],
                fileData: Data, mimeType: String) async throws -> (status: Int, body: String) {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Int, String), Error>) in
            let guardQueue = DispatchQueue(label: "com.sunohelper.s3upload.guard")
            var didResume = false
            let finish: (Result<(Int, String), Error>) -> Void = { result in
                guardQueue.async {
                    guard !didResume else { return }
                    didResume = true
                    switch result {
                    case .success(let v): continuation.resume(returning: v)
                    case .failure(let e): continuation.resume(throwing: e)
                    }
                }
            }
            let watchdog = Task {
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                finish(.failure(SunoError.uploadFailed("S3 上传超时(120s)")))
            }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try Self.performUpload(
                        presignedURL: presignedURL,
                        fields: fields,
                        fileData: fileData,
                        mimeType: mimeType
                    )
                    watchdog.cancel()
                    finish(.success(result))
                } catch {
                    watchdog.cancel()
                    finish(.failure(error))
                }
            }
        }
    }

    private static func performUpload(presignedURL: String, fields: [String: String],
                                      fileData: Data, mimeType: String) throws -> (Int, String) {
        guard let url = URL(string: presignedURL) else {
            throw SunoError.uploadFailed("S3 URL 无效")
        }
        let boundary = "----SunoHelperFormBoundary\(UUID().uuidString)"
        var body = Data()
        let crlf = "\r\n"
        for (key, value) in fields {
            body.append(Data("--\(boundary)\(crlf)".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(key)\"\(crlf)\(crlf)".utf8))
            body.append(Data("\(value)\(crlf)".utf8))
        }
        body.append(Data("--\(boundary)\(crlf)".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"audio.mp3\"\(crlf)".utf8))
        body.append(Data("Content-Type: \(mimeType)\(crlf)\(crlf)".utf8))
        body.append(fileData)
        body.append(Data("\(crlf)--\(boundary)--\(crlf)".utf8))

        DebugLog.shared.info("S3上传", "CFNetwork HTTP/1.1 POST body=\(body.count)B CT=\(mimeType)")

        let request = CFHTTPMessageCreateRequest(nil, "POST" as CFString, url as CFURL, kCFHTTPVersion1_1).takeRetainedValue()
        CFHTTPMessageSetHeaderFieldValue(request, "Content-Type" as CFString, "multipart/form-data; boundary=\(boundary)" as CFString)
        CFHTTPMessageSetHeaderFieldValue(request, "Content-Length" as CFString, "\(body.count)" as CFString)
        CFHTTPMessageSetBody(request, body as CFData)

        let readStream = CFReadStreamCreateForHTTPRequest(nil, request).takeRetainedValue()
        // 强制 Connection: close：S3 响应后直接关闭 TCP 连接 → 干净的 EOF（n==0），
        // 避免 HTTP/1.1 keep-alive 下响应已读完、连接却不关闭导致 CFReadStreamRead 返回 -1 误报“读取响应失败”。
        if let pk = CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPAttemptPersistentConnection) {
            CFReadStreamSetProperty(readStream, pk, kCFBooleanFalse)
        }
        guard CFReadStreamOpen(readStream) else {
            throw SunoError.uploadFailed("S3 上传：无法建立网络连接")
        }
        defer { CFReadStreamClose(readStream) }

        var responseBody = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = CFReadStreamRead(readStream, &buffer, buffer.count)
            if n > 0 {
                responseBody.append(&buffer, count: n)
            } else if n == 0 {
                break
            } else {
                // n < 0：响应阶段传输层报错，多为 keep-alive 下连接被 S3 关闭的 EOF 误报。
                // 跳出循环，交由下方状态码 / body 做权威判定，避免误报“读取响应失败”。
                break
            }
        }

        // 读取 HTTP 状态码（response header）做权威判定。
        // 用 CFStreamPropertyKey(rawValue:) 桥接（之前的 as 强转会触发编译错误）。
        let respKey = CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPResponseHeader)
        var statusCode = 0
        if let prop = CFReadStreamCopyProperty(readStream, respKey) {
            let responseHeader = prop.takeRetainedValue() as! CFHTTPMessage
            if CFHTTPMessageIsHeaderComplete(responseHeader) {
                statusCode = Int(CFHTTPMessageGetResponseStatusCode(responseHeader))
            }
        }

        let bodyStr = String(data: responseBody, encoding: .utf8) ?? ""
        // S3 失败返回 200 + XML <Error> body（非 4xx），所以无论状态码都必须先查 body。
        if bodyStr.contains("<Error>") {
            throw SunoError.uploadFailed("S3 上传被拒绝: \(bodyStr.prefix(200))")
        }
        if statusCode == 0 {
            // 极端：状态头读不到（CFNetwork 偶发），但无 <Error>，乐观判定成功
            statusCode = 204
        }
        if (200...299).contains(statusCode) {
            DebugLog.shared.info("S3上传", "CFNetwork 响应 status=\(statusCode) body=\(responseBody.count)B 成功")
            return (statusCode, bodyStr)
        } else {
            throw SunoError.uploadFailed("S3 上传失败 status=\(statusCode): \(bodyStr.prefix(200))")
        }
    }
}
