import AppKit
import ThreadbearCore

/// What the schedule editor sheet is editing: a new schedule (from the
/// Scheduled view, or a composer's draft) or one that exists.
struct ScheduleEditorState: Identifiable, Equatable {
    let id = UUID()
    /// The schedule being edited; nil for a new one.
    var scheduleId: String?
    var text = ""
    var title = ""
    var once = false
    var at = Date()
    var repeatChoice = RepeatChoice()
    /// Sends here; nil starts a new thread each time.
    var threadId: String?
    /// The thread it was opened from, which "This thread" means. Nil from
    /// the Scheduled view or the new-thread composer.
    var fromThreadId: String?
    /// Settings for a new thread each time, as the composer would use.
    var cwd = ""
    var accountId: String?
    var model: String?
    var effort: String?
    var ask = false
    /// The composer draft it came from, emptied once it's saved.
    var draftKey: String?
    /// Images in that draft, which a schedule can't send.
    var draftImages = 0

    var isNew: Bool { scheduleId == nil }
    var when: ScheduleWhen { once ? .at(at) : .cron(repeatChoice.cron) }
}

extension AppModel {
    // MARK: Loading

    /// The list after hello; `schedules.updated` replaces it from then on.
    func loadSchedules() {
        guard let client else { return }
        Task {
            do {
                schedules = try await client.listSchedules()
                schedulesSupported = true
            } catch RPCError.server(let code, _) where code == RPCError.methodNotFound {
                // A runner from before schedules.
                schedulesSupported = false
                schedules = []
            } catch {
                AppLog.write("rpc", "schedules.list failed: \(error.localizedDescription)")
            }
        }
    }

    var activeScheduleCount: Int { schedules.reduce(0) { $0 + ($1.isActive ? 1 : 0) } }

    func schedule(_ id: String) -> Schedule? { schedules.first { $0.id == id } }

    /// Where a schedule sends: its thread's title, or "New thread in misc".
    func scheduleTarget(_ schedule: Schedule) -> String {
        if let threadId = schedule.threadId {
            guard let thread = threads[threadId] else { return "A thread that's gone" }
            return thread.title.isEmpty ? "Untitled" : thread.title
        }
        return "New thread in \(FolderName.short(schedule.cwd ?? defaults.cwd))"
    }

    func showSchedules() {
        sidebarMode = .scheduled
    }

    // MARK: The editor

    /// A new schedule. From a composer it starts with the draft and that
    /// composer's thread (or, from the new-thread composer, a new thread
    /// each time on the composer's folder, account and model).
    func newSchedule(from thread: ThreadSummary?, draftKey: String? = nil) {
        let settings = ThreadSettings(app: self, thread: thread)
        var state = ScheduleEditorState()
        if let draftKey, let draft = drafts[draftKey] {
            state.text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
            state.draftImages = draft.images.count
            state.draftKey = draftKey
        }
        state.at = ScheduleTime.defaultOnce(now: Date())
        state.threadId = thread?.id
        state.fromThreadId = thread?.id
        state.cwd = draftKey == nil ? defaults.cwd : settings.cwd
        state.accountId = settings.account
        state.model = settings.model
        state.effort = settings.effort
        state.ask = settings.ask
        scheduleEditor = state
    }

    func editSchedule(_ id: String) {
        guard let schedule = schedule(id) else { return }
        var state = ScheduleEditorState(scheduleId: id)
        state.text = schedule.text
        state.title = schedule.title
        state.once = schedule.isOneOff
        state.at = schedule.at ?? ScheduleTime.defaultOnce(now: Date())
        if let cron = schedule.cron { state.repeatChoice = RepeatChoice(cron: cron) }
        state.threadId = schedule.threadId
        state.cwd = schedule.cwd ?? defaults.cwd
        scheduleEditor = state
    }

    /// Makes or updates the schedule. Returns the runner's reason when it
    /// says no, for the sheet to show (it stays open).
    func saveSchedule(_ state: ScheduleEditorState) async -> String? {
        guard let client, connection == .connected else { return "Not connected to the runner." }
        let text = state.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = state.title.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let saved: Schedule
            if let id = state.scheduleId {
                saved = try await client.updateSchedule(id, ScheduleUpdate(
                    title: title.isEmpty ? nil : title, text: text, when: state.when,
                    cwd: state.threadId == nil ? state.cwd : nil
                ))
            } else {
                saved = try await client.createSchedule(NewScheduleRequest(
                    text: text, title: title.isEmpty ? nil : title, when: state.when, threadId: state.threadId,
                    cwd: state.cwd, accountId: state.accountId, model: state.model, effort: state.effort,
                    permissionMode: state.ask ? .ask : .full
                ))
            }
            replace(saved)
            if let key = state.draftKey {
                // Images can't go with a schedule, so they stay in the box.
                if var draft = drafts[key], !draft.images.isEmpty {
                    draft.text = ""
                    drafts[key] = draft
                } else {
                    drafts[key] = nil
                }
            }
            return nil
        } catch {
            AppLog.write("rpc", "saving a schedule failed: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    /// What the runner makes of a time as it's typed: its words and the
    /// next runs, or why it can't read it.
    func previewSchedule(_ when: ScheduleWhen) async -> Result<SchedulePreview, PreviewError> {
        guard let client else { return .failure(PreviewError(message: "Not connected to the runner.")) }
        do {
            return .success(try await client.previewSchedule(when))
        } catch {
            return .failure(PreviewError(message: error.localizedDescription))
        }
    }

    struct PreviewError: Error, Equatable {
        var message: String
    }

    // MARK: Row actions

    func runSchedule(_ id: String) {
        guard let client else { return }
        Task {
            do {
                replace(try await client.runSchedule(id).schedule)
            } catch {
                show(error)
            }
        }
    }

    func setSchedulePaused(_ id: String, _ paused: Bool) {
        guard let client else { return }
        Task {
            do {
                replace(try await client.updateSchedule(id, ScheduleUpdate(paused: paused)))
            } catch {
                show(error)
            }
        }
    }

    /// Asks first: a deleted schedule can't be got back.
    func deleteSchedule(_ id: String) {
        guard let client, let schedule = schedule(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \u{201C}\(schedule.title)\u{201D}?"
        alert.informativeText = "It won't send its message again."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if scheduleEditor?.scheduleId == id { scheduleEditor = nil }
        Task {
            do {
                try await client.deleteSchedule(id)
                schedules.removeAll { $0.id == id }
            } catch {
                show(error)
            }
        }
    }

    /// A reply's schedule goes in straight away; `schedules.updated` brings
    /// the whole list (in order) a moment later anyway.
    private func replace(_ schedule: Schedule) {
        if let index = schedules.firstIndex(where: { $0.id == schedule.id }) {
            schedules[index] = schedule
        } else {
            schedules.insert(schedule, at: 0)
        }
    }
}
