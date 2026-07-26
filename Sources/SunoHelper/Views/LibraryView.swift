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

    var body: some View {
        AppNav {
            Group {
                if store.items.isEmpty {
                    VStack(spacing: 12) {
                        if refreshing {
                            ProgressView().tint(AppTheme.accent)
                            Text("正在从 Suno 拉取你的音乐库…")
                                .font(.caption).foregroundColor(AppTheme.textSecondary)
                        } else {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 42))
                                .foregroundColor(AppTheme.surface2)
                            Text(session.isLoggedIn ? "音乐库是空的" : "请先登录 Suno 账户")
                                .foregroundColor(AppTheme.textSecondary)
                            Text(session.isLoggedIn ? "下拉刷新，或去「创作」生成新歌" : "登录后可查看你在 Suno 的所有作品")
                                .font(.caption)
                                .foregroundColor(AppTheme.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(store.items) { song in
                            SongCard(song: song) {
                                extendClipID = song.id
                                showExtend = true
                            }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    if let path = song.downloadedLocalPath {
                                        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
                                    }
                                    store.remove(song)
                                } label: { Label("删除", systemImage: "trash") }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .hideScrollContentBackground()
                    .refreshable { await reloadLibrary() }
                }
            }
            .background(AppTheme.bg)
            .navigationTitle("音乐库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { Task { await reloadLibrary() } }) {
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
            Task { await reloadLibrary() }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SunoReloadLibrary"))) { _ in
            Task { await reloadLibrary() }
        }
        .sheet(isPresented: $showExtend) {
            if let id = extendClipID {
                GenerateView(extendClipID: id)
            }
        }
    }

    /// 从 Suno 拉取当前账户的全部歌曲（分页，最多 10 页兜底）
    func reloadLibrary() async {
        guard session.isLoggedIn else {
            await MainActor.run { refreshMsg = "请先登录 Suno 账户" }
            return
        }
        await MainActor.run { refreshing = true }
        do {
            var page = 0
            var all: [Song] = []
            while page < 10 {
                let resp = try await SunoAPI.shared.library(page: page)
                all.append(contentsOf: resp.clips.map { Song.from(clip: $0) })
                if resp.has_more == true { page += 1 } else { break }
            }
            await MainActor.run { store.mergeRemote(all) }
        } catch {
            await MainActor.run { refreshMsg = "拉取失败：\(error.localizedDescription)" }
        }
        await MainActor.run { refreshing = false }
    }
}
