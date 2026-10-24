import ComposableArchitecture
import Foundation
import LeoKit

/// The sheet that names an item: a new one, a rename, or a copy. The text and
/// the message under it are the sheet's; checking the name against the list
/// and sending it are the pane's.
@Reducer
public struct NameEntry {
    @ObservableState
    public struct State: Equatable {
        public enum Kind: Equatable, Sendable {
            case add
            case rename(from: String)
            case duplicate(from: String)
        }

        public let kind: Kind
        public var text: String
        /// Why the name can't be used: the validator's, or the daemon's.
        public var error: String?
        /// A new task needs its schedule: the sheet asks for it beside the name.
        public let requiresSchedule: Bool
        public var schedule = ""
        public var scheduleError: String?
        public var schedulePreview: LeoCronPreviewResult?

        public init(kind: Kind, requiresSchedule: Bool = false) {
            self.kind = kind
            self.requiresSchedule = requiresSchedule
            switch kind {
            case .add: text = ""
            case .rename(let name): text = name
            case .duplicate(let name): text = "\(name)-copy"
            }
        }
    }

    public enum Action {
        case textChanged(String)
        case scheduleChanged(String)
        case submitTapped
        case cancelTapped
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .textChanged(let text):
                state.text = text
            case .scheduleChanged(let text):
                state.schedule = text
                state.scheduleError = nil
                state.schedulePreview = nil
            case .submitTapped, .cancelTapped:
                break
            }
            return .none
        }
    }
}
