import Foundation
import LeoKit

/// One thread's loaded messages, oldest first, for a task filter (nil:
/// everything). Pages and live events merge by id; a message a live event
/// brought while a page request was out wins over that page's older copy.
struct LeoChatTimeline: Equatable {
    private(set) var messages: [LeoChatMessage] = []
    private(set) var hasMore = false
    /// Every task name seen in the thread, kept across filter changes for
    /// the filter menu.
    private(set) var knownTasks: Set<String>
    let taskFilter: String?
    /// Messages a live event merged since the current page request started.
    private var liveSinceFetch: Set<String> = []

    init(taskFilter: String? = nil, knownTasks: Set<String> = []) {
        self.taskFilter = taskFilter
        self.knownTasks = knownTasks
    }

    var newest: LeoChatMessage? { messages.last }
    var oldest: LeoChatMessage? { messages.first }

    func message(id: String) -> LeoChatMessage? { messages.first { $0.id == id } }

    /// Whether `message` is in this thread's view (its agent and filter).
    func admits(_ message: LeoChatMessage, agent: String) -> Bool {
        message.agent == agent && (taskFilter == nil || message.task == taskFilter)
    }

    /// A page request is starting: live merges from now on outrank it.
    mutating func beginFetch() { liveSinceFetch = [] }

    mutating func endFetch() { liveSinceFetch = [] }

    mutating func mergePage(_ page: LeoChatPage) {
        hasMore = page.hasMore
        merge(page.messages.filter { !liveSinceFetch.contains($0.id) })
        liveSinceFetch = []
    }

    /// A live message; `isFetching` records it so an in-flight page can't
    /// overwrite it with an older copy.
    mutating func mergeLive(_ message: LeoChatMessage, isFetching: Bool) {
        merge([message])
        if isFetching { liveSinceFetch.insert(message.id) }
    }

    /// Upserts, keeping time order (ties by id: ULIDs sort by time).
    mutating func merge(_ incoming: [LeoChatMessage]) {
        guard !incoming.isEmpty else { return }
        var byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for message in incoming {
            byID[message.id] = message
            if let task = message.task { knownTasks.insert(task) }
        }
        messages = byID.values.sorted { ($0.ts, $0.id) < ($1.ts, $1.id) }
    }
}
