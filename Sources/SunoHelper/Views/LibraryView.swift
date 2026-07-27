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
    @State private var totalCount: Int? = nil   // 总数（来自 API）

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
            .navigationTitle(totalCount != nil ? "音乐库 (\(totalCount!))" : "音乐库")
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
    /// 策略：先连续加载前 3 页（~60 首），让用户立即看到足够多的歌曲；
    /// 然后后台继续加载剩余页面，避免只显示第一页的 ~20 首导致"1569 首但列表不全"
    func fullReload() async {
        guard session.isLoggedIn else {
            await MainActor.run { refreshMsg = "请先登录 Suno 账户" }
            return
        }
        await MainActor.run {
            refreshing = true
            currentPage = 1   // Suno API page 从 1 开始
            hasMorePages = true
            allLoaded = false
            loadingMore = false
        }

        // 连续加载前 3 页（或直到无更多数据），合并后一次性写入 store
        var allSongs: [Song] = []
        let initialPages = 3
        var actualLoadedPages = 0

        for page in 1...initialPages {
            do {
                let resp = try await SunoAPI.shared.library(page: page)
                let songs = resp.clips.map { Song.from(clip: $0) }
                if songs.isEmpty { break }           // 空页说明到底了
                allSongs.append(contentsOf: songs)
                actualLoadedPages += 1
                await MainActor.run {
                    totalCount = resp.num_total_results
                    // 只要还有数据就继续（不依赖 has_more，该字段可能不准）
                    hasMorePages = resp.has_more == true || (totalCount != nil && allSongs.count < totalCount!)
                }
                if resp.has_more != true && (totalCount == nil || allSongs.count >= totalCount!) { break }
            } catch {
                // 单页失败不终止整体刷新，已加载的数据仍然有效
                await MainActor.run { refreshMsg = "第 \(page) 页加载失败，已加载前 \(allSongs.count) 首" }
                break
            }
        }

        await MainActor.run {
            if !allSongs.isEmpty {
                store.replaceRemote(allSongs)
            }
            currentPage = actualLoadedPages + 1      // 下一页从已加载的下一页开始
            allLoaded = !hasMorePages               // 根据实际判断是否全部加载完
            refreshing = false
        }

        // 前台预加载：如果还有更多数据且未全部加载，继续在后台拉取剩余页面
        if hasMorePages && !allLoaded {
            Task { await preloadRemaining() }
        }
    }

    /// 后台预加载剩余页面（用户可同时浏览已加载的歌曲）
    func preloadRemaining() async {
        // 防止重复触发
        guard !loadingMore, !allLoaded, hasMorePages else { return }
        await MainActor.run { loadingMore = true }

        while hasMorePages && !allLoaded {
            do {
                let resp = try await SunoAPI.shared.library(page: currentPage)
                let newSongs = resp.clips.map { Song.from(clip: $0) }
                let hadNew = !newSongs.isEmpty
                await MainActor.run {
                    if hadNew { store.appendRemote(newSongs) }
                    currentPage += 1
                    // 智能判断：已知总数时以总数为准；否则依赖 has_more
                    if let total = totalCount {
                        hasMorePages = store.items.count < total
                    } else {
                        hasMorePages = resp.has_more == true && hadNew
                    }
                    allLoaded = !hasMorePages || !hadNew
                }
                // 每页之间稍作间隔，避免请求过于密集
                try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms
            } catch {
                // 预加载失败静默重试下次滚动触发
                await MainActor.run { loadingMore = false }
                return
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
                // 智能判断：已知 totalCount 时以"已加载数 < 总数"为准，不依赖不可靠的 has_more
                if let total = totalCount {
                    hasMorePages = store.items.count < total
                } else {
                    hasMorePages = resp.has_more == true && hadNew
                }
                if !hasMorePages || !hadNew { allLoaded = true }
                totalCount = resp.num_total_results
            }
        } catch {
            // 单页加载失败不终止分页，下次滚动到底部会重试
            await MainActor.run { refreshMsg = "加载更多失败，稍后重试：\(error.localizedDescription)" }
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
