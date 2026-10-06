import AppKit
import SwiftUI
import SwiftRenderKit

// MARK: - Region tool
//
// Armed with R, or live while ⌥ is held: drag → normalized `ReviewRegion` rect, click
// → point pin. While active, a readout follows the cursor in scene points (scenes are
// written in 1920×1080 points, so that's the number to quote in code). Releasing opens
// the composer card next to the rect; the draft rect stays drawn until it posts.
// Always in the viewer's stack, but it only takes clicks while active.

struct RegionTool: View {
    @Bindable var model: ProjectModel
    var canvas: CGRect
    @State private var dragStart: CGPoint?
    @State private var dragNow: CGPoint?
    @State private var hover: CGPoint?
    @State private var optionHeld = false
    @State private var flagsMonitor: Any?
    @State private var cursorPushed = false

    private var active: Bool { model.ui.regionArmed || optionHeld }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if active {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(drag)
                        .onContinuousHover { phase in
                            if case .active(let p) = phase { hover = p } else { hover = nil }
                        }
                        .onHover { inside in setCursor(inside) }
                    if dragStart == nil, let p = hover, canvas.contains(p) { crosshairReadout(p) }
                }
                if let a = dragStart, let b = dragNow { rubberBand(a, b) }
                if let d = model.review.draft, let region = d.region {
                    draftMarker(region)
                    composer(region, container: geo.size)
                }
            }
        }
        .onAppear(perform: installFlagsMonitor)
        .onDisappear { removeFlagsMonitor(); setCursor(false) }
        // Disarming under a still pointer gets no hover-exit.
        .onChange(of: active) { _, on in if !on { setCursor(false); hover = nil } }
    }

    // MARK: Drawing

    private func rubberBand(_ a: CGPoint, _ b: CGPoint) -> some View {
        let r = Self.dragRect(a, b).intersection(canvas)
        let region = RegionMath.normalize(Self.dragRect(a, b), in: canvas)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(StudioStyle.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                .background(StudioStyle.accent.opacity(0.12))
                .frame(width: max(1, r.width), height: max(1, r.height))
                .offset(x: r.minX, y: r.minY)
            readout(RegionMath.describe(region, sceneSize: sceneSize))
                .offset(x: r.minX, y: r.minY > canvas.minY + 26 ? r.minY - 24 : r.maxY + 6)
        }
        .allowsHitTesting(false)
    }

    private func crosshairReadout(_ p: CGPoint) -> some View {
        let n = RegionMath.point(p, in: canvas)
        let s = RegionMath.scenePoints(n, sceneSize: sceneSize)
        return readout("\(Int(s.minX)), \(Int(s.minY)) pt")
            .offset(x: min(p.x + 14, canvas.maxX - 110), y: min(p.y + 14, canvas.maxY - 22))
            .allowsHitTesting(false)
    }

    private func readout(_ text: String) -> some View {
        Text(text)
            .font(StudioStyle.monoSmall)
            .foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 3)
            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
    }

    /// The pending comment's rect (or point) while the composer is open.
    @ViewBuilder
    private func draftMarker(_ region: ReviewRegion) -> some View {
        let r = RegionMath.rect(region, in: canvas)
        if RegionMath.isPoint(region) {
            Circle()
                .fill(StudioStyle.accent)
                .frame(width: 12, height: 12)
                .overlay(Circle().strokeBorder(.black.opacity(0.6), lineWidth: 1))
                .offset(x: r.minX - 6, y: r.minY - 6)
                .allowsHitTesting(false)
        } else {
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .strokeBorder(StudioStyle.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 3]))
                    .background(StudioStyle.accent.opacity(0.10))
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
                readout(RegionMath.describe(region, sceneSize: sceneSize))
                    .offset(x: r.minX, y: r.minY > canvas.minY + 26 ? r.minY - 24 : r.maxY + 6)
            }
            .allowsHitTesting(false)
        }
    }

    private func composer(_ region: ReviewRegion, container: CGSize) -> some View {
        let r = RegionMath.rect(region, in: canvas)
        let origin = Self.composerOrigin(anchor: r, size: CGSize(width: 330, height: 150), container: container)
        return CommentComposer(model: model, floating: true)
            .offset(x: origin.x, y: origin.y)
    }

    // MARK: Geometry (pure, tested)

    static func dragRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Right of the rect if it fits, else left, else below; always inside the container.
    static func composerOrigin(anchor r: CGRect, size: CGSize, container: CGSize, gap: CGFloat = 12) -> CGPoint {
        var x: CGFloat
        if r.maxX + gap + size.width <= container.width - 8 { x = r.maxX + gap }
        else if r.minX - gap - size.width >= 8 { x = r.minX - gap - size.width }
        else { x = r.midX - size.width / 2 }
        x = min(max(8, x), max(8, container.width - size.width - 8))
        let y = min(max(8, r.minY), max(8, container.height - size.height - 8))
        return CGPoint(x: x, y: y)
    }

    // MARK: Input

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if dragStart == nil {
                    dragStart = v.startLocation
                    model.playback.pause()
                }
                dragNow = v.location
            }
            .onEnded { v in
                let r = Self.dragRect(v.startLocation, v.location)
                let isClick = r.width < RegionMath.clickSlop && r.height < RegionMath.clickSlop
                dragStart = nil; dragNow = nil
                // A click/drag entirely in the letterbox is not a note on the frame.
                guard isClick ? canvas.contains(v.startLocation) : r.intersects(canvas) else { return }
                let region = isClick ? RegionMath.point(v.startLocation, in: canvas) : RegionMath.normalize(r, in: canvas)
                model.ui.regionArmed = false
                let p = model.playback
                model.review.beginComment(t: p.inOut?.lowerBound ?? p.t, end: p.inOut?.upperBound, region: region)
            }
    }

    private func setCursor(_ crosshair: Bool) {
        if crosshair, !cursorPushed { NSCursor.crosshair.push(); cursorPushed = true }
        if !crosshair, cursorPushed { NSCursor.pop(); cursorPushed = false }
    }

    private func installFlagsMonitor() {
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { e in
            let held = e.modifierFlags.contains(.option)
            MainActor.assumeIsolated { if optionHeld != held { optionHeld = held } }
            return e
        }
    }

    private func removeFlagsMonitor() {
        if let m = flagsMonitor { NSEvent.removeMonitor(m) }
        flagsMonitor = nil
    }

    private var sceneSize: CGSize {
        CGSize(width: model.info?.width ?? 1920, height: model.info?.height ?? 1080)
    }
}
