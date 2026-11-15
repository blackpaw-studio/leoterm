import Foundation

/// A machine's agent count in words, for the Mac header's accessibility
/// label and the iOS Machines list.
public enum LeoAgentCountText {
    public static func describing(_ count: Int) -> String {
        count == 1 ? "1 agent" : "\(count) agents"
    }
}
