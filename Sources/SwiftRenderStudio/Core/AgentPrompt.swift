import Foundation
import SwiftRenderKit

// MARK: - Agent prompt   // S8
//
// To implement (studio-ux §4.8): project, scene, source path, canvas; each comment as
// `id @ timecode (frame), region in scene points, clip source file:line, body,
// before-frame path`; the claim → edit → build (--scratch-path .build/studio) →
// after-frame → reply → resolve loop; house rules (pure body(at:), no whoosh/riser,
// don't touch other comments, ask when unclear).

enum AgentPrompt {
    static func make(_ r: AgentRequest, info: SceneInfo?, comments: [ReviewComment]) -> (prompt: String, system: String) {
        let picked = comments.filter { r.commentIDs.contains($0.id) }
        let lines = picked.map { "- \($0.id) @ \($0.timecode): \($0.body)" }.joined(separator: "\n")
        let prompt = "Address these review comments on scene \(r.scene):\n\(lines)"
        let system = "Scenes are pure functions of t. Use tick/rim/thump/blip/swell, never whoosh or riser."
        return (prompt, system)
    }
}
