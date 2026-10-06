// MARK: - Names a new scene can't take
//
// A scene is a `public struct <Name>` in a module that imports SwiftUI and SwiftRender, and
// the generated registry names it next to SwiftRenderTool's types. A scene called `Score`,
// `Timeline` or `Text` shadows the type the rest of the package means and breaks its build
// with errors far from the cause, so new_scene and write_scene refuse these names.
// MCPCreateTests checks that every public type of Sources/SwiftRender is listed.

enum ReservedNames {
    static let all: Set<String> = swiftRender.union(tool).union(modules).union(swiftUI).union(foundation).union(stdlib)

    /// `public` types of the SwiftRender module (what `import SwiftRender` brings in).
    static let swiftRender: Set<String> = [
        "AppIconHero", "AppleLaunch", "AppleLaunchFilm", "AppleLaunchShot", "ArpPattern", "AspectPreset",
        "AssetPaths", "AudioAnalyzer", "AudioAnalyzerError", "AudioReactiveScene", "AudioTrack", "CaptionCue",
        "CaptionTrack", "CaptionView", "CaptionWord", "ChangelogList", "Chord", "Clip", "CodePalette", "CodeReveal",
        "CubicBezier", "DeviceFrame", "Dither", "Ease", "EndCard", "Eyebrow", "FeatureCard", "FeatureList",
        "FeatureTriad", "GlassPanel", "ImageClip", "Instrument", "KeynoteTitle", "Knob", "KnobStore", "LaunchAssets",
        "LaunchIcon", "LaunchLayout", "LaunchScore", "LaunchTheme", "MP4Assembler", "MediaLibrary", "Mixer",
        "Motion", "NoProps", "NoiseLCG", "Note", "PixelCanvas", "PixelFont", "PixelGrid", "PlatformBadges",
        "PoseOverlay", "PostFX", "PropsAudioScene", "PropsScene", "Recorder", "RenderContext", "RenderFrame",
        "RenderScene", "SampleBuffer", "SampleError", "SampleLibrary", "SampleRef", "Scale", "SceneProbe",
        "SceneStructure", "Score", "ScoreBuilder", "ScoreEvent", "ScoreSynth", "ScreenshotView", "Speech",
        "SpeechError", "SpeechSpec", "Spring", "Stage", "StatCounter", "StatRow", "Stylize", "SwiftHighlighter",
        "TTSEngine", "TerminalCard", "Timeline", "TimelineBuilder", "Transition", "VideoClip", "VisionFrame",
        "VisionPoint", "VisionTrack", "Voice", "WAV",
    ]

    /// SwiftRenderTool types the generated registry and main.swift use.
    static let tool: Set<String> = ["SceneRunner", "SwiftRenderCommand", "SceneRegistry"]

    /// Module names (a type named like its module breaks qualified lookups).
    static let modules: Set<String> = [
        "SwiftRender", "SwiftRenderKit", "SwiftRenderTool", "SwiftRenderScenes", "SwiftRenderCLI", "SwiftRenderStudio",
        "SwiftRenderMCP", "LaunchScenes", "LaunchKit", "Launch", "SwiftUI", "Foundation", "AppKit", "AVFoundation",
        "CoreGraphics", "CoreImage", "Metal", "Swift",
    ]

    /// SwiftUI types a scene body is likely to use.
    static let swiftUI: Set<String> = [
        "View", "Text", "Image", "Color", "Font", "Shape", "Path", "Circle", "Rectangle", "RoundedRectangle",
        "Capsule", "Ellipse", "Group", "Spacer", "Divider", "ZStack", "VStack", "HStack", "LazyVStack", "LazyHStack",
        "Grid", "GridRow", "GeometryReader", "GeometryProxy", "Canvas", "GraphicsContext", "Animation", "Angle",
        "Gradient", "LinearGradient", "RadialGradient", "AngularGradient", "EllipticalGradient", "ForEach",
        "EmptyView", "AnyView", "AnyShape", "TimelineView", "Label", "Button", "List", "Section", "Toggle", "Slider",
        "Layout", "Material", "Edge", "Alignment", "Axis", "UnitPoint", "Shadow", "Shader", "ShaderLibrary",
        "BlendMode", "ContentMode", "ViewBuilder", "ViewModifier", "Environment", "State", "Binding", "Scene",
        "App", "Window", "WindowGroup", "ScrollView", "Mask", "Namespace", "Anchor", "CGPoint", "CGSize", "CGRect",
        "CGFloat", "Transaction", "Visibility", "Style", "ShapeStyle", "ForegroundStyle", "StrokeStyle",
        "AttributedString", "LocalizedStringKey", "Model3D",
    ]

    static let foundation: Set<String> = [
        "Date", "Data", "URL", "UUID", "Bundle", "Timer", "Locale", "Calendar", "TimeInterval", "NSObject",
        "NSString", "Process", "FileManager", "JSONDecoder", "JSONEncoder", "Measurement", "DateFormatter",
        "NumberFormatter", "Progress", "Notification", "Thread", "OperationQueue", "DispatchQueue",
    ]

    static let stdlib: Set<String> = [
        "String", "Int", "Double", "Float", "Bool", "Array", "Dictionary", "Set", "Optional", "Character", "Error",
        "Result", "Task", "Range", "ClosedRange", "Sequence", "Collection", "Equatable", "Hashable", "Codable",
        "Decodable", "Encodable", "Identifiable", "Comparable", "Never", "Void", "Any", "AnyObject", "Self", "Type",
        "Protocol", "Substring", "Int32", "Int64", "UInt", "UInt8", "UInt32", "UInt64", "Float32", "Float64",
        "SIMD2", "SIMD3", "SIMD4", "MainActor", "Sendable", "Actor",
    ]
}
