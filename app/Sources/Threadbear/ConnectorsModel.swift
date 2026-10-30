import AppKit
import ThreadbearCore

/// The Connectors panel's side of AppModel (docs/protocol.md,
/// "Connectors"). The runner asks the gateway; the app only asks the runner.
extension AppModel {
    /// After hello; `connectors.updated` keeps it current from then on.
    func loadConnectors() {
        fetchConnectors(refresh: false)
    }

    /// A fresh look at the gateway: the panel opening, or its refresh
    /// button. The runner skips the ask if it made one a moment ago.
    func refreshConnectors() {
        fetchConnectors(refresh: true)
    }

    private func fetchConnectors(refresh: Bool) {
        guard let client else { return }
        Task {
            do {
                connectors = try await client.connectorsStatus(refresh: refresh)
            } catch RPCError.server(let code, _) where code == RPCError.methodNotFound {
                // A runner from before Connectors: no icon, no panel.
                connectors = nil
                if connectorsShown { connectorsShown = false }
            } catch {
                AppLog.write("rpc", "connectors.status failed: \(error.localizedDescription)")
            }
        }
    }

    /// Opens a service's page on the gateway in the browser: its sign-in
    /// when it's signed out, else where it can be signed out or retried.
    func openConnect(_ service: ConnectorService) {
        guard let url = ConnectorsText.serviceURL(connectors, service) else { return }
        AppLog.write("connectors", "opening the gateway's page for \(service.id)")
        NSWorkspace.shared.open(url)
    }

    /// Opens the gateway's admin page, with every service on it.
    func openConnectorsAdmin() {
        guard let url = ConnectorsText.manageURL(connectors) else { return }
        AppLog.write("connectors", "opening the gateway's admin page")
        NSWorkspace.shared.open(url)
    }
}
