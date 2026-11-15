import Foundation
import LeoKit

/// A Form's current values and how they are submitted. AppKit-free so the
/// collect-and-submit rules are unit-tested.
///
/// A submit whose action is a `callback` carries the collected values:
/// `{"formId", "values": {fieldId: string|bool}, "payload": <original>}`.
/// Other submit actions (copy, openURL, ...) pass through unchanged.
@MainActor
final class LeoPluginFormModel {
    private(set) var form: LeoPluginNode.Form
    private(set) var values: [String: LeoJSONValue]
    private let emitter: LeoPluginActionEmitter

    init(form: LeoPluginNode.Form, mint: LeoPluginGestureMint, handler: @escaping LeoPluginActionHandler) {
        self.form = form
        self.values = Self.defaults(for: form)
        self.emitter = LeoPluginActionEmitter(mint: mint, handler: handler)
    }

    func setText(_ text: String, for fieldID: String) {
        guard let field = field(fieldID), field.type == .text || field.type == .textArea else { return }
        values[fieldID] = .string(text)
    }

    func setChoice(_ value: String, for fieldID: String) {
        guard let field = field(fieldID), field.type == .picker, field.options.contains(where: { $0.value == value }) else { return }
        values[fieldID] = .string(value)
    }

    func setChecked(_ checked: Bool, for fieldID: String) {
        guard field(fieldID)?.type == .checkbox else { return }
        values[fieldID] = .bool(checked)
    }

    /// Returns whether an action was emitted.
    @discardableResult
    func submit(fieldID: String, origin: LeoPluginGesture.Origin) -> Bool {
        guard let field = field(fieldID), field.type == .submit, let action = field.action else { return false }
        emitter.emit(resolved(action), origin: origin)
        return true
    }

    /// Adopts a re-rendered form: user edits survive for fields that still
    /// exist with the same kind; new fields start from their defaults.
    func apply(form newForm: LeoPluginNode.Form) {
        let fresh = Self.defaults(for: newForm)
        let kinds = Dictionary(form.fields.map { ($0.id, $0.type) }, uniquingKeysWith: { first, _ in first })
        var merged = fresh
        for field in newForm.fields where kinds[field.id] == field.type {
            guard let kept = values[field.id] else { continue }
            if field.type == .picker, case .string(let s) = kept, !field.options.contains(where: { $0.value == s }) { continue }
            merged[field.id] = kept
        }
        form = newForm
        values = merged
    }

    // MARK: Private

    private func field(_ id: String) -> LeoPluginNode.Field? { form.fields.first { $0.id == id } }

    private func resolved(_ action: LeoPluginAction) -> LeoPluginAction {
        guard case .callback(let id, let payload) = action else { return action }
        return .callback(id: id, payload: .object([
            "formId": .string(form.id),
            "values": .object(values),
            "payload": payload,
        ]))
    }

    private static func defaults(for form: LeoPluginNode.Form) -> [String: LeoJSONValue] {
        var result: [String: LeoJSONValue] = [:]
        for field in form.fields {
            switch field.type {
            case .text, .textArea: result[field.id] = .string(field.value ?? "")
            case .picker:
                let chosen = field.options.first { $0.value == field.value } ?? field.options.first
                if let chosen { result[field.id] = .string(chosen.value) }
            case .checkbox: result[field.id] = .bool(field.checked ?? false)
            case .submit: break
            }
        }
        return result
    }
}
