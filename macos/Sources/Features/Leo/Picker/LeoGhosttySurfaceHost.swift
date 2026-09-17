import GhosttyKit

/// Pure direction mapping between the Leo-facing `LeoSplitDirection`
/// (independent of AppKit/`SplitTree`, see `LeoSurfaceRequest.swift`) and
/// `SplitTree<Ghostty.SurfaceView>.NewDirection`, the type `newSplit`
/// actually takes. Kept as free functions (rather than an extension on the
/// generic nested type, which Swift can't target directly) so both
/// `TerminalController` and `GhosttyAttachTabHost` share one mapping.
func leoSplitTreeDirection(for direction: LeoSplitDirection) -> SplitTree<Ghostty.SurfaceView>.NewDirection {
    switch direction {
    case .left: .left
    case .right: .right
    case .up: .up
    case .down: .down
    }
}

func leoSplitDirection(for direction: SplitTree<Ghostty.SurfaceView>.NewDirection) -> LeoSplitDirection {
    switch direction {
    case .left: .left
    case .right: .right
    case .up: .up
    case .down: .down
    }
}
