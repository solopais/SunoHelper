import SwiftUI
import Combine

struct LibraryView: View {
    @StateObject private var store = SongStore.shared
    @StateObject private var session = SunoSession.shared
    @State private var showExtend = false
    @State private var extendClipID: String?
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
                        loadingMore: $loadingMore,
                        allLoaded: $allLoaded,
                        onExtend: { id in extendClipID = id; showExtend = true },
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
            .navigationTitle("音乐库")
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
    }

    /// 完全重新加载（下拉刷新 / 首次进入）
    func fullReload() async {
        guard session.isLoggedIn else {
            await MainActor.run { refreshMsg = "请先登录 Suno 账户" }
            return
        }
        await MainActor.run {
            refreshing = true
            currentPage = 0
            hasMorePages = true
            allLoaded = false
            loadingMore = false
        }

        do {
            let resp = try await SunoAPI.shared.library(page: 0)
            let songs = resp.clips.map { Song.from(clip: $0) }
            await MainActor.run {
                store.mergeRemote(songs)
                currentPage = 1
                hasMorePages = resp.has_more == true
                allLoaded = !hasMorePages
                totalCount = resp.num_total_results
            }
        } catch {
            await MainActor.run { refreshMsg = "拉取失败：\(error.localizedDescription)" }
        }

        await MainActor.run { refreshing = false }
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
                hasMorePages = resp.has_more == true && hadNew
                if !hasMorePages || !hadNew { allLoaded = true }
                totalCount = resp.num_total_results
            }
        } catch {
            await MainActor.run {
                allLoaded = true  // 出错也停止，避免死循环
            }
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
    @Binding var loadingMore: Bool
    @Binding var allLoaded: Bool
    let onExtend: (String) -> Void
    let onDelete: (Song) -> Void

    var body: some View {
        List {
            ForEach(songs) { song in
                SongCard(song: song) {
                    onExtend(song.id)
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
        .refreshable { await onLoadMore() }
    }

    /// 判断是否应该触发加载更多（列表倒数第 3 个 item 时触发）
    func shouldTriggerLoadMore(for song: Song) -> Bool {
        guard !loadingMore, !allLoaded else { return false }
        guard let idx = songs.firstIndex(where: { $0.id == song.id }) else { return false }
        return idx >= songs.count - 3
    }
}
