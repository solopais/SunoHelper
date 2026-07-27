#!/usr/bin/env python3
"""Fix SunoAPI.swift and LibraryView.swift for Round 14"""
import os

os.chdir('C:/Users/22603/WorkBuddy/2026-07-23-16-41-40/SunoApp')

# === 1. 修改 SunoAPI.swift ===
filepath = 'Sources/SunoHelper/Network/SunoAPI.swift'
with open(filepath, 'r', encoding='utf-8') as f:
    content = f.read()

# 1a. 去掉 uploadSession 属性
old_session = r'''    /// 专用上传 session：避免 URLSession.shared 的 keep-alive 连接复用问题（-1005）
    private static let uploadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 1
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private func makeRequest'''

new_session = r'''    private func makeRequest'''

if old_session in content:
    content = content.replace(old_session, new_session)
    print("[OK] Removed uploadSession")
else:
    print("[WARN] uploadSession block not found")

# 1b. 替换 uploadFileToS3 方法
# 找到方法起始和结束
upload_start = content.find(r'''    /// Step 2: 上传文件到 S3''')
if upload_start == -1:
    print("[ERROR] uploadFileToS3 start not found")
else:
    # 方法结束标记：uploadAudioOnly 的注释
    upload_end_marker = r'''        /// 音频上传完整流程'''
    upload_end = content.find(upload_end_marker, upload_start)
    if upload_end == -1:
        print("[ERROR] uploadFileToS3 end not found")
    else:
        new_upload = r'''    /// Step 2: 上传文件到 S3（使用预签名 URL + form fields）
    /// 修复 -1005：ephemeral session + data(for:) + httpBody，失败后 shared session 重试
    /// 根因：upload(for:fromFile:) + Connection:close 均无效（URLSession 覆盖 Connection header）
    /// 新方案：用 data(for:) + httpBody 避免文件流 API 的潜在 bug，ephemeral session 避免连接复用
    func uploadFileToS3(presignedURL: String, fields: [String: String],
                        fileData: Data, fileName: String, mimeType: String) async throws {
        try await run {
            let s3URL = URL(string: presignedURL)!
            let boundary = "Boundary-\(UUID().uuidString)"
            let fieldsContentType = fields["Content-Type"] ?? mimeType

            DebugLog.shared.info("S3上传", "fields=\(fields.keys.sorted()) CT=\(fieldsContentType) url=\(presignedURL)")

            // 构造 multipart body
            var body = Data()
            for (key, value) in fields {
                body.append(Data("--\(boundary)\r\n".utf8))
                body.append(Data("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".utf8))
                body.append(Data("\(value)\r\n".utf8))
            }
            // file 字段（必须最后）
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"upload.mp3\"\r\n".utf8))
            body.append(Data("Content-Type: \(fieldsContentType)\r\n\r\n".utf8))
            body.append(fileData)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))

            DebugLog.shared.info("S3上传", "body=\(body.count)B → ephemeral+data(for:)")

            // 构造请求（用 httpBody 而非 upload(fromFile:)）
            var req = URLRequest(url: s3URL)
            req.httpMethod = "POST"
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            req.timeoutInterval = 300

            // 尝试 1: ephemeral session + data(for:)
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.httpMaximumConnectionsPerHost = 1
            config.timeoutIntervalForRequest = 300
            config.timeoutIntervalForResource = 600
            let session = URLSession(configuration: config)

            do {
                let (data, resp) = try await session.data(for: req)
                if let http = resp as? HTTPURLResponse {
                    DebugLog.shared.info("S3上传", "ephemeral响应: \(http.statusCode)")
                    if !(200...299).contains(http.statusCode) {
                        let msg = String(data: data, encoding: .utf8) ?? "(empty)"
                        DebugLog.shared.error("S3上传", "ephemeral失败[\(http.statusCode)]: \(msg.prefix(300))")
                        throw SunoError.uploadFailed("S3[\(http.statusCode)]: \(msg.prefix(200))")
                    }
                    DebugLog.shared.success("S3上传", "ephemeral上传成功 (\(http.statusCode))")
                }
                return
            } catch let error as URLError where error.code == .networkConnectionLost {
                DebugLog.shared.warn("S3上传", "ephemeral -1005，3秒后用 shared 重试...")
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }

            // 尝试 2: shared session + data(for:)
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse {
                    DebugLog.shared.info("S3上传", "shared响应: \(http.statusCode)")
                    if !(200...299).contains(http.statusCode) {
                        let msg = String(data: data, encoding: .utf8) ?? "(empty)"
                        DebugLog.shared.error("S3上传", "shared失败[\(http.statusCode)]: \(msg.prefix(300))")
                        throw SunoError.uploadFailed("S3[\(http.statusCode)]: \(msg.prefix(200))")
                    }
                    DebugLog.shared.success("S3上传", "shared重试成功 (\(http.statusCode))")
                }
                return
            } catch let error as URLError where error.code == .networkConnectionLost {
                DebugLog.shared.error("S3上传", "shared 也 -1005。两种 session 均失败，可能是 HTTP/2 兼容性问题")
                throw SunoError.network(error)
            }
        }
    }

'''
        content = content[:upload_start] + new_upload + content[upload_end:]
        print("[OK] Replaced uploadFileToS3")

# 1c. 修改 library 方法的日志（打印完整 URL 包括 num_results）
old_log = r'''            DebugLog.shared.info("音乐库", "GET /api/feed/v2?page=\(safePage)")'''
new_log = r'''            DebugLog.shared.info("音乐库", "GET /api/feed/v2?page=\(safePage)&num_results=50")'''
if old_log in content:
    content = content.replace(old_log, new_log)
    print("[OK] Updated library log")

with open(filepath, 'w', encoding='utf-8') as f:
    f.write(content)
print("[DONE] SunoAPI.swift updated")

# === 2. 修改 LibraryView.swift ===
filepath2 = 'Sources/SunoHelper/Views/LibraryView.swift'
with open(filepath2, 'r', encoding='utf-8') as f:
    content2 = f.read()

# 2a. 替换 fullReload 方法
old_fullreload_start = r'''    /// 完全重新加载（下拉刷新 / 首次进入 / 创作完成通知）'''
old_fullreload_end = r'''    /// 后台预加载剩余页面'''

fr_start = content2.find(old_fullreload_start)
fr_end = content2.find(old_fullreload_end)

if fr_start == -1 or fr_end == -1:
    print("[ERROR] fullReload boundaries not found")
else:
    new_fullreload = r'''    /// 完全重新加载（下拉刷新 / 首次进入 / 创作完成通知）
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

'''
    content2 = content2[:fr_start] + new_fullreload + content2[fr_end:]
    print("[OK] Replaced fullReload")

# 2b. 替换 preloadRemaining 方法
old_preload_start = r'''    /// 后台预加载剩余页面'''
old_preload_end = r'''    /// 加载下一页'''

pr_start = content2.find(old_preload_start)
pr_end = content2.find(old_preload_end)

if pr_start == -1 or pr_end == -1:
    print("[ERROR] preloadRemaining boundaries not found")
else:
    new_preload = r'''    /// 后台预加载剩余页面（用户可同时浏览已加载的歌曲）
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

'''
    content2 = content2[:pr_start] + new_preload + content2[pr_end:]
    print("[OK] Replaced preloadRemaining")

# 2c. 替换 loadNextPage 方法
old_loadnext_start = r'''    /// 加载下一页（无限滚动触发）'''
old_loadnext_end = r'''}\n\n// MARK: - 空态视图'''

ln_start = content2.find(old_loadnext_start)
ln_end = content2.find(r'''// MARK: - 空态视图''')

if ln_start == -1 or ln_end == -1:
    print("[ERROR] loadNextPage boundaries not found")
else:
    new_loadnext = r'''    /// 加载下一页（无限滚动触发）
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

'''
    # 找到 loadNextPage 结束位置（在 // MARK: - 空态视图 之前）
    ln_end_pos = content2.find(r'''// MARK: - 空态视图''')
    if ln_end_pos != -1:
        content2 = content2[:ln_start] + new_loadnext + '\n' + content2[ln_end_pos:]
        print("[OK] Replaced loadNextPage")

with open(filepath2, 'w', encoding='utf-8') as f:
    f.write(content2)
print("[DONE] LibraryView.swift updated")
