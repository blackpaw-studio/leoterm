import ComposableArchitecture
import Foundation
import LeoKit

/// A control operation on one agent.
public enum AgentCommand: Equatable, Sendable {
    case interrupt
    case restart
    case setEnvironments([String])
    case start
    case stop
}

/// Talks to paired daemons' web listeners.
@DependencyClient
public struct DaemonClient: Sendable {
    /// Redeems a `leo pair` code at one origin.
    public var pair: @Sendable (_ baseURL: URL, _ code: String, _ deviceName: String, _ cfAccess: LeoCFAccessCredentials?) async throws -> LeoPairingGrant
    public var fetchState: @Sendable (_ connection: DaemonConnection) async throws -> LeoObservedState
    /// One event-stream connection; it ends when the daemon closes it.
    public var events: @Sendable (_ connection: DaemonConnection) -> AsyncThrowingStream<LeoObserveEvent, any Error> = { _ in .finished() }
    public var perform: @Sendable (_ connection: DaemonConnection, _ agent: String, _ command: AgentCommand) async throws -> Void
    public var environmentNames: @Sendable (_ connection: DaemonConnection) async throws -> [String]
    /// `PUT /api/v1/devices/{id}/push`: how the daemon pushes to this device.
    public var setPush: @Sendable (_ connection: DaemonConnection, _ deviceID: String, _ registration: LeoPushRegistration) async throws -> Void
    /// `DELETE /api/v1/devices/{id}/push`.
    public var deletePush: @Sendable (_ connection: DaemonConnection, _ deviceID: String) async throws -> Void
}

extension DaemonClient: DependencyKey {
    public static let testValue = DaemonClient()

    public static var liveValue: DaemonClient {
        let session = URLSession(configuration: .default)
        @Sendable func client(_ connection: DaemonConnection) -> LeoWebDaemonClient {
            LeoWebDaemonClient(transport: LeoHTTPSTransport(endpoint: connection.endpoint, session: session))
        }
        return DaemonClient(
            pair: { baseURL, code, deviceName, cfAccess in
                let transport = LeoHTTPSTransport(endpoint: LeoRemoteEndpoint(baseURL: baseURL, token: nil, cfAccess: cfAccess), session: session)
                return try await LeoWebDaemonClient.pair(code: code, deviceName: deviceName, transport: transport)
            },
            fetchState: { try await client($0).fetchState() },
            events: { client($0).events() },
            perform: { connection, agent, command in
                let client = client(connection)
                switch command {
                case .interrupt: try await client.interrupt(agent)
                case .restart: try await client.restart(agent)
                case .setEnvironments(let names): try await client.setEnvironments(agent, names: names)
                case .start: try await client.start(agent)
                case .stop: try await client.stop(agent)
                }
            },
            environmentNames: { try await client($0).environmentNames() },
            setPush: { connection, deviceID, registration in try await client(connection).registerPush(deviceID: deviceID, registration) },
            deletePush: { connection, deviceID in try await client(connection).unregisterPush(deviceID: deviceID) }
        )
    }
}

extension DependencyValues {
    public var daemonClient: DaemonClient {
        get { self[DaemonClient.self] }
        set { self[DaemonClient.self] = newValue }
    }
}
