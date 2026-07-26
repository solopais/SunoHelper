import SwiftUI

struct LibraryView: View {
    @StateObject private var store = SongStore.shared
    @State private var showExtend = false
    @State private var extendClipID: String?
    @State private var refreshing = false
    @State private var refreshMsg = ""

    var body: some View {
        AppNav {
            Group {
                if store.items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 42))
                            .foregroundColor(AppTheme.surface2)
                        Text("还没有歌曲")
                            .foregroundColor(AppTheme.textSecondary)
                        Text("去「创作」用提示词生成你的第一首歌")
                            .font(.caption)
                            .foregroundColor(AppTheme.textSecondary)
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
                    .refreshable { await refreshPending() }
                }
            }
            .background(AppTheme.bg)
            .navigationTitle("音乐库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { Task { await refreshPending() } }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(refreshing)
                }
            }
            .alert("提示", isPresented: .constant(!refreshMsg.isEmpty)) {
                Button("好") { refreshMsg = "" }
            } message: { Text(refreshMsg) }
        }
        .sheet(isPresented: $showExtend) {
            if let id = extendClipID {
                GenerateView(extendClipID: id)
            }
        }
    }

    func refreshPending() async {
        let pending = store.items.filter { $0.pending }
        guard !pending.isEmpty else { return }
        await MainActor.run { refreshing = true }
        do {
            let ids = pending.map { $0.id }
            let clips = try await SunoAPI.shared.feed(ids: ids)
            for c in clips {
                await MainActor.run { store.update(Song.from(clip: c)) }
            }
        } catch {
            await MainActor.run { refreshMsg = "刷新失败：\(error.localizedDescription)" }
        }
        await MainActor.run { refreshing = false }
    }
}
