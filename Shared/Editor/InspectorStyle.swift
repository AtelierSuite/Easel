import SwiftUI

extension View {
    /// The look of a panel's form: grouped rows on iPhone and iPad, and in
    /// the Mac's inspector the look of Pages, Numbers and Keynote's.
    func panelFormStyle() -> some View {
        modifier(PanelFormStyle())
    }
}

extension Text {
    /// A section's footnote in a list, wrapped onto as many lines as it
    /// needs: a Mac list would otherwise cut it off after one.
    func panelFootnote() -> some View {
        fixedSize(horizontal: false, vertical: true)
    }
}

private struct PanelFormStyle: ViewModifier {
    @Environment(\.panelPlacement) private var placement

    func body(content: Content) -> some View {
        #if os(macOS)
        if placement == .inspector {
            content.formStyle(InspectorFormStyle())
        } else {
            content.formStyle(.grouped)
        }
        #else
        content.formStyle(.grouped)
        #endif
    }
}

/// A panel's rows: a list on iPhone and iPad, and in the Mac's inspector a
/// form laid out like the rest of it. Rows that can be dragged into a new
/// order on iPhone and iPad are moved from their menus there.
struct PanelList<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.panelPlacement) private var placement

    var body: some View {
        #if os(macOS)
        if placement == .inspector {
            Form { content }
                .formStyle(InspectorFormStyle())
        } else {
            List { content }
                .panelListStyle()
        }
        #else
        List { content }
            .panelListStyle()
        #endif
    }
}

#if os(macOS)
/// Sections one under the other, each under a bold title and parted from
/// the next by a hairline, with small controls: the look of the inspector
/// in Pages, Numbers and Keynote.
struct InspectorFormStyle: FormStyle {
    static let horizontalPadding: CGFloat = 16

    func makeBody(configuration: Configuration) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Group(sections: configuration.content) { sections in
                    let shown = sections.filter { !$0.content.isEmpty || !$0.header.isEmpty }
                    ForEach(shown) { section in
                        if section.id != shown.first?.id {
                            Divider()
                                .padding(.horizontal, Self.horizontalPadding)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            if !section.header.isEmpty {
                                section.header
                                    .font(.callout.bold())
                            }
                            section.content
                            if !section.footer.isEmpty {
                                section.footer
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Self.horizontalPadding)
                        .padding(.vertical, 12)
                    }
                }
            }
        }
        // Filling the panel even with nothing in it, for a message laid
        // over it to have somewhere to show.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .font(.callout)
        .controlSize(.small)
        .toggleStyle(InspectorCheckboxStyle())
        .labeledContentStyle(InspectorLabeledContentStyle())
        .pickerStyle(.menu)
    }
}

/// The box before its name. A form would otherwise set the name on the
/// left and the box on the right, like any other control.
struct InspectorCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            Toggle("", isOn: configuration.$isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
            configuration.label
                .labelStyle(.titleOnly)
                .contentShape(.rect)
                .onTapGesture { configuration.isOn.toggle() }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The name on the left and its value or control on the right.
struct InspectorLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline) {
            configuration.label
            Spacer(minLength: 8)
            configuration.content
        }
    }
}

/// A number typed in beside a slider, with arrows that step it, as in the
/// inspectors of Pages, Numbers and Keynote.
struct InspectorNumberField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var suffix: String = ""
    var fractionDigits = 0

    var body: some View {
        HStack(spacing: 2) {
            TextField(
                value: Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) }),
                format: .number.precision(.fractionLength(fractionDigits))
            ) {
                EmptyView()
            }
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: 48)
            // The same width with or without a unit, so the sliders beside
            // the fields all end in line.
            Text(verbatim: suffix)
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .leading)
            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
        }
        .fixedSize()
    }
}
#endif

#if os(macOS)
/// The first line of a filter or style in the Mac's inspector: a box that
/// turns it on and off before its name, and a menu of what else can be done
/// with it.
struct InspectorItemHeader<MenuItems: View>: View {
    let title: Text
    @Binding var isOn: Bool
    var menuIdentifier: String?
    @ViewBuilder let menuItems: MenuItems

    var body: some View {
        HStack(spacing: 4) {
            Toggle(isOn: $isOn) {
                title.font(.callout.bold())
            }
            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Layers.More")
            .accessibilityIdentifier(menuIdentifier ?? "")
        }
    }
}

/// What sits above a list of filters or styles in the Mac's inspector: a
/// pop-up button to add one, and a menu for all of them.
struct InspectorAddBar<AddMenu: View, MoreItems: View>: View {
    @ViewBuilder let addMenu: AddMenu
    @ViewBuilder let moreItems: MoreItems

    var body: some View {
        HStack {
            addMenu
                .fixedSize()
            Spacer()
            Menu {
                moreItems
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Layers.More")
        }
        .controlSize(.small)
        .padding(.horizontal, InspectorFormStyle.horizontalPadding)
        .padding(.vertical, 8)
    }
}
#endif
