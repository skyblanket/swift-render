import AppKit
import SwiftUI
import XCTest
@testable import SwiftRender
@testable import SwiftRenderScenes
@testable import SwiftRenderKit
@testable import SwiftRenderTool

/// Regression tests for the 0.10 review findings in the CLI, the Kit and the engine
/// caches: output paths, scene names and ids reaching the file system, knob files,
/// review sign-off, process time limits, and caches that must notice edited files.
final class HardeningTests: XCTestCase {
    private func tempDir(_ tag: String = "sr-hard") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.resolvingSymlinksInPath()
    }

    private func tempProject() throws -> Project {
        let dir = try tempDir("sr-hard-proj")
        try "// swift-tools-version: 5.10\n".write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        return Project(root: dir)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: --out never deletes a directory

    func testOutputPathRefusesDirectoriesAndMissingValues() throws {
        let dir = try tempDir()
        let victim = dir.appendingPathComponent("victim", isDirectory: true)
        try FileManager.default.createDirectory(at: victim.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "keep".write(to: victim.appendingPathComponent("sub/notes.txt"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try OutputPath.validate(""))
        XCTAssertThrowsError(try OutputPath.validate("out/"))
        XCTAssertThrowsError(try OutputPath.validate(victim.path))
        XCTAssertNoThrow(try OutputPath.validate(victim.appendingPathComponent("film.mp4").path))

        XCTAssertThrowsError(try OutputPath.removeExistingFile(at: victim))
        XCTAssertTrue(exists(victim.appendingPathComponent("sub/notes.txt")), "a directory is never removed")

        let file = dir.appendingPathComponent("old.mp4")
        try Data([1, 2, 3]).write(to: file)
        try OutputPath.removeExistingFile(at: file)
        XCTAssertFalse(exists(file))
        try OutputPath.removeExistingFile(at: file)            // missing is fine

        // A symlink is unlinked, its target left alone.
        let target = dir.appendingPathComponent("target.txt")
        try "t".write(to: target, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("link.mp4")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try OutputPath.removeExistingFile(at: link)
        XCTAssertTrue(exists(target))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
    }

    func testCLIArgsRejectMissingAndMalformedValues() throws {
        let dir = try tempDir()
        func parse(_ tail: [String]) throws -> CLIArgs { try parseCLIArgs(["swift-render", "render", "TextReveal"] + tail) }
        func rejects(_ tail: [String], _ needle: String, line: UInt = #line) {
            XCTAssertThrowsError(try parse(tail), line: line) { e in
                XCTAssertTrue("\(e)".contains(needle), "\(e)", line: line)
                XCTAssertEqual((e as? CLIUsageError)?.code, 64, line: line)
            }
        }
        rejects(["--out"], "--out needs a value")                  // the one-token typo that used to delete the cwd
        rejects(["--out", "--preview"], "--out needs a value")
        rejects(["--out", "renders/"], "names a directory")
        rejects(["--out", dir.path], "existing directory")
        rejects(["--fps", "0"], "--fps")
        rejects(["--fps", "-30"], "--fps")
        rejects(["--duration", "-2"], "--duration")
        rejects(["--duration", "nan"], "--duration")
        rejects(["--range", "3:1"], "--range")
        rejects(["--at", "nan"], "--at")
        rejects(["--aspect", "4:3"], "--aspect")
        rejects(["--jobs", "zero"], "--jobs")
        rejects(["--snapshot", dir.path], "existing directory")

        let ok = try parse(["--out", dir.appendingPathComponent("a.mp4").path, "--fps", "30", "--range", "0.5:1",
                            "--at", "1,2.5", "--preview"])
        XCTAssertEqual(ok.fps, 30)
        XCTAssertEqual(ok.rangeStart, 0.5)
        XCTAssertEqual(ok.at, [1, 2.5])
        XCTAssertTrue(ok.preview)
    }

    @MainActor
    func testRecorderAndAssemblerNeverReplaceADirectory() async throws {
        let dir = try tempDir()
        let victim = dir.appendingPathComponent("renders", isDirectory: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try "keep".write(to: victim.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)

        let recorder = Recorder(config: .init(fps: 10, size: CGSize(width: 64, height: 64), postFX: false))
        do {
            try await recorder.render(to: victim, duration: 0.2) { _ in Color.red }
            XCTFail("rendering onto a directory must throw")
        } catch {}
        XCTAssertTrue(exists(victim.appendingPathComponent("keep.txt")))

        let chunk = dir.appendingPathComponent("chunk.mp4")
        try await recorder.render(to: chunk, duration: 0.2) { _ in Color.blue }
        do {
            try await MP4Assembler.assemble(video: [chunk], audio: nil, to: victim)
            XCTFail("assembling onto a directory must throw")
        } catch {}
        XCTAssertTrue(exists(victim.appendingPathComponent("keep.txt")))

        // A regular old output is still replaced.
        let out = dir.appendingPathComponent("film.mp4")
        try Data("old".utf8).write(to: out)
        try await MP4Assembler.assemble(video: [chunk], audio: nil, to: out)
        XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0, 3)
    }

    /// End to end with the real binary: `render X --out` (no value) inside a directory
    /// must exit 64 and leave that directory alone.
    func testCLIRenderWithDanglingOutLeavesWorkingTreeAlone() throws {
        let bin = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("swift-render")
        guard FileManager.default.isExecutableFile(atPath: bin.path) else {
            throw XCTSkip("swift-render not built next to the test bundle (\(bin.path))")
        }
        let dir = try tempDir("sr-victim")
        try "notes".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        for tail in [["--out"], ["--out", "."], ["--jobs", "2", "--out", dir.path]] {
            let p = Process()
            p.executableURL = bin
            p.arguments = ["render", "TextReveal", "--preview", "--duration", "0.3"] + tail
            p.currentDirectoryURL = dir
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 64, "\(tail)")
            XCTAssertTrue(OutputPath.isDirectory(dir), "\(tail)")
            XCTAssertTrue(exists(dir.appendingPathComponent("notes.txt")), "\(tail)")
        }
    }

    func testJobsForwardTheInvokedArgumentsNotTheProcessArgv() {
        let argv = ["swift-render", "render", "X", "--jobs", "4", "--duration", "5", "--out", "o.mp4", "--open", "--fps", "30"]
        XCTAssertEqual(chunkPassthrough(argv), ["--duration", "5", "--fps", "30"])
    }

    // MARK: scene names and ids never become paths

    func testSceneNamesStayInsideTheirDirectories() throws {
        let project = try tempProject()
        XCTAssertTrue(Project.isValidSceneName("TimelineDemo"))
        XCTAssertTrue(Project.isValidSceneName("_Private2"))
        for bad in ["", "../../swift-render", "a/b", ".hidden", "9Lives", "Na\u{0}me", "Ünïcode", "a.b"] {
            XCTAssertFalse(Project.isValidSceneName(bad), bad)
            for url in [project.knobsURL(scene: bad), project.reviewURL(scene: bad)] {
                XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path,
                               (url.path.contains("/knobs/") ? project.knobsDir : project.reviewsDir).standardizedFileURL.path,
                               "\(bad) → \(url.path)")
            }
            XCTAssertEqual(project.propsVariantsDir(scene: bad).deletingLastPathComponent().standardizedFileURL.path,
                           project.propsDir.standardizedFileURL.path)
        }
        XCTAssertEqual(project.knobsURL(scene: "Hello").lastPathComponent, "Hello.json")
    }

    func testReviewIdsAndAttachmentPathsAreContained() throws {
        let project = try tempProject()
        try project.ensureDotDir()
        let store = ReviewStore(project: project)
        XCTAssertEqual(ReviewAttachmentPaths.before("c1a2b3c4d"), ".swift-render/attachments/c1a2b3c4d-before.png")
        for id in ["../../../escaped", "a/b", "..", ""] {
            let rel = ReviewAttachmentPaths.after(id, reply: "../r")
            XCTAssertNotNil(store.containedAttachmentURL(rel), rel)
            XCTAssertEqual(store.url(forAttachment: rel).deletingLastPathComponent().path,
                           project.attachmentsDir.standardizedFileURL.path, rel)
        }
        for bad in [".swift-render/attachments/../../Sources/X.swift", ".swift-render/attachments/sub/x.png",
                    "/etc/hosts", ".swift-render/attachments/", ".swift-render/attachments/.."] {
            XCTAssertNil(store.containedAttachmentURL(bad), bad)
        }
    }

    /// A shared review file whose attachment paths climb out of attachments/ must not
    /// make `delete` remove anything outside it — file or directory.
    func testRemoveIgnoresAttachmentPathsOutsideAttachments() throws {
        let project = try tempProject()
        let store = ReviewStore(project: project)
        let important = project.root.appendingPathComponent("Sources/App/Important.swift")
        try FileManager.default.createDirectory(at: important.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "let x = 1".write(to: important, atomically: true, encoding: .utf8)
        let precious = project.root.appendingPathComponent("Precious", isDirectory: true)
        try FileManager.default.createDirectory(at: precious, withIntermediateDirectories: true)
        try "a".write(to: precious.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let outside = project.root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).txt")
        try "o".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        var c = ReviewComment(t: 1, body: "x", author: ReviewAuthor(name: "Mallory"))
        c.attachments = [ReviewAttachment(kind: .before, path: ".swift-render/attachments/../../Sources/App/Important.swift"),
                         ReviewAttachment(kind: .frame, path: ".swift-render/attachments/../../../\(outside.lastPathComponent)")]
        c.replies = [ReviewReply(author: .agent(), body: "y",
                                 attachments: [ReviewAttachment(kind: .after, path: ".swift-render/attachments/../../Precious")])]
        let good = ReviewAttachmentPaths.before(c.id)
        try store.add(scene: "Hello", c)
        try store.attach(scene: "Hello", id: c.id, ReviewAttachment(kind: .before, path: good))
        try Data([1]).write(to: store.url(forAttachment: good))

        try store.remove(scene: "Hello", id: c.id)
        XCTAssertTrue(exists(important))
        XCTAssertTrue(exists(precious.appendingPathComponent("a.txt")))
        XCTAssertTrue(exists(outside))
        XCTAssertFalse(exists(store.url(forAttachment: good)), "the comment's own attachment is still removed")
    }

    func testStatusChangesClearAHumanSignOff() throws {
        let project = try tempProject()
        let store = ReviewStore(project: project)
        var c = ReviewComment(t: 1, body: "logo", author: ReviewAuthor(name: "Sky"), status: .resolved, resolution: "bigger")
        c.acceptedBy = ReviewAuthor(name: "Sky")
        try store.add(scene: "Hello", c)

        // Same status, no new resolution: the sign-off stands.
        XCTAssertNotNil(try store.setStatus(scene: "Hello", id: c.id, .resolved).acceptedBy)
        try store.setStatus(scene: "Hello", id: c.id, .open, by: ReviewAuthor(name: "Sky"))
        try store.setStatus(scene: "Hello", id: c.id, .inProgress, by: .agent())
        let after = try store.setStatus(scene: "Hello", id: c.id, .resolved, by: .agent(), resolution: "new unreviewed fix")
        XCTAssertNil(after.acceptedBy, "an agent's new resolution is not human-accepted")

        try store.update(scene: "Hello", id: c.id) { $0.acceptedBy = ReviewAuthor(name: "Sky") }
        XCTAssertNil(try store.setStatus(scene: "Hello", id: c.id, .resolved, resolution: "different text").acceptedBy)
    }

    func testTransitionChecksUnderTheLock() throws {
        let project = try tempProject()
        let store = ReviewStore(project: project)
        let c = try store.add(scene: "Hello", ReviewComment(t: 1, body: "x", author: ReviewAuthor(name: "Sky")))
        struct Refused: Error {}
        XCTAssertThrowsError(try store.transition(scene: "Hello", id: c.id, to: .resolved) { _ in throw Refused() })
        XCTAssertEqual(try store.load(scene: "Hello").comments.first?.status, .open, "a refused transition writes nothing")
        XCTAssertEqual(try store.transition(scene: "Hello", id: c.id, to: .resolved) { _ in }.status, .resolved)
    }

    func testTimecodeFormatNeverTraps() {
        XCTAssertEqual(ReviewComment.format(72.5), "01:12.50")
        for t in [Double.nan, .infinity, -.infinity] { XCTAssertEqual(ReviewComment.format(t), "--:--.--") }
        XCTAssertFalse(ReviewComment.format(1e19).isEmpty)
        XCTAssertFalse(ReviewComment.format(-1e300).isEmpty)
    }

    func testUnreadableReviewFilesAreReportedNotSilentlyEmpty() throws {
        let project = try tempProject()
        let store = ReviewStore(project: project)
        let c = try store.add(scene: "Hello", ReviewComment(t: 1, body: "x", author: ReviewAuthor(name: "Sky")))
        let url = project.reviewURL(scene: "Hello")
        try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "\"open\"", with: "\"blocked\"")
            .write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertEqual(store.unreadableScenes().map(\.scene), ["Hello"])
        XCTAssertThrowsError(try store.resolve(id: c.id)) { e in XCTAssertTrue("\(e)".contains("unreadable"), "\(e)") }
    }

    // MARK: knob files

    func testKnobSaveNeverReplacesABrokenFile() throws {
        let project = try tempProject()
        let url = project.knobsURL(scene: "Film")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let conflicted = "{\n<<<<<<< HEAD\n  \"speed\": 1.5,\n=======\n  \"speed\": 2,\n>>>>>>> theirs\n  \"title\": \"Hello\"\n}\n"
        try conflicted.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(KnobFile.load(url), [:], "renders keep going on a broken file")
        XCTAssertThrowsError(try KnobFile.loadStrict(url))
        XCTAssertThrowsError(try KnobFile.save(["speed": .number(2)], to: url))
        XCTAssertThrowsError(try KnobFile.save([:], to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), conflicted, "left untouched")

        let fine = project.knobsURL(scene: "Fine")
        XCTAssertEqual(try KnobFile.loadStrict(fine), [:], "missing = no overrides")
        try KnobFile.save(["a": .number(1)], to: fine)
        try KnobFile.save(["a": .number(2), "b": .bool(true)], to: fine)
        XCTAssertEqual(try KnobFile.loadStrict(fine), ["a": .number(2), "b": .bool(true)])
        try KnobFile.save([:], to: fine)
        XCTAssertFalse(exists(fine))
    }

    // MARK: project discovery

    func testDiscoverPrefersAnExplicitFolderAndALaunchPackage() throws {
        let a = try tempProject(), b = try tempProject()
        setenv("SWIFT_RENDER_ROOT", a.root.path, 1)
        defer { unsetenv("SWIFT_RENDER_ROOT") }
        XCTAssertEqual(Project.discover()?.root, a.root)
        XCTAssertEqual(Project.discover(from: b.root)?.root, b.root, "a chosen folder wins over the environment")
        unsetenv("SWIFT_RENDER_ROOT")

        // An app root whose Launch/ is the swift-render package (what `init` creates).
        let launch = b.root.appendingPathComponent("Launch", isDirectory: true)
        try FileManager.default.createDirectory(at: launch, withIntermediateDirectories: true)
        try #"{"product":"launch"}"#.write(to: launch.appendingPathComponent("swift-render.json"), atomically: true, encoding: .utf8)
        let found = try XCTUnwrap(Project.discover(from: b.root))
        XCTAssertEqual(found.root, launch.standardizedFileURL)
        XCTAssertEqual(found.config.product, "launch")
        let sub = b.root.appendingPathComponent("Sources/App", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        XCTAssertEqual(Project.discover(from: sub)?.root, launch.standardizedFileURL)
    }

    func testExternalLaunchPropsResolveAgainstTheScannedRoot() throws {
        let app = try tempDir("sr-app")
        let icon = app.appendingPathComponent("Sources/App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
        try FileManager.default.createDirectory(at: icon.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x89]).write(to: icon)
        let launchDir = app.appendingPathComponent(".swift-render/launch", isDirectory: true)
        try FileManager.default.createDirectory(at: launchDir, withIntermediateDirectories: true)
        let props = launchDir.appendingPathComponent("App.json")
        let json = #"{"name":"App","icon":{"path":"Sources/App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"},"screenshots":[{"path":"missing.png"}]}"#
        try json.write(to: props, atomically: true, encoding: .utf8)

        XCTAssertEqual(PropsAssets.scannedRoot(forPropsFile: props)?.path, app.standardizedFileURL.path)
        XCTAssertNil(PropsAssets.scannedRoot(forPropsFile: app.appendingPathComponent("x.json")))
        let other = try tempProject()
        let text = try PropsAssets.read(props, projectRoot: other.root)
        XCTAssertTrue(text.contains(icon.standardizedFileURL.path), text)
        XCTAssertTrue(text.contains("\"missing.png\""), "paths that don't exist are left as they are")
        XCTAssertEqual(try PropsAssets.read(props, projectRoot: app), json, "unchanged when the host runs in the scanned root")
    }

    // MARK: processes

    func testProcessRunnerTimesOutAndStopsTheWholeGroup() throws {
        let dir = try tempDir()
        let pidFile = dir.appendingPathComponent("grandchild.pid")
        let start = Date()
        XCTAssertThrowsError(try ProcessRunner.run("/bin/sh", ["-c", "sleep 60 & echo $! > '\(pidFile.path)'; wait"],
                                                   timeout: 0.5)) { e in
            XCTAssertEqual(e as? ProcessRunnerError, .timedOut(seconds: 0.5))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 8)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let deadline = Date().addingTimeInterval(4)
        while kill(pid, 0) == 0, Date() < deadline { usleep(50_000) }
        XCTAssertNotEqual(kill(pid, 0), 0, "the grandchild in the child's process group was stopped too")

        let token = ProcessCancel()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { token.cancel() }
        XCTAssertThrowsError(try ProcessRunner.run("/bin/sleep", ["60"], cancel: token)) { e in
            XCTAssertEqual(e as? ProcessRunnerError, .cancelled)
        }
        XCTAssertThrowsError(try ProcessRunner.run("/bin/sleep", ["60"], cancel: token), "a cancelled token stops later runs at once")
        XCTAssertEqual(try ProcessRunner.run("/bin/echo", ["hi"], timeout: 10).stdout, "hi\n")
    }

    // MARK: caches notice edited files

    private func writeConstantWAV(_ value: Float, frames: Int, to url: URL) throws {
        try WAV.write(left: Array(repeating: value, count: frames), right: Array(repeating: value, count: frames), to: url)
        // Same size on purpose (only content + mtime differ): bump mtime past the old one.
        let later = Date().addingTimeInterval(Double.random(in: 1...1000))
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: url.path)
    }

    func testSampleLibraryReloadsAnEditedFile() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("hit.wav")
        try writeConstantWAV(0.5, frames: 2000, to: url)
        XCTAssertGreaterThan(try SampleLibrary.load(url: url).left[1000], 0.4)
        try writeConstantWAV(-0.5, frames: 2000, to: url)
        XCTAssertLessThan(try SampleLibrary.load(url: url).left[1000], -0.4, "the edited sample, not the memo")
    }

    func testAudioCacheNeverMixesAStaleSample() throws {
        let dir = try tempDir()
        let sampleURL = dir.appendingPathComponent("foley.wav")
        let cache = dir.appendingPathComponent("cache", isDirectory: true)
        try writeConstantWAV(0.5, frames: 4000, to: sampleURL)
        let score = Score(duration: 0.5) { sample(sampleURL.path, at: 0) }
        let first = try AudioCache.load(score, in: cache)
        XCTAssertGreaterThan(first.left[2000], 0)
        try writeConstantWAV(-0.5, frames: 4000, to: sampleURL)
        let second = try AudioCache.load(score, in: cache)
        XCTAssertNotEqual(first.fingerprint, second.fingerprint)
        XCTAssertFalse(second.cacheHit)
        XCTAssertLessThan(second.left[2000], 0, "re-synthesized with the edited sample")
        XCTAssertLessThan(try AudioCache.readFloatWAV(second.wav).left[2000], 0, "and that is what got cached")
    }

    func testImagesReloadAfterTheFileChanges() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("still.png")
        func writePNG(_ w: Int) throws {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        }
        try writePNG(8)
        XCTAssertEqual(MediaLibrary.image(url.path)?.width, 8)
        try writePNG(16)
        XCTAssertEqual(MediaLibrary.image(url.path)?.width, 16)
    }

    /// A TTS failure leaves the voice out of the mix: that mix must not be cached under
    /// the fingerprint (it would outlive the failure), and the result says what's missing.
    func testDegradedVoiceoverIsNotCached() throws {
        let dir = try tempDir()
        let old = getenv("SWIFT_RENDER_KOKORO_PYTHON").map { String(cString: $0) }
        setenv("SWIFT_RENDER_KOKORO_PYTHON", dir.appendingPathComponent("no-python").path, 1)
        defer { if let old { setenv("SWIFT_RENDER_KOKORO_PYTHON", old, 1) } else { unsetenv("SWIFT_RENDER_KOKORO_PYTHON") } }
        let line = "never synthesized \(UUID().uuidString)"
        let score = Score(duration: 1) {
            speak(line, at: 0.1, engine: .kokoro())
            thump(at: 0.5)
        }
        let cache = dir.appendingPathComponent("cache", isDirectory: true)
        let audio = try AudioCache.load(score, in: cache)
        XCTAssertFalse(audio.degraded.isEmpty)
        XCTAssertTrue(audio.degraded[0].contains("voiceover"), audio.degraded[0])
        XCTAssertFalse(exists(AudioCache.url(fingerprint: audio.fingerprint, in: cache)), "nothing cached under the fingerprint")
        XCTAssertTrue(exists(audio.wav), "the degraded mix is still playable")
        XCTAssertNil(AudioCache.existing(score, in: cache))
        let again = try AudioCache.load(score, in: cache)
        XCTAssertFalse(again.cacheHit, "a later load tries again")
    }
}
