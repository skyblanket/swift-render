import CoreImage
import SwiftUI
import SwiftRenderKit

// MARK: - A/B compare   // S6
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
        case .sideBySide: return "Side by side"
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

    /// "Δ 3.1%" ("Δ <0.1%" for any change too small to round up, "Δ 0%" for none).
    static func label(_ changed: Double) -> String {
        if changed == 0 { return "Δ 0%" }
        if changed < 0.001 { return "Δ <0.1%" }
        return String(format: "Δ %.1f%%", changed * 100)
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
                StudioStyle.viewerBackground
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
            labels(c, left: "BEFORE", right: afterTitle)
        case .toggle:
            frame(showAfter ? p.after : p.before, c)
                .frame(width: canvas.width, height: canvas.height)
                .position(x: canvas.midX, y: canvas.midY)
                .contentShape(Rectangle())
                .onTapGesture { showAfter.toggle() }
            labels(c, left: showAfter ? afterTitle : "BEFORE", right: "click to flip", leftAfter: showAfter)
        case .sideBySide:
            let half = ViewerGeometry.canvasRect(container: CGSize(width: container.width / 2, height: container.height - 70),
                                                 content: CGSize(width: p.before.width, height: p.before.height),
                                                 zoom: .fit, inset: 10)
            HStack(spacing: 0) {
                VStack(spacing: 6) {
                    badge("BEFORE", sub: beforeSub(c), color: .white)
                    frame(p.before, c).frame(width: half.width, height: half.height)
                }
                .frame(width: container.width / 2)
                VStack(spacing: 6) {
                    badge(afterTitle, sub: afterSub(c), color: StudioStyle.ok)
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
            labels(c, left: "DIFFERENCE ×4", right: "black = unchanged")
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
                        .strokeBorder(Color(red: ReviewImage.boxColor.r, green: ReviewImage.boxColor.g, blue: ReviewImage.boxColor.b),
                                      lineWidth: 1.5)
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
            Rectangle().fill(.white).frame(width: 1.5).shadow(color: .black.opacity(0.6), radius: 2)
            Circle()
                .fill(.white)
                .frame(width: 26, height: 26)
                .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.black))
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
        }
        .frame(width: 26, height: canvas.height)
        .offset(x: x - 13)
        .allowsHitTesting(false)
    }

    private func labels(_ c: ReviewComment, left: String, right: String, leftAfter: Bool = false) -> some View {
        HStack(alignment: .top) {
            badge(left, sub: leftAfter ? afterSub(c) : (left == "BEFORE" ? beforeSub(c) : nil),
                  color: leftAfter ? StudioStyle.ok : .white)
            Spacer()
            badge(right, sub: right == afterTitle ? afterSub(c) : nil,
                  color: right == afterTitle ? StudioStyle.ok : .secondary)
        }
        .padding(8)
        .frame(width: canvas.width)
        .position(x: canvas.midX, y: canvas.minY + 24)
        .allowsHitTesting(false)
    }

    private func badge(_ title: String, sub: String?, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(color)
            if let sub { Text(sub).font(StudioStyle.monoSmall).foregroundStyle(.white.opacity(0.7)) }
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(.black.opacity(0.7), in: Capsule())
        .fixedSize()
    }

    private var afterTitle: String { effectiveSource == .live ? "AFTER · LIVE" : "AFTER" }

    private func beforeSub(_ c: ReviewComment) -> String {
        [c.revision, StudioStyle.timecode(c.t)].compactMap { $0 }.joined(separator: " · ")
    }

    private func afterSub(_ c: ReviewComment) -> String {
        if effectiveSource == .live { return "gen \(model.host.generation) · \(StudioStyle.timecode(c.t))" }
        let who = c.replies.last { $0.attachments.contains { $0.kind == .after } }?.author.name
        return [who, StudioStyle.timecode(c.latestAfter?.t ?? c.t)].compactMap { $0 }.joined(separator: " · ")
    }

    private var emptyState: some View {
        Group {
            if loading {
                ProgressView().controlSize(.small)
            } else if let loadError {
                StudioEmptyState(title: "Can't Compare", symbol: "exclamationmark.triangle", message: loadError)
            } else {
                StudioEmptyState(title: "Nothing to Compare", symbol: "rectangle.split.2x1",
                                 message: "Comments posted in Studio capture a BEFORE frame. Select one to compare it with the live build or Claude's after frame.")
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .position(x: canvas.midX, y: canvas.midY)
    }

    // MARK: Controls

    private var controls: some View {
        let c = target
        return HStack(spacing: 10) {
            Picker("Mode", selection: Binding(get: { mode }, set: { model.ui.compare = $0 })) {
                ForEach(CompareMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
            if let c, c.latestAfter != nil {
                Picker("After", selection: $source) {
                    Text("Claude's frame").tag(AfterSource.attachment)
                    Text("Live").tag(AfterSource.live)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .help("AFTER shows the attached after-frame, or the current build rendered live")
            }
            if let pair {
                Text(CompareMath.label(pair.changed))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(pair.changed < 0.001 ? StudioStyle.warn : .primary)
                    .help("Share of a 64×36 luminance grid that changed by more than 4%")
            }
            if loading { ProgressView().controlSize(.mini) }
            if let c {
                Divider().frame(height: 16)
                CommentBadge(number: model.review.number(of: c.id), status: c.status, agent: c.author.kind == .agent, size: 16)
                Text(c.body).font(.system(size: 11)).lineLimit(1).frame(maxWidth: 220, alignment: .leading)
                if c.status == .resolved, c.acceptedBy == nil {
                    Button { act { try model.review.accept(c.id) } } label: { Label("Accept", systemImage: "checkmark") }
                        .buttonStyle(.borderedProminent).tint(StudioStyle.ok)
                } else if c.acceptedBy != nil {
                    Label("Accepted", systemImage: "checkmark.seal.fill").font(.system(size: 11)).foregroundStyle(StudioStyle.ok)
                }
                if !c.status.isActive {
                    Button("Reopen") {
                        act { try model.review.reopen(c.id, note: nil) }
                        model.review.selection = c.id
                        model.ui.inspectorTab = .comments
                    }
                }
            }
            Button("Done") { model.ui.compare = nil }
                .keyboardShortcut(.cancelAction)
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.1)))
        .padding(.bottom, 10)
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
                guard let host = model.host.active else { throw ReviewError.io("No render host — build first.") }
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
