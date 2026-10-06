import SwiftUI

// MARK: - Props tab   // S7
//
// Shell: the props JSON in effect, editable as text, Apply → `ProjectModel.setProps`.
// S7 adds the form (bools, numbers, colors, media pickers, arrays, objects), decode
// errors mapped to fields by coding path, Load/Save as, and variant renders.

struct PropsTab: View {
    @Bindable var model: ProjectModel
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        if model.info?.propsJSON == nil && model.propsJSON == nil {
            StudioEmptyState(title: "No Props", symbol: "curlybraces", message: "This scene isn't a PropsScene.")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $text)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                if let error { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(StudioStyle.warn) }
                HStack {
                    Spacer()
                    Button("Apply") {
                        let json = text
                        Task {
                            do { try await model.setProps(json); error = nil } catch { self.error = "\(error)" }
                        }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(10)
            .onAppear { text = model.propsJSON ?? model.info?.propsJSON ?? "" }
            .onChange(of: model.info?.name) { _, _ in text = model.propsJSON ?? model.info?.propsJSON ?? "" }
        }
    }
}
