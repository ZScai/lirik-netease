#!/usr/bin/env swift
//
//  run_lyrics_strip_visibility_tests.swift
//  lirik
//
//  Standalone checks for LyricsStripVisibility (lirik/Sources/Widget/LyricsStripVisibility.swift).
//  The struct is copied here so the script runs without the PockKit app target:
//      swift Tests/run_lyrics_strip_visibility_tests.swift
//

import Foundation

struct LyricsStripVisibility: Equatable {
    static let hideDebounce: TimeInterval = 0.6

    private(set) var collapsed: Bool
    private(set) var hideDeadline: Date?

    init(collapsed: Bool = true) {
        self.collapsed = collapsed
    }

    mutating func consume(playing: Bool, now: Date, debounce: TimeInterval = LyricsStripVisibility.hideDebounce) {
        if playing {
            hideDeadline = nil
            collapsed = false
            return
        }

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

struct Failure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(description: message) }
}

func run() throws {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // Starts hidden so launch doesn't show a placeholder.
    var gate = LyricsStripVisibility()
    try expect(gate.collapsed, "initial state is collapsed")
    try expect(gate.hideDeadline == nil, "initial state has no pending hide")

    // Idle snapshots while already hidden do not arm a reveal.
    gate.consume(playing: false, now: t0)
    try expect(gate.collapsed, "still collapsed when nothing is playing")
    try expect(gate.hideDeadline == nil, "no deadline while already collapsed")

    // Playing shows immediately.
    gate.consume(playing: true, now: t0.addingTimeInterval(1))
    try expect(!gate.collapsed, "playing expands immediately")
    try expect(gate.hideDeadline == nil, "playing clears any hide deadline")

    // Pause arms a deadline but stays visible.
    let pauseAt = t0.addingTimeInterval(10)
    gate.consume(playing: false, now: pauseAt)
    try expect(!gate.collapsed, "pause stays visible during debounce")
    try expect(gate.hideDeadline == pauseAt.addingTimeInterval(0.6), "pause deadline is now + 0.6s")

    // Later idle ticks must not push the deadline out (that would never hide).
    gate.consume(playing: false, now: pauseAt.addingTimeInterval(0.5))
    try expect(!gate.collapsed, "still visible 0.5s into the pause")
    try expect(gate.hideDeadline == pauseAt.addingTimeInterval(0.6), "poll tick does not extend the deadline")

    // Resume before the deadline cancels the hide.
    gate.consume(playing: true, now: pauseAt.addingTimeInterval(0.55))
    try expect(!gate.collapsed, "resume before deadline stays visible")
    try expect(gate.hideDeadline == nil, "resume clears the deadline")

    // A full pause commits at the deadline.
    let pause2 = t0.addingTimeInterval(20)
    gate.consume(playing: false, now: pause2)
    gate.consume(playing: false, now: pause2.addingTimeInterval(0.6))
    try expect(gate.collapsed, "pause commits once the debounce elapses")
    try expect(gate.hideDeadline == nil, "committed hide clears the deadline")

    // Nothing-playing uses the same idle path as pause.
    gate.consume(playing: true, now: t0.addingTimeInterval(30))
    let gapAt = t0.addingTimeInterval(31)
    gate.consume(playing: false, now: gapAt)
    try expect(!gate.collapsed, "brief session gap stays visible")
    gate.consume(playing: true, now: gapAt.addingTimeInterval(0.2))
    try expect(!gate.collapsed && gate.hideDeadline == nil, "track-change gap under 0.6s does not collapse")

    // Quit / stop that outlasts the debounce does collapse.
    let quitAt = t0.addingTimeInterval(40)
    gate.consume(playing: false, now: quitAt)
    gate.consume(playing: false, now: quitAt.addingTimeInterval(0.61))
    try expect(gate.collapsed, "session gone past the debounce collapses")

    // Playing again after a committed hide shows immediately.
    gate.consume(playing: true, now: quitAt.addingTimeInterval(2))
    try expect(!gate.collapsed, "playback after hide shows immediately")
}

do {
    try run()
    print("LyricsStripVisibility: all checks passed")
} catch let failure as Failure {
    fputs("FAIL: \(failure.description)\n", stderr)
    exit(1)
}
