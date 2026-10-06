import SwiftUI
import SwiftRenderKit

// MARK: - Knobs tab   // S7
//
// Shell: read-only list of `SceneInfo.knobs` with current values. S7 adds sliders /
// toggles / fields / ColorPicker driving `ProjectModel.setKnobs(_:dragging:)`
// (reprobe off while dragging, ~30 Hz), ↺ reset, ↗ source, ● differs-from-file,
// Save/Revert (`saveKnobs`), Bake into source, and not-yet-reached keys.

struct KnobsTab: View {
    @Bindable var model: ProjectModel

    var body: some View {
        let knobs = model.info?.knobs ?? []
        if knobs.isEmpty {
            ContentUnavailableView("No knobs", systemImage: "slider.horizontal.3",
                                   description: Text("Declare tunables in the scene with Knob.double(\"key\", 0.4, 0…2)."))
        } else {
            List(knobs, id: \.key) { k in
                HStack {
                    Image(systemName: icon(k.kind)).foregroundStyle(.secondary).frame(width: 16)
                    Text(k.key).font(.system(size: 12, design: .monospaced))
                    Spacer()
                    Text(display(k.value, kind: k.kind)).font(StudioStyle.mono).foregroundStyle(.secondary)
                    if let src = k.source {
                        Button { SourceOpener.open(src) } label: { Image(systemName: "arrow.up.forward.square") }
                            .buttonStyle(.borderless)
                            .help("Open source")
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private func icon(_ k: KnobInfo.Kind) -> String {
        switch k {
        case .double: return "dial.medium"
        case .bool: return "switch.2"
        case .text: return "textformat"
        case .color: return "paintpalette"
        }
    }

    private func display(_ v: KnobValue, kind: KnobInfo.Kind) -> String {
        switch v {
        case .number(let d): return String(format: "%.2f", d)
        case .bool(let b): return b ? "on" : "off"
        case .string(let s): return s
        }
    }
}
