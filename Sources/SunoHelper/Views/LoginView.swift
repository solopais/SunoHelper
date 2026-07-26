import SwiftUI
import WebKit

struct LoginView: View {
    @StateObject private var session = SunoSession.shared
    @State private var status = "请在下方网页里登录你的 Suno 免费账户"
    @State private var showPaste = false
    @State private var pasteText = ""
    @State private var grabbing = false

    var body: some View {
        AppNav {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 6) {
                        Text("Suno 助手")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundColor(AppTheme.text)
                        Text("登录你的 Suno 账户，用提示词生成 AI 歌曲")
                            .font(.subheadline)
                            .foregroundColor(AppTheme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 12)

                    SunoWebView(session: session)
                        .frame(height: 420)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16)
                            .stroke(AppTheme.surface2, lineWidth: 1))
                        .padding(.horizontal, 16)

                    Text(status)
                        .font(.footnote)
                        .foregroundColor(AppTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    VStack(spacing: 12) {
                        Button(action: grabCookies) {
                            HStack {
                                if grabbing { ProgressView().tint(.white) }
                                Text(grabbing ? "正在抓取…" : "抓取登录态并保存")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(AppTheme.gradient())
                            .foregroundColor(.white)
                            .font(.headline)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(grabbing)

                        Button(action: { showPaste = true }) {
                            Text("手动粘贴 Cookie")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .foregroundColor(AppTheme.text)
                                .overlay(RoundedRectangle(cornerRadius: 12)
                                    .stroke(AppTheme.surface2, lineWidth: 1))
                        }
                    }
                    .padding(.horizontal, 16)

                    Text("Cookie 仅保存在本机，不会上传任何服务器。")
                        .font(.caption2)
                        .foregroundColor(AppTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .padding(.bottom, 24)
            }
            .hideScrollContentBackground()
            .background(AppTheme.bg)
            .navigationTitle("登录")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $showPaste) {
            NavigationView {
                VStack(spacing: 12) {
                    Text("把浏览器里 Suno 的 Cookie 整段粘贴进来（需包含 __session=...）")
                        .font(.footnote)
                        .foregroundColor(AppTheme.textSecondary)
                        .padding(.horizontal, 16)
                    TextEditor(text: $pasteText)
                        .font(.system(.body, design: .monospaced))
                        .padding(8)
                        .background(AppTheme.surface)
                        .foregroundColor(AppTheme.text)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 16)
                    Button(action: {
                        session.saveCookie(pasteText)
                        showPaste = false
                        if session.isLoggedIn {
                            status = "已保存登录态 ✅"
                        } else {
                            status = "Cookie 无效或已过期，请重新获取"
                        }
                    }) {
                        Text("保存")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(AppTheme.accent)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal, 16)
                    Spacer()
                }
                .padding(.top, 12)
                .navigationTitle("粘贴 Cookie")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("取消") { showPaste = false }
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    func grabCookies() {
        grabbing = true
        status = "正在从网页读取 Cookie…"
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let str = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            DispatchQueue.main.async {
                self.grabbing = false
                if str.contains("__session") {
                    self.session.saveCookie(str)
                    self.status = "已保存登录态 ✅"
                } else {
                    self.status = "还没检测到登录态，请先在网页里登录 Suno"
                }
            }
        }
    }
}

struct SunoWebView: UIViewRepresentable {
    @ObservedObject var session: SunoSession

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        if let url = URL(string: "https://suno.com") {
            wv.load(URLRequest(url: url))
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate {}
}
