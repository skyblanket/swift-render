import Foundation

// MARK: - LaunchScanner
//
// Reads a Swift codebase and proposes LaunchProps: name, tagline, features,
// icon, accent, code, changelog, platforms and numbers — each with the file it
// came from. Offline and deterministic; a missing or malformed piece is
// reported, never thrown. The scanner never invents numbers: every highlight
// comes from git, the manifest or a file count.

/// Why the scanner chose each value, plus what it could not find.
public struct LaunchScanReport: Codable, Sendable, Equatable {
    public struct Evidence: Codable, Sendable, Equatable {
        public var field: String
        public var value: String
        /// "README.md:5", "git rev-list", "AppIcon.appiconset/Contents.json"
        public var source: String
        public init(field: String, value: String, source: String) {
            self.field = field; self.value = value; self.source = source
        }
    }
    public var root: String
    public var evidence: [Evidence] = []
    /// Disagreements the scanner resolved by precedence (e.g. CHANGELOG version vs latest tag).
    public var conflicts: [String] = []
    /// Fields it could not fill.
    public var missing: [String] = []
    public var warnings: [String] = []
    public init(root: String) { self.root = root }

    public func source(of field: String) -> String? { evidence.last { $0.field == field }?.source }
}

public struct LaunchScanner {
    public struct Options: Sendable {
        /// Run `swift package dump-package` (executes the manifest). Off for untrusted repos;
        /// a regex reading of Package.swift is used instead.
        public var executeManifest: Bool
        /// Read commit/contributor/tag stats and the remote URL from git.
        public var git: Bool
        /// Stop walking the tree after this many files. The walk is breadth-first, so
        /// top-level files (README, CHANGELOG, LICENSE) and shallow manifests are always seen.
        public var maxFiles: Int
        public init(executeManifest: Bool = true, git: Bool = true, maxFiles: Int = 20_000) {
            self.executeManifest = executeManifest; self.git = git; self.maxFiles = maxFiles
        }
    }

    /// The scanned directory, symlinks resolved (FileManager won't enumerate a symlink).
    public let root: URL
    public let options: Options
    /// The folder name as given (a symlink keeps its own name for the fallback product name).
    let folderName: String

    public init(root: URL, options: Options = Options()) {
        let given = root.standardizedFileURL
        self.root = given.resolvingSymlinksInPath()
        self.folderName = given.lastPathComponent
        self.options = options
    }

    /// `path` (relative to `root`, or absolute) as a file URL — nil when it resolves,
    /// symlinks included, to somewhere outside `root`. Scanned and user-edited asset
    /// paths go through this before anything is copied from them.
    public static func contained(_ path: String, in root: URL) -> URL? {
        guard !path.isEmpty else { return nil }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        return resolved.path.hasPrefix(prefix) ? resolved : nil
    }

    /// An SSH or HTTPS GitHub remote → ("https://github.com/o/r", "o/r"); nil for non-URL remotes.
    public static func githubURL(_ remote: String) -> (url: String, repo: String)? {
        State.githubURL(remote).map { ($0.0, $0.1) }
    }

    /// Scan the codebase. Never throws: missing pieces land in `report.missing`.
    public func scan() -> (props: LaunchProps, report: LaunchScanReport) {
        var s = State(root: root, folderName: folderName, options: options)
        s.run()
        return (s.props, s.report)
    }
}

// MARK: - Scan state

private let skipDirs: Set<String> = [".build", ".git", ".swiftpm", "DerivedData", "Pods", "Carthage", "node_modules",
                                     "checkouts", "build", ".swift-render", "xcuserdata", "out", "vendor", ".venv"]

private struct State {
    let root: URL
    let folderName: String
    let options: LaunchScanner.Options
    var props = LaunchProps(name: "")
    var report: LaunchScanReport

    // Gathered facts, resolved by precedence at the end.
    var packageName: String?
    var packageProducts: (library: [String], executable: [String], app: [String]) = ([], [], [])
    /// Executable product → its targets; executable target → its source directory.
    var executableProductTargets: [String: [String]] = [:]
    var executableTargetPaths: [String: String] = [:]
    var packagePlatforms: [LaunchProps.Platform] = []
    var packageDependencies: Int?
    var toolsVersion: String?
    var xcodeApp: (name: String, version: String?, displayName: String?, platforms: [LaunchProps.Platform], swift: String?, iconName: String?)?
    var plistName: String?
    var readmeH1: (String, Int)?
    var changelogVersion: (String, String?, Int, String)?   // version, date, line, file
    var tagVersion: String?
    var files: [String] = []                                   // relative paths
    var walkCapped = false
    var accentFromBadge: (String, Int)?
    /// Sources with an `@main` SwiftUI `App` (SwiftPM apps have no .xcodeproj).
    var appMains: [String] = []

    init(root: URL, folderName: String, options: LaunchScanner.Options) {
        self.root = root
        self.folderName = folderName
        self.options = options
        report = LaunchScanReport(root: root.path)
        props.accent = ""   // filled by AccentColor / README badge / default in resolve()
    }

    mutating func note(_ field: String, _ value: String, _ source: String) {
        report.evidence.append(.init(field: field, value: value, source: source))
    }

    /// The product's names as spelled in its sources, which sentence-casing must not change.
    var knownNames: [String] {
        [packageName, xcodeApp?.name, xcodeApp?.displayName, plistName, readmeH1?.0, folderName].compactMap { $0 }
    }

    mutating func run() {
        walk()
        scanPackage()
        scanXcodeProject()
        scanAssets()
        scanInfoPlist()
        scanReadme()
        scanChangelog()
        scanLicense()
        scanGit()
        scanCode()
        scanScreenshots()
        resolve()
    }

    // MARK: file walk

    /// Breadth-first, in name order: everything at depth n is recorded before depth n + 1,
    /// so top-level files and shallow manifests (Info.plist, .xcodeproj, Sources/*.swift)
    /// are seen before a deep data or asset folder can use up `maxFiles`, and a capped
    /// scan is deterministic. Hidden entries are skipped except `.github/`.
    mutating func walk() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        var queue: [(url: URL, rel: String, depth: Int)] = [(root, "", 0)]
        var head = 0
        outer: while head < queue.count {
            let (dir, dirRel, depth) = queue[head]
            head += 1
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: []) else { continue }
            for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = url.lastPathComponent
                if name.hasPrefix("."), !(depth == 0 && name == ".github") { continue }
                let rel = dirRel.isEmpty ? name : dirRel + "/" + name
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {   // symlinked directories are not followed
                    // .xcassets / .xcodeproj / .icon are read as units: record them, don't descend.
                    if name.hasSuffix(".xcassets") || name.hasSuffix(".xcodeproj") || name.hasSuffix(".icon") {
                        files.append(rel)
                        continue
                    }
                    if skipDirs.contains(name) || name.hasSuffix(".xcframework") || values?.isPackage == true { continue }
                    // A `swift-render init` scaffold (Launch/) is the film, not the product's code.
                    if fm.fileExists(atPath: url.appendingPathComponent("swift-render.json").path),
                       fm.fileExists(atPath: url.appendingPathComponent("Sources/LaunchScenes").path) { continue }
                    queue.append((url, rel, depth + 1))
                    continue
                }
                files.append(rel)
                // Top-level files never count against the cap.
                if depth > 0, files.count >= options.maxFiles {
                    walkCapped = true
                    report.warnings.append("stopped after \(options.maxFiles) files")
                    break outer
                }
            }
        }
        files.sort()
    }

    /// A text file with CRLF / CR line endings normalized to LF.
    func read(_ rel: String) -> String? {
        (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8))?
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    func firstFile(named names: [String], topLevelOnly: Bool = true) -> String? {
        for n in names {
            if let f = files.first(where: { (topLevelOnly ? !$0.contains("/") : true) && $0.lowercased() == n.lowercased() }) { return f }
        }
        return nil
    }

    // MARK: Package.swift

    mutating func scanPackage() {
        guard let manifest = read("Package.swift") else { return }
        if let r = manifest.range(of: #"swift-tools-version:\s*([0-9.]+)"#, options: .regularExpression) {
            let v = manifest[r].split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            toolsVersion = v.split(separator: ".").prefix(2).joined(separator: ".")
        }
        if options.executeManifest, let json = dumpPackage() {
            parseDump(json)
        } else {
            parseManifestRegex(manifest)
        }
    }

    /// `swift package dump-package` in a private scratch dir: under `swift run` the
    /// package's own `.build` is locked, and dump-package would wait on it forever.
    /// Killed after 60 s (the regex reading takes over).
    mutating func dumpPackage() -> [String: Any]? {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("sr-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["swift", "package", "--scratch-path", scratch.path, "dump-package"]
        p.currentDirectoryURL = root
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let box = ScanOutput()
        let reader = DispatchGroup()
        reader.enter()
        let handle = out.fileHandleForReading
        DispatchQueue.global().async { box.data = handle.readDataToEndOfFile(); reader.leave() }
        guard (try? p.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(60)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning {
            p.terminate()
            report.warnings.append("swift package dump-package timed out; read Package.swift with regexes")
        }
        p.waitUntilExit()
        reader.wait()
        guard p.terminationStatus == 0,
              let obj = try? JSONSerialization.jsonObject(with: box.data) as? [String: Any] else { return nil }
        return obj
    }

    mutating func parseDump(_ json: [String: Any]) {
        if let name = json["name"] as? String { packageName = name; note("packageName", name, "swift package dump-package") }
        for p in json["products"] as? [[String: Any]] ?? [] {
            guard let name = p["name"] as? String, let type = p["type"] as? [String: Any] else { continue }
            if type["library"] != nil { packageProducts.library.append(name) }
            if type["executable"] != nil {
                packageProducts.executable.append(name)
                executableProductTargets[name] = p["targets"] as? [String] ?? []
            }
            if type.keys.contains(where: { $0.lowercased().contains("application") }) { packageProducts.app.append(name) }
        }
        for p in json["platforms"] as? [[String: Any]] ?? [] {
            if let n = p["platformName"] as? String, let name = Self.platform(n) {
                packagePlatforms.append(.init(name, minimum: (p["version"] as? String).map(Self.shortVersion)))
            }
        }
        for t in json["targets"] as? [[String: Any]] ?? [] where (t["type"] as? String) == "executable" {
            guard let name = t["name"] as? String else { continue }
            executableTargetPaths[name] = (t["path"] as? String).map { Self.trimSlashes($0) } ?? "Sources/\(name)"
        }
        packageDependencies = (json["dependencies"] as? [Any])?.count
        if let tv = (json["toolsVersion"] as? [String: Any])?["_version"] as? String {
            toolsVersion = tv.split(separator: ".").prefix(2).joined(separator: ".")
        }
    }

    mutating func parseManifestRegex(_ src: String) {
        if let m = Self.firstMatch(#"Package\s*\(\s*name:\s*"([^"]+)""#, src) { packageName = m; note("packageName", m, "Package.swift") }
        for m in Self.allMatches(#"\.library\s*\(\s*name:\s*"([^"]+)""#, src) { packageProducts.library.append(m) }
        for m in Self.allMatches(#"\.executable\s*\(\s*name:\s*"([^"]+)""#, src) { packageProducts.executable.append(m) }
        for (name, list) in Self.matchPairs(#"\.executable\s*\(\s*name:\s*"([^"]+)"\s*,\s*targets:\s*\[([^\]]*)\]"#, src) {
            executableProductTargets[name] = Self.allMatches(#""([^"]+)""#, list)
        }
        for (name, rest) in Self.matchPairs(#"\.executableTarget\s*\(\s*name:\s*"([^"]+)"([^)]*)"#, src) {
            executableTargetPaths[name] = Self.firstMatch(#"path:\s*"([^"]+)""#, rest).map { Self.trimSlashes($0) } ?? "Sources/\(name)"
        }
        for m in Self.allMatches(#"\.iOSApplication\s*\(\s*name:\s*"([^"]+)""#, src) { packageProducts.app.append(m) }
        let platformRE = #"\.(iOS|macOS|watchOS|tvOS|visionOS|macCatalyst)\s*\(\s*(?:\.v([0-9_]+)|"([0-9.]+)")"#
        if let re = try? NSRegularExpression(pattern: platformRE) {
            let ns = src as NSString
            for m in re.matches(in: src, range: NSRange(location: 0, length: ns.length)) {
                let n = ns.substring(with: m.range(at: 1))
                var v: String?
                if m.range(at: 2).location != NSNotFound { v = ns.substring(with: m.range(at: 2)).replacingOccurrences(of: "_", with: ".") }
                if m.range(at: 3).location != NSNotFound { v = ns.substring(with: m.range(at: 3)) }
                if let name = Self.platform(n), !packagePlatforms.contains(where: { $0.name == name }) {
                    packagePlatforms.append(.init(name, minimum: v.map(Self.shortVersion)))
                }
            }
        }
        packageDependencies = Self.allMatches(#"(\.package\s*\()"#, src).count
    }

    static func platform(_ s: String) -> LaunchProps.Platform.Name? {
        switch s.lowercased() {
        case "ios", "iphoneos": return .iOS
        case "macos", "macosx": return .macOS
        case "watchos": return .watchOS
        case "tvos", "appletvos": return .tvOS
        case "visionos", "xros": return .visionOS
        case "maccatalyst": return .macCatalyst
        case "linux": return .linux
        default: return nil
        }
    }

    static func shortVersion(_ v: String) -> String {
        var parts = v.split(separator: ".").map(String.init)
        while parts.count > 1 && parts.last == "0" { parts.removeLast() }
        return parts.joined(separator: ".")
    }

    // MARK: .xcodeproj

    mutating func scanXcodeProject() {
        let projects = files.filter { $0.hasSuffix(".xcodeproj") && !$0.contains("Pods") }
            .sorted { $0.split(separator: "/").count < $1.split(separator: "/").count }
        for proj in projects {
            let pbx = root.appendingPathComponent(proj).appendingPathComponent("project.pbxproj")
            guard let data = try? Data(contentsOf: pbx),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let objects = plist["objects"] as? [String: [String: Any]] else {
                report.warnings.append("\(proj): project.pbxproj unreadable")
                continue
            }
            func settings(_ listID: Any?) -> [String: Any] {
                guard let id = listID as? String, let list = objects[id],
                      let configs = list["buildConfigurations"] as? [String] else { return [:] }
                let named = configs.compactMap { objects[$0] }
                let release = named.first { ($0["name"] as? String) == "Release" } ?? named.first
                return release?["buildSettings"] as? [String: Any] ?? [:]
            }
            let projectSettings = objects.values.first { ($0["isa"] as? String) == "PBXProject" }
                .map { settings($0["buildConfigurationList"]) } ?? [:]
            let projectBase = (proj as NSString).lastPathComponent.replacingOccurrences(of: ".xcodeproj", with: "")
            let apps = objects.values.filter {
                ($0["isa"] as? String) == "PBXNativeTarget" &&
                ($0["productType"] as? String) == "com.apple.product-type.application"
            }
            // Prefer the target named like the project.
            guard let app = apps.first(where: { ($0["name"] as? String) == projectBase }) ?? apps.first,
                  let targetName = app["name"] as? String else { continue }
            let bs = projectSettings.merging(settings(app["buildConfigurationList"])) { $1 }
            func str(_ k: String) -> String? {
                guard var v = bs[k] as? String else { return nil }
                v = v.replacingOccurrences(of: "$(TARGET_NAME)", with: targetName)
                     .replacingOccurrences(of: "${TARGET_NAME}", with: targetName)
                return v.contains("$(") ? nil : v
            }
            var platforms: [LaunchProps.Platform] = []
            let pairs: [(String, LaunchProps.Platform.Name)] = [("IPHONEOS_DEPLOYMENT_TARGET", .iOS), ("MACOSX_DEPLOYMENT_TARGET", .macOS),
                                                                ("XROS_DEPLOYMENT_TARGET", .visionOS), ("WATCHOS_DEPLOYMENT_TARGET", .watchOS),
                                                                ("TVOS_DEPLOYMENT_TARGET", .tvOS)]
            let supported = (str("SUPPORTED_PLATFORMS") ?? str("SDKROOT") ?? "").lowercased()
            let family = str("TARGETED_DEVICE_FAMILY") ?? ""
            for (key, name) in pairs {
                let sdk: [LaunchProps.Platform.Name: [String]] = [.iOS: ["iphoneos"], .macOS: ["macosx"], .visionOS: ["xros"],
                                                                  .watchOS: ["watchos"], .tvOS: ["appletvos"]]
                let listed = sdk[name]?.contains { supported.contains($0) } ?? false
                let byFamily = name == .visionOS && family.contains("7")
                if (listed || byFamily) || (supported.isEmpty && app["buildConfigurationList"] != nil && bs[key] != nil && name == .iOS) {
                    platforms.append(.init(name, minimum: str(key).map(Self.shortVersion)))
                }
            }
            if supported.contains("iphoneos") && !platforms.contains(where: { $0.name == .iOS }) { platforms.append(.init(.iOS)) }
            let product = str("PRODUCT_NAME") ?? targetName
            xcodeApp = (product, str("MARKETING_VERSION"), str("INFOPLIST_KEY_CFBundleDisplayName"), platforms,
                        str("SWIFT_VERSION").map(Self.shortVersion), str("ASSETCATALOG_COMPILER_APPICON_NAME"))
            note("xcodeApp", product, "\(proj)/project.pbxproj")
            return
        }
    }

    // MARK: Assets.xcassets — AppIcon + AccentColor

    mutating func scanAssets() {
        let catalogs = files.filter { $0.hasSuffix(".xcassets") && !Self.isTestPath($0) }
        let iconName = xcodeApp?.iconName ?? "AppIcon"
        var best: (path: String, pixels: Int, shape: LaunchProps.IconShape, source: String)?
        for cat in catalogs {
            let set = "\(cat)/\(iconName).appiconset"
            let contents = root.appendingPathComponent(set).appendingPathComponent("Contents.json")
            if let data = try? Data(contentsOf: contents),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for img in json["images"] as? [[String: Any]] ?? [] {
                    guard let file = img["filename"] as? String, img["appearances"] == nil else { continue }
                    // Xcode writes plain file names into an .appiconset; anything else (a path,
                    // "..", a symlink out of the repo) could pull an unrelated file into the film
                    // or into `init`'s Launch/assets/.
                    let rel = "\(set)/\(file)"
                    guard !file.isEmpty, file == (file as NSString).lastPathComponent, file != "..", file != ".",
                          LaunchScanner.contained(rel, in: root) != nil else {
                        report.warnings.append("\(set)/Contents.json: ignored icon filename \"\(file)\" (outside the icon set)")
                        continue
                    }
                    guard FileManager.default.fileExists(atPath: root.appendingPathComponent(rel).path) else { continue }
                    let declared = Self.pixels(size: img["size"] as? String, scale: img["scale"] as? String)
                    let actual = Self.pngSize(root.appendingPathComponent(rel)).map { $0.0 * $0.1 } ?? 0
                    let px = max(declared, actual)
                    let idiom = (img["idiom"] as? String) ?? ""
                    let shape: LaunchProps.IconShape = idiom == "mac" ? .macOS : .iOS
                    // Prefer iOS/universal art (needs our squircle mask) at equal size.
                    let better = best == nil || px > best!.pixels || (px == best!.pixels && shape == .iOS && best!.shape == .macOS)
                    if better { best = (rel, px, shape, "\(set)/Contents.json") }
                }
            }
            let accent = root.appendingPathComponent("\(cat)/AccentColor.colorset/Contents.json")
            if props.accent.isEmpty,
               let data = try? Data(contentsOf: accent),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let hex = Self.colorsetHex(json) {
                props.accent = hex
                note("accent", hex, "\(cat)/AccentColor.colorset/Contents.json")
            }
        }
        if let best {
            props.icon = .init(path: best.path, shape: best.shape)
            note("icon", best.path, best.source)
        } else if let iconBundle = files.first(where: { $0.hasSuffix(".icon") && !Self.isTestPath($0) }) {
            report.missing.append("icon: \(iconBundle) is an Icon Composer bundle (not flattened) — export a PNG and set icon.path")
        }
    }

    /// Declared pixel count of an icon image ("1024x1024" at "1x"); 0 for nonsense (inf, NaN, huge).
    static func pixels(size: String?, scale: String?) -> Int {
        guard let size, let w = Double(size.split(separator: "x").first ?? "") else { return 0 }
        let s = Double((scale ?? "1x").replacingOccurrences(of: "x", with: "")) ?? 1
        let side = w * s
        guard side.isFinite, side > 0, side <= 65_535 else { return 0 }
        return Int(side * side)
    }

    /// Width and height from a PNG's IHDR chunk (no image decoding).
    static func pngSize(_ url: URL) -> (Int, Int)? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 24), d.count == 24,
              d.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { return nil }
        func be(_ o: Int) -> Int { d[o..<o + 4].reduce(0) { $0 << 8 | Int($1) } }
        let (width, height) = (be(16), be(20))
        // A corrupt header (0 or ~2^32) is not an image size, and w × h would overflow.
        guard (1...65_535).contains(width), (1...65_535).contains(height) else { return nil }
        return (width, height)
    }

    static func colorsetHex(_ json: [String: Any]) -> String? {
        let colors = json["colors"] as? [[String: Any]] ?? []
        guard let entry = colors.first(where: { $0["appearances"] == nil }) ?? colors.first,
              let comps = (entry["color"] as? [String: Any])?["components"] as? [String: Any] else { return nil }
        func v(_ k: String) -> Double? {
            guard let raw = comps[k] else { return nil }
            let s = "\(raw)".trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("0x") || s.hasPrefix("0X") { return Double(Int(s.dropFirst(2), radix: 16) ?? 0) / 255 }
            guard let x = Double(s) else { return nil }
            return s.contains(".") || x <= 1 ? x : x / 255
        }
        guard let r = v("red"), let g = v("green"), let b = v("blue") else { return nil }
        return LaunchColor.hex(r, g, b)
    }

    static func isTestPath(_ p: String) -> Bool {
        p.split(separator: "/").contains { $0.hasSuffix("Tests") || $0 == "Tests" || $0.hasSuffix("UITests") }
    }

    // MARK: Info.plist

    mutating func scanInfoPlist() {
        let plists = files.filter { $0.hasSuffix("Info.plist") && !Self.isTestPath($0) && !$0.contains(".xcodeproj/") }
        for rel in plists {
            guard let data = try? Data(contentsOf: root.appendingPathComponent(rel)),
                  let p = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let v = p[key] as? String, !v.contains("$("), !v.isEmpty {
                    plistName = v
                    note("displayName", v, "\(rel) \(key)")
                    return
                }
            }
        }
    }

    // MARK: README

    mutating func scanReadme() {
        guard let rel = firstFile(named: ["README.md", "README.markdown", "Readme.md", "README"]), let text = read(rel) else {
            report.missing.append(walkCapped ? "README not reached (scan stopped after \(options.maxFiles) files)"
                                             : "README (tagline, features, code)")
            return
        }
        let lines = text.components(separatedBy: "\n")
        var inFence = false
        var fenceLang = "", fenceStart = 0, fenceLines: [String] = []
        var heading = "", h2 = ""
        var swiftBlocks: [(code: String, line: Int, under: String)] = []
        var shellCommands: [(String, Int)] = []
        var taglineLine: Int?
        var paragraph: [String] = [], paragraphStart = 0
        var h3s: [(String, Int, String)] = []        // title, line, parent h2
        var h2s: [(String, Int)] = []
        var bulletsByH2: [String: [(String, Int)]] = [:]
        var sectionBody: [Int: String] = [:]        // first paragraph after a heading line
        var lastHeadingLine: Int?

        func isBadgeOrDecor(_ l: String) -> Bool {
            let t = l.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("[![") || t.hasPrefix("![") || t.hasPrefix("<") || t.contains("shields.io")
                || t.hasPrefix("---") || t.hasPrefix("http") || t.hasPrefix("|")
        }

        for (i, raw) in lines.enumerated() {
            let n = i + 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if inFence {
                    let code = fenceLines.joined(separator: "\n")
                    if fenceLang == "swift" { swiftBlocks.append((code, fenceStart, heading)) }
                    if ["bash", "sh", "shell", "console", "zsh", ""].contains(fenceLang) && fenceLang != "" {
                        for (k, l) in fenceLines.enumerated() { shellCommands.append((l, fenceStart + k + 1)) }
                    }
                    inFence = false
                } else {
                    inFence = true; fenceLang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
                    fenceStart = n; fenceLines = []
                }
                continue
            }
            if inFence { fenceLines.append(raw); continue }

            if let colors = Self.firstMatch(#"color=([0-9A-Fa-f]{6})\b"#, line), accentFromBadge == nil,
               line.lowercased().contains("release") || line.lowercased().contains("version") {
                accentFromBadge = ("#" + colors.uppercased(), n)
            }

            if line.hasPrefix("#") {
                if !paragraph.isEmpty, let h = lastHeadingLine, sectionBody[h] == nil { sectionBody[h] = paragraph.joined(separator: " ") }
                paragraph = []
                let level = line.prefix(while: { $0 == "#" }).count
                let title = LaunchText.clean(String(line.dropFirst(level)))
                if level == 1, readmeH1 == nil { readmeH1 = (title, n) }
                if level == 2 { h2 = title; h2s.append((title, n)) }
                if level == 3 { h3s.append((title, n, h2)) }
                heading = title
                lastHeadingLine = n
                continue
            }
            if readmeH1 == nil, let h = Self.firstMatch(#"<h1[^>]*>(.*?)</h1>"#, line) {
                readmeH1 = (LaunchText.clean(h), n)
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                bulletsByH2[h2, default: []].append((String(line.dropFirst(2)), n))
                continue
            }
            if line.isEmpty {
                if !paragraph.isEmpty {
                    if let h = lastHeadingLine, sectionBody[h] == nil { sectionBody[h] = paragraph.joined(separator: " ") }
                    if taglineLine == nil, readmeH1 != nil, h2s.isEmpty {
                        let para = paragraph.joined(separator: " ")
                        if !isBadgeOrDecor(para) {
                            taglineLine = paragraphStart
                            let (tag, rest) = LaunchText.splitSentence(para, limit: 80)
                            props.tagline = tag
                            note("tagline", tag, "\(rel):\(paragraphStart)")
                            if !rest.isEmpty, rest.count <= 110 {
                                let (sub, _) = LaunchText.splitSentence(rest, limit: 110)
                                props.subtitle = sub
                                note("subtitle", sub, "\(rel):\(paragraphStart)")
                            }
                        }
                    }
                }
                paragraph = []
                continue
            }
            if isBadgeOrDecor(line) || line.hasPrefix(">") && taglineLine != nil { continue }
            if paragraph.isEmpty { paragraphStart = n }
            paragraph.append(line.hasPrefix(">") ? String(line.dropFirst()) : line)
        }
        if let h1 = readmeH1 { note("readmeTitle", h1.0, "\(rel):\(h1.1)") }

        // Features: (1) bullets under a features-like H2, (2) H3s, (3) H2s minus boilerplate.
        let featureH2 = #"(?i)features|highlights|why |what you get|what's inside"#
        var feats: [(LaunchProps.Feature, String)] = []
        if let h = h2s.first(where: { $0.0.range(of: featureH2, options: .regularExpression) != nil }),
           let bullets = bulletsByH2[h.0] {
            for (b, n) in bullets.prefix(6) { feats.append((Self.feature(from: b, body: nil), "\(rel):\(n)")) }
        }
        let boilerplate = #"(?i)^(why|install|installation|cli|how it works|requirements|roadmap|license|contributing|usage|"#
            + #"getting started|quick ?start|faq|credits|acknowledg|support|documentation|docs|example|changelog|table of contents|"#
            + #"for ai|more demos|build|development|testing|setup|overview|about|authors?|community|sponsors?)"#
        if feats.count < 3 {
            for (title, n, _) in h3s where title.range(of: boilerplate, options: .regularExpression) == nil {
                feats.append((Self.feature(from: title, body: sectionBody[n]), "\(rel):\(n)"))
                if feats.count >= 6 { break }
            }
        }
        if feats.count < 3 {
            for (title, n) in h2s where title.range(of: boilerplate, options: .regularExpression) == nil {
                if feats.contains(where: { $0.0.title == Self.feature(from: title, body: nil).title }) { continue }
                feats.append((Self.feature(from: title, body: sectionBody[n]), "\(rel):\(n)"))
                if feats.count >= 6 { break }
            }
        }
        for (f, src) in feats.prefix(6) {
            props.features.append(f)
            note("features", f.title, src)
        }

        // Code: prefer a block under a usage-ish heading; `.package(url:` blocks are the install snippet.
        let usage = #"(?i)usage|quick ?start|example|getting started|api|in your head|hello"#
        let candidates = swiftBlocks.filter { !$0.code.contains(".package(url:") && !$0.code.contains("PackageDescription") }
        if let block = candidates.first(where: { $0.under.range(of: usage, options: .regularExpression) != nil }) ?? candidates.first {
            props.code = .init(source: Self.cleanSnippet(block.code), language: .swift, title: Self.fileTitle(block.code))
            note("code", props.code?.title ?? "snippet", "\(rel):\(block.line)")
        }
        if let pkg = swiftBlocks.first(where: { $0.code.contains(".package(url:") }) {
            let line = pkg.code.components(separatedBy: "\n").first { $0.contains(".package(url:") }?
                .trimmingCharacters(in: .whitespaces) ?? pkg.code
            props.install = .init(source: line.hasSuffix(",") ? String(line.dropLast()) : line, language: .swift, title: "Package.swift")
            note("install", "Package.swift dependency", "\(rel):\(pkg.line)")
        }

        // Terminal: up to three commands from shell blocks, favouring the ones that show the tool off.
        var cmds: [(String, Int, Int)] = []
        for (rawLine, n) in shellCommands {
            var l = rawLine.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("$ ") { l.removeFirst(2) }
            if l.isEmpty || l.hasPrefix("#") { continue }
            if let hash = l.range(of: "   #") ?? l.range(of: "  #") { l = String(l[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces) }
            for part in l.components(separatedBy: "&&").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
                var score = 0
                if part.hasPrefix("cd ") || part.hasPrefix("export ") || part.hasPrefix("open ") { continue }
                if part.hasPrefix("git clone") { score -= 2 }
                if part.contains("brew install") || part.contains("swift run") || part.contains("mint run") { score += 3 }
                if let name = packageName ?? readmeH1?.0, part.lowercased().contains(name.lowercased()) { score += 2 }
                if part.count > 70 { score -= 2 }
                cmds.append((part, n, score))
            }
        }
        let picked = cmds.enumerated().sorted { ($0.element.2, -$0.offset) > ($1.element.2, -$1.offset) }.prefix(2)
            .sorted { $0.offset < $1.offset }.map(\.element)
        if !picked.isEmpty, picked.contains(where: { $0.2 > 0 }) {
            props.terminal = picked.map { "$ " + $0.0 }
            note("terminal", picked.map(\.0).joined(separator: " · "), "\(rel):\(picked[0].1)")
        }
    }

    static func feature(from text: String, body: String?) -> LaunchProps.Feature {
        // "**Title** — detail", "Title — detail", "Title: detail"
        var title = text, rawDetail = ""
        if let m = firstMatch(#"^\*\*([^*]+)\*\*[:\s—–-]*(.*)$"#, text) {
            title = m
            rawDetail = text.replacingOccurrences(of: #"^\*\*[^*]+\*\*[:\s—–-]*"#, with: "", options: .regularExpression)
        } else {
            for sep in [" — ", " – ", " - ", ": "] where text.contains(sep) {
                let parts = text.components(separatedBy: sep)
                title = parts[0]; rawDetail = parts.dropFirst().joined(separator: sep); break
            }
        }
        title = LaunchText.clean(title).trimmingCharacters(in: CharacterSet(charactersIn: ".: "))
        var detail = LaunchText.clean(rawDetail)
        // A heading suffix that is only a code token ("— `--props`") says less than the section's prose.
        let codeOnly = rawDetail.trimmingCharacters(in: .whitespaces).range(of: #"^`[^`]+`$"#, options: .regularExpression) != nil
        if let body, !body.isEmpty, detail.count < 12 || codeOnly {
            detail = LaunchText.clause(body, limit: 80)
        }
        if title.split(separator: " ").count > 4 { title = LaunchText.truncate(title, 28) }
        detail = LaunchText.capitalized(detail.trimmingCharacters(in: CharacterSet(charactersIn: ":;, ")))
        let byTitle = LaunchText.symbol(for: title)
        return .init(title: title, detail: LaunchText.truncate(detail, 80),
                     symbol: byTitle != "sparkle" ? byTitle : LaunchText.symbol(for: detail))
    }

    static func cleanSnippet(_ code: String) -> String {
        var lines = code.components(separatedBy: "\n").filter { !$0.contains("...") && !$0.contains("…") }
        // Keep one import; the rest are noise on screen.
        var seenImport = false
        lines = lines.filter { l in
            guard l.hasPrefix("import ") else { return true }
            defer { seenImport = true }
            return !seenImport
        }
        return LaunchText.trimCode(lines.joined(separator: "\n"), maxLines: 16, maxColumns: 72).0
    }

    static func fileTitle(_ code: String) -> String? {
        firstMatch(#"(?:struct|class|enum|actor)\s+([A-Z][A-Za-z0-9_]*)"#, code).map { "\($0).swift" }
    }

    // MARK: CHANGELOG

    mutating func scanChangelog() {
        guard let rel = firstFile(named: ["CHANGELOG.md", "CHANGES.md", "HISTORY.md", "RELEASES.md"]), let text = read(rel) else { return }
        let headingRE = #"^##\s+\[?v?(\d+\.\d+(?:\.\d+)?(?:-[\w.]+)?)\]?(?:\s*[-—–]\s*\(?(\d{4}-\d{2}-\d{2})\)?)?"#
        var entry: [(LaunchProps.ChangelogItem.Kind, String)] = []
        var kind: LaunchProps.ChangelogItem.Kind = .added
        var collecting = false
        var current: String?
        let lines = text.components(separatedBy: "\n")
        func flush() { if let c = current { entry.append((kind, c)); current = nil } }
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                if collecting { flush(); break }
                guard let re = try? NSRegularExpression(pattern: headingRE),
                      let m = re.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { continue }
                let ns = line as NSString
                let version = ns.substring(with: m.range(at: 1))
                let date = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : nil
                changelogVersion = (version, date, i + 1, rel)
                collecting = true
                continue
            }
            guard collecting else { continue }
            if line.hasPrefix("### ") {
                flush()
                let k = line.dropFirst(4).lowercased()
                kind = k.contains("add") || k.contains("new") ? .added
                    : k.contains("perf") ? .performance
                    : k.contains("fix") ? .fixed
                    : k.contains("remov") ? .removed
                    : k.contains("secur") ? .security
                    : k.contains("deprec") ? .deprecated : .changed
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") { flush(); current = String(line.dropFirst(2)); continue }
            if !line.isEmpty, current != nil, raw.hasPrefix("  ") { current! += " " + line }
        }
        flush()
        guard let v = changelogVersion else { return }
        let rank: [LaunchProps.ChangelogItem.Kind: Int] = [.added: 0, .performance: 1, .changed: 2, .fixed: 3, .security: 4, .removed: 5, .deprecated: 6]
        let items = entry.enumerated().sorted { (rank[$0.element.0] ?? 9, $0.offset) < (rank[$1.element.0] ?? 9, $1.offset) }
            .prefix(5).map { e -> LaunchProps.ChangelogItem in
                // A bold lead-in is the item's own title; otherwise its first clause.
                let raw = e.element.1
                let title = Self.firstMatch(#"^\*\*([^*]+)\*\*"#, raw).map(LaunchText.clean) ?? LaunchText.clause(raw, limit: 60)
                let clean = LaunchText.capitalized(title.trimmingCharacters(in: CharacterSet(charactersIn: ".:; ")),
                                                   keeping: knownNames)
                return .init(e.element.0, LaunchText.truncate(clean, 60))
            }
        props.changelog = items
        if !items.isEmpty { note("changelog", "\(items.count) items from \(v.0)", "\(rel):\(v.2)") }
    }

    // MARK: LICENSE

    mutating func scanLicense() {
        guard let rel = firstFile(named: ["LICENSE", "LICENSE.md", "LICENSE.txt", "COPYING"]),
              let text = read(rel)?.prefix(800).lowercased() else { return }
        let kinds: [(String, String)] = [("mit license", "MIT"), ("permission is hereby granted, free of charge", "MIT"),
                                         ("apache license", "Apache-2.0"), ("bsd", "BSD"), ("gnu general public", "GPL"),
                                         ("mozilla public", "MPL-2.0"), ("isc license", "ISC"), ("unlicense", "Unlicense")]
        if let k = kinds.first(where: { text.contains($0.0) }) {
            props.license = k.1
            note("license", k.1, rel)
        }
    }

    // MARK: git

    func git(_ args: [String]) -> String? {
        guard let r = try? ProcessRunner.run("/usr/bin/env", ["git", "-C", root.path] + args), r.status == 0 else { return nil }
        let s = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    mutating func scanGit() {
        guard options.git, git(["rev-parse", "--is-inside-work-tree"]) == "true" else {
            report.missing.append("git history (commits, contributors, tags)")
            return
        }
        if let n = git(["rev-list", "--count", "HEAD"]).flatMap(Int.init) {
            props.stats.commits = n
            note("stats.commits", "\(n)", "git rev-list --count HEAD")
            if git(["rev-parse", "--is-shallow-repository"]) == "true" {
                report.warnings.append("shallow clone: commit count is a lower bound")
            }
        }
        if let log = git(["shortlog", "-sne", "HEAD"]) {
            let people = log.components(separatedBy: "\n").filter {
                let l = $0.lowercased()
                return !l.contains("[bot]") && !l.contains("dependabot") && !l.contains("github-actions") && !l.contains("noreply@anthropic")
            }
            props.stats.contributors = people.count
            note("stats.contributors", "\(people.count)", "git shortlog -sne HEAD")
        }
        if let roots = git(["rev-list", "--max-parents=0", "HEAD"])?.components(separatedBy: "\n"),
           let first = roots.compactMap({ git(["log", "-1", "--format=%as", $0]) }).min() {
            props.stats.firstCommit = first
            note("stats.firstCommit", first, "git log")
        }
        if let tags = git(["tag", "--list"])?.components(separatedBy: "\n") {
            let releases = tags.filter { $0.range(of: #"^v?\d+\.\d+"#, options: .regularExpression) != nil }
            props.stats.releases = releases.count
            note("stats.releases", "\(releases.count)", "git tag --list")
        }
        if let tag = git(["describe", "--tags", "--abbrev=0"]) { tagVersion = LaunchText.normalizeVersion(tag) }
        if let remote = git(["remote", "get-url", "origin"]), let (url, repo) = Self.githubURL(remote) {
            props.url = url; props.repo = repo
            note("url", url, "git remote get-url origin")
        }
    }

    /// "git@github.com:o/r.git" / "https://github.com/o/r.git" → ("https://github.com/o/r", "o/r")
    static func githubURL(_ remote: String) -> (String, String)? {
        var s = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix(".git") { s.removeLast(4) }
        if s.hasPrefix("git@") { s = "https://" + s.dropFirst(4).replacingOccurrences(of: ":", with: "/") }
        if s.hasPrefix("ssh://git@") { s = "https://" + s.dropFirst(10) }
        guard let u = URL(string: s), let host = u.host, u.scheme?.hasPrefix("http") == true else { return nil }
        let parts = u.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        return ("https://\(host)/\(parts[0])/\(parts[1])", "\(parts[0])/\(parts[1])")
    }

    // MARK: Swift sources

    mutating func scanCode() {
        var lines = 0, tests = 0, targets = Set<String>()
        var views: [(rel: String, source: String, count: Int)] = []
        for rel in files where rel.hasSuffix(".swift") && !rel.hasSuffix(".generated.swift") && rel != "Package.swift" {
            guard let src = read(rel) else { continue }
            let all = src.components(separatedBy: "\n")
            lines += all.lazy.filter { l in
                let t = l.trimmingCharacters(in: .whitespaces)
                return !t.isEmpty && !t.hasPrefix("//")
            }.count
            if Self.isTestPath(rel) {
                tests += Self.allMatches(#"func\s+(test\w*)\s*\("#, src).count + Self.allMatches(#"(@Test)\b"#, src).count
            } else if rel.hasPrefix("Sources/") {
                let comps = rel.split(separator: "/")
                if comps.count > 2 { targets.insert(String(comps[1])) }
            }
            if !Self.isTestPath(rel), Self.isAppMain(src) { appMains.append(rel) }
            if !Self.isTestPath(rel), src.contains(": View {"), src.contains("var body"), all.count <= 48 {
                views.append((rel, src, all.count))
            }
        }
        if lines > 0 { props.stats.swiftLines = lines; note("stats.swiftLines", "\(lines)", "*.swift (non-blank, non-comment)") }
        if tests > 0 { props.stats.testCount = tests; note("stats.testCount", "\(tests)", "Tests (func test… + @Test)") }
        if !targets.isEmpty { props.stats.targets = targets.count }
        appViews = views
    }
    var appViews: [(rel: String, source: String, count: Int)] = []

    /// An `@main` SwiftUI app entry point: `@main struct X: App`, or an `@main` type with scenes.
    static func isAppMain(_ src: String) -> Bool {
        guard src.contains("@main") else { return false }
        if src.range(of: #"@main\s+(?:public\s+|final\s+)*(?:struct|class)\s+\w+\s*:\s*(?:[\w.]+\s*,\s*)*(?:SwiftUI\.)?App\b"#,
                     options: .regularExpression) != nil { return true }
        return ["WindowGroup", "DocumentGroup", "MenuBarExtra"].contains { src.contains($0) }
    }

    /// The executable product (or bare executable target) whose sources hold an `@main` App,
    /// with that file — when it is the package's primary product: named like the package, or
    /// the package ships no library. An auxiliary App (a viewer beside a library of another
    /// name, like swift-render's Studio) doesn't make a library an app.
    func primaryAppExecutable() -> (product: String, file: String)? {
        guard !appMains.isEmpty else { return nil }
        func target(of file: String) -> String? {
            executableTargetPaths.filter { file.hasPrefix($0.value + "/") }.max { $0.value.count < $1.value.count }?.key
                ?? (file.hasPrefix("Sources/") ? file.split(separator: "/").dropFirst().first.map(String.init) : nil)
        }
        var candidates: [(product: String, file: String)] = []
        for file in appMains {
            guard let t = target(of: file) else { continue }
            let products = executableProductTargets.filter { $0.value.contains(t) }.map(\.key).sorted()
            if !products.isEmpty {
                candidates += products.map { ($0, file) }
            } else if executableTargetPaths[t] != nil || packageProducts.executable.contains(t) {
                candidates.append((t, file))   // SwiftPM makes a product for every executable target
            }
        }
        let pkg = packageName.map(Self.norm)
        return candidates.first { Self.norm($0.product) == pkg } ?? (packageProducts.library.isEmpty ? candidates.first : nil)
    }

    // MARK: Screenshots

    mutating func scanScreenshots() {
        let dirs = ["fastlane/screenshots", "Screenshots", "screenshots", "docs/screenshots", ".github/screenshots"]
        let shots = files.filter { f in
            f.lowercased().hasSuffix(".png") && dirs.contains { f.hasPrefix($0 + "/") } && !f.lowercased().contains("icon")
        }
        for rel in shots.prefix(4) {
            guard let (w, h) = Self.pngSize(root.appendingPathComponent(rel)) else { continue }
            let device: LaunchProps.Device
            let ratio = Double(max(w, h)) / Double(max(1, min(w, h)))
            if h > w && ratio > 1.9 { device = .iPhone }
            else if h > w { device = .iPad }
            else if ratio > 1.45 && ratio < 1.7 { device = .mac }
            else { device = .macWindow }
            props.screenshots.append(.init(path: rel, device: device))
            note("screenshots", rel, "\(w)×\(h) png")
        }
    }

    // MARK: Resolve

    mutating func resolve() {
        // Name: Info.plist display name > Xcode app product > package > README H1 > folder.
        // A library/CLI package's stray Info.plist (e.g. a helper .app it packages) doesn't
        // name the product: there the package name wins.
        let folder = folderName
        let swiftPMApp = xcodeApp == nil && packageProducts.app.isEmpty ? primaryAppExecutable() : nil
        let appLike = xcodeApp != nil || !packageProducts.app.isEmpty || swiftPMApp != nil || packageName == nil
        let plistName = appLike ? self.plistName : nil
        var name = plistName ?? xcodeApp?.displayName ?? xcodeApp?.name ?? packageName ?? readmeH1?.0 ?? folder
        if let h1 = readmeH1?.0, Self.norm(h1) == Self.norm(name), h1.count <= 24 { name = h1 }   // keep the README's styling
        if plistName == nil, xcodeApp == nil, packageName == nil, readmeH1 == nil { report.missing.append("name (used the folder name)") }
        props.name = name
        note("name", name, plistName != nil ? "Info.plist" : xcodeApp != nil ? "project.pbxproj" : packageName != nil ? "Package.swift" : readmeH1 != nil ? "README" : "folder name")

        // Kind
        if xcodeApp != nil || !packageProducts.app.isEmpty || swiftPMApp != nil { props.kind = .app }
        else if !packageProducts.library.isEmpty { props.kind = .library }
        else if !packageProducts.executable.isEmpty { props.kind = .cli }
        else { props.kind = files.contains { $0.hasSuffix(".swift") } ? .library : .app }
        note("kind", props.kind.rawValue, xcodeApp != nil ? "project.pbxproj"
             : swiftPMApp.map { "\($0.file) (@main App, product \($0.product))" }
             ?? (packageName == nil ? "no Package.swift or .xcodeproj" : "Package.swift products"))

        // Platforms + Swift
        props.platforms = xcodeApp?.platforms.isEmpty == false ? xcodeApp!.platforms : packagePlatforms
        props.swiftVersion = xcodeApp?.swift ?? toolsVersion
        if props.platforms.isEmpty { report.missing.append("platforms") }

        // Version precedence: CHANGELOG release > latest tag > MARKETING_VERSION.
        let cl = changelogVersion.map { LaunchText.normalizeVersion($0.0) }
        props.version = cl ?? tagVersion ?? xcodeApp?.version
        props.releaseDate = changelogVersion?.1
        if let cl, let tag = tagVersion, cl != tag {
            report.conflicts.append("version: \(changelogVersion!.3) says \(cl), latest tag is v\(tag) — using \(cl)")
        }
        if let v = props.version { note("version", v, cl != nil ? "\(changelogVersion!.3):\(changelogVersion!.2)" : tagVersion != nil ? "git describe" : "MARKETING_VERSION") }

        // Tagline fallback
        if props.tagline.isEmpty {
            props.tagline = props.kind == .app ? "Meet \(name)." : "\(name), in Swift."
            report.missing.append("tagline (README has no lead paragraph)")
        }

        // Accent: AccentColor > README release badge > default. The CLI may refine from the icon.
        if props.accent.isEmpty {
            if let (hex, line) = accentFromBadge {
                props.accent = hex
                note("accent", hex, "README badge color (line \(line))")
            } else {
                props.accent = props.kind == .app ? "#0A84FF" : "#F05138"
                report.missing.append("accent (no AccentColor; using \(props.accent))")
            }
        }

        // Code for apps: a short SwiftUI view from the sources.
        if props.code == nil, let v = appViews.sorted(by: { ($0.rel.hasSuffix("ContentView.swift") ? 0 : 1, $0.count) < ($1.rel.hasSuffix("ContentView.swift") ? 0 : 1, $1.count) }).first {
            props.code = .init(source: Self.cleanSnippet(v.source), language: .swift, title: (v.rel as NSString).lastPathComponent)
            note("code", v.rel, v.rel)
        }
        if props.code != nil, props.code?.caption == nil {
            props.code?.caption = props.kind == .app ? "Built with SwiftUI." : "Just a few lines of Swift."
        }
        if props.code == nil { report.missing.append("code (no ```swift block in the README)") }

        // Highlights from real numbers only, best first; small numbers are dropped.
        let s = props.stats
        var cands: [(Int, LaunchProps.Stat)] = []
        if let v = s.stars, v >= 100 { cands.append((6, .init(value: Double(v), format: .compact, label: "GitHub stars", source: "gh"))) }
        if let v = s.testCount, v >= 50 { cands.append((5, .init(value: Double(v), format: .integer, label: "tests", source: report.source(of: "stats.testCount")))) }
        if let v = s.commits, v >= 200 { cands.append((4, .init(value: Double(v), format: v >= 10_000 ? .compact : .integer, label: "commits", source: report.source(of: "stats.commits")))) }
        if let v = s.contributors, v >= 5 { cands.append((3, .init(value: Double(v), format: .integer, label: "contributors", source: report.source(of: "stats.contributors")))) }
        if let v = s.releases, v >= 5 { cands.append((2, .init(value: Double(v), format: .integer, label: "releases", source: report.source(of: "stats.releases")))) }
        if let v = s.swiftLines, v >= 2_000 {
            cands.append((1, .init(value: Double(v), format: .compact, label: "lines of Swift", source: report.source(of: "stats.swiftLines"))))
        }
        props.highlights = cands.sorted { $0.0 > $1.0 }.prefix(3).map(\.1)

        // Facts for the platforms shot.
        if let deps = packageDependencies { props.stats.dependencies = deps }
        if props.kind != .app, packageDependencies == 0 { props.facts.append("Zero dependencies") }
        if let l = props.license, props.kind != .app { props.facts.append("\(l) licensed") }

        // Call to action
        switch props.kind {
        case .app:
            let mac = props.platforms.contains { $0.name == .macOS }
            let ios = props.platforms.contains { $0.name == .iOS || $0.name == .visionOS }
            props.cta = .init(mac && !ios ? .downloadForMac : ios ? .appStore : .availableNow)
        case .cli:
            if let brew = props.terminal?.first(where: { $0.contains("brew install") }) {
                props.cta = .init(.brew, value: brew.components(separatedBy: "brew install").last?.trimmingCharacters(in: .whitespaces))
            } else if let repo = props.repo { props.cta = .init(.github, value: repo) }
        case .library, .framework, .plugin:
            if let url = props.url { props.cta = .init(.swiftPackage, value: url, from: props.version ?? "1.0.0") }
            else { props.cta = .init(.availableNow) }
        }

        // Music mood by kind.
        props.music = .init(bpm: 100, key: 0, mood: props.kind == .app ? .bright : .bright)
        if props.features.count < 3 { report.missing.append("features (found \(props.features.count); the feature shot needs 3)") }
    }

    static func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    static func firstMatch(_ pattern: String, _ s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)),
              m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound else { return nil }
        return (s as NSString).substring(with: m.range(at: 1))
    }

    /// Groups 1 and 2 of every match.
    static func matchPairs(_ pattern: String, _ s: String) -> [(String, String)] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap {
            guard $0.numberOfRanges > 2, $0.range(at: 1).location != NSNotFound else { return nil }
            let second = $0.range(at: 2).location != NSNotFound ? ns.substring(with: $0.range(at: 2)) : ""
            return (ns.substring(with: $0.range(at: 1)), second)
        }
    }

    static func trimSlashes(_ p: String) -> String {
        var s = p
        if s.hasPrefix("./") { s.removeFirst(2) }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func allMatches(_ pattern: String, _ s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.numberOfRanges > 1 && $0.range(at: 1).location != NSNotFound ? ns.substring(with: $0.range(at: 1)) : nil
        }
    }
}

private final class ScanOutput: @unchecked Sendable { var data = Data() }
