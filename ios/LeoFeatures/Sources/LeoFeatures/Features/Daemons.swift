import ComposableArchitecture
import Foundation

/// The paired-daemons screen. Its rows come from `Fleet`; this feature owns
/// only the screen's own interactions.
@Reducer
public struct Daemons {
    @ObservableState
    public struct State: Equatable {
        @Presents public var alert: AlertState<Action.Alert>?

        public init() {}
    }

    public enum Action {
        case addButtonTapped
        case alert(PresentationAction<Alert>)
        case delegate(Delegate)
        case forgetButtonTapped(PairedDaemon)
        case retryButtonTapped(PairedDaemon.ID)

        @CasePathable
        public enum Alert: Equatable {
            case confirmForget(PairedDaemon.ID)
        }

        @CasePathable
        public enum Delegate {
            case add
            case forget(PairedDaemon.ID)
            case retry(PairedDaemon.ID)
        }
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .addButtonTapped:
                return .send(.delegate(.add))
            case .alert(.presented(.confirmForget(let id))):
                return .send(.delegate(.forget(id)))
            case .alert, .delegate:
                return .none
            case .forgetButtonTapped(let daemon):
                state.alert = Self.forgetAlert(daemon)
                return .none
            case .retryButtonTapped(let id):
                return .send(.delegate(.retry(id)))
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }

    static func forgetAlert(_ daemon: PairedDaemon) -> AlertState<Action.Alert> {
        AlertState {
            TextState("Forget \(daemon.name)?")
        } actions: {
            ButtonState(role: .destructive, action: .confirmForget(daemon.id)) { TextState("Forget") }
            ButtonState(role: .cancel) { TextState("Cancel") }
        } message: {
            TextState("This device's token is deleted. To revoke it on the daemon too, run `leo devices revoke \(daemon.deviceID)`.")
        }
    }
}
