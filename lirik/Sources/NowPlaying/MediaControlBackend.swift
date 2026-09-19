//
//  MediaControlBackend.swift
//  lirik
//
//  System Now Playing backend via mediaremote-adapter / media-control.
//  Works on macOS 15.4+ where direct MediaRemote.framework access is blocked.
//  Same approach as TouchBarLyrics / Lyrimuse: run Apple-signed /usr/bin/perl
//  (or Homebrew media-control) which is entitled to MediaRemote, streaming
//  JSON updates to stdout.
//
//  Launch resolution order:
//  1. Bundled mediaremote-adapter.pl + MediaRemoteAdapter.framework
//  2. Homebrew `media-control` on PATH (/opt/homebrew or /usr/local)
//
//  Covers NetEase Cloud Music (com.netease.163music) and any other app that
//  publishes to macOS Now Playing — no AppleScript dictionary required.
//

import Foundation

/// Streams system-wide now-playing info via mediaremote-adapter or media-control.
final class MediaControlBackend {

    // MARK: - Launch mode

    private enum LaunchMode {
        /// `/usr/bin/perl` + bundled script + framework (TouchBarLyrics style).
        case bundledPerl(scriptURL: URL, frameworkURL: URL)
        /// Homebrew `media-control stream …` (preferred when no arm64 framework).
        case mediaControlCLI(executableURL: URL)
    }

    // MARK: - State

    private var process: Process?
    private var buffer = Data()
    private var raw: [String: Any] = [:]
    private var onUpdate: ((NowPlayingTrack?) -> Void)?
    private var stopped = false
    private var pollTimer: Timer?
    private var tickTimer: Timer?
    private var polling = false
    private var launchMode: LaunchMode?

    /// True when either a bundled adapter or media-control CLI is available.
    private(set) var isAvailable: Bool = false

    // MARK: - Known NetEase / player bundle IDs

    static let netEaseBundleID = "com.netease.163music"
    static let spotifyBundleID = "com.spotify.client"
    static let appleMusicBundleID = "com.apple.Music"

    // MARK: - Init

    init() {
        launchMode = Self.resolveLaunchMode()
        isAvailable = launchMode != nil
        if let mode = launchMode {
            NSLog("[MediaControlBackend] Available via \(Self.describe(mode))")
        } else {
            NSLog("[MediaControlBackend] Not available — install brew media-control or bundle MediaRemoteAdapter.framework")
        }
    }

    // MARK: - Public API

    /// One-shot fetch using `get --no-artwork --micros`.
    func fetchNowPlaying(completion: @escaping (NowPlayingTrack?) -> Void) {
        guard let mode = launchMode else {
            completion(nil)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let data = Self.runOnce(mode: mode, arguments: ["get", "--no-artwork", "--micros"])
            DispatchQueue.main.async {
                guard let self else {
                    completion(nil)
                    return
                }
                if let data, let obj = try? JSONSerialization.jsonObject(with: data) {
                    if let dict = obj as? [String: Any] {
                        self.raw = dict.filter { !($0.value is NSNull) }
                        completion(self.currentTrack())
                    } else {
                        self.raw = [:]
                        completion(nil)
                    }
                } else {
                    completion(nil)
                }
            }
        }
    }

    /// Starts the stream process and calls `onUpdate` on the main thread.
    func startStreaming(onUpdate: @escaping (NowPlayingTrack?) -> Void) {
        self.onUpdate = onUpdate
        stopped = false
        launchStream()

        // Periodic full `get` to correct missed seek/position updates (TouchBarLyrics pattern).
        let poll = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(poll, forMode: .common)
        pollTimer = poll

        // Local tick so elapsed advances between stream pushes while playing.
        let tick = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, !self.stopped else { return }
            if let track = self.currentTrack() {
                self.onUpdate?(track)
            }
        }
        RunLoop.main.add(tick, forMode: .common)
        tickTimer = tick
    }

    /// Stops the stream and timers.
    func stopStreaming() {
        stopped = true
        pollTimer?.invalidate()
        pollTimer = nil
        tickTimer?.invalidate()
        tickTimer = nil
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        onUpdate = nil
        buffer = Data()
        raw = [:]
    }

    // MARK: - Launch resolution

    private static func resolveLaunchMode() -> LaunchMode? {
        let bundle = Bundle(for: MediaControlBackend.self)
        let resourceURL = bundle.resourceURL

        let scriptCandidates: [URL?] = [
            resourceURL?.appendingPathComponent("mediaremote-adapter.pl"),
            bundle.url(forResource: "mediaremote-adapter", withExtension: "pl"),
        ]
        let frameworkCandidates: [URL?] = [
            resourceURL?.appendingPathComponent("MediaRemoteAdapter.framework"),
            bundle.url(forResource: "MediaRemoteAdapter", withExtension: "framework"),
        ]

        if let script = scriptCandidates.compactMap({ $0 }).first(where: { FileManager.default.isReadableFile(atPath: $0.path) }),
           let framework = frameworkCandidates.compactMap({ $0 }).first(where: {
               var isDir: ObjCBool = false
               return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue
           }) {
            return .bundledPerl(scriptURL: script, frameworkURL: framework)
        }

        if let cli = findMediaControlCLI() {
            return .mediaControlCLI(executableURL: cli)
        }

        return nil
    }

    private static func findMediaControlCLI() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/media-control",
            "/usr/local/bin/media-control",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        // Last resort: PATH lookup via /usr/bin/which (works when Pock inherits a login PATH).
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["media-control"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        do {
            try which.run()
            which.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty,
               FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        } catch {
            // ignore
        }
        return nil
    }

    private static func describe(_ mode: LaunchMode) -> String {
        switch mode {
        case .bundledPerl:
            return "bundled mediaremote-adapter"
        case .mediaControlCLI(let url):
            return "media-control at \(url.path)"
        }
    }

    // MARK: - Process helpers

    private static func makeProcess(mode: LaunchMode, subcommandAndFlags: [String]) -> Process {
        let process = Process()
        switch mode {
        case let .bundledPerl(scriptURL, frameworkURL):
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = [scriptURL.path, frameworkURL.path] + subcommandAndFlags
        case let .mediaControlCLI(executableURL):
            process.executableURL = executableURL
            process.arguments = subcommandAndFlags
        }
        return process
    }

    private static func runOnce(mode: LaunchMode, arguments: [String]) -> Data? {
        let process = makeProcess(mode: mode, subcommandAndFlags: arguments)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return pipe.fileHandleForReading.readDataToEndOfFile()
        } catch {
            NSLog("[MediaControlBackend] runOnce failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func launchStream() {
        guard let mode = launchMode, !stopped else { return }

        let process = Self.makeProcess(
            mode: mode,
            subcommandAndFlags: ["stream", "--no-artwork", "--micros", "--debounce=100"]
        )
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                self?.consume(data)
            }
        }

        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                NSLog("[MediaControlBackend] stream ended — restarting in 2s")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.launchStream()
                }
            }
        }

        do {
            try process.run()
            self.process = process
            NSLog("[MediaControlBackend] stream started (pid \(process.processIdentifier)) via \(Self.describe(mode))")
        } catch {
            NSLog("[MediaControlBackend] failed to start stream: \(error.localizedDescription)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                guard let self, !self.stopped else { return }
                self.launchStream()
            }
        }
    }

    private func poll() {
        guard !polling, !stopped, let mode = launchMode else { return }
        polling = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = Self.runOnce(mode: mode, arguments: ["get", "--no-artwork", "--micros"])
            DispatchQueue.main.async {
                self?.polling = false
                self?.applyPoll(data)
            }
        }
    }

    private func applyPoll(_ data: Data?) {
        guard !stopped else { return }
        guard let data, !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            return
        }
        if let dict = obj as? [String: Any] {
            raw = dict.filter { !($0.value is NSNull) }
        } else {
            raw = [:]
        }
        onUpdate?(currentTrack())
    }

    // MARK: - JSON stream parsing

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            handleLine(line)
        }
    }

    private func handleLine(_ line: Data) {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "data",
              let payload = obj["payload"] as? [String: Any]
        else { return }

        let isDiff = obj["diff"] as? Bool ?? false
        if !isDiff { raw = [:] }

        // Drop stale timing when the title changes. Keep artist/album from the
        // previous payload only until the next diff replaces them — clearing
        // artist to "Unknown" made LRCLIB miss and poison the notFound cache.
        if let newTitle = payload["title"] as? String,
           newTitle != (raw["title"] as? String) {
            if payload["elapsedTimeMicros"] == nil && payload["elapsedTime"] == nil {
                raw.removeValue(forKey: "elapsedTimeMicros")
                raw.removeValue(forKey: "timestampEpochMicros")
                raw.removeValue(forKey: "elapsedTime")
                raw.removeValue(forKey: "timestamp")
            }
            if payload["durationMicros"] == nil && payload["duration"] == nil {
                raw.removeValue(forKey: "durationMicros")
                raw.removeValue(forKey: "duration")
            }
        }

        for (k, v) in payload {
            if v is NSNull {
                raw.removeValue(forKey: k)
            } else {
                raw[k] = v
            }
        }

        onUpdate?(currentTrack())
    }

    // MARK: - Track mapping

    private func currentTrack() -> NowPlayingTrack? {
        guard let title = raw["title"] as? String, !title.isEmpty else {
            return nil
        }

        let artist = (raw["artist"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = raw["album"] as? String
        let playing = raw["playing"] as? Bool ?? false
        let playbackRate = (raw["playbackRate"] as? NSNumber)?.doubleValue
            ?? (playing ? 1.0 : 0.0)
        let bundleID = raw["bundleIdentifier"] as? String

        let duration = Self.seconds(
            microsKey: "durationMicros",
            secondsKey: "duration",
            in: raw
        )
        let baseElapsed = Self.seconds(
            microsKey: "elapsedTimeMicros",
            secondsKey: "elapsedTime",
            in: raw
        )

        let elapsed: TimeInterval?
        if let base = baseElapsed {
            if playing, let tsMicros = Self.int64(raw["timestampEpochMicros"]) {
                let dt = Date().timeIntervalSince1970 - Double(tsMicros) / 1_000_000.0
                let live = base + max(0, dt) * (playbackRate > 0 ? playbackRate : 1.0)
                if let d = duration, d > 0 {
                    elapsed = min(live, d)
                } else {
                    elapsed = live
                }
            } else {
                elapsed = base
            }
        } else {
            elapsed = nil
        }

        return NowPlayingTrack(
            title: title,
            artist: (artist?.isEmpty == false) ? artist! : "Unknown Artist",
            album: (album?.isEmpty == false) ? album : nil,
            duration: duration,
            elapsedTime: elapsed,
            isPlaying: playing || playbackRate > 0,
            source: Self.source(forBundleID: bundleID)
        )
    }

    private static func source(forBundleID bundleID: String?) -> NowPlayingSource {
        guard let id = bundleID else { return .system }
        switch id {
        case spotifyBundleID:
            return .spotify
        case appleMusicBundleID:
            return .appleMusic
        case netEaseBundleID:
            return .netease
        case let s where s.hasPrefix("com.apple.Safari")
            || s.contains("chrome")
            || s.contains("firefox")
            || s.contains("Chromium")
            || s == "company.thebrowser.Browser"
            || s == "com.brave.Browser":
            return .browser
        default:
            return .system
        }
    }

    private static func seconds(microsKey: String, secondsKey: String, in dict: [String: Any]) -> TimeInterval? {
        if let micros = int64(dict[microsKey]) {
            return Double(micros) / 1_000_000.0
        }
        if let n = dict[secondsKey] as? NSNumber {
            return n.doubleValue
        }
        if let d = dict[secondsKey] as? Double {
            return d
        }
        return nil
    }

    private static func int64(_ v: Any?) -> Int64? {
        (v as? NSNumber)?.int64Value
    }
}
