import ComposableArchitecture
import Foundation

extension Reducer {
    /// Deletes a file preview's temporary files once they leave state,
    /// however that happens: the preview closed, or its Files screen, agent
    /// or daemon went away. One rule at the root instead of a cleanup at
    /// every exit.
    func discardingPreviews(_ temporaryFiles: @escaping (State) -> [URL]) -> DiscardingPreviews<Self> {
        DiscardingPreviews(base: self, temporaryFiles: temporaryFiles)
    }
}

struct DiscardingPreviews<Base: Reducer>: Reducer {
    let base: Base
    let temporaryFiles: (Base.State) -> [URL]

    @Dependency(\.surfacedFiles) var surfacedFiles

    func reduce(into state: inout Base.State, action: Base.Action) -> Effect<Base.Action> {
        let before = temporaryFiles(state)
        let effects = base.reduce(into: &state, action: action)
        let after = Set(temporaryFiles(state))
        let gone = before.filter { !after.contains($0) }
        guard !gone.isEmpty else { return effects }
        let discard = surfacedFiles.discard
        return .merge(effects, .run { _ in gone.forEach(discard) })
    }
}
