import AppKit
import AVFoundation
import SwiftRender
import SwiftUI

// MARK: - Live preview
//
// Scenes are pure functions of t, so scrubbing is free: the window simply renders
// `body(at: t)` for whatever t the slider or the clock says. Audio is the same
// mix the render muxes (Score or --audio) and is the clock while playing.

@MainActor
final class PreviewModel: ObservableObject {
    @Published var t: Double = 0
    @Published var playing = false
    let duration: Double
    let fps: Int
    private let player: AVAudioPlayer?
    private var timer: Timer?
    private var startWall = Date()
    private var startT = 0.0

    init(duration: Double, fps: Int, audioURL: URL?) {
        self.duration = duration
        self.fps = fps
        player = audioURL.flatMap { try? AVAudioPlayer(contentsOf: $0) }
        player?.prepareToPlay()
    }

    var hasAudio: Bool { player != nil }

    func toggle() { playing ? pause() : play() }

    func play() {
        if t >= duration - 0.5 / Double(fps) { t = 0 }
        playing = true
        startWall = Date(); startT = t
        if let player { player.currentTime = t; player.play() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func pause() {
        playing = false
        timer?.invalidate(); timer = nil
        player?.pause()
    }

    func seek(_ nt: Double) {
        t = max(0, min(duration, nt))
        if playing {
            startWall = Date(); startT = t
            player?.currentTime = t
        }
    }

    func step(frames: Int) {
        pause()
        let f = (t * Double(fps)).rounded() + Double(frames)
        seek(f / Double(fps))
    }

    private func tick() {
        guard playing else { return }
        let nt: Double
        if let player, player.isPlaying { nt = player.currentTime }
        else { nt = startT + Date().timeIntervalSince(startWall) }
        if nt >= duration { t = duration; pause(); return }
        t = nt
    }
}

struct PreviewRoot: View {
    @ObservedObject var model: PreviewModel
    let size: CGSize
    let postFX: Bool
    let make: (Double) -> AnyView

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let s = min(geo.size.width / size.width, geo.size.height / size.height)
                RenderFrame(size: size, fps: model.fps, duration: model.duration, t: model.t, postFX: postFX) {
                    make(model.t)
                }
                .scaleEffect(s)
                .frame(width: size.width * s, height: size.height * s)
                .clipped()
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .background(Color.black)
            controls
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button(action: model.toggle) {
                Image(systemName: model.playing ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.space, modifiers: [])
            Text(timecode(model.t)).monospacedDigit().frame(width: 92, alignment: .leading)
            Slider(value: Binding(get: { model.t }, set: { model.seek($0) }), in: 0...max(0.001, model.duration))
            Text("f \(Int((model.t * Double(model.fps)).rounded()))").monospacedDigit().frame(width: 64, alignment: .trailing)
            Text(timecode(model.duration)).monospacedDigit().foregroundStyle(.secondary)
            if !model.hasAudio { Image(systemName: "speaker.slash").foregroundStyle(.secondary) }
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    private func timecode(_ t: Double) -> String {
        String(format: "%02d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }
}

@MainActor
func runPreview(runner: SceneRunner, name: String, duration: Double, size: CGSize, fps: Int,
                audio: AudioSource, propsURL: URL?, postFX: Bool, snapshot: String?) throws {
    let make = try runner.makeView(duration, audio, propsURL)

    var audioURL: URL? = nil
    var tempAudio: URL? = nil
    switch audio {
    case .file(let u): audioURL = u
    case .score(let score):
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sr-preview-\(UUID().uuidString).wav")
        try ScoreSynth.writeWAV(score, to: tmp)
        audioURL = tmp; tempAudio = tmp
    case .none: break
    }

    let model = PreviewModel(duration: duration, fps: fps, audioURL: audioURL)
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let host = NSHostingView(rootView: PreviewRoot(model: model, size: size, postFX: postFX, make: make))
    let aspect = size.width / max(1, size.height)
    let w: CGFloat = aspect >= 1 ? 1280 : 560
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: w / aspect + 40),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
    window.title = "\(name) — swift-render preview"
    window.contentView = host
    window.center()
    window.makeKeyAndOrderFront(nil)
    window.isReleasedWhenClosed = false

    let cleanup = { if let tempAudio { try? FileManager.default.removeItem(at: tempAudio) } }
    NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
        cleanup()
        NSApp.terminate(nil)
    }

    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 123: model.step(frames: shift ? -fps : -1); return nil          // ←
        case 124: model.step(frames: shift ? fps : 1); return nil            // →
        case 115: model.pause(); model.seek(0); return nil                   // home
        case 119: model.pause(); model.seek(duration); return nil            // end
        case 53: window.close(); return nil                                  // esc
        default:
            if event.charactersIgnoringModifiers == "w", event.modifierFlags.contains(.command) {
                window.close(); return nil
            }
            return event
        }
    }

    if let snapshot {
        // Deterministic still of the preview UI for agents/CI: seek, lay out, capture, quit.
        model.seek(min(duration, duration * 0.5))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                let url = URL(fileURLWithPath: snapshot)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                print("[swift-render] preview snapshot → \(snapshot)")
            }
            cleanup()
            exit(0)
        }
    }

    print("[swift-render] preview \(name) — space play/pause · ←/→ frame · ⇧←/⇧→ 1s · esc close")
    app.activate(ignoringOtherApps: true)
    app.run()
}
