#if DEBUG
import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit

/// `-chatMarkdownFixture`: agent-0's thread holds one message with a Markdown
/// attachment (`sample`) and a plain-text one (`notes`), for driving the native
/// Markdown viewer and the QuickLook fallback. Layered on `-navFixture`.
enum ChatMarkdownFixture {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-chatMarkdownFixture") }

    static let agent = "agent-0"
    static let sampleID = "sample"
    static let notesID = "notes"

    static let messages: [LeoChatMessage] = [
        LeoChatMessage(
            id: "md-files", agent: agent, direction: .outbound, kind: .text, text: "Notes from the run.",
            ts: Date().addingTimeInterval(-600),
            attachments: [
                LeoChatAttachment(id: sampleID, filename: "sample.md", mime: "text/markdown", bytes: 2_400),
                LeoChatAttachment(id: notesID, filename: "notes.txt", mime: "text/plain", bytes: 40),
            ]
        )
    ]

    static let sample = """
    # Release notes

    A paragraph with *emphasis*, **strong text**, `inline code`, and ~~strikethrough~~. \
    Here is a [safe link](https://example.com) and a [script link](javascript:alert(1)) that stays plain.

    ![A diagram](https://example.com/diagram.png)

    ## Steps

    1. Build the app
       - Run the unit tests
       - Run the UI tests
    2. Ship it

    ### Snippet

    ```swift
    let greeting = "Hello, Markdown"
    print(greeting + " — rendered natively, scrolling sideways when a line is long enough to need it.")
    ```

    > A quoted remark that wraps onto a second line when the screen is narrow enough to need it.

    ---

    ## Results

    | Name | Owner | Status | Duration | Retries | Coverage | Branch | Notes |
    |:--|:--|:-:|--:|--:|--:|:--|:--|
    | Parser | Ada | Passing | 12s | 0 | 98% | main | Handles malformed input |
    | Viewer | Grace | Passing | 31s | 1 | 91% | feat/viewer | Wide tables scroll sideways |
    | Share | Linus | Flaky | 8s | 3 | 77% | feat/share | Needs a second look |
    """

    static func prepare(_ values: inout DependencyValues) {
        values.chatClient.messages = { _, _, _ in LeoChatPage(messages: messages, hasMore: false) }
        values.chatClient.download = { _, attachment in
            let isSample = attachment.id == sampleID
            let url = URL.temporaryDirectory.appending(path: attachment.filename)
            try Data((isSample ? sample : "Plain notes, opened in QuickLook.").utf8).write(to: url)
            return url
        }
    }
}
#endif
