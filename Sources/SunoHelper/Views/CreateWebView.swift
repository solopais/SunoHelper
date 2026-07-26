import SwiftUI
import WebKit

/// 在真实浏览器上下文里打开 Suno 创作页（https://suno.com/create）。
/// 因为 WKWebView 共享默认 cookie 仓库，这里会延续「登录」页的登录态，
/// hCaptcha 由用户真实交互满足，生成不受原生接口 422（token_validation_failed）的限制。
/// 关闭本页时会发通知，让原生音乐库刷新刚生成的歌曲。
struct CreateWebView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AppNav {
            ZStack(alignment: .topTrailing) {
                CreateWK()
                    .ignoresSafeArea(edges: [.bottom, .horizontal])
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.white)
                        .background(Circle().fill(Color.black.opacity(0.45)))
                        .padding(10)
                }
            }
            .background(AppTheme.bg)
            .navigationTitle("在 Suno 网页创作")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onDisappear {
            // 关闭网页创作后，刷新原生音乐库（抓取刚生成的歌）
            NotificationCenter.default.post(name: Notification.Name("SunoReloadLibrary"), object: nil)
        }
    }
}

struct CreateWK: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.allowsBackForwardNavigationGestures = true
        if let url = URL(string: "https://suno.com/create") {
            wv.load(URLRequest(url: url))
        }
        return wv
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
