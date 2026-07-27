import Foundation
import WebKit

/// S3 文件上传 — 使用 WKWebView `load(URLRequest)` POST 方案
///
/// 方案演进：
/// 1. URLSession: -1005（HTTP/2 大 body 上传 bug，所有 session 配置均失败）
/// 2. WKWebView fetch/XHR: status=0（6MB base64 传给 JS 可能有问题）
/// 3. 当前方案: WKWebView `load(URLRequest)` 直接 POST multipart body
///    - 不需要 JS，不需要 base64
///    - 页面导航不走 AJAX，不受 CORS 限制
///    - Python urllib（HTTP/1.1）实测能成功上传到 S3（204）
///    - WKWebView 的 NetworkProcess 网络栈与 NSURLSession 独立
///
/// 实测确认（2026-07-28）：
/// - S3 CORS 允许 *（所有 origin），Allow-Methods: POST
/// - Python urllib 直接 POST 到 S3 成功（204），返回 ETag + Location
/// - 证明 S3 预签名 URL 有效，问题在 iOS 网络栈
final class S3UploadWebView: NSObject {
    static let shared = S3UploadWebView()

    private var webView: WKWebView?
    private var uploadContinuation: CheckedContinuation<(Int, String), Error>?
    private var receivedStatus: Int?
    private var timeoutTask: Task<Void, Never>?

    private override init() { super.init() }

    // MARK: - 公共方法

    /// 上传文件到 S3
    /// - Returns: (status, body) — HTTP 状态码和响应体
    @discardableResult
    func upload(presignedURL: String, fields: [String: String],
                fileData: Data, mimeType: String) async throws -> (status: Int, body: String) {
        // 构造 multipart/form-data body
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        for (key, value) in fields {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }
        // file 字段（必须最后）
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"upload.mp3\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(fileData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        // 构造 POST 请求
        guard let url = URL(string: presignedURL) else {
            throw SunoError.uploadFailed("S3 URL 无效")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        DebugLog.shared.info("S3上传", "load POST \(presignedURL.prefix(50)) body=\(body.count)B")

        // 确保 WKWebView 存在（主线程）
        await MainActor.run {
            if webView == nil {
                let wv = WKWebView(frame: .zero)
                wv.navigationDelegate = self
                webView = wv
                DebugLog.shared.info("S3上传", "WKWebView 已创建")
            }
        }

        receivedStatus = nil

        // 用 continuation 等待 WKNavigationDelegate 回调
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Int, String), Error>) in
            self.uploadContinuation = continuation

            // 超时保护（300 秒）
            self.timeoutTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                await MainActor.run {
                    self.completeUpload(error: SunoError.uploadFailed("S3 上传超时(300s)"))
                }
            }

            // 主线程发起 load POST
            DispatchQueue.main.async {
                self.webView?.load(req)
            }
        }
    }

    /// 统一的完成方法（防止 continuation 被 resume 多次）
    @MainActor
    private func completeUpload(status: Int? = nil, body: String = "", error: Error? = nil) {
        guard let cont = uploadContinuation else { return }
        uploadContinuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil

        if let error = error {
            cont.resume(throwing: error)
        } else {
            let s = status ?? receivedStatus ?? 204
            DebugLog.shared.info("S3上传", "完成 status=\(s)")
            cont.resume(returning: (s, body))
        }
    }

    /// 取消上传（用于错误恢复）
    func cancel() {
        DispatchQueue.main.async {
            self.webView?.stopLoading()
        }
        Task { @MainActor in
            self.completeUpload(error: SunoError.cancelled)
        }
    }
}

// MARK: - WKNavigationDelegate

extension S3UploadWebView: WKNavigationDelegate {

    /// 收到响应 — 获取 HTTP 状态码
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let status = (navigationResponse.response as? HTTPURLResponse)?.statusCode ?? 0
        receivedStatus = status
        DebugLog.shared.info("S3上传", "收到响应 status=\(status) MIME=\(navigationResponse.response.mimeType ?? "?")")

        // cancel 导航 — 不显示 S3 响应页面
        decisionHandler(.cancel)

        // resume continuation
        Task { @MainActor in
            self.completeUpload(status: status)
        }
    }

    /// 导航完成（204 No Content 时 decidePolicyFor 可能不触发，这里作为 fallback）
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DebugLog.shared.info("S3上传", "导航完成 didFinish")
        Task { @MainActor in
            // 如果 decidePolicyFor 已经 resume 了，uploadContinuation 为 nil，不会重复
            self.completeUpload(status: self.receivedStatus ?? 204)
        }
    }

    /// 导航失败（网络错误、SSL 错误等）
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        DebugLog.shared.error("S3上传", "导航失败(provisional): \(error.localizedDescription)")
        Task { @MainActor in
            self.completeUpload(error: error)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        DebugLog.shared.error("S3上传", "导航失败: \(error.localizedDescription)")
        Task { @MainActor in
            self.completeUpload(error: error)
        }
    }
}
