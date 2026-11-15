import ComposableArchitecture
import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// The system pasteboard, for Copy buttons.
public struct PasteboardClient: Sendable {
    public var copy: @Sendable (_ text: String) -> Void

    public init(copy: @escaping @Sendable (String) -> Void) {
        self.copy = copy
    }
}

extension PasteboardClient: DependencyKey {
    public static var testValue: PasteboardClient {
        PasteboardClient(copy: { _ in reportIssue("PasteboardClient.copy is unimplemented") })
    }

    public static var liveValue: PasteboardClient {
        #if canImport(UIKit)
        PasteboardClient(copy: { text in Task { @MainActor in UIPasteboard.general.string = text } })
        #else
        PasteboardClient(copy: { _ in })
        #endif
    }
}

extension DependencyValues {
    public var pasteboard: PasteboardClient {
        get { self[PasteboardClient.self] }
        set { self[PasteboardClient.self] = newValue }
    }
}
