import SwiftUI

struct SettingsView: View {
    @StateObject private var session = SunoSession.shared
    @StateObject private var store = SongStore.shared
    @State private var credits: Int?
    @State private var creditsMsg = ""
    @State private var showClear = false

    var body: some View {
        AppNav {
            List {
                Section {
                    HStack {
                        Text("账户")
                        Spacer()
                        Text(session.email ?? (session.isLoggedIn ? "已登录" : "未登录"))
                            .foregroundColor(AppTheme.textSecondary)
                    }
                    HStack {
                        Text("会话状态")
                        Spacer()
                        if session.sessionExpired {
                            Text("已过期").foregroundColor(AppTheme.error)
                        } else if session.isLoggedIn {
                            Text("有效").foregroundColor(AppTheme.success)
                        } else {
                            Text("未登录").foregroundColor(AppTheme.textSecondary)
                        }
                    }
                    HStack {
                        Text("剩余额度")
                        Spacer()
                        if let c = credits {
                            Text("\(c)").foregroundColor(AppTheme.accent)
                        } else if !creditsMsg.isEmpty {
                            Text(creditsMsg).foregroundColor(AppTheme.error).font(.caption)
                        } else {
                            Text("点击刷新").foregroundColor(AppTheme.textSecondary)
                        }
                    }
                    Button("刷新额度") { Task { await loadCredits() } }
                        .foregroundColor(AppTheme.accent)
                }
                .listRowBackground(AppTheme.surface)

                Section("数据") {
                    HStack {
                        Text("音乐库数量")
                        Spacer()
                        Text("\(store.items.count)").foregroundColor(AppTheme.textSecondary)
                    }
                    Button(role: .destructive) {
                        showClear = true
                    } label: {
                        Text("清空音乐库")
                    }
                }
                .listRowBackground(AppTheme.surface)

                Section("关于") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("1.0").foregroundColor(AppTheme.textSecondary)
                    }
                    HStack {
                        Text("方式")
                        Spacer()
                        Text("Suno 网页端免费账户").foregroundColor(AppTheme.textSecondary)
                    }
                    Link("Suno 官网", destination: URL(string: "https://suno.com")!)
                        .foregroundColor(AppTheme.accent)
                }
                .listRowBackground(AppTheme.surface)

                Section {
                    Button(role: .destructive) {
                        session.logout()
                    } label: {
                        Text("退出登录")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .listRowBackground(AppTheme.surface)
            }
            .listStyle(.insetGrouped)
            .hideScrollContentBackground()
            .background(AppTheme.bg)
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .alert("清空音乐库", isPresented: $showClear) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) {
                    store.clearAll()
                    DownloadManager.shared.clearAllDownloads()
                }
            } message: {
                Text("将删除全部历史记录与已下载的音频文件，无法恢复。")
            }
            .task { await loadCredits() }
        }
    }

    func loadCredits() async {
        do {
            credits = try await SunoAPI.shared.credits()
            creditsMsg = ""
        } catch {
            creditsMsg = "获取失败"
        }
    }
}
