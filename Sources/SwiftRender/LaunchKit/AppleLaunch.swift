import SwiftRenderKit
import SwiftUI

/// AppleLaunch — an Apple-keynote-style launch film for any Swift codebase, built
/// from LaunchKit and driven entirely by `LaunchProps` (usually written by
/// `swift-render launch`, which scans the repo).
///
///   swift run swift-render launch .                                   # scan + render
///   swift run swift-render render AppleLaunch --props launch.json --out out/launch.mp4
///   swift run swift-render check AppleLaunch --props launch.json
///
/// The shot list (`LaunchPlan`) adapts to what the props contain: features,
/// screenshots, code, a terminal session, numbers, a changelog. Length is a whole
/// number of bars at 90/100/120 BPM, so every cut lands on a frame and a beat.
/// Works at 16:9, 9:16 and 1:1 (square canvases stack like vertical ones).
public struct AppleLaunch: PropsScene {
    public typealias Props = LaunchProps
    public static let defaultDuration: Double = LaunchPlan(.sample).duration
    public static var ownsPostFX: Bool { true }
    public static var defaultProps: LaunchProps { .sample }

    public static func duration(for props: LaunchProps) -> Double {
        LaunchPlan(props.validated().props).duration
    }

    public static func soundtrack(duration: Double) -> Score? {
        soundtrack(duration: duration, props: .sample)
    }

    public static func soundtrack(duration: Double, props: LaunchProps) -> Score? {
        let p = props.validated().props
        return LaunchScore.make(LaunchPlan(p), p, duration: duration)
    }

    @MainActor public static func body(at t: Double, duration: Double, props: LaunchProps) -> some View {
        AppleLaunchFilm(t: t, duration: duration, props: props.validated().props)
    }
}

/// The film as a view — also usable inside your own scene (`AppleLaunchFilm(t:duration:props:)`).
public struct AppleLaunchFilm: View {
    let t: Double
    let duration: Double
    let props: LaunchProps
    let plan: LaunchPlan

    public init(t: Double, duration: Double, props: LaunchProps) {
        self.t = t; self.duration = duration; self.props = props; self.plan = LaunchPlan(props)
    }

    public var body: some View {
        let theme = LaunchTheme(props: props)
        let fadeIn = Ease.easeInOut(Ease.clip(t, 0, 1.6))
        let fadeOut = Ease.easeIn(Ease.clip(t, duration - 1.0, duration))
        ZStack {
            Stage(glow: 0.075 * fadeIn, center: .top, at: t)
            // Clip starts accumulate in floating point and can land a hair after the plan's
            // frame-exact cut (26.400000000000002 vs 26.4), which would show the outgoing shot on
            // the cut frame while the score already hits the downbeat. A 1 µs nudge keeps the
            // picture cut on the plan's frame (far below one frame; still pure in t).
            Timeline(t + 1e-6) {
                for (i, shot) in plan.shots.enumerated() {
                    // The end card focus-pulls in; the shot before it runs 0.4 s longer so the
                    // end card still starts exactly on its downbeat.
                    let intoEnd = i + 1 < plan.shots.count && plan.shots[i + 1].kind == .end
                    let len = plan.length(i) + (intoEnd ? 0.4 : 0)
                    // Named by shot id, so Studio's timeline and review comments say "triad", not the type.
                    if shot.kind == .end {
                        Clip(len) { l in AppleLaunchShot(shot.kind, at: l, length: len, props: props, plan: plan) }
                            .transition(.focusPull(0.4))
                            .named(shot.id)
                    } else {
                        Clip(len) { l in AppleLaunchShot(shot.kind, at: l, length: len, props: props, plan: plan) }
                            .named(shot.id)
                    }
                }
            }
            theme.background.opacity(fadeOut).ignoresSafeArea()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .launchTheme(theme)
        .launchPostFX(at: t, dark: theme.isDark)
    }
}

/// One stock shot of the AppleLaunch film at local time `l` (with its slow push).
/// Ejected and `init`-scaffolded scenes fall back to these for shots they don't override.
public struct AppleLaunchShot: View {
    let kind: LaunchShot.Kind
    let l: Double
    let length: Double
    let props: LaunchProps
    let plan: LaunchPlan
    @Environment(\.renderContext) private var ctx
    @Environment(\.launchTheme) private var theme

    public init(_ kind: LaunchShot.Kind, at l: Double, length: Double, props: LaunchProps, plan: LaunchPlan) {
        self.kind = kind; self.l = l; self.length = length; self.props = props; self.plan = plan
    }

    public var body: some View {
        let L = LaunchLayout(ctx)
        content(L)
            .frame(width: ctx.width, height: ctx.height)
            .scaleEffect(Motion.push(l, over: length, amount: kind == .end ? 0.03 : 0.045))
    }

    @ViewBuilder
    private func content(_ L: LaunchLayout) -> some View {
        switch kind {
        case .open:
            KeynoteTitle([openLine], at: l, start: plan.beat, size: 64,
                         reveal: .letters(stagger: Self.openStagger(openLine, start: plan.beat, length: length)), accentLine: nil)
        case .hero:
            AppIconHero(iconPath: props.icon?.path, at: l, size: L.isVertical ? 380 : 300, shape: props.icon?.shape ?? .iOS,
                        beat: plan.beat, sweepAt: LaunchScore.Cue.heroSweep(plan), name: props.name,
                        tagline: heroLine.isEmpty ? nil : heroLine,
                        nameAt: LaunchScore.Cue.heroName(plan), taglineAt: LaunchScore.Cue.heroTagline(plan))
        case .title:
            // start 0: the headline is already rising on the cut frame, under the shot's rim.
            KeynoteTitle(Self.balance(props.tagline), sub: props.subtitle, at: l, start: 0,
                         size: L.isVertical ? 128 : 132, accentLine: 1, gradient: props.accentSecondary != nil)
        case .triad:
            FeatureTriad(props.features, at: l, start: LaunchScore.Cue.triadStart(plan), stagger: plan.beat)
        case .more:
            FeatureList(Array(props.features.dropFirst(FeatureTriad.shown(props.features.count))), at: l, start: 0.1, stagger: LaunchScore.Cue.rowStagger(plan))
        case .device:
            device(L)
        case .code:
            code(L)
        case .terminal:
            let cps = LaunchScore.Cue.terminalSpeed(plan, props)
            VStack(spacing: 56 * L.type) {
                KeynoteTitle(["Right from", "your terminal."], at: l, start: 0, size: L.isVertical ? 96 : 84, accentLine: 1)
                TerminalCard(TerminalCard.session(props.terminal ?? [], start: LaunchScore.Cue.terminalStart, cps: cps),
                             at: l, title: props.name, cps: cps,
                             width: L.stacks ? L.width : 1360 * L.type, fontSize: L.isVertical ? 28 : 34)
                    .reveal(Motion.pop(l, 0.1, response: 0.5, damping: 0.82), rise: 60)
            }
        case .stats:
            VStack(spacing: 60 * L.type) {
                Eyebrow("By the numbers", at: l, start: 0)
                StatRow(props.highlights, at: l, start: LaunchScore.Cue.statStart, stagger: LaunchScore.Cue.statStagger(plan))
            }
        case .changelog:
            ChangelogList(version: props.version ?? "this release", items: props.changelog, at: l,
                          start: 0.25, stagger: LaunchScore.Cue.rowStagger(plan))
        case .platforms:
            PlatformBadges(props.platforms, swift: props.kind == .app ? nil : props.swiftVersion, facts: Array(props.facts.dropFirst()),
                           headline: props.facts.first.map { $0.hasSuffix(".") ? $0 : $0 + "." }, at: l, start: 0.1)
        case .end:
            EndCard(name: props.name, icon: LaunchAssets.image(props.icon?.path), iconShape: props.icon?.shape ?? .iOS,
                    cta: props.cta, url: props.url, footnote: footnote, at: l)
        }
    }

    // MARK: Shots with a caption beside the subject

    @ViewBuilder
    private func device(_ L: LaunchLayout) -> some View {
        let shot = props.screenshots.first
        let kind = shot?.device ?? .iPhone
        let f = props.features.first
        let caption = shot?.caption.map { Self.balance($0) } ?? (f.map { [$0.title + "."] } ?? [props.name])
        let sub = shot?.caption == nil ? f?.detail : nil
        let phone = kind == .iPhone
        let u = L.type
        // Side by side at 16:9 (and for a phone on a square canvas), stacked otherwise. Caption +
        // spacing + device stay inside the safe width: 820 + 110 + 410 and 640 + 110 + 900 ≤ 1651.
        let sideBySide = !L.stacks || (L.isSquare && phone)
        let spacing: CGFloat = (L.isSquare ? 70 : 110) * u
        let devWidth: CGFloat = L.isVertical ? (phone ? 540 : 940) * u
            : L.isSquare ? (phone ? 330 * u : L.width)
            : (phone ? 410 : 900) * u
        let captionWidth: CGFloat = !sideBySide ? L.width : L.isSquare ? L.width - devWidth - spacing : (phone ? 820 : 640) * u
        let title = KeynoteTitle(caption, eyebrow: shot?.caption == nil ? "Meet \(props.name)" : nil, sub: sub, at: l,
                                 start: 0.2, size: L.isVertical ? 100 : 92,
                                 alignment: sideBySide ? .leading : .center, accentLine: caption.count > 1 ? 1 : nil,
                                 maxWidth: captionWidth)
        let frame = DeviceFrame(kind, at: l, enter: .settle, width: devWidth, title: props.name) {
            ScreenshotView(shot?.path)
        }
        if sideBySide {
            HStack(spacing: spacing) { title.frame(width: captionWidth, alignment: .leading); frame }
        } else {
            VStack(spacing: (L.isSquare ? 44 : 70) * u) { title; frame }
        }
    }

    @ViewBuilder
    private func code(_ L: LaunchLayout) -> some View {
        let snippet = props.code ?? LaunchProps.CodeSnippet(source: "")
        let caption = Self.balance(snippet.caption ?? "Just a few lines of Swift.")
        let mode = LaunchScore.Cue.codeMode(plan)
        let codeWidth = L.stacks ? L.width : 1080 * L.type
        // The window's height budget: what the canvas leaves beside (or under) the caption.
        let codeHeight = L.size.height * (L.isVertical ? 0.6 : L.isSquare ? 0.62 : 0.84)
        let title = KeynoteTitle(caption, at: l, start: 0, size: L.isVertical ? 96 : 84,
                                 alignment: L.stacks ? .center : .leading, accentLine: 1,
                                 maxWidth: L.stacks ? L.width : 560 * L.type)
        let window = CodeReveal(snippet.source, language: snippet.language, at: l, start: LaunchScore.Cue.codeStart,
                                mode: mode, focus: snippet.focus, title: snippet.title, maxWidth: codeWidth, maxHeight: codeHeight)
            .reveal(Motion.pop(l, 0.15, response: 0.55, damping: 0.82), rise: 50)
        if L.stacks {
            VStack(spacing: (L.isSquare ? 44 : 64) * L.type) { title; window }
        } else {
            HStack(alignment: .center, spacing: 90 * L.type) { title.frame(width: 560 * L.type, alignment: .leading); window }
        }
    }

    // MARK: Copy

    private var openLine: String {
        props.voiceoverLines?["open"] ?? "Introducing"
    }

    /// Letter stagger for the open line: 0.045 s, tightened so a long custom line is fully
    /// in (and in focus) half a second before the open cuts to the hero.
    static func openStagger(_ line: String, start: Double, length: Double) -> Double {
        let gaps = Double(max(1, line.count - 1))
        return max(0.012, min(0.045, (length - 0.5 - 0.35 - start) / gaps))
    }

    /// One factual line under the name: what it is and where it runs.
    private var heroLine: String {
        let devices: [String] = props.platforms.compactMap {
            switch $0.name {
            case .iOS: return "iPhone"
            case .macOS: return "Mac"
            case .visionOS: return "Vision Pro"
            case .watchOS: return "Apple Watch"
            case .tvOS: return "Apple TV"
            case .macCatalyst, .linux: return nil
            }
        }
        let list = devices.count > 1 ? devices.dropLast().joined(separator: ", ") + " and " + devices.last! : devices.first
        switch props.kind {
        // With no platforms, the subtitle only goes here when there is no title shot to carry it.
        case .app: return list.map { "For \($0)." } ?? (props.tagline.isEmpty ? props.subtitle ?? "" : "")
        case .library, .framework: return "A Swift package" + (list.map { " for \($0)." } ?? ".")
        case .cli: return "A command-line tool, written in Swift."
        case .plugin: return "A Swift package plugin."
        }
    }

    private var footnote: String? {
        var parts: [String] = []
        if let v = props.version { parts.append("Version \(v)") }
        parts += props.platforms.prefix(3).map { PlatformBadges.label($0) }
        if let l = props.license { parts.append(l) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    /// Splits a sentence into one or two lines of similar length: at a comma or full stop in
    /// the middle third when the two halves are within 1.5x of each other (the most even such
    /// break wins), otherwise at the word break that balances the lengths.
    public static func balance(_ s: String) -> [String] {
        let words = s.split(separator: " ").map(String.init)
        guard words.count >= 3, s.count > 16 else { return [s] }
        let punctuated = words.indices.filter {
            (words[$0].hasSuffix(",") || words[$0].hasSuffix(".")) && $0 < words.count - 1
                && $0 >= words.count / 3 && $0 <= words.count * 2 / 3
        }
        let even = punctuated.compactMap { k -> (Int, Int)? in
            let a = words[...k].joined(separator: " ").count, b = words[(k + 1)...].joined(separator: " ").count
            return Double(max(a, b)) <= 1.5 * Double(min(a, b)) ? (k, abs(a - b)) : nil
        }
        if let comma = even.min(by: { $0.1 < $1.1 })?.0 {
            return [words[...comma].joined(separator: " "), words[(comma + 1)...].joined(separator: " ")]
        }
        var best = 1, bestDiff = Int.max
        for k in 1..<words.count {
            let a = words[..<k].joined(separator: " ").count, b = words[k...].joined(separator: " ").count
            // Prefer a slightly longer second line (it's the accent line).
            let diff = abs(a - b + 2)
            if diff < bestDiff { bestDiff = diff; best = k }
        }
        return [words[..<best].joined(separator: " "), words[best...].joined(separator: " ")]
    }
}
