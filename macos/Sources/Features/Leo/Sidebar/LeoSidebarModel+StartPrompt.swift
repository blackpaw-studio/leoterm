import Foundation

/// B-049: "Start <name>?" for a click on an agent that isn't running.
struct LeoStartPrompt: Identifiable, Equatable {
    enum Phase: Equatable {
        /// Asking; nothing has been started.
        case confirm
        /// Started (or already starting): attaches once the daemon reports
        /// the agent running.
        case waiting
    }

    let id: UUID
    let agent: LeoAgentRow.ID
    /// The window the click came from, where the sheet shows and the
    /// attach lands.
    let origin: LeoWindowID
    let disposition: AttachDisposition
    let phase: Phase

    func with(phase: Phase) -> LeoStartPrompt {
        LeoStartPrompt(id: id, agent: agent, origin: origin, disposition: disposition, phase: phase)
    }
}

/// A click goes to the agent: a running one is attached; any other asks
/// before starting it, then attaches once the daemon reports it running --
/// never on a timer, never by guessing (principle 5). The wait ends when
/// the user cancels, the sheet goes away (its window closed), the start
/// is refused, or the agent leaves the list; nothing retries.
extension LeoSidebarModel {
    func startPrompt(in window: LeoWindowID) -> LeoStartPrompt? { startPrompts[window] }

    /// Where a click (or Return) goes once the click count and modifiers
    /// have picked a disposition. Needs the window it came from: that's
    /// where the attach lands and the prompt shows.
    func go(to row: LeoAgentRow, from origin: LeoWindowID?, disposition: AttachDisposition) {
        guard let origin, !isDisconnected else { return }
        guard row.status == .running else {
            askToStart(row, from: origin, disposition: disposition)
            return
        }
        requestAttach(row, from: origin, disposition: disposition)
    }

    /// Start: asks the daemon to start the agent. A refusal ends the
    /// prompt (the row shows the daemon's error); acceptance keeps waiting
    /// for the running report.
    func confirmStart(_ id: LeoStartPrompt.ID) {
        guard let prompt = prompt(id), prompt.phase == .confirm else { return }
        guard let row = snapshot.rows.first(where: { $0.id == prompt.agent }) else {
            endStartPrompt(id)
            return
        }
        startPrompts[prompt.origin] = prompt.with(phase: .waiting)
        startRequested(row) { [weak self] accepted in
            guard !accepted else { return }
            self?.endStartPrompt(id)
        }
        resolveStartPrompts()
    }

    /// Cancel, Escape, or the sheet going away: forget the prompt. The
    /// agent and its tabs are left as they are (an accepted start keeps
    /// going; it just won't attach).
    func cancelStartPrompt(_ id: LeoStartPrompt.ID) { endStartPrompt(id) }

    /// Return on the list: the same as a single click on the selected row.
    func activateSelection(from origin: LeoWindowID) {
        if let dispatch = selectedDispatch { return requestDispatchAttach(dispatch, from: origin, disposition: .content) }
        guard let selected = actionableSelection?.id,
              let row = visibleRows.first(where: { $0.id == selected }) else { return }
        rowClicked(row, from: origin)
    }

    /// After each snapshot: a waiting prompt whose agent the daemon now
    /// reports running attaches; one whose agent left the list ends. A
    /// disconnected list is stale, so it decides nothing.
    func resolveStartPrompts() {
        guard !isDisconnected else { return }
        for prompt in startPrompts.values {
            guard let row = snapshot.rows.first(where: { $0.id == prompt.agent }) else {
                endStartPrompt(prompt.id)
                continue
            }
            guard prompt.phase == .waiting, row.status == .running else { continue }
            endStartPrompt(prompt.id)
            requestAttach(row, from: prompt.origin, disposition: prompt.disposition)
        }
    }

    /// One prompt per window: a click while one is open (e.g. a
    /// double-click's second click) never asks again.
    private func askToStart(_ row: LeoAgentRow, from origin: LeoWindowID, disposition: AttachDisposition) {
        guard startPrompts[origin] == nil else { return }
        let phase: LeoStartPrompt.Phase = row.status == .starting ? .waiting : .confirm
        startPrompts[origin] = LeoStartPrompt(id: UUID(), agent: row.id, origin: origin, disposition: disposition, phase: phase)
    }

    private func prompt(_ id: LeoStartPrompt.ID) -> LeoStartPrompt? {
        startPrompts.values.first { $0.id == id }
    }

    /// By id, so a sheet that finishes closing after a newer prompt opened
    /// in its window leaves the newer one alone.
    private func endStartPrompt(_ id: LeoStartPrompt.ID) {
        guard let prompt = prompt(id) else { return }
        startPrompts[prompt.origin] = nil
    }
}
