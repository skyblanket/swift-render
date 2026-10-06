import CoreImage
import SwiftUI
import SwiftRenderKit

// MARK: - A/B compare
//
// BEFORE = the comment's `.before` still (captured when it was posted). AFTER = the
// newest `.after` attachment on a reply, or LIVE: the current build rendered at the
// same t through the active host (lossless bgra8, full width). Modes: split (drag the
// wipe), toggle (click flips), side by side, difference (|A−B| × 4). Δ% counts the
// cells of a 64×36 luminance grid that moved by more than 4% — the same grid `check`
// uses for blank-frame detection — so "0.0%" means "nothing visible changed".

enum CompareMode: String, CaseIterable, Identifiable, Sendable {
    case split, toggle, sideBySide, difference
    var id: String { rawValue }
    var title: String {
        switch self {
        case .split: return "Split"
        case .toggle: return "Toggle"
        case .sideBySide: return "Side by Side"
        case .difference: return "Difference"
        }
    }
    var next: CompareMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// Before/after pixels plus what was derived from them.
struct ComparePair: @unchecked Sendable {
    var before: CGImage
    var after: CGImage
    var difference: CGImage?
    /// Fraction of 64×36 cells whose luminance moved more than the threshold.
    var changed: Double
}

enum CompareMath {
    /// Grid size for Δ% (matches `luminanceSpread` in `check`).
    static let grid = (w: 64, h: 36)
    /// A cell counts as changed past this luminance delta (0…1).
    static let threshold = 0.04

    /// Rec. 601 luminance of `image` scaled to the grid, 0…1, row-major.
    static func luma(_ image: CGImage, width w: Int = grid.w, height h: Int = grid.h) -> [Double] {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return [] }
        var out = [Double](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r = Double(px[i * 4]), g = Double(px[i * 4 + 1]), b = Double(px[i * 4 + 2])
            out[i] = (0.299 * r + 0.587 * g + 0.114 * b) / 255
        }
        return out
    }

    /// Share of grid cells that differ (0…1). Images of different sizes are compared
    /// on the same grid, so an aspect change reads as a big change, not a crash.
    static func changedFraction(_ a: CGImage, _ b: CGImage, threshold: Double = threshold) -> Double {
        changedFraction(luma(a), luma(b), threshold: threshold)
    }

    static func changedFraction(_ a: [Double], _ b: [Double], threshold: Double = threshold) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        let n = zip(a, b).filter { abs($0 - $1) > threshold }.count
        return Double(n) / Double(a.count)
    }

    /// |A − B| with ×`gain` exposure, at A's size.
    static func difference(_ a: CGImage, _ b: CGImage, gain: Double = 4) -> CGImage? {
        let ia = CIImage(cgImage: a)
        var ib = CIImage(cgImage: b)
        if b.width != a.width || b.height != a.height {
            ib = ib.transformed(by: CGAffineTransform(scaleX: CGFloat(a.width) / CGFloat(b.width),
                                                      y: CGFloat(a.height) / CGFloat(b.height)))
        }
        guard let diff = CIFilter(name: "CIDifferenceBlendMode") else { return nil }
        diff.setValue(ib, forKey: kCIInputImageKey)
        diff.setValue(ia, forKey: kCIInputBackgroundImageKey)
        guard let exposure = CIFilter(name: "CIExposureAdjust") else { return nil }
        exposure.setValue(diff.outputImage, forKey: kCIInputImageKey)
        exposure.setValue(log2(gain), forKey: kCIInputEVKey)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
        guard let out = exposure.outputImage?.cropped(to: ia.extent) else { return nil }
        return ctx.createCGImage(out, from: ia.extent)
    }

    static func pair(before: CGImage, after: CGImage) -> ComparePair {
        ComparePair(before: before, after: after, difference: difference(before, after),
                    changed: changedFraction(before, after))
    }

    /// "12% of the frame changed" ("No visible change in this frame" for none, "Less than
    /// 1% of the frame changed" for a sliver).
    static func label(_ changed: Double) -> String {
        if changed == 0 { return "No visible change in this frame" }
        if changed < 0.01 { return "Less than 1% of the frame changed" }
        return "\(Int((changed * 100).rounded()))% of the frame changed"
    }
}

struct CompareView: View {
    @Bindable var model: ProjectModel
    var mode: CompareMode
    var canvas: CGRect

    enum AfterSource: String, Hashable { case attachment, live }

    @State private var pair: ComparePair?
    @State private var loadError: String?
    @State private var loading = false
    @State private var wipe: CGFloat = 0.5
    @State private var showAfter = true
    @State private var source: AfterSource = .attachment

    /// The comment being compared: the explicit pick, else the selection, else the newest
    /// resolved note, else any note with a before frame.
    private var target: ReviewComment? {
        let r = model.review
        if let c = r.compared, c.beforeAttachment != nil { return c }
        if let c = r.selected, c.beforeAttachment != nil { return c }
        let withBefore = r.comments.filter { $0.beforeAttachment != nil }
        return withBefore.filter { $0.status == .resolved }.max { $0.updatedAt < $1.updatedAt } ?? withBefore.last
    }

    private var effectiveSource: AfterSource {
        target?.latestAfter == nil ? .live : source
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                StudioStyle.canvas
                if let c = target, let pair {
                    content(c, pair, container: geo.size)
                } else {
                    emptyState
                }
                VStack {
                    Spacer()
                    controls
                }
            }
        }
        .task(id: loadKey) { await load() }
    }

    // MARK: Layers

    @ViewBuilder
    private func content(_ c: ReviewComment, _ p: ComparePair, container: CGSize) -> some View {
        switch mode {
        case .split:
            ZStack(alignment: .topLeading) {
                frame(p.after, c)
                frame(p.before, c)
                    .mask(alignment: .leading) { Rectangle().frame(width: canvas.width * wipe) }
                wipeHandle
            }
            .frame(width: canvas.width, height: canvas.height)
            .position(x: canvas.midX, y: canvas.midY)
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                wipe = min(1, max(0, g.location.x / max(1, canvas.width)))
            })
            labels(c, left: "Before", right: afterTitle)
        case .toggle:
            frame(showAfter ? p.after : p.before, c)
                .frame(width: canvas.width, height: canvas.height)
                .position(x: canvas.midX, y: canvas.midY)
                .contentShape(Rectangle())
                .onTapGesture { showAfter.toggle() }
            labels(c, left: showAfter ? afterTitle : "Before", right: "Click to flip", leftAfter: showAfter)
        case .sideBySide:
            let half = ViewerGeometry.canvasRect(container: CGSize(width: container.width / 2, height: container.height - 70),
                                                 content: CGSize(width: p.before.width, height: p.before.height),
                                                 zoom: .fit, inset: 10)
            HStack(spacing: 0) {
                VStack(spacing: 6) {
                    badge("Before", help: beforeSub(c))
                    frame(p.before, c).frame(width: half.width, height: half.height)
                }
                .frame(width: container.width / 2)
                VStack(spacing: 6) {
                    badge(afterTitle, help: afterSub(c))
                    frame(p.after, c).frame(width: half.width, height: half.height)
                }
                .frame(width: container.width / 2)
            }
            .frame(maxHeight: .infinity)
            .padding(.bottom, 56)
        case .difference:
            ZStack {
                if let d = p.difference { frame(d, c) } else { frame(p.after, c) }
            }
            .frame(width: canvas.width, height: canvas.height)
            .position(x: canvas.midX, y: canvas.midY)
            labels(c, left: "Difference", right: "Black means unchanged")
        }
    }

    /// A frame with the comment's region outlined (same box agents see).
    private func frame(_ img: CGImage, _ c: ReviewComment) -> some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                Image(decorative: img, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: g.size.width, height: g.size.height)
                if let region = c.region, !RegionMath.isPoint(region) {
                    let r = RegionMath.rect(region, in: CGRect(origin: .zero, size: g.size))
                    Rectangle()
                        .strokeBorder(StudioStyle.regionBox, lineWidth: 1.5)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var wipeHandle: some View {
        let x = canvas.width * wipe
        return ZStack {
            Rectangle().fill(StudioStyle.onPicture).frame(width: 1.5).shadow(color: StudioStyle.shadow.opacity(0.6), radius: 2)
            Circle()
                .fill(StudioStyle.onPicture)
                .frame(width: 26, height: 26)
                .overlay(Image(systemName: "arrow.left.and.right").font(StudioStyle.Fonts.footnoteEmphasis).foregroundStyle(StudioStyle.onLight))
                .shadow(color: StudioStyle.shadow.opacity(0.5), radius: 3, y: 1)
        }
        .frame(width: 26, height: canvas.height)
        .offset(x: x - 13)
        .allowsHitTesting(false)
    }

    private func labels(_ c: ReviewComment, left: String, right: String, leftAfter: Bool = false) -> some View {
        HStack(alignment: .top) {
            badge(left, help: leftAfter ? afterSub(c) : (left == "Before" ? beforeSub(c) : nil))
            Spacer()
            badge(right, help: right == afterTitle ? afterSub(c) : nil)
        }
        .padding(StudioStyle.Space.s)
        .frame(width: canvas.width)
        .position(x: canvas.midX, y: canvas.minY + 24)
    }

    /// Corner label on material; the details (revision, who, when) are in its tooltip.
    private func badge(_ title: String, help: String?) -> some View {
        Text(title)
            .font(StudioStyle.Fonts.subheadline.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .studioGlass(cornerRadius: 12)
            .fixedSize()
            .help(help ?? "")
    }

    private var afterTitle: String { effectiveSource == .live ? "Now" : "After" }

    private func beforeSub(_ c: ReviewComment) -> String {
        ["Posted at \(StudioTime.short(c.t))", c.revision.map { "revision \($0)" }].compactMap { $0 }.joined(separator: ", ")
    }

    private func afterSub(_ c: ReviewComment) -> String {
        if effectiveSource == .live { return "The current build at \(StudioTime.short(c.t))" }
        let who = c.replies.last { $0.attachments.contains { $0.kind == .after } }?.author
        return "\(who.map(ReviewStyle.displayName) ?? "Claude")'s frame at \(StudioTime.short(c.latestAfter?.t ?? c.t))"
    }

    private var emptyState: some View {
        Group {
            if loading {
                ProgressView().controlSize(.small)
            } else if let loadError {
                StudioEmptyState(title: "Can't compare this one", symbol: "exclamationmark.triangle", message: loadError)
            } else {
                StudioEmptyState(title: "Nothing to compare yet", symbol: StudioStyle.Symbol.compare,
                                 message: "Comments you post in Studio save a Before frame. Pick one to compare it with Claude's frame or what's playing now.")
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .position(x: canvas.midX, y: canvas.midY)
    }

    // MARK: Controls

    private var controls: some View {
        let c = target
        let state = c.map(CommentState.init)
        return HStack(spacing: StudioStyle.Space.m) {
            Picker("Mode", selection: Binding(get: { mode }, set: { model.ui.compare = $0 })) {
                ForEach(CompareMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if let c, c.latestAfter != nil {
                Picker("After", selection: $source) {
                    Text("Claude's Frame").tag(AfterSource.attachment)
                    Text("Now").tag(AfterSource.live)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .help("Compare with the frame Claude attached, or with what's playing now")
            }
            if let pair {
                Text(CompareMath.label(pair.changed))
                    .font(StudioStyle.Fonts.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Measured on a 64 × 36 grid: a cell counts when its brightness moves more than 4%.")
            }
            if loading { ProgressView().controlSize(.small) }
            if let c, let state {
                if state == .readyForReview {
                    Button("Not Quite") {
                        act { try model.review.reopen(c.id, note: nil) }
                        model.review.open(c.id)
                        model.ui.inspectorTab = .comments
                    }
                    Button("Looks Good") { act { try model.review.accept(c.id) } }
                        .buttonStyle(.borderedProminent)
                } else if state.isSettled {
                    StatusLabel(state: state, font: StudioStyle.Fonts.callout)
                }
            }
            Button { model.ui.compare = nil } label: { Image(systemName: StudioStyle.Symbol.close) }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Close Compare (Esc)")
        }
        .controlSize(.regular)
        .padding(.horizontal, StudioStyle.Space.l).padding(.vertical, StudioStyle.Space.s)
        .studioGlass(cornerRadius: 22)
        .shadow(color: StudioStyle.shadow.opacity(0.25), radius: 10, y: 4)
        .padding(.bottom, StudioStyle.Space.l)
    }

    private func act(_ f: () throws -> Void) {
        do { try f() } catch { model.ui.toast = "\(error)" }
    }

    // MARK: Loading

    private var loadKey: String {
        guard let c = target else { return "none" }
        let live = effectiveSource == .live ? "live-\(model.host.generation)" : (c.latestAfter?.path ?? "")
        return "\(c.id)|\(c.beforeAttachment?.path ?? "")|\(live)|\(model.review.revision)"
    }

    private func load() async {
        guard let c = target, let before = c.beforeAttachment else { pair = nil; return }
        loading = true
        defer { loading = false }
        let review = model.review
        let beforeURL = review.url(before)
        let afterURL = effectiveSource == .attachment ? c.latestAfter.map { review.url($0) } : nil
        do {
            let b = try await Task.detached { try ReviewImage.load(beforeURL) }.value
            let a: CGImage
            if let afterURL {
                a = try await Task.detached { try ReviewImage.load(afterURL) }.value
            } else {
                guard let host = model.host.active else { throw ReviewError.io("Nothing is playing yet. Build first.") }
                let f = try await host.frame(t: c.t, maxWidth: b.width, format: host.supportsBinaryFrames ? .bgra8 : .png)
                a = f.image
            }
            let made = await Task.detached { CompareMath.pair(before: b, after: a) }.value
            guard !Task.isCancelled else { return }
            pair = made
            loadError = nil
        } catch {
            guard !Task.isCancelled else { return }
            pair = nil
            loadError = "\(error)"
        }
    }
}
