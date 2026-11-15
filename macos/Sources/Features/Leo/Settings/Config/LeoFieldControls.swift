import AppKit
import LeoKit
import SwiftUI

/// A multi-line text box with a hairline border, optionally monospaced (YAML).
struct LeoMultilineField: View {
    let text: Binding<String>
    let isMonospaced: Bool

    var body: some View {
        TextEditor(text: text)
            .font(isMonospaced ? .body.monospaced() : .body)
            .autocorrectionDisabled()
            .multilineTextAlignment(.leading)
            .frame(minWidth: 260, maxWidth: .infinity, minHeight: 72, maxHeight: 160)
            .padding(4)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
    }
}

/// Inherit, on or off for a bool that may be unset.
struct LeoTriStatePicker: View {
    let label: String
    let value: LeoConfigValue
    let inherited: LeoConfigValue?
    let set: (LeoConfigValue) -> Void

    private enum Choice: Hashable { case inherit, on, off }

    var body: some View {
        Picker(label, selection: Binding(get: { choice }, set: apply)) {
            Text(inheritLabel).tag(Choice.inherit)
            Text("On").tag(Choice.on)
            Text("Off").tag(Choice.off)
        }
        .labelsHidden()
        .fixedSize()
    }

    private var choice: Choice {
        switch value.boolValue {
        case true?: .on
        case false?: .off
        case nil: .inherit
        }
    }

    private var inheritLabel: String {
        switch inherited?.boolValue {
        case true?: "Inherit (on)"
        case false?: "Inherit (off)"
        case nil: "Inherit"
        }
    }

    private func apply(_ choice: Choice) {
        switch choice {
        case .inherit: set(.null)
        case .on: set(.bool(true))
        case .off: set(.bool(false))
        }
    }
}

/// A menu over (value, label) pairs. A value the list doesn't have (a newer
/// daemon's, or a deleted reference) is kept as an extra entry rather than
/// silently replaced.
struct LeoOptionPicker: View {
    let label: String
    let value: String
    let options: [(value: String, label: String)]
    var missingSuffix = ""
    let set: (String) -> Void

    var body: some View {
        Picker(label, selection: Binding(get: { value }, set: set)) {
            ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
            if !options.contains(where: { $0.value == value }) {
                Text(value + missingSuffix).tag(value)
            }
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// A text field with a menu of known values beside it (the model field).
struct LeoSuggestionField: View {
    let text: Binding<String>
    let suggestions: [String]
    let prompt: Text?

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: text, prompt: prompt).labelsHidden()
            Menu {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button(suggestion) { text.wrappedValue = suggestion }
                }
            } label: {
                Image(systemName: "chevron.down.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Suggestions")
        }
    }
}

/// A type this app doesn't know: shown, not editable.
struct LeoUnknownFieldNote: View {
    let typeName: String
    let webLink: URL?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("Can’t be edited here").foregroundStyle(.secondary)
            if let webLink {
                Link("Edit in the web UI", destination: webLink).font(.caption)
            } else {
                Text("Edit in the web UI").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .accessibilityLabel("A \(typeName) setting this version of Leo can’t edit. Edit it in the web UI.")
    }
}
