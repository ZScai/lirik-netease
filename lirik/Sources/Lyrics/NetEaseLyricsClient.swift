//
//  NetEaseLyricsClient.swift
//  lirik
//
//  Fallback lyrics source when LRCLIB misses — important for 网易云 catalogue.
//

import Foundation

final class NetEaseLyricsClient: Sendable {

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchLyrics(
        title: String,
        artist: String,
        album: String? = nil,
        duration: TimeInterval? = nil
    ) async throws -> LRCLIBResult {
        guard let songID = try await searchSongID(
            title: title, artist: artist, album: album, duration: duration
        ) else {
            return .notFound
        }
        return try await fetchLyric(songID: songID)
    }

    private func searchSongID(
        title: String,
        artist: String,
        album: String?,
        duration: TimeInterval?
    ) async throws -> Int? {
        _ = album
        let parts = [title, artist].filter { !$0.isEmpty && $0 != "Unknown Artist" }
        let query = parts.joined(separator: " ")
        guard !query.isEmpty else { return nil }

        guard let url = URL(string: "https://music.163.com/api/cloudsearch/pc") else {
            throw LRCLIBError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        request.setValue("Lirik/1.0 (macOS TouchBar Lyric Widget)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        request.httpBody = "s=\(encoded)&type=1&limit=10".data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LRCLIBError.networkError("NetEase search HTTP error")
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]],
              !songs.isEmpty else {
            return nil
        }

        let targetTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let targetArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let targetDurMs = (duration ?? 0) > 0 ? Int(((duration ?? 0) * 1000).rounded()) : nil

        func score(_ song: [String: Any]) -> Int {
            var s = 0
            let name = ((song["name"] as? String) ?? "").lowercased()
            let artists = ((song["ar"] as? [[String: Any]]) ?? [])
                .compactMap { $0["name"] as? String }
                .joined(separator: "/")
                .lowercased()
            let dt = song["dt"] as? Int ?? 0

            if name == targetTitle { s += 100 }
            else if name.contains(targetTitle) || targetTitle.contains(name) { s += 40 }

            if !targetArtist.isEmpty && targetArtist != "unknown artist" {
                if artists.contains(targetArtist) { s += 80 }
            }

            if let targetDurMs, dt > 0 {
                let delta = abs(dt - targetDurMs)
                if delta <= 2000 { s += 60 }
                else if delta <= 5000 { s += 30 }
                else if delta >= 60000 { s -= 40 }
            }
            return s
        }

        guard let best = songs.max(by: { score($0) < score($1) }),
              let id = best["id"] as? Int else {
            return nil
        }

        let bestScore = score(best)
        if bestScore >= 80 {
            NSLog("[NetEaseLyrics] matched id=\(id) score=\(bestScore) for \(title) — \(artist)")
            return id
        }

        // Soft fallback: first title-overlapping hit
        if let first = songs.first,
           let fid = first["id"] as? Int,
           let name = (first["name"] as? String)?.lowercased(),
           name.contains(targetTitle) || targetTitle.contains(name) {
            return fid
        }
        return nil
    }

    private func fetchLyric(songID: Int) async throws -> LRCLIBResult {
        guard var components = URLComponents(string: "https://music.163.com/api/song/lyric") else {
            throw LRCLIBError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "id", value: String(songID)),
            URLQueryItem(name: "lv", value: "1"),
            URLQueryItem(name: "kv", value: "1"),
            URLQueryItem(name: "tv", value: "-1")
        ]
        guard let url = components.url else { throw LRCLIBError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        request.setValue("Lirik/1.0 (macOS TouchBar Lyric Widget)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LRCLIBError.networkError("NetEase lyric HTTP error")
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .notFound
        }

        let lrc = ((root["lrc"] as? [String: Any])?["lyric"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !lrc.isEmpty, lrc.contains("[") {
            return .synced(id: songID, lrcText: lrc, plainLyrics: nil)
        }
        if !lrc.isEmpty {
            return .plainOnly(id: songID, plainText: lrc)
        }
        return .notFound
    }
}
