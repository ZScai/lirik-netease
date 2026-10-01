//
//  LyricsStripVisibility.swift
//  lirik
//
//  Decides when the Touch Bar lyrics strip should take space.
//  Playing shows immediately. Paused, stopped, and "no session" hide only
//  after a short debounce so a track change that briefly reports idle
//  does not collapse the strip and pop it back open.
//
//  Behavior checks: Tests/run_lyrics_strip_visibility_tests.swift
//  (the script inlines this type so it can run without the Pock target).
//

import Foundation

struct LyricsStripVisibility: Equatable {

    /// How long an idle reading must persist before the strip collapses.
    /// Longer than media-control's stream debounce and a single 0.5s poll
    /// tick, shorter than a pause the user will actually notice as "stuck."
    static let hideDebounce: TimeInterval = 0.6

    private(set) var collapsed: Bool

    /// When non-nil, an idle stretch is in progress and should commit at this time.
    private(set) var hideDeadline: Date?

    init(collapsed: Bool = true) {
        self.collapsed = collapsed
    }

    /// `playing` is true only when lyrics should occupy the Touch Bar right now.
    /// The widget passes `track.isPlaying`, or true while a permission prompt
    /// must stay readable.
    mutating func consume(playing: Bool, now: Date, debounce: TimeInterval = LyricsStripVisibility.hideDebounce) {
        if playing {
            hideDeadline = nil
            collapsed = false
            return
        }

        // Already hidden: further idle snapshots must not arm another reveal.
        if collapsed {
            hideDeadline = nil
            return
        }

        if hideDeadline == nil {
            hideDeadline = now.addingTimeInterval(debounce)
        }

        if let deadline = hideDeadline, now >= deadline {
            collapsed = true
            hideDeadline = nil
        }
    }
}
