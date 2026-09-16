import Foundation

enum LeoHostStoreError: Error, Equatable, Sendable {
    case invalidConfiguration(String, [LeoHostValidationError])
    case duplicateName(String)
}

struct LeoHostStoreProblem: Equatable, Sendable {
    let host: LeoHostConfiguration
    let errors: [LeoHostValidationError]
}

struct LeoHostStore {
    static let key = "leo.hosts"

    private let defaults: UserDefaults
    private let onInvalid: ([LeoHostStoreProblem]) -> Void

    init(
        defaults: UserDefaults,
        onInvalid: @escaping ([LeoHostStoreProblem]) -> Void = { _ in }
    ) {
        self.defaults = defaults
        self.onInvalid = onInvalid
    }

    func load() -> [LeoHostConfiguration] {
        guard let data = defaults.data(forKey: Self.key),
              let hosts = try? JSONDecoder().decode([LeoHostConfiguration].self, from: data) else {
            return []
        }
        let partitioned = hosts.reduce(into: (valid: [LeoHostConfiguration](), invalid: [LeoHostStoreProblem]())) { result, host in
            let errors = host.validate()
            if errors.isEmpty {
                result.valid.append(host)
            } else {
                result.invalid.append(.init(host: host, errors: errors))
            }
        }
        if !partitioned.invalid.isEmpty {
            onInvalid(partitioned.invalid)
        }
        return partitioned.valid.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func save(_ hosts: [LeoHostConfiguration]) throws {
        for host in hosts {
            let errors = host.validate()
            if !errors.isEmpty {
                throw LeoHostStoreError.invalidConfiguration(host.name, errors)
            }
        }

        var names = Set<String>()
        for host in hosts {
            let key = host.name.lowercased()
            guard names.insert(key).inserted else {
                throw LeoHostStoreError.duplicateName(key)
            }
        }

        defaults.set(try JSONEncoder().encode(hosts), forKey: Self.key)
    }
}
