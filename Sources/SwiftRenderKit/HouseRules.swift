import Foundation

// MARK: - House rules for agents
//
// The rules every agent working on swift-render scenes gets, wherever it comes in:
// the MCP server's `instructions`, Studio's appended system prompt, the director
// agent and the review skill (those two are Markdown files that say the same).

/// The rules every agent working on swift-render scenes is given.
public enum HouseRules {
    /// Visual grammar of launch films (LaunchKit / AppleLaunch / a `Launch/` package).
    /// Scoped on purpose: the demo films use shake and flash deliberately.
    public static let launchFilm = """
    Launch films (LaunchKit, AppleLaunch, scenes in a Launch/ package): no camera shake, no flash or \
    white frames (never .transition(.flash())), no whoosh/riser/crash/boom in the score. Hard cuts on \
    downbeats, a single focus-pull dissolve into the end card, slow pushes for energy.
    """

    /// The short list, one rule per line.
    public static let text = """
    House rules: scenes are pure functions of t (no @State, Timer, Date(), unseeded randomness, onAppear \
    or withAnimation). Audio: no whoosh, riser or swish sounds — use tick, rim, thump, blip or swell hits, \
    or harmony. \(launchFilm) Stay on the note; never hand-edit .swift-render/reviews/*.json.
    """
}
