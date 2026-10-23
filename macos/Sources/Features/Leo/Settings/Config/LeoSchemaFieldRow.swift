import LeoKit
import SwiftUI

/// One schema field: its label and control, with the help line beneath, then
/// the warning, then any errors. A known type gets a standard control; an
/// unknown one is shown read-only (`LeoConfigControl.readOnlyUnknown`).
struct LeoSchemaFieldRow: View {
    let row: LeoConfigFormRow
    var cronPreview: String?
    let set: (LeoConfigValue) -> Void
    let revert: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                control
            } label: {
                Text(row.field.label).fontWeight(row.isDirty ? .semibold : .regular)
            }
            if !row.field.help.isEmpty {
                Text(row.field.help).font(.caption).foregroundStyle(.secondary)
            }
            if !row.field.warning.isEmpty {
                Label(row.field.warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            ForEach(row.errors, id: \.self) { message in
                Text(message).font(.caption).foregroundStyle(.red)
                    .accessibilityLabel("Error: \(message)")
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Controls

    @ViewBuilder private var control: some View {
        switch row.control {
        case .text(let placeholder):
            TextField(row.field.label, text: text, prompt: prompt(placeholder)).labelsHidden()
        case .multiline:
            LeoMultilineField(text: text, isMonospaced: false)
        case .yaml:
            LeoMultilineField(text: text, isMonospaced: true)
        case .number(_, _, let placeholder):
            TextField(row.field.label, text: numberText, prompt: prompt(placeholder))
                .labelsHidden().multilineTextAlignment(.trailing).frame(maxWidth: 140)
        case .duration(let placeholder):
            TextField(row.field.label, text: text, prompt: prompt(placeholder))
                .labelsHidden().font(.body.monospaced()).multilineTextAlignment(.trailing).frame(maxWidth: 140)
        case .toggle:
            Toggle(row.field.label, isOn: flag).labelsHidden()
        case .triState:
            LeoTriStatePicker(label: row.field.label, value: row.value, inherited: row.inherited, set: set)
        case .picker(let options):
            LeoOptionPicker(label: row.field.label, value: row.value.stringValue ?? "", options: options.map { ($0.value, $0.label) }) { set(.string($0)) }
        case .referencePicker(_, let names, let emptyLabel):
            LeoOptionPicker(
                label: row.field.label, value: row.value.stringValue ?? "",
                options: [("", emptyLabel)] + names.map { ($0, $0) }, missingSuffix: " (missing)"
            ) { set(.string($0)) }
        case .list:
            LeoListEditor(items: row.value.stringList ?? []) { set(.list($0.map(LeoConfigValue.string))) }
        case .keyValue:
            LeoKeyValueEditor(
                entries: row.value.envEntries, secrets: row.value.envSecrets,
                setSecret: { set(row.value.settingEnvSecret($0, to: $1)) }, onChange: { set(row.value.replacingEnvEntries($0)) }
            )
        case .cron:
            LeoCronField(text: text, preview: cronPreview, prompt: prompt(nil))
        case .secret(let state):
            LeoSecretField(state: state, set: set, revert: revert)
        case .suggestions(let suggestions, let placeholder):
            LeoSuggestionField(text: text, suggestions: suggestions, prompt: prompt(placeholder))
        case .readOnlyUnknown(let typeName, let webLink):
            LeoUnknownFieldNote(typeName: typeName, webLink: webLink)
        }
    }

    // MARK: Bindings

    private var text: Binding<String> {
        Binding(get: { row.value.stringValue ?? "" }, set: { set($0.isEmpty ? .null : .string($0)) })
    }

    /// An int field's text: a whole number reads as `.int`, empty as unset,
    /// and anything else is kept as typed so the validator can say why.
    private var numberText: Binding<String> {
        Binding(
            get: {
                switch row.value {
                case .int(let number): String(number)
                case .string(let typed): typed
                default: ""
                }
            },
            set: { typed in
                let trimmed = typed.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { set(.null) } else if let number = Int(trimmed) { set(.int(number)) } else { set(.string(typed)) }
            }
        )
    }

    private var flag: Binding<Bool> {
        Binding(
            get: { row.value.boolValue ?? row.field.defaultValue.boolValue ?? false },
            set: { set(.bool($0)) }
        )
    }

    private func prompt(_ placeholder: String?) -> Text? {
        placeholder.map { Text($0) }
    }
}
