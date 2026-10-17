import Paintbrush
import PhotosUI
import SwiftUI

/// The layer stack, top layer first, with the active layer's opacity and
/// blend mode beneath it and ways to add, copy and combine layers.
struct LayersPanel: View {
    let composition: Composition
    @Bindable var state: EditorState

    @State private var renaming: Layer?
    @State private var newName = ""

    var body: some View {
        List {
            Section {
                ForEach(composition.layerListRows) { row in
                    switch row {
                    case .group(let group, let depth):
                        GroupRow(group: group, state: state)
                            .padding(.leading, CGFloat(depth) * 16)
                            .moveDisabled(true)
                    case .layer(let layer, let depth):
                        layerRow(layer)
                            .padding(.leading, CGFloat(depth) * 16)
                    }
                }
                .onMove { source, destination in
                    state.moveLayers(fromDisplayed: source, toDisplayed: destination)
                }
            }

            if let groupID = state.activeGroupID, let group = composition.group(groupID) {
                GroupSection(group: group, state: state)
            } else if let layer = state.activeLayer {
                layerSections(layer)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) {
            LayerActionsBar(state: state)
                .padding(.bottom, 8)
        }
        .modifier(LayersPanelChrome(state: state))
        .alert("Layers.Rename.Title", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }
        )) {
            TextField("Layers.Rename.Placeholder", text: $newName)
            Button("Common.Cancel", role: .cancel) { renaming = nil }
            Button("Layers.Rename.Confirm") {
                if let renaming { state.rename(renaming.id, to: newName) }
                renaming = nil
            }
        }
    }

    private func layerRow(_ layer: Layer) -> some View {
                    LayerRow(
                        layer: layer, isActive: layer.id == state.activeLayerID,
                        isEditingMask: layer.id == state.activeLayerID && state.isEditingMask,
                        toggleVisibility: { state.setVisibility(!layer.isVisible, of: layer.id) },
                        editMask: {
                            state.activeLayerID = layer.id
                            state.isEditingMask = true
                        }
                    )
                    .contentShape(.rect)
                    .onTapGesture {
                        state.activeLayerID = layer.id
                        state.isEditingMask = false
                    }
                    .listRowBackground(
                        layer.id == state.activeLayerID && state.activeGroupID == nil ? Color.accentColor.opacity(0.18) : nil
                    )
                    .contextMenu { menuItems(for: layer) }
                    .swipeActions(edge: .trailing) {
                        Button("Layers.Delete", systemImage: "trash", role: .destructive) {
                            state.deleteLayer(layer.id)
                        }
                        .disabled(!state.canDelete(layer.id))
                        Button("Layers.Duplicate", systemImage: "plus.square.on.square") {
                            state.duplicateLayer(layer.id)
                        }
                        .tint(.indigo)
                    }
                    .accessibilityIdentifier("layer.\(layer.name)")
                    .accessibilityAddTraits(layer.id == state.activeLayerID ? .isSelected : [])
    }

    @ViewBuilder
    private func layerSections(_ layer: Layer) -> some View {
            if let adjustment = layer.adjustment {
                Section("Layers.Section.Adjustment") {
                    FilterRow(filter: adjustment, state: state, isAdjustment: true)
                }
            }
            Section("Layers.Section.Appearance") {
                LabeledSlider(
                    label: "Layers.Opacity",
                    value: Binding(
                        get: { layer.opacity },
                        set: { value in state.updateActiveLayer { $0.opacity = value } }
                    ),
                    valueText: "\(Int((layer.opacity * 100).rounded()))%"
                )
                .accessibilityIdentifier("layerOpacity")
                if !layer.isAdjustment {
                    LabeledSlider(
                        label: "Layers.Fill",
                        value: Binding(
                            get: { layer.fillOpacity },
                            set: { value in state.updateActiveLayer { $0.fillOpacity = value } }
                        ),
                        valueText: "\(Int((layer.fillOpacity * 100).rounded()))%"
                    )
                    .accessibilityIdentifier("layerFill")
                }
                Picker("Layers.BlendMode", selection: Binding(
                    get: { layer.blendMode },
                    set: { value in state.updateActiveLayer { $0.blendMode = value } }
                )) {
                    ForEach(Array(LayerBlendMode.groups.enumerated()), id: \.offset) { _, group in
                        Section {
                            ForEach(group) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                    }
                }
                .accessibilityIdentifier("blendMode")
                Toggle("Layers.Lock", isOn: Binding(
                    get: { layer.isLocked },
                    set: { state.setLocked($0, of: layer.id) }
                ))
                Toggle("Layers.ClipToBelow", isOn: Binding(
                    get: { layer.isClipped },
                    set: { state.setClipped($0, of: layer.id) }
                ))
                .disabled(!layer.isClipped && !composition.canClip(layer.id))
                .accessibilityIdentifier("clipToBelow")
                if !layer.isAdjustment {
                Button {
                    open(.filters)
                } label: {
                    LabeledContent {
                        Text(verbatim: layer.activeFilters.isEmpty ? "" : "\(layer.activeFilters.count)")
                    } label: {
                        Label("Panel.Filters.Title", systemImage: EditorPanel.filters.symbolName)
                    }
                }
                .accessibilityIdentifier("layerFilters")
                Button {
                    open(.effects)
                } label: {
                    LabeledContent {
                        Text(verbatim: layer.activeEffects.isEmpty ? "" : "\(layer.activeEffects.count)")
                    } label: {
                        Label("Panel.Effects.Title", systemImage: EditorPanel.effects.symbolName)
                    }
                }
                .accessibilityIdentifier("layerEffects")
                }
            }
            MaskSection(layer: layer, state: state)
    }

    @Environment(\.panelPlacement) private var placement

    /// On iPhone, the layers sheet goes down before the next one comes up:
    /// swapped in place, the new sheet would keep the full height.
    private func open(_ panel: EditorPanel) {
        guard placement == .sheet else {
            state.presentedPanel = panel
            return
        }
        state.presentedPanel = nil
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            state.presentedPanel = panel
        }
    }

    @ViewBuilder
    private func menuItems(for layer: Layer) -> some View {
        Section {
            Button("Layers.Rename", systemImage: "pencil") {
                newName = layer.name
                renaming = layer
            }
            Button("Layers.Duplicate", systemImage: "plus.square.on.square") { state.duplicateLayer(layer.id) }
            Button(layer.isLocked ? "Layers.Unlock" : "Layers.Lock", systemImage: layer.isLocked ? "lock.open" : "lock") {
                state.setLocked(!layer.isLocked, of: layer.id)
            }
        }
        Section {
            Button("Layers.MoveUp", systemImage: "arrow.up") { state.moveLayer(layer.id, by: 1) }
                .disabled(composition.layers.last?.id == layer.id)
            Button("Layers.MoveDown", systemImage: "arrow.down") { state.moveLayer(layer.id, by: -1) }
                .disabled(composition.layers.first?.id == layer.id)
            Button("Layers.MergeDown", systemImage: "square.2.layers.3d.bottom.filled") { state.mergeDown(layer.id) }
                .disabled(!composition.canMergeDown(layer.id))
            if layer.isClipped {
                Button("Layers.ReleaseClipping", systemImage: "arrow.turn.left.up") {
                    state.setClipped(false, of: layer.id)
                }
            } else {
                Button("Layers.ClipToBelow", systemImage: "arrow.turn.left.down") { state.setClipped(true, of: layer.id) }
                    .disabled(!composition.canClip(layer.id))
            }
            if layer.isText || layer.isVector {
                Button("Layers.Rasterize", systemImage: "square.grid.3x3.square") { state.rasterizeLayer(layer.id) }
            }
            if layer.isSmartObject {
                Button("SmartObject.Edit", systemImage: "square.and.pencil") {
                    state.activeLayerID = layer.id
                    state.editSmartObjectContents()
                }
                Button("Layers.Rasterize", systemImage: "square.grid.3x3.square") { state.rasterizeLayer(layer.id) }
            } else if !layer.isAdjustment {
                Button("SmartObject.Convert", systemImage: "shippingbox") {
                    state.activeLayerID = layer.id
                    state.convertToSmartObject()
                }
            }
            if !layer.isVector && !layer.isAdjustment {
                Menu("Trace.Title", systemImage: "scribble.variable") {
                    ForEach(ImageTracer.colorCounts, id: \.self) { colors in
                        Button(colors == 2 ? String(localized: "Trace.BlackAndWhite") : String(localized: "Trace.Colors \(colors)")) {
                            state.activeLayerID = layer.id
                            state.traceImage(colors: colors)
                        }
                    }
                }
            }
            if layer.hasActiveFilters {
                Button("LayerFilters.ApplyAll", systemImage: "square.and.arrow.down.on.square") {
                    state.applyFilters(of: layer.id)
                }
            }
        }
        Section {
            Button("Groups.Group", systemImage: "folder.badge.plus") {
                state.activeLayerID = layer.id
                state.groupActiveLayer()
            }
            if !composition.groups.isEmpty {
                Menu("Groups.MoveTo", systemImage: "folder") {
                    Button("Groups.NoGroup") { state.moveLayer(layer.id, toGroup: nil) }
                        .disabled(layer.groupID == nil)
                    ForEach(composition.groups) { group in
                        Button(group.name) { state.moveLayer(layer.id, toGroup: group.id) }
                            .disabled(layer.groupID == group.id)
                    }
                }
            }
        }
        Section {
            Button("Layers.Delete", systemImage: "trash", role: .destructive) { state.deleteLayer(layer.id) }
                .disabled(!state.canDelete(layer.id))
        }
    }
}

/// One layer in the list: a thumbnail on a checkerboard, its name, and
/// what sets it apart — hidden, locked, a blend mode, less than full opacity.
private struct LayerRow: View {
    let layer: Layer
    let isActive: Bool
    let isEditingMask: Bool
    let toggleVisibility: () -> Void
    let editMask: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if layer.isClipped {
                // Pointing down at the layer it clips to, as in Photoshop.
                Image(systemName: "arrow.turn.left.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                    .accessibilityLabel("Layers.Clipped")
            }
            ZStack {
                if let adjustment = layer.adjustment {
                    Color.secondary.opacity(0.12)
                    Image(systemName: adjustment.kind.symbolName)
                        .font(.system(size: 20))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Checkerboard(squareSize: 5)
                    Image(decorative: layer.image.thumbnail(), scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(.rect(cornerRadius: 6))
            .overlay {
                // Outlined is what painting goes into: the layer or its mask.
                let target = isActive && !isEditingMask && !layer.isAdjustment
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(target ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: target ? 2 : 1)
            }
            if let mask = layer.mask {
                Button(action: editMask) {
                    Image(decorative: mask.preview(), scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 44, height: 44)
                        .background(Color.black)
                        .clipShape(.rect(cornerRadius: 6))
                        .opacity(mask.isEnabled ? 1 : 0.4)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(
                                    maskIsTarget ? Color.accentColor : Color.secondary.opacity(0.3),
                                    lineWidth: maskIsTarget ? 2 : 1
                                )
                        }
                        .overlay {
                            if !mask.isEnabled {
                                Image(systemName: "xmark")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(.red)
                            }
                        }
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Mask.Edit")
                .accessibilityIdentifier("mask.\(layer.name)")
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if layer.isText {
                        Image(systemName: "textformat")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if layer.isVector {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Layers.Vector")
                    } else if layer.isSmartObject {
                        Image(systemName: "shippingbox")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("SmartObject.Badge")
                    }
                    Text(layer.name)
                        .lineLimit(1)
                }
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .opacity(layer.isVisible ? 1 : 0.5)

            Spacer(minLength: 0)

            if layer.hasActiveFilters {
                Image(systemName: EditorPanel.filters.symbolName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Panel.Filters.Title")
            }
            if layer.isLocked {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Layers.Locked")
            }
            Button(action: toggleVisibility) {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(layer.isVisible ? Color.primary : Color.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(layer.isVisible ? "Layers.Hide" : "Layers.Show")
            .accessibilityIdentifier("visibility.\(layer.name)")
        }
    }

    private var maskIsTarget: Bool { isEditingMask || (isActive && layer.isAdjustment) }

    private var detail: String? {
        var parts: [String] = []
        if layer.blendMode != .normal { parts.append(layer.blendMode.label) }
        if layer.opacity < 0.995 { parts.append("\(Int((layer.opacity * 100).rounded()))%") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Adding, copying and combining layers.
struct LayerActionsBar: View {
    @Bindable var state: EditorState
    @Environment(\.panelPlacement) fileprivate var placement
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isPickingPhotos = false

    var body: some View {
        let active = state.activeLayer
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                GlassGroup {
                    GlassMenuButton(symbol: "plus", label: "Layers.Add") {
                        Button("Layers.NewLayer", systemImage: "square.badge.plus") { state.addEmptyLayer() }
                        Menu("Layers.NewAdjustment", systemImage: "circle.lefthalf.filled") {
                            ForEach(LayerFilter.Kind.allCases.filter(\.isPerPixel)) { kind in
                                Button {
                                    state.addAdjustmentLayer(kind)
                                } label: {
                                    Label {
                                        Text(verbatim: kind.label)
                                    } icon: {
                                        Image(systemName: kind.symbolName)
                                    }
                                }
                                .accessibilityIdentifier("addAdjustment.\(kind.rawValue)")
                            }
                        }
                        // The picker is presented from outside the menu,
                        // which is gone by the time a picker inside it would show.
                        Button("Layers.ImportPhotos", systemImage: "photo.on.rectangle") { isPickingPhotos = true }
                        Button("Layers.ImportFiles", systemImage: "folder") { state.isImportingFiles = true }
                        Button("Layers.Paste", systemImage: "doc.on.clipboard") {
                            if let item = ImageImport.pasteboardImage() {
                                state.addImageLayers([item])
                            } else {
                                state.errorMessage = String(localized: "Error.NothingToPaste")
                            }
                        }
                    }
                    .accessibilityIdentifier("addLayer")
                    GlassIconButton(symbol: "plus.square.on.square", label: "Layers.Duplicate") {
                        if let active { state.duplicateLayer(active.id) }
                    }
                    .disabled(active == nil)
                    GlassIconButton(symbol: "square.2.layers.3d.bottom.filled", label: "Layers.MergeDown") {
                        if let active { state.mergeDown(active.id) }
                    }
                    .disabled(active.map { !state.composition.canMergeDown($0.id) } ?? true)
                    GlassIconButton(symbol: "trash", label: "Layers.Delete") {
                        if let active { state.deleteLayer(active.id) }
                    }
                    .disabled(active.map { !state.canDelete($0.id) } ?? true)
                    .accessibilityIdentifier("deleteLayer")
                }
                GlassGroup {
                    GlassMenuButton(symbol: "ellipsis", label: "Layers.More") {
                        Button("Layers.Copy", systemImage: "doc.on.doc") {
                            if let image = state.copiedImage() { ImageImport.copyToPasteboard(image) }
                        }
                        .disabled(active == nil)
                        Button("Groups.Group", systemImage: "folder.badge.plus") { state.groupActiveLayer() }
                            .disabled(active == nil)
                        Button("Layers.Flatten", systemImage: "square.3.layers.3d.down.right") { state.flatten() }
                            .disabled(state.composition.layers.count < 2)
                        Button("Panel.Comps.Title", systemImage: EditorPanel.comps.symbolName) { openComps() }
                            .accessibilityIdentifier("layerComps")
                    }
                }
            }
        }
        .photosPicker(isPresented: $isPickingPhotos, selection: $photoItems, matching: .images, photoLibrary: .shared())
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task {
                let result = await ImageImport.load(items)
                state.addImageLayers(result.images)
                if result.failed { state.errorMessage = String(localized: "Error.ImportFailed") }
            }
        }
    }
}

extension LayerActionsBar {
    /// On iPhone, the layers sheet goes down before the comps one comes up.
    private func openComps() {
        guard placement == .sheet else {
            state.presentedPanel = .comps
            return
        }
        state.presentedPanel = nil
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            state.presentedPanel = .comps
        }
    }
}

/// On iPhone the layers sheet closes with Done; beside the canvas on iPad
/// the inspector is simply there, under its title.
private struct LayersPanelChrome: ViewModifier {
    let state: EditorState
    @Environment(\.panelPlacement) private var placement

    func body(content: Content) -> some View {
        switch placement {
        case .sheet: content.panelActions(confirm: { state.presentedPanel = nil })
        case .inspector: content.panelActions()
        }
    }
}

/// The active layer's mask: adding one, choosing whether painting goes
/// into it, and the ways to change it as a whole.
private struct MaskSection: View {
    let layer: Layer
    @Bindable var state: EditorState

    var body: some View {
        Section {
            if let mask = layer.mask {
                if !layer.isAdjustment {
                    Toggle("Mask.Edit", systemImage: "paintbrush.pointed", isOn: $state.isEditingMask)
                        .accessibilityIdentifier("editMask")
                }
                Toggle("Mask.Enabled", isOn: Binding(get: { mask.isEnabled }, set: { state.setMaskEnabled($0) }))
                Menu {
                    Section {
                        Button("Mask.HideSelection", systemImage: "eye.slash") { state.maskSelection(reveal: false) }
                        Button("Mask.RevealSelection", systemImage: "eye") { state.maskSelection(reveal: true) }
                    }
                    .disabled(state.selection == nil)
                    Button("Mask.Invert", systemImage: "circle.lefthalf.filled.inverse") { state.invertMask() }
                    // An adjustment layer is nothing but its mask.
                    if !layer.isAdjustment {
                        Section {
                            Button("Mask.Apply", systemImage: "square.and.arrow.down.on.square") { state.applyMask() }
                                .disabled(layer.isLocked)
                            Button("Mask.Delete", systemImage: "trash", role: .destructive) { state.deleteMask() }
                        }
                    }
                } label: {
                    Label("Mask.Actions", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("maskActions")
            } else {
                Button(
                    state.selection == nil ? "Mask.Add" : "Mask.AddFromSelection",
                    systemImage: "circle.rectangle.dashed"
                ) {
                    state.addMask()
                }
                .disabled(layer.isLocked)
                .accessibilityIdentifier("addMask")
            }
            if !layer.isAdjustment {
                Button("Mask.RemoveBackground", systemImage: "person.and.background.dotted") {
                    state.removeBackground()
                }
                .disabled(layer.isLocked)
                .accessibilityIdentifier("removeBackground")
            }
        } header: {
            Text("Mask.Title")
        } footer: {
            if layer.mask != nil { Text("Mask.Footer") }
        }
    }
}

/// A group's line in the Layers panel: a folder that opens and closes, with
/// its own eye.
private struct GroupRow: View {
    let group: LayerGroup
    let state: EditorState

    var body: some View {
        let isActive = state.activeGroupID == group.id
        HStack(spacing: 10) {
            Button {
                state.updateGroup(group.id) { $0.isExpanded.toggle() }
            } label: {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(group.isExpanded ? 90 : 0))
                    .frame(width: 24, height: 36)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(group.isExpanded ? "Groups.Collapse" : "Groups.Expand")
            Image(systemName: group.isExpanded ? "folder" : "folder.fill")
                .foregroundStyle(Color.accentColor)
                .frame(width: 36)
            Text(group.name)
                .lineLimit(1)
                .opacity(group.isVisible ? 1 : 0.5)
            if let mode = group.blendMode {
                Text(mode.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if group.opacity < 0.995 {
                Text(verbatim: "\(Int((group.opacity * 100).rounded()))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if group.isLocked {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                state.updateGroup(group.id) { $0.isVisible.toggle() }
            } label: {
                Image(systemName: group.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(group.isVisible ? Color.primary : Color.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(group.isVisible ? "Layers.Hide" : "Layers.Show")
        }
        .contentShape(.rect)
        .onTapGesture { state.activeGroupID = group.id }
        .listRowBackground(isActive ? Color.accentColor.opacity(0.18) : nil)
        .contextMenu {
            Button("Groups.Ungroup", systemImage: "folder.badge.minus") { state.ungroup(group.id) }
            Button("Groups.Merge", systemImage: "square.2.layers.3d.bottom.filled") { state.mergeGroup(group.id) }
            Button("SmartObject.Convert", systemImage: "shippingbox") {
                state.activeGroupID = group.id
                state.convertToSmartObject()
            }
            Button("Groups.Delete", systemImage: "trash", role: .destructive) { state.deleteGroup(group.id) }
                .disabled(!state.canDeleteGroup(group.id))
        }
        .accessibilityIdentifier("group.\(group.name)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// A picked group's settings: its name, opacity, blend mode and lock, and
/// the ways to take it apart.
private struct GroupSection: View {
    let group: LayerGroup
    let state: EditorState

    var body: some View {
        Section("Groups.Section") {
            TextField("Layers.Rename.Placeholder", text: Binding(
                get: { group.name },
                set: { value in
                    let trimmed = value.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { state.updateGroup(group.id) { $0.name = trimmed } }
                }
            ))
            LabeledSlider(
                label: "Layers.Opacity",
                value: Binding(get: { group.opacity }, set: { value in state.updateGroup(group.id) { $0.opacity = value } }),
                valueText: "\(Int((group.opacity * 100).rounded()))%"
            )
            .accessibilityIdentifier("groupOpacity")
            Picker("Layers.BlendMode", selection: Binding(
                get: { group.blendMode },
                set: { value in state.updateGroup(group.id) { $0.blendMode = value } }
            )) {
                Text("BlendMode.PassThrough").tag(LayerBlendMode?.none)
                ForEach(Array(LayerBlendMode.groups.enumerated()), id: \.offset) { _, modes in
                    Section {
                        ForEach(modes) { mode in
                            Text(mode.label).tag(LayerBlendMode?.some(mode))
                        }
                    }
                }
            }
            .accessibilityIdentifier("groupBlendMode")
            Toggle("Layers.Lock", isOn: Binding(
                get: { group.isLocked }, set: { value in state.updateGroup(group.id) { $0.isLocked = value } }
            ))
            Button("Groups.Ungroup", systemImage: "folder.badge.minus") { state.ungroup(group.id) }
            Button("Groups.Merge", systemImage: "square.2.layers.3d.bottom.filled") { state.mergeGroup(group.id) }
            Button("Groups.Delete", systemImage: "trash", role: .destructive) { state.deleteGroup(group.id) }
                .disabled(!state.canDeleteGroup(group.id))
        }
    }
}
