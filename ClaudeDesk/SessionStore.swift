import Foundation
import Combine

/// Owns one long-lived `ClaudeRunner` per project so a turn keeps running while
/// the user has navigated to a different project's chat. Tracks `runningIDs`
/// (projects with a turn in flight) and `unseenIDs` (turns that finished while
/// the user wasn't watching) for sidebar dot rendering.
@MainActor
final class SessionStore: ObservableObject {
    /// Projects whose current turn is still in flight.
    @Published private(set) var runningIDs: Set<UUID> = []
    /// Projects with a finished assistant turn the user hasn't seen yet.
    @Published private(set) var unseenIDs: Set<UUID> = []
    /// Projects whose turn appears stuck — `isRunning` is true but no stream
    /// events have arrived in `stuckThresholdSeconds`. Surfaces a ⚠️ in the
    /// sidebar so the user knows they may need to Stop and retry.
    @Published private(set) var stuckIDs: Set<UUID> = []

    /// How long a running turn can sit silent before we call it stuck. Tuned
    /// for the longest expected gap between stream events (extended thinking
    /// can chew this much before a message_delta).
    private let stuckThresholdSeconds: TimeInterval = 90

    private weak var projectStore: ProjectStore?
    private var sessions: [UUID: ClaudeRunner] = [:]
    /// Projects whose ChatView is currently on screen. A turn finishing for
    /// any project NOT in this set goes to `unseenIDs` for the sidebar dot.
    private var currentlyViewing: Set<UUID> = []
    private var monitorTask: Task<Void, Never>?

    init(projectStore: ProjectStore) {
        self.projectStore = projectStore
        startStuckMonitor()
    }

    deinit {
        monitorTask?.cancel()
    }

    private func startStuckMonitor() {
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                // Poll every 5 seconds. Cheaper than waking on every event and
                // good enough granularity for a 90-second threshold.
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self?.scanForStuck()
            }
        }
    }

    private func scanForStuck() {
        let now = Date()
        var freshly: Set<UUID> = []
        for (id, runner) in sessions where runner.isRunning {
            // Use lastEventAt if set, otherwise fall back to runStartedAt so we
            // notice a claude process that never produced any output at all.
            let anchor = runner.lastEventAt ?? runner.runStartedAt ?? now
            if now.timeIntervalSince(anchor) > stuckThresholdSeconds {
                freshly.insert(id)
            }
        }
        if freshly != stuckIDs {
            stuckIDs = freshly
        }
    }

    /// Returns the session for a project, lazily loading the transcript on first
    /// access. The session lives for the rest of the app's lifetime.
    func session(for projectID: UUID) -> ClaudeRunner {
        if let s = sessions[projectID] { return s }
        let transcript = projectStore?.loadTranscript(for: projectID) ?? []
        let s = ClaudeRunner(projectID: projectID, transcript: transcript)
        s.registry = self
        sessions[projectID] = s
        return s
    }

    /// Call from a ChatView's `.onAppear`: this project is now the active one.
    /// Clears its unseen flag and makes it so background turns finishing for
    /// OTHER projects get flagged unseen but not this one.
    func markSeen(_ projectID: UUID) {
        currentlyViewing.insert(projectID)
        unseenIDs.remove(projectID)
    }

    /// Call from ChatView's `.onDisappear` so a project that just scrolled out
    /// of the split (or got de-selected) starts counting unseen turns again.
    func markUnseen(_ projectID: UUID) {
        currentlyViewing.remove(projectID)
    }

    /// Drop a session entirely (e.g. when the project is removed). Cancels any
    /// in-flight turn so the subprocess doesn't keep running for a project
    /// that's gone.
    func remove(_ projectID: UUID) {
        sessions[projectID]?.cancel()
        sessions.removeValue(forKey: projectID)
        runningIDs.remove(projectID)
        unseenIDs.remove(projectID)
        stuckIDs.remove(projectID)
        currentlyViewing.remove(projectID)
    }

    // MARK: - Called by ClaudeRunner

    func didStartTurn(for projectID: UUID) {
        runningIDs.insert(projectID)
        // Don't accumulate stale unseen flags from prior turns.
        unseenIDs.remove(projectID)
    }

    func didFinishTurn(for projectID: UUID) {
        runningIDs.remove(projectID)
        stuckIDs.remove(projectID)
        if !currentlyViewing.contains(projectID) {
            unseenIDs.insert(projectID)
        }
    }
}
