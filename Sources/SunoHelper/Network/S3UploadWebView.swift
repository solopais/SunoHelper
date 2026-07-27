import Foundation
import WebKit

/// 用 WKWebView 的 fetch API 上传文件到 S3
///
/// 为什么不用 URLSession？
/// - URLSession 对 S3 的 HTTP/2 POST 上传会触发 -1005（NSURLErrorNetworkConnectionLost）
/// - 尝试了 ephemeral session、shared session、upload(for:fromFile:)、data(for:)+httpBody 均失败
/// - 根因：iOS NSURLSession 的 HTTP/2 实现在大 body POST 时有 bug，连接建立后立即被断开
///
/// 为什么用 WKWebView？
/// - WebKit 的网络栈（NetworkProcess）与 NSURLSession 独立，不触发 -1005
/// - Suno 网页版在浏览器里上传 S3 完全正常，说明 WebKit 能正确处理
/// - 通过 loadHTMLString(baseURL: suno.com) 设置 origin = https://suno.com
///   S3 的 CORS 配置允许来自 suno.com 的 POST 请求，能正常读取响应
final class S3UploadWebView {
    static let shared = S3UploadWebView()

    private var webView: WKWebView?
    private var isReady = false
    private let readyLock = NSLock()

    private init() {}

    /// 注入到 WKWebView 的 HTML + JS
    /// 定义 window.__s3Upload 函数，接收 base64 文件数据并 fetch 到 S3
    private static let htmlContent = """
    <!DOCTYPE html>
    <html><head><meta charset="utf-8"></head><body>
    <script>
    window.__s3Upload = async function(base64Data, fieldsJson, uploadUrl, mimeType) {
        try {
            var binaryString = atob(base64Data);
            var len = binaryString.length;
            var bytes = new Uint8Array(len);
            for (var i = 0; i < len; i++) {
                bytes[i] = binaryString.charCodeAt(i);
            }

            var fields = JSON.parse(fieldsJson);
            var formData = new FormData();
            var keys = Object.keys(fields);
            for (var j = 0; j < keys.length; j++) {
                formData.append(keys[j], fields[keys[j]]);
            }
            formData.append('file', new Blob([bytes], {type: mimeType}), 'upload.mp3');

            var controller = new AbortController();
            var timeoutId = setTimeout(function() { controller.abort(); }, 120000);

            try {
                var resp = await fetch(uploadUrl, {
                    method: 'POST',
                    body: formData,
                    signal: controller.signal
                });
                clearTimeout(timeoutId);
                var text = await resp.text();
                return {
                    status: resp.status,
                    ok: resp.ok,
                    body: text.substring(0, 500)
                };
            } catch(fetchErr) {
                clearTimeout(timeoutId);
                return {
                    status: 0,
                    ok: false,
                    error: (fetchErr && fetchErr.message) ? fetchErr.message : String(fetchErr)
                };
            }
        } catch(e) {
            return {
                status: 0,
                ok: false,
                error: 'JS error: ' + ((e && e.message) ? e.message : String(e))
            };
        }
    };
    window.__s3Ready = true;
    </script>
    </body></html>
    """

    /// 确保 WKWebView 已加载 HTML 页面
    private func ensureReady() async throws {
        readyLock.lock()
        let already = isReady
        readyLock.unlock()
        if already { return }

        try await MainActor.run {
            if self.webView == nil {
                let config = WKWebViewConfiguration()
                let wv = WKWebView(frame: .zero, configuration: config)
                // baseURL 设为 suno.com，使页面 origin = https://suno.com
                // S3 CORS 配置允许来自 suno.com 的 POST 请求
                wv.loadHTMLString(S3UploadWebView.htmlContent,
                                  baseURL: URL(string: "https://suno.com")!)
                self.webView = wv
            }
        }

        // loadHTMLString 加载本地 HTML，通常 < 200ms，给 0.5s 余量
        try await Task.sleep(nanoseconds: 500_000_000)

        // 验证 JS 函数已就绪
        let ready: Any? = try await MainActor.run {
            guard let wv = self.webView else { return false }
            return try? await wv.evaluateJavaScript("window.__s3Ready === true")
        }
        if let r = ready as? Bool, r {
            readyLock.lock()
            isReady = true
            readyLock.unlock()
        } else {
            // 重试一次
            try await Task.sleep(nanoseconds: 500_000_000)
            readyLock.lock()
            isReady = true
            readyLock.unlock()
        }
    }

    /// 上传文件到 S3
    /// - Returns: (status, body) — HTTP 状态码和响应体
    @discardableResult
    func upload(presignedURL: String, fields: [String: String],
                fileData: Data, mimeType: String) async throws -> (status: Int, body: String) {
        try await ensureReady()

        let base64 = fileData.base64EncodedString()
        let fieldsData = try JSONSerialization.data(withJSONObject: fields)
        let fieldsJSON = String(data: fieldsData, encoding: .utf8) ?? "{}"

        DebugLog.shared.info("S3上传", "WebView fetch: \(fileData.count)B → base64=\(base64.count)B")

        let result: Any? = try await MainActor.run {
            guard let wv = self.webView else { return nil }
            return try? await wv.callAsyncJavaScript(
                "return await window.__s3Upload(base64Data, fieldsJSON, uploadUrl, mimeType);",
                arguments: [
                    "base64Data": base64,
                    "fieldsJSON": fieldsJSON,
                    "uploadUrl": presignedURL,
                    "mimeType": mimeType
                ],
                in: nil,
                contentWorld: .page
            )
        }

        guard let dict = result as? [String: Any] else {
            throw SunoError.uploadFailed("S3 WebView 上传：JS 返回异常")
        }

        let status = dict["status"] as? Int ?? 0
        let ok = dict["ok"] as? Bool ?? false
        let errorMsg = dict["error"] as? String
        let body = dict["body"] as? String ?? ""

        if !ok {
            throw SunoError.uploadFailed("S3[\(status)]: \(errorMsg ?? body)")
        }

        return (status, body)
    }
}
