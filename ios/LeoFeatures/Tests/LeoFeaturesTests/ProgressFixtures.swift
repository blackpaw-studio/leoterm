import Foundation
import LeoKit

@testable import LeoFeatures

let progressEpoch = Date(timeIntervalSince1970: 1_800_000_000)

extension LeoAgentTask {
    static func make(
        _ id: String, title: String? = nil, percent: Double? = nil, state: State = .running, status: String? = nil,
        stale: Bool = false, startedAt: Date = progressEpoch, updatedAt: Date? = nil, endedAt: Date? = nil, revision: Int = 1
    ) -> LeoAgentTask {
        LeoAgentTask(
            id: id, title: title ?? id, mode: percent == nil ? .indeterminate : .determinate, percent: percent, status: status,
            state: state, stale: stale, startedAt: startedAt, updatedAt: updatedAt, endedAt: endedAt, revision: revision
        )
    }
}

extension LeoObservedAgent {
    static func make(_ name: String, tasks: [LeoAgentTask], attention: LeoAttentionSignal? = nil) -> LeoObservedAgent {
        LeoObservedAgent(
            name: name, status: .running, activity: .working, currentAction: nil, lastActivityAt: nil,
            attention: attention, startedAt: nil, template: "coding", harness: "claude", tasks: tasks
        )
    }
}
