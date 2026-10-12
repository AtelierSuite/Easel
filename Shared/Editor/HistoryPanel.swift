import SwiftUI

/// Names a step for the History panel from what it changed.
enum HistoryNaming {
    static func name(from old: Composition, to new: Composition, tool: Tool?) -> String {
        if old.size != new.size { return String(localized: "History.Canvas") }
        let oldIDs = old.layers.map(\.id), newIDs = new.layers.map(\.id)
        if newIDs.count > oldIDs.count { return String(localized: "History.AddLayer") }
        if newIDs.count < oldIDs.count { return String(localized: "History.DeleteLayer") }
        if oldIDs != newIDs { return String(localized: "History.Reorder") }
        if old.layers == new.layers {
            if old.guides != new.guides { return String(localized: "History.Guides") }
            if old.swatches != new.swatches { return String(localized: "History.Swatches") }
            if old.patterns != new.patterns { return String(localized: "History.Patterns") }
            if old.layerComps != new.layerComps { return String(localized: "History.Comps") }
            if old.artboards != new.artboards { return String(localized: "History.Artboards") }
            return String(localized: "History.Groups")
        }
        let changed = zip(old.layers, new.layers).filter { $0 != $1 }
        guard changed.count == 1, let (before, after) = changed.first else {
            return String(localized: "History.EditLayers")
        }
        if before.image != after.image || before.mask != after.mask {
            // The tool in hand made it, if it is one that changes pixels.
            if let tool, tool.paintsPixels || tool == .transform {
                return String(localized: String.LocalizationValue(tool.labelKey))
            }
            return String(localized: "History.EditPixels")
        }
        switch EditScope(from: old, to: new).kind {
        case .opacity: return String(localized: "History.Opacity")
        case .blendMode: return String(localized: "History.BlendMode")
        case .transform: return String(localized: "History.Move")
        case .text: return String(localized: "History.Text")
        case .vector: return String(localized: "History.Shape")
        case .filters: return String(localized: "History.Filters")
        case .effects: return String(localized: "History.Effects")
        case .name: return String(localized: "History.Rename")
        case .visibility: return String(localized: "History.Visibility")
        case .other: return String(localized: "History.EditLayers")
        }
    }
}

/// The steps taken, newest last: tapping one goes back or forward to it.
struct HistoryPanel: View {
    let history: CompositionHistory
    @Bindable var state: EditorState

    var body: some View {
        List {
            Section {
                ForEach(Array(history.steps.enumerated()), id: \.offset) { index, name in
                    Button {
                        history.jump(to: index)
                    } label: {
                        HStack {
                            Text(name)
                                .foregroundStyle(index > history.position ? .secondary : .primary)
                            Spacer()
                            if index == history.position {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    // Plain text, so steps that can be redone show as dimmed.
                    .tint(.primary)
                    .accessibilityAddTraits(index == history.position ? .isSelected : [])
                }
            } footer: {
                Text("History.Footer")
            }
            Section {
                Toggle("History.Compare", systemImage: "rectangle.lefthalf.inset.filled", isOn: $state.isComparing)
                    .disabled(history.original == nil)
                    .accessibilityIdentifier("compareOriginal")
            }
        }
        .onDisappear { state.isComparing = false }
    }
}
