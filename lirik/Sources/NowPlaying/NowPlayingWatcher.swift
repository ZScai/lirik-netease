//
//  NowPlayingWatcher.swift
//  lirik
//
//  Single source of truth for "what is playing right now," per AGENTS.md §7.
//  Consumers (LRCSyncEngine, LyricsWidget) interact only with this type —
//  never with backends directly.
//
//  Backend selection (respects Music Player Source preference):
//  - Auto / System: prefer MediaControlBackend (mediaremote-adapter /
//    media-control) so NetEase and any Now Playing app work on macOS 15.4+;
//    fall back to legacy MediaRemote, then AppleScript (Spotify/Music only).
//  - Spotify / Apple Music: AppleScript only (existing path).
//

import Foundation

/// Watches system-wide now-playing state and notifies consumers of
/// track changes and elapsed-time updates.
final class NowPlayingWatcher {

    // MARK: - Public callbacks

    /// Called when the playing track changes (including nil → track,
    /// track → nil, and track → different track). Not called for
    /// mere elapsed-time updates within the same track.
    var onTrackChange: ((NowPlayingTrack?) -> Void)?

    /// Called on every poll/notification cycle with the latest elapsed
    /// time. This is the value LRCSyncEngine uses to pick the current
    /// lyric line — per AGENTS.md §7, MediaRemote elapsed-time updates
    /// are the single source of truth for sync position.
    var onElapsedTimeUpdate: ((TimeInterval) -> Void)?

    /// Called when macOS Automation permission is denied for a media app.
    var onPermissionDenied: ((String) -> Void)?

    /// The most recently observed track. nil if nothing is playing
    /// or no backend has reported yet.
    private(set) var currentTrack: NowPlayingTrack?

    // MARK: - Backends

    private let mediaControlBackend = MediaControlBackend()
    private let mediaRemoteBackend = MediaRemoteBackend()
    private let appleScriptBackend = AppleScriptBackend()

    private enum ActiveBackend {
        case mediaControl
        case mediaRemote
        case appleScript
    }
    private var activeBackend: ActiveBackend?

    private var preferenceObserver: NSObjectProtocol?

    // MARK: - Lifecycle

    /// Starts watching for now-playing changes. Auto-detects which
    /// backend to use based on preference + what works on this OS.
    func startWatching() {
        // Idempotent: if a backend is already active, just force a refresh
        // rather than double-registering observers and timers.
        if activeBackend != nil {
            NSLog("[NowPlayingWatcher] startWatching called while already active — forcing refresh instead")
            forceRefresh()
            return
        }

        observePlayerPreferenceChanges()

        NSLog("[NowPlayingWatcher] Starting — preference=\(preferredPlayer())")
        startForCurrentPreference()
    }

    /// Forces an immediate refetch from whichever backend is active.
    /// Call this after the Touch Bar wakes, the widget re-appears, or the
    /// system wakes from sleep — situations where our polling timers may
    /// have quiesced or MediaRemote snapshots may be stale.
    ///
    /// Safe to call even before a backend is selected (no-op in that case).
    func forceRefresh() {
        switch activeBackend {
        case .mediaControl:
            mediaControlBackend.fetchNowPlaying { [weak self] track in
                self?.handleUpdate(self?.filtered(track))
            }
        case .mediaRemote:
            mediaRemoteBackend.fetchNowPlaying(timeout: 2.0) { [weak self] track in
                self?.handleUpdate(self?.filtered(track))
            }
        case .appleScript:
            appleScriptBackend.fetchNowPlaying { [weak self] track in
                self?.handleUpdate(self?.filtered(track))
            }
        case .none:
            break
        }
    }

    /// Stops all watching and cleans up.
    func stopWatching() {
        NSLog("[NowPlayingWatcher] Stopping")
        tearDownBackends()
        if let preferenceObserver {
            NotificationCenter.default.removeObserver(preferenceObserver)
            self.preferenceObserver = nil
        }
    }

    // MARK: - Preference-driven selection

    private func preferredPlayer() -> String {
        UserDefaults.standard.string(forKey: LirikPreferenceViewController.keyPreferredPlayer) ?? "auto"
    }

    private func observePlayerPreferenceChanges() {
        guard preferenceObserver == nil else { return }
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("io.github.ridhaaf.lirik.preferredPlayerChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            NSLog("[NowPlayingWatcher] Player preference changed → \(self.preferredPlayer()); restarting backends")
            self.tearDownBackends()
            self.startForCurrentPreference()
        }
    }

    private func tearDownBackends() {
        mediaControlBackend.stopStreaming()
        mediaRemoteBackend.stopObserving()
        appleScriptBackend.stopPolling()
        activeBackend = nil
    }

    private func startForCurrentPreference() {
        let pref = preferredPlayer()
        switch pref {
        case "spotify", "music":
            NSLog("[NowPlayingWatcher] Preference \(pref) — AppleScript backend")
            startAppleScriptBackend()
        case "system":
            startSystemNowPlayingPath(allowAppleScriptFallback: false)
        default: // "auto"
            startSystemNowPlayingPath(allowAppleScriptFallback: true)
        }
    }

    /// Prefers MediaControl (adapter / media-control), then legacy MediaRemote,
    /// optionally AppleScript for Spotify/Music when system path is unavailable.
    private func startSystemNowPlayingPath(allowAppleScriptFallback: Bool) {
        if mediaControlBackend.isAvailable {
            NSLog("[NowPlayingWatcher] Using MediaControlBackend (system Now Playing)")
            startMediaControlBackend()
            return
        }

        if mediaRemoteBackend.isAvailable {
            NSLog("[NowPlayingWatcher] MediaControl unavailable — probing legacy MediaRemote")
            probeMediaRemoteThenFallback(allowAppleScriptFallback: allowAppleScriptFallback)
            return
        }

        if allowAppleScriptFallback {
            NSLog("[NowPlayingWatcher] No system Now Playing backend — AppleScript fallback (Spotify/Music only)")
            startAppleScriptBackend()
        } else {
            NSLog("[NowPlayingWatcher] ⚠️ System Now Playing unavailable. Install: brew install media-control")
            // Still start MediaControl so a later brew install + widget reopen can work;
            // for now emit nil.
            activeBackend = .mediaControl
            handleUpdate(nil)
        }
    }

    // MARK: - Backend selection (legacy MediaRemote probe)

    /// Tries a one-shot MediaRemote fetch with a short timeout.
    /// If the callback fires, we use MediaRemote going forward.
    /// If it times out (macOS 15.4+), we fall back to AppleScript (when allowed).
    private func probeMediaRemoteThenFallback(allowAppleScriptFallback: Bool) {
        NSLog("[NowPlayingWatcher] Probing MediaRemote (2s timeout)...")

        mediaRemoteBackend.fetchNowPlaying(timeout: 2.0) { [weak self] track in
            guard let self else { return }

            if track != nil {
                NSLog("[NowPlayingWatcher] MediaRemote responded — using it as backend")
                self.startMediaRemoteBackend()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.mediaRemoteBackend.fetchNowPlaying(timeout: 2.0) { [weak self] retryTrack in
                        guard let self else { return }

                        if retryTrack != nil {
                            NSLog("[NowPlayingWatcher] MediaRemote responded on retry — using it")
                            self.startMediaRemoteBackend()
                        } else if allowAppleScriptFallback {
                            NSLog("[NowPlayingWatcher] MediaRemote timed out twice — falling back to AppleScript")
                            self.startAppleScriptBackend()
                        } else {
                            NSLog("[NowPlayingWatcher] MediaRemote timed out — no AppleScript fallback for System mode")
                            self.activeBackend = .mediaRemote
                            self.handleUpdate(nil)
                        }
                    }
                }
            }
        }
    }

    // MARK: - MediaControl backend

    private func startMediaControlBackend() {
        activeBackend = .mediaControl
        mediaControlBackend.startStreaming { [weak self] newTrack in
            guard let self else { return }
            self.handleUpdate(self.filtered(newTrack))
        }
    }

    // MARK: - MediaRemote backend

    private func startMediaRemoteBackend() {
        activeBackend = .mediaRemote

        mediaRemoteBackend.startObserving { [weak self] info in
            guard let self else { return }
            let newTrack = self.mediaRemoteBackend.parseInfo(info)
            self.handleUpdate(self.filtered(newTrack))
        }
    }

    // MARK: - AppleScript backend

    private func startAppleScriptBackend() {
        activeBackend = .appleScript

        appleScriptBackend.onPermissionDenied = { [weak self] appName in
            self?.onPermissionDenied?(appName)
        }

        appleScriptBackend.startPolling { [weak self] newTrack in
            guard let self else { return }
            self.handleUpdate(self.filtered(newTrack))
        }
    }

    // MARK: - Preference filter

    /// Applies Music Player Source preference to a track from any backend.
    private func filtered(_ track: NowPlayingTrack?) -> NowPlayingTrack? {
        guard let track else { return nil }
        switch preferredPlayer() {
        case "spotify":
            return track.source == .spotify ? track : nil
        case "music":
            return track.source == .appleMusic ? track : nil
        case "system":
            // Accept everything from system Now Playing (NetEase, browsers, etc.)
            return track
        default:
            return track
        }
    }

    // MARK: - Unified update handling

    /// Processes an update from either backend. Detects track changes
    /// vs. mere elapsed-time updates and fires the appropriate callbacks.
    private func handleUpdate(_ newTrack: NowPlayingTrack?) {
        // Track change detection
        let isNewTrack: Bool
        // NetEase / media-control often delivers title first, then duration in a
        // later diff. Duration 0 → "notFound" must not stick forever.
        let durationBecameKnown: Bool
        switch (currentTrack, newTrack) {
        case (nil, nil):
            return // No change: still nothing playing
        case (nil, .some):
            isNewTrack = true
            durationBecameKnown = false
        case (.some, nil):
            isNewTrack = true
            durationBecameKnown = false
        case let (.some(old), .some(new)):
            isNewTrack = !old.isSameTrack(as: new)
            let oldDur = old.duration ?? 0
            let newDur = new.duration ?? 0
            durationBecameKnown = old.isSameTrack(as: new)
                && oldDur <= 0
                && newDur > 0
        }

        if isNewTrack || durationBecameKnown {
            currentTrack = newTrack
            onTrackChange?(newTrack)
        } else {
            // Same track — update stored state for elapsed time / play state
            currentTrack = newTrack
        }

        // Always fire elapsed-time updates so the sync engine stays current
        if let elapsed = newTrack?.elapsedTime {
            onElapsedTimeUpdate?(elapsed)
        }
    }
}
