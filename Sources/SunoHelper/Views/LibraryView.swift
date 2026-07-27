import SwiftUI
import Combine

struct LibraryView: View {
    @StateObject private var store = SongStore.shared
    @StateObject private var session = SunoSession.shared
    @State private var showExtend = false
    @State private var extendClipID: String?
    @State private var showCover = false
    @State private var coverClipID: String?
    @State private var refreshing = false
    @State private var refreshMsg = ""
    @State private var didInitialLoad = false

    // === 无限滚动状态 ===
    @State private var currentPage = 0
    @State private var hasMorePages = true
    @State private var loadingMore = false
    @State private var allLoaded = false       // 已全部加载完毕

    var body: some View {
        AppNav {
            Group {
                if store.items.isEmpty && !refreshing && didInitialLoad {
                    EmptyLibraryView(isLoggedIn: session.isLoggedIn)
                } else if store.items.isEmpty && refreshing {
                    LoadingView(message: "正在从 Suno 拉取你的音乐库…")
                } else if store.items.isEmpty && !didInitialLoad {
                    EmptyLibraryView(isLoggedIn: session.isLoggedIn)
                } else {
                    SongListContent(
                        songs: store.items,
                        onLoadMore: { await loadNextPage() },
                        onRefresh: { await fullReload() },
                        loadingMore: $loadingMore,
                        allLoaded: $allLoaded,
                        onExtend: { id in extendClipID = id; showExtend = true },
                        onCover: { id in coverClipID = id; showCover = true },
                        onDelete: { song in
                            if let path = song.downloadedLocalPath {
                                try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
                            }
                            store.remove(song)
                        }
                    )
                }
            }
            .background(AppTheme.bg)
            .navigationTitle("音乐库 (\(store.items.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { Task { await fullReload() } }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(refreshing)
                }
            }
            .alert("提示", isPresented: .constant(!refreshMsg.isEmpty)) {
                Button("好") { refreshMsg = "" }
            } message: { Text(refreshMsg) }
        }
        .onAppear {
            guard !didInitialLoad, session.isLoggedIn else { return }
            didInitialLoad = true
            Task { await fullReload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SunoReloadLibrary"))) { _ in
            Task { await fullReload() }
        }
        .sheet(isPresented: $showExtend) {
            if let id = extendClipID {
                GenerateView(extendClipID: id)
            }
        }
        .sheet(isPresented: $showCover) {
            if let id = coverClipID {
                GenerateView(coverClipID: id)
            }
        }
    }

    /// 完全重新加载（下拉刷新 / 首次进入 / 创作完成通知）
    /// 策略：先加载第 1 页立即展示，然后后台渐进式加载剩余页面
    /// 注意：Suno API 的 num_total_results 始终返回 21（不可靠），不能用来判断总数！
    ///       只能依赖 has_more + clips 是否为空来判断是否还有更多数据
    func fullReload() async {
        guard session.isLoggedIn else {
            await MainActor.run { refreshMsg = "请先登录 Suno 账户" }
            return
        }
        await MainActor.run {
            refreshing = true
            currentPage = 1
            hasMorePages = true
            allLoaded = false
            loadingMore = false
        }

        do {
            // 先加载第 1 页，立即展示（用户 1 秒内看到数据）
            let resp = try await SunoAPI.shared.library(page: 1)
            let songs = resp.clips.map { Song.from(clip: $0) }
            var lastHasMore = resp.has_more == true && !songs.isEmpty

            await MainActor.run {
                if !songs.isEmpty {
                    store.replaceRemote(songs)
                }
                currentPage = 2
                hasMorePages = lastHasMore
                allLoaded = !lastHasMore
                refreshing = false  // 第 1 页已展示，停止全屏刷新
            }

            // 同步加载第 2-3 页，追加到列表（用户 2-3 秒内看到 ~60 首）
            if lastHasMore {
                for page in 2...3 {
                    try? await Task.sleep(nanoseconds: 800_000_000)  // 页间间隔防 429
                    do {
                        let resp2 = try await SunoAPI.shared.library(page: page)
                        let songs2 = resp2.clips.map { Song.from(clip: $0) }
                        lastHasMore = resp2.has_more == true && !songs2.isEmpty

                        await MainActor.run {
                            if !songs2.isEmpty {
                                store.appendRemote(songs2)
                            }
                            currentPage = page + 1
                            hasMorePages = lastHasMore
                            allLoaded = !lastHasMore
                        }

                        if !lastHasMore || songs2.isEmpty { break }
                    } catch {
                        // 第 2-3 页失败：显示错误但保留已加载的
                        DebugLog.shared.error("音乐库", "page=\(page) 失败: \(error.localizedDescription)")
                        await MainActor.run {
                            refreshMsg = "第\(page)页加载失败: \(error.localizedDescription.prefix(100))。已加载\(store.items.count)首"
                        }
                        break
                    }
                }
            }

            // 3 页加载完后，后台继续预加载剩余（不阻塞用户浏览）
            if hasMorePages && !allLoaded {
                Task { await preloadRemaining() }
            }
        } catch let error as SunoError {
            await MainActor.run {
                refreshing = false
                switch error {
                case .authExpired:
                    refreshMsg = "登录已过期，请重新登录 Suno 账户"
                case .captcha:
                    refreshMsg = "需要人机验证，请在浏览器中访问 suno.com 确认"
                default:
                    refreshMsg = "加载失败：\(error.localizedDescription)"
                }
            }
        } catch {
            await MainActor.run {
                refreshing = false
                refreshMsg = "加载失败：\(error.localizedDescription)"
            }
        }
    }

    /// 后台预加载剩余页面（用户可同时浏览已加载的歌曲）
    /// 注意：每页间隔 1.2 秒，避免触发 Suno API 的 429 限流（实测 14 页连续请求就限流）
    func preloadRemaining() async {
        guard session.isLoggedIn else { return }
        guard !loadingMore, !allLoaded, hasMorePages else { return }

        // 用局部变量控制循环，避免 @State 在后台线程的数据竞争
        var page = currentPage
        var hasMore = hasMorePages

        await MainActor.run { loadingMore = true }

        var consecutiveErrors = 0
        while hasMore {
            do {
                try? await Task.sleep(nanoseconds: 1_200_000_000)  // 每页间隔 1.2 秒防 429
                let resp = try await SunoAPI.shared.library(page: page)
                let newSongs = resp.clips.map { Song.from(clip: $0) }
                let hadNew = !newSongs.isEmpty
                hasMore = resp.has_more == true && hadNew
                page += 1

                await MainActor.run {
                    if hadNew { store.appendRemote(newSongs) }
                    currentPage = page
                    hasMorePages = hasMore
                    if !hasMore { allLoaded = true }
                }
                consecutiveErrors = 0
            } catch let error as SunoError {
                consecutiveErrors += 1
                if case .authExpired = error {
                    await MainActor.run {
                        refreshMsg = "登录已过期，请重新登录"
                        loadingMore = false
                        allLoaded = true
                    }
                    return
                }
                // 429 限流时等待更长时间重试
                if case .http(let code, _) = error, code == 429 {
                    consecutiveErrors = 0  // 429 不算致命错误，等待后重试
                    try? await Task.sleep(nanoseconds: 5_000_000_000)  // 429 时等 5 秒
                    continue
                }
                if consecutiveErrors >= 3 {
                    await MainActor.run { loadingMore = false }
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                consecutiveErrors += 1
                if consecutiveErrors >= 3 {
                    await MainActor.run { loadingMore = false }
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }

        await MainActor.run { loadingMore = false; allLoaded = true }
    }

    /// 加载下一页（无限滚动触发）
    func loadNextPage() async {
        guard !loadingMore, !allLoaded, hasMorePages, session.isLoggedIn else { return }
        await MainActor.run { loadingMore = true }

        do {
            let resp = try await SunoAPI.shared.library(page: currentPage)
            let newSongs = resp.clips.map { Song.from(clip: $0) }
            let hadNew = !newSongs.isEmpty
            await MainActor.run {
                if hadNew { store.appendRemote(newSongs) }
                currentPage += 1
                // 只依赖 has_more + 是否有新数据（不使用 num_total_results）
                hasMorePages = resp.has_more == true && hadNew
                if !hasMorePages || !hadNew { allLoaded = true }
            }
        } catch let error as SunoError {
            if case .authExpired = error {
                await MainActor.run { refreshMsg = "登录已过期，请重新登录" }
            } else if case .http(let code, _) = error, code == 429 {
                // 429 限流：静默处理，下次滚动重试
                await MainActor.run { loadingMore = false }
                return
            } else {
                await MainActor.run { refreshMsg = "加载更多失败：\(error.localizedDescription)" }
            }
        } catch {
            await MainActor.run { refreshMsg = "加载更多失败：\(error.localizedDescription)" }
        }

        await MainActor.run { loadingMore = false }
    }
}

// MARK: - 空态视图
private struct EmptyLibraryView: View {
    let isLoggedIn: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 42))
                .foregroundColor(AppTheme.surface2)
            Text(isLoggedIn ? "音乐库是空的" : "请先登录 Suno 账户")
                .foregroundColor(AppTheme.textSecondary)
            Text(isLoggedIn ? "下拉刷新，或去「创作」生成新歌" : "登录后可查看你在 Suno 的所有作品")
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 加载中视图
private struct LoadingView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().tint(AppTheme.accent).scaleEffect(1.2)
            Text(message)
                .font(.caption).foregroundColor(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 歌曲列表 + 无限滚动
private struct SongListContent: View {
    let songs: [Song]
    let onLoadMore: () async -> Void
    let onRefresh: () async -> Void
    @Binding var loadingMore: Bool
    @Binding var allLoaded: Bool
    let onExtend: (String) -> Void
    let onCover: (String) -> Void
    let onDelete: (Song) -> Void

    var body: some View {
        List {
            ForEach(songs) { song in
                SongCard(song: song) {
                    onExtend(song.id)
                } onCover: {
                    onCover(song.id)
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) { onDelete(song) } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
                // 无限滚动触发：接近列表底部时加载更多
                .onAppear {
                    if shouldTriggerLoadMore(for: song) {
                        Task { await onLoadMore() }
                    }
                }
            }

            // 底部加载指示器
            if loadingMore {
                HStack(spacing: 10) {
                    ProgressView().tint(AppTheme.accent).scaleEffect(0.8)
                    Text("正在加载更多…").font(.caption).foregroundColor(AppTheme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else if allLoaded && !songs.isEmpty {
                Text("— 已全部加载 —")
                    .font(.caption).foregroundColor(AppTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .hideScrollContentBackground()
        .refreshable { await onRefresh() }
    }

    /// 判断是否应该触发加载更多（列表倒数第 3 个 item 时触发）
    func shouldTriggerLoadMore(for song: Song) -> Bool {
        guard !loadingMore, !allLoaded else { return false }
        guard let idx = songs.firstIndex(where: { $0.id == song.id }) else { return false }
        return idx >= songs.count - 3
    }
}
