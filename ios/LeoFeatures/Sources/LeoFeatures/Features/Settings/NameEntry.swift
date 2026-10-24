import ComposableArchitecture
import Foundation

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

        public init(kind: Kind) {
            self.kind = kind
            switch kind {
            case .add: text = ""
            case .rename(let name): text = name
            case .duplicate(let name): text = "\(name)-copy"
            }
        }
    }

    public enum Action {
        case textChanged(String)
        case submitTapped
        case cancelTapped
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            if case .textChanged(let text) = action { state.text = text }
            return .none
        }
    }
}
