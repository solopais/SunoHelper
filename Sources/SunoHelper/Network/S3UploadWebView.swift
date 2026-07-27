import Foundation
import WebKit

/// 用 WKWebView 的 fetch/XHR API 上传文件到 S3
///
/// 方案演进：
/// 1. URLSession: -1005（HTTP/2 连接断开），所有 session 配置均失败
/// 2. loadHTMLString + fetch: "Load failed"（loadHTMLString 的 origin 不可靠，CORS 拒绝）
/// 3. 当前方案: load(https://suno.com/) 加载真实页面，确保 origin = https://suno.com
///    Suno 网页版在浏览器里上传 S3 正常，我们模拟同样的环境
///    JS 先尝试 fetch，失败后用 XMLHttpRequest 兜底
final class S3UploadWebView {
    static let shared = S3UploadWebView()

    private var webView: WKWebView?
    private var pageInitialized = false
    private let lock = NSLock()

    private init() {}

    // MARK: - JS 脚本

    /// Console 捕获脚本（documentStart 注入，捕获页面 JS 错误用于调试）
    private static let consoleJS = """
    (function() {
        var origError = console.error;
        console.error = function() {
            try {
                var args = Array.from(arguments);
                var msg = args.map(function(a) { return typeof a === 'object' ? JSON.stringify(a) : String(a); }).join(' ');
                window.webkit.messageHandlers.s3console.postMessage('ERR: ' + msg);
            } catch(e) {}
            origError.apply(console, arguments);
        };
        var origLog = console.log;
        console.log = function() {
            try {
                var args = Array.from(arguments);
                var msg = args.map(function(a) { return typeof a === 'object' ? JSON.stringify(a) : String(a); }).join(' ');
                window.webkit.messageHandlers.s3console.postMessage('LOG: ' + msg);
            } catch(e) {}
            origLog.apply(console, arguments);
        };
    })();
    """

    /// 上传函数（documentEnd 注入，每次页面加载都会重新注入）
    /// 先尝试 fetch，失败后用 XMLHttpRequest 兜底
    private static let uploadJS = """
    (function() {
        window.__s3Upload = async function(base64Data, fieldsJson, uploadUrl, mimeType) {
            try {
                var binaryString = atob(base64Data);
                var len = binaryString.length;
                var bytes = new Uint8Array(len);
                for (var i = 0; i < len; i++) { bytes[i] = binaryString.charCodeAt(i); }

                var fields = JSON.parse(fieldsJson);
                var formData = new FormData();
                var keys = Object.keys(fields);
                for (var j = 0; j < keys.length; j++) {
                    formData.append(keys[j], fields[keys[j]]);
                }
                formData.append('file', new Blob([bytes], {type: mimeType}), 'upload.mp3');

                // 方法 1: fetch API
                try {
                    var controller = new AbortController();
                    var timeoutId = setTimeout(function() { controller.abort(); }, 120000);
                    var resp = await fetch(uploadUrl, {
                        method: 'POST',
                        body: formData,
                        signal: controller.signal
                    });
                    clearTimeout(timeoutId);
                    var text = await resp.text();
                    return { status: resp.status, ok: resp.ok, body: text.substring(0, 500), method: 'fetch' };
                } catch(fetchErr) {
                    var fetchErrInfo = (fetchErr && fetchErr.name) ? (fetchErr.name + ': ' + (fetchErr.message || '')) : String(fetchErr);

                    // 方法 2: XMLHttpRequest 兜底
                    try {
                        return await new Promise(function(resolve) {
                            var xhr = new XMLHttpRequest();
                            xhr.open('POST', uploadUrl, true);
                            xhr.timeout = 120000;
                            xhr.onload = function() {
                                resolve({
                                    status: xhr.status,
                                    ok: xhr.status >= 200 && xhr.status < 300,
                                    body: (xhr.responseText || '').substring(0, 500),
                                    method: 'xhr',
                                    fetchError: fetchErrInfo
                                });
                            };
                            xhr.onerror = function() {
                                resolve({
                                    status: 0,
                                    ok: false,
                                    error: 'XHR onerror status=' + xhr.status + ' readyState=' + xhr.readyState,
                                    method: 'xhr',
                                    fetchError: fetchErrInfo
                                });
                            };
                            xhr.ontimeout = function() {
                                resolve({
                                    status: 0,
                                    ok: false,
                                    error: 'XHR timeout',
                                    method: 'xhr',
                                    fetchError: fetchErrInfo
                                });
                            };
                            xhr.send(formData);
                        });
                    } catch(xhrErr) {
                        return {
                            status: 0,
                            ok: false,
                            error: 'fetch=[' + fetchErrInfo + '] xhr=[' + ((xhrErr && xhrErr.message) ? xhrErr.message : String(xhrErr)) + ']',
                            method: 'both_failed'
                        };
                    }
                }
            } catch(e) {
                return { status: 0, ok: false, error: 'JS: ' + ((e && e.message) ? e.message : String(e)), method: 'js_error' };
            }
        };
        window.__s3Ready = true;
    })();
    """

    // MARK: - MainActor 方法（WKWebView 必须在主线程操作）

    /// 创建 WKWebView 并加载真实 suno.com 页面
    @MainActor
    private func setupWebViewIfNeeded() {
        if webView == nil {
            let config = WKWebViewConfiguration()
            let ucc = config.userContentController

            // Console 捕获（documentStart）
            ucc.add(S3ConsoleHandler.shared, name: "s3console")
            ucc.addUserScript(WKUserScript(
                source: S3UploadWebView.consoleJS,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))

            // 上传函数（documentEnd，每次页面加载/跳转后自动注入）
            ucc.addUserScript(WKUserScript(
                source: S3UploadWebView.uploadJS,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))

            let wv = WKWebView(frame: .zero, configuration: config)

            // 加载真实 suno.com 页面 — origin = https://suno.com
            // Suno 网页版从这里上传 S3，CORS 允许此 origin
            var req = URLRequest(url: URL(string: "https://suno.com/")!)
            req.timeoutInterval = 15
            wv.load(req)
            webView = wv

            DebugLog.shared.info("S3上传", "正在加载 suno.com 页面以设置 origin...")
        }
    }

    /// 检查 JS 是否就绪
    @MainActor
    private func checkReady() async -> Bool {
        guard let wv = webView else { return false }
        do {
            let result = try await wv.evaluateJavaScript("window.__s3Ready === true")
            return result as? Bool ?? false
        } catch {
            return false
        }
    }

    /// 获取当前页面 URL（用于调试，确认是否跳转到了其他域名）
    @MainActor
    private func getCurrentURL() async -> String? {
        guard let wv = webView else { return nil }
        return try? await wv.evaluateJavaScript("window.location.href") as? String
    }

    /// 手动注入 JS（页面加载超时的兜底）
    @MainActor
    private func injectJSManually() async {
        guard let wv = webView else { return }
        try? await wv.evaluateJavaScript(S3UploadWebView.uploadJS)
    }

    /// 执行 JS 上传
    @MainActor
    private func performUpload(base64: String, fieldsJSON: String,
                               presignedURL: String, mimeType: String) async throws -> [String: Any]? {
        guard let wv = webView else { return nil }
        let result = try await wv.callAsyncJavaScript(
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
        return result as? [String: Any]
    }

    // MARK: - 公共方法

    /// 确保 WKWebView 已加载 suno.com 页面且 JS 就绪
    private func ensureReady() async throws {
        // 快速路径：已初始化且就绪
        lock.lock()
        let initialized = pageInitialized
        lock.unlock()
        if initialized && await checkReady() { return }

        await setupWebViewIfNeeded()

        // 轮询等待页面加载完成（最多 15 秒）
        for i in 0..<30 {
            try await Task.sleep(nanoseconds: 500_000_000)  // 0.5s
            if await checkReady() {
                let url = await getCurrentURL()
                DebugLog.shared.info("S3上传", "suno.com 页面就绪 (url=\(url ?? "?"))")
                lock.lock()
                pageInitialized = true
                lock.unlock()
                return
            }
            if i == 0 {
                DebugLog.shared.info("S3上传", "等待 suno.com 页面加载...")
            }
        }

        // 超时 — 尝试手动注入 JS
        DebugLog.shared.warn("S3上传", "页面加载超时(15s)，尝试手动注入 JS...")
        await injectJSManually()
        try await Task.sleep(nanoseconds: 500_000_000)
        lock.lock()
        pageInitialized = true
        lock.unlock()
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

        let result = try await performUpload(
            base64: base64,
            fieldsJSON: fieldsJSON,
            presignedURL: presignedURL,
            mimeType: mimeType
        )

        guard let dict = result else {
            throw SunoError.uploadFailed("S3 WebView 上传：JS 返回异常")
        }

        let status = dict["status"] as? Int ?? 0
        let ok = dict["ok"] as? Bool ?? false
        let errorMsg = dict["error"] as? String
        let body = dict["body"] as? String ?? ""
        let method = dict["method"] as? String ?? "?"

        DebugLog.shared.info("S3上传", "WebView响应: status=\(status) ok=\(ok) method=\(method)")

        if !ok {
            throw SunoError.uploadFailed("S3[\(status)] [\(method)]: \(errorMsg ?? body)")
        }

        return (status, body)
    }
}

/// Console 消息处理器（独立类避免 retain cycle）
private final class S3ConsoleHandler: NSObject, WKScriptMessageHandler {
    static let shared = S3ConsoleHandler()
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if let body = message.body as? String {
            DebugLog.shared.info("S3上传JS", body)
        }
    }
}
