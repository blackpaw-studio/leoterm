import ComposableArchitecture
import Foundation

/// The paired-daemons screen. Its rows come from `Fleet`; this feature owns
/// only the screen's own interactions.
@Reducer
public struct Daemons {
    @ObservableState
    public struct State: Equatable {
        @Presents public var alert: AlertState<Action.Alert>?
        /// The open machine's settings.
        @Presents public var machine: MachineSettings.State?

        public init() {}
    }

    public enum Action {
        case addButtonTapped
        case alert(PresentationAction<Alert>)
        /// The screen came on screen: stats polling may run.
        case appeared
        case delegate(Delegate)
        case disappeared
        case forgetButtonTapped(PairedDaemon)
        case machine(PresentationAction<MachineSettings.Action>)
        /// A machine's row was tapped; the parent opens its settings.
        case machineTapped(PairedDaemon.ID)
        case retryButtonTapped(PairedDaemon.ID)

        @CasePathable
        public enum Alert: Equatable {
            case confirmForget(PairedDaemon.ID)
        }

        @CasePathable
        public enum Delegate {
            case add
            case forget(PairedDaemon.ID)
            case openMachine(PairedDaemon.ID)
            case retry(PairedDaemon.ID)
            case visibilityChanged(Bool)
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
            case .machine(.presented(.delegate(.retry(let id)))):
                return .send(.delegate(.retry(id)))
            case .alert, .delegate, .machine:
                return .none
            case .appeared:
                return .send(.delegate(.visibilityChanged(true)))
            case .disappeared:
                return .send(.delegate(.visibilityChanged(false)))
            case .forgetButtonTapped(let daemon):
                state.alert = Self.forgetAlert(daemon)
                return .none
            case .machineTapped(let id):
                return .send(.delegate(.openMachine(id)))
            case .retryButtonTapped(let id):
                return .send(.delegate(.retry(id)))
            }
        }
        .ifLet(\.$alert, action: \.alert)
        .ifLet(\.$machine, action: \.machine) { MachineSettings() }
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
