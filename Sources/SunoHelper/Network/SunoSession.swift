import Foundation
import Combine

/// 管理 Suno 网页登录态（cookie / __session JWT）
/// 数据只存在本机 UserDefaults，不上传任何服务器。
final class SunoSession: ObservableObject {
    static let shared = SunoSession()

    @Published var isLoggedIn = false
    @Published var sessionExpired = false

    private let cookieKey = "suno_cookie_string"
    private let tokenKey = "suno_session_token"

    var cookie: String? { UserDefaults.standard.string(forKey: cookieKey) }
    var token: String? { UserDefaults.standard.string(forKey: tokenKey) }

    init() {
        if let c = cookie { validate(cookie: c) }
    }

    func saveCookie(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: cookieKey)
        if let tok = extractSession(from: trimmed) {
            UserDefaults.standard.set(tok, forKey: tokenKey)
        }
        validate(cookie: trimmed)
    }

    func extractSession(from cookie: String) -> String? {
        let parts = cookie.components(separatedBy: ";")
        for p in parts {
            let kv = p.trimmingCharacters(in: .whitespaces)
            if kv.hasPrefix("__session=") {
                return String(kv.dropFirst("__session=".count))
            }
        }
        return nil
    }

    func validate(cookie: String) {
        guard let tok = extractSession(from: cookie) else {
            DispatchQueue.main.async {
                self.isLoggedIn = false
                self.sessionExpired = false
            }
            return
        }
        let expired = isJWTExpired(tok)
        DispatchQueue.main.async {
            self.isLoggedIn = !expired
            self.sessionExpired = expired
        }
    }

    func isJWTExpired(_ jwt: String) -> Bool {
        let seg = jwt.components(separatedBy: ".")
        guard seg.count >= 2 else { return false }
        var b = seg[1]
        let rem = b.count % 4
        if rem > 0 { b += String(repeating: "=", count: 4 - rem) }
        guard let data = Data(base64Encoded: b),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? Double else { return false }
        return Date().timeIntervalSince1970 >= exp
    }

    func logout() {
        UserDefaults.standard.removeObject(forKey: cookieKey)
        UserDefaults.standard.removeObject(forKey: tokenKey)
        DispatchQueue.main.async {
            self.isLoggedIn = false
            self.sessionExpired = false
        }
    }

    /// 构造请求头：Cookie（全量）+ Authorization: Bearer <__session>
    func authHeaders() -> [String: String] {
        var h: [String: String] = [:]
        if let c = cookie { h["Cookie"] = c }
        if let t = token { h["Authorization"] = "Bearer \(t)" }
        return h
    }

    var email: String? {
        guard let tok = token else { return nil }
        let seg = tok.components(separatedBy: ".")
        guard seg.count >= 2 else { return nil }
        var b = seg[1]
        let rem = b.count % 4
        if rem > 0 { b += String(repeating: "=", count: 4 - rem) }
        guard let data = Data(base64Encoded: b),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (json["https://suno.ai/claims/email"] as? String)
            ?? (json["email"] as? String)
    }
}
