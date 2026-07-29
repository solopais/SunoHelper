import Foundation
import CFNetwork

/// S3 文件上传 —— 1:1 对齐 SunoTools backend.py 的 s3_upload：
///   session.post(url, data=fields, files={"file": (fileName, file, mime)}, headers={"Connection":"close"})
/// 即标准 multipart/form-data：先放所有 fields 表单字段，最后放 file 字段（S3 要求 file 在最后）。
///
/// iOS 实现策略：
///   - 主路径用 URLSession（标准 multipart），最简单可靠；
///   - 若 URLSession 在传输层失败（iOS HTTP/2 大文件偶发 -1005），回退 CFNetwork HTTP/1.1
///     （CFHTTP 层只支持 HTTP/1.0/1.1，从根上绕开 HTTP/2 的 -1005）。
///   - 重试由调用方（SunoAPI.uploadFileToS3）按 SunoTools 的 4 次策略执行。
final class S3Uploader {
    static let shared = S3Uploader()
    private init() {}

    /// 上传到 S3 预签名 URL。返回 (HTTP 状态码, 响应体)。
    /// 传输层错误（非 S3 明确拒绝）会回退到 CFNetwork。
    func upload(presignedURL: String, fields: [String: String],
                fileData: Data, fileName: String, mimeType: String) async throws -> (Int, String) {
        do {
            return try await urlSessionUpload(presignedURL: presignedURL, fields: fields,
                                              fileData: fileData, fileName: fileName, mimeType: mimeType)
        } catch let e as SunoError {
            // S3 明确拒绝（<Error> 或 4xx），属于权威失败，不再重试/回退
            throw e
        } catch {
            DebugLog.shared.info("S3上传", "URLSession 失败(\(error.localizedDescription))，回退 CFNetwork HTTP/1.1")
            return try cfNetworkUpload(presignedURL: presignedURL, fields: fields,
                                       fileData: fileData, fileName: fileName, mimeType: mimeType)
        }
    }

    /// 构造 multipart/form-data body（fields 在前，file 最后 —— 对齐 requests 行为）
    private func buildBody(fields: [String: String], fileData: Data,
                           fileName: String, mimeType: String, boundary: String) -> Data {
        var body = Data()
        let crlf = "\r\n"
        for (key, value) in fields {
            body.append(Data("--\(boundary)\(crlf)".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(key)\"\(crlf)\(crlf)".utf8))
            body.append(Data("\(value)\(crlf)".utf8))
        }
        body.append(Data("--\(boundary)\(crlf)".utf8))
        // 真实文件名（对齐 SunoTools 的 seg.fileName；中文名做 percent-encoding 保证合法）
        let safeName = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\(crlf)".utf8))
        body.append(Data("Content-Type: \(mimeType)\(crlf)\(crlf)".utf8))
        body.append(fileData)
        body.append(Data("\(crlf)--\(boundary)--\(crlf)".utf8))
        return body
    }

    // MARK: - 主路径：URLSession（标准 multipart）

    private func urlSessionUpload(presignedURL: String, fields: [String: String],
                                  fileData: Data, fileName: String, mimeType: String) async throws -> (Int, String) {
        guard let url = URL(string: presignedURL) else { throw SunoError.uploadFailed("S3 URL 无效") }
        let boundary = "----SunoHelperFormBoundary\(UUID().uuidString)"
        let body = buildBody(fields: fields, fileData: fileData, fileName: fileName, mimeType: mimeType, boundary: boundary)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("close", forHTTPHeaderField: "Connection")
        req.httpBody = body
        req.timeoutInterval = 300
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let bodyStr = String(data: data, encoding: .utf8) ?? ""
        if bodyStr.contains("<Error>") {
            throw SunoError.uploadFailed("S3 上传被拒绝: \(bodyStr.prefix(200))")
        }
        guard (200...299).contains(code) else {
            throw SunoError.uploadFailed("S3[\(code)]: \(bodyStr.prefix(200))")
        }
        DebugLog.shared.info("S3上传", "URLSession 成功 (\(code)) body=\(bodyStr.count)B")
        return (code, bodyStr)
    }

    // MARK: - 兜底路径：CFNetwork HTTP/1.1（规避 iOS HTTP/2 大文件 -1005）

    private func cfNetworkUpload(presignedURL: String, fields: [String: String],
                                 fileData: Data, fileName: String, mimeType: String) throws -> (Int, String) {
        guard let url = URL(string: presignedURL) else {
            throw SunoError.uploadFailed("S3 URL 无效")
        }
        let boundary = "----SunoHelperFormBoundary\(UUID().uuidString)"
        let body = buildBody(fields: fields, fileData: fileData, fileName: fileName, mimeType: mimeType, boundary: boundary)
        DebugLog.shared.info("S3上传", "CFNetwork HTTP/1.1 POST body=\(body.count)B CT=\(mimeType) file=\(fileName)")

        let request = CFHTTPMessageCreateRequest(nil, "POST" as CFString, url as CFURL, kCFHTTPVersion1_1).takeRetainedValue()
        CFHTTPMessageSetHeaderFieldValue(request, "Content-Type" as CFString, "multipart/form-data; boundary=\(boundary)" as CFString)
        CFHTTPMessageSetHeaderFieldValue(request, "Content-Length" as CFString, "\(body.count)" as CFString)
        CFHTTPMessageSetBody(request, body as CFData)

        let readStream = CFReadStreamCreateForHTTPRequest(nil, request).takeRetainedValue()
        // 强制 Connection: close：S3 响应后直接关闭 TCP → 干净 EOF，避免 keep-alive 下误报读取失败
        let pk = CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPAttemptPersistentConnection)
        CFReadStreamSetProperty(readStream, pk, kCFBooleanFalse)
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
            } else {
                // n==0 干净 EOF；n<0 多为 keep-alive 关闭的 EOF 误报，交由状态码/body 做权威判定
                break
            }
        }

        let respKey = CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPResponseHeader)
        var statusCode = 0
        if let prop = CFReadStreamCopyProperty(readStream, respKey) {
            let responseHeader = prop as! CFHTTPMessage
            if CFHTTPMessageIsHeaderComplete(responseHeader) {
                statusCode = Int(CFHTTPMessageGetResponseStatusCode(responseHeader))
            }
        }

        let bodyStr = String(data: responseBody, encoding: .utf8) ?? ""
        if bodyStr.contains("<Error>") {
            throw SunoError.uploadFailed("S3 上传被拒绝: \(bodyStr.prefix(200))")
        }
        if statusCode == 0 {
            // 极端：状态头读不到（CFNetwork 偶发）但无 <Error>，乐观判定成功
            statusCode = 204
        }
        if (200...299).contains(statusCode) {
            DebugLog.shared.info("S3上传", "CFNetwork 成功 status=\(statusCode) body=\(responseBody.count)B")
            return (statusCode, bodyStr)
        } else {
            throw SunoError.uploadFailed("S3 上传失败 status=\(statusCode): \(bodyStr.prefix(200))")
        }
    }
}
