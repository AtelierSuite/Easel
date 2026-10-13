import SwiftUI
import UniformTypeIdentifiers

/// Shown while smart objects from a Photoshop file wait for files they
/// link to, or Displace filters for their maps: the first file's name, and
/// a way to choose it. Each layer shows the pixels Photoshop saved, or its
/// filters without the map, until then.
struct LinkedFilesBanner: View {
    let state: EditorState
    @State private var isDismissed = false
    @State private var isChoosing = false
    /// The file being chosen, kept past the picker closing.
    @State private var choosingName = ""

    var body: some View {
        let links = state.missingLinkNames
        let names = links + state.missingMapNames.filter { !links.contains($0) }
        if let name = names.first, !isDismissed {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.tint)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("LinkedFile.Missing \(name)")
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Group {
                        if !links.contains(name) {
                            Text(names.count > 1 ? "LinkedFile.MapDetail.More \(names.count - 1)" : "LinkedFile.MapDetail")
                        } else {
                            Text(names.count > 1 ? "LinkedFile.Detail.More \(names.count - 1)" : "LinkedFile.Detail")
                        }
                    }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("LinkedFile.Choose") {
                        choosingName = name
                        isChoosing = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 4)
                    .accessibilityIdentifier("chooseLinkedFile")
                }
                Spacer(minLength: 0)
                Button {
                    isDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("LinkedFile.Dismiss")
                .accessibilityIdentifier("dismissLinkedFiles")
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 12)
            .frame(maxWidth: 520)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .fileImporter(isPresented: $isChoosing, allowedContentTypes: Self.contentTypes) { result in
                guard case .success(let url) = result else { return }
                let name = choosingName
                if state.missingLinkNames.contains(name) {
                    state.relink(named: name, to: url)
                } else {
                    state.setDisplacementMap(from: url) { $0.displacementMap == nil && $0.displacementMapName == name }
                }
            }
        }
    }

    /// Photoshop documents and pictures, as Photoshop links to.
    private static let contentTypes: [UTType] = [
        .image,
        UTType("com.adobe.photoshop-image") ?? UTType(importedAs: "com.adobe.photoshop-image"),
        UTType("com.adobe.photoshop-large-image") ?? UTType(importedAs: "com.adobe.photoshop-large-image"),
    ]
}
