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
/// Works at 16:9 and 9:16.
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
            Timeline(t) {
                for (i, shot) in plan.shots.enumerated() {
                    // The end card focus-pulls in; the shot before it runs 0.4 s longer so the
                    // end card still starts exactly on its downbeat.
                    let intoEnd = i + 1 < plan.shots.count && plan.shots[i + 1].kind == .end
                    let len = plan.length(i) + (intoEnd ? 0.4 : 0)
                    if shot.kind == .end {
                        Clip(len) { l in AppleLaunchShot(shot.kind, at: l, length: len, props: props, plan: plan) }
                            .transition(.focusPull(0.4))
                    } else {
                        Clip(len) { l in AppleLaunchShot(shot.kind, at: l, length: len, props: props, plan: plan) }
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
            KeynoteTitle([openLine], at: l, start: plan.beat, size: 64, reveal: .letters(stagger: 0.045), accentLine: nil)
        case .hero:
            AppIconHero(iconPath: props.icon?.path, at: l, size: L.isVertical ? 380 : 300, shape: props.icon?.shape ?? .iOS,
                        beat: plan.beat, sweepAt: plan.beat * 2 - 0.2, name: props.name, tagline: heroLine,
                        nameAt: plan.beat * 2 - 0.1, taglineAt: plan.beat * 3 + 0.1)
        case .title:
            KeynoteTitle(Self.balance(props.tagline), sub: props.subtitle, at: l, start: 0.05,
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
            VStack(spacing: 56 * L.type) {
                KeynoteTitle(["Right from", "your terminal."], at: l, start: 0.05, size: L.isVertical ? 96 : 84, accentLine: 1)
                TerminalCard(TerminalCard.session(props.terminal ?? [], start: LaunchScore.Cue.terminalStart,
                                                  cps: LaunchScore.Cue.terminalCPS),
                             at: l, title: props.name, cps: LaunchScore.Cue.terminalCPS,
                             width: L.isVertical ? L.width : 1360 * L.type, fontSize: L.isVertical ? 28 : 34)
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
        let devWidth: CGFloat = phone ? (L.isVertical ? 540 : 460) : (L.isVertical ? 940 : 1040)
        let title = KeynoteTitle(caption, eyebrow: shot?.caption == nil ? "Meet \(props.name)" : nil, sub: sub, at: l,
                                 start: 0.35, size: L.isVertical ? 100 : 92,
                                 alignment: L.isVertical ? .center : .leading, accentLine: caption.count > 1 ? 1 : nil,
                                 maxWidth: L.isVertical ? L.width : (phone ? 820 : 640) * L.type)
        let frame = DeviceFrame(kind, at: l, enter: .settle, width: devWidth * L.type, title: props.name) {
            ScreenshotView(shot?.path)
        }
        if L.isVertical {
            VStack(spacing: 70 * L.type) { title; frame }
        } else {
            HStack(spacing: 110 * L.type) { title.frame(width: (phone ? 820 : 640) * L.type, alignment: .leading); frame }
        }
    }

    @ViewBuilder
    private func code(_ L: LaunchLayout) -> some View {
        let snippet = props.code ?? LaunchProps.CodeSnippet(source: "")
        let caption = Self.balance(snippet.caption ?? "Just a few lines of Swift.")
        let mode = LaunchScore.Cue.codeMode(plan)
        let codeWidth = L.isVertical ? L.width : 1080 * L.type
        let title = KeynoteTitle(caption, at: l, start: 0.05, size: L.isVertical ? 96 : 84,
                                 alignment: L.isVertical ? .center : .leading, accentLine: 1,
                                 maxWidth: L.isVertical ? L.width : 560 * L.type)
        let window = CodeReveal(snippet.source, language: snippet.language, at: l, start: LaunchScore.Cue.codeStart,
                                mode: mode, focus: snippet.focus, title: snippet.title, maxWidth: codeWidth)
            .reveal(Motion.pop(l, 0.15, response: 0.55, damping: 0.82), rise: 50)
        if L.isVertical {
            VStack(spacing: 64 * L.type) { title; window }
        } else {
            HStack(alignment: .center, spacing: 90 * L.type) { title.frame(width: 560 * L.type, alignment: .leading); window }
        }
    }

    // MARK: Copy

    private var openLine: String {
        props.voiceoverLines?["open"] ?? "Introducing"
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
        case .app: return list.map { "For \($0)." } ?? (props.subtitle ?? "")
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

    /// Splits a sentence into one or two lines of similar length (at a comma when there is one).
    public static func balance(_ s: String) -> [String] {
        let words = s.split(separator: " ").map(String.init)
        guard words.count >= 3, s.count > 16 else { return [s] }
        if let comma = words.firstIndex(where: { $0.hasSuffix(",") || $0.hasSuffix(".") }), comma < words.count - 1,
           comma >= words.count / 3, comma <= words.count * 2 / 3 {
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
