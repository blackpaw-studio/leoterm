import Foundation

/// A `UserDefaults` that lives only in memory, for tests to inject wherever
/// production takes a `UserDefaults`. A `UserDefaults(suiteName:)` suite
/// leaves a plist in the real `~/Library/Preferences` even after
/// `removePersistentDomain` (B-039); this never reads or writes a domain.
///
/// Every accessor production can reach is overridden, so nothing falls
/// through to the standard search list the superclass was created with.
/// Persistent-domain calls would reach real domains, so they trap.
final class LeoInMemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    private var registered: [String: Any] = [:]

    init() {
        // `nil` is the standard search list; the overrides below never consult it.
        super.init(suiteName: nil)!
    }

    // MARK: Storage

    override func object(forKey defaultName: String) -> Any? {
        lock.withLock { values[defaultName] ?? registered[defaultName] }
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        // Bridge as the real store does, so `as? NSNumber` and `as? Bool` both work.
        lock.withLock { values[defaultName] = value.map { $0 as AnyObject } }
    }

    override func removeObject(forKey defaultName: String) {
        set(nil, forKey: defaultName)
    }

    override func register(defaults registrationDictionary: [String: Any]) {
        lock.withLock { registered.merge(registrationDictionary) { $1 } }
    }

    override func dictionaryRepresentation() -> [String: Any] {
        lock.withLock { registered.merging(values) { $1 } }
    }

    override func synchronize() -> Bool { true }

    override func persistentDomain(forName _: String) -> [String: Any]? { Self.noDomains() }
    override func setPersistentDomain(_: [String: Any], forName _: String) { Self.noDomains() }
    override func removePersistentDomain(forName _: String) { Self.noDomains() }

    private static func noDomains() -> Never {
        preconditionFailure("LeoInMemoryDefaults has no persistent domains; a real one would leave a plist behind")
    }

    // MARK: Typed setters

    override func set(_ value: Int, forKey defaultName: String) { set(value as Any, forKey: defaultName) }
    override func set(_ value: Float, forKey defaultName: String) { set(value as Any, forKey: defaultName) }
    override func set(_ value: Double, forKey defaultName: String) { set(value as Any, forKey: defaultName) }
    override func set(_ value: Bool, forKey defaultName: String) { set(value as Any, forKey: defaultName) }
    override func set(_ url: URL?, forKey defaultName: String) { set(url as Any?, forKey: defaultName) }

    // MARK: Typed getters (the real store's conversions)

    override func string(forKey defaultName: String) -> String? {
        switch object(forKey: defaultName) {
        case let string as String: string
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }

    override func array(forKey defaultName: String) -> [Any]? { object(forKey: defaultName) as? [Any] }
    override func dictionary(forKey defaultName: String) -> [String: Any]? { object(forKey: defaultName) as? [String: Any] }
    override func data(forKey defaultName: String) -> Data? { object(forKey: defaultName) as? Data }
    override func stringArray(forKey defaultName: String) -> [String]? { object(forKey: defaultName) as? [String] }
    override func url(forKey defaultName: String) -> URL? {
        switch object(forKey: defaultName) {
        case let url as URL: url
        case let path as String: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        default: nil
        }
    }

    override func integer(forKey defaultName: String) -> Int { number(forKey: defaultName)?.intValue ?? 0 }
    override func float(forKey defaultName: String) -> Float { number(forKey: defaultName)?.floatValue ?? 0 }
    override func double(forKey defaultName: String) -> Double { number(forKey: defaultName)?.doubleValue ?? 0 }
    override func bool(forKey defaultName: String) -> Bool {
        if let string = object(forKey: defaultName) as? String {
            return ["yes", "true"].contains(string.lowercased()) || (Int(string) ?? 0) != 0
        }
        return number(forKey: defaultName)?.boolValue ?? false
    }

    private func number(forKey defaultName: String) -> NSNumber? {
        switch object(forKey: defaultName) {
        case let number as NSNumber: number
        case let string as String: Double(string).map(NSNumber.init(value:))
        default: nil
        }
    }
}
