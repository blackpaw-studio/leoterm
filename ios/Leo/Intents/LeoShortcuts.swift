import AppIntents

/// The phrases Siri and Spotlight offer without any setup.
struct LeoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendMessageToAgent(),
            phrases: ["Tell an agent in \(.applicationName)"],
            shortTitle: "Tell an Agent",
            systemImageName: "waveform"
        )
    }
}
