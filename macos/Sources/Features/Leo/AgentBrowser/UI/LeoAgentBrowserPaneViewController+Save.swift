import AppKit
import LeoKit

/// File ▸ Save Page as PDF… (⇧⌘S) and Save Full-Page Screenshot… (⌥⇧⌘S)
/// (B-406). Like find, they reach the pane through the responder chain only
/// while focus is in it, and its stack claims their keys first so a page
/// can't swallow them. Each asks for a path in the agent's workspace, then
/// saves through the browser's download log (local or SFTP, never
/// overwriting) and reports in the download strip. Saving reads the page,
/// so it is not the user's input to the agent's browser.
extension LeoAgentBrowserPaneViewController {
    /// What the key equivalent asks for: ⇧⌘S or ⌥⇧⌘S; nil for any other key.
    static func saveAction(for event: NSEvent) -> Selector? {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard event.charactersIgnoringModifiers?.lowercased() == "s" else { return nil }
        switch modifiers {
        case [.command, .shift]: return #selector(savePageAsPDF(_:))
        case [.command, .shift, .option]: return #selector(saveFullPageScreenshot(_:))
        default: return nil
        }
    }

    static let saveActions: Set<Selector> = [#selector(savePageAsPDF(_:)), #selector(saveFullPageScreenshot(_:))]

    /// Whether the active tab shows a page there is something to save of.
    var canSavePage: Bool {
        guard let url = model.source.tabs.page(forTab: nil)?.url else { return false }
        return url.absoluteString != "about:blank"
    }

    func performSaveKeyEquivalent(_ event: NSEvent) -> Bool {
        guard ownsFindFocus(view.window?.firstResponder), let action = Self.saveAction(for: event) else { return false }
        if canSavePage { perform(action, with: nil) } else { NSSound.beep() }
        return true
    }

    @objc func savePageAsPDF(_ sender: Any?) {
        beginSave(.pdf)
    }

    @objc func saveFullPageScreenshot(_ sender: Any?) {
        beginSave(.png)
    }

    /// Shows the path sheet over the pane's window.
    private func beginSave(_ kind: LeoBrowserCaptureKind) {
        guard saveSheet == nil, let window = view.window, let sheet = makeSaveSheet(kind) else { return NSSound.beep() }
        saveSheet = sheet
        sheet.present(on: window)
    }

    /// The sheet for the active tab, wired to save on confirm; nil with no page.
    func makeSaveSheet(_ kind: LeoBrowserCaptureKind) -> LeoBrowserSaveSheet? {
        guard canSavePage, let page = model.source.tabs.page(forTab: nil) else { return nil }
        let downloads = model.source.downloads
        let defaultName = LeoBrowserCapturePath.defaultName(title: page.title, host: model.source.activeRemoteURL?.host(), kind: kind)
        let sheet = LeoBrowserSaveSheet(model: LeoBrowserSaveSheetModel(kind: kind, defaultName: defaultName) {
            downloads.captureProblem(with: $0, kind: kind)
        })
        sheet.onFinish = { [weak self] path in
            guard let self else { return }
            saveSheet = nil
            guard let path else { return }
            pendingSave = Task { await self.save(kind, of: page, at: path, defaultName: defaultName) }
        }
        return sheet
    }

    /// Captures `page` and saves it at `path`, showing progress and the
    /// outcome in the strip.
    func save(_ kind: LeoBrowserCaptureKind, of page: any LeoBrowserPage, at path: String, defaultName: String) async {
        let name = Self.requestedName(path, kind: kind, defaultName: defaultName)
        let id = model.beginCapture(name: name)
        do {
            let data = switch kind {
            case .pdf: try await page.pdf()
            case .png: try await page.screenshot(fullPage: true)
            }
            let saved = try await model.source.downloads.saveCapture(data, kind: kind, path: path, defaultName: defaultName)
            model.finishCapture(id, name: name, outcome: .success(saved))
        } catch let error as LeoBrowserError {
            model.finishCapture(id, name: name, outcome: .failure(error))
        } catch {
            model.finishCapture(id, name: name, outcome: .failure(LeoBrowserError(.jsError, error.localizedDescription)))
        }
    }

    /// The file name `path` asks for, for the strip while saving: the
    /// default for a folder, with the extension added when missing.
    private static func requestedName(_ path: String, kind: LeoBrowserCaptureKind, defaultName: String) -> String {
        guard !path.hasSuffix("/") else { return defaultName }
        let last = (path as NSString).lastPathComponent
        return (last as NSString).pathExtension.lowercased() == kind.pathExtension ? last : last + "." + kind.pathExtension
    }
}
