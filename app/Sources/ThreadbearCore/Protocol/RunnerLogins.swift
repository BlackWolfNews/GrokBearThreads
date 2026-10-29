import Foundation

/// A runner's logins as its composer pickers need them: its accounts (with
/// their models), its pools and its defaults. This Mac's come from its own
/// hello; another runner's from the hello its connection made, kept fresh by
/// that runner's accounts.updated and pools.updated.
public struct RunnerLogins: Sendable, Equatable {
    public var accounts: [Account]
    public var pools: [Pool]
    public var defaults: RunnerDefaults

    public init(accounts: [Account], pools: [Pool], defaults: RunnerDefaults) {
        self.accounts = accounts
        self.pools = pools
        self.defaults = defaults
    }

    public init(hello: HelloResult) {
        self.init(accounts: hello.accounts, pools: hello.pools ?? [], defaults: hello.defaults)
    }

    public func account(_ id: String) -> Account? { accounts.first { $0.id == id } }
    public func pool(_ id: String) -> Pool? { pools.first { $0.id == id } }
}
