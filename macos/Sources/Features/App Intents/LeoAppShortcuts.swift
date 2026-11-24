import AppIntents

@available(macOS 15.0, *)
struct LeoAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendMessageToLeoAgentIntent(),
            phrases: ["Tell an agent in \(.applicationName)"],
            shortTitle: "Tell an Agent",
            systemImageName: "bubble.left.and.text.bubble.right")
    }
}
