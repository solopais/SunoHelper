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
    /// 重要：不再依赖 has_more（API 返回 has_more=false 但 num_total=1571，矛盾）
    ///       改为根据 num_total_results 和已加载数量判断是否继续翻页
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
            let numTotal = resp.num_total_results ?? 0
            // 不再依赖 has_more！根据 num_total 和已加载数量判断
            var lastShouldContinue = !songs.isEmpty && (numTotal == 0 || songs.count < numTotal)

            DebugLog.shared.info("音乐库", "fullReload page=1 clips=\(songs.count) num_total=\(numTotal) has_more=\(resp.has_more ?? false) → shouldContinue=\(lastShouldContinue)")

            await MainActor.run {
                if !songs.isEmpty {
                    store.replaceRemote(songs)
                }
                currentPage = 2
                hasMorePages = lastShouldContinue
                allLoaded = !lastShouldContinue
                refreshing = false  // 第 1 页已展示，停止全屏刷新
            }

            // 同步加载第 2-3 页，追加到列表
            if lastShouldContinue {
                for page in 2...3 {
                    try? await Task.sleep(nanoseconds: 800_000_000)  // 页间间隔防 429
                    do {
                        let resp2 = try await SunoAPI.shared.library(page: page)
                        let songs2 = resp2.clips.map { Song.from(clip: $0) }

                        // 去重：检查新歌曲是否已存在
                        let existingIDs = Set(store.items.map { $0.id })
                        let uniqueSongs = songs2.filter { !existingIDs.contains($0.id) }

                        let numTotal2 = resp2.num_total_results ?? 0
                        // 如果返回的歌曲全部重复，说明分页不工作
                        if songs2.isEmpty {
                            lastShouldContinue = false
                        } else if uniqueSongs.isEmpty {
                            DebugLog.shared.warn("音乐库", "page=\(page) 返回\(songs2.count)首但全部重复，分页可能不工作，停止")
                            lastShouldContinue = false
                        } else {
                            lastShouldContinue = numTotal2 == 0 || (store.items.count + uniqueSongs.count) < numTotal2
                        }

                        DebugLog.shared.info("音乐库", "fullReload page=\(page) clips=\(songs2.count) unique=\(uniqueSongs.count) num_total=\(numTotal2) → shouldContinue=\(lastShouldContinue)")

                        await MainActor.run {
                            if !uniqueSongs.isEmpty {
                                store.appendRemote(uniqueSongs)
                            }
                            currentPage = page + 1
                            hasMorePages = lastShouldContinue
                            allLoaded = !lastShouldContinue
                        }

                        if !lastShouldContinue || songs2.isEmpty { break }
                    } catch {
                        DebugLog.shared.error("音乐库", "page=\(page) 失败: \(error.localizedDescription)")
                        await MainActor.run {
                            refreshMsg = "第\(page)页加载失败: \(error.localizedDescription.prefix(100))。已加载\(store.items.count)首"
                        }
                        break
                    }
                }
            }

            // 3 页加载完后，后台继续预加载剩余
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
    /// 不再依赖 has_more，根据 num_total_results 和已加载数量判断
    /// 加去重逻辑：如果返回歌曲全部重复，说明分页不工作，停止加载
    func preloadRemaining() async {
        guard session.isLoggedIn else { return }
        guard !loadingMore, !allLoaded, hasMorePages else { return }

        var page = currentPage
        var hasMore = hasMorePages

        await MainActor.run { loadingMore = true }

        var consecutiveErrors = 0
        while hasMore {
            do {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                let resp = try await SunoAPI.shared.library(page: page)
                let newSongs = resp.clips.map { Song.from(clip: $0) }
                let numTotal = resp.num_total_results ?? 0

                // 去重
                let existingIDs = Set(store.items.map { $0.id })
                let uniqueSongs = newSongs.filter { !existingIDs.contains($0.id) }

                if newSongs.isEmpty {
                    hasMore = false
                } else if uniqueSongs.isEmpty {
                    DebugLog.shared.warn("音乐库", "preload page=\(page) 返回\(newSongs.count)首但全部重复，停止")
                    hasMore = false
                } else {
                    hasMore = numTotal == 0 || (store.items.count + uniqueSongs.count) < numTotal
                }

                DebugLog.shared.info("音乐库", "preload page=\(page) clips=\(newSongs.count) unique=\(uniqueSongs.count) total_loaded=\(store.items.count + uniqueSongs.count)/\(numTotal)")

                page += 1

                await MainActor.run {
                    if !uniqueSongs.isEmpty { store.appendRemote(uniqueSongs) }
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
                if case .http(let code, _) = error, code == 429 {
                    consecutiveErrors = 0
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
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
    /// 不再依赖 has_more，根据 num_total_results 和已加载数量判断
    func loadNextPage() async {
        guard !loadingMore, !allLoaded, hasMorePages, session.isLoggedIn else { return }
        await MainActor.run { loadingMore = true }

        do {
            let resp = try await SunoAPI.shared.library(page: currentPage)
            let newSongs = resp.clips.map { Song.from(clip: $0) }
            let numTotal = resp.num_total_results ?? 0

            // 去重
            let existingIDs = Set(store.items.map { $0.id })
            let uniqueSongs = newSongs.filter { !existingIDs.contains($0.id) }

            var shouldContinue = false
            if newSongs.isEmpty {
                shouldContinue = false
            } else if uniqueSongs.isEmpty {
                DebugLog.shared.warn("音乐库", "loadNextPage page=\(currentPage) 全部重复，停止")
                shouldContinue = false
            } else {
                shouldContinue = numTotal == 0 || (store.items.count + uniqueSongs.count) < numTotal
            }

            await MainActor.run {
                if !uniqueSongs.isEmpty { store.appendRemote(uniqueSongs) }
                currentPage += 1
                hasMorePages = shouldContinue
                if !shouldContinue { allLoaded = true }
            }
        } catch let error as SunoError {
            if case .authExpired = error {
                await MainActor.run { refreshMsg = "登录已过期，请重新登录" }
            } else if case .http(let code, _) = error, code == 429 {
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
