import BearDock
import AppKit
import ThreadbearCore

/// The CLIs' versions and updates, and what to do when an account runs out
/// of room. The app never polls: `accounts.updated` and `clis.updated`
/// bring the news, and the popover redraws its relative times from `now`.
extension AppModel {
    /// After hello, for a runner that didn't put its CLIs in it: a step 4
    /// runner answers with the list, an older one with -32601.
    func loadClis() {
        guard let client else { return }
        Task {
            do {
                clis = try await client.listClis()
                clisSupported = true
            } catch RPCError.server(let code, _) where code == RPCError.methodNotFound {
                clis = []
                clisSupported = false
            } catch {
                AppLog.write("rpc", "clis.list failed: \(error.localizedDescription)")
            }
        }
    }

    /// The Usage panel's charts. The panel asks when it opens and once a
    /// minute while it stays open; nothing else needs them.
    func loadUsageStats() async {
        guard let client else { return }
        do {
            usageStats = try await client.usageStats()
            usageStatsSupported = true
        } catch RPCError.server(let code, _) where code == RPCError.methodNotFound {
            usageStatsSupported = false
        } catch {
            AppLog.write("rpc", "usage.stats failed: \(error.localizedDescription)")
        }
    }

    /// The usage popover's buttons. Each returns at once; progress comes
    /// through `clis.updated`.
    func checkClis() { cliCall("clis.check") { try await $0.checkClis() } }

    func updateCli(_ provider: String, version: String? = nil, force: Bool = false) {
        cliCall("clis.update") { try await $0.updateCli(provider: provider, version: version, force: force) }
    }

    func setCliPolicy(_ provider: String, _ policy: String) {
        cliCall("clis.setPolicy") { try await $0.setCliPolicy(provider: provider, policy: policy) }
    }

    private func cliCall(_ method: String, _ call: @escaping (RPCClient) async throws -> [CliStatus]) {
        guard let client else { return }
        Task {
            do {
                clis = try await call(client)
                clisSupported = true
            } catch RPCError.server(let code, _) where code == RPCError.methodNotFound {
                clisSupported = false
            } catch {
                show(error)
            }
        }
    }

    /// An update under way, or one that failed and hasn't been dismissed,
    /// for the quiet line under the toolbar.
    var cliBanner: (text: String, failedKey: String?)? {
        for cli in clis {
            guard let update = cli.update, let text = CliText.bannerText(cli) else { continue }
            if update.state == "failed" {
                let key = Self.failureKey(cli)
                if dismissedCliFailures.contains(key) { continue }
                return (text, key)
            }
            return (text, nil)
        }
        return nil
    }

    static func failureKey(_ cli: CliStatus) -> String {
        "\(cli.provider)|\(cli.update?.finishedAt.map(ISO8601.format) ?? cli.update?.targetVersion ?? "")"
    }

    func dismissCliFailure(_ key: String) { dismissedCliFailures.insert(key) }

    // MARK: Limits

    /// When the open thread can't go on where it is: its account is at its
    /// limit, or its last turn failed on the limit. Says so, and where it
    /// could go instead.
    struct LimitAdvice: Equatable {
        var text: String
        var target: Account?
    }

    func limitAdvice(for thread: ThreadSummary) -> LimitAdvice? {
        let account = account(thread.accountId)
        // A pool thread is the runner's to move: say nothing while its pool
        // has a login with room, and say when it carries on once it's
        // waiting. The button still offers a login outside the pool, which
        // pins it there.
        if usesPools, let poolId = thread.poolId, let pool = pool(poolId) {
            if let waiting = thread.waitingForRoom {
                return LimitAdvice(text: Pools.waitingSentence(poolTitle: pool.title, waiting, now: now),
                                   target: AccountUsageText.switchTarget(accounts, from: thread.accountId))
            }
            if Pools.logins(pool, accounts: accounts).contains(where: Pools.hasRoom) { return nil }
        }
        let blocked = account?.usage?.blocked == true
        // Only while the thread is still on the account the turn failed on:
        // after "Switch to ..." the status stays `error` until the next
        // turn, and the line blamed the new account.
        let failedOnLimit = thread.status == .error && failedOnAccount[thread.id] == thread.accountId
            && loadedSession(thread.id)?.lastTurnErrorKind == .usageLimit
        guard blocked || failedOnLimit else { return nil }
        var text = "\(accountShortTitle(thread.accountId)) has reached its limit"
        if let reset = AccountUsageText.mainWindows(account?.usage).filter({ $0.remainingPercent < 1 }).compactMap(\.resetsAt).min() {
            text += ", resets " + AccountUsageText.resetTime(reset, now: now)
        }
        return LimitAdvice(text: text + ".", target: AccountUsageText.switchTarget(accounts, from: thread.accountId))
    }

    /// Moves a thread to another account (the limit line's button).
    func switchAccount(_ threadId: String, to accountId: String) {
        setAccount(threadId, accountId)
    }
}

extension ThreadSession {
    /// Why the last turn failed, when the runner said (`errorKind`): the
    /// newest footer, a few rows from the end.
    var lastTurnErrorKind: TurnErrorKind? {
        // Read so a view that asks is drawn again once the thread loads
        // (the rows themselves aren't observed).
        guard state == .loaded else { return nil }
        for index in stride(from: displayCount - 1, through: max(0, displayCount - 40), by: -1) {
            if case .footer(let completion) = displayRow(index).content {
                return completion.outcome == .failed ? completion.errorKind : nil
            }
        }
        return nil
    }
}

/// The main window, for popovers that size themselves to fit inside it.
@MainActor
enum AppWindow {
    static var contentHeight: CGFloat? {
        let window = NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.frame.width > 600
            && !($0 is DockPanelWindow) && !String(describing: type(of: $0)).contains("Popover") }
        return window.map { $0.contentLayoutRect.height }
    }

    /// Screen space above the chip whose popover is opening, set just
    /// before the popover is made. Picker popovers open upwards from the
    /// composer, so this, not the window's height, is what they have to
    /// fit in: a window reaching up near the top of the screen left the
    /// model picker's Effort row below the bottom of the screen.
    static var roomAboveAnchor: CGFloat?
}
