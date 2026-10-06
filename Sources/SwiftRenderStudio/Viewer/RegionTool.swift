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

    /// The marquee: a 1.5 pt accent line over a dark underlay, so it reads on any frame.
    /// No fill: the picture inside stays exactly as rendered.
    private func marquee(_ r: CGRect) -> some View {
        Rectangle()
            .strokeBorder(StudioStyle.pictureScrim, lineWidth: 3.5)
            .overlay(Rectangle().strokeBorder(StudioStyle.accent, lineWidth: 1.5))
            .frame(width: max(1, r.width), height: max(1, r.height))
            .offset(x: r.minX, y: r.minY)
    }

    private func rubberBand(_ a: CGPoint, _ b: CGPoint) -> some View {
        let r = Self.dragRect(a, b).intersection(canvas)
        let region = RegionMath.normalize(Self.dragRect(a, b), in: canvas)
        return ZStack(alignment: .topLeading) {
            marquee(r)
            // Size in scene points only while ⌥ is held.
            if optionHeld {
                readout(RegionMath.sizeLabel(region, sceneSize: sceneSize))
                    .offset(x: r.minX, y: r.minY > canvas.minY + 26 ? r.minY - 24 : r.maxY + 6)
            }
        }
        .allowsHitTesting(false)
    }

    private func readout(_ text: String) -> some View {
        Text(text)
            .font(StudioStyle.Fonts.footnote.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(StudioStyle.onPicture)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(StudioStyle.pictureScrim, in: StudioStyle.rounded(StudioStyle.Radius.small))
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
                .overlay(Circle().strokeBorder(StudioStyle.onPicture, lineWidth: 2))
                .shadow(color: StudioStyle.shadow.opacity(0.4), radius: 2)
                .offset(x: r.minX - 6, y: r.minY - 6)
                .allowsHitTesting(false)
        } else {
            marquee(r).allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func composer(_ region: ReviewRegion, container: CGSize) -> some View {
        let r = RegionMath.rect(region, in: canvas)
        let origin = Self.composerOrigin(anchor: r, size: Self.composerSize, container: container)
        Group {
            if let origin {
                CommentComposer(model: model, floating: true)
                    .offset(x: origin.x, y: origin.y)
            }
        }
        // No room beside the spot: the composer docks in the Comments tab instead.
        .onAppear { setDocked(origin == nil) }
        .onChange(of: origin == nil) { _, docked in setDocked(docked) }
    }

    private func setDocked(_ docked: Bool) {
        if model.review.draftDocked != docked { model.review.draftDocked = docked }
        if docked { model.ui.inspectorTab = .comments; model.ui.showInspector = true }
    }

    /// Compact, so it fits beside most regions instead of below them.
    static let composerSize = CGSize(width: 280, height: 156)

    // MARK: Geometry (pure, tested)

    static func dragRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Beside the rect, never over it: right, then left, then below, then above. nil when
    /// none fits (the composer docks in the inspector).
    static func composerOrigin(anchor r: CGRect, size: CGSize, container: CGSize, gap: CGFloat = 12, margin: CGFloat = 8) -> CGPoint? {
        let maxX = container.width - margin, maxY = container.height - margin
        func clampY(_ y: CGFloat) -> CGFloat { min(max(margin, y), max(margin, maxY - size.height)) }
        func clampX(_ x: CGFloat) -> CGFloat { min(max(margin, x), max(margin, maxX - size.width)) }
        if r.maxX + gap + size.width <= maxX { return CGPoint(x: r.maxX + gap, y: clampY(r.minY)) }
        if r.minX - gap - size.width >= margin { return CGPoint(x: r.minX - gap - size.width, y: clampY(r.minY)) }
        if r.maxY + gap + size.height <= maxY, size.width <= maxX - margin { return CGPoint(x: clampX(r.midX - size.width / 2), y: r.maxY + gap) }
        if r.minY - gap - size.height >= margin, size.width <= maxX - margin { return CGPoint(x: clampX(r.midX - size.width / 2), y: r.minY - gap - size.height) }
        return nil
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
        guard flagsMonitor == nil, !StudioStyle.isSnapshot else { return }
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
