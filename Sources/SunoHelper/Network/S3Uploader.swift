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
                throw SunoError.uploadFailed("S3 读取响应失败")
            }
        }

        var statusCode = 0
        if let prop = CFReadStreamCopyProperty(readStream, kCFStreamPropertyHTTPResponseHeader) {
            let responseHeader = prop.takeRetainedValue() as! CFHTTPMessage
            if CFHTTPMessageIsHeaderComplete(responseHeader) {
                statusCode = Int(CFHTTPMessageGetResponseStatusCode(responseHeader))
            }
        }
        let bodyStr = String(data: responseBody, encoding: .utf8) ?? ""
        DebugLog.shared.info("S3上传", "CFNetwork 响应 status=\(statusCode) body=\(responseBody.count)B")
        return (statusCode, bodyStr)
    }
}
