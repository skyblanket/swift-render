import CoreGraphics
import Observation
import SwiftRenderKit

// MARK: - Timeline layout and interaction state
//
// The lane stack is laid out in code (fixed heights, no dividers), so one gesture
// and one hover handler on the whole column can resolve any point to a lane and a
// lane-local point, and hit-test it with that lane's renderer. Heights depend only
// on SceneInfo; everything else a lane draws is read by that lane's own view.

enum LaneKey: Hashable, Sendable {
    case ruler, clips, captions, score(String), audio, notes
}

struct TimelineLayout: Equatable, Sendable {
    struct Slot: Equatable, Sendable {
        var key: LaneKey
        var title: String
        var y: CGFloat
        var height: CGFloat
    }

    static let rulerHeight: CGFloat = 28
    static let scrollerHeight: CGFloat = 22

    var slots: [Slot] = []
    var contentHeight: CGFloat = 0

    init(slots: [(LaneKey, String, CGFloat)]) {
        var y: CGFloat = 0
        for (k, t, h) in slots {
            self.slots.append(Slot(key: k, title: t, y: y, height: h))
            y += h
        }
        contentHeight = y
    }

    /// Lanes for `info`: clips, captions (when any), score groups present, audio, notes.
    init(info: SceneInfo?) {
        let clips = ClipsLane(clips: info?.clips ?? [])
        var s: [(LaneKey, String, CGFloat)] = [(.clips, clips.title, clips.height)]
        if let c = info?.captions, !c.isEmpty { s.append((.captions, "Captions", CaptionsLane(captions: c).height)) }
        for lane in ScoreLanes.renderers(info?.events ?? []) { s.append((.score(lane.title), lane.title, lane.height)) }
        // No sound yet: the lane collapses to one quiet line.
        let sound = info.map { $0.audioPath != nil || !$0.loudness.isEmpty } ?? false
        s.append((.audio, "Audio", sound ? WaveformLane(loudness: [], rate: 50).height : WaveformLane.collapsedHeight))
        s.append((.notes, "Comments", CommentsLane(comments: []).height))
        self.init(slots: s)
    }

    func slot(_ key: LaneKey) -> Slot? { slots.first { $0.key == key } }

    /// Where a point in the lanes column lands. `lanesHeight` is the visible lane
    /// area between ruler and scroller; `scrollY` the vertical lane scroll.
    enum Zone: Equatable {
        case ruler(CGPoint)
        case lane(LaneKey, CGPoint)
        /// Below the last lane: empty, click seeks.
        case empty
        case scroller
    }

    func zone(at p: CGPoint, lanesHeight: CGFloat, scrollY: CGFloat) -> Zone {
        if p.y < Self.rulerHeight { return .ruler(p) }
        if p.y >= Self.rulerHeight + lanesHeight { return .scroller }
        let cy = p.y - Self.rulerHeight + scrollY
        guard let s = slots.first(where: { cy >= $0.y && cy < $0.y + $0.height }) else { return .empty }
        return .lane(s.key, CGPoint(x: p.x, y: cy - s.y))
    }

    /// Column-space y of a lane's top edge.
    func columnY(_ key: LaneKey, scrollY: CGFloat) -> CGFloat? {
        slot(key).map { Self.rulerHeight + $0.y - scrollY }
    }

    func maxScroll(lanesHeight: CGFloat) -> CGFloat { max(0, contentHeight - lanesHeight) }
}

/// Per-window timeline interaction state. Lanes never read `hover`, so moving the
/// mouse redraws only the hover overlay.
@MainActor @Observable
final class TimelineState {
    struct Hover: Equatable {
        var point: CGPoint
        var key: LaneKey?
        var hit: LaneHit?
    }

    enum Drag {
        case scrub
        case inOut(isIn: Bool)
        case retime(LaneHit, t: Double, end: Double?)
        case press(LaneKey?, LaneHit?)
    }

    var scrollY: CGFloat = 0
    var hover: Hover?
    var retime: RetimePreview?
    @ObservationIgnored var drag: Drag?
    @ObservationIgnored var dragMoved = false
    /// Visible lane area (between ruler and scroller), for vertical scroll clamping.
    @ObservationIgnored var lanesHeight: CGFloat = 0
    /// We set a resize cursor over a handle and owe AppKit an arrow.
    @ObservationIgnored var cursorSet = false
}
