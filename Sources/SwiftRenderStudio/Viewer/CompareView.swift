import SwiftUI
import SwiftRenderKit

// MARK: - A/B compare   // S6
//
// To implement (studio-ux §1.3): BEFORE = the comment's `.before` attachment,
// AFTER = latest `.after` or "live" (current build at the same t, lossless bgra8);
// split (drag wipe), toggle (\), side-by-side, difference (CIDifferenceBlendMode ×4
// exposure); Δ% from a 64×36 luminance diff; Accept / Reopen.

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

struct CompareView: View {
    @Bindable var model: ProjectModel
    var mode: CompareMode
    var canvas: CGRect

    var body: some View {
        ZStack(alignment: .bottom) {
            // S6: before/after layers and wipe handle.
            Rectangle()
                .fill(.clear)
                .overlay(alignment: .top) {
                    HStack {
                        StudioBadge(text: "BEFORE", color: .white)
                        Spacer()
                        StudioBadge(text: "AFTER · LIVE", color: StudioStyle.accent)
                    }
                    .padding(8)
                }
                .frame(width: canvas.width, height: canvas.height)
                .position(x: canvas.midX, y: canvas.midY)
            HStack(spacing: 10) {
                Picker("Mode", selection: Binding(get: { mode }, set: { model.ui.compare = $0 })) {
                    ForEach(CompareMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
                Text("Select a resolved comment to compare").font(.caption).foregroundStyle(.secondary)
                Button("Done") { model.ui.compare = nil }
            }
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 10)
        }
    }
}
