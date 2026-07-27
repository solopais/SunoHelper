import SwiftUI

struct SettingsView: View {
    @StateObject private var session = SunoSession.shared
    @StateObject private var store = SongStore.shared
    @State private var credits: Int?
    @State private var monthlyLimit: Int?
    @State private var monthlyUsage: Int?
    @State private var planType: SunoPlanType = .unknown
    @State private var creditsMsg = ""
    @State private var showClear = false
    @StateObject private var debugLog = DebugLog.shared
    @State private var showDebugLog = false

    var body: some View {
        AppNav {
            List {
                // MARK: - 账户信息
                Section {
                    HStack {
                        Text("账户")
                        Spacer()
                        Text(session.email ?? (session.isLoggedIn ? "已登录" : "未登录"))
                            .foregroundColor(AppTheme.textSecondary)
                    }

                    HStack {
                        Text("账户类型")
                        Spacer()
                        PlanBadge(plan: planType)
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
                }
                .listRowBackground(AppTheme.surface)

                // MARK: - 额度信息
                Section("额度") {
                    HStack {
                        Text("剩余额度")
                        Spacer()
                        if let c = credits {
                            Text("\(c)").foregroundColor(AppTheme.accent).fontWeight(.medium)
                        } else if !creditsMsg.isEmpty {
                            Text(creditsMsg).foregroundColor(AppTheme.error).font(.caption)
                        } else {
                            Text("点击刷新").foregroundColor(AppTheme.textSecondary)
                        }
                    }

                    if let limit = monthlyLimit {
                        HStack {
                            Text("月度上限")
                            Spacer()
                            Text("\(limit)").foregroundColor(AppTheme.textSecondary)
                        }
                    }

                    if let usage = monthlyUsage {
                        HStack {
                            Text("本月已用")
                            Spacer()
                            Text("\(usage)").foregroundColor(AppTheme.textSecondary)
                        }
                    }

                    HStack {
                        Text("可用模型")
                        Spacer()
                        Text(availableModelsText).font(.caption).foregroundColor(AppTheme.textSecondary)
                    }

                    Button(action: { Task { await loadCredits() } }) {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("刷新信息")
                        }
                    }
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

                Section("调试") {
                    NavigationLink(destination: DebugLogView()) {
                        HStack {
                            Image(systemName: "doc.text.magnifyingglass")
                            Text("调试日志")
                            Spacer()
                            Text("\(debugLog.entries.count)")
                                .font(.caption).foregroundColor(AppTheme.textSecondary)
                        }
                    }
                    .foregroundColor(AppTheme.text)
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
            let info = try await SunoAPI.shared.billing()
            await MainActor.run {
                credits = info.credits
                monthlyLimit = info.monthly_limit
                monthlyUsage = info.monthly_usage
                planType = info.inferredPlan
                creditsMsg = ""
            }
        } catch {
            await MainActor.run { creditsMsg = "获取失败" }
        }
    }

    /// 可用模型描述文本
    var availableModelsText: String {
        if planType == .free {
            return "v4.5-all / v4（免费版）"
        }
        return "全部 6 个模型（含 v5.5 Pro）"
    }
}

// MARK: - 调试日志视图
struct DebugLogView: View {
    @StateObject private var debugLog = DebugLog.shared

    var body: some View {
        List {
            Section {
                HStack {
                    Button(action: { debugLog.clear() }) {
                        Label("清空日志", systemImage: "trash")
                            .foregroundColor(.red)
                    }
                    Spacer()
                    Button(action: copyLog) {
                        Label("复制全部", systemImage: "doc.on.doc")
                            .foregroundColor(AppTheme.accent)
                    }
                }
            }
            .listRowBackground(AppTheme.surface)

            Section("日志（最新在前）") {
                ForEach(debugLog.entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(entry.level.rawValue)
                                .font(.system(size: 10, design: .monospaced))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(levelColor(entry.level).opacity(0.2))
                                .foregroundColor(levelColor(entry.level))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                            Text(entry.category)
                                .font(.caption2).foregroundColor(AppTheme.textSecondary)
                            Spacer()
                            Text(timeString(entry.timestamp))
                                .font(.caption2).foregroundColor(AppTheme.textSecondary)
                        }
                        Text(entry.message)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(AppTheme.text)
                            .lineLimit(nil)
                    }
                    .listRowBackground(AppTheme.surface)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                }
            }
        }
        .listStyle(.insetGrouped)
        .hideScrollContentBackground()
        .background(AppTheme.bg)
        .navigationTitle("调试日志")
        .navigationBarTitleDisplayMode(.inline)
    }

    func levelColor(_ level: DebugLog.Level) -> Color {
        switch level {
        case .info: return AppTheme.textSecondary
        case .warn: return .orange
        case .error: return AppTheme.error
        case .success: return AppTheme.success
        }
    }

    func timeString(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df.string(from: date)
    }

    func copyLog() {
        UIPasteboard.general.string = debugLog.exportText()
    }
}

// MARK: - 账户类型标签
private struct PlanBadge: View {
    let plan: SunoPlanType

    var body: some View {
        Text(plan.displayName)
            .font(.caption).fontWeight(.semibold)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(badgeColor.opacity(0.15))
            .foregroundColor(badgeColor)
            .clipShape(Capsule())
    }

    var badgeColor: Color {
        switch plan {
        case .free:     return Color.gray
        case .pro:      return Color.blue
        case .premier:  return Color.purple
        case .unknown:  return Color.gray
        }
    }
}
