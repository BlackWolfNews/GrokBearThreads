import AppKit
import ThreadbearCore

enum SettingsTab: String, Hashable, CaseIterable {
    case general, models, pools
}

/// The Settings window's side of AppModel. Everything in it is the
/// runner's (runner.json and its secrets folder); the app keeps none of it,
/// and never the OpenRouter key, which goes to the runner once and is
/// forgotten.
extension AppModel {
    /// After hello; `settings.updated` replaces them from then on.
    func loadSettings() {
        guard let client else { return }
        Task {
            do {
                receive(try await client.settingsGet())
            } catch RPCError.server(let code, _) where code == RPCError.methodNotFound {
                // A runner from before settings.
                settingsUnsupported = true
                runnerSettings = nil
            } catch {
                AppLog.write("rpc", "settings.get failed: \(error.localizedDescription)")
            }
        }
    }

    func receive(_ settings: RunnerSettings) {
        runnerSettings = settings
        settingsUnsupported = false
        // The new-thread composer starts in the default folder.
        if !settings.defaultCwd.isEmpty { defaults.cwd = (settings.defaultCwd as NSString).expandingTildeInPath }
    }

    /// Changes what's given. The window shows the change straight away;
    /// the runner's answer (or its error) then has the last word.
    func updateSettings(_ update: SettingsUpdate) {
        guard let client else { return settingsError = "Not connected to the runner." }
        if var shown = runnerSettings {
            if let v = update.defaultCwd { shown.defaultCwd = v }
            if let v = update.idleMinutes { shown.idleMinutes = v }
            if let v = update.maxLiveCLIs { shown.maxLiveCLIs = v }
            if let v = update.followMain { shown.followMain = v }
            if let v = update.pool { shown.models.pool = v }
            if let v = update.dailyBudgetUsd { shown.models.dailyBudgetUsd = v }
            if let v = update.privateFolders { shown.models.privateFolders = v }
            runnerSettings = shown
        }
        Task {
            do {
                receive(try await client.settingsUpdate(update))
                settingsError = nil
            } catch {
                settingsError = error.localizedDescription
                AppLog.write("rpc", "settings.update failed: \(error.localizedDescription)")
                loadSettings()
            }
        }
    }

    /// Sends the key to the runner (nil removes it). True once it's saved.
    func setOpenRouterKey(_ key: String?) async -> Bool {
        guard let client else {
            settingsError = "Not connected to the runner."
            return false
        }
        do {
            receive(try await client.settingsSetKey(key: key))
            settingsError = nil
            return true
        } catch {
            // Never log the key, only that it failed.
            settingsError = error.localizedDescription
            AppLog.write("rpc", "settings.setKey failed: \(error.localizedDescription)")
            return false
        }
    }
}
